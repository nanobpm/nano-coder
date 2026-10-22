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
import nano.retry : ErrorInfo, RetryPolicy, retryDelay, retryableError = retryable;

class ApiError : Exception
{
    int status;
    string body_;
    /// The body's normalized error (code, type, message).
    ErrorInfo info;
    this(int status, string body_, string what)
    {
        this.status = status;
        this.body_ = body_;
        info = ErrorInfo.fromBody(status, body_);
        auto shown = body_.length > 600 ? body_[0 .. 600] ~ "…" : body_;
        super(format("%s failed (HTTP %s): %s", what, status, shown));
    }
}


struct Request
{
    string method = "POST";
    string url;
    string[string] headers;
    string body_;
    Duration idleTimeout = 600.seconds;
    Duration connectTimeout = 30.seconds;
}

/// Perform `req`; each received chunk goes to `onChunk` (when set) as it
/// arrives. Returns the status and the full body.
/// Response headers `perform` reports.
struct ResponseMeta
{
    string contentType, retryAfter;
}

int perform(const ref Request req, out string body_, scope void delegate(const(char)[]) onChunk = null)
{
    ResponseMeta meta;
    return perform(req, body_, meta, onChunk);
}

int perform(const ref Request req, out string body_, out ResponseMeta meta,
    scope void delegate(const(char)[]) onChunk = null)
{
    auto http = HTTP(req.url);
    http.method = req.method == "GET" ? HTTP.Method.get : HTTP.Method.post;
    foreach (k, v; req.headers) http.addRequestHeader(k, v);
    http.connectTimeout = req.connectTimeout;
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
    // Headers of the final response only (a redirect or 100 resets them).
    http.onReceiveStatusLine = (HTTP.StatusLine) { meta = ResponseMeta.init; };
    http.onReceiveHeader = (in char[] key, in char[] value) {
        auto k = key.idup.toLower;
        if (k == "content-type") meta.contentType = value.idup;
        else if (k == "retry-after") meta.retryAfter = value.idup;
    };
    http.onReceive = (ubyte[] data) {
        buf ~= cast(char[]) data;
        if (onChunk !is null) onChunk(cast(const(char)[]) data);
        return data.length;
    };
    http.perform();
    body_ = cast(string) buf.idup;
    return http.statusLine.code;
}

/// POST JSON, retrying transient failures per the provider's retry policy
/// (status classification, `Retry-After` and "try again in" hints).
///
/// With `onEvent`, the request asks for server-sent events and each `data:`
/// payload goes to `onEvent`; a stream that fails before any event arrived
/// is retried. A server that answers a stream request with plain JSON gets
/// that body returned (parse it whole); an SSE reply returns null.
string postJson(string url, string[string] headers, JSONValue body_, string what, RetryPolicy policy,
        const(ushort)[] statuses, long timeoutSecs, scope void delegate(string data) onEvent = null)
{
    import std.random : uniform01;
    import std.datetime.systime : Clock;
    import std.stdio : stderr;
    Request req;
    req.url = url;
    req.headers = headers.dup;
    req.headers["Content-Type"] = "application/json";
    if (onEvent !is null) req.headers["Accept"] = "text/event-stream";
    req.body_ = body_.toString;
    req.idleTimeout = timeoutSecs.seconds;
    for (long attempt = 0;; attempt++)
    {
        bool received;
        SseParser sse;
        string text;
        int status;
        ResponseMeta meta;
        Exception failure;
        ErrorInfo info;
        bool haveInfo;
        try
        {
            status = perform(req, text, meta, onEvent is null ? null : (const(char)[] chunk) {
                // Only an event-stream 2xx is parsed as events.
                if (meta.contentType.indexOf("event-stream") < 0) return;
                received = true;
                sse.feed(chunk, onEvent);
            });
        }
        catch (CurlException e)
        {
            if (cancelRequested()) throw new Cancelled;
            // Connection resets, timeouts, DNS: transient, unless the stream
            // already delivered events (a restart would duplicate them).
            if (received || attempt >= policy.maxRetries) throw new Exception(format("%s: %s", what, e.msg));
            failure = e;
        }
        if (failure is null)
        {
            bool ok = status >= 200 && status < 300;
            bool isSse = meta.contentType.indexOf("event-stream") >= 0;
            if (ok && onEvent !is null && isSse)
            {
                sse.finish(onEvent);
                return null;
            }
            if (ok)
            {
                // An error inside a 2xx JSON body.
                JSONValue j;
                try j = parseJSON(text);
                catch (Exception) throw new Exception(format("%s: invalid JSON response: %s", what,
                    text.length > 500 ? text[0 .. 500] : text));
                auto e = j.type == JSONType.object ? "error" in j.object : null;
                if (e is null || e.type == JSONType.null_) return text;
                auto err = new ApiError(status, text, what);
                if (onEvent !is null || attempt >= policy.maxRetries || !retryableError(err.info, statuses)) throw err;
                failure = err;
                info = err.info;
                haveInfo = true;
            }
            else
            {
                auto err = new ApiError(status, text, what);
                if (attempt >= policy.maxRetries || !retryableError(err.info, statuses)) throw err;
                failure = err;
                info = err.info;
                haveInfo = true;
            }
        }
        auto delay = retryDelay(policy, attempt, haveInfo ? &info : null, meta.retryAfter,
            Clock.currTime.toUnixTime, uniform01());
        stderr.writefln("[%s] attempt %s failed: %s; retrying in %.1fs", what, attempt + 1, failure.msg,
            delay.total!"msecs" / 1000.0);
        pause(delay);
    }
}

/// `postJson` with a provider's retry policy, retryable statuses and timeout.
string postProvider(string url, string[string] headers, JSONValue body_, string what,
        const ref imported!"nano.config".ProviderConfig c, scope void delegate(string data) onEvent = null)
{
    // Drop the OpenAI-style `[DONE]` terminator for every provider, as the Rust
    // shared SSE layer does: GitHub Copilot's Anthropic Messages endpoint sends
    // it too, and the Messages/Responses parsers would fail to parse it as JSON.
    void delegate(string) filtered = null;
    if (onEvent !is null)
        filtered = (string data) { if (!isStreamEnd(data)) onEvent(data); };
    return postJson(url, headers, body_, what, c.retryPolicy, c.statuses, c.timeoutSecs, filtered);
}

/// The `data: [DONE]` end-of-stream marker (not a JSON event).
bool isStreamEnd(string data) pure @safe
{
    import std.string : strip;
    return data.strip == "[DONE]";
}

unittest
{
    assert(isStreamEnd("[DONE]") && isStreamEnd(" [DONE]\r"));
    assert(!isStreamEnd(`{"type":"message_stop"}`) && !isStreamEnd("[DONE] x"));
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
