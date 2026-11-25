/// A scripted local HTTP server for provider tests (Rust's `test_server`):
/// each connection gets the next reply; requests are captured.
module nano.testserver;
@safe:
import nano.clock : sleepFor;

version (unittest):

import nano.safeio : Chan, Join, spawn;

/// A reply: status, extra header lines ("name: value\r\n"…) and body. An
/// `x-truncate` header cuts the body short (a dropped stream).
struct Reply
{
    int status;
    string headers;
    string body_;
    /// When set, the body is sent without a length, one `\n\n`-ended event
    /// at a time with this many milliseconds before each, then the
    /// connection closes (a slow but steady stream).
    int dripMs;
}

/// One request as the server saw it.
struct Captured
{
    string method, path, headers, body_;
}

struct TestServer
{
    string url;
    private Join!(immutable(Captured)[]) handle;
    private Chan!bool stop;

    /// Stop serving (replies nobody asked for are dropped) and return the
    /// requests seen.
    immutable(Captured)[] finish()
    {
        stop.put(true);
        return handle.join();
    }
}

/// Serve `replies` in order, one per connection, on 127.0.0.1.
///
/// The URL carries a path prefix unique to this server. Tests run on threads
/// of one process, and a client of another test (a retry or an outage probe
/// aimed at a port that has since closed) can connect to this server once
/// the OS hands it the same port. Such a connection gets a 404 and does not
/// use up a reply, so the test's own client still gets every reply
/// (issue #388: a stray connection took the second reply and the retry
/// found the server gone).
TestServer serve(immutable(Reply)[] replies)
{
    import std.format : format;
    import core.atomic : atomicOp;
    static shared ulong servers;
    immutable prefix = format("/srv%s-%s", processNonce, atomicOp!"+="(servers, 1));
    auto port = Chan!ushort.make;
    auto stop = Chan!bool.make;
    auto h = spawn(&run, replies, prefix, port, stop);
    ushort p;
    port.take(p);
    return TestServer(format("http://127.0.0.1:%s%s", p, prefix), h, stop);
}

/// Differs between test processes, so a prefix can't match another run's.
private ulong processNonce() nothrow
{
    import std.process : thisProcessID;
    return thisProcessID;
}

private immutable(Captured)[] run(immutable(Reply)[] replies, string prefix, Chan!ushort port, Chan!bool stop)
{
    import core.time : seconds;
    import std.algorithm : canFind;
    import std.conv : to;
    import std.format : format;
    import std.socket;
    import std.string : indexOf, splitLines, strip, toLower, startsWith;
    auto listener = new TcpSocket;
    scope (exit) listener.close();
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(8);
    port.put((cast(InternetAddress) listener.localAddress).port);
    immutable(Captured)[] seen;
    for (size_t next = 0; next < replies.length;)
    {
        auto r = replies[next];
        if (!awaitClient(listener, stop)) break;
        // Not `listener.accept()`: on macOS a client that already left makes
        // it leave a GC finalizer that later closes a reused fd number
        // (nano.safeio.acceptFd, issue #388).
        import nano.safeio : acceptFd;
        int acceptErr;
        immutable fd = acceptFd(listener.handle, acceptErr);
        if (fd == socket_t.init) continue;
        auto conn = new Socket(fd, AddressFamily.INET);
        scope (exit) conn.close();
        char[] buf;
        char[4096] chunk;
        ptrdiff_t head = -1;
        size_t want;
        for (;;)
        {
            auto n = conn.receive(chunk[]);
            if (n <= 0) break;
            buf ~= chunk[0 .. n];
            if (head < 0)
            {
                head = buf.indexOf("\r\n\r\n");
                if (head >= 0)
                    foreach (line; buf[0 .. head].splitLines)
                        if (line.toLower.startsWith("content-length:")) want = line[15 .. $].strip.to!size_t;
            }
            if (head >= 0 && buf.length >= head + 4 + want) break;
        }
        if (head < 0) continue; // no request on it: not our client
        auto headText = buf[0 .. head].idup;
        auto first = headText[0 .. headText.indexOf("\r\n") < 0 ? $ : headText.indexOf("\r\n")];
        auto sp1 = first.indexOf(' '), sp2 = first.indexOf(' ', sp1 + 1);
        if (sp1 < 0 || sp2 < 0) continue;
        auto path = first[sp1 + 1 .. sp2];
        if (!path.startsWith(prefix))
        {
            conn.send("HTTP/1.1 404 Status\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            continue;
        }
        next++;
        seen ~= Captured(first[0 .. sp1], path[prefix.length .. $], headText, buf[head + 4 .. $].idup);
        if (r.dripMs > 0)
        {
            import core.thread : Thread;
            import core.time : msecs;
            import std.string : indexOf;
            conn.send(format("HTTP/1.1 %s Status\r\n%sConnection: close\r\n\r\n", r.status, r.headers));
            for (string rest = r.body_; rest.length;)
            {
                auto end = rest.indexOf("\n\n");
                auto n = end < 0 ? rest.length : end + 2;
                sleepFor(r.dripMs.msecs);
                conn.send(rest[0 .. n]);
                rest = rest[n .. $];
            }
            continue;
        }
        bool cut = r.headers.toLower.canFind("x-truncate");
        auto len = cut ? r.body_.length + 64 : r.body_.length;
        auto response = format("HTTP/1.1 %s Status\r\n%sContent-Length: %s\r\nConnection: close\r\n\r\n%s",
            r.status, r.headers, len, r.body_);
        conn.send(response);
    }
    return seen;
}

/// Wait for a connection on `listener`: false once the test calls `finish`
/// or after 10 s with no client (the client stopped asking).
private bool awaitClient(imported!"std.socket".Socket listener, Chan!bool stop)
{
    import core.time : msecs, seconds;
    import std.socket : Socket, SocketSet;
    import nano.clock : monoNow, since;
    const start = monoNow;
    auto set = new SocketSet;
    while (since(start) < 10.seconds)
    {
        bool v;
        if (stop.tryTake(v)) return false;
        set.reset();
        set.add(listener);
        if (Socket.select(set, null, null, 20.msecs) > 0) return true;
    }
    return false;
}

unittest
{
    import nano.http : perform, Request;
    auto srv = serve([immutable Reply(200, "x-a: 1\r\n", "hello")]);
    Request req;
    req.url = srv.url ~ "/p";
    req.method = "POST";
    req.body_ = "body";
    string got;
    assert(perform(req, got) == 200);
    auto seen = srv.finish();
    assert(got == "hello" && seen.length == 1 && seen[0].method == "POST" && seen[0].path == "/p" && seen[0].body_ == "body");
}

// A connection from another test's client (stray: no request, or a path
// without this server's prefix) doesn't use up a reply (issue #388).
unittest
{
    import std.socket : TcpSocket, InternetAddress;
    import std.string : indexOf, lastIndexOf;
    import std.conv : to;
    import nano.http : perform, Request;
    auto srv = serve([immutable Reply(200, "", "mine")]);
    immutable hostPort = srv.url["http://".length .. $];
    immutable slash = hostPort.indexOf('/');
    immutable port = hostPort[hostPort.lastIndexOf(':', slash) + 1 .. slash].to!ushort;
    auto silent = new TcpSocket(new InternetAddress("127.0.0.1", port));
    silent.close();
    Request other;
    other.url = "http://127.0.0.1:" ~ port.to!string ~ "/elsewhere";
    string got;
    assert(perform(other, got) == 404);
    Request req;
    req.url = srv.url ~ "/p";
    assert(perform(req, got) == 200 && got == "mine");
    auto seen = srv.finish();
    assert(seen.length == 1 && seen[0].path == "/p");
}
