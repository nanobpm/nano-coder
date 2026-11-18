/// Resuming an interrupted turn when its input id is redelivered: the
/// pending input and its output-limit continuation survive a crash, a
/// provider error and a mid-turn compaction (issue #114).
module nano.agent_resume_test;

@safe:

version (unittest):

import nano.option : some, unwrap;
import std.json;
import std.file : tempDir, exists, rmdirRecurse;
import std.path : buildPath;
import nano.agent;
import nano.llm;
import nano.session;
import nano.tools : ToolRegistry;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;

private:

string freshDir(string name)
{
    auto dir = buildPath(tempDir, "nano-d-resume-" ~ name);
    if (dir.exists) rmdirRecurse(dir);
    return dir;
}

Message truncated(string content)
{
    auto m = Message.assistant(content);
    m.stopReason = "length";
    return m;
}

LLMResponse cut(string content, long tokens = 50)
{
    auto r = LLMResponse(content);
    r.stopReason = "length";
    r.usage.outputTokens = tokens;
    return r;
}

ToolCall echoCall(string id)
{
    return ToolCall.fromRaw(id, "echo", `{"text":"pong"}`);
}

ToolRegistry echoTools()
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    return reg;
}

/// A log interrupted mid-turn: a system message, the accepted input
/// `msg-1` ("run it"), then `records`. Returns the log's path.
string crashedSession(string dir, Message[] records)
{
    auto log = new SessionLog(dir, "mock/m", "/w");
    auto sys = Message.system("sys");
    log.append(sys);
    log.input("msg-1", "run it");
    foreach (ref m; records) log.append(m);
    return log.path;
}

/// Load `path` the way an ACP session/load does.
Agent loaded(string path, MockClient mock)
{
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    auto r = restore(path);
    assert(agent.loadRestored(r, some(new SessionLog(path))).length == 0);
    return agent;
}

string resume(Agent agent)
{
    return agent.run("run it", new NullEvents, true, "msg-1");
}

// rust: agent.rs::resume_restores_a_lost_user_message
unittest
{
    auto mock = new MockClient([LLMResponse("answer")]);
    auto agent = loaded(crashedSession(freshDir("lost-user"), null), mock);
    assert(agent.resume == "answer");
    assert(mock.seen[0][$ - 1].role == Role.user && mock.seen[0][$ - 1].content == "run it");
    // The resumed input is not accepted twice.
    size_t users;
    foreach (ref m; mock.seen[0]) if (m.role == Role.user) users++;
    assert(users == 1);
}

// rust: agent.rs::a_truncated_final_assistant_is_not_replayed_as_a_clean_finish
unittest
{
    auto mock = new MockClient([LLMResponse("done")]);
    auto agent = loaded(crashedSession(freshDir("cut-final"), [Message.user("run it"), truncated("partial ")]), mock);
    assert(agent.resume == "partial done");
    assert(mock.seen.length == 1, "the truncated turn resumed with a model call");
    // The crash came before the chunk's reminder was logged: it is re-sent.
    assert(mock.seen[0][$ - 1].continuation);
}

// rust: agent.rs::replay_after_a_crash_rebuilds_the_whole_answer
unittest
{
    auto mock = new MockClient(null);
    auto agent = loaded(crashedSession(freshDir("replay-prefix"),
        [Message.user("run it"), truncated("partial "), continuationReminder(50), Message.assistant("done")]), mock);
    assert(agent.resume == "partial done", "the replay rebuilds the whole answer, not just the tail");
    assert(agent.lastStop == StopReason.endTurn);
    assert(mock.seen.length == 0, "a recorded answer is replayed, not re-run");
}

// rust: agent.rs::resume_restores_the_continuation_budget_before_a_tool_run
unittest
{
    auto mock = new MockClient([cut("c")]);
    auto agent = loaded(crashedSession(freshDir("budget"), [Message.user("run it"), truncated("a"),
        continuationReminder(50), truncated("b"), continuationReminder(50), Message.assistant("", [echoCall("c1")]),
        Message.toolResult("c1", "echo", "pong"), truncated("c"), continuationReminder(50)]), mock);
    agent.resume;
    assert(agent.lastStop == StopReason.maxTokens, "the spent budget ends the turn at the cap");
    assert(mock.seen.length == 1, "one continuation request, then the budget stops the turn");
}

// rust: agent.rs::resume_restores_continuation_state_before_session_start_context
unittest
{
    import nano.claude_hooks : Hook, Event, HookManager;
    import core.time : seconds;
    auto dir = freshDir("hook-resume");
    auto mock = new MockClient([LLMResponse("done")]);
    auto agent = loaded(crashedSession(dir, [Message.user("run it"), truncated("partial ")]), mock);
    Hook h;
    h.event = Event.sessionStart;
    h.command = "echo hook-context";
    h.matcher = "resume";
    h.timeout = 10.seconds;
    agent.useHooks(new HookManager([h], dir), true);
    assert(agent.resume == "partial done", "the prefix is restored despite the hook context");
    assert(agent.lastStop == StopReason.endTurn);
    bool delivered;
    foreach (ref m; mock.seen[0])
    {
        import std.algorithm : canFind;
        if (m.role == Role.user && m.content.canFind("hook-context")) delivered = true;
    }
    assert(delivered, "SessionStart context is still delivered");
}

// rust: agent.rs::resume_stops_reconstruction_at_a_stop_hook_reprompt
unittest
{
    auto mock = new MockClient(null);
    auto agent = loaded(crashedSession(freshDir("stop-hook"), [Message.user("run it"), truncated("stale"),
        Message.auto_("<system-reminder>stop-hook reason</system-reminder>"), Message.assistant("fresh")]), mock);
    assert(agent.resume == "fresh", "the Stop-hook segment is not prefixed by the discarded chunk");
    assert(mock.seen.length == 0, "a recorded clean answer is not re-run");
}

// rust: agent.rs::resume_before_a_stop_hook_reply_does_not_restore_the_discarded_prefix
unittest
{
    auto mock = new MockClient([LLMResponse("fresh")]);
    auto agent = loaded(crashedSession(freshDir("stop-hook-seed"), [Message.user("run it"), truncated("stale"),
        Message.auto_("<system-reminder>stop-hook reason</system-reminder>")]), mock);
    assert(agent.resume == "fresh", "the continued answer is not prefixed by the discarded chunk");
    assert(mock.seen.length == 1, "the model is called once to answer the Stop-hook prompt");
}

/// A log compacted mid-turn: the replacement restates the pending input at
/// index 2 with continuation snapshot (`answer`, `count`), then `after`.
string compactedSession(string dir, Message[] replaced, string answer, size_t count, Message[] after = null)
{
    auto log = new SessionLog(dir, "mock/m", "/w");
    auto sys = Message.system("sys");
    log.append(sys);
    log.input("msg-1", "run it");
    auto u = Message.user("run it");
    log.append(u);
    auto p = PendingInput("msg-1", "run it", 2, true, answer, count);
    log.replace([Message.system("sys"), Message.user("summary"), Message.user("run it")] ~ replaced, 2, 6,
        "standard", null, null, &p);
    foreach (ref m; after) log.append(m);
    return log.path;
}

// rust: agent.rs::resume_after_compaction_restores_the_persisted_continuation
unittest
{
    auto mock = new MockClient([LLMResponse("three")]);
    auto agent = loaded(compactedSession(freshDir("compact-resume"), null, "one two ", 2), mock);
    assert(agent.resume == "one two three", "the persisted prefix is restored despite the compaction");
    assert(agent.lastStop == StopReason.endTurn);
    assert(mock.seen.length == 1);
}

// rust: agent.rs::resume_after_compaction_with_a_spent_budget_ends_max_tokens
unittest
{
    auto mock = new MockClient([LLMResponse("should not be called")]);
    auto agent = loaded(compactedSession(freshDir("compact-spent"), [truncated("tail")], "one two three ",
        maxTruncatedContinuations), mock);
    assert(agent.resume == "one two three ", "the accumulated answer is preserved");
    assert(agent.lastStop == StopReason.maxTokens, "the spent budget ends the recovered turn");
    assert(mock.seen.length == 0, "an exhausted recovered turn makes no model call");
}

// rust: agent.rs::resume_after_compaction_replays_chunks_logged_after_the_summary
unittest
{
    auto mock = new MockClient([LLMResponse("three")]);
    auto agent = loaded(compactedSession(freshDir("compact-extra"), null, "one ", 1,
        [truncated("two "), continuationReminder(50)]), mock);
    assert(agent.resume == "one two three", "the post-compaction chunk is folded into the whole answer");
    assert(mock.seen.length == 1);
}

// rust: agent.rs::resume_after_compaction_resets_the_prefix_on_a_post_summary_tool_run
unittest
{
    auto mock = new MockClient([LLMResponse("fresh")]);
    auto agent = loaded(compactedSession(freshDir("compact-tool"), null, "one ", 1,
        [Message.assistant("", [echoCall("c1")]), Message.toolResult("c1", "echo", "pong")]), mock);
    assert(agent.resume == "fresh", "the post-tool answer is not prefixed by the discarded continuation");
    assert(mock.seen.length == 1);
}

// rust: agent.rs::resume_after_compaction_replays_a_logged_clean_final_answer
unittest
{
    auto mock = new MockClient([LLMResponse("should not be called")]);
    auto agent = loaded(compactedSession(freshDir("compact-clean"), null, "one ", 1, [Message.assistant("done")]), mock);
    assert(agent.resume == "one done", "the replay shortcut folds the persisted prefix into the answer");
    assert(mock.seen.length == 0);
}

// rust: agent.rs::resume_preserves_the_prefix_across_an_interleaved_timer_message
unittest
{
    auto timer = Message.auto_("<system-reminder>A timer fired.</system-reminder>");
    timer.timer = true;
    auto mock = new MockClient([LLMResponse("should not be called")]);
    auto agent = loaded(crashedSession(freshDir("timer-prefix"), [Message.user("run it"), truncated("one "),
        continuationReminder(50), timer, Message.assistant("two")]), mock);
    assert(agent.resume == "one two", "the fired-timer message does not clear the interrupted answer's prefix");
    assert(mock.seen.length == 0);
}

// rust: agent.rs::resume_after_the_third_cutoff_still_issues_the_last_continuation
unittest
{
    auto mock = new MockClient([LLMResponse("d")]);
    auto agent = loaded(crashedSession(freshDir("third-cutoff"), [Message.user("run it"), truncated("a"),
        continuationReminder(50), truncated("b"), continuationReminder(50), truncated("c")]), mock);
    assert(agent.resume == "abcd", "the final chunk is stitched onto the recovered prefix");
    assert(agent.lastStop == StopReason.endTurn, "the budget still had room for the fourth request");
    assert(mock.seen.length == 1);
}

// rust: agent.rs::resume_with_a_spent_budget_before_turn_end_ends_max_tokens
unittest
{
    auto mock = new MockClient([LLMResponse("should not be called")]);
    auto agent = loaded(crashedSession(freshDir("spent"), [Message.user("run it"), truncated("a"),
        continuationReminder(50), truncated("b"), continuationReminder(50), truncated("c"), continuationReminder(50),
        truncated("d")]), mock);
    assert(agent.resume == "abcd", "the accumulated chunks are preserved");
    assert(agent.lastStop == StopReason.maxTokens, "the spent budget ends the recovered turn");
    assert(mock.seen.length == 0, "an exhausted recovered turn makes no model call");
}

// rust: agent.rs::a_same_agent_retry_after_a_provider_error_does_not_replay_the_snapshot_twice
unittest
{
    auto dir = freshDir("same-agent");
    auto mock = new MockClient([cut("one "), LLMResponse("!error:provider glitch"), cut("two "), cut("three "),
        LLMResponse("four")]);
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    bool failed;
    try agent.run("go", new NullEvents, true, "in-1");
    catch (Exception) failed = true;
    assert(failed, "the provider error fails the first attempt");
    assert(agent.run("go", new NullEvents, true, "in-1") == "one two three four",
        "the recovered prefix is counted once, not doubled into a premature stop");
    assert(agent.lastStop == StopReason.endTurn);
}

// rust: agent.rs::redelivering_a_truncated_turn_replays_its_stop_reason
// rust: agent.rs::a_truncated_turns_stop_reason_survives_a_reload
unittest
{
    auto dir = freshDir("redeliver");
    LLMResponse[] cuts;
    foreach (_; 0 .. maxTruncatedContinuations + 1) cuts ~= cut("more");
    auto mock = new MockClient(cuts);
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    auto first = agent.run("go", new NullEvents, true, "in-1");
    assert(agent.lastStop == StopReason.maxTokens);
    mock.seen = null;
    agent.lastStop = StopReason.endTurn;
    assert(agent.run("go", new NullEvents, true, "in-1") == first);
    assert(agent.lastStop == StopReason.maxTokens);
    assert(mock.seen.length == 0, "a recorded turn is not re-run");

    // After a reload too: the persisted turn end carries the stop reason.
    auto r = restore(agent.log.unwrap("set by the test").path);
    assert(r.completedStops["in-1"] == "max_tokens");
    assert(!r.hasPending);
    auto fresh = new MockClient(null);
    auto second = loaded(agent.log.unwrap("set by the test").path, fresh);
    second.run("go", new NullEvents, true, "in-1");
    assert(second.lastStop == StopReason.maxTokens);
    assert(fresh.seen.length == 0);
}

// A mid-turn compaction keeps the in-flight input: its position (restated
// when folded) and continuation snapshot are persisted and restored.
unittest
{
    auto dir = freshDir("compact-persist");
    auto agent = new Agent(new MockClient(null), echoTools, Policy.init, "sys");
    agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    agent.hasPending = true;
    agent.pending = PendingInput("in-9", "do the thing", 1, true, "half ", 1);
    auto p = agent.pending;
    agent.log.unwrap("set by the test").input("in-9", "do the thing");
    agent.log.unwrap("set by the test").replace([Message.system("sys"), Message.user("summary"), Message.user("do the thing")], 1, 2,
        "standard", null, null, &p);
    auto r = restore(agent.log.unwrap("set by the test").path);
    assert(r.hasPending && r.pending.id == "in-9");
    assert(r.pending.hasContinuation && r.pending.answer == "half " && r.pending.count == 1);
    assert(r.pending.hasBase && r.pending.base == 3);
    // A replace without a pending position (a /clear) drops it.
    agent.log.unwrap("set by the test").replace([Message.system("sys")]);
    assert(!restore(agent.log.unwrap("set by the test").path).hasPending);
}

// rust: agent.rs::resume_after_a_logged_continuation_reminder_stitches_the_prefix
unittest
{
    auto mock = new MockClient([LLMResponse("done")]);
    auto agent = loaded(crashedSession(freshDir("cut-a"), [Message.user("run it"), truncated("partial "),
        continuationReminder(50)]), mock);
    assert(agent.resume == "partial done");
    assert(agent.lastStop == StopReason.endTurn);
    size_t reminders;
    foreach (ref m; mock.seen[0]) if (m.autoInitiated) reminders++;
    assert(reminders == 1, "the existing reminder is reused, not re-pushed");
}

// rust: agent.rs::resume_before_a_logged_continuation_reminder_re_prompts_and_stitches
unittest
{
    import std.algorithm : canFind;
    auto mock = new MockClient([LLMResponse("done")]);
    auto agent = loaded(crashedSession(freshDir("cut-b"), [Message.user("run it"), truncated("partial ")]), mock);
    assert(agent.resume == "partial done");
    auto note = mock.seen[0][$ - 1];
    assert(note.autoInitiated && note.content.canFind("cut off"), note.content);
}

/// Steers the agent while its first reply is being written.
class SteeringClient : MockClient
{
    Agent agent;
    this(LLMResponse[] script) { super(script); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (seen.length == 0) agent.control.steer("change course");
        return super.chat(req, sink);
    }
}

// rust: agent.rs::a_steer_between_continuations_drops_the_cut_off_prefix
unittest
{
    auto mock = new SteeringClient([cut("cut "), LLMResponse("revised")]);
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    mock.agent = agent;
    assert(agent.run("write", new NullEvents) == "revised",
        "the steered answer is not prefixed by the discarded cut-off chunk");
    assert(mock.seen.length == 2, "the cut-off chunk, then the steered continuation");
    bool absorbed;
    foreach (ref m; agent.messages) if (m.role == Role.user && m.content == "change course") absorbed = true;
    assert(absorbed, "the steer was absorbed into the turn");
}

// rust: session.rs::turn_end_persists_a_truncated_stop_reason_and_defaults_old_records
unittest
{
    import std.algorithm : canFind;
    import std.file : readText, append;
    auto log = new SessionLog(freshDir("sr"), "mock/m", "/w");
    log.input("in-1", "hi");
    auto u = Message.user("hi"), a = Message.assistant("partial");
    log.append(u);
    log.append(a);
    log.turnEnd("in-1", "partial", "max_tokens");
    assert(restore(log.path).completedStops["in-1"] == "max_tokens");
    assert(stopReasonFrom("max_tokens") == StopReason.maxTokens);
    // A clean end_turn is omitted from the record...
    log.turnEnd("in-2", "ok", "end_turn");
    auto text = log.path.readText;
    assert(!text[text.lastIndexOf_(`"in-2"`) .. $].canFind("stop_reason"));
    // ...and a record without the field restores to end_turn.
    append(log.path, `{"type":"turn_end","data":{"input_id":"in-9","response":"ok","recorded_at":"2026-01-01T00:00:00+00:00"}}` ~ "\n");
    auto r = restore(log.path);
    assert("in-9" in r.completed && "in-9" !in r.completedStops);
}

size_t lastIndexOf_(string s, string needle)
{
    import std.string : lastIndexOf;
    return cast(size_t) s.lastIndexOf(needle);
}

// A crash after the answer was logged: redelivering the input finishes it
// from the log, without a model call.
// rust: agent.rs::resume_finishes_a_recorded_answer_without_calling_the_model
unittest
{
    auto mock = new MockClient([]);
    auto path = crashedSession(freshDir("lost-end"), [Message.user("run it"), Message.assistant("already answered")]);
    auto agent = loaded(path, mock);
    assert(agent.resume == "already answered");
    assert(mock.seen.length == 0);
    auto r = restore(path);
    assert(r.completed["msg-1"] == "already answered" && !r.hasPending);
}

// rust: agent.rs::resume_finishes_a_reported_outcome_without_calling_the_model
unittest
{
    import nano.goal : OutcomeStatus;
    auto mock = new MockClient([]);
    auto report = Message.assistant("");
    report.toolCalls = [ToolCall.fromRaw("o1", "report_outcome", `{"status":"blocked","summary":"need a token"}`)];
    auto agent = loaded(crashedSession(freshDir("lost-outcome"), [Message.user("run it"), report,
        Message.toolResult("o1", "report_outcome", "Recorded outcome: blocked.")]), mock);
    assert(agent.resume == "Blocked: need a token", agent.messages[$ - 1].content);
    assert(agent.hasOutcome && agent.lastOutcome.status == OutcomeStatus.blocked);
    assert(mock.seen.length == 0);
}

// A finished input redelivered after a resume answers from the log; a new
// one continues the restored conversation.
// rust: agent.rs::resumes_sessions_and_deduplicates_inputs
unittest
{
    auto dir = freshDir("dedupe");
    auto first = new Agent(new MockClient([LLMResponse("one")]), echoTools, Policy.init, "sys");
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(first.messages[0]);
    first.log = some(log);
    assert(first.run("hello", new NullEvents, true, "msg-1") == "one");

    auto mock = new MockClient([LLMResponse("two")]);
    auto second = loaded(log.path, mock);
    assert(second.messages.length == 3);
    assert(second.run("hello", new NullEvents, true, "msg-1") == "one");
    assert(mock.seen.length == 0);
    assert(second.run("again", new NullEvents, true, "msg-2") == "two");
    assert(mock.seen[0].length == 4);
}

// The plan is restored by a resume, carried through compaction, and a
// load resets the mode.
// rust: agent.rs::plan_survives_compaction_and_resume
// rust: agent.rs::new_session_and_load_reset_the_mode
unittest
{
    import std.algorithm : canFind, startsWith;
    import nano.mode : AgentMode;
    auto dir = freshDir("plan");
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("p1", "plan_add", `{"goal":"Fix the bug","items":["Find it","Fix it"]}`)]),
        LLMResponse("", "", [ToolCall.fromRaw("p2", "plan_update", `{"id":1,"status":"done","note":"it is in parser.rs:40"}`)]),
        LLMResponse("", "", [ToolCall.fromRaw("p3", "plan_update", `{"id":7,"status":"done"}`)]),
        LLMResponse("found it"), LLMResponse("SUMMARY: looked for the bug")]);
    auto agent = new Agent(mock, echoTools, Policy.init, "sys");
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    agent.run("go", new NullEvents);
    assert(mock.seen[1][3].content.startsWith("Set the goal, added items 1-2."), mock.seen[1][3].content);
    assert(mock.seen[3][7].isError && mock.seen[3][7].content.canFind("items are 1, 2"), mock.seen[3][7].content);
    CompactReport report;
    assert(agent.compact(report));
    auto summary = agent.messages[1].content;
    assert(summary.canFind("SUMMARY: looked for the bug") && summary.canFind("Goal: Fix the bug"), summary);
    assert(summary.canFind("- it is in parser.rs:40") && summary.canFind("Next: 2. Fix it"), summary);

    auto resumed = new Agent(new MockClient([]), echoTools, Policy.init, "sys");
    resumed.control.mode = AgentMode.plan;
    auto r = restore(log.path);
    resumed.loadRestored(r, some(new SessionLog(log.path)));
    assert(resumed.plan == agent.plan);
    assert(resumed.control.mode == AgentMode.normal, "a load resets the mode");
}

// A restart or a load drops the session's thinking override and its totals.
// (A failed switch keeping the override has no D counterpart: D opens the
// new log before calling restart, so a failure leaves the agent untouched.)
// rust: agent.rs::session_transitions_clear_the_thinking_override
// rust: agent.rs::switching_sessions_in_process_resets_totals_and_indexes
unittest
{
    import std.algorithm : canFind;
    import std.typecons : Nullable;
    import nano.option : Option;
    import nano.thinking : Thinking;
    auto dir = freshDir("transitions");
    auto agent = new Agent(new MockClient([LLMResponse("one")]), echoTools, Policy.init, "sys");
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    agent.run("alpha question here", new NullEvents);

    agent.sessionThinking = Nullable!Thinking(Thinking.parse("high"));
    agent.restart("sys", Option!SessionLog.init);
    assert(agent.sessionThinking.isNull, "a restart clears the override");

    agent.sessionThinking = Nullable!Thinking(Thinking.parse("high"));
    agent.sessionInputTokens = 99;
    agent.sessionOutputTokens = 77;
    agent.compactions = 2;
    auto r = restore(log.path);
    agent.loadRestored(r, some(new SessionLog(log.path)));
    assert(agent.sessionThinking.isNull, "a load clears the override");
    assert(agent.sessionInputTokens == 0 && agent.sessionOutputTokens == 0 && agent.compactions == 0);
    assert(agent.messages.canFind!(m => m.content == "alpha question here"));
}
