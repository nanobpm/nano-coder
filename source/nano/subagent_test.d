/// The `agent` tool end to end with scripted models (issue #231): a parent
/// hands a task to a sub-agent and gets its report; parallel children are
/// capped; a cancel stops them; the parent's policy applies to their calls;
/// limits truncate; usage rolls up; the child log is written and referenced.
module nano.subagent_test;
@safe:

version (unittest):

import core.atomic : atomicLoad, atomicOp, atomicStore, cas;
import core.time : msecs;
import std.algorithm : canFind;
import std.file : exists, readText, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.clock : sleepFor, monoNow;
import nano.control : Cancelled, TurnControl, cancelRequested, cancelledResponse;
import nano.llm;
import nano.option : some, unwrap;
import nano.permissions : Policy, parseRule;
import nano.providers.mock : MockClient;
import nano.session : SessionLog;
import nano.subagent : SubClientFactory, SubLimits;
import nano.tools : ToolRegistry;

private:

shared int active, peak;

/// Counts how many children are inside a model call at once.
final class Overlapping : MockClient
{
    this(LLMResponse[] s) { super(s); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto now = atomicOp!"+="(active, 1);
        for (;;)
        {
            auto p = atomicLoad(peak);
            if (now <= p || cas(&peak, p, now)) break;
        }
        sleepFor(40.msecs);
        atomicOp!"-="(active, 1);
        return super.chat(req, sink);
    }
}

/// Waits in its model call until the turn is cancelled.
final class Hanging : MockClient
{
    this() { super([]); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        atomicOp!"+="(active, 1);
        auto start = monoNow;
        while (!cancelRequested)
        {
            if (monoNow - start > 5000.msecs) assert(0, "never cancelled");
            sleepFor(2.msecs);
        }
        throw new Cancelled;
    }
}

LLMResponse used(LLMResponse r, long input, long output)
{
    r.usage.inputTokens = input;
    r.usage.outputTokens = output;
    return r;
}

LLMResponse report(string summary)
{
    return LLMResponse("", "", [ToolCall.fromRaw("o", "report_outcome",
        JSONValue(["status": "completed", "summary": summary]).toString)]);
}

/// The children's models, by the `model` an `agent` call asks for.
final class Scripts : SubClientFactory
{
    LLMClient make(string spec) const
    {
        switch (spec)
        {
            case "mock/search":
                return new MockClient([used(LLMResponse("", "", [ToolCall.fromRaw("g", "grep", `{"pattern":"parse"}`)]), 100, 10),
                    used(report("parser at src/p.d:12"), 200, 20)]);
            case "mock/parallel":
                return new Overlapping([report("parallel report")]);
            case "mock/hang":
                return new Hanging;
            case "mock/denied":
                return new MockClient([LLMResponse("", "", [ToolCall.fromRaw("b", "bash", `{"command":"forbidden-cmd now"}`)]),
                    report("could not run it")]);
            case "mock/cancel":
                return new MockClient([LLMResponse("", "", [ToolCall.fromRaw("g", "grep", `{"pattern":"trigger-cancel"}`)])]);
            case "mock/loop":
                LLMResponse[] s;
                foreach (i; 0 .. 8)
                    s ~= LLMResponse(i == 0 ? "partial: looked at a.d:1" : "", "",
                        [ToolCall.fromRaw("g", "grep", JSONValue(["pattern": JSONValue(i)]).toString)]);
                return new MockClient(s);
            case "mock/after":
                return new MockClient([LLMResponse("", "", [ToolCall.fromRaw("g", "grep", `{"pattern":"after-edit"}`)]),
                    report("saw the edit")]);
            case "mock/nested":
                return new MockClient([LLMResponse("", "", [ToolCall.fromRaw("a", "agent", `{"task":"deeper"}`)]),
                    report("no nesting")]);
            default:
                assert(0, "no script for " ~ spec);
        }
    }
}

string agentCall(string id, string model, string extra = "")
{
    return `{"task":"investigate ` ~ id ~ `","model":"` ~ model ~ `"` ~ extra ~ `}`;
}

final class Fixture
{
    Agent agent;
    MockClient parent;
    string[] grepped, bashed;
    /// Every grep and bash, in the order they ran.
    string[] order;
    string dir;

    this(LLMResponse[] script, Policy policy = Policy.init)
    {
        parent = new MockClient(script);
        auto reg = new ToolRegistry;
        reg.register(ToolDefinition("grep", "search", parseJSON(`{"type":"object"}`)), (JSONValue a) {
            grepped ~= a["pattern"].toString;
            order ~= "grep " ~ a["pattern"].str;
            if (a["pattern"].toString == `"trigger-cancel"`) agent.control.cancel();
            return "src/p.d:12: parse()";
        });
        reg.register(ToolDefinition("bash", "run", parseJSON(`{"type":"object"}`)), (JSONValue a) {
            bashed ~= a["command"].str;
            order ~= "bash " ~ a["command"].str;
            if (a["command"].str == "trigger-cancel") agent.control.cancel();
            return "ok";
        });
        reg.register(ToolDefinition("write_file", "write", parseJSON(`{"type":"object"}`)), (JSONValue a) => "written");
        agent = new Agent(parent, reg, policy, "sys");
        agent.subagentClients = new immutable Scripts;
    }

    void persist()
    {
        import std.conv : to;
        dir = buildPath(tempDir, "nano-subagent-" ~ monoNow.ticks.to!string);
        agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    }

    ~this() {}

    string toolResult(string id)
    {
        foreach (m; agent.messages) if (m.role == Role.tool && m.toolCallId == id) return m.content;
        assert(0, "no result for " ~ id);
    }
}

// A parent → child → parent exchange: the child's grep runs through the
// parent, its report is the tool result, and its usage rolls up.
unittest
{
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("c1", "agent", agentCall("parser", "mock/search"))]),
        LLMResponse("the parser is at src/p.d:12")]);
    assert(f.agent.offeredTools.canFind!(t => t.name == "agent"));
    assert(f.agent.run("where is the parser?", new NullEvents) == "the parser is at src/p.d:12");
    auto r = f.toolResult("c1");
    assert(r.canFind("parser at src/p.d:12") && r.canFind("2 tool calls") && r.canFind("330 tokens"), r);
    assert(f.grepped == [`"parse"`], "the child's call ran on the parent's registry");
    assert(f.agent.sessionInputTokens == 300 && f.agent.sessionOutputTokens == 30, "usage rolls up");
    // The parent's request carried only the report, not the child's grep output.
    assert(!f.parent.seen[1].canFind!(m => m.content.canFind("parse()")));
    // The child was offered only the read-only tools it may use.
}

// Parallel children run at once, capped by the concurrency setting.
unittest
{
    atomicStore(active, 0);
    atomicStore(peak, 0);
    ToolCall[] calls;
    foreach (i; 0 .. 4)
    {
        import std.conv : to;
        calls ~= ToolCall.fromRaw("p" ~ i.to!string, "agent", agentCall(i.to!string, "mock/parallel"));
    }
    auto f = new Fixture([LLMResponse("", "", calls), LLMResponse("all done")]);
    f.agent.subagentMaxConcurrency = 2;
    assert(f.agent.run("go", new NullEvents) == "all done");
    assert(atomicLoad(peak) == 2, "two at a time");
    foreach (c; calls) assert(f.toolResult(c.id).canFind("parallel report"));
}

// A cancel stops every running child and the parent's turn.
unittest
{
    atomicStore(active, 0);
    static void cancelSoon(shared TurnControl c)
    {
        while (atomicLoad(active) < 2) sleepFor(2.msecs);
        c.cancel();
    }
    import nano.safeio : spawn;
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("h1", "agent", agentCall("a", "mock/hang")),
        ToolCall.fromRaw("h2", "agent", agentCall("b", "mock/hang"))]), LLMResponse("never")]);
    f.agent.control.startTurn();
    auto h = spawn(&cancelSoon, new shared TurnControl);
    assert(f.agent.run("go", new NullEvents, false) == cancelledResponse);
    h.join();
    assert(f.toolResult("h1").canFind("[truncated: cancelled"));
    f.agent.control.startTurn();
}

// A cancel from a tool the child called ends the child and the turn.
unittest
{
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("c", "agent", agentCall("x", "mock/cancel"))]),
        LLMResponse("never")]);
    assert(f.agent.run("go", new NullEvents) == cancelledResponse);
    assert(f.grepped == [`"trigger-cancel"`]);
    f.agent.control.startTurn();
}

// The parent's permission policy applies to the child's calls: a denied one
// comes back to the child as a tool error (in its own log), never a prompt.
// The child log is written next to the parent's and referenced from it.
unittest
{
    Policy p;
    p.deny ~= parseRule("Bash(forbidden-cmd*)");
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("d1", "agent", agentCall("x", "mock/denied"))]),
        LLMResponse("ok")], p);
    f.persist();
    scope (exit) if (f.dir.exists) rmdirRecurse(f.dir);
    assert(f.agent.run("go", new NullEvents) == "ok");
    assert(!f.bashed.length, "refused before it ran (no shell for sub-agents)");
    assert(f.toolResult("d1").canFind("could not run it"));
    Message parentResult;
    foreach (m; f.agent.messages) if (m.toolCallId == "d1") parentResult = m;
    auto child = parentResult.subLog;
    assert(child.length && child.exists, "the child log is referenced: " ~ child);
    auto parentLog = f.agent.log.unwrap("set").path;
    import std.path : dirName, stripExtension;
    assert(child.dirName == parentLog.stripExtension && child.canFind("sub-d1"));
    assert(readText(parentLog).canFind(`"sub_log":`));
    auto text = readText(child);
    assert(text.canFind(`"is_error":true`) && text.canFind("forbidden-cmd"), text);
    assert(!readText(parentLog).canFind("forbidden-cmd now"), "the parent log carries only the report");
    // --trajectory expands the child log under the `agent` result.
    import nano.trajectory : load;
    auto plain = load(parentLog).toPlain;
    assert(plain.canFind("sub-agent log: " ~ child) && plain.canFind("│") && plain.canFind("forbidden-cmd"), plain);
    assert(load(parentLog).toJson.canFind(`"sub_rows"`));
    // After session tidying compresses the child log, the reference (still
    // the .jsonl path) resolves to the archive.
    import nano.session : gzipLog;
    import std.file : write, remove;
    write(child ~ ".gz", gzipLog(readText(child)));
    remove(child);
    assert(load(parentLog).toPlain.canFind("forbidden-cmd"), "compressed child rows still expand");
}

// Limits: past its turn cap the child gets one more call to report, then
// stops; the partial report is returned, marked truncated.
unittest
{
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("l", "agent", agentCall("x", "mock/loop"))]),
        LLMResponse("ok")]);
    SubLimits lim;
    lim.turns = 2;
    f.agent.subagentLimits = lim;
    assert(f.agent.run("go", new NullEvents) == "ok");
    auto r = f.toolResult("l");
    assert(r.canFind("partial: looked at a.d:1") && r.canFind("[truncated: turn limit (2 model calls)"), r);
    assert(f.grepped.length == 1, "no call ran past the limit");
}

// Read-only: the child is not offered write tools or `agent` (depth 1), and
// bad arguments are a tool error for the parent.
unittest
{
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("n", "agent", agentCall("x", "mock/nested")),
        ToolCall.fromRaw("bad", "agent", `{"task":"x","tools":"all"}`)]), LLMResponse("ok")]);
    assert(f.agent.run("go", new NullEvents) == "ok");
    assert(f.toolResult("n").canFind("no nesting"));
    assert(f.toolResult("bad").canFind(`tools must be "read-only"`));
}

// Without a client factory (as inside a sub-agent) there is no `agent` tool.
unittest
{
    auto a = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    assert(!a.offeredTools.canFind!(t => t.name == "agent"));
}

// A child's read_file never authorizes a parent write: it runs on the
// child's own ReadState, so the parent's registry records nothing.
unittest
{
    import nano.tools.files : registerFiles = register, ReadState;
    import std.conv : to;
    import std.file : mkdirRecurse, write, readText;
    auto dir = buildPath(tempDir, "nano-sub-readstate-" ~ monoNow.ticks.to!string);
    mkdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto target = buildPath(dir, "f.txt");
    write(target, "one\n");
    auto parentState = new ReadState;
    auto reg = new ToolRegistry;
    registerFiles(reg, parentState);
    auto parent = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c", "agent",
            `{"task":"read it","model":"mock/read"}`)]),
        LLMResponse("", "", [ToolCall.fromRaw("w", "write_file",
            JSONValue(["path": target, "content": "two\n"]).toString)]),
        LLMResponse("done")]);
    final class ReadScript : SubClientFactory
    {
        LLMClient make(string spec) const
        {
            return new MockClient([LLMResponse("", "", [ToolCall.fromRaw("r", "read_file",
                JSONValue(["path": target]).toString)]), report("saw one")]);
        }
        void configure(Agent a, string spec) const {}
    }
    auto agent = new Agent(parent, reg, Policy.init, "sys");
    agent.subagentClients = new immutable ReadScript;
    auto answer = agent.run("go", new NullEvents);
    // The child read the file (its report says so)...
    assert(toolResultText(agent, "c").canFind("saw one"));
    // ...but the parent's write_file must still demand the parent read it.
    auto w = toolResultText(agent, "w");
    assert(w.canFind("read") && w.canFind("before"), w);
    assert(readText(target) == "one\n", "the write was refused");
}

string toolResultText(Agent agent, string id)
{
    foreach (m; agent.messages) if (m.role == Role.tool && m.toolCallId == id) return m.content;
    assert(0, "no result for " ~ id);
}

// A report that crosses the token cap on its final call is still marked
// truncated (report_outcome bypasses the forwarded-call limit check).
unittest
{
    final class BigTokens : SubClientFactory
    {
        LLMClient make(string spec) const
        {
            return new MockClient([used(report("done but over budget"), 500, 50)]);
        }
        void configure(Agent a, string spec) const {}
    }
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("t", "agent", agentCall("x", "mock/big"))]),
        LLMResponse("ok")]);
    f.agent.subagentClients = new immutable BigTokens;
    SubLimits lim;
    lim.tokens = 100;
    f.agent.subagentLimits = lim;
    assert(f.agent.run("go", new NullEvents) == "ok");
    assert(f.toolResult("t").canFind("[truncated: token limit (100 tokens)"), f.toolResult("t"));
}

/// A child model that reads `target`, then reports the read's result text
/// verbatim, so a test can see what the parent answered.
final class ReadEcho : MockClient
{
    this(string target)
    {
        super([LLMResponse("", "", [ToolCall.fromRaw("r", "read_file", JSONValue(["path": target]).toString)])]);
    }

    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (script.length) return super.chat(req, sink);
        string last;
        foreach (ref m; req.messages) if (m.role == Role.tool) last = m.content;
        return report("READ: " ~ last);
    }
}

/// Runs one parent turn whose single `agent` call has a ReadEcho child read
/// `target` under `policy`; returns the child's report.
string childReadReport(string target, Policy policy)
{
    final class EchoFactory : SubClientFactory
    {
        string t;
        this(string t) immutable { this.t = t; }
        LLMClient make(string spec) const { return new ReadEcho(t); }
        void configure(Agent a, string spec) const {}
    }
    import nano.tools.files : registerFiles = register, ReadState;
    auto reg = new ToolRegistry;
    registerFiles(reg, new ReadState);
    auto parent = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c", "agent",
        `{"task":"read it","model":"mock/read"}`)]), LLMResponse("done")]);
    auto agent = new Agent(parent, reg, policy, "sys");
    agent.subagentClients = new immutable EchoFactory(target);
    agent.run("go", new NullEvents);
    return toolResultText(agent, "c");
}

// A child's read_file goes through the parent's permission rules: a path the
// parent denies is refused for the child too (review round 5).
unittest
{
    import std.conv : to;
    import std.file : mkdirRecurse, write;
    auto dir = buildPath(tempDir, "nano-sub-readdeny-" ~ monoNow.ticks.to!string);
    mkdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto secret = buildPath(dir, ".env");
    write(secret, "TOKEN=hunter2\n");
    Policy p;
    p.deny ~= parseRule("Read(**/.env)");
    auto r = childReadReport(secret, p);
    assert(r.canFind("READ: ") && !r.canFind("hunter2"), r);
    // Without the rule the same read succeeds.
    assert(childReadReport(secret, Policy.init).canFind("hunter2"));
}

// An ordinary I/O failure in a child's read still answers the child (it must
// not block waiting for a reply): a directory is not a readable file.
unittest
{
    import std.conv : to;
    import std.file : mkdirRecurse;
    auto dir = buildPath(tempDir, "nano-sub-readerr-" ~ monoNow.ticks.to!string);
    mkdirRecurse(buildPath(dir, "sub"));
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto r = childReadReport(buildPath(dir, "sub"), Policy.init);
    assert(r.canFind("READ: "), r);
}

// The footer's "files read" lists only successful reads, at the path the
// parent actually read: a denied read and a missing file never appear.
unittest
{
    import std.conv : to;
    import std.file : mkdirRecurse, write;
    auto dir = buildPath(tempDir, "nano-sub-filesread-" ~ monoNow.ticks.to!string);
    mkdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto ok = buildPath(dir, "ok.txt");
    auto secret = buildPath(dir, ".env");
    write(ok, "hi\n");
    write(secret, "TOKEN=hunter2\n");
    Policy p;
    p.deny ~= parseRule("Read(**/.env)");
    final class ReadThree : SubClientFactory
    {
        string ok, secret, missing;
        this(string ok, string secret, string missing) immutable
        {
            this.ok = ok; this.secret = secret; this.missing = missing;
        }
        LLMClient make(string spec) const
        {
            return new MockClient([LLMResponse("", "", [
                ToolCall.fromRaw("r1", "read_file", JSONValue(["path": ok]).toString),
                ToolCall.fromRaw("r2", "read_file", JSONValue(["path": secret]).toString),
                ToolCall.fromRaw("r3", "read_file", JSONValue(["path": missing]).toString)]),
                report("read what I could")]);
        }
    }
    import nano.tools.files : registerFiles = register, ReadState;
    auto reg = new ToolRegistry;
    registerFiles(reg, new ReadState);
    auto parent = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c", "agent",
        `{"task":"read them","model":"mock/read"}`)]), LLMResponse("done")]);
    auto agent = new Agent(parent, reg, p, "sys");
    agent.subagentClients = new immutable ReadThree(ok, secret, buildPath(dir, "missing.txt"));
    agent.run("go", new NullEvents);
    auto r = toolResultText(agent, "c");
    assert(r.canFind("files read: " ~ ok), r);
    assert(!r.canFind(".env") && !r.canFind("missing.txt"), r);
}

// A reused tool-call id never reuses a compressed child log's filename: both
// the plain and the tidied-up `.jsonl.gz` name count as occupied, so the new
// child gets a fresh id and the old `sub_log` reference still expands the
// original transcript.
unittest
{
    import std.conv : to;
    import std.file : mkdirRecurse, write;
    auto dir = buildPath(tempDir, "nano-sub-logid-" ~ monoNow.ticks.to!string);
    mkdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    final class Immediate : SubClientFactory
    {
        LLMClient make(string spec) const { return new MockClient([report("first child")]); }
    }
    import nano.session : gzipLog;
    auto parent = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c", "agent",
        `{"task":"one","model":"mock/imm"}`)]), LLMResponse("done")]);
    auto agent = new Agent(parent, new ToolRegistry, Policy.init, "sys");
    agent.subagentClients = new immutable Immediate;
    auto logDir = buildPath(dir, "log");
    agent.log = some(new SessionLog(logDir, "mock/m", "/w"));
    agent.run("go", new NullEvents);
    auto first = toolResultText(agent, "c");
    // Tidy-up compresses the child log; only the `.jsonl.gz` name remains.
    // (The child log lives in the parent log's id-named subdirectory.)
    import std.path : stripExtension;
    auto childDir = agent.log.unwrap("set").path.stripExtension;
    auto firstLog = buildPath(childDir, "sub-c.jsonl");
    assert(firstLog.exists, firstLog);
    write(firstLog ~ ".gz", gzipLog(readText(firstLog)));
    import std.file : remove;
    remove(firstLog);
    foreach (l; agent.log) l.close();
    // A resumed session keeps its log path (so its child-log directory is the
    // same) and can reuse a tool-call id: the new child must not take the
    // compressed log's plain filename. Reopening the same path models that.
    auto parent2 = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c", "agent",
        `{"task":"two","model":"mock/imm"}`)]), LLMResponse("done")]);
    auto agent2 = new Agent(parent2, new ToolRegistry, Policy.init, "sys");
    agent2.subagentClients = new immutable Immediate;
    agent2.log = some(new SessionLog(agent.log.unwrap("set").path));
    agent2.run("go", new NullEvents);
    assert(!firstLog.exists, "the plain name stayed with the compressed log");
    auto second = buildPath(childDir, "sub-c-2.jsonl");
    assert(second.exists, "the reused id got a fresh filename: " ~ second);
    assert(readText(second).canFind("first child"), "the new child's transcript");
}

// A mutation between two `agent` calls is a barrier: the second child does
// not start (so none of its reads run) until the edit ran, even while the
// parent waits on the first child.
unittest
{
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("a1", "agent", agentCall("first", "mock/search")),
        ToolCall.fromRaw("e", "bash", `{"command":"edit"}`),
        ToolCall.fromRaw("a2", "agent", agentCall("second", "mock/after"))]), LLMResponse("ok")]);
    assert(f.agent.run("go", new NullEvents) == "ok");
    import std.algorithm : countUntil;
    auto edit = f.order.countUntil("bash edit"), read = f.order.countUntil("grep after-edit");
    assert(edit >= 0 && read > edit, "the second child read before the edit");
    assert(f.toolResult("a2").canFind("saw the edit"));
}

// With a concurrency cap of one, the report that shows a child finishing
// also shows its replacement running (it has a live row from the start).
unittest
{
    import nano.subagent : SubProgress;
    final class Seen : NullEvents
    {
        SubProgress[][] reports;
        override void subagents(const(SubProgress)[] all) { reports ~= all.dup; }
    }
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("q1", "agent", agentCall("1", "mock/parallel")),
        ToolCall.fromRaw("q2", "agent", agentCall("2", "mock/parallel"))]), LLMResponse("ok")]);
    f.agent.subagentMaxConcurrency = 1;
    auto ev = new Seen;
    assert(f.agent.run("go", ev) == "ok");
    bool together;
    foreach (r; ev.reports)
        if (r.canFind!(p => p.callId == "q1" && p.done) && r.canFind!(p => p.callId == "q2" && !p.done)) together = true;
    assert(together, "the replacement was started after the report");
}

// `/subagents off` leaves the agent tool out of the next request (and an
// agent call then is an unknown tool); with candidates, the offered tool
// lists them and an omitted model runs on the first.
unittest
{
    import nano.subagent : SubCandidate;
    auto f = new Fixture([LLMResponse("", "", [ToolCall.fromRaw("c1", "agent", `{"task":"find the parser"}`)]),
        LLMResponse("done")]);
    f.agent.subagentCandidates = [SubCandidate("mock/search", "searches", SubLimits(3, 30, 1000))];
    auto tool = f.agent.offeredTools;
    size_t i;
    while (tool[i].name != "agent") i++;
    assert(tool[i].parameters["properties"]["model"]["enum"][0].str == "mock/search");
    f.agent.subagentsOn = false;
    assert(!f.agent.offeredTools.canFind!(t => t.name == "agent"));
    assert(f.agent.run("go", new NullEvents) == "done");
    assert(f.toolResult("c1").canFind("agent"), "an agent call while off is not run as a sub-agent");
    f.agent.subagentsOn = true;
    assert(f.agent.offeredTools.canFind!(t => t.name == "agent"));
}
