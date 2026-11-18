/// GitHub Copilot client against scripted token-exchange and API servers
/// (providers/github_copilot.rs tests).
module nano.providers.copilot_test;
@safe:

version (unittest):

import std.algorithm : canFind;
import std.format : format;
import std.json;
import std.string : toLower;
import nano.config : Config, presets, resolve;
import nano.llm;
import nano.providers.openai : CopilotClient;
import nano.testserver;

private:

enum chatOk = `{"output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}],"status":"completed"}`;

CopilotClient client(string auth, string model = "gpt-5-mini")
{
    Config cfg;
    cfg.providers = presets();
    auto p = resolve(cfg, "github-copilot/" ~ model);
    p.apiKey = "gho_oauth";
    p.config.retryInitialBackoffMs = 1;
    p.config.timeoutSecs = 10;
    auto c = new CopilotClient(p);
    c.endpoints.copilotToken = auth ~ "/copilot_internal/v2/token";
    return c;
}

string tokenBody(string api, string token, long expiresIn = 1800)
{
    import std.datetime.systime : Clock;
    return format(`{"token":"%s","expires_at":%s,"endpoints":{"api":"%s"}}`, token,
        Clock.currTime.toUnixTime + expiresIn, api);
}

immutable(Reply) ok(string body_, string headers = "") { return immutable Reply(200, headers, body_); }

ChatRequest ask(Message[] messages...)
{
    ChatRequest req;
    req.messages = messages.dup;
    return req;
}

/// Serve `api` replies behind a token exchange; run `fn` on the client.
immutable(Captured)[] withApi(immutable(Reply)[] api, string model,
    scope void delegate(CopilotClient) @safe fn, scope immutable(Captured)[]* authLog = null)
{
    auto apiSrv = serve(api);
    auto authSrv = serve([ok(tokenBody(apiSrv.url, "sess-1"))]);
    fn(client(authSrv.url, model));
    auto a = authSrv.finish();
    if (authLog) *authLog = a;
    return apiSrv.finish();
}

// rust: providers/github_copilot.rs::auto_initiated_trailing_user_message_is_billed_as_agent
unittest
{
    auto log = withApi([ok(chatOk)], "gpt-5-mini", (c) {
        auto req = ask(Message.user("hello"), Message.assistant("partial"), Message.auto_("continue"));
        c.chat(req, null);
    });
    assert(log[0].headers.toLower.canFind("x-initiator: agent"),
        "auto-initiated trailing user message is agent-initiated, not a billed user turn");
}

// rust: providers/github_copilot.rs::classifies_reasoning_models
unittest
{
    import nano.copilot : isReasoningModel;
    foreach (m; ["gpt-6-astra", "gpt-5.6-sol", "gpt-5", "grok-code-fast-1", "oswe-preview", "mai-code-1"])
        assert(isReasoningModel(m), m);
    foreach (m; ["gpt-4.1", "gpt-4o-mini", "o4-mini", "claude-sonnet-4.5", "gemini-2.5-pro"])
        assert(!isReasoningModel(m), m);
}

Capabilities probed(string models, int status = 200, scope size_t* requests = null)
{
    Capabilities caps;
    auto log = withApi([immutable Reply(status, "", models)], "gpt-5-mini", (c) { caps = c.probeCapabilities(); });
    if (requests) *requests = log.length;
    return caps;
}

// rust: providers/github_copilot.rs::detect_capabilities_keeps_output_limit_when_window_is_absent
unittest
{
    auto c = probed(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{"max_output_tokens":16000}}}]}`);
    assert(c.window == 0, "no prompt or context-window limit means no detected window");
    assert(c.maxOutput == 16_000, "the output cap survives the absent window");
}

// D probes window, thinking and vision with one /models fetch (Rust's
// detect_capabilities and detect_thinking_and_vision share it the same way).
// rust: providers/github_copilot.rs::detect_capabilities_makes_one_failed_models_request
// rust: providers/github_copilot.rs::detect_thinking_and_vision_makes_one_failed_models_request
unittest
{
    size_t n;
    auto c = probed(`{"error":"boom"}`, 500, &n);
    assert(c.window == 0 && c.thinking.isNull && c.vision.isNull && c.maxOutput == 0);
    assert(n == 1, "the failed fetch is not retried for the second probe");
}

// rust: providers/github_copilot.rs::detect_capabilities_reads_both_from_one_models_request
// rust: providers/github_copilot.rs::detect_thinking_and_vision_reads_both_from_one_models_request
// rust: providers/github_copilot.rs::detect_capabilities_reads_the_models_output_limit
// rust: providers/github_copilot.rs::reads_thinking_levels_and_window_from_one_models_request
unittest
{
    size_t n;
    auto c = probed(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{"max_prompt_tokens":111,"max_output_tokens":16000},`
        ~ `"supports":{"reasoning_effort":["none","low","high"],"vision":true}}}]}`, 200, &n);
    assert(c.window == 111 && c.thinking.get.levels == ["off", "low", "high"]);
    assert(!c.vision.isNull, "vision derived from the same shared /models entry");
    assert(c.maxOutput == 16_000, "output limit comes from the same shared /models entry");
    assert(n == 1, "one shared /models fetch");
}

// rust: providers/github_copilot.rs::detects_context_window_field_fallbacks
unittest
{
    auto c = probed(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{"max_prompt_tokens":111,"max_context_window_tokens":999}}}]}`);
    assert(c.window == 111 && c.windowSource == "Copilot /models max_prompt_tokens", c.windowSource);
    assert(c.promptCap, "the prompt budget caps the prompt alone");
    assert(c.totalWindow == 999, "the combined window is kept as a second limit");
    c = probed(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{"max_context_window_tokens":222}}}]}`);
    assert(c.window == 222 && c.windowSource == "Copilot /models max_context_window_tokens");
    assert(!c.promptCap && c.totalWindow == 0, "the full window caps prompt + output");
    assert(probed(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{}}}]}`).window == 0);
    assert(probed(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{"max_prompt_tokens":0}}}]}`).window == 0);
    assert(probed(`{"data":[{"id":"other","capabilities":{"limits":{"max_prompt_tokens":111}}}]}`).window == 0);
}

// rust: providers/github_copilot.rs::exchange_failure_explains_login
unittest
{
    auto auth = serve([immutable Reply(404, "", `{"message":"Not Found"}`)]);
    string err;
    try
    {
        auto req = ask(Message.user("hello"));
        client(auth.url).chat(req, null);
    }
    catch (Exception e) err = e.msg;
    auth.finish();
    assert(err.canFind("--login github-copilot"), err);
}

// rust: providers/github_copilot.rs::exchanges_token_and_sends_editor_headers
unittest
{
    immutable(Captured)[] authLog;
    auto log = withApi([ok(chatOk), ok(chatOk)], "gpt-5-mini", (c) {
        auto req = ask(Message.user("hello"));
        assert(c.chat(req, null).content == "hi");
        auto followup = ask(Message.user("hello"), Message.assistant("", [ToolCall.fromRaw("c", "t", `{}`)]),
            Message.toolResult("c", "t", "ok"));
        c.chat(followup, null);
    }, &authLog);
    assert(authLog.length == 1, "session token is cached");
    assert(authLog[0].headers.toLower.canFind("authorization: bearer gho_oauth"));
    assert(authLog[0].headers.canFind("vscode/"));
    auto first = log[0].headers.toLower;
    assert(log[0].path == "/responses");
    assert(first.canFind("authorization: bearer sess-1") && first.canFind("copilot-integration-id: vscode-chat"));
    assert(first.canFind("x-initiator: user") && log[1].headers.toLower.canFind("x-initiator: agent"));
    assert(parseJSON(log[0].body_)["model"].str == "gpt-5-mini");
}

// D keeps no /models cache (one combined probe per session); a re-probe after
// the session's API endpoint changes asks the new endpoint.
// rust: providers/github_copilot.rs::models_cache_refetches_when_the_endpoint_changes
unittest
{
    import nano.copilot : refreshMarginSecs;
    auto api1 = serve([ok(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{"max_prompt_tokens":111}}}]}`)]);
    auto api2 = serve([ok(`{"data":[{"id":"gpt-5-mini","capabilities":{"limits":{"max_prompt_tokens":222}}}]}`)]);
    auto auth = serve([ok(tokenBody(api1.url, "sess-1", refreshMarginSecs - 1)), ok(tokenBody(api2.url, "sess-2"))]);
    auto c = client(auth.url);
    assert(c.probeCapabilities().window == 111);
    assert(c.probeCapabilities().window == 222, "re-fetched from the new endpoint");
    assert(api1.finish().length == 1 && api2.finish().length == 1 && auth.finish().length == 2);
}

// rust: providers/github_copilot.rs::reexchanges_once_on_unauthorized
unittest
{
    auto api = serve([immutable Reply(401, "", `{"error":{"message":"token expired"}}`), ok(chatOk)]);
    auto auth = serve([ok(tokenBody(api.url, "sess-1")), ok(tokenBody(api.url, "sess-2"))]);
    auto req = ask(Message.user("hello"));
    assert(client(auth.url).chat(req, null).content == "hi");
    assert(auth.finish().length == 2);
    assert(api.finish()[1].headers.toLower.canFind("bearer sess-2"));
}

// rust: providers/github_copilot.rs::routes_claude_model_to_messages_endpoint
unittest
{
    auto log = withApi([ok(`{"content":[{"type":"text","text":"bonjour"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2}}`)],
        "claude-sonnet-4.5", (c) {
            auto req = ask(Message.system("be brief"), Message.user("hi"));
            assert(c.chat(req, null).content == "bonjour");
        });
    assert(log[0].path == "/v1/messages", log[0].path);
    auto b = parseJSON(log[0].body_);
    assert(b["model"].str == "claude-sonnet-4.5");
    assert((b["system"].type == JSONType.string ? b["system"].str : b["system"][0]["text"].str) == "be brief");
    auto h = log[0].headers.toLower;
    assert(h.canFind("anthropic-version: 2023-06-01") && h.canFind("copilot-integration-id: vscode-chat"));
}

// rust: providers/github_copilot.rs::routes_completions_model_to_chat_completions
unittest
{
    auto log = withApi([ok(`{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}`)], "o4-mini", (c) {
        auto req = ask(Message.user("hello"));
        assert(c.chat(req, null).content == "hi");
    });
    auto b = parseJSON(log[0].body_);
    assert(log[0].path == "/chat/completions" && b["model"].str == "o4-mini" && "messages" in b);
}

// rust: providers/github_copilot.rs::routes_gpt_model_to_responses_endpoint
unittest
{
    auto log = withApi([ok(`{"output":[{"type":"message","content":[{"type":"output_text","text":"pong"}]}],`
        ~ `"usage":{"input_tokens":3,"output_tokens":1},"status":"completed"}`)], "gpt-6-astra", (c) {
        auto req = ask(Message.user("ping"));
        assert(c.chat(req, null).content == "pong");
    });
    auto b = parseJSON(log[0].body_);
    assert(log[0].path == "/responses" && b["model"].str == "gpt-6-astra" && "input" in b && "messages" !in b);
    assert(log[0].headers.toLower.canFind("copilot-integration-id: vscode-chat"));
}

// rust: providers/github_copilot.rs::sends_vision_header_when_request_carries_an_image
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import nano.attachment : Attachment, fakePng, sha256Hex, store;
    import nano.vision : Vision;
    enum reply = `{"content":[{"type":"text","text":"a diagram"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2}}`;
    auto dir = buildPath(tempDir, "nano-copilot-vision");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto bytes = fakePng(100, 100);
    Attachment a;
    a.mediaType = "image/png";
    a.path = "/tmp/d.png";
    a.sha256 = sha256Hex(bytes);
    a.width = 100;
    a.height = 100;
    a.bytes = bytes.length;
    a.extension = "png";
    store(dir, a, bytes);
    auto log = withApi([ok(reply)], "claude-sonnet-4.5", (c) {
        auto result = Message.toolResult("t1", "read_file", "image/png, 100×100, 8 B");
        result.attachments = [a];
        auto req = ask(result);
        req.vision = Vision.init;
        req.attachmentsDir = dir;
        c.chat(req, null);
    });
    assert(log[0].headers.toLower.canFind("copilot-vision-request: true"), log[0].headers);
    log = withApi([ok(reply)], "claude-sonnet-4.5", (c) {
        auto req = ask(Message.user("hi"));
        c.chat(req, null);
    });
    assert(!log[0].headers.toLower.canFind("copilot-vision-request"), "no image, no vision header");
}

enum sseHeaders = "content-type: text/event-stream\r\n";

string streamText(CopilotClient c, ref ChatRequest req)
{
    string shown;
    auto r = c.chat(req, (bool t, string x) { if (!t) shown ~= x; });
    assert(r.content == shown, r.content ~ " vs " ~ shown);
    return r.content;
}

// rust: providers/github_copilot.rs::stream_routes_claude_model_to_messages_endpoint
unittest
{
    string sse;
    foreach (e; [`{"type":"message_start","message":{"usage":{"input_tokens":4,"output_tokens":1}}}`,
        `{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
        `{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"bonjour"}}`,
        `{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}`,
        `{"type":"message_stop"}`])
        sse ~= "event: " ~ parseJSON(e)["type"].str ~ "\ndata: " ~ e ~ "\n\n";
    auto log = withApi([ok(sse, sseHeaders)], "claude-sonnet-4.5", (c) {
        auto req = ask(Message.system("be brief"), Message.user("hi"));
        req.maxTokens = 64;
        assert(streamText(c, req) == "bonjour");
    });
    auto b = parseJSON(log[0].body_);
    assert(log[0].path == "/v1/messages" && b["stream"].boolean);
    assert(log[0].headers.toLower.canFind("anthropic-version: 2023-06-01"));
}

// rust: providers/github_copilot.rs::stream_routes_completions_model_to_chat_completions
unittest
{
    auto log = withApi([ok("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"hi\"}}]}\n\ndata: [DONE]\n\n",
        sseHeaders)], "o4-mini", (c) {
        auto req = ask(Message.user("hello"));
        assert(streamText(c, req) == "hi");
    });
    auto b = parseJSON(log[0].body_);
    assert(log[0].path == "/chat/completions" && "messages" in b && b["stream"].boolean);
}

// rust: providers/github_copilot.rs::stream_routes_gpt_model_to_responses_endpoint
unittest
{
    string sse;
    foreach (e; [`{"type":"response.output_text.delta","delta":"po"}`, `{"type":"response.output_text.delta","delta":"ng"}`,
        `{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":3,"output_tokens":1}}}`])
        sse ~= "data: " ~ e ~ "\n\n";
    auto log = withApi([ok(sse, sseHeaders)], "gpt-6-astra", (c) {
        auto req = ask(Message.user("ping"));
        assert(streamText(c, req) == "pong");
    });
    auto b = parseJSON(log[0].body_);
    assert(log[0].path == "/responses" && "input" in b && "messages" !in b && b["stream"].boolean);
}
