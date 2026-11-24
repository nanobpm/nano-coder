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
import std.algorithm : canFind;
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

/// A model the `agent` tool offers (`[[subagent_models]]`): what it is
/// for, and the limits of a sub-agent on it.
struct SubCandidate
{
    string model, use;
    SubLimits limits;
}

/// The `agent` tool's definition: with `candidates`, `model` is an enum of
/// them (the first the default) and the description says what each is for;
/// without, `model` is any `provider/model`.
ToolDefinition definition(const(SubCandidate)[] candidates = null) pure
{
    import std.json : JSONValue;
    string desc = "Run a read-only sub-agent: a fresh agent with its own context window investigates `task` with read_file, "
        ~ "grep and glob (under your permission rules; no shell, so it cannot change files) and returns only its final report, so the "
        ~ "intermediate output never enters your context. Use it for broad searches (dozens of greps and reads "
        ~ "across a codebase) and for independent investigations; several agent calls in one reply run in "
        ~ "parallel. Don't use it for a single lookup you can do with one grep or read_file. The sub-agent sees "
        ~ "nothing of this conversation: state the task completely (what to find, where to look, what to report). "
        ~ "It cannot edit files. Its report cites file:line for its claims. With background: true it runs while you "
        ~ "carry on (into later turns too).";
    auto params = parseJSON(`{"type":"object","properties":{`
        ~ `"task":{"type":"string","description":"The complete, self-contained task and what the report should contain."},`
        ~ `"tools":{"type":"string","enum":["read-only"],"description":"The tool set (only \"read-only\" for now)."},`
        ~ `"model":{"type":"string","description":"provider/model to run it on (default: subagent_model, else your model)."},`
        ~ `"timeout_s":{"type":"integer","description":"Wall-clock limit in seconds (default 600)."},`
        ~ `"background":{"type":"boolean","description":"Start it and return at once with a handle (e.g. sub-3); its result arrives later as a reminder (or from agent_wait). Watch it with agent_status/agent_read, stop it with agent_cancel."}`
        ~ `},"required":["task"]}`);
    if (candidates.length)
    {
        desc ~= "\n\nModels you can run it on (`model`; default " ~ candidates[0].model ~ "):";
        JSONValue[] names;
        foreach (c; candidates)
        {
            names ~= JSONValue(c.model);
            desc ~= "\n- " ~ c.model ~ (c.use.length ? ": " ~ c.use : "");
        }
        params["properties"]["model"] = JSONValue(["type": JSONValue("string"), "enum": JSONValue(names),
            "description": JSONValue("The model to run it on (default " ~ candidates[0].model ~ ").")]);
        params["properties"]["timeout_s"]["description"] = JSONValue("Wall-clock limit in seconds (default: the model's limit).");
    }
    return ToolDefinition(toolName, desc, params);
}

/// The model and limits for a call: with `candidates`, the one it names
/// (the first when none is named; a ToolError listing them for any other);
/// without, its model, else `fallback`, under `base`. An explicit
/// `timeout_s` wins over the limit either way.
SubCandidate choose(const SubArgs a, const(SubCandidate)[] candidates, string fallback, SubLimits base) pure
{
    import nano.tools : ToolError;
    SubCandidate c;
    if (!candidates.length) c = SubCandidate(a.model.length ? a.model : fallback, null, base);
    else if (!a.model.length) c = candidates[0];
    else
    {
        bool found;
        foreach (x; candidates) if (x.model == a.model) { c = x; found = true; break; }
        if (!found)
        {
            string list;
            foreach (i, x; candidates) list ~= (i ? ", " : "") ~ x.model;
            throw new ToolError(format("agent: model \"%s\" is not one of the sub-agent models: %s", a.model, list));
        }
    }
    if (a.timeoutSet) c.limits.timeoutSecs = a.timeoutSecs;
    return c;
}

/// A parsed `/subagents` argument: show the state, or switch it (and
/// with `--save` write it to the user config too).
struct SubToggle
{
    /// No `on`/`off`: just show.
    bool show;
    bool on, save;
}

/// Parse `/subagents [on|off] [--save]`.
imported!"nano.result".Result!(SubToggle, string) parseToggle(string arg) pure
{
    import std.string : split;
    alias R = imported!"nano.result".Result!(SubToggle, string);
    SubToggle t = SubToggle(true);
    bool chosen;
    foreach (w; arg.split)
    {
        if (w == "--save") t.save = true;
        else if ((w == "on" || w == "off") && !chosen) { t.on = w == "on"; t.show = false; chosen = true; }
        else return R.err(format(`/subagents: unexpected "%s" (usage: %s)`, w, commandUsage));
    }
    if (t.save && t.show) return R.err("/subagents: --save needs on or off");
    return R.ok(t);
}

/// What `/subagents` shows: on or off, and the models a sub-agent may run
/// on with their limits.
string statusText(bool on, const(SubCandidate)[] candidates, string defaultModel, SubLimits base) pure
{
    string lim(SubLimits l)
    {
        return format("timeout %ss, %s turns, %s tokens", l.timeoutSecs, l.turns, l.tokens);
    }
    auto s = "Sub-agents (the agent tool): " ~ (on ? "on" : "off") ~ "\n";
    if (!candidates.length)
        s ~= format("Model: %s (any provider/model the agent names)\nLimits: %s", defaultModel, lim(base));
    else
    {
        s ~= "Models (the first is the default):";
        foreach (c; candidates)
            s ~= format("\n  %s%s — %s", c.model, c.use.length ? " (" ~ c.use ~ ")" : "", lim(c.limits));
    }
    return s ~ "\n/subagents on|off switches them for this session (--save also writes the config); "
        ~ "the change invalidates the provider's prompt cache once.";
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
    /// The call gave `timeout_s` (it overrides a candidate's limit).
    bool timeoutSet;
    /// `background: true`: return a handle at once (issue #266).
    bool background;
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
    if (args.type == JSONType.object)
        if (auto t = "timeout_s" in args.objectNoRef)
            a.timeoutSet = t.type != JSONType.null_; // null means omitted, as in optInt
    if (a.timeoutSecs <= 0) throw new ToolError("agent: timeout_s must be a positive number of seconds");
    if (args.type == JSONType.object)
        if (auto b = "background" in args.objectNoRef)
        {
            if (b.type == JSONType.true_) a.background = true;
            else if (b.type != JSONType.false_ && b.type != JSONType.null_)
                throw new ToolError("agent: background must be true or false");
        }
    return a;
}

/// What a sub-agent sends its parent.
enum SubKind { tool, progress, done, /** its log is open (`args`: the path) */ started }

/// A message from a sub-agent's thread to its parent.
struct SubMsg
{
    size_t slot;
    SubKind kind;
    /// `tool`: the call to run for the child.
    string callId, name, args;
    /// `progress`: the child's counters so far.
    size_t toolCalls, turns;
    ulong tokens;
    /// `progress`: the child's cumulative usage so far (tokens and AI
    /// Credits), so the parent's totals move per request (issue #340).
    TokenUsage spent;
    /// `progress`: the child's model requests interrupted without usage.
    size_t uncounted;
    /// `progress`: how many AI Credit reports the child has received so far,
    /// so an unchanged snapshot is not mistaken for a new report.
    ulong aicReports;
}

/// What `now` adds to a running sub-agent's usage the parent already counted
/// (`seen`): the parent folds each progress snapshot in as this delta, and the
/// final usage too, so every token and credit is counted exactly once. The
/// delta never carries `hasAic`: `UsageFold` sets it from the report count.
TokenUsage usageDelta(TokenUsage seen, TokenUsage now) pure nothrow @nogc
{
    import nano.arith : saturatingSub;
    TokenUsage d;
    d.inputTokens = saturatingSub(now.inputTokens, seen.inputTokens);
    d.outputTokens = saturatingSub(now.outputTokens, seen.outputTokens);
    import std.algorithm.comparison : max;
    d.aic = max(0.0, now.aic - seen.aic);
    return d;
}

/// A running sub-agent's usage as the parent has counted it (issue #340):
/// each progress snapshot and the final result are cumulative, so the parent
/// adds only what is new, and the totals move per request without double
/// counting at `done`.
struct UsageFold
{
    TokenUsage counted;
    size_t uncounted;
    /// AI Credit reports already folded in.
    ulong aicReports;

    /// Advance to the cumulative `now`, which carries `reportsNow` AI Credit
    /// reports; returns what to add to the totals (and, in `newUncounted`,
    /// the newly interrupted requests). The delta has `hasAic` only when a
    /// new credit report arrived, so a replayed or tool-only snapshot never
    /// looks like a provider reporting zero credits.
    TokenUsage advance(TokenUsage now, ulong reportsNow, size_t uncountedNow, out size_t newUncounted)
        pure nothrow @nogc
    {
        import nano.arith : saturatingSub;
        auto d = usageDelta(counted, now);
        d.hasAic = reportsNow > aicReports;
        if (reportsNow > aicReports) aicReports = reportsNow;
        if (now.inputTokens > counted.inputTokens) counted.inputTokens = now.inputTokens;
        if (now.outputTokens > counted.outputTokens) counted.outputTokens = now.outputTokens;
        if (now.aic > counted.aic) counted.aic = now.aic;
        counted.hasAic = counted.hasAic || now.hasAic;
        newUncounted = saturatingSub(uncountedNow, uncounted);
        if (uncountedNow > uncounted) uncounted = uncountedNow;
        return d;
    }
}

unittest
{
    import std.math : isClose;
    // A fake sub-agent: parent spent 1000 in / 0.1 AIC; progress 1, 2, then
    // done (also replayed, as a late duplicate) — status = parent + latest.
    TokenUsage parent;
    parent.inputTokens = 1000; parent.hasAic = true; parent.aic = 0.1;
    void add(ref TokenUsage t, TokenUsage d) { t.inputTokens += d.inputTokens; t.outputTokens += d.outputTokens; t.aic += d.aic; }
    UsageFold f;
    size_t nu, lost;
    TokenUsage p1, p2, fin;
    p1.inputTokens = 200; p1.outputTokens = 20; p1.hasAic = true; p1.aic = 0.02;
    p2 = p1; p2.inputTokens = 500; p2.outputTokens = 50; p2.aic = 0.05;
    fin = p2; fin.inputTokens = 700; fin.aic = 0.07;
    add(parent, f.advance(p1, 1, 0, nu));
    assert(parent.inputTokens == 1200 && parent.outputTokens == 20 && isClose(parent.aic, 0.12));
    add(parent, f.advance(p2, 2, 0, nu));
    assert(parent.inputTokens == 1500 && parent.outputTokens == 50 && isClose(parent.aic, 0.15));
    add(parent, f.advance(fin, 3, 1, nu));
    lost += nu;
    assert(parent.inputTokens == 1700 && isClose(parent.aic, 0.17) && lost == 1);
    add(parent, f.advance(fin, 3, 1, nu));
    lost += nu;
    assert(parent.inputTokens == 1700 && isClose(parent.aic, 0.17) && lost == 1, "done counts exactly once");
}

unittest
{
    TokenUsage a, b;
    a.inputTokens = 100; a.outputTokens = 10; a.hasAic = true; a.aic = 0.5;
    b = a; b.inputTokens = 250; b.aic = 0.75;
    auto d = usageDelta(a, b);
    assert(d.inputTokens == 150 && d.outputTokens == 0 && !d.hasAic && d.aic == 0.25);
    assert(usageDelta(b, a).inputTokens == 0 && usageDelta(b, a).aic == 0);
}

unittest
{
    // A cumulative snapshot with hasAic set but no new credit report (a
    // replay, or a tool-only progress update) must not count as a report.
    TokenUsage now;
    now.inputTokens = 100; now.hasAic = true; now.aic = 0.5;
    UsageFold f;
    size_t nu;
    assert(f.advance(now, 1, 0, nu).hasAic);
    assert(!f.advance(now, 1, 0, nu).hasAic, "unchanged snapshot");
    now.inputTokens = 200;
    assert(!f.advance(now, 1, 0, nu).hasAic, "tokens without a new credit report");
    auto z = f.advance(now, 2, 0, nu);
    assert(z.hasAic && z.aic == 0, "a genuine zero-credit report stays distinguishable");
}

/// The parent's answer to a forwarded tool call.
struct ToolReply
{
    string text;
    bool isError;
    /// `read_file` only, on success: the path that was actually read (after
    /// any hook rewrite), so the child's footer lists real reads.
    string effectivePath;
}

/// Set by the parent to stop a sub-agent at its next step: a copyable,
/// sendable handle (like `Chan`). Every copy points at one heap-allocated
/// `shared` cell, so the parent's `abort` reaches the child's events and its
/// cancellation scope (nano.control) on the child's thread.
struct SubAbort
{
    import core.atomic : atomicLoad, atomicStore;
    /// The one cell all copies share; null only in `SubAbort.init`, which
    /// never aborts.
    private shared(bool)* flag;
    /// Set by `agent_cancel`: report now, then stop (issue #266).
    private shared(bool)* wrap;

    static SubAbort make() { return SubAbort(new shared bool, new shared bool); }
    /// Ask the child to stop investigating and report what it has.
    void wrapUp() { if (wrap !is null) atomicStore(*wrap, true); }
    bool wrapping() const nothrow @nogc { return wrap !is null && atomicLoad(*wrap); }
    void abort() { if (flag !is null) atomicStore(*flag, true); }
    bool aborted() const nothrow @nogc { return flag !is null && atomicLoad(*flag); }
    /// The cell the child's cancellation scope points at.
    shared(bool)* ptr() { return flag is null ? (flag = new shared bool) : flag; }
}

unittest
{
    // A copy (as passed to spawn and kept in the child's events) sees the
    // parent's abort: the handles share one cell.
    auto a = SubAbort.make;
    auto b = a;
    assert(!b.aborted);
    a.abort();
    assert(b.aborted);
    assert(a.ptr is b.ptr);
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
    /// Model requests interrupted before the provider reported their usage:
    /// not counted (never estimated), but reported.
    size_t uncountedRequests;
    /// AI Credit reports the child received (see `UsageFold`).
    ulong aicReports;
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
        if (uncountedRequests)
            s ~= format("; %s interrupted request%s not counted", uncountedRequests, uncountedRequests == 1 ? "" : "s");
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
    /// Cumulative usage of every model call (turns and compactions).
    TokenUsage spent;
    string limitHit;
    size_t gensSinceLimit;
    /// Whether a fresh request has carried the report reminder since the limit.
    bool reminderDelivered;
    /// A report reminder is queued and not yet drained into a request.
    bool reminderQueued;
    /// The parent's `agent_cancel` asked for a final report.
    bool wrappedUp;
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
        if (abort.wrapping)
        {
            wrappedUp = true;
            return "cancel by the parent";
        }
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
        auto why = wrappedUp ? "The parent agent cancelled you" : format("You reached your %s", limitHit);
        reminderQueued = true;
        foreach (a; agent) a.control.steer(wrapReminder(why ~ ". Stop investigating and call "
            ~ "report_outcome now with what you found so far."));
    }

    void progress()
    {
        SubMsg m;
        m.slot = spec.slot;
        m.kind = SubKind.progress;
        m.toolCalls = toolCalls;
        m.turns = generations;
        m.tokens = tokens;
        m.spent = spent;
        foreach (a; agent) { m.uncounted = a.uncountedRequests; m.aicReports = a.aicReports; }
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
        // The parent reports the path it actually read; a denied, missing or
        // limit-blocked file is not a read, and a hook-rewritten read lists
        // the effective path, not the requested one.
        if (r.effectivePath.length && !filesRead.canFind(r.effectivePath)) filesRead ~= r.effectivePath;
        return r.text;
    }

    void text(bool reasoning, string chunk) {}
    void toolStart(const ref ToolCall call)
    {
        toolCalls++;
        progress();
    }
    void toolEnd(const ref ToolCall call, string result, bool isError) {}
    void usage(TokenUsage u)
    {
        import nano.arith : toSize;
        tokens += toSize(u.inputTokens < 0 ? 0 : u.inputTokens) + toSize(u.outputTokens < 0 ? 0 : u.outputTokens);
        spent.inputTokens += u.inputTokens < 0 ? 0 : u.inputTokens;
        spent.outputTokens += u.outputTokens < 0 ? 0 : u.outputTokens;
        if (u.hasAic)
        {
            spent.hasAic = true;
            spent.aic += u.aic;
        }
        progress();
    }
    void userMessage(string text) {}
    void assistantMessage(string text, string reasoning) {}
    void responseRestarted() {}
    void generationStart()
    {
        if (abort.aborted) throw new SubStop("stopped by the parent");
        if (limitHit is null)
        {
            // A limit (or the parent's cancel) first seen here arrived after
            // this request's steers drained: the request lacks the report
            // reminder, so it is not the grace call. Leave the reminder to
            // the next fresh call (beforeFreshCall), which gets the grace
            // (issue #322). Queue the reminder now too, so a tool-free
            // answer to this request still leads to a reminded request.
            checkLimits();
            generations++;
            return;
        }
        // A retry of a request that lacked the reminder (an interrupted
        // stream or rejected output skips beforeFreshCall) is not the grace.
        if (!reminderDelivered)
        {
            generations++;
            return;
        }
        // One call after the limit is the grace to write the report.
        if (gensSinceLimit++ >= 1) throw new SubStop(limitHit);
        generations++;
    }

    /// A compaction's summary call: counted toward the budget like any model
    /// call, but it does not spend the reporting grace (it carries no
    /// tools, so the child could not report in it). Once the grace call
    /// has gone out, nothing more runs.
    void summaryStart()
    {
        if (abort.aborted) throw new SubStop("stopped by the parent");
        checkLimits();
        if (limitHit !is null && gensSinceLimit >= 1) throw new SubStop(limitHit);
        generations++;
    }

    /// Before a fresh call's steers drain and its request is built (the
    /// agent calls this from its CallModel step): a limit first seen now
    /// still gets its reminder into the grace request.
    void beforeFreshCall()
    {
        if (abort.aborted) throw new SubStop("stopped by the parent");
        checkLimits();
        if (limitHit !is null && gensSinceLimit == 0)
        {
            // A reminder queued by a late checkLimits is still pending; one
            // copy per request is enough.
            if (!reminderQueued) steerReportReminder();
            // The steers drain after this, so the coming request carries it.
            reminderQueued = false;
            reminderDelivered = true;
        }
    }

    /// A child's own progress is reported through its channel, not rendered.
    void subagents(const(SubProgress)[] all) {}
}

// A cancel that lands after a request was built (between beforeFreshCall
// and generationStart) does not spend the grace on that request, which
// never carried the report reminder: the next call is still the grace.
unittest
{
    immutable spec = SubSpec(0, "c", "t", "m", "s", null, SubLimits.init);
    auto ab = SubAbort.make;
    auto st = new ChildEvents(spec, Chan!SubMsg.make, Chan!ToolReply.make, ab);
    st.beforeFreshCall();
    ab.wrapUp(); // the parent's agent_cancel, mid-call setup
    st.generationStart(); // its request lacks the reminder
    assert(st.wrappedUp);
    st.beforeFreshCall();
    st.generationStart(); // the grace call, carrying the reminder
    bool stopped;
    try st.generationStart();
    catch (SubStop) stopped = true;
    assert(stopped, "no more model calls after the grace call");
}

// A limit first seen during request setup, then a stream retry
// (CallModel(false): no beforeFreshCall, no steer drain) of that request:
// neither call carried the reminder, so the next fresh call is still the grace.
unittest
{
    immutable spec = SubSpec(0, "c", "t", "m", "s", null, SubLimits.init);
    auto ab = SubAbort.make;
    auto st = new ChildEvents(spec, Chan!SubMsg.make, Chan!ToolReply.make, ab);
    st.beforeFreshCall();
    ab.wrapUp();
    st.generationStart(); // interrupted
    st.generationStart(); // its retry, still without the reminder
    st.beforeFreshCall();
    st.generationStart(); // the grace call
    bool stopped;
    try st.generationStart();
    catch (SubStop) stopped = true;
    assert(stopped, "no more model calls after the grace call");
}

// A compaction needed after the limit does not spend the reporting grace:
// the summary call counts toward the budget, the following tool-enabled
// call still runs, and only the one after that stops the child.
unittest
{
    SubLimits lim;
    lim.turns = 1;
    immutable spec = SubSpec(0, "c", "t", "m", "s", null, lim);
    auto st = new ChildEvents(spec, Chan!SubMsg.make, Chan!ToolReply.make, SubAbort.make);
    st.generationStart(); // the one allowed call
    st.beforeFreshCall();
    assert(st.limitHit !is null);
    st.summaryStart(); // compaction before the grace call
    assert(st.generations == 2, "the summary counts toward the budget");
    st.generationStart(); // the grace call, still available
    bool stopped;
    try st.summaryStart();
    catch (SubStop) stopped = true;
    assert(stopped, "no more model calls after the grace call");
    stopped = false;
    try st.generationStart();
    catch (SubStop) stopped = true;
    assert(stopped);
}

// The parent's cancel landing between a fresh call's steer drain and its
// request (issue #322): that request carries no report reminder, so it is
// not the grace call. The next fresh call gets the reminder and the grace;
// only the call after that stops the child. Repeated to pin the ordering.
unittest
{
    import std.algorithm : canFind;
    foreach (n; 0 .. 200)
    {
        immutable spec = SubSpec(0, "c", "t", "m", "s", null, SubLimits.init);
        auto ab = SubAbort.make;
        auto st = new ChildEvents(spec, Chan!SubMsg.make, Chan!ToolReply.make, ab);
        st.beforeFreshCall(); // steers drain here
        ab.wrapUp(); // the cancel lands now
        st.generationStart(); // this request has no reminder
        assert(st.wrappedUp && st.limitHit !is null);
        assert(st.gensSinceLimit == 0, "the reminder-less call is not the grace");
        st.beforeFreshCall(); // queues the reminder for the grace call
        st.generationStart(); // the grace call: the child can report
        bool stopped;
        try st.generationStart();
        catch (SubStop) stopped = true;
        assert(stopped, "only one final step");
    }
}

// A retry (no beforeFreshCall) of the reminder-less request after the cancel
// does not spend the grace either (issue #322).
unittest
{
    immutable spec = SubSpec(0, "c", "t", "m", "s", null, SubLimits.init);
    auto ab = SubAbort.make;
    auto st = new ChildEvents(spec, Chan!SubMsg.make, Chan!ToolReply.make, ab);
    st.beforeFreshCall();
    ab.wrapUp();
    st.generationStart(); // reminder-less request; stream interrupted
    st.generationStart(); // its retry, still without the reminder
    st.generationStart(); // another retry
    assert(st.gensSinceLimit == 0, "retries without the reminder are not the grace");
    st.beforeFreshCall();
    st.generationStart(); // the grace call
    bool stopped;
    try st.generationStart();
    catch (SubStop) stopped = true;
    assert(stopped);
}

// End to end through a real Agent (issue #322): the cancel lands after the
// first request's steers drained, and the
// model answers that request without tools. The queued reminder keeps the
// turn going, so a second request goes out carrying it.
unittest
{
    import nano.agent : Agent;
    import nano.tools : ToolRegistry;
    import nano.permissions : Policy;
    import nano.providers.mock : MockClient;
    import nano.option : some;
    import std.algorithm : any, count;
    immutable spec = SubSpec(0, "c", "t", "m", "s", null, SubLimits.init);
    auto ab = SubAbort.make;
    auto st = new ChildEvents(spec, Chan!SubMsg.make, Chan!ToolReply.make, ab);
    bool[] reminded;
    size_t[] reminderCount;
    auto client = new class MockClient
    {
        this() { super([]); }
        override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
        {
            reminded ~= req.messages.any!(m => m.content.canFind("call report_outcome now"));
            reminderCount ~= req.messages.count!(m => m.content.canFind("call report_outcome now"));
            if (reminded.length > 1) return LLMResponse("the report");
            return LLMResponse("still looking");
        }
    };
    auto agent = new Agent(client, new ToolRegistry, Policy.init, "s");
    st.agent = some(agent);
    agent.verifyBeforeComplete = false;
    // The cancel lands after the first request's steers drained but before
    // its generationStart, so the production late-detection path runs.
    bool cancelled;
    agent.onThresholdChecked = () {
        if (!cancelled) { cancelled = true; ab.wrapUp(); }
    };
    agent.run("go", st);
    assert(cancelled);
    assert(reminded.length >= 2, "a tool-free reply must not end the turn before the reminder");
    assert(!reminded[0] && reminded[1], "the next request carries the report reminder");
    assert(reminderCount[1] == 1, "the reminded request carries exactly one reminder");
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
        agent.settingsTools = false;
        agent.outcomeTool = true;
        agent.verifyBeforeComplete = false;
        agent.maxIterations = spec.limits.turns + 2;
        if (spec.logDir.length)
        {
            import std.file : exists;
            import std.path : buildPath;
            import nano.session : compressedExtension;
            // Both the plain and the tidied-up compressed name are occupied:
            // reusing an id whose earlier log was compressed would make the
            // old `sub_log` references expand this child's transcript
            // instead (trajectory.load prefers the plain file).
            string id = spec.logId;
            bool taken(string i) { return buildPath(spec.logDir, i ~ ".jsonl").exists
                || buildPath(spec.logDir, i ~ compressedExtension).exists; }
            for (size_t n = 2; taken(id); n++) id = format("%s-%s", spec.logId, n);
            auto log = new SessionLog(spec.logDir, spec.model, spec.cwd, id);
            agent.log = some(log);
            res.logPath = log.path;
            SubMsg m;
            m.slot = spec.slot;
            m.kind = SubKind.started;
            m.args = log.path;
            up.put(m);
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
        res.uncountedRequests = agent.uncountedRequests;
        res.aicReports = agent.aicReports;
        if (st.limitHit !is null && !res.truncated)
        {
            res.truncated = true;
            res.truncatedReason = st.limitHit;
        }
        if (st.wrappedUp)
        {
            res.cancelled = res.truncated = true;
            res.truncatedReason = "cancelled by the parent";
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
            res.hasAic = a.hasSessionAic;
            res.aic = a.sessionAic;
            res.uncountedRequests = a.uncountedRequests;
            res.aicReports = a.aicReports;
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
    /// What of its usage the parent's totals already hold.
    UsageFold fold;
    bool reportedDone;
    /// The child's own read state: its read_file calls never authorize a
    /// later parent write (the parent model sees only the report).
    imported!"nano.option".Option!(imported!"nano.tools.files".ReadState) readState;
    /// Started with `background: true` (issue #266): it outlives its reply
    /// and its result is delivered later.
    bool background;
    /// Its result reached the parent model (a reminder or `agent_wait`).
    bool delivered;
    /// Its handle (`sub-N`) and log path once open.
    string id, logPath;
    size_t turns;
    /// Its last few tool calls (name and argument summary).
    string[] recent;
    /// Why `agent_cancel` stopped it.
    string cancelReason;

    /// The state `agent_status` shows.
    string state() pure const
    {
        if (!finished) return started ? "running" : "queued";
        if (result.cancelled) return "cancelled";
        return result.truncated ? "truncated" : "done";
    }
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
    /// The session-unique handle (`sub-N`); call ids can repeat across replies.
    string handle;
    size_t index, toolCalls;
    ulong tokens;
    Duration elapsed;
    bool done;
    /// When done: the result.
    bool truncated;
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
    {
        // Candidates: an enum and their uses; without, a free-form model.
        import std.exception : collectExceptionMsg;
        import nano.result : unwrap;
        auto free = definition();
        assert(("enum" in free.parameters["properties"]["model"].objectNoRef) is null);
        immutable cands = [SubCandidate("a/x", "quick searches", SubLimits(5, 60, 100)), SubCandidate("b/y", "hard analysis")];
        auto d = definition(cands);
        auto e = d.parameters["properties"]["model"]["enum"].arrayNoRef;
        assert(e.length == 2 && e[0].str == "a/x" && e[1].str == "b/y");
        assert(d.description.canFind("- a/x: quick searches") && d.description.canFind("- b/y: hard analysis"));
        assert(d.description.canFind("default a/x"));
        // Omitted model: the first, with its limits; outside the list: an error naming them.
        auto c = choose(parseArgs(parseJSON(`{"task":"t"}`), 600), cands, "z/z", SubLimits.init);
        assert(c.model == "a/x" && c.limits.turns == 5 && c.limits.timeoutSecs == 60);
        assert(choose(parseArgs(parseJSON(`{"task":"t","model":"b/y","timeout_s":7}`), 600), cands, "z/z",
            SubLimits.init).limits.timeoutSecs == 7);
        auto msg = collectExceptionMsg(choose(parseArgs(parseJSON(`{"task":"t","model":"q/q"}`), 600), cands, "z/z", SubLimits.init));
        assert(msg.canFind(`"q/q"`) && msg.canFind("a/x, b/y"), msg);
        // No list: free-form, else the fallback.
        assert(choose(parseArgs(parseJSON(`{"task":"t","model":"q/q"}`), 600), null, "z/z", SubLimits.init).model == "q/q");
        assert(choose(parseArgs(parseJSON(`{"task":"t"}`), 600), null, "z/z", SubLimits.init).model == "z/z");
        // /subagents arguments and status.
        assert(parseToggle("").unwrap("ok").show);
        auto t = parseToggle("off --save").unwrap("ok");
        assert(!t.show && !t.on && t.save);
        assert(parseToggle("on").unwrap("ok").on && parseToggle("maybe").isErr && parseToggle("--save").isErr);
        auto st = statusText(true, cands, "z/z", SubLimits.init);
        assert(st.canFind(": on") && st.canFind("a/x (quick searches) — timeout 60s, 5 turns, 100 tokens"), st);
        assert(statusText(false, null, "z/z", SubLimits.init).canFind("off\nModel: z/z"));
    }
    assert(parseArgs(parseJSON(`{"task":"x","timeout_s":5,"model":"m/n"}`), 600).model == "m/n");
    // A JSON null timeout is omitted, so a candidate's own limit stays.
    assert(!parseArgs(parseJSON(`{"task":"x","timeout_s":null}`), 600).timeoutSet);
    assert(parseArgs(parseJSON(`{"task":"x","timeout_s":5}`), 600).timeoutSet);
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

// ---- background sub-agents (issue #266) ----

/// The tools that watch and steer background sub-agents.
enum string statusTool = "agent_status", readTool = "agent_read", cancelTool = "agent_cancel", waitTool = "agent_wait";

/// Whether `name` is one of the background-control tools.
bool isControlTool(string name) pure nothrow
{
    return name == statusTool || name == readTool || name == cancelTool || name == waitTool;
}

/// Most bytes one `agent_read` returns.
enum size_t readCap = 16 * 1024;
/// Seconds `agent_cancel` waits for the final report before cutting the
/// sub-agent off.
enum long cancelGraceSecs = 5;
/// Most seconds one `agent_wait` blocks.
enum long maxWaitSecs = 3600;
/// Finished sub-agents kept for `agent_status` after their result was
/// delivered (older ones are forgotten; their logs stay).
enum size_t keepDelivered = 16;
/// Recent tool calls `agent_status` shows per sub-agent.
enum size_t recentCalls = 3;

/// The background-control tools' definitions.
ToolDefinition[] controlDefinitions() pure
{
    return [
        ToolDefinition(statusTool, "Status of this session's sub-agents (one by id, or all): state (queued, running, done, "
            ~ "cancelled, truncated), turns, tokens, elapsed time and the last few tool calls. Cheap: no transcript.",
            parseJSON(`{"type":"object","properties":{"id":{"type":"string","description":"A handle such as sub-3; omit for all."}}}`)),
        ToolDefinition(readTool, "Read a sub-agent's log (its messages and tool calls) from line `since`, at most 16 KB; "
            ~ "the result ends with the `since` to continue from.",
            parseJSON(`{"type":"object","properties":{"id":{"type":"string"},"since":{"type":"integer","description":"The log line to start at (default 0)."}},"required":["id"]}`)),
        ToolDefinition(cancelTool, "Cancel a background sub-agent: it gets one short final step to report what it has "
            ~ "(returned here, marked cancelled and partial); if it can't report within a few seconds it is cut off.",
            parseJSON(`{"type":"object","properties":{"id":{"type":"string"},"reason":{"type":"string","description":"Why, for the log."}},"required":["id","reason"]}`)),
        ToolDefinition(waitTool, "Wait until the given background sub-agents finish or timeout_s passes; returns their "
            ~ "results (each delivered once), or their status for the ones still running.",
            parseJSON(`{"type":"object","properties":{"ids":{"type":"array","items":{"type":"string"}},"timeout_s":{"type":"integer","description":"Seconds to wait at most."}},"required":["ids","timeout_s"]}`)),
    ];
}

/// A short summary of a tool call's arguments for `agent_status`: the
/// argument values, joined, at most `max` characters.
string argSummary(string argsJson, size_t max = 60)
{
    import std.range : walkLength;
    import std.utf : toUTF8;
    import std.array : array;
    string s;
    try
    {
        auto j = parseJSON(argsJson);
        if (j.type == JSONType.object)
            foreach (k, v; j.objectNoRef)
                s ~= (s.length ? ", " : "") ~ k ~ "=" ~ (v.type == JSONType.string ? v.str : v.toString);
        else s = argsJson;
    }
    catch (JSONException) s = argsJson; // not JSON: show it raw
    if (s.walkLength > max) s = toUTF8(s.array[0 .. max - 1]) ~ "…";
    return s;
}

unittest
{
    assert(argSummary(`{"pattern":"parse"}`) == "pattern=parse");
    import std.array : replicate;
    import std.range : walkLength;
    assert(argSummary(`{"p":"` ~ "x".replicate(100) ~ `"}`).walkLength == 60);
    assert(argSummary("nope") == "nope");
}

/// What `agent_read` returns: log lines from `since`, capped at `cap`
/// bytes, and the line to continue from. Streams the file in chunks and
/// keeps only what it returns, so a large log is never loaded whole.
string readLogTail(string path, size_t since, size_t cap = readCap)
{
    import std.array : appender;
    import std.stdio : File;
    import nano.safeio : ownText;
    auto f = File(path, "rb");
    auto out_ = appender!string;
    ubyte[] line;
    size_t lineNo, next = since;
    bool full;
    auto buf = new ubyte[64 * 1024];
    // Appends a finished line (when in range) and says whether to stop.
    bool finish()
    {
        scope (exit) { line = null; lineNo++; }
        if (lineNo < since) return false;
        auto text = ownText(line.dup);
        if (out_.data.length + text.length + 1 > cap)
        {
            if (out_.data.length == 0)
            {
                // One line bigger than the cap: its head, and move past it.
                size_t n = cap;
                while (n > 0 && n < text.length && (text[n] & 0xC0) == 0x80) n--;
                out_ ~= text[0 .. n] ~ "…[line cut at 16 KB]\n";
                next = lineNo + 1;
            }
            full = true;
            return true;
        }
        out_ ~= text ~ "\n";
        next = lineNo + 1;
        return false;
    }
    outer: for (;;)
    {
        auto got = f.rawRead(buf);
        if (!got.length) break;
        foreach (b; got)
        {
            if (b == '\n') { if (finish()) break outer; }
            // Keep at most cap + 1 bytes of a line: anything longer is cut
            // to its head in finish(), so a multi-MB line never sits whole
            // in memory.
            else if (lineNo >= since && line.length <= cap) line ~= b;
        }
    }
    // A last line without a newline may still be being written: leave it.
    auto body_ = out_.data.length ? out_.data : (since > lineNo ? "(no line " ~ format("%s", since) ~ " yet)\n" : "(nothing new)\n");
    return body_ ~ format("[next since: %s%s]", next, full ? "; more follows" : "");
}

unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    import std.array : replicate;
    import std.algorithm : canFind;
    auto p = buildPath(tempDir, "nano-readlog-test.jsonl");
    scope (exit) remove(p);
    write(p, "a\nb\nc\npartial");
    auto t = readLogTail(p, 0);
    assert(t.canFind("a\nb\nc\n") && t.canFind("[next since: 3]") && !t.canFind("partial"), t);
    assert(readLogTail(p, 2).canFind("c\n[next since: 3]"));
    assert(readLogTail(p, 3).canFind("(nothing new)"));
    // The byte cap stops before a line that would cross it.
    write(p, "x".replicate(10) ~ "\n" ~ "y".replicate(10) ~ "\nz\n");
    auto c = readLogTail(p, 0, 15);
    assert(c.canFind("xxxxxxxxxx\n[next since: 1; more follows]"), c);
    // A single line over the cap is cut and skipped.
    auto big = readLogTail(p, 1, 4);
    assert(big.canFind("yyyy…[line cut") && big.canFind("[next since: 2; more follows]"), big);
    // A line far larger than the cap and the read buffer is cut to its head.
    write(p, "h".replicate(200_000) ~ "\nnext\n");
    auto huge = readLogTail(p, 0, 8);
    assert(huge.canFind("hhhhhhhh…[line cut") && !huge.canFind("hhhhhhhhh")
        && huge.canFind("[next since: 1; more follows]"), huge);
    assert(readLogTail(p, 1, 8).canFind("next\n[next since: 2]"));
}

// ---- /subagents list, show and stop (issue #267) ----

/// The `/subagents` usage line.
enum string commandUsage = "/subagents [on|off] [--save] | show <id> | stop <id>|all";

/// One sub-agent as `/subagents` lists it.
struct SubInfo
{
    /// Its handle (`sub-N`), model and state (queued, running, done, cancelled, truncated).
    string id, model, state;
    /// Its launch sequence: a combined listing sorts on it, so it stays
    /// oldest first even when children enter the archive out of launch order.
    size_t seq;
    /// The first line of its task, cut to `taskCols` characters.
    string task;
    size_t turns;
    ulong tokens;
    long elapsedSecs;
    bool background;
    /// Its log, once open (empty before it starts or without session logs).
    string logPath;
}

/// Most finished sub-agents a session remembers for `/subagents` (older
/// ones are counted only; their logs stay).
enum size_t keepHistory = 200;
/// Characters of a task's first line kept for the listing.
enum size_t taskCols = 60;

/// The first line of `text`, at most `max` characters (an ellipsis marks a cut).
string firstLine(string text, size_t max = taskCols) pure
{
    import std.utf : decode;
    // One bounded walk: stop at the newline or after `max` code points, so a
    // huge one-line task is neither scanned nor copied beyond the prefix.
    size_t i, cut, n;
    while (i < text.length && text[i] != '\n' && (!max || n < max))
    {
        if (max && n == max - 1) cut = i;
        decode(text, i);
        ++n;
    }
    if (i < text.length && text[i] != '\n') return text[0 .. cut].idup ~ "…";
    text = text[0 .. i];
    // A copy: a slice would keep a long task body alive in the listing history.
    return text.idup;
}

unittest // the first line is a copy, not a slice of the task
{
    import std.array : replicate;
    auto task = "short\n" ~ "x".replicate(10_000);
    auto line = firstLine(task);
    assert(line == "short" && line.ptr != task.ptr);
    auto plain = "only";
    assert(firstLine("abcdef", 4) == "abc…");
    assert(firstLine("abcd", 4) == "abcd");
    assert(firstLine("äöüßé", 3) == "äö…");
    assert(firstLine(plain).ptr != plain.ptr);
}

/// The log at `path` as it is now: the session tidy-up of another process may
/// have compressed a finished child's `.jsonl` to `.jsonl.gz` since. Null
/// when neither exists.
string currentLogPath(string path)
{
    import std.file : exists;
    if (path.exists) return path;
    if ((path ~ ".gz").exists) return path ~ ".gz";
    return null;
}

unittest // a compressed child log is found by its original path
{
    import std.file : tempDir, write, remove, exists;
    import std.path : buildPath;
    import std.conv : to;
    import std.process : thisProcessID;
    auto p = buildPath(tempDir, "nano-curlog-" ~ thisProcessID.to!string ~ ".jsonl");
    assert(currentLogPath(p) is null);
    write(p ~ ".gz", "");
    scope (exit) remove(p ~ ".gz");
    assert(currentLogPath(p) == p ~ ".gz");
    write(p, "");
    scope (exit) remove(p);
    assert(currentLogPath(p) == p);
}

/// The sub-agent table `/subagents` shows below the on/off state; `forgotten`
/// counts finished ones dropped from memory (`keepHistory`).
string listingText(const(SubInfo)[] all, size_t forgotten) pure
{
    import nano.context : formatTokens;
    import nano.arith : toSize;
    if (!all.length && !forgotten) return "No sub-agents in this session yet.";
    string s = "Sub-agents of this session:";
    if (forgotten) s ~= format("\n  (%s earlier ones not shown; their logs stay)", forgotten);
    foreach (ref i; all)
        s ~= format("\n  %s  %s  %s%s  %s turns · %s tokens · %ss  %s", i.id, i.model, i.state,
            i.background ? " (background)" : "", i.turns, formatTokens(toSize(i.tokens)), i.elapsedSecs, i.task);
    return s ~ "\n/subagents show <id> shows a transcript; /subagents stop <id>|all stops them.";
}

/// `/subagents show <id>`.
struct SubShowCmd
{
    string id;
}

/// `/subagents stop <id>` or `/subagents stop all` (`id` is then "all").
struct SubStopCmd
{
    string id;
}

/// A `/subagents` argument that doesn't parse: the message to show.
struct SubCmdError
{
    string message;
}

/// A parsed `/subagents` command, or why it doesn't parse.
alias SubCommand = imported!"std.sumtype".SumType!(SubToggle, SubShowCmd, SubStopCmd, SubCmdError);

/// Parse `/subagents [on|off] [--save]`, `show <id>` or `stop <id>|all`.
SubCommand parseCommand(string arg) pure
{
    import std.string : split;
    import nano.result : unwrap, unwrapErr;
    auto w = arg.split;
    if (w.length && (w[0] == "show" || w[0] == "stop"))
    {
        if (w.length != 2)
            return SubCommand(SubCmdError(format("/subagents %s needs one sub-agent id%s (usage: %s)", w[0],
                w[0] == "stop" ? " or all" : "", commandUsage)));
        return w[0] == "show" ? SubCommand(SubShowCmd(w[1])) : SubCommand(SubStopCmd(w[1]));
    }
    auto t = parseToggle(arg);
    if (t.isErr) return SubCommand(SubCmdError(t.unwrapErr("isErr")));
    return SubCommand(t.unwrap("isOk"));
}

unittest
{
    import std.sumtype : match;
    string kind(string a)
    {
        return parseCommand(a).match!((SubCmdError e) => "err: " ~ e.message,(SubToggle t) => t.show ? "show-state" : t.on ? "on" : "off",
            (SubShowCmd s) => "show " ~ s.id, (SubStopCmd s) => "stop " ~ s.id);
    }
    assert(kind("") == "show-state" && kind("off") == "off" && kind(" on --save") == "on");
    assert(kind("show sub-2") == "show sub-2" && kind("stop  sub-3 ") == "stop sub-3" && kind("stop all") == "stop all");
    assert(kind("stop").canFind("needs one sub-agent id or all"));
    assert(kind("show a b").canFind("needs one sub-agent id ("));
    assert(kind("bogus").canFind("usage: /subagents [on|off] [--save] | show"));
}

unittest // the listing, mixed states
{
    import std.algorithm : count;
    assert(listingText(null, 0) == "No sub-agents in this session yet.");
    auto all = [SubInfo("sub-1", "a/x", "done", 1, firstLine("find it\nmore"), 3, 1500, 12),
        SubInfo("sub-2", "b/y", "running", 2, "scan", 1, 10, 4, true),
        SubInfo("sub-3", "a/x", "queued", 3, "later", 0, 0, 0, true),
        SubInfo("sub-4", "a/x", "cancelled", 4, "stop me", 2, 20, 7, true)];
    auto t = listingText(all, 5);
    assert(t.canFind("5 earlier ones not shown"), t);
    assert(t.canFind("sub-1  a/x  done  3 turns · 1.5k tokens · 12s  find it\n"), t);
    assert(!t.canFind("more"), t);
    assert(t.canFind("sub-2  b/y  running (background)") && t.canFind("sub-3  a/x  queued")
        && t.canFind("sub-4  a/x  cancelled (background)  2 turns"), t);
    assert(t.count("\n  sub-") == 4);
    import std.array : replicate;
    import std.range : walkLength;
    assert(firstLine("é".replicate(100)).walkLength == taskCols);
}

/// Stream the conversation messages of a session log (a sub-agent's) to
/// `dg`, one line at a time, so even a large log is never held whole.
/// Other records (header, compaction, plans) are skipped; `dg` returns
/// false to stop early.
void eachLogMessage(string path, scope bool delegate(Message) @safe dg)
{
    import nano.session : eachLogLineUntil, messageFromRecord;
    import std.algorithm : startsWith;
    eachLogLineUntil(path, (const(char)[] line, ulong) {
        // A record's type comes first (`record` in nano.session).
        if (!line.startsWith(`{"type":"message"`)) return true;
        Message m;
        try
        {
            auto data = parseJSON(line)["data"];
            // messageFromRecord rejects an unknown role: skip it like damage.
            auto role = "role" in data;
            if (role is null || role.type != JSONType.string || !["system", "user", "assistant", "tool"].canFind(role.str))
                return true;
            m = messageFromRecord(data);
        }
        catch (JSONException) return true; // a damaged record: skip it as a resume does
        return dg(m);
    }, false);
}

unittest // a large synthetic log streams in order, within the test budget
{
    import std.file : tempDir, remove;
    import std.path : buildPath;
    import std.stdio : File;
    import std.array : replicate;
    import std.conv : to;
    import nano.session : messageRecord;
    import core.memory : GC;
    auto p = buildPath(tempDir, "nano-sublog-" ~ to!string(monoNow.ticks) ~ ".jsonl");
    scope (exit) remove(p);
    {
        auto f = File(p, "wb");
        f.write(`{"type":"session","data":{"version":1}}` ~ "\n");
        auto pad = "x".replicate(1000);
        foreach (i; 0 .. 4000)
        {
            auto m = i % 2 ? Message.assistant(to!string(i) ~ pad) : Message.user(to!string(i) ~ pad);
            f.write(`{"type":"message","data":` ~ messageRecord(m).jsonText ~ "}\n");
            if (i % 1000 == 0) f.write(`{"type":"plan","data":{}}` ~ "\n");
        }
        f.write(`{"type":"message","data":{"role":"user","content":"torn`); // no newline: not committed
    }
    size_t n;
    bool ordered = true;
    eachLogMessage(p, (Message m) {
        import std.algorithm : startsWith;
        if (!m.content.startsWith(to!string(n) ~ "x")) ordered = false;
        n++;
        return true;
    });
    assert(n == 4000 && ordered, to!string(n));
    // Stopping early reads no further.
    size_t seen;
    eachLogMessage(p, (Message m) => ++seen < 3);
    assert(seen == 3);
}
