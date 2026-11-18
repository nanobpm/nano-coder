/// A scripted local HTTP server for provider tests (Rust's `test_server`):
/// each connection gets the next reply; requests are captured.
module nano.testserver;
@safe:

version (unittest):

import nano.safeio : Chan, Join, spawn;

/// A reply: status, extra header lines ("name: value\r\n"…) and body. An
/// `x-truncate` header cuts the body short (a dropped stream).
struct Reply
{
    int status;
    string headers;
    string body_;
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

    /// Wait for the scripted replies to be served (or the server to give up
    /// waiting for a connection) and return the requests.
    immutable(Captured)[] finish() { return handle.join(); }
}

/// Serve `replies` in order, one per connection, on 127.0.0.1.
TestServer serve(immutable(Reply)[] replies)
{
    auto port = Chan!ushort.make;
    auto h = spawn(&run, replies, port);
    ushort p;
    port.take(p);
    import std.format : format;
    return TestServer(format("http://127.0.0.1:%s", p), h);
}

private immutable(Captured)[] run(immutable(Reply)[] replies, Chan!ushort port)
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
    foreach (ref r; replies)
    {
        auto set = new SocketSet;
        set.add(listener);
        if (Socket.select(set, null, null, 10.seconds) <= 0) break; // the client stopped asking
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
                head = (cast(const(char)[]) buf).indexOf("\r\n\r\n");
                if (head >= 0)
                    foreach (line; (cast(const(char)[]) buf[0 .. head]).splitLines)
                        if (line.toLower.startsWith("content-length:")) want = line[15 .. $].strip.to!size_t;
            }
            if (head >= 0 && buf.length >= head + 4 + want) break;
        }
        if (head < 0) break;
        auto headText = buf[0 .. head].idup;
        auto first = headText[0 .. headText.indexOf("\r\n") < 0 ? $ : headText.indexOf("\r\n")];
        auto sp1 = first.indexOf(' '), sp2 = first.indexOf(' ', sp1 + 1);
        seen ~= Captured(first[0 .. sp1], first[sp1 + 1 .. sp2], headText, buf[head + 4 .. $].idup);
        bool cut = r.headers.toLower.canFind("x-truncate");
        auto len = cut ? r.body_.length + 64 : r.body_.length;
        auto response = format("HTTP/1.1 %s Status\r\n%sContent-Length: %s\r\nConnection: close\r\n\r\n%s",
            r.status, r.headers, len, r.body_);
        conn.send(response);
    }
    return seen;
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
