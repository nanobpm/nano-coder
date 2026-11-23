/// HTTP over libcurl (std.net.curl), with server-sent-event streaming and
/// retries with exponential backoff for transient failures.
module nano.http;

@safe:
import nano.safeio : jsonText, jsonPretty, asChars, lossyText;
import nano.clock : monoNow, sleepFor, wallNow;

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
    this(string msg) pure { super(msg); }
}

class ApiError : Exception
{
    int status;
    string body_;
    /// The body's normalized error (code, type, message).
    ErrorInfo info;
    this(int status, string body_, string what) pure
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
    Duration idleTimeout = 120.seconds;
    Duration connectTimeout = 30.seconds;
    /// Abort the transfer (an exception) once the body would exceed this many bytes; 0: no limit.
    size_t maxBytes;
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
    // Content-Type goes with the body below: std.net.curl's `postData` would
    // add a second one, which some gateways never answer.
    string contentType = "application/json";
    foreach (k, v; req.headers)
    {
        import std.uni : sicmp;
        if (sicmp(k, "Content-Type") == 0) contentType = v;
        else http.addRequestHeader(k, v);
    }
    http.connectTimeout = req.connectTimeout;
    // libcurl's low-speed limit acts as an idle timeout: fail after `idleTimeout`
    // seconds below 1 byte/s, without capping a slow but steady stream.
    import etc.c.curl : CurlOption;
    http.handle.set(CurlOption.low_speed_limit, 1);
    http.handle.set(CurlOption.low_speed_time, req.idleTimeout.total!"seconds");
    if (req.method != "GET")
    {
        const(void)[] payload = req.body_;
        http.setPostData(payload, contentType);
    }
    // A cancelled turn aborts the transfer (libcurl polls this about once a second
    // and on every chunk).
    http.onProgress = (size_t a, size_t b, size_t c, size_t d) => cancelRequested() ? 1 : 0;
    ubyte[] buf;
    size_t received; // bytes of the final response, buffered or streamed
    ushort statusCode;
    // Headers of the final response only (a redirect or 100 resets them).
    http.onReceiveStatusLine = (HTTP.StatusLine sl) {
        meta = ResponseMeta.init;
        statusCode = sl.code;
        buf = null;
        received = 0;
    };
    http.onReceiveHeader = (in char[] key, in char[] value) {
        auto k = key.idup.toLower;
        if (k == "content-type") meta.contentType = value.idup;
        else if (k == "retry-after") meta.retryAfter = value.idup;
    };
    http.onReceive = (ubyte[] data) {
        // A streamed 2xx SSE reply is consumed chunk-by-chunk by `onChunk`;
        // buffering it in `buf` would retain the whole raw stream in GC memory
        // only to discard it. Non-SSE replies and error bodies are still buffered.
        immutable streamOnly = onChunk !is null && statusCode >= 200 && statusCode < 300
            && meta.contentType.indexOf("event-stream") >= 0;
        // The cap bounds the transfer, not just what is retained: returning
        // less than offered makes libcurl abort before more is buffered or streamed.
        if (req.maxBytes && received + data.length > req.maxBytes) return 0;
        received += data.length;
        if (!streamOnly) buf ~= data;
        if (onChunk !is null) onChunk(asChars(data)); // unchecked: a chunk may end inside a character
        return data.length;
    };
    http.perform();
    body_ = buf.length ? lossyText(buf) : null;
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
        const(ushort)[] statuses, long timeoutSecs, scope void delegate(string data) @safe onEvent = null,
        scope bool delegate() @safe shown = null, scope void delegate() @safe reset = null)
{
    import std.random : uniform01;
    import std.datetime.systime : Clock;
    import std.stdio : stderr;
    Request req;
    req.url = url;
    req.headers = headers.dup;
    req.headers["Content-Type"] = "application/json";
    if (onEvent !is null) req.headers["Accept"] = "text/event-stream";
    req.body_ = body_.jsonText;
    import nano.config : defaultTimeoutSecs;
    req.idleTimeout = (timeoutSecs > 0 ? timeoutSecs : defaultTimeoutSecs()).seconds;
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
        offline.bound(req);
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
            if (received)
            {
                // A stream cut after visible output can't be restarted here
                // (it was shown); the agent asks again. When only bookkeeping
                // events arrived (role, usage, empty deltas), the caller's
                // accumulator is reset and the request retried like any other.
                auto lost = new StreamInterrupted(format("%s: connection lost mid-reply (%s)", what, curlReason(e.msg)));
                if (shown is null || reset is null || shown() || attempt >= policy.maxRetries) throw lost;
                reset();
                failure = lost;
            }
            else
            {
                // Connection refused/reset, DNS, timeouts: the network is down or
                // flaky. Wait for it (backing off) without using up the retry budget.
                offline.wait(e);
                attempt--;
                continue;
            }
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
            wallNow.toUnixTime, uniform01());
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

// rust: providers/mod.rs::clean_reason_strips_curl_handle_noise
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
    Request r = {method: req.method, url: req.url, body_: req.body_, idleTimeout: req.idleTimeout,
        connectTimeout: req.connectTimeout};
    foreach (k, v; req.headers) r.headers[k] = v;
    for (;;)
    {
        offline.bound(r);
        try
        {
            auto status = perform(r, body_);
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

    Duration idle, connect; // the request's own timeouts, before `bound` capped them

    this(string what, RetryPolicy policy) pure { this.what = what; this.policy = policy; }

    /// The budget left while an outage is being waited out (`Duration.max`
    /// when none is, or the budget is unbounded).
    Duration remaining() const
    {
        if (failures == 0 || policy.offlineBudget == Duration.max) return Duration.max;
        auto spent = monoNow - since;
        return spent >= policy.offlineBudget ? Duration.zero : policy.offlineBudget - spent;
    }

    /// Cap a resend's timeouts at the remaining budget, so a resend that
    /// connects and then stalls can't outlive it. Only the idle and connect
    /// timeouts: a reply that is flowing is never cut off.
    void bound(ref Request req)
    {
        import std.algorithm : min, max;
        if (idle == Duration.zero) { idle = req.idleTimeout; connect = req.connectTimeout; }
        auto left = remaining();
        req.idleTimeout = left == Duration.max ? idle : min(idle, max(left, 1.seconds));
        req.connectTimeout = left == Duration.max ? connect : min(connect, max(left, 1.msecs));
    }

    /// One failed attempt: throws once the offline budget is spent, else
    /// sleeps the next backoff, clamped to the budget (Ctrl-C throws
    /// Cancelled). A redirect loop isn't an outage: it fails at once.
    void wait(CurlException e)
    {
        import std.algorithm : min;
        import std.uni : toLower;
        auto now = monoNow;
        reason = curlReason(e.msg);
        if (reason.toLower.indexOf("redirect") >= 0) throw new Exception(format("%s: %s", what, reason));
        if (failures == 0)
        {
            since = now;
            live = liveStderr();
            if (!live) stdErr.writefln("[%s] network unavailable (%s); waiting to reconnect (Ctrl-C to stop)", what, reason);
        }
        auto spent = () => failures > 0 && remaining() == Duration.zero;
        auto outOfBudget = () => new Exception(format("%s: network unavailable (%s)", what, reason));
        if (spent()) throw outOfBudget();
        auto backoff = policy.backoff(failures++);
        auto pauseFor = min(backoff, remaining());
        auto until = now + pauseFor;
        while (monoNow < until)
        {
            if (cancelRequested()) throw new Cancelled;
            if (live && monoNow - shown >= 1.seconds) draw();
            sleepFor(min(50.msecs, until - monoNow));
        }
        // No further request once the budget is gone.
        if (spent()) throw outOfBudget();
    }

    private void draw()
    {
        shown = monoNow;
        import core.sys.posix.unistd : isatty;
        import nano.frame : fit;
        import nano.lineedit : terminalWidth;
        // Fitted to the row: a wrapped line leaves stale rows `\r` can't reach.
        auto cols = noticeWidth(terminalWidth(isatty(2) ? 2 : 1));
        stdErr.writef("\r\x1b[K%s", fit(format("[%s] network unavailable (%s); waiting to reconnect, %s (Ctrl-C to stop)",
            what, reason, formatElapsed(shown - since)), cols));
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
        auto took = formatElapsed(monoNow - since);
        if (live) stdErr.writef("\r\x1b[K");
        stdErr.writefln("[%s] network back after %s", what, took);
        failures = 0;
    }
}

/// The live notice's width: the measured columns, at least one (never a
/// wider floor, which would wrap on a narrow terminal).
size_t noticeWidth(size_t cols) pure nothrow { return cols ? cols : 1; }

// rust: providers/mod.rs::live_notice_width_preserves_narrow_terminals
unittest
{
    import nano.frame : fit;
    import nano.frame : visibleWidth;
    foreach (c; [10, 19, 1, 80, 200]) assert(noticeWidth(c) == c);
    assert(noticeWidth(0) == 1);
    auto notice = "[agent] network unavailable (connection refused); waiting to reconnect, 3s (Ctrl-C to stop)";
    foreach (c; [1, 5, 10, 19, 20, 80]) assert(visibleWidth(fit(notice, noticeWidth(c))) <= c);
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
        const ref imported!"nano.config".ProviderConfig c, scope void delegate(string data) @safe onEvent = null,
        scope bool delegate() @safe shown = null, scope void delegate() @safe reset = null)
{
    // Drop the OpenAI-style `[DONE]` terminator for every provider, as the Rust
    // shared SSE layer does: GitHub Copilot's Anthropic Messages endpoint sends
    // it too, and the Messages/Responses parsers would fail to parse it as JSON.
    void delegate(string) @safe filtered = null;
    if (onEvent !is null)
        filtered = (string data) { if (!isStreamEnd(data)) onEvent(data); };
    return postJson(url, headers, body_, what, c.retryPolicy, c.statuses, c.timeoutSecs, filtered, shown, reset);
}

/// Stream a provider request into `st` (an accumulator with a `sink` and an
/// `event(data)` method). A drop before any visible output (non-empty text or
/// thinking reached the sink) restarts from a fresh copy of `st` as given.
/// Returns the whole body when the reply wasn't an event stream, else null.
string postStream(S)(ref S st, string url, string[string] headers, JSONValue body_, string what,
        const ref imported!"nano.config".ProviderConfig c)
{
    auto sink = st.sink;
    bool shown;
    S local = st;
    local.sink = (bool thinking, string text) {
        if (text.length) shown = true;
        if (sink !is null) sink(thinking, text);
    };
    auto initial = local;
    auto whole = postProvider(url, headers, body_, what, c, (string data) { local.event(data); }, () => shown,
        () { local = initial; });
    st = local;
    return whole;
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
    auto until = monoNow + d;
    while (monoNow < until)
    {
        if (cancelRequested()) throw new Cancelled;
        sleepFor(50.msecs);
    }
}

/// Incremental server-sent-events parser: emits each event's joined `data:` lines.
struct SseParser
{
    import std.array : Appender;

    private Appender!(char[]) pending;
    private Appender!(char[]) data;
    private bool hasData;

    void feed(const(char)[] chunk, scope void delegate(string) @safe emit)
    {
        if (chunk.length) pending.put(chunk);
        auto buf = pending.data;
        size_t pos;
        for (;;)
        {
            auto rel = buf[pos .. $].indexOf('\n');
            if (rel < 0) break;
            auto nl = pos + rel;
            auto line = buf[pos .. nl];
            pos = nl + 1;
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
                if (hasData) data.put('\n');
                data.put(v);
                hasData = true;
            }
        }
        if (pos == buf.length) pending.clear();
        else if (pos > 0)
        {
            auto rem = buf[pos .. $].dup;
            pending.clear();
            pending.put(rem);
        }
    }

    void finish(scope void delegate(string) @safe emit)
    {
        if (pending.data.length) feed("\n", emit);
        dispatch(emit);
    }

    private void dispatch(scope void delegate(string) @safe emit)
    {
        if (!hasData) return;
        // Chunks arrive unchecked (a network chunk may end inside a
        // character), so validate once here: a completed event holds every
        // byte of any multi-byte character, and invalid bytes become U+FFFD
        // instead of reaching the consumer as broken UTF-8.
        import std.string : representation;
        auto d = lossyText(data.data.representation);
        data.clear();
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

// Completed events are sanitized before delivery: invalid bytes in a stream
// become U+FFFD instead of reaching the consumer as broken UTF-8, and a
// multi-byte character split across network chunks survives whole.
unittest
{
    string[] got;
    SseParser p;
    void emit(string s) { got ~= s; }
    // "hé" split inside the é (0xC3 0xA9) across two chunks, plus a bad byte.
    p.feed("data: h\xc3", &emit);
    p.feed("\xa9llo \xff!\n\n", &emit);
    p.finish(&emit);
    assert(got == ["héllo \uFFFD!"], got[0]);
    // An event that ends without a trailing blank line is still sanitized.
    got = null;
    SseParser q;
    q.feed("data: a\xffb", &emit);
    q.finish(&emit);
    assert(got == ["a\uFFFDb"], got[0]);
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
    auto start = monoNow;
    string msg;
    try postJson("http://127.0.0.1:9/x", null, JSONValue(1), "probe", p, [], 5);
    catch (StreamInterrupted) assert(0);
    catch (Exception e) msg = e.msg;
    assert(msg.length && msg[0 .. 6] == "probe:", msg);
    // Retried well past maxRetries = 0 before giving up.
    assert(monoNow - start >= 300.msecs);
}

// rust: providers/mod.rs::transport_waits_out_an_offline_endpoint_past_max_retries_then_fails
// rust: providers/mod.rs::offline_budget_bounds_the_backoff_sleep
unittest
{
    import core.time : msecs, MonoTime;
    import std.algorithm : canFind;
    RetryPolicy p;
    p.maxRetries = 0;
    p.initialBackoff = 1000.msecs;
    p.maxBackoff = 1000.msecs;
    p.offlineBudget = 100.msecs;
    auto start = monoNow;
    import std.exception : collectExceptionMsg;
    auto msg = collectExceptionMsg(postJson("http://127.0.0.1:9/x", null, JSONValue(1), "probe", p, [], 5));
    auto took = monoNow - start;
    assert(msg.canFind("network unavailable"), msg);
    assert(took >= 80.msecs && took < 600.msecs, "the backoff is clamped to the budget");
}

private void holdStalledListener(ushort port, imported!"nano.safeio".Chan!bool done)
{
    import std.socket : TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;
    sleepFor(30.msecs);
    auto l = new TcpSocket;
    scope (exit) l.close();
    l.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    l.bind(new InternetAddress("127.0.0.1", port));
    l.listen(4); // never accepted: connections complete and then hear nothing
    bool v;
    done.take(v); // until the test is finished with it
}

// rust: providers/mod.rs::offline_budget_bounds_an_in_flight_resend
unittest
{
    import core.time : MonoTime;
    import std.algorithm : canFind;
    import std.socket : TcpSocket, InternetAddress;
    import nano.safeio : spawn;
    ushort port;
    {
        auto probe = new TcpSocket;
        probe.bind(new InternetAddress("127.0.0.1", InternetAddress.PORT_ANY));
        port = (cast(InternetAddress) probe.localAddress).port;
        probe.close(); // the first attempt is refused: the outage starts
    }
    import nano.safeio : Chan;
    auto done = Chan!bool.make;
    auto h = spawn(&holdStalledListener, port, done);
    RetryPolicy p;
    p.maxRetries = 0;
    p.initialBackoff = 20.msecs;
    p.maxBackoff = 20.msecs;
    p.offlineBudget = 150.msecs;
    auto start = monoNow;
    import std.exception : collectExceptionMsg;
    auto msg = collectExceptionMsg(postJson(format("http://127.0.0.1:%s/x", port), null, JSONValue(1), "probe", p, [], 30));
    auto took = monoNow - start;
    done.close();
    h.join();
    assert(msg.canFind("network unavailable"), msg);
    assert(took >= 120.msecs && took < 5.seconds, "a stalled resend outlived the budget");
}

// rust: providers/mod.rs::transport_does_not_wait_out_a_redirect_loop
unittest
{
    import core.time : MonoTime;
    import std.algorithm : canFind;
    import std.range : repeat;
    import std.array : array;
    import nano.testserver : serve, Reply;
    immutable loop = Reply(301, "Location: /\r\n", "");
    auto srv = serve(loop.repeat(60).array.idup);
    RetryPolicy p;
    p.maxRetries = 0;
    p.offlineBudget = 10.seconds;
    auto start = monoNow;
    import std.exception : collectExceptionMsg;
    auto msg = collectExceptionMsg(postJson(srv.url ~ "/x", null, JSONValue(1), "probe", p, [], 5));
    assert(monoNow - start < 3.seconds, "a redirect loop was waited out as an outage: " ~ msg);
    assert(msg.length && !msg.canFind("network unavailable"), msg);
    srv.finish();
}

// A POST carries exactly one Content-Type. std.net.curl's `postData` adds
// `application/octet-stream` on top of ours, and some gateways (Alibaba
// Cloud Model Studio) never answer a request with two.
unittest
{
    import std.algorithm : canFind, count;
    import std.string : toLower;
    import nano.testserver : serve, Reply;
    auto srv = serve([Reply(200, "Content-Type: application/json\r\n", `{"ok":true}`)]);
    RetryPolicy p;
    p.maxRetries = 0;
    postJson(srv.url ~ "/x", null, JSONValue(1), "probe", p, [], 5);
    auto seen = srv.finish();
    assert(seen.length == 1);
    auto h = seen[0].headers.toLower;
    assert(h.count("content-type:") == 1, seen[0].headers);
    assert(h.canFind("content-type: application/json"), seen[0].headers);
}

// Streamed 2xx SSE replies are delivered to `onChunk` without buffering the
// whole raw stream in `body_`; non-SSE 2xx replies and error responses still
// buffer `body_` (issue #308).
unittest
{
    import nano.testserver : serve, Reply;
    auto srv = serve([
        Reply(200, "Content-Type: text/event-stream\r\n", "data: one\n\ndata: two\n\n"),
        Reply(200, "Content-Type: application/json\r\n", `{"ok":true}`),
        Reply(500, "Content-Type: text/event-stream\r\n", "data: err\n\n"),
    ]);

    // 1. 2xx text/event-stream with onChunk: chunks arrive, body_ stays empty.
    {
        Request req;
        req.url = srv.url ~ "/sse";
        req.body_ = "{}";
        string body_;
        ResponseMeta meta;
        string[] events;
        SseParser sse;
        auto status = perform(req, body_, meta, (const(char)[] chunk) {
            sse.feed(chunk, (string ev) { events ~= ev; });
        });
        sse.finish((string ev) { events ~= ev; });
        assert(status == 200);
        assert(events == ["one", "two"]);
        assert(body_.length == 0, "expected SSE stream not to buffer body_: " ~ body_);
    }

    // 2. 2xx application/json with onEvent (postJson): still returns full JSON body.
    {
        RetryPolicy p;
        p.maxRetries = 0;
        string[] events;
        auto res = postJson(srv.url ~ "/json", null, JSONValue(1), "probe", p, [], 5,
            (string ev) { events ~= ev; });
        assert(res == `{"ok":true}`, res);
        assert(events.length == 0);
    }

    // 3. Non-2xx with event-stream content-type: still buffers error body for ApiError.
    {
        RetryPolicy p;
        p.maxRetries = 0;
        ApiError caught;
        try postJson(srv.url ~ "/err", null, JSONValue(1), "probe", p, [], 5,
            (string) {});
        catch (ApiError e) caught = e;
        assert(caught !is null);
        assert(caught.status == 500);
        assert(caught.body_ == "data: err\n\n", caught.body_);
    }

    srv.finish();
}

// The `maxBytes` cap bounds an unbuffered SSE stream too: the transfer aborts
// instead of forwarding chunks past the limit.
unittest
{
    import nano.testserver : serve, Reply;
    import std.net.curl : CurlException;
    auto srv = serve([Reply(200, "Content-Type: text/event-stream\r\n", "data: one\n\ndata: two\n\n")]);
    Request req;
    req.url = srv.url ~ "/sse";
    req.body_ = "{}";
    req.maxBytes = 5;
    string body_;
    ResponseMeta meta;
    size_t forwarded;
    bool threw;
    try perform(req, body_, meta, (const(char)[] chunk) { forwarded += chunk.length; });
    catch (CurlException) threw = true;
    assert(threw, "expected the capped stream to abort");
    assert(forwarded <= 5);
    srv.finish();
}
