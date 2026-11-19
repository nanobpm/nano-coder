/// Replay (ACP session/load) after compaction (agent.rs tests): the real
/// pre-compaction turns are shown in place of the synthetic summary, across
/// repeated and mid-turn compactions and a resume from the log.
module nano.agent_replay_test;
@safe:

version (unittest):

import std.algorithm : canFind, count, filter, map;
import std.array : array, replicate;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.llm;
import nano.option : Option, some;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : SessionLog, restore;
import nano.tools : ToolRegistry;

private:

const(string)[] users(const(Message)[] ms) { return ms.filter!(m => m.role == Role.user).map!(m => m.content).array; }

Agent agentWith(LLMResponse[] script)
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("big", "big", parseJSON(`{"type":"object"}`)), (JSONValue a) => "x".replicate(8_000));
    return new Agent(new MockClient(script), reg, Policy.init, "sys");
}

bool compactNow(Agent agent)
{
    CompactReport report;
    return agent.compact(report);
}

// rust: agent.rs::replay_history_replays_every_user_message
unittest
{
    auto agent = agentWith([]);
    agent.messages ~= [Message.user("same"), Message.assistant("first answer"), Message.user("same")];
    assert(users(agent.replayMessages) == ["same", "same"]);
}

// After a compaction the replay shows the real turn, every time, and never
// the summary; a reset drops the stash. (Rust resets it by replacing the
// system prompt; D's analogue is the session restart.)
// rust: agent.rs::replay_history_after_compaction_restores_real_turns_not_summary
unittest
{
    auto agent = agentWith([LLMResponse("done"), LLMResponse("SUMMARY: pinged once")]);
    agent.run("ping", new NullEvents);
    assert(compactNow(agent));
    assert(agent.messages.canFind!(m => m.role == Role.user && m.content.canFind("SUMMARY")));
    assert(!users(agent.messages).canFind("ping"));
    foreach (_; 0 .. 2)
    {
        auto shown = users(agent.replayMessages);
        assert(shown.canFind("ping") && !shown.canFind!(t => t.canFind("SUMMARY")), shown[0]);
    }
    agent.restart("fresh prompt", Option!SessionLog.init);
    assert(!users(agent.replayMessages).canFind("ping"), "a reset does not resurrect the stash");
}

// rust: agent.rs::replay_after_repeated_compaction_preserves_the_original_turns
unittest
{
    auto agent = agentWith([LLMResponse("r1"), LLMResponse("SUMMARY: one"), LLMResponse("r2"), LLMResponse("SUMMARY: two")]);
    agent.run("ping", new NullEvents);
    assert(compactNow(agent));
    agent.run("pong", new NullEvents);
    assert(compactNow(agent));
    assert(!users(agent.messages).canFind("ping") && !users(agent.messages).canFind("pong"));
    auto shown = users(agent.replayMessages);
    assert(shown.canFind("ping") && shown.canFind("pong"), "both compactions' turns are kept");
    assert(!shown.canFind!(t => t.canFind("SUMMARY")), "no summary is shown");
}

// An input folded mid-turn is restated after the summary; the replay shows it once.
// rust: agent.rs::replay_after_mid_turn_compaction_shows_the_folded_input_once
unittest
{
    auto agent = agentWith([LLMResponse("", "", [ToolCall.fromRaw("b1", "big", `{}`)]), LLMResponse("SUMMARY"),
        LLMResponse("done")]);
    agent.configuredWindow = 3_000;
    agent.autoCompactThreshold = 0.5;
    agent.run("go", new NullEvents);
    assert(users(agent.messages).canFind!(t => t.canFind("SUMMARY")), "the turn compacted");
    assert(users(agent.replayMessages).count("go") == 1, "the folded input is replayed once");
}

// The stash and the restated index survive a resume from the log, a
// repeated compaction logging only its delta.
unittest
{
    auto dir = buildPath(tempDir, "nano-d-agent-replay");
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto agent = agentWith([LLMResponse("r1"), LLMResponse("SUMMARY: one"), LLMResponse("r2"), LLMResponse("SUMMARY: two")]);
    auto log = new SessionLog(dir, "mock/m", "/w");
    agent.log = some(log);
    log.append(agent.messages[0]);
    agent.run("ping", new NullEvents);
    assert(compactNow(agent));
    agent.run("pong", new NullEvents);
    assert(compactNow(agent));
    auto r = restore(log.path);
    assert(r.replayStash.length == agent.replayStash.length, "the stash is rebuilt from the log");
    assert(users(r.replayStash) == ["ping", "pong"]);
}
