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
import nano.safeio : jsonText;
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
    workspace = getcwd(); // the real path (macOS: /var -> /private/var), as a live log records it
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
    workspace = getcwd(); // the real path (macOS: /var -> /private/var), as a live log records it
    finishedLog(root, "sess-other", workspace, "fix the flaky parser test", "error[E0308]");

    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY (#2–#3)"),
        call("s1", hist.searchTool, `{"pattern":"E0308","session":"sess-other"}`), LLMResponse("blocked")]);
    auto agent = compacted(root, workspace, mock);
    agent.crossSessionHistory = false;
    assert(!agent.offeredTools.any!(d => d.name == hist.sessionsTool), "no sessions_list with the setting off");
    assert(agent.offeredTools.any!(d => d.name == hist.searchTool), "the history tools stay");
    // The advertised schemas keep their previous shape: no `session` property.
    foreach (d; agent.offeredTools)
        if (d.name == hist.searchTool || d.name == hist.readTool)
            assert(!d.parameters.jsonText.canFind(`"session"`), d.name ~ " still advertises session: " ~ d.parameters.jsonText);
    // And with the setting on, both advertise it.
    agent.crossSessionHistory = true;
    foreach (d; agent.offeredTools)
        if (d.name == hist.searchTool || d.name == hist.readTool)
            assert(d.parameters.jsonText.canFind(`"session"`), d.name ~ " lost its session property");

    agent.crossSessionHistory = false;
    agent.run("search the other session", new NullEvents);
    assert(lastToolResult(mock).canFind("cross_session_history = false"), lastToolResult(mock));
}

// A session from another working directory goes through the permission
// policy as a read of its log: a Read deny rule hides it from discovery
// entirely (no cached title or first request leaks), and without a rule the
// cross-workspace read asks the user first — a non-Yes answer fails closed,
// an explicit Yes lets it through.
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
    workspace = getcwd(); // the real path (macOS: /var -> /private/var), as a live log records it
    auto other = finishedLog(root, "sess-other", elsewhere, "secret work", "the launch codes");

    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY (#2–#3)"),
        call("l1", hist.sessionsTool, `{}`), LLMResponse("listed"),
        call("s1", hist.searchTool, `{"pattern":"launch codes","session":"sess-other"}`), LLMResponse("hidden"),
        call("s2", hist.searchTool, `{"pattern":"launch codes","session":"sess-other"}`), LLMResponse("declined"),
        call("s3", hist.searchTool, `{"pattern":"launch codes","session":"sess-other"}`), LLMResponse("allowed")]);
    auto agent = compacted(root, workspace, mock);
    agent.policy.deny = [parseRule("Read(" ~ root ~ "/sessions/sess-other.jsonl)")];

    // Denied: sessions_list never shows it (its title stays hidden), and
    // resolving it by id fails as "no session matches", not with its metadata.
    agent.run("list the sessions", new NullEvents);
    assert(!lastToolResult(mock).canFind("sess-other") && !lastToolResult(mock).canFind("secret work"), lastToolResult(mock));
    agent.run("search the denied session", new NullEvents);
    assert(lastToolResult(mock).canFind("no session matches"), lastToolResult(mock));

    // Allowed by the policy but foreign: the read asks first; a "No" answer
    // fails closed. The broker is resolved from a spawned answerer like the
    // UI's key reader does.
    import nano.question : Answer, Answered, QuestionBroker;
    import nano.safeio : spawn;
    import nano.clock : sleepFor;
    import std.datetime : msecs;
    agent.policy.deny = null;
    agent.questions = QuestionBroker.make;
    agent.questions.interactive = true;
    static void answer(QuestionBroker b, string a)
    {
        while (b.pending is null) sleepFor(1.msecs);
        b.resolve(Answer(Answered([a])));
    }
    auto no = spawn(&answer, agent.questions, "No");
    agent.run("search the other session", new NullEvents);
    no.join();
    assert(lastToolResult(mock).canFind("not confirmed"), lastToolResult(mock));

    // A Yes answer lets the read through.
    auto yes = spawn(&answer, agent.questions, "Yes");
    agent.run("search again", new NullEvents);
    yes.join();
    assert(lastToolResult(mock).canFind("the launch codes"), lastToolResult(mock));
}

// Headless (no answerer), a cross-workspace read fails closed rather than
// exposing the log.
unittest
{
    auto root = buildPath(tempDir, "nano-d-xs-headless");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto workspace = buildPath(root, "work");
    auto elsewhere = buildPath(root, "elsewhere");
    mkdirRecurse(workspace);
    mkdirRecurse(elsewhere);
    auto prevCwd = getcwd();
    chdir(workspace);
    scope (exit) chdir(prevCwd);
    workspace = getcwd(); // the real path (macOS: /var -> /private/var), as a live log records it
    finishedLog(root, "sess-other", elsewhere, "secret work", "the launch codes");

    auto mock = new MockClient([LLMResponse("ok"), LLMResponse("SUMMARY (#2–#3)"),
        call("s1", hist.searchTool, `{"pattern":"launch codes","session":"sess-other"}`), LLMResponse("blocked")]);
    auto agent = compacted(root, workspace, mock);
    agent.run("search the other session", new NullEvents);
    assert(lastToolResult(mock).canFind("not confirmed"), lastToolResult(mock));
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
    workspace = getcwd(); // the real path (macOS: /var -> /private/var), as a live log records it
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
    // Wall-clock: judged against the host's current speed, like the module
    // budgets, so a busy host doesn't fail it while a real regression still does.
    import nano.testenv_test : calibrate, loadFactor;
    if (elapsed >= 900.msecs)
        assert(elapsed.total!"msecs" < cast(long)(900 * loadFactor(calibrate())), elapsed.toString);
}
