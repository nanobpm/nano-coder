/// Replay recorded turns through the turn state machine (nano.turn.step).
///
/// A session log records what each turn did: the model's replies, tool
/// results, continuation reminders, Stop hook reasons, steers and the answer
/// (`turn_end`). Replaying feeds those back in as events and checks that
/// `step` asks for exactly what the log shows next and ends the turn with the
/// recorded answer. The fixtures below are small logs in the real format;
/// set NANO_REPLAY_DIR to a sessions directory to replay every turn in it
/// (`NANO_REPLAY_DIR=~/Library/Application\ Support/nano-coder/sessions
/// scripts/ci.sh test`), which reports any turn the machine would have run
/// differently.
module nano.turn_replay_test;
@safe:

import std.json : JSONValue, JSONType, parseJSON;
import std.sumtype : match;
import nano.llm : Message, Role;
import nano.mode : AgentMode;
import nano.turn;

/// How a replayed turn went.
struct Replay
{
    enum Kind { matched, differed, skipped }
    Kind kind;
    /// Why it differed or was skipped.
    string why;
}

/// One logged turn: its messages after the prompt and the recorded answer.
struct LoggedTurn
{
    Message[] messages;
    string response;
}

/// The turns in a session log (JSONL): each `input`, the messages after its
/// prompt, and its `turn_end`. Turns rewritten by a compaction, or never
/// finished, are left out.
LoggedTurn[] turnsOf(string jsonl)
{
    import std.string : lineSplitter, strip;
    import nano.session : messageFromRecord;
    LoggedTurn[] turns;
    LoggedTurn cur;
    bool open, prompt, broken;
    foreach (line; jsonl.lineSplitter)
    {
        if (!line.strip.length) continue;
        JSONValue j;
        try j = parseJSON(line);
        catch (Exception) continue; // a torn last line
        if (j.type != JSONType.object) continue;
        const t = "type" in j;
        if (t is null || t.type != JSONType.string) continue;
        const d = "data" in j;
        switch (t.str)
        {
            case "input":
                cur = LoggedTurn.init;
                open = true;
                prompt = broken = false;
                break;
            case "replace":
                broken = true;
                break;
            case "message":
                if (!open || d is null) break;
                auto m = messageFromRecord(*d);
                // The prompt and any hook context before the first reply.
                if (!prompt && (m.role == Role.user || m.role == Role.system)) break;
                prompt = true;
                cur.messages ~= m;
                break;
            case "turn_end":
                if (!open || d is null) break;
                if (auto r = "response" in *d) if (r.type == JSONType.string) cur.response = r.str;
                if (!broken && cur.messages.length) turns ~= cur;
                open = false;
                break;
            default:
                break;
        }
    }
    return turns;
}

/// Replay one logged turn through `step`.
Replay replay(const LoggedTurn turn)
{
    import std.algorithm.searching : canFind, startsWith;
    import std.format : format;
    alias R = Replay;
    const ms = turn.messages;
    size_t i;
    // The machine says which assistant message comes next (a model reply,
    // or an outcome's response), so the role is enough: early logs don't
    // record a reply's timing or stop reason.
    bool isReply(const ref Message m) { return m.role == Role.assistant; }
    bool isSteer(const ref Message m) { return m.role == Role.user && !m.autoInitiated; }
    // Timers fire between calls (prepareCall), outside the machine.
    void skipTimers() { while (i < ms.length && ms[i].role == Role.user && ms[i].timer) i++; }
    if (turn.response.canFind("[stopped after")) return R(R.Kind.skipped, "ended at the turn cap");
    // A cancelled turn was cancelled once its last logged message was in.
    import nano.control : cancelledResponse;
    const cancelling = turn.response == cancelledResponse;
    // Timers after it fired outside the machine.
    bool cancelled()
    {
        import std.algorithm.searching : all;
        return cancelling && ms[i .. $].all!(m => m.role == Role.user && m.timer);
    }
    auto state = TurnState.start(Limits(0, false));
    Event[] event = [Event(CallDue(AgentMode.normal, false))];
    size_t toolCalls;
    for (;;)
    {
        auto t = step(state, event[0]);
        state = t.state;
        Event[] next;
        foreach (effect; t.effects)
        {
            enum Go { on, done, skip, differ }
            Go go = Go.on;
            string why;
            string answer;
            effect.match!(
                (const Next _) { next ~= Event(CallDue(AgentMode.normal, cancelled)); },
                (const CallModel c) {
                    // Steers and timers are absorbed before a fresh call.
                    if (c.fresh)
                        while (i < ms.length && ms[i].role == Role.user && (ms[i].timer || isSteer(ms[i]))) i++;
                    // A call that failed for good isn't logged; its error is the answer.
                    if (i >= ms.length && turn.response.startsWith("Error: "))
                    {
                        go = Go.skip;
                        why = "the call failed";
                        return;
                    }
                    if (i >= ms.length || !isReply(ms[i]))
                    {
                        go = Go.differ;
                        why = i < ms.length
                            ? format("expected a model reply at message %s, found %s %s%s", i, ms[i].role,
                                ms[i].autoInitiated ? "auto " : "", ms[i].content.length > 40 ? ms[i].content[0 .. 40] : ms[i].content)
                            : "expected a model reply after the last message";
                        return;
                    }
                    const m = ms[i++];
                    toolCalls = m.toolCalls.length;
                    // A steer right after a tool-free reply was queued while it was written.
                    const steer = !toolCalls && i < ms.length && isSteer(ms[i]);
                    next ~= Event(Replied(m.content, m.stopReason == "max_tokens", toolCalls,
                        m.usage.outputTokens, steer, false));
                },
                (const ContinueCutOff _) {
                    skipTimers();
                    if (i < ms.length && ms[i].continuation) i++;
                    else { go = Go.differ; why = format("expected a continuation reminder at message %s", i); }
                },
                (const RunTools _) {
                    bool reported, loop;
                    foreach (n; 0 .. toolCalls)
                    {
                        if (i >= ms.length || ms[i].role != Role.tool)
                        {
                            go = Go.differ;
                            why = format("expected %s tool results at message %s", toolCalls, i);
                            return;
                        }
                        const m = ms[i++];
                        if (m.toolName == "report_outcome" && !m.isError) reported = true;
                        if (m.content.canFind("repeated too many times")) loop = true;
                    }
                    next ~= Event(ToolsRan(loop, reported, null, cancelled));
                },
                (const RunStopHook _) {
                    // A Stop hook's reason is an automatic message that isn't a
                    // continuation reminder or a timer.
                    const blocked = i < ms.length && ms[i].role == Role.user && ms[i].autoInitiated
                        && !ms[i].continuation && !ms[i].timer;
                    next ~= Event(StopHookRan(blocked, blocked ? ms[i].content : null, cancelled));
                },
                (const StopBlocked _) { i++; },
                (const FinishOutcome _) {
                    if (i < ms.length && ms[i].role == Role.assistant) answer = ms[i++].content;
                    go = Go.done;
                },
                (const Finish f) { answer = f.answer; go = Go.done; },
                (const AskKeepGoing _) { go = Go.skip; why = "asked to keep going"; },
                (const Cancel _) { answer = cancelledResponse; go = Go.done; },
                (const Rethrow _) { go = Go.skip; why = "failed"; },
                (const CompactForOverflow _) { go = Go.skip; why = "compacted"; },
                (const SyncContinuation _) {},
                (const Notice _) {},
                (const Restarting _) {},
                (const LimitOutput _) {},
            );
            final switch (go)
            {
                case Go.on: break;
                case Go.skip: return R(R.Kind.skipped, why);
                case Go.differ: return R(R.Kind.differed, why);
                case Go.done:
                    skipTimers();
                    if (i < ms.length) return R(R.Kind.differed, format("ended with %s messages left", ms.length - i));
                    if (answer != turn.response)
                        return R(R.Kind.differed, format("answer %s, recorded %s", answer.length, turn.response.length));
                    return R(R.Kind.matched);
            }
        }
        if (next.length != 1) return R(R.Kind.differed, "no next event");
        event = next;
    }
}

version (unittest)
{
    private string msg(string role, string content, string extra = "")
    {
        return `{"type":"message","data":{"role":"` ~ role ~ `","content":` ~ JSONValue(content).toString ~ extra ~ `}}` ~ "\n";
    }
    private string reply(string content, string stop = "end_turn", string calls = "")
    {
        return msg("assistant", content, `,"duration_ms":5,"stop_reason":"` ~ stop ~ `"`
            ~ (calls.length ? `,"tool_calls":` ~ calls : ""));
    }
    private string call(string id, string name)
    {
        return `[{"id":"` ~ id ~ `","name":"` ~ name ~ `","arguments":{}}]`;
    }
    private string tool(string id, string name, string content)
    {
        return msg("tool", content, `,"tool_call_id":"` ~ id ~ `","name":"` ~ name ~ `"`);
    }
    private enum input = `{"type":"input","data":{"id":"in-1","text":"go"}}` ~ "\n";
    private string end(string response) { return `{"type":"turn_end","data":{"input_id":"in-1","response":` ~ JSONValue(response).toString ~ `}}` ~ "\n"; }

    private Replay only(string log)
    {
        auto turns = turnsOf(log);
        assert(turns.length == 1, "one turn");
        return replay(turns[0]);
    }
}

unittest
{
    // Tools, then an answer.
    auto log = input ~ msg("user", "go") ~ reply("", "tool_use", call("c1", "bash")) ~ tool("c1", "bash", "ok")
        ~ reply("done") ~ end("done");
    assert(only(log).kind == Replay.Kind.matched, only(log).why);
    // A recorded answer the machine wouldn't give.
    assert(only(input ~ msg("user", "go") ~ reply("done") ~ end("other")).kind == Replay.Kind.differed);
}

unittest
{
    // A cut-off reply continued twice: the answer is the chunks joined.
    auto rem = `,"auto_initiated":true,"continuation":true`;
    auto log = input ~ msg("user", "go") ~ reply("a", "max_tokens") ~ msg("user", "<system-reminder>more</system-reminder>", rem)
        ~ reply("b", "max_tokens") ~ msg("user", "<system-reminder>more</system-reminder>", rem) ~ reply("c") ~ end("abc");
    assert(only(log).kind == Replay.Kind.matched, only(log).why);
    // Without the reminder the log disagrees with the machine.
    log = input ~ msg("user", "go") ~ reply("a", "max_tokens") ~ reply("c") ~ end("ac");
    assert(only(log).kind == Replay.Kind.differed);
}

unittest
{
    // Cancelled while a tool ran: the turn ends without another call.
    auto log = input ~ msg("user", "go") ~ reply("", "tool_use", call("c1", "bash"))
        ~ tool("c1", "bash", "Error: the turn was cancelled; the command was killed") ~ end("[turn cancelled]");
    assert(only(log).kind == Replay.Kind.matched, only(log).why);
}

unittest
{
    // A reported outcome ends the turn with its response.
    auto log = input ~ msg("user", "go") ~ reply("", "tool_use", call("o", "report_outcome"))
        ~ tool("o", "report_outcome", "recorded") ~ msg("assistant", "Done: shipped") ~ end("Done: shipped");
    assert(only(log).kind == Replay.Kind.matched, only(log).why);
}

unittest
{
    // A Stop hook blocks once; a steer queued during an answer extends the turn.
    auto log = input ~ msg("user", "go") ~ reply("first") ~ msg("user", "<system-reminder>check</system-reminder>",
        `,"auto_initiated":true`) ~ reply("second") ~ end("second");
    assert(only(log).kind == Replay.Kind.matched, only(log).why);
    log = input ~ msg("user", "go") ~ reply("first") ~ msg("user", "also this") ~ reply("both") ~ end("both");
    assert(only(log).kind == Replay.Kind.matched, only(log).why);
}

unittest
{
    // Turns rewritten by a compaction aren't replayed; the turn cap is skipped.
    auto log = input ~ msg("user", "go") ~ `{"type":"replace","data":{"messages":[]}}` ~ "\n" ~ reply("x") ~ end("x");
    assert(turnsOf(log).length == 0);
    log = input ~ msg("user", "go") ~ reply("x") ~ end("x\n[stopped after 3 LLM calls without a final answer]");
    assert(only(log).kind == Replay.Kind.skipped);
}

// Every turn in a sessions directory, when NANO_REPLAY_DIR names one.
unittest
{
    import std.process : environment;
    import std.file : dirEntries, SpanMode, readText, exists;
    import std.stdio : writefln;
    const dir = environment.get("NANO_REPLAY_DIR");
    if (dir is null || !exists(dir)) return;
    size_t[3] counts;
    string[size_t] examples;
    size_t[string] reasons;
    foreach (e; dirEntries(dir, "*.jsonl", SpanMode.shallow))
    {
        string text;
        try text = readText(e.name);
        catch (Exception) continue; // unreadable or not UTF-8: not a log to replay
        foreach (n, turn; turnsOf(text))
        {
            auto r = replay(turn);
            counts[r.kind]++;
            if (r.kind == Replay.Kind.differed)
            {
                import std.regex : replaceAll, regex;
                auto key = r.why.replaceAll(regex(`[0-9]+`), "N");
                if (key !in reasons) examples[examples.length] = e.name ~ " turn " ~ str(n) ~ ": " ~ r.why;
                reasons[key]++;
            }
        }
    }
    writefln("replay: %s matched, %s differed, %s skipped", counts[0], counts[1], counts[2]);
    foreach (k, v; reasons) writefln("  %s x %s", v, k);
    foreach (k, v; examples) writefln("  e.g. %s", v);
}

private string str(size_t n) { import std.conv : to; return n.to!string; }
