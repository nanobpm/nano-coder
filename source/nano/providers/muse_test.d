/// Muse Code client against scripted mint, auth, catalog and API servers
/// (providers/muse.rs tests).
module nano.providers.muse_test;
@safe:

version (unittest):

import std.algorithm : canFind;
import std.json;
import std.string : toLower;
import std.typecons : Nullable;
import nano.config : Config, presets, resolve, ResolvedProvider;
import nano.llm;
import nano.muse;
import nano.providers.muse : MuseClient;
import nano.testserver;

private:

enum responsesOk = `{"output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}],"status":"completed"}`;
enum catalogBody = `{"data":[{"model_id":"muse-spark-1.3"}]}`;
enum mintBody = `{"api_key":"minted-key","base_url":"http://unused"}`;

immutable(Reply) ok(string body_) { return immutable Reply(200, "", body_); }

/// A credentials dir holding `creds`; removed by the caller's scope(exit).
string credsDir(string name, StoredCredentials creds)
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-muse-test-" ~ name);
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    saveCredentials(creds, dir);
    return dir;
}

StoredCredentials freshGrant()
{
    StoredCredentials c;
    c.oauthToken = "oauth-tok";
    c.createdAt = "2026-01-01T00:00:00Z";
    return c;
}

/// A grant past its expiry, with a refresh token to renew it.
StoredCredentials staleGrant()
{
    auto c = freshGrant();
    c.refreshToken = "refresh-tok";
    c.expiresAt = 1;
    return c;
}

ResolvedProvider provider(string base, string[string] headers = null)
{
    Config cfg;
    cfg.providers = presets();
    auto p = resolve(cfg, "muse/muse-spark-1.3");
    p.apiKey = null; // a real META_API_KEY would bypass the grant under test
    p.config.baseUrl = base;
    p.config.retryInitialBackoffMs = 1;
    p.config.timeoutSecs = 10;
    foreach (k, v; headers) p.config.headers[k] = v;
    return p;
}

MuseClient client(string base, string dir, Endpoints e, string[string] headers = null)
{
    auto c = new MuseClient(provider(base, headers), dir);
    c.endpoints = e;
    c.persist = false;
    return c;
}

/// Endpoints with the auth/mint on `mintSrv` and the catalog on `catalogSrv`.
Endpoints endpoints(string mintSrv, string catalogSrv)
{
    auto e = Endpoints.forBases(mintSrv, mintSrv);
    e.catalog = catalogSrv ~ "/muse-code/models";
    return e;
}

string hello(MuseClient c)
{
    ChatRequest req;
    req.messages = [Message.user("hello")];
    return c.chat(req, null).content;
}

void cleanup(string dir)
{
    import std.file : rmdirRecurse;
    rmdirRecurse(dir);
}

// rust: providers/muse.rs::catalog_applies_configured_provider_headers
unittest
{
    auto dir = credsDir("hdr", freshGrant);
    scope (exit) cleanup(dir);
    auto catalog = serve([ok(catalogBody)]);
    auto mintSrv = serve([ok(mintBody)]);
    client(catalog.url, dir, endpoints(mintSrv.url, catalog.url), ["User-Agent": "custom-agent/9"]).listModels();
    mintSrv.finish();
    auto sent = catalog.finish()[0].headers.toLower;
    assert(sent.canFind("user-agent: custom-agent/9") && !sent.canFind("muse-build/"), sent);
}

// rust: providers/muse.rs::catalog_remints_on_a_401_with_a_non_json_body
// rust: providers/muse.rs::catalog_remints_once_after_a_401
unittest
{
    foreach (unauthorized; ["Unauthorized", `{"error":{"message":"expired"}}`])
    {
        auto dir = credsDir("cat401", freshGrant);
        scope (exit) cleanup(dir);
        auto catalog = serve([immutable Reply(401, "", unauthorized), ok(catalogBody)]);
        auto mintSrv = serve([ok(mintBody), ok(mintBody)]);
        assert(client(catalog.url, dir, endpoints(mintSrv.url, catalog.url)).listModels() == ["muse-spark-1.3"]);
        assert(mintSrv.finish().length == 2 && catalog.finish().length == 2, unauthorized);
    }
}

// rust: providers/muse.rs::catalog_sends_api_version_header
unittest
{
    auto dir = credsDir("ver", freshGrant);
    scope (exit) cleanup(dir);
    auto catalog = serve([ok(catalogBody)]);
    auto mintSrv = serve([ok(mintBody)]);
    client(catalog.url, dir, endpoints(mintSrv.url, catalog.url)).listModels();
    mintSrv.finish();
    assert(catalog.finish()[0].headers.toLower.canFind("x-api-version: 1.0.0"));
}

Endpoints mintAt(string url)
{
    auto e = Endpoints.forBases("http://unused", "http://unused");
    e.mint = url ~ "/muse-code/key";
    return e;
}

// rust: providers/muse.rs::mint_defaults_base_url_when_omitted
unittest
{
    auto srv = serve([ok(`{"api_key":"minted-key"}`)]);
    auto minted = mint(mintAt(srv.url), "oauth-tok", false);
    srv.finish();
    assert(minted.apiKey == "minted-key" && minted.baseUrl == defaultApiBase);
}

// rust: providers/muse.rs::mint_rejects_an_inactive_subscription_even_with_a_key
unittest
{
    foreach (gate; [`{"api_key":"k","base_url":"http://x","is_subs_active":false}`,
        `{"api_key":"k","base_url":"http://x","require_payment":true}`])
    {
        auto srv = serve([ok(gate)]);
        string err;
        try mint(mintAt(srv.url), "oauth-tok", false);
        catch (Exception e) err = e.msg;
        srv.finish();
        assert(err.canFind("--login muse") && !err.canFind(`"k"`), err);
    }
}

// rust: providers/muse.rs::mint_sends_api_version_and_onboard_flag
unittest
{
    foreach (onboard; [true, false])
    {
        auto srv = serve([ok(`{"api_key":"k","base_url":"http://x"}`)]);
        mint(mintAt(srv.url), "oauth-tok", onboard);
        auto r = srv.finish()[0];
        assert(r.headers.toLower.canFind("x-api-version: 1.0.0"), r.headers);
        assert(parseJSON(r.body_)["onboard"].boolean == onboard);
    }
}

// rust: providers/muse.rs::mints_and_calls_the_responses_api
unittest
{
    auto dir = credsDir("chat", freshGrant);
    scope (exit) cleanup(dir);
    auto mintSrv = serve([ok(mintBody)]);
    auto api = serve([ok(responsesOk)]);
    // The provider's explicit base_url wins over the minted base.
    assert(hello(client(api.url, dir, endpoints(mintSrv.url, mintSrv.url))) == "hi");
    auto a = api.finish()[0];
    auto b = parseJSON(a.body_);
    assert(a.path == "/responses" && b["model"].str == "muse-spark-1.3" && "input" in b && "messages" !in b);
    auto h = a.headers.toLower;
    assert(h.canFind("authorization: bearer minted-key") && h.canFind("x-client-id: tbh:exec"), h);
    auto m = mintSrv.finish()[0];
    assert(m.path == "/muse-code/key" && !parseJSON(m.body_)["onboard"].boolean);
    assert(m.headers.toLower.canFind("authorization: bearer oauth-tok") && m.headers.toLower.canFind("x-api-version: 1.0.0"));
}

// rust: providers/muse.rs::parses_the_catalog_envelope_tolerantly
unittest
{
    assert(catalogRows(parseJSON(`[{"model_id":"muse-spark-1.3","context_limit":131072}]`)).length == 1);
    assert(catalogRows(parseJSON(`{"data":[{"id":"a"},{"id":"b"}]}`)).length == 2);
    auto models = parseJSON(`{"models":[{"model_id":"c"}]}`);
    assert(catalogRows(models).length == 1 && modelId(catalogRows(models)[0]) == "c");
    assert(modelId(parseJSON(`{"id":"d"}`)) == "d");
    assert(contextLimit(parseJSON(`{"context_limit":131072}`)) == 131_072);
    assert(contextLimit(parseJSON(`{"contextLimit":200000}`)) == 200_000);
    assert(contextLimit(parseJSON(`{"context_limit":0}`)) == 0);
}

enum refreshed = `{"access_token":"fresh-tok","refresh_token":"refresh-tok-2","expires_in":3600}`;

// rust: providers/muse.rs::remint_refreshes_a_stale_oauth_token_first
// rust: providers/muse.rs::synthetic_grant_refresh_does_not_touch_the_saved_credentials
unittest
{
    import std.file : read;
    auto dir = credsDir("stale", staleGrant);
    scope (exit) cleanup(dir);
    auto before = read(credentialsPath(dir));
    auto auth = serve([ok(refreshed)]);
    auto mintSrv = serve([ok(mintBody)]);
    auto api = serve([ok(responsesOk)]);
    auto e = Endpoints.forBases(auth.url, mintSrv.url);
    assert(hello(client(api.url, dir, e)) == "hi");
    api.finish();
    assert(auth.finish()[0].path == "/oidc/device/token/");
    assert(mintSrv.finish()[0].headers.toLower.canFind("authorization: bearer fresh-tok"));
    assert(read(credentialsPath(dir)) == before, "a non-persisting client leaves muse.json alone");
}

// rust: providers/muse.rs::remint_with_a_fresh_grant_skips_the_refresh
unittest
{
    auto dir = credsDir("fresh", freshGrant);
    scope (exit) cleanup(dir);
    auto mintSrv = serve([ok(mintBody)]);
    auto api = serve([ok(responsesOk)]);
    auto e = Endpoints.forBases("http://127.0.0.1:1", mintSrv.url);
    assert(hello(client(api.url, dir, e)) == "hi");
    api.finish();
    assert(mintSrv.finish()[0].headers.toLower.canFind("authorization: bearer oauth-tok"));
}

// rust: providers/muse.rs::remints_once_after_a_401
unittest
{
    auto dir = credsDir("401", freshGrant);
    scope (exit) cleanup(dir);
    auto mintSrv = serve([ok(mintBody), ok(mintBody)]);
    auto api = serve([immutable Reply(401, "", `{"error":{"code":"invalid_api_key","message":"expired"}}`), ok(responsesOk)]);
    assert(hello(client(api.url, dir, endpoints(mintSrv.url, mintSrv.url))) == "hi");
    assert(mintSrv.finish().length == 2 && api.finish().length == 2);
}

// rust: providers/muse.rs::reuses_a_stored_minted_key_without_minting_again
unittest
{
    auto creds = freshGrant;
    creds.apiKey = "stored-key";
    creds.apiBase = "http://unused";
    auto dir = credsDir("stored", creds);
    scope (exit) cleanup(dir);
    auto api = serve([ok(responsesOk)]);
    // A closed mint port: minting would fail the chat.
    enum nowhere = "http://127.0.0.1:1";
    assert(hello(client(api.url, dir, endpoints(nowhere, nowhere))) == "hi", "the seeded key must skip the mint");
    assert(api.finish()[0].headers.toLower.canFind("authorization: bearer stored-key"));
}

// rust: providers/muse.rs::uses_a_literal_api_key_without_minting
unittest
{
    auto api = serve([ok(responsesOk)]);
    auto p = provider(api.url);
    p.apiKey = "env-key";
    auto c = new MuseClient(p, "/nonexistent-dir");
    assert(hello(c) == "hi");
    auto a = api.finish()[0];
    assert(a.path == "/responses" && a.headers.toLower.canFind("authorization: bearer env-key"));
}
