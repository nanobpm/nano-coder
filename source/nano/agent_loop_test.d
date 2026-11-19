/// The turn loop's limits and ordering (agent.rs tests): the turn cap and
/// its headless safety cap, the loop detector, cancel and late steers.
module nano.agent_loop_test;
@safe:

version (unittest):

import std.algorithm : all, canFind, count, filter;
import std.array : array;
import std.conv : to;
import std.file : exists, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.control : Cancelled, Steer, cancelledResponse;
import nano.goal : OutcomeStatus;
import nano.llm;
import nano.mode : AgentMode;
import nano.option : some, unwrap;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.question : QuestionBroker;
import nano.reminders : repeatMaxWarnings, repeatWarnAfter;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;

private:

/// A scripted client that runs `hook(n)` before its n-th call (1-based).
class Hooked : MockClient
{
    void delegate(size_t call) @safe hook;
    this(LLMResponse[] script) { super(script); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (hook !is null) hook(seen.length + 1);
        return super.chat(req, sink);
    }
}

Agent agentFor(LLMClient c)
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    return new Agent(c, reg, Policy.init, "system");
}

/// `n` identical echo calls (the loop detector's input).
LLMResponse[] echoLoop(size_t n)
{
    LLMResponse[] r;
    foreach (i; 1 .. n + 1) r ~= LLMResponse("", "", [ToolCall.fromRaw("c" ~ i.to!string, "echo", `{}`)]);
    return r;
}

/// `n` distinct echo calls (no loop warning).
LLMResponse[] echoStream(size_t n)
{
    LLMResponse[] r;
    foreach (i; 1 .. n + 1)
        r ~= LLMResponse("", "", [ToolCall.fromRaw("c" ~ i.to!string, "echo", `{"text":"pong ` ~ i.to!string ~ `"}`)]);
    return r;
}

// rust: agent.rs::zero_turn_cap_is_unbounded
unittest
{
    auto mock = new MockClient(echoStream(3) ~ LLMResponse("done"));
    auto agent = agentFor(mock);
    agent.maxIterations = 0;
    assert(agent.run("go", new NullEvents) == "done");
    assert(agent.lastStop == StopReason.endTurn && mock.seen.length == 4, "a cap of 0 is unbounded");
}

// Interactive with no cap: only the loop detector ends a runaway turn.
// rust: agent.rs::an_interactive_session_keeps_an_unbounded_zero_cap
unittest
{
    auto mock = new MockClient(echoLoop(20));
    auto agent = agentFor(mock);
    agent.questions = QuestionBroker.make;
    agent.questions.interactive = true;
    agent.maxIterations = 0;
    agent.run("go", new NullEvents);
    assert(agent.lastStop == StopReason.endTurn);
    assert(mock.seen.length == repeatWarnAfter + repeatMaxWarnings);
    assert(agent.hasOutcome && agent.lastOutcome.status == OutcomeStatus.blocked);
}

// rust: agent.rs::auto_mode_disables_the_turn_cap
unittest
{
    auto mock = new MockClient(echoStream(3) ~ LLMResponse("done"));
    auto agent = agentFor(mock);
    agent.maxIterations = 2;
    agent.control.mode = AgentMode.auto_;
    assert(agent.run("go", new NullEvents) == "done", "auto mode runs past the cap");
    assert(mock.seen.length == 4);
}

// Headless, auto mode still stops at the safety cap, even when it is
// switched on mid-turn.
// rust: agent.rs::auto_mode_does_not_disable_the_cap_in_a_headless_turn
// rust: agent.rs::switching_to_auto_mid_turn_keeps_the_headless_safety_cap
unittest
{
    foreach (midTurn; [false, true])
    {
        auto mock = new Hooked(echoStream(headlessSafetyCap + 10));
        auto agent = agentFor(mock);
        agent.maxIterations = headlessSafetyCap + 50;
        if (midTurn) mock.hook = (size_t call) { if (call == 2) agent.control.mode = AgentMode.auto_; };
        else agent.control.mode = AgentMode.auto_;
        agent.run("go", new NullEvents);
        assert(agent.lastStop == StopReason.maxTurnRequests);
        assert(mock.seen.length == headlessSafetyCap);
    }
}

// rust: agent.rs::the_loop_detector_resets_on_a_new_turn
unittest
{
    auto mock = new MockClient(echoLoop(repeatWarnAfter) ~ LLMResponse("first done")
        ~ echoLoop(repeatWarnAfter - 1) ~ LLMResponse("second done"));
    auto agent = agentFor(mock);
    agent.run("go", new NullEvents);
    bool warns(const ref Message m) { return m.role == Role.tool && m.content.canFind("same `echo` call"); }
    assert(agent.messages.count!warns == 1, "one warning in the first turn");
    assert(agent.run("again", new NullEvents) == "second done");
    auto tools = agent.messages.filter!(m => m.role == Role.tool).array;
    assert(tools.length == repeatWarnAfter + repeatWarnAfter - 1);
    assert(tools[repeatWarnAfter .. $].all!(m => !m.content.canFind("same `echo` call")), "a fresh turn");
}

// A cancel during the model call ends the turn as cancelled, and the
// session records it: the same input redelivered gets the same answer.
// rust: agent.rs::cancel_during_model_call_stops_the_turn
unittest
{
    auto dir = buildPath(tempDir, "nano-d-loop-cancel");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto agent = agentFor(new MockClient([]));
    agent.client = new class MockClient
    {
        this() { super([]); }
        override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
        {
            // What a provider does when the cancel lands mid-request.
            agent.control.cancel();
            throw new Cancelled;
        }
    };
    agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    assert(agent.run("hang", new NullEvents, true, "in-1") == cancelledResponse);
    assert(agent.lastStop == StopReason.cancelled);
    auto path = agent.log.unwrap("set above").path;

    import nano.session : restore;
    auto resumed = agentFor(new MockClient([]));
    auto r = restore(path);
    resumed.completedInputs = r.completed.dup;
    assert(resumed.run("hang", new NullEvents, true, "in-1") == cancelledResponse, "not asked again");
}

// A steer that arrives during the last allowed call doesn't displace the
// final answer; it is left for the caller to requeue.
// rust: agent.rs::steer_on_last_iteration_keeps_the_final_answer
unittest
{
    auto mock = new Hooked([LLMResponse("done")]);
    auto agent = agentFor(mock);
    mock.hook = (size_t call) { agent.control.steer("late"); };
    agent.maxIterations = 1;
    assert(agent.run("go", new NullEvents) == "done");
    assert(agent.lastStop == StopReason.endTurn);
    auto pend = agent.control.takePending();
    assert(pend.length == 1, "the late steer is left for the caller");
}

// rust: agent.rs::records_assistant_tool_calls_before_results
unittest
{
    auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{}`)]), LLMResponse("done")]);
    auto agent = agentFor(mock);
    assert(agent.run("ping", new NullEvents) == "done");
    auto second = mock.seen[1];
    assert(second[2].role == Role.assistant && second[2].toolCalls[0].id == "c1");
    assert(second[3].role == Role.tool && second[3].toolCallId == "c1" && second[3].toolName == "echo"
        && second[3].content == "pong");
}
