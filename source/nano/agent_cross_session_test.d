/// Cross-session history at the agent level (issue #271): `sessions_list`,
/// the `session` argument of the history tools, the `cross_session_history`
/// setting, and the permission check for another workspace's log.
module nano.agent_cross_session_test;
@safe:

version (unittest):

import std.algorithm : any, canFind, startsWith;
import std.conv : to;
import std.file : chdir, exists, getcwd, mkdirRecurse, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.string : representation;
import nano.agent;
import nano.llm;
import nano.option : some, unwrap;
import nano.permissions : Policy, parseRule;
import nano.providers.mock : MockClient;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;
import ctx = nano.context;
import hist = nano.session_history;

private:

LLMResponse call(string id, string name, string args) { return LLMResponse("", "", [ToolCall.fromRaw(id, name, args)]); }

/// A session log under `root`'s sessions dir with one turn's messages.
SessionLog finishedLog(string root, string id, string cwd, string userText, string toolOut)
{
    auto log = new SessionLog(buildPath(root, "sessions"), "mock/m", cwd, id);
    log.input("in-1", userText);
    auto sys = Message.system("sys");
    log.append(sys);
    auto u = Message.user(userText);
    log.append(u);
    auto a = Message.assistant("", [ToolCall.fromRaw("c1", "bash", `{"command":"make it"}`)]);
    log.append(a);
    auto t = Message.toolResult("c1", "bash", toolOut, false);
    log.append(t);
    auto done = Message.assistant("done with " ~ userText);
    log.append(done);
    log.close();
    return log;
}

/// An agent with a smart-compacted context (so the history tools are
/// offered), logging to its own session in `root`'s sessions dir, running in
/// `workspace`. The process cwd is `workspace` for the permission check.
Agent compacted(string root, string workspace, MockClient mock)
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    auto log = new SessionLog(buildPath(root, "sessions"), "mock/m", workspace);
    log.append(agent.messages[0]);
    agent.log = some(log);
    agent.run("ping", new NullEvents);
    auto mode = ctx.CompactionMode.smart;
    CompactReport report;
    assert(agent.compact(report, CompactTrigger.manual, &mode));
    return agent;
}

string lastToolResult(MockClient mock)
{
    foreach_reverse (m; mock.seen[$ - 1])
        if (m.role == Role.tool) return m.content;
    return null;
}

// Two sessions in one directory (one live, one finished): the finished
// session's history is searched and read by id, prefix and title; an
// ambiguous match lists the candidates.
unittest
{
    auto root = buildPath(tempDir, "nano-d-xs-read");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto workspace = buildPath(root, "work");
    mkdirRecurse(workspace);
    auto prevCwd = getcwd();
    chdir(workspace);
    scope (exit) chdir(prevCwd);
    finishedLog(root, "sess-other", workspace, "fix the flaky parser test", "error[E0308]: mismatched types at parser.rs:42");

    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY (#2–#3)"),
        call("l1", hist.sessionsTool, `{}`), LLMResponse("listed"),
        call("s1", hist.searchTool, `{"pattern":"E0308","session":"sess-other"}`), LLMResponse("found it"),
        call("s2", hist.searchTool, `{"pattern":"E0308","session":"sess-oth"}`), LLMResponse("prefix works"),
        call("s3", hist.searchTool, `{"pattern":"E0308","session":"flaky parser"}`), LLMResponse("title works"),
        call("r1", hist.readTool, `{"id":6,"session":"sess-other"}`), LLMResponse("read it"),
        call("a1", hist.searchTool, `{"pattern":"x","session":"sess"}`), LLMResponse("ambiguous")]);
    auto agent = compacted(root, workspace, mock);

    agent.run("list the sessions", new NullEvents);
    assert(lastToolResult(mock).canFind("sess-other") && lastToolResult(mock).canFind("[live]"), lastToolResult(mock));

    agent.run("search the other session", new NullEvents);
    assert(lastToolResult(mock).canFind("error[E0308]") && lastToolResult(mock).canFind("#6 tool bash"), lastToolResult(mock));

    agent.run("search by prefix", new NullEvents);
    assert(lastToolResult(mock).canFind("error[E0308]"), lastToolResult(mock));

    agent.run("search by title", new NullEvents);
    assert(lastToolResult(mock).canFind("error[E0308]"), lastToolResult(mock));

    agent.run("read the message", new NullEvents);
    assert(lastToolResult(mock).canFind("#6 tool bash") && lastToolResult(mock).canFind("mismatched types at parser.rs:42"),
        lastToolResult(mock));
    agent.run("ambiguous", new NullEvents);
    assert(lastToolResult(mock).canFind("ambiguous") && lastToolResult(mock).canFind("sess-other"), lastToolResult(mock));
}

// `cross_session_history = false`: no sessions_list, and the session
// argument is refused; the history tools behave as before.
unittest
{
    auto root = buildPath(tempDir, "nano-d-xs-off");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto workspace = buildPath(root, "work");
    mkdirRecurse(workspace);
    auto prevCwd = getcwd();
    chdir(workspace);
    scope (exit) chdir(prevCwd);
    finishedLog(root, "sess-other", workspace, "fix the flaky parser test", "error[E0308]");

    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY (#2–#3)"),
        call("s1", hist.searchTool, `{"pattern":"E0308","session":"sess-other"}`), LLMResponse("blocked")]);
    auto agent = compacted(root, workspace, mock);
    agent.crossSessionHistory = false;
    assert(!agent.offeredTools.any!(d => d.name == hist.sessionsTool), "no sessions_list with the setting off");
    assert(agent.offeredTools.any!(d => d.name == hist.searchTool), "the history tools stay");

    agent.run("search the other session", new NullEvents);
    assert(lastToolResult(mock).canFind("cross_session_history = false"), lastToolResult(mock));
}

// A session from another working directory goes through the permission
// policy as a read of its log: a Read deny rule blocks it.
unittest
{
    auto root = buildPath(tempDir, "nano-d-xs-perm");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto workspace = buildPath(root, "work");
    auto elsewhere = buildPath(root, "elsewhere");
    mkdirRecurse(workspace);
    mkdirRecurse(elsewhere);
    auto prevCwd = getcwd();
    chdir(workspace);
    scope (exit) chdir(prevCwd);
    auto other = finishedLog(root, "sess-other", elsewhere, "secret work", "the launch codes");

    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY (#2–#3)"),
        call("s1", hist.searchTool, `{"pattern":"launch codes","session":"sess-other"}`), LLMResponse("blocked"),
        call("s2", hist.searchTool, `{"pattern":"launch codes","session":"sess-other"}`), LLMResponse("allowed")]);
    auto agent = compacted(root, workspace, mock);
    agent.policy.deny = [parseRule("Read(" ~ root ~ "/sessions/sess-other.jsonl)")];

    agent.run("search the other session", new NullEvents);
    assert(lastToolResult(mock).canFind("denies read_file"), lastToolResult(mock));

    // Without the rule, reading another workspace's log is allowed (the
    // policy's default ask resolves under the caller's sandbox decision).
    agent.policy.deny = null;
    agent.run("search again", new NullEvents);
    assert(lastToolResult(mock).canFind("the launch codes"), lastToolResult(mock));
}

// A large log is searched within the module's time budget: the search
// streams it like the current session's, never loading it whole.
unittest
{
    import nano.clock : monoNow;
    import std.datetime : msecs;
    auto root = buildPath(tempDir, "nano-d-xs-large");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto workspace = buildPath(root, "work");
    mkdirRecurse(workspace);
    auto prevCwd = getcwd();
    chdir(workspace);
    scope (exit) chdir(prevCwd);
    auto log = new SessionLog(buildPath(root, "sessions"), "mock/m", workspace, "sess-big");
    log.input("in-1", "a long session with one needle deep inside");
    auto sys = Message.system("sys");
    log.append(sys);
    foreach (i; 0 .. 20_000)
    {
        auto m = Message.toolResult("c" ~ i.to!string, "bash", "filler output line without the needle " ~ i.to!string, false);
        log.append(m);
    }
    auto needle = Message.user("the needle is a ZXQ-9917 part");
    log.append(needle);
    log.close();

    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY (#2–#3)"),
        call("s1", hist.searchTool, `{"pattern":"ZXQ-9917","session":"sess-big"}`), LLMResponse("found")]);
    auto agent = compacted(root, workspace, mock);
    auto started = monoNow;
    agent.run("find the part", new NullEvents);
    auto elapsed = monoNow - started;
    assert(lastToolResult(mock).canFind("ZXQ-9917"), lastToolResult(mock));
    assert(elapsed < 900.msecs, elapsed.toString);
}
