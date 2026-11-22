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
    override string modelName() pure const { return model; }
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

/// A scripted client whose capability probe reports `window` tokens once
/// `gate` opens, counting its probes and whether they asked for the window.
class Probing : Interfering, CapabilityProbe
{
    import nano.safeio : Shared;
    size_t window;
    Shared!bool gate;
    Shared!int probes, windowProbes;
    this(string model, LLMResponse[] script, size_t window, Shared!bool gate, Shared!int probes, Shared!int windowProbes)
    {
        super(model, script);
        this.window = window;
        this.gate = gate;
        this.probes = probes;
        this.windowProbes = windowProbes;
    }
    Capabilities probeCapabilities(bool withWindow = true)
    {
        gate.await((ref const bool open) => open, (ref bool _) {});
        probes.update((ref int n) { n++; });
        if (withWindow) windowProbes.update((ref int n) { n++; });
        Capabilities c;
        c.maxOutput = 1_234;
        if (withWindow) { c.window = window; c.windowSource = model; }
        return c;
    }
}

/// Probe counters and a gate shared by the switched-to client and the fresh
/// clients the agent builds for its background probes.
struct Probes
{
    import nano.safeio : Shared;
    Shared!bool gate;
    Shared!int probes, windowProbes;
    static Probes make(bool open)
    {
        return Probes(Shared!bool.make(open), Shared!int.make(0), Shared!int.make(0));
    }
    Probing client(string model, LLMResponse[] script, size_t window)
    {
        return new Probing(model, script, window, gate, probes, windowProbes);
    }
}

// A mid-turn `/model` to a spec with a configured window: the window is
// authoritative at once, only the thinking half is probed, and in the background.
// rust: agent.rs::mid_turn_model_switch_with_a_configured_window_skips_the_probe
unittest
{
    import core.time : seconds;
    auto p = Probes.make(true);
    auto first = new Interfering("first", [toolCall("c1")]);
    auto agent = agentFor(first);
    agent.probeClient = (string spec) => cast(LLMClient) p.client("probed", null, 4_096);
    agent.onModelRequest = (string spec) {
        agent.useClient(p.client("probed", [LLMResponse("done")], 4_096), ConfiguredWindow(111_111, "provider context_window"));
    };
    first.hook = (size_t call) { if (call == 1) agent.control.requestModel("mock/probed"); };
    assert(agent.run("hi", new NullEvents) == "done");
    assert(agent.lastStop == StopReason.endTurn && agent.client.modelName == "probed", "switched mid-turn");
    assert(agent.settleProbes(5.seconds));
    string source;
    assert(agent.contextWindow(source) == 111_111 && source == "provider context_window", source);
    assert(agent.capabilities.window == 0, "a configured window skips the endpoint's window probe");
    assert(p.probes.get == 1 && p.windowProbes.get == 0, "only the thinking half ran");
    assert(agent.capabilities.maxOutput == 1_234, "the rest of the probe is published");
}

// Without a configured window the probe still runs, but on a background
// thread: the next model call doesn't wait for it, and the result is
// published once it lands.
// rust: agent.rs::mid_turn_model_switch_without_a_configured_window_probes_in_the_background
unittest
{
    import core.time : seconds;
    auto p = Probes.make(false); // the endpoint doesn't answer until the turn is over
    auto first = new Interfering("first", [toolCall("c1")]);
    auto agent = agentFor(first);
    agent.probeClient = (string spec) => cast(LLMClient) p.client("probed", null, 4_096);
    agent.onModelRequest = (string spec) {
        agent.useClient(p.client("probed", [LLMResponse("done")], 4_096), ConfiguredWindow.init);
    };
    first.hook = (size_t call) { if (call == 1) agent.control.requestModel("mock/probed"); };
    assert(agent.run("hi", new NullEvents) == "done", "the turn finished while the probe was stalled");
    assert(agent.client.modelName == "probed");
    string source;
    agent.contextWindow(source);
    assert(source == "default" || source == "known for the model name", source);
    p.gate.update((ref bool open) { open = true; });
    assert(agent.settleProbes(5.seconds));
    assert(agent.contextWindow(source) == 4_096 && source == "reported by the endpoint (probed)", source);
    assert(p.windowProbes.get == 1);
}

// A probe for one model that lands after a later switch must not overwrite
// the newer model's reports.
// rust: agent.rs::a_stale_background_probe_is_discarded_after_a_later_switch
unittest
{
    import core.time : seconds;
    auto slow = Probes.make(false);
    auto fast = Probes.make(true);
    auto agent = agentFor(new Interfering("first", []));
    agent.probeClient = (string spec) => cast(LLMClient) (spec.canFind("slow")
        ? slow.client("slow", null, 999) : fast.client("fast", null, 4_096));
    agent.onModelRequest = (string spec) {
        auto c = spec.canFind("slow") ? slow.client("slow", null, 999) : fast.client("fast", null, 4_096);
        agent.useClient(c, ConfiguredWindow.init);
    };
    agent.control.requestModel("mock/slow");
    assert(agent.applyModelRequest());
    agent.control.requestModel("mock/fast");
    assert(agent.applyModelRequest());
    assert(agent.settleProbes(5.seconds), "the stale probe is not waited for");
    assert(agent.capabilities.window == 4_096);
    slow.gate.update((ref bool open) { open = true; });
    slow.probes.await((ref const int n) => n == 1, (ref int _) {}); // the stale probe finished
    agent.collectProbes();
    assert(agent.capabilities.window == 4_096 && agent.capabilities.windowSource == "fast",
        "the stale probe did not overwrite the live model's window");
}

/// Events that count summary starts and usage reports, to assert a
/// threshold compaction in `prepareCall` notifies its consumers.
class CountingEvents : NullEvents
{
    size_t summaries, usages;
    override void summaryStart() { summaries++; }
    override void usage(TokenUsage u) { usages++; }
}

string bigText()
{
    string big;
    foreach (_; 0 .. 1_000) big ~= "0123456789";
    return big;
}

// A threshold compaction triggered by the recheck after applying a queued
// `/model` forwards the turn's events: the summary's generation and usage
// reach the renderer (PR #260 review).
unittest
{
    auto first = new Interfering("first", [toolCall("c1")]);
    auto agent = agentFor(first);
    auto small = new Interfering("small", [LLMResponse("SUM"), LLMResponse("done")]);
    agent.onModelRequest = (string spec) { agent.useClient(small, ConfiguredWindow(4_000, "test")); };
    first.hook = (size_t call) { if (call == 1) agent.control.requestModel("mock/small"); };
    agent.compactionPinRequests = false;
    auto big = bigText();
    agent.messages ~= [Message.user(big), Message.assistant(big), Message.user("q"), Message.assistant("a")];
    auto ev = new CountingEvents;
    assert(agent.run("go", ev) == "done");
    assert(small.seen.length == 2 && small.seen[0][0].content == ctx.summarySystemPrompt,
        "the recheck compacted on the switched model");
    assert(ev.summaries == 1, "summaryStart fired for the recheck compaction");
    assert(ev.usages >= 2, "the summary's usage and the reply's usage both reported");
}

// A background probe that lands during `applyModelRequest` can shrink the
// window even when no model request is queued: the threshold is rechecked
// unconditionally, so an oversized prompt is never sent (PR #260 review).
unittest
{
    import nano.safeio : Shared;
    auto p = Probes.make(false);
    auto agent = agentFor(new Interfering("first", [LLMResponse("unused")]));
    Interfering probed;
    agent.probeClient = (string spec) => cast(LLMClient) p.client("probed", null, 4_096);
    agent.onModelRequest = (string spec) {
        probed = p.client("probed", [LLMResponse("SUM"), LLMResponse("done")], 4_096);
        agent.useClient(probed, ConfiguredWindow.init);
    };
    // The switch happens before the turn (e.g. typed at the prompt while the
    // previous turn ran), so its probe is already in flight at prepareCall.
    agent.control.requestModel("mock/probed");
    assert(agent.applyModelRequest());
    agent.compactionPinRequests = false;
    auto big = bigText();
    agent.messages ~= [Message.user(big), Message.assistant(big), Message.user("q"), Message.assistant("a")];
    assert(!agent.overThreshold(), "under the default window's threshold until the probe lands");
    // The probe's result must land after prepareCall's first threshold check
    // but before its apply: only the unconditional recheck can catch it.
    // Keep the probe gated until the first check has read the state (the
    // hook at agent.d:813), then wait for the worker to finish there — never
    // block inside the publish hook: a probe that completes before the first
    // collection publishes on the agent thread, and blocking there deadlocks
    // the test against the very check hook that would release it.
    agent.onThresholdChecked = {
        p.gate.update((ref bool open) { open = true; });
        p.probes.await((ref const int n) => n == 1, (ref int _) {});
    };
    auto ev = new CountingEvents;
    assert(agent.run("go", ev) == "done");
    assert(probed !is null && probed.seen.length == 2 && probed.seen[0][0].content == ctx.summarySystemPrompt,
        "the probe-shrunk window triggered a compaction before the prompt went out");
    assert(ev.summaries == 1 && ev.usages >= 2, "the compaction notified its consumers");
}
