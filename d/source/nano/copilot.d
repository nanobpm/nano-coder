/// GitHub Copilot model routing (from `providers/github_copilot.rs`): which
/// upstream API a model is served through, and which models reason.
module nano.copilot;

@safe:

import std.algorithm : startsWith, any;
import std.ascii : isDigit;

/// The Copilot upstream API a model must be called through: the wrong one
/// fails with `unsupported_api_for_model` rather than falling back.
enum CopilotApi { completions, responses, messages }

string path(CopilotApi api) pure nothrow
{
    final switch (api)
    {
        case CopilotApi.completions: return "/chat/completions";
        case CopilotApi.responses: return "/responses";
        case CopilotApi.messages: return "/v1/messages";
    }
}

/// The leading integer of a version tail (`"5.6"` → 5); -1 when none.
private long leadingMajor(string tail) pure
{
    import std.conv : to;
    size_t n;
    while (n < tail.length && tail[n].isDigit) n++;
    return n && n < 10 ? tail[0 .. n].to!long : -1;
}

/// Claude 4.x/5.x (`claude-(haiku|sonnet|opus|fable)-[45]` then `.`, `-` or end).
bool usesAnthropicMessages(string model) pure
{
    foreach (family; ["claude-haiku-", "claude-sonnet-", "claude-opus-", "claude-fable-"])
        if (model.startsWith(family))
        {
            auto rest = model[family.length .. $];
            if (rest.length && (rest[0] == '4' || rest[0] == '5') && (rest.length == 1 || rest[1] == '.' || rest[1] == '-'))
                return true;
        }
    return false;
}

/// Claude 4/5 → Messages; GPT before 5 → Chat Completions; newer GPT, Grok,
/// OSWE and MAI → Responses; anything else → Chat Completions.
CopilotApi apiForModel(string model) pure
{
    if (usesAnthropicMessages(model)) return CopilotApi.messages;
    if (model.startsWith("gpt-"))
    {
        auto major = leadingMajor(model[4 .. $]);
        if (major >= 0 && major < 5) return CopilotApi.completions;
    }
    if (["gpt-", "grok-", "oswe", "mai-"].any!(p => model.startsWith(p))) return CopilotApi.responses;
    return CopilotApi.completions;
}

/// Responses-routed models reason: they need reasoning items replayed and
/// reject a non-default temperature. GPT-5 and later, Grok, OSWE, MAI.
bool isReasoningModel(string model) pure
{
    if (apiForModel(model) != CopilotApi.responses) return false;
    if (model.startsWith("gpt-")) return leadingMajor(model[4 .. $]) >= 5;
    return true;
}

unittest
{
    assert(apiForModel("claude-sonnet-4.5") == CopilotApi.messages);
    assert(apiForModel("claude-opus-4-1") == CopilotApi.messages);
    assert(apiForModel("claude-sonnet-42") == CopilotApi.completions);
    assert(apiForModel("claude-3.5-sonnet") == CopilotApi.completions);
    assert(apiForModel("gpt-4.1") == CopilotApi.completions);
    assert(apiForModel("gpt-4o") == CopilotApi.completions);
    assert(apiForModel("gpt-5-mini") == CopilotApi.responses);
    assert(apiForModel("gpt-6-astra") == CopilotApi.responses);
    assert(apiForModel("grok-code-fast-1") == CopilotApi.responses);
    assert(apiForModel("o4-mini") == CopilotApi.completions);
    assert(isReasoningModel("gpt-5") && isReasoningModel("grok-code-fast-1"));
    assert(!isReasoningModel("gpt-4.1") && !isReasoningModel("o4-mini") && !isReasoningModel("claude-sonnet-4.5"));
}

// ---- Authentication: device-flow login and session-token exchange ----

import std.json;
import std.format : format;
import std.string : strip, stripRight, split;
import std.process : environment;

enum defaultClientId = "Iv1.b507a08c87ecfe98";
enum defaultApiBase = "https://api.individual.githubcopilot.com";
/// Refresh a session token this long before it expires.
enum long refreshMarginSecs = 300;

static immutable string[2][] editorHeaders = [
    ["User-Agent", "GitHubCopilotChat/0.35.0"],
    ["Editor-Version", "vscode/1.107.0"],
    ["Editor-Plugin-Version", "copilot-chat/0.35.0"],
    ["Copilot-Integration-Id", "vscode-chat"],
];

/// GitHub host: `github.com`, or a GHE.com domain via `GITHUB_COPILOT_DOMAIN`.
string domain() @trusted
{
    import std.algorithm : stripLeft;
    auto d = environment.get("GITHUB_COPILOT_DOMAIN", "").strip;
    if (d.startsWith("https://")) d = d["https://".length .. $];
    d = d.stripRight("/");
    return d.length ? d : "github.com";
}

private string clientId() @trusted
{
    auto id = environment.get("GITHUB_COPILOT_CLIENT_ID", "");
    return id.length ? id : defaultClientId;
}

struct Endpoints
{
    string deviceCode, accessToken, copilotToken;

    static Endpoints forDomain(string d) pure
    {
        return Endpoints("https://" ~ d ~ "/login/device/code", "https://" ~ d ~ "/login/oauth/access_token",
            "https://api." ~ d ~ "/copilot_internal/v2/token");
    }
}

/// The platform data dir (`~/Library/Application Support/nano-coder` or
/// `$XDG_DATA_HOME/nano-coder`), shared with the Rust build; the legacy
/// `agentic-harness` dir when only that exists.
string appDataDir() @trusted
{
    import std.path : buildPath, expandTilde;
    import std.file : exists;
    version (OSX) auto base = buildPath(expandTilde("~"), "Library", "Application Support");
    else auto base = environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share"));
    auto current = buildPath(base, "nano-coder"), legacy = buildPath(base, "agentic-harness");
    return !current.exists && legacy.exists ? legacy : current;
}

/// `github-copilot.json` in the platform data dir, shared with the Rust build.
string credentialsPath(string dataDir = null) @trusted
{
    import std.path : buildPath;
    return buildPath(dataDir.length ? dataDir : appDataDir(), "github-copilot.json");
}

/// Replace `path` with `text` atomically, owner-only (0600): written to a
/// unique, exclusively created temp file in the same dir, then renamed, so a
/// failed write never leaves a torn or empty credentials file.
void writePrivateAtomic(string path, string text) @trusted
{
    import std.file : mkdirRecurse, rename, remove, setAttributes, exists;
    import std.path : dirName;
    import std.random : uniform;
    import std.process : thisProcessID;
    import std.string : toStringz;
    import core.sys.posix.fcntl : open, O_CREAT, O_EXCL, O_WRONLY;
    import core.sys.posix.unistd : write, close, fsync;
    mkdirRecurse(path.dirName);
    auto tmp = format("%s.tmp.%s.%08x", path, thisProcessID, uniform!uint);
    int fd = open(tmp.toStringz, O_CREAT | O_EXCL | O_WRONLY, octal!600);
    if (fd < 0) throw new Exception("open " ~ tmp ~ " failed");
    bool ok;
    scope (exit) if (!ok && tmp.exists) remove(tmp);
    {
        scope (exit) close(fd);
        size_t done;
        while (done < text.length)
        {
            auto n = write(fd, text.ptr + done, text.length - done);
            if (n <= 0) throw new Exception("write " ~ tmp ~ " failed");
            done += n;
        }
        fsync(fd);
    }
    rename(tmp, path);
    ok = true;
    // A pre-existing file's looser mode doesn't survive the rename, but force it anyway.
    setAttributes(path, octal!600);
}

struct StoredCredentials
{
    string oauthToken, domain, createdAt;
}

/// The saved login, if any (and parseable).
bool loadCredentials(out StoredCredentials c, string dataDir = null) @trusted
{
    import std.file : exists, readText;
    auto path = credentialsPath(dataDir);
    if (!path.exists) return false;
    try
    {
        auto j = parseJSON(readText(path));
        c.oauthToken = j["oauth_token"].str;
        c.domain = "domain" in j ? j["domain"].str : "github.com";
        c.createdAt = "created_at" in j ? j["created_at"].str : "";
        return true;
    }
    catch (Exception) return false;
}

/// Write the login with owner-only permissions; returns the path.
string saveCredentials(const StoredCredentials c, string dataDir = null) @trusted
{
    auto path = credentialsPath(dataDir);
    JSONValue j = ["oauth_token": c.oauthToken, "domain": c.domain, "created_at": c.createdAt];
    writePrivateAtomic(path, j.toPrettyString);
    return path;
}

package template octal(int n) { enum octal = (n / 100) * 64 + ((n / 10) % 10) * 8 + n % 10; }

/// `proxy-ep=proxy.individual.githubcopilot.com` → `https://api.individual.githubcopilot.com`.
string baseUrlFromToken(string token) pure
{
    foreach (part; token.split(';'))
        if (part.startsWith("proxy-ep="))
        {
            auto ep = part["proxy-ep=".length .. $];
            return "https://" ~ (ep.startsWith("proxy.") ? "api." ~ ep["proxy.".length .. $] : ep);
        }
    return null;
}

/// Short-lived Copilot API credentials.
struct SessionToken
{
    string token, baseUrl;
    long refreshAt;
}

/// Exchange a GitHub OAuth token for a Copilot session token.
SessionToken exchange(const Endpoints e, string oauth) @trusted
{
    import nano.http : Request, perform;
    import std.datetime.systime : Clock;
    Request req;
    req.method = "GET";
    req.url = e.copilotToken;
    foreach (h; editorHeaders) req.headers[h[0]] = h[1];
    req.headers["Accept"] = "application/json";
    req.headers["Authorization"] = "Bearer " ~ oauth;
    string text;
    auto status = perform(req, text);
    if (status < 200 || status >= 300)
        throw new Exception(format("Copilot token exchange failed (HTTP %s): %s. Run `nano-coder --login github-copilot` "
            ~ "or set GITHUB_COPILOT_OAUTH_TOKEN; the account must have an active Copilot subscription.",
            status, text.length > 300 ? text[0 .. 300] : text));
    auto j = parseJSON(text);
    auto t = "token" in j;
    if (t is null || t.type != JSONType.string) throw new Exception("Copilot token response has no token");
    SessionToken s;
    s.token = t.str;
    auto expires = "expires_at" in j && j["expires_at"].type == JSONType.integer ? j["expires_at"].integer
        : Clock.currTime.toUnixTime + 1500;
    s.refreshAt = expires - refreshMarginSecs;
    if (auto ep = "endpoints" in j)
        if (ep.type == JSONType.object)
            if (auto api = "api" in *ep) if (api.type == JSONType.string) s.baseUrl = api.str.stripRight("/");
    if (!s.baseUrl.length) s.baseUrl = baseUrlFromToken(s.token);
    if (!s.baseUrl.length) s.baseUrl = defaultApiBase;
    return s;
}

/// POST a form with editor headers; the parsed JSON reply.
private JSONValue postForm(string url, string[2][] fields, bool requireOk) @trusted
{
    import nano.http : Request, perform;
    import std.uri : encodeComponent;
    Request req;
    req.url = url;
    foreach (h; editorHeaders) req.headers[h[0]] = h[1];
    req.headers["Accept"] = "application/json";
    req.headers["Content-Type"] = "application/x-www-form-urlencoded";
    string[] pairs;
    foreach (f; fields) pairs ~= encodeComponent(f[0]) ~ "=" ~ encodeComponent(f[1]);
    import std.array : join;
    req.body_ = pairs.join("&");
    string text;
    auto status = perform(req, text);
    if (requireOk && (status < 200 || status >= 300))
        throw new Exception(format("%s failed (HTTP %s): %s", url, status, text));
    return parseJSON(text);
}

/// Interactive device-flow login; saves the OAuth token and returns its path.
/// `note` prints progress (stderr in the CLI); `sleep` waits between polls.
string login(scope void delegate(string) @safe note, scope void delegate(long secs) @safe sleep,
    Endpoints e = Endpoints.init, string dataDir = null) @trusted
{
    import std.datetime.systime : Clock;
    auto d = domain();
    if (e == Endpoints.init) e = Endpoints.forDomain(d);
    auto id = clientId();
    auto device = postForm(e.deviceCode, [["client_id", id], ["scope", "read:user"]], true);
    string field(string k) { auto v = k in device; return v && v.type == JSONType.string ? v.str : null; }
    auto deviceCode = field("device_code"), userCode = field("user_code"), uri = field("verification_uri");
    if (!deviceCode.length || !userCode.length || !uri.length)
        throw new Exception("unexpected device code response: " ~ device.toString);
    long num(JSONValue j, string k, long dflt)
    {
        auto v = k in j;
        return v && v.type == JSONType.integer ? v.integer : dflt;
    }
    long interval = num(device, "interval", 5);
    if (interval < 1) interval = 1;
    auto deadline = Clock.currTime.toUnixTime + num(device, "expires_in", 900);
    note("UNOFFICIAL: this signs in as the VS Code Copilot extension; use at your own risk.");
    note(format("Open %s and enter code: %s", uri, userCode));
    note("Waiting for authorization...");
    while (true)
    {
        if (Clock.currTime.toUnixTime > deadline) throw new Exception("device code expired before authorization");
        sleep(interval);
        auto poll = postForm(e.accessToken, [["client_id", id], ["device_code", deviceCode],
            ["grant_type", "urn:ietf:params:oauth:grant-type:device_code"]], false);
        if (auto t = "access_token" in poll)
            if (t.type == JSONType.string)
            {
                // Prove the account actually has Copilot before reporting success.
                auto session = exchange(e, t.str);
                auto path = saveCredentials(StoredCredentials(t.str, d, Clock.currTime.toISOExtString), dataDir);
                note("Logged in; Copilot API endpoint " ~ session.baseUrl);
                return path;
            }
        auto err = "error" in poll;
        if (err is null || err.type != JSONType.string) throw new Exception("unexpected token response: " ~ poll.toString);
        switch (err.str)
        {
            case "authorization_pending": break;
            case "slow_down": interval = num(poll, "interval", interval + 5); break;
            default:
                auto desc = "error_description" in poll;
                throw new Exception(format("login failed: %s: %s", err.str, desc && desc.type == JSONType.string ? desc.str : ""));
        }
    }
}

unittest
{
    assert(baseUrlFromToken("tid=1;exp=2;proxy-ep=proxy.individual.githubcopilot.com;x=y") == "https://api.individual.githubcopilot.com");
    assert(baseUrlFromToken("proxy-ep=copilot.example.com") == "https://copilot.example.com");
    assert(baseUrlFromToken("tid=1") is null);
    auto e = Endpoints.forDomain("acme.ghe.com");
    assert(e.copilotToken == "https://api.acme.ghe.com/copilot_internal/v2/token");
    assert(e.deviceCode == "https://acme.ghe.com/login/device/code");
}

@trusted unittest
{
    import std.file : tempDir, rmdirRecurse, getAttributes, exists;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-copilot-cred");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    StoredCredentials c;
    assert(!loadCredentials(c, dir));
    auto path = saveCredentials(StoredCredentials("gho_x", "github.com", "2026-01-01T00:00:00Z"), dir);
    assert((getAttributes(path) & octal!777) == octal!600);
    assert(loadCredentials(c, dir) && c.oauthToken == "gho_x" && c.domain == "github.com");
}
