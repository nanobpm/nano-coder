/// OpenAI Responses encoding and parsing (providers/openai_responses.rs tests).
module nano.providers.responses_test;
@safe:

version (unittest):

import std.algorithm : canFind;
import std.json;
import nano.config : ProviderKind, ResolvedProvider;
import nano.llm;
import nano.providers.responses;
import nano.thinking : Request;

private:

ResolvedProvider copilot(string model)
{
    ResolvedProvider p;
    p.model = model;
    p.config.kind = ProviderKind.githubCopilot;
    return p;
}

LLMResponse streamed(string[] events)
{
    ResponsesStream st;
    st.sink = (bool t, string x) {};
    foreach (e; events) st.event(e);
    return st.finish();
}

// rust: providers/openai_responses.rs::encodes_thinking_levels
unittest
{
    auto p = copilot("gpt-4.1");
    JSONValue body_(Request t)
    {
        ChatRequest req;
        req.messages = [Message.user("q")];
        req.thinking = t;
        return responsesBody(req, p, false);
    }
    assert(body_(Request(Request.Kind.effort, "high"))["reasoning"] == parseJSON(`{"effort":"high"}`));
    assert(body_(Request(Request.Kind.off))["reasoning"] == parseJSON(`{"effort":"none"}`));
    assert("reasoning" !in body_(Request.init));
}

// rust: providers/openai_responses.rs::incomplete_status_resolves_to_nested_reason_not_bare_incomplete
unittest
{
    assert(parseResponses(parseJSON(`{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}`),
        false).stopReason == "max_output_tokens");
    assert(parseResponses(parseJSON(`{"status":"incomplete","incomplete_details":{"reason":"content_filter"},"output":[]}`),
        false).stopReason == "content_filter");
    assert(parseResponses(parseJSON(`{"status":"incomplete","output":[]}`), false).stopReason == "incomplete");
    assert(streamed([`{"type":"response.incomplete","response":{"status":"incomplete",`
        ~ `"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":1,"output_tokens":2}}}`])
        .stopReason == "max_output_tokens");
}

// rust: providers/openai_responses.rs::muse_reasoning_round_trips_and_suppresses_temperature
unittest
{
    import nano.config : Config, presets, resolve;
    Config cfg;
    cfg.providers = presets();
    auto p = resolve(cfg, "muse/muse-spark-1.3");
    assert(p.replayReasoning, "Muse must default to reasoning replay");
    auto reasoning = parseJSON(`{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"plan"}],"encrypted_content":"enc"}`);
    auto value = parseJSON(`{"status":"completed","output":[` ~ reasoning.toString
        ~ `,{"type":"function_call","call_id":"c1","name":"bash","arguments":"{}"}]}`);
    auto r = parseResponses(value, p.replayReasoning);
    assert(r.thinkingBlocks == [reasoning]);
    auto reply = Message.assistant("", [ToolCall.fromRaw("c1", "bash", `{}`)]);
    reply.thinkingBlocks = r.thinkingBlocks;
    ChatRequest req;
    req.messages = [Message.user("go"), reply, Message.toolResult("c1", "bash", "ok")];
    req.temperature = 0.7;
    auto b = responsesBody(req, p, false);
    assert(b["include"] == parseJSON(`["reasoning.encrypted_content"]`) && b["store"] == JSONValue(false));
    assert("temperature" !in b, "Muse reasoning model kept temperature");
    auto input = b["input"].arrayNoRef;
    assert(input[1] == reasoning && input[2]["type"].str == "function_call" && input[2]["call_id"].str == "c1");
}

// rust: providers/openai_responses.rs::omits_temperature_for_reasoning_models_only
unittest
{
    ChatRequest req;
    req.messages = [Message.user("hi")];
    req.temperature = 0.7;
    auto astra = copilot("gpt-6-astra"), old = copilot("gpt-4.1");
    assert("temperature" !in responsesBody(req, astra, false));
    assert(responsesBody(req, old, false)["temperature"].floating == 0.7);
}

// rust: providers/openai_responses.rs::parse_response_propagates_failed_status
unittest
{
    string err;
    try parseResponses(parseJSON(`{"status":"failed","output":[],"error":{"message":"content policy"}}`), false);
    catch (Exception e) err = e.msg;
    assert(err.canFind("failed") && err.canFind("content policy"), err);
}

// rust: providers/openai_responses.rs::stream_accumulator_collects_text_thinking_and_calls
unittest
{
    auto r = streamed([`{"type":"response.reasoning_summary_text.delta","delta":"pl"}`,
        `{"type":"response.reasoning_summary_text.delta","delta":"an"}`,
        `{"type":"response.output_text.delta","delta":"he"}`,
        `{"type":"response.output_text.delta","delta":"llo"}`,
        `{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"c9","name":"bash"}}`,
        `{"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\"cmd\":"}`,
        `{"type":"response.function_call_arguments.delta","output_index":1,"delta":"\"ls\"}"}`,
        `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":4}}}`]);
    assert(r.content == "hello" && r.reasoning == "plan" && r.stopReason == "completed");
    assert(r.toolCalls[0].id == "c9" && r.toolCalls[0].name == "bash" && r.toolCalls[0].arguments["cmd"].str == "ls");
    assert(r.usage.inputTokens + r.usage.outputTokens == 7);
}

// rust: providers/openai_responses.rs::stream_captures_function_call_item_id
unittest
{
    auto r = streamed([`{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_9","call_id":"c9","name":"bash"}}`,
        `{"type":"response.function_call_arguments.delta","output_index":0,"delta":"{}"}`,
        `{"type":"response.completed","response":{"status":"completed"}}`]);
    assert(r.toolCalls[0].id == "c9" && r.toolCalls[0].itemId == "fc_9");
}

// rust: providers/openai_responses.rs::stream_failed_event_is_an_error
unittest
{
    string err;
    try streamed([`{"type":"response.failed","response":{"status":"failed","error":{"message":"boom"}}}`]);
    catch (Exception e) err = e.msg;
    assert(err.canFind("boom"), err);
}

// rust: providers/openai_responses.rs::tool_result_image_becomes_an_input_image_part
unittest
{
    import std.base64 : Base64;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import nano.attachment : Attachment, fakePng, sha256Hex, store;
    import nano.vision : Vision;
    auto dir = buildPath(tempDir, "nano-responses-image");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto bytes = fakePng(1024, 768);
    Attachment a;
    a.mediaType = "image/png";
    a.path = "/tmp/chart.png";
    a.sha256 = sha256Hex(bytes);
    a.width = 1024;
    a.height = 768;
    a.bytes = bytes.length;
    a.extension = "png";
    store(dir, a, bytes);
    auto result = Message.toolResult("call_1", "read_file", "image/png, 1024×768, 90 KB");
    result.attachments = [a];
    ChatRequest req;
    req.messages = [Message.user("read the chart"), result];
    req.vision = Vision.init;
    req.attachmentsDir = dir;
    auto p = copilot("gpt-4.1");
    auto output = responsesBody(req, p, false)["input"][1]["output"].arrayNoRef;
    assert(output[0] == parseJSON(`{"type":"input_text","text":"image/png, 1024×768, 90 KB"}`));
    assert(output[1]["type"].str == "input_image");
    assert(output[1]["image_url"].str == "data:image/png;base64," ~ Base64.encode(bytes));
}

// rust: providers/openai_responses.rs::trajectory_data_is_never_sent
unittest
{
    auto p = copilot("gpt-4.1");
    JSONValue body_(Message assistant)
    {
        ChatRequest req;
        req.messages = [Message.user("q"), assistant];
        return responsesBody(req, p, false);
    }
    auto logged = Message.assistant("answer");
    logged.thinking = "private reasoning";
    logged.usage.inputTokens = 10;
    logged.usage.outputTokens = 5;
    logged.hasUsage = true;
    logged.durationMs = 1234;
    assert(body_(logged) == body_(Message.assistant("answer")));
}
