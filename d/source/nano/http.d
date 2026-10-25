/// HTTP over libcurl (std.net.curl), with server-sent-event streaming and
/// retries with exponential backoff for transient failures.
module nano.http;

@safe:

import nano.safeio : stdErr, stdOut;

import std.net.curl : HTTP, CurlException;
import nano.control : cancelRequested, Cancelled;
import std.json;
import std.format : format;
import std.string : indexOf, strip, startsWith, toLower;
import core.time : seconds, msecs, Duration;
import core.thread : Thread;
import nano.retry : ErrorInfo, RetryPolicy, retryDelay, retryableError = retryable;

/// A streamed reply that broke after some events arrived. The request can't
/// be resumed, but the caller can discard the partial reply and ask again.
class StreamInterrupted : Exception
{
    this(string msg) { super(msg); }
}

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

int perform(const ref Request req, out string body_, scope void delegate(const(char)[]) @safe onChunk = null)
{
    ResponseMeta meta;
    return perform(req, body_, meta, onChunk);
}

/// `@trusted`: std.net.curl's API is @system throughout. This only hands it
/// values it reads or copies (the request strings, the payload) and copies
/// every buffer it hands back before keeping it.
int perform(const ref Request req, out string body_, out ResponseMeta meta,
    scope void delegate(const(char)[]) @safe onChunk = null) @trusted
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
        const(ushort)[] statuses, long timeoutSecs, scope void delegate(string data) @safe onEvent = null)
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
    auto offline = OfflineWait(what, policy);
    scope (failure) offline.abandon();
    for (long attempt = 0;; attempt++)
    {
        bool received;
        SseParser sse;
        string text;
        int status;
        ResponseMeta meta;
        Exception failure;
        // The failed request's error details (in a GC-owned ApiError), if any.
        const(ErrorInfo)* info;
        try
        {
            status = perform(req, text, meta, onEvent is null ? null : (const(char)[] chunk) {
                offline.end();
                // Only an event-stream 2xx is parsed as events.
                if (meta.contentType.indexOf("event-stream") < 0) return;
                received = true;
                sse.feed(chunk, onEvent);
            });
        }
        catch (CurlException e)
        {
            if (cancelRequested()) throw new Cancelled;
            // A stream cut after events arrived can't be restarted here (the
            // events were already shown); the agent asks again.
            if (received) throw new StreamInterrupted(format("%s: connection lost mid-reply (%s)", what, curlReason(e.msg)));
            // Connection refused/reset, DNS, timeouts: the network is down or
            // flaky. Wait for it (backing off) without using up the retry budget.
            offline.wait(e);
            attempt--;
            continue;
        }
        offline.end();
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
                auto e = j.type == JSONType.object ? "error" in j.objectNoRef : null;
                if (e is null || e.type == JSONType.null_) return text;
                auto err = new ApiError(status, text, what);
                if (onEvent !is null || attempt >= policy.maxRetries || !retryableError(err.info, statuses)) throw err;
                failure = err;
                info = &err.info;
            }
            else
            {
                auto err = new ApiError(status, text, what);
                if (attempt >= policy.maxRetries || !retryableError(err.info, statuses)) throw err;
                failure = err;
                info = &err.info;
            }
        }
        auto delay = retryDelay(policy, attempt, info, meta.retryAfter,
            Clock.currTime.toUnixTime, uniform01());
        stdErr.writefln("[%s] attempt %s failed: %s; retrying in %.1fs", what, attempt + 1, failure.msg,
            delay.total!"msecs" / 1000.0);
        pause(delay);
    }
}

/// A curl error without libcurl's " on handle XXXX" suffix.
string curlReason(string msg) pure
{
    auto i = msg.indexOf(" on handle ");
    return i < 0 ? msg : msg[0 .. i];
}

unittest
{
    assert(curlReason("Couldn't connect to server on handle B45438000") == "Couldn't connect to server");
    assert(curlReason("Timeout was reached") == "Timeout was reached");
}

/// `perform`, waiting out an unreachable network (as `postJson` does) for a
/// request on a turn's path, such as refreshing a session token.
int performOnline(const ref Request req, out string body_, string what, RetryPolicy policy = RetryPolicy.init)
{
    auto offline = OfflineWait(what, policy);
    scope (failure) offline.abandon();
    for (;;)
    {
        try
        {
            auto status = perform(req, body_);
            offline.end();
            return status;
        }
        catch (CurlException e)
        {
            if (cancelRequested()) throw new Cancelled;
            offline.wait(e);
        }
    }
}

/// Waiting out an unreachable network: backs off between attempts (without
/// using up `maxRetries`) and reports it on one line. On a terminal (or in
/// the frame UI) the line is rewritten in place with the time spent waiting;
/// otherwise it is printed when the wait starts and when it ends.
private struct OfflineWait
{
    import core.time : MonoTime;
    string what;
    RetryPolicy policy;
    long failures;
    MonoTime since, shown;
    bool live;
    string reason;

    this(string what, RetryPolicy policy) { this.what = what; this.policy = policy; }

    /// One failed attempt: throws once the offline budget is spent, else
    /// sleeps the next backoff (Ctrl-C throws Cancelled).
    void wait(CurlException e)
    {
        auto now = MonoTime.currTime;
        reason = curlReason(e.msg);
        if (failures == 0)
        {
            since = now;
            live = liveStderr();
            if (!live) stdErr.writefln("[%s] network unavailable (%s); waiting to reconnect (Ctrl-C to stop)", what, reason);
        }
        if (now - since >= policy.offlineBudget) throw new Exception(format("%s: %s", what, e.msg));
        auto until = now + policy.backoff(failures++);
        while (MonoTime.currTime < until)
        {
            if (cancelRequested()) throw new Cancelled;
            if (live && MonoTime.currTime - shown >= 1.seconds) draw();
            Thread.sleep(50.msecs);
        }
    }

    private void draw()
    {
        shown = MonoTime.currTime;
        stdErr.writef("\r\x1b[K[%s] network unavailable (%s); waiting to reconnect, %s (Ctrl-C to stop)", what, reason,
            formatElapsed(shown - since));
        stdErr.flush();
    }

    /// Cancelled or out of budget: end the live line without claiming recovery.
    void abandon()
    {
        if (failures && live) stdErr.writeln();
        failures = 0;
    }

    /// The network answered: close the line.
    void end()
    {
        if (failures == 0) return;
        auto took = formatElapsed(MonoTime.currTime - since);
        if (live) stdErr.writef("\r\x1b[K");
        stdErr.writefln("[%s] network back after %s", what, took);
        failures = 0;
    }
}

/// Whether stderr shows an in-place line: a terminal, or the frame UI's transcript.
private bool liveStderr()
{
    import core.sys.posix.unistd : isatty;
    import nano.lineedit : ttyOut;
    return isatty(2) != 0 || ttyOut != 1;
}

/// `45s`, `3m05s`, `1h02m`.
string formatElapsed(Duration d) pure
{
    auto s = d.total!"seconds";
    if (s < 60) return format("%ss", s);
    if (s < 3600) return format("%sm%02ss", s / 60, s % 60);
    return format("%sh%02sm", s / 3600, s % 3600 / 60);
}

unittest
{
    assert(formatElapsed(45.seconds) == "45s");
    assert(formatElapsed(185.seconds) == "3m05s");
    assert(formatElapsed(3720.seconds) == "1h02m");
}

/// `postJson` with a provider's retry policy, retryable statuses and timeout.
string postProvider(string url, string[string] headers, JSONValue body_, string what,
        const ref imported!"nano.config".ProviderConfig c, scope void delegate(string data) @safe onEvent = null)
{
    // Drop the OpenAI-style `[DONE]` terminator for every provider, as the Rust
    // shared SSE layer does: GitHub Copilot's Anthropic Messages endpoint sends
    // it too, and the Messages/Responses parsers would fail to parse it as JSON.
    void delegate(string) @safe filtered = null;
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

    void feed(const(char)[] chunk, scope void delegate(string) @safe emit)
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

    void finish(scope void delegate(string) @safe emit)
    {
        if (pending.length) feed("\n", emit);
        dispatch(emit);
    }

    private void dispatch(scope void delegate(string) @safe emit)
    {
        if (!hasData) return;
        auto d = data;
        data = null;
        hasData = false;
        emit(d);
    }
}

// rust: providers/mod.rs::parses_events_split_across_chunks
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

// Unreachable network: transport failures keep retrying past maxRetries until
// the offline budget runs out (unbounded in use; Ctrl-C cancels).
unittest
{
    import core.time : msecs, MonoTime;
    RetryPolicy p;
    p.maxRetries = 0;
    p.initialBackoff = 20.msecs;
    p.maxBackoff = 40.msecs;
    p.offlineBudget = 300.msecs;
    auto start = MonoTime.currTime;
    string msg;
    try postJson("http://127.0.0.1:9/x", null, JSONValue(1), "probe", p, [], 5);
    catch (StreamInterrupted) assert(0);
    catch (Exception e) msg = e.msg;
    assert(msg.length && msg[0 .. 6] == "probe:", msg);
    // Retried well past maxRetries = 0 before giving up.
    assert(MonoTime.currTime - start >= 300.msecs);
}
