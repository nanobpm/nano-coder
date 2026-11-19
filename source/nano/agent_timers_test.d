/// Agent timers and plan: idle firing, disabled timers, rollback on a failed persist.
module nano.agent_timers_test;
@safe:

version (unittest):
private:

import std.json : parseJSON;
import nano.agent;
import nano.llm;
import nano.option : some;
import nano.permissions : Policy;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;

// rust: agent.rs::idle_firing_resets_the_pending_nudge_counter
// rust: agent.rs::disabled_timers_neither_fire_nor_nudge_on_a_turn
unittest
{
    import nano.providers.mock : MockClient;
    import nano.timers : pendingNudgeEvery;
    import std.algorithm : all, canFind;
    long clock = 1_000_000;
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    agent.now = () => clock;
    agent.stepsSinceTimerNote = pendingNudgeEvery - 1;
    agent.timers.apply("timer_set", parseJSON(`{"after": "30m", "note": "check CI"}`), clock);
    clock += 31 * 60;
    string notice;
    assert(agent.takeFiredTimers(notice).length, "fired via idle delivery");
    assert(agent.stepsSinceTimerNote == 0, "a fresh firing restarts the nudge interval");

    auto mock = new MockClient([LLMResponse("done")]);
    auto off = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    off.now = () => clock;
    off.timers.apply("timer_set", parseJSON(`{"after": "30m", "note": "check CI"}`), clock);
    clock += 31 * 60;
    off.timerTools = false;
    off.run("look", new NullEvents);
    assert(mock.seen.all!(req => req.all!(m => !m.content.canFind("check CI"))), "a disabled timer neither fires nor nudges");
    assert(off.timers.items.length == 1 && !off.timers.pending.length);
}

// A tool change the session log fails to record is rolled back.
// rust: agent.rs::a_timer_tool_persistence_failure_rolls_the_live_timers_back
// rust: agent.rs::a_plan_tool_persistence_failure_rolls_the_live_plan_back
unittest
{
    import nano.providers.mock : MockClient;
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-persist-rollback");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    long clock = 1_000_000;
    agent.now = () => clock;
    auto log = new SessionLog(dir, "mock/m", "/w");
    agent.log = some(log);
    agent.runTimerTool("timer_set", parseJSON(`{"after": "30m", "note": "check CI"}`));
    assert(agent.timers.items.length == 1);
    log.failNextWrite = true;
    bool threw;
    try agent.runTimerTool("timer_cancel", parseJSON(`{"id": 1}`));
    catch (Exception) threw = true;
    assert(threw && agent.timers.items.length == 1, "a failed persist keeps the live timer");
    agent.runTimerTool("timer_cancel", parseJSON(`{"id": 1}`));
    assert(agent.timers.empty);

    agent.runPlanTool("plan_add", parseJSON(`{"items": ["one"]}`));
    auto before = agent.plan.toJSON.toString;
    log.failNextWrite = true;
    threw = false;
    try agent.runPlanTool("plan_add", parseJSON(`{"items": ["two"]}`));
    catch (Exception) threw = true;
    assert(threw && agent.plan.toJSON.toString == before, "a failed persist keeps the live plan");
}

// rust: agent.rs::timers_survive_resume_and_restart_clears_them
unittest
{
    import nano.providers.mock : MockClient;
    import nano.session : restore;
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-timers-resume");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    long clock = 1_000_000;
    agent.now = () => clock;
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    agent.runTimerTool("timer_set", parseJSON(`{"after": "1h", "note": "check CI"}`));

    auto resumed = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    auto r = restore(log.path);
    resumed.loadRestored(r, some(new SessionLog(log.path)));
    assert(resumed.timers.items.length == 1 && resumed.timers.items[0].note == "check CI");
    resumed.restart("sys", typeof(resumed.log).init);
    assert(resumed.timers.empty);
}

// rust: agent.rs::a_firing_persistence_failure_rolls_the_due_timers_back
unittest
{
    import nano.providers.mock : MockClient;
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-fire-rollback");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    long clock = 1_000_000;
    agent.now = () => clock;
    auto log = new SessionLog(dir, "mock/m", "/w");
    agent.log = some(log);
    agent.runTimerTool("timer_set", parseJSON(`{"after": "5m", "note": "check CI"}`));
    clock += 600;
    log.failNextWrite = true;
    string notice;
    bool threw;
    try agent.takeFiredTimers(notice);
    catch (Exception) threw = true;
    assert(threw && agent.timers.items.length == 1 && !agent.timers.pending.length, "still due");
    assert(agent.takeFiredTimers(notice).length && agent.timers.pending.length == 1);
}
