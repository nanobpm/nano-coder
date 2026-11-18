/// Session log persistence and restore (session.rs tests).
module nano.session_test;
@safe:

version (unittest):

import std.algorithm : canFind, map;
import std.array : array;
import std.exception : assertThrown, collectExceptionMsg;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.json;
import std.path : buildPath;
import nano.llm;
import nano.session;

private:

string fresh(string name)
{
    auto dir = buildPath(tempDir, "nano-session-test-" ~ name);
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

SessionLog create(string dir, string id) { return new SessionLog(dir, "mock/m", "/x", id); }

string pathFor(string dir, string id) { return buildPath(dir, id ~ ".jsonl"); }

void add(SessionLog log, Message m) { log.append(m); }

ulong[] lines(const Message[] ms) { return ms.map!(m => ulong(m.logLine)).array; }

enum header = `{"type":"session","data":{"version":1,"id":"%s","created_at":"2026-01-01T00:00:00Z"}}` ~ "\n";

string headerFor(string id)
{
    import std.format : format;
    return format(header, id);
}

/// A message record as the log writes it (`type` first).
string messageLine(Message m) { return `{"type":"message","data":` ~ messageRecord(m).toString ~ "}\n"; }

// rust: session.rs::a_stale_log_line_on_a_direct_record_is_renumbered_to_its_physical_line
unittest
{
    import nano.session_history : load;
    auto dir = fresh("stale");
    scope (exit) rmdirRecurse(dir);
    write(pathFor(dir, "s"), headerFor("s") ~ `{"type":"input","data":{"id":"i","text":"hi"}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"user","content":"hi","log_line":99}}` ~ "\n");
    assert(load(pathFor(dir, "s"))[0].id == 3, "the physical line wins over the serialized field");
    assert(restore(pathFor(dir, "s")).conversation[0].logLine == 3);
}

// rust: session.rs::backfill_distinguishes_messages_by_thinking_blocks
unittest
{
    auto dir = fresh("think");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s8");
    auto thinkA = Message.assistant("reply"), thinkB = Message.assistant("reply");
    thinkA.thinkingBlocks = [parseJSON(`{"thinking":"a"}`)];
    thinkB.thinkingBlocks = [parseJSON(`{"thinking":"b"}`)];
    log.add(Message.system("sys")); // #2
    log.add(thinkA); // #3
    log.add(thinkB); // #4
    log.replace([Message.user("summary"), thinkB]);
    assert(restore(log.path).conversation[1].logLine == 4);
}

// rust: session.rs::backfill_uses_the_summarized_range_to_disambiguate_duplicates
unittest
{
    auto dir = fresh("range");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s6");
    log.add(Message.system("sys")); // #2 (folded)
    log.add(Message.user("same")); // #3 (folded)
    log.add(Message.assistant("x")); // #4 (folded)
    log.add(Message.user("same")); // #5 (retained)
    log.replace([Message.user("summary"), Message.user("same")], 2, 4, "smart");
    auto r = restore(log.path);
    assert(r.conversation[1].logLine == 5);
    assert(r.historyAvailable, "a smart replace offers the history tools");
}

// rust: session.rs::blank_lines_do_not_shift_message_ids
unittest
{
    import nano.session_history : load;
    auto dir = fresh("blank");
    scope (exit) rmdirRecurse(dir);
    auto path = pathFor(dir, "s7");
    write(path, headerFor("s7") ~ messageLine(Message.user("hi")) ~ "\n" ~ messageLine(Message.assistant("hello")));
    assert(lines(restore(path).conversation) == [2, 4], "the assistant message stays on physical line 4");
    auto again = Message.user("again");
    assert(new SessionLog(path).append(again) == 5, "the append lands past the blank line 3");
    assert(lines(restore(path).conversation) == [2, 4, 5]);
    assert(load(path).map!(e => e.id).array == [2, 4, 5]);
}

// rust: session.rs::discards_torn_tail_and_appends_cleanly
unittest
{
    import std.file : append;
    auto dir = fresh("torn");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s3");
    log.add(Message.user("a"));
    append(log.path, `{"type":"message","data":{"role":"us`);
    assert(restore(log.path).conversation.length == 1);
    new SessionLog(log.path).add(Message.user("b"));
    assert(restore(log.path).conversation.length == 2);
}

// D's JSON objects don't keep key order, so the golden check is on the parsed shape.
// rust: session.rs::golden_format_is_stable
unittest
{
    auto m = Message.toolResult("c1", "bash", "ok");
    assert(messageRecord(m) == parseJSON(`{"role":"tool","content":"ok","tool_call_id":"c1","name":"bash"}`),
        messageRecord(m).toString);
}

// rust: session.rs::hint_consumed_tracks_messages_after_the_latest_replace
unittest
{
    import nano.session_history : failedToolHint;
    auto dir = fresh("hint");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s7b");
    log.add(Message.system("sys"));
    log.replace([Message.user("summary")], 2, 2, "smart");
    auto r = restore(log.path);
    assert(r.historyAvailable && !r.historyHintConsumed);
    auto hinted = Message.toolResult("c1", "bash", "Exit code: 1\n\n" ~ failedToolHint);
    hinted.isError = true;
    new SessionLog(log.path).add(hinted);
    assert(restore(log.path).historyHintConsumed, "a hint emitted after the replace is consumed");
}

// rust: session.rs::hooks_record_is_audit_only_and_survives_replay
unittest
{
    auto dir = fresh("hooks");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s8");
    log.hooks([["/repo/.claude/settings.json", "project", "abc123"]]);
    log.input("in-1", "hi");
    log.add(Message.user("hi"));
    log.add(Message.assistant("hello"));
    log.turnEnd("in-1", "hello", "end_turn");
    auto r = restore(log.path);
    assert(r.conversation.length == 2 && r.conversation[0].content == "hi", "the audit record adds no conversation rows");
    assert(r.completed["in-1"] == "hello");
    assert(readText(log.path).canFind(`"hash":"abc123"`), "the hook audit record is persisted");
}

// rust: session.rs::read_records_rejects_a_header_id_that_differs_from_the_requested_id
unittest
{
    auto dir = fresh("renamed");
    scope (exit) rmdirRecurse(dir);
    write(pathFor(dir, "renamed"), headerFor("real"));
    assert(collectExceptionMsg(restore(pathFor(dir, "renamed"))).canFind("does not match"));
}

// rust: session.rs::reads_utc_records_and_unstamped_messages_from_older_logs
unittest
{
    auto dir = fresh("utc");
    scope (exit) rmdirRecurse(dir);
    write(pathFor(dir, "u"), headerFor("u") ~ `{"type":"input","data":{"id":"i","text":"hi","recorded_at":"2026-01-01T00:00:00Z"}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"user","content":"hi"}}` ~ "\n");
    auto r = restore(pathFor(dir, "u"));
    assert(r.conversation.length == 1 && r.conversation[0].content == "hi" && r.pending.text == "hi");
    // New records carry the local offset.
    auto now = nowStamp();
    assert(now[19 .. $].canFind('+') || now[19 .. $].canFind('-') || now.canFind('Z'), now);
}

// rust: session.rs::rejects_unsupported_versions_and_bad_ids
unittest
{
    auto dir = fresh("future");
    scope (exit) rmdirRecurse(dir);
    write(pathFor(dir, "future"), `{"type":"session","data":{"version":99,"id":"future","created_at":"2026-01-01T00:00:00Z"}}` ~ "\n");
    assert(collectExceptionMsg(restore(pathFor(dir, "future"))).canFind("unsupported session format version 99"));
    assertThrown(validateId("../etc/passwd"));
    assertThrown(validateId(".hidden"));
    validateId(newSessionId());
}

// rust: session.rs::replace_backfills_log_lines_for_legacy_retained_messages
unittest
{
    auto dir = fresh("legacy");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s5");
    log.add(Message.system("sys")); // #2
    log.add(Message.user("first")); // #3
    log.add(Message.assistant("reply")); // #4
    log.replace([Message.system("sys"), Message.user("first"), Message.assistant("reply"), Message.assistant("summary")]);
    assert(lines(restore(log.path).conversation) == [0, 3, 4, 0]);
}

// rust: session.rs::replace_can_keep_the_pending_input
unittest
{
    auto dir = fresh("pending");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s3");
    log.input("in-1", "go");
    log.add(Message.user("go"));
    auto keep = PendingInput("in-1", "go", 2);
    log.replace([Message.system("sys"), Message.user("summary"), Message.user("go")], 0, 0, null, null, null, &keep);
    auto r = restore(log.path);
    assert(r.conversation.map!(m => m.content).array == ["sys", "summary", "go"]);
    assert(lines(r.conversation) == [0, 0, 3]);
    assert(r.hasPending && r.pending.id == "in-1" && r.pending.text == "go" && r.pending.position == 2);
    assert(!r.pending.hasContinuation && r.pending.hasBase && r.pending.base == 3 && r.pending.recallNotes == 0);
}

// rust: session.rs::replace_resets_conversation
unittest
{
    auto dir = fresh("reset");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s2");
    log.add(Message.user("a"));
    log.replace([Message.system("new")]);
    auto r = restore(log.path);
    assert(r.conversation.length == 1 && r.conversation[0].role == Role.system && r.conversation[0].content == "new");
}

// rust: session.rs::round_trips_and_tracks_inputs
unittest
{
    auto dir = fresh("round");
    scope (exit) rmdirRecurse(dir);
    auto log = create(dir, "s1");
    log.add(Message.system("sys"));
    log.input("in-1", "hi");
    log.add(Message.user("hi"));
    log.add(Message.assistant("hello"));
    log.turnEnd("in-1", "hello", "end_turn");
    log.input("in-2", "hi");
    log.add(Message.user("again"));
    auto r = restore(log.path);
    assert(r.conversation.length == 4 && r.completed["in-1"] == "hello");
    assert(r.hasPending && r.pending.id == "in-2" && r.pending.text == "hi" && r.pending.position == 3);
    assert(!r.pending.hasContinuation && !r.pending.hasBase && r.pending.recallNotes == 0);
    assertThrown(create(dir, "s1"), "create must not clobber");
}
