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
TestServer serve(immutable(Reply)[] replies)
{
    auto port = Chan!ushort.make;
    auto stop = Chan!bool.make;
    auto h = spawn(&run, replies, port, stop);
    ushort p;
    port.take(p);
    import std.format : format;
    return TestServer(format("http://127.0.0.1:%s", p), h, stop);
}

private immutable(Captured)[] run(immutable(Reply)[] replies, Chan!ushort port, Chan!bool stop)
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
    for (size_t i = 0; i < replies.length;)
    {
        if (!awaitClient(listener, stop)) break;
        auto r = replies[i];
        auto conn = listener.accept();
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
        // A client that hung up before sending a whole request (e.g. a
        // connect that timed out under load) doesn't consume a reply: wait
        // for the next one instead of shutting the server down.
        if (head < 0) continue;
        i++;
        auto headText = buf[0 .. head].idup;
        auto first = headText[0 .. headText.indexOf("\r\n") < 0 ? $ : headText.indexOf("\r\n")];
        auto sp1 = first.indexOf(' '), sp2 = first.indexOf(' ', sp1 + 1);
        seen ~= Captured(first[0 .. sp1], first[sp1 + 1 .. sp2], headText, buf[head + 4 .. $].idup);
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
