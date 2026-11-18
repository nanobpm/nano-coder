/// Switching the model: direct switches supersede a queued `/model`, and a
/// queued one applies before every model call, including compaction and
/// its retries (agent.rs tests).
module nano.agent_model_test;
@safe:

version (unittest):

import std.algorithm : canFind, startsWith;
import std.array : replicate;
import std.functional : toDelegate;
import std.json : JSONValue, parseJSON;
import nano.agent;
import nano.llm;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.tools : ToolRegistry;
import ctx = nano.context;

private:

/// A scripted client named `model` that runs `hook(n)` before its n-th call
/// (1-based), e.g. to queue a `/model` while a call is in flight.
class Interfering : MockClient
{
    string model;
    void delegate(size_t call) @safe hook;
    this(string model, LLMResponse[] script) { super(script); this.model = model; }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (hook !is null) hook(seen.length + 1);
        return super.chat(req, sink);
    }
    override string modelName() const { return model; }
}

Agent agentFor(LLMClient c)
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "echoed");
    return new Agent(c, reg, Policy.init, "system");
}

LLMResponse toolCall(string id) { return LLMResponse("", "", [ToolCall.fromRaw(id, "echo", `{}`)]); }

/// Builds a scripted client named after the spec's model, or throws for a
/// provider named `flaky` (as a failing `api_key_command` would).
LLMClient build(string spec, out ConfiguredWindow w)
{
    import std.string : indexOf;
    if (spec.startsWith("flaky/")) throw new Exception("api_key_command `exit 1` failed");
    return new Interfering(spec[spec.indexOf('/') + 1 .. $], [LLMResponse("from " ~ spec)]);
}

// rust: agent.rs::a_direct_model_switch_supersedes_a_stale_queued_request
unittest
{
    auto agent = agentFor(new Interfering("first", [LLMResponse("done")]));
    agent.control.requestModel("mock/stale");
    agent.setModel("mock/direct", toDelegate(&build));
    assert(agent.client.modelName == "direct");
    assert(agent.control.takeModelRequest() is null, "the stale request was cleared");
}

// rust: agent.rs::a_failed_direct_model_switch_still_clears_a_stale_queued_request
unittest
{
    auto agent = agentFor(new Interfering("first", []));
    agent.control.requestModel("mock/leftover");
    bool threw;
    try agent.setModel("flaky/x", toDelegate(&build));
    catch (Exception) threw = true;
    assert(threw, "the unbuildable client fails the switch");
    assert(agent.control.takeModelRequest() is null, "cleared before the failed build");
}

// A spec that can't build a client changes nothing; a valid one still switches.
// rust: agent.rs::failed_model_switch_restores_the_previous_spec
unittest
{
    auto agent = agentFor(new Interfering("gpt-4o-mini", []));
    agent.configuredWindow = 5_000;
    try agent.setModel("flaky/some-model", toDelegate(&build));
    catch (Exception e) assert(e.msg.canFind("api_key_command"));
    assert(agent.client.modelName == "gpt-4o-mini" && agent.configuredWindow == 5_000, "unchanged");
    agent.setModel("mock/other-model", toDelegate(&build));
    assert(agent.client.modelName == "other-model" && agent.configuredWindow == 0);
}

// A `/model` typed while a tool call runs applies at the next model call.
// (Recording both specs in the recents list is the REPL's `switchModel`.)
// rust: agent.rs::model_switch_during_tool_call_applies_at_the_next_model_call
unittest
{
    auto first = new Interfering("interfering", [toolCall("c1"), LLMResponse("never")]);
    auto agent = agentFor(first);
    agent.onModelRequest = (string spec) { ConfiguredWindow w; agent.useClient(build(spec, w), w); };
    first.hook = (size_t call) { if (call == 1) agent.control.requestModel("mock/switched"); };
    assert(agent.run("do it", new NullEvents) == "from mock/switched");
    assert(agent.lastStop == StopReason.endTurn);
    assert(agent.client.modelName == "switched" && first.seen.length == 1);
    assert(agent.control.takeModelRequest() is null, "consumed");
}

// A `/model` left queued after a turn's last call applies before /compact's
// summary: the old client has only the turn's two replies scripted.
// rust: agent.rs::model_switch_queued_before_manual_compaction_applies_to_the_summary
unittest
{
    auto first = new Interfering("old", [toolCall("c1"), LLMResponse("done")]);
    auto agent = agentFor(first);
    agent.onModelRequest = (string spec) { ConfiguredWindow w; agent.useClient(build(spec, w), w); };
    agent.run("ping", new NullEvents);
    agent.control.requestModel("mock/summarizer");
    CompactReport report;
    assert(agent.compact(report) && report.summarized > 0);
    assert(report.fallback is null, "the summary came from the new client");
    assert(agent.client.modelName == "summarizer");
    assert(agent.control.takeModelRequest() is null);
    assert(first.seen.length == 2, "the summary did not go to the old client");
}

// rust: agent.rs::model_switch_queued_during_a_call_applies_before_threshold_compaction
unittest
{
    auto first = new Interfering("old", [toolCall("b1"), LLMResponse("done")]);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "big", parseJSON(`{"type":"object"}`)), (JSONValue a) => "x".replicate(8_000));
    auto agent = new Agent(first, reg, Policy.init, "system");
    agent.configuredWindow = 3_000;
    agent.autoCompactThreshold = 0.5;
    agent.onModelRequest = (string spec) {
        // The new model summarizes, then answers.
        agent.useClient(new Interfering("summarizer", [LLMResponse("SUMMARY"), LLMResponse("done")]), ConfiguredWindow(3_000));
    };
    first.hook = (size_t call) { if (call == 1) agent.control.requestModel("mock/summarizer"); };
    assert(agent.run("go", new NullEvents) == "done");
    assert(agent.lastStop == StopReason.endTurn);
    assert(agent.client.modelName == "summarizer" && first.seen.length == 1);
    assert(agent.control.takeModelRequest() is null);
}

// A `/model` queued during the call that overflows applies to the compaction
// and the retry: nothing after the switch reaches the old client.
// rust: agent.rs::model_switch_queued_during_an_overflow_applies_to_the_compaction_and_retry
unittest
{
    auto first = new Interfering("scripted", [toolCall("c1"),
        LLMResponse("!error:HTTP 400: maximum context length is 4096 tokens.")]);
    auto agent = agentFor(first);
    LLMResponse[] newScript = [LLMResponse("SUMMARY"), LLMResponse("recovered")];
    auto second = new Interfering("x", newScript);
    agent.onModelRequest = (string spec) { agent.useClient(second, ConfiguredWindow.init); };
    first.hook = (size_t call) { if (call == 2) agent.control.requestModel("flaky/x"); };
    assert(agent.run("hi", new NullEvents) == "recovered");
    assert(agent.client.modelName == "x");
    assert(agent.control.takeModelRequest() is null);
    assert(first.seen.length == 2, "tool, overflow; the rest on the new client");
    assert(second.seen.length == 2 && second.seen[0][0].content.startsWith(ctx.summarySystemPrompt));
}

// The summary is rejected over an output cap while a `/model` is queued: the
// retry goes to the new model.
// rust: agent.rs::a_compaction_summary_retry_honours_a_pending_model_switch
unittest
{
    auto first = new Interfering("scripted", [toolCall("c1"), LLMResponse("done"),
        LLMResponse("!error:max_tokens: 12288 > 8000, which is the maximum allowed number of output tokens")]);
    auto agent = agentFor(first);
    auto second = new Interfering("switched", [LLMResponse("SUMMARY: on the new model")]);
    agent.onModelRequest = (string spec) { agent.useClient(second, ConfiguredWindow.init); };
    first.hook = (size_t call) { if (call == 3) agent.control.requestModel("mock/switched"); };
    agent.run("ping", new NullEvents);
    CompactReport report;
    assert(agent.compact(report));
    assert(report.fallback is null, "the summary succeeded on the new model");
    assert(first.seen.length == 3, "only the rejected attempt hit the old model");
    assert(agent.client.modelName == "switched" && second.seen.length == 1);
    assert(agent.control.takeModelRequest() is null);
}

// A spec that fails to build at apply time is reported and dropped; the turn
// finishes on the current model.
// rust: agent.rs::model_switch_to_an_unbuildable_spec_drops_the_request_and_reports_it
unittest
{
    auto first = new Interfering("interfering", [toolCall("c1"), LLMResponse("done")]);
    auto agent = agentFor(first);
    string[] failures;
    agent.onModelRequest = (string spec) {
        try { ConfiguredWindow w; agent.useClient(build(spec, w), w); }
        catch (Exception e) failures ~= spec ~ ": " ~ e.msg;
    };
    first.hook = (size_t call) { if (call == 1) agent.control.requestModel("flaky/x"); };
    assert(agent.run("hi", new NullEvents) == "done");
    assert(agent.lastStop == StopReason.endTurn);
    assert(agent.client.modelName == "interfering", "unchanged");
    assert(agent.control.takeModelRequest() is null, "dropped, not re-queued");
    assert(failures.length == 1 && failures[0].startsWith("flaky/x: ") && failures[0].canFind("api_key_command"));
}
