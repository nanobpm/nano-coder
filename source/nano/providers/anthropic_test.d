/// Anthropic Messages encoding and streaming (providers/anthropic.rs tests).
module nano.providers.anthropic_test;
@safe:

version (unittest):

import std.json;
import nano.config : ResolvedProvider;
import nano.llm;
import nano.providers.anthropic;
import nano.clock : FakeClock;
import nano.thinking : Request, anthropicDefaultMaxTokens;

private:

/// Fake time for one test: retry backoffs and offline waits advance it
/// instead of sleeping, so a loaded host can't outlast the test server's
/// 10 s accept window.
FakeClock fakeTime()
{
    import std.datetime.systime : SysTime;
    return FakeClock.install(SysTime(0));
}

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

/// Fake time for one test: retry backoffs and offline waits advance it
/// instead of sleeping (issues #379, #388).
imported!"nano.clock".FakeClock fakeTime()
{
    import std.datetime.systime : SysTime;
    import nano.clock : FakeClock;
    return FakeClock.install(SysTime(0));
}

AnthropicClient against(string url, bool stream)
{
    ResolvedProvider p;
    p.name = "anthropic";
    p.model = "claude";
    p.apiKey = "ak-test";
    p.config.baseUrl = url;
    p.config.stream = stream;
    p.config.timeoutSecs = 10;
    return new AnthropicClient(p);
}

string sse(string[] events)
{
    string s;
    foreach (e; events) s ~= "event: " ~ parseJSON(e)["type"].str ~ "\ndata: " ~ e ~ "\n\n";
    return s;
}

// rust: providers/anthropic.rs::retries_overload_and_parses_tool_use
unittest
{
    import std.algorithm : canFind;
    import std.string : toLower;
    import nano.testserver;
    auto clock = fakeTime();
    auto srv = serve([
        immutable Reply(529, "retry-after: 0.01\r\n", `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`),
        immutable Reply(200, "", `{"content":[{"type":"text","text":"Let me check."},`
            ~ `{"type":"tool_use","id":"toolu_1","name":"bash","input":{"command":"date"}}],`
            ~ `"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}`),
    ]);
    ChatRequest req;
    req.messages = [Message.user("date?")];
    req.maxTokens = 64;
    auto r = against(srv.url, false).chat(req, null);
    auto seen = srv.finish();
    assert(r.content == "Let me check." && r.toolCalls[0].arguments["command"].str == "date");
    assert(r.usage.inputTokens + r.usage.outputTokens == 15);
    assert(seen.length == 2 && seen[1].path == "/messages");
    auto h = seen[1].headers.toLower;
    assert(h.canFind("x-api-key: ak-test") && h.canFind("anthropic-version: 2023-06-01"), h);
}

// rust: providers/anthropic.rs::retries_after_empty_delta_and_resets_accumulator
unittest
{
    import nano.testserver;
    auto clock = fakeTime();
    enum start = `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`;
    auto truncated = sse([start, `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}`])
        ~ "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"wor";
    auto good = sse([`{"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}`, start,
        `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}`,
        `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}`,
        `{"type":"message_stop"}`]);
    auto srv = serve([immutable Reply(200, "content-type: text/event-stream\r\nx-truncate: 1\r\n", truncated),
        immutable Reply(200, "content-type: text/event-stream\r\n", good)]);
    ChatRequest req;
    req.messages = [Message.user("hi")];
    req.maxTokens = 64;
    string[] shown;
    auto r = against(srv.url, true).chat(req, (bool t, string x) { if (!t && x.length) shown ~= x; });
    assert(srv.finish().length == 2);
    assert(r.content == "world" && shown == ["world"], r.content);
}

// rust: providers/anthropic.rs::streams_thinking_text_and_tool_use_and_replays_thinking
unittest
{
    import nano.testserver;
    auto clock = fakeTime();
    auto srv = serve([immutable Reply(200, "content-type: text/event-stream\r\n", sse([
        `{"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":1}}}`,
        `{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}`,
        `{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan."}}`,
        `{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}`,
        `{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}`,
        `{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Running"}}`,
        `{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"bash","input":{}}}`,
        `{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}`,
        `{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"ls\"}"}}`,
        `{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}`,
        `{"type":"message_stop"}`]))]);
    ChatRequest req;
    req.messages = [Message.user("hello")];
    req.maxTokens = 64;
    string thought;
    auto r = against(srv.url, true).chat(req, (bool t, string x) { if (t) thought ~= x; });
    auto seen = srv.finish();
    assert(thought == "Plan." && r.content == "Running" && r.reasoning == "Plan.");
    assert(r.toolCalls[0].arguments == parseJSON(`{"command":"ls"}`));
    assert(r.usage.inputTokens == 20 && r.usage.outputTokens == 9);
    assert(parseJSON(seen[0].body_)["stream"].boolean);

    auto reply = Message.assistant(r.content, r.toolCalls);
    reply.thinkingBlocks = r.thinkingBlocks;
    ChatRequest again;
    again.messages = [Message.user("hello"), reply];
    auto content = body_(again)["messages"][1]["content"];
    assert(content[0] == parseJSON(`{"type":"thinking","thinking":"Plan.","signature":"sig"}`));
    assert(content[1]["type"].str == "text");
}
