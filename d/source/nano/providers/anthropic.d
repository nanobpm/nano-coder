/// Anthropic Messages API.
module nano.providers.anthropic;

import std.json;
import std.format : format;
import std.string : stripRight;
import std.math : isNaN;
import nano.llm;
import nano.http;
import nano.config;

class AnthropicClient : LLMClient
{
    private ResolvedProvider p;

    this(ResolvedProvider p) { this.p = p; }

    string modelName() const { return p.model; }
    string providerName() const { return p.name; }

    private string[string] headers()
    {
        string[string] h;
        if (p.apiKey.length) h["x-api-key"] = p.apiKey;
        h["anthropic-version"] = "2023-06-01";
        foreach (k, v; p.config.headers) h[k] = v;
        return h;
    }

    JSONValue requestBody(const ref ChatRequest req, bool stream)
    {
        JSONValue b = ["model": p.model];
        b["max_tokens"] = req.maxTokens > 0 ? req.maxTokens : 32_000;
        string system;
        JSONValue[] msgs;
        foreach (m; req.messages)
        {
            final switch (m.role)
            {
                case Role.system:
                    system ~= (system.length ? "\n\n" : "") ~ m.content;
                    break;
                case Role.user:
                    push(msgs, "user", textBlock(m.content));
                    break;
                case Role.assistant:
                    JSONValue[] blocks;
                    if (m.content.length) blocks ~= textBlock(m.content);
                    foreach (c; m.toolCalls)
                    {
                        JSONValue tu = ["type": "tool_use", "id": c.id, "name": c.name];
                        tu["input"] = c.arguments;
                        blocks ~= tu;
                    }
                    if (blocks.length == 0) blocks ~= textBlock("(no content)");
                    foreach (bl; blocks) push(msgs, "assistant", bl);
                    break;
                case Role.tool:
                    JSONValue tr = ["type": "tool_result", "tool_use_id": m.toolCallId];
                    tr["content"] = m.content.length ? m.content : "(no output)";
                    if (m.isError) tr["is_error"] = true;
                    push(msgs, "user", tr);
                    break;
            }
        }
        if (system.length)
        {
            JSONValue sb = textBlock(system);
            sb["cache_control"] = ["type": "ephemeral"];
            b["system"] = [sb];
        }
        // Cache the conversation prefix up to the latest message.
        if (msgs.length)
        {
            auto last = &msgs[$ - 1]["content"].array[$ - 1];
            last.object["cache_control"] = JSONValue(["type": "ephemeral"]);
        }
        b["messages"] = msgs;
        if (req.tools.length)
        {
            JSONValue[] tools;
            foreach (t; req.tools)
            {
                JSONValue tj = ["name": t.name, "description": t.description];
                tj["input_schema"] = t.parameters;
                tools ~= tj;
            }
            b["tools"] = tools;
        }
        if (!isNaN(req.temperature)) b["temperature"] = req.temperature;
        if (stream) b["stream"] = true;
        if (p.config.extraBody.type == JSONType.object)
            foreach (k, v; p.config.extraBody.object) b[k] = v;
        foreach (d; p.config.dropParams) b.object.remove(d);
        return b;
    }

    private static JSONValue textBlock(string t)
    {
        return JSONValue(["type": "text", "text": t]);
    }

    /// Append a content block, merging consecutive same-role messages (the API
    /// requires alternation, and parallel tool results share one user turn).
    private static void push(ref JSONValue[] msgs, string role, JSONValue block)
    {
        if (msgs.length && msgs[$ - 1]["role"].str == role)
        {
            msgs[$ - 1]["content"].array ~= block;
            return;
        }
        JSONValue m = ["role": role];
        m["content"] = [block];
        msgs ~= m;
    }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto url = p.config.baseUrl.stripRight("/") ~ "/messages";
        auto what = format("%s chat request", p.name);
        if (!p.config.stream || sink is null)
        {
            auto text = postJson(url, headers(), requestBody(req, false), what, p.config.maxRetries, p.config.timeoutSecs);
            auto r = parseWhole(parseJSON(text));
            if (sink !is null)
            {
                if (r.reasoning.length) sink(true, r.reasoning);
                if (r.content.length) sink(false, r.content);
            }
            return r;
        }
        AnthropicStream st;
        st.sink = sink;
        postJson(url, headers(), requestBody(req, true), what, p.config.maxRetries, p.config.timeoutSecs,
                (string data) { st.event(data); });
        return st.finish();
    }

    static LLMResponse parseWhole(JSONValue j)
    {
        LLMResponse r;
        foreach (block; j["content"].array)
        {
            auto t = block["type"].str;
            if (t == "text") r.content ~= block["text"].str;
            else if (t == "thinking") r.reasoning ~= block["thinking"].str;
            else if (t == "tool_use")
            {
                ToolCall c = ToolCall(block["id"].str, block["name"].str);
                c.arguments = block["input"];
                r.toolCalls ~= c;
            }
        }
        if (auto s = "stop_reason" in j) if (s.type == JSONType.string) r.stopReason = s.str;
        if (auto u = "usage" in j) readUsage(*u, r.usage);
        return r;
    }

    string[] listModels()
    {
        Request req;
        req.method = "GET";
        req.url = p.config.baseUrl.stripRight("/") ~ "/models?limit=1000";
        req.headers = headers();
        string text;
        auto status = perform(req, text);
        if (status < 200 || status >= 300) throw new ApiError(status, text, p.name ~ " model list");
        string[] ids;
        foreach (m; parseJSON(text)["data"].array) ids ~= m["id"].str;
        return ids;
    }
}

private void readUsage(JSONValue u, ref TokenUsage usage)
{
    long get(string k) { auto v = k in u; return v && v.type == JSONType.integer ? v.integer : 0; }
    // input_tokens excludes cached reads/writes; report the full prompt size.
    auto input = get("input_tokens") + get("cache_read_input_tokens") + get("cache_creation_input_tokens");
    if (input) usage.inputTokens = input;
    if (auto c = get("cache_read_input_tokens")) usage.cachedInputTokens = c;
    if (auto o = get("output_tokens")) usage.outputTokens = o;
}

struct AnthropicStream
{
    StreamSink sink;
    LLMResponse r;
    private string[size_t] kinds, ids, names, inputs;
    private size_t[] order;

    void event(string data)
    {
        auto j = parseJSON(data);
        auto type = j["type"].str;
        switch (type)
        {
            case "message_start":
                if (auto u = "usage" in j["message"]) readUsage(*u, r.usage);
                break;
            case "content_block_start":
                auto idx = cast(size_t) j["index"].integer;
                auto b = j["content_block"];
                kinds[idx] = b["type"].str;
                if (kinds[idx] == "tool_use")
                {
                    order ~= idx;
                    ids[idx] = b["id"].str;
                    names[idx] = b["name"].str;
                    inputs[idx] = "";
                }
                break;
            case "content_block_delta":
                auto idx = cast(size_t) j["index"].integer;
                auto d = j["delta"];
                switch (d["type"].str)
                {
                    case "text_delta":
                        r.content ~= d["text"].str;
                        sink(false, d["text"].str);
                        break;
                    case "thinking_delta":
                        r.reasoning ~= d["thinking"].str;
                        sink(true, d["thinking"].str);
                        break;
                    case "input_json_delta":
                        inputs[idx] ~= d["partial_json"].str;
                        break;
                    default:
                        break;
                }
                break;
            case "message_delta":
                if (auto d = "delta" in j)
                    if (auto s = "stop_reason" in *d) if (s.type == JSONType.string) r.stopReason = s.str;
                if (auto u = "usage" in j) readUsage(*u, r.usage);
                break;
            case "error":
                throw new Exception("anthropic stream error: " ~ j["error"].toString);
            default:
                break;
        }
    }

    LLMResponse finish()
    {
        foreach (idx; order) r.toolCalls ~= ToolCall.fromRaw(ids[idx], names[idx], inputs[idx]);
        return r;
    }
}

unittest
{
    ResolvedProvider p;
    p.model = "claude";
    auto c = new AnthropicClient(p);
    auto msgs = [Message.system("sys"), Message.user("hi"),
        Message.assistant("ok", [ToolCall.fromRaw("t1", "bash", `{"command":"ls"}`), ToolCall.fromRaw("t2", "bash", `{}`)]),
        Message.toolResult("t1", "bash", "a"), Message.toolResult("t2", "bash", "b", true)];
    ChatRequest req;
    req.messages = msgs;
    auto b = c.requestBody(req, false);
    assert(b["system"][0]["text"].str == "sys");
    assert(b["messages"].array.length == 3);
    assert(b["messages"][1]["content"].array.length == 3);
    assert(b["messages"][2]["content"].array.length == 2 && b["messages"][2]["content"][1]["is_error"].boolean);
    assert("cache_control" in b["messages"][2]["content"][1]);
}

unittest
{
    AnthropicStream st;
    string shown;
    st.sink = (bool t, string x) { if (!t) shown ~= x; };
    foreach (ev; [
        `{"type":"message_start","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":100}}}`,
        `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
        `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}`,
        `{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"glob","input":{}}}`,
        `{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"pattern\":"}}`,
        `{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"*.d\"}"}}`,
        `{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}`,
    ])
        st.event(ev);
    auto r = st.finish();
    assert(shown == "Hi" && r.toolCalls[0].arguments["pattern"].str == "*.d");
    assert(r.usage.inputTokens == 105 && r.usage.outputTokens == 7 && r.stopReason == "tool_use");
}
