/// Anthropic Messages encoding and streaming (providers/anthropic.rs tests).
module nano.providers.anthropic_test;
@safe:

version (unittest):

import std.json;
import nano.config : ResolvedProvider;
import nano.llm;
import nano.providers.anthropic;
import nano.thinking : Request, anthropicDefaultMaxTokens;

private:

JSONValue body_(const ref ChatRequest req)
{
    ResolvedProvider p;
    p.model = "claude";
    return new AnthropicClient(p).requestBody(req, false);
}

// rust: providers/anthropic.rs::encodes_system_tools_and_grouped_tool_results
unittest
{
    ChatRequest req;
    req.messages = [Message.system("be brief"), Message.user("time and date?"),
        Message.assistant("checking", [ToolCall.fromRaw("t1", "get_time", `{}`), ToolCall.fromRaw("t2", "bash", "{bad")]),
        Message.toolResult("t1", "get_time", "noon"), Message.toolResult("t2", "bash", "Error")];
    req.tools = [ToolDefinition("get_time", "time", parseJSON(`{"type":"object"}`))];
    req.temperature = 1.5;
    auto b = body_(req);
    assert(b["system"][0]["text"].str == "be brief");
    assert(b["max_tokens"].integer == anthropicDefaultMaxTokens && anthropicDefaultMaxTokens == 8192);
    assert(b["temperature"].floating == 1.0, "clamped to Anthropic's range");
    assert(b["tools"][0]["input_schema"]["type"].str == "object");
    auto m = b["messages"].arrayNoRef;
    assert(m.length == 3);
    assert(m[1]["content"][1]["type"].str == "tool_use");
    assert(m[1]["content"][2]["input"] == parseJSON(`{}`), "malformed arguments go as an empty object");
    assert(m[2]["role"].str == "user" && m[2]["content"].arrayNoRef.length == 2);
    assert(m[2]["content"][1]["tool_use_id"].str == "t2");
}

// rust: providers/anthropic.rs::encodes_thinking_levels
// rust: providers/anthropic.rs::encodes_adaptive_on_without_output_config
unittest
{
    JSONValue with_(Request t, long maxTokens = 0)
    {
        ChatRequest req;
        req.messages = [Message.user("hi")];
        req.temperature = 0.5;
        req.maxTokens = maxTokens;
        req.thinking = t;
        return body_(req);
    }
    auto b = with_(Request(Request.Kind.effort, "high"));
    assert(b["thinking"] == parseJSON(`{"type":"adaptive"}`) && b["output_config"] == parseJSON(`{"effort":"high"}`));
    assert("temperature" !in b);
    b = with_(Request(Request.Kind.budget, null, 16384), 4096);
    assert(b["thinking"] == parseJSON(`{"type":"enabled","budget_tokens":4095}`) && "temperature" !in b, b.toString);
    b = with_(Request(Request.Kind.budget, null, 16384), 1000);
    assert("thinking" !in b && b["temperature"].floating == 0.5);
    b = with_(Request(Request.Kind.off));
    assert(b["thinking"] == parseJSON(`{"type":"disabled"}`) && b["temperature"].floating == 0.5);
    b = with_(Request(Request.Kind.adaptiveOn));
    assert(b["thinking"] == parseJSON(`{"type":"adaptive"}`) && "output_config" !in b && "temperature" !in b);
}

// rust: providers/anthropic.rs::trajectory_data_is_never_sent
unittest
{
    auto logged = Message.assistant("answer");
    logged.thinking = "private reasoning";
    logged.usage.inputTokens = 10;
    logged.usage.outputTokens = 5;
    logged.hasUsage = true;
    logged.durationMs = 1234;
    ChatRequest a, b;
    a.messages = [Message.user("q"), logged];
    b.messages = [Message.user("q"), Message.assistant("answer")];
    assert(body_(a)["messages"] == body_(b)["messages"]);
}

// rust: providers/anthropic.rs::skips_reasoning_blocks_from_openai_compatible_providers
unittest
{
    auto m = Message.assistant("hi");
    m.thinkingBlocks = [parseJSON(`{"type":"reasoning_content","text":"from kimi"}`)];
    ChatRequest req;
    req.messages = [Message.user("hello"), m];
    auto content = body_(req)["messages"][1]["content"];
    assert(content.arrayNoRef.length == 1 && content[0]["type"].str == "text" && content[0]["text"].str == "hi");
}

// rust: providers/anthropic.rs::tool_result_carries_image_as_base64_block
unittest
{
    import std.base64 : Base64;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import nano.attachment : Attachment, fakePng, sha256Hex, store;
    import nano.vision : Vision;
    auto dir = buildPath(tempDir, "nano-anthropic-image");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto bytes = fakePng(1200, 675);
    Attachment a;
    a.mediaType = "image/png";
    a.path = "shot.png";
    a.sha256 = sha256Hex(bytes);
    a.width = 1200;
    a.height = 675;
    a.bytes = bytes.length;
    a.extension = "png";
    store(dir, a, bytes);
    auto result = Message.toolResult("t1", "read_file", "image/png, 1200×675, 131 KB");
    result.attachments = [a];
    ChatRequest req;
    req.messages = [Message.user("look"), Message.assistant("", [ToolCall.fromRaw("t1", "read_file", `{}`)]), result];
    req.vision = Vision.init;
    req.attachmentsDir = dir;
    auto tr = body_(req)["messages"][2]["content"][0];
    assert(tr["type"].str == "tool_result" && tr["tool_use_id"].str == "t1");
    auto content = tr["content"].arrayNoRef;
    assert(content[0] == parseJSON(`{"type":"text","text":"image/png, 1200×675, 131 KB"}`));
    assert(content[1]["type"].str == "image" && content[1]["source"]["type"].str == "base64");
    assert(content[1]["source"]["media_type"].str == "image/png");
    assert(content[1]["source"]["data"].str == Base64.encode(bytes));
}

// rust: providers/anthropic.rs::finish_preserves_truncated_tool_call_arguments_as_malformed
unittest
{
    AnthropicStream st;
    st.sink = (bool t, string x) {};
    foreach (e; [
        `{"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":1}}}`,
        `{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"write_file","input":{}}}`,
        `{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/tmp/big.txt\",\"content\":\"..."}}`,
        `{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":9}}`,
        `{"type":"message_stop"}`,
    ])
        st.event(e);
    auto r = st.finish();
    assert(r.stopReason == "max_tokens");
    assert(r.toolCalls[0].invalidArguments == `{"path":"/tmp/big.txt","content":"...`);
    assert(r.toolCalls[0].arguments == parseJSON(`{}`));
}
