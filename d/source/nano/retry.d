/// Retry classification and backoff for provider requests
/// (`providers/retry.rs`). Providers report failures inconsistently, so the
/// classifier fails open, except for errors that can never succeed on retry.
module nano.retry;

@safe:

import core.time : Duration, seconds, msecs, usecs;
import std.json;
import std.algorithm : canFind, min;

immutable ushort[] defaultRetryableStatuses = [408, 409, 425, 429, 500, 502, 503, 504, 529];

/// A provider error body, normalized (OpenAI or Anthropic shape).
struct ErrorInfo
{
    int status;
    string code, kind, message;

    /// `{"error":{"code","type","message"}}` or `{"type":"error","error":{...}}`.
    static ErrorInfo fromBody(int status, string body_) @trusted
    {
        ErrorInfo e;
        e.status = status;
        JSONValue j;
        try j = parseJSON(body_);
        catch (Exception) {}
        JSONValue* err = j.type == JSONType.object ? "error" in j.object : null;
        string field(string name)
        {
            if (err is null || err.type != JSONType.object) return null;
            auto v = name in err.object;
            if (v is null) return null;
            if (v.type == JSONType.string) return v.str;
            if (v.type == JSONType.integer || v.type == JSONType.uinteger || v.type == JSONType.float_) return v.toString;
            return null;
        }
        e.code = field("code");
        e.kind = field("type");
        if (err !is null && err.type == JSONType.string) e.message = err.str;
        else
        {
            e.message = field("message");
            if (e.message is null) e.message = body_.length > 2000 ? body_[0 .. 2000] : body_;
        }
        return e;
    }

    bool overloaded() const
    {
        return code == "server_is_overloaded" || code == "slow_down" || kind == "overloaded_error" || status == 529;
    }

    bool rateLimited() const
    {
        return code == "rate_limit_exceeded" || kind == "rate_limit_error" || status == 429;
    }
}

/// Whether an error is worth retrying.
bool retryable(const ErrorInfo e, const(ushort)[] statuses)
{
    static immutable fatalCodes = ["context_length_exceeded", "insufficient_quota", "usage_not_included",
        "usage_limit_reached", "credit_balance_exhausted", "billing_hard_limit_reached", "cyber_policy",
        "misalignment_policy_violation", "invalid_prompt", "bio_policy", "invalid_api_key", "invalid_token"];
    if (e.code.length && fatalCodes.canFind(e.code)) return false;
    if (e.status != 429 && ["authentication_error", "permission_error", "insufficient_quota", "invalid_request_error"].canFind(e.kind))
        return false;
    if (e.status < 200 || e.status >= 300) return statuses.canFind(cast(ushort) e.status);
    // An error reported inside a 2xx body: fail open.
    return true;
}

struct RetryPolicy
{
    long maxRetries = 5;
    Duration initialBackoff = 1.seconds;
    Duration maxBackoff = 30.seconds;

    /// Exponential backoff for a zero-based attempt.
    Duration backoff(long attempt) const
    {
        auto factor = 1L << (attempt < 20 ? attempt : 20);
        auto d = initialBackoff * factor;
        return d < maxBackoff ? d : maxBackoff;
    }
}

/// Delay before the next attempt. Server hints (`Retry-After`, or "try again
/// in Ns" in a rate-limit message) are honoured exactly, capped at
/// `maxBackoff`; computed backoffs lose up to 20% to `jitter` in [0, 1).
Duration retryDelay(RetryPolicy policy, long attempt, const(ErrorInfo)* err, string retryAfterHeader,
    long nowUnix, double jitter)
{
    Duration hint;
    if (retryAfterHeader.length) hint = parseRetryAfterHeader(retryAfterHeader, nowUnix);
    if (err !is null && err.rateLimited)
    {
        auto m = parseRetryAfterMessage(err.message);
        if (m > hint) hint = m;
    }
    if (hint > Duration.zero) return hint < policy.maxBackoff ? hint : policy.maxBackoff;
    if (err !is null && err.overloaded)
    {
        // Overloads get a longer backoff.
        policy.initialBackoff = 10.seconds;
        policy.maxBackoff = 60.seconds;
    }
    auto delay = policy.backoff(attempt);
    if (jitter < 0) jitter = 0;
    if (jitter > 1) jitter = 1;
    return delay - usecsOf((delay / 5).total!"usecs" * jitter);
}

private Duration usecsOf(double n) { return (cast(long) n).usecs; }

/// `Retry-After`: seconds (integer or decimal) or an HTTP date.
Duration parseRetryAfterHeader(string value, long nowUnix) @trusted
{
    import std.string : strip;
    import std.conv : to;
    import std.math : isFinite;
    value = value.strip;
    try return value.to!ulong.seconds;
    catch (Exception) {}
    try
    {
        auto s = value.to!double;
        if (isFinite(s) && s > 0) return usecsOf(s * 1e6);
    }
    catch (Exception) {}
    try
    {
        import std.datetime.systime : parseRFC822DateTime;
        auto at = parseRFC822DateTime(value).toUnixTime;
        return at > nowUnix ? (at - nowUnix).seconds : Duration.zero;
    }
    catch (Exception) {}
    return Duration.zero;
}

/// "try again in 1.5s" / "250ms" / "2 seconds" in an error message.
Duration parseRetryAfterMessage(string message) @trusted
{
    import std.regex : regex, matchFirst;
    import std.conv : to;
    import std.uni : toLower;
    static re = regex(`\btry again in\s*(\d+(?:\.\d+)?)\s*(ms|milliseconds?|s|seconds?)\b`, "i");
    auto m = matchFirst(message, re);
    if (m.empty) return Duration.zero;
    double amount;
    try amount = m[1].to!double;
    catch (Exception) return Duration.zero;
    return m[2].toLower[0] == 'm' ? usecsOf(amount * 1e3) : usecsOf(amount * 1e6);
}

unittest
{
    alias E = ErrorInfo;
    auto s = defaultRetryableStatuses;
    assert(retryable(E(429), s) && retryable(E(503), s) && retryable(E(529, null, "overloaded_error"), s));
    assert(!retryable(E(400), s));
    assert(!retryable(E(401, null, "authentication_error"), s));
    assert(!retryable(E(429, "insufficient_quota"), s));
    assert(!retryable(E(400, "context_length_exceeded"), s));
    assert(retryable(E(200, "server_error"), s));
}

unittest
{
    auto openai = ErrorInfo.fromBody(429,
        `{"error":{"message":"Rate limit. Please try again in 1.5s.","type":"requests","code":"rate_limit_exceeded"}}`);
    assert(openai.code == "rate_limit_exceeded" && openai.message[0 .. 10] == "Rate limit");
    auto anthropic = ErrorInfo.fromBody(529, `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`);
    assert(anthropic.kind == "overloaded_error" && anthropic.overloaded);
    assert(ErrorInfo.fromBody(502, "bad gateway").message == "bad gateway");
    assert(ErrorInfo.fromBody(400, `{"error":"plain"}`).message == "plain");
}

@trusted unittest
{
    // 2026-01-01T00:00:00Z
    long now = 1_767_225_600;
    assert(parseRetryAfterHeader("7", now) == 7.seconds);
    assert(parseRetryAfterHeader("Thu, 01 Jan 2026 00:00:03 GMT", now) == 3.seconds);
    assert(parseRetryAfterMessage("try again in 250ms") == 250.msecs);
    assert(parseRetryAfterMessage("Please try again in 2 seconds") == 2.seconds);
    RetryPolicy p;
    auto rate = ErrorInfo(429, "rate_limit_exceeded", null, "try again in 2s");
    assert(retryDelay(p, 0, &rate, null, now, 0.5) == 2.seconds);
    assert(retryDelay(p, 0, null, "999", now, 0) == p.maxBackoff);
    assert(retryDelay(p, 0, null, null, now, 0) == 1.seconds);
    assert(retryDelay(p, 3, null, null, now, 0) == 8.seconds);
    assert(retryDelay(p, 10, null, null, now, 0) == 30.seconds);
    assert(retryDelay(p, 0, null, null, now, 1) == 800.msecs);
    auto over = ErrorInfo(529);
    assert(retryDelay(p, 0, &over, null, now, 0) == 10.seconds);
}
