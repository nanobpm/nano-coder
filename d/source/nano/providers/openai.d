/// OpenAI Chat Completions (and compatible servers: Ollama, vLLM, llama.cpp,
/// OpenRouter, ...), plus GitHub Copilot, which speaks the same API behind a
/// token exchange.
module nano.providers.openai;

import std.json;
import std.format : format;
import std.string : stripRight, strip, startsWith, endsWith;
import std.math : isNaN;
import std.algorithm : canFind, sort;
import nano.llm;
import nano.http;
import nano.config;
import nano.thinking : applyChat, applyAnthropic;

class OpenAIClient : LLMClient, CapabilityProbe
{
    protected ResolvedProvider p;

    this(ResolvedProvider p) { this.p = p; }

    string modelName() const { return p.model; }
    string providerName() const { return p.name; }

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
        applyChat(req.thinking, b);
        p.config.finishBody(b);
        return b;
    }

    static JSONValue encode(const ref Message m)
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
        return j;
    }

    /// Chat Completions messages. `tool` messages carry only text, so a tool
    /// result's images go in one `user` message after the run of tool
    /// results (as `image_url` parts); omitted ones become placeholder text.
    JSONValue[] encodeMessages(const ref ChatRequest req) @trusted
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
            auto j = encode(m);
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
            auto text = postJson(url, headers(req), requestBody(req, false), what, p.config.maxRetries, p.config.timeoutSecs);
            auto r = parseWhole(parseJSON(text));
            if (sink !is null)
            {
                if (r.reasoning.length) sink(true, r.reasoning);
                if (r.content.length) sink(false, r.content);
            }
            return r;
        }
        StreamState st;
        st.sink = sink;
        postJson(url, headers(req), requestBody(req, true), what, p.config.maxRetries, p.config.timeoutSecs,
                (string data) { st.event(data); });
        return st.finish();
    }

    static LLMResponse parseWhole(JSONValue j)
    {
        LLMResponse r;
        if (auto e = "error" in j) throw new Exception("provider error: " ~ e.toString);
        auto choice = j["choices"][0];
        auto msg = choice["message"];
        if (auto c = "content" in msg) if (c.type == JSONType.string) r.content = c.str;
        foreach (key; ["reasoning_content", "reasoning"])
            if (auto c = key in msg) if (c.type == JSONType.string) r.reasoning ~= c.str;
        if (auto calls = "tool_calls" in msg)
            if (calls.type == JSONType.array)
                foreach (c; calls.array)
                    r.toolCalls ~= ToolCall.fromRaw(c["id"].str, c["function"]["name"].str, c["function"]["arguments"].str);
        if (auto f = "finish_reason" in choice) if (f.type == JSONType.string) r.stopReason = f.str;
        if (auto u = "usage" in j) readUsage(*u, r.usage);
        splitThink(r);
        return r;
    }

    /// Models that put `<think>` in content: move it to reasoning.
    static void splitThink(ref LLMResponse r)
    {
        import std.string : indexOf;
        if (r.content.indexOf("<think>") < 0) return;
        string said, thought;
        ThinkSplitter s;
        void emit(bool t, string x) { if (t) thought ~= x; else said ~= x; }
        s.push(r.content, &emit);
        s.finish(&emit);
        r.content = said.strip;
        r.reasoning ~= thought;
    }

    /// GET/POST `url` with a short timeout; null on any failure.
    private JSONValue probe(string url, string body_ = null) @trusted
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
        catch (Exception) return JSONValue.init;
    }

    /// Whether probing is worth a startup round trip: Copilot, or a local
    /// server (Ollama, llama.cpp, LM Studio, or any loopback endpoint).
    protected bool shouldProbe()
    {
        import nano.vision : baseUrlHost;
        auto host = baseUrlHost(p.config.baseUrl);
        return p.name == "ollama" || p.name == "llamacpp" || p.name == "lmstudio"
            || host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]";
    }

    /// Thinking levels and vision from `/models`, then (by server) llama.cpp
    /// `/props` or Ollama `/api/show` (port of `detect_capabilities`).
    Capabilities probeCapabilities() @trusted
    {
        import nano.thinking : Reported;
        import nano.vision : Vision;
        import std.uri : encodeComponent;
        Capabilities c;
        if (!shouldProbe()) return c;
        auto base = baseUrl;
        auto root = base.length > 3 && base[$ - 3 .. $] == "/v1" ? base[0 .. $ - 3] : base;
        auto models = probe(base ~ "/models");
        JSONValue entry;
        if (models.type == JSONType.object)
            if (auto d = "data" in models)
                if (d.type == JSONType.array)
                    foreach (m; d.array)
                        if (m.type == JSONType.object)
                            if (auto id = "id" in m) if (id.type == JSONType.string && id.str == p.model) { entry = m; break; }
        if (entry.type == JSONType.object)
        {
            c.thinking = Reported.fromModelEntry(entry);
            c.vision = Vision.fromModelEntry(entry);
        }
        string owner;
        if (entry.type == JSONType.object)
            if (auto o = "owned_by" in entry) if (o.type == JSONType.string) owner = o.str;
        if (owner == "llamacpp" || p.name == "llamacpp")
        {
            auto props = probe(root ~ "/props?model=" ~ encodeComponent(p.model));
            if (c.thinking.isNull) c.thinking = Reported.fromLlamacppProps(props);
            if (c.vision.isNull) c.vision = Vision.fromLlamacppProps(props);
        }
        else if (p.name == "ollama" || root.endsWith(":11434") || owner == "library" || owner == "ollama")
        {
            auto show = probe(root ~ "/api/show", JSONValue(["model": p.model]).toString);
            if (c.thinking.isNull) c.thinking = Reported.fromOllamaShow(show);
            if (c.vision.isNull) c.vision = Vision.fromOllamaShow(show);
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
        foreach (m; parseJSON(text)["data"].array) ids ~= m["id"].str;
        ids.sort();
        return ids;
    }
}

void readUsage(JSONValue u, ref TokenUsage usage)
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

    void event(string data)
    {
        if (data == "[DONE]") return;
        auto j = parseJSON(data);
        if (auto e = "error" in j) throw new Exception("provider stream error: " ~ e.toString);
        if (auto u = "usage" in j) readUsage(*u, r.usage);
        auto choices = "choices" in j;
        if (choices is null || choices.type != JSONType.array || choices.array.length == 0) return;
        auto c = choices.array[0];
        if (auto f = "finish_reason" in c) if (f.type == JSONType.string) r.stopReason = f.str;
        auto delta = "delta" in c;
        if (delta is null || delta.type != JSONType.object) return;
        foreach (key; ["reasoning_content", "reasoning"])
            if (auto v = key in *delta)
                if (v.type == JSONType.string && v.str.length)
                {
                    r.reasoning ~= v.str;
                    sink(true, v.str);
                }
        if (auto v = "content" in *delta)
            if (v.type == JSONType.string && v.str.length)
                think.push(v.str, (bool t, string x) { emit(t, x); });
        if (auto calls = "tool_calls" in *delta)
            if (calls.type == JSONType.array)
                foreach (tc; calls.array)
                {
                    size_t idx = "index" in tc ? cast(size_t) tc["index"].integer : order.length;
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
        if (thinking) r.reasoning ~= text; else r.content ~= text;
        sink(thinking, text);
    }

    LLMResponse finish()
    {
        think.finish((bool t, string x) { emit(t, x); });
        foreach (n, idx; order)
        {
            auto id = ids[idx].length ? ids[idx] : format("call_%s", n);
            r.toolCalls ~= ToolCall.fromRaw(id, names[idx], args[idx]);
        }
        return r;
    }
}

/// GitHub Copilot: exchanges the stored OAuth token for a short-lived session
/// token, then speaks Chat Completions with editor headers.
class CopilotClient : OpenAIClient
{
    private string sessionToken;
    private string apiBase;
    private long refreshAt;

    this(ResolvedProvider p) { super(p); }

    static immutable string[2][] editorHeaders = [
        ["User-Agent", "GitHubCopilotChat/0.35.0"],
        ["Editor-Version", "vscode/1.107.0"],
        ["Editor-Plugin-Version", "copilot-chat/0.35.0"],
        ["Copilot-Integration-Id", "vscode-chat"],
    ];

    private static string oauthToken(out string domain)
    {
        import std.process : environment;
        import std.file : exists, readText;
        import std.path : buildPath, expandTilde;
        domain = "github.com";
        if (auto t = environment.get("GITHUB_COPILOT_OAUTH_TOKEN")) return t;
        foreach (path; [
            buildPath(expandTilde("~"), "Library", "Application Support", "nano-coder", "github-copilot.json"),
            buildPath(environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share")), "nano-coder", "github-copilot.json"),
        ])
            if (path.exists)
            {
                auto j = parseJSON(readText(path));
                if (auto d = "domain" in j) if (d.type == JSONType.string && d.str.length) domain = d.str;
                return j["oauth_token"].str;
            }
        throw new Exception("no GitHub Copilot login found; run `nano-coder --login github-copilot` (Rust build) or set GITHUB_COPILOT_OAUTH_TOKEN");
    }

    private void ensureToken()
    {
        import std.datetime.systime : Clock;
        auto now = Clock.currTime.toUnixTime;
        if (sessionToken.length && now < refreshAt) return;
        string domain;
        auto oauth = oauthToken(domain);
        Request req;
        req.method = "GET";
        req.url = format("https://api.%s/copilot_internal/v2/token", domain);
        foreach (h; editorHeaders) req.headers[h[0]] = h[1];
        req.headers["Accept"] = "application/json";
        req.headers["Authorization"] = "Bearer " ~ oauth;
        string text;
        auto status = perform(req, text);
        if (status < 200 || status >= 300) throw new ApiError(status, text, "Copilot token exchange");
        auto j = parseJSON(text);
        sessionToken = j["token"].str;
        refreshAt = ("expires_at" in j ? j["expires_at"].integer : now + 1500) - 120;
        apiBase = p.config.baseUrl.stripRight("/");
        if (auto e = "endpoints" in j)
            if (auto api = "api" in *e) apiBase = api.str.stripRight("/");
    }

    override protected bool shouldProbe() { return true; }

    override protected string baseUrl()
    {
        ensureToken();
        return apiBase;
    }

    override protected string[string] headers(const ref ChatRequest req)
    {
        ensureToken();
        string[string] h;
        foreach (e; editorHeaders) h[e[0]] = e[1];
        h["Authorization"] = "Bearer " ~ sessionToken;
        h["Openai-Intent"] = "conversation-edits";
        // The last message decides who initiated this request: a tool result
        // is the agent continuing, anything else is the user.
        h["X-Initiator"] = req.messages.length && req.messages[$ - 1].role == Role.tool ? "agent" : "user";
        if (req.attachmentPlan().carriesImage) h["Copilot-Vision-Request"] = "true";
        foreach (k, v; p.config.headers) h[k] = v;
        return h;
    }
}

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
        `{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":3}}`,
        `[DONE]`,
    ])
        st.event(ev);
    auto r = st.finish();
    assert(shown == "Hello" && r.content == "Hello");
    assert(r.toolCalls.length == 1 && r.toolCalls[0].arguments["command"].str == "ls");
    assert(r.stopReason == "tool_calls" && r.usage.inputTokens == 10);
}

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
