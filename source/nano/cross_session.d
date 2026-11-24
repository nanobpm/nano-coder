/// Cross-session history (issue #271, part of #264): `sessions_list` and the
/// `session` argument of `history_search`/`history_read`, so an agent can read
/// another session's log instead of the user copying context between sessions
/// by hand.
///
/// Everything here is read-only and bounded: another session's log is streamed
/// through the same `history_search`/`history_read` machinery as the current
/// one (never loaded whole beyond what those already hold, and capped by the
/// same byte limits), and a live session's log is only read — never locked,
/// moved or rewritten. "Live" is probed with the session log's own flock: a
/// running nano-coder holds it exclusively for the life of its writer.
///
/// Permissions: a session whose working directory is the current workspace
/// (or below it) may be read outright. Reading one from another directory
/// goes through the permission policy as a read of that log (`Policy.checkIn`
/// with the log's absolute path), so a `Read(...)` deny rule still hides it
/// and an unverifiable read is blocked unless the sandbox confines it.
module nano.cross_session;

@safe:

import std.algorithm : canFind, startsWith, endsWith, map;
import std.array : array, join, replace;
import std.format : format;
import std.json;
import std.string : toLower, strip;
import std.conv : to;

import nano.paths : startsWithPath, normalize;
import nano.permissions : Policy;
import nano.safeio : jsonText;
import nano.session_history : HistoryError;
import nano.session_index : Summary, list;
import nano.option : Option, some, unwrap;

/// One session as `sessions_list` reports it.
struct SessionInfo
{
    string id;
    /// Working directory the session started in (null for older logs).
    string cwd;
    /// The model's few-word title, else the first telling prompt, else the first prompt.
    string title;
    /// RFC 3339, as written in the log header.
    string createdAt;
    /// When the log was last written (RFC 3339).
    string lastUsed;
    /// `lastUsed` as absolute hnsecs (`SysTime.stdTime`): the sort key, since
    /// local-time strings misorder across a DST fallback.
    long lastUsedTime;
    /// The log file `history_search`/`history_read` stream.
    string path;
    /// A process currently has the log open (it holds the log's flock).
    bool live;
    /// The live session accepts inter-session messages (issue #272): it
    /// listens on a registry socket (`session_messages` on).
    bool messages;
    /// The session's user-chosen handle (issue #300), or null. A running
    /// session's comes from the registry, a stopped one's from the index.
    string name;
    /// The process holding a live session's log (0 when unknown or not live;
    /// found through `/proc/locks`, so Linux only).
    int pid;
    /// That process's current working directory (null when unknown); it can
    /// differ from `cwd`, where the session started.
    string processCwd;
}

/// What `Summary` names a session by (title, else first telling prompt).
private string nameOf(const ref Summary s) pure @safe
{
    return s.title.length ? s.title
        : s.firstTellingPrompt.length ? s.firstTellingPrompt
        : s.firstPrompt;
}

private SessionInfo infoOf(Summary s, bool live) @safe
{
    import nano.session : stamp;
    SessionInfo i;
    i.id = s.id;
    i.cwd = s.cwd;
    i.title = nameOf(s); // full: resolve() and filters match it; lineOf shortens
    i.name = s.name;
    i.createdAt = s.createdAt;
    i.lastUsed = stamp(s.lastUsed);
    i.lastUsedTime = s.lastUsed.stdTime;
    i.path = s.path;
    i.live = live;
    return i;
}

/// Whether a live session accepts messages: its registry socket answers
/// (issue #272). A stale socket (a dead session) is left for the next
/// `session_send` to remove; here it just doesn't mark the session.
private bool acceptsMessages(string id) @safe
{
    import std.file : exists;
    import nano.peers : peersDir, socketPath;
    import std.socket : Socket, UnixAddress, AddressFamily, SocketType, SocketException, SocketOSException;
    auto path = socketPath(peersDir(), id);
    if (!path.exists) return false;
    import nano.peers : unixSocket;
    auto s = unixSocket();
    scope (exit) s.close();
    // Non-blocking: a listener whose backlog is full (busy routing) must not
    // stall discovery; a would-block connect means a live listener.
    s.blocking = false;
    try
    {
        s.connect(new UnixAddress(path));
        return true;
    }
    catch (SocketOSException e)
    {
        import core.stdc.errno : EAGAIN, EINPROGRESS;
        return e.errorCode == EAGAIN || e.errorCode == EINPROGRESS; // else stale: not reachable
    }
    catch (SocketException) return false; // stale or refusing: not reachable
}

/// Whether a process currently holds `path`'s session lock. Probed by opening
/// the log read-only and attempting the same non-blocking exclusive flock a
/// writer takes: `contended` means a live writer holds it. The probe never
/// waits and closes at once, so a live session is never disturbed.
private bool isLive(string path) @safe
{
    import nano.safeio : tryLockFile, LockResult;
    import std.file : exists;
    if (!path.exists) return false;
    return tryLockFile(path) == LockResult.contended;
}

/// Every session in `dir` with at least one prompt, newest first, with the
/// live flag probed. `filter` keeps sessions whose id, title or working
/// directory contains it (case-insensitive). The current session is included
/// (marked live) so an id prefix can be checked against it too.
///
/// Discovery is permission-aware (issue #271): a session another workspace's
/// policy denies is omitted before its log is opened for summarizing and
/// before any cached metadata (title, first request) is returned, so
/// `sessions_list` can't leak a denied session's existence or contents. The
/// check reads only each log's header line for its recorded cwd.
SessionInfo[] listSessions(ref Policy policy, string dir, string cwd, string filter = null) @safe
{
    import nano.session : logHeaderCwd;
    import nano.handle : runningHandles;
    import nano.peers : peersDir;
    SessionInfo[] out_;
    auto handles = runningHandles(peersDir(), dir);
    // /proc/locks is read and indexed once per discovery, not per live session.
    bool locksRead;
    int[string] locks;
    void probe(ref SessionInfo i)
    {
        if (!locksRead) { locks = readLockIndex(); locksRead = true; }
        probeProcess(i, locks);
    }
    bool matches(const ref SessionInfo i, string f)
    {
        return i.id.toLower.canFind(f) || i.title.toLower.canFind(f)
            || (i.title.length && shortTitle(i.title).toLower.canFind(f)) || (i.name.length && i.name.canFind(f))
            || (i.cwd.length && i.cwd.toLower.canFind(f));
    }
    // Deny before the index opens or reports a log (issue #271): the header's
    // cwd decides whether the policy judges the log a foreign read.
    bool deniedPath(string path)
    {
        auto sessionCwd = logHeaderCwd(path);
        if (inWorkspace(sessionCwd, cwd)) return false;
        return policy.checkIn("read_file", JSONValue(["path": JSONValue(path)]), cwd) !is null;
    }
    foreach (s; list(dir, false, &deniedPath))
    {
        auto i = infoOf(s, isLive(s.path));
        if (i.live)
        {
            i.messages = acceptsMessages(i.id);
            // The registry is current for a running session (the index
            // catches up after its next turn).
            i.name = handles.get(i.id, null);
            probe(i);
        }
        if (!i.cwd.length) i.cwd = logHeaderCwd(s.path);
        if (filter.length && !matches(i, filter.toLower)) continue;
        out_ ~= i;
    }
    // A just-opened session listening for messages has no prompts yet, so
    // the index omits it; list it too (after the same permission check) or
    // `session_send` can't reach it until its user runs a turn.
    foreach (i; listeningWithoutPrompts(dir, out_, &deniedPath))
    {
        i.name = handles.get(i.id, null);
        probe(i);
        if (filter.length && !matches(i, filter.toLower)) continue;
        out_ ~= i;
    }
    return out_;
}

/// Live sessions with a peer socket and a log in `dir` that `known` doesn't
/// already list (the index skips sessions without prompts).
private SessionInfo[] listeningWithoutPrompts(string dir, const SessionInfo[] known,
    scope bool delegate(string path) @safe denied) @safe
{
    import std.file : dirEntries, SpanMode, exists, FileException;
    import std.path : baseName, buildPath, extension, stripExtension;
    import nano.peers : peersDir;
    import nano.session : logHeaderCwd;
    SessionInfo[] out_;
    auto pdir = peersDir();
    if (!pdir.exists) return out_;
    string[] socks;
    try
        foreach (e; dirEntries(pdir, "*.sock", SpanMode.shallow)) socks ~= e.name;
    catch (FileException) return out_; // unreadable peers dir: nothing extra to list
    foreach (sock; socks)
    {
        auto id = sock.baseName.stripExtension;
        if (!id.length || known.canFind!((k, x) => k.id == x)(id)) continue;
        auto path = buildPath(dir, id ~ ".jsonl");
        if (!path.exists || denied(path) || !isLive(path) || !acceptsMessages(id)) continue;
        SessionInfo i;
        i.id = id;
        i.path = path;
        i.live = true;
        i.messages = true;
        i.cwd = logHeaderCwd(path);
        // Its activity is the log's mtime, as the index uses for others, so
        // a just-opened listener sorts by when it was last written.
        try
        {
            import std.file : timeLastModified;
            import nano.session : stamp;
            auto t = timeLastModified(path);
            i.lastUsed = stamp(t);
            i.lastUsedTime = t.stdTime;
        }
        catch (FileException) {} // vanished since the probe: sorts last
        out_ ~= i;
    }
    return out_;
}

/// Longest title `sessions_list` shows, in bytes (issue #348): worker
/// sessions are otherwise titled with a whole job payload.
enum maxTitleBytes = 120;

/// Default and largest `limit` of `sessions_list` (issue #348).
enum defaultListLimit = 50;
/// ditto
enum maxListLimit = 500;

/// A short title for `title` (issue #348): an ACP job payload (`{"jobKey":…,
/// "jobType":…,"processInstanceKey":…}` first input) becomes
/// `jobType · pik N`; anything else is capped at `maxTitleBytes` on a
/// character boundary with a trailing `…`.
string shortTitle(string title) pure @safe
{
    auto t = title.strip;
    if (t.startsWith("{"))
    {
        auto jt = jsonStringField(t, "jobType");
        if (jt.length)
        {
            auto pik = jsonScalarField(t, "processInstanceKey");
            return capTitle(pik.length ? jt ~ " · pik " ~ pik : jt);
        }
    }
    return capTitle(t);
}

private string capTitle(string t) pure @safe
{
    import std.utf : stride, UTFException;
    import std.string : indexOf;
    auto nl = t.indexOf('\n');
    if (nl >= 0) t = t[0 .. nl].strip ~ " …";
    if (t.length <= maxTitleBytes) return t;
    size_t end = 0;
    try
        while (end < t.length)
        {
            immutable n = stride(t, end);
            if (end + n > maxTitleBytes - 3) break; // room for "…"
            end += n;
        }
    catch (UTFException) {} // invalid UTF-8: cut at the last good boundary
    return t[0 .. end] ~ "…";
}

/// The string value of `"key":"…"` in raw JSON text (no unescaping; job
/// types and keys are plain), or null. Raw text is scanned because the
/// payload is often followed by prose or truncated.
private string jsonStringField(string text, string key) pure @safe
{
    import std.string : indexOf;
    auto at = text.indexOf(`"` ~ key ~ `"`);
    if (at < 0) return null;
    auto rest = text[at + key.length + 2 .. $].stripLeftColon;
    if (!rest.startsWith(`"`)) return null;
    auto close = rest[1 .. $].indexOf('"');
    return close < 0 ? null : rest[1 .. 1 + close];
}

/// `"key":` followed by a number or a quoted string, as text, or null.
private string jsonScalarField(string text, string key) pure @safe
{
    import std.string : indexOf;
    auto s = jsonStringField(text, key);
    if (s.length) return s;
    auto at = text.indexOf(`"` ~ key ~ `"`);
    if (at < 0) return null;
    auto rest = text[at + key.length + 2 .. $].stripLeftColon;
    size_t n;
    while (n < rest.length && rest[n] >= '0' && rest[n] <= '9') n++;
    return rest[0 .. n];
}

private string stripLeftColon(string s) pure @safe
{
    import std.string : stripLeft;
    s = s.stripLeft;
    if (s.startsWith(":")) s = s[1 .. $];
    return s.stripLeft;
}

unittest
{
    assert(shortTitle(`{"jobKey":"1","jobType":"senior:pr-review","processInstanceKey":"289676","prompt":"long…"}`)
        == "senior:pr-review · pik 289676");
    assert(shortTitle(`{"jobType": "x", "processInstanceKey": 42}`) == "x · pik 42");
    assert(shortTitle(`{"jobType":"only"}`) == "only");
    assert(shortTitle(`{"a":1}`) == `{"a":1}`);
    assert(shortTitle("fix the parser") == "fix the parser");
    assert(shortTitle("first line\nsecond") == "first line …");
    import std.array : replicate;
    auto capped = shortTitle("é".replicate(200));
    assert(capped.length <= maxTitleBytes && capped.endsWith("…"));
    import std.utf : validate;
    validate(capped);
    assert(shortTitle("a".replicate(maxTitleBytes)) == "a".replicate(maxTitleBytes));
}

/// `/proc/locks` indexed by `lockIndex`; empty where `/proc` is absent
/// (macOS), unreadable or malformed, so pids stay unknown (best effort).
private int[string] readLockIndex() @safe
{
    import std.file : readText, FileException;
    import std.conv : ConvException;
    try return lockIndex(readText("/proc/locks"));
    catch (FileException) {} // no /proc: leave pids unknown
    catch (ConvException) {} // malformed /proc/locks line: leave pids unknown
    return null;
}

/// Fill a live session's `pid` and `processCwd` from the `/proc/locks`
/// index (the process holding the log's flock) and `/proc/<pid>/cwd`. Best
/// effort: leaves them unset where `/proc` is absent or unreadable.
private void probeProcess(ref SessionInfo i, const int[string] locks) @safe
{
    import std.file : DirEntry, readLink, FileException;
    try
    {
        auto st = DirEntry(i.path).statBuf;
        i.pid = locks.get(lockKey(st.st_dev, st.st_ino), 0);
        if (i.pid > 0) i.processCwd = readLink(format("/proc/%s/cwd", i.pid));
    }
    catch (FileException) {} // the log or process just went away: leave unknown
}

/// The `lockIndex` key for the file `dev`:`ino`.
private string lockKey(ulong dev, ulong ino) pure @safe
{
    immutable major = ((dev >> 8) & 0xfff) | ((dev >> 32) & ~0xfffUL);
    immutable minor = (dev & 0xff) | ((dev >> 12) & ~0xffUL);
    return format("%x:%x:%s", major, minor, ino);
}

/// FLOCK holders in `/proc/locks` text, keyed by `lockKey`, so one read
/// serves every live session's lookup.
int[string] lockIndex(string locks) pure @safe
{
    import std.string : lineSplitter, split;
    int[string] out_;
    foreach (line; locks.lineSplitter)
    {
        auto f = line.split;
        // "1: FLOCK ADVISORY WRITE 1234 08:02:5678 0 EOF"; blocked waiters ("->") shift by one.
        if (f.length < 6 || f[1] != "FLOCK") continue;
        auto parts = f[5].split(":");
        if (parts.length != 3) continue;
        auto key = format("%x:%x:%s", parts[0].to!ulong(16), parts[1].to!ulong(16), parts[2].to!ulong);
        if (key !in out_) out_[key] = f[4].to!int;
    }
    return out_;
}

/// The pid holding a FLOCK on the file `dev`:`ino` per `/proc/locks` text, or 0.
int lockHolder(string locks, ulong dev, ulong ino) pure @safe
{
    return lockIndex(locks).get(lockKey(dev, ino), 0);
}

unittest
{
    auto locks = "1: POSIX  ADVISORY  WRITE 99 08:02:77 0 EOF\n2: FLOCK  ADVISORY  WRITE 4321 fd:01:77 0 EOF\n";
    immutable dev = (0xfdUL << 8) | 0x01;
    assert(lockHolder(locks, dev, 77) == 4321);
    assert(lockHolder(locks, dev, 78) == 0);
    assert(lockHolder(locks, (8UL << 8) | 2, 77) == 0, "POSIX locks are not session locks");
}

/// One line of the `sessions_list` result.
private string lineOf(const ref SessionInfo i) @safe
{
    auto label = i.title.length ? shortTitle(i.title) : "(no title)";
    auto out_ = format("%s  %s  %s  %s", i.id, label, i.cwd.length ? i.cwd : "(unknown cwd)",
        i.lastUsed.length >= 19 ? i.lastUsed[0 .. 19] : i.lastUsed);
    if (i.live) out_ ~= i.pid > 0 ? format("  [live pid %s]", i.pid) : "  [live]";
    if (i.processCwd.length && i.processCwd != i.cwd) out_ ~= "  [now in " ~ i.processCwd ~ "]";
    if (i.messages) out_ ~= "  [messages]";
    if (i.name.length) out_ ~= "  [name: " ~ i.name ~ "]";
    return out_;
}

/// The `sessions_list` tool result: one `#id title cwd last-activity [live]`
/// line per session, live ones first, then newest first. `live`/`messages`
/// keep only open / `session_send`-reachable sessions; `limit` (default
/// `defaultListLimit`) caps the lines and says how many more matched. The
/// text is also capped in bytes like other tool output.
string listResult(ref Policy policy, string dir, string cwd, JSONValue args) @safe
{
    import nano.tools : truncateOutputBytes, defaultMaxOutput;
    string filter;
    bool onlyLive, onlyMessages;
    long limit = defaultListLimit;
    if (args.type == JSONType.object)
    {
        auto o = args.objectNoRef;
        if (auto f = "filter" in o)
            if (f.type == JSONType.string) filter = f.str;
        if (auto f = "live" in o) onlyLive = f.type == JSONType.true_;
        if (auto f = "messages" in o) onlyMessages = f.type == JSONType.true_;
        if (auto f = "limit" in o)
        {
            if (f.type == JSONType.integer) limit = f.integer;
            else if (f.type == JSONType.uinteger) limit = f.uinteger > maxListLimit ? maxListLimit : f.uinteger.to!long;
        }
    }
    if (limit < 1) limit = 1;
    if (limit > maxListLimit) limit = maxListLimit;
    auto sessions = selectSessions(listSessions(policy, dir, cwd, filter), onlyLive, onlyMessages);
    if (!sessions.length)
    {
        string what = onlyMessages ? "reachable " : onlyLive ? "live " : "";
        return filter.length
            ? format("No %ssessions match %s.", what, JSONValue(filter).jsonText)
            : what.length ? format("No %ssessions.", what) : "No saved sessions.";
    }
    return truncateOutputBytes(limitedLines(sessions, limit), defaultMaxOutput, "sessions-list");
}

/// The first `limit` (clamped to 1..`maxListLimit`) of `sessions` as lines,
/// plus a note saying how many more matched.
string limitedLines(SessionInfo[] sessions, long limit) @safe
{
    if (limit < 1) limit = 1;
    if (limit > maxListLimit) limit = maxListLimit;
    auto shown = sessions.length > limit ? sessions[0 .. limit.to!size_t] : sessions;
    auto text = shown.map!lineOf.array.join("\n");
    if (sessions.length > shown.length)
        text ~= format("\n(%s more not shown; raise limit or narrow with filter/live/messages)",
            sessions.length - shown.length);
    return text;
}

unittest
{
    import std.algorithm : count;
    SessionInfo[] many;
    foreach (n; 0 .. 600)
    {
        SessionInfo i;
        i.id = format("s%s", n);
        many ~= i;
    }
    size_t rows(string t) { return t.count('\n') + 1 - (t.canFind("more not shown") ? 1 : 0); }
    auto def = limitedLines(many, defaultListLimit);
    assert(rows(def) == defaultListLimit && def.canFind("(550 more not shown"));
    assert(rows(limitedLines(many, 3)) == 3 && limitedLines(many, 3).canFind("(597 more not shown"));
    assert(rows(limitedLines(many, 0)) == 1 && limitedLines(many, -5).canFind("(599 more not shown"));
    assert(rows(limitedLines(many, 10_000)) == maxListLimit && limitedLines(many, 10_000).canFind("(100 more"));
    auto few = limitedLines(many[0 .. 2], defaultListLimit);
    assert(rows(few) == 2 && !few.canFind("more not shown"));
}

/// `sessions` filtered by `live`/`messages` and ordered live first, then by
/// last activity (newest first); stable, so ties keep the index order.
SessionInfo[] selectSessions(SessionInfo[] sessions, bool live, bool messages) pure @safe
{
    import std.algorithm : filter, sort, SwapStrategy;
    auto out_ = sessions.filter!(i => (!live || i.live) && (!messages || i.messages)).array;
    out_.sort!((a, b) => a.live != b.live ? a.live : a.lastUsedTime > b.lastUsedTime, SwapStrategy.stable);
    return out_;
}

unittest
{
    SessionInfo s(string id, bool live, bool msgs, long used)
    {
        SessionInfo i;
        i.id = id; i.live = live; i.messages = msgs; i.lastUsedTime = used;
        return i;
    }
    auto all = [s("a", false, false, 3), s("b", true, false, 1),
        s("c", true, true, 2), s("d", false, false, 4)];
    assert(selectSessions(all, false, false).map!(i => i.id).array == ["c", "b", "d", "a"]);
    assert(selectSessions(all, true, false).map!(i => i.id).array == ["c", "b"]);
    assert(selectSessions(all, false, true).map!(i => i.id).array == ["c"]);
    // DST fallback: the absolute time orders, not the local-time string.
    auto later = s("later", false, false, 20), earlier = s("earlier", false, false, 10);
    later.lastUsed = "2026-11-01T01:15:00-05:00";
    earlier.lastUsed = "2026-11-01T01:45:00-04:00";
    assert(selectSessions([earlier, later], false, false).map!(i => i.id).array == ["later", "earlier"]);
}

/// `needle` as one session: an exact id, a handle (issue #300), a unique id
/// prefix, or a title match
/// (case-insensitive; every exact-title match beats any substring match, so
/// two sessions sharing a title report ambiguity instead of silently picking
/// one). An ambiguous match throws a HistoryError listing the candidates.
/// With `fallback`, an empty `needle` resolves to that session (the caller's
/// own log).
SessionInfo resolve(string needle, SessionInfo[] sessions, scope const(SessionInfo)* fallback = null) @safe
{
    if (!needle.length)
    {
        if (fallback !is null) return *fallback;
        throw new HistoryError("no current session to read; pass a session handle, id, prefix or title");
    }
    // An exact id wins, as in `resolveResumeId`: a handle claimed before
    // handles were refused from looking like ids must not shadow that session.
    foreach (i; sessions)
        if (i.id == needle) return i;
    // Then a handle: a running holder beats stopped sessions that once had
    // it, then the newest (`sessions` is newest first).
    {
        Option!SessionInfo stopped;
        immutable lowered = needle.toLower; // handles are always lowercase
        foreach (i; sessions)
            if (i.name.length && i.name == lowered)
            {
                if (i.live) return i;
                if (stopped.isNone) stopped = some(i);
            }
        if (stopped.isSome) return stopped.unwrap("checked just above");
    }
    SessionInfo[] candidates;
    foreach (i; sessions)
    {
        if (i.id == needle) return i;
        if (i.id.startsWith(needle) || (i.title.length && (i.title.toLower.canFind(needle.toLower)
                || shortTitle(i.title).toLower.canFind(needle.toLower))))
            candidates ~= i;
    }
    // Case-insensitive exact titles beat the other substring matches; several
    // sessions may share one title (identical first-request fallbacks too).
    SessionInfo[] exact;
    foreach (ref c; candidates)
        if (c.title.toLower == needle.toLower
            || (c.title.length && shortTitle(c.title).toLower == needle.toLower)) exact ~= c;
    if (exact.length) candidates = exact;
    if (candidates.length == 1) return candidates[0];
    if (!candidates.length)
        throw new HistoryError(format("no session matches %s; sessions_list shows the ids and titles",
            JSONValue(needle).jsonText));
    throw new HistoryError(format("session %s is ambiguous; candidates:\n%s",
        JSONValue(needle).jsonText, candidates.map!lineOf.array.join("\n")));
}

/// The session id `--resume <arg>` / `/resume <arg>` names (issue #300): an
/// exact id first, then a handle (a running holder, else the newest that had
/// it), a unique id prefix, then a title, as `resolve`. An argument
/// that matches nothing listed but names a log file is returned as is (a
/// session without prompts isn't indexed); otherwise throws with the reason.
string resolveResumeId(string dir, string arg) @safe
{
    import std.file : exists;
    import std.path : buildPath;
    import nano.handle : runningHandles;
    import nano.peers : peersDir;
    import nano.handle : plausibleId;
    // An exact log id wins first (as in `resolve`) and needs no listing, so
    // an unrelated corrupt log can't block it.
    if (plausibleId(arg) && (buildPath(dir, arg ~ ".jsonl").exists || buildPath(dir, arg ~ ".jsonl.gz").exists))
        return arg;
    auto handles = runningHandles(peersDir(), dir);
    // A running holder of the handle wins, even one not listed (no prompt yet).
    foreach (id, h; handles)
        if (h.toLower == arg.toLower && buildPath(dir, id ~ ".jsonl").exists) return id;
    SessionInfo[] infos;
    foreach (s; list(dir))
    {
        auto i = infoOf(s, isLive(s.path));
        if (i.live) i.name = handles.get(i.id, null); // a live session holds only its registry claim
        infos ~= i;
    }
    try return resolve(arg, infos).id;
    catch (HistoryError e)
    {
        if (plausibleId(arg) && (buildPath(dir, arg ~ ".jsonl").exists || buildPath(dir, arg ~ ".jsonl.gz").exists)) return arg;
        throw new Exception(e.msg.replace("sessions_list shows", "--list-sessions shows"));
    }
}

/// The `session` argument of a history call: absent (read the caller's own
/// log) or a non-empty string.
string sessionArg(JSONValue args) pure @safe
{
    if (args.type != JSONType.object) return null;
    auto v = "session" in args.objectNoRef;
    if (v is null || v.type == JSONType.null_) return null;
    if (v.type != JSONType.string || !v.str.strip.length)
        throw new HistoryError("session must be a non-empty string (a handle, id, unique id prefix or title)");
    return v.str.strip;
}

/// Whether `sessionCwd` is the current workspace or below it: those sessions
/// may be read without a policy check.
/// Both paths are canonicalized first (symlinks resolved), so a recorded cwd
/// like `<workspace>/link` that points outside the workspace is foreign; a
/// relative or unresolvable path is never in the workspace (fail closed).
bool inWorkspace(string sessionCwd, string cwd) @safe
{
    import nano.paths : canonicalize;
    import std.path : isAbsolute;
    if (!sessionCwd.length || !cwd.length || !sessionCwd.isAbsolute || !cwd.isAbsolute) return false;
    auto s = canonicalize(sessionCwd), c = canonicalize(cwd);
    if (s is null || c is null) return false;
    return startsWithPath(normalize(s), normalize(c));
}

/// Null when the session's log may be read from `cwd`, else the message the
/// model sees. A session from another directory is judged as a read of its
/// log file, so `Read(...)` deny rules still cover it and an unverifiable
/// read is blocked unless the sandbox confines it.
string readDenied(ref Policy policy, const ref SessionInfo s, string cwd) @safe
{
    if (inWorkspace(s.cwd, cwd)) return null;
    return policy.checkIn("read_file", JSONValue(["path": JSONValue(s.path)]), cwd);
}

/// Whether reading `s` from `cwd` needs the user's confirmation first
/// (issue #271's default-ask): any session outside the current workspace
/// that the policy didn't already deny. In-workspace sessions never ask.
bool needsConfirmation(const ref SessionInfo s, string cwd) @safe
{
    return !inWorkspace(s.cwd, cwd);
}

/// The question a cross-workspace read asks before it proceeds.
string confirmQuestion(const ref SessionInfo s) @safe
{
    auto label = s.title.length ? s.title : "(no title)";
    return format("Read session %s (%s) from %s? It belongs to another workspace.", s.id, label,
        s.cwd.length ? s.cwd : "an unknown directory");
}

unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import nano.session : SessionLog;
    import nano.llm : Message;

    auto dir = buildPath(tempDir, "nano-d-cross-session-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    import nano.paths : canonicalize;
    import std.string : toUpper;
    auto root = buildPath(canonicalize(tempDir), "nano-d-cross-session-ws");
    auto alpha = buildPath(root, "alpha"), beta = buildPath(root, "beta");
    mkdirRecurse(buildPath(alpha, "sub")); mkdirRecurse(beta);
    scope (exit) rmdirRecurse(root);
    auto liveLog = new SessionLog(dir, "m", alpha, "sess-live");
    {
        auto finished = new SessionLog(dir, "m", beta, "sess-done");
        finished.input("in-1", "finish the parser slice");
        finished.close();
    }
    liveLog.input("in-2", "keep working on the live one");

    Policy noRules;
    auto all = listSessions(noRules, dir, alpha);
    assert(all.length == 2, all.to!string);
    auto live = all[0].id == "sess-live" ? all[0] : all[1];
    auto done = all[0].id == "sess-done" ? all[0] : all[1];
    assert(live.live, "the open log is live");
    assert(!done.live, "a closed log is not live");
    assert(live.title == "keep working on the live one");
    assert(listSessions(noRules, dir, alpha, "done").length == 1);
    assert(listSessions(noRules, dir, alpha, alpha.toUpper).length == 1, "filter is case-insensitive");
    assert(!listSessions(noRules, dir, alpha, "nope").length);
    {
        // A long title stays whole for resolve() and filters; only the list shortens it.
        import std.array : replicate;
        auto longLog = new SessionLog(dir, "m", beta, "sess-long");
        auto longTitle = "x".replicate(150) ~ " tailword";
        longLog.input("in-3", longTitle);
        longLog.close();
        auto ss = listSessions(noRules, dir, alpha);
        assert(resolve(longTitle, ss).id == "sess-long", "a >120-byte title resolves");
        assert(listSessions(noRules, dir, alpha, "tailword").length == 1, "filter sees past the cap");
        auto shown = shortTitle(longTitle);
        assert(resolve(shown, ss).id == "sess-long", "the displayed short title resolves");
        assert(listSessions(noRules, dir, alpha, shown).length == 1, "filter matches the displayed title");
        { import std.file : remove; import std.algorithm : filter; remove(ss.filter!(x => x.id == "sess-long").front.path); }
    }

    // A deny rule hides a foreign session from the listing entirely, cached
    // title and all; an in-workspace session stays.
    import nano.permissions : parseRule;
    Policy denying;
    denying.deny = [parseRule("Read(" ~ dir ~ "/sess-done.jsonl)")];
    auto visible = listSessions(denying, dir, alpha);
    assert(visible.length == 1 && visible[0].id == "sess-live", visible.to!string);

    // Resolve: exact id, unique prefix, title substring; ambiguity lists candidates.
    assert(resolve("sess-done", all).id == "sess-done");
    assert(resolve("sess-d", all).id == "sess-done");
    assert(resolve("parser", all).id == "sess-done");
    assert(resolve("", all, &live).id == live.id, "a blank needle falls back to the current session");
    bool threw;
    try resolve("sess", all);
    catch (HistoryError e)
    {
        threw = true;
        assert(e.msg.canFind("ambiguous") && e.msg.canFind("sess-live") && e.msg.canFind("sess-done"), e.msg);
    }
    assert(threw);
    threw = false;
    try resolve("zzz", all);
    catch (HistoryError e) { threw = true; assert(e.msg.canFind("no session matches"), e.msg); }
    assert(threw);

    // Two sessions titled alike (identical first-request fallbacks too) are
    // ambiguous by title, case-insensitively; one exact title still wins over
    // a substring of the other.
    SessionInfo a, b, c;
    a.id = "aaaa1111"; a.title = "Fix the parser"; a.path = "/x/a.jsonl"; a.cwd = alpha;
    b.id = "bbbb2222"; b.title = "fix the parser"; b.path = "/x/b.jsonl"; b.cwd = alpha;
    c.id = "cccc3333"; c.title = "Fix the parser tests"; c.path = "/x/c.jsonl"; c.cwd = alpha;
    auto titled = [a, b, c];
    threw = false;
    try resolve("FIX THE PARSER", titled);
    catch (HistoryError e)
    {
        threw = true;
        assert(e.msg.canFind("ambiguous") && e.msg.canFind("aaaa1111") && e.msg.canFind("bbbb2222")
            && !e.msg.canFind("cccc3333"), e.msg);
    }
    assert(threw, "duplicate titles are ambiguous, not first-wins");
    assert(resolve("fix the parser tests", titled).id == "cccc3333", "one exact title beats the substring matches");

    // Workspace check: same tree or below it is fine, a sibling is not.
    assert(inWorkspace(alpha, alpha));
    assert(inWorkspace(buildPath(alpha, "sub"), alpha));
    assert(!inWorkspace(beta, alpha));
    assert(!inWorkspace(null, alpha));
    assert(!inWorkspace("relative/alpha", alpha), "a relative cwd is never in the workspace");
    assert(!inWorkspace(buildPath(alpha, "missing"), alpha), "an unresolvable cwd fails closed");
    // A symlink inside the workspace that points at a sibling is foreign.
    {
        import std.file : symlink;
        auto link = buildPath(alpha, "linked");
        symlink(beta, link);
        assert(!inWorkspace(link, alpha), "a symlink to a sibling escapes the workspace");
        SessionInfo viaLink = done; viaLink.cwd = link;
        assert(needsConfirmation(viaLink, alpha), "a symlinked foreign cwd still asks");
    }

    Policy p;
    assert(readDenied(p, live, alpha) is null);
    assert(readDenied(p, done, alpha) is null, "no rules: another workspace is still allowed");
    p.deny = [parseRule("Read(" ~ dir ~ "/sess-done.jsonl)")];
    auto denied = readDenied(p, done, alpha);
    assert(denied !is null && denied.canFind("denies read_file"), denied is null ? done.path : denied);
    assert(readDenied(p, live, alpha) is null, "a session in the workspace skips the policy");

    // Default-ask: a foreign session needs confirmation, an in-workspace one doesn't.
    assert(needsConfirmation(done, alpha));
    assert(!needsConfirmation(live, alpha));
    assert(confirmQuestion(done).canFind("sess-done") && confirmQuestion(done).canFind(beta));

    liveLog.close();
}

// Issue #300: a handle resolves first — before ids, prefixes and a colliding
// title — and a running holder beats a stopped one, then the newest wins.
unittest
{
    SessionInfo mk(string id, string title, string name, bool live)
    {
        SessionInfo i;
        i.id = id;
        i.title = title;
        i.name = name;
        i.live = live;
        return i;
    }
    // Newest first, as `listSessions` returns them.
    auto sessions = [
        mk("sess-3", "perf", null, false),       // a title that collides with the handle
        mk("sess-2", "older run", "perf", false), // a stopped session that had the handle
        mk("sess-1", "matrix", "perf", true),     // the running holder
    ];
    assert(resolve("perf", sessions).id == "sess-1", "the running holder wins");
    assert(resolve("Perf", sessions).id == "sess-1", "a handle matches whatever the case");
    sessions[2].live = false;
    assert(resolve("perf", sessions).id == "sess-2", "with none running, the newest holder wins");
    assert(resolve("sess-3", sessions).id == "sess-3", "an id still resolves");
    assert(resolve("matrix", sessions).id == "sess-1", "a title still resolves");
    // A legacy ID-shaped handle never shadows the session with that exact id.
    sessions[1].name = "sess-3";
    assert(resolve("sess-3", sessions).id == "sess-3", "an exact id beats a legacy handle");
    sessions[1].name = sessions[2].name = null;
    assert(resolve("perf", sessions).id == "sess-3", "without a holder the title matches");
    // sessions_list shows the handle.
    auto named = mk("sess-9", "t", "nano-engine", true);
    assert(lineOf(named).canFind("[name: nano-engine]"), lineOf(named));
}
