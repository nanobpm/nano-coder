/// UNOFFICIAL Meta Muse Code auth and catalog (`providers/muse.rs`).
///
/// Signs in the way the `muse` CLI does: an RFC 8628 device-code login
/// against `auth.meta.com` with Muse's public OAuth client id, then a mint of
/// that OAuth token for a short-lived Meta API key (`POST {mint}/muse-code/key`).
/// Model calls (`MuseClient`) speak the OpenAI Responses API with Muse's
/// client headers. Not Meta-sanctioned: only used when explicitly selected.
module nano.muse;

@safe:

import std.json;
import std.format : format;
import std.string : strip, toLower;
import std.algorithm : stripRight, canFind;
import std.process : environment;
import std.typecons : Nullable;

enum defaultClientId = "1031625952748946";
enum defaultAuthBase = "https://auth.meta.com";
enum defaultMintBase = "https://api.meta.ai";
/// Model API base when neither config nor the mint names one.
enum defaultApiBase = "https://api.meta.ai/v1";
/// `x-api-version` on the device, token, mint and catalog endpoints.
enum museApiVersion = "1.0.0";
/// Refresh the OAuth access token this long before it expires.
enum long refreshMarginSecs = 60;

/// Client identity headers the `muse` CLI sends; a provider's own `headers`
/// override them case-insensitively.
immutable string[2][] clientHeaders = [
    ["User-Agent", "muse-build/1.4.7 (non-interactive; macos-aarch64; nano-coder)"],
    ["x-client-id", "tbh:exec"],
];

private string envBase(string var, string dflt) @trusted
{
    auto v = environment.get(var, "").strip.stripRight('/');
    return v.length ? v : dflt;
}

/// OAuth host (`MUSE_AUTH_BASE_URL` overrides).
string authBase() { return envBase("MUSE_AUTH_BASE_URL", defaultAuthBase); }
/// Mint and catalog host (`MUSE_MINT_BASE_URL` overrides).
string mintBase() { return envBase("MUSE_MINT_BASE_URL", defaultMintBase); }

private string clientId() @trusted
{
    auto id = environment.get("MUSE_CLIENT_ID", "");
    return id.length ? id : defaultClientId;
}

struct Endpoints
{
    string deviceAuthorization, token, mint, catalog;

    static Endpoints forBases(string auth, string mint) pure
    {
        return Endpoints(auth ~ "/oidc/device/authorization/", auth ~ "/oidc/device/token/",
            mint ~ "/muse-code/key", mint ~ "/muse-code/models");
    }

    static Endpoints fromEnv() { return forBases(authBase(), mintBase()); }
}

/// The live OAuth grant: the token the mint exchanges, plus what renews it.
struct OauthGrant
{
    string accessToken;
    /// Null when the grant has none.
    string refreshToken;
    /// Unix expiry of `accessToken`; null when unknown or non-expiring.
    Nullable!long expiresAt;

    /// Past (or within a margin of) expiry, with a refresh token to renew it.
    bool needsRefresh(long now) const
    {
        return refreshToken !is null && !expiresAt.isNull && now >= expiresAt.get - refreshMarginSecs;
    }
}

/// `muse.json`, saved by `--login muse`: the OAuth grant plus the key minted from it.
struct StoredCredentials
{
    string oauthToken, refreshToken;
    Nullable!long expiresAt;
    string apiKey, apiBase, createdAt;

    OauthGrant grant() const { return OauthGrant(oauthToken, refreshToken, expiresAt); }

    JSONValue toJSON() const @trusted
    {
        JSONValue j = ["oauth_token": oauthToken];
        if (refreshToken !is null) j["refresh_token"] = refreshToken;
        if (!expiresAt.isNull) j["expires_at"] = expiresAt.get;
        if (apiKey !is null) j["api_key"] = apiKey;
        if (apiBase !is null) j["api_base"] = apiBase;
        j["created_at"] = createdAt;
        return j;
    }

    static StoredCredentials fromJSON(const JSONValue j) @trusted
    {
        string str(string k)
        {
            auto v = k in j;
            return v && v.type == JSONType.string ? v.str : null;
        }
        StoredCredentials c;
        c.oauthToken = j["oauth_token"].str;
        c.refreshToken = str("refresh_token");
        if (auto v = "expires_at" in j)
            if (v.type == JSONType.integer || v.type == JSONType.uinteger) c.expiresAt = v.integer;
        c.apiKey = str("api_key");
        c.apiBase = str("api_base");
        c.createdAt = str("created_at");
        return c;
    }
}

string credentialsPath(string dataDir = null)
{
    import std.path : buildPath;
    import nano.copilot : appDataDir;
    return buildPath(dataDir.length ? dataDir : appDataDir(), "muse.json");
}

bool loadCredentials(out StoredCredentials c, string dataDir = null) @trusted
{
    import std.file : exists, readText;
    auto path = credentialsPath(dataDir);
    if (!path.exists) return false;
    try c = StoredCredentials.fromJSON(parseJSON(readText(path)));
    catch (Exception) return false;
    return true;
}

/// Atomic, owner-only save; returns the path.
string saveCredentials(const StoredCredentials c, string dataDir = null)
{
    import nano.copilot : writePrivateAtomic;
    auto path = credentialsPath(dataDir);
    writePrivateAtomic(path, c.toJSON.toPrettyString);
    return path;
}

/// Fold a refreshed grant into `muse.json`, unless a newer login replaced it
/// (the refresh token is the stable identity across rotations). Best-effort.
void persistRotated(const OauthGrant renewed, const OauthGrant prior, string dataDir = null)
{
    StoredCredentials c;
    if (!loadCredentials(c, dataDir) || c.refreshToken != prior.refreshToken) return;
    c.oauthToken = renewed.accessToken;
    if (renewed.refreshToken !is null) c.refreshToken = renewed.refreshToken;
    if (!renewed.expiresAt.isNull) c.expiresAt = renewed.expiresAt;
    try saveCredentials(c, dataDir);
    catch (Exception) {}
}

/// A grant another client already renewed and saved: adopted only when it
/// is the same login (same refresh token) and strictly fresher.
Nullable!OauthGrant reloadRenewedGrant(const OauthGrant grant, string dataDir = null)
{
    StoredCredentials c;
    if (!loadCredentials(c, dataDir)) return typeof(return).init;
    auto onDisk = c.grant;
    if (onDisk.accessToken == grant.accessToken) return typeof(return).init;
    if (onDisk.refreshToken != grant.refreshToken || !isFresher(onDisk, grant)) return typeof(return).init;
    return Nullable!OauthGrant(onDisk);
}

/// A later expiry, or a non-expiring grant replacing an expiring one.
bool isFresher(const OauthGrant candidate, const OauthGrant prior)
{
    if (!candidate.expiresAt.isNull && !prior.expiresAt.isNull) return candidate.expiresAt.get > prior.expiresAt.get;
    return candidate.expiresAt.isNull && !prior.expiresAt.isNull;
}

/// RFC 8628 §3.5: each `slow_down` adds at least 5 s to the poll interval.
long slowDownInterval(long current, long advertised)
{
    return advertised > current + 5 ? advertised : current + 5;
}

/// Muse's client headers, minus any the provider overrides.
string[string] withClientHeaders(string[string] h, const string[string] overrides = null)
{
    foreach (pair; clientHeaders)
    {
        bool overridden;
        foreach (k, _; overrides) if (k.toLower == pair[0].toLower) overridden = true;
        if (!overridden) h[pair[0]] = pair[1];
    }
    return h;
}

private JSONValue postForm(string url, string[2][] fields, bool requireOk, out int status) @trusted
{
    import nano.http : Request, perform;
    import std.uri : encodeComponent;
    import std.array : join;
    Request req;
    req.url = url;
    req.headers = withClientHeaders(null);
    req.headers["Accept"] = "application/json";
    req.headers["x-api-version"] = museApiVersion;
    req.headers["Content-Type"] = "application/x-www-form-urlencoded";
    string[] pairs;
    foreach (f; fields) pairs ~= encodeComponent(f[0]) ~ "=" ~ encodeComponent(f[1]);
    req.body_ = pairs.join("&");
    string text;
    status = perform(req, text);
    if (requireOk && (status < 200 || status >= 300))
        throw new Exception(format("%s failed (HTTP %s): %s", url, status, text.length > 300 ? text[0 .. 300] : text));
    try return parseJSON(text);
    catch (Exception e)
    {
        if (requireOk) throw new Exception(format("%s: invalid JSON response", url));
        return JSONValue.init;
    }
}

private string strField(const JSONValue j, string k) @trusted
{
    if (j.type != JSONType.object) return null;
    auto v = k in j;
    return v && v.type == JSONType.string ? v.str : null;
}

private Nullable!long intField(const JSONValue j, string k) @trusted
{
    if (j.type != JSONType.object) return Nullable!long.init;
    auto v = k in j;
    if (v && (v.type == JSONType.integer || v.type == JSONType.uinteger)) return Nullable!long(v.integer);
    return Nullable!long.init;
}

private long now() @trusted
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toUnixTime;
}

/// A minted Meta API key and the endpoint it is valid for.
struct MintedKey
{
    string apiKey, baseUrl;
}

/// Exchange an OAuth access token for a Meta API key. `onboard` only for
/// the interactive login (the account may be new).
MintedKey mint(const Endpoints e, string oauth, bool onboard) @trusted
{
    import nano.http : Request, perform, ApiError;
    Request req;
    req.url = e.mint;
    req.headers = withClientHeaders(null);
    req.headers["Accept"] = "application/json";
    req.headers["x-api-version"] = museApiVersion;
    req.headers["Content-Type"] = "application/json";
    req.headers["Authorization"] = "Bearer " ~ oauth;
    req.body_ = JSONValue(["onboard": onboard]).toString;
    string text;
    auto status = perform(req, text);
    JSONValue v;
    try v = parseJSON(text);
    catch (Exception) {}
    if (status < 200 || status >= 300)
    {
        // A 401 is an ApiError so the caller's re-mint logic sees it.
        if (status == 401) throw new ApiError(status, "{}", mintRefusal(status, v));
        throw new Exception(mintRefusal(status, v));
    }
    auto key = strField(v, "api_key");
    if (!key.length) throw new Exception(mintRefusal(status, v));
    // A 2xx can still carry the account gate alongside a key.
    bool flag(string k)
    {
        if (v.type != JSONType.object) return false;
        auto x = k in v;
        return x && (x.type == JSONType.true_ || x.type == JSONType.false_) ? x.boolean : false;
    }
    bool inactive = v.type == JSONType.object && "is_subs_active" in v && v["is_subs_active"].type == JSONType.false_;
    if (inactive || flag("require_payment")) throw new Exception(mintRefusal(status, v));
    auto base = strField(v, "base_url");
    base = base is null ? null : base.stripRight('/');
    return MintedKey(key, base.length ? base : defaultApiBase);
}

/// An actionable message for a refused mint. Never echoes the body: a
/// refused 2xx can still carry the key.
string mintRefusal(int status, const JSONValue v) @trusted
{
    string field(string k)
    {
        auto s = strField(v, k);
        return s.length ? s : null;
    }
    auto detail = field("detail");
    if (detail is null) detail = field("title");
    auto action = field("action_url");
    if (action is null) action = field("require_payment_action_url");
    bool payment = v.type == JSONType.object && "require_payment" in v && v["require_payment"].type == JSONType.true_;
    auto msg = detail !is null ? format("Muse key mint refused (HTTP %s): %s", status, detail)
        : format("Muse key mint failed (HTTP %s): no usable API key in the response", status);
    if (payment && detail is null) msg ~= ": a payment method or Muse Code subscription is required";
    if (action !is null) msg ~= " — " ~ action;
    return msg ~ ". Run `nano-coder --login muse` again once fixed (or set META_API_KEY).";
}

/// Renew a stale access token; null when fresh, without a refresh token,
/// or when the refresh fails (the caller then mints with what it has).
Nullable!OauthGrant refreshGrant(const Endpoints e, const OauthGrant grant)
{
    if (!grant.needsRefresh(now)) return typeof(return).init;
    int status;
    JSONValue v;
    try v = postForm(e.token, [["client_id", clientId()], ["grant_type", "refresh_token"],
        ["refresh_token", grant.refreshToken]], false, status);
    catch (Exception) return typeof(return).init;
    if (status < 200 || status >= 300) return typeof(return).init;
    auto token = strField(v, "access_token");
    if (token is null) return typeof(return).init;
    OauthGrant g;
    g.accessToken = token;
    // Rotation is optional: keep the old refresh token when none comes back.
    auto rt = strField(v, "refresh_token");
    g.refreshToken = rt !is null ? rt : grant.refreshToken;
    auto expiresIn = intField(v, "expires_in");
    g.expiresAt = expiresIn.isNull ? grant.expiresAt : Nullable!long(now + expiresIn.get);
    return Nullable!OauthGrant(g);
}

/// Interactive device-code login; mints a key to prove the account works,
/// saves both and returns the path.
string login(scope void delegate(string) @safe note, scope void delegate(long secs) @safe sleep,
    Endpoints e = Endpoints.init, string dataDir = null) @trusted
{
    import std.datetime.systime : Clock;
    import std.datetime.timezone : UTC;
    if (e == Endpoints.init) e = Endpoints.fromEnv();
    auto id = clientId();
    int status;
    auto device = postForm(e.deviceAuthorization, [["client_id", id]], true, status);
    auto deviceCode = strField(device, "device_code"), userCode = strField(device, "user_code"),
        uri = strField(device, "verification_uri");
    if (deviceCode is null || userCode is null || uri is null)
        throw new Exception("unexpected device code response: " ~ device.toString);
    auto iv = intField(device, "interval");
    long interval = iv.isNull ? 5 : iv.get;
    if (interval < 1) interval = 1;
    auto ex = intField(device, "expires_in");
    auto deadline = now + (ex.isNull ? 900 : ex.get);
    note("UNOFFICIAL: this signs in as the Muse Code CLI; use at your own risk.");
    note(format("Open %s and enter code: %s", uri, userCode));
    note("Waiting for authorization...");
    while (true)
    {
        if (now > deadline) throw new Exception("device code expired before authorization");
        sleep(interval);
        auto poll = postForm(e.token, [["client_id", id], ["device_code", deviceCode],
            ["grant_type", "urn:ietf:params:oauth:grant-type:device_code"]], false, status);
        if (auto token = strField(poll, "access_token"))
        {
            auto expiresIn = intField(poll, "expires_in");
            // Prove the account can mint before reporting success.
            auto minted = mint(e, token, true);
            StoredCredentials c;
            c.oauthToken = token;
            c.refreshToken = strField(poll, "refresh_token");
            if (!expiresIn.isNull) c.expiresAt = now + expiresIn.get;
            c.apiKey = minted.apiKey;
            c.apiBase = minted.baseUrl;
            c.createdAt = Clock.currTime(UTC()).toISOExtString;
            auto path = saveCredentials(c, dataDir);
            note("Logged in; Muse API endpoint " ~ c.apiBase);
            return path;
        }
        auto err = strField(poll, "error");
        if (err is null) throw new Exception("unexpected token response: " ~ poll.toString);
        switch (err)
        {
            case "authorization_pending": break;
            case "slow_down":
                auto adv = intField(poll, "interval");
                interval = slowDownInterval(interval, adv.isNull ? 0 : adv.get);
                break;
            default:
                auto desc = strField(poll, "error_description");
                throw new Exception(format("login failed: %s: %s", err, desc is null ? "" : desc));
        }
    }
}

// ---- Catalog rows (`GET {mint}/muse-code/models`) ----

/// Rows of a catalog reply: a bare array, or one under `data`/`models`/`rows`.
const(JSONValue)[] catalogRows(const JSONValue v) @trusted
{
    if (v.type == JSONType.object)
        foreach (k; ["data", "models", "rows"])
            if (auto rows = k in v) if (rows.type == JSONType.array) return rows.array;
    return v.type == JSONType.array ? v.array : null;
}

string modelId(const JSONValue row)
{
    foreach (k; ["id", "model_id", "modelId"]) if (auto s = strField(row, k)) return s;
    return null;
}

/// `metadata["muse-code"].is_hidden`, or `visibility: "hidden"`.
bool isHiddenRow(const JSONValue row) @trusted
{
    if (row.type != JSONType.object) return false;
    if (auto m = "metadata" in row)
        if (m.type == JSONType.object)
            if (auto mc = "muse-code" in *m)
                if (mc.type == JSONType.object)
                    if (auto h = "is_hidden" in *mc) if (h.type == JSONType.true_) return true;
    foreach (k; ["visibility", "Visibility"])
        if (auto s = strField(row, k)) return s.toLower == "hidden";
    return false;
}

/// An image-generation model (its image flag is not input vision).
bool isImageGenerationRow(const JSONValue row) @trusted
{
    if (row.type != JSONType.object) return false;
    foreach (k; ["supports_image_generation", "supportsImageGeneration"])
        if (auto v = k in row) return v.type == JSONType.true_;
    return false;
}

/// Contributor rows need a per-request opt-in this client never sends.
bool isContributorRow(const JSONValue row)
{
    return modelId(row).toLower.canFind("contributor");
}

/// Chat rows accept images; generation, hidden and contributor rows don't.
bool museVision(const JSONValue row)
{
    return !isImageGenerationRow(row) && !isHiddenRow(row) && !isContributorRow(row);
}

private long positive(const JSONValue row, string[] keys) @trusted
{
    if (row.type != JSONType.object) return 0;
    foreach (k; keys)
        if (auto v = k in row)
            if (v.type == JSONType.integer || v.type == JSONType.uinteger) return v.integer > 0 ? v.integer : 0;
    return 0;
}

/// The context window (0 when unknown).
long contextLimit(const JSONValue row)
{
    return positive(row, ["context_limit", "contextLimit", "context_window", "contextWindow", "max_context_window_tokens"]);
}

/// The published output cap (0 when unknown).
long outputLimit(const JSONValue row)
{
    return positive(row, ["output_limit", "outputLimit", "max_output_tokens", "maxOutputTokens",
        "max_completion_tokens", "maxCompletionTokens"]);
}

/// Reasoning tiers: `reasoning_effort_variants` (`[{tier}]`, `[{effort}]` or
/// strings), else a flat `reasoning_effort` list; `none` reads as `off`.
string[] effortLevels(const JSONValue row) @trusted
{
    if (row.type != JSONType.object) return null;
    const(JSONValue)[] raw;
    bool found;
    foreach (k; ["reasoning_effort_variants", "reasoningEffortVariants", "reasoning_effort", "reasoningEffort"])
        if (auto v = k in row)
            if (v.type == JSONType.array) { raw = v.array; found = true; break; }
    if (!found) return null;
    string[] levels;
    foreach (v; raw)
    {
        string s = v.type == JSONType.string ? v.str : null;
        if (s is null) foreach (k; ["tier", "effort"]) if ((s = strField(v, k)) !is null) break;
        if (s is null) continue;
        s = s.strip.toLower;
        if (s == "none") s = "off";
        if (s.length) levels ~= s;
    }
    return levels;
}

/// Model ids worth offering: no generation, hidden or contributor rows.
string[] listableModels(const JSONValue catalog)
{
    import std.algorithm : sort, uniq;
    import std.array : array;
    string[] ids;
    foreach (row; catalogRows(catalog))
    {
        auto id = modelId(row);
        if (id !is null && !isImageGenerationRow(row) && !isHiddenRow(row) && !isContributorRow(row)) ids ~= id;
    }
    return ids.sort.uniq.array;
}

unittest
{
    auto e = Endpoints.forBases("https://auth.example", "https://mint.example");
    assert(e.token == "https://auth.example/oidc/device/token/" && e.catalog == "https://mint.example/muse-code/models");
    assert(slowDownInterval(5, 0) == 10 && slowDownInterval(5, 30) == 30 && slowDownInterval(5, 7) == 10);
    auto h = withClientHeaders(null, ["user-agent": "mine"]);
    assert("User-Agent" !in h && h["x-client-id"] == "tbh:exec");
}

@trusted unittest
{
    auto refused = mintRefusal(403, parseJSON(`{"api_key":"sk-secret","require_payment":true,"action_url":"https://pay"}`));
    assert(!refused.canFind("sk-secret") && refused.canFind("subscription is required") && refused.canFind("https://pay"));
    assert(mintRefusal(402, parseJSON(`{"detail":"Upgrade"}`)).canFind("refused (HTTP 402): Upgrade"));
    assert(mintRefusal(500, JSONValue.init).canFind("no usable API key"));
}

@trusted unittest
{
    OauthGrant g = OauthGrant("a", "r", Nullable!long(100));
    assert(g.needsRefresh(50) && !g.needsRefresh(39));
    assert(!OauthGrant("a", null, Nullable!long(100)).needsRefresh(1000));
    assert(isFresher(OauthGrant("b", "r", Nullable!long(200)), g));
    assert(isFresher(OauthGrant("b", "r"), g) && !isFresher(OauthGrant("b", "r"), OauthGrant("a", "r")));
}

@trusted unittest
{
    import std.file : tempDir, rmdirRecurse, exists, getAttributes;
    import std.path : buildPath;
    import nano.copilot : octal;
    auto dir = buildPath(tempDir, "nano-d-muse-cred");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    StoredCredentials c;
    c.oauthToken = "old";
    c.refreshToken = "r1";
    c.expiresAt = 100;
    c.apiKey = "k";
    c.createdAt = "2026-01-01T00:00:00Z";
    auto path = saveCredentials(c, dir);
    assert((getAttributes(path) & octal!777) == octal!600);
    StoredCredentials back;
    assert(loadCredentials(back, dir) && back.apiKey == "k" && back.apiBase is null && back.expiresAt.get == 100);

    // Another client renewed it: adopted when the login matches and it's fresher.
    persistRotated(OauthGrant("new", null, Nullable!long(500)), OauthGrant("old", "r1", Nullable!long(100)), dir);
    assert(loadCredentials(back, dir) && back.oauthToken == "new" && back.refreshToken == "r1" && back.expiresAt.get == 500);
    auto adopted = reloadRenewedGrant(OauthGrant("old", "r1", Nullable!long(100)), dir);
    assert(!adopted.isNull && adopted.get.accessToken == "new");
    // A different login (refresh token changed) is never written over or adopted.
    persistRotated(OauthGrant("mine"), OauthGrant("old", "other"), dir);
    assert(loadCredentials(back, dir) && back.oauthToken == "new");
    assert(reloadRenewedGrant(OauthGrant("old", "other", Nullable!long(1)), dir).isNull);
}

@trusted unittest
{
    auto cat = parseJSON(`{"data":[
        {"id":"muse-spark-1.3","context_limit":200000,"output_limit":32000,
         "reasoning_effort_variants":[{"effort":"none"},{"tier":"High"},"low"]},
        {"model_id":"muse-image","supports_image_generation":true},
        {"id":"muse-internal","metadata":{"muse-code":{"is_hidden":true}}},
        {"id":"muse-old","visibility":"Hidden"},
        {"id":"muse-spark-1.3-contributor"},
        {"id":"muse-spark-1.3"}]}`);
    auto rows = catalogRows(cat);
    assert(rows.length == 6);
    assert(contextLimit(rows[0]) == 200_000 && outputLimit(rows[0]) == 32_000 && contextLimit(rows[1]) == 0);
    assert(effortLevels(rows[0]) == ["off", "high", "low"] && effortLevels(rows[1]) is null);
    assert(museVision(rows[0]) && !museVision(rows[1]) && !museVision(rows[2]) && !museVision(rows[4]));
    assert(listableModels(cat) == ["muse-spark-1.3"]);
    assert(catalogRows(parseJSON(`[{"id":"x"}]`)).length == 1);
}
