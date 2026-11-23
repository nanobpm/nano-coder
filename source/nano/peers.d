/// Inter-session messages (issue #272, part of #264): a session that opts in
/// (`session_messages = true`, or `/messages on`) listens on a Unix socket in
/// the peer registry, and another session's `session_send` tool delivers a
/// message into its steer/queue path.
///
/// Registry: `<peers dir>/<session-id>.sock`, one per listening session, in a
/// directory created mode 0700. The peers dir is `NANO_CODER_PEERS`, else a
/// `peers` folder next to the session logs. A stale socket (a session that
/// died without `close`) is removed by whoever finds it: a refused `connect`
/// means the file is unlinked and the sender reports `not running`.
///
/// Wire format: one JSON object per line, A2A-shaped so a later A2A bridge
/// maps it directly:
///
///   - request:  `{"jsonrpc":"2.0","id":N,"method":"message/send","params":{
///                 "message":{"role":"user","parts":[{"kind":"text","text":…}],
///                 "messageId":…,"contextId":<sender session id>,
///                 "metadata":{"nano":{"title":…,"confirm":bool}}}}`
///   - response: `{"jsonrpc":"2.0","id":N,"result":{"status":"delivered"|
///                 "queued"|"awaiting confirmation"|"refused"|"not running",
///                 "message":…}}`
///
/// Trust: the receiver serves only a peer whose uid is its own
/// (`socketPeerUid`), and the registry directory is 0700, so another user can
/// neither plant a socket nor connect to one.
///
/// Delivery: the listener thread hands the labelled message to a shared
/// `PeerInbox` the UI thread drains: mid-turn it is queued like a steer
/// (visible, editable and withdrawable in `/queue`); idle it starts a turn.
/// With confirmation on, the UI thread first asks the user to accept or
/// decline and reports the outcome back through the inbox.
///
/// The loop guard (two agents must not ping-pong) lives with the sender: a
/// turn started by a peer message marks the agent (`Agent.peerTurn`), and
/// `session_send` then needs the user's approval whatever the confirm
/// setting.
module nano.peers;

@safe:

import std.algorithm : canFind, endsWith;
import std.array : appender;
import std.format : format;
import std.json;
import std.string : strip;
import std.conv : octal;
import core.time : Duration, seconds;

import nano.option : NotNull, nullable;
import nano.result : Result, unwrap, unwrapErr;
import nano.safeio : Chan, Locked, Shared, spawnDaemon, JoinHandle, jsonText;



/// The tool `session_send` registers as (permission rules name it).
enum sendTool = "session_send";

/// The largest message accepted (the request line included): bigger sends
/// are refused before they are read whole.
enum size_t maxMessageBytes = 64 * 1024;
/// Cap on the bytes of idle deliveries awaiting the user: a slow or absent
/// user must not let peers grow the session's memory without bound.
enum size_t maxQueuedBytes = 1024 * 1024;

/// The label a delivered message carries, e.g.
/// `[from session ab88e980 · ts-performance-matrix] …`.
string label(string senderId, string title) pure
{
    auto brief = senderId.length > 8 ? senderId[0 .. 8] : senderId;
    return title.strip.length
        ? format("[from session %s · %s]", brief, title.strip)
        : format("[from session %s]", brief);
}

unittest
{
    assert(label("ab88e980-rest", "ts-performance-matrix") == "[from session ab88e980 · ts-performance-matrix]");
    assert(label("ab88e980-rest", "  ") == "[from session ab88e980]");
    assert(label("short", "t") == "[from session short · t]");
}

/// The peers directory: `NANO_CODER_PEERS`, else `peers` next to the
/// session logs (`sessionDir`'s parent). Created mode 0700 by `ensureDir`.
string peersDir()
{
    import std.process : environment;
    import std.path : buildPath, dirName;
    import nano.session : sessionDir;
    if (auto x = environment.get("NANO_CODER_PEERS")) return x;
    return buildPath(sessionDir().dirName, "peers");
}

/// Create the peers directory (and parents) mode 0700; tighten an existing
/// one's mode. Returns false when it can't be made a private directory.
bool ensureDir(string dir)
{
    import std.file : exists, isDir, mkdirRecurse, getAttributes;
    import std.path : dirName;
    import nano.safeio : mkdirMode;
    import core.stdc.errno : errno, EEXIST;
    if (dir.exists) return dir.isDir && tighten(dir);
    auto parent = dir.dirName;
    if (parent.length && parent != dir && !parent.exists) mkdirRecurse(parent);
    if (mkdirMode(dir, octal!700) != 0 && errno != EEXIST) return false;
    return tighten(dir);
}

private bool tighten(string dir)
{
    import std.file : getAttributes;
    import nano.safeio : chmodPath;
    if ((getAttributes(dir) & octal!777) == octal!700) return true;
    return chmodPath(dir, octal!700) == 0;
}

unittest
{
    import std.file : tempDir, rmdirRecurse, exists, getAttributes, mkdirRecurse;
    import std.path : buildPath;
    auto root = buildPath(tempDir, "nano-d-peers-dir");
    scope (exit) rmdirRecurse(root);
    auto dir = buildPath(root, "a", "peers");
    assert(ensureDir(dir));
    assert(dir.exists);
    assert((getAttributes(dir) & octal!777) == octal!700, "private to the user");
    assert(ensureDir(dir), "idempotent");
    // A permissive existing directory is tightened.
    auto loose = buildPath(root, "loose");
    mkdirRecurse(loose);
    assert((getAttributes(loose) & octal!777) != octal!700);
    assert(ensureDir(loose));
    assert((getAttributes(loose) & octal!777) == octal!700);
}

/// One message as the wire carries it (already decoded).
struct PeerMessage
{
    string senderId;
    string senderTitle;
    string text;
    string messageId;
    /// The sender asks the receiver to confirm even when its own
    /// `session_messages_confirm` is off (the loop guard's approval).
    bool confirm;

}

/// The `message/send` params, or the error the sender reads.
Result!(PeerMessage, string) parseMessage(JSONValue params) pure
{
    alias R = Result!(PeerMessage, string);
    if (params.type != JSONType.object) return R.err("params must be an object");
    auto m = "message" in params.objectNoRef;
    if (m is null || m.type != JSONType.object) return R.err("params.message must be an object");
    PeerMessage pm;
    if (auto v = "messageId" in m.objectNoRef)
        if (v.type == JSONType.string) pm.messageId = v.str;
    if (auto v = "contextId" in m.objectNoRef)
        if (v.type == JSONType.string) pm.senderId = v.str;
    if (!pm.senderId.length) return R.err("message.contextId (the sender's session id) is required");
    if (auto v = "parts" in m.objectNoRef)
        if (v.type == JSONType.array)
            foreach (p; v.arrayNoRef)
            {
                if (p.type != JSONType.object) continue;
                auto t = "text" in p.objectNoRef;
                if (t !is null && t.type == JSONType.string)
                    pm.text ~= (pm.text.length ? "\n" : "") ~ t.str;
            }
    if (!pm.text.strip.length) return R.err("message has no text part");
    if (auto md = "metadata" in m.objectNoRef)
        if (md.type == JSONType.object)
            if (auto n = "nano" in md.objectNoRef)
                if (n.type == JSONType.object)
                {
                    if (auto v = "title" in n.objectNoRef)
                        if (v.type == JSONType.string) pm.senderTitle = v.str;
                    if (auto v = "confirm" in n.objectNoRef)
                        if (v.type == JSONType.true_ || v.type == JSONType.false_) pm.confirm = v.boolean;
                }
    return R.ok(pm);
}

/// The request line for `pm` (one JSON object, newline-terminated).
string requestLine(PeerMessage pm, long id) pure
{
    JSONValue nano = ["title": JSONValue(pm.senderTitle), "confirm": JSONValue(pm.confirm)];
    JSONValue part = ["kind": JSONValue("text"), "text": JSONValue(pm.text)];
    JSONValue msg = [
        "role": JSONValue("user"),
        "parts": JSONValue([part]),
        "messageId": JSONValue(pm.messageId.length ? pm.messageId : "msg-0"),
        "contextId": JSONValue(pm.senderId),
        "metadata": JSONValue(["nano": nano]),
    ];
    JSONValue req = [
        "jsonrpc": JSONValue("2.0"),
        "id": JSONValue(id),
        "method": JSONValue("message/send"),
        "params": JSONValue(["message": msg]),
    ];
    return req.jsonText(JSONOptions.doNotEscapeSlashes) ~ "\n";
}

unittest
{
    auto line = requestLine(PeerMessage("sess-sender", "a title", "hello there", "m-1", true), 7);
    assert(line.endsWith("\n") && line.canFind(`"method":"message/send"`), line);
    auto v = parseJSON(line);
    auto pm = parseMessage(v["params"]).unwrap("valid request");
    assert(pm.senderId == "sess-sender" && pm.senderTitle == "a title" && pm.text == "hello there" && pm.confirm);
    assert(pm.messageId == "m-1");
    // Two text parts join with a newline.
    auto two = parseJSON(`{"message":{"role":"user","parts":[{"kind":"text","text":"a"},{"kind":"text","text":"b"}],"messageId":"m","contextId":"s"}}`);
    assert(parseMessage(two).unwrap("two parts").text == "a\nb");
    // No text, no contextId: refused.
    assert(parseMessage(parseJSON(`{"message":{"role":"user","parts":[],"messageId":"m","contextId":"s"}}`)).isErr);
    assert(parseMessage(parseJSON(`{"message":{"role":"user","parts":[{"kind":"text","text":"x"}],"messageId":"m"}}`)).isErr);
}

/// The delivery outcomes `session_send` reports (the response's `status`).
enum Status : string
{
    delivered = "delivered",
    queued = "queued",
    awaiting = "awaiting confirmation",
    refused = "refused",
    notRunning = "not running",
}

/// The response line for one request.
private string responseLine(JSONValue id, Status status, string message) pure
{
    JSONValue resp = [
        "jsonrpc": JSONValue("2.0"),
        "id": id,
        "result": JSONValue(["status": JSONValue(status), "message": JSONValue(message)]),
    ];
    return resp.jsonText(JSONOptions.doNotEscapeSlashes) ~ "\n";
}

/// Binding the registry socket failed (another live session of the same id,
/// or an unwritable directory).
class ListenError : Exception
{
    this(string msg) pure @safe { super(msg); }
}

/// One accepted connection's parsed message, handed from the listener
/// thread to the UI thread (which routes it and fills `reply`).
struct PeerRequest
{
    PeerMessage pm;
    /// The UI thread's answer: status and note for the sender (a handle:
    /// default-constructible, always set before the request is put).
    Shared!ReplyCell reply;
}

struct ReplyCell
{
    bool resolved;
    Status status;
    string note;
    /// Routing took the request (it is about to be answered): a timeout
    /// must wait for that answer rather than expire it.
    bool claimed;
    /// The listener gave up waiting and told the sender `refused`: routing
    /// must drop the request, or a retry of the "failed" send runs twice.
    bool expired;
}

/// A listening session's end of the registry: the socket file it owns.
/// `close` stops the listener and removes the socket (idempotent). A struct
/// (one impl per listener), so no new reference type.
struct PeerListener
{
    import std.socket : Socket;
    import nano.option : NotNull, nullable;
    private NotNull!Impl impl;

    private static final class Impl
    {
        string path;
        /// Set at listen() and never nulled (close() is idempotent via
        /// `closed`); a bare reference because the impl is filled by field.
        @nullable("set at listen(), never nulled")
        Socket listener;
        JoinHandle thread;
        bool closed;
        /// Set by close(): the listener thread stops waiting on an
        /// unanswered request and exits promptly instead of after 120 s.
        Shared!bool stop;
    }

    /// Listen on `<dir>/<id>.sock` (the directory must exist); accepted
    /// messages go to `requests`, whose consumer must answer each promptly
    /// (the sender blocks on the reply). Throws when the socket can't be
    /// bound (another live session of the same id).
    static PeerListener listen(string dir, string id, Chan!PeerRequest requests)
    {
        import std.socket : Socket, UnixAddress, SocketException, AddressFamily, SocketType;
        import std.file : exists, remove;
        auto path = socketPath(dir, id);
        auto socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
        try
        {
            // A stale socket from a dead session is replaced; a live one
            // refuses the bind.
            if (path.exists && !live(path)) remove(path);
            socket.bind(new UnixAddress(path));
            socket.listen(4);
        }
        catch (SocketException e)
        {
            socket.close();
            throw new ListenError(format("cannot listen on %s: %s", path, e.msg));
        }
        auto impl = new Impl;
        impl.path = path;
        impl.listener = socket;
        impl.stop = Shared!bool.make;
        // Duplicate the fd for the listener thread so `serve` owns its own
        // `Socket` (its GC finalizer cannot close `impl.listener`'s fd, and
        // `close()` shutting down `impl.listener` still wakes `serve`'s
        // select/accept on the shared open file description).
        import nano.safeio : dupSocket;
        import std.socket : socket_t;
        auto serveFd = dupSocket(impl.listener.handle);
        if (serveFd == socket_t.init)
        {
            socket.close();
            removeIfThere(path);
            throw new ListenError(format("cannot dup listener fd for %s", path));
        }
        impl.thread = spawnDaemon(&serve, serveFd, requests, impl.stop);
        return PeerListener(NotNull!Impl(impl));
    }

    /// The socket's path (for diagnostics).
    string path() { return impl.path; }

    /// Stop the listener thread and remove the socket file (idempotent).
    void close()
    {
        import std.file : exists, remove;
        import std.socket : SocketShutdown, SocketException;
        if (impl.closed) return;
        impl.closed = true;
        auto l = impl.listener;
        // Flag the thread (it polls the flag at least every 100 ms, also
        // while waiting on an unanswered request), wake the accept loop, and
        // join it before closing the fd, so the thread never sees the fd
        // closed (and possibly reused) under it.
        impl.stop.update((ref bool b) { b = true; });
        try l.shutdown(SocketShutdown.BOTH);
        catch (SocketException) {} // already closed: fine
        impl.thread.join();
        l.close();
        if (impl.path.exists) removeIfThere(impl.path);
    }

    private static void serve(imported!"std.socket".socket_t handle_, Chan!PeerRequest requests, Shared!bool stop)
    {
        import core.time : msecs;
        import std.socket : Socket, SocketSet, SocketException, AddressFamily, SocketType;
        import core.sys.posix.unistd : getuid;
        import nano.safeio : socketPeerUid;
        auto listener = new Socket(handle_, AddressFamily.UNIX);
        scope (exit) listener.close();
        auto set = new SocketSet;
        while (!stop.get)
        {
            import core.stdc.errno : errno, EINTR;
            set.reset();
            set.add(listener);
            int n;
            try n = Socket.select(set, null, null, 100.msecs);
            catch (SocketException)
            {
                if (errno == EINTR) continue; // GC stop-the-world / signal
                return; // closed by `close`
            }
            if (n <= 0) continue; // timeout: poll again (close wakes select)
            Socket conn;
            try conn = listener.accept();
            catch (SocketException)
            {
                if (errno == EINTR) continue;
                return; // closed by `close`
            }
            scope (exit) conn.close();
            // Same uid only: anything else is dropped unanswered.
            if (socketPeerUid(conn.handle) != long(getuid())) continue;
            // Bound framing I/O: a client that connects and never finishes
            // its line must not pin the sole listener (or `close`'s join).
            import std.socket : SocketOptionLevel, SocketOption;
            import core.time : seconds;
            conn.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 5.seconds);
            conn.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 5.seconds);
            handle(conn, requests, stop);
        }
    }

    /// One request/response exchange on an accepted connection: parse, hand
    /// to the UI thread, wait for its answer (bounded, so a stuck consumer
    /// never pins the listener), reply.
    private static void handle(Socket conn, Chan!PeerRequest requests, Shared!bool stop)
    {
        import nano.clock : monoNow, since;
        import core.time : msecs, seconds;
        auto line = readLine(conn);
        if (line is null) return;
        JSONValue id0 = JSONValue(0);
        if (line.length > maxMessageBytes)
        {
            sendReply(conn, responseLine(id0, Status.refused, "message too long"));
            return;
        }
        JSONValue id = JSONValue(0);
        string reply;
        JSONValue v;
        try v = parseJSON(line);
        catch (JSONException e)
        {
            reply = responseLine(id, Status.refused, "not JSON: " ~ e.msg);
            sendReply(conn, reply);
            return;
        }
        // Refuse anything that isn't a JSON object *before* any objectNoRef
        // lookup: `[]`, `5`, `"x"` are valid JSON but objectNoRef throws on
        // them, and nothing here catches it — the listener thread would die
        // and the session would silently stop accepting messages while its
        // socket file stayed in place.
        if (v.type != JSONType.object)
        {
            sendReply(conn, responseLine(id, Status.refused, "expected a message/send request"));
            return;
        }
        if (auto pid = "id" in v.objectNoRef) id = *pid;
        auto method = "method" in v.objectNoRef;
        auto params = "params" in v.objectNoRef;
        if (method is null || method.type != JSONType.string
            || method.str != "message/send" || params is null)
        {
            sendReply(conn, responseLine(id, Status.refused, "expected a message/send request"));
            return;
        }
        auto pm = parseMessage(*params);
        if (pm.isErr)
        {
            sendReply(conn, responseLine(id, Status.refused, pm.unwrapErr("isErr")));
            return;
        }
        auto cell = Shared!ReplyCell.make;
        requests.put(PeerRequest(pm.unwrap("isOk"), cell));
        // The UI thread answers within moments (mid-turn) or after the user
        // decides (idle, confirm on): block on the cell's condition (woken
        // by the answering update), bounded so a wedged consumer never pins
        // the listener thread.
        ReplyCell r;
        auto answered = awaitOrStop(cell, stop, r);
        if (!answered)
        {
            // Expire it atomically unless routing already claimed it (then
            // its answer is moments away): an expired request never runs.
            bool expired;
            cell.update((ref ReplyCell c) {
                if (!c.resolved && !c.claimed) { c.expired = true; expired = true; }
            });
            if (expired)
            {
                sendReply(conn, responseLine(id, Status.refused, "the target session did not answer in time"));
                return;
            }
            // Never report success for an unanswered request.
            if (!awaitOrStop(cell, stop, r))
            {
                sendReply(conn, responseLine(id, Status.refused, "the target session did not answer in time"));
                return;
            }
        }
        sendReply(conn, responseLine(id, r.status, r.note));
    }

    /// Wait up to 120 s for `cell` to resolve, in short slices so close()
    /// (setting `stop`) ends the wait promptly; true when it resolved.
    private static bool awaitOrStop(Shared!ReplyCell cell, Shared!bool stop, out ReplyCell r)
    {
        import nano.clock : monoNow, since;
        import core.time : msecs, seconds;
        ReplyCell got;
        auto start = monoNow;
        while (since(start) < 120.seconds)
        {
            if (cell.await((ref const ReplyCell c) => c.resolved, (ref ReplyCell c) { got = c; }, 100.msecs))
            {
                r = got;
                return true;
            }
            if (stop.get) return false;
        }
        return false;
    }

    private static void sendReply(Socket conn, string reply)
    {
        import std.string : representation;
        import std.socket : SocketException;
        try sendAll(conn, reply.representation);
        catch (SocketException) {} // the sender gave up waiting: nothing to do
    }
}

/// Write every byte of `data` to `conn`, retrying on `EINTR` (e.g. a GC
/// stop-the-world signal) and short writes; returns false on error/closed.
private bool sendAll(imported!"std.socket".Socket conn, const(ubyte)[] data)
{
    import core.stdc.errno : errno, EINTR;
    size_t sent = 0;
    while (sent < data.length)
    {
        auto n = conn.send(data[sent .. $]);
        if (n == conn.ERROR)
        {
            if (errno == EINTR) continue;
            return false;
        }
        if (n <= 0) return false;
        sent += size_t(n);
    }
    return true;
}

/// Remove a socket file, ignoring a concurrent removal (a successor may
/// have replaced it, or another cleaner got there first).
private void removeIfThere(string path)
{
    import std.file : remove, FileException;
    try remove(path);
    catch (FileException) {} // already gone: fine
}

/// `<dir>/<id>.sock`; the id is validated (it names a file).
string socketPath(string dir, string id)
{
    import std.path : buildPath;
    import nano.session : validateId;
    validateId(id);
    return buildPath(dir, id ~ ".sock");
}

/// Read one newline-terminated line (bounded), or null on a clean close.
private string readLine(imported!"std.socket".Socket conn, Duration total = 30.seconds)
{
    import core.stdc.errno : errno, EINTR;
    import nano.clock : monoNow, since;
    auto buf = appender!(char[]);
    ubyte[1] b;
    auto start = monoNow;
    while (buf.data.length < maxMessageBytes + 1)
    {
        // A total deadline, not only the per-receive timeout: a sender
        // trickling one byte at a time must not hold the listener.
        if (since(start) > total) return null;
        auto n = conn.receive(b[]);
        if (n == 0) return buf.data.length ? buf.data.idup : null; // closed
        if (n == conn.ERROR)
        {
            // A GC stop-the-world signal (SIGUSR1/SIGUSR2) or SIGCHLD can
            // interrupt blocking recv() with EINTR while the peer is fine.
            if (errno == EINTR) continue;
            return null; // timed out or errored: treat as closed
        }
        if (b[0] == '\n') return buf.data.idup;
        buf ~= char(b[0]);
    }
    return buf.data.idup; // overlong: the caller reports it
}

/// Whether a live session still answers the socket at `path`.
private bool live(string path)
{
    import std.socket : Socket, UnixAddress, AddressFamily, SocketType, SocketException, SocketOSException;
    auto s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    scope (exit) s.close();
    try
    {
        s.connect(new UnixAddress(path));
        return true;
    }
    catch (SocketOSException e) return !stale(e.errorCode);
    catch (SocketException) return false; // no OS error code: treat as stale
}

/// Whether the last socket error proves nobody listens (refused or no
/// such file); other errors (EINTR, EAGAIN, …) keep the socket.
private bool stale(int code) pure nothrow @nogc
{
    import core.stdc.errno : ECONNREFUSED, ENOENT;
    return code == ECONNREFUSED || code == ENOENT;
}

unittest
{
    import core.stdc.errno : ECONNREFUSED, ENOENT, EINTR, EAGAIN;
    assert(stale(ECONNREFUSED) && stale(ENOENT));
    assert(!stale(EINTR) && !stale(EAGAIN));
}

/// Deliver `pm` to the session listening at `<dir>/<to>.sock`; the outcome,
/// with the receiver's note in `note`. A stale socket (connection refused)
/// is removed, so a dead session reports `not running` and its file is gone.
Status send(string dir, string to, PeerMessage pm, out string note)
{
    import std.socket : Socket, UnixAddress, AddressFamily, SocketType;
    import std.file : exists, remove;
    auto path = socketPath(dir, to);
    if (!path.exists)
    {
        note = format("session %s is not listening (messages off, or not running)", to);
        return Status.notRunning;
    }
    auto s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    scope (exit) s.close();
    import std.socket : SocketException, SocketOSException, SocketOption, SocketOptionLevel, wouldHaveBlocked;
    import core.time : seconds;
    // Bound the whole exchange: a full backlog would block connect, and a
    // suspended receiver the reply read, pinning this tool call. The read
    // outlasts the receiver's own 120 s answer deadline.
    s.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 10.seconds);
    s.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 130.seconds);
    bool failed;
    int code;
    try s.connect(new UnixAddress(path));
    catch (SocketOSException e) { failed = true; code = e.errorCode; }
    catch (SocketException) failed = true; // no OS code: not provably stale
    if (failed)
    {
        // A timeout is a busy receiver, not a dead one: keep its socket.
        if (wouldHaveBlocked())
        {
            note = format("session %s did not accept the connection in time", to);
            return Status.refused;
        }
        // Only refused/missing proves nobody listens; keep it otherwise.
        if (!stale(code))
        {
            note = format("session %s could not be reached; try again", to);
            return Status.refused;
        }
        // Stale: nobody is accepting. Remove it so the next listing is clean.
        removeIfThere(path);
        note = format("session %s is not running (removed a stale socket)", to);
        return Status.notRunning;
    }
    string line;
    try
    {
        import std.string : representation;
        if (!sendAll(s, requestLine(pm, 1).representation))
        {
            note = "delivery failed: could not send request";
            return Status.refused;
        }
        line = readLine(s, 140.seconds);
    }
    catch (SocketException e)
    {
        note = "delivery failed: " ~ e.msg;
        return Status.refused;
    }
    if (line is null)
    {
        note = "the receiver closed without answering";
        return Status.refused;
    }
    try
    {
        auto v = parseJSON(line);
        if (v.type != JSONType.object)
        {
            note = "a malformed response from the receiver";
            return Status.refused;
        }
        auto r = "result" in v.objectNoRef;
        if (r is null || r.type != JSONType.object)
        {
            note = "a malformed response from the receiver";
            return Status.refused;
        }
        if (auto m = "message" in r.objectNoRef)
            if (m.type == JSONType.string) note = m.str;
        if (auto st = "status" in r.objectNoRef)
            if (st.type == JSONType.string)
                switch (st.str)
                {
                    case "delivered": return Status.delivered;
                    case "queued": return Status.queued;
                    case "awaiting confirmation": return Status.awaiting;
                    case "refused": return Status.refused;
                    default: return Status.notRunning;
                }
        note = note.length ? note : "a malformed response from the receiver";
        return Status.refused;
    }
    catch (JSONException e)
    {
        note = "a malformed response from the receiver: " ~ e.msg;
        return Status.refused;
    }
}

// ---------------------------------------------------------------------------
// The receiving session's side: shared state the UI thread drains.
// ---------------------------------------------------------------------------

/// One delivered message waiting for the UI thread (idle: confirm and/or
/// start a turn).
struct Inbound
{
    /// The wire message (its strings are immutable: sendable as-is).
    PeerMessage pm;
    /// The labelled text, ready to run as a prompt.
    string labelled;
    /// The receiver's confirm setting asks the user first.
    bool needsConfirm;
    /// The sender hears the outcome through this cell (the request's
    /// reply; a handle, always set before the message can wait here).
    Shared!ReplyCell outcome;
}

/// Resolve an inbound the user answered (or one that needs no answer):
/// accepted messages report `delivered`, declined ones `refused`.
void settle(ref Inbound m, bool accepted, string note = null)
{
    m.outcome.update((ref ReplyCell r) {
        r.resolved = true;
        r.status = accepted ? Status.delivered : Status.refused;
        r.note = note.length ? note
            : accepted ? "accepted by the target session's user" : "declined by the target session's user";
    });
}

/// The question a confirm prompt asks.
string confirmQuestion(const ref Inbound m) pure
{
    import nano.queue : preview;
    return format("Accept a message %s? \"%s\"", label(m.pm.senderId, m.pm.senderTitle), preview(m.pm.text, 120));
}

/// The receiving session's router: the UI thread drains the listener's
/// channel (`requests`), routes each message — mid-turn it joins the running
/// turn's steers under a `/queue` id (answered `queued` at once); idle it
/// waits in `waiting` for the prompt loop to confirm and/or start a turn —
/// and answers the sender through the request's cell.
struct PeerRouter
{
    import nano.control : TurnControl;
    /// The listener hands accepted messages here.
    Chan!PeerRequest requests;
    /// The running turn's controls (steers), so a mid-turn delivery is
    /// `/queue`-visible like a typed steer. Set by make() before any use; a
    /// bare reference so the router stays default-constructible (the prompt
    /// loop declares it before the agent exists).
    @nullable("set by PeerRouter.make before any use")
    private shared TurnControl control;
    /// Idle deliveries the prompt loop hasn't settled yet (a channel: the
    /// listener thread puts, the prompt loop takes).
    private Chan!WaitingItem waiting;
    /// The receiver's confirm setting (the prompt loop keeps it current).
    private Shared!bool confirmSetting;
    /// Whether the agent is mid-turn (set at each turn boundary).
    private Shared!bool midTurnFlag;
    /// Bytes held by `waiting` (bounded by `maxQueuedBytes`).
    private Shared!size_t queuedBytes;
    /// Set when the host has no way to ask its user (ACP): a message that
    /// needs confirmation is refused at routing time, before the sender's
    /// reply is resolved, so the sender reliably hears the refusal.
    private Shared!bool noConfirmChannel;

    // A waiting delivery: the message's strings are immutable (sendable).
    private struct WaitingItem
    {
        PeerMessage pm;
        string labelled;
        bool needsConfirm;
        Shared!ReplyCell outcome;
    }

    static PeerRouter make(shared TurnControl control)
    {
        import core.atomic : atomicLoad, atomicStore;
        PeerRouter r = PeerRouter(Chan!PeerRequest.make, atomicLoad(control), Chan!WaitingItem.make,
            Shared!bool.make(true), Shared!bool.make(false));
        r.queuedBytes = Shared!size_t.make(0);
        r.noConfirmChannel = Shared!bool.make(false);
        return r;
    }

    private this(Chan!PeerRequest requests, shared TurnControl control, Chan!WaitingItem waiting,
            Shared!bool confirmSetting, Shared!bool midTurnFlag)
    {
        import core.atomic : atomicStore;
        this.requests = requests;
        atomicStore(this.control, control);
        this.waiting = waiting;
        this.confirmSetting = confirmSetting;
        this.midTurnFlag = midTurnFlag;
    }

    bool opCast(B : bool)() pure const { return !!requests; }

    /// The receiver's confirm setting, as routing applies it.
    void confirm(bool on) { confirmSetting.update((ref bool b) { b = on; }); }
    bool confirm() { return confirmSetting.get; }

    /// The host can't ask its user to confirm (ACP): refuse such messages
    /// in routing, with an explanatory note, instead of queueing them.
    void confirmUnavailable(bool on) { noConfirmChannel.update((ref bool b) { b = on; }); }

    /// Whether an idle delivery is waiting for `takeWaiting`.
    bool hasWaiting() { return queuedBytes.get > 0; }

    /// Route every request the listener accepted so far. Mid-turn each
    /// becomes a steer (its `/queue` id reserved from `queue`); idle each
    /// waits for the prompt loop. Call at each turn boundary and prompt.
    void routePending(ref imported!"nano.queue".MessageQueue queue)
    {
        PeerRequest req;
        while (requests.tryTake(req))
        {
            // Claim it, unless the listener already timed it out (the
            // sender was told `refused`, so it must not run).
            bool live;
            req.reply.update((ref ReplyCell c) { if (!c.expired) { c.claimed = true; live = true; } });
            if (!live) continue;
            auto labelled = label(req.pm.senderId, req.pm.senderTitle) ~ " " ~ req.pm.text;
            auto confirm = this.confirm || req.pm.confirm;
            if (confirm && noConfirmChannel.get)
            {
                answer(req.reply, Status.refused,
                    "the target session can't ask its user to confirm; it accepts only sends without confirm, and only if its own session_messages_confirm is off");
                continue;
            }
            // Confirmation-requiring messages always wait for the user,
            // even mid-turn: steering them in would bypass the approval.
            if (midTurn && !confirm)
            {
                import core.atomic : atomicLoad;
                // Unread steers are bounded like the idle inbox; the budget
                // frees as the turn reads them (or `/queue` withdraws them).
                if (atomicLoad(control).pendingSteerBytes + labelled.length > maxQueuedBytes)
                {
                    answer(req.reply, Status.refused, "the target session's inbox is full; try again later");
                    continue;
                }
                auto id = queue.reserveId();
                atomicLoad(control).steerWithId(labelled, id, true);
                answer(req.reply, Status.queued, "queued in the target session (visible and editable in /queue)");
            }
            else
            {
                auto bytes = retainedBytes(req.pm, labelled);
                bool admitted;
                queuedBytes.update((ref size_t q) {
                    if (q + bytes <= maxQueuedBytes) { q += bytes; admitted = true; }
                });
                if (!admitted)
                {
                    answer(req.reply, Status.refused, "the target session's inbox is full; try again later");
                    continue;
                }
                waiting.put(WaitingItem(req.pm, labelled.idup, confirm, req.reply));
                // Confirm off: delivered at once (the prompt loop starts the
                // turn). Confirm on: the sender hears awaiting-confirmation
                // at once — a slow user never pins the sender; the outcome
                // is visible in the target's own log and /queue.
                answer(req.reply, confirm ? Status.awaiting : Status.delivered,
                    confirm ? "waiting for the target session's user to accept or decline"
                        : "starts a turn in the target session");
            }
        }
    }

    /// Whether the agent is mid-turn (set at each turn boundary by the
    /// prompt loop): mid-turn deliveries steer, idle ones wait.
    void midTurn(bool on) { midTurnFlag.update((ref bool b) { b = on; }); }
    bool midTurn() { return midTurnFlag.get; }

    /// The next idle delivery the prompt loop must settle, if any.
    bool takeWaiting(out Inbound first)
    {
        WaitingItem item;
        if (!waiting.tryTake(item)) return false;
        auto bytes = retainedBytes(item.pm, item.labelled);
        queuedBytes.update((ref size_t q) { import nano.arith : saturatingSub; q = saturatingSub(q, bytes); });
        first = Inbound(item.pm, item.labelled, item.needsConfirm, item.outcome);
        return true;
    }

    /// Refuse everything addressed to the session being left: accepted
    /// requests not yet routed, idle deliveries and unread peer steers.
    /// Call with the listener stopped, before the session id changes, so
    /// none of it runs in the replacement session.
    void discardAll()
    {
        enum note = "the target session switched to another session before running it";
        PeerRequest req;
        while (requests.tryTake(req))
        {
            bool live;
            req.reply.update((ref ReplyCell c) { if (!c.expired) { c.claimed = true; live = true; } });
            if (live) answer(req.reply, Status.refused, note);
        }
        Inbound m;
        while (takeWaiting(m)) settle(m, false, note);
        import core.atomic : atomicLoad;
        atomicLoad(control).dropPeerSteers();
    }

    /// Run a peer's steer that missed its turn as a later peer prompt, so
    /// it keeps its provenance (the loop guard) instead of becoming an
    /// ordinary prompt. Its sender was answered when it was steered.
    /// Returns false when the inbox is full and the message was dropped.
    bool requeueLate(string labelled)
    {
        auto done = Shared!ReplyCell.make;
        answer(done, Status.queued, "queued");
        PeerMessage pm;
        pm.text = labelled;
        // Its steer budget was freed when the turn drained it, so admit it
        // against the inbox cap (with one steer budget of headroom, since its
        // sender was already told `queued`). Beyond that it is dropped: the
        // inbox must stay bounded across any number of turns.
        auto bytes = retainedBytes(pm, labelled);
        bool admitted;
        queuedBytes.update((ref size_t q) {
            if (q + bytes <= 2 * maxQueuedBytes) { q += bytes; admitted = true; }
        });
        if (!admitted) return false;
        waiting.put(WaitingItem(pm, labelled, false, done));
        return true;
    }

    /// Extract the sender label from a labelled peer message (e.g.
    /// `ab88e980` from `[from session ab88e980 · title] text`) for drop
    /// notices; returns `"peer"` when the prefix is missing. Control
    /// characters and terminal escape sequences are stripped so every
    /// caller gets a terminal-safe single-line value.
    static string senderFromLabel(string labelled) pure
    {
        import std.encoding : sanitize;
        import std.string : indexOf;
        import nano.trajectory : terminalSafe;
        enum prefix = "[from session ";
        if (labelled.length > prefix.length && labelled[0 .. prefix.length] == prefix)
        {
            auto rest = labelled[prefix.length .. $];
            auto close = rest.indexOf(']');
            if (close > 0)
            {
                auto clean = terminalSafe(sanitize(rest[0 .. close])).strip;
                return clean.length ? clean : "peer";
            }
        }
        return "peer";
    }

    /// Every string a waiting item retains, so the byte cap can't be
    /// dodged with a huge sender id, title or message id.
    private static size_t retainedBytes(const ref PeerMessage pm, string labelled) pure nothrow @nogc
    {
        return labelled.length + pm.text.length + pm.senderId.length + pm.senderTitle.length + pm.messageId.length;
    }

    private static void answer(Shared!ReplyCell reply, Status status, string note)
    {
        reply.update((ref ReplyCell r) { r.resolved = true; r.status = status; r.note = note; });
    }
}

/// The `session_send` tool definition (offered only with messages on).
imported!"nano.llm".ToolDefinition sendDefinition() pure
{
    import nano.llm : ToolDefinition;
    return ToolDefinition(sendTool,
        "Send a message to another running nano-coder session on this machine (one that turned "
        ~ "`session_messages` on; sessions_list marks it [messages]). `to` is an id, a unique id prefix or a "
        ~ "title, resolved like the history tools' `session` argument. The message joins the target's input "
        ~ "labelled with this session's id; the target may confirm it first. The result is one of: delivered, "
        ~ "queued (the target is mid-turn; visible in its /queue), awaiting confirmation, refused (the target "
        ~ "has messages off or declined), not running. A turn started by a peer message cannot send one without "
        ~ "the user's approval, so two agents cannot ping-pong.",
        parseJSON(`{"type":"object","properties":{"to":{"type":"string","description":"The target session: an id, a unique id prefix, or a title from sessions_list"},"text":{"type":"string","description":"The message text"},"confirm":{"type":"boolean","description":"Ask the target's user to accept even when their confirm setting is off (default false)"}},"required":["to","text"]}`));
}

// ---------------------------------------------------------------------------
// Tests: two in-process sessions over real registry sockets.
// ---------------------------------------------------------------------------

version (unittest):

/// A stand-in for the prompt loop's routing pass: drains the listener's
/// channel into the router (answering mid-turn and confirm-off deliveries)
/// until `stop`. Confirm-on deliveries wait in the router for the test to
/// `takeWaiting` and `settle` them. Runs on a daemon thread because `send`
/// blocks the calling test thread until the receiver answers.
package(nano) struct TestPump
{
    import nano.queue : MessageQueue;
    import nano.safeio : Shared, JoinHandle, spawnDaemon;
    PeerRouter router;
    MessageQueue queue;
    Shared!bool halt;
    JoinHandle thread;

    static TestPump start(PeerRouter router)
    {
        auto p = TestPump(router, MessageQueue.make, Shared!bool.make(false));
        p.thread = spawnDaemon(&pump, p.router, p.queue, p.halt);
        return p;
    }

    void stop()
    {
        halt.update((ref bool b) { b = true; });
        thread.join();
    }

    private static void pump(PeerRouter router, MessageQueue queue, Shared!bool halt)
    {
        import core.time : msecs;
        import nano.clock : sleepFor;
        while (!halt.get)
        {
            router.routePending(queue);
            sleepFor(1.msecs);
        }
        router.routePending(queue);
    }
}

// Two sessions: one listening, one sending. Delivery idle (confirm off) is
// accepted and waits for the prompt loop; the wire is the A2A shape.
unittest
{
    import std.file : exists, tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import nano.control : TurnControl;
    import nano.queue : MessageQueue;
    import core.atomic : atomicLoad;
    auto root = buildPath(tempDir, "nano-d-peers-send");
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(root);
    auto control = new shared TurnControl;
    auto router = PeerRouter.make(atomicLoad(control));
    router.confirm(false); // the receiver's setting is off until the test turns it on
    auto listener = PeerListener.listen(root, "sess-target", router.requests);
    scope (exit) listener.close();
    assert(socketPath(root, "sess-target").exists, "the registry socket exists");
    auto pump = TestPump.start(router);
    scope (exit) pump.stop();

    // Deliver: idle, confirm off → delivered at once, waiting for the loop.
    string note;
    auto status = send(root, "sess-target", PeerMessage("sess-sender", "a title", "hello there", "m-1", false), note);
    assert(status == Status.delivered, note);
    Inbound inbound;
    assert(router.takeWaiting(inbound), "the message waits for the prompt loop");
    assert(inbound.pm.senderId == "sess-sender" && inbound.pm.text == "hello there");
    assert(inbound.labelled == "[from session sess-sen · a title] hello there", inbound.labelled);
    assert(!inbound.needsConfirm, "confirm off: no ask");
    settle(inbound, true);

    // Confirm on: the sender hears awaiting-confirmation at once (a slow
    // user never pins the sender); the test settles the waiting inbound.
    router.confirm(true);
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "please review", "m-2", false), note);
    assert(status == Status.awaiting, note);
    assert(router.takeWaiting(inbound));
    assert(inbound.needsConfirm);
    settle(inbound, true); // accepted
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "and this?", "m-3", false), note);
    assert(status == Status.awaiting, note);
    assert(router.takeWaiting(inbound));
    settle(inbound, false); // declined

    // Mid-turn: the message joins the steers under a /queue id (the pump
    // routes it; the steer is visible on the turn's control).
    router.midTurn(true);
    // Confirm on mid-turn: still waits for the user, never steered in.
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "needs approval", "m-4a", false), note);
    assert(status == Status.awaiting, note);
    assert(control.pendingSteers.length == 0, "confirmation not bypassed mid-turn");
    assert(router.takeWaiting(inbound));
    settle(inbound, false);
    router.confirm(false);
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "explicit", "m-4b", true), note);
    assert(status == Status.awaiting, "explicit confirm waits mid-turn: " ~ note);
    assert(router.takeWaiting(inbound));
    settle(inbound, false);
    // No confirm channel (ACP): a confirm message is refused in routing,
    // so the sender hears the refusal itself, idle and mid-turn.
    router.confirmUnavailable(true);
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "explicit", "m-4c", true), note);
    assert(status == Status.refused && note.canFind("confirm"), note);
    assert(!router.hasWaiting, "nothing waits for a confirm that can't happen");
    router.midTurn(false);
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "explicit", "m-4d", true), note);
    assert(status == Status.refused, note);
    router.midTurn(true);
    router.confirmUnavailable(false);
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "mid-turn note", "m-4", false), note);
    assert(status == Status.queued, note);
    auto pending = control.pendingSteers;
    assert(pending.length == 1 && pending[0].text == "[from session sess-sen] mid-turn note", pending[0].text);
    assert(pending[0].id >= 0, "listed in /queue");
    router.midTurn(false);

    // Setting off: no listener → not running. A dead listener leaves a stale
    // socket the next send removes.
    listener.close();
    assert(!socketPath(root, "sess-target").exists, "close removes the socket");
    status = send(root, "sess-target", PeerMessage("sess-sender", null, "anyone?", "m-5", false), note);
    assert(status == Status.notRunning, note);
    // A stale socket (no listener behind it) is removed by the sender.
    import std.socket : Socket, UnixAddress, AddressFamily, SocketType;
    auto stale = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    stale.bind(new UnixAddress(socketPath(root, "sess-stale")));
    stale.close(); // bound but nobody accepts: connect is refused
    status = send(root, "sess-stale", PeerMessage("sess-sender", null, "hi", "m-6", false), note);
    assert(status == Status.notRunning, note);
    assert(!socketPath(root, "sess-stale").exists, "the stale socket is cleaned up: " ~ note);
}

// A same-uid client that sends valid *non-object* JSON (`[]`, `5`, `"x"`)
// gets a refusal, not a dead listener: the type check runs before any
// objectNoRef lookup, so the exception that killed the thread is gone and a
// later, valid send is still delivered. Regression test for the listener
// thread dying on objectNoRef's JSONException.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import std.socket : Socket, UnixAddress, AddressFamily, SocketType;
    import std.string : representation;
    import nano.control : TurnControl;
    import core.atomic : atomicLoad;
    auto root = buildPath(tempDir, "nano-d-peers-nonobject");
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(root);
    auto control = new shared TurnControl;
    auto router = PeerRouter.make(atomicLoad(control));
    router.confirm(false);
    auto listener = PeerListener.listen(root, "sess-target", router.requests);
    scope (exit) listener.close();
    auto pump = TestPump.start(router);
    scope (exit) pump.stop();

    // Send a raw non-object JSON line: refused, and the listener survives.
    auto raw = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    scope (exit) raw.close();
    raw.connect(new UnixAddress(socketPath(root, "sess-target")));
    raw.send("[]\n".representation);
    auto reply = readLine(raw);
    assert(reply !is null, "the listener answers the non-object request");
    assert(parseJSON(reply)["result"]["status"].str == "refused", reply);

    // A second, valid send is still delivered: the listener thread lived.
    string note;
    auto status = send(root, "sess-target", PeerMessage("sess-sender", null, "still here", "m-1", false), note);
    assert(status == Status.delivered, note);
    Inbound inbound;
    assert(router.takeWaiting(inbound), "the valid message waits for the loop");
    settle(inbound, true);
}

// The same-uid check: a peer whose uid isn't the process's own is dropped.
// (Can't fake a foreign uid in-process; assert the probe answers our own uid
// and that the listener serves a same-uid peer — the drop path is the
// comparison in serve().)
unittest
{
    import std.socket : Socket, UnixAddress, AddressFamily, SocketType;
    import core.sys.posix.unistd : getuid;
    import nano.safeio : socketPeerUid;
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    auto root = buildPath(tempDir, "nano-d-peers-uid");
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(root);
    auto server = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    server.bind(new UnixAddress(buildPath(root, "x.sock")));
    server.listen(1);
    scope (exit) server.close();
    auto client = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    scope (exit) client.close();
    client.connect(new UnixAddress(buildPath(root, "x.sock")));
    auto conn = server.accept();
    scope (exit) conn.close();
    assert(socketPeerUid(conn.handle) == long(getuid()), "our own peer is recognized");
}

// The loop guard lives in the agent (peerTurn): covered by the agent-level
// test in agent_peers_test.d.

// Review fixes: expired requests never run, every retained string counts
// against the inbox cap, peer steers have a byte budget, late peer steers
// keep their provenance, and a session switch refuses old deliveries.
unittest
{
    import nano.control : TurnControl;
    import nano.queue : MessageQueue;
    import core.atomic : atomicLoad;
    auto control = new shared TurnControl;
    auto router = PeerRouter.make(atomicLoad(control));
    router.confirm(false);
    auto queue = MessageQueue.make;

    // A request the listener timed out is dropped by routing.
    auto expired = Shared!ReplyCell.make;
    expired.update((ref ReplyCell c) { c.expired = true; });
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, "late", "m", false), expired));
    router.routePending(queue);
    assert(!router.hasWaiting, "an expired request never runs");
    assert(!expired.get.resolved);

    // A routed request is claimed, so a timeout can't expire it any more.
    auto live = Shared!ReplyCell.make;
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, "hi", "m", false), live));
    router.routePending(queue);
    assert(live.get.claimed && live.get.resolved && router.hasWaiting);
    Inbound m;
    assert(router.takeWaiting(m));
    assert(!router.hasWaiting, "the accounting returns to zero");

    // A tiny body with a huge message id is charged for the id.
    import std.array : replicate;
    auto big = "x".replicate(maxQueuedBytes / 2 + 1);
    auto c1 = Shared!ReplyCell.make, c2 = Shared!ReplyCell.make;
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, "a", big, false), c1));
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, "b", big, false), c2));
    router.routePending(queue);
    assert(c1.get.status == Status.delivered);
    assert(c2.get.status == Status.refused, "the second big message id overflows the cap");
    assert(router.takeWaiting(m));

    // Mid-turn: peer steers are flagged and bounded by unread bytes.
    router.midTurn(true);
    auto s1 = Shared!ReplyCell.make, s2 = Shared!ReplyCell.make;
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, big, "m", false), s1));
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, big, "m", false), s2));
    router.routePending(queue);
    assert(s1.get.status == Status.queued);
    assert(s2.get.status == Status.refused, "unread peer steers are capped");
    auto steers = control.takePending;
    assert(steers.length == 1 && steers[0].fromPeer, "a peer steer keeps its provenance");
    auto s3 = Shared!ReplyCell.make;
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, big, "m", false), s3));
    router.routePending(queue);
    assert(s3.get.status == Status.queued, "the budget frees once steers are read");
    router.midTurn(false);

    // A late peer steer runs later as a (pre-answered) peer prompt.
    assert(router.requeueLate("[from session sess-a] later"));
    assert(router.takeWaiting(m) && m.labelled == "[from session sess-a] later" && !m.needsConfirm);
    assert(PeerRouter.senderFromLabel("[from session sess-a · title] hi") == "sess-a · title");
    assert(PeerRouter.senderFromLabel("[from session sess-a] hi") == "sess-a");
    assert(PeerRouter.senderFromLabel("unlabelled") == "peer");
    assert(PeerRouter.senderFromLabel("[from session sess-a · \x1b[31mevil\x1b[0m\nline] hi") == "sess-a · evilline");
    assert(PeerRouter.senderFromLabel("[from session \x1b[2J] hi") == "peer");
    assert(PeerRouter.senderFromLabel("[from session \xC3] hi").length > 0);

    // Late steers can't grow the inbox past its bound across turns.
    {
        auto quarter = "x".replicate(maxQueuedBytes / 4);
        size_t accepted, dropped;
        foreach (i; 0 .. 32)
        {
            if (router.requeueLate(quarter)) accepted++;
            else dropped++;
        }
        size_t n;
        while (router.takeWaiting(m)) n++;
        assert(n == accepted && accepted > 0 && dropped > 0, "dropped late steers are reported to the caller");
    }

    // Leaving a session refuses its queued, waiting and steered messages.
    auto w = Shared!ReplyCell.make, q = Shared!ReplyCell.make;
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, "w", "m", false), w));
    router.routePending(queue);
    router.requests.put(PeerRequest(PeerMessage("sess-a", null, "q", "m", false), q));
    router.discardAll();
    assert(!router.hasWaiting && q.get.status == Status.refused);
    assert(!control.hasSteers, "the unread peer steer was dropped");
    assert(w.get.status == Status.refused, "a waiting delivery is refused");
}
