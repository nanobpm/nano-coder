/// The agent's turn loop as a pure state machine.
///
/// `step(state, event)` decides what happens next: it returns the new state
/// and the effects to carry out (call the model, run the tools, run a Stop
/// hook, compact, ask to keep going, finish). It does no I/O itself.
/// `Agent.runTurn` is the interpreter: it performs each effect and feeds what
/// happened back in as the next event. The decisions (the turn cap, retries
/// after a dropped stream, an output-cap rejection or a context overflow,
/// continuing a reply cut off at the output limit, steers extending a turn,
/// Stop hooks keeping it going, reported outcomes and the loop detector's
/// hard stop) are all here, so they are tested by feeding events in, with no
/// model, tools or terminal.
module nano.turn;
@safe:

import std.sumtype : SumType, match;
import nano.mode : AgentMode;
import ctx = nano.context;

pure:

/// Why a turn ended (what an ACP `PromptResponse` reports).
enum StopReason : string
{
    endTurn = "end_turn",
    cancelled = "cancelled",
    maxTurnRequests = "max_turn_requests",
    maxTokens = "max_tokens",
}

/// The model calls a headless run (ACP, `-p`) may make in one turn when no
/// cap is configured, or in auto mode.
enum headlessSafetyCap = 300;
/// How many times a reply cut off at the output-token limit is continued.
enum maxTruncatedContinuations = 3;
/// How many times a dropped reply stream is asked for again, per call.
enum maxStreamRestarts = 10;

/// What bounds a turn. Fixed for the turn.
struct Limits
{
    /// The configured cap on model calls per turn (0 or less: none).
    long maxIterations;
    /// No one to ask (ACP, `-p`): stop at the cap, or at `headlessSafetyCap`.
    bool headless;
    /// How many times Stop hooks may keep one turn going.
    size_t maxStopBlocks = 3;
}

/// Which answer a Stop hook is being asked about.
enum Pending
{
    none,
    /// A tool-free answer.
    answer,
    /// An outcome reported with `report_outcome`.
    outcome,
}

/// Where a turn is. A value: `step` returns a new one.
struct TurnState
{
    Limits limits;
    /// Model calls started, and extra calls granted past the cap.
    long iteration, granted;
    /// The cap for the current call (recomputed from the live mode each call).
    long budget;
    /// Output-limit continuations: the cut-off chunks so far, and how many.
    string continued;
    size_t truncations;
    /// How many times a Stop hook has kept this turn going.
    size_t stopBlocks;
    /// Per model call: dropped streams asked for again, and whether the
    /// output-cap and context-overflow retries were used.
    size_t dropped;
    bool capRetried, overflowRetried;
    /// The latest answer text (what a capped turn returns).
    string last;
    /// What a Stop hook result applies to.
    Pending pending;
    /// A reported outcome's response, while its Stop gate runs.
    string reportedResponse;

    /// A turn starting with `continued`/`truncations` rebuilt by a resume.
    static TurnState start(Limits limits, string continued = null, size_t truncations = 0) pure
    {
        TurnState s;
        s.limits = limits;
        s.continued = continued;
        s.truncations = truncations;
        return s;
    }
}

// ---- Events: what happened ------------------------------------------------

/// A model call is due (the start, or after a `Next` effect).
struct CallDue { AgentMode mode; bool cancelled; }
/// The answer to `AskKeepGoing`.
struct KeepGoing { bool yes; }
/// The model replied (already recorded in the conversation).
struct Replied
{
    string content;
    /// Cut off at the output-token limit.
    bool cut;
    size_t toolCalls;
    long outputTokens;
    /// Steers are queued, and whether the turn was cancelled meanwhile.
    bool steersWaiting, cancelled;
}
/// How a model call failed.
enum Failure
{
    /// The user cancelled.
    cancelled,
    /// The connection dropped mid-reply.
    interrupted,
    /// Any other error; `message` says which.
    error,
}
/// The model call failed.
struct CallFailed
{
    Failure failure;
    string message;
    /// The `max_tokens` the failed request sent.
    long sentMaxTokens;
    bool cancelled;
}
/// The compaction a context overflow asked for finished.
struct Compacted { bool ok; bool cancelled; }
/// The Stop hooks ran.
struct StopHookRan { bool blocked; string reason; bool cancelled; }
/// The tool calls ran.
struct ToolsRan
{
    /// The loop detector stopped the turn.
    bool loopStopped;
    /// `report_outcome` was called; its response.
    bool reported;
    string reportedResponse;
    bool cancelled;
}

alias Event = SumType!(CallDue, KeepGoing, Replied, CallFailed, Compacted, StopHookRan, ToolsRan);

// ---- Effects: what to do --------------------------------------------------

/// Gather a `CallDue` (the live mode, cancellation) and go round again.
struct Next {}
/// Ask the user whether to continue past the turn cap; answer `KeepGoing`.
struct AskKeepGoing {}
/// Call the model; answer `Replied` or `CallFailed`. `fresh`: a new call
/// (absorb steers, fire timers, compact at the threshold, apply queued
/// model and thinking changes), not a retry of the last one.
struct CallModel { bool fresh; }
/// Report that a dropped stream is being asked for again.
struct Restarting { size_t attempt; string message; }
/// The provider rejected `max_tokens`: use `cap` from now on.
struct LimitOutput { long cap; string message; }
/// The request overflowed the context: learn the window (`learned`, or 0 to
/// estimate it) and compact; answer `Compacted`.
struct CompactForOverflow { size_t learned; }
/// Re-raise the failure that the last `CallFailed` reported.
struct Rethrow {}
/// End the turn as cancelled.
struct Cancel {}
/// Ask for the rest of a cut-off reply.
struct ContinueCutOff { long outputTokens; }
/// Persist the in-flight continuation (`continued`, `truncations`).
struct SyncContinuation { string continued; size_t truncations; }
/// Show a note in the transcript.
struct Notice { string text; }
/// Run the Stop hooks (`again`: one already blocked this turn); answer `StopHookRan`.
struct RunStopHook { bool again; }
/// A Stop hook blocked: add its reason for the model.
struct StopBlocked { string reason; }
/// Run the reply's tool calls; answer `ToolsRan`.
struct RunTools {}
/// End the turn with the reported outcome, or the loop detector's block.
struct FinishOutcome { bool loopStopped; }
/// End the turn with `answer`.
struct Finish { string answer; StopReason stop; }

alias Effect = SumType!(Next, AskKeepGoing, CallModel, Restarting, LimitOutput, CompactForOverflow, Rethrow, Cancel,
    ContinueCutOff, SyncContinuation, Notice, RunStopHook, StopBlocked, RunTools, FinishOutcome, Finish);

/// The state after an event, and what to do about it.
struct Step
{
    TurnState state;
    Effect[] effects;
}

/// The default reason shown when a Stop hook blocks without one.
enum stopHookDefaultReason = "A Stop hook asked the agent to keep going.";

/// The turn's next state and effects after `event`.
Step step(TurnState s, Event event)
{
    return event.match!(
        (CallDue e) => callDue(s, e),
        (KeepGoing e) => keepGoing(s, e),
        (Replied e) => replied(s, e),
        (CallFailed e) => callFailed(s, e),
        (Compacted e) => compacted(s, e),
        (StopHookRan e) => stopHookRan(s, e),
        (ToolsRan e) => toolsRan(s, e),
    );
}

private Step to(TurnState s, Effect[] effects...) { return Step(s, effects.dup); }
private Effect fx(T)(T t) { return Effect(t); }

/// The cap for this call: interactive normal mode asks to keep going at the
/// configured cap; auto mode has none; headless runs stop at the cap, or at
/// the safety cap when there is none.
private long budgetFor(const TurnState s, AgentMode mode)
{
    const l = s.limits;
    const headlessCap = l.headless && (l.maxIterations <= 0 || mode == AgentMode.auto_);
    if (headlessCap) return headlessSafetyCap + s.granted;
    if (mode == AgentMode.auto_ || l.maxIterations <= 0) return long.max;
    return l.maxIterations + s.granted;
}

private Step callDue(TurnState s, CallDue e)
{
    s.iteration++;
    s.budget = budgetFor(s, e.mode);
    if (s.iteration > s.budget)
    {
        if (e.mode == AgentMode.normal && !s.limits.headless) return to(s, fx(AskKeepGoing()));
        return capped(s);
    }
    if (e.cancelled) return to(s, fx(Cancel()));
    s.dropped = 0;
    s.capRetried = s.overflowRetried = false;
    return to(s, fx(CallModel(true)));
}

private Step capped(TurnState s)
{
    import std.format : format;
    import std.string : stripLeft;
    auto note = format("[stopped after %s LLM calls without a final answer]", s.iteration - 1);
    return to(s, fx(Notice("\n" ~ note)), fx(Finish((s.last ~ "\n" ~ note).stripLeft, StopReason.maxTurnRequests)));
}

private Step keepGoing(TurnState s, KeepGoing e)
{
    if (!e.yes) return capped(s);
    s.granted += s.limits.maxIterations;
    s.iteration--;
    return to(s, fx(Notice("\n[continuing past the turn cap]\n")), fx(Next()));
}

private Step callFailed(TurnState s, CallFailed e)
{
    if (e.failure == Failure.cancelled || e.cancelled) return to(s, fx(Cancel()));
    if (e.failure == Failure.interrupted)
    {
        // Nothing of the reply was kept, so ask again (the request itself
        // waits for the network).
        if (++s.dropped > maxStreamRestarts) return to(s, fx(Rethrow()));
        return to(s, fx(Restarting(s.dropped, e.message)), fx(CallModel(false)));
    }
    if (!s.capRetried && ctx.isOutputCapError(e.message) && !ctx.isContextOverflow(e.message))
    {
        // The provider caps output below the max_tokens this request sent:
        // learn the cap (else halve what was sent) and retry once.
        s.capRetried = true;
        const sent = e.sentMaxTokens;
        long cap = ctx.outputCapFromError(e.message);
        if (cap <= 0) cap = sent / 2 > 1_024 ? sent / 2 : 1_024;
        if (cap < 256) cap = 256;
        if (cap < sent) return to(s, fx(LimitOutput(cap, e.message)), fx(CallModel(false)));
    }
    if (s.overflowRetried || !ctx.isContextOverflow(e.message)) return to(s, fx(Rethrow()));
    // The request did not fit: learn the window, compact, retry once.
    s.overflowRetried = true;
    return to(s, fx(CompactForOverflow(ctx.limitFromError(e.message))));
}

private Step compacted(TurnState s, Compacted e)
{
    if (!e.ok) return to(s, e.cancelled ? fx(Cancel()) : fx(Rethrow()));
    if (e.cancelled) return to(s, fx(Cancel()));
    return to(s, fx(CallModel(false)));
}

private Step replied(TurnState s, Replied e)
{
    s.last = e.content;
    const room = s.iteration < s.budget;
    if (e.toolCalls)
    {
        // Tool calls begin a new answer: dropped call markup mustn't prefix it.
        s.continued = null;
        return to(s, fx(SyncContinuation(s.continued, s.truncations)), fx(RunTools()));
    }
    // A steer that arrived while the answer was written extends the turn;
    // the reply after it is a fresh answer. On the last allowed call the
    // answer stands and the steer stays queued for the caller.
    if (room && e.steersWaiting && !e.cancelled)
    {
        s.continued = null;
        return to(s, fx(SyncContinuation(s.continued, s.truncations)), fx(Next()));
    }
    // A reply cut off at the output-token limit isn't finished (any tool
    // call in it was dropped): ask for the rest, in smaller pieces.
    if (e.cut && room && !e.cancelled && s.truncations < maxTruncatedContinuations)
    {
        s.truncations++;
        s.continued ~= e.content;
        return to(s, fx(ContinueCutOff(e.outputTokens)), fx(SyncContinuation(s.continued, s.truncations)), fx(Next()));
    }
    Effect[] out_;
    if (e.cut) out_ ~= fx(Notice("\n[the reply hit the output-token limit]"));
    // The whole answer: the chunks carried across continuations, then this one.
    s.last = s.continued ~ e.content;
    // A blocking Stop hook keeps the turn going (capped per turn).
    if (!e.cut && s.stopBlocks < s.limits.maxStopBlocks && !e.cancelled && room)
    {
        s.pending = Pending.answer;
        return Step(s, out_ ~ fx(RunStopHook(s.stopBlocks > 0)));
    }
    return Step(s, out_ ~ fx(Finish(s.last, e.cut ? StopReason.maxTokens : StopReason.endTurn)));
}

private Step toolsRan(TurnState s, ToolsRan e)
{
    // The loop detector's hard stop ends the turn as blocked rather than
    // burning budget until the turn cap.
    if (e.loopStopped) return to(s, fx(FinishOutcome(true)));
    if (!e.reported) return to(s, fx(Next()));
    // A reported outcome ends the turn like a tool-free answer, so it passes
    // the same Stop gate.
    s.reportedResponse = e.reportedResponse;
    if (s.stopBlocks < s.limits.maxStopBlocks && !e.cancelled && s.iteration < s.budget)
    {
        s.pending = Pending.outcome;
        return to(s, fx(RunStopHook(s.stopBlocks > 0)));
    }
    return to(s, fx(FinishOutcome(false)));
}

private Step stopHookRan(TurnState s, StopHookRan e)
{
    import std.string : strip;
    const was = s.pending;
    s.pending = Pending.none;
    if (!e.blocked)
        return was == Pending.outcome ? to(s, fx(FinishOutcome(false))) : to(s, fx(Finish(s.last, StopReason.endTurn)));
    s.stopBlocks++;
    const reason = e.reason.strip.length ? e.reason : stopHookDefaultReason;
    if (was == Pending.outcome)
    {
        s.last = s.reportedResponse;
        return to(s, fx(StopBlocked(reason)), fx(Next()));
    }
    s.continued = null;
    return to(s, fx(SyncContinuation(s.continued, s.truncations)), fx(StopBlocked(reason)), fx(Next()));
}

// ---- Tests: drive the machine with events ----------------------------------

version (unittest)
{
    private string[] names(const Effect[] effects)
    {
        string[] n;
        foreach (e; effects)
            n ~= e.match!((const Next _) => "Next", (const AskKeepGoing _) => "AskKeepGoing",
                (const CallModel c) => c.fresh ? "CallModel" : "Retry", (const Restarting _) => "Restarting",
                (const LimitOutput l) => "LimitOutput", (const CompactForOverflow _) => "CompactForOverflow",
                (const Rethrow _) => "Rethrow", (const Cancel _) => "Cancel", (const ContinueCutOff _) => "ContinueCutOff",
                (const SyncContinuation _) => "Sync", (const Notice _) => "Notice", (const RunStopHook _) => "RunStopHook",
                (const StopBlocked _) => "StopBlocked", (const RunTools _) => "RunTools",
                (const FinishOutcome f) => f.loopStopped ? "FinishLoop" : "FinishOutcome",
                (const Finish f) => "Finish:" ~ f.stop);
        return n;
    }

    /// Feed `events` in order from `s`; the effect names of every step.
    private string[] run(ref TurnState s, Event[] events...)
    {
        string[] all;
        foreach (e; events)
        {
            auto t = step(s, e);
            s = t.state;
            all ~= names(t.effects);
        }
        return all;
    }

    private Event due(AgentMode m = AgentMode.normal) { return Event(CallDue(m, false)); }
    private Event answer(string text) { return Event(Replied(text)); }
}

unittest
{
    // A plain answer: one call, the Stop gate, the end.
    auto s = TurnState.start(Limits(0, false));
    assert(run(s, due, answer("hi"), Event(StopHookRan(false))) == ["CallModel", "RunStopHook", "Finish:end_turn"]);
    assert(s.last == "hi");
}

unittest
{
    // Tool calls, then an answer.
    auto s = TurnState.start(Limits(0, false));
    auto r = run(s, due, Event(Replied("", false, 2)), Event(ToolsRan()), due, answer("done"), Event(StopHookRan()));
    assert(r == ["CallModel", "Sync", "RunTools", "Next", "CallModel", "RunStopHook", "Finish:end_turn"], r[0]);
    assert(s.iteration == 2);
}

unittest
{
    // Interactive normal mode asks at the cap; a yes grants another cap's worth.
    auto s = TurnState.start(Limits(1, false));
    auto r = run(s, due, Event(Replied("", false, 1)), Event(ToolsRan()), due);
    assert(r[$ - 1] == "AskKeepGoing");
    assert(run(s, Event(KeepGoing(true))) == ["Notice", "Next"]);
    assert(run(s, due) == ["CallModel"] && s.iteration == 2 && s.budget == 2);
    // A no ends the turn with the cap note after the last text.
    s = TurnState.start(Limits(1, false));
    run(s, due, Event(Replied("partial", false, 1)), Event(ToolsRan()), due);
    auto t = step(s, Event(KeepGoing(false)));
    assert(names(t.effects) == ["Notice", "Finish:max_turn_requests"]);
    assert(t.effects[1].match!((Finish f) => f.answer, _ => "") == "partial\n[stopped after 1 LLM calls without a final answer]");
}

unittest
{
    // Headless runs stop at the cap without asking; with no cap, at the safety cap.
    auto s = TurnState.start(Limits(1, true));
    assert(run(s, due, Event(Replied("", false, 1)), Event(ToolsRan()), due)[$ - 1] == "Finish:max_turn_requests");
    s = TurnState.start(Limits(0, true));
    run(s, due);
    assert(s.budget == headlessSafetyCap);
    // Auto mode has no cap interactively.
    s = TurnState.start(Limits(5, false));
    run(s, due(AgentMode.auto_));
    assert(s.budget == long.max);
}

unittest
{
    // Cancellation before a call, and during one.
    auto s = TurnState.start(Limits(0, false));
    assert(run(s, Event(CallDue(AgentMode.normal, true))) == ["Cancel"]);
    s = TurnState.start(Limits(0, false));
    assert(run(s, due, Event(CallFailed(Failure.cancelled))) == ["CallModel", "Cancel"]);
}

unittest
{
    // A dropped stream is asked for again, up to maxStreamRestarts, then fails.
    auto s = TurnState.start(Limits(0, false));
    run(s, due);
    foreach (i; 0 .. maxStreamRestarts)
        assert(run(s, Event(CallFailed(Failure.interrupted, "lost"))) == ["Restarting", "Retry"]);
    assert(run(s, Event(CallFailed(Failure.interrupted, "lost"))) == ["Rethrow"]);
    // The count is per call.
    s = TurnState.start(Limits(0, false));
    run(s, due, Event(CallFailed(Failure.interrupted)), Event(Replied("", false, 1)), Event(ToolsRan()), due);
    assert(s.dropped == 0);
}

unittest
{
    // An output-cap rejection retries once at the learned cap (else half of what was sent).
    auto s = TurnState.start(Limits(0, false));
    run(s, due);
    auto t = step(s, Event(CallFailed(Failure.error, "max_tokens: 64000 > 32000, which is the maximum allowed", 64_000)));
    assert(names(t.effects) == ["LimitOutput", "Retry"]);
    assert(t.effects[0].match!((LimitOutput l) => l.cap, _ => 0L) == 32_000);
    s = t.state;
    // A second one is a plain failure.
    assert(run(s, Event(CallFailed(Failure.error, "max_tokens: 64000 > 32000, which is the maximum allowed", 32_000)))
        == ["Rethrow"]);
    // Other errors fail.
    s = TurnState.start(Limits(0, false));
    assert(run(s, due, Event(CallFailed(Failure.error, "rate limited"))) == ["CallModel", "Rethrow"]);
}

unittest
{
    // A context overflow compacts and retries once.
    auto s = TurnState.start(Limits(0, false));
    run(s, due);
    auto t = step(s, Event(CallFailed(Failure.error, "This model's maximum context length is 131072 tokens")));
    assert(names(t.effects) == ["CompactForOverflow"]);
    assert(t.effects[0].match!((CompactForOverflow c) => c.learned, _ => size_t(0)) == 131_072);
    s = t.state;
    assert(run(s, Event(Compacted(true))) == ["Retry"]);
    assert(run(s, Event(CallFailed(Failure.error, "context_length_exceeded"))) == ["Rethrow"]);
    // A compaction that fails re-raises; one that was cancelled cancels.
    s = TurnState.start(Limits(0, false));
    run(s, due, Event(CallFailed(Failure.error, "context_length_exceeded")));
    assert(run(s, Event(Compacted(false))) == ["Rethrow"]);
    s = TurnState.start(Limits(0, false));
    run(s, due, Event(CallFailed(Failure.error, "context_length_exceeded")));
    assert(run(s, Event(Compacted(false, true))) == ["Cancel"]);
}

unittest
{
    // A cut-off reply is continued up to maxTruncatedContinuations times; the
    // answer is the chunks joined.
    auto s = TurnState.start(Limits(0, false));
    run(s, due);
    foreach (i; 0 .. maxTruncatedContinuations)
    {
        assert(run(s, Event(Replied("c" ~ cast(char)('0' + i), true))) == ["ContinueCutOff", "Sync", "Next"]);
        run(s, due);
    }
    auto t = step(s, Event(Replied("end", true)));
    assert(names(t.effects) == ["Notice", "Finish:max_tokens"]);
    assert(t.effects[1].match!((Finish f) => f.answer, _ => "") == "c0c1c2end");
    // A resumed turn starts with its rebuilt continuation.
    s = TurnState.start(Limits(0, false), "a", 1);
    t = step(step(s, due).state, Event(Replied("b")));
    assert(t.state.last == "ab");
}

unittest
{
    // A steer queued during the answer extends the turn, dropping the
    // continuation; on the last allowed call the answer stands.
    auto s = TurnState.start(Limits(0, false), "x", 1);
    assert(run(s, due, Event(Replied("a", false, 0, 0, true))) == ["CallModel", "Sync", "Next"]);
    assert(s.continued is null);
    s = TurnState.start(Limits(1, false));
    assert(run(s, due, Event(Replied("a", false, 0, 0, true)))[$ - 1] == "Finish:end_turn");
}

unittest
{
    // Stop hooks keep the turn going up to maxStopBlocks times.
    auto s = TurnState.start(Limits(0, false, 2));
    auto r = run(s, due, answer("a"), Event(StopHookRan(true, " ")));
    assert(r == ["CallModel", "RunStopHook", "Sync", "StopBlocked", "Next"]);
    r = run(s, due, answer("b"), Event(StopHookRan(true, "more")), due, answer("c"));
    assert(r == ["CallModel", "RunStopHook", "Sync", "StopBlocked", "Next", "CallModel", "Finish:end_turn"]);
    assert(s.stopBlocks == 2);
    // The default reason, and `again` once one has blocked.
    s = TurnState.start(Limits(0, false));
    run(s, due, answer("a"));
    auto t = step(s, Event(StopHookRan(true, "")));
    assert(t.effects[1].match!((StopBlocked b) => b.reason, _ => "") == stopHookDefaultReason);
    t = step(step(t.state, due).state, answer("b"));
    assert(t.effects[0].match!((RunStopHook h) => h.again, _ => false));
}

unittest
{
    // A reported outcome passes the Stop gate; a block keeps going with the
    // outcome's response as the last text.
    auto s = TurnState.start(Limits(0, false));
    auto r = run(s, due, Event(Replied("", false, 1)), Event(ToolsRan(false, true, "Done: x")), Event(StopHookRan()));
    assert(r == ["CallModel", "Sync", "RunTools", "RunStopHook", "FinishOutcome"]);
    s = TurnState.start(Limits(0, false));
    run(s, due, Event(Replied("", false, 1)), Event(ToolsRan(false, true, "Done: x")));
    assert(run(s, Event(StopHookRan(true, "check"))) == ["StopBlocked", "Next"] && s.last == "Done: x");
    // The loop detector's stop ends the turn at once.
    s = TurnState.start(Limits(0, false));
    assert(run(s, due, Event(Replied("", false, 1)), Event(ToolsRan(true)))[$ - 1] == "FinishLoop");
}
