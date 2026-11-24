/// The agent loop: send the conversation, stream the reply, run the tool
/// calls it asks for (after permission checks), feed results back, repeat.
module nano.agent;

@safe:
import nano.safeio : jsonText, jsonPretty;
import nano.clock : monoNow, since, sleepFor, stdTimeNow, wallNow;
import core.time : MonoTime;
import nano.arith : checkedMul, checkedSub, saturatingAdd, saturatingSub, clampToLong, toLong, toSize;
import nano.option : Option, some, none, match, ifSome, orElse, unwrap, NotNull;
import nano.result : orThrow, toOption, match, unwrap;

import nano.safeio : Chan, Isolated, Join, JoinHandle, spawn, spawnDaemon, stdErr, stdOut;
import nano.subagent : SubAbort;
import nano.probe : ProbeState;
import core.time : seconds;

import std.json;
import std.format : format;
import std.string : strip, stripLeft;
import std.array : join;
import std.conv : to;
import nano.llm;
import nano.http : StreamInterrupted, hasUsage;
import core.thread : Thread;
import core.time : Duration;
static import nano.session_index;
import nano.tools;
import nano.question : QuestionError, QuestionBroker, Question, QuestionOption, Answer, Answered;
import std.sumtype : match;
import nano.mode : AgentMode, planAllows;
import nano.goal : Outcome, OutcomeStatus, verifyReminder, outcomeToolName = toolName, outcomeDefinition = definition;
import nano.reminders : Reminders, wrap;
import mem = nano.memory;
import ctx = nano.context;
import hist = nano.session_history;
import cross = nano.cross_session;
import peers = nano.peers;
import nano.instructions : ProjectInstructions;
import nano.thinking : Thinking, ThinkingResolved = Resolved, resolveThinking = resolve, Request, cappedBudget, Reported, ThinkingSource = Source;
import temp = nano.temperature;
import nano.vision : Vision, resolveVision = resolve;
import nano.llm : Attachment;
import nano.tools.files : PatchSnapshot, PatchHandler;

/// A tool result as displayed: the text plus each attached image's placeholder.
string toolResultDisplay(string text, const(Attachment)[] attachments) pure
{
    foreach (ref a; attachments) text ~= (text.length ? "\n" : "") ~ a.placeholder;
    return text;
}
import nano.config : KindedClient, ProviderConfig, ProviderKind;
import std.typecons : Nullable;
import std.algorithm : min, max, clamp;
import nano.plan : Plan, isPlanTool, planDefinitions = definitions;
import settings = nano.session_settings;
import nano.timers : Timers, TimerError, isTimerTool, timerDefinitions = definitions, firedMessage, firedNotice, pendingNudge, pendingNudgeEvery, Timer, maxPending;
import nano.permissions;
import nano.session;
import nano.control;
import nano.claude_hooks : HookManager, Decision, HookOutcome = Outcome, applyUpdatedInput, maxStopBlocks;
import nano.subagent : SubClientFactory, SubLimits, SubSlot, SubGate, SubMsg, SubKind, SubResult, SubProgress,
    ToolReply, SubAbort, SubSpec, subToolName = toolName, subDefinition = definition, SubCandidate,
    isSubControlTool = isControlTool, subControlDefinitions = controlDefinitions;
import nano.safeio : Chan;
import std.typecons : Rebindable;

/// Bytes of recent final responses an agent keeps for idempotent
/// redelivery (issue #312); older ones are read back from the session log.
enum size_t completedMaxBytes = 1024 * 1024;

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
    /// A streamed reply broke off and is being asked again: the partial
    /// already shown is abandoned, and the restart begins a fresh segment.
    void responseRestarted();
    /// A model call (one generation) is about to start: a rate shown for
    /// the previous one is stale from here on.
    void generationStart();
    /// A fresh model call is about to be prepared, before its steers drain
    /// and its request is built. A sub-agent's limit check runs here, so a
    /// limit first seen now still gets its report reminder into the grace
    /// request (nano.subagent.ChildEvents). Events classes that don't
    /// care mix in `AgentEventDefaults` for a no-op.
    void beforeFreshCall();
    /// Every running sub-agent's state after a change; `done` ones are
    /// listed once, as they finish. Renderers that show progress override
    /// this; events classes that don't care mix in `AgentEventDefaults`.
    void subagents(const(SubProgress)[] all);
    /// A compaction's summary request (a model call that is not a turn's
    /// generation) is about to start. A sub-agent counts it toward its
    /// budget without spending its one reporting-grace call on it
    /// (nano.subagent.ChildEvents); everyone else treats it as a
    /// generation (`AgentEventDefaults`).
    void summaryStart();
}

/// No-op defaults for the `AgentEvents` members an events class need not
/// care about (a D interface can't give a virtual method a body). Mix in
/// and override what you render.
mixin template AgentEventDefaults()
{
    void beforeFreshCall() {}
    void subagents(const imported!"nano.subagent".SubProgress[] all) {}
    void summaryStart() { generationStart(); }
}

/// Wrap text the model should read as a system note, not user words.
string wrapReminder(string text) pure nothrow
{
    return "<system-reminder>\n" ~ text ~ "\n</system-reminder>";
}

/// The text a `wrapReminder` note wraps, or null when `content` is not one.
/// Replay shows a Stop hook's rejection reason as the user message it
/// printed live, so it needs the reason back out of the wrapper.
string unwrapReminder(string content) pure nothrow
{
    import std.string : startsWith, endsWith;
    enum pre = "<system-reminder>\n", post = "\n</system-reminder>";
    if (!content.startsWith(pre) || !content.endsWith(post)) return null;
    // Both delimiters must fit without overlapping: a malformed wrapper like
    // "<system-reminder>\n</system-reminder>" passes both checks yet shares
    // the newline, and slicing [pre.length .. $ - post.length] would invert
    // the bounds. Not a wrapper: fall back to the raw content.
    if (content.length < pre.length + post.length) return null;
    return content[pre.length .. $ - post.length];
}


/// A `report_outcome` call the agent rejects: `Outcome.fromArgs`'s error, or
/// the verify reminder. Its message is the tool result for the model.
class OutcomeError : Exception
{
    this(string msg) pure { super(msg); }
}

/// Why compaction was requested.
/// A refused `session_settings` call; the message is for the model.
class SettingsError : Exception
{
    this(string msg) pure { super(msg); }
}

/// Why compaction was requested.
enum CompactTrigger { manual, threshold, overflow, /** opportunistic, at the idle prompt (Rust #186); folds like threshold */ idle,
    /** the agent's `session_settings compact_now` (#293), before its next request; folds like threshold */ agent }

/// Once-per-crossing gate for idle compaction (Rust `idle_compact.rs`): after
/// an idle attempt that did not compact, it stays shut until the context grows
/// by real headroom (`window / 10`); any compaction or a reset re-arms it.
struct IdleCompactGate
{
    private bool spent;
    private size_t spentAt;
    bool armed(size_t tokens, size_t window) pure const { return !spent || tokens > spentAt + window / 10; }
    void spend(size_t tokens) pure { spent = true; spentAt = tokens; }
    void reset() pure { spent = false; }
}

/// An idle compaction's outcome, with usage before and after as a percentage
/// of the window for the transcript note.
struct IdleCompactReport
{
    CompactReport report;
    size_t percentBefore, percentAfter;

    this(CompactReport r, size_t window) pure
    {
        import std.math : round;
        // Saturate before converting: a huge anomalous count over a tiny
        // window exceeds size_t (and size_t.max rounds up as a double).
        size_t pct(size_t t)
        {
            import std.conv : to;
            immutable p = round(t * 100.0 / (window ? window : 1));
            // 2.0^^64 is the first double past size_t.max (which rounds up to it).
            return p >= 2.0 ^^ (size_t.sizeof * 8) ? size_t.max : p.to!size_t;
        }
        report = r;
        percentBefore = pct(r.tokensBefore);
        percentAfter = pct(r.tokensAfter);
    }

    string toString() pure const
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

    string toString() pure const
    {
        auto s = format("%scompacted %s messages: ~%s -> ~%s tokens (%s -> %s messages)",
            mode == ctx.CompactionMode.standard ? "" : ctx.modeName(mode) ~ "-", summarized, ctx.formatTokens(tokensBefore),
            ctx.formatTokens(tokensAfter), messagesBefore, messagesAfter);
        if (fallback !is null) s ~= format("; summary failed (%s), older messages were dropped", fallback);
        else if (truncated) s ~= "; the summary hit the output limit and is incomplete";
        return s;
    }
}

/// The result for calls skipped after the loop detector's hard stop.
enum string loopStoppedToolResult =
    "Error: the turn is ending as blocked (repeated-call loop detected); this tool call was not run.";

/// The turn loop's state machine; `StopReason` and the turn limits live there.
public import nano.turn : StopReason, headlessSafetyCap, maxTruncatedContinuations, maxStreamRestarts;
import nano.turn : TurnState, Limits, Event, CallDue, KeepGoing, Replied, CallFailed, Failure, Compacted, StopHookRan,
    ToolsRan, Next, AskKeepGoing, CallModel, Restarting, LimitOutput, CompactForOverflow, Rethrow, Cancel,
    ContinueCutOff, SyncContinuation, Notice, RunStopHook, StopBlocked, RunTools, FinishOutcome, Finish, step;

/// A `context_window` from the configuration and which key set it.
struct ConfiguredWindow
{
    size_t tokens;
    string source;
}

/// The replay stash with the content dropped for entries with a log
/// (`Agent.replayStashLog`) read back from their log lines. An entry whose
/// line can't be read keeps its empty content.
const(Message)[] rehydrateStash(const(Message)[] stash, Option!SessionLog[] logs)
{
    import nano.session_history : load;
    bool any;
    foreach (l; logs) any |= l.isSome;
    if (!any) return stash;
    // The lines each log must give back: only those are decoded, streaming
    // the log (issue #263: decoding it whole held every message of a long
    // session at once, and the heap stayed at that peak).
    bool[ulong][SessionLog] wanted;
    foreach (i, ref m; stash)
        if (i < logs.length)
            logs[i].ifSome((SessionLog l) { wanted.require(l)[m.logLine] = true; });
    Message[ulong][SessionLog] byLog;
    foreach (src, lines; wanted)
    {
        Message[ulong] at;
        // The path is read at replay time, not at slimming time: a
        // recovery (`SessionLog.recoverReplaced`) may have moved the
        // writer since, and the stale path would name a foreign file.
        try
            foreach (e; load(src.path, (id) => (id in lines) !is null))
                if (e.message.role == Role.tool || e.message.role == Role.assistant) at[e.id] = e.message;
        catch (Exception) {} // an unreadable log: the entries replay empty
        byLog[src] = at;
    }
    import nano.safeio : deepCopy;
    const(Message)[] o;
    o.reserve(stash.length);
    foreach (i, ref m; stash)
    {
        if (i >= logs.length || logs[i].isNone) { o ~= m; continue; }
        Message x = deepCopy(m);
        auto src = logs[i].unwrap("isSome");
        if (auto r = x.logLine in byLog[src])
            if (r.role == x.role && r.toolCallId == x.toolCallId && (r.role == Role.tool || r.timestamp == x.timestamp))
            {
                x.content = r.content;
                x.thinking = r.thinking;
                x.thinkingBlocks = r.thinkingBlocks;
                x.toolCalls = r.toolCalls;
            }
        o ~= x;
    }
    return o;
}

/// One path an apply_patch call touches, as the file-tool call that would
/// change it directly (for the per-path hooks).
private struct PatchEdit
{
    string name;
    JSONValue args;
}

/// A fixed-size Bloom filter of evicted completed-input ids (issue #312):
/// its memory is constant however many turns a session evicts. `mayContain`
/// has no false negatives; a false positive is harmless (a log lookup).
struct EvictedIds
{
    private enum words = 4_096; // 32 KiB, 262_144 bits
    private ulong[] bits;

    private static size_t[2] slots(string id) pure nothrow @nogc
    {
        immutable h = hashOf(id);
        immutable g = hashOf(id, 0x9E37_79B9_7F4A_7C15UL) | 1;
        return [h % (words * 64), (h + g) % (words * 64)];
    }

    /// Record `id` as evicted.
    void add(string id) pure nothrow
    {
        if (bits.length == 0) bits = new ulong[words];
        foreach (s; slots(id)) bits[s / 64] |= 1UL << (s % 64);
    }

    /// Whether `id` may have been evicted (never false for an added id).
    bool mayContain(string id) const pure nothrow @nogc
    {
        if (bits.length == 0) return false;
        foreach (s; slots(id)) if (!(bits[s / 64] & (1UL << (s % 64)))) return false;
        return true;
    }

    /// The bytes the filter holds: constant once anything was added.
    size_t byteSize() const pure nothrow @nogc => bits.length * ulong.sizeof;
}

unittest
{
    import std.conv : to;
    EvictedIds e;
    assert(!e.mayContain("x") && e.byteSize == 0);
    foreach (i; 0 .. 20_000) e.add("in-" ~ i.to!string);
    immutable size = e.byteSize;
    foreach (i; 0 .. 20_000) assert(e.mayContain("in-" ~ i.to!string));
    foreach (i; 20_000 .. 40_000) e.add("in-" ~ i.to!string);
    assert(e.byteSize == size && size <= 32 * 1024);
}

class Agent
{
    NotNull!LLMClient client;
    NotNull!ToolRegistry tools;
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
    /// What the endpoint reports about the current model, and the probe
    /// generations that guard it (`nano.probe`).
    ProbeState probe;
    /// The reports themselves.
    ref inout(Capabilities) capabilities() inout pure return { return probe.caps; }
    version (unittest)
    {
        /// Test hook: runs in `prepareCall` after the first
        /// threshold-compaction block, just before `applyModelRequest`. A
        /// test that needs a probe to land after the first check gates the
        /// probe and opens the gate here — blocking inside a publication
        /// instead deadlocks the agent thread against this hook.
        void delegate() onThresholdChecked;
    }
    private ProviderConfig noProvider;
    Option!SessionLog log;
    TokenUsage lastUsage;
    /// Steer or cancel the running turn from another thread.
    NotNull!(shared TurnControl) control;
    /// Why the last `run` ended.
    StopReason lastStop;
    /// Finished turns by input id (see `Restored.completed`): redelivering
    /// one returns the recorded response without re-running the turn.
    string[string] completedInputs;
    string[string] completedStops;
    JSONValue[string] completedOutcomes;
    /// The ids in `completedInputs`, oldest first, and the bytes their
    /// responses hold: past `completedMaxBytes` the oldest are evicted
    /// (issue #312).
    string[] completedOrder;
    size_t completedBytes;
    /// The byte cap on `completedInputs` (tests lower it).
    size_t completedCap = completedMaxBytes;
    /// Ids evicted from `completedInputs`, as a fixed-size Bloom filter so
    /// it never grows with the session: redelivering one reads its response
    /// back from the session log's `turn_end` record. A false positive only
    /// costs a log scan that finds nothing; the turn then runs normally.
    EvictedIds completedEvicted;
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

    /// `autoCompactThreshold` clamped to the effective 0.1–0.99 range
    /// (a NaN falls back to the 0.8 default). Every reader that reports or
    /// acts on the threshold goes through this, so a configured out-of-range
    /// value can never yield a negative or overflowing token count.
    double effectiveAutoCompactThreshold() const pure nothrow @nogc @safe
    {
        auto t = autoCompactThreshold;
        if (t != t) return 0.8;
        return t < 0.1 ? 0.1 : t > 0.99 ? 0.99 : t;
    }
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
    void adoptPending(const ref Restored r) pure
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
    private void syncPendingContinuation(string answer, size_t count) pure
    {
        if (!hasPending) return;
        pending.hasContinuation = answer.length || count;
        pending.answer = pending.hasContinuation ? answer : null;
        pending.count = pending.hasContinuation ? count : 0;
        pending.hasBase = true;
        pending.base = messages.length;
    }

    /// Take a reported outcome from a resumed turn's messages; true when found.
    private bool outcomeFrom(const Message[] tail) pure
    {
        foreach_reverse (ref m; tail)
            foreach_reverse (ref c; m.toolCalls)
                if (c.name == outcomeToolName)
                {
                    // Malformed outcome arguments are not a recorded outcome: keep scanning.
                    foreach (o; Outcome.fromArgs(c.arguments).toOption)
                    {
                        lastOutcome = o;
                        hasOutcome = true;
                        return true;
                    }
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
    /// The restored `pinStash` dropped legacy non-request entries, so the
    /// next compaction writes it in full rather than as a delta (issue #301).
    bool pinStashRestate;
    /// The requests `ctx.trimPinStash` dropped from between `pinStash[0]`
    /// and `pinStash[1]` (issue #312): they still count in the on-disk
    /// `pinned_base` and in the pinned block's omission note.
    ctx.PinGap pinGap;
    /// The smallest window a trimmed `pinStash` still renders exactly for
    /// (`ctx.trimPinStash`; tests lower it).
    size_t pinTrimFloor = ctx.pinTrimWindowTokens;
    /// The real turns folded by compactions since the last plain replacement:
    /// a replay (ACP session/load) shows them in place of the summary.
    Message[] replayStash;
    /// Per `replayStash` entry: the session log its content was dropped for
    /// (it is read back from its `logLine` there on replay), or null when the
    /// entry keeps its content (or, with no log, dropped it). Long sessions would otherwise hold every
    /// folded tool output in memory (issue #248).
    /// The live `SessionLog`, not its path at slimming time:
    /// `SessionLog.recoverReplaced` can move the writer to a recovery file
    /// (changing `l.path`) after the reference was taken, and a saved path
    /// would then name a foreign file the replay reads empty or unrelated
    /// output from.
    Option!SessionLog[] replayStashLog;
    /// Log lines whose in-memory content a compaction clipped: their content
    /// differs from the log record, so the stash keeps it.
    bool[ulong] clippedLines;
    /// Log lines up to this one came from a restored session, whose clipping
    /// is unknown (`clippedLines` is not persisted): their content is never
    /// dropped from the stash.
    ulong restoredLineFloor;
    /// The session logs `replayStashLog` has handed out, so a slimmed entry's
    /// reference stays valid for the session's life even across a `restart`
    /// (which closes the outgoing log: a replay still reads it back).
    private SessionLog[] stashRefLogs;
    /// history_search / history_read calls in the current turn (logged on its turn_end).
    uint turnHistoryCalls;
    /// The thinking level the turn's latest request sent (as the status line
    /// shows it; empty: none), so a setting changed while it runs is shown
    /// only once a request sends it. None between turns.
    Option!string requestThinking;
    /// Index of the restated in-flight input the latest compaction folded;
    /// a replay skips it, its original being in `replayStash`.
    Option!size_t replayRestated;
    /// The configured `context_window` (0: none), and whether the top-level
    /// key or the provider's set it (`contextWindow`'s source).
    size_t configuredWindow;
    string configuredWindowSource = "context_window in config";

    void setConfiguredWindow(ConfiguredWindow w) pure
    {
        configuredWindow = w.tokens;
        if (w.source.length) configuredWindowSource = w.source;
    }

    /// Apply a configured window restored from a session record (issue
    /// #297). Clearing a positive window re-probes the endpoint: the probe
    /// made under the old window skipped window detection, so without it the
    /// session would fall back to a model-name estimate.
    void restoreConfiguredWindow(ConfiguredWindow w)
    {
        const cleared = configuredWindow > 0 && w.tokens == 0;
        setConfiguredWindow(w);
        if (cleared) refreshCapabilities();
    }
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
    /// How many model calls (sub-agents included) reported AI Credits this
    /// session, so a turn reporting zero credits is told apart from one reporting none.
    ulong aicReports;
    /// Model requests interrupted (cancelled or a broken stream) before the
    /// provider reported usage: left out of the totals, never estimated.
    size_t uncountedRequests;
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

    /// Run one user input to completion. Returns the final assistant text,
    /// or `cancelledResponse` when the turn was cancelled. Steers that arrive
    /// too late for this turn stay in `control` for the caller to queue.
    /// Pass `resetControl = false` when the caller already called
    /// `control.startTurn()`, so a cancel routed before `run` began is kept.
    string run(string input, AgentEvents ev, bool resetControl = true, string givenId = null,
        bool fromPeer = false, string peerSender = null, uint peerHop = 1, string peerThread = null)
    {
        import std.datetime.systime : Clock;
        import std.conv : to;
        // A harness-initiated input (a fired timer): never pinned as a request.
        bool automatic = automaticInput;
        automaticInput = false;
        // The loop guard (issues #272, #350): a peer-started turn's sends
        // count hops along the thread; any other input starts at hop 1.
        peerTurn = fromPeer;
        inputSender = fromPeer ? peerSender : null;
        // Issue #350: the hop and thread of the peer message that started
        // this turn; a reply from it is one hop further along the thread.
        inputHop = fromPeer ? (peerHop ? peerHop : 1) : 0;
        inputThread = fromPeer ? peerThread : null;
        if (givenId.length)
        {
            if (auto done = givenId in completedInputs)
            {
                import std.stdio : stderr;
                stdErr.writefln("[agent] input %s already processed; returning recorded response", JSONValue(givenId).jsonText);
                auto st = givenId in completedStops;
                lastStop = st is null ? StopReason.endTurn : stopReasonFrom(*st);
                auto oc = givenId in completedOutcomes;
                // A recorded outcome that no longer parses is treated as none.
                auto recorded = oc is null ? Option!Outcome.init : Outcome.fromArgs(*oc).toOption;
                hasOutcome = recorded.isSome;
                foreach (o; recorded) lastOutcome = o;
                return *done;
            }
            else if (completedEvicted.mayContain(givenId))
            {
                Option!CompletedTurn found;
                // Recover a removed or replaced log first: the lookup reads by path.
                log.ifSome((SessionLog l) { l.revalidate(); found = findCompletedTurn(l.path, givenId); });
                foreach (t; found)
                {
                    stdErr.writefln("[agent] input %s already processed; returning recorded response",
                        JSONValue(givenId).jsonText);
                    lastStop = stopReasonFrom(t.stopReason);
                    auto recorded = t.outcome.type == JSONType.object ? Outcome.fromArgs(t.outcome).toOption
                        : Option!Outcome.init;
                    hasOutcome = recorded.isSome;
                    foreach (o; recorded) lastOutcome = o;
                    return t.response;
                }
            }
        }
        // Every input carries an id; the log pairs it with a turn_end record,
        // so an input without one marks a turn a crash interrupted.
        auto inputId = givenId.length ? givenId
            : format("in-%s-%s", (stdTimeNow - 621_355_968_000_000_000L) / 10_000, ++inputCounter);
        ulong from = logSize();
        // Redelivering the id of an interrupted turn resumes it (its input
        // was logged already).
        bool resuming = hasPending && givenId.length && pending.id == givenId;
        // A resumed turn keeps its persisted provenance: a peer input or an
        // absorbed peer steer re-arms the loop guard whatever the caller says.
        if (resuming)
            foreach (i; pending.position .. messages.length)
                if (messages[i].fromSession.length)
                {
                    peerTurn = true;
                    // The hop isn't persisted: a resumed peer turn counts
                    // as hop 1 (like a message from an older sender).
                    if (!inputHop) inputHop = 1;
                    if (!inputSender.length && i == pending.position) inputSender = messages[i].fromSession;
                    break;
                }
        if (!resuming) log.ifSome((SessionLog l) { l.input(inputId, input, inputSender); });
        turnHistoryCalls = 0;
        turnSerial++;
        scope (exit) requestThinking = Option!string.init;
        string response;
        // Esc Esc stops background sub-agents too (issue #266), wherever
        // in the turn it landed.
        scope (exit) if (control.isCancelled && subagentsActive) finishSubagents();
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
            l.turnEnd(inputId, response, lastStop, hasOutcome ? lastOutcome.toJSON : JSONValue.init,
                turnHistoryCalls);
            indexTurn(l, from);
        });
        hasPending = false;
        rememberCompleted(inputId, response);
        if (lastStop != StopReason.endTurn) completedStops[inputId] = lastStop;
        else completedStops.remove(inputId);
        if (hasOutcome) completedOutcomes[inputId] = lastOutcome.toJSON;
        else completedOutcomes.remove(inputId);
        evictCompleted();
        return response;
    }

    /// Bound `pinStash` for a `window`-token context (`ctx.trimPinStash`).
    private void trimPins(size_t window)
    {
        foreach (t; ctx.trimPinStash(pinStash, pinGap, window, pinTrimFloor))
        {
            // A fresh array: a slice would keep the dropped requests reachable.
            auto kept = new Message[](1 + checkedSub(pinStash.length, t.keepFrom));
            kept[0] = pinStash[0];
            kept[1 .. $] = pinStash[t.keepFrom .. $];
            pinStash = kept;
            pinGap = t.gap;
        }
    }

    /// Record `response` as input `id`'s, oldest-first for eviction.
    private void rememberCompleted(string id, string response)
    {
        if (auto old = id in completedInputs) completedBytes = saturatingSub(completedBytes, completedCost(id, *old));
        else completedOrder ~= id;
        completedInputs[id] = response;
        completedBytes += completedCost(id, response);
    }

    /// What one completed entry counts against `completedCap`: its response,
    /// its id (held as a key and in `completedOrder`) and a fixed charge for
    /// the map/order metadata, so even empty responses are bounded.
    private static size_t completedCost(string id, string response) pure nothrow @nogc
    {
        return response.length + 2 * id.length + 64;
    }

    /// Drop the oldest completed responses past `completedCap` (the
    /// newest is always kept); their ids stay redeliverable from the log.
    private void evictCompleted()
    {
        // Without a session log an evicted response could not be read back,
        // and a redelivered input would run (and repeat side effects) again.
        if (log.isNone) return;
        size_t drop;
        while (completedBytes > completedCap && drop + 1 < completedOrder.length)
        {
            auto id = completedOrder[drop++];
            if (auto r = id in completedInputs) completedBytes = saturatingSub(completedBytes, completedCost(id, *r));
            completedInputs.remove(id);
            completedStops.remove(id);
            completedOutcomes.remove(id);
            completedEvicted.add(id);
        }
        // A fresh array: a front slice would keep growing its old block.
        if (drop) completedOrder = completedOrder[drop .. $].dup;
    }

    /// Ask for session titles (`session_titles`): `titleClient` builds a client
    /// for a `provider/model` spec; `titleModel` (null: the session's model).
    bool sessionTitles;
    string titleModel;
    LLMClient delegate(string spec) titleClient;
    private bool[string] titlesRequested;

    /// Read other sessions' logs (`cross_session_history`, issue #271): offer
    /// `sessions_list` and honor the `session` argument of the history tools.
    /// Off, the history tools behave as before and no other log is opened.
    bool crossSessionHistory = true;
    /// Send messages to other sessions (`session_messages`, issue #272):
    /// offer the `session_send` tool. The listener side lives in the prompt
    /// loop (app.d / acp.d); the agent only sends.
    bool messagesOn;
    /// The messaging state the session log records as wanted (issue #336):
    /// differs from `messagesOn` when a listener failed to start. `/restart`
    /// carries this intent over rather than the live state.
    bool messagesWanted;
    /// The current turn was started by a peer message (set by the prompt
    /// loop via `run(..., fromPeer: true)`): the loop guard — its sends are
    /// one hop further along the thread and stop at `maxHops`, so two agents
    /// can't ping-pong forever. Cleared when the next turn starts.
    bool peerTurn;
    /// The hop count (issue #350) of the peer message that started this
    /// turn (the furthest one it read); 0 when no peer message did. A send
    /// from this turn is hop `inputHop + 1`.
    uint inputHop;
    /// The thread (originating contextId) of that peer message, or null.
    string inputThread;
    /// The most hops a message thread may take (`session_messages_max_hops`,
    /// issue #350): a send beyond it is refused, so agents replying to each
    /// other stop instead of running up token cost.
    uint maxHops = 4;
    /// The most messages this session may send one target per hour
    /// (`session_messages_max_per_hour`, issue #350; 0: no cap): the
    /// backstop for loops that start fresh threads.
    uint maxSendsPerHour = 10;
    /// Recent send times (stdTime) per target id, for `maxSendsPerHour`;
    /// pruned to the last hour on every send, so it stays bounded.
    private long[][string] recentSends;

    /// How many send times are recorded for the rate cap; tests check that
    /// an uncapped agent (`maxSendsPerHour == 0`) records none.
    package size_t recordedSendCount() const pure nothrow
    {
        size_t n;
        foreach (v; recentSends) n += v.length;
        return n;
    }
    /// The full session id of the peer that started this turn (issue
    /// #272), persisted with its input; empty for any other input.
    string inputSender;
    /// While the loop echoes a peer's mid-turn steer to the events
    /// (`userMessage`), that peer's full session id; empty otherwise. Lets
    /// the ACP server mark peer input for its client (issue #347).
    string echoSender;

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
        auto deadline = monoNow + max;
        foreach (t; titleThreads)
            while (t.running)
            {
                if (monoNow >= deadline) return false;
                sleepFor(20.msecs);
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
                auto bm = Message.user(input);
                bm.fromSession = inputSender;
                push(bm);
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
            um.fromSession = inputSender;
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
        // The loop's decisions are nano.turn.step's; this performs its
        // effects and feeds what happened back in.
        import nano.claude_hooks : maxStopBlocks;
        auto state = TurnState.start(Limits(maxIterations, headless, maxStopBlocks), continued, truncations);
        // The next event, in a slice: SumType assignment is @system when a
        // member holds a pointer, but appending builds a fresh one.
        Event[] event = [Event(CallDue(control.mode, control.isCancelled))];
        LLMResponse r;
        Exception failure; // what a `Rethrow` re-raises
        MonoTime swStart;
        string loopStop;
        for (;;)
        {
            assert(event.length == 1, "every step ends the turn or asks for the next event");
            auto t = step(state, event[0]);
            state = t.state;
            Event[] next;
            foreach (effect; t.effects)
            {
                // Each effect either answers with the next event, ends the
                // turn (`done`), or does its work and moves on.
                bool done;
                string answer;
                effect.match!(
                    (Next _) { next ~= Event(CallDue(control.mode, control.isCancelled)); },
                    (AskKeepGoing _) { next ~= Event(KeepGoing(askKeepGoing())); },
                    (CallModel c) {
                        if (c.fresh)
                        {
                            // A sub-agent's limit check runs before its
                            // steers drain, so the report reminder reaches
                            // the grace request (nano.subagent.ChildEvents).
                            ev.beforeFreshCall();
                            if (!prepareCall(ev)) { done = true; answer = cancelled(ev); return; }
                            swStart = monoNow;
                        }
                        next ~= callModel(ev, swStart, r, failure);
                    },
                    (Restarting x) {
                        stdErr.writefln("[agent] %s; asking again (%s/%s)", x.message, x.attempt, maxStreamRestarts);
                        ev.responseRestarted();
                    },
                    (LimitOutput l) {
                        learnedMaxOutput = l.cap;
                        stdErr.writefln("[agent] output-limit rejection (%s); retrying with max_tokens=%s", l.message, l.cap);
                    },
                    (CompactForOverflow c) {
                        // A `/model` queued during the call applies to the
                        // compaction and the retry, not the model being left.
                        applyModelRequest();
                        auto learned = c.learned ? c.learned : estimateContextTokens() * 9 / 10;
                        learnedWindow = learned > 1_000 ? learned : 1_000;
                        CompactReport rep;
                        const ok = compact(rep, CompactTrigger.overflow, null, null, some(ev));
                        next ~= Event(Compacted(ok, control.isCancelled));
                    },
                    (Rethrow _) { throw failure; },
                    (Cancel _) { done = true; answer = cancelled(ev); },
                    (ContinueCutOff c) { push(continuationReminder(c.outputTokens)); },
                    (SyncContinuation c) { syncPendingContinuation(c.continued, c.truncations); },
                    (Notice n) { ev.text(false, n.text); },
                    (RunStopHook h) {
                        auto o = hooks.match!(m => m.runStop(h.again), () => HookOutcome.init);
                        next ~= Event(StopHookRan(o.blocked, o.blockReason, control.isCancelled));
                    },
                    (StopBlocked b) {
                        hasReported = false;
                        auto rej = Message.auto_(wrapReminder(b.reason));
                        rej.stopBlocked = true;
                        push(rej);
                        ev.userMessage(b.reason);
                    },
                    (RunTools _) { next ~= runToolCalls(r, ev, loopStop); },
                    (FinishOutcome f) {
                        if (f.loopStopped) reported = Outcome(OutcomeStatus.blocked, loopStop);
                        auto response = reported.response;
                        push(Message.assistant(response, null));
                        ev.text(false, response);
                        ev.assistantMessage(response, null);
                        lastOutcome = reported;
                        hasOutcome = true;
                        hasReported = false;
                        lastStop = StopReason.endTurn;
                        done = true;
                        answer = response;
                    },
                    (Finish f) {
                        lastStop = f.stop;
                        done = true;
                        answer = f.answer;
                    },
                );
                if (done) return answer;
            }
            event = next;
        }
    }

    /// Before a fresh model call: absorb queued steers, fire due timers,
    /// compact at the threshold, and apply queued model and thinking
    /// changes. False if the turn was cancelled meanwhile.
    private bool prepareCall(AgentEvents ev)
    {
        foreach (s; control.takePending)
        {
            auto sm = Message.user(s.text);
            sm.steered = true;
            sm.fromSession = s.sender;
            push(sm);
            echoSender = s.fromPeer ? s.sender : null;
            ev.userMessage(s.text);
            echoSender = null;
            // A peer's steer makes the rest of this turn peer-driven: the
            // loop guard must hold for whatever it asks for.
            if (s.fromPeer)
            {
                peerTurn = true;
                // The furthest hop read this turn governs its replies.
                auto h = s.hop ? s.hop : 1;
                if (h > inputHop) { inputHop = h; inputThread = s.thread; }
                else if (!inputThread.length) inputThread = s.thread;
                // A legacy steer carries no thread: fall back to its sender,
                // as an idle delivery does, so identity is timing-independent.
                if (!inputThread.length) inputThread = s.sender;
            }
            control.absorbed(s);
        }
        fireDueTimers(ev);
        deliverBackground(ev);
        // Publish finished probes first: one can lower the window, which
        // the threshold check below must see.
        collectProbes();
        if (agentCompact)
        {
            // Asked for by the agent (`session_settings compact_now`) during
            // the last reply, so the tool results it waits on are in place.
            agentCompact = false;
            CompactReport rep;
            compact(rep, CompactTrigger.agent, agentCompactHasMode ? &agentCompactMode : null,
                agentCompactFocus.length ? agentCompactFocus : null, some(ev));
            if (control.isCancelled) return false;
        }
        if (overThreshold())
        {
            CompactReport rep;
            compact(rep, CompactTrigger.threshold, null, null, some(ev));
            if (control.isCancelled) return false;
        }
        version (unittest) if (onThresholdChecked !is null) onThresholdChecked();
        // A switch (or a probe collected with it) can lower the window
        // again: recheck before the request goes out. Apply and collect
        // unconditionally first — a probe `applyModelRequest` publishes can
        // shrink the window even when no model request is queued — and
        // forward the events so this compaction notifies like the one above.
        applyModelRequest();
        collectProbes();
        if (overThreshold())
        {
            CompactReport rep;
            compact(rep, CompactTrigger.threshold, null, null, some(ev));
            if (control.isCancelled) return false;
        }
        if (auto level = control.takeThinkingRequest())
        {
            import nano.thinking : sessionSetting, sessionSettingValue;
            // Checked when it was typed, so this can't fail.
            sessionThinking = sessionSetting(level).unwrap("validated when typed");
            // A resume restores the session's thinking level (#297).
            SessionSettings ss;
            ss.thinking = sessionSettingValue(sessionThinking);
            logSettings(ss);
        }
        return true;
    }

    /// One model call: the reply recorded in the conversation (`Replied`), or
    /// how it failed (`CallFailed`, with the exception kept in `failure`).
    private Event callModel(AgentEvents ev, MonoTime swStart, out LLMResponse r, out Exception failure)
    {
        // `/subagents on|off` typed mid-turn: every request, retries
        // included, follows it; sub-agents already running finish.
        if (auto sub = control.takeSubagentsRequest())
        {
            subagentsOn = sub == 1;
            // A resume restores the session's sub-agents switch (#297).
            SessionSettings ss;
            ss.subagents = subagentsOn ? 1 : 0;
            logSettings(ss);
        }
        ChatRequest req;
        req.messages = messages;
        req.tools = offeredTools();
        req.maxTokens = requestMaxTokens();
        auto th = thinking();
        req.thinking = th.request();
        requestThinking = some(shownLevel(th));
        req.vision = vision();
        req.attachmentsDir = attachmentsDir();
        auto tr = temperatureFor(th.anthropicThinkingOn);
        req.temperature = tr.effective;
        ev.generationStart();
        try r = chatCounted(req, (bool t, string s) { ev.text(t, s); }, ev);
        catch (Cancelled e)
        {
            failure = e;
            countAborted(e.usage, ev);
            return Event(CallFailed(Failure.cancelled, e.msg, req.maxTokens, true));
        }
        catch (StreamInterrupted e)
        {
            failure = e;
            countAborted(e.usage, ev);
            return Event(CallFailed(Failure.interrupted, e.msg, req.maxTokens, control.isCancelled));
        }
        catch (Exception e) // classified by nano.turn.step: retried, compacted for, or re-raised
        {
            failure = e;
            return Event(CallFailed(Failure.error, e.msg, req.maxTokens, control.isCancelled));
        }
        // Retried attempts add to the totals but not to the calibration below.
        countRetried(r.retried, ev);
        lastUsage = r.usage;
        recordUsage(r.usage);
        if (r.usage.inputTokens > 0)
        {
            // Anchored at the assistant message about to be pushed. Convert
            // the nonnegative operands separately and sum the sizes with
            // saturating arithmetic: a malformed pair such as long.max + 1
            // would overflow the signed addition before `toSize` runs, and a
            // halt here would crash a completed turn over bookkeeping. The
            // clamped anchor only makes later estimates read high.
            calibLen = messages.length + 1;
            calibTokens = saturatingAdd(toSize(max(0L, r.usage.inputTokens)), toSize(max(0L, r.usage.outputTokens)));
        }
        ev.usage(r.usage);
        auto reply = Message.assistant(r.content, r.toolCalls);
        reply.thinking = r.reasoning;
        reply.thinkingBlocks = r.thinkingBlocks;
        reply.usage = r.usage;
        reply.hasUsage = r.usage != TokenUsage.init;
        reply.durationMs = since(swStart).total!"msecs";
        reply.temperature = tr.describe;
        // Only when a level is sent or set somewhere, so logs without
        // thinking levels stay unchanged.
        if (th.effective != Thinking.init || th.source != ThinkingSource.global)
            reply.thinkingLevel = th.describe;
        const cut = r.stopReason == "length" || r.stopReason == "max_tokens";
        reply.stopReason = r.toolCalls.length ? "tool_use" : cut ? "max_tokens" : "end_turn";
        push(reply);
        if (r.content.length || r.reasoning.length) ev.assistantMessage(r.content, r.reasoning);
        return Event(Replied(r.content, cut, r.toolCalls.length, r.usage.outputTokens, control.hasSteers,
            control.isCancelled));
    }

    /// Run a reply's tool calls, each result pushed in call order. A run of
    /// two or more consecutive read-only calls executes concurrently
    /// (`runConcurrently`); every other call is a barrier that runs alone,
    /// so "read, edit, read" still reads the edit (issue #222). The loop
    /// detector's hard stop sets `loopStop` and skips the rest.
    private Event runToolCalls(const ref LLMResponse r, AgentEvents ev, ref string loopStop)
    {
        loopStop = null;
        // The `agent` calls of each barrier-free stretch of the reply start
        // together (up to the concurrency cap) when the loop reaches the
        // stretch; each result is taken in order below. A child never
        // starts before an earlier mutation, so "agent, edit, agent" has
        // the second child read the edit.
        // Guard first: a failed launch still stops children already started.
        scope (exit) finishSubagents();
        resetSubagents(ev);
        auto calls = r.toolCalls;
        for (size_t i = 0; i < calls.length;)
        {
            if (subagentsOffered && calls[i].name == subToolName && (calls[i].id in subGates) is null
                && loopStop is null)
                launchSubagents(r, i);
            size_t j = i;
            while (j < calls.length && concurrentEligible(calls[j].name)) j++;
            if (j > i + 1 && !control.isCancelled && loopStop is null)
            {
                runConcurrently(r.stopReason, calls[i .. j], ev, loopStop);
                i = j;
                continue;
            }
            auto call = calls[i++];
            ev.toolStart(call);
            CallRun c;
            c.recallBefore = recallState.dup;
            c.notesBefore = recallTurnNotes;
            if (control.isCancelled) c.result = cancelledToolResult;
            else if (loopStop !is null) c.result = loopStoppedToolResult;
            else
            {
                import nano.tools : setSpillDir, spillDirFor;
                // Cut outputs are kept beside a persisted session's log.
                setSpillDir(log.match!(l => spillDirFor(l.path), () => string.init));
                c.result = runTool(call, r.stopReason, c.isError, c.dispatched, c.effectiveArgs);
                c.ran = true;
            }
            finishCall(call, c, ev, loopStop);
        }
        return Event(ToolsRan(loopStop !is null, hasReported, reported.response, control.isCancelled));
    }

    /// Most worker threads one run of read-only calls uses at a time.
    enum maxConcurrentTools = 8;

    /// Whether calls to `name` may run concurrently with their read-only
    /// neighbours: read-only by construction, never prompting. Tools say so
    /// themselves (`Concurrency.readOnly`); of the agent's own, the history
    /// tools and the plan and timer listings qualify. Everything else (bash,
    /// edits, question, report_outcome, plan/timer/memory mutations, unknown
    /// names) is a barrier.
    ///
    /// Thread-safety audit (#222). Worker threads get only a `Job`: a plain
    /// function and immutable text, so the type system rules out shared
    /// agent state. What each job touches: read_file reads the file and
    /// hashes it; the agent records the digest in its `ReadState` afterwards
    /// (`settle`, on this thread). grep/glob walk the tree with per-call
    /// `Ignores`/regexes and rebuild the Read-deny scan from rule text
    /// (`Rule.matches` keeps its compiled copy per thread). The history
    /// tools are barriers (they read results logged by earlier calls). The
    /// spill directory, spill set and truncation are thread-local and used
    /// on this thread only (truncation happens after the run). Stats, the
    /// loop detector, memory recall and the frame UI are touched only here,
    /// in call order. memory_search, plan_show and timer_list run on this
    /// thread while the workers run, so they share nothing with them.
    private bool concurrentEligible(string name)
    {
        if (outcomeTool && name == outcomeToolName) return false;
        // Tool-use hooks are arbitrary commands that may change files, so a
        // call a hook can see keeps its sequential place: a PostToolUse hook
        // on one read must run before the next read observes the tree.
        // Checked before the plan/timer listings so hooked ones are barriers.
        if (hooks.match!(m => m.hasToolHooks(name), () => false)) return false;
        if (planTools && isPlanTool(name)) return name == "plan_show";
        if (timerTools && isTimerTool(name)) return name == "timer_list";
        if (settingsTools && name == settings.toolName) return false;
        // History tools are barriers: they must see the preceding calls'
        // logged results, and history_read's spill bookkeeping is the
        // agent thread's own.
        if (hist.isHistoryTool(name)) return false;
        return tools.readOnly(name);
    }

    /// One call's way through `runToolCalls`.
    private static struct CallRun
    {
        string result;
        bool isError = true;
        /// Reached its handler (see `runTool`).
        bool dispatched;
        JSONValue effectiveArgs;
        /// Admitted and run (or refused) rather than cancelled or loop-stopped.
        bool ran;
        /// Recall state before the call, restored if its result can't be logged.
        typeof(recallState) recallBefore;
        typeof(recallTurnNotes) notesBefore;
    }

    version (unittest)
    {
        /// Test hook: called by a worker right after it reads `afterCancel`.
        static shared void function() @safe workerRecordedHook;
    }

    /// What a worker hands back: the job's result, and whether the turn was
    /// already cancelled when the job finished (decided on the worker, so a
    /// result completed before a cancel keeps its result however late the
    /// agent collects it).
    private static struct WorkerDone
    {
        JobResult result;
        bool afterCancel;
    }

    /// A worker: run the job, then say which call finished.
    private static WorkerDone worker(Job job, size_t index, Chan!size_t finished)
    {
        scope (exit) finished.put(index);
        auto res = runJob(job);
        auto afterCancel = cancelRequested();
        import core.atomic : atomicLoad;
        version (unittest)
            if (auto hook = atomicLoad(workerRecordedHook)) hook();
        return WorkerDone(res, afterCancel);
    }

    /// Run consecutive read-only calls concurrently (issue #222). In call
    /// order, first: each call starts (`toolStart`) and is admitted (plan
    /// mode, permissions, PreToolUse hooks, so a veto never races). Then the
    /// admitted calls run: those a tool can package as a `Job` on worker
    /// threads (at most `maxConcurrentTools` at once, through safeio's
    /// `spawn`), the rest on this thread meanwhile. Last, in call order
    /// again: the tool's `settle`, the PostToolUse hooks, the loop detector,
    /// memory recall, `toolEnd` and the logged result, exactly as one call
    /// at a time would produce them. A cancellation stops launching: a call
    /// that hadn't finished reports the usual interrupted result, and every
    /// worker is joined before this returns, so nothing outlives the turn.
    private void runConcurrently(string stopReason, const(ToolCall)[] calls, AgentEvents ev, ref string loopStop)
    {
        import nano.tools : setSpillDir, spillDirFor;
        setSpillDir(log.match!(l => spillDirFor(l.path), () => string.init));
        auto n = calls.length;
        auto runs = new CallRun[n];
        auto contexts = new string[][n];
        auto admitted = new bool[n];
        auto jobs = new Job[n];
        auto offloaded = new bool[n];
        auto finished = new bool[n];
        auto results = new JobResult[n];
        // Calls never admitted because a cancel arrived first: no hooks,
        // reported as interrupted.
        auto skipped = new bool[n];
        foreach (k, ref call; calls)
        {
            ev.toolStart(call);
            if (control.isCancelled)
            {
                skipped[k] = true;
                continue;
            }
            admitted[k] = admit(call, stopReason, runs[k].result, runs[k].effectiveArgs, contexts[k]);
            if (!admitted[k]) continue;
            if (tools.has(call.name))
            {
                auto mode = tools.concurrency(call.name);
                // Packaging only copies text: the tool's own checks run in the job.
                if (mode.offload !is null)
                {
                    // Packaging can fail (e.g. a deleted cwd while building
                    // the Read-deny scan): that call fails like a sequential
                    // one would, rather than unwinding the whole batch.
                    try
                    {
                        jobs[k] = mode.offload(runs[k].effectiveArgs);
                        offloaded[k] = true;
                    }
                    catch (Exception e)
                    {
                        results[k] = JobResult(e.msg, true, true);
                        finished[k] = true;
                    }
                }
            }
        }
        // The workers, launched in call order while not cancelled.
        auto done = Chan!size_t.make;
        auto handles = new Join!WorkerDone[n];
        size_t next, running;
        // Every started worker is joined on every exit path (a failed spawn
        // or a throwing in-memory tool included), so none outlives the turn.
        scope (failure)
            while (running)
            {
                size_t k;
                done.take(k);
                // Counted off before the join: a join that rethrows has still
                // consumed this worker's notification.
                running--;
                // `runJob` turns a job's exception into a result, so this
                // only waits.
                handles[k].join();
            }
        void launch()
        {
            for (; running < maxConcurrentTools && next < n && !control.isCancelled; next++)
                if (offloaded[next] && !finished[next])
                {
                    handles[next] = spawn(&worker, jobs[next], next, done);
                    running++;
                }
        }
        launch();
        // In-memory read-only tools run here while the workers run.
        foreach (k, ref call; calls)
            if (admitted[k] && !offloaded[k] && !finished[k] && !control.isCancelled)
            {
                bool isError;
                results[k].text = execute(call, runs[k].effectiveArgs, isError);
                results[k].error = isError;
                // Finished after a cancellation (the worker rule): interrupted.
                finished[k] = !control.isCancelled;
            }
        while (running)
        {
            size_t k;
            done.take(k);
            // Before the join, so a rethrowing join leaves the failure guard
            // waiting only for notifications still to come.
            running--;
            auto w = handles[k].join();
            results[k] = w.result;
            // Finished after a cancellation: reported as interrupted.
            finished[k] = !w.afterCancel;
            launch();
        }
        foreach (k, ref call; calls)
        {
            auto c = &runs[k];
            c.recallBefore = recallState.dup;
            c.notesBefore = recallTurnNotes;
            // Cancellation outranks a loop stop for a call that never ran:
            // an interrupted call reports the interrupted result even when an
            // earlier finished call tripped the loop detector.
            // A loop stop outranks a refusal, as in the sequential path.
            if (skipped[k] || (admitted[k] && !finished[k])) c.result = cancelledToolResult;
            else if (loopStop !is null) c.result = loopStoppedToolResult;
            else if (!admitted[k]) c.ran = true;
            else
            {
                auto res = results[k];
                if (offloaded[k] && !res.error)
                    if (auto settle = tools.concurrency(call.name).settle) settle(res);
                c.ran = c.dispatched = true;
                c.isError = res.error;
                auto text = res.crashed ? format("%s failed: %s", call.name, res.text) : res.text;
                c.result = afterTool(call, c.effectiveArgs, text, contexts[k]);
            }
            finishCall(call, *c, ev, loopStop);
        }
    }

    /// A call's result after it ran (truncated, annotated, the loop detector
    /// consulted), shown (`toolEnd`) and logged. `c.ran` false: cancelled or
    /// loop-stopped, logged as it is.
    private void finishCall(const ref ToolCall call, ref CallRun c, AgentEvents ev, ref string loopStop)
    {
        string result = c.result;
        bool isError = c.isError;
        bool dispatched = c.dispatched;
        auto effectiveArgs = c.effectiveArgs;
        Attachment[] attachments;
        if (c.ran)
        {
            {
                import nano.tools : truncateOutput;
                // bash, read_file and history_read bound their own output.
                if (call.name != "bash" && call.name != "read_file" && call.name != hist.readTool
                    && call.name != "load_skill")
                    result = truncateOutput(result, toolOutputLimit,
                        format("tool-%s-%s", safeName(call.id), safeName(call.name)));
            }
            // A successful edit marks the tree unchecked; a bash call
            // that started (even one exiting non-zero) is the check.
            auto patched = call.name == "apply_patch" && dispatched ? patchTouches(effectiveArgs, isError) : null;
            if (!isError && (call.name == "write_file" || call.name == "edit_file" || patched.length)) editsSinceCheck = true;
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
            foreach (p; patched)
            {
                import std.file : getcwd;
                instructions.ifSome((ProjectInstructions pi) {
                    if (auto nested = pi.nestedFor(p, getcwd())) result ~= nested;
                });
            }
            // Memory recall (Rust #167): a note for each memory whose
            // anchors appear in this call's arguments and whose full
            // text is not already in context. Only calls that ran.
            if (dispatched)
                foreach (note; recallMemories(call.name, withPaths(effectiveArgs, patched), !isError, result))
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
        if (auto sub = call.id in subLogs) msg.subLog = *sub;
        // Commit this call's recall changes only once the result
        // carrying their notes is durable: a failed append rolls them
        // back, so a resume never treats unseen notes as seen.
        try push(msg);
        catch (Exception e)
        {
            recallState = c.recallBefore;
            recallTurnNotes = c.notesBefore;
            throw e;
        }
        if (recallState != c.recallBefore) recallChanged();
    }

    /// System reminders for one finished call: plan/memory nudges and the
    /// loop detector, whose hard stop sets `loopStop`. Returns text to append.
    private string remind(const ref ToolCall call, bool ok, string result, ref string loopStop)
    {
        if ((planTools && isPlanTool(call.name)) || (outcomeTool && call.name == outcomeToolName)
            || (timerTools && isTimerTool(call.name)) || (settingsTools && call.name == settings.toolName))
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
            extra ~= "\n\n" ~ wrap(loopHardStopNote);
            loopStop = v.text;
        }
        return extra;
    }

    /// The context window and where it came from.
    size_t contextWindow() pure const { string _; return contextWindow(_); }

    size_t contextWindow(out string source) pure const
    {
        size_t w;
        if (configuredWindow) { w = configuredWindow; source = configuredWindowSource; }
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
        // Mirror the wire plan: only the newest `imageSlots` images still
        // intact on disk are sent as images, every other one as a placeholder.
        auto slots = imageSlots;
        auto avail = availability();
        auto part(size_t from, size_t to) { return avail is null ? null : avail[from .. to]; }
        calibrated = calibLen && calibLen <= messages.length;
        if (calibrated)
        {
            // The anchor charged the prefix's newest images in full. A newer
            // image after it takes a slot and turns one of those into a
            // placeholder; keeping the anchor would charge both, so recompute.
            auto prefix = ctx.availableCount(messages[0 .. calibLen], part(0, calibLen));
            auto suffix = ctx.availableCount(messages[calibLen .. $], part(calibLen, messages.length));
            calibrated = min(prefix, slots) == min(prefix, saturatingSub(slots, suffix));
            if (calibrated) return saturatingAdd(calibTokens, ctx.messagesTokens(messages[calibLen .. $], slots, part(calibLen, messages.length)));
        }
        size_t tools_;
        foreach (d; offeredTools())
            tools_ += ctx.textTokens(d.name) + ctx.textTokens(d.description) + ctx.textTokens(() { return d.parameters.jsonText; }());
        return ctx.messagesTokens(messages, slots, avail) + tools_;
    }

    /// Whether each attachment of each message is intact on disk, as
    /// `ChatRequest.attachmentPlan` decides for the wire. Without vision every
    /// attachment is a placeholder anyway, so the files aren't read.
    private const(bool[])[] availability()
    {
        import nano.attachment : exists;
        if (!imageSlots) return null;
        auto dir = attachmentsDir();
        auto out_ = new bool[][](messages.length);
        foreach (i, ref m; messages)
        {
            out_[i] = new bool[](m.attachments.length);
            foreach (j, ref a; m.attachments) out_[i][j] = dir.length && exists(dir, a);
        }
        return out_;
    }

    size_t estimateContextTokens() { bool _; return estimateContextTokens(_); }

    private size_t outputBase() pure const { return toSize(effectiveMaxTokens()); }

    /// The output budget before the context-window clamp: `max_tokens` when
    /// configured, else the model's published cap, a known cap for the model
    /// name, or the large default; never above a cap learned from an error.
    long effectiveMaxTokens() pure const
    {
        long base = maxTokens > 0 ? maxTokens
            : capabilities.maxOutput ? clampToLong(capabilities.maxOutput)
            : ctx.outputLimitForModel(client.modelName) ? clampToLong(ctx.outputLimitForModel(client.modelName))
            : ctx.defaultMaxOutputTokens;
        return learnedMaxOutput > 0 && learnedMaxOutput < base ? learnedMaxOutput : base;
    }

    /// The endpoint's prompt-only cap is in force (Copilot `max_prompt_tokens`).
    private bool promptCapped() pure const
    {
        return !configuredWindow && capabilities.promptCap && capabilities.window
            && (!learnedWindow || learnedWindow >= capabilities.window);
    }

    /// The combined prompt + output window to enforce alongside a prompt cap (0 = none).
    private size_t combinedWindow() pure const
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
    void resetIdleCompaction() pure
    {
        idleGate.reset();
        idleCached = false;
    }

    private bool idleCompactDueAt(size_t tokens) pure
    {
        if (!idleCompact || !overThresholdAt(tokens)) return false;
        auto window = contextWindow();
        auto threshold = effectiveAutoCompactThreshold;
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
        if (applyModelRequest())
        {
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
    bool overThresholdAt(size_t tokens) pure
    {
        if (!autoCompact) return false;
        auto threshold = effectiveAutoCompactThreshold;
        auto window = contextWindow();
        auto reserved = saturatingAdd(outputBase < ctx.minOutputReserve ? outputBase : ctx.minOutputReserve, ctx.outputMargin(window));
        double limit = window * threshold;
        auto headroom = saturatingSub(window, reserved);
        if (headroom && headroom < limit) limit = headroom;
        return tokens > limit && tokens > saturatingAdd(compactFloor, window / 10);
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

    /// The API the live client speaks (Rust takes `kind()` from the client,
    /// so a config edit whose rebuild failed cannot change it); a client
    /// that names none (a test double) follows no provider's rules.
    private ProviderKind providerKind()
    {
        if (auto k = cast(KindedClient) client.nonNull) return k.kind;
        return ProviderKind.mock;
    }

    /// Ask the endpoint what the current model supports (at startup or a
    /// direct model change), waiting for the answer. A configured window wins,
    /// so only the thinking half runs then. Any background probe in flight is
    /// superseded.
    void refreshCapabilities()
    {
        probe.beginDetect();
        // The switch supersedes any background probe: stop its HTTP calls now
        // (it stays tracked until it exits and is joined).
        if (probing) pendingProbe.abort.abort();
        auto caps = probeOf(client.nonNull, !configuredWindow);
        if (configuredWindow) probe.storeWithoutWindow(caps);
        else probe.store(caps);
    }

    /// What `c` reports (nothing for a client that can't probe, or on failure).
    private static Capabilities probeOf(LLMClient c, bool window)
    {
        Capabilities caps;
        try
            if (auto p = cast(CapabilityProbe) c) caps = p.probeCapabilities(window);
        catch (Exception) {} // a failed probe means "unknown": the fallbacks stand
        return caps;
    }

    /// Builds a fresh client for a `provider/model` spec, for a background
    /// probe after a mid-turn switch (null: mid-turn switches don't probe).
    LLMClient delegate(string spec) probeClient;

    /// A background probe: the generation it publishes under, its thread, the
    /// abort flag its HTTP calls poll (set when a later switch supersedes it),
    /// and when it started (for `probeDeadline`).
    private static struct PendingProbe
    {
        ulong generation;
        Join!(Isolated!ProbeOutcome) thread;
        SubAbort abort;
        MonoTime started;
    }
    /// What a probe thread returns: the capabilities, and whether it ran
    /// past its own deadline or was cancelled (then the result is dropped).
    private static struct ProbeOutcome
    {
        Capabilities caps;
        bool late;
    }
    /// The one probe thread (running, or finished and not yet joined). A
    /// superseded probe stays here, cancelled, until it finishes and is
    /// joined, so at most one probe thread is ever alive.
    private PendingProbe pendingProbe;
    /// Whether `pendingProbe` holds a thread not yet joined or dropped.
    private bool probing;
    /// A generation that wants a probe but couldn't start one because a
    /// probe thread was still alive; started once that thread is gone.
    private Option!ulong wantedProbe;

    /// How long a background probe may run before it is abandoned: past the
    /// deadline it is cancelled (its HTTP calls bail at the next poll) and
    /// dropped, and the fallback window stands. Bounds the life of a probe
    /// against a hanging provider (nano-coder#270).
    Duration probeDeadline = 30.seconds;

    /// Probe the current client on a background thread (after a mid-turn
    /// switch), so the next model call goes out at once, with the fallback
    /// window, until `collectProbes` publishes the result.
    ///
    /// At most one probe thread runs at a time: a switch that finds one still
    /// running cancels it (it is stale by construction) and records the want
    /// instead of spawning; `collectProbes` starts the wanted generation's
    /// probe once the thread is joined. Rapid switches cost one thread, not
    /// one per switch.
    private void startBackgroundProbe()
    {
        auto generation = probe.beginDetect();
        if (probeClient is null) return;
        wantedProbe = some(generation);
        collectProbes();
    }

    /// Start the background probe for `generation` (none may be alive).
    private void spawnProbe(ulong generation)
    {
        LLMClient c;
        try c = probeClient(client.providerName ~ "/" ~ client.modelName);
        catch (Exception) return; // the probe is optional: the fallbacks stand
        auto abort = SubAbort.make;
        // Isolated: `probeClient` builds a new client from a resolved
        // (deep-copied) config, and only the probe thread keeps it.
        pendingProbe = PendingProbe(generation,
            spawnDaemon(&runProbe, Isolated!LLMClient.assumeIsolated(c), configuredWindow == 0, abort, probeDeadline),
            abort, monoNow);
        probing = true;
    }

    /// Runs on the probe thread: what `client` reports (nothing on failure).
    /// The abort cell is this thread's cancellation scope, so a superseded
    /// probe's HTTP calls bail at their next poll; the thread also sets its
    /// own deadline, so a probe past `deadline` bails even while the agent
    /// is blocked and not collecting. A late or cancelled result is flagged.
    private static Isolated!ProbeOutcome runProbe(Isolated!LLMClient client, bool window, SubAbort abort,
        Duration deadline)
    {
        import nano.control : setCancelDeadline, pastCancelDeadline;
        pushCancelScope(abort.ptr);
        scope (exit) popCancelScope();
        setCancelDeadline(monoNow + deadline);
        scope (exit) setCancelDeadline(MonoTime.max);
        auto caps = probeOf(client.unwrap, window);
        const late = abort.aborted || pastCancelDeadline();
        // Isolated: built on this thread, and only the result box keeps it.
        return Isolated!ProbeOutcome.assumeIsolated(ProbeOutcome(caps, late));
    }

    /// Join the probe thread if it finished, publishing its result when its
    /// generation is still live and it beat `probeDeadline` (anything else is
    /// discarded). A running probe that is stale or past the deadline is
    /// cancelled but stays tracked until it exits and is joined, so a probe
    /// that ignores cancellation still blocks new ones: at most one probe
    /// thread is ever alive. With no thread alive, the wanted generation's
    /// probe starts. Whether a result was published.
    bool collectProbes()
    {
        bool published;
        if (probing)
        {
            alias p = pendingProbe;
            if (p.thread.running)
            {
                // Stale: its result can never publish, so stop its HTTP calls.
                if (!probe.isCurrent(p.generation)) p.abort.abort();
                // Past the deadline: cancel it; its result will be dropped.
                if (since(p.started) >= probeDeadline) p.abort.abort();
            }
            else
            {
                auto outcome = p.thread.join().unwrap;
                // Lateness is judged by when the probe finished (the worker
                // flags it), not when it is collected: an on-time result
                // collected after a long model call still publishes, and a
                // cancel that lands after the outcome was final can't expire it.
                const late = outcome.late;
                if (!late)
                    published = probe.publishIfCurrent(p.generation, outcome.caps, configuredWindow == 0);
                probing = false;
                pendingProbe = PendingProbe.init;
            }
        }
        const alive = probing;
        if (!alive && probeClient !is null)
            wantedProbe.ifSome((ref ulong g) {
                if (probe.isCurrent(g)) spawnProbe(g);
            });
        if (!alive) wantedProbe = none;
        return published;
    }

    /// Wait up to `max` for the live background probe (a superseded one is
    /// joined first, then the wanted one is started and waited for), then
    /// publish; false if it still runs.
    bool settleProbes(Duration max)
    {
        import core.time : msecs;
        auto deadline = monoNow + max;
        for (;;)
        {
            collectProbes();
            if (!probing) return true;
            if (monoNow >= deadline) return false;
            sleepFor(5.msecs);
        }
    }

    /// Test-only: how many probe threads are tracked (at most one).
    version (unittest) size_t probesInFlight()
    {
        return probing ? 1 : 0;
    }

    /// Test-only: whether the tracked probe thread has exited (its outcome is
    /// final), without collecting or publishing it, so a test can order fake
    /// time after the worker's own lateness verdict.
    version (unittest) bool probeThreadExited()
    {
        return !probing || !pendingProbe.thread.running;
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
            if (maxTok <= 0) maxTok = imported!"nano.thinking".anthropicDefaultMaxTokens;
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

    /// The thinking level the status line shows: what the running turn's
    /// request sent, else what the next one would (empty: none sent, as for
    /// a level the provider drops).
    string shownThinking() { return requestThinking.orElse(shownLevel(thinking())); }

    private static string shownLevel(const ThinkingResolved th) pure
    {
        import nano.thinking : wireValue;
        auto w = wireValue(th);
        return w.isNull ? null : w.str;
    }

    /// The temperature the current model is sent, and why.
    temp.Resolved temperatureNow() { return temperatureFor(thinking().anthropicThinkingOn); }

    /// The warnings a resumed session's restored settings bring (issue
    /// #297), as `/model` (`model`: the model was switched) and `/thinking`
    /// (`thinkingLevel`: a level was restored) would show them, so a restored
    /// value the model does not support is not applied silently.
    string[] restoreWarnings(bool model, bool thinkingLevel)
    {
        string[] w;
        if (model)
            if (auto t = temperatureNow.warning) w ~= t;
        if (model || thinkingLevel)
            if (auto t = thinking().warning) w ~= t;
        return w;
    }

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
    /// its references stay valid), else a temp dir of this agent's own (two
    /// agents in one process don't share, or clean up, each other's images).
    string attachmentsDir()
    {
        import std.path : buildPath, dirName;
        import std.file : tempDir;
        import std.process : thisProcessID;
        import std.random : uniform;
        string dir = log.match!(l => l.path.length ? buildPath(dirName(l.path), l.id ~ ".attachments") : null, () => string.init);
        if (dir.length) return dir;
        if (!tempAttachments.length)
            tempAttachments = buildPath(tempDir, format("nano-coder-attachments-%s-%08x", thisProcessID, uniform!uint));
        return tempAttachments;
    }
    private string tempAttachments; /// see attachmentsDir

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
            auto usedC = saturatingAdd(estimateContextTokens(), ctx.outputMargin(combined));
            long roomC = clampToLong(saturatingSub(combined, usedC));
            auto c = maxTokens < roomC ? maxTokens : roomC;
            return c < 1 ? 1 : c;
        }
        auto window = contextWindow();
        auto used = saturatingAdd(estimateContextTokens(), ctx.outputMargin(window));
        long room = clampToLong(saturatingSub(window, used));
        auto n = maxTokens < room ? maxTokens : room;
        return n < 1 ? 1 : n;
    }

    /// Summarize older messages into one, keeping recent messages verbatim.
    /// `mode` overrides `compactionMode` (null: the configured one); `focus`
    /// steers the summary. Returns false when there is nothing to compact.
    bool compact(out CompactReport report, CompactTrigger trigger = CompactTrigger.manual,
            scope const(ctx.CompactionMode)* mode = null, string focus = null, Option!AgentEvents ev = none)
    {
        import std.algorithm : canFind;
        ctx.CompactionMode m = mode is null ? compactionMode : *mode;
        // Smart compaction points into the session log; without one it is standard.
        if (log.isNone) m = ctx.CompactionMode.standard;
        bool smart = ctx.citesHistory(m);
        auto window = contextWindow();
        size_t bodyStart = messages.length && messages[0].role == Role.system ? 1 : 0;
        auto len = messages.length;
        auto avail = availability();
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
            if (ctx.messagesTokens(messages[b .. $], imageSlots, avail is null ? null : avail[b .. len]) > keepBudget) break;
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

        long budget;
        // The output cap an output-cap rejection taught us (0: none yet).
        // Every request clamps to it, so a window or maxOutput change
        // published between the rejection and the retry cannot raise the
        // retry above what the server just refused.
        long learnedCap;
        string summary, fallback;
        bool truncated, retried;
        size_t drops;
        TokenUsage summaryUsage;
        long summaryMs = -1;
        if (m == ctx.CompactionMode.extract)
        {
            // Built in code: no model call, so no usage, retry or fallback.
            import nano.extract : extractSummary;
            const swStart = monoNow;
            summary = ctx.smartSummaryPrefix ~ "\n" ~ extractSummary(summarized) ~ "\n\n" ~ ctx.smartSummaryNote(first, last);
            summaryMs = since(swStart).total!"msecs";
        }
        else for (;;)
        {
            // Every compaction (manual, threshold, overflow, idle) and its
            // retry summarizes on the model the user chose: a `/model` still
            // queued applies first. A cancel pending now stops before the
            // call (callers reset the control for a manual run).
            applyModelRequest();
            if (control.isCancelled) return false;
            // The switch, or a probe it collected, can change the window:
            // size the summary for the model that will run it.
            // Recompute before every request (a probe can change the
            // window or the max output alone), then apply the learned cap.
            if (auto now = contextWindow()) window = now;
            budget = ctx.summaryOutputBudget(window, toLong(outputBase));
            if (learnedCap && learnedCap < budget) budget = learnedCap;
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
                const swStart = monoNow;
                // A compaction is a model call too: a sub-agent's budget
                // counts it (its turn cap and token cap), so emit the same
                // events a turn's call does.
                foreach (e; ev) e.summaryStart();
                auto r = chatCounted(req, (bool, string) {}, ev);
                summaryMs = since(swStart).total!"msecs";
                countRetried(r.retried, ev);
                summaryUsage = r.usage;
                recordUsage(r.usage);
                foreach (e; ev) e.usage(r.usage);
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
            catch (Cancelled e)
            {
                countAborted(e.usage, ev);
                return false;
            }
            catch (StreamInterrupted e)
            {
                countAborted(e.usage, ev);
                // A dropped summary stream is asked again, as a turn's is,
                // before history is dropped for want of a summary.
                if (control.isCancelled) return false;
                if (++drops <= maxStreamRestarts)
                {
                    stdErr.writefln("[agent] %s; asking for the summary again (%s/%s)", e.msg, drops, maxStreamRestarts);
                    continue;
                }
                fallback = e.msg;
                break;
            }
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
                    if (learned < budget) { learnedCap = learned; continue; }
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
            if (auto pinned = ctx.pinnedUserRequests(pinStash, summarized, smart, window, pinGap))
                summary ~= "\n\n" ~ pinned;
        // The requests this compaction adds to the pinned block (the stash so
        // far is their base): the log records only these, so a session holds
        // each request once instead of restating the whole stash (issue #205).
        // The compaction's in-memory changes commit only when the replace
        // record is persisted: a failed `l.replace` rolls them all back, so
        // a later successful compaction never writes a delta whose base
        // counts requests no log record holds (resume would lose them).
        auto savedMessages = messages;
        auto savedPinStash = pinStash;
        auto savedReplayStash = replayStash;
        auto savedReplayStashLog = replayStashLog;
        auto savedClippedLines = clippedLines.dup;
        auto savedReplayRestated = replayRestated;
        auto savedPending = pending;
        auto savedCalibLen = calibLen;
        // The rollback covers only the mutation-and-persistence transaction:
        // once `l.replace` has persisted the compacted conversation the log
        // holds the replacement, so a later failure (reporting, notification)
        // must not revert the live state away from what the log records.
        bool persisted;
        scope (failure)
            if (!persisted)
            {
                messages = savedMessages;
                pinStash = savedPinStash;
                replayStash = savedReplayStash;
                replayStashLog = savedReplayStashLog;
                clippedLines = savedClippedLines;
                replayRestated = savedReplayRestated;
                pending = savedPending;
                calibLen = savedCalibLen;
            }
        // A full restatement (no base) after a restore dropped legacy entries.
        auto pinnedBase = pinStashRestate ? Option!size_t.init : some(pinStash.length + pinGap.count);
        Message[] pinnedNew = pinStashRestate ? pinStash.dup : null;
        foreach (ref x; summarized)
            if (ctx.isUserRequest(x)) { pinStash ~= x; pinnedNew ~= x; }

        // The newly folded real turns for the replay stash. On a repeated
        // compaction the first folded message is the previous summary, whose
        // turns are already stashed, and a previous restatement is dropped.
        immutable extendsStash = replayStash.length > 0;
        Message[] folded;
        foreach (i, ref x; summarized)
        {
            if (extendsStash && i == 0) continue;
            if (extendsStash && replayRestated.match!(r => r == bodyStart + i, () => false)) continue;
            folded ~= x;
        }

        Message[] next = messages[0 .. bodyStart].dup;
        next ~= Message.user(summary);
        next[$ - 1].timestamp = nowStamp();
        // The summary request's cost, persisted with the replace record.
        next[$ - 1].usage = summaryUsage;
        next[$ - 1].hasUsage = summaryUsage != TokenUsage.init;
        if (summaryMs >= 0) next[$ - 1].durationMs = summaryMs;
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
                if (x.role == Role.tool)
                    foreach (c; ctx.clippedContent(x, clipTo))
                    {
                        if (x.logLine && c != x.content) clippedLines[x.logLine] = true;
                        x.content = smart && x.logLine
                            ? c ~ format("\n[clipped at compaction; history_read #%s has it whole]", x.logLine) : c;
                    }
        }
        messages = next;
        calibLen = 0;
        size_t stashBase = replayStash.length;
        // A copy: `folded` is persisted whole below.
        replayStash = extendsStash ? replayStash ~ folded : folded.dup;
        {
            // The live log holds the folded turns: keep only references to
            // large tool outputs (`replayMessages` reads them back). Without
            // a log nothing can replay them (a replay needs a resumed or
            // loaded session), so they are dropped.
            // The reference is the log itself, not its path: a recovery can
            // move the writer to a new path after this, and the replay must
            // follow it rather than read a foreign file at the stale path.
            auto srcs = extendsStash ? replayStashLog.dup : null;
            srcs.length = stashBase;
            foreach (ref x; replayStash[stashBase .. $])
            {
                // Without a log only a tool result is dropped (a reply's text
                // is the transcript; it has nowhere to be read back from).
                bool slim = stashSlimmable(x) && (log.isNone ? x.role == Role.tool
                    : x.logLine > restoredLineFloor && x.logLine !in clippedLines);
                srcs ~= slim ? log : Option!SessionLog.init;
                if (slim) slimMessage(x);
            }
            replayStashLog = srcs;
            log.ifSome((SessionLog l) @safe {
                bool held;
                foreach (s; stashRefLogs) held |= s is l;
                if (!held) stashRefLogs ~= l;
            });
        }
        replayRestated = replayStash.length && hasPending && pending.position < split
            ? some(pendingPos) : Option!size_t.init;
        if (hasPending)
        {
            pending.position = pendingPos;
            pending.hasBase = true;
            pending.base = messages.length;
        }
        log.ifSome((SessionLog l) {
            import std.conv : to;
            l.replace(messages, first, last, ctx.modeName(m), client.providerName ~ "/" ~ client.modelName, pinnedNew,
                hasPending ? &pending : null, folded, extendsStash ? some(stashBase) : Option!size_t.init, replayRestated,
                pinnedBase, trigger.to!string);
        });
        // The replace record is durable: the live state now matches the log,
        // so nothing past this point may roll it back.
        persisted = true;
        pinStashRestate = false;
        // Bound the stash once the log holds it in full (issue #312).
        trimPins(window);
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
        historyAvailable = historyHintPending = ctx.citesHistory(m);
        if (onCompacted !is null) onCompacted(report);
        return true;
    }

    /// Count an aborted request: the usage the provider reported before the
    /// abort when there is any, else one more request left uncounted (no
    /// estimate; issue #340).
    private void countAborted(E)(TokenUsage u, E ev)
    {
        if (hasUsage(u))
        {
            recordUsage(u);
            static if (is(E : AgentEvents)) ev.usage(u);
            else foreach (e; ev) e.usage(u);
        }
        else uncountedRequests++;
    }

    /// `client.chat`, first counting what retried stream attempts cost when
    /// the request fails, whatever the failure (issue #340); the failure is
    /// rethrown unchanged otherwise, for the caller to classify.
    private LLMResponse chatCounted(E)(ref ChatRequest req, StreamSink sink, E ev)
    {
        try return client.chat(req, sink);
        catch (SpendingException e)
        {
            countRetried(e.retried, ev);
            e.retried = RetrySpend.init;
            throw e;
        }
    }

    /// Count the stream attempts dropped and retried before a request's
    /// final attempt: their reported usage, plus one uncounted request per
    /// attempt that reported none (issue #340).
    private void countRetried(E)(RetrySpend spent, E ev)
    {
        if (hasUsage(spent.usage))
        {
            recordUsage(spent.usage);
            static if (is(E : AgentEvents)) ev.usage(spent.usage);
            else foreach (e; ev) e.usage(spent.usage);
        }
        uncountedRequests += spent.uncounted;
    }

    private void recordUsage(TokenUsage u) pure
    {
        sessionInputTokens += u.inputTokens;
        sessionOutputTokens += u.outputTokens;
        if (u.hasAic)
        {
            hasSessionAic = true;
            sessionAic += u.aic;
            aicReports++;
        }
    }

    /// Zero the per-session totals (tokens, credits, compactions), as a new
    /// or resumed session starts counting from scratch.
    void resetSessionCounters() pure
    {
        sessionInputTokens = sessionOutputTokens = 0;
        hasSessionAic = false;
        sessionAic = 0;
        aicReports = 0;
        uncountedRequests = 0;
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
        string[] context;
        string refused;
        if (!admit(call, stopReason, refused, effectiveArgs, context)) return refused;
        auto args = effectiveArgs;
        // apply_patch: each touched path also passes the hooks as a direct
        // edit of it would (the policy already checked every path).
        // The per-path hook inputs are built once, before the patch runs, from
        // a snapshot of every touched path taken first: a move deletes its
        // source, so rebuilding them afterwards would lose the content the
        // post-hooks should see. The tool then commits only if it stages from
        // exactly that snapshot, so it writes the content the hooks approved
        // and an edit made while they ran fails the call.
        PatchEdit[] patchInputs;
        PatchSnapshot[] originals;
        if (call.name == "apply_patch")
        {
            originals = patchOriginalsOf(args);
            patchInputs = patchEdits(args, true, originals);
            if (auto deny = patchPathHooks(call, patchInputs, context)) return withContext(deny, context);
            if (auto d = "dry_run" in args)
                if (d.type == JSONType.true_) { patchInputs = null; originals = null; }
        }
        dispatched = true;
        auto out_ = execute(call, args, isError, originals);
        return afterTool(call, args, out_, context, isError, patchInputs);
    }

    /// Before a call runs: its arguments, the tool, plan mode, the permission
    /// policy and the PreToolUse hooks. False with the refusal in `refused`;
    /// true with the arguments to run with (after any hook rewrite) and the
    /// hooks' context.
    private bool admit(const ref ToolCall call, string stopReason, out string refused, out JSONValue args,
        ref string[] context)
    {
        if (auto e = call.rawArgumentsError(stopReason)) { refused = e; return false; }
        bool isPlan = planTools && isPlanTool(call.name);
        bool isOutcome = outcomeTool && call.name == outcomeToolName;
        bool isHistory = (historyEnabled && hist.isHistoryTool(call.name))
            || (sessionsOffered && call.name == hist.sessionsTool);
        bool isTimer = timerTools && isTimerTool(call.name);
        bool isAgent = subagentsOffered && call.name == subToolName;
        bool isSubCtl = subagentsOffered && isSubControlTool(call.name);
        bool isSend = messagesOn && log.isSome && call.name == peers.sendTool;
        bool isSettings = settingsTools && call.name == settings.toolName;
        // An `agent` call was checked when its reply's sub-agents launched.
        if (isAgent)
            if (auto gate = call.id in subGates)
            {
                if (gate.deny !is null) { refused = gate.deny; return false; }
                args = gate.args;
                context ~= gate.context;
                return true;
            }
        if (!isPlan && !isOutcome && !isHistory && !isTimer && !isAgent && !isSubCtl && !isSend && !isSettings && !tools.has(call.name))
        {
            refused = format("Tool '%s' not found. Available: %s", call.name, toolNames());
            return false;
        }
        // Backstop for a call already in flight when plan mode was switched on.
        if (control.mode == AgentMode.plan && !planAllows(call.name))
        {
            refused = format("%s is disabled in plan mode (read-only)", call.name);
            return false;
        }
        // An unverifiable shell loop never prompts: the policy allows it
        // under the OS sandbox and blocks it without one (Rust #171).
        auto permissionDeny = policy.decide(call.name, call.arguments).match!(
            (PermAllow _) => string.init,
            (PermDeny d) => d.message,
        );
        if (permissionDeny !is null) { refused = permissionDeny; return false; }
        // PreToolUse hooks run after the permission check, before the tool:
        // they can deny the call, rewrite its input, or add context.
        args = call.arguments;
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
            if (deny !is null) { refused = withContext(deny, context); return false; }
        }
        return true;
    }

    /// Run an admitted call's handler on this thread.
    private string execute(const ref ToolCall call, JSONValue args, out bool isError,
        PatchSnapshot[] originals = null)
    {
        isError = true;
        bool isPlan = planTools && isPlanTool(call.name);
        bool isOutcome = outcomeTool && call.name == outcomeToolName;
        bool isHistory = (historyEnabled && hist.isHistoryTool(call.name))
            || (sessionsOffered && call.name == hist.sessionsTool);
        bool isTimer = timerTools && isTimerTool(call.name);
        bool isAgent = subagentsOffered && call.name == subToolName;
        bool isSend = messagesOn && call.name == peers.sendTool;
        string out_;
        try
        {
            if (isSend) out_ = runSessionSend(args);
            else if (isAgent) out_ = runSubagent(call, call.id in subGates);
            else if (subagentsOffered && isSubControlTool(call.name)) out_ = runSubControl(call.name, args);
            else if (settingsTools && call.name == settings.toolName) out_ = runSessionSettings(args);
            else if (isOutcome)
            {
                auto o = Outcome.fromArgs(args).orThrow!(e => new OutcomeError(e));
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
                auto ownLog = log.unwrap("history tools are offered only with a session log");
                turnHistoryCalls++;
                if (call.name == hist.sessionsTool)
                {
                    if (!crossSessionHistory)
                        throw new hist.HistoryError("sessions_list is disabled (cross_session_history = false)");
                    import std.file : getcwd;
                    out_ = cross.listResult(policy, sessionDirOf(ownLog), getcwd(), args);
                }
                else
                {
                    auto logPath = ownLog.path;
                    if (auto denied = resolveSessionArg(args, ownLog, logPath))
                        throw new hist.HistoryError(denied);
                    out_ = call.name == hist.searchTool ? hist.search(logPath, args) : hist.read(logPath, args);
                }
            }
            else if (isTimer) out_ = runTimerTool(call.name, args);
            else if (call.name == "read_file" && childReadState.isSome)
            {
                import nano.tools.files : readFile;
                out_ = readFile(args, childReadState.unwrap("checked isSome"));
            }
            else if (call.name == "apply_patch") out_ = applyPatchPrepared(args, tools, originals);
            else out_ = isPlan ? runPlanTool(call.name, args) : tools.execute(call.name, args);
            isError = false;
        }
        catch (ToolError e) out_ = e.msg;
        catch (TimerError e) out_ = e.msg;
        catch (hist.HistoryError e) out_ = e.msg;
        catch (OutcomeError e) out_ = e.msg;
        catch (QuestionError e) out_ = e.msg;
        catch (Exception e) out_ = format("%s failed: %s", call.name, e.msg);
        return out_;
    }

    /// The `session_send` handler (issue #272): resolve the target like the
    /// history tools' `session` argument, apply the loop guard and the
    /// sender's permission policy, and deliver through the registry socket.
    private string runSessionSend(JSONValue args)
    {
        import std.file : getcwd;
        auto ownLog = log.unwrap("session_send is offered only with a session log");
        string to, text;
        bool confirm;
        if (args.type == JSONType.object)
        {
            if (auto v = "to" in args.objectNoRef)
                if (v.type == JSONType.string) to = v.str.strip;
            if (auto v = "text" in args.objectNoRef)
                if (v.type == JSONType.string) text = v.str;
            if (auto v = "confirm" in args.objectNoRef)
                if (v.type == JSONType.true_ || v.type == JSONType.false_) confirm = v.boolean;
        }
        if (!to.length) throw new hist.HistoryError("session_send: `to` must be a non-empty session handle, id, prefix or title");
        if (!text.strip.length) throw new hist.HistoryError("session_send: `text` must be a non-empty message");
        // The loop guard (issue #350): a send from a peer-started turn is one
        // hop further along its thread; beyond `maxHops` it is refused. The
        // target's own confirm setting still applies (and `confirm: true`
        // still asks its user), so a plain reply needs no approval when the
        // target has confirmation off.
        auto hop = sendHop(peerTurn, inputHop);
        if (auto why = hopRefusal(hop, maxHops))
            throw new hist.HistoryError(why);
        auto cwd = getcwd();
        auto dir = sessionDirOf(ownLog);
        auto sessions = cross.listSessions(policy, dir, cwd);
        cross.SessionInfo self;
        self.id = ownLog.id;
        self.path = ownLog.path;
        self.live = true;
        self.cwd = cwd;
        auto target = cross.resolve(to, sessions, &self);
        if (target.id == ownLog.id)
            throw new hist.HistoryError("session_send: the target is this session; just answer directly");
        if (auto denied = cross.readDenied(policy, target, cwd))
            throw new hist.HistoryError(denied);
        // The sender's permission policy judges the send itself (a
        // `session_send(...)` deny rule matches the call's JSON).
        if (auto denied = policy.checkIn(peers.sendTool, args, cwd))
            throw new hist.HistoryError(denied);
        auto now = stdTimeNow;
        if (auto why = rateRefusal(recentSends, ownLog.id, target.id, now, maxSendsPerHour))
            throw new hist.HistoryError(why);
        peers.PeerMessage pm;
        pm.senderId = ownLog.id;
        pm.senderTitle = selfTitle(sessions, ownLog.id);
        pm.senderName = name;
        pm.text = text;
        pm.messageId = format("msg-%s", ++sendCounter);
        pm.confirm = confirm;
        pm.hop = hop;
        // A reply continues its thread; a user-started send opens one.
        pm.thread = peerTurn && inputThread.length ? inputThread
            : peerTurn && inputSender.length ? inputSender : format("%s/%s", ownLog.id, pm.messageId);
        string note;
        auto status = peers.send(peers.peersDir(), target.id, pm, note);
        if (maxSendsPerHour && status != peers.Status.notRunning && status != peers.Status.refused)
            recentSends[sendKey(ownLog.id, target.id)] ~= now; // keyed per sender/target pair
        return format("%s: %s", statusText(status), note.length ? note : defaultNote(status, target));
    }

    private uint sendCounter;

    /// The hop of a send (issue #350): 1 from a user-started turn, one more
    /// than the message that started a peer turn.
    static uint sendHop(bool peerTurn, uint inputHop) pure nothrow @nogc
    {
        if (!peerTurn) return 1;
        const h = inputHop ? inputHop : 1;
        return h == uint.max ? uint.max : h + 1; // saturate: a wrapped hop would reset the thread
    }

    /// Why a send at `hop` is refused under `maxHops`, or null.
    static string hopRefusal(uint hop, uint maxHops) pure
    {
        if (hop <= maxHops) return null;
        return format("thread hop limit reached (hop %s > session_messages_max_hops %s): stop, or ask your user",
            hop, maxHops);
    }

    /// Why one more send to `target` at `now` (stdTime) breaks the per-pair
    /// cap of `perHour` sends an hour (0: no cap), or null. Prunes the
    /// target's entries older than an hour, so the map stays bounded.
    static string rateRefusal(ref long[][string] sent, string sender, string target, long now, uint perHour) pure
    {
        const key = sendKey(sender, target);
        enum long hourTicks = 3600L * 10_000_000L;
        if (auto times = key in sent)
        {
            import std.algorithm : filter;
            import std.array : array;
            *times = (*times).filter!(t => t + hourTicks > now).array;
            if (!times.length) sent.remove(key);
        }
        // Drop other targets' stale entries too: a long session talks to many.
        string[] stale;
        foreach (k, v; sent)
            if (!v.length || v[$ - 1] + hourTicks <= now) stale ~= k;
        foreach (k; stale) sent.remove(k);
        if (!perHour) return null;
        auto times = key in sent;
        if (times is null || times.length < perHour) return null;
        return format("rate limit reached: %s messages to session %s in the last hour "
            ~ "(session_messages_max_per_hour); stop, or ask your user", times.length, target);
    }

    /// The `recentSends` key of a sender/target pair; never shown to the model.
    static string sendKey(string sender, string target) pure nothrow
    {
        return sender ~ "\x00" ~ target;
    }

    private static string statusText(peers.Status s) pure
    {
        final switch (s)
        {
            case peers.Status.delivered: return "delivered";
            case peers.Status.queued: return "queued";
            case peers.Status.awaiting: return "awaiting confirmation";
            case peers.Status.refused: return "refused";
            case peers.Status.notRunning: return "not running";
        }
    }

    private static string selfTitle(cross.SessionInfo[] sessions, string id)
    {
        foreach (i; sessions)
            if (i.id == id) return i.title;
        return null;
    }

    private static string defaultNote(peers.Status status, const ref cross.SessionInfo target) pure
    {
        import peers = nano.peers;
        final switch (status)
        {
            case peers.Status.delivered: return format("delivered to session %s", target.id);
            case peers.Status.queued: return format("queued in session %s (mid-turn; visible in its /queue)", target.id);
            case peers.Status.awaiting: return format("waiting for session %s's user to accept", target.id);
            case peers.Status.refused: return format("session %s refused the message", target.id);
            case peers.Status.notRunning: return format("session %s is not running (or has messages off)", target.id);
        }
    }

    /// This session's user-chosen handle (issue #300), or null. Set with
    /// `setName`, restored from the log by `loadRestored`.
    string name;

    /// Set this session's handle to `handle` (null or empty clears it):
    /// validated, claimed in the peers registry (refused while another
    /// running session holds it) and, when `record`, written to the session
    /// log so a resume restores it. Returns null on success, else why not.
    string setName(string handle, bool record = true)
    {
        import nano.handle : invalidHandle, claim;
        if (!handle.length)
        {
            // Record the clear even with no live name: a handle refused on
            // restore is still in the log, and a resume would bring it back.
            // Persist first: a failed write leaves the handle (and its
            // claim) in place, so a retry really retries.
            string failed;
            if (record) log.ifSome((SessionLog l) {
                try l.name(null);
                catch (Exception e) failed = "can't record the handle: " ~ e.msg;
            });
            if (failed !is null) return failed;
            if (name.length) releaseName();
            name = null;
            return null;
        }
        if (auto why = invalidHandle(handle)) return why;
        // Without a log the handle can be neither claimed nor resumed.
        if (log.isNone) return "sessions are not saved (--no-session or persist_sessions = false)";
        string refused;
        string claimedId;
        log.ifSome((SessionLog l) { claimedId = l.id; refused = claim(peers.peersDir(), sessionDirOf(l), handle, l.id); });
        if (refused !is null) return refused;
        immutable changed = name != handle;
        if (record && changed)
        {
            // Persist before touching in-memory state or the old claim: a
            // failed write must not leave `name` changed (a retry would then
            // report success without recording it) nor hold the new claim.
            import nano.handle : release;
            string failed;
            log.ifSome((SessionLog l) {
                try l.name(handle);
                catch (Exception e)
                {
                    // Recoverable (a full disk, say): report it, don't end the session.
                    // Release the id the claim was taken under: a write that
                    // recovered the log before throwing has a new `l.id`.
                    release(peers.peersDir(), handle, claimedId);
                    failed = "can't record the handle: " ~ e.msg;
                }
            });
            if (failed !is null) return failed;
            // The write may have recovered the log to a new id (no hook
            // moves this not-yet-live claim): move the claim to the final
            // id, or discovery misses it and another session can take it.
            string moved;
            log.ifSome((SessionLog l) {
                if (l.id == claimedId) return;
                moved = claim(peers.peersDir(), sessionDirOf(l), handle, l.id);
                release(peers.peersDir(), handle, claimedId);
            });
            if (moved !is null)
            {
                // The name record is already in the log: write a clearing
                // record so a resume doesn't bring back a handle the user
                // was told wasn't set (or the previous one, now released).
                string rollback;
                log.ifSome((SessionLog l) {
                    try l.name(name.length ? name : null);
                    catch (Exception e) rollback = " (and the log still names it: " ~ e.msg ~ ")";
                });
                return "can't keep the handle after the log moved: " ~ moved ~ rollback;
            }
        }
        if (name.length && changed) releaseName();
        name = handle;
        log.ifSome((SessionLog l) { l.onIdChange = &moveNameClaim; });
        return null;
    }

    /// The log moved to a recovery id: move the handle's claim with it, or
    /// the old (now unlocked) id reads as stopped and another session could
    /// take the handle. Never throws: it runs on the log's append path.
    private void moveNameClaim(string oldId, string newId) nothrow
    {
        import nano.handle : claim, release;
        if (!name.length) return;
        string refused;
        try
        {
            log.ifSome((SessionLog l) { refused = claim(peers.peersDir(), sessionDirOf(l), name, newId); });
            release(peers.peersDir(), name, oldId);
        }
        catch (Exception e) refused = e.msg;
        if (refused is null) return;
        immutable lost = name;
        name = null;
        try log.ifSome((SessionLog l) {
            l.report("WARNING: this session lost its handle " ~ lost ~ " when its log moved to " ~ newId
                ~ ": " ~ refused ~ " (set it again with /name)");
        });
        catch (Exception) {} // best-effort diagnostic: the handle is already dropped
    }

    /// Drop this session's registry claim on its handle (it keeps the name
    /// in memory): before the session is left or the process exits.
    void releaseName()
    {
        import nano.handle : release;
        if (!name.length) return;
        log.ifSome((SessionLog l) { release(peers.peersDir(), name, l.id); });
    }

    /// The directory a session log lives in (where its sibling sessions are).
    private static string sessionDirOf(SessionLog l)
    {
        import std.path : dirName;
        return l.path.dirName;
    }

    /// Honor a history call's `session` argument (issue #271): resolve it to
    /// one session's log and check the read against the permission policy.
    /// Returns the message the model sees when the read may not happen (the
    /// setting off, the policy denying another workspace's log, or the user
    /// declining a cross-workspace read); on success `logPath` names the log
    /// to stream and the result is null. Without the argument the call reads
    /// the session's own log, as before.
    private string resolveSessionArg(JSONValue args, SessionLog ownLog, ref string logPath)
    {
        import std.file : getcwd;
        auto needle = cross.sessionArg(args);
        if (!needle.length) return null;
        if (!crossSessionHistory)
            return "the session argument is disabled (cross_session_history = false)";
        auto dir = sessionDirOf(ownLog);
        auto cwd = getcwd();
        auto sessions = cross.listSessions(policy, dir, cwd);
        cross.SessionInfo self;
        self.id = ownLog.id;
        self.path = ownLog.path;
        self.live = true;
        self.cwd = cwd;
        auto target = cross.resolve(needle, sessions, &self);
        if (target.id == ownLog.id) return null; // this session: read as today
        if (auto denied = cross.readDenied(policy, target, cwd)) return denied;
        // Default-ask (issue #271): a session from another workspace is read
        // only after the user confirms; headless (no answerer) fails closed.
        if (cross.needsConfirmation(target, cwd) && !confirmedCrossRead(target))
            return format("reading session %s from another workspace (%s) was not confirmed; "
                ~ "the user must allow it first", target.id, target.cwd.length ? target.cwd : "unknown directory");
        logPath = target.path;
        return null;
    }

    /// Ask the user whether a cross-workspace session may be read; false when
    /// they decline or no one can answer (headless fails closed, issue #271).
    private bool confirmedCrossRead(const ref cross.SessionInfo target)
    {
        import nano.question : Question, QuestionOption, Answered;
        if (!questions || !questions.interactive) return false;
        auto q = Question(cross.confirmQuestion(target), null,
            [QuestionOption("No"), QuestionOption("Yes")]);
        q.custom = false;
        auto a = questions.ask([q]);
        return a.match!(
            (Answered got) => got.answers.length && got.answers[0] == "Yes",
            _ => false);
    }

    /// After a call ran: the PostToolUse hooks, and the hooks' context added.
    private string afterTool(const ref ToolCall call, JSONValue args, string out_, string[] context,
        bool isError = true, PatchEdit[] patchInputs = null)
    {
        foreach (h; hooks)
        {
            auto o = h.runPostToolUse(call.name, args, out_, call.id);
            if (auto ctx = o.contextBlock) context ~= ctx;
            if (o.blocked && o.blockReason.strip.length) context ~= o.blockReason;
        }
        if (call.name == "apply_patch" && !isError)
            foreach (edit; patchInputs)
                foreach (h; hooks)
                {
                    auto o = h.runPostToolUse(edit.name, edit.args, out_, call.id);
                    if (auto ctx = o.contextBlock) context ~= ctx;
                    if (o.blocked && o.blockReason.strip.length) context ~= o.blockReason;
                }
        return withContext(out_, context);
    }

    // ---- sub-agents (the `agent` tool, issue #231) ----
    /// Builds sub-agents' clients; null: no `agent` tool (as in a sub-agent).
    Rebindable!(immutable SubClientFactory) subagentClients;
    /// The model sub-agents run on (`subagent_model`; empty: this agent's).
    string subagentModel;
    /// How many sub-agents run at once (`subagent_max_concurrency`).
    size_t subagentMaxConcurrency = 4;
    SubLimits subagentLimits;
    /// The models the `agent` tool may pick (`[[subagent_models]]` that
    /// resolve); empty: any model, defaulting to `subagentModel`.
    immutable(SubCandidate)[] subagentCandidates;
    /// The session's `/subagents on|off`: off leaves the `agent` tool out of
    /// the next request (sub-agents already running finish).
    bool subagentsOn = true;
    /// The current reply's sub-agents, the gate result of its `agent` calls
    /// by call id, and the child logs to reference.
    private SubSlot[] subSlots;
    private SubGate[string] subGates;
    private string[string] subLogs;
    private Chan!SubMsg subUp;
    private size_t subRunning, subCallSeq;
    /// The last sub-agent number handed out (`sub-N`, `SubSpec.slot`).
    private size_t subSeq;
    private Option!AgentEvents subEvents;
    /// Set only while runTool runs a sub-agent's read_file: the child's own
    /// read registry, kept apart from the parent's.
    private Option!(imported!"nano.tools.files".ReadState) childReadState;

    bool subagentsEnabled() pure const { return subagentClients.get !is null; }

    /// The `agent` tool goes into the next request: sub-agents are
    /// available and the session has them on.
    bool subagentsOffered() pure const { return subagentsEnabled && subagentsOn; }

    /// Clear the previous reply's sub-agent state before a reply's tools run.
    private void resetSubagents(AgentEvents ev)
    {
        // Background sub-agents (issue #266) outlive their reply; the
        // reply's blocking ones were collected by finishSubagents.
        dropSlots((ref const SubSlot s) => !s.background);
        subGates = null;
        subLogs = null;
        if (!subUp) subUp = Chan!SubMsg.make;
        subEvents = some(ev);
    }

    /// Remove the slots `gone` picks (a slot holds an immutable spec, so
    /// it is copied, not moved, into the new array).
    private void dropSlots(scope bool delegate(ref const SubSlot) @safe gone)
    {
        SubSlot[] kept;
        foreach (ref s; subSlots)
        {
            if (!gone(s)) kept ~= s;
            else archiveSlot(s);
        }
        subSlots = kept;
    }

    /// Finished sub-agents no longer in `subSlots`, for `/subagents`
    /// (issue #267): metadata only, at most `keepHistory`.
    private imported!"nano.subagent".SubInfo[] subHistory;
    /// Sub-agents dropped from `subHistory` past its cap.
    private size_t subForgotten;

    /// Remember a slot leaving `subSlots` (its metadata, not its result).
    private void archiveSlot(ref const SubSlot s)
    {
        import nano.subagent : keepHistory;
        subHistory ~= infoOf(s);
        if (subHistory.length > keepHistory)
        {
            subForgotten += saturatingSub(subHistory.length, keepHistory);
            subHistory = subHistory[$ - keepHistory .. $].dup;
        }
    }

    private static imported!"nano.subagent".SubInfo infoOf(ref const SubSlot s)
    {
        import nano.subagent : SubInfo, firstLine;
        SubInfo i;
        i.id = s.id;
        i.seq = s.spec.slot;
        i.model = s.spec.model;
        i.state = s.state;
        i.task = firstLine(s.task);
        i.turns = s.turns;
        i.tokens = s.finished ? s.result.inputTokens + s.result.outputTokens : s.tokens;
        i.elapsedSecs = s.started ? (s.finished ? s.result.durationMs / 1000 : since(s.start).total!"seconds") : 0;
        i.background = s.background;
        i.logPath = s.logPath.length ? s.logPath : s.result.logPath;
        return i;
    }

    /// Every sub-agent of this session, oldest first, for `/subagents`;
    /// `forgotten` counts the earliest ones no longer remembered.
    imported!"nano.subagent".SubInfo[] subagentList(out size_t forgotten)
    {
        pollSubagents();
        return subagentSnapshot(forgotten);
    }

    /// `subagentList` without serving waiting messages first: safe to call
    /// from `onSubagentsChanged`, which runs while a message is handled.
    imported!"nano.subagent".SubInfo[] subagentSnapshot(out size_t forgotten)
    {
        import std.algorithm : sort;
        forgotten = subForgotten;
        auto all = subHistory.dup;
        foreach (ref s; subSlots) all ~= infoOf(s);
        // Slots leave `subSlots` as they finish, not in launch order, so the
        // archive alone is not oldest first: sort the combination on the
        // launch sequence.
        sort!((a, b) => a.seq < b.seq)(all);
        return all;
    }

    /// The log of sub-agent `id` (`/subagents show`), or why there is none.
    imported!"nano.result".Result!(string, string) subagentLog(string id)
    {
        alias R = imported!"nano.result".Result!(string, string);
        size_t forgotten;
        foreach (ref i; subagentList(forgotten))
        {
            if (i.id != id) continue;
            if (!i.logPath.length)
                return R.err(format("%s has no log%s", id, i.state == "queued" ? " yet: it has not started"
                    : log.isNone ? ": this session keeps no logs" : " yet"));
            import nano.subagent : currentLogPath;
            auto path = currentLogPath(i.logPath);
            if (path is null) return R.err(format("%s's log %s is gone", id, i.logPath));
            return R.ok(path);
        }
        return R.err(format("No sub-agent %s (/subagents lists them).", id));
    }

    /// `/subagents stop <id>|all`: stop running or queued sub-agents as
    /// `agent_cancel` does (each gets a short final step to report, then is
    /// cut off), started by the user. A background one's result reaches the
    /// model like any finished one. Returns what happened.
    string stopSubagentsByUser(string which)
    {
        import nano.subagent : cancelGraceSecs;
        import core.time : seconds;
        import std.array : join;
        enum reason = "stopped by the user";
        pollSubagents();
        size_t[] seqs;
        if (which == "all")
        {
            foreach (ref s; subSlots) if (!s.finished) seqs ~= s.spec.slot;
            if (!seqs.length) return "No sub-agent is running.";
        }
        else
        {
            bool found;
            foreach (ref s; subSlots)
                if (s.id == which)
                {
                    found = true;
                    if (s.finished) return format("%s already ended (%s); nothing to stop.", which, s.state);
                    seqs ~= s.spec.slot;
                }
            if (!found)
            {
                foreach (ref h; subHistory)
                    if (h.id == which) return format("%s already ended (%s); nothing to stop.", which, h.state);
                return format("No sub-agent %s (/subagents lists them).", which);
            }
        }
        foreach (q; seqs)
        {
            auto i = slotOf(q);
            subSlots[i].cancelReason = reason;
            if (!subSlots[i].started) cancelUnstarted(subSlots[i]);
            else subSlots[i].abort.wrapUp();
        }
        bool done(size_t q) { return subSlots[slotOf(q)].finished; }
        bool allDone()
        {
            foreach (q; seqs) if (!done(q)) return false;
            return true;
        }
        auto deadline = monoNow + cancelGraceSecs.seconds;
        bool[size_t] cut;
        while (!allDone())
        {
            if (!cut.length && !pumpUntil(deadline))
            {
                foreach (q; seqs)
                    if (!done(q))
                    {
                        cut[q] = true;
                        subSlots[slotOf(q)].abort.abort();
                    }
            }
            else if (cut.length) pumpSubagents();
        }
        string[] ids;
        foreach (q; seqs)
        {
            auto i = slotOf(q);
            if (q in cut)
                subSlots[i].result.report = format("(no report: it did not report within %ss and was cut off)", cancelGraceSecs);
            subSlots[i].result.cancelled = subSlots[i].result.truncated = true;
            subSlots[i].result.truncatedReason = "cancelled by the user";
            ids ~= subSlots[i].id;
            foreach (l; log) l.subagent(subSlots[i].id, "cancelled", reason);
        }
        reportSubagents();
        return format("Stopped %s; %s reaches the agent as a cancelled result.", ids.join(", "),
            ids.length > 1 ? "each one's report" : "its report");
    }

    /// The position in `subSlots` of sub-agent number `seq`, or `size_t.max`.
    private size_t slotOf(size_t seq) pure const nothrow
    {
        foreach (i, ref s; subSlots) if (s.spec.slot == seq) return i;
        return size_t.max;
    }

    /// Where the barrier-free stretch of `calls` starting at `from` ends:
    /// the first call that is neither an `agent` call nor eligible to run
    /// beside reads (an edit, bash, a hooked call ...).
    private size_t subSegmentEnd(const(ToolCall)[] calls, size_t from)
    {
        auto j = from;
        while (j < calls.length && (calls[j].name == subToolName || concurrentEligible(calls[j].name))) j++;
        return j;
    }

    /// Check and start the `agent` calls in the barrier-free stretch of `r`
    /// that begins at call `from` (the rest wait for a slot). Later
    /// stretches launch when the loop reaches them, after the mutations
    /// between.
    private void launchSubagents(const ref LLMResponse r, size_t from)
    {
        import nano.subagent : parseArgs, systemPrompt, encodeDefinition, forwardable, choose;
        import std.file : getcwd;
        import std.path : stripExtension;
        if (!subagentsOffered) return;
        string cwd;
        immutable(string)[] defs;
        foreach (call; r.toolCalls[from .. subSegmentEnd(r.toolCalls, from)])
        {
            if (call.name != subToolName || control.isCancelled || (call.id in subGates) !is null) continue;
            // An invalid call is reported by runTool, as for any tool.
            if (call.rawArgumentsError(r.stopReason)) continue;
            SubGate g;
            if (admit(call, r.stopReason, g.deny, g.args, g.context))
            {
                try
                {
                    auto a = parseArgs(g.args, subagentLimits.timeoutSecs);
                    if (!cwd.length)
                    {
                        cwd = getcwd();
                        foreach (d; tools.definitions)
                            if (forwardable(d.name) && (control.mode != AgentMode.plan || planAllows(d.name)))
                                defs ~= encodeDefinition(d);
                    }
                    auto picked = choose(a, subagentCandidates, subagentModel.length ? subagentModel
                        : client.providerName ~ "/" ~ client.modelName, subagentLimits);
                    auto limits = picked.limits, model = picked.model;
                    auto seq = ++subSeq;
                    immutable spec = SubSpec(seq, call.id, a.task, model,
                        systemPrompt(cwd, wallNow.toISOExtString[0 .. 10]), defs, limits,
                        log.match!(l => l.path.stripExtension, () => string.init), format("sub-%s", seq), cwd);
                    if (a.background && !backgroundSubagents)
                        throw new ToolError("agent: background sub-agents are not available here (nothing serves "
                            ~ "them between prompts); run it without background");
                    g.slot = seq;
                    g.launched = true;
                    subSlots ~= SubSlot(call.id, a.task, spec);
                    subSlots[$ - 1].background = a.background;
                    subSlots[$ - 1].id = format("sub-%s", seq);
                }
                catch (ToolError e) g.argError = e.msg;
            }
            subGates[call.id] = g;
        }
        if (!subSlots.length) return;
        if (startSubagents()) reportSubagents();
        else subagentsChanged();
    }

    /// Called on this agent's thread when a sub-agent is launched, makes
    /// progress, ends or is cancelled, so the UI's id snapshot (used by
    /// `/subagents stop <Tab>` mid-turn) includes ones the turn spawned.
    void delegate() onSubagentsChanged;

    private void subagentsChanged()
    {
        if (onSubagentsChanged !is null) onSubagentsChanged();
    }

    /// Start waiting sub-agents while there is room (none once cancelled).
    /// True when one started (the caller reports it).
    private bool startSubagents()
    {
        bool any;
        import nano.safeio : spawn;
        import nano.subagent : runChild;
        auto cap = subagentMaxConcurrency ? subagentMaxConcurrency : 1;
        foreach (i; 0 .. subSlots.length)
        {
            if (subSlots[i].started || subSlots[i].finished) continue;
            if (control.isCancelled)
            {
                subSlots[i].finished = true;
                subSlots[i].result.report = "(cancelled before the sub-agent started)";
                subSlots[i].result.truncated = subSlots[i].result.cancelled = true;
                subSlots[i].result.truncatedReason = "cancelled";
                continue;
            }
            if (subRunning >= cap) break;
            subSlots[i].down = Chan!ToolReply.make;
            subSlots[i].abort = SubAbort.make;
            immutable spec = subSlots[i].spec;
            subSlots[i].handle = spawn(&runChild, spec, subagentClients.get, subUp, subSlots[i].down, subSlots[i].abort);
            subSlots[i].started = true;
            subSlots[i].start = monoNow;
            subRunning++;
            any = true;
        }
        return any;
    }

    /// Handle one message from a running sub-agent: run its tool call
    /// (through this agent's policy and hooks), note its progress, or collect
    /// its result.
    private void pumpSubagents()
    {
        SubMsg m;
        // Every child sends `done` (even on failure) and nothing closes the
        // channel, so a take ends only with a message.
        if (!subUp.take(m)) assert(0, "the sub-agent channel closed");
        handleSubMsg(m);
    }

    /// Serve the sub-agents' waiting messages without blocking: background
    /// ones run while this agent is between steps or idle (issue #266).
    void pollSubagents()
    {
        SubMsg m;
        while (subRunning && subUp && subUp.tryTake(m)) handleSubMsg(m);
    }

    /// Wait for a sub-agent message until `deadline`, polling (the clock
    /// may be fake in tests). False when the deadline passed first.
    private bool pumpUntil(MonoTime deadline)
    {
        import nano.clock : sleepFor;
        import core.time : msecs;
        SubMsg m;
        // The deadline is checked before every take: a steady stream of
        // sibling messages must not keep a wait running past it.
        for (;;)
        {
            if (monoNow >= deadline) return false;
            if (subUp.tryTake(m)) break;
            sleepFor(5.msecs);
        }
        handleSubMsg(m);
        return true;
    }

    private void handleSubMsg(SubMsg m)
    {
        import nano.subagent : forwardable, argSummary, recentCalls;
        auto i = slotOf(m.slot);
        assert(i != size_t.max, "a message from a forgotten sub-agent");
        final switch (m.kind)
        {
            case SubKind.started:
                subSlots[i].logPath = m.args;
                break;
            case SubKind.tool:
                ToolReply rep;
                rep.isError = true;
                if (control.isCancelled) rep.text = cancelledToolResult;
                else if (subSlots[i].abort.aborted) rep.text = loopStoppedToolResult;
                else if (!forwardable(m.name)) rep.text = format("%s is not available to a read-only sub-agent", m.name);
                else
                {
                    subSlots[i].recent ~= m.name ~ "(" ~ argSummary(m.args) ~ ")";
                    if (subSlots[i].recent.length > recentCalls) subSlots[i].recent = subSlots[i].recent[1 .. $].dup;
                    auto call = ToolCall.fromRaw(format("%s.%s", subSlots[i].callId, ++subCallSeq), m.name, m.args);
                    // A child's read_file runs on its own ReadState: the
                    // parent's registry would record the read, letting a
                    // later parent write pass the read-before-write check on
                    // a file the parent model never saw. It still goes
                    // through runTool, so the parent's permission rules and
                    // hooks apply as for every forwarded tool.
                    if (m.name == "read_file" && subSlots[i].readState.isNone)
                    {
                        import nano.tools.files : ReadState;
                        import nano.option : some;
                        subSlots[i].readState = some(new ReadState);
                    }
                    childReadState = m.name == "read_file" ? subSlots[i].readState : typeof(childReadState).init;
                    scope (exit) childReadState = typeof(childReadState).init;
                    // A dispatch failure (a hook cannot start, the
                    // registry throws) must still wake the child: close
                    // its reply channel so its `down.take` ends instead
                    // of blocking cleanup forever.
                    try
                    {
                        bool dispatched;
                        JSONValue effectiveArgs;
                        rep.text = runTool(call, "tool_use", rep.isError, dispatched, effectiveArgs);
                        // Tell the child which path it actually read (after
                        // any hook rewrite); only a dispatched, successful
                        // read counts as one.
                        if (!rep.isError && dispatched && m.name == "read_file")
                            if (auto p = "path" in effectiveArgs)
                                if (p.type == JSONType.string) rep.effectivePath = p.str;
                    }
                    catch (Exception e)
                    {
                        subSlots[i].down.close();
                        rep.text = format("%s failed: %s", m.name, e.msg);
                    }
                }
                // After a dispatch failure the channel is closed and the
                // child already woke; the put is a harmless no-op then.
                subSlots[i].down.put(rep);
                break;
            case SubKind.progress:
                subSlots[i].toolCalls = m.toolCalls;
                subSlots[i].turns = m.turns;
                subSlots[i].tokens = m.tokens;
                // A running child's usage counts as it is spent (issue
                // #340): fold in what this snapshot adds to the last one.
                size_t lost;
                recordUsage(subSlots[i].fold.advance(m.spent, m.uncounted, lost));
                uncountedRequests += lost;
                reportSubagents();
                break;
            case SubKind.done:
                subSlots[i].result = subSlots[i].handle.join();
                subSlots[i].finished = true;
                subSlots[i].toolCalls = subSlots[i].result.toolCalls;
                subSlots[i].turns = subSlots[i].result.turns;
                if (subSlots[i].result.logPath.length) subSlots[i].logPath = subSlots[i].result.logPath;
                subRunning--;
                // Usage rolls up into this session's totals (status line, /cost).
                // Only what the progress snapshots didn't already add.
                size_t lost;
                recordUsage(subSlots[i].fold.advance(subSlots[i].result.usage, subSlots[i].result.uncountedRequests, lost));
                uncountedRequests += lost;
                // Start the replacements first, so the one report shows
                // them running (a child sends no progress during its first
                // model request).
                startSubagents();
                reportSubagents();
                break;
        }
    }

    /// The `agent` call's result: wait for its sub-agent, serving the others.
    private string runSubagent(const ref ToolCall call, const(SubGate)* gate)
    {
        if (gate is null || !gate.launched)
            throw new ToolError(gate !is null && gate.argError.length ? gate.argError : "agent: the sub-agent did not start");
        auto seq = gate.slot;
        auto i = slotOf(seq);
        if (subSlots[i].background)
        {
            if (!subSlots[i].started && startSubagents()) reportSubagents();
            i = slotOf(seq);
            auto sl = subSlots[i];
            auto l = sl.spec.limits;
            return format("Started %s in the background%s on %s (limits: %s turns, %ss, %s tokens). It keeps running "
                ~ "while you work; its result arrives as a reminder on a later step (or from agent_wait). "
                ~ "agent_status, agent_read, agent_cancel and agent_wait take its id.", sl.id,
                sl.started ? "" : " (queued: the sub-agent concurrency cap is reached)", sl.spec.model, l.turns,
                l.timeoutSecs, l.tokens);
        }
        for (;;)
        {
            i = slotOf(seq);
            if (subSlots[i].finished) break;
            if (!subSlots[i].started && startSubagents()) reportSubagents();
            if (!subSlots[slotOf(seq)].finished && subRunning) pumpSubagents();
        }
        auto res = subSlots[i].result;
        if (res.logPath.length) subLogs[call.id] = res.logPath;
        return res.toolText;
    }

    /// After a reply's tools ran: stop and collect sub-agents still running
    /// (a cancel or a loop stop skipped their calls).
    private void finishSubagents()
    {
        import std.algorithm : any;
        // Esc Esc stops background sub-agents too.
        bool all = control.isCancelled;
        foreach (ref s; subSlots)
            if ((all || !s.background) && s.started && !s.finished) s.abort.abort();
        foreach (ref s; subSlots) if ((all || !s.background) && !s.started) cancelUnstarted(s);
        while (subSlots.any!(s => !s.background && !s.finished) || (all && subRunning)) pumpSubagents();
        dropSlots((ref const SubSlot s) => !s.background);
        subGates = null;
        // Background children still running keep the observer: idle polling
        // delivers their progress and the completion that ends their row.
        if (!subagentsActive) subEvents = none;
    }

    private static void cancelUnstarted(ref SubSlot s)
    {
        s.finished = true;
        s.result.report = "(cancelled before the sub-agent started)";
        s.result.truncated = s.result.cancelled = true;
        s.result.truncatedReason = "cancelled";
    }

    /// Stop every sub-agent, background ones included, and wait for them
    /// (session exit, relaunch, `/restart`). Their logs stay; results not
    /// yet delivered are logged as a note.
    void stopSubagents()
    {
        foreach (ref s; subSlots)
        {
            if (s.started && !s.finished) s.abort.abort();
            else if (!s.started) cancelUnstarted(s);
        }
        while (subRunning) pumpSubagents();
        foreach (ref s; subSlots)
            if (s.background && !s.delivered)
            {
                s.delivered = true;
                foreach (l; log) l.subagent(s.id, "stopped", s.result.toolText);
            }
        foreach (ref s; subSlots) archiveSlot(s);
        subSlots = null;
        subEvents = none;
    }

    /// Stop every sub-agent and forget the list `/subagents` shows: used
    /// when the session is left (`/new`, `/restart`, `/resume`, ACP load),
    /// so the next session does not list the previous one's sub-agents.
    void leaveSessionSubagents()
    {
        stopSubagents();
        subHistory = null;
        subForgotten = 0;
    }

    /// Whether a sub-agent is running or queued (the UI shows activity).
    bool subagentsActive() pure const nothrow
    {
        foreach (ref s; subSlots) if (!s.finished) return true;
        return false;
    }

    /// Whether a background sub-agent finished and its result waits for
    /// delivery (serves waiting sub-agents first).
    bool backgroundResultsReady()
    {
        pollSubagents();
        foreach (ref s; subSlots) if (s.background && s.finished && !s.delivered) return true;
        return false;
    }

    /// The text of the finished, undelivered background results, marking
    /// them delivered (once only), or null. `notice` is the short line to show.
    string takeBackgroundResults(out string notice)
    {
        string text;
        string[] ids;
        foreach (ref s; subSlots)
            if (s.background && s.finished && !s.delivered)
            {
                s.delivered = true;
                ids ~= s.id;
                text ~= (text.length ? "\n\n" : "") ~ resultText(s);
            }
        pruneSubagents();
        if (!ids.length) return null;
        import std.array : join;
        notice = format("[background sub-agent%s %s finished]", ids.length > 1 ? "s" : "", ids.join(", "));
        return text;
    }

    private static string resultText(const ref SubSlot s)
    {
        import std.string : lineSplitter;
        import std.range : front, empty;
        auto first = s.task.lineSplitter;
        return format("Background sub-agent %s (%s) %s:\n%s", s.id, first.empty ? "" : first.front,
            s.state == "done" ? "finished" : "ended: " ~ s.state, s.result.toolText);
    }

    /// Forget delivered background sub-agents beyond the most recent few.
    private void pruneSubagents()
    {
        import nano.subagent : keepDelivered;
        import std.algorithm : count;
        // A delivered result lives on in the conversation and the log:
        // keep only the status metadata here.
        foreach (ref s; subSlots)
            if (s.background && s.delivered)
            {
                s.result.report = null;
                s.recent = null;
                s.readState = none;
            }
        auto n = subSlots.count!(s => s.background && s.delivered);
        if (n <= keepDelivered) return;
        auto drop = saturatingSub(n, keepDelivered);
        dropSlots((ref const SubSlot s) {
            if (drop && s.background && s.delivered) { drop--; return true; }
            return false;
        });
    }

    /// Before a model call: serve background sub-agents, stop them on a
    /// cancel, and deliver finished results as one reminder (issue #266).
    private void deliverBackground(AgentEvents ev)
    {
        if (!subSlots.length) return;
        if (control.isCancelled)
        {
            finishSubagents();
            return;
        }
        if (!backgroundResultsReady()) return;
        string notice;
        auto text = takeBackgroundResults(notice);
        if (text is null) return;
        auto m = Message.auto_(wrapReminder(text));
        m.timer = true;
        push(m);
        ev.userMessage(notice);
    }

    /// Run `agent_status`, `agent_read`, `agent_cancel` or `agent_wait`.
    private string runSubControl(string name, JSONValue args)
    {
        import nano.subagent : statusTool, readTool, cancelTool, waitTool, readLogTail;
        import nano.tools : optString, requireString, optInt;
        pollSubagents();
        size_t find(string id)
        {
            foreach (i, ref s; subSlots) if (s.id == id) return i;
            string known;
            foreach (ref s; subSlots) known ~= (known.length ? ", " : "") ~ s.id;
            throw new ToolError(format("%s: no sub-agent %s (known: %s)", name, id, known.length ? known : "none"));
        }
        if (name == statusTool)
        {
            auto id = optString(args, "id");
            if (id.length) return statusLine(subSlots[find(id)]);
            if (!subSlots.length) return "No sub-agents in this session.";
            string o;
            foreach (ref s; subSlots) o ~= (o.length ? "\n" : "") ~ statusLine(s);
            return o;
        }
        if (name == readTool)
        {
            auto i = find(requireString(args, "id", name));
            auto since = optInt(args, "since", 0);
            if (since < 0) throw new ToolError("agent_read: since must be 0 or more");
            if (!subSlots[i].logPath.length)
                return subSlots[i].started ? "(its log is not open yet; try again shortly)"
                    : "(no log: it has not started" ~ (log.isNone ? ", or this session keeps no logs" : "") ~ ")";
            import nano.arith : toSize;
            return readLogTail(subSlots[i].logPath, toSize(since));
        }
        if (name == cancelTool)
        {
            auto id = requireString(args, "id", name);
            auto reason = requireString(args, "reason", name);
            return cancelSubagent(find(id), reason);
        }
        assert(name == waitTool);
        return waitSubagents(args);
    }

    private string statusLine(const ref SubSlot s)
    {
        import std.array : join;
        auto tokens = s.finished ? s.result.inputTokens + s.result.outputTokens : s.tokens;
        auto el = s.started ? (s.finished ? s.result.durationMs / 1000 : since(s.start).total!"seconds") : 0;
        auto o = format("%s [%s%s] %s: %s turns, %s tool calls, %s tokens, %ss", s.id, s.state,
            s.background ? (s.delivered ? ", delivered" : "") : ", blocking", s.spec.model, s.turns, s.toolCalls, tokens, el);
        if (s.recent.length) o ~= "; last: " ~ s.recent.join("; ");
        return o;
    }

    /// `agent_cancel`: ask the sub-agent for a final report, wait up to
    /// the grace period, then cut it off.
    private string cancelSubagent(size_t i, string reason)
    {
        import nano.subagent : cancelGraceSecs;
        import core.time : seconds;
        scope (exit) subagentsChanged();
        auto seq = subSlots[i].spec.slot;
        auto id = subSlots[i].id;
        if (subSlots[i].finished) return format("%s already ended (%s); nothing to cancel.", id, subSlots[i].state);
        subSlots[i].cancelReason = reason;
        if (!subSlots[i].started) cancelUnstarted(subSlots[i]);
        else
        {
            subSlots[i].abort.wrapUp();
            auto deadline = monoNow + cancelGraceSecs.seconds;
            bool cut;
            while (!subSlots[slotOf(seq)].finished)
            {
                if (!cut && !pumpUntil(deadline))
                {
                    cut = true;
                    subSlots[slotOf(seq)].abort.abort();
                }
                else if (cut) pumpSubagents();
            }
            i = slotOf(seq);
            if (cut)
            {
                subSlots[i].result.report = format("(no report: it did not report within %ss and was cut off)", cancelGraceSecs);
            }
            subSlots[i].result.cancelled = subSlots[i].result.truncated = true;
            subSlots[i].result.truncatedReason = "cancelled by the parent: " ~ reason;
        }
        subSlots[i].delivered = true;
        foreach (l; log) l.subagent(id, "cancelled", reason);
        auto text = resultText(subSlots[i]);
        pruneSubagents(); // cancelled slots count against the kept few too
        return text;
    }

    /// `agent_wait`: block until the sub-agents finish or the timeout.
    private string waitSubagents(JSONValue args)
    {
        import nano.subagent : maxWaitSecs;
        import nano.tools : optInt;
        import core.time : seconds;
        auto ids = "ids" in args;
        if (ids is null || ids.type != JSONType.array || !ids.arrayNoRef.length)
            throw new ToolError("agent_wait: ids must be a non-empty list of sub-agent handles");
        auto t = optInt(args, "timeout_s", 60);
        if (t < 0) throw new ToolError("agent_wait: timeout_s must be 0 or more");
        size_t[] seqs;
        foreach (v; ids.arrayNoRef)
        {
            if (v.type != JSONType.string) throw new ToolError("agent_wait: ids must be strings such as sub-3");
            bool found;
            foreach (ref s; subSlots) if (s.id == v.str) { seqs ~= s.spec.slot; found = true; }
            if (!found) throw new ToolError(format("agent_wait: no sub-agent %s", v.str));
        }
        auto deadline = monoNow + min(t, maxWaitSecs).seconds;
        bool allDone()
        {
            foreach (q; seqs) if (!subSlots[slotOf(q)].finished) return false;
            return true;
        }
        while (!allDone() && !control.isCancelled && pumpUntil(deadline)) {}
        string o;
        foreach (q; seqs)
        {
            auto i = slotOf(q);
            string part;
            if (!subSlots[i].finished) part = "still running: " ~ statusLine(subSlots[i]);
            else if (subSlots[i].delivered) part = subSlots[i].id ~ ": its result was already delivered. " ~ statusLine(subSlots[i]);
            else
            {
                subSlots[i].delivered = true;
                part = resultText(subSlots[i]);
            }
            o ~= (o.length ? "\n\n" : "") ~ part;
        }
        pruneSubagents();
        return o;
    }

    /// Show every started sub-agent's progress (renderers that support it).
    private void reportSubagents()
    {
        scope (exit) subagentsChanged();
        SubProgress[] all;
        foreach (i, ref s; subSlots)
        {
            if (!s.started || s.reportedDone) continue;
            SubProgress p;
            p.callId = s.callId;
            p.handle = s.id;
            p.task = s.task;
            p.index = i;
            p.toolCalls = s.toolCalls;
            p.tokens = s.finished ? s.result.inputTokens + s.result.outputTokens : s.tokens;
            p.elapsed = since(s.start);
            p.done = s.finished;
            p.truncated = s.result.truncated;
            if (s.finished) s.reportedDone = true;
            all ~= p;
        }
        if (all.length)
            foreach (e; subEvents)
                e.subagents(all);
    }

    /// An apply_patch call's touched paths as the file-tool calls a direct
    /// change would make: `write_file` for an added file or a move's
    /// destination, `edit_file` otherwise (with the path only). None when the
    /// patch doesn't parse, or is a dry run (which writes nothing) unless
    /// `withDryRun`: a dry run still reads every path, so pre-hooks see it.
    private static PatchEdit[] patchEdits(JSONValue args, bool withDryRun = false, PatchSnapshot[] originals = null)
    {
        import nano.tools : ToolError;
        import nano.tools.files : parsePatch, PatchKind, FilePatch;
        auto p = "patch" in args;
        if (p is null || p.type != JSONType.string) return null;
        if (!withDryRun) if (auto d = "dry_run" in args) if (d.type == JSONType.true_) return null;
        FilePatch[] files;
        try files = parsePatch(p.str);
        catch (ToolError) return null; // unparseable: the tool reports it and touches nothing
        PatchEdit[] out_;
        // Hooks that inspect content (`content`, `old_string`, `new_string`)
        // see the same fields a direct write_file/edit_file would carry. A
        // move's destination content comes from the patch's own sequential
        // state (an earlier section's Add/Update), as the tool stages it,
        // never from stale disk.
        import nano.tools.files : applyHunks, resolvePath;
        import std.file : readText, FileException;
        import std.utf : UTFException;
        string[string] staged; // path -> text after the sections so far
        bool[string] absent, unknown;
        bool textOf(string path, out string c)
        {
            auto key = resolvePath(path);
            if (key in absent || key in unknown) return false;
            if (auto t = key in staged) { c = *t; return true; }
            // From the snapshot the tool will verify, never a second disk read.
            if (originals.length)
            {
                import nano.safeio : utf8Text;
                foreach (ref o; originals)
                    if (o.path == key)
                    {
                        if (!o.existed || !o.readable) return false;
                        try c = utf8Text(o.before);
                        catch (UTFException) return false;
                        return true;
                    }
                return false;
            }
            try { c = readText(key); return true; }
            catch (FileException) return false;
            catch (UTFException) return false;
        }
        void set(string path, bool known, string c)
        {
            auto key = resolvePath(path);
            absent.remove(key); unknown.remove(key); staged.remove(key);
            if (known) staged[key] = c; else unknown[key] = true;
        }
        void drop(string path)
        {
            auto key = resolvePath(path);
            staged.remove(key); unknown.remove(key);
            absent[key] = true;
        }
        foreach (fp; files)
        {
            if (fp.kind == PatchKind.add)
            {
                out_ ~= PatchEdit("write_file", JSONValue(["path": fp.path, "content": fp.content]));
                set(fp.path, true, fp.content);
                continue;
            }
            if (fp.kind == PatchKind.delete_)
            {
                out_ ~= PatchEdit("edit_file", JSONValue(["path": fp.path]));
                drop(fp.path);
                continue;
            }
            if (fp.hunks.length == 0)
                out_ ~= PatchEdit("edit_file", JSONValue(["path": fp.path]));
            else
                foreach (h; fp.hunks)
                    out_ ~= PatchEdit("edit_file", JSONValue(["path": fp.path,
                        "old_string": h.old_.length ? h.old_.join("\n") ~ "\n" : "",
                        "new_string": h.new_.length ? h.new_.join("\n") ~ "\n" : ""]));
            string updated;
            bool known = textOf(fp.path, updated);
            if (known && fp.hunks.length)
            {
                try
                {
                    string[] notes;
                    updated = applyHunks(updated, fp.hunks, notes, fp.path);
                }
                catch (ToolError) known = false; // the tool fails the same way and writes nothing
            }
            if (fp.moveTo is null)
            {
                set(fp.path, known, updated);
                continue;
            }
            JSONValue w = JSONValue(["path": fp.moveTo]);
            if (known) w["content"] = updated;
            out_ ~= PatchEdit("write_file", w);
            drop(fp.path);
            set(fp.moveTo, known, updated);
        }
        return out_;
    }

    /// Run the PreToolUse hooks for each path an apply_patch call touches.
    /// A hook can deny or add context; it can't rewrite one path of a patch,
    /// so an input rewrite blocks the call. Null when every path may proceed.
    private string patchPathHooks(const ToolCall call, PatchEdit[] edits, ref string[] context)
    {
        foreach (edit; edits)
            foreach (h; hooks)
            {
                auto o = h.runPreToolUse(edit.name, edit.args, call.id);
                if (auto ctx = o.contextBlock) context ~= ctx;
                auto path = edit.args["path"].str;
                if (o.denies)
                    return o.blockReason.length ? o.blockReason : format("blocked by a PreToolUse hook (on %s)", path);
                if (o.decision == Decision.ask)
                    return o.blockReason.strip.length ? o.blockReason
                        : format("a PreToolUse hook requested confirmation (ask) for %s, which nano cannot prompt for yet; blocking the call", path);
                if (o.updatedInput.type != JSONType.null_)
                    return format("a PreToolUse hook rewrote the input for %s, which apply_patch cannot apply to one path of a patch; "
                            ~ "use edit_file or write_file for that file", path);
            }
        return null;
    }

    /// The paths a successful, non-dry-run apply_patch call changed. Parsed
    /// from the patch text only: the files have already been rewritten, so
    /// re-reading them to re-apply the hunks (as patchEdits would) repeats
    /// the matching work against the new content and computes near-miss
    /// diagnostics that are discarded. Error and dry-run exclusions match
    /// patchEdits.
    private static string[] patchTouches(JSONValue args, bool isError)
    {
        import nano.tools : ToolError;
        import nano.tools.files : patchPaths;
        if (isError) return null;
        auto p = "patch" in args;
        if (p is null || p.type != JSONType.string) return null;
        if (auto d = "dry_run" in args) if (d.type == JSONType.true_) return null;
        try return patchPaths(p.str);
        catch (ToolError) return null; // unparseable: the tool reported it and touched nothing
    }

    /// Every path an apply_patch call touches, as on disk now (before any
    /// hook runs). None when the patch is missing or doesn't parse: the tool
    /// rejects it before touching any path.
    private static PatchSnapshot[] patchOriginalsOf(JSONValue args)
    {
        import nano.tools : ToolError;
        import nano.tools.files : patchOriginals;
        auto p = "patch" in args;
        if (p is null || p.type != JSONType.string) return null;
        try return patchOriginals(p.str);
        catch (ToolError) return null; // unparseable: the tool reports it and touches nothing
    }

    /// Run apply_patch against the snapshot its hook inputs were built from,
    /// when the registry's handler accepts one; otherwise (an unexpected
    /// handler shape) fall back to the plain call, which stages from disk.
    private static string applyPatchPrepared(JSONValue args, ToolRegistry tools, PatchSnapshot[] originals)
    {
        if (auto h = tools.handlerAs!PatchHandler("apply_patch")) return h(args, originals);
        return tools.execute("apply_patch", args);
    }

    /// The call's arguments with the patch's paths listed, so memory recall
    /// sees them as it sees a file tool's `path`.
    private static JSONValue withPaths(JSONValue args, string[] paths)
    {
        if (!paths.length || args.type != JSONType.object) return args;
        JSONValue r = JSONValue(string[string].init);
        foreach (k, v; args.objectNoRef) r[k] = v;
        r["paths"] = JSONValue(paths);
        return r;
    }

    /// Instruction files: nested ones attach to file-tool results.
    Option!ProjectInstructions instructions;
    /// A smart summary is in context: offer history_search/history_read.
    bool historyAvailable;
    /// Append the "look in history" hint to the next failed tool result.
    bool historyHintPending;
    bool historyEnabled() pure const { return log.isSome && historyAvailable; }
    /// `sessions_list` is offered with history, and also whenever messaging
    /// is on so `session_send` targets can be discovered before history is.
    bool sessionsOffered() pure const
    {
        return log.isSome && crossSessionHistory && (historyAvailable || messagesOn);
    }

    /// The messages a replay shows (Rust `replay_history`): the stashed
    /// pre-compaction turns, then the conversation without its synthetic
    /// summary (the first non-system message) or the restated input.
    const(Message)[] replayMessages()
    {
        if (!replayStash.length) return messages;
        const(Message)[] o = rehydrateStash(replayStash, replayStashLog);
        bool skipped;
        foreach (i, ref m; messages)
        {
            if (!skipped && m.role != Role.system) { skipped = true; continue; }
            if (replayRestated.match!(r => r == i, () => false)) continue;
            o ~= m;
        }
        return o;
    }

    /// Adopt a restored session (Rust `load_session`): its conversation
    /// after the current system message, logged to `newLog`, with its
    /// redelivery answers, pending input, plan, timers, recall, compaction
    /// stashes and history state. The mode and session thinking reset, as for
    /// a new session. Returns a note per part of the saved state it dropped.
    string[] loadRestored(ref Restored r, Option!SessionLog newLog)
    {
        import nano.mode : AgentMode;
        string[] dropped;
        // Sub-agents belong to the session being left (issue #266): stop them
        // before the conversation and log are replaced, for every loader
        // (`/resume`, ACP `session/load`).
        leaveSessionSubagents();
        // Setting requests queued for the session being left (model, thinking,
        // sub-agents) must not apply to the loaded one on its next turn.
        control.takeModelRequest();
        control.takeThinkingRequest();
        control.takeSubagentsRequest();
        // Repairs are logged first: a failed write leaves the live session as
        // it was — and closes the incoming log, which the agent never
        // adopted, so its descriptor and lock do not leak into `openHere`.
        auto repairs = danglingRepairs(r.conversation);
        // Once `replaceLog` adopts it the log is the live writer: a later
        // failure (e.g. a throwing timers callback) must not close it.
        scope (failure) if (!ownsLog(newLog)) newLog.ifSome((SessionLog l) { l.close(); });
        foreach (ref m; repairs)
        {
            import nano.session : nowStamp;
            if (!m.timestamp.length) m.timestamp = nowStamp();
            newLog.ifSome((SessionLog l) { m.logLine = l.append(m); });
        }
        // Keep only the system message of the replaced conversation — and
        // copy it: `messages[0 .. 1]` would stay a slice of the old backing
        // array, keeping the whole previous conversation reachable through
        // its allocation, which the conservative GC then scans and the
        // post-resume `releaseHeap` cannot reclaim.
        messages = messages.length && messages[0].role == Role.system ? messages[0 .. 1].dup : null;
        foreach (ref m; r.conversation)
            if (m.role != Role.system) messages ~= m;
        releaseName();
        replaceLog(newLog);
        name = null;
        if (r.name.length)
        {
            if (auto why = setName(r.name, false)) dropped ~= "the handle " ~ r.name ~ ": " ~ why;
        }
        control.mode = AgentMode.normal;
        sessionThinking.nullify();
        completedInputs = r.completed;
        completedStops = r.completedStops;
        completedOutcomes = r.completedOutcomes;
        completedEvicted = EvictedIds.init;
        // A hand-built `Restored` may lack the order: any order will do.
        completedOrder = r.completedOrder.length == r.completed.length ? r.completedOrder : r.completed.keys;
        completedBytes = 0;
        foreach (k, v; completedInputs) completedBytes += completedCost(k, v);
        evictCompleted();
        historyAvailable = r.historyAvailable;
        historyHintPending = r.historyAvailable && !r.historyHintConsumed;
        // Only user requests are pinned (`pinnedUserRequests` ignores the
        // rest). An older log's stash also holds folded tool and assistant
        // turns (issue #301); drop them, and have the next compaction restate
        // the stash in full, because its `pinned_base` would count them.
        pinStash = null;
        foreach (ref m; r.pinStash) if (ctx.isUserRequest(m)) pinStash ~= m;
        pinStashRestate = pinStash.length != r.pinStash.length;
        pinGap = ctx.PinGap.init;
        // A pending restatement writes the stash in full, so it is bounded
        // only after that compaction (issue #312).
        if (!pinStashRestate) trimPins(contextWindow);
        replayStash = r.replayStash;
        replayStashLog = null;
        stashRefLogs = null;
        // Entries `restore` slimmed read their content back from this log
        // (issue #263); without one they replay empty, as a live compaction
        // without a log drops them.
        if (r.replayStashSlim.length)
        {
            replayStashLog = new Option!SessionLog[](replayStash.length);
            foreach (i, slimmed; r.replayStashSlim)
                if (slimmed && i < replayStashLog.length) replayStashLog[i] = newLog;
            newLog.ifSome((SessionLog l) { stashRefLogs ~= l; });
        }
        clippedLines = null;
        restoredLineFloor = 0;
        foreach (ref m; messages)
            if (m.logLine > restoredLineFloor) restoredLineFloor = m.logLine;
        replayRestated = r.replayRestated;
        adoptPending(r);
        plan = Plan.init;
        if (r.plan.type == JSONType.object)
        {
            // A malformed plan is dropped; the session resumes.
            Plan.fromJSON(r.plan).match!((p) { plan = p; }, (e) { dropped ~= "the saved plan: " ~ e; });
        }
        // The log's delta chain length is unknown here: snapshot on the next
        // change so repeated short runs cannot grow the chain without bound.
        planDeltasSinceSnapshot = planSnapshotEvery;
        Timers t;
        try t = Timers.fromJSON(r.timers);
        catch (Exception e) dropped ~= "the saved timers: " ~ e.msg; // malformed timers are dropped, the session resumes
        setTimers(t);
        restoreRecall(r.recall);
        reminders = Reminders.init;
        calibLen = calibTokens = 0;
        compactFloor = 0;
        resetIdleCompaction();
        resetSessionCounters();
        messages ~= repairs;
        return dropped;
    }

    /// Start a fresh session in place (Rust `new_session`, for `/restart`):
    /// the conversation is just `system`, logged to `newLog` (none: not
    /// persisted); mode, session thinking, plan, timers, reminders, hook session,
    /// calibration, history tools and counters are reset. The old log stays.
    /// Whether `messages[0]` was rendered for plan mode.
    bool promptPlan;

    /// Re-render the system prompt with `render` when the mode has changed
    /// since it was rendered: plan mode drops the save guidance and adds the
    /// plan note; leaving it restores them. A loaded session is in normal
    /// mode, so this brings a prompt rendered for plan mode back.
    void syncModePrompt(scope string delegate(bool plan) @safe render)
    {
        import nano.mode : AgentMode;
        bool plan = control.mode == AgentMode.plan;
        if (plan == promptPlan || !messages.length || messages[0].role != Role.system) return;
        messages[0].content = render(plan);
        calibLen = calibTokens = 0; // the usage anchor counted the old prompt
        promptPlan = plan;
    }

    /// `restart`, failure-atomic: the new session's log is created first,
    /// and when that throws the live session (messages, mode, `/thinking`
    /// override, plan, ...) is left untouched and the error propagates.
    void restartWith(scope Option!SessionLog delegate() @safe makeLog, scope string delegate() @safe render)
    {
        auto newLog = makeLog();
        restart(render(), newLog);
    }

    /// Switch to `newLog`, closing the outgoing log (releasing its lock and
    /// descriptor) unless it is the same object.
    /// Whether `l` is the agent's live writer (ownership has transferred).
    bool ownsLog(Option!SessionLog l)
    {
        bool same;
        log.ifSome((SessionLog cur) { l.ifSome((SessionLog n) { same = n is cur; }); });
        return same;
    }

    /// ditto
    bool ownsLog(SessionLog l) { return ownsLog(some(l)); }

    void replaceLog(Option!SessionLog newLog)
    {
        auto old = log;
        log = newLog;
        old.ifSome((SessionLog o) {
            bool same;
            newLog.ifSome((SessionLog n) { same = n is o; });
            if (!same) o.close();
        });
    }

    void restart(string system, Option!SessionLog newLog)
    {
        // Sub-agents belong to the session being left (issue #266).
        leaveSessionSubagents();
        // Setting requests queued for the session being left must not apply
        // to the new one on its first turn (issue #297).
        control.takeModelRequest();
        control.takeThinkingRequest();
        control.takeSubagentsRequest();
        import nano.mode : AgentMode;
        // An empty system prompt (e.g. an ACP host without one) sends no
        // system message at all: some providers reject an empty one.
        messages = system.length ? [Message.system(system)] : null;
        promptPlan = false; // the caller renders `system` for normal mode
        releaseName();
        name = null;
        replaceLog(newLog);
        if (messages.length) log.ifSome((SessionLog l) { l.append(messages[0]); });
        // A new session must not answer a prompt from the previous session's
        // idempotency cache (issue #248).
        completedInputs = null;
        completedStops = null;
        completedOutcomes = null;
        completedOrder = null;
        completedBytes = 0;
        completedEvicted = EvictedIds.init;
        control.mode = AgentMode.normal;
        sessionThinking.nullify();
        plan = Plan.init;
        planDeltasSinceSnapshot = 0;
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
        pinGap = ctx.PinGap.init;
        pinStashRestate = false;
        replayStash = null;
        replayStashLog = null;
        stashRefLogs = null;
        clippedLines = null;
        restoredLineFloor = 0;
        replayRestated = Option!size_t.init;
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
    /// How tool calls recall memories (`memory_recall`): entity (default) or
    /// the pre-entity anchor substring match.
    mem.RecallMode memoryRecallMode = mem.RecallMode.entity;
    /// The working directory's repository (`owner/repo`) entity recall adds
    /// to every call; resolved once by the app (empty: no repo resolution).
    string recallRepo;
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
    void installSystem(string system, bool[string] shown) pure
    {
        if (messages.length && messages[0].role == Role.system && messages[0].content != system)
        {
            messages[0].content = system;
            // The usage anchor counted the old system text.
            calibLen = calibTokens = 0;
        }
        indexShown = shown;
    }

    /// Restore recall state from a session log (null: none recorded). The
    /// installed system message (and so `indexShown`) is kept.
    void restoreRecall(JSONValue j) pure
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
        auto notes = memoryRecallMode == mem.RecallMode.entity
            ? mem.recallEntities(memory, tool, args, recallRepo, recallState, indexShown, budget)
            : mem.recall(memory, tool, args, recallState, indexShown, budget);
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
    ToolDefinition[] offeredTools() pure
    {
        auto all = tools.definitions ~ (planTools ? planDefinitions() : null)
            ~ (outcomeTool ? [outcomeDefinition()] : null) ~ (historyEnabled ? hist.definitions(crossSessionHistory) : null)
            ~ (sessionsOffered ? [hist.sessionsDefinition()] : null)
            ~ (messagesOn && log.isSome ? [peers.sendDefinition()] : null)
            ~ (timerTools ? timerDefinitions() : null) ~ (settingsTools ? [settings.definition()] : null)
            ~ (subagentsOffered ? [subDefinition(subagentCandidates)] ~ subControlDefinitions() : null);
        if (control.mode != AgentMode.plan) return all;
        ToolDefinition[] kept;
        foreach (t; all) if (planAllows(t.name)) kept ~= t;
        return kept;
    }

    /// The `/tools` listing: the tools offered right now (plan mode hides
    /// the mutating ones; plan, outcome, history and timer tools as enabled),
    /// one line each with the description's first line.
    string toolsListing() pure
    {
        import std.string : indexOf;
        string[] out_;
        foreach (d; offeredTools)
        {
            auto nl = d.description.indexOf('\n');
            auto l = nl >= 0 ? d.description[0 .. nl] : d.description;
            out_ ~= format("  %-14s %s", d.name, l.length > 160 ? l[0 .. 160] ~ "…" : l);
        }
        return out_.join("\n");
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
    /// A `/model SPEC` queued mid-turn, applied (on the agent thread) before
    /// the next model call. It reports a failure itself: the request is
    /// dropped either way, so a bad spec can't retry every turn.
    void delegate(string) onModelRequest;

    /// Apply a queued `/model`, if any; whether there was one.
    bool applyModelRequest()
    {
        collectProbes();
        auto spec = control.takeModelRequest();
        if (!spec.length) return false;
        midTurnSwitch = true;
        scope (exit) midTurnSwitch = false;
        if (onModelRequest !is null) onModelRequest(spec);
        return true;
    }

    /// A direct switch (at the prompt or from settings): it supersedes a
    /// `/model` still queued from the last turn, even when `build` fails, and
    /// a failed build changes nothing else.
    void setModel(string spec, LLMClient delegate(string spec, out ConfiguredWindow window) @safe build,
        bool logChange = true)
    {
        control.takeModelRequest();
        ConfiguredWindow window;
        auto c = build(spec, window);
        useClient(c, window, logChange);
    }

    /// Switch to a built client; history carries over, what was learned about
    /// the old model doesn't.
    void useClient(LLMClient c, ConfiguredWindow window, bool logChange = true)
    {
        if (logChange)
        {
            // A resume restores the session's last model (issue #297).
            // Switching models resets the live context window to the new
            // provider's configuration; record that concrete window (0: none),
            // so a resume restores what is live now, not whatever the config
            // resolves to later. Logged before the switch: a failed write
            // leaves the old client in place.
            SessionSettings s;
            s.model = c.providerName ~ "/" ~ c.modelName;
            import std.conv : to;
            s.contextWindow = window.tokens.to!long;
            logSettings(s);
        }
        client = c;
        setConfiguredWindow(window);
        learnedWindow = 0;
        learnedMaxOutput = 0;
        // A mid-turn switch never waits on the endpoint.
        if (midTurnSwitch) startBackgroundProbe();
        else refreshCapabilities();
    }

    /// Record a runtime settings change in the session log (issue #297): a
    /// resumed session restores the latest record of each field.
    void logSettings(const SessionSettings s)
    {
        log.ifSome((SessionLog l) { l.settings(s); });
    }

    /// Set while a queued `/model` applies (`useClient` then probes in the background).
    private bool midTurnSwitch;

    /// Timers the agent set for itself (`timer_*` tools).
    Timers timers;
    /// Offer the timer tools (off for ACP, which has no idle loop to fire them).
    bool timerTools = true;
    /// The nano-coder version, reported by `session_settings get`.
    string harnessVersion;
    /// Offer `session_settings` (issue #293); sub-agents don't get it.
    bool settingsTools = true;
    /// Turns started in this process, for the settings cooldown.
    private size_t turnSerial;
    /// The turn each setting was last changed by the agent.
    private size_t[string] settingChangedAt;
    /// A `compact_now` waiting for the next request boundary.
    private bool agentCompact, agentCompactHasMode;
    private ctx.CompactionMode agentCompactMode;
    private string agentCompactFocus;

    /// The `session_settings` tool: read the session's settings, change an
    /// allowlisted one for this session, or queue a compaction. Every
    /// change is logged and announced.
    private string runSessionSettings(JSONValue args)
    {
        import nano.result : orThrow;
        auto r = settings.parse(args).orThrow!(e => new SettingsError(e));
        final switch (r.action)
        {
            case settings.Action.get:
                bool calibrated;
                auto used = estimateContextTokens(calibrated);
                auto window = contextWindow();
                JSONValue o = [
                    "model": JSONValue(client.providerName ~ "/" ~ client.modelName),
                    "compaction_mode": JSONValue(ctx.modeName(compactionMode)),
                    "auto_compact": JSONValue(autoCompact),
                    "auto_compact_threshold": JSONValue(effectiveAutoCompactThreshold()),
                    "context_tokens": JSONValue(used),
                    "context_window": JSONValue(window),
                    "history_tools": JSONValue(historyEnabled()),
                    "settable": JSONValue(settings.writableKeys.dup),
                ];
                if (harnessVersion.length) o["nano_coder_version"] = harnessVersion;
                if (log.isNone) o["note"] = "no session log: smart and extract compaction fall back to standard";
                return o.toPrettyString;
            case settings.Action.set:
                auto old = ctx.modeName(compactionMode);
                auto next = ctx.modeName(r.mode);
                if (old == next) return format("%s is already %s", r.key, next);
                if (auto at = r.key in settingChangedAt)
                    if (turnSerial < *at + settings.settingCooldownTurns)
                        throw new SettingsError(format("%s was changed %s turn(s) ago; it can change again "
                            ~ "after %s turns, or the user can change it with /settings", r.key, turnSerial - *at,
                            settings.settingCooldownTurns));
                compactionMode = r.mode;
                settingChangedAt[r.key] = turnSerial;
                announceSetting(r.key, old, next, r.reason);
                {
                    // A resume restores the session's compaction mode (#297).
                    SessionSettings s;
                    s.compactionMode = next;
                    logSettings(s);
                }
                return format("%s: %s → %s for this session (the user's config is unchanged)", r.key, old, next);
            case settings.Action.compactNow:
                agentCompact = true;
                agentCompactHasMode = r.hasMode;
                agentCompactMode = r.mode;
                agentCompactFocus = r.focus;
                auto mode = ctx.modeName(r.hasMode ? r.mode : compactionMode);
                announceSetting("compact_now", "", mode, r.reason);
                return format("Compaction (%s) queued: it runs before your next request, then you continue from "
                    ~ "the summary.", mode);
        }
    }

    /// Log and show an agent-made settings change.
    private void announceSetting(string key, string old, string next, string reason)
    {
        log.ifSome((SessionLog l) { l.setting(key, old, next, reason); });
        stdErr.writefln("[agent] %s%s%s%s", key, old.length ? ": " ~ old ~ " → " : " ", next,
            reason.length ? " (" ~ reason ~ ")" : "");
    }
    /// Whether `agent` may start background sub-agents: only hosts that serve
    /// them between turns (the CLI prompt loops). ACP sets it false (#266).
    bool backgroundSubagents = true;
    /// Called after the timers change (the UI updates the status bar).
    void delegate() onTimersChanged;
    /// The clock timers run on (unix seconds); tests replace it.
    long delegate() now;

    long timerNow()
    {
        import std.datetime.systime : Clock;
        return now !is null ? now() : wallNow.toUnixTime;
    }

    package string runTimerTool(string name, JSONValue args)
    {
        auto before = Timers(timers.items.dup, timers.pending.dup, timers.lastId);
        auto o = timers.apply(name, args, timerNow());
        if (o.changed)
        {
            // A change the log did not record is rolled back, so the live
            // timers never run ahead of what a resume restores.
            scope (failure) timers = before;
            timersChanged();
        }
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
        auto before = Timers(timers.items.dup, timers.pending.dup, timers.lastId);
        Timer[] closed;
        auto due = timers.takeDue(t, closed);
        if (!due.length) return null;
        {
            // Unrecorded, they stay due and fire on the next try.
            scope (failure) timers = before;
            timersChanged();
        }
        stepsSinceTimerNote = 0; // a fresh firing restarts the nudge interval
        notice = firedNotice(due);
        import std.algorithm : map;
        auto msg = firedMessage(due, t);
        if (closed.length)
        {
            // Both the display and the model need it: earlier reminders still
            // name the closed ids, and the model would keep chasing them.
            auto why = format("\n(auto-closed fired timer%s %s: at most %s wait for timer_done)",
                closed.length == 1 ? "" : "s", closed.map!(x => x.id.to!string).join(", "), maxPending);
            notice ~= why;
            msg ~= why;
        }
        return msg;
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
            return;
        }
        if (!timers.pending.length) { stepsSinceTimerNote = 0; return; }
        if (++stepsSinceTimerNote < pendingNudgeEvery) return;
        stepsSinceTimerNote = 0;
        auto nudge = Message.auto_(wrapReminder(pendingNudge(timers.pending, timerNow())));
        nudge.timer = true;
        push(nudge);
    }
    package size_t stepsSinceTimerNote;

    /// Replace the timers with ones restored from the session log.
    void setTimers(Timers t)
    {
        timers = t;
        if (onTimersChanged !is null) onTimersChanged();
    }

    package string runPlanTool(string name, JSONValue args)
    {
        auto before = plan.dup;
        // The plan's error is the tool's message to the model.
        auto o = plan.apply(name, args).orThrow!(e => new ToolError(e));
        if (o.changed)
        {
            // As for timers: a change that cannot be recorded is rolled back
            // (the rollback itself lives in `planChanged`, which disarms it
            // once the change is persisted).
            planChanged(before, o.restarted);
        }
        return o.text;
    }

    /// Log a plan change as a delta against `before` (issue #205: a full
    /// snapshot per change rewrites every note, and `plan` records were 8% of
    /// the largest logs), with a full snapshot every `planSnapshotEvery`
    /// changes so a resume never replays an unbounded delta chain.
    private enum size_t planSnapshotEvery = 20;
    private size_t planDeltasSinceSnapshot;

    private void planChanged(Plan before, bool restarted = false)
    {
        import std.algorithm : canFind;
        // Only persistence may roll the plan back: once the change is
        // recorded the log holds it, so a throwing notification must leave
        // the live plan matching what resume will restore.
        bool persisted;
        scope (failure) if (!persisted) plan = before;
        log.ifSome((SessionLog l) {
            // Keep the finished plan findable by the history tools; a failed
            // write rolls the restart back with the rest.
            if (restarted) l.planArchive(before.toJSON);
            if (++planDeltasSinceSnapshot >= planSnapshotEvery || restarted
                || (before.items.length == 0 && plan.items.length > 1))
            {
                l.plan(plan.toJSON);
                planDeltasSinceSnapshot = 0;
            }
            else
            {
                JSONValue goal = JSONValue(null);
                if (before.goal != plan.goal) goal = JSONValue(plan.goal);
                JSONValue[] upserts;
                foreach (i, ref it; plan.items)
                    if (i >= before.items.length || it != before.items[i])
                        upserts ~= it.toJSON;
                uint[] drop;
                foreach (ref b; before.items[0 .. min(before.items.length, plan.items.length)])
                    if (!plan.items.canFind!(i => i.id == b.id)) drop ~= b.id;
                l.planDelta(goal, upserts, drop, before.items.length);
            }
        });
        persisted = true;
        reminders.planChanged();
        if (onPlanChanged !is null) onPlanChanged();
    }

    /// Replace the plan with one carried over from an earlier run, telling
    /// the model about it unless `announce` is false.
    void setPlan(Plan p, bool announce)
    {
        // As in `planChanged`: only persistence may roll the plan back. A
        // failure before the snapshot is recorded restores the previous plan,
        // so a later delta never references an unrecorded baseline.
        auto before = plan.dup;
        bool persisted;
        scope (failure) if (!persisted) plan = before;
        plan = p;
        if (announce && planTools && !plan.empty) push(Message.user(plan.carriedOverNote));
        log.ifSome((SessionLog l) { l.plan(plan.toJSON); });
        persisted = true;
        planDeltasSinceSnapshot = 0;
    }

    private static string withContext(string text, string[] context) pure
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

    private void syncHookSession(HookManager h) pure
    {
        h.setSession(log.match!(l => l.id, () => ""), log.match!(l => l.path, () => ""),
            control.mode == AgentMode.plan ? "plan" : "default");
    }

    private string toolNames() pure
    {
        string s;
        foreach (d; tools.definitions) s ~= (s.length ? ", " : "") ~ d.name;
        return s;
    }
}

version (unittest)
{

    class NullEvents : AgentEvents
    {
        mixin AgentEventDefaults;
        string shown;
        string[] tools;
        void text(bool r, string s) pure { if (!r) shown ~= s; }
        void toolStart(const ref ToolCall c) pure { tools ~= c.name; }
        void toolEnd(const ref ToolCall c, string res, bool err) pure {}
        void usage(TokenUsage u) pure {}
        string[] steered;
        void userMessage(string t) pure { steered ~= t; }
        void assistantMessage(string t, string r) pure {}
        size_t restarts;
        void responseRestarted() pure { restarts++; }
        size_t generations;
        void generationStart() pure { generations++; }
    }

    // The interface defaults cover the events a renderer need not care
    // about: NullEvents never mentions `subagents` or `beforeFreshCall`,
    // yet compiles and runs a turn (the agent calls both unconditionally).
    unittest
    {
        import nano.providers.mock;
        auto reg = new ToolRegistry;
        auto mock = new MockClient([LLMResponse("ok")]);
        auto agent = new Agent(mock, reg, Policy.init, "sys");
        assert(agent.run("go", new NullEvents) == "ok");
    }
}

// rust: agent.rs::malformed_tool_call_skips_handler_and_reports_actionable_error
unittest
{
    import nano.providers.mock;
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
    import std.algorithm : canFind;
    assert(second[$ - 1].content.canFind("malformed JSON") && second[$ - 1].content.canFind("`echo`"));
}

// rust: agent.rs::steer_during_tool_call_joins_next_model_call
unittest
{
    import nano.providers.mock;
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
    import nano.providers.mock;
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
    import nano.providers.mock;
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
    import nano.providers.mock;
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
    import nano.providers.mock;
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
    import nano.providers.mock;
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
// rust: agent.rs::an_automatic_timer_turn_marks_its_message_auto_initiated
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

// Round-5 review fix for issue #205: replacing the agent's log closes the
// outgoing one (releasing its lock and descriptor); a no-op replace keeps it.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import nano.providers.mock;
    import nano.session : SessionLog, newSessionId;
    auto dir = buildPath(tempDir, "nano-d-replacelog-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto agent = new Agent(new MockClient([LLMResponse("ok")]), new ToolRegistry, Policy.init, "sys");
    auto first = new SessionLog(dir, "mock/m", "/w");
    agent.replaceLog(some(first));
    assert(first.isOpenForWrite, "the live log stays open");
    auto second = new SessionLog(dir, "mock/m", "/w");
    agent.replaceLog(some(second));
    assert(!first.isOpenForWrite, "a replaced log is closed (lock and descriptor released)");
    assert(second.isOpenForWrite, "the incoming log stays open");
    // Re-setting the same log is a no-op, and dropping the log closes it.
    agent.replaceLog(some(second));
    assert(second.isOpenForWrite, "replacing a log with itself closes nothing");
    agent.replaceLog(Option!SessionLog.init);
    assert(!second.isOpenForWrite, "teardown (no new log) closes the outgoing log");
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
// rust: agent.rs::a_resumed_session_keeps_attachments_and_survives_a_missing_file
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
    // A resumed session keeps the attachment (by hash) on its tool result.
    {
        import nano.session : SessionLog, restore;
        import std.algorithm : filter;
        import std.array : array;
        auto log = new SessionLog(buildPath(dir, "sessions"), "mock/m", "/w");
        log.append(agent.messages[0]);
        foreach (ref m; agent.messages[1 .. $]) log.append(m);
        auto r = restore(log.path);
        auto resumed = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
        resumed.loadRestored(r, some(new SessionLog(log.path)));
        auto kept = resumed.messages.filter!(m => m.attachments.length).array;
        assert(kept.length == 1 && kept[0].attachments[0].sha256 == t.attachments[0].sha256);
    }
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
    import nano.providers.mock;
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

// Resuming over a system-message-only session must not keep the replaced
// conversation's backing array alive through a slice: `loadRestored` copies
// the kept system message so the old allocation is collectable.
unittest
{
    import nano.session : Restored;
    import nano.providers.mock;
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    agent.messages ~= [Message.user("u1"), Message.assistant("a1")];
    // Restore a system-only conversation so nothing is appended after the
    // kept system message: an append could reallocate and mask a missing copy.
    auto old = agent.messages;
    Restored r;
    agent.loadRestored(r, Option!SessionLog.init);
    assert(agent.messages.length == 1 && agent.messages[0].role == Role.system);
    assert(agent.messages.ptr !is old.ptr, "kept system message aliases the old array");
    old[0].content = "overwritten";
    assert(agent.messages[0].content == "sys", agent.messages[0].content);
}

// `restart` starts a clean session: no idempotency cache carried over from the
// previous session, and no empty system message when there is no prompt.
unittest
{
    import nano.providers.mock;
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    agent.completedInputs["id1"] = "old";
    agent.completedStops["id1"] = StopReason.cancelled;
    agent.completedOutcomes["id1"] = JSONValue(1);
    agent.restart("", Option!SessionLog.init);
    assert(agent.completedInputs.length == 0);
    assert(agent.completedStops.length == 0);
    assert(agent.completedOutcomes.length == 0);
    assert(agent.messages.length == 0);
    agent.restart("sys2", Option!SessionLog.init);
    assert(agent.messages.length == 1 && agent.messages[0].content == "sys2");
}

/// The tool result a crash left unwritten (Rust's INTERRUPTED_TOOL_RESULT).
enum interruptedToolResult = "Error: the harness stopped before this tool call completed; its outcome is unknown.";

/// Error results for the tool calls of the last assistant message with calls
/// that no later message answers.
Message[] danglingRepairs(const Message[] conversation) pure
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
private string safeName(string s) pure
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
    import nano.providers.mock;
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
    assert(tool.content.indexOf("); full output saved to " ~ buildPath(dir, "sess-x.spill")) > 0,
        tool.content);
    assert(dirEntries(buildPath(dir, "sess-x.spill"), SpanMode.shallow).array.length == 1);
}

/// The stop reason a log records by value (`max_tokens`); unknown: end_turn.
StopReason stopReasonFrom(string value) @safe pure nothrow
{
    import std.traits : EnumMembers;
    static foreach (m; EnumMembers!StopReason)
        if (value == m) return m;
    return StopReason.endTurn;
}

/// The note appended to a tool result when the loop detector ends the turn.
enum string loopHardStopNote = "This call already ran, but it has repeated too many times: the turn is ending "
    ~ "as blocked and any further retries are being stopped. Do not retry it.";

/// The reminder asking the model to continue a cut-off reply.
Message continuationReminder(long completionTokens) pure
{
    auto m = Message.auto_(wrapReminder(truncatedContinuationNote(completionTokens)));
    m.continuation = true;
    return m;
}

/// Replay a turn's logged messages over a continuation snapshot: the answer
/// carried across cut-off chunks and how many continuations ran. A fired
/// timer keeps the prefix; any other user message, a tool run or a finished
/// reply starts a new answer segment (issue #114).
auto replayContinuation(const ref PendingInput snapshot, const Message[] tail) pure
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

string truncatedContinuationNote(long completionTokens) pure
{
    auto at = completionTokens > 0 ? format(" at the output-token limit (%s tokens)", completionTokens)
        : " at the output-token limit";
    return "Your previous reply was cut off" ~ at ~ "; any tool call in it was not run. "
        ~ "Continue from where you left off, and write large outputs in smaller pieces "
        ~ "(e.g. `write_file` a skeleton, then `edit_file` to fill it in) so each reply "
        ~ "fits within the limit.";
}

private LLMResponse cutText(string content, long tokens) pure
{
    auto r = LLMResponse(content);
    r.stopReason = "length";
    r.usage.outputTokens = tokens;
    return r;
}

// rust: agent.rs::a_reply_cut_off_at_the_output_limit_continues_instead_of_ending
unittest
{
    import nano.providers.mock;
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
    import nano.providers.mock;
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
    import nano.providers.mock;
    auto mock = new MockClient([cutText("one ", 100), cutText("two ", 100), LLMResponse("three")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "one two three");
    assert(agent.lastStop == StopReason.endTurn);
}

// rust: agent.rs::a_tool_run_resets_the_continuation_accumulator
unittest
{
    import nano.providers.mock;
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

    private LLMResponse probeCall(string id, string path) pure
    {
        return LLMResponse("", "", [ToolCall.fromRaw(id, "probe", JSONValue(["path": path]).jsonText)]);
    }

    private ToolRegistry probeTools() pure
    {
        auto reg = new ToolRegistry;
        reg.register(ToolDefinition("probe", "", parseJSON(`{}`)), (JSONValue a) => "no such file");
        return reg;
    }

    private string[] toolTexts(Agent a) pure
    {
        string[] r;
        foreach (m; a.messages) if (m.role == Role.tool) r ~= m.content;
        return r;
    }

    private size_t pinCount(Agent a) pure
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

unittest // a new system text drops the usage anchor, so estimates count it
{
    import nano.providers.mock : MockClient;
    LLMResponse[] none;
    auto agent = new Agent(new MockClient(none), new ToolRegistry, Policy.init, "short");
    agent.push(Message.user("hi"));
    agent.calibLen = agent.messages.length;
    agent.calibTokens = 10;
    bool calibrated;
    assert(agent.estimateContextTokens(calibrated) == 10 && calibrated);
    agent.installSystem("short", null); // unchanged: kept
    assert(agent.calibLen);
    import std.array : replicate;
    agent.installSystem("long ".replicate(4000), null);
    auto estimate = agent.estimateContextTokens(calibrated);
    assert(!calibrated && estimate > 500, "the longer system text is counted");
}

unittest // extreme usage anchors clamp instead of halting the estimate
{
    import nano.providers.mock : MockClient;
    LLMResponse[] none;
    auto agent = new Agent(new MockClient(none), new ToolRegistry, Policy.init, "sys");
    agent.push(Message.user("hi"));
    agent.calibLen = agent.messages.length;
    bool calibrated;
    // A malformed provider report near 2^63 sums past size_t.max on 64-bit:
    // the anchor clamps there and the estimate stays calibrated (and huge).
    agent.calibTokens = size_t.max;
    assert(agent.estimateContextTokens(calibrated) == size_t.max && calibrated);
    // So does a saturated floor: the threshold check wraps to "due" on
    // nothing, it must read "not due" instead of halting or wrapping low.
    agent.compactFloor = size_t.max;
    assert(!agent.overThresholdAt(size_t.max));
    agent.compactFloor = 0;
    // The report of a successful compaction formats clamped counts rather
    // than throwing, so the run never reads as failed over bookkeeping.
    auto rep = CompactReport(4, 2, size_t.max, size_t.max, 2, null, false, ctx.CompactionMode.standard);
    import std.algorithm : canFind;
    assert(rep.toString.canFind("compacted 2 messages"), rep.toString);
    // The idle report saturates its percentages instead of throwing.
    auto idle = IdleCompactReport(rep, 1);
    assert(idle.percentBefore == size_t.max && idle.percentAfter == size_t.max);
    // A saturated estimate plus the output margin must not wrap low and
    // grant a large output budget: the exhausted context gets the minimum.
    agent.configuredWindow = 12_000;
    assert(agent.requestMaxTokens() == 1);
    agent.configuredWindow = 0;
    agent.capabilities.window = 12_000;
    agent.capabilities.promptCap = true;
    agent.capabilities.totalWindow = 12_000;
    assert(agent.requestMaxTokens() == 1);
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


// apply_patch passes the same gate as the file tools for every touched path:
// a policy-denied path in a multi-file patch writes nothing and is named,
// plan mode blocks it, an `Edit` hook sees each path, and a successful patch
// counts as an edit for verify-before-complete.
unittest
{
    import nano.providers.mock;
    import nano.claude_hooks : Hook, Event;
    import nano.tools.files : ReadState, registerFiles = register;
    import std.algorithm : canFind;
    import std.file : tempDir, write, readText, mkdirRecurse, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import core.time : seconds;
    auto dir = buildPath(tempDir, format("nano-agent-patch-%s", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto ok = buildPath(dir, "ok.txt"), secret = buildPath(dir, ".env");
    write(ok, "one\n");
    write(secret, "KEY=1\n");
    string patchFor(string target)
    {
        return "*** Begin Patch\n*** Update File: " ~ ok ~ "\n@@\n-one\n+two\n*** Update File: " ~ target
            ~ "\n@@\n-KEY=1\n+KEY=2\n*** End Patch\n";
    }
    auto call = (string id, string patch) => ToolCall.fromRaw(id, "apply_patch", JSONValue(["patch": patch]).toString);
    string toolText(Agent a, string id)
    {
        foreach (m; a.messages) if (m.role == Role.tool && m.toolCallId == id) return m.content;
        assert(0, "no tool result for " ~ id);
    }
    auto reg = new ToolRegistry;
    registerFiles(reg, new ReadState);
    auto ev = new NullEvents;

    // A deny rule on one path blocks the whole patch: nothing is written.
    auto mock = new MockClient([LLMResponse("", "", [call("p1", patchFor(secret))]), LLMResponse("done")]);
    auto agent = new Agent(mock, reg, Policy.fromConfig(parseJSON(`{"deny":["Edit(**/.env)"]}`)), "sys");
    agent.run("patch", ev);
    auto t = toolText(agent, "p1");
    assert(t.canFind("denies apply_patch on " ~ secret), t);
    assert(readText(ok) == "one\n" && readText(secret) == "KEY=1\n");

    // Plan mode blocks it like edit_file.
    mock = new MockClient([LLMResponse("", "", [call("p2", patchFor(secret))]), LLMResponse("done")]);
    agent = new Agent(mock, reg, Policy.init, "sys");
    agent.control.mode = AgentMode.plan;
    agent.run("patch", ev);
    assert(toolText(agent, "p2").canFind("disabled in plan mode"), toolText(agent, "p2"));
    assert(readText(ok) == "one\n");
    agent.control.mode = AgentMode.normal;

    // A PreToolUse hook matching `Edit` sees each path and can deny one.
    Hook h;
    h.event = Event.preToolUse;
    h.matcher = "Edit";
    h.command = `grep -q '\.env' && { echo "no env edits" >&2; exit 2; }; exit 0`;
    h.timeout = 10.seconds;
    mock = new MockClient([LLMResponse("", "", [call("p3", patchFor(secret))]), LLMResponse("done")]);
    agent = new Agent(mock, reg, Policy.init, "sys");
    agent.hooks = some(new HookManager([h], tempDir));
    agent.run("patch", ev);
    assert(toolText(agent, "p3").canFind("no env edits"), toolText(agent, "p3"));
    assert(readText(ok) == "one\n" && readText(secret) == "KEY=1\n");

    // Applied: both files change, and completing needs a check first.
    auto done = ToolCall.fromRaw("o1", "report_outcome", `{"status":"completed","summary":"done"}`);
    mock = new MockClient([LLMResponse("", "", [call("p4", patchFor(secret)), done]),
        LLMResponse("", "", [ToolCall.fromRaw("o2", "report_outcome", `{"status":"completed","summary":"done"}`)])]);
    agent = new Agent(mock, reg, Policy.init, "sys");
    agent.run("patch", ev);
    assert(toolText(agent, "p4").canFind("Applied patch to 2 file(s)"), toolText(agent, "p4"));
    assert(readText(ok) == "two\n" && readText(secret) == "KEY=2\n");
    assert(toolText(agent, "o1").canFind(verifyReminder));
}

unittest // apply_patch hooks see the content a direct write_file/edit_file would carry
{
    auto args = JSONValue(["patch": "*** Begin Patch\n*** Add File: n.txt\n+hello\n*** Update File: u.txt\n@@\n-old\n+new\n*** End Patch\n"]);
    auto edits = Agent.patchEdits(args);
    assert(edits.length == 2);
    assert(edits[0].name == "write_file" && edits[0].args["content"].str == "hello\n");
    assert(edits[1].name == "edit_file" && edits[1].args["old_string"].str == "old\n" && edits[1].args["new_string"].str == "new\n");
}

unittest // a move's destination hook input comes from the patch's own sequential state
{
    // An earlier Add supplies the moved content (nothing is on disk).
    auto added = JSONValue(["patch": "*** Begin Patch\n*** Add File: nano-test-none/a.txt\n+SECRET\n"
        ~ "*** Move File: nano-test-none/a.txt -> nano-test-none/b.txt\n*** End Patch\n"]);
    auto edits = Agent.patchEdits(added);
    assert(edits.length == 3 && edits[2].name == "write_file");
    assert(edits[2].args["content"].str == "SECRET\n", edits[2].args.toString);
    // An earlier Update is carried into the move, and the move's own hunks apply on top.
    auto updated = JSONValue(["patch": "*** Begin Patch\n*** Add File: nano-test-none/c.txt\n+one\n"
        ~ "*** Update File: nano-test-none/c.txt\n@@\n-one\n+two\n"
        ~ "*** Update File: nano-test-none/c.txt\n*** Move to: nano-test-none/d.txt\n@@\n-two\n+three\n*** End Patch\n"]);
    edits = Agent.patchEdits(updated);
    assert(edits[$ - 1].args["path"].str == "nano-test-none/d.txt" && edits[$ - 1].args["content"].str == "three\n",
        edits[$ - 1].args.toString);
    // A source deleted earlier in the patch yields no content rather than stale disk text.
    auto deleted = JSONValue(["patch": "*** Begin Patch\n*** Delete File: nano-test-none/e.txt\n"
        ~ "*** Move File: nano-test-none/e.txt -> nano-test-none/f.txt\n*** End Patch\n"]);
    edits = Agent.patchEdits(deleted);
    assert("content" !in edits[$ - 1].args.objectNoRef);
}

// issue #297: setting requests queued for the session being left (model,
// thinking, sub-agents) are dropped when another session is loaded, so they
// cannot overwrite the restored settings on its next turn.
unittest
{
    import nano.session : Restored;
    import nano.providers.mock;
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    agent.control.requestModel("mock/old");
    agent.control.requestThinking("high");
    agent.control.requestSubagents(false);
    Restored r;
    agent.loadRestored(r, Option!SessionLog.init);
    assert(agent.control.takeModelRequest() is null);
    assert(agent.control.takeThinkingRequest() is null);
    assert(agent.control.takeSubagentsRequest() == 0);
}

// issue #297: `restart` (`/restart`, ACP `session/new`) also drops queued
// setting requests from the session being left.
unittest
{
    import nano.providers.mock;
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    agent.control.requestModel("mock/old");
    agent.control.requestThinking("high");
    agent.control.requestSubagents(false);
    agent.restart("sys", Option!SessionLog.init);
    assert(agent.control.takeModelRequest() is null);
    assert(agent.control.takeThinkingRequest() is null);
    assert(agent.control.takeSubagentsRequest() == 0);
}
