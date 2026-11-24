/// OpenAI chat-completions client against a scripted server (providers/openai.rs tests).
module nano.providers.openai_test;
@safe:

import std.string : representation;

version (unittest):

import std.algorithm : canFind;
import std.json;
import std.string : toLower;
import nano.config : ResolvedProvider;
import nano.llm;
import nano.providers.openai;
import nano.testserver;

private:

OpenAIClient against(string url, bool stream = true, long timeoutSecs = 10, long maxRetries = 5)
{
    ResolvedProvider p;
    p.name = "test";
    p.model = "some-model";
    p.apiKey = "sk-test";
    p.config.baseUrl = url;
    p.config.stream = stream;
    p.config.retryInitialBackoffMs = 1;
    p.config.timeoutSecs = timeoutSecs;
    p.config.maxRetries = maxRetries;
    return new OpenAIClient(p);
}

ChatRequest hello(string text = "hello")
{
    ChatRequest req;
    req.messages = [Message.user(text)];
    return req;
}

string sse(string[] events, bool done = false)
{
    string s;
    foreach (e; events) s ~= "data: " ~ e ~ "\n\n";
    return done ? s ~ "data: [DONE]\n\n" : s;
}

enum streamHeaders = "content-type: text/event-stream\r\n";
enum cutHeaders = "content-type: text/event-stream\r\nx-truncate: 1\r\n";

// rust: providers/openai.rs::does_not_retry_auth_errors
unittest
{
    auto srv = serve([immutable Reply(401, "",
        `{"error":{"message":"bad key","type":"invalid_request_error","code":"invalid_api_key"}}`)]);
    auto req = hello();
    string err;
    try against(srv.url, false).chat(req, null);
    catch (Exception e) err = e.msg;
    assert(err.canFind("invalid_api_key") || err.canFind("bad key"), err);
    assert(srv.finish().length == 1);
}

// rust: providers/openai.rs::does_not_retry_mid_stream_disconnect_after_partial_output
unittest
{
    auto srv = serve([immutable Reply(200, cutHeaders,
        sse([`{"choices":[{"delta":{"role":"assistant","content":"hello"}}]}`])
        ~ `data: {"choices":[{"delta":{"content":" wor`)]);
    auto req = hello("hi");
    string[] shown;
    bool failed;
    try against(srv.url).chat(req, (bool t, string x) { if (!t) shown ~= x; });
    catch (Exception e) failed = true;
    assert(failed && shown == ["hello"]);
    assert(srv.finish().length == 1);
}

// rust: providers/openai.rs::retries_after_metadata_only_event_and_resets_accumulator
unittest
{
    enum call = `{"choices":[{"delta":{"role":"assistant","tool_calls":[`
        ~ `{"index":0,"id":"c1","type":"function","function":{"name":"get_time","arguments":"{}"}}]}}]}`;
    auto srv = serve([immutable Reply(200, cutHeaders, sse([call]) ~ `data: {"choices":[{"delta":{"content":" wor`),
        immutable Reply(200, streamHeaders, sse([call, `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`], true))]);
    auto req = hello("hi");
    string[] shown;
    auto r = against(srv.url).chat(req, (bool t, string x) { if (!t && x.length) shown ~= x; });
    assert(srv.finish().length == 2);
    assert(shown.length == 0);
    assert(r.toolCalls.length == 1 && r.toolCalls[0].name == "get_time" && r.toolCalls[0].arguments == parseJSON(`{}`));
}

// rust: providers/openai.rs::retries_mid_stream_disconnect_before_any_output
unittest
{
    auto srv = serve([immutable Reply(200, cutHeaders, `data: {"choices":[{"delta":{"content":"par`),
        immutable Reply(200, streamHeaders, sse([`{"choices":[{"delta":{"role":"assistant","content":"hello"}}]}`,
            `{"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}`], true))]);
    auto req = hello("hi");
    string[] shown;
    auto r = against(srv.url).chat(req, (bool t, string x) { if (!t && x.length) shown ~= x; });
    assert(r.content == "hello world" && shown == ["hello", " world"]);
    assert(srv.finish().length == 2);
}

// rust: providers/openai.rs::retries_rate_limits_then_succeeds
unittest
{
    auto srv = serve([immutable Reply(429, "retry-after: 0\r\n", `{"error":{"message":"slow down","code":"rate_limit_exceeded"}}`),
        immutable Reply(503, "", "upstream"),
        immutable Reply(200, "", `{"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}`)]);
    auto req = hello();
    auto r = against(srv.url, false).chat(req, null);
    auto seen = srv.finish();
    assert(r.content == "hi" && seen.length == 3);
    assert(seen[2].path == "/chat/completions" && parseJSON(seen[2].body_)["model"].str == "some-model");
    assert(seen[2].headers.toLower.canFind("authorization: bearer sk-test"));
}

// rust: providers/openai.rs::retries_truncated_success_bodies
unittest
{
    auto srv = serve([immutable Reply(200, "x-truncate: 1\r\n", `{"choices":[{"mess`),
        immutable Reply(200, "", `{"choices":[{"message":{"content":"whole"}}]}`)]);
    auto req = hello();
    auto r = against(srv.url, false).chat(req, null);
    assert(r.content == "whole" && srv.finish().length == 2);
}

// rust: providers/openai.rs::stream_falls_back_to_json_and_splits_think_tags
unittest
{
    auto srv = serve([immutable Reply(200, "",
        `{"choices":[{"message":{"content":"<think>hmm</think>\nhi"},"finish_reason":"stop"}]}`)]);
    auto req = hello();
    auto r = against(srv.url).chat(req, (bool t, string x) {});
    srv.finish();
    assert(r.content == "hi" && r.reasoning == "hmm", r.content ~ "|" ~ r.reasoning);
}

// rust: providers/openai.rs::slow_but_steady_stream_survives_beyond_idle_timeout
unittest
{
    string[] events;
    foreach (piece; ["h", "e", "l", "l", "o", " ", "w", "o", "r", "l", "d"])
        events ~= `{"choices":[{"delta":{"content":"` ~ piece ~ `"}}]}`;
    // 12 x 100 ms (11 deltas and [DONE]): the stream outlasts the 1 s idle
    // timeout, while each gap is a tenth of it, so a loaded host stalling a
    // gap several-fold still can't trip it (issue #358).
    auto srv = serve([immutable Reply(200, streamHeaders, sse(events, true), 100)]);
    auto c = against(srv.url, true, 1);
    auto req = hello("hi");
    auto r = c.chat(req, (bool t, string x) {});
    srv.finish();
    assert(r.content == "hello world");
}

// rust: providers/openai.rs::streamed_leading_whitespace_after_thinking_is_trimmed
unittest
{
    auto srv = serve([immutable Reply(200, streamHeaders, sse([
        `{"choices":[{"delta":{"role":"assistant","reasoning_content":"ponder"}}]}`,
        `{"choices":[{"delta":{"content":"\n\nanswer"}}]}`,
        `{"choices":[],"finish_reason":"stop"}`], true))]);
    auto req = hello();
    auto r = against(srv.url).chat(req, (bool t, string x) {});
    srv.finish();
    assert(r.content == "answer" && r.reasoning == "ponder", "[" ~ r.content ~ "][" ~ r.reasoning ~ "]");
}

// rust: providers/openai.rs::streamed_leading_whitespace_is_preserved_without_thinking
unittest
{
    auto srv = serve([immutable Reply(200, streamHeaders, sse([
        `{"choices":[{"delta":{"role":"assistant","content":" world"}}]}`,
        `{"choices":[{"delta":{"content":" again"}}]}`,
        `{"choices":[],"finish_reason":"stop"}`], true))]);
    auto req = hello();
    string[] shown;
    auto r = against(srv.url).chat(req, (bool t, string x) { if (!t) shown ~= x; });
    srv.finish();
    assert(r.content == " world again" && shown == [" world", " again"], r.content);
}

// rust: providers/openai.rs::streams_reasoning_text_and_tool_calls
unittest
{
    auto srv = serve([immutable Reply(200, streamHeaders, sse([
        `{"choices":[{"delta":{"role":"assistant","reasoning_content":"Let me "}}]}`,
        `{"choices":[{"delta":{"reasoning_content":"check."}}]}`,
        `{"choices":[{"delta":{"content":"<think>more</think>\n\nChecking"}}]}`,
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"bash","arguments":"{\"comm"}}]}}]}`,
        `{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}`,
        `{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}`], true))]);
    auto req = hello();
    string[] shown;
    auto r = against(srv.url).chat(req, (bool t, string x) { if (x.length) shown ~= (t ? "R:" : "T:") ~ x; });
    auto seen = srv.finish();
    assert(r.reasoning == "Let me check.more" && r.content == "Checking", r.reasoning ~ "|" ~ r.content);
    assert(r.toolCalls.length == 1 && r.toolCalls[0].id == "call_a" && r.toolCalls[0].name == "bash");
    assert(r.toolCalls[0].arguments == parseJSON(`{"command":"ls"}`));
    assert(r.usage.inputTokens + r.usage.outputTokens == 17 && r.stopReason == "tool_calls");
    assert(shown == ["R:Let me ", "R:check.", "R:more", "T:Checking"], imported!"std.conv".text(shown));
    assert(r.thinkingBlocks.length == 0, "reasoning is kept only with replay_reasoning");
    auto b = parseJSON(seen[0].body_);
    assert(b["stream"].boolean && b["stream_options"]["include_usage"].boolean);
}

// rust: providers/openai.rs::trajectory_data_is_never_sent
unittest
{
    auto logged = Message.assistant("answer");
    logged.thinking = "private reasoning";
    logged.usage.inputTokens = 10;
    logged.usage.outputTokens = 5;
    logged.hasUsage = true;
    logged.durationMs = 1234;
    auto plain = Message.assistant("answer");
    foreach (replay; [false, true])
        assert(OpenAIClient.encode(logged, replay) == OpenAIClient.encode(plain, replay));
}

struct Stored
{
    string dir;
    imported!"nano.attachment".Attachment a;
    immutable(ubyte)[] bytes;
}

Stored storedPng(string dir, string path, uint w, uint h, bool keep = true)
{
    import nano.attachment : Attachment, fakePng, sha256Hex, store;
    auto bytes = fakePng(w, h);
    Attachment a;
    a.mediaType = "image/png";
    a.path = path;
    a.sha256 = sha256Hex(keep ? bytes : "missing-bytes".representation);
    a.width = w;
    a.height = h;
    a.bytes = bytes.length;
    a.extension = "png";
    if (keep) store(dir, a, bytes);
    return Stored(dir, a, bytes);
}

string freshDir(string name)
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, name);
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

// rust: providers/openai.rs::tool_result_image_goes_in_a_followup_user_message
unittest
{
    import std.base64 : Base64;
    import std.file : rmdirRecurse;
    import nano.vision : Vision;
    auto dir = freshDir("nano-openai-followup");
    scope (exit) rmdirRecurse(dir);
    auto s = storedPng(dir, "/tmp/plot.png", 800, 600);
    auto result = Message.toolResult("c1", "read_file", "image/png, 800×600, 50 KB");
    result.attachments = [s.a];
    ChatRequest req;
    req.messages = [Message.user("look at the plot"),
        Message.assistant("", [ToolCall.fromRaw("c1", "read_file", `{"path":"/tmp/plot.png"}`)]), result];
    req.vision = Vision.init;
    req.attachmentsDir = dir;
    auto m = against("http://x").requestBody(req, false)["messages"].arrayNoRef;
    assert(m.length == 4);
    assert(m[2]["role"].str == "tool" && m[2]["content"].str.canFind("[image attached after the tool results]"));
    assert(m[3]["role"].str == "user");
    auto parts = m[3]["content"].arrayNoRef;
    assert(parts[0]["text"].str == "[attached image]" && parts[1]["type"].str == "image_url");
    assert(parts[1]["image_url"]["url"].str == "data:image/png;base64," ~ Base64.encode(s.bytes));
}

// rust: providers/openai.rs::tool_without_its_own_image_does_not_claim_one_follows
unittest
{
    import std.file : rmdirRecurse;
    import nano.vision : Vision;
    auto dir = freshDir("nano-openai-claim");
    scope (exit) rmdirRecurse(dir);
    auto present = storedPng(dir, "/tmp/present.png", 10, 10);
    auto missing = storedPng(dir, "/tmp/missing.png", 10, 10, false);
    auto r1 = Message.toolResult("c1", "read_file", "present");
    r1.attachments = [present.a];
    auto r2 = Message.toolResult("c2", "read_file", "missing");
    r2.attachments = [missing.a];
    ChatRequest req;
    req.messages = [Message.assistant("", [ToolCall.fromRaw("c1", "read_file", `{}`), ToolCall.fromRaw("c2", "read_file", `{}`)]),
        r1, r2];
    req.vision = Vision(4);
    req.attachmentsDir = dir;
    auto m = against("http://x").requestBody(req, false)["messages"].arrayNoRef;
    assert(m[1]["tool_call_id"].str == "c1" && m[1]["content"].str.canFind("[image attached after the tool results]"));
    assert(m[2]["tool_call_id"].str == "c2" && !m[2]["content"].str.canFind("[image attached after the tool results]"));
    assert(m[2]["content"].str.canFind("no longer available"), m[2]["content"].str);
}

struct Probed
{
    Capabilities caps;
    string[] paths;
}

/// Probe a provider named `name` (model qwen3:8b) against scripted replies.
Probed probeWith(string name, immutable(Reply)[] replies)
{
    auto srv = serve(replies);
    ResolvedProvider p;
    p.name = name;
    p.model = "qwen3:8b";
    p.config.baseUrl = srv.url ~ "/v1";
    auto caps = new OpenAIClient(p).probeCapabilities();
    string[] paths;
    foreach (c; srv.finish()) paths ~= c.path;
    return Probed(caps, paths);
}

immutable(Reply) ok(string body_) { return immutable Reply(200, "", body_); }

// rust: providers/openai.rs::asks_llama_cpp_for_its_loaded_context
unittest
{
    auto r = probeWith("local", [ok(`{"data":[{"id":"qwen3:8b","owned_by":"llamacpp","meta":{"n_ctx_train":262144}}]}`),
        ok(`{"default_generation_settings":{"n_ctx":65536}}`)]);
    assert(r.caps.window == 65536 && r.caps.windowSource == "llama.cpp /props n_ctx", r.caps.windowSource);
    assert(r.paths == ["/v1/models", "/props?model=qwen3%3A8b"]);
}

// rust: providers/openai.rs::recognizes_llama_cpp_by_provider_name
unittest
{
    auto r = probeWith("llamacpp", [ok(`{"data":[{"id":"qwen3:8b"}]}`), ok(`{"default_generation_settings":{"n_ctx":65536}}`)]);
    assert(r.caps.window == 65536 && r.caps.windowSource == "llama.cpp /props n_ctx");
    assert(r.paths == ["/v1/models", "/props?model=qwen3%3A8b"]);
}

// rust: providers/openai.rs::recognizes_lm_studio_by_provider_name
unittest
{
    auto r = probeWith("lmstudio", [ok(`{"data":[{"id":"qwen3:8b"}]}`),
        ok(`{"data":[{"id":"qwen3:8b","loaded_context_length":12288}]}`)]);
    assert(r.caps.window == 12288 && r.caps.windowSource == "LM Studio loaded_context_length");
    assert(r.paths == ["/v1/models", "/api/v0/models"]);
}

// rust: providers/openai.rs::reports_nothing_when_the_endpoint_does_not_say
unittest
{
    auto r = probeWith("hosted", [ok(`{"data":[{"id":"qwen3:8b","owned_by":"system"},{"id":"b"}]}`)]);
    assert(r.caps.window == 0 && r.caps.thinking.isNull);
    assert(r.paths == ["/v1/models"], "unknown servers get no extra probes");
    r = probeWith("hosted", [immutable Reply(404, "", "{}")]);
    assert(r.caps.window == 0 && r.caps.thinking.isNull && r.caps.vision.isNull);
}

// rust: providers/openai.rs::output_cap_survives_absent_window_on_generic_server
unittest
{
    auto r = probeWith("hosted", [ok(`{"data":[{"id":"qwen3:8b","max_completion_tokens":8000}]}`)]);
    assert(r.caps.window == 0, "no window field means no detected window");
    assert(r.caps.maxOutput == 8000, "the published output cap survives the absent window");
}

// D has one combined probe (Rust's detect / detect_levels / detect_tv): each
// endpoint is fetched once, and window, thinking and vision come from it.
// rust: providers/openai.rs::combined_detection_probes_each_endpoint_once
// rust: providers/openai.rs::detects_thinking_levels_on_ollama_and_llama_cpp
// rust: providers/openai.rs::thinking_and_vision_probe_shares_one_fetch
unittest
{
    import nano.thinking : Format;
    auto r = probeWith("box", [ok(`{"data":[{"id":"qwen3:8b","owned_by":"llamacpp"}]}`),
        ok(`{"default_generation_settings":{"n_ctx":65536},"modalities":{"vision":true},"chat_template":"{% if enable_thinking %}"}`)]);
    assert(r.caps.window == 65536 && r.caps.windowSource == "llama.cpp /props n_ctx");
    assert(r.caps.thinking.get.levels == ["off", "on"]);
    assert(!r.caps.vision.isNull, "vision derived from the shared /props");
    assert(r.paths == ["/v1/models", "/props?model=qwen3%3A8b"], "each endpoint probed once");

    r = probeWith("ollama", [ok(`{"data":[{"id":"qwen3:8b","owned_by":"library"}]}`),
        ok(`{"capabilities":["completion","thinking","vision"],"parameters":"num_ctx 16384"}`), ok(`{"models":[]}`)]);
    assert(r.caps.window == 16384 && r.caps.windowSource == "Ollama num_ctx", r.caps.windowSource);
    assert(r.caps.thinking.get.format == Format.effort);
    assert(!r.caps.vision.isNull, "vision derived from the same /api/show");
    assert(r.paths == ["/v1/models", "/api/show", "/api/ps"], "/api/show is shared, not repeated");

    r = probeWith("hosted", [ok(`{"data":[{"id":"qwen3:8b","owned_by":"system"}]}`)]);
    assert(r.caps.thinking.isNull && r.paths == ["/v1/models"], "unknown servers get no extra probes");
}

// Stream attempts dropped before any output and retried: their reported
// tokens and credits, and one request each, add up with the final attempt's
// so the totals equal the sum over every attempt (issue #340).
enum spentEvent = `{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":1},"copilot_usage":{"total_nano_aiu":250000000}}`;

/// The totals over a request's attempts: tokens, credits, and requests
/// (each attempt reporting usage plus each one left uncounted).
struct Totals { long input, output; double aic; size_t requests; }

Totals totals(TokenUsage final_, bool finalCounted, RetrySpend retried) pure
{
    import nano.http : addUsage;
    auto u = addUsage(final_, retried.usage);
    return Totals(u.inputTokens, u.outputTokens, u.aic, retried.uncounted + (finalCounted ? 1 : 0));
}

// A retry that fails then succeeds.
unittest
{
    import std.math : isClose;
    auto srv = serve([immutable Reply(200, cutHeaders, sse([spentEvent]) ~ `data: {"choices":[{"delta":{"content":"pa`),
        immutable Reply(200, cutHeaders, `data: {"choices":[{"delta":{"content":"pa`),
        immutable Reply(200, streamHeaders, sse([`{"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}`,
            `{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3},"copilot_usage":{"total_nano_aiu":500000000}}`], true))]);
    auto req = hello();
    auto r = against(srv.url).chat(req, (bool t, string x) {});
    auto seen = srv.finish();
    assert(r.content == "done" && seen.length == 3);
    assert(r.usage.inputTokens == 12, "only the final attempt sizes the context");
    auto t = totals(r.usage, true, r.retried);
    assert(t.input == 22 && t.output == 4 && isClose(t.aic, 0.75), "tokens and credits of every attempt");
    // The first attempt reported usage; the second none; the final its own.
    assert(r.retried.uncounted == 1 && t.requests + 1 == seen.length, "every attempt is one request");
}

// A retry that fails on every attempt.
unittest
{
    import std.math : isClose;
    import nano.http : StreamInterrupted;
    auto srv = serve([immutable Reply(200, cutHeaders, sse([spentEvent]) ~ `data: {"choices":[{"delta":{"content":"pa`),
        immutable Reply(200, cutHeaders, `data: {"choices":[{"delta":{"content":"pa`),
        immutable Reply(200, cutHeaders, sse([`{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":2},`
            ~ `"copilot_usage":{"total_nano_aiu":125000000}}`]) ~ `data: {"choices":[{"delta":{"content":"pa`)]);
    auto c = against(srv.url, true, 10, 2);
    auto req = hello();
    StreamInterrupted dropped;
    try c.chat(req, (bool t, string x) {});
    catch (StreamInterrupted e) dropped = e;
    auto seen = srv.finish();
    assert(dropped !is null && seen.length == 3, "three attempts, all dropped");
    assert(dropped.usage.inputTokens == 11, "the final attempt's own usage");
    auto t = totals(dropped.usage, true, dropped.retried);
    assert(t.input == 21 && t.output == 3 && isClose(t.aic, 0.375), "tokens and credits of every attempt");
    // The first attempt reported usage; the second none; the final its own.
    assert(dropped.retried.uncounted == 1 && t.requests + 1 == seen.length, "every attempt is one request");
}

// A retry whose next attempt fails in the parser (malformed JSON) still
// carries the dropped attempt's spending (issue #340).
unittest
{
    import std.math : isClose;
    import nano.llm : SpendingException;
    auto srv = serve([immutable Reply(200, cutHeaders, sse([spentEvent]) ~ `data: {"choices":[{"delta":{"content":"pa`),
        immutable Reply(200, streamHeaders, "data: {not json\n\n")]);
    auto req = hello();
    SpendingException failed;
    try against(srv.url).chat(req, (bool t, string x) {});
    catch (SpendingException e) failed = e;
    srv.finish();
    assert(failed !is null, "the parser error carries the retried spending");
    assert(failed.retried.usage.inputTokens == 10 && isClose(failed.retried.usage.aic, 0.25));
    assert(failed.next !is null, "the original error stays chained");
}

// The final parse runs after the stream retries: a malformed or error reply
// there still carries the dropped attempts' spending, the usage-reporting
// one and the uncounted one (issue #340). Each provider funnels its final
// parse through `finishCounted`, so these cover the class.
void assertRetriedKept(SpendingException failed, long input, double aic)
{
    import std.math : isClose;
    assert(failed !is null, "the final parse error carries the retried spending");
    assert(failed.retried.usage.inputTokens == input && isClose(failed.retried.usage.aic, aic), "first attempt usage");
    assert(failed.retried.uncounted == 1, "the usage-free dropped attempt is still one request");
}

immutable dropSpent = immutable Reply(200, cutHeaders, sse([spentEvent]) ~ `data: {"choices":[{"delta":{"content":"pa`);
immutable dropBare = immutable Reply(200, cutHeaders, `data: {"choices":[{"delta":{"content":"pa`);

// (a) Chat completions: the retry returns a non-SSE malformed body.
unittest
{
    auto srv = serve([dropSpent, dropBare, immutable Reply(200, "content-type: text/html\r\n", "<html>proxy</html>")]);
    auto req = hello();
    SpendingException failed;
    try against(srv.url).chat(req, (bool t, string x) {});
    catch (SpendingException e) failed = e;
    srv.finish();
    assertRetriedKept(failed, 10, 0.25);
}

// (b) Chat completions: the retry returns a 200 error object.
unittest
{
    auto srv = serve([dropSpent, dropBare,
        immutable Reply(200, "content-type: application/json\r\n", `{"error":{"message":"boom"}}`)]);
    auto req = hello();
    SpendingException failed;
    try against(srv.url).chat(req, (bool t, string x) {});
    catch (SpendingException e) failed = e;
    srv.finish();
    assertRetriedKept(failed, 10, 0.25);
    assert(failed.msg.canFind("boom"), failed.msg);
}

// (c) The Anthropic route: the retry returns a 200 error object.
unittest
{
    import nano.providers.anthropic : AnthropicClient;
    enum spent = `{"type":"message_start","message":{"usage":{"input_tokens":10}}}`;
    enum delta = `{"type":"message_delta","delta":{},"usage":{"output_tokens":1},"copilot_usage":{"total_nano_aiu":250000000}}`;
    auto srv = serve([immutable Reply(200, cutHeaders, sse([spent, delta]) ~ `data: {"type":"cont`),
        immutable Reply(200, cutHeaders, `data: {"type":"cont`),
        immutable Reply(200, "content-type: application/json\r\n", `{"type":"error","error":{"type":"overloaded_error","message":"busy"}}`)]);
    ResolvedProvider p;
    p.name = "test";
    p.model = "some-model";
    p.apiKey = "sk-test";
    p.config.baseUrl = srv.url;
    p.config.stream = true;
    p.config.retryInitialBackoffMs = 1;
    p.config.timeoutSecs = 10;
    p.config.maxRetries = 5;
    auto req = hello();
    SpendingException failed;
    try new AnthropicClient(p).chat(req, (bool t, string x) {});
    catch (SpendingException e) failed = e;
    srv.finish();
    assertRetriedKept(failed, 10, 0.25);
}
