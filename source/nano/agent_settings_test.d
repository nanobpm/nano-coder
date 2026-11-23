/// The `session_settings` tool (issue #293): the agent reads and adjusts
/// its own session's compaction, within the allowlist, logged and shown.
module nano.agent_settings_test;
@safe:

version (unittest):

import std.algorithm : all, any, canFind, filter, map, startsWith;
import std.array : join;
import std.array : array;
import std.file : exists, readText, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.string : lineSplitter;
import nano.agent;
import nano.llm;
import nano.option : some, unwrap;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;
import ctx = nano.context;
import nano.extract : extractHeader;

private:

LLMResponse call(string id, string args) { return LLMResponse("", "", [ToolCall.fromRaw(id, "session_settings", args)]); }

Agent logged(string name, MockClient mock)
{
    auto dir = buildPath(tempDir, "nano-d-agent-settings-" ~ name);
    if (dir.exists) rmdirRecurse(dir);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    return agent;
}

JSONValue[] records(Agent agent)
{
    JSONValue[] rs;
    foreach (line; readText(agent.log.unwrap("logged").path).lineSplitter) rs ~= parseJSON(line);
    return rs;
}

string[] settingsResults(MockClient mock)
{
    return mock.seen[$ - 1].filter!(m => m.role == Role.tool && m.toolName == "session_settings")
        .map!(m => m.content).array;
}

// get reports the effective settings; set changes this session's mode,
// logs it, and a second change inside the cooldown is refused.
unittest
{
    auto mock = new MockClient([call("g", `{"action":"get"}`),
        call("s1", `{"action":"set","key":"compaction_mode","value":"extract","reason":"huge logs ahead"}`),
        call("s2", `{"action":"set","key":"compaction_mode","value":"smart"}`), LLMResponse("ok")]);
    auto agent = logged("set", mock);
    agent.compactionMode = ctx.CompactionMode.smart;
    agent.harnessVersion = "9.9.9";
    assert(agent.offeredTools.any!(d => d.name == "session_settings"));
    agent.run("go", new NullEvents);
    auto rs = settingsResults(mock);
    assert(rs.length == 3, rs.join("|"));
    assert(rs[0].canFind(`"compaction_mode": "smart"`) && rs[0].canFind(`"context_window"`)
        && rs[0].canFind(`"nano_coder_version": "9.9.9"`), rs[0]);
    assert(rs[1].canFind("smart → extract for this session"), rs[1]);
    assert(rs[2].canFind("can change again"), rs[2]);
    assert(agent.compactionMode == ctx.CompactionMode.extract);
    assert(records(agent).any!(r => r["type"].str == "setting" && r["data"]["key"].str == "compaction_mode"
        && r["data"]["old"].str == "smart" && r["data"]["new"].str == "extract" && r["data"]["reason"].str == "huge logs ahead"));
}

// Security and cost settings are refused, and change nothing.
unittest
{
    auto mock = new MockClient([call("p", `{"action":"set","key":"permissions","value":"yolo"}`),
        call("m", `{"action":"set","key":"model","value":"x/y"}`), LLMResponse("ok")]);
    auto agent = logged("refuse", mock);
    agent.run("go", new NullEvents);
    auto tools = mock.seen[$ - 1].filter!(m => m.role == Role.tool).array;
    assert(tools.length == 2 && tools.all!(t => t.isError && t.content.canFind("can't be changed by the agent")));
    assert(!records(agent).any!(r => r["type"].str == "setting"));
}

// compact_now compacts before the next request (extract: no summary call),
// and the replace record says the agent asked for it.
unittest
{
    auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("e", "echo", `{}`)]),
        call("c", `{"action":"compact_now","mode":"extract","reason":"done with the logs"}`), LLMResponse("continued")]);
    auto agent = logged("compact", mock);
    agent.run("go", new NullEvents);
    assert(mock.seen.length == 3, "no summary request for extract");
    auto last = mock.seen[$ - 1];
    assert(last.any!(m => m.role == Role.user && m.content.startsWith(ctx.smartSummaryPrefix) && m.content.canFind(extractHeader)));
    assert(records(agent).any!(r => r["type"].str == "replace" && r["data"]["mode"].str == "extract"
        && r["data"]["trigger"].str == "agent"));
    assert(records(agent).any!(r => r["type"].str == "setting" && r["data"]["key"].str == "compact_now"));
    assert(agent.compactionMode == ctx.CompactionMode.standard, "compact_now does not change the session mode");
}

// Turning the tool off (as sub-agents do) withdraws it.
unittest
{
    auto agent = logged("off", new MockClient([]));
    agent.settingsTools = false;
    assert(!agent.offeredTools.any!(d => d.name == "session_settings"));
}

// issue #297: a `session_settings` compaction-mode change also writes a
// `settings` record, so a resume restores it.
unittest
{
    auto mock = new MockClient([call("s", `{"action":"set","key":"compaction_mode","value":"extract"}`), LLMResponse("ok")]);
    auto agent = logged("settings-record", mock);
    agent.run("go", new NullEvents);
    assert(records(agent).any!(r => r["type"].str == "settings" && r["data"]["compaction_mode"].str == "extract"));
}

// issue #297: a model switch writes a `settings` record with the new
// provider/model, so a resume restores it; restoring with `logChange = false`
// does not append a duplicate record.
unittest
{
    import nano.session : SessionSettings, restore;
    auto agent = logged("model-record", new MockClient([]));
    SessionSettings prior;
    prior.contextWindow = 50_000;
    agent.logSettings(prior);
    auto other = new MockClient([]);
    agent.useClient(other, ConfiguredWindow.init);
    assert(records(agent).any!(r => r["type"].str == "settings"
        && "model" in r["data"] && r["data"]["model"].str == "mock/mock"
        && "context_window" in r["data"] && r["data"]["context_window"].integer == 0));
    auto before = records(agent).length;
    agent.useClient(new MockClient([]), ConfiguredWindow.init, false);
    assert(records(agent).length == before, "restore switch does not write a duplicate settings record");
    // Restoring the log sees the cleared override (`contextWindow == 0`), not the prior 50_000.
    auto path = agent.log.unwrap("logged").path;
    auto r = restore(path);
    assert(r.settings.model == "mock/mock");
    assert(r.settings.contextWindow == 0);
}

// issue #297: `/subagents off` mid-turn writes a `settings` record, so a
// resume restores the switch.
unittest
{
    auto mock = new MockClient([LLMResponse("ok")]);
    auto agent = logged("subagents-record", mock);
    agent.control.requestSubagents(false);
    agent.run("go", new NullEvents);
    assert(!agent.subagentsOn);
    assert(records(agent).any!(r => r["type"].str == "settings" && "subagents" in r["data"]
        && r["data"]["subagents"].boolean == false));
}

// issue #297: mid-turn `/thinking` writes a `settings` record distinguishing
// `"default"` from `"reset"`, and both round-trip via `sessionSetting`.
unittest
{
    import std.conv : to;
    import nano.result : unwrap;
    import nano.thinking : Thinking, sessionSetting, sessionSettingValue;
    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("ok"), LLMResponse("ok")]);
    auto agent = logged("thinking-record", mock);
    agent.control.requestThinking("high");
    agent.run("go1", new NullEvents);
    assert(!agent.sessionThinking.isNull && agent.sessionThinking.get == Thinking.of("high"));
    agent.control.requestThinking("default");
    agent.run("go2", new NullEvents);
    assert(!agent.sessionThinking.isNull && agent.sessionThinking.get == Thinking.init);
    agent.control.requestThinking("reset");
    agent.run("go3", new NullEvents);
    assert(agent.sessionThinking.isNull);
    string[] loggedThinking;
    foreach (r; records(agent))
        if (r["type"].str == "settings" && "thinking" in r["data"])
            loggedThinking ~= r["data"]["thinking"].str;
    assert(loggedThinking == ["high", "default", "reset"], loggedThinking.to!string);
    // Round-trip check via sessionSetting + sessionSettingValue.
    foreach (v; ["high", "off", "default", "reset"])
    {
        auto parsed = sessionSetting(v);
        assert(!parsed.isErr);
        assert(sessionSettingValue(parsed.unwrap("isOk")) == v);
    }
    assert(sessionSetting("default").unwrap("ok").isNull == false);
    assert(sessionSetting("reset").unwrap("ok").isNull == true);
    assert(sessionSetting("bad level!").isErr);
}
