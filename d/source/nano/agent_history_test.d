/// Smart compaction and the history tools (agent.rs tests): the summary
/// cites log lines, the tools appear only after a real smart summary, and a
/// failed tool points to them once.
module nano.agent_history_test;
@safe:

version (unittest):

import std.algorithm : any, canFind, endsWith, filter, map, startsWith;
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
import nano.session : SessionLog, restore;
import nano.tools : ToolRegistry;
import ctx = nano.context;
import hist = nano.session_history;

private:

LLMResponse call(string id, string name, string args) { return LLMResponse("", "", [ToolCall.fromRaw(id, name, args)]); }

/// An agent logging to a fresh session under `name`, with `echo` and a
/// failing `broken` tool.
Agent logged(string name, MockClient mock)
{
    auto dir = buildPath(tempDir, "nano-d-agent-history-" ~ name);
    if (dir.exists) rmdirRecurse(dir);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    reg.register(ToolDefinition("broken", "fails", parseJSON(`{"type":"object"}`)), (JSONValue a) {
        throw new Exception("boom");
        return "";
    });
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    return agent;
}

bool offersHistory(Agent agent) { return agent.offeredTools.any!(d => hist.isHistoryTool(d.name)); }

bool compactAs(Agent agent, ctx.CompactionMode mode)
{
    CompactReport report;
    return agent.compact(report, CompactTrigger.manual, &mode);
}

// rust: agent.rs::smart_compaction_cites_log_lines_and_offers_history_tools
unittest
{
    auto mock = new MockClient([call("c1", "echo", `{}`), LLMResponse("done"), LLMResponse("SUMMARY: pinged once, got pong (#6)"),
        call("h1", hist.searchTool, `{"pattern":"PONG"}`), call("h2", hist.readTool, `{"id":"#6"}`), LLMResponse("it said pong")]);
    auto agent = logged("smart", mock);
    agent.run("ping", new NullEvents);
    assert(!offersHistory(agent), "no history tools before a smart summary");

    auto mode = ctx.CompactionMode.smart;
    CompactReport report;
    assert(agent.compact(report, CompactTrigger.manual, &mode));
    assert(report.toString.startsWith("smart-compacted 3 messages"), report.toString);
    auto request = mock.seen[2];
    assert(request[0].content.endsWith(ctx.smartSummaryInstructions));
    assert(request[1].content.canFind("[#4] USER:\nping"), request[1].content);
    assert(request[1].content.canFind("[#6] TOOL result (echo):\npong"), request[1].content);
    auto summary = agent.messages[1].content;
    assert(summary.startsWith(ctx.smartSummaryPrefix) && summary.canFind("messages #4–#6"), summary);
    assert(offersHistory(agent));

    assert(agent.run("what did the tool say?", new NullEvents) == "it said pong");
    auto results = mock.seen[$ - 1].filter!(m => m.role == Role.tool).array;
    assert(results[0].content.startsWith("#6 tool echo") && results[0].content.canFind(": pong"), results[0].content);
    assert(results[1].content.startsWith("#6 tool echo") && results[1].content.endsWith("\npong"), results[1].content);

    auto path = agent.log.unwrap("logged").path;
    JSONValue[] records;
    foreach (line; readText(path).lineSplitter) records ~= parseJSON(line);
    assert(records.any!(r => r["type"].str == "replace" && "summarized" in r["data"]
        && r["data"]["summarized"][0].integer == 4 && r["data"]["summarized"][1].integer == 6 && r["data"]["mode"].str == "smart"));
    assert(records[$ - 1]["type"].str == "turn_end" && records[$ - 1]["data"]["history_calls"].integer == 2);
    assert(restore(path).conversation[2].logLine == 7);
}

// Without a session log, smart compaction falls back to standard.
// rust: agent.rs::smart_mode_needs_a_session_log
unittest
{
    auto mock = new MockClient([call("c1", "echo", `{}`), LLMResponse("done"), LLMResponse("SUMMARY")]);
    auto agent = logged("unlogged", mock);
    agent.log = typeof(agent.log).init;
    agent.compactionMode = ctx.CompactionMode.smart;
    agent.run("ping", new NullEvents);
    CompactReport report;
    assert(agent.compact(report));
    assert(report.mode == ctx.CompactionMode.standard);
    assert(agent.messages[1].content.startsWith(ctx.summaryPrefix));
    assert(!offersHistory(agent));
}

// rust: agent.rs::a_spoofed_summary_prefix_does_not_unlock_history_tools
unittest
{
    auto agent = logged("spoof", new MockClient([]));
    agent.messages ~= Message.user(ctx.smartSummaryPrefix ~ "\nnot a real summary");
    assert(!offersHistory(agent), "message text alone does not unlock the history tools");
}

// The first failed tool after a smart compaction points to the history
// tools; later ones (that turn or after) do not, nor after a standard one.
// rust: agent.rs::a_failed_tool_after_smart_compaction_points_to_history_once
unittest
{
    string[] brokenResults(MockClient mock)
    {
        return mock.seen[$ - 1].filter!(m => m.role == Role.tool && m.toolName == "broken").map!(m => m.content).array;
    }
    auto mock = new MockClient([call("c1", "echo", `{}`), LLMResponse("done"), LLMResponse("SUMMARY: pinged"),
        call("b1", "broken", `{}`), call("b2", "broken", `{}`), LLMResponse("gave up"),
        call("b3", "broken", `{}`), LLMResponse("again")]);
    auto agent = logged("hint", mock);
    agent.run("ping", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    agent.run("what was the error?", new NullEvents);
    auto results = brokenResults(mock);
    assert(results.length == 2);
    assert(results[0].canFind(hist.failedToolHint), "the first failure gets the hint: " ~ results[0]);
    assert(!results[1].canFind(hist.failedToolHint), "only once: " ~ results[1]);
    agent.run("try once more", new NullEvents);
    results = brokenResults(mock);
    assert(results.length == 3 && !results[2].canFind(hist.failedToolHint), "not in a later turn");

    mock = new MockClient([call("c1", "echo", `{}`), LLMResponse("done"), LLMResponse("SUMMARY"),
        call("b1", "broken", `{}`), LLMResponse("x")]);
    agent = logged("hint-standard", mock);
    agent.run("ping", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.standard));
    agent.run("what was the error?", new NullEvents);
    assert(!brokenResults(mock).any!(r => r.canFind(hist.failedToolHint)));
}

// /tools lists what is offered now: plan mode hides the mutating tools, and
// the history tools appear once a smart compaction has made them available.
// (Rust captures a snapshot when the turn starts and filters it live; D
// renders the listing from the live state after each step.)
// rust: agent.rs::tools_snapshot_captured_in_plan_mode_still_lists_mutating_tools_live
// rust: agent.rs::tools_snapshot_captured_without_history_still_lists_it_live
unittest
{
    import nano.mode : AgentMode;
    auto agent = logged("listing", new MockClient([]));
    agent.tools.register(ToolDefinition("write_file", "write a file\nzq-second-line", parseJSON(`{"type":"object"}`)),
        (JSONValue a) => "ok");
    assert(agent.toolsListing.canFind("write_file") && agent.toolsListing.canFind("plan_add"));
    assert(!agent.toolsListing.canFind("zq-second-line"), "one line per tool");
    agent.control.mode = AgentMode.plan;
    assert(!agent.toolsListing.canFind("write_file"), "plan mode hides the mutating tool");
    agent.control.mode = AgentMode.normal;
    assert(agent.toolsListing.canFind("write_file"));
    assert(!agent.toolsListing.canFind(hist.searchTool));
    agent.historyAvailable = true;
    assert(agent.toolsListing.canFind(hist.searchTool) && agent.toolsListing.canFind(hist.readTool));
}

/// Records the tool names each request offers; a scripted error is thrown.
class ToolSpy : MockClient
{
    string[][] toolsSeen;
    string[] errors;
    this(LLMResponse[] script, string[] errors) { super(script); this.errors = errors; }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        string[] names;
        foreach (ref t; req.tools) names ~= t.name;
        toolsSeen ~= names;
        if (toolsSeen.length == 2) throw new Exception(errors[0]);
        return super.chat(req, sink);
    }
}

// rust: agent.rs::overflow_smart_compaction_rebuilds_tools_before_retry
unittest
{
    import std.algorithm : canFind;
    import nano.context : CompactionMode;
    auto spy = new ToolSpy([LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{}`)]),
        LLMResponse("SUMMARY: pinged"), LLMResponse("done")],
        ["HTTP 400: This model's maximum context length is 4000 tokens. However, you requested 5000 tokens."]);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    auto agent = new Agent(spy, reg, Policy.init, "sys");
    agent.compactionMode = CompactionMode.smart;
    auto dir = buildPath(tempDir, "nano-overflow-tools");
    if (exists(dir)) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    assert(agent.run("ping", new NullEvents) == "done");
    assert(spy.toolsSeen.length == 4, imported!"std.conv".to!string(spy.toolsSeen.length));
    assert(!spy.toolsSeen[1].canFind("history_search"), "no history tools before smart compaction");
    assert(spy.toolsSeen[3].canFind("history_search") && spy.toolsSeen[3].canFind("history_read"),
        "the retry offers the history tools");
}
