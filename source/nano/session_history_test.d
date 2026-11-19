/// history_search / history_read over a session log (history.rs tests).
module nano.session_history_test;
@safe:

version (unittest):

import std.algorithm : canFind, count, map, startsWith;
import std.array : array, replicate;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.json;
import std.path : buildPath;
import std.string : lineSplitter;
import nano.llm;
import nano.session : SessionLog;
import nano.session_history;

private:

string fresh(string name)
{
    auto dir = buildPath(tempDir, "nano-history-test-" ~ name);
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

/// Rust's fixture: messages on lines 2–6, then a smart replace.
string fixture(string dir)
{
    auto log = new SessionLog(dir, "m", "/w", "h");
    auto long_ = "a ".replicate(400) ~ "error[E0308]: mismatched types at auth.rs:42" ~ " b".replicate(400);
    foreach (m; [Message.system("sys"), Message.user("fix the flaky test in auth.rs"),
            Message.assistant("", [ToolCall.fromRaw("c1", "bash", `{"command":"cargo test auth"}`)]),
            Message.toolResult("c1", "bash", long_, true), Message.assistant("fixed")])
        log.append(m);
    log.replace([Message.system("sys"), Message.user("summary"), Message.assistant("fixed")], 3, 5, "smart", null);
    return log.path;
}

string find(string path, string args) { return search(path, parseJSON(args)); }

// rust: history.rs::assistant_hits_name_the_tool_output_they_follow
unittest
{
    auto dir = fresh("after");
    scope (exit) rmdirRecurse(dir);
    auto path = fixture(dir);
    auto out_ = find(path, `{"pattern":"fixed"}`);
    assert(out_.startsWith("#6 assistant") && out_.canFind("[after tool output #5]"), out_);
    out_ = find(path, `{"pattern":"cargo test auth","role":"assistant"}`);
    assert(out_.startsWith("#4 assistant") && !out_.canFind("after tool output"), out_);
    auto log = new SessionLog(dir, "m", "/w", "multi");
    foreach (m; [Message.user("go"), Message.toolResult("a", "bash", "one"), Message.toolResult("b", "bash", "two"),
            Message.assistant("both said something")])
        log.append(m);
    out_ = find(log.path, `{"pattern":"something"}`);
    assert(out_.canFind("[after tool output #3–#4]"), out_);
}

// rust: history.rs::failures_include_nonzero_bash_exits
unittest
{
    assert(looksFailed("read_file", false, "no such file"));
    assert(looksFailed("bash", true, "ls: /work: No such file\n\nExit code: 1"));
    assert(looksFailed("bash", true, "Exit code: 2"));
    assert(looksFailed("bash", true, "Error: command timed out after 600s and was killed"));
    assert(looksFailed("bash", true, "partial output\nTerminated by signal 9"));
    assert(!looksFailed("bash", true, "fine"));
    assert(!looksFailed(searchTool, false, "bad pattern"));
}

// rust: history.rs::hint_is_consumed_only_by_tool_results_and_history_calls
unittest
{
    auto failed = Message.toolResult("c1", "bash", failedToolHint, true);
    assert(consumesHint(failed));
    auto user = Message.user(failedToolHint), said = Message.assistant(failedToolHint);
    assert(!consumesHint(user) && !consumesHint(said));
    auto call = Message.assistant("", [ToolCall.fromRaw("h", searchTool, `{}`)]);
    assert(consumesHint(call));
    auto readResult = Message.toolResult("h", readTool, "results");
    assert(consumesHint(readResult));
    auto named = Message.assistant(searchTool), ok = Message.toolResult("c2", "bash", "ok");
    assert(!consumesHint(named) && !consumesHint(ok));
}

// rust: history.rs::ids_are_log_lines_and_replace_records_are_skipped
unittest
{
    auto dir = fresh("ids");
    scope (exit) rmdirRecurse(dir);
    assert(load(fixture(dir)).map!(e => e.id).array == [2, 3, 4, 5, 6]);
}

string readTwo(string name, Message m)
{
    auto dir = fresh(name);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "m", "/w", "t");
    log.append(m);
    return read(log.path, parseJSON(`{"id":2}`));
}

// rust: history.rs::read_includes_logged_thinking_text
unittest
{
    auto m = Message.assistant("on it");
    m.thinking = "check auth.rs first";
    auto out_ = readTwo("think", m);
    assert(out_.canFind("[thinking] check auth.rs first\non it"), out_);
}

// rust: history.rs::read_includes_plain_thinking_alongside_replay_blocks
unittest
{
    auto m = Message.assistant("on it");
    m.thinking = "check auth.rs first";
    m.thinkingBlocks = [parseJSON(`{"type":"reasoning_content","text":"check auth.rs first"}`)];
    auto out_ = readTwo("replay", m);
    assert(out_.canFind("[thinking] check auth.rs first\non it") && out_.count("[thinking]") == 1, out_);
}

// rust: history.rs::read_includes_thinking_blocks
unittest
{
    auto m = Message.assistant("");
    m.thinkingBlocks = [parseJSON(`{"type":"thinking","thinking":"weigh the options","signature":"sig"}`)];
    auto out_ = readTwo("blocks", m);
    assert(out_.canFind("[thinking] weigh the options"), out_);
}

// rust: history.rs::reports_matches_hidden_by_the_role_filter
unittest
{
    auto dir = fresh("hidden");
    scope (exit) rmdirRecurse(dir);
    auto path = fixture(dir);
    auto out_ = find(path, `{"pattern":"E0308","role":"assistant"}`);
    assert(out_.startsWith("No assistant messages match") && out_.canFind("role=assistant hid 1 matching message(s): 1 tool"), out_);
    out_ = find(path, `{"pattern":"auth","role":"user"}`);
    assert(out_.startsWith("#3 user") && out_.canFind("role=user hid"), out_);
    assert(!find(path, `{"pattern":"E0308"}`).canFind("hid"));
    assert(!find(path, `{"pattern":"E0308","role":"tool"}`).canFind("hid"));
}

// rust: history.rs::search_finds_text_and_tool_calls_newest_first
unittest
{
    import std.exception : assertThrown;
    import std.utf : count;
    auto dir = fresh("newest");
    scope (exit) rmdirRecurse(dir);
    auto path = fixture(dir);
    auto out_ = find(path, `{"pattern":"auth"}`);
    auto lines = out_.lineSplitter.array;
    assert(lines.length == 3, out_);
    assert(lines[0].startsWith("#5 tool bash (failed)") && lines[0].canFind("error[E0308]"), out_);
    assert(lines[0].canFind("…") && lines[0].count < 400, "snippets are short");
    assert(lines[1].startsWith("#4 assistant") && lines[1].canFind("cargo test auth"), out_);
    assert(lines[2].startsWith("#3 user"), out_);
    lines = find(path, `{"pattern":"auth","role":"user"}`).lineSplitter.array;
    assert(lines.length == 2 && lines[0].startsWith("#3 user") && lines[1].startsWith("[role=user hid"), lines[1]);
    out_ = find(path, `{"pattern":"auth","limit":1}`);
    assert(out_.canFind("[2 more older matching messages not shown (#3–#4)") && out_.canFind("order=oldest"), out_);
    out_ = find(path, `{"pattern":"auth","order":"oldest","limit":1}`);
    assert(out_.startsWith("#3 user") && out_.canFind("2 more newer") && out_.canFind("order=newest"), out_);
    assertThrown(find(path, `{"pattern":"auth","order":"sideways"}`));
    out_ = find(path, `{"pattern":"auth","before":4}`);
    assert(out_.startsWith("#3 user") && out_.lineSplitter.array.length == 1, out_);
    assert(find(path, `{"pattern":"E0308]"}`).startsWith("#5"));
    assert(find(path, `{"pattern":"nothing-like-this"}`).startsWith("No messages match"));
    assertThrown(find(path, `{}`));
}

// rust: history.rs::search_shows_later_matches_in_a_message
unittest
{
    auto dir = fresh("later");
    scope (exit) rmdirRecurse(dir);
    auto noise = "x ".replicate(300);
    auto log = new SessionLog(dir, "m", "/w", "s");
    auto m = Message.toolResult("t1", "bash", "Compiling lease " ~ noise ~ " Compiling lease " ~ noise
        ~ " error[E0599]: no method named `renew` in lease " ~ noise);
    log.append(m);
    auto out_ = find(log.path, `{"pattern":"lease"}`);
    assert(out_.canFind("[3 matches]") && out_.canFind("no method named `renew`"), out_);
}
