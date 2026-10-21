/// HTTP over libcurl (std.net.curl), with server-sent-event streaming and
/// retries with exponential backoff for transient failures.
module nano.http;

import std.net.curl : HTTP, CurlException;
import nano.control : cancelRequested, Cancelled;
import std.json;
import std.format : format;
import std.string : indexOf, strip, startsWith, toLower;
import core.time : seconds, msecs, Duration;
import core.thread : Thread;

class ApiError : Exception
{
    int status;
    string body_;
    this(int status, string body_, string what)
    {
        this.status = status;
        this.body_ = body_;
        auto shown = body_.length > 600 ? body_[0 .. 600] ~ "…" : body_;
        super(format("%s failed (HTTP %s): %s", what, status, shown));
    }
}

bool retryable(int status)
{
    return status == 408 || status == 409 || status == 429 || (status >= 500 && status <= 599);
}

struct Request
{
    string method = "POST";
    string url;
    string[string] headers;
    string body_;
    Duration idleTimeout = 600.seconds;
}

/// Perform `req`; each received chunk goes to `onChunk` (when set) as it
/// arrives. Returns the status and the full body.
int perform(const ref Request req, out string body_, scope void delegate(const(char)[]) onChunk = null)
{
    auto http = HTTP(req.url);
    http.method = req.method == "GET" ? HTTP.Method.get : HTTP.Method.post;
    foreach (k, v; req.headers) http.addRequestHeader(k, v);
    http.connectTimeout = 30.seconds;
    // libcurl's low-speed limit acts as an idle timeout: fail after `idleTimeout`
    // seconds below 1 byte/s, without capping a slow but steady stream.
    import etc.c.curl : CurlOption;
    http.handle.set(CurlOption.low_speed_limit, 1);
    http.handle.set(CurlOption.low_speed_time, cast(long) req.idleTimeout.total!"seconds");
    if (req.method != "GET")
    {
        auto payload = cast(const(void)[]) req.body_;
        http.postData = payload;
    }
    // A cancelled turn aborts the transfer (libcurl polls this about once a second
    // and on every chunk).
    http.onProgress = (size_t a, size_t b, size_t c, size_t d) => cancelRequested() ? 1 : 0;
    char[] buf;
    http.onReceive = (ubyte[] data) {
        buf ~= cast(char[]) data;
        if (onChunk !is null) onChunk(cast(const(char)[]) data);
        return data.length;
    };
    http.perform();
    body_ = cast(string) buf.idup;
    return http.statusLine.code;
}

/// POST JSON, retrying transient failures. `stream` gets SSE `data:` payloads
/// when set; streamed requests retry only if nothing was received yet.
string postJson(string url, string[string] headers, JSONValue body_, string what, long maxRetries,
        long timeoutSecs, scope void delegate(string data) onEvent = null)
{
    Request req;
    req.url = url;
    req.headers = headers.dup;
    req.headers["Content-Type"] = "application/json";
    req.body_ = body_.toString;
    req.idleTimeout = timeoutSecs.seconds;
    Duration backoff = 1000.msecs;
    for (long attempt = 0;; attempt++)
    {
        bool received;
        SseParser sse;
        string text;
        int status;
        try
        {
            status = perform(req, text, onEvent is null ? null : (const(char)[] chunk) {
                received = true;
                sse.feed(chunk, onEvent);
            });
        }
        catch (CurlException e)
        {
            if (cancelRequested()) throw new Cancelled;
            if (attempt < maxRetries && !received)
            {
                pause(backoff);
                backoff = backoff * 2;
                continue;
            }
            throw new Exception(format("%s: %s", what, e.msg));
        }
        if (status >= 200 && status < 300)
        {
            if (onEvent !is null) sse.finish(onEvent);
            return text;
        }
        if (attempt < maxRetries && retryable(status))
        {
            pause(backoff);
            backoff = backoff * 2;
            continue;
        }
        throw new ApiError(status, text, what);
    }
}

/// Sleep for a retry backoff, cut short (with Cancelled) by a cancel.
private void pause(Duration d)
{
    import core.time : MonoTime;
    auto until = MonoTime.currTime + d;
    while (MonoTime.currTime < until)
    {
        if (cancelRequested()) throw new Cancelled;
        Thread.sleep(50.msecs);
    }
}

/// Incremental server-sent-events parser: emits each event's joined `data:` lines.
struct SseParser
{
    private string pending;
    private string data;
    private bool hasData;

    void feed(const(char)[] chunk, scope void delegate(string) emit)
    {
        pending ~= chunk;
        for (;;)
        {
            auto nl = pending.indexOf('\n');
            if (nl < 0) break;
            auto line = pending[0 .. nl];
            pending = pending[nl + 1 .. $];
            if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
            if (line.length == 0)
            {
                dispatch(emit);
                continue;
            }
            if (line.startsWith("data:"))
            {
                auto v = line[5 .. $];
                if (v.length && v[0] == ' ') v = v[1 .. $];
                data = hasData ? data ~ "\n" ~ v : v;
                hasData = true;
            }
        }
    }

    void finish(scope void delegate(string) emit)
    {
        if (pending.length) feed("\n", emit);
        dispatch(emit);
    }

    private void dispatch(scope void delegate(string) emit)
    {
        if (!hasData) return;
        auto d = data;
        data = null;
        hasData = false;
        emit(d);
    }
}

unittest
{
    string[] got;
    SseParser p;
    void emit(string s) { got ~= s; }
    p.feed("event: x\ndata: {\"a\"", &emit);
    p.feed(":1}\r\n\r\ndata: one\ndata: two\n\ndata: [DONE]", &emit);
    p.finish(&emit);
    assert(got == [`{"a":1}`, "one\ntwo", "[DONE]"]);
}
