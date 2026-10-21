/// UNOFFICIAL Meta Muse Code client (`providers/muse.rs` `MuseClient`): the
/// OpenAI Responses API with a minted Meta API key and Muse's client headers.
module nano.providers.muse;

import nano.llm;
import nano.config;
import nano.http;
import nano.muse;
import nano.providers.responses : responsesBody, parseResponses, ResponsesStream;
import std.json;
import std.format : format;
import std.typecons : Nullable;
import std.algorithm : stripRight;

/// A live model-call credential: a minted key or `META_API_KEY`.
struct SessionKey
{
    string apiKey, baseUrl;
}

class MuseClient : LLMClient, CapabilityProbe
{
    private ResolvedProvider p;
    /// The OAuth grant to mint with; unset when `META_API_KEY` is the key.
    private OauthGrant grant;
    private bool haveGrant;
    private Nullable!SessionKey session;
    /// The catalog, keyed by the API base it was fetched for.
    private string catalogBase;
    private JSONValue catalog;
    /// Where to authenticate and mint (tests point this at a mock).
    Endpoints endpoints;
    /// Write rotated grants back to `muse.json` (off for synthetic grants).
    bool persist = true;
    /// The credentials dir (null: the platform data dir).
    string credentialsDir;

    this(ResolvedProvider p, string credentialsDir = null)
    {
        this.p = p;
        this.credentialsDir = credentialsDir;
        endpoints = Endpoints.fromEnv();
        if (p.apiKey.length) return;
        StoredCredentials c;
        if (!loadCredentials(c, credentialsDir))
            throw new Exception("not logged in to Muse Code: run `nano-coder-d --login muse` or set META_API_KEY");
        grant = c.grant;
        haveGrant = true;
        // Reuse the key the login minted; a 401 re-mints.
        if (c.apiKey.length) session = SessionKey(c.apiKey, c.apiBase.length ? c.apiBase : defaultApiBase);
    }

    string modelName() const { return p.model; }
    string providerName() const { return p.name; }

    private string configuredBase() const { return p.config.baseUrl.stripRight('/'); }

    /// The key for model calls: `META_API_KEY` outright, else the cached
    /// minted key, else a mint (renewing a stale OAuth token first).
    private SessionKey sessionKey(bool force)
    {
        if (p.apiKey.length) return SessionKey(p.apiKey, configuredBase.length ? configuredBase : defaultApiBase);
        if (!force && !session.isNull) return session.get;
        if (!haveGrant) throw new Exception("no Muse credentials");
        auto t = nowSecs();
        if (grant.needsRefresh(t))
        {
            // A peer client may already have renewed (and rotated) it.
            if (persist)
            {
                auto renewed = reloadRenewedGrant(grant, credentialsDir);
                if (!renewed.isNull) grant = renewed.get;
            }
            auto fresh = refreshGrant(endpoints, grant);
            if (!fresh.isNull)
            {
                if (persist) persistRotated(fresh.get, grant, credentialsDir);
                grant = fresh.get;
            }
        }
        auto minted = mint(endpoints, grant.accessToken, false);
        session = SessionKey(minted.apiKey, minted.baseUrl);
        return session.get;
    }

    private static long nowSecs() @trusted
    {
        import std.datetime.systime : Clock;
        return Clock.currTime.toUnixTime;
    }

    private string apiBase(const SessionKey s) const
    {
        return configuredBase.length ? configuredBase : s.baseUrl;
    }

    private string[string] headers(const SessionKey s)
    {
        string[string] h;
        foreach (k, v; p.config.headers) h[k] = v;
        h = withClientHeaders(h, p.config.headers);
        h["Authorization"] = "Bearer " ~ s.apiKey;
        return h;
    }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        bool stream = p.config.stream && sink !is null;
        auto body_ = responsesBody(req, p, stream);
        // A revoked or early-expired key: mint once more, then fail.
        try return call(body_, stream, sink, sessionKey(false));
        catch (ApiError e)
        {
            if (e.status != 401 || p.apiKey.length) throw e;
            return call(body_, stream, sink, sessionKey(true));
        }
    }

    private LLMResponse call(JSONValue body_, bool stream, StreamSink sink, SessionKey s)
    {
        auto url = apiBase(s) ~ "/responses";
        auto what = format("%s chat request", p.name);
        auto h = headers(s);
        if (!stream) return reportWhole(parseResponses(parseJSON(postProvider(url, h, body_, what, p.config)), p.replayReasoning), sink);
        ResponsesStream st;
        st.sink = sink;
        st.replay = p.replayReasoning;
        auto whole = postProvider(url, h, body_, what, p.config, (string data) { st.event(data); });
        if (whole !is null) return reportWhole(parseResponses(parseJSON(whole), p.replayReasoning), sink);
        return st.finish();
    }

    /// `GET {mint}/muse-code/models` with the key; ApiError on failure.
    private JSONValue fetchCatalog(const SessionKey s, bool probing) @trusted
    {
        import core.time : seconds;
        Request req;
        req.method = "GET";
        req.url = endpoints.catalog;
        req.headers = headers(s);
        req.headers["Accept"] = "application/json";
        req.headers["x-api-version"] = museApiVersion;
        if (probing)
        {
            req.connectTimeout = 3.seconds;
            req.idleTimeout = 3.seconds;
        }
        string text;
        auto status = perform(req, text);
        if (status < 200 || status >= 300) throw new ApiError(status, text, "Muse model catalog");
        return parseJSON(text);
    }

    /// The catalog, re-minting once on a 401 (an expired seeded key).
    private JSONValue catalogJson(bool probing)
    {
        auto s = sessionKey(false);
        if (catalogBase.length && catalogBase == apiBase(s)) return catalog;
        JSONValue v;
        try v = fetchCatalog(s, probing);
        catch (ApiError e)
        {
            if (e.status != 401 || p.apiKey.length) throw e;
            s = sessionKey(true);
            v = fetchCatalog(s, probing);
        }
        catalogBase = apiBase(s);
        catalog = v;
        return v;
    }

    string[] listModels() { return listableModels(catalogJson(false)); }

    /// Thinking levels and vision from the model's catalog row.
    Capabilities probeCapabilities() @trusted
    {
        import nano.thinking : Reported, Format;
        import nano.vision : Vision;
        Capabilities c;
        JSONValue row;
        try
        {
            foreach (r; catalogRows(catalogJson(true)))
                if (modelId(r) == p.model) { row = parseJSON(r.toString); break; }
        }
        catch (Exception) return c;
        if (row.type != JSONType.object) return c;
        c.thinking = Reported.fromModelEntry(row);
        if (c.thinking.isNull)
        {
            auto levels = effortLevels(row);
            if (levels.length) c.thinking = Reported(levels, false, Format.effort);
        }
        if (museVision(row)) c.vision = Vision.capable();
        {
            import nano.muse : contextLimit, outputLimit;
            c.maxOutput = cast(size_t) outputLimit(row);
            if (auto w = contextLimit(row))
            {
                c.window = cast(size_t) w;
                c.windowSource = "Muse /muse-code/models context_limit";
            }
        }
        return c;
    }
}
