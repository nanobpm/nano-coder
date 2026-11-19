/// Idle compaction (Rust #186, issue #182): the auto-compaction run at the
/// idle prompt, once per threshold crossing, never below the threshold.
module nano.agent_idle_test;

@safe:

version (unittest):

import std.algorithm : canFind, startsWith;
import std.array : replicate;
import nano.agent;
import nano.llm;
import nano.control : Cancelled;
import nano.mode : AgentMode;
import nano.tools : ToolRegistry;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;

private:

/// A mock that cancels the turn on its `at`-th call (Esc Esc mid-summary).
class CancellingMock : MockClient
{
    size_t calls, at;
    Agent agent;
    this(LLMResponse[] script, size_t at) { super(script); this.at = at; }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (++calls == at)
        {
            seen ~= [Message[].init];
            agent.control.cancel();
            throw new Cancelled;
        }
        return super.chat(req, sink);
    }
}

/// An agent left idle above the threshold: the turn ran with auto-compaction
/// off, then it is switched back on as if the turn crossed the threshold.
Agent idleAboveThreshold(MockClient mock)
{
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    agent.configuredWindow = 3_000;
    agent.autoCompact = false;
    agent.compactionPinRequests = false;
    assert(agent.run("x ".replicate(4_000), new NullEvents) == "ok");
    agent.autoCompact = true;
    agent.autoCompactThreshold = 0.5;
    return agent;
}

// rust: agent/idle_compact.rs::armed_until_spent_then_only_after_real_growth
unittest
{
    IdleCompactGate gate;
    assert(gate.armed(90_000, 100_000), "a fresh gate is armed");
    gate.spend(90_000);
    assert(!gate.armed(90_000, 100_000), "a spent gate does not retry at the same size");
    assert(!gate.armed(100_000, 100_000), "nor after growth inside the hysteresis band");
    assert(gate.armed(100_001, 100_000), "a new crossing re-arms it");
    gate.reset();
    assert(gate.armed(1, 100_000), "a compaction or reset re-arms it");
}

// rust: agent.rs::idle_compaction_runs_once_per_crossing
unittest
{
    auto agent = idleAboveThreshold(new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY")]));
    assert(agent.idleCompactDue(), "idle above the threshold is due");
    IdleCompactReport report;
    assert(agent.runIdleCompaction(report), "compacted");
    assert(report.percentBefore > 50, report.toString);
    assert(report.percentAfter < report.percentBefore, report.toString);
    assert(report.toString.startsWith("compacted while idle (was "), report.toString);
    assert(!agent.idleCompactDue(), "not again until usage recrosses the floor");
}

// rust: agent.rs::idle_compaction_is_off_without_idle_or_auto_compact
unittest
{
    auto agent = idleAboveThreshold(new MockClient([LLMResponse("ok")]));
    assert(agent.idleCompactDue());
    agent.idleCompact = false;
    assert(!agent.idleCompactDue(), "idle_compact = false");
    agent.idleCompact = true;
    agent.autoCompact = false;
    assert(!agent.idleCompactDue(), "auto_compact = false turns it off too");
    agent.autoCompact = true;
    agent.configuredWindow = 100_000;
    assert(!agent.idleCompactDue(), "below the threshold: never compacts early");
}

// rust: agent.rs::idle_compaction_never_runs_below_the_configured_threshold
unittest
{
    auto agent = idleAboveThreshold(new MockClient([LLMResponse("ok")]));
    auto tokens = agent.estimateContextTokens();
    // A window where the output reservation puts the limit under `tokens`,
    // yet tokens are under 99% of it.
    agent.maxTokens = 8_192; // an output reservation to subtract
    // Just above the reserve (4096 + window/50), so it is subtracted.
    agent.configuredWindow = 4_300;
    assert(tokens > 300 && tokens < 4_000, "the setup's context fits the arithmetic");
    agent.autoCompactThreshold = 0.99;
    assert(agent.overThreshold(), "the reservation trips the mid-turn rescue");
    assert(tokens < agent.contextWindow() * 0.99, "usage is under the configured threshold");
    assert(!agent.idleCompactDue(), "idle compaction waits for the configured threshold");
    agent.autoCompactThreshold = 0.5;
    assert(agent.idleCompactDue(), "past the configured threshold it is due");
}

// rust: agent.rs::idle_poll_cache_is_keyed_on_the_offered_tool_set
unittest
{
    auto agent = idleAboveThreshold(new MockClient([LLMResponse("ok")]));
    assert(agent.idleCompactDuePolled());
    // A cached "below threshold" estimate under a different mode is not served.
    agent.autoCompactThreshold = 0.99;
    agent.configuredWindow = 1_000_000;
    assert(!agent.idleCompactDuePolled());
    agent.configuredWindow = 3_000;
    agent.autoCompactThreshold = 0.5;
    auto other = agent.control.mode == AgentMode.plan ? AgentMode.normal : AgentMode.plan;
    agent.control.mode = other;
    assert(agent.idleCompactDuePolled(), "a mode switch re-estimates instead of serving a stale entry");
}

// rust: agent.rs::a_cancelled_idle_compaction_is_not_retried_on_the_same_crossing
unittest
{
    // Call 1 is the turn; call 2 is the idle summary, which Esc Esc cancels.
    auto mock = new CancellingMock([LLMResponse("ok")], 2);
    auto agent = idleAboveThreshold(mock);
    mock.agent = agent;
    assert(agent.idleCompactDue());
    auto before = agent.estimateContextTokens();
    IdleCompactReport report;
    assert(!agent.runIdleCompaction(report), "cancelled");
    assert(mock.calls == 2, "the summary call was made, then cancelled");
    assert(agent.estimateContextTokens() == before, "nothing was folded");
    assert(!agent.idleCompactDue(), "a cancelled attempt spends the crossing");
    assert(!agent.idleCompactDuePolled(), "the polled check agrees");
    // A new conversation starts a fresh crossing.
    agent.resetIdleCompaction();
    assert(agent.idleCompactDue(), "a reset re-arms the gate");
    assert(agent.idleCompactDuePolled(), "and the polled cache was invalidated");
}
