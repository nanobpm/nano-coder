/// The agent loop: send the conversation, stream the reply, run the tool
/// calls it asks for (after permission checks), feed results back, repeat.
module nano.agent;

@safe:
import nano.arith : checkedMul, checkedSub, saturatingSub;
import nano.option : Option, some, none, match, ifSome, unwrap;

import nano.safeio : Isolated, JoinHandle, spawnDaemon, stdErr, stdOut;

import std.json;
import std.format : format;
import std.string : strip, stripLeft;
import std.array : join;
import std.conv : to;
import nano.llm;
import nano.http : StreamInterrupted;
import core.thread : Thread;
import core.time : Duration;
static import nano.session_index;
import nano.tools;
import nano.question : QuestionError, QuestionBroker, Question, QuestionOption, Answer, Answered;
import std.sumtype : match;
import nano.mode : AgentMode, planAllows;
import nano.goal : Outcome, OutcomeError, OutcomeStatus, verifyReminder, outcomeToolName = toolName, outcomeDefinition = definition;
import nano.reminders : Reminders, wrap;
import mem = nano.memory;
import ctx = nano.context;
import hist = nano.session_history;
import nano.instructions : ProjectInstructions;
import nano.thinking : Thinking, ThinkingResolved = Resolved, resolveThinking = resolve, Request, cappedBudget, Reported;
import temp = nano.temperature;
import nano.vision : Vision, resolveVision = resolve;
import nano.llm : Attachment;

/// A tool result as displayed: the text plus each attached image's placeholder.
string toolResultDisplay(string text, const(Attachment)[] attachments)
{
    foreach (ref a; attachments) text ~= (text.length ? "\n" : "") ~ a.placeholder;
    return text;
}
import nano.config : ProviderConfig, ProviderKind;
import std.typecons : Nullable;
import std.algorithm : min, max, clamp;
import nano.plan : Plan, PlanError, isPlanTool, planDefinitions = definitions;
import nano.timers : Timers, TimerError, isTimerTool, timerDefinitions = definitions, firedMessage, firedNotice, pendingNudge, pendingNudgeEvery;
import nano.permissions;
import nano.session;
import nano.control;
import nano.claude_hooks : HookManager, Decision, HookOutcome = Outcome, applyUpdatedInput, maxStopBlocks;

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
string wrapReminder(string text) nothrow
{
    return "<system-reminder>\n" ~ text ~ "\n</system-reminder>";
}

/// Why compaction was requested.
enum CompactTrigger { manual, threshold, overflow, /** opportunistic, at the idle prompt (Rust #186); folds like threshold */ idle }

/// Once-per-crossing gate for idle compaction (Rust `idle_compact.rs`): after
/// an idle attempt that did not compact, it stays shut until the context grows
/// by real headroom (`window / 10`); any compaction or a reset re-arms it.
struct IdleCompactGate
{
    private bool spent;
    private size_t spentAt;
    bool armed(size_t tokens, size_t window) const { return !spent || tokens > spentAt + window / 10; }
    void spend(size_t tokens) { spent = true; spentAt = tokens; }
    void reset() { spent = false; }
}

/// An idle compaction's outcome, with usage before and after as a percentage
/// of the window for the transcript note.
struct IdleCompactReport
{
    CompactReport report;
    size_t percentBefore, percentAfter;

    this(CompactReport r, size_t window)
    {
        import std.math : round;
        size_t pct(size_t t) { return cast(size_t) round(t * 100.0 / (window ? window : 1)); }
        report = r;
        percentBefore = pct(r.tokensBefore);
        percentAfter = pct(r.tokensAfter);
    }

    string toString() const
    {
        auto s = format("compacted while idle (was %s%% → %s%%)", percentBefore, percentAfter);
        // A degraded compaction is never reported as a clean one.
        if (report.fallback !is null || report.truncated) s ~= "; " ~ report.toString;
        return s;
    }
}

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
    /// The global temperature (NaN = default); provider and model settings
    /// and `extra_body` are resolved per request (`temperatureFor`).
    double temperature = double.nan;
    /// The global thinking level and vision override.
    Thinking globalThinking;
    Nullable!bool globalVision;
    /// `/thinking LEVEL` for this session (null = use the config).
    Nullable!Thinking sessionThinking;
    /// The provider settings for a provider name (null when unknown).
    const(ProviderConfig)* delegate(string name) providerLookup;
    /// What the endpoint reports about the current model.
    Capabilities capabilities;
    private ProviderConfig noProvider;
    Option!SessionLog log;
    TokenUsage lastUsage;
    /// Steer or cancel the running turn from another thread.
    shared TurnControl control;
    /// Why the last `run` ended.
    StopReason lastStop;
    /// Finished turns by input id (see `Restored.completed`): redelivering
    /// one returns the recorded response without re-running the turn.
    string[string] completedInputs;
    string[string] completedStops;
    JSONValue[string] completedOutcomes;
    /// Claude Code-compatible user hooks (null = none).
    Option!HookManager hooks;
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
    /// Pin the user's requests verbatim after each compaction summary
    /// (`compaction_pin_requests`, issue #66).
    bool compactionPinRequests = true;
    /// The accepted input whose turn has not ended (redelivering its id resumes it).
    bool hasPending;
    PendingInput pending;

    /// Take a restored log's pending input. Its positions index the logged
    /// conversation; the agent keeps its own system prompt in place of any
    /// logged system message, so remap them.
    void adoptPending(const ref Restored r)
    {
        // A loaded conversation starts a fresh crossing.
        resetIdleCompaction();
        hasPending = r.hasPending;
        if (!hasPending) return;
        pending = r.pending;
        static size_t remap(const Message[] conv, size_t i)
        {
            size_t n = 1;
            foreach (ref m; conv[0 .. min(i, conv.length)]) if (m.role != Role.system) n++;
            return n;
        }
        pending.position = remap(r.conversation, r.pending.position);
        if (pending.hasBase) pending.base = remap(r.conversation, r.pending.base);
    }

    /// Mirror the live continuation into the pending input (so a mid-turn
    /// compaction persists it) and advance its replay boundary.
    private void syncPendingContinuation(string answer, size_t count)
    {
        if (!hasPending) return;
        pending.hasContinuation = answer.length || count;
        pending.answer = pending.hasContinuation ? answer : null;
        pending.count = pending.hasContinuation ? count : 0;
        pending.hasBase = true;
        pending.base = messages.length;
    }

    /// Take a reported outcome from a resumed turn's messages; true when found.
    private bool outcomeFrom(const Message[] tail)
    {
        foreach_reverse (ref m; tail)
            foreach_reverse (ref c; m.toolCalls)
                if (c.name == outcomeToolName)
                {
                    try
                    {
                        lastOutcome = Outcome.fromArgs(c.arguments);
                        hasOutcome = true;
                        return true;
                    }
                    catch (Exception) {} // malformed outcome arguments: not a recorded outcome, keep scanning
                }
        return false;
    }

    /// Set before `run` when the input is harness-initiated (a fired timer);
    /// `run` consumes it.
    bool automaticInput;
    /// The genuine user requests folded by earlier compactions, so each
    /// compaction rebuilds the pinned block from originals (Rust's
    /// `pre_compaction_transcript`, trimmed to requests).
    Message[] pinStash;
    /// The provider config's `context_window` (0: none).
    size_t configuredWindow;
    /// Learned from a context-overflow error (0: none).
    size_t learnedWindow;
    /// Compactions this session.
    uint compactions;
    /// Longest tool result kept whole (characters); longer ones are cut and spilled.
    size_t toolOutputLimit = 40_000;
    /// Session token totals.
    ulong sessionInputTokens, sessionOutputTokens;
    /// AI Credits used this session; `hasSessionAic` once a provider reported any.
    bool hasSessionAic;
    double sessionAic = 0;
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
        this.control = new shared TurnControl;
        if (systemPrompt.length) push(Message.system(systemPrompt));
    }

    void push(Message m)
    {
        import nano.session : nowStamp;
        if (!m.timestamp.length) m.timestamp = nowStamp();
        log.ifSome((SessionLog l) { m.logLine = l.append(m); });
        messages ~= m;
    }

    /// Answer the tool calls of the last assistant message that a crash left
    /// without results, so a resumed conversation is valid to send (providers
    /// reject a tool call with no result). Each repair is logged like a push.
    void repairDanglingToolCalls()
    {
        foreach (m; danglingRepairs(messages)) push(m);
    }

    /// Run one user input to completion. Returns the final assistant text,
    /// or `cancelledResponse` when the turn was cancelled. Steers that arrive
    /// too late for this turn stay in `control` for the caller to queue.
    /// Pass `resetControl = false` when the caller already called
    /// `control.startTurn()`, so a cancel routed before `run` began is kept.
    string run(string input, AgentEvents ev, bool resetControl = true, string givenId = null)
    {
        import std.datetime.systime : Clock;
        import std.conv : to;
        // A harness-initiated input (a fired timer): never pinned as a request.
        bool automatic = automaticInput;
        automaticInput = false;
        if (givenId.length)
            if (auto done = givenId in completedInputs)
            {
                import std.stdio : stderr;
                stdErr.writefln("[agent] input %s already processed; returning recorded response", JSONValue(givenId).toString);
                auto st = givenId in completedStops;
                lastStop = st is null ? StopReason.endTurn : stopReasonFrom(*st);
                auto oc = givenId in completedOutcomes;
                hasOutcome = oc !is null;
                if (hasOutcome) lastOutcome = Outcome.fromArgs(*oc);
                return *done;
            }
        // Every input carries an id; the log pairs it with a turn_end record,
        // so an input without one marks a turn a crash interrupted.
        auto inputId = givenId.length ? givenId
            : format("in-%s-%s", (Clock.currStdTime - 621_355_968_000_000_000L) / 10_000, ++inputCounter);
        ulong from = logSize();
        // Redelivering the id of an interrupted turn resumes it (its input
        // was logged already).
        bool resuming = hasPending && givenId.length && pending.id == givenId;
        if (!resuming) log.ifSome((SessionLog l) { l.input(inputId, input); });
        string response;
        try response = runTurn(input, ev, resetControl, automatic, inputId, resuming);
        catch (Exception e)
        {
            log.ifSome((SessionLog l) {
                l.turnEnd(inputId, "Error: " ~ e.msg, "end_turn");
                indexTurn(l, from);
            });
            throw e;
        }
        log.ifSome((SessionLog l) {
            l.turnEnd(inputId, response, cast(string) lastStop, hasOutcome ? lastOutcome.toJSON : JSONValue.init);
            indexTurn(l, from);
        });
        hasPending = false;
        completedInputs[inputId] = response;
        if (lastStop != StopReason.endTurn) completedStops[inputId] = cast(string) lastStop;
        else completedStops.remove(inputId);
        if (hasOutcome) completedOutcomes[inputId] = lastOutcome.toJSON;
        else completedOutcomes.remove(inputId);
        return response;
    }

    /// Ask for session titles (`session_titles`): `titleClient` builds a client
    /// for a `provider/model` spec; `titleModel` (null: the session's model).
    bool sessionTitles;
    string titleModel;
    LLMClient delegate(string spec) titleClient;
    private bool[string] titlesRequested;

    private ulong logSize()
    {
        import std.file : getSize;
        string path = log.match!(l => l.path, () => string.init);
        if (!path.length) return 0;
        try return getSize(path);
        catch (Exception) return 0; // no log file yet (or unreadable): treat as empty
    }

    /// Keep the `--resume` picker's summary current (only a cache: the picker
    /// rebuilds a missing or stale summary), then maybe request a title.
    private void indexTurn(SessionLog log, ulong from)
    {
        import nano.session_index : update, Summary;
        Summary s;
        try s = update(log.path, from, client.providerName ~ "/" ~ client.modelName);
        catch (Exception) return; // indexing is best effort; the session log itself is intact
        requestTitle(s, log.path);
    }

    /// With `session_titles` on, ask the model for a title in the background
    /// once the session has a telling prompt and no title. Failures are silent:
    /// a later run tries again.
    private void requestTitle(const ref nano.session_index.Summary s, string logPath)
    {
        import nano.session_index : titleSource;
        if (!sessionTitles || titleClient is null || s.title !is null || (s.id in titlesRequested)) return;
        auto source = titleSource(s);
        if (source is null) return;
        titlesRequested[s.id] = true;
        auto spec = titleModel !is null ? titleModel : client.providerName ~ "/" ~ client.modelName;
        LLMClient c;
        try c = titleClient(spec);
        catch (Exception) return; // a title is optional
        // Isolated: `titleClient` builds a new client from a resolved
        // (deep-copied) config, and only the title thread keeps it.
        titleThreads ~= spawnDaemon(&fetchTitle, Isolated!LLMClient.assumeIsolated(c), source, logPath);
    }

    /// Ask `client` for a title for `source` and store it in the session at
    /// `path`. Runs on its own thread (`spawn`).
    private static void fetchTitle(Isolated!LLMClient client, string source, string path)
    {
        import nano.session_index : cleanTitle, setTitle;
        try
        {
            auto c = client.unwrap;
            ChatRequest req;
            req.messages = [Message.system(titlePrompt), Message.user(source)];
            req.maxTokens = 400; // room for reasoning models that think first
            auto title = cleanTitle(c.chat(req, null).content);
            if (title !is null) setTitle(path, title); // false: another process won
        }
        catch (Exception) {} // a title is optional
    }

    /// Title requests in flight (tests join them).
    JoinHandle[] titleThreads;

    /// Wait up to `max` for title requests to finish; false if one still runs.
    bool settleTitles(Duration max)
    {
        import core.time : MonoTime, msecs;
        auto deadline = MonoTime.currTime + max;
        foreach (t; titleThreads)
            while (t.running)
            {
                if (MonoTime.currTime >= deadline) return false;
                Thread.sleep(20.msecs);
            }
        return true;
    }

    private size_t inputCounter;

    /// System prompt for session titles.
    enum string titlePrompt = "You name coding-assistant sessions. Reply with a title of at most six words "
        ~ "that says what the user is working on, from their requests below. Reply with the title only: no quotes, "
        ~ "no trailing period.";

    private string runTurn(string input, AgentEvents ev, bool resetControl, bool automatic = false,
        string inputId = null, bool resuming = false)
    {
        if (resetControl) control.startTurn();
        stopBlocks = 0;
        hasOutcome = hasReported = false;
        // Verify-before-complete and the recall budget are per input: a
        // resumed input keeps them.
        if (!resuming) editsSinceCheck = verifyReminderFired = false;
        reminders.outcomeTool = outcomeTool;
        reminders.startTurn();
        recallTurnNotes = resuming ? pending.recallNotes : 0;
        string pinText;
        auto typed = input;
        // Where a resume `SessionStart` context message lands (size_t.max: none).
        size_t hookContextStart = size_t.max;
        foreach (h; hooks)
        {
            syncHookSession(h);
            if (!sessionStarted)
            {
                // Runs once; its context waits for the first accepted prompt.
                sessionStarted = true;
                auto start = h.runSessionStart(resumed ? "resume" : "startup");
                if (auto ctx = start.contextBlock) pendingStartContext = ctx;
            }
        }
        if (resuming)
        {
            // UserPromptSubmit isn't re-run: the prompt was accepted already.
            auto pos = pending.position;
            if (pos >= messages.length || messages[pos].role != Role.user)
            {
                // The input was logged but its user message was not.
                if (pos < messages.length) messages = messages[0 .. pos];
                pending.position = messages.length;
                push(Message.user(pending.text));
            }
            else if (messages.length > pos + 1 && messages[$ - 1].role == Role.assistant && !messages[$ - 1].toolCalls.length
                && !isLengthStop(messages[$ - 1].stopReason))
            {
                // The final answer was recorded but the turn end was not:
                // rebuild the whole answer, the chunks before it included.
                auto end = checkedSub(messages.length, 1);
                auto boundary = min(pending.hasBase ? pending.base : pos, end);
                auto rc = replayContinuation(pending, messages[boundary .. end]);
                outcomeFrom(messages[pos .. $]);
                lastStop = StopReason.endTurn;
                return rc.answer ~ messages[$ - 1].content;
            }
            else if (outcomeTool && messages[$ - 1].role == Role.tool && outcomeFrom(messages[pos .. $]))
            {
                // The outcome was reported but the answer it implies was not recorded.
                auto response = lastOutcome.response;
                push(Message.assistant(response));
                lastStop = StopReason.endTurn;
                return response;
            }
            if (pendingStartContext !is null)
            {
                hookContextStart = messages.length;
                auto hm = Message.user(wrapReminder(pendingStartContext));
                hm.hookContext = true;
                pendingStartContext = null;
                push(hm);
            }
        }
        else foreach (h; hooks)
        {
            auto o = h.runUserPromptSubmit(input);
            if (o.blocked)
            {
                hasPending = true;
                pending = PendingInput(inputId, typed, messages.length);
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
            if (extra.length)
            {
                pinText = input;
                input ~= "\n\n" ~ wrapReminder(extra.join("\n\n"));
            }
        }
        if (!resuming)
        {
            auto um = Message.user(input);
            um.pinText = pinText;
            um.autoInitiated = automatic;
            hasPending = true;
            pending = PendingInput(inputId, typed, messages.length);
            push(um);
        }
        string last;
        // Output-limit continuations: the cut-off chunks so far, and how many.
        string continued;
        size_t truncations;
        // A resumed turn rebuilds its in-flight continuation from the
        // messages logged before the interrupt (issue #114).
        if (resuming && pending.position <= messages.length)
        {
            auto start = pending.position;
            auto scanEnd = max(hookContextStart != size_t.max ? hookContextStart : messages.length, start);
            auto boundary = clamp(pending.hasBase ? pending.base : start, start, scanEnd);
            auto rc = replayContinuation(pending, messages[boundary .. scanEnd]);
            continued = rc.answer;
            truncations = rc.count;
            bool lastTruncated = scanEnd > start && messages[scanEnd - 1].role == Role.assistant
                && !messages[scanEnd - 1].toolCalls.length && isLengthStop(messages[scanEnd - 1].stopReason);
            // The crash came before the chunk's reminder was logged: re-prompt,
            // unless the budget is spent.
            if (lastTruncated && truncations < maxTruncatedContinuations) push(continuationReminder(0));
            syncPendingContinuation(continued, truncations);
            if (lastTruncated && truncations >= maxTruncatedContinuations)
            {
                // Never call the model past the cap: end the turn MaxTokens.
                outcomeFrom(messages[start .. $]);
                lastStop = StopReason.maxTokens;
                return continued;
            }
        }
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
            fireDueTimers(ev);
            if (overThreshold())
            {
                CompactReport rep;
                compact(rep, CompactTrigger.threshold);
                if (control.isCancelled) return cancelled(ev);
            }
            if (auto spec = control.takeModelRequest())
                if (onModelRequest !is null) onModelRequest(spec);
            if (auto level = control.takeThinkingRequest())
            {
                import nano.thinking : setSession;
                // Checked when it was typed, so this can't fail.
                try setSession(sessionThinking, level);
                catch (Exception) {} // the level was validated when typed, so this can't fail
            }
            LLMResponse r;
            import std.datetime.stopwatch : StopWatch, AutoStart;
            auto sw = StopWatch(AutoStart.yes);
            bool overflowRetried, capRetried;
            size_t dropped;
            for (;;)
            {
                ChatRequest req;
                req.messages = messages;
                req.tools = offeredTools();
                req.maxTokens = requestMaxTokens();
                auto th = thinking();
                req.thinking = th.request();
                req.vision = vision();
                req.attachmentsDir = attachmentsDir();
                req.temperature = temperatureFor(th.anthropicThinkingOn).effective;
                try
                {
                    r = client.chat(req, (bool t, string s) { ev.text(t, s); });
                    break;
                }
                catch (Cancelled) return cancelled(ev);
                catch (StreamInterrupted e)
                {
                    // The connection dropped mid-reply. Nothing of it was kept, so
                    // ask again (the request itself waits for the network).
                    if (control.isCancelled) return cancelled(ev);
                    if (++dropped > maxStreamRestarts) throw e;
                    stdErr.writefln("[agent] %s; asking again (%s/%s)", e.msg, dropped, maxStreamRestarts);
                    ev.text(false, "\n");
                    continue;
                }
                catch (Exception e)
                {
                    if (control.isCancelled) return cancelled(ev);
                    if (!capRetried && ctx.isOutputCapError(e.msg) && !ctx.isContextOverflow(e.msg))
                    {
                        // The provider caps output below the max_tokens this request
                        // sent: learn the cap (else halve what was sent) and retry once.
                        capRetried = true;
                        long sent = req.maxTokens;
                        long cap = ctx.outputCapFromError(e.msg);
                        if (cap <= 0) cap = sent / 2 > 1_024 ? sent / 2 : 1_024;
                        if (cap < 256) cap = 256;
                        if (cap < sent)
                        {
                            learnedMaxOutput = cap;
                            import std.stdio : stderr;
                            stdErr.writefln("[agent] output-limit rejection (%s); retrying with max_tokens=%s", e.msg, cap);
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
            reply.thinkingBlocks = r.thinkingBlocks;
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
                // A steer that arrived while the answer was written extends the
                // turn; the reply after it is a fresh answer.
                if (control.hasSteers && !control.isCancelled)
                {
                    continued = null;
                    syncPendingContinuation(continued, truncations);
                    continue;
                }
                // A reply cut off at the output-token limit isn't finished (any
                // tool call in it was dropped): ask for the rest, in smaller
                // pieces, up to maxTruncatedContinuations times.
                if (cut && iteration < budget && !control.isCancelled && truncations < maxTruncatedContinuations)
                {
                    truncations++;
                    continued ~= r.content;
                    push(continuationReminder(r.usage.outputTokens));
                    syncPendingContinuation(continued, truncations);
                    continue;
                }
                if (cut) ev.text(false, "\n[the reply hit the output-token limit]");
                // The whole answer: the chunks carried across continuations, then this one.
                last = continued ~ r.content;
                // A blocking Stop hook keeps the turn going (capped per turn).
                if (!cut && stopBlocks < maxStopBlocks && !control.isCancelled && iteration < budget)
                {
                    // Not `foreach (h; hooks)`: the `continue` below is for the turn loop.
                    auto o = hooks.match!(h => h.runStop(stopBlocks > 0), () => HookOutcome.init);
                    if (o.blocked)
                    {
                        stopBlocks++;
                        continued = null;
                        syncPendingContinuation(continued, truncations);
                        auto reason = o.blockReason.strip.length ? o.blockReason : "A Stop hook asked the agent to keep going.";
                        push(Message.auto_(wrapReminder(reason)));
                        ev.userMessage(reason);
                        continue;
                    }
                }
                lastStop = cut ? StopReason.maxTokens : StopReason.endTurn;
                return last;
            }
            // Tool calls begin a new answer: dropped call markup mustn't prefix it.
            continued = null;
            syncPendingContinuation(continued, truncations);
            string loopStop;
            foreach (call; r.toolCalls)
            {
                ev.toolStart(call);
                bool isError = true;
                string result;
                Attachment[] attachments;
                bool dispatched;
                JSONValue effectiveArgs;
                auto recallBefore = recallState.dup;
                auto notesBefore = recallTurnNotes;
                if (control.isCancelled) result = cancelledToolResult;
                else if (loopStop !is null) result = loopStoppedToolResult;
                else
                {
                    {
                        import nano.tools : setSpillDir, spillDirFor, truncateOutput;
                        // Cut outputs are kept beside a persisted session's log.
                        setSpillDir(log.match!(l => spillDirFor(l.path), () => string.init));
                        result = runTool(call, r.stopReason, isError, dispatched, effectiveArgs);
                        // bash, read_file and history_read bound their own output.
                        if (call.name != "bash" && call.name != "read_file" && call.name != hist.readTool
                            && call.name != "load_skill")
                            result = truncateOutput(result, toolOutputLimit,
                                format("tool-%s-%s", safeName(call.id), safeName(call.name)));
                    }
                    // A successful edit marks the tree unchecked; a bash call
                    // that started (even one exiting non-zero) is the check.
                    if (!isError && (call.name == "write_file" || call.name == "edit_file")) editsSinceCheck = true;
                    else if (dispatched && !isError && call.name == "bash") editsSinceCheck = false;
                    if (call.name == "read_file") result = imageResult(result, isError, attachments);
                    // Deeper instruction files and scoped rules attach to the first
                    // file-tool result that touches a matching path.
                    if (!isError && (call.name == "read_file" || call.name == "write_file" || call.name == "edit_file"))
                        if (auto p = "path" in call.arguments)
                            if (p.type == JSONType.string)
                            {
                                import std.file : getcwd;
                                instructions.ifSome((ProjectInstructions pi) {
                                    if (auto nested = pi.nestedFor(p.str, getcwd())) result ~= nested;
                                });
                            }
                    // Memory recall (Rust #167): a note for each memory whose
                    // anchors appear in this call's arguments and whose full
                    // text is not already in context. Only calls that ran.
                    if (dispatched)
                        foreach (note; recallMemories(call.name, effectiveArgs, !isError, result))
                            result ~= "\n\n" ~ wrap(note);
                    if (hist.isHistoryTool(call.name)) historyHintPending = false;
                    else if (historyHintPending && historyEnabled && hist.looksFailed(call.name, !isError, result))
                    {
                        historyHintPending = false;
                        result ~= "\n\n" ~ hist.failedToolHint;
                    }
                    if (remindersEnabled) result ~= remind(call, !isError, result, loopStop);
                }
                ev.toolEnd(call, toolResultDisplay(result, attachments), isError);
                auto msg = Message.toolResult(call.id, call.name, result, isError);
                msg.attachments = attachments;
                // Commit this call's recall changes only once the result
                // carrying their notes is durable: a failed append rolls them
                // back, so a resume never treats unseen notes as seen.
                try push(msg);
                catch (Exception e)
                {
                    recallState = recallBefore;
                    recallTurnNotes = notesBefore;
                    throw e;
                }
                if (recallState != recallBefore) recallChanged();
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
                if (stopBlocks < maxStopBlocks && !control.isCancelled && iteration < budget)
                {
                    // Not `foreach (h; hooks)`: the `continue` below is for the turn loop.
                    auto o = hooks.match!(h => h.runStop(stopBlocks > 0), () => HookOutcome.init);
                    if (o.blocked)
                    {
                        stopBlocks++;
                        hasReported = false;
                        auto reason = o.blockReason.strip.length ? o.blockReason : "A Stop hook asked the agent to keep going.";
                        push(Message.auto_(wrapReminder(reason)));
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
        if ((planTools && isPlanTool(call.name)) || (outcomeTool && call.name == outcomeToolName)
            || (timerTools && isTimerTool(call.name)))
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
        else if (capabilities.window) { w = capabilities.window; source = "reported by the endpoint (" ~ capabilities.windowSource ~ ")"; }
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
        if (calibrated) return calibTokens + ctx.messagesTokens(messages[calibLen .. $], imageSlots);
        size_t tools_;
        foreach (d; offeredTools())
            tools_ += ctx.textTokens(d.name) + ctx.textTokens(d.description) + ctx.textTokens(() { return d.parameters.toString; }());
        return ctx.messagesTokens(messages, imageSlots) + tools_;
    }

    size_t estimateContextTokens() { bool _; return estimateContextTokens(_); }

    private size_t outputBase() const { return cast(size_t) effectiveMaxTokens(); }

    /// The output budget before the context-window clamp: `max_tokens` when
    /// configured, else the model's published cap, a known cap for the model
    /// name, or the large default; never above a cap learned from an error.
    long effectiveMaxTokens() const
    {
        long base = maxTokens > 0 ? maxTokens
            : capabilities.maxOutput ? cast(long) capabilities.maxOutput
            : ctx.outputLimitForModel(client.modelName) ? cast(long) ctx.outputLimitForModel(client.modelName)
            : ctx.defaultMaxOutputTokens;
        return learnedMaxOutput > 0 && learnedMaxOutput < base ? learnedMaxOutput : base;
    }

    /// The endpoint's prompt-only cap is in force (Copilot `max_prompt_tokens`).
    private bool promptCapped() const
    {
        return !configuredWindow && capabilities.promptCap && capabilities.window
            && (!learnedWindow || learnedWindow >= capabilities.window);
    }

    /// The combined prompt + output window to enforce alongside a prompt cap (0 = none).
    private size_t combinedWindow() const
    {
        auto a = capabilities.totalWindow;
        if (a && learnedWindow) return a < learnedWindow ? a : learnedWindow;
        return a ? a : learnedWindow;
    }

    /// Past the auto-compaction threshold (or too close to the window for the
    /// output reservation)?
    bool overThreshold() { return overThresholdAt(estimateContextTokens()); }

    /// Run the auto-compaction at the idle prompt instead of on the critical
    /// path of the next message (Rust #186). Off with `auto_compact`.
    bool idleCompact = true;
    IdleCompactGate idleGate;
    private struct IdleKey { size_t len, calibLen, calibTokens, images; AgentMode mode; bool history; }
    private IdleKey idleKey;
    private size_t idleTokens;
    private bool idleCached;

    /// Whether an idle compaction is due: idle and auto compaction are on, the
    /// context is past the threshold (with the floor's hysteresis, and never
    /// below the configured fraction itself), and the gate is armed. The
    /// caller owns the *idle* half (prompt quiet, no fresh draft).
    bool idleCompactDue() { return idleCompact && autoCompact && idleCompactDueAt(estimateContextTokens()); }

    /// `idleCompactDue` for the prompt's periodic poll, memoized on what
    /// changes the estimate in memory; `runIdleCompaction` re-checks fresh.
    bool idleCompactDuePolled()
    {
        if (!idleCompact || !autoCompact) return false;
        auto key = IdleKey(messages.length, calibLen, calibTokens, imageSlots, control.mode, historyAvailable);
        if (!idleCached || key != idleKey)
        {
            idleTokens = estimateContextTokens();
            idleKey = key;
            idleCached = true;
        }
        return idleCompactDueAt(idleTokens);
    }

    /// Forget the poll's memoized estimate (a different conversation).
    void resetIdleCompaction()
    {
        idleGate.reset();
        idleCached = false;
    }

    private bool idleCompactDueAt(size_t tokens)
    {
        if (!idleCompact || !overThresholdAt(tokens)) return false;
        auto window = contextWindow();
        auto threshold = clamp(autoCompactThreshold, 0.1, 0.99);
        if (tokens < window * threshold) return false;
        return idleGate.armed(tokens, window);
    }

    /// Run the compaction auto-compaction would, at the idle prompt.
    /// Cancellable like a turn; an attempt that did not compact spends the
    /// gate for this crossing so it is not retried in a loop.
    bool runIdleCompaction(out IdleCompactReport report)
    {
        control.startTurn();
        auto atEntry = estimateContextTokens();
        // A `/model` left pending changes the window: apply it first and
        // look again on the next poll.
        if (auto spec = control.takeModelRequest())
        {
            if (onModelRequest !is null) onModelRequest(spec);
            idleGate.spend(atEntry);
            return false;
        }
        auto before = estimateContextTokens();
        if (!idleCompact || !autoCompact || !idleCompactDueAt(before)) return false;
        auto window = contextWindow();
        CompactReport rep;
        bool done;
        scope (exit) if (!done || control.isCancelled) idleGate.spend(before);
        done = compact(rep, CompactTrigger.idle);
        if (!done || control.isCancelled) return false;
        report = IdleCompactReport(rep, window);
        return true;
    }

    /// `overThreshold` for an already-estimated context size.
    bool overThresholdAt(size_t tokens)
    {
        if (!autoCompact) return false;
        auto threshold = autoCompactThreshold < 0.1 ? 0.1 : autoCompactThreshold > 0.99 ? 0.99 : autoCompactThreshold;
        auto window = contextWindow();
        auto reserved = (outputBase < ctx.minOutputReserve ? outputBase : ctx.minOutputReserve) + ctx.outputMargin(window);
        double limit = window * threshold;
        auto headroom = saturatingSub(window, reserved);
        if (headroom && headroom < limit) limit = headroom;
        return tokens > limit && tokens > compactFloor + window / 10;
    }

    /// `max_tokens` for the next request: the configured value lowered so the
    /// prompt plus output fits the window. 0 (unset) stays unset.
    /// An output cap learned from a provider error (0 = none); /model resets it.
    long learnedMaxOutput;

    private const(ProviderConfig)* providerEntry()
    {
        auto pc = providerLookup is null ? null : providerLookup(client.providerName);
        return pc is null ? &noProvider : pc;
    }

    private ProviderKind providerKind()
    {
        auto pc = providerEntry();
        return pc.hasKind ? pc.kind : ProviderKind.openai;
    }

    /// Ask the endpoint what the current model supports (after a model change).
    void refreshCapabilities()
    {
        capabilities = Capabilities.init;
        if (auto probe = cast(CapabilityProbe) client) capabilities = probe.probeCapabilities();
    }

    /// The thinking level the current model is sent, and why. A fixed budget
    /// must stay below the output cap: one that can't fit sends no level.
    ThinkingResolved thinking()
    {
        Thinking st;
        if (!sessionThinking.isNull) st = sessionThinking.get;
        Reported rep;
        if (!capabilities.thinking.isNull) rep = capabilities.thinking.get;
        auto r = resolveThinking(globalThinking, sessionThinking.isNull ? null : &st, providerKind,
            *providerEntry, client.modelName, capabilities.thinking.isNull ? null : &rep);
        auto req = r.request();
        if (req.kind == Request.Kind.budget)
        {
            auto maxTok = requestMaxTokens();
            if (maxTok <= 0) maxTok = 32_000;
            auto sent = cappedBudget(req.budget, maxTok);
            string extra;
            if (sent == 0)
            {
                r.effective = Thinking.init;
                extra = format("max_tokens %s leaves no room for a thinking budget; thinking stays off", maxTok);
            }
            else if (sent < req.budget)
                extra = format("max_tokens %s caps the %s thinking budget at %s of %s tokens; raise max_tokens for the full budget",
                    maxTok, r.effective, sent, req.budget);
            if (extra.length) r.warning = r.warning.length ? r.warning ~ "\n" ~ extra : extra;
        }
        return r;
    }

    /// The temperature for a request whose Anthropic thinking state is `on`.
    temp.Resolved temperatureFor(bool on)
    {
        auto r = temp.resolve(temperature, providerKind, *providerEntry, client.modelName);
        return on ? r.fixedBy("thinking is on, and Anthropic then requires the default temperature") : r;
    }

    /// The temperature the current model is sent, and why.
    temp.Resolved temperatureNow() { return temperatureFor(thinking().anthropicThinkingOn); }

    /// Whether (and how) the current model can view images.
    Nullable!Vision vision()
    {
        Vision v;
        if (!capabilities.vision.isNull) v = capabilities.vision.get;
        return resolveVision(globalVision, providerKind, *providerEntry, client.modelName,
            capabilities.vision.isNull ? null : &v);
    }

    /// How many images a request may carry (0 without vision).
    private size_t imageSlots()
    {
        auto v = vision();
        return v.isNull ? 0 : v.get.maxImages;
    }

    /// Records an image read so a later write to it passes the freshness
    /// check (set by the host to the file tools' read state).
    void delegate(string path, const(ubyte)[] bytes) markRead;

    /// Where this session's images are stored: beside a persisted log (so
    /// its references stay valid), else a process-local temp dir.
    string attachmentsDir()
    {
        import std.path : buildPath, dirName;
        import std.file : tempDir;
        import std.process : thisProcessID;
        string dir = log.match!(l => l.path.length ? buildPath(dirName(l.path), l.id ~ ".attachments") : null, () => string.init);
        if (dir.length) return dir;
        return buildPath(tempDir, format("nano-coder-attachments-%s", thisProcessID));
    }

    /// Turn a `read_file` image result (`{"image": {...}}`, metadata only)
    /// into the tool-result text plus its attachment: re-read the file, fit
    /// it to the model's limits and store it. Without vision, or when the
    /// image can't be prepared, the result becomes a tool error. A non-image
    /// binary file gets a hint about the model's image capability.
    private string imageResult(string result, ref bool isError, ref Attachment[] attachments)
    {
        import nano.safeio : jsonGet, readImmutableBytes;
        import std.algorithm : startsWith, canFind;
        import nano.attachment : sniff, prepare, sha256Hex, store, mediaType, extension;
        import std.file : read;
        if (isError)
        {
            if (result.canFind("looks like a binary file"))
                result ~= vision().isNull
                    ? " (the current model can't view images; switch to a vision model or set `vision = true`)"
                    : " (the current model can view images, but this is not a supported image type: PNG, JPEG, GIF or WebP)";
            return result;
        }
        if (!result.startsWith(`{"image":`)) return result;
        JSONValue image;
        try image = parseJSON(result)["image"];
        catch (Exception) return result; // not image JSON after all: pass the text through unchanged
        string str(string k) { auto p = jsonGet(image, k); return p && p.type == JSONType.string ? p.str : ""; }
        auto path = str("path");
        auto v = vision();
        isError = true;
        if (v.isNull)
            return format("%s is an image (%s), but the current model can't view images; "
                ~ "switch to a vision model or set `vision = true`", path, str("media_type").length ? str("media_type") : "unknown type");
        if (!path.length) return "image result had no path";
        immutable(ubyte)[] bytes;
        try bytes = readImmutableBytes(path);
        catch (Exception e) return format("%s: could not read image: %s", path, e.msg);
        auto fmt = sniff(bytes);
        if (fmt.isNull) return format("%s: unrecognised image data", path);
        auto limits = v.get.imageLimits;
        Attachment a;
        try
        {
            auto p = prepare(bytes, fmt.get, limits);
            a = Attachment(p.mediaType, path, sha256Hex(p.bytes), p.width, p.height, p.bytes.length, p.extension);
            try store(attachmentsDir(), a, p.bytes);
            catch (Exception e) return format("%s: could not store image: %s", path, e.msg);
        }
        catch (Exception e) return format("%s: could not process image: %s", path, e.msg);
        if (markRead !is null) markRead(path, bytes);
        isError = false;
        attachments = [a];
        return format("%s, %s×%s, %s", a.mediaType, a.width, a.height, ctx.formatBytes(a.bytes));
    }

    private long requestMaxTokens()
    {
        auto maxTokens = effectiveMaxTokens();
        if (maxTokens < 1) maxTokens = 1;
        if (promptCapped)
        {
            auto combined = combinedWindow();
            if (!combined) return maxTokens;
            auto usedC = estimateContextTokens() + ctx.outputMargin(combined);
            long roomC = cast(long) saturatingSub(combined, usedC);
            auto c = maxTokens < roomC ? maxTokens : roomC;
            return c < 1 ? 1 : c;
        }
        auto window = contextWindow();
        auto used = estimateContextTokens() + ctx.outputMargin(window);
        long room = cast(long) saturatingSub(window, used);
        auto n = maxTokens < room ? maxTokens : room;
        return n < 1 ? 1 : n;
    }

    /// Summarize older messages into one, keeping recent messages verbatim.
    /// `mode` overrides `compactionMode` (null: the configured one); `focus`
    /// steers the summary. Returns false when there is nothing to compact.
    bool compact(out CompactReport report, CompactTrigger trigger = CompactTrigger.manual,
            const(ctx.CompactionMode)* mode = null, string focus = null)
    {
        import std.algorithm : canFind;
        ctx.CompactionMode m = mode is null ? compactionMode : *mode;
        // Smart compaction points into the session log; without one it is standard.
        if (log.isNone) m = ctx.CompactionMode.standard;
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
            if (ctx.messagesTokens(messages[b .. $], imageSlots) > keepBudget) break;
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
            auto inputWindow = saturatingSub(window, budget);
            auto chars = checkedMul(max(saturatingSub(inputWindow, 2_000), 2_000), 3);
            auto request = "Conversation to summarize:\n\n" ~ ctx.renderTranscript(summarized, chars, smart);
            if (focus.strip.length) request ~= "\n\nWhen summarizing, focus on: " ~ focus.strip;
            ChatRequest req;
            auto system = ctx.summarySystemPrompt ~ (smart ? ctx.smartSummaryInstructions : "");
            // A repeated compaction folds the previous summary back in: warn
            // that it is lossy (issue #66).
            if (summarized.canFind!((ref m) => ctx.isSummaryMessage(m)))
                system ~= compactionPinRequests ? ctx.earlierSummaryLossyInstructions : ctx.earlierSummaryLossyNoPinInstructions;
            req.messages = [Message.system(system), Message.user(request)];
            req.maxTokens = budget;
            // No thinking field: only a model that thinks anyway locks the temperature.
            req.temperature = temperatureFor(thinking().alwaysAnthropicThinking).effective;
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
        // Pin the user's own words, rebuilt from the originals every time.
        if (compactionPinRequests)
            if (auto pinned = ctx.pinnedUserRequests(pinStash, summarized, smart, window))
                summary ~= "\n\n" ~ pinned;
        foreach (ref x; summarized)
            if (ctx.isUserRequest(x)) pinStash ~= x;

        Message[] next = messages[0 .. bodyStart].dup;
        next ~= Message.user(summary);
        next[$ - 1].timestamp = nowStamp();
        // An in-flight input folded into the summary is restated after it.
        size_t pendingPos;
        if (hasPending)
        {
            if (pending.position < split)
            {
                next ~= Message.user(pending.text);
                pendingPos = next.length - 1;
            }
            else pendingPos = checkedSub(pending.position, split) + next.length;
        }
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
        if (hasPending)
        {
            pending.position = pendingPos;
            pending.hasBase = true;
            pending.base = messages.length;
        }
        log.ifSome((SessionLog l) {
            l.replace(messages, first, last, ctx.modeName(m), client.providerName ~ "/" ~ client.modelName, pinStash,
                hasPending ? &pending : null);
        });
        // The replacement drops recalled notes' full text from context, so
        // every memory may be recalled again (except those the retained
        // system message's index renders in full: `indexShown` is kept).
        if (!recallState.empty)
        {
            recallState = mem.Recall.init;
            recallChanged();
        }
        report = CompactReport(len, messages.length, tokensBefore, estimateContextTokens(), checkedSub(split, bodyStart),
            fallback, truncated, m);
        // Nested instructions attached to folded tool results may be gone.
        instructions.ifSome((ProjectInstructions pi) { pi.forgetNested(); });
        compactFloor = report.tokensAfter;
        idleGate.reset();
        compactions++;
        historyAvailable = historyHintPending = m == ctx.CompactionMode.smart;
        if (onCompacted !is null) onCompacted(report);
        return true;
    }

    private void recordUsage(TokenUsage u)
    {
        sessionInputTokens += u.inputTokens;
        sessionOutputTokens += u.outputTokens;
        if (u.hasAic)
        {
            hasSessionAic = true;
            sessionAic += u.aic;
        }
    }

    /// Zero the per-session totals (tokens, credits, compactions), as a new
    /// or resumed session starts counting from scratch.
    void resetSessionCounters()
    {
        sessionInputTokens = sessionOutputTokens = 0;
        hasSessionAic = false;
        sessionAic = 0;
        compactions = 0;
    }

    private string cancelled(AgentEvents ev)
    {
        ev.text(false, "\n" ~ cancelledResponse);
        lastStop = StopReason.cancelled;
        return cancelledResponse;
    }

    private string runTool(const ref ToolCall call, string stopReason, out bool isError)
    {
        bool _;
        JSONValue _a;
        return runTool(call, stopReason, isError, _, _a);
    }

    /// `dispatched`: the call reached its handler (not refused as invalid,
    /// unknown, plan-mode, permission- or hook-denied); `effectiveArgs` are
    /// the arguments it ran with (after any hook rewrite).
    private string runTool(const ref ToolCall call, string stopReason, out bool isError, out bool dispatched,
        out JSONValue effectiveArgs)
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
        bool isTimer = timerTools && isTimerTool(call.name);
        if (!isPlan && !isOutcome && !isHistory && !isTimer && !tools.has(call.name))
            return format("Tool '%s' not found. Available: %s", call.name, toolNames());
        // Backstop for a call already in flight when plan mode was switched on.
        if (control.mode == AgentMode.plan && !planAllows(call.name))
            return format("%s is disabled in plan mode (read-only)", call.name);
        // An unverifiable shell loop never prompts: the policy allows it
        // under the OS sandbox and blocks it without one (Rust #171).
        auto permissionDeny = policy.decide(call.name, call.arguments).match!(
            (PermAllow _) => cast(string) null,
            (PermDeny d) => d.message,
        );
        if (permissionDeny !is null) return permissionDeny;
        // PreToolUse hooks run after the permission check, before the tool:
        // they can deny the call, rewrite its input, or add context.
        JSONValue args = call.arguments;
        string[] context;
        foreach (h; hooks)
        {
            auto o = h.runPreToolUse(call.name, call.arguments, call.id);
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
        dispatched = true;
        effectiveArgs = args;
        string out_;
        try
        {
            if (isOutcome)
            {
                auto o = Outcome.fromArgs(args);
                // Verify-before-complete (Rust #158): `completed` after an
                // edit with no later bash check is bounced once per turn.
                if (verifyBeforeComplete && o.status == OutcomeStatus.completed && editsSinceCheck && !verifyReminderFired)
                {
                    verifyReminderFired = true;
                    throw new OutcomeError(verifyReminder);
                }
                out_ = format("Recorded outcome: %s. Your turn ends now.", o.toJSON["status"].str);
                reported = o;
                hasReported = true;
            }
            else if (isHistory)
            {
                // History tools are offered only when historyEnabled(), which needs a log.
                auto logPath = log.unwrap("history tools are offered only with a session log").path;
                out_ = call.name == hist.searchTool ? hist.search(logPath, args) : hist.read(logPath, args);
            }
            else if (isTimer) out_ = runTimerTool(call.name, args);
            else out_ = isPlan ? runPlanTool(call.name, args) : tools.execute(call.name, args);
            isError = false;
        }
        catch (ToolError e) out_ = e.msg;
        catch (PlanError e) out_ = e.msg;
        catch (TimerError e) out_ = e.msg;
        catch (hist.HistoryError e) out_ = e.msg;
        catch (OutcomeError e) out_ = e.msg;
        catch (QuestionError e) out_ = e.msg;
        catch (Exception e) out_ = format("%s failed: %s", call.name, e.msg);
        foreach (h; hooks)
        {
            auto o = h.runPostToolUse(call.name, args, out_, call.id);
            if (auto ctx = o.contextBlock) context ~= ctx;
            if (o.blocked && o.blockReason.strip.length) context ~= o.blockReason;
        }
        return withContext(out_, context);
    }

    /// Instruction files: nested ones attach to file-tool results.
    Option!ProjectInstructions instructions;
    /// A smart summary is in context: offer history_search/history_read.
    bool historyAvailable;
    /// Append the "look in history" hint to the next failed tool result.
    bool historyHintPending;
    bool historyEnabled() const { return log.isSome && historyAvailable; }

    /// Start a fresh session in place (Rust `new_session`, for `/restart`):
    /// the conversation is just `system`, logged to `newLog` (none: not
    /// persisted); mode, session thinking, plan, timers, reminders, hook session,
    /// calibration, history tools and counters are reset. The old log stays.
    void restart(string system, Option!SessionLog newLog)
    {
        import nano.mode : AgentMode;
        messages = [Message.system(system)];
        log = newLog;
        log.ifSome((SessionLog l) { l.append(messages[0]); });
        control.mode = AgentMode.normal;
        sessionThinking.nullify();
        plan = Plan.init;
        setTimers(Timers.init);
        reminders = Reminders.init;
        sessionStarted = false;
        pendingStartContext = null;
        resumed = false;
        stopBlocks = 0;
        calibLen = calibTokens = 0;
        compactFloor = 0;
        resetIdleCompaction();
        pinStash = null;
        hasPending = false;
        historyAvailable = historyHintPending = false;
        recallState = mem.Recall.init;
        recallTurnNotes = 0;
        resetSessionCounters();
        lastUsage = TokenUsage.init;
        hasOutcome = hasReported = false;
    }

    /// The memory store (null: memory off). Recall from tool calls reads it.
    Option!(mem.Store) memory;
    /// Memory recall from tool calls (Rust #167): which memories' full text
    /// is already in this context. Persisted in `recall` records; reset by
    /// compaction and a new session.
    mem.Recall recallState;
    /// Recall notes attached so far for the current input.
    size_t recallTurnNotes;
    /// Ids the memory index in the installed system message renders in full:
    /// recall treats them as in context. Derived, never persisted; replaced
    /// whenever the app installs a system prompt (`installSystem`).
    bool[string] indexShown;

    /// Install `system` as the system message, with the ids its memory index
    /// renders in full.
    void installSystem(string system, bool[string] shown)
    {
        if (messages.length && messages[0].role == Role.system) messages[0].content = system;
        indexShown = shown;
    }

    /// Restore recall state from a session log (null: none recorded). The
    /// installed system message (and so `indexShown`) is kept.
    void restoreRecall(JSONValue j)
    {
        recallState = mem.Recall.fromJSON(j);
        recallTurnNotes = 0;
    }

    /// Persist the recall state. Best-effort: a failed append only means a
    /// resumed session may repeat a note.
    private void recallChanged()
    {
        log.ifSome((SessionLog l) {
            try l.recall(recallState.toJSON);
            catch (Exception e) stdErr.writeln("[agent] could not persist memory recall state: ", e.msg);
        });
    }

    /// Recall memories whose anchors appear in this dispatched call; returns
    /// the note texts to attach. A memory tool's output instead marks what it
    /// showed as seen (and logs a `used` event for a fired id).
    private string[] recallMemories(string tool, const JSONValue args, bool ok, string result)
    {
        foreach (store; memory) return recallMemories(store, tool, args, ok, result);
        return null;
    }

    private string[] recallMemories(mem.Store memory, string tool, const JSONValue args, bool ok, string result)
    {
        string session = log.match!(l => l.id, () => string.init);
        if (mem.isMemoryTool(tool))
        {
            if (ok)
                foreach (id; recallState.noteSeenIn(result)) mem.logRecall(memory, "used", id, tool, session);
            return null;
        }
        auto budget = saturatingSub(mem.recallNotesPerTurn, recallTurnNotes);
        auto notes = mem.recall(memory, tool, args, recallState, indexShown, budget);
        string[] texts;
        foreach (n; notes)
        {
            mem.logRecall(memory, "fired", n.id, tool, session);
            texts ~= n.text;
        }
        recallTurnNotes += notes.length;
        if (hasPending) pending.recallNotes = recallTurnNotes;
        return texts;
    }

    /// Offer `report_outcome` (config `outcome_tool`).
    bool outcomeTool = true;
    /// Ask once per turn for a check before accepting `report_outcome(completed)`
    /// after unchecked edits (Rust #158). The ACP server turns it off: the
    /// orchestrator verifies there.
    bool verifyBeforeComplete = true;
    private bool editsSinceCheck, verifyReminderFired;
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
            ~ (outcomeTool ? [outcomeDefinition()] : null) ~ (historyEnabled ? hist.definitions() : null)
            ~ (timerTools ? timerDefinitions() : null);
        if (control.mode != AgentMode.plan) return all;
        ToolDefinition[] kept;
        foreach (t; all) if (planAllows(t.name)) kept ~= t;
        return kept;
    }

    private bool headless() { return !questions || !questions.interactive; }

    /// Interactive normal mode: ask whether to keep going past the cap.
    private bool askKeepGoing()
    {
        auto q = Question("Reached the turn cap without a final answer. Keep going?", null,
            [QuestionOption("No"), QuestionOption("Yes")]);
        q.custom = false;
        auto a = questions.ask([q]);
        return a.match!(
            (Answered got) => got.answers.length && got.answers[0] == "Yes",
            _ => false,
        );
    }

    /// The task plan (`plan_*` tools), kept outside the conversation.
    Plan plan;
    /// Offer the plan tools (config `plan_tools`).
    bool planTools = true;
    /// Called after the plan changes (the UI shows the checklist).
    void delegate() onPlanChanged;
    /// A `/model SPEC` queued mid-turn, applied (on the agent thread) before the next model call.
    void delegate(string) onModelRequest;

    /// Timers the agent set for itself (`timer_*` tools).
    Timers timers;
    /// Offer the timer tools (off for ACP, which has no idle loop to fire them).
    bool timerTools = true;
    /// Called after the timers change (the UI updates the status bar).
    void delegate() onTimersChanged;
    /// The clock timers run on (unix seconds); tests replace it.
    long delegate() now;

    long timerNow()
    {
        import std.datetime.systime : Clock;
        return now !is null ? now() : Clock.currTime.toUnixTime;
    }

    private string runTimerTool(string name, JSONValue args)
    {
        auto o = timers.apply(name, args, timerNow());
        if (o.changed) timersChanged();
        return o.text;
    }

    private void timersChanged()
    {
        log.ifSome((SessionLog l) { l.timers(timers.toJSON); });
        if (onTimersChanged !is null) onTimersChanged();
    }

    /// Take the due timers and return the message they send, or null.
    /// The caller runs it as a turn (an idle prompt or `--wait-timers`).
    string takeFiredTimers(out string notice)
    {
        auto t = timerNow();
        auto due = timers.takeDue(t);
        if (!due.length) return null;
        timersChanged();
        notice = firedNotice(due);
        return firedMessage(due, t);
    }

    /// Mid-turn: due timers join the conversation before the next model call,
    /// and fired ones not yet marked done are restated every few steps.
    private void fireDueTimers(AgentEvents ev)
    {
        if (!timerTools) return;
        if (timers.anyDue(timerNow()))
        {
            string notice;
            auto text = takeFiredTimers(notice);
            auto tm = Message.auto_(wrapReminder(text));
            tm.timer = true;
            push(tm);
            ev.userMessage(notice);
            stepsSinceTimerNote = 0;
            return;
        }
        if (!timers.pending.length) { stepsSinceTimerNote = 0; return; }
        if (++stepsSinceTimerNote < pendingNudgeEvery) return;
        stepsSinceTimerNote = 0;
        auto nudge = Message.auto_(wrapReminder(pendingNudge(timers.pending, timerNow())));
        nudge.timer = true;
        push(nudge);
    }
    private size_t stepsSinceTimerNote;

    /// Replace the timers with ones restored from the session log.
    void setTimers(Timers t)
    {
        timers = t;
        if (onTimersChanged !is null) onTimersChanged();
    }

    private string runPlanTool(string name, JSONValue args)
    {
        auto o = plan.apply(name, args);
        if (o.changed) planChanged();
        return o.text;
    }

    private void planChanged()
    {
        reminders.planChanged();
        log.ifSome((SessionLog l) { l.plan(plan.toJSON); });
        if (onPlanChanged !is null) onPlanChanged();
    }

    /// Replace the plan with one carried over from an earlier run, telling
    /// the model about it unless `announce` is false.
    void setPlan(Plan p, bool announce)
    {
        plan = p;
        if (announce && planTools && !plan.empty) push(Message.user(plan.carriedOverNote));
        log.ifSome((SessionLog l) { l.plan(plan.toJSON); });
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
        hooks = some(h);
        this.resumed = resumed;
        sessionStarted = false;
        pendingStartContext = null;
        if (!h.files.length) return;
        import nano.claude_hooks : label;
        string[3][] files;
        foreach (f; h.files) files ~= [f.path, f.source.label, f.hash];
        log.ifSome((SessionLog l) { l.hooks(files); });
    }

    private void syncHookSession(HookManager h)
    {
        h.setSession(log.match!(l => l.id, () => ""), log.match!(l => l.path, () => ""),
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

// rust: agent.rs::malformed_tool_call_skips_handler_and_reports_actionable_error
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

// rust: agent.rs::steer_during_tool_call_joins_next_model_call
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
// rust: agent.rs::steer_during_tool_call_joins_next_model_call
// rust: agent.rs::steer_during_final_answer_extends_the_turn
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
// rust: agent.rs::steer_during_final_answer_extends_the_turn
// rust: agent.rs::cancel_kills_running_bash_and_skips_remaining_calls
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
// rust: agent.rs::reporting_an_outcome_ends_the_turn_and_is_recorded
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
    agent.hooks = some(new HookManager([hook(Event.sessionStart, "echo started"),
        hook(Event.userPromptSubmit, `grep -q forbidden && { echo no secrets >&2; exit 2; }; echo ctx`)], tempDir));
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
    agent.hooks = some(new HookManager([
        hook(Event.preToolUse, `echo '{"decision":"block"}' >/dev/null; echo nope >&2; exit 2`, "echo"),
        hook(Event.preToolUse, `grep -q '"ls"' && echo '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"echo patched"}}}' || echo '{"hookSpecificOutput":{"updatedInput":{"command":"sudo rm -rf /"}}}'`, "Bash"),
        hook(Event.postToolUse, `echo '{"hookSpecificOutput":{"additionalContext":"post-note"}}'`, "Bash"),
    ], tempDir));
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
    agent.hooks = some(new HookManager([hook(Event.stop, `echo '{"decision":"block","reason":"more"}'`)], tempDir));
    assert(agent.run("go", new NullEvents) == "d");
    assert(mock.seen.length == 4 && mock.seen[1][$ - 1].content.canFind("more"));
}

// Rust #171: an unverifiable shell loop never prompts. Without the OS sandbox
// it is blocked (interactive or not), it is rejected in plan mode, and a
// literal-list loop whose unrolled commands are allowed just runs. Each run is
// interactive with no answerer, so a raised question would hang the test.
// rust: agent.rs::an_unverifiable_loop_is_blocked_without_asking_when_unsandboxed
// rust: agent.rs::an_unverifiable_loop_in_plan_mode_is_rejected_without_prompting
// rust: agent.rs::a_literal_list_loop_runs_without_asking
unittest
{
    enum loop = `{"command":"for f in $(git ls-files); do sed -i s/x/y/ \"$f\"; done"}`;
    string[] ran;
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("bash", "", parseJSON(`{}`)), (JSONValue a) { ran ~= a["command"].str; return "ok"; });
    string runCall(string args, bool plan = false)
    {
        auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("b1", "bash", args)]), LLMResponse("done")]);
        auto agent = new Agent(mock, reg, Policy.init, null);
        agent.questions = QuestionBroker.make;
        agent.questions.interactive = true;
        if (plan) agent.control.mode = AgentMode.plan;
        agent.run("run it", new NullEvents);
        assert(agent.questions.pending() is null);
        return mock.seen[1][$ - 1].content;
    }
    import std.algorithm : canFind;
    auto text = runCall(loop);
    assert(text.canFind("Blocked by nano-coder permissions") && text.canFind("not a known read-only command"), text);
    assert(!ran.length);
    text = runCall(loop, true);
    assert(text.canFind("plan mode") || text.canFind("read-only"), text);
    assert(!ran.length);
    assert(runCall(`{"command":"for f in a.txt b.txt; do wc -l \"$f\"; done"}`) == "ok");
}

// Verify-before-complete (Rust #158): `completed` after an unchecked edit is
// bounced once per turn; a bash check clears it; a never-run bash doesn't;
// blocked/needs_input pass; the flag turns it off.
// rust: agent.rs::completed_after_an_unverified_edit_is_reminded_once_then_goes_through
// rust: agent.rs::completed_after_an_edit_and_a_check_is_not_reminded
// rust: agent.rs::completed_after_an_edit_and_a_rejected_bash_is_still_reminded
// rust: agent.rs::completed_after_an_edit_and_an_invalid_real_bash_is_still_reminded
// rust: agent.rs::blocked_and_needs_input_are_never_intercepted
// rust: agent.rs::verify_before_complete_can_be_turned_off
unittest
{
    import nano.providers.mock;
    import nano.tools.bash : bashDefinition = definition, bashExecute = execute;
    import std.algorithm : canFind, startsWith;
    ToolRegistry registry(bool realBash = false)
    {
        auto reg = new ToolRegistry;
        foreach (n; ["write_file", "edit_file"])
            reg.register(ToolDefinition(n, n, parseJSON(`{"type":"object"}`)), (JSONValue a) => "written");
        if (realBash) reg.register(bashDefinition(), (JSONValue a) => bashExecute(a));
        else reg.register(ToolDefinition("bash", "bash", parseJSON(`{"type":"object"}`)), (JSONValue a) => "ok");
        return reg;
    }
    string toolText(Agent a, string id)
    {
        foreach (m; a.messages) if (m.role == Role.tool && m.toolCallId == id) return m.content;
        assert(0, "no tool result for " ~ id);
    }
    auto edit = ToolCall.fromRaw("e1", "edit_file", `{"path":"a.rs"}`);
    auto done = (string id, string summary = "done") => ToolCall.fromRaw(id, "report_outcome",
        `{"status":"completed","summary":"` ~ summary ~ `"}`);
    auto ev = new NullEvents;
    // Reminded once, then the second report goes through.
    {
        auto mock = new MockClient([LLMResponse("", "", [edit]), LLMResponse("", "", [done("o1")]),
            LLMResponse("", "", [done("o2", "done, cargo test passes")])]);
        auto agent = new Agent(mock, registry(), Policy.init, "sys");
        assert(agent.run("ship it", ev) == "done, cargo test passes");
        assert(toolText(agent, "o1").canFind(verifyReminder));
        assert(agent.hasOutcome && agent.lastOutcome.status == OutcomeStatus.completed);
    }
    // A bash check clears the edit (no further responses: the turn ended).
    {
        auto mock = new MockClient([LLMResponse("", "", [edit, ToolCall.fromRaw("b1", "bash", `{"command":"cargo test"}`),
            done("o1", "done, cargo test passes")])]);
        auto agent = new Agent(mock, registry(), Policy.init, "sys");
        agent.run("ship it", ev);
        auto t = toolText(agent, "o1");
        assert(!t.canFind(verifyReminder) && t.canFind("Recorded outcome"), t);
    }
    // A malformed bash call, or one the real handler rejects, never ran: still reminded.
    foreach (args; [`{"command":"cargo te`, `{}`, `{"command":1}`, `{"command":"true","timeout_seconds":0}`])
    {
        auto mock = new MockClient([LLMResponse("", "", [edit, ToolCall.fromRaw("b1", "bash", args), done("o1")]),
            LLMResponse("", "", [done("o2")])]);
        auto agent = new Agent(mock, registry(args != `{"command":"cargo te`), Policy.init, "sys");
        agent.run("ship it", ev);
        assert(toolText(agent, "o1").canFind(verifyReminder), args);
    }
    // blocked / needs_input are never intercepted.
    foreach (st; [["blocked", "Blocked: "], ["needs_input", "Question: "]])
    {
        auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("e1", "write_file", `{"path":"a.rs"}`),
            ToolCall.fromRaw("o1", "report_outcome", `{"status":"` ~ st[0] ~ `","summary":"no token"}`)])]);
        auto agent = new Agent(mock, registry(), Policy.init, "sys");
        auto r = agent.run("ship it", ev);
        auto t = toolText(agent, "o1");
        assert(!t.canFind(verifyReminder) && t.canFind("Recorded outcome") && r.startsWith(st[1]), r);
    }
    // The flag turns it off.
    {
        auto mock = new MockClient([LLMResponse("", "", [edit, done("o1")])]);
        auto agent = new Agent(mock, registry(), Policy.init, "sys");
        agent.verifyBeforeComplete = false;
        agent.run("ship it", ev);
        assert(!toolText(agent, "o1").canFind(verifyReminder));
        assert(agent.hasOutcome && agent.lastOutcome.status == OutcomeStatus.completed);
    }
}

// report_outcome ends the turn with its summary as the answer.
// rust: agent.rs::plan_mode_keeps_read_only_tools
// rust: agent.rs::plan_mode_gates_mutating_tools
// rust: agent.rs::normal_mode_cap_stops_headless
// rust: agent.rs::a_headless_turn_with_no_cap_stops_at_the_safety_cap
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
// rust: agent.rs::a_hard_stop_skips_the_rest_of_the_batch
// rust: agent.rs::a_repeat_loop_ends_the_turn_blocked_after_the_warnings
// rust: agent.rs::identical_tool_calls_draw_a_loop_warning_on_the_third
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
// rust: agent.rs::prompt_only_window_does_not_shrink_max_tokens
// rust: agent.rs::an_unset_max_tokens_uses_a_known_model_cap_before_the_large_fallback
// rust: agent.rs::an_unset_max_tokens_falls_back_to_a_large_default_when_unpublished
// rust: agent.rs::an_unset_max_tokens_defaults_to_the_models_published_output_limit
// rust: agent.rs::an_output_limit_rejection_is_learned_and_retried
// rust: agent.rs::auto_compaction_mid_turn_keeps_the_turn_going
// rust: agent.rs::a_second_overflow_is_returned
// rust: agent.rs::context_overflow_compacts_and_retries_once
// rust: agent.rs::manual_compaction_summarizes_older_messages
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

// rust: agent.rs::compaction_pins_the_users_requests_across_a_second_compaction
unittest
{
    import std.algorithm : canFind, find;
    import nano.providers.mock;
    auto mock = new MockClient([LLMResponse("working on the lease"), LLMResponse("more work"),
        LLMResponse("SUMMARY ONE: the user mentioned a port"), LLMResponse("even more work"),
        LLMResponse("SUMMARY TWO: something about a lease and a port")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    agent.run("Fix the lease renewal race. Run the dev server on port 8123, never 5173.", new NullEvents);
    agent.run("Now add a regression test.", new NullEvents);
    CompactReport rep;
    assert(agent.compact(rep));
    agent.run("Also update the docs.", new NullEvents);
    assert(agent.compact(rep));
    auto summary = agent.messages.find!((ref m) => ctx.isSummaryMessage(m))[0].content;
    assert(summary.canFind(ctx.pinnedRequestsPrefix), summary);
    assert(summary.canFind("Run the dev server on port 8123, never 5173."), summary);
    assert(summary.canFind("Now add a regression test.") && summary.canFind("Also update the docs."), summary);
    assert(!summary.canFind("SUMMARY ONE\n\n["), summary);
}

// rust: agent.rs::a_repeated_compaction_warns_the_summariser_the_earlier_summary_is_lossy
// rust: agent.rs::a_repeated_compaction_without_the_pin_tells_the_summariser_to_preserve_requirements
unittest
{
    import std.algorithm : canFind;
    import nano.providers.mock;
    foreach (pin; [true, false])
    {
        auto mock = new MockClient([LLMResponse("work"), LLMResponse("SUMMARY ONE"), LLMResponse("more"),
            LLMResponse("SUMMARY TWO")]);
        auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
        agent.compactionPinRequests = pin;
        agent.run("first request", new NullEvents);
        CompactReport rep;
        assert(agent.compact(rep));
        assert(!mock.seen[$ - 1][0].content.canFind("lossy"), "a first compaction has no earlier summary");
        agent.run("second request", new NullEvents);
        assert(agent.compact(rep));
        auto system = mock.seen[$ - 1][0].content;
        assert(system.canFind("lossy"), system);
        assert(system.canFind("Do not restate the user's goals") == pin, system);
        assert(system.canFind("Preserve every goal, requirement") == !pin, system);
        assert(system.canFind("pinned verbatim alongside your summary") == pin, system);
        assert(agent.messages[1].content.canFind(ctx.pinnedRequestsPrefix) == pin);
    }
}

// Automatic turns are flagged at their origin; hook context appended to a
// prompt leaves the user's text in `pinText`.
unittest
{
    import nano.providers.mock;
    auto agent = new Agent(new MockClient([LLMResponse("ok"), LLMResponse("ok")]), new ToolRegistry, Policy.init, "sys");
    agent.run("plain prompt", new NullEvents);
    assert(!agent.messages[1].autoInitiated && agent.messages[1].pinText is null);
    // A fired timer's turn is harness-initiated; the flag is one-shot.
    agent.automaticInput = true;
    agent.run("timer fired", new NullEvents);
    assert(agent.messages[3].content == "timer fired" && agent.messages[3].autoInitiated && !agent.automaticInput);
    assert(Message.auto_("x").autoInitiated && !ctx.isUserRequest(Message.auto_("x")));
    // A reset (new session or /clear) drops the stash.
    agent.pinStash = [Message.user("old")];
    agent.restart("sys", Option!SessionLog.init);
    assert(agent.pinStash is null);
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
    assert(agent.messages.length == 3 && agent.messages[1].content
        == ctx.summaryPrefix ~ "\nSUM\n\n" ~ ctx.pinnedRequestsPrefix ~ "\nu1\nu2", agent.messages[1].content);
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
    b.compactionPinRequests = false; // the threshold floor, not the pin, is under test
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
    c.compactionPinRequests = false;
    c.messages ~= [Message.user("x"), Message.assistant("y")];
    assert(c.run("go", new NullEvents) == "ok");
    assert(c.learnedWindow == 9_000 && c.contextWindow == 9_000 && over.seen.length == 3);
    // A second overflow in the same request is an error.
    over.script = [LLMResponse("!error:context length exceeded"), LLMResponse("SUM4"),
        LLMResponse("!error:context length exceeded")];
    bool threw;
    try c.run("again", new NullEvents);
    catch (Exception e) threw = true; // expected: the run must throw, which is what this test checks
    assert(threw);

    // An output-cap error lowers max_tokens and retries once.
    auto capped = new MockClient([LLMResponse("!error:max_tokens: 64000 > 32000, which is the maximum allowed"),
        LLMResponse("fine")]);
    auto d = new Agent(capped, new ToolRegistry, Policy.init, "sys");
    d.maxTokens = 64_000;
    d.configuredWindow = 1_000_000;
    assert(d.run("go", new NullEvents) == "fine" && d.learnedMaxOutput == 32_000);

    // Unset max_tokens: the published cap, else a known cap, else the large
    // default; a learned cap still clamps it (issue #114).
    auto e = new Agent(new MockClient([LLMResponse("x")]), new ToolRegistry, Policy.init, "sys");
    assert(e.effectiveMaxTokens == ctx.defaultMaxOutputTokens);
    e.capabilities.maxOutput = 7_000;
    assert(e.effectiveMaxTokens == 7_000);
    e.learnedMaxOutput = 5_000;
    assert(e.effectiveMaxTokens == 5_000);
    e.maxTokens = 3_000;
    assert(e.effectiveMaxTokens == 3_000);
    // A prompt-only cap leaves max_tokens alone unless the combined window binds.
    auto f = new Agent(new MockClient([LLMResponse("x")]), new ToolRegistry, Policy.init, "sys");
    f.capabilities.window = 100;
    f.capabilities.promptCap = true;
    assert(f.requestMaxTokens == ctx.defaultMaxOutputTokens);
    f.capabilities.totalWindow = 2_000;
    assert(f.requestMaxTokens < 2_000);
}

// rust: agent.rs::no_titles_unless_enabled
// rust: agent.rs::titles_sessions_once_a_prompt_says_something
// rust: agent.rs::read_file_image_errors_with_a_hint_when_the_model_cannot_see
// rust: agent.rs::read_file_attaches_an_image_for_a_vision_model
unittest
{
    // read_file on an image: attached for a vision model, an error otherwise.
    import nano.providers.mock : MockClient;
    import nano.tools.files : ReadState, registerFiles = register;
    import nano.attachment : fakePng, exists_ = exists;
    import std.file : tempDir, write, mkdirRecurse, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.algorithm : canFind;
    auto dir = buildPath(tempDir, format("nano-agent-img-%s", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto png = buildPath(dir, "shot.png");
    write(png, fakePng(20, 10));
    auto call = ToolCall.fromRaw("r1", "read_file", JSONValue(["path": png]).toString);
    Agent make(bool vision)
    {
        auto reg = new ToolRegistry;
        auto st = new ReadState;
        registerFiles(reg, st);
        auto agent = new Agent(new MockClient([LLMResponse("", "", [call]), LLMResponse("seen")]), reg, Policy.init, "sys");
        agent.globalVision = vision;
        agent.markRead = (string p, const(ubyte)[] b) { st.record(p, b); };
        return agent;
    }

    auto blind = make(false);
    blind.run("look", new NullEvents);
    auto t = blind.messages[$ - 2];
    assert(t.isError && t.content.canFind("can't view images") && !t.attachments.length, t.content);

    auto agent = make(true);
    scope (exit) if (exists(agent.attachmentsDir)) rmdirRecurse(agent.attachmentsDir);
    agent.run("look", new NullEvents);
    t = agent.messages[$ - 2];
    assert(!t.isError && t.content == "image/png, 20×10, 64 B" && t.attachments.length == 1, t.content);
    assert(exists_(agent.attachmentsDir, t.attachments[0]));

    // The wire plan sends the newest image; one past the quota is a placeholder.
    auto older = t;
    ChatRequest req;
    req.messages = [older, t];
    req.vision = agent.vision;
    req.attachmentsDir = agent.attachmentsDir;
    auto plan = req.attachmentPlan;
    auto first = req.resolveAttachments(0, plan), second = req.resolveAttachments(1, plan);
    assert(!first[0].isImage && first[0].text == "[image omitted: " ~ png ~ " (sent earlier)]");
    assert(second[0].isImage && second[0].image.mediaType == "image/png");
    req.attachmentsDir = buildPath(dir, "missing");
    auto gone = req.attachmentPlan;
    assert(req.resolveAttachments(1, gone)[0].text.canFind("no longer available"));
    assert(toolResultDisplay("x", t.attachments) == "x\n[image: " ~ png ~ ", 20×10]");
}

// Each turn updates the session index; with session_titles on, a telling
// prompt gets one background title request, stored cleaned in the index.
unittest
{
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import nano.session : SessionLog;
    import nano.session_index : list;
    import nano.providers.mock : MockClient;
    auto dir = buildPath(tempDir, "nano-d-agent-titles");
    if (dir.exists) rmdirRecurse(dir);
    auto agent = new Agent(new MockClient([LLMResponse("a"), LLMResponse("b"), LLMResponse("c")]), new ToolRegistry,
        Policy.init, null);
    agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    MockClient titler;
    string[] specs;
    agent.sessionTitles = true;
    agent.titleClient = (string spec) {
        specs ~= spec;
        titler = new MockClient([LLMResponse("Title: \"Fixing the deploy test.\"")]);
        return cast(LLMClient) titler;
    };
    auto ev = new NullEvents;
    agent.run("hi", ev); // terse: no title yet
    assert(agent.titleThreads.length == 0 && list(dir)[0].prompts == 1);
    agent.run("Fix the flaky deploy test in CI", ev);
    assert(agent.titleThreads.length == 1);
    agent.titleThreads[0].join();
    assert(specs == ["mock/mock"], specs[0]);
    assert(titler.seen[0][0].content == Agent.titlePrompt && titler.seen[0][1].content == "Fix the flaky deploy test in CI");
    agent.run("ok", ev); // titled already: no second request
    assert(agent.titleThreads.length == 1);
    auto s = list(dir)[0];
    assert(s.title == "Fixing the deploy test" && s.prompts == 3 && s.model == "mock/mock");
}

// AI Credits add up across responses that report them and reset with the session.
// rust: agent.rs::record_usage_accumulates_aic_when_reported, agent.rs::new_session_resets_cumulative_counters
unittest
{
    import std.math : isClose;
    auto reg = new ToolRegistry;
    LLMResponse credited(string text, bool aic)
    {
        auto r = LLMResponse(text);
        r.usage = TokenUsage(10, 5);
        if (aic) { r.usage.hasAic = true; r.usage.aic = 0.0216; }
        return r;
    }
    auto mock = new MockClient([credited("a", true), credited("b", false), credited("c", true)]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    auto ev = new NullEvents;
    agent.run("one", ev);
    assert(agent.hasSessionAic && isClose(agent.sessionAic, 0.0216));
    agent.run("two", ev);
    assert(isClose(agent.sessionAic, 0.0216));
    agent.run("three", ev);
    assert(isClose(agent.sessionAic, 0.0432) && agent.sessionInputTokens == 30);
    agent.resetSessionCounters();
    assert(!agent.hasSessionAic && agent.sessionAic == 0 && agent.sessionInputTokens == 0);
}

/// The tool result a crash left unwritten (Rust's INTERRUPTED_TOOL_RESULT).
enum interruptedToolResult = "Error: the harness stopped before this tool call completed; its outcome is unknown.";

/// Error results for the tool calls of the last assistant message with calls
/// that no later message answers.
Message[] danglingRepairs(const Message[] conversation)
{
    ptrdiff_t at = -1;
    foreach_reverse (i, ref m; conversation)
        if (m.role == Role.assistant && m.toolCalls.length) { at = i; break; }
    if (at < 0) return null;
    bool[string] answered;
    foreach (ref m; conversation[at + 1 .. $]) if (m.toolCallId.length) answered[m.toolCallId] = true;
    Message[] repairs;
    foreach (ref c; conversation[at].toolCalls)
        if (c.id !in answered) repairs ~= Message.toolResult(c.id, c.name, interruptedToolResult, true);
    return repairs;
}

// rust: agent.rs::repairs_interrupted_turns_on_resume
unittest
{
    auto calls = [ToolCall.fromRaw("c1", "echo", `{}`), ToolCall.fromRaw("c2", "bash", `{}`)];
    auto conv = [Message.system("s"), Message.user("run"), Message.assistant("", calls),
        Message.toolResult("c1", "echo", "ok")];
    auto r = danglingRepairs(conv);
    assert(r.length == 1 && r[0].toolCallId == "c2" && r[0].content == interruptedToolResult);
    assert(danglingRepairs(conv ~ r).length == 0);
    assert(danglingRepairs([Message.user("x")]).length == 0);
}

/// `s` with anything but [A-Za-z0-9_-] replaced, for a file name.
private string safeName(string s)
{
    import std.array : appender;
    auto o = appender!string;
    foreach (char c; s)
        o.put((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ? c : '_');
    return o.data;
}

// A long result from a tool that doesn't bound its own output is cut and the
// whole text kept beside the session's log.
// rust: agent.rs::persisted_sessions_spill_beside_their_log, agent.rs::long_tool_output_is_cut_and_kept_on_disk
unittest
{
    import std.file : tempDir, rmdirRecurse, exists, dirEntries, SpanMode, mkdirRecurse;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.string : indexOf;
    import std.array : array;
    import nano.session : SessionLog;
    auto dir = buildPath(tempDir, format("nano-d-agent-spill-%s", thisProcessID));
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) {
        auto big = new char[500];
        big[] = 'z';
        return big.idup;
    });
    auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("big1", "echo", `{}`)]), LLMResponse("done")]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    agent.toolOutputLimit = 10;
    agent.log = some(new SessionLog(dir, "m", dir, "sess-x"));
    agent.run("go", new NullEvents);
    auto tool = agent.messages[3];
    assert(tool.content.indexOf("characters omitted; full output saved to " ~ buildPath(dir, "sess-x.spill")) > 0,
        tool.content);
    assert(dirEntries(buildPath(dir, "sess-x.spill"), SpanMode.shallow).array.length == 1);
}

/// Continuations asked for after replies cut off at the output-token limit, per turn.
enum maxTruncatedContinuations = 3;
/// Replies re-requested in one step after the connection dropped mid-stream.
enum maxStreamRestarts = 10;

/// The nudge after a reply cut off at the output-token limit (Rust's wording).
/// The stop reason a log records by value (`max_tokens`); unknown: end_turn.
StopReason stopReasonFrom(string value) @safe pure nothrow
{
    import std.traits : EnumMembers;
    static foreach (m; EnumMembers!StopReason)
        if (value == m) return m;
    return StopReason.endTurn;
}

/// A stop reason meaning the reply was cut off at the output-token limit.
bool isLengthStop(string reason) @safe pure nothrow { return reason == "length" || reason == "max_tokens"; }

/// The reminder asking the model to continue a cut-off reply.
Message continuationReminder(long completionTokens)
{
    auto m = Message.auto_(wrapReminder(truncatedContinuationNote(completionTokens)));
    m.continuation = true;
    return m;
}

/// Replay a turn's logged messages over a continuation snapshot: the answer
/// carried across cut-off chunks and how many continuations ran. A fired
/// timer keeps the prefix; any other user message, a tool run or a finished
/// reply starts a new answer segment (issue #114).
auto replayContinuation(const ref PendingInput snapshot, const Message[] tail)
{
    static struct Replayed { string answer; size_t count; }
    auto r = Replayed(snapshot.hasContinuation ? snapshot.answer : null, snapshot.hasContinuation ? snapshot.count : 0);
    foreach (ref m; tail)
        final switch (m.role)
        {
            case Role.user:
                if (m.continuation) r.count++;
                else if (!m.timer) r.answer = null;
                break;
            case Role.assistant:
                if (!m.toolCalls.length && isLengthStop(m.stopReason)) r.answer ~= m.content;
                else r.answer = null;
                break;
            case Role.tool: r.answer = null; break;
            case Role.system: break;
        }
    return r;
}

string truncatedContinuationNote(long completionTokens)
{
    auto at = completionTokens > 0 ? format(" at the output-token limit (%s tokens)", completionTokens)
        : " at the output-token limit";
    return "Your previous reply was cut off" ~ at ~ "; any tool call in it was not run. "
        ~ "Continue from where you left off, and write large outputs in smaller pieces "
        ~ "(e.g. `write_file` a skeleton, then `edit_file` to fill it in) so each reply "
        ~ "fits within the limit.";
}

private LLMResponse cutText(string content, long tokens)
{
    auto r = LLMResponse(content);
    r.stopReason = "length";
    r.usage.outputTokens = tokens;
    return r;
}

// rust: agent.rs::a_reply_cut_off_at_the_output_limit_continues_instead_of_ending
unittest
{
    import std.string : indexOf;
    auto mock = new MockClient([cutText("half a file", 4096), LLMResponse("all done")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "half a fileall done");
    assert(agent.lastStop == StopReason.endTurn);
    auto note = agent.messages[3];
    assert(note.role == Role.user && note.content.indexOf("cut off") >= 0 && note.content.indexOf("4096") >= 0);
    assert(agent.messages[2].content == "half a file" && agent.messages[2].stopReason == "max_tokens");
}

// rust: agent.rs::repeated_output_limit_cut_offs_end_with_a_distinct_stop_reason
unittest
{
    LLMResponse[] cuts;
    foreach (_; 0 .. maxTruncatedContinuations + 1) cuts ~= cutText("still going", 100);
    auto mock = new MockClient(cuts);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    import std.array : replicate;
    assert(agent.run("go", new NullEvents) == "still going".replicate(maxTruncatedContinuations + 1));
    assert(agent.lastStop == StopReason.maxTokens);
}

// rust: agent.rs::output_limit_continuations_accumulate_the_whole_answer
unittest
{
    auto mock = new MockClient([cutText("one ", 100), cutText("two ", 100), LLMResponse("three")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "one two three");
    assert(agent.lastStop == StopReason.endTurn);
}

// rust: agent.rs::a_tool_run_resets_the_continuation_accumulator
unittest
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    auto mock = new MockClient([cutText("lost ", 100), LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{}`)]),
        LLMResponse("fresh")]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "fresh");
}

// A reply whose stream drops mid-way is asked for again; the partial text
// isn't kept in the conversation.
// rust: agent.rs::mid_reply_drops_are_retried_and_leave_no_partial_text_in_history, agent.rs::too_many_mid_reply_drops_end_the_turn
unittest
{
    import nano.providers.mock;
    auto mock = new MockClient([LLMResponse("!drop:Hal"), LLMResponse("!drop:Half a"), LLMResponse("whole answer")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "whole answer");
    assert(mock.seen.length == 3);
    assert(agent.messages[$ - 1].content == "whole answer" && agent.messages[$ - 2].content == "go");
    // Past the restart limit the error ends the turn.
    LLMResponse[] drops;
    foreach (i; 0 .. maxStreamRestarts + 1) drops ~= LLMResponse("!drop:x");
    mock.script = drops ~ LLMResponse("never");
    bool threw;
    try agent.run("again", new NullEvents);
    catch (StreamInterrupted) threw = true;
    assert(threw);
}

// Timers: a timer set by the model fires mid-turn as a system note before
// the next model call, and an idle one is handed to the caller as a prompt.
// rust: agent.rs::a_timer_set_in_a_turn_fires_mid_turn_when_the_clock_passes_it, agent.rs::a_pending_timer_nudges_every_few_steps_until_marked_done
// rust: agent.rs::idle_take_fired_timers_returns_due_timers_once, agent.rs::timer_tools_are_hidden_when_timers_are_disabled
unittest
{
    import nano.providers.mock;
    import std.algorithm : canFind, any;
    long clock = 1_000_000;
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("t", "timer_set", `{"after": "5m", "note": "check CI"}`)]),
        LLMResponse("", "", [ToolCall.fromRaw("w", "wait", `{}`)]),
        LLMResponse("done"),
    ]);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("wait", "", parseJSON(`{"type":"object"}`)), (JSONValue a) { clock += 600; return "waited"; });
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    agent.now = () => clock;
    assert(agent.run("go", new NullEvents) == "done");
    assert(mock.toolsSeen[0].canFind("timer_set"));
    assert(mock.seen[1][$ - 1].content.canFind("Timer 1 set for"));
    assert(mock.seen[2].any!(m => m.content.canFind("Timer 1, set at") && m.content.canFind("check CI")));
    assert(agent.timers.empty && agent.timers.pending.length == 1);

    // Not marked done: restated every few steps, until timer_done.
    reg.register(ToolDefinition("noop", "", parseJSON(`{"type":"object"}`)), (JSONValue a) => "ok");
    LLMResponse noop(int i) { return LLMResponse("", "", [ToolCall.fromRaw("n", "noop", format(`{"i": %s}`, i))]); }
    mock.script = [noop(1), noop(2), noop(3), noop(4), noop(5),
        LLMResponse("", "", [ToolCall.fromRaw("d", "timer_done", `{"id": 1}`)]), noop(6), noop(7), noop(8), noop(9),
        noop(10), noop(11), LLMResponse("ok")];
    auto before = mock.seen.length;
    agent.run("keep working", new NullEvents);
    size_t nudges;
    foreach (req; mock.seen[before .. $])
        if (req[$ - 1].content.canFind("haven't marked done")) nudges++;
    assert(nudges == 1, nudges.to!string);
    assert(agent.timers.pending.length == 0, agent.timers.toJSON.toString ~ mock.seen[$ - 1][$ - 1].content);

    // Idle: nothing due yet, then the fired message.
    mock.script = [LLMResponse("", "", [ToolCall.fromRaw("t", "timer_set", `{"after": "2m", "note": "look again"}`)]),
        LLMResponse("ok")];
    agent.run("again", new NullEvents);
    string notice;
    assert(agent.takeFiredTimers(notice) is null);
    clock += 120;
    auto msg = agent.takeFiredTimers(notice);
    assert(msg.canFind("look again") && notice.canFind("⏰ timer 2"), notice);

    agent.timerTools = false;
    mock.script = [LLMResponse("x")];
    agent.run("off", new NullEvents);
    assert(!mock.toolsSeen[$ - 1].canFind("timer_set"));
}

// ---- memory recall from tool calls (Rust #167) ----
version (unittest)
{
    private mem.Store recallStore(string name)
    {
        import std.file : tempDir, exists, rmdirRecurse;
        import std.path : buildPath;
        auto dir = buildPath(tempDir, "nano-d-recall-" ~ name);
        if (dir.exists) rmdirRecurse(dir);
        return new mem.Store(buildPath(dir, "memory"), null, 0);
    }

    private LLMResponse probeCall(string id, string path)
    {
        return LLMResponse("", "", [ToolCall.fromRaw(id, "probe", JSONValue(["path": path]).toString)]);
    }

    private ToolRegistry probeTools()
    {
        auto reg = new ToolRegistry;
        reg.register(ToolDefinition("probe", "", parseJSON(`{}`)), (JSONValue a) => "no such file");
        return reg;
    }

    private string[] toolTexts(Agent a)
    {
        string[] r;
        foreach (m; a.messages) if (m.role == Role.tool) r ~= m.content;
        return r;
    }

    private size_t pinCount(Agent a)
    {
        import std.algorithm : count;
        size_t n;
        foreach (t; toolTexts(a)) n += t.count("📌");
        return n;
    }
}

// rust: agent.rs::tool_calls_recall_matching_memories_once_per_context
// rust: agent.rs::replacing_the_conversation_resets_and_persists_recall
unittest // a hint fires once per context, a rule every time; compaction resets durably; resume restores
{
    import std.algorithm : canFind;
    import std.array : replicate;
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    import nano.providers.mock : MockClient;
    auto store = recallStore("once");
    auto path = "/nonexistent/omarchy.local/worker.log";
    auto mock = new MockClient([probeCall("r1", path), LLMResponse("one"), probeCall("r2", path), LLMResponse("two"),
        LLMResponse("SUMMARY: read logs"), probeCall("r3", path), LLMResponse("three")]);
    auto agent = new Agent(mock, probeTools(), Policy.init, "sys");
    agent.memory = some(store);
    auto sdir = buildPath(tempDir, "nano-d-recall-once-sessions");
    if (sdir.exists) rmdirRecurse(sdir);
    agent.log = some(new SessionLog(sdir, "mock/m", "/x"));
    // Longer than the index's 200-char clip, so the index alone does not show it.
    auto hint = store.save(mem.Scope.user,
        "worker logs on omarchy.local live under ~/.local/share/c8ctl-nano/logs " ~ "x".replicate(200), null, null);
    auto rule = store.saveWith(mem.Scope.user, "never broad-kill on this host", null, null, "rule", ["worker.log"], true);
    agent.run("look", new NullEvents);
    auto first = toolTexts(agent)[$ - 1];
    assert(first.canFind(hint.id) && first.canFind(rule.id) && first.canFind("verify"), first);
    assert(first.canFind("<system-reminder>"), first);

    agent.run("again", new NullEvents);
    auto second = toolTexts(agent)[$ - 1];
    assert(!second.canFind(hint.id), "a hint fires once per context: " ~ second);
    assert(second.canFind(rule.id), "a rule fires on every match: " ~ second);

    // A resume restores what was seen.
    agent.restoreRecall(restore(agent.log.unwrap("set above").path).recall);
    assert(hint.id in agent.recallState.seen);

    CompactReport rep;
    assert(agent.compact(rep));
    assert(agent.recallState.empty, "compaction resets recall");
    assert(mem.Recall.fromJSON(restore(agent.log.unwrap("set above").path).recall).empty, "the reset is persisted");
    agent.run("after compaction", new NullEvents);
    auto third = toolTexts(agent)[$ - 1];
    assert(third.canFind(hint.id), "a hint reappears after compaction: " ~ third);

    auto stats = mem.recallStats(store);
    assert(stats[hint.id][0] == 2, "fired twice");
}

// rust: agent.rs::memories_rendered_in_full_by_the_index_do_not_refire
unittest // the installed index's fully rendered memories don't refire; clipped ones do
{
    import std.algorithm : canFind, endsWith;
    import std.array : replicate;
    import std.string : lineSplitter;
    import nano.providers.mock : MockClient;
    auto store = recallStore("index");
    auto path = "/nonexistent/omarchy.local/worker.log";
    auto short_ = store.save(mem.Scope.user, "worker logs on omarchy.local live under ~/.local/share", null, null);
    auto long_ = store.saveWith(mem.Scope.user, "worker.log detail: " ~ "x".replicate(300), null, null, null,
        ["worker.log"], true);
    bool[string] rendered;
    auto index = store.indexWithRendered(false, rendered);
    string shortLine, longLine;
    foreach (l; index.lineSplitter)
    {
        if (l.canFind(short_.id)) shortLine = l;
        if (l.canFind(long_.id)) longLine = l;
    }
    assert(shortLine.endsWith("live under ~/.local/share") && longLine.endsWith("…"), index);
    assert(short_.id in rendered && long_.id !in rendered);

    auto mock = new MockClient([probeCall("r1", path), LLMResponse("one"), probeCall("r2", path), LLMResponse("two")]);
    auto agent = new Agent(mock, probeTools(), Policy.init, "sys" ~ index);
    agent.memory = some(store);
    agent.installSystem("sys" ~ index, rendered);
    agent.run("look", new NullEvents);
    auto first = toolTexts(agent)[$ - 1];
    assert(!first.canFind(short_.id), "no duplicate recall of a fully rendered memory: " ~ first);
    assert(first.canFind(long_.id), "the clipped memory still fires: " ~ first);
    assert(short_.id !in agent.recallState.seen, "index visibility is not recorded as seen");
    // A resume keeps the installed system message, so still no duplicate.
    agent.restoreRecall(agent.recallState.toJSON);
    agent.run("again", new NullEvents);
    assert(!toolTexts(agent)[$ - 1].canFind(short_.id));
}

// rust: agent.rs::a_memory_evicted_from_the_installed_index_becomes_recallable
unittest // an index re-install that drops a memory makes it recallable again
{
    import std.algorithm : canFind;
    import std.array : replicate;
    import std.format : format;
    import nano.providers.mock : MockClient;
    auto store = recallStore("evict");
    auto path = "/nonexistent/omarchy.local/worker.log";
    auto short_ = store.save(mem.Scope.user, "worker logs on omarchy.local live under ~/.local/share", null, null);
    bool[string] rendered;
    auto index = store.indexWithRendered(false, rendered);
    auto mock = new MockClient([probeCall("r1", path), LLMResponse("one"), probeCall("r2", path), LLMResponse("two")]);
    auto agent = new Agent(mock, probeTools(), Policy.init, "sys");
    agent.memory = some(store);
    agent.installSystem("sys" ~ index, rendered);
    agent.run("look", new NullEvents);
    assert(!toolTexts(agent)[$ - 1].canFind(short_.id), "shown by the index");
    foreach (n; 0 .. 60)
        store.save(mem.Scope.user, format("unrelated fact number %s %s", n, "y".replicate(150)), null, null);
    bool[string] rendered2;
    index = store.indexWithRendered(false, rendered2);
    assert(!index.canFind(short_.id), "precondition: evicted from the index");
    agent.installSystem("sys" ~ index, rendered2);
    agent.run("again", new NullEvents);
    auto second = toolTexts(agent)[$ - 1];
    assert(second.canFind(short_.id), "an evicted memory recalls again: " ~ second);
}

// rust: agent.rs::recall_attaches_at_most_two_notes_per_turn
unittest // at most two notes per input; refused calls never recall
{
    import std.array : replicate;
    import std.format : format;
    import nano.providers.mock : MockClient;
    auto store = recallStore("cap");
    auto path = "/nonexistent/omarchy.local/x";
    foreach (n; 0 .. 4)
        store.save(mem.Scope.user, format("fact %s about omarchy.local %s", n, "x".replicate(200)), null, null);
    auto mock = new MockClient([probeCall("r1", path), probeCall("r2", path), LLMResponse("done"),
        probeCall("r3", path), probeCall("r4", path), LLMResponse("done")]);
    auto agent = new Agent(mock, probeTools(), Policy.init, "sys");
    agent.memory = some(store);
    agent.run("look", new NullEvents);
    assert(pinCount(agent) == 2, format("%s", pinCount(agent)));
    // A new input gets a fresh budget.
    agent.run("again", new NullEvents);
    assert(pinCount(agent) == 4, format("%s", pinCount(agent)));

    // A call that never reaches a handler (unknown tool, plan-mode refusal) recalls nothing.
    auto unknown = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("u1", "nope", `{"path":"` ~ path ~ `"}`)]),
        LLMResponse("done")]);
    auto b = new Agent(unknown, probeTools(), Policy.init, "sys");
    b.memory = some(store);
    b.run("look", new NullEvents);
    assert(pinCount(b) == 0);
}
