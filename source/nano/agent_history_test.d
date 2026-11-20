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
import nano.result : unwrap;
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
// rust: turn_commands.rs::tools_listing_follows_live_history_availability
// rust: turn_commands.rs::tools_listing_follows_the_live_mode
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

Agent breaksMidSummary(MockClient mock)
{
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    agent.run("one", new NullEvents);
    agent.run("two", new NullEvents);
    return agent;
}

// rust: agent.rs::compaction_retries_a_mid_summary_drop_instead_of_dropping_history
// rust: agent.rs::compaction_falls_back_after_too_many_mid_summary_drops
unittest
{
    auto mock = new MockClient([LLMResponse("a1"), LLMResponse("a2"), LLMResponse("!drop:x"), LLMResponse("!drop:x"),
        LLMResponse("the summary")]);
    auto agent = breaksMidSummary(mock);
    CompactReport rep;
    assert(agent.compact(rep));
    assert(rep.fallback is null, "a mid-summary drop is retried: " ~ rep.fallback);
    assert(mock.seen.length == 5, "two breaks then one summary");
    assert(agent.messages[1].content.canFind("the summary") && agent.messages[1].content.canFind("one"));

    auto script = [LLMResponse("a1"), LLMResponse("a2")];
    foreach (i; 0 .. maxStreamRestarts + 1) script ~= LLMResponse("!drop:x");
    mock = new MockClient(script);
    agent = breaksMidSummary(mock);
    assert(agent.compact(rep));
    assert(rep.fallback !is null, "a persistently broken summary stream falls back");
    assert(mock.seen.length == 2 + maxStreamRestarts + 1);
}

// rust: agent.rs::compaction_persists_the_summary_request_usage_on_the_replace_record
unittest
{
    auto dir = buildPath(tempDir, "nano-summary-usage");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto summary = LLMResponse("SUMMARY: pinged once");
    summary.usage = TokenUsage(321, 45);
    auto agent = new Agent(new MockClient([LLMResponse("done"), summary]), new ToolRegistry, Policy.init, "sys");
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    agent.run("ping", new NullEvents);
    CompactReport rep;
    assert(agent.compact(rep));
    JSONValue replace;
    foreach (line; readText(log.path).lineSplitter)
    {
        auto j = parseJSON(line);
        if (j["type"].str == "replace") replace = j["data"];
    }
    auto msgs = replace["messages"].arrayNoRef;
    auto withUsage = msgs.filter!(m => "usage" in m.objectNoRef).array;
    assert(withUsage.length == 1, replace.toString);
    assert(withUsage[0]["content"].str.canFind("SUMMARY: pinged once"));
    assert(withUsage[0]["usage"]["prompt_tokens"].integer == 321 && withUsage[0]["usage"]["completion_tokens"].integer == 45);
    assert("duration_ms" in withUsage[0].objectNoRef);
}

// The kept tail is sized as the wire sends it: past the image limit, older
// images cost a placeholder, so several image turns fit.
// rust: agent.rs::compaction_tail_budget_mirrors_the_vision_wire_plan
unittest
{
    import std.digest : toHexString, LetterCase;
    import std.digest.sha : sha256Of;
    import std.format : format;
    import nano.attachment : Attachment, store;
    import nano.vision : Vision;
    auto mock = new MockClient([LLMResponse("SUMMARY"), LLMResponse("done")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    Vision v;
    v.maxImages = 1;
    agent.capabilities.vision = v;
    agent.configuredWindow = 6_000;
    agent.autoCompactThreshold = 0.5;
    agent.compactionPinRequests = false;
    auto dir = agent.attachmentsDir;
    scope (exit) if (exists(dir)) rmdirRecurse(dir);
    immutable bytes = cast(immutable(ubyte)[]) "compaction-tail-image";
    Attachment img;
    img.mediaType = "image/png";
    img.extension = "png";
    img.sha256 = toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
    img.width = img.height = 1000;
    img.bytes = bytes.length;
    store(dir, img, bytes);
    string big;
    foreach (i; 0 .. 4_000) big ~= "big ";
    agent.messages ~= Message.user(big);
    foreach (i; 0 .. 120)
    {
        auto m = Message.user(format("img%s", i));
        m.attachments = [img];
        agent.messages ~= m;
    }
    agent.run("go", new NullEvents);
    assert(agent.compactions == 1, "threshold compaction ran");
    auto kept = agent.messages.map!(m => m.content).array;
    assert(!kept.any!(c => c.canFind("big ")), "the large text turn is folded");
    assert(kept.canFind("img119"), "the newest image turn is kept");
    auto images = kept.filter!(c => c.startsWith("img")).array.length;
    assert(images > 1 && images < 120, format("kept %s image turns", images));
}

// rust: agent.rs::a_failed_new_session_keeps_the_thinking_override
// rust: agent.rs::a_title_is_requested_at_most_once_per_session_across_switches
unittest
{
    import nano.thinking : Thinking;
    import nano.session : SessionLog, restore;
    import nano.providers.mock : MockClient;
    import std.exception : collectExceptionMsg;
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.typecons : nullable;

    auto agent = new Agent(new MockClient([LLMResponse("one"), LLMResponse("two"), LLMResponse("three")]),
        new ToolRegistry, Policy.init, "sys");
    agent.sessionThinking = nullable(Thinking.parse("high").unwrap("a valid level"));
    agent.messages ~= Message.user("earlier");
    bool rendered;
    auto msg = collectExceptionMsg(agent.restartWith(() @safe => (throw new Exception("blocked")),
        () @safe { rendered = true; return "new"; }));
    assert(msg == "blocked" && !rendered);
    assert(!agent.sessionThinking.isNull && agent.messages.length == 2, "the live session survives a failed switch");

    // A → B → A: A stays requested, so no second title request.
    auto dir = buildPath(tempDir, "nano-d-agent-title-switch");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto a = new SessionLog(dir, "mock/m", "/w");
    agent.restart("sys", some(a));
    size_t requests;
    agent.sessionTitles = true;
    agent.titleClient = (string spec) { requests++; throw new Exception("titler offline"); };
    auto ev = new NullEvents;
    agent.run("Fix the flaky deploy test in CI", ev);
    assert(requests == 1);
    agent.restart("sys", some(new SessionLog(dir, "mock/m", "/w")));
    auto ra = restore(a.path);
    agent.loadRestored(ra, some(new SessionLog(a.path)));
    agent.run("Fix the flaky deploy test in CI again", ev);
    assert(requests == 1, "A stays requested across the switch");
}

// rust: agent.rs::stored_system_message_reflects_mode_change
// rust: agent.rs::load_session_renders_prompt_with_default_mode_writability
// rust: agent.rs::new_generation_clears_stale_output_rate
// rust: agent.rs::one_shot_provider_publishes_usage_over_elapsed_rate
// rust: agent.rs::the_title_fallback_uses_the_sessions_live_model (agent.d title test: spec "mock/mock")
unittest
{
    import nano.mode : AgentMode;
    import nano.session : SessionLog, restore;
    import nano.status : RateMeter;
    import nano.providers.mock : MockClient;
    import std.algorithm : canFind;
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;

    string render(bool plan) @safe { return plan ? "sys\nPLAN MODE" : "sys\nmemory_save guidance"; }
    auto agent = new Agent(new MockClient([LLMResponse("a")]), new ToolRegistry, Policy.init, render(false));
    agent.control.mode = AgentMode.plan;
    agent.syncModePrompt(&render);
    assert(agent.messages[0].content.canFind("PLAN MODE") && !agent.messages[0].content.canFind("memory_save"));
    agent.control.mode = AgentMode.normal;
    agent.syncModePrompt(&render);
    assert(agent.messages[0].content.canFind("memory_save") && !agent.messages[0].content.canFind("PLAN MODE"));

    // Loading while in plan mode: the session is normal, its prompt writable.
    auto dir = buildPath(tempDir, "nano-d-agent-mode-load");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w");
    auto sysMsg = Message.system(render(false));
    log.append(sysMsg);
    agent.control.mode = AgentMode.plan;
    agent.syncModePrompt(&render);
    auto rl = restore(log.path);
    agent.loadRestored(rl, some(new SessionLog(log.path)));
    agent.syncModePrompt(&render);
    assert(agent.control.mode == AgentMode.normal && agent.messages[0].content.canFind("memory_save"));

    // Every generation announces itself (the console clears the stale rate),
    // including the one a turn continues into without going idle.
    auto call = ToolCall.fromRaw("t1", "nope", "{}");
    auto steered = new Agent(new MockClient([LLMResponse("", "", [call]), LLMResponse("revised")]), new ToolRegistry,
        Policy.init, "sys");
    auto ev = new NullEvents;
    steered.run("write", ev);
    assert(ev.generations == 2 && steered.messages[$ - 1].content == "revised");

    // One-shot reply: the whole answer in one delta at completion is rated
    // over the call since generation start.
    RateMeter m;
    m.reset(0);
    m.record(24, 1_000);
    assert(m.finish(6, 1_000) == 6.0);
}
