/// Background sub-agents (issue #266): `agent(background: true)` returns a
/// handle at once; `agent_status`, `agent_read`, `agent_cancel` and
/// `agent_wait` watch and steer them; their result is delivered once, as a
/// reminder on a later step; Esc and session exit stop them.
module nano.subagent_bg_test;
@safe:

version (unittest):

import core.atomic : atomicLoad, atomicOp, atomicStore, cas;
import core.time : msecs, seconds;
import std.algorithm : canFind, count;
import std.file : exists, readText, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.clock : sleepFor, monoNow, FakeClock, wallNow;
import nano.control : Cancelled, cancelRequested;
import nano.llm;
import nano.option : some, unwrap;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : SessionLog;
import nano.subagent : SubClientFactory;
import nano.tools : ToolRegistry;

private:

shared bool gateOpen, gateReached;
shared int active, peak;

LLMResponse report(string summary)
{
    return LLMResponse("", "", [ToolCall.fromRaw("o", "report_outcome",
        JSONValue(["status": "completed", "summary": summary]).toString)]);
}

LLMResponse grep(string pattern)
{
    return LLMResponse("", "", [ToolCall.fromRaw("g", "grep", JSONValue(["pattern": pattern]).toString)]);
}

/// Greps, then waits in its second model call until the test opens the gate.
final class Gated : MockClient
{
    this() { super([grep("parse"), report("gated report")]); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (seen.length == 1)
        {
            atomicStore(gateReached, true);
            auto start = monoNow;
            while (!atomicLoad(gateOpen) && !cancelRequested)
            {
                if (monoNow - start > 5000.msecs) assert(0, "the gate never opened");
                sleepFor(1.msecs);
            }
            if (cancelRequested) throw new Cancelled;
        }
        return super.chat(req, sink);
    }
}

/// Greps forever, until the parent's cancel reminder asks for a report.
final class Looping : MockClient
{
    this() { super([]); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        foreach (ref m; req.messages)
            if (m.content.canFind("cancelled you")) return report("partial: half done");
        sleepFor(1.msecs);
        return grep("again");
    }
}

/// Waits in its model call until it is aborted.
final class Hanging : MockClient
{
    this() { super([]); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto start = monoNow;
        while (!cancelRequested)
        {
            if (monoNow - start > 5000.msecs) assert(0, "never cancelled");
            sleepFor(1.msecs);
        }
        throw new Cancelled;
    }
}

/// Counts children inside a model call at once.
final class Overlapping : MockClient
{
    this() { super([report("overlap report")]); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto now = atomicOp!"+="(active, 1);
        for (;;)
        {
            auto p = atomicLoad(peak);
            if (now <= p || cas(&peak, p, now)) break;
        }
        sleepFor(20.msecs);
        atomicOp!"-="(active, 1);
        return super.chat(req, sink);
    }
}

final class Scripts : SubClientFactory
{
    LLMClient make(string spec) const
    {
        switch (spec)
        {
            case "mock/search": return new MockClient([grep("parse"), report("parser at src/p.d:12")]);
            case "mock/gated": return new Gated;
            case "mock/loop": return new Looping;
            case "mock/hang": return new Hanging;
            case "mock/overlap": return new Overlapping;
            default: assert(0, "no script for " ~ spec);
        }
    }
}

ToolCall call(string id, string name, string args)
{
    return ToolCall.fromRaw(id, name, args);
}

ToolCall bg(string id, string model)
{
    return call(id, "agent", `{"task":"investigate ` ~ id ~ `","model":"` ~ model ~ `","background":true}`);
}

LLMResponse calls(ToolCall[] cs...)
{
    return LLMResponse("", "", cs.dup);
}

final class Fixture
{
    Agent agent;
    MockClient parent;
    string dir;

    this(LLMResponse[] script)
    {
        parent = new MockClient(script);
        auto reg = new ToolRegistry;
        reg.register(ToolDefinition("grep", "search", parseJSON(`{"type":"object"}`)), (JSONValue a) {
            if (a["pattern"].str == "trigger-cancel") agent.control.cancel();
            return "src/p.d:12: parse()";
        });
        agent = new Agent(parent, reg, Policy.init, "sys");
        agent.subagentClients = new immutable Scripts;
    }

    void persist(string name)
    {
        import std.conv : to;
        dir = buildPath(tempDir, "nano-subagent-bg-" ~ name ~ "-" ~ monoNow.ticks.to!string);
        agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    }

    void cleanup()
    {
        agent.stopSubagents();
        if (dir.length && dir.exists) rmdirRecurse(dir);
    }

    string toolResult(string id)
    {
        foreach (m; agent.messages) if (m.role == Role.tool && m.toolCallId == id) return m.content;
        assert(0, "no result for " ~ id);
    }

    /// Serve the background children until one has a result waiting.
    void awaitResult()
    {
        auto start = monoNow;
        while (!agent.backgroundResultsReady())
        {
            assert(monoNow - start < 5.seconds, "no background result");
            sleepFor(1.msecs);
        }
    }

    /// The reminders in the conversation that carry a background result.
    size_t deliveries(string needle)
    {
        return agent.messages.count!(m => m.role == Role.user && m.content.canFind("Background sub-agent")
            && m.content.canFind(needle));
    }
}

// A background start returns at once with a handle; the result arrives as
// one reminder on a later step, and only once.
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/search")), LLMResponse("started it"),
        LLMResponse("got it"), LLMResponse("still nothing new")]);
    scope (exit) f.cleanup();
    assert(f.agent.offeredTools.canFind!(t => t.name == "agent_wait"));
    assert(f.agent.run("go", new NullEvents) == "started it");
    auto r = f.toolResult("b1");
    assert(r.canFind("Started sub-1 in the background") && r.canFind("mock/search"), r);
    f.awaitResult();
    assert(f.agent.run("next", new NullEvents) == "got it");
    assert(f.deliveries("parser at src/p.d:12") == 1);
    auto seen = f.parent.seen[2];
    assert(seen.canFind!(m => m.content.canFind("parser at src/p.d:12")), "the model saw the result");
    assert(f.agent.run("again", new NullEvents) == "still nothing new");
    assert(f.deliveries("parser at src/p.d:12") == 1, "delivered once");
    assert(!f.agent.subagentsActive);
}

// agent_status and agent_read while it runs: state, turns, last tool call;
// the log from a line with the next `since`.
unittest
{
    atomicStore(gateOpen, false);
    atomicStore(gateReached, false);
    auto f = new Fixture([calls(bg("b1", "mock/gated")), LLMResponse("started"),
        calls(call("s", "agent_status", `{}`), call("r", "agent_read", `{"id":"sub-1"}`),
            call("r2", "agent_read", `{"id":"sub-1","since":1000}`), call("x", "agent_status", `{"id":"sub-9"}`)),
        LLMResponse("looked")]);
    f.persist("status");
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "started");
    auto start = monoNow;
    while (!atomicLoad(gateReached))
    {
        assert(monoNow - start < 5.seconds);
        f.agent.pollSubagents();
        sleepFor(1.msecs);
    }
    assert(f.agent.subagentsActive);
    assert(f.agent.run("check", new NullEvents) == "looked");
    auto st = f.toolResult("s");
    assert(st.canFind("sub-1 [running]") && st.canFind("1 turns") && st.canFind("grep(pattern=parse)"), st);
    auto rd = f.toolResult("r");
    assert(rd.canFind(`"grep"`) && rd.canFind("[next since: "), rd);
    assert(f.toolResult("r2").canFind("(no line 1000 yet)"));
    assert(f.toolResult("x").canFind("no sub-agent sub-9"));
    atomicStore(gateOpen, true);
    f.awaitResult();
}

// agent_cancel: the child gets a final step to report; the report is the
// result, marked cancelled and partial.
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/loop")), LLMResponse("started"),
        calls(call("c", "agent_cancel", `{"id":"sub-1","reason":"wrong track"}`)), LLMResponse("cancelled it"),
        LLMResponse("nothing more")]);
    f.persist("cancel");
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "started");
    assert(f.agent.run("stop it", new NullEvents) == "cancelled it");
    auto r = f.toolResult("c");
    assert(r.canFind("partial: half done") && r.canFind("ended: cancelled") && r.canFind("cancelled by the parent: wrong track"), r);
    assert(f.agent.run("more", new NullEvents) == "nothing more");
    assert(f.deliveries("half done") == 0, "agent_cancel's result counts as delivery");
    assert(readText(f.agent.log.unwrap("set").path).canFind(`"type":"subagent"`));
}

// A child that can't report within the grace period is cut off with an
// empty report (fake time: the grace passes at once).
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/hang")), LLMResponse("started"),
        calls(call("c", "agent_cancel", `{"id":"sub-1","reason":"stuck"}`)), LLMResponse("cut")]);
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "started");
    {
        auto clock = FakeClock.install(wallNow);
        assert(f.agent.run("stop it", new NullEvents) == "cut");
    }
    auto r = f.toolResult("c");
    assert(r.canFind("(no report: it did not report within 5s and was cut off)") && r.canFind("cancelled"), r);
    assert(!f.agent.subagentsActive);
}

// agent_wait: returns the result on completion (counting as delivery), and
// the status on timeout.
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/search")), calls(call("w", "agent_wait", `{"ids":["sub-1"],"timeout_s":30}`)),
        LLMResponse("waited"), LLMResponse("no repeat")]);
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "waited");
    assert(f.toolResult("w").canFind("parser at src/p.d:12"), f.toolResult("w"));
    assert(f.agent.run("next", new NullEvents) == "no repeat");
    assert(f.deliveries("parser at src/p.d:12") == 0, "agent_wait delivered it");

    auto g = new Fixture([calls(bg("h1", "mock/hang")), calls(call("w", "agent_wait", `{"ids":["sub-1"],"timeout_s":2}`)),
        LLMResponse("timed out")]);
    scope (exit) g.cleanup();
    {
        auto clock = FakeClock.install(wallNow);
        assert(g.agent.run("go", new NullEvents) == "timed out");
    }
    assert(g.toolResult("w").canFind("still running: sub-1 [running]"), g.toolResult("w"));
    assert(g.agent.subagentsActive);
}

// Background and blocking sub-agents share the concurrency cap.
unittest
{
    atomicStore(active, 0);
    atomicStore(peak, 0);
    auto f = new Fixture([calls(bg("b1", "mock/overlap"),
        call("k1", "agent", `{"task":"blocking","model":"mock/overlap"}`)), LLMResponse("both")]);
    scope (exit) f.cleanup();
    f.agent.subagentMaxConcurrency = 1;
    assert(f.agent.run("go", new NullEvents) == "both");
    assert(f.toolResult("b1").canFind("Started sub-1"));
    assert(f.toolResult("k1").canFind("overlap report"));
    assert(atomicLoad(peak) == 1, "one at a time");
    // A background one queued behind a running one says so.
    auto g = new Fixture([calls(bg("b1", "mock/hang"), bg("b2", "mock/search")), LLMResponse("two")]);
    scope (exit) g.cleanup();
    g.agent.subagentMaxConcurrency = 1;
    assert(g.agent.run("go", new NullEvents) == "two");
    assert(g.toolResult("b2").canFind("queued"), g.toolResult("b2"));
}

// Esc Esc stops background children; so does leaving the session.
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/hang")), LLMResponse("started"),
        calls(call("t", "grep", `{"pattern":"trigger-cancel"}`)), LLMResponse("never")]);
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "started");
    assert(f.agent.subagentsActive);
    f.agent.run("esc", new NullEvents);
    assert(!f.agent.subagentsActive, "Esc stopped the background child");
    f.agent.control.startTurn();

    auto g = new Fixture([calls(bg("b1", "mock/hang")), LLMResponse("started")]);
    g.persist("exit");
    scope (exit) g.cleanup();
    assert(g.agent.run("go", new NullEvents) == "started");
    g.agent.stopSubagents();
    assert(!g.agent.subagentsActive);
    auto text = readText(g.agent.log.unwrap("set").path);
    assert(text.canFind(`"event":"stopped"`), text);
}

// A delivered background result is in the log, so a resume shows it.
unittest
{
    import nano.session : restore;
    auto f = new Fixture([calls(bg("b1", "mock/search")), LLMResponse("started"), LLMResponse("got it")]);
    f.persist("resume");
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "started");
    f.awaitResult();
    assert(f.agent.run("next", new NullEvents) == "got it");
    auto path = f.agent.log.unwrap("set").path;
    auto conv = restore(path).conversation;
    assert(conv.canFind!(m => m.content.canFind("Background sub-agent sub-1")
        && m.content.canFind("parser at src/p.d:12")), "the resumed conversation holds the result");
}
