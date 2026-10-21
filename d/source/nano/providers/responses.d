/// OpenAI Responses API (`POST {base}/responses`), from
/// `providers/openai_responses.rs`. Copilot routes GPT-5+, Grok, OSWE and MAI
/// models here: a flat `input` item list instead of `messages`, and an
/// `output` item list instead of `choices`.
module nano.providers.responses;

@safe:

import std.json;
import std.format : format;
import std.math : isNaN;
import std.string : join;
import nano.llm;
import nano.config : ResolvedProvider, reasonsOverResponses;
import thinking = nano.thinking;

private string strOf(const JSONValue v, string key) @trusted
{
    if (v.type != JSONType.object) return "";
    auto p = key in v.object;
    return p && p.type == JSONType.string ? p.str : "";
}

private string typeOf(const JSONValue v) { return strOf(v, "type"); }

/// The Responses request body for `req`, with provider overrides applied.
JSONValue responsesBody(const ref ChatRequest req, const ref ResolvedProvider p, bool stream) @trusted
{
    auto replay = p.replayReasoning;
    string[] instructions;
    JSONValue[] input;
    auto plan = req.attachmentPlan();
    foreach (i, ref m; req.messages)
    {
        final switch (m.role)
        {
            case Role.system:
                if (m.content.length) instructions ~= m.content;
                break;
            case Role.user:
                input ~= JSONValue(["role": "user", "content": m.content]);
                break;
            case Role.assistant:
                if (m.content.length) input ~= JSONValue(["role": "assistant", "content": m.content]);
                // Reasoning items go right before the calls they led to.
                if (replay)
                    foreach (ref b; m.thinkingBlocks)
                        if (typeOf(b) == "reasoning") input ~= parseJSON(b.toString);
                foreach (ref c; m.toolCalls)
                {
                    JSONValue fc = ["type": "function_call", "call_id": c.id, "name": c.name,
                        "arguments": c.encodedArguments];
                    if (c.itemId.length) fc["id"] = c.itemId;
                    input ~= fc;
                }
                break;
            case Role.tool:
                JSONValue item = ["type": "function_call_output", "call_id": m.toolCallId];
                auto resolved = m.attachments.length ? req.resolveAttachments(i, plan) : null;
                if (!resolved.length) item["output"] = m.content;
                else
                {
                    JSONValue[] output = [JSONValue(["type": "input_text", "text": m.content])];
                    foreach (r; resolved)
                        output ~= r.isImage
                            ? JSONValue(["type": "input_image",
                                "image_url": "data:" ~ r.image.mediaType ~ ";base64," ~ r.image.dataBase64])
                            : JSONValue(["type": "input_text", "text": r.text]);
                    item["output"] = output;
                }
                input ~= item;
                break;
        }
    }
    JSONValue b = ["model": p.model];
    b["input"] = input;
    if (replay)
    {
        // Ask for replayable reasoning and keep it out of server-side state.
        b["include"] = [JSONValue("reasoning.encrypted_content")];
        b["store"] = false;
    }
    if (instructions.length) b["instructions"] = instructions.join("\n\n");
    if (req.tools.length)
    {
        JSONValue[] tools;
        foreach (ref t; req.tools)
        {
            JSONValue tj = ["type": "function", "name": t.name, "description": t.description];
            tj["parameters"] = t.parameters;
            tools ~= tj;
        }
        b["tools"] = tools;
    }
    // Reasoning models reject a non-default temperature.
    if (!isNaN(req.temperature) && !reasonsOverResponses(p.config.kind, p.model)) b["temperature"] = req.temperature;
    if (req.maxTokens > 0) b["max_output_tokens"] = req.maxTokens;
    alias K = thinking.Request.Kind;
    if (req.thinking.kind == K.effort) b["reasoning"] = JSONValue(["effort": req.thinking.level]);
    else if (req.thinking.kind == K.off) b["reasoning"] = JSONValue(["effort": "none"]);
    if (stream) b["stream"] = true;
    p.config.finishBody(b);
    return b;
}

/// Text of a content-part list (refusals skipped).
private string partsText(const JSONValue content) @trusted
{
    string s;
    if (content.type == JSONType.array)
        foreach (ref part; content.array)
            if (typeOf(part) != "refusal") s ~= strOf(part, "text");
    return s;
}

private string reasoningText(const JSONValue item) @trusted
{
    string s;
    foreach (key; ["summary", "content"])
        if (auto v = key in item.object) s ~= partsText(*v);
    return s;
}

/// `incomplete` surfaces its nested reason (e.g. `max_output_tokens`).
private string stopReason(const JSONValue response) @trusted
{
    auto status = strOf(response, "status");
    if (status == "incomplete")
        if (auto d = "incomplete_details" in response.object)
        {
            auto r = strOf(*d, "reason");
            if (r.length) return r;
        }
    return status;
}

private void readUsage(const JSONValue u, ref TokenUsage usage) @trusted
{
    if (u.type != JSONType.object) return;
    if (auto v = "input_tokens" in u.object) if (v.type == JSONType.integer) usage.inputTokens = v.integer;
    if (auto v = "output_tokens" in u.object) if (v.type == JSONType.integer) usage.outputTokens = v.integer;
    if (auto d = "input_tokens_details" in u.object)
        if (d.type == JSONType.object)
            if (auto v = "cached_tokens" in d.object) if (v.type == JSONType.integer) usage.cachedInputTokens = v.integer;
}

private ToolCall callFrom(const JSONValue item, string raw) @trusted
{
    auto id = strOf(item, "call_id");
    if (!id.length) id = strOf(item, "id");
    auto c = ToolCall.fromRaw(id, strOf(item, "name"), raw);
    c.itemId = strOf(item, "id");
    return c;
}

/// Parse a whole (non-streamed) Responses payload.
LLMResponse parseResponses(JSONValue v, bool replay) @trusted
{
    if (strOf(v, "status") == "failed")
        throw new Exception("response failed: " ~ ("error" in v ? v["error"].toString : v.toString));
    auto output = "output" in v;
    if (output is null || output.type != JSONType.array) throw new Exception("response has no output: " ~ v.toString);
    LLMResponse r;
    foreach (item; output.array)
        switch (typeOf(item))
        {
            case "message":
                if (auto c = "content" in item) r.content ~= partsText(*c);
                break;
            case "reasoning":
                r.reasoning ~= reasoningText(item);
                if (replay) r.thinkingBlocks ~= item;
                break;
            case "function_call":
                r.toolCalls ~= callFrom(item, strOf(item, "arguments"));
                break;
            default:
                break;
        }
    if (auto u = "usage" in v) readUsage(*u, r.usage);
    r.stopReason = stopReason(v);
    return r;
}

/// Accumulates a streamed Responses payload.
struct ResponsesStream
{
    StreamSink sink;
    bool replay;
    LLMResponse r;
    private JSONValue[long] items;
    private string[long] args;
    private long[] order;

    void event(string data) @trusted
    {
        auto j = parseJSON(data);
        long index = "output_index" in j && j["output_index"].type == JSONType.integer ? j["output_index"].integer : 0;
        switch (typeOf(j))
        {
            case "response.output_text.delta":
                auto piece = strOf(j, "delta");
                r.content ~= piece;
                if (piece.length) sink(false, piece);
                break;
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                auto piece = strOf(j, "delta");
                r.reasoning ~= piece;
                if (piece.length) sink(true, piece);
                break;
            case "response.output_item.added":
                if (auto item = "item" in j)
                    if (typeOf(*item) == "function_call")
                    {
                        if (index !in items) { order ~= index; args[index] = ""; }
                        items[index] = *item;
                    }
                break;
            case "response.output_item.done":
                if (replay)
                    if (auto item = "item" in j)
                        if (typeOf(*item) == "reasoning") r.thinkingBlocks ~= *item;
                break;
            case "response.function_call_arguments.delta":
                if (index !in items) { order ~= index; items[index] = JSONValue(string[string].init); args[index] = ""; }
                args[index] ~= strOf(j, "delta");
                break;
            case "response.completed", "response.incomplete":
                if (auto resp = "response" in j)
                {
                    if (auto u = "usage" in *resp) readUsage(*u, r.usage);
                    auto s = stopReason(*resp);
                    if (s.length) r.stopReason = s;
                }
                break;
            case "response.failed":
                auto resp = "response" in j;
                throw new Exception("response failed: " ~ (resp && "error" in *resp ? (*resp)["error"].toString : j.toString));
            case "error", "response.error":
                throw new Exception("stream error: " ~ ("error" in j ? j["error"].toString : j.toString));
            default:
                break;
        }
    }

    LLMResponse finish() @trusted
    {
        import std.algorithm : sort;
        size_t position;
        foreach (idx; order.sort)
        {
            auto item = items[idx];
            if (!strOf(item, "name").length) continue;
            auto c = callFrom(item, args[idx]);
            if (!c.id.length) c.id = format("call_%s", position);
            r.toolCalls ~= c;
            position++;
        }
        return r;
    }
}

@trusted unittest
{
    import nano.config : ProviderKind;
    ResolvedProvider p;
    p.model = "gpt-5";
    p.config.kind = ProviderKind.githubCopilot;
    p.replayReasoning = true;
    auto call = ToolCall.fromRaw("call_1", "bash", `{"command":"ls"}`);
    call.itemId = "fc_1";
    auto reply = Message.assistant("", [call]);
    reply.thinkingBlocks = [parseJSON(`{"type":"reasoning","id":"rs_1","encrypted_content":"enc"}`),
        parseJSON(`{"type":"thinking","thinking":"x"}`)];
    ChatRequest req;
    req.messages = [Message.system("sys"), Message.user("hi"), reply, Message.toolResult("call_1", "bash", "out")];
    req.temperature = 0.3;
    req.maxTokens = 100;
    req.thinking.kind = thinking.Request.Kind.effort;
    req.thinking.level = "high";
    auto b = responsesBody(req, p, true);
    assert(b["instructions"].str == "sys");
    auto input = b["input"].array;
    assert(input.length == 4);
    assert(input[0]["role"].str == "user" && input[1]["type"].str == "reasoning");
    assert(input[2]["type"].str == "function_call" && input[2]["id"].str == "fc_1" && input[2]["call_id"].str == "call_1");
    assert(input[3]["type"].str == "function_call_output" && input[3]["output"].str == "out");
    assert(b["include"][0].str == "reasoning.encrypted_content" && b["store"].boolean == false);
    assert("temperature" !in b, "reasoning models reject temperature");
    assert(b["max_output_tokens"].integer == 100 && b["reasoning"]["effort"].str == "high" && b["stream"].boolean);

    // No replay: no reasoning items, include/store; a non-reasoning model keeps temperature.
    p.replayReasoning = false;
    p.model = "o4-mini";
    req.thinking.kind = thinking.Request.Kind.off;
    auto b2 = responsesBody(req, p, false);
    assert(b2["input"].array.length == 3 && "include" !in b2 && "stream" !in b2);
    assert(b2["temperature"].floating == 0.3 && b2["reasoning"]["effort"].str == "none");
}

@trusted unittest
{
    auto r = parseResponses(parseJSON(`{"status":"completed","output":[
        {"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Think."}]},
        {"type":"message","content":[{"type":"output_text","text":"Hi"},{"type":"refusal","refusal":"no"}]},
        {"type":"function_call","id":"fc_1","call_id":"call_1","name":"bash","arguments":"{\"command\":\"ls\"}"}],
        "usage":{"input_tokens":10,"output_tokens":5}}`), true);
    assert(r.content == "Hi" && r.reasoning == "Think." && r.thinkingBlocks.length == 1);
    assert(r.toolCalls[0].id == "call_1" && r.toolCalls[0].itemId == "fc_1" && r.toolCalls[0].arguments["command"].str == "ls");
    assert(r.usage.inputTokens == 10 && r.stopReason == "completed");
    auto inc = parseResponses(parseJSON(`{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}`), false);
    assert(inc.stopReason == "max_output_tokens");
    bool threw;
    try parseResponses(parseJSON(`{"status":"failed","error":{"message":"bad"},"output":[]}`), false);
    catch (Exception) threw = true;
    assert(threw);
}

@trusted unittest
{
    ResponsesStream st;
    string shown, thought;
    st.sink = (bool t, string x) { if (t) thought ~= x; else shown ~= x; };
    st.replay = true;
    foreach (e; [
        `{"type":"response.reasoning_summary_text.delta","output_index":0,"delta":"Plan."}`,
        `{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","encrypted_content":"e"}}`,
        `{"type":"response.output_text.delta","output_index":1,"delta":"Hel"}`,
        `{"type":"response.output_text.delta","output_index":1,"delta":"lo"}`,
        `{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","id":"fc_9","call_id":"call_9","name":"glob"}}`,
        `{"type":"response.function_call_arguments.delta","output_index":2,"delta":"{\"pattern\":"}`,
        `{"type":"response.function_call_arguments.delta","output_index":2,"delta":"\"*\"}"}`,
        `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":7,"output_tokens":3}}}`,
    ])
        st.event(e);
    auto r = st.finish();
    assert(shown == "Hello" && thought == "Plan." && r.content == "Hello");
    assert(r.thinkingBlocks.length == 1 && r.thinkingBlocks[0]["id"].str == "rs_1");
    assert(r.toolCalls.length == 1 && r.toolCalls[0].id == "call_9" && r.toolCalls[0].itemId == "fc_9");
    assert(r.toolCalls[0].arguments["pattern"].str == "*" && r.usage.outputTokens == 3);
    ResponsesStream bad;
    bad.sink = (bool t, string x) {};
    bool threw;
    try bad.event(`{"type":"response.failed","response":{"error":{"message":"nope"}}}`);
    catch (Exception e) threw = true;
    assert(threw);
}
