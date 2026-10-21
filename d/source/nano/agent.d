/// The agent loop: send the conversation, stream the reply, run the tool
/// calls it asks for (after permission checks), feed results back, repeat.
module nano.agent;

import std.json;
import std.format : format;
import std.string : strip, stripLeft;
import std.array : join;
import std.conv : to;
import nano.llm;
import nano.tools;
import nano.question : QuestionError, QuestionBroker, Question, QuestionOption, Answer;
import nano.mode : AgentMode, planAllows;
import nano.goal : Outcome, OutcomeError, OutcomeStatus, outcomeToolName = toolName, outcomeDefinition = definition;
import nano.reminders : Reminders, wrap;
import ctx = nano.context;
import hist = nano.session_history;
import nano.instructions : ProjectInstructions;
import nano.plan : Plan, PlanError, isPlanTool, planDefinitions = definitions;
import nano.permissions;
import nano.session;
import nano.control;
import nano.claude_hooks : HookManager, Decision, applyUpdatedInput, maxStopBlocks;

/// What the loop reports as it works (the CLI renders these).
interface AgentEvents
{
    void text(bool reasoning, string chunk);
    void toolStart(const ref ToolCall call);
    void toolEnd(const ref ToolCall call, string result, bool isError);
    void usage(TokenUsage u);
    /// A steering message joined the conversation mid-turn.
    void userMessage(string text);
    /// A complete model reply (after its deltas went to `text`).
    void assistantMessage(string text, string reasoning);
}

/// Wrap text the model should read as a system note, not user words.
string wrapReminder(string text)
{
    return "<system-reminder>\n" ~ text ~ "\n</system-reminder>";
}

/// Why compaction was requested.
enum CompactTrigger { manual, threshold, overflow }

/// What a compaction did.
struct CompactReport
{
    size_t messagesBefore, messagesAfter, tokensBefore, tokensAfter, summarized;
    /// Why the summary failed (older messages were dropped instead), or null.
    string fallback;
    bool truncated;
    ctx.CompactionMode mode;

    string toString() const
    {
        auto s = format("%scompacted %s messages: ~%s -> ~%s tokens (%s -> %s messages)",
            mode == ctx.CompactionMode.smart ? "smart-" : "", summarized, ctx.formatTokens(tokensBefore),
            ctx.formatTokens(tokensAfter), messagesBefore, messagesAfter);
        if (fallback !is null) s ~= format("; summary failed (%s), older messages were dropped", fallback);
        else if (truncated) s ~= "; the summary hit the output limit and is incomplete";
        return s;
    }
}

/// The result for calls skipped after the loop detector's hard stop.
enum string loopStoppedToolResult =
    "Error: the turn is ending as blocked (repeated-call loop detected); this tool call was not run.";

/// Why a turn ended (ACP `stopReason`).
/// The turn cap for runs nobody can answer a "keep going?" prompt in.
enum headlessSafetyCap = 300;

enum StopReason : string
{
    endTurn = "end_turn",
    cancelled = "cancelled",
    maxTurnRequests = "max_turn_requests",
    maxTokens = "max_tokens",
}

class Agent
{
    LLMClient client;
    ToolRegistry tools;
    Policy policy;
    Message[] messages;
    long maxIterations;
    long maxTokens;
    double temperature = double.nan;
    SessionLog log;
    TokenUsage lastUsage;
    /// Steer or cancel the running turn from another thread.
    TurnControl control;
    /// Why the last `run` ended.
    StopReason lastStop;
    /// Claude Code-compatible user hooks (null = none).
    HookManager hooks;
    /// Whether this agent continues a restored session (`SessionStart` source).
    bool resumed;
    private bool sessionStarted;
    private string pendingStartContext;
    private int stopBlocks;

    // ---- context accounting and compaction (context.rs, agent.rs) ----
    /// Compact automatically past `autoCompactThreshold` of the window.
    bool autoCompact = true;
    double autoCompactThreshold = 0.8;
    ctx.CompactionMode compactionMode = ctx.CompactionMode.standard;
    /// The provider config's `context_window` (0: none).
    size_t configuredWindow;
    /// Learned from a context-overflow error (0: none).
    size_t learnedWindow;
    /// Compactions this session.
    uint compactions;
    /// Session token totals.
    ulong sessionInputTokens, sessionOutputTokens;
    /// Called after every compaction with its report (the UI prints it).
    void delegate(const ref CompactReport) onCompacted;
    /// Usage-anchored estimate: messages[0 .. calibLen] cost `calibTokens`.
    private size_t calibLen, calibTokens;
    /// Tokens right after the last compaction: no auto-compaction until the
    /// context has grown a tenth of the window past it (no compaction loops).
    private size_t compactFloor;

    this(LLMClient client, ToolRegistry tools, Policy policy, string systemPrompt)
    {
        this.client = client;
        this.tools = tools;
        this.policy = policy;
        this.control = new TurnControl;
        if (systemPrompt.length) push(Message.system(systemPrompt));
    }

    void push(Message m)
    {
        import nano.session : nowStamp;
        if (!m.timestamp.length) m.timestamp = nowStamp();
        if (log !is null) m.logLine = log.append(m);
        messages ~= m;
    }

    /// Run one user input to completion. Returns the final assistant text,
    /// or `cancelledResponse` when the turn was cancelled. Steers that arrive
    /// too late for this turn stay in `control` for the caller to queue.
    /// Pass `resetControl = false` when the caller already called
    /// `control.startTurn()`, so a cancel routed before `run` began is kept.
    string run(string input, AgentEvents ev, bool resetControl = true)
    {
        import std.datetime.systime : Clock;
        // Every input carries an id; the log pairs it with a turn_end record,
        // so an input without one marks a turn a crash interrupted.
        auto inputId = format("in-%s-%s", (Clock.currStdTime - 621_355_968_000_000_000L) / 10_000, ++inputCounter);
        if (log !is null) log.input(inputId, input);
        string response;
        try response = runTurn(input, ev, resetControl);
        catch (Exception e)
        {
            if (log !is null) log.turnEnd(inputId, "Error: " ~ e.msg, "end_turn");
            throw e;
        }
        if (log !is null)
            log.turnEnd(inputId, response, cast(string) lastStop, hasOutcome ? lastOutcome.toJSON : JSONValue.init);
        return response;
    }

    private size_t inputCounter;

    private string runTurn(string input, AgentEvents ev, bool resetControl)
    {
        if (resetControl) control.startTurn();
        stopBlocks = 0;
        hasOutcome = hasReported = false;
        reminders.outcomeTool = outcomeTool;
        reminders.startTurn();
        if (hooks !is null)
        {
            syncHookSession();
            if (!sessionStarted)
            {
                // Runs once; its context waits for the first accepted prompt.
                sessionStarted = true;
                auto start = hooks.runSessionStart(resumed ? "resume" : "startup");
                if (auto ctx = start.contextBlock) pendingStartContext = ctx;
            }
            auto o = hooks.runUserPromptSubmit(input);
            if (o.blocked)
            {
                push(Message.user(input));
                auto reason = o.blockReason.strip.length ? o.blockReason : "Your message was blocked by a UserPromptSubmit hook.";
                push(Message.assistant(reason, null));
                ev.text(false, reason);
                ev.assistantMessage(reason, null);
                lastStop = StopReason.endTurn;
                return reason;
            }
            string[] extra;
            if (pendingStartContext !is null) extra ~= pendingStartContext;
            pendingStartContext = null;
            if (auto ctx = o.contextBlock) extra ~= ctx;
            if (extra.length) input ~= "\n\n" ~ wrapReminder(extra.join("\n\n"));
        }
        push(Message.user(input));
        string last;
        // The turn cap: interactive normal mode asks to keep going; auto mode
        // has none; headless runs (ACP, -p) stop at the cap, or at a safety
        // cap when there is none. Re-read from the live mode each iteration.
        long granted, iteration, budget;
        for (;;)
        {
            iteration++;
            auto mode = control.mode;
            bool headlessCap = headless && (maxIterations <= 0 || mode == AgentMode.auto_);
            budget = headlessCap ? headlessSafetyCap + granted
                : (mode == AgentMode.auto_ || maxIterations <= 0) ? long.max : maxIterations + granted;
            if (iteration > budget)
            {
                if (mode == AgentMode.normal && !headless && askKeepGoing())
                {
                    ev.text(false, "\n[continuing past the turn cap]\n");
                    granted += maxIterations;
                    iteration--;
                    continue;
                }
                break;
            }
            if (control.isCancelled) return cancelled(ev);
            foreach (s; control.takePending)
            {
                push(Message.user(s.text));
                ev.userMessage(s.text);
                control.absorbed(s);
            }
            if (overThreshold())
            {
                CompactReport rep;
                compact(rep, CompactTrigger.threshold);
                if (control.isCancelled) return cancelled(ev);
            }
            LLMResponse r;
            import std.datetime.stopwatch : StopWatch, AutoStart;
            auto sw = StopWatch(AutoStart.yes);
            bool overflowRetried, capRetried;
            for (;;)
            {
                ChatRequest req;
                req.messages = messages;
                req.tools = offeredTools();
                req.maxTokens = requestMaxTokens();
                req.temperature = temperature;
                try
                {
                    r = client.chat(req, (bool t, string s) { ev.text(t, s); });
                    break;
                }
                catch (Cancelled) return cancelled(ev);
                catch (Exception e)
                {
                    if (control.isCancelled) return cancelled(ev);
                    if (!capRetried && maxTokens > 0 && ctx.isOutputCapError(e.msg) && !ctx.isContextOverflow(e.msg))
                    {
                        // The provider caps output below max_tokens: learn it and retry.
                        auto cap = ctx.outputCapFromError(e.msg);
                        if (cap > 0 && (learnedMaxOutput == 0 || cap < learnedMaxOutput))
                        {
                            capRetried = true;
                            learnedMaxOutput = cap;
                            continue;
                        }
                    }
                    if (overflowRetried || !ctx.isContextOverflow(e.msg)) throw e;
                    // The request did not fit: learn the window, compact, retry once.
                    overflowRetried = true;
                    auto learned = ctx.limitFromError(e.msg);
                    if (!learned) learned = estimateContextTokens() * 9 / 10;
                    learnedWindow = learned > 1_000 ? learned : 1_000;
                    CompactReport rep;
                    if (!compact(rep, CompactTrigger.overflow))
                    {
                        if (control.isCancelled) return cancelled(ev);
                        throw e;
                    }
                    if (control.isCancelled) return cancelled(ev);
                }
            }
            lastUsage = r.usage;
            recordUsage(r.usage);
            if (r.usage.inputTokens > 0)
            {
                // Anchored at the assistant message about to be pushed.
                calibLen = messages.length + 1;
                calibTokens = cast(size_t)(r.usage.inputTokens + (r.usage.outputTokens > 0 ? r.usage.outputTokens : 0));
            }
            ev.usage(r.usage);
            auto reply = Message.assistant(r.content, r.toolCalls);
            reply.thinking = r.reasoning;
            reply.usage = r.usage;
            reply.hasUsage = r.usage != TokenUsage.init;
            reply.durationMs = sw.peek.total!"msecs";
            reply.stopReason = r.toolCalls.length ? "tool_use"
                : (r.stopReason == "length" || r.stopReason == "max_tokens") ? "max_tokens" : "end_turn";
            push(reply);
            last = r.content;
            if (r.content.length || r.reasoning.length) ev.assistantMessage(r.content, r.reasoning);
            if (r.toolCalls.length == 0)
            {
                bool cut = r.stopReason == "length" || r.stopReason == "max_tokens";
                if (cut) ev.text(false, "\n[the reply hit the output-token limit]");
                // A steer that arrived while the answer was written extends the turn.
                if (control.hasSteers && !control.isCancelled) continue;
                // A blocking Stop hook keeps the turn going (capped per turn).
                if (hooks !is null && !cut && stopBlocks < maxStopBlocks && !control.isCancelled
                    && iteration < budget)
                {
                    auto o = hooks.runStop(stopBlocks > 0);
                    if (o.blocked)
                    {
                        stopBlocks++;
                        auto reason = o.blockReason.strip.length ? o.blockReason : "A Stop hook asked the agent to keep going.";
                        push(Message.user(wrapReminder(reason)));
                        ev.userMessage(reason);
                        continue;
                    }
                }
                lastStop = cut ? StopReason.maxTokens : StopReason.endTurn;
                return last;
            }
            string loopStop;
            foreach (call; r.toolCalls)
            {
                ev.toolStart(call);
                bool isError = true;
                string result;
                if (control.isCancelled) result = cancelledToolResult;
                else if (loopStop !is null) result = loopStoppedToolResult;
                else
                {
                    result = runTool(call, r.stopReason, isError);
                    // Deeper instruction files and scoped rules attach to the first
                    // file-tool result that touches a matching path.
                    if (!isError && instructions !is null
                        && (call.name == "read_file" || call.name == "write_file" || call.name == "edit_file"))
                        if (auto p = "path" in call.arguments)
                            if (p.type == JSONType.string)
                            {
                                import std.file : getcwd;
                                if (auto nested = instructions.nestedFor(p.str, getcwd())) result ~= nested;
                            }
                    if (hist.isHistoryTool(call.name)) historyHintPending = false;
                    else if (historyHintPending && historyEnabled && hist.looksFailed(call.name, !isError, result))
                    {
                        historyHintPending = false;
                        result ~= "\n\n" ~ hist.failedToolHint;
                    }
                    if (remindersEnabled) result ~= remind(call, !isError, result, loopStop);
                }
                ev.toolEnd(call, result, isError);
                push(Message.toolResult(call.id, call.name, result, isError));
            }
            if (loopStop !is null)
            {
                // The loop detector's hard stop: end the turn as blocked rather
                // than burning budget until the turn cap.
                reported = Outcome(OutcomeStatus.blocked, loopStop);
                auto response = reported.response;
                push(Message.assistant(response, null));
                ev.text(false, response);
                ev.assistantMessage(response, null);
                lastOutcome = reported;
                hasOutcome = true;
                hasReported = false;
                lastStop = StopReason.endTurn;
                return response;
            }
            if (hasReported)
            {
                // A reported outcome ends the turn like a tool-free answer, so
                // it passes the same Stop gate.
                if (hooks !is null && stopBlocks < maxStopBlocks && !control.isCancelled && iteration < budget)
                {
                    auto o = hooks.runStop(stopBlocks > 0);
                    if (o.blocked)
                    {
                        stopBlocks++;
                        hasReported = false;
                        auto reason = o.blockReason.strip.length ? o.blockReason : "A Stop hook asked the agent to keep going.";
                        push(Message.user(wrapReminder(reason)));
                        ev.userMessage(reason);
                        last = reported.response;
                        continue;
                    }
                }
                auto response = reported.response;
                push(Message.assistant(response, null));
                ev.text(false, response);
                ev.assistantMessage(response, null);
                lastOutcome = reported;
                hasOutcome = true;
                hasReported = false;
                lastStop = StopReason.endTurn;
                return response;
            }
        }
        auto note = format("[stopped after %s LLM calls without a final answer]", iteration - 1);
        ev.text(false, "\n" ~ note);
        lastStop = StopReason.maxTurnRequests;
        return (last ~ "\n" ~ note).stripLeft;
    }

    /// System reminders for one finished call: plan/memory nudges and the
    /// loop detector, whose hard stop sets `loopStop`. Returns text to append.
    private string remind(const ref ToolCall call, bool ok, string result, ref string loopStop)
    {
        if ((planTools && isPlanTool(call.name)) || (outcomeTool && call.name == outcomeToolName))
        {
            // Never counted, but they break a repeat streak.
            reminders.resetRepeat();
            return null;
        }
        import nano.memory : saveTool;
        if (ok && call.name == saveTool) reminders.memorySaved();
        string extra;
        foreach (note; reminders.afterToolCall(plan, tools.has(saveTool))) extra ~= "\n\n" ~ wrap(note);
        auto v = reminders.afterRepeatCall(call.name, call.arguments,
                call.invalidArguments.length ? call.invalidArguments : null, ok, result ~ extra);
        if (v.warning) extra ~= "\n\n" ~ wrap(v.text);
        else if (v.hardStop)
        {
            extra ~= "\n\n" ~ wrap("This call already ran, but it has repeated too many times: the turn is ending "
                    ~ "as blocked and any further retries are being stopped. Do not retry it.");
            loopStop = v.text;
        }
        return extra;
    }

    /// The context window and where it came from.
    size_t contextWindow() const { string _; return contextWindow(_); }

    size_t contextWindow(out string source) const
    {
        size_t w;
        if (configuredWindow) { w = configuredWindow; source = "configured"; }
        else if ((w = ctx.windowForModel(client.modelName)) != 0) source = "known for the model name";
        else { w = ctx.defaultContextWindow; source = "default"; }
        if (learnedWindow && learnedWindow < w)
        {
            w = learnedWindow;
            source = "learned from a context-overflow error";
        }
        return w;
    }

    /// Estimated tokens the next request sends, and whether it is anchored
    /// to provider-reported usage.
    size_t estimateContextTokens(out bool calibrated)
    {
        calibrated = calibLen && calibLen <= messages.length;
        if (calibrated) return calibTokens + ctx.messagesTokens(messages[calibLen .. $]);
        size_t tools_;
        foreach (d; offeredTools())
            tools_ += ctx.textTokens(d.name) + ctx.textTokens(d.description) + ctx.textTokens(() @trusted { return d.parameters.toString; }());
        return ctx.messagesTokens(messages) + tools_;
    }

    size_t estimateContextTokens() { bool _; return estimateContextTokens(_); }

    private size_t outputBase() const { return maxTokens > 0 ? cast(size_t) maxTokens : ctx.minOutputReserve; }

    /// Past the auto-compaction threshold (or too close to the window for the
    /// output reservation)?
    bool overThreshold()
    {
        if (!autoCompact) return false;
        auto threshold = autoCompactThreshold < 0.1 ? 0.1 : autoCompactThreshold > 0.99 ? 0.99 : autoCompactThreshold;
        auto tokens = estimateContextTokens();
        auto window = contextWindow();
        auto reserved = (outputBase < ctx.minOutputReserve ? outputBase : ctx.minOutputReserve) + ctx.outputMargin(window);
        double limit = window * threshold;
        if (window > reserved && window - reserved < limit) limit = window - reserved;
        return tokens > limit && tokens > compactFloor + window / 10;
    }

    /// `max_tokens` for the next request: the configured value lowered so the
    /// prompt plus output fits the window. 0 (unset) stays unset.
    /// An output cap learned from a provider error (0 = none); /model resets it.
    long learnedMaxOutput;

    private long requestMaxTokens()
    {
        if (maxTokens <= 0) return maxTokens;
        auto maxTokens = learnedMaxOutput > 0 && learnedMaxOutput < this.maxTokens ? learnedMaxOutput : this.maxTokens;
        auto window = contextWindow();
        auto used = estimateContextTokens() + ctx.outputMargin(window);
        long room = window > used ? cast(long)(window - used) : 0;
        auto n = maxTokens < room ? maxTokens : room;
        return n < 1 ? 1 : n;
    }

    /// Summarize older messages into one, keeping recent messages verbatim.
    /// `mode` overrides `compactionMode` (null: the configured one); `focus`
    /// steers the summary. Returns false when there is nothing to compact.
    bool compact(out CompactReport report, CompactTrigger trigger = CompactTrigger.manual,
            const(ctx.CompactionMode)* mode = null, string focus = null)
    {
        ctx.CompactionMode m = mode is null ? compactionMode : *mode;
        // Smart compaction points into the session log; without one it is standard.
        if (log is null) m = ctx.CompactionMode.standard;
        bool smart = m == ctx.CompactionMode.smart;
        auto window = contextWindow();
        size_t bodyStart = messages.length && messages[0].role == Role.system ? 1 : 0;
        auto len = messages.length;
        size_t keepBudget = trigger == CompactTrigger.manual ? 0
            : (ctx.keepRecentTokens < window / 4 ? ctx.keepRecentTokens : window / 4);
        // Split where no tool result is separated from its call.
        size_t[] boundaries;
        foreach (i; bodyStart + 1 .. len)
            if (messages[i].role == Role.user || messages[i].role == Role.assistant) boundaries ~= i;
        if (!boundaries.length) return false;
        auto split = boundaries[$ - 1];
        foreach_reverse (b; boundaries)
        {
            if (ctx.messagesTokens(messages[b .. $]) > keepBudget) break;
            split = b;
        }
        if (split == boundaries[0]) split = boundaries[$ - 1];
        auto summarized = messages[bodyStart .. split].dup;
        if (!summarized.length) return false;
        auto tokensBefore = estimateContextTokens();
        ulong first, last;
        foreach (ref x; summarized)
            if (x.logLine)
            {
                if (!first || x.logLine < first) first = x.logLine;
                if (x.logLine > last) last = x.logLine;
            }

        auto budget = ctx.summaryOutputBudget(window, cast(long) outputBase);
        string summary, fallback;
        bool truncated, retried;
        for (;;)
        {
            auto inputWindow = window > cast(size_t) budget ? window - cast(size_t) budget : 0;
            auto chars = (inputWindow > 4_000 ? inputWindow - 2_000 : 2_000) * 3;
            auto request = "Conversation to summarize:\n\n" ~ ctx.renderTranscript(summarized, chars, smart);
            if (focus.strip.length) request ~= "\n\nWhen summarizing, focus on: " ~ focus.strip;
            ChatRequest req;
            req.messages = [Message.system(ctx.summarySystemPrompt ~ (smart ? ctx.smartSummaryInstructions : "")),
                Message.user(request)];
            req.maxTokens = budget;
            req.temperature = temperature;
            try
            {
                auto r = client.chat(req, (bool, string) {});
                recordUsage(r.usage);
                truncated = r.stopReason == "length" || r.stopReason == "max_tokens";
                auto body_ = r.content.strip;
                if (body_.length)
                {
                    if (truncated) body_ ~= ctx.summaryTruncatedNote;
                    summary = smart ? ctx.smartSummaryPrefix ~ "\n" ~ body_ ~ "\n\n" ~ ctx.smartSummaryNote(first, last)
                        : ctx.summaryPrefix ~ "\n" ~ body_;
                }
                else
                {
                    fallback = truncated ? "empty summary: the output limit was reached before any summary text" : "empty summary";
                    truncated = false;
                }
                break;
            }
            catch (Cancelled) return false;
            catch (Exception e)
            {
                if (control.isCancelled) return false;
                // Learn a smaller output cap and retry once.
                if (!retried && ctx.isOutputCapError(e.msg) && !ctx.isContextOverflow(e.msg))
                {
                    retried = true;
                    long learned = ctx.outputCapFromError(e.msg);
                    if (!learned) learned = budget / 2 > 1_024 ? budget / 2 : 1_024;
                    if (learned < 256) learned = 256;
                    if (learned < budget) { budget = learned; continue; }
                }
                fallback = e.msg;
                break;
            }
        }
        if (fallback !is null)
        {
            auto note = format("[%s earlier messages were removed to fit the context window; no summary is available]",
                summarized.length);
            summary = smart && first ? ctx.smartSummaryPrefix ~ "\n" ~ note ~ "\n\n" ~ ctx.smartSummaryNote(first, last) : note;
        }
        if (planTools && !plan.empty) summary ~= "\n\n" ~ plan.contextNote();

        Message[] next = messages[0 .. bodyStart].dup;
        next ~= Message.user(summary);
        next[$ - 1].timestamp = nowStamp();
        next ~= messages[split .. $];
        if (trigger != CompactTrigger.manual)
        {
            auto clipTo = window / 8 > 1_000 ? window / 8 : 1_000;
            foreach (ref x; next[bodyStart + 1 .. $])
                if (x.role == Role.tool && ctx.clipMessage(x, clipTo) && smart && x.logLine)
                    x.content ~= format("\n[clipped at compaction; history_read #%s has it whole]", x.logLine);
        }
        messages = next;
        calibLen = 0;
        if (log !is null) log.replace(messages, first, last, ctx.modeName(m), client.providerName ~ "/" ~ client.modelName);
        report = CompactReport(len, messages.length, tokensBefore, estimateContextTokens(), split - bodyStart,
            fallback, truncated, m);
        // Nested instructions attached to folded tool results may be gone.
        if (instructions !is null) instructions.forgetNested();
        compactFloor = report.tokensAfter;
        compactions++;
        historyAvailable = historyHintPending = m == ctx.CompactionMode.smart;
        if (onCompacted !is null) onCompacted(report);
        return true;
    }

    private void recordUsage(TokenUsage u)
    {
        sessionInputTokens += u.inputTokens;
        sessionOutputTokens += u.outputTokens;
    }

    private string cancelled(AgentEvents ev)
    {
        ev.text(false, "\n" ~ cancelledResponse);
        lastStop = StopReason.cancelled;
        return cancelledResponse;
    }

    private string runTool(const ref ToolCall call, string stopReason, out bool isError)
    {
        isError = true;
        if (call.invalidArguments.length)
        {
            auto raw = call.invalidArguments.length > 300 ? call.invalidArguments[0 .. 300] ~ "…" : call.invalidArguments;
            auto advice = stopReason == "length" || stopReason == "max_tokens"
                ? "The reply was cut off by the output-token limit; send a smaller call (e.g. write the file in parts)."
                : "Send the arguments as a single JSON object.";
            return format("Invalid arguments for %s (not a JSON object): %s\n%s", call.name, raw, advice);
        }
        bool isPlan = planTools && isPlanTool(call.name);
        bool isOutcome = outcomeTool && call.name == outcomeToolName;
        bool isHistory = historyEnabled && hist.isHistoryTool(call.name);
        if (!isPlan && !isOutcome && !isHistory && !tools.has(call.name))
            return format("Tool '%s' not found. Available: %s", call.name, toolNames());
        // Backstop for a call already in flight when plan mode was switched on.
        if (control.mode == AgentMode.plan && !planAllows(call.name))
            return format("%s is disabled in plan mode (read-only)", call.name);
        if (auto blocked = policy.check(call.name, call.arguments)) return blocked;
        // PreToolUse hooks run after the permission check, before the tool:
        // they can deny the call, rewrite its input, or add context.
        JSONValue args = call.arguments;
        string[] context;
        if (hooks !is null)
        {
            auto o = hooks.runPreToolUse(call.name, call.arguments, call.id);
            if (auto ctx = o.contextBlock) context ~= ctx;
            string deny;
            if (o.denies) deny = o.blockReason.length ? o.blockReason : "blocked by a PreToolUse hook";
            else if (o.decision == Decision.ask)
                deny = o.blockReason.strip.length ? o.blockReason
                    : "a PreToolUse hook requested confirmation (ask), which nano cannot prompt for yet; blocking the call";
            else if (o.updatedInput.type != JSONType.null_)
            {
                args = applyUpdatedInput(call.name, call.arguments, o.updatedInput);
                // The rewritten input must pass the policy too, or a hook could
                // rewrite a command or path past the user's rules.
                if (auto blocked = policy.check(call.name, args)) deny = blocked;
            }
            if (deny !is null) return withContext(deny, context);
        }
        string out_;
        try
        {
            if (isOutcome)
            {
                auto o = Outcome.fromArgs(args);
                out_ = format("Recorded outcome: %s. Your turn ends now.", o.toJSON["status"].str);
                reported = o;
                hasReported = true;
            }
            else if (isHistory)
                out_ = call.name == hist.searchTool ? hist.search(log.path, args) : hist.read(log.path, args);
            else out_ = isPlan ? runPlanTool(call.name, args) : tools.execute(call.name, args);
            isError = false;
        }
        catch (ToolError e) out_ = e.msg;
        catch (PlanError e) out_ = e.msg;
        catch (hist.HistoryError e) out_ = e.msg;
        catch (OutcomeError e) out_ = e.msg;
        catch (QuestionError e) out_ = e.msg;
        catch (Exception e) out_ = format("%s failed: %s", call.name, e.msg);
        if (hooks !is null)
        {
            auto o = hooks.runPostToolUse(call.name, args, out_, call.id);
            if (auto ctx = o.contextBlock) context ~= ctx;
            if (o.blocked && o.blockReason.strip.length) context ~= o.blockReason;
        }
        return withContext(out_, context);
    }

    /// Instruction files: nested ones attach to file-tool results.
    ProjectInstructions instructions;
    /// A smart summary is in context: offer history_search/history_read.
    bool historyAvailable;
    /// Append the "look in history" hint to the next failed tool result.
    bool historyHintPending;
    bool historyEnabled() const { return log !is null && historyAvailable; }

    /// Offer `report_outcome` (config `outcome_tool`).
    bool outcomeTool = true;
    /// System reminders and the loop detector (config `reminders`).
    bool remindersEnabled = true;
    private Reminders reminders;
    /// Asks the user (question tool, turn-cap prompt); null or not
    /// interactive means headless: a hard cap and no prompts.
    QuestionBroker questions;
    /// The outcome the last turn reported, if any.
    Outcome lastOutcome;
    bool hasOutcome;
    private Outcome reported;
    private bool hasReported;

    /// The tools offered to the model: plan mode keeps only the read-only ones.
    ToolDefinition[] offeredTools()
    {
        auto all = tools.definitions ~ (planTools ? planDefinitions() : null)
            ~ (outcomeTool ? [outcomeDefinition()] : null) ~ (historyEnabled ? hist.definitions() : null);
        if (control.mode != AgentMode.plan) return all;
        ToolDefinition[] kept;
        foreach (t; all) if (planAllows(t.name)) kept ~= t;
        return kept;
    }

    private bool headless() { return questions is null || !questions.interactive; }

    /// Interactive normal mode: ask whether to keep going past the cap.
    private bool askKeepGoing()
    {
        auto q = Question("Reached the turn cap without a final answer. Keep going?", null,
            [QuestionOption("No"), QuestionOption("Yes")]);
        q.custom = false;
        auto a = questions.ask([q]);
        return a.kind == Answer.Kind.answers && a.answers.length && a.answers[0] == "Yes";
    }

    /// The task plan (`plan_*` tools), kept outside the conversation.
    Plan plan;
    /// Offer the plan tools (config `plan_tools`).
    bool planTools = true;
    /// Called after the plan changes (the UI shows the checklist).
    void delegate() onPlanChanged;

    private string runPlanTool(string name, JSONValue args)
    {
        auto o = plan.apply(name, args);
        if (o.changed) planChanged();
        return o.text;
    }

    private void planChanged()
    {
        reminders.planChanged();
        if (log !is null) log.plan(plan.toJSON);
        if (onPlanChanged !is null) onPlanChanged();
    }

    /// Replace the plan with one carried over from an earlier run, telling
    /// the model about it unless `announce` is false.
    void setPlan(Plan p, bool announce)
    {
        plan = p;
        if (announce && planTools && !plan.empty) push(Message.user(plan.carriedOverNote));
        if (log !is null) log.plan(plan.toJSON);
    }

    private static string withContext(string text, string[] context)
    {
        foreach (c; context) text ~= "\n\n" ~ wrapReminder(c);
        return text;
    }

    /// Attach `h` for a fresh (`resumed = false`) or restored session:
    /// `SessionStart` runs again on the next prompt, and the hook config files
    /// are recorded in the session log for the audit trail.
    void useHooks(HookManager h, bool resumed)
    {
        hooks = h;
        this.resumed = resumed;
        sessionStarted = false;
        pendingStartContext = null;
        if (h is null || log is null || !h.files.length) return;
        import nano.claude_hooks : label;
        string[3][] files;
        foreach (f; h.files) files ~= [f.path, f.source.label, f.hash];
        log.hooks(files);
    }

    private void syncHookSession()
    {
        hooks.setSession(log !is null ? log.id : "", log !is null ? log.path : "",
            control.mode == AgentMode.plan ? "plan" : "default");
    }

    private string toolNames()
    {
        string s;
        foreach (d; tools.definitions) s ~= (s.length ? ", " : "") ~ d.name;
        return s;
    }
}

version (unittest)
{
    import nano.providers.mock;

    class NullEvents : AgentEvents
    {
        string shown;
        string[] tools;
        void text(bool r, string s) { if (!r) shown ~= s; }
        void toolStart(const ref ToolCall c) { tools ~= c.name; }
        void toolEnd(const ref ToolCall c, string res, bool err) {}
        void usage(TokenUsage u) {}
        string[] steered;
        void userMessage(string t) { steered ~= t; }
        void assistantMessage(string t, string r) {}
    }
}

unittest
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)),
        (JSONValue a) => "echoed " ~ a["text"].str);
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{"text":"hi"}`), ToolCall.fromRaw("c2", "nope", `{}`),
            ToolCall.fromRaw("c3", "echo", `{"text":`)]),
        LLMResponse("done"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    auto ev = new NullEvents;
    assert(agent.run("go", ev) == "done");
    assert(ev.tools == ["echo", "nope", "echo"]);
    auto second = mock.seen[1];
    assert(second[$ - 3].content == "echoed hi" && !second[$ - 3].isError);
    assert(second[$ - 2].isError && second[$ - 1].isError);
    import std.string : indexOf;
    assert(second[$ - 1].content.indexOf("Invalid arguments") == 0);
}

unittest
{
    auto reg = new ToolRegistry;
    bool ran;
    reg.register(ToolDefinition("bash", "", parseJSON(`{}`)), (JSONValue a) { ran = true; return ""; });
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "bash", `{"command":"sudo rm -rf /"}`)]),
        LLMResponse("ok"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, null);
    agent.maxIterations = 5;
    agent.run("x", new NullEvents);
    assert(!ran);
    import std.string : indexOf;
    assert(mock.seen[1][$ - 1].content.indexOf("Blocked") == 0);
}

// A steer sent while a tool runs joins the next model call.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    reg.register(ToolDefinition("work", "", parseJSON(`{}`)), (JSONValue a) {
        agent.control.steer("use the other file");
        return "ok";
    });
    auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c1", "work", `{}`)]), LLMResponse("done")]);
    agent = new Agent(mock, reg, Policy.init, null);
    auto ev = new NullEvents;
    assert(agent.run("go", ev) == "done");
    assert(ev.steered == ["use the other file"]);
    assert(mock.seen[1][$ - 1].role == Role.user && mock.seen[1][$ - 1].content == "use the other file");
}

// A steer that lands during the final answer extends the turn.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    auto mock = new MockClient([LLMResponse("long answer"), LLMResponse("short")]);
    agent = new Agent(mock, reg, Policy.init, null);
    auto ev = new NullEvents;
    agent.control.startTurn();
    // Queued before `run`: absorbed before the first call, so no extension.
    agent.control.steer("make it shorter");
    assert(agent.run("go", ev) == "long answer");
    assert(ev.steered == ["make it shorter"]);
}

// A cancel stops the turn: remaining tool calls are recorded as cancelled.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    int runs;
    reg.register(ToolDefinition("work", "", parseJSON(`{}`)), (JSONValue a) {
        runs++;
        agent.control.cancel();
        return "ok";
    });
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "work", `{}`), ToolCall.fromRaw("c2", "work", `{}`)]),
        LLMResponse("never"),
    ]);
    agent = new Agent(mock, reg, Policy.init, null);
    assert(agent.run("go", new NullEvents) == cancelledResponse);
    assert(runs == 1 && mock.seen.length == 1);
    assert(agent.messages[$ - 1].content == cancelledToolResult && agent.messages[$ - 1].isError);
    // The next turn starts clean.
    agent.client = new MockClient([LLMResponse("fine")]);
    assert(agent.run("again", new NullEvents) == "fine");
}

// Claude hooks in the loop: prompt context and blocking, PreToolUse deny and
// rewrite (re-checked against the policy), PostToolUse context, Stop blocks.
unittest
{
    import nano.claude_hooks : Hook, Event;
    import std.algorithm : canFind;
    import std.file : tempDir;
    import core.time : seconds;
    Hook hook(Event e, string command, string matcher = null)
    {
        Hook h;
        h.event = e;
        h.command = command;
        h.matcher = matcher;
        h.timeout = 10.seconds;
        return h;
    }
    string[] ran;
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("bash", "", parseJSON(`{}`)), (JSONValue a) { ran ~= a["command"].str; return "ran"; });
    reg.register(ToolDefinition("echo", "", parseJSON(`{}`)), (JSONValue a) { ran ~= "echo"; return "echoed"; });

    // UserPromptSubmit: context is attached; exit 2 rejects without a model call.
    auto mock = new MockClient([LLMResponse("ok")]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    agent.hooks = new HookManager([hook(Event.sessionStart, "echo started"),
        hook(Event.userPromptSubmit, `grep -q forbidden && { echo no secrets >&2; exit 2; }; echo ctx`)], tempDir);
    assert(agent.run("hello", new NullEvents) == "ok");
    auto first = mock.seen[0][$ - 1].content;
    assert(first.canFind("hello") && first.canFind("started") && first.canFind("ctx") && first.canFind("<system-reminder>"), first);
    assert(agent.run("forbidden words", new NullEvents) == "no secrets");
    assert(mock.seen.length == 1);
    assert(agent.messages[$ - 1].content == "no secrets");

    // PreToolUse: deny blocks, rewrites apply but pass the policy again.
    mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{}`), ToolCall.fromRaw("c2", "bash", `{"command":"ls"}`),
            ToolCall.fromRaw("c3", "bash", `{"command":"pwd"}`)]),
        LLMResponse("done"),
    ]);
    agent = new Agent(mock, reg, Policy.init, null);
    agent.hooks = new HookManager([
        hook(Event.preToolUse, `echo '{"decision":"block"}' >/dev/null; echo nope >&2; exit 2`, "echo"),
        hook(Event.preToolUse, `grep -q '"ls"' && echo '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"echo patched"}}}' || echo '{"hookSpecificOutput":{"updatedInput":{"command":"sudo rm -rf /"}}}'`, "Bash"),
        hook(Event.postToolUse, `echo '{"hookSpecificOutput":{"additionalContext":"post-note"}}'`, "Bash"),
    ], tempDir);
    ran = null;
    agent.run("go", new NullEvents);
    auto results = mock.seen[1][$ - 3 .. $];
    assert(results[0].content == "nope", results[0].content);
    assert(results[1].content.canFind("ran") && results[1].content.canFind("post-note"), results[1].content);
    assert(results[2].content.canFind("Blocked"), "a rewrite past the policy is blocked: " ~ results[2].content);
    assert(ran == ["echo patched"], ran.join(","));

    // Stop: a block keeps the turn going, capped per turn.
    mock = new MockClient([LLMResponse("a"), LLMResponse("b"), LLMResponse("c"), LLMResponse("d"), LLMResponse("e")]);
    agent = new Agent(mock, reg, Policy.init, null);
    agent.hooks = new HookManager([hook(Event.stop, `echo '{"decision":"block","reason":"more"}'`)], tempDir);
    assert(agent.run("go", new NullEvents) == "d");
    assert(mock.seen.length == 4 && mock.seen[1][$ - 1].content.canFind("more"));
}

// report_outcome ends the turn with its summary as the answer.
unittest
{
    import nano.providers.mock;
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "report_outcome", `{"status":"blocked","summary":"no token"}`)]),
        LLMResponse("never sent"),
    ]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    auto ev = new NullEvents;
    assert(agent.run("go", ev) == "Blocked: no token");
    assert(agent.hasOutcome && agent.lastOutcome.summary == "no token");
    assert(mock.seen.length == 1 && agent.lastStop == StopReason.endTurn);
    assert(agent.messages[$ - 2].content == "Recorded outcome: blocked. Your turn ends now.");
    assert(agent.messages[$ - 1].content == "Blocked: no token");
    // A bad report is a tool error the model can fix; the turn goes on.
    mock.script = [
        LLMResponse("", "", [ToolCall.fromRaw("c2", "report_outcome", `{"status":"maybe","summary":"x"}`)]),
        LLMResponse("fine"),
    ];
    assert(agent.run("again", ev) == "fine" && !agent.hasOutcome);
}

// A headless turn stops at the cap with Rust's note; plan mode hides mutating tools.
unittest
{
    import nano.providers.mock;
    import std.algorithm : canFind;
    auto echo = LLMResponse("working", "", [ToolCall.fromRaw("c", "echo", `{}`)]);
    auto mock = new MockClient([echo, echo, echo]);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    reg.register(ToolDefinition("read_file", "", parseJSON(`{"type":"object"}`)), (JSONValue a) => "text");
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    agent.maxIterations = 2;
    auto response = agent.run("go", new NullEvents);
    assert(mock.seen.length == 2 && agent.lastStop == StopReason.maxTurnRequests);
    assert(response == "working\n[stopped after 2 LLM calls without a final answer]", response);
    assert(mock.toolsSeen[0].canFind("echo") && mock.toolsSeen[0].canFind("report_outcome"));

    agent.control.mode = AgentMode.plan;
    mock.script = [echo, LLMResponse("ok")];
    agent.maxIterations = 0;
    agent.run("plan it", new NullEvents);
    assert(!mock.toolsSeen[$ - 1].canFind("echo") && mock.toolsSeen[$ - 1].canFind("read_file"));
    assert(mock.toolsSeen[$ - 1].canFind("plan_add"));
    // The in-flight backstop.
    assert(agent.messages[$ - 2].content == "echo is disabled in plan mode (read-only)");
}

// The loop detector warns on repeated identical calls, then ends the turn as
// blocked and skips the rest of the batch.
unittest
{
    import std.algorithm : startsWith, canFind;
    import nano.providers.mock;
    LLMResponse same(string id, size_t n = 1)
    {
        ToolCall[] calls;
        foreach (i; 0 .. n) calls ~= ToolCall.fromRaw(format("%s-%s", id, i), "nope", `{"a":1}`);
        return LLMResponse("", "", calls);
    }
    auto mock = new MockClient([same("c1"), same("c2"), same("c3"), same("c4"), same("c5", 2), LLMResponse("never")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    auto answer = agent.run("go", new NullEvents);
    assert(answer.startsWith("Blocked: the model repeated the same `nope` call 5 times"), answer);
    assert(agent.hasOutcome && mock.seen.length == 5);
    assert(agent.messages[$ - 2].content == loopStoppedToolResult, agent.messages[$ - 2].content);
    assert(agent.messages[$ - 3].content.canFind("Do not retry it."));
    bool warned;
    foreach (m; agent.messages) if (m.content.canFind("try something different, or call report_outcome")) warned = true;
    assert(warned);
    // Disabled, the loop runs into the turn cap instead.
    mock.script = [same("d1"), same("d2"), same("d3"), same("d4"), same("d5"), same("d6"), LLMResponse("done")];
    agent.remindersEnabled = false;
    assert(agent.run("again", new NullEvents) == "done");
}

// Compaction: manual, past the threshold, and after a context overflow.
unittest
{
    import std.algorithm : startsWith, canFind;
    import nano.providers.mock;
    auto mock = new MockClient([LLMResponse("SUM")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    agent.messages ~= [Message.user("u1"), Message.assistant("a1"), Message.user("u2"), Message.assistant("a2")];
    CompactReport rep;
    assert(agent.compact(rep));
    assert(agent.messages.length == 3 && agent.messages[1].content == ctx.summaryPrefix ~ "\nSUM");
    assert(agent.messages[2].content == "a2" && rep.summarized == 3 && agent.compactions == 1);
    assert(rep.toString.startsWith("compacted 3 messages: ~"), rep.toString);
    // The summarizer saw the folded messages, not the kept one.
    auto req = mock.seen[0][1].content;
    assert(req.canFind("USER:\nu1") && req.canFind("ASSISTANT:\na1") && !req.canFind("a2"));
    assert(mock.seen[0][0].content == ctx.summarySystemPrompt);
    // Nothing left to fold.
    agent.messages = agent.messages[0 .. 1] ~ Message.user("only");
    assert(!agent.compact(rep));

    // A failed summary drops the older messages with a note.
    mock.script = [LLMResponse("!error:boom")];
    agent.messages ~= [Message.assistant("a"), Message.user("b")];
    assert(agent.compact(rep) && rep.fallback == "boom");
    assert(agent.messages[1].content.startsWith("[2 earlier messages were removed"));

    // Past the threshold, the turn compacts before the request and goes on.
    string big;
    foreach (_; 0 .. 1_000) big ~= "0123456789";
    auto auto_ = new MockClient([LLMResponse("SUM2"), LLMResponse("done")]);
    auto b = new Agent(auto_, new ToolRegistry, Policy.init, "sys");
    b.configuredWindow = 4_000;
    b.messages ~= [Message.user(big), Message.assistant(big), Message.user("q"), Message.assistant("a")];
    string reported;
    b.onCompacted = (ref const CompactReport r) { reported = r.toString; };
    assert(b.overThreshold());
    assert(b.run("go", new NullEvents) == "done");
    assert(auto_.seen.length == 2 && auto_.seen[0][0].content == ctx.summarySystemPrompt, reported);
    assert(auto_.seen[1][1].content == ctx.summaryPrefix ~ "\nSUM2" && reported.canFind("compacted"));
    assert(!b.overThreshold(), "the floor stops a compaction loop");

    // A context overflow learns the window, compacts and retries once.
    auto over = new MockClient([LLMResponse("!error:This model's maximum context length is 9000 tokens"),
        LLMResponse("SUM3"), LLMResponse("ok")]);
    auto c = new Agent(over, new ToolRegistry, Policy.init, "sys");
    c.messages ~= [Message.user("x"), Message.assistant("y")];
    assert(c.run("go", new NullEvents) == "ok");
    assert(c.learnedWindow == 9_000 && c.contextWindow == 9_000 && over.seen.length == 3);
    // A second overflow in the same request is an error.
    over.script = [LLMResponse("!error:context length exceeded"), LLMResponse("SUM4"),
        LLMResponse("!error:context length exceeded")];
    bool threw;
    try c.run("again", new NullEvents);
    catch (Exception e) threw = true;
    assert(threw);

    // An output-cap error lowers max_tokens and retries once.
    auto capped = new MockClient([LLMResponse("!error:max_tokens: 64000 > 32000, which is the maximum allowed"),
        LLMResponse("fine")]);
    auto d = new Agent(capped, new ToolRegistry, Policy.init, "sys");
    d.maxTokens = 64_000;
    d.configuredWindow = 1_000_000;
    assert(d.run("go", new NullEvents) == "fine" && d.learnedMaxOutput == 32_000);
}
