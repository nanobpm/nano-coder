/// Read-only sub-agents (the `agent` tool, issue #231): a fresh `Agent` with
/// its own context window runs a task on its own thread and returns only its
/// report.
///
/// Threads follow the "E profile" (nano.safeio): the child is started with
/// `spawn` and only sendable values cross. The child builds its own client
/// (from an immutable `SubClientFactory`), conversation and session log; its
/// tool calls are not run on its thread but sent to the parent, which runs
/// them with its own permission policy and hooks (so a sub-agent never
/// prompts, and a denied call comes back as a tool error) and sends the result
/// back. Model calls, where a sub-agent spends its time, run in parallel.
module nano.subagent;

@safe:

import core.atomic : atomicLoad, atomicStore;
import core.time : MonoTime, Duration, seconds;
import std.format : format;
import std.json;
import nano.llm;
import nano.safeio : Chan, Join, jsonText;
import nano.clock : monoNow, since;

/// The tool's name.
enum string toolName = "agent";

/// The tools a v1 sub-agent may call (the history tools run on its own log).
immutable string[] readOnlyTools = ["read_file", "grep", "glob"];

/// Whether a sub-agent may call `name` through its parent.
bool forwardable(string name) pure nothrow
{
    foreach (t; readOnlyTools) if (t == name) return true;
    return false;
}

/// Builds a sub-agent's model client on the sub-agent's thread. It is
/// immutable, so it can be shared with every child.
interface SubClientFactory
{
    /// A new client for `spec` (`provider/model`).
    LLMClient make(string spec) const;
}

/// Per sub-agent caps. Hitting one ends the sub-agent with its partial
/// report, marked truncated.
struct SubLimits
{
    /// Model calls.
    size_t turns = 40;
    /// Wall-clock seconds (`timeout_s` overrides per call).
    long timeoutSecs = 600;
    /// Input plus output tokens over all its model calls.
    ulong tokens = 1_000_000;
}

/// The `agent` tool's definition.
ToolDefinition definition() pure
{
    return ToolDefinition(toolName,
        "Run a read-only sub-agent: a fresh agent with its own context window investigates `task` with read_file, "
        ~ "grep and glob (under your permission rules; no shell, so it cannot change files) and returns only its final report, so the "
        ~ "intermediate output never enters your context. Use it for broad searches (dozens of greps and reads "
        ~ "across a codebase) and for independent investigations; several agent calls in one reply run in "
        ~ "parallel. Don't use it for a single lookup you can do with one grep or read_file. The sub-agent sees "
        ~ "nothing of this conversation: state the task completely (what to find, where to look, what to report). "
        ~ "It cannot edit files. Its report cites file:line for its claims.",
        parseJSON(`{"type":"object","properties":{`
            ~ `"task":{"type":"string","description":"The complete, self-contained task and what the report should contain."},`
            ~ `"tools":{"type":"string","enum":["read-only"],"description":"The tool set (only \"read-only\" for now)."},`
            ~ `"model":{"type":"string","description":"provider/model to run it on (default: subagent_model, else your model)."},`
            ~ `"timeout_s":{"type":"integer","description":"Wall-clock limit in seconds (default 600)."}`
            ~ `},"required":["task"]}`));
}

/// The system prompt of a sub-agent.
string systemPrompt(string cwd, string today) pure
{
    return "You are a read-only sub-agent of a coding agent. You were given one task; investigate it with the "
        ~ "tools you have (read_file, grep, glob) and finish by calling report_outcome, whose summary is your "
        ~ "report: the only thing the parent agent will see. You cannot edit files, ask questions or talk to the "
        ~ "user. Be thorough but efficient: search broadly first, then read what matters.\n\n"
        ~ "The report must stand on its own: answer the task directly, cite file:line (e.g. src/app.d:120) for "
        ~ "every claim about the code, and say what you could not determine. Keep it concise.\n\n"
        ~ format("Working directory: %s\nToday's date: %s", cwd, today);
}

/// A parsed `agent` call.
struct SubArgs
{
    string task, model;
    long timeoutSecs;
}

/// Parse and check an `agent` call's arguments; throws a ToolError.
SubArgs parseArgs(JSONValue args, long defaultTimeout) pure
{
    import nano.tools : requireString, optString, optInt, ToolError;
    import std.string : strip;
    SubArgs a;
    a.task = requireString(args, "task", toolName);
    if (!a.task.strip.length) throw new ToolError("agent: task is empty; describe what the sub-agent should do");
    auto set = optString(args, "tools", "read-only");
    if (set != "read-only")
        throw new ToolError(format(`agent: tools must be "read-only" (edit-capable sub-agents are not supported), got "%s"`, set));
    a.model = optString(args, "model");
    a.timeoutSecs = optInt(args, "timeout_s", defaultTimeout);
    if (a.timeoutSecs <= 0) throw new ToolError("agent: timeout_s must be a positive number of seconds");
    return a;
}

/// What a sub-agent sends its parent.
enum SubKind { tool, progress, done }

/// A message from a sub-agent's thread to its parent.
struct SubMsg
{
    size_t slot;
    SubKind kind;
    /// `tool`: the call to run for the child.
    string callId, name, args;
    /// `progress`: the child's counters so far.
    size_t toolCalls;
    ulong tokens;
}

/// The parent's answer to a forwarded tool call.
struct ToolReply
{
    string text;
    bool isError;
}

/// Set by the parent to stop a sub-agent at its next step: a copyable,
/// sendable handle (like `Chan`). The cell is `shared` so the child's
/// cancellation scope (nano.control) can publish its address on its thread.
struct SubAbort
{
    import core.atomic : atomicLoad, atomicStore;
    /// Set once by `abort`; polled by `aborted`.
    private shared bool flag;

    static SubAbort make() { return SubAbort.init; }
    void abort() { atomicStore(flag, true); }
    bool aborted() nothrow @nogc { return atomicLoad(flag); }
    /// The cell the child's cancellation scope points at.
    shared(bool)* ptr() return { return &flag; }
}

/// What a sub-agent did. Sendable: it crosses back through `join`.
struct SubResult
{
    string report;
    bool truncated;
    /// Why it was truncated (a limit, a cancel, an error).
    string truncatedReason;
    bool cancelled;
    ulong inputTokens, outputTokens;
    bool hasAic;
    double aic = 0;
    size_t turns, toolCalls;
    long durationMs;
    /// The child's session log (null when the parent has none).
    string logPath;
    immutable(string)[] filesRead;
    string model;

    /// The tool result the parent's model reads.
    string toolText() pure const
    {
        import std.array : join;
        import std.string : strip;
        auto body_ = report.strip.length ? report : "(the sub-agent produced no report)";
        string s = body_;
        if (truncated) s ~= format("\n\n[truncated: %s; the report above is partial]", truncatedReason);
        s ~= format("\n\n[sub-agent: %s turns, %s tool calls, %s tokens, %.1fs", turns, toolCalls,
            inputTokens + outputTokens, durationMs / 1000.0);
        if (filesRead.length)
        {
            auto shown = filesRead.length > 20 ? filesRead[0 .. 20] : filesRead;
            s ~= "; files read: " ~ shown.join(", ") ~ (filesRead.length > 20 ? format(" (+%s more)", filesRead.length - 20) : "");
        }
        return s ~ "]";
    }

    TokenUsage usage() pure const
    {
        TokenUsage u;
        import nano.arith : clampToLong;
        u.inputTokens = clampToLong(inputTokens);
        u.outputTokens = clampToLong(outputTokens);
        u.hasAic = hasAic;
        u.aic = aic;
        return u;
    }
}

/// Everything a sub-agent's thread needs, all immutable.
struct SubSpec
{
    size_t slot;
    string callId, task, model, system;
    /// The offered tools, as JSON definitions.
    immutable(string)[] toolDefs;
    SubLimits limits;
    /// Where to write the child log, and the id stem; null dir: no log.
    string logDir, logId, cwd;
}

/// Thrown out of the child's loop when it must stop now (limit or abort).
private class SubStop : Exception
{
    this(string msg) pure { super(msg); }
}

/// Serialise a tool definition for a `SubSpec`.
string encodeDefinition(const ToolDefinition d) pure
{
    import nano.safeio : jsonCopy;
    JSONValue j = ["name": JSONValue(d.name), "description": JSONValue(d.description)];
    j["parameters"] = jsonCopy(d.parameters);
    return j.jsonText;
}

private ToolDefinition decodeDefinition(string s)
{
    auto j = parseJSON(s);
    return ToolDefinition(j["name"].str, j["description"].str, j["parameters"]);
}

/// The child's live state and its loop's events (on the child's thread).
private final class ChildEvents : imported!"nano.agent".AgentEvents
{
    import nano.agent : Agent;
    import nano.option : Option;
    immutable SubSpec spec;
    Chan!SubMsg up;
    Chan!ToolReply down;
    SubAbort abort;
    MonoTime start;
    size_t generations, toolCalls;
    ulong tokens;
    string limitHit;
    size_t gensSinceLimit;
    string[] filesRead;
    Option!Agent agent;

    this(immutable SubSpec spec, Chan!SubMsg up, Chan!ToolReply down, SubAbort abort)
    {
        this.spec = spec;
        this.up = up;
        this.down = down;
        this.abort = abort;
        start = monoNow;
    }

    long timeout() const { return spec.limits.timeoutSecs; }

    /// The wall-clock moment the deadline passes (monoNow scale).
    MonoTime deadline() const { return start + timeout.seconds; }

    /// The first limit breach's reason, or null.
    private string limitWhy()
    {
        if (generations >= spec.limits.turns) return format("turn limit (%s model calls)", spec.limits.turns);
        if (tokens >= spec.limits.tokens) return format("token limit (%s tokens)", spec.limits.tokens);
        if (since(start) >= timeout.seconds) return format("time limit (%ss)", timeout);
        return null;
    }

    /// Check the limits; on the first breach, tell the child to report now.
    void checkLimits()
    {
        if (limitHit !is null) return;
        auto why = limitWhy();
        if (why is null) return;
        limitHit = why;
        steerReportReminder();
    }

    /// Tell the child to stop investigating and report now (idempotent).
    private void steerReportReminder()
    {
        import nano.agent : wrapReminder;
        foreach (a; agent) a.control.steer(wrapReminder(format("You reached your %s. Stop investigating and call "
            ~ "report_outcome now with what you found so far.", limitHit)));
    }

    void progress()
    {
        SubMsg m;
        m.slot = spec.slot;
        m.kind = SubKind.progress;
        m.toolCalls = toolCalls;
        m.tokens = tokens;
        up.put(m);
    }

    /// Run a tool call through the parent.
    string forward(string name, JSONValue args)
    {
        import nano.tools : ToolError;
        checkLimits();
        if (limitHit !is null)
            throw new ToolError(format("not run: you reached your %s; call report_outcome now with your findings", limitHit));
        if (abort.aborted) throw new SubStop("stopped by the parent");
        SubMsg m;
        m.slot = spec.slot;
        m.kind = SubKind.tool;
        m.name = name;
        m.args = args.jsonText;
        up.put(m);
        ToolReply r;
        if (!down.take(r)) throw new SubStop("the parent went away");
        if (r.isError) throw new ToolError(r.text);
        return r.text;
    }

    void text(bool reasoning, string chunk) {}
    void toolStart(const ref ToolCall call)
    {
        toolCalls++;
        if (call.name == "read_file")
            if (auto p = "path" in call.arguments)
                if (p.type == JSONType.string)
                {
                    import std.algorithm : canFind;
                    if (!filesRead.canFind(p.str)) filesRead ~= p.str;
                }
        progress();
    }
    void toolEnd(const ref ToolCall call, string result, bool isError) {}
    void usage(TokenUsage u)
    {
        import nano.arith : toSize;
        tokens += toSize(u.inputTokens < 0 ? 0 : u.inputTokens) + toSize(u.outputTokens < 0 ? 0 : u.outputTokens);
        progress();
    }
    void userMessage(string text) {}
    void assistantMessage(string text, string reasoning) {}
    void responseRestarted() {}
    void generationStart()
    {
        if (abort.aborted) throw new SubStop("stopped by the parent");
        checkLimits();
        // One call after the limit is the grace to write the report.
        if (limitHit !is null && gensSinceLimit++ >= 1) throw new SubStop(limitHit);
        generations++;
    }

    /// Before a fresh call's steers drain and its request is built (the
    /// agent calls this from its CallModel step): a limit first seen now
    /// still gets its reminder into the grace request.
    void beforeFreshCall()
    {
        if (abort.aborted) throw new SubStop("stopped by the parent");
        checkLimits();
        if (limitHit !is null && gensSinceLimit == 0) steerReportReminder();
    }
}

/// The text of the child's latest assistant reply, for a partial report.
private string lastAssistantText(const Message[] ms) pure
{
    import std.string : strip;
    foreach_reverse (ref m; ms)
        if (m.role == Role.assistant && m.content.strip.length) return m.content;
    return null;
}

/// A handler that runs `name` through the parent. A helper, not a loop-body
/// delegate: D closures share the loop variable.
private imported!"nano.tools".ToolHandler forwarder(ChildEvents st, string name)
{
    return (JSONValue a) => st.forward(name, a);
}

/// The sub-agent's thread: run `spec.task` to a report. Never throws; the
/// last thing it does is send `done`.
SubResult runChild(immutable SubSpec spec, immutable(SubClientFactory) factory, Chan!SubMsg up,
    Chan!ToolReply down, SubAbort abort)
{
    import nano.agent : Agent;
    import nano.tools : ToolRegistry;
    import nano.permissions : Policy;
    import nano.session : SessionLog;
    import nano.option : some;
    import nano.control : cancelRequested, cancelledResponse, pushCancelScope, popCancelScope;
    import nano.goal : OutcomeStatus;
    SubResult res;
    res.model = spec.model;
    auto st = new ChildEvents(spec, up, down, abort);
    // Blocking work on this thread (the model's HTTP requests, its retry
    // waits) polls this child's abort before the process-wide cancel flag,
    // so the parent stopping this child interrupts an in-flight request
    // without cancelling its own turn.
    pushCancelScope(abort.ptr);
    scope (exit) popCancelScope();
    scope (exit)
    {
        res.durationMs = since(st.start).total!"msecs";
        res.toolCalls = st.toolCalls;
        res.turns = st.generations;
        res.filesRead = st.filesRead.idup;
        SubMsg m;
        m.slot = spec.slot;
        m.kind = SubKind.done;
        up.put(m);
    }
    // Any failure (no client for the model, a log that can't be written) is
    // the sub-agent's result, so the parent always gets one.
    try
    {
        auto client = factory.make(spec.model);
        auto tools = new ToolRegistry;
        foreach (d; spec.toolDefs)
        {
            auto def = decodeDefinition(d);
            tools.register(def, forwarder(st, def.name));
        }
        // The parent applies its own policy to every forwarded call; this
        // one only refuses what no policy allows.
        auto agent = new Agent(client, tools, Policy.init, spec.system);
        st.agent = some(agent);
        agent.planTools = false;
        agent.timerTools = false;
        agent.outcomeTool = true;
        agent.verifyBeforeComplete = false;
        agent.maxIterations = spec.limits.turns + 2;
        if (spec.logDir.length)
        {
            import std.file : exists;
            import std.path : buildPath;
            string id = spec.logId;
            for (size_t n = 2; buildPath(spec.logDir, id ~ ".jsonl").exists; n++) id = format("%s-%s", spec.logId, n);
            auto log = new SessionLog(spec.logDir, spec.model, spec.cwd, id);
            agent.log = some(log);
            res.logPath = log.path;
        }
        string answer;
        try
        {
            // The cancel flag is process-wide: never reset it from here.
            answer = agent.run(spec.task, st, false);
            if (agent.hasOutcome)
            {
                answer = agent.lastOutcome.summary;
                if (agent.lastOutcome.status == OutcomeStatus.blocked && !st.limitHit)
                    answer = "[the sub-agent reported itself blocked]\n" ~ answer;
            }
            if (answer == cancelledResponse || cancelRequested)
            {
                res.cancelled = res.truncated = true;
                res.truncatedReason = abort.aborted ? "stopped by the parent" : "cancelled";
                auto partial = lastAssistantText(agent.messages);
                answer = partial.length ? partial : "(cancelled before the sub-agent reported)";
            }
            else if (st.limitHit !is null)
            {
                res.truncated = true;
                res.truncatedReason = st.limitHit;
            }
            else
            {
                // A final report_outcome bypasses `forward`, so its usage and
                // the time it took never hit a limit check: a report that
                // crossed the token or time cap is still marked truncated.
                if (st.tokens >= spec.limits.tokens)
                {
                    res.truncated = true;
                    res.truncatedReason = format("token limit (%s tokens)", spec.limits.tokens);
                }
                else if (since(st.start) >= st.timeout.seconds)
                {
                    res.truncated = true;
                    res.truncatedReason = format("time limit (%ss)", st.timeout);
                }
            }
        }
        catch (SubStop e)
        {
            res.truncated = true;
            res.truncatedReason = e.msg;
            auto partial = lastAssistantText(agent.messages);
            answer = partial.length ? partial : "(no report: the sub-agent stopped before writing one)";
        }
        res.report = answer;
        res.inputTokens = agent.sessionInputTokens;
        res.outputTokens = agent.sessionOutputTokens;
        res.hasAic = agent.hasSessionAic;
        res.aic = agent.sessionAic;
        if (st.limitHit !is null && !res.truncated)
        {
            res.truncated = true;
            res.truncatedReason = st.limitHit;
        }
        foreach (l; agent.log) l.close();
    }
    catch (Exception e)
    {
        res.truncated = true;
        res.truncatedReason = "error: " ~ e.msg;
        res.report = "(the sub-agent failed: " ~ e.msg ~ ")";
        foreach (a; st.agent)
        {
            res.inputTokens = a.sessionInputTokens;
            res.outputTokens = a.sessionOutputTokens;
        }
    }
    return res;
}

/// A running or finished sub-agent, on the parent's side.
struct SubSlot
{
    string callId;
    string task;
    immutable(SubSpec) spec;
    Chan!ToolReply down;
    SubAbort abort;
    Join!SubResult handle;
    bool started, finished;
    SubResult result;
    MonoTime start;
    size_t toolCalls;
    ulong tokens;
    bool reportedDone;
    /// The child's own read state: its read_file calls never authorize a
    /// later parent write (the parent model sees only the report).
    imported!"nano.option".Option!(imported!"nano.tools.files".ReadState) readState;
}

/// An `agent` call's checks, made before its reply's sub-agents start.
struct SubGate
{
    /// The refusal (permission, plan mode or a hook), or null.
    string deny;
    JSONValue args;
    string[] context;
    /// Its slot, when it started; else why its arguments were rejected.
    bool launched;
    size_t slot;
    string argError;
}

/// Live progress of the sub-agents, for renderers that show it.
struct SubProgress
{
    string callId, task;
    size_t index, toolCalls;
    ulong tokens;
    Duration elapsed;
    bool done;
    /// When done: the result.
    bool truncated;
}

/// Renderers that show sub-agent progress mix this in alongside
/// `AgentEvents` and override `subagents` (the loop checks with
/// `__traits(hasMember, …, "subagents")`, so an events class without the
/// mixin simply never gets the calls).
mixin template SubAgentEvents()
{
    /// Every running sub-agent's state after a change; `done` ones are listed
    /// once, as they finish. The mixed-in default ignores them.
    void subagents(const imported!"nano.subagent".SubProgress[] all) {}
}

/// One line of progress for a sub-agent (task, tool calls, tokens, elapsed).
string progressLine(const ref SubProgress p) pure
{
    import nano.context : formatTokens;
    import nano.arith : toSize;
    import std.string : indexOf;
    string t = p.task;
    auto nl = t.indexOf('\n');
    if (nl >= 0) t = t[0 .. nl];
    import std.range : walkLength;
    import std.utf : toUTF8;
    import std.array : array;
    if (t.walkLength > 60) t = toUTF8(t.array[0 .. 59]) ~ "…";
    return format("%s #%s %s · %s tool calls · %s tokens · %ss%s", p.done ? "↳" : "⟳", p.index + 1, t, p.toolCalls,
        formatTokens(toSize(p.tokens)), p.elapsed.total!"seconds", p.done ? (p.truncated ? " · truncated" : " · done") : "");
}

unittest
{
    import std.algorithm : canFind;
    SubProgress p;
    p.task = "find the parser\nand more";
    p.toolCalls = 3;
    p.tokens = 1500;
    auto l = progressLine(p);
    assert(l.canFind("#1 find the parser ·") && l.canFind("3 tool calls"), l);
    p.done = true;
    assert(progressLine(p).canFind("done"));
}

unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm : canFind;
    assert(parseArgs(parseJSON(`{"task":"x"}`), 600).timeoutSecs == 600);
    assert(parseArgs(parseJSON(`{"task":"x","timeout_s":5,"model":"m/n"}`), 600).model == "m/n");
    assert(collectExceptionMsg(parseArgs(parseJSON(`{"task":"x","tools":"all"}`), 600)).canFind("read-only"));
    assert(collectExceptionMsg(parseArgs(parseJSON(`{"task":" "}`), 600)).canFind("empty"));
    assert(collectExceptionMsg(parseArgs(parseJSON(`{"task":"x","timeout_s":0}`), 600)).canFind("positive"));
    assert(forwardable("grep") && !forwardable("write_file") && !forwardable("agent"));
    // No shell: the parent sandbox is writable, so bash would break read-only.
    assert(!forwardable("bash"));
    SubResult r;
    r.report = "found it at a.d:3";
    r.truncated = true;
    r.truncatedReason = "time limit (5s)";
    r.filesRead = ["a.d"];
    auto t = r.toolText;
    assert(t.canFind("found it") && t.canFind("[truncated: time limit") && t.canFind("files read: a.d"), t);
}
