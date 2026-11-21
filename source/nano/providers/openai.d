/// OpenAI Chat Completions (and compatible servers: Ollama, vLLM, llama.cpp,
/// OpenRouter, ...), plus GitHub Copilot, which speaks the same API behind a
/// token exchange.
module nano.providers.openai;

@safe:

import nano.arith : toSize;
import nano.safeio : jsonText, jsonPretty;
import nano.clock : wallNow;

import std.json;
import std.format : format;
import std.string : stripRight, strip, startsWith, endsWith;
import std.math : isNaN;
import std.algorithm : canFind, sort;
import std.array : join;
import nano.llm;
import nano.http;
import nano.config;
import nano.thinking : chatFields;

class OpenAIClient : LLMClient, CapabilityProbe, KindedClient
{
    protected ResolvedProvider p;

    this(ResolvedProvider p) pure { this.p = p; }

    string modelName() pure const { return p.model; }
    string providerName() pure const { return p.name; }
    ProviderKind kind() pure const { return ProviderKind.openai; }

    protected string baseUrl() { return p.config.baseUrl.stripRight("/"); }

    protected string[string] headers(const ref ChatRequest req)
    {
        string[string] h;
        if (p.apiKey.length) h["Authorization"] = "Bearer " ~ p.apiKey;
        foreach (k, v; p.config.headers) h[k] = v;
        return h;
    }

    JSONValue requestBody(const ref ChatRequest req, bool stream)
    {
        JSONValue b = ["model": p.model];
        b["messages"] = encodeMessages(req);
        if (req.tools.length)
        {
            JSONValue[] tools;
            foreach (t; req.tools)
            {
                JSONValue fn = ["name": t.name, "description": t.description];
                fn["parameters"] = t.parameters;
                JSONValue tj = ["type": "function"];
                tj["function"] = fn;
                tools ~= tj;
            }
            b["tools"] = tools;
        }
        if (req.maxTokens > 0)
            b[p.config.maxTokensParam.length ? p.config.maxTokensParam : "max_tokens"] = req.maxTokens;
        if (!isNaN(req.temperature)) b["temperature"] = req.temperature;
        if (stream)
        {
            b["stream"] = true;
            b["stream_options"] = ["include_usage": true];
        }
        foreach (k, v; chatFields(req.thinking)) b[k] = v;
        p.config.finishBody(b);
        return b;
    }

    static JSONValue encode(const ref Message m, bool replayReasoning = false) pure
    {
        JSONValue j = ["role": roleName(m.role)];
        final switch (m.role)
        {
            case Role.system, Role.user:
                j["content"] = m.content;
                break;
            case Role.assistant:
                if (m.toolCalls.length)
                {
                    j["content"] = m.content.length ? JSONValue(m.content) : JSONValue(null);
                    JSONValue[] calls;
                    foreach (c; m.toolCalls)
                    {
                        JSONValue fn = ["name": c.name, "arguments": c.encodedArguments];
                        JSONValue cj = ["id": c.id, "type": "function"];
                        cj["function"] = fn;
                        calls ~= cj;
                    }
                    j["tool_calls"] = calls;
                }
                else j["content"] = m.content;
                break;
            case Role.tool:
                j["tool_call_id"] = m.toolCallId;
                j["content"] = m.content;
                break;
        }
        if (replayReasoning && m.role == Role.assistant)
        {
            string reasoning;
            foreach (ref b; m.thinkingBlocks)
                if (b.type == JSONType.object && "type" in b && b["type"].type == JSONType.string
                        && b["type"].str == "reasoning_content" && "text" in b && b["text"].type == JSONType.string)
                    reasoning ~= b["text"].str;
            if (reasoning.length) j["reasoning_content"] = reasoning;
        }
        return j;
    }

    /// A `thinking_blocks` entry holding `reasoning_content` for replay.
    static JSONValue reasoningBlock(string text) pure
    {
        return JSONValue(["type": "reasoning_content", "text": text]);
    }

    /// Chat Completions messages. `tool` messages carry only text, so a tool
    /// result's images go in one `user` message after the run of tool
    /// results (as `image_url` parts); omitted ones become placeholder text.
    JSONValue[] encodeMessages(const ref ChatRequest req)
    {
        JSONValue[] out_;
        JSONValue[] pending;
        void flush()
        {
            if (!pending.length) return;
            JSONValue[] content = [JSONValue(["type": "text", "text": "[attached image]"])];
            content ~= pending;
            out_ ~= JSONValue(["role": JSONValue("user"), "content": JSONValue(content)]);
            pending = null;
        }
        auto plan = req.attachmentPlan();
        foreach (i, m; req.messages)
        {
            if (m.role != Role.tool) flush();
            auto j = encode(m, p.replayReasoning);
            if (m.role == Role.tool && m.attachments.length)
            {
                string content = m.content;
                bool added;
                foreach (r; req.resolveAttachments(i, plan))
                {
                    if (r.isImage)
                    {
                        JSONValue part = ["type": "image_url"];
                        part["image_url"] = ["url": "data:" ~ r.image.mediaType ~ ";base64," ~ r.image.dataBase64];
                        pending ~= part;
                        added = true;
                    }
                    else content ~= "\n" ~ r.text;
                }
                // Says *its own* image follows, after the whole tool-result run.
                j["content"] = added ? content ~ "\n[image attached after the tool results]" : content;
            }
            out_ ~= j;
        }
        flush();
        return out_;
    }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto url = baseUrl ~ "/chat/completions";
        auto what = format("%s chat request", p.name);
        if (!p.config.stream || sink is null)
        {
            auto text = postProvider(url, headers(req), requestBody(req, false), what, p.config);
            auto r = parseWhole(parseJSON(text), p.replayReasoning);
            if (sink !is null)
            {
                if (r.reasoning.length) sink(true, r.reasoning);
                if (r.content.length) sink(false, r.content);
            }
            return r;
        }
        StreamState st;
        st.sink = sink;
        st.replay = p.replayReasoning;
        auto whole = postStream(st, url, headers(req), requestBody(req, true), what, p.config);
        if (whole !is null) return reportWhole(parseWhole(parseJSON(whole), p.replayReasoning), sink);
        return st.finish();
    }

    static LLMResponse parseWhole(JSONValue j, bool replay = false)
    {
        LLMResponse r;
        if (auto e = "error" in j) throw new Exception("provider error: " ~ e.jsonText);
        auto choice = j["choices"][0];
        auto msg = choice["message"];
        if (auto c = "content" in msg) if (c.type == JSONType.string) r.content = c.str;
        // `reasoning_content` (DeepSeek, llama.cpp, vLLM), else `reasoning`.
        foreach (key; ["reasoning_content", "reasoning"])
            if (auto c = key in msg)
                if (c.type == JSONType.string && c.str.length) { r.reasoning ~= c.str; break; }
        // Replay echoes only the provider's actual `reasoning_content`.
        if (replay)
            if (auto c = "reasoning_content" in msg)
                if (c.type == JSONType.string && c.str.length) r.thinkingBlocks ~= reasoningBlock(c.str);
        if (auto calls = "tool_calls" in msg)
            if (calls.type == JSONType.array)
                foreach (c; calls.arrayNoRef)
                    r.toolCalls ~= ToolCall.fromRaw(c["id"].str, c["function"]["name"].str, c["function"]["arguments"].str);
        if (auto f = "finish_reason" in choice) if (f.type == JSONType.string) r.stopReason = f.str;
        if (auto u = "usage" in j) { readUsage(*u, r.usage); readCopilotAic(j, r.usage); }
        splitThink(r);
        return r;
    }

    /// Models that put `<think>` in content: move it to reasoning.
    static void splitThink(ref LLMResponse r)
    {
        import std.string : indexOf;
        if (r.content.indexOf("<think>") < 0) return;
        auto parts = ThinkSplitter.splitAll(r.content);
        r.content = parts[0];
        r.reasoning ~= parts[1];
    }

    /// GET/POST `url` with a short timeout; null on any failure.
    private JSONValue probe(string url, string body_ = null)
    {
        import core.time : seconds;
        Request req;
        req.method = body_ is null ? "GET" : "POST";
        req.url = url;
        ChatRequest none;
        req.headers = headers(none);
        if (body_ !is null) { req.headers["Content-Type"] = "application/json"; req.body_ = body_; }
        req.connectTimeout = 3.seconds;
        req.idleTimeout = 3.seconds;
        try
        {
            string text;
            auto status = perform(req, text);
            if (status < 200 || status >= 300) return JSONValue.init;
            return parseJSON(text);
        }
        catch (Exception) return JSONValue.init; // a failed probe means "unknown"; the caller keeps its defaults
    }

    /// Whether probing is worth a startup round trip: Copilot, or a local
    /// server (Ollama, llama.cpp, LM Studio, or any loopback endpoint).
    protected bool shouldProbe() pure
    {
        import nano.vision : baseUrlHost;
        auto host = baseUrlHost(p.config.baseUrl);
        return p.name == "ollama" || p.name == "llamacpp" || p.name == "lmstudio"
            || host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]";
    }

    /// Copilot reads its window from `capabilities.limits` instead.
    protected bool copilotLimits() pure { return false; }

    /// Thinking levels and vision from `/models`, then (by server) llama.cpp
    /// `/props` or Ollama `/api/show` (port of `detect_capabilities`).
    Capabilities probeCapabilities()
    {
        import nano.thinking : Reported;
        import nano.vision : Vision;
        import std.uri : encodeComponent;
        Capabilities c;
        if (!shouldProbe()) return c;
        auto base = baseUrl;
        auto root = base.length > 3 && base[$ - 3 .. $] == "/v1" ? base[0 .. $ - 3] : base;
        auto entry = modelEntry(probe(base ~ "/models"), p.model, !copilotLimits);
        if (entry.type == JSONType.object)
        {
            c.thinking = Reported.fromModelEntry(entry);
            c.vision = Vision.fromModelEntry(entry);
            if (copilotLimits) copilotWindow(entry, c);
            else
            {
                c.maxOutput = outputLimitInEntry(entry);
                windowInEntry(entry, c);
            }
        }
        string owner;
        if (entry.type == JSONType.object)
            if (auto o = "owned_by" in entry) if (o.type == JSONType.string) owner = o.str;
        if (copilotLimits) return c;
        if (owner == "llamacpp" || p.name == "llamacpp")
        {
            auto props = probe(root ~ "/props?model=" ~ encodeComponent(p.model));
            if (c.thinking.isNull) c.thinking = Reported.fromLlamacppProps(props);
            if (c.vision.isNull) c.vision = Vision.fromLlamacppProps(props);
            if (!c.window)
            {
                auto n = tokensAt(props, ["default_generation_settings", "n_ctx"]);
                if (!n) n = tokensAt(props, ["n_ctx"]);
                if (n) { c.window = n; c.windowSource = "llama.cpp /props n_ctx"; }
            }
        }
        else if (p.name == "ollama" || root.endsWith(":11434") || owner == "library" || owner == "ollama")
        {
            auto show = probe(root ~ "/api/show", JSONValue(["model": p.model]).jsonText);
            if (c.thinking.isNull) c.thinking = Reported.fromOllamaShow(show);
            if (c.vision.isNull) c.vision = Vision.fromOllamaShow(show);
            if (!c.window) ollamaWindow(probe(root ~ "/api/ps"), show, p.model, c);
        }
        else if (!c.window && (p.name == "lmstudio" || root.endsWith(":1234")))
        {
            auto listed = modelEntry(probe(root ~ "/api/v0/models"), p.model);
            if (auto n = tokensAt(listed, ["loaded_context_length"]))
            {
                c.window = n;
                c.windowSource = "LM Studio loaded_context_length";
            }
        }
        return c;
    }

    string[] listModels()
    {
        Request req;
        req.method = "GET";
        req.url = baseUrl ~ "/models";
        ChatRequest none;
        req.headers = headers(none);
        string text;
        auto status = perform(req, text);
        if (status < 200 || status >= 300) throw new ApiError(status, text, p.name ~ " model list");
        string[] ids;
        foreach (m; parseJSON(text)["data"].arrayNoRef) ids ~= m["id"].str;
        ids.sort();
        return ids;
    }
}

void readUsage(JSONValue u, ref TokenUsage usage) pure
{
    if (u.type != JSONType.object) return;
    if (auto v = "prompt_tokens" in u) if (v.type == JSONType.integer) usage.inputTokens = v.integer;
    if (auto v = "completion_tokens" in u) if (v.type == JSONType.integer) usage.outputTokens = v.integer;
    if (auto d = "prompt_tokens_details" in u)
        if (d.type == JSONType.object)
            if (auto v = "cached_tokens" in *d) if (v.type == JSONType.integer) usage.cachedInputTokens = v.integer;
}

/// Accumulates a streamed Chat Completions response.
struct StreamState
{
    StreamSink sink;
    LLMResponse r;
    ThinkSplitter think;
    string[size_t] ids, names, args;
    size_t[] order;
    /// Keep `reasoning_content` for replay.
    bool replay;
    string replayText;

    void event(string data)
    {
        if (data == "[DONE]") return;
        auto j = parseJSON(data);
        if (auto e = "error" in j) throw new Exception("provider stream error: " ~ e.jsonText);
        if (auto u = "usage" in j) { readUsage(*u, r.usage); readCopilotAic(j, r.usage); }
        auto choices = "choices" in j;
        if (choices is null || choices.type != JSONType.array || choices.arrayNoRef.length == 0) return;
        auto c = choices.arrayNoRef[0];
        if (auto f = "finish_reason" in c) if (f.type == JSONType.string) r.stopReason = f.str;
        auto delta = "delta" in c;
        if (delta is null || delta.type != JSONType.object) return;
        foreach (key; ["reasoning_content", "reasoning"])
            if (auto v = key in *delta)
                if (v.type == JSONType.string && v.str.length)
                {
                    r.reasoning ~= v.str;
                    if (key == "reasoning_content") replayText ~= v.str;
                    sink(true, v.str);
                    break;
                }
        if (auto v = "content" in *delta)
            if (v.type == JSONType.string && v.str.length)
                think.push(v.str, (bool t, string x) { emit(t, x); });
        if (auto calls = "tool_calls" in *delta)
            if (calls.type == JSONType.array)
                foreach (tc; calls.arrayNoRef)
                {
                    size_t idx = "index" in tc ? toSize(tc["index"].integer) : order.length;
                    if (idx !in args) { order ~= idx; args[idx] = ""; names[idx] = ""; ids[idx] = ""; }
                    if (auto id = "id" in tc) if (id.type == JSONType.string) ids[idx] = id.str;
                    if (auto fn = "function" in tc)
                    {
                        if (auto n = "name" in *fn) if (n.type == JSONType.string) names[idx] ~= n.str;
                        if (auto a = "arguments" in *fn) if (a.type == JSONType.string) args[idx] ~= a.str;
                    }
                }
    }

    void emit(bool thinking, string text)
    {
        import std.string : stripLeft;
        // Drop the blank lines that usually follow `</think>`, but only when
        // thinking preceded this content: otherwise leading whitespace is
        // real (a continuation resuming mid-line, Rust #114).
        if (!thinking && !r.content.length && r.reasoning.length) text = text.stripLeft;
        if (!text.length) return;
        if (thinking) r.reasoning ~= text; else r.content ~= text;
        sink(thinking, text);
    }

    LLMResponse finish()
    {
        import std.string : strip;
        think.finish((bool t, string x) { emit(t, x); });
        r.reasoning = r.reasoning.strip;
        foreach (n, idx; order)
        {
            auto id = ids[idx].length ? ids[idx] : format("call_%s", n);
            r.toolCalls ~= ToolCall.fromRaw(id, names[idx], args[idx]);
        }
        if (replay && replayText.length) r.thinkingBlocks ~= OpenAIClient.reasoningBlock(replayText);
        return r;
    }
}

/// GitHub Copilot: exchanges the stored OAuth token for a short-lived session
/// token, then speaks Chat Completions with editor headers.
class CopilotClient : OpenAIClient
{
    import nano.copilot : Endpoints, SessionToken, editorHeaders;

    private string oauth;
    /// Where the OAuth token is exchanged (tests point this at a mock).
    Endpoints endpoints;
    private SessionToken session;
    private bool forceRefresh;

    override ProviderKind kind() pure const { return ProviderKind.githubCopilot; }

    this(ResolvedProvider p)
    {
        import nano.copilot : domain, loadCredentials, StoredCredentials;
        super(p);
        auto d = domain();
        // `api_key` (GITHUB_COPILOT_OAUTH_TOKEN by default), else the saved
        // login for this domain.
        oauth = p.apiKey;
        StoredCredentials c;
        if (!oauth.length && loadCredentials(c) && c.domain == d) oauth = c.oauthToken;
        if (!oauth.length)
            throw new Exception("not logged in to GitHub Copilot: run `nano-coder --login github-copilot` "
                ~ "or set GITHUB_COPILOT_OAUTH_TOKEN");
        endpoints = Endpoints.forDomain(d);
    }

    private void ensureToken()
    {
        import nano.copilot : exchange;
        import std.datetime.systime : Clock;
        if (!forceRefresh && session.token.length && wallNow.toUnixTime < session.refreshAt) return;
        session = exchange(endpoints, oauth);
        forceRefresh = false;
    }

    /// A configured `base_url` wins over the session's endpoint.
    private string apiBase() pure
    {
        return p.config.baseUrl.length ? p.config.baseUrl.stripRight("/") : session.baseUrl;
    }

    override protected bool shouldProbe() pure { return true; }

    override protected bool copilotLimits() pure { return true; }

    override protected string baseUrl()
    {
        ensureToken();
        return apiBase();
    }

    override protected string[string] headers(const ref ChatRequest req)
    {
        ensureToken();
        string[string] h;
        foreach (e; editorHeaders) h[e[0]] = e[1];
        h["Authorization"] = "Bearer " ~ session.token;
        h["Openai-Intent"] = "conversation-edits";
        // The last message decides who initiated this request: a tool result
        // or an auto-initiated nudge (a continuation, a timer) is the agent
        // continuing; anything else is a billed user turn.
        bool agent = req.messages.length
            && (req.messages[$ - 1].role == Role.tool || req.messages[$ - 1].autoInitiated);
        h["X-Initiator"] = agent ? "agent" : "user";
        if (req.attachmentPlan().carriesImage) h["Copilot-Vision-Request"] = "true";
        foreach (k, v; p.config.headers) h[k] = v;
        return h;
    }

    /// Copilot serves each model family through one API; calling the wrong
    /// one fails with `unsupported_api_for_model`.
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        // A revoked or early-expired session token: re-exchange once.
        try return route(req, sink);
        catch (ApiError e)
        {
            if (e.status != 401) throw e;
            forceRefresh = true;
            return route(req, sink);
        }
    }

    private LLMResponse route(const ref ChatRequest req, StreamSink sink)
    {
        import nano.copilot : CopilotApi, apiForModel, path;
        auto api = apiForModel(p.model);
        if (api == CopilotApi.completions) return super.chat(req, sink);
        auto url = baseUrl ~ path(api);
        auto h = headers(req);
        auto what = format("%s chat request", p.name);
        bool stream = p.config.stream && sink !is null;
        if (api == CopilotApi.responses)
        {
            import nano.providers.responses : responsesBody, parseResponses, ResponsesStream;
            auto body_ = responsesBody(req, p, stream);
            if (!stream)
                return reportWhole(parseResponses(parseJSON(postProvider(url, h, body_, what, p.config)),
                    p.replayReasoning), sink);
            ResponsesStream st;
            st.sink = sink;
            st.replay = p.replayReasoning;
            auto whole = postStream(st, url, h, body_, what, p.config);
            if (whole !is null) return reportWhole(parseResponses(parseJSON(whole), p.replayReasoning), sink);
            return st.finish();
        }
        import nano.providers.anthropic : AnthropicClient, AnthropicStream;
        h["anthropic-version"] = "2023-06-01";
        auto body_ = new AnthropicClient(p).requestBody(req, stream);
        if (!stream)
            return reportWhole(AnthropicClient.parseWhole(parseJSON(postProvider(url, h, body_, what, p.config))), sink);
        AnthropicStream st;
        st.sink = sink;
        auto whole = postStream(st, url, h, body_, what, p.config);
        if (whole !is null) return reportWhole(AnthropicClient.parseWhole(parseJSON(whole)), sink);
        return st.finish();
    }
}


// rust: providers/openai.rs::parses_copilot_aic_from_response
unittest
{
    StreamState st;
    string shown;
    st.sink = (bool t, string x) { if (!t) shown ~= x; };
    foreach (ev; [
        `{"choices":[{"delta":{"content":"Hel"}}]}`,
        `{"choices":[{"delta":{"content":"lo"}}]}`,
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"bash","arguments":"{\"comm"}}]}}]}`,
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}`,
        `{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":3},"copilot_usage":{"total_nano_aiu":11600000}}`,
        `[DONE]`,
    ])
        st.event(ev);
    auto r = st.finish();
    assert(shown == "Hello" && r.content == "Hello");
    assert(r.toolCalls.length == 1 && r.toolCalls[0].arguments["command"].str == "ls");
    assert(r.stopReason == "tool_calls" && r.usage.inputTokens == 10);
    assert(r.usage.hasAic && imported!"std.math".isClose(r.usage.aic, 0.0116));
}

// rust: providers/openai.rs::encodes_tool_round_trip_and_provider_overrides
unittest
{
    ResolvedProvider p;
    p.name = "x";
    p.model = "m";
    p.config.extraBody = parseJSON(`{"think":false}`);
    p.config.dropParams = ["temperature"];
    auto c = new OpenAIClient(p);
    auto msgs = [Message.user("hi"), Message.assistant("", [ToolCall.fromRaw("c1", "bash", `{"command":"ls"}`)]),
        Message.toolResult("c1", "bash", "out")];
    ChatRequest req;
    req.messages = msgs;
    req.temperature = 0.5;
    auto b = c.requestBody(req, true);
    assert(b["think"].boolean == false && "temperature" !in b);
    assert(b["messages"][1]["tool_calls"][0]["function"]["arguments"].str == `{"command":"ls"}`);
    assert(b["messages"][2]["tool_call_id"].str == "c1");
}

// rust: providers/openai.rs::replay_ignores_generic_reasoning_field
// rust: providers/openai.rs::replays_reasoning_content_when_enabled
unittest
{
    // With replay on, streamed `reasoning_content` is kept and sent back on
    // the assistant message; the generic `reasoning` field never is.
    StreamState st;
    st.sink = (bool t, string x) {};
    st.replay = true;
    st.event(`{"choices":[{"delta":{"role":"assistant","reasoning_content":"Need ls."}}]}`);
    st.event(`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"bash","arguments":"{}"}}]}}]}`);
    auto r = st.finish();
    assert(r.thinkingBlocks == [parseJSON(`{"type":"reasoning_content","text":"Need ls."}`)]);
    auto m = Message.assistant("", r.toolCalls);
    m.thinkingBlocks = r.thinkingBlocks;
    assert(OpenAIClient.encode(m, true)["reasoning_content"].str == "Need ls.");
    assert("reasoning_content" !in OpenAIClient.encode(m, false));

    StreamState off;
    off.sink = (bool t, string x) {};
    off.event(`{"choices":[{"delta":{"reasoning":"hm"}}]}`);
    auto r2 = off.finish();
    assert(r2.reasoning == "hm" && r2.thinkingBlocks.length == 0);
    auto w = OpenAIClient.parseWhole(parseJSON(`{"choices":[{"message":{"content":"x","reasoning_content":"a","reasoning":"b"}}]}`), true);
    assert(w.reasoning == "a" && w.thinkingBlocks.length == 1);
}

/// The `/models` entry for `model`; a server listing a single model (such
/// as ds4, which accepts aliases) is taken to be serving it.
JSONValue modelEntry(JSONValue models, string model, bool onlyFallback = true) pure
{
    JSONValue items = models;
    if (models.type == JSONType.object)
    {
        auto d = "data" in models.objectNoRef;
        if (d is null) return JSONValue.init;
        items = *d;
    }
    if (items.type != JSONType.array) return JSONValue.init;
    foreach (m; items.arrayNoRef)
        if (m.type == JSONType.object)
            if (auto id = "id" in m.objectNoRef)
                if (id.type == JSONType.string && id.str == model) return m;
    // A local server listing one model (llama.cpp names it after the file)
    // serves that model; Copilot's catalogue must match exactly.
    return onlyFallback && items.arrayNoRef.length == 1 ? items.arrayNoRef[0] : JSONValue.init;
}

/// A positive integer at `path` that fits a signed token budget, else 0.
size_t tokensAt(JSONValue v, string[] path) pure
{
    foreach (k; path)
    {
        if (v.type != JSONType.object) return 0;
        auto n = k in v.objectNoRef;
        if (n is null) return 0;
        v = *n;
    }
    if (v.type == JSONType.integer && v.integer > 0) return toSize(v.integer);
    if (v.type == JSONType.uinteger && v.uinteger > 0 && v.uinteger <= long.max) return toSize(v.uinteger);
    return 0;
}

unittest
{
    import std.json : parseJSON;
    assert(tokensAt(parseJSON(`{"n": 9223372036854775808}`), ["n"]) == 0);
    assert(tokensAt(parseJSON(`{"n": 18446744073709551615}`), ["n"]) == 0);
    assert(tokensAt(parseJSON(`{"n": 9223372036854775807}`), ["n"]) == long.max);
    assert(tokensAt(parseJSON(`{"n": 4096}`), ["n"]) == 4096);
}

/// The window listed on a `/models` entry (vLLM, OpenRouter, Groq, Mistral, ...).
void windowInEntry(JSONValue entry, ref Capabilities c) pure
{
    static immutable string[][] paths = [["max_model_len"], ["loaded_context_length"], ["context_length"],
        ["top_provider", "context_length"], ["context_window"], ["max_context_length"]];
    foreach (path; paths)
        if (auto n = tokensAt(entry, path.dup))
        {
            c.window = n;
            c.windowSource = "/models " ~ path.join(".");
            return;
        }
}

/// The model's published output cap on its `/models` entry (0 = none).
size_t outputLimitInEntry(JSONValue entry) pure
{
    static immutable string[][] paths = [["max_output_tokens"], ["max_completion_tokens"],
        ["top_provider", "max_completion_tokens"], ["top_provider", "max_output_tokens"]];
    foreach (path; paths)
        if (auto n = tokensAt(entry, path.dup)) return n;
    return 0;
}

/// Copilot: `max_prompt_tokens` caps the prompt alone (with the larger
/// `max_context_window_tokens` as a second, combined limit).
void copilotWindow(JSONValue entry, ref Capabilities c) pure
{
    auto limit = (string f) => tokensAt(entry, ["capabilities", "limits", f]);
    auto prompt = limit("max_prompt_tokens"), combined = limit("max_context_window_tokens");
    c.maxOutput = limit("max_output_tokens");
    if (prompt)
    {
        c.window = prompt;
        c.windowSource = "Copilot /models max_prompt_tokens";
        c.promptCap = true;
        c.totalWindow = combined;
    }
    else if (combined)
    {
        c.window = combined;
        c.windowSource = "Copilot /models max_context_window_tokens";
    }
}

/// Ollama: the loaded model's context from `/api/ps`, else `num_ctx` from
/// the model's parameters (the model's maximum is not what Ollama runs with).
void ollamaWindow(JSONValue ps, JSONValue show, string model, ref Capabilities c) pure
{
    import std.string : lineSplitter, strip;
    import std.algorithm : startsWith;
    import std.conv : to;
    bool same(string n) { return n == model || n == model ~ ":latest"; }
    if (ps.type == JSONType.object)
        if (auto ms = "models" in ps.objectNoRef)
            if (ms.type == JSONType.array)
                foreach (m; ms.arrayNoRef)
                {
                    bool hit;
                    foreach (k; ["name", "model"])
                        if (m.type == JSONType.object)
                            if (auto v = k in m.objectNoRef) if (v.type == JSONType.string && same(v.str)) hit = true;
                    if (!hit) continue;
                    if (auto n = tokensAt(m, ["context_length"]))
                    {
                        c.window = n;
                        c.windowSource = "Ollama /api/ps context_length";
                        return;
                    }
                    break;
                }
    if (show.type != JSONType.object) return;
    auto params = "parameters" in show.objectNoRef;
    if (params is null || params.type != JSONType.string) return;
    foreach (line; params.str.lineSplitter)
    {
        auto l = line.strip;
        if (!l.startsWith("num_ctx")) continue;
        try
        {
            auto n = l["num_ctx".length .. $].strip.to!size_t;
            if (n > 0) { c.window = n; c.windowSource = "Ollama num_ctx"; return; }
        }
        catch (Exception) {} // a non-numeric num_ctx: fall back to the other window sources
    }
}

// rust: providers/openai.rs::detects_window_from_models_listing
// rust: providers/openai.rs::ollama_ps_window_survives_a_failed_show_probe
// rust: providers/openai.rs::uses_ollama_num_ctx_not_the_model_maximum
unittest
{
    Capabilities c;
    auto e = modelEntry(parseJSON(`{"data":[{"id":"other","max_model_len":1},{"id":"q","owned_by":"vllm","max_model_len":32768}]}`), "q");
    windowInEntry(e, c);
    assert(c.window == 32768 && c.windowSource == "/models max_model_len");
    c = Capabilities.init;
    windowInEntry(modelEntry(parseJSON(`{"data":[{"id":"x","top_provider":{"context_length":8192,"max_completion_tokens":4000}}]}`), "y"), c);
    assert(c.window == 8192 && c.windowSource == "/models top_provider.context_length");
    assert(outputLimitInEntry(parseJSON(`{"top_provider":{"max_completion_tokens":4000}}`)) == 4000);
    c = Capabilities.init;
    copilotWindow(parseJSON(`{"capabilities":{"limits":{"max_prompt_tokens":111,"max_context_window_tokens":200,"max_output_tokens":16000}}}`), c);
    assert(c.window == 111 && c.promptCap && c.totalWindow == 200 && c.maxOutput == 16000);
    c = Capabilities.init;
    ollamaWindow(parseJSON(`{"models":[{"name":"qwen3:8b","context_length":8192}]}`), JSONValue.init, "qwen3:8b", c);
    assert(c.window == 8192 && c.windowSource == "Ollama /api/ps context_length");
    c = Capabilities.init;
    ollamaWindow(JSONValue.init, parseJSON(`{"parameters":"temperature 0.6\nnum_ctx                        16384"}`), "qwen3:8b", c);
    assert(c.window == 16384 && c.windowSource == "Ollama num_ctx");
}
