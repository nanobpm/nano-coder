/// Qwen Cloud / Alibaba Cloud Model Studio endpoints (`providers/qwen.rs`):
/// the plan × region table that the `qwen` preset (and, later, the
/// `/settings` endpoint picker) is derived from.
module nano.qwen;

@safe:

import std.string : strip, toLower, indexOf, startsWith, endsWith;
import std.algorithm : stripRight;

/// A Model Studio billing plan; it decides the API-key variable and hosts.
enum QwenPlan { standard, tokenPlan, codingPlan }

string apiKeyEnv(QwenPlan p) pure
{
    final switch (p)
    {
        case QwenPlan.standard: return "DASHSCOPE_API_KEY";
        case QwenPlan.tokenPlan: return "BAILIAN_TOKEN_PLAN_API_KEY";
        case QwenPlan.codingPlan: return "BAILIAN_CODING_PLAN_API_KEY";
    }
}

string label(QwenPlan p) pure
{
    final switch (p)
    {
        case QwenPlan.standard: return "Standard API key";
        case QwenPlan.tokenPlan: return "Token Plan";
        case QwenPlan.codingPlan: return "Coding Plan";
    }
}

struct QwenEndpoint
{
    QwenPlan plan;
    string region;
    /// OpenAI-compatible base URL (no trailing slash).
    string baseUrl;

    string apiKeyEnv() const pure { return plan.apiKeyEnv; }
    /// The picker row, e.g. `Token Plan — China (Beijing)`.
    string label() const pure { return plan.label ~ " — " ~ region; }
}

/// Every Model Studio endpoint; the first is the `qwen` preset's default.
immutable QwenEndpoint[] endpoints = [
    QwenEndpoint(QwenPlan.standard, "Singapore (International)", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
    QwenEndpoint(QwenPlan.standard, "China (Beijing)", "https://dashscope.aliyuncs.com/compatible-mode/v1"),
    QwenEndpoint(QwenPlan.standard, "US (Virginia)", "https://dashscope-us.aliyuncs.com/compatible-mode/v1"),
    QwenEndpoint(QwenPlan.standard, "China (Hong Kong)", "https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1"),
    QwenEndpoint(QwenPlan.tokenPlan, "China (Beijing)", "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"),
    QwenEndpoint(QwenPlan.tokenPlan, "Singapore (International)", "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"),
    QwenEndpoint(QwenPlan.codingPlan, "China (Beijing)", "https://coding.dashscope.aliyuncs.com/v1"),
    QwenEndpoint(QwenPlan.codingPlan, "Singapore (International)", "https://coding-intl.dashscope.aliyuncs.com/v1"),
];

immutable(QwenEndpoint) defaultEndpoint() { return endpoints[0]; }

/// The endpoint whose base URL is exactly `url` (ignoring a trailing slash).
immutable(QwenEndpoint)* endpointForUrl(string url) @trusted
{
    url = url.stripRight('/');
    foreach (ref e; endpoints) if (e.baseUrl == url) return &e;
    return null;
}

/// Whether `url` is a Model Studio host: a plan endpoint, the
/// `dashscope.aliyuncs.com` / `maas.aliyuncs.com` apex, or a workspace host
/// under either (dot boundary, so look-alikes don't match).
bool isModelStudioUrl(string url)
{
    if (endpointForUrl(url) !is null) return true;
    auto t = url.strip;
    auto lower = t.toLower;
    size_t scheme = lower.startsWith("https://") ? 8 : lower.startsWith("http://") ? 7 : 0;
    auto host = t[scheme .. $];
    foreach (i, ch; host) if (ch == '/' || ch == '?' || ch == '#') { host = host[0 .. i]; break; }
    // Userinfo, then port, then a trailing DNS dot.
    foreach_reverse (i, ch; host) if (ch == '@') { host = host[i + 1 .. $]; break; }
    auto colon = host.indexOf(':');
    if (colon >= 0) host = host[0 .. colon];
    host = host.stripRight('.').toLower;
    foreach (apex; ["maas.aliyuncs.com", "dashscope.aliyuncs.com"])
        if (host == apex || (host.endsWith(apex) && host[0 .. $ - apex.length].endsWith(".")))
            return true;
    return false;
}

unittest
{
    import std.algorithm : count, canFind, uniq, sort, map;
    import std.array : array;
    assert(endpoints.count!(e => e.plan == QwenPlan.standard) == 4);
    assert(endpoints.count!(e => e.plan == QwenPlan.tokenPlan) == 2);
    assert(endpoints.count!(e => e.plan == QwenPlan.codingPlan) == 2);
    assert(defaultEndpoint.baseUrl == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1");
    assert(defaultEndpoint.apiKeyEnv == "DASHSCOPE_API_KEY");
    assert(QwenPlan.codingPlan.apiKeyEnv == "BAILIAN_CODING_PLAN_API_KEY");
    auto labels = endpoints.map!(e => e.label).array.sort.uniq.array;
    assert(labels.length == endpoints.length);
    foreach (ref e; endpoints)
    {
        assert(e.baseUrl.startsWith("https://") && !e.baseUrl.endsWith("/"));
        assert(*endpointForUrl(e.baseUrl) == e && *endpointForUrl(e.baseUrl ~ "/") == e);
        assert(isModelStudioUrl(e.baseUrl));
    }
    assert(endpointForUrl("https://example.com/v1") is null);
    assert(endpointForUrl("https://dashscope-intl.aliyuncs.com/compatible-mode/v1/extra") is null);
}

unittest
{
    assert(isModelStudioUrl("https://abc123.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"));
    assert(isModelStudioUrl("HTTPS://ABC123.AP-SOUTHEAST-1.MAAS.ALIYUNCS.COM/compatible-mode/v1"));
    assert(isModelStudioUrl("http://abc123.ap-southeast-1.maas.aliyuncs.com:8443/v1?x=1"));
    assert(isModelStudioUrl("https://user@ws.dashscope.aliyuncs.com./v1"));
    assert(isModelStudioUrl("https://maas.aliyuncs.com"));
    assert(!isModelStudioUrl("https://evilmaas.aliyuncs.com/v1"));
    assert(!isModelStudioUrl("https://maas.aliyuncs.com.evil.example/v1"));
    assert(!isModelStudioUrl("https://example.com/v1"));
}
