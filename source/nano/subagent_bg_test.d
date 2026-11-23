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
import std.conv : to;
import nano.agent;
import nano.clock : sleepFor, monoNow, FakeClock, wallNow;
import nano.control : Cancelled, cancelRequested;
import nano.llm;
import nano.option : Option, some, unwrap;
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

/// A parent that opens the gate in its second model call: after the step's
/// preparation, so a gated child cannot finish before that step's tools run.
final class OpensGate : MockClient
{
    this(LLMResponse[] script) { super(script); }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (seen.length == 1) atomicStore(gateOpen, true);
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
        this(new MockClient(script));
    }

    this(MockClient client)
    {
        parent = client;
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

    /// Serve the background children until none is running. A fast child
    /// may finish (and be delivered) inside the turn that started it, so
    /// waiting for an undelivered result could wait forever.
    void awaitDone()
    {
        auto start = monoNow;
        while (agent.subagentsActive)
        {
            assert(monoNow - start < 5.seconds, "the background child never finished");
            agent.pollSubagents();
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
    f.awaitDone();
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
    // The gated child can't finish before the step that waits for it.
    atomicStore(gateOpen, false);
    atomicStore(gateReached, false);
    auto f = new Fixture(new OpensGate([calls(bg("b1", "mock/gated")),
        calls(call("w", "agent_wait", `{"ids":["sub-1"],"timeout_s":30}`)), LLMResponse("waited"), LLMResponse("no repeat")]));
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "waited");
    assert(f.toolResult("w").canFind("gated report"), f.toolResult("w"));
    assert(f.agent.run("next", new NullEvents) == "no repeat");
    assert(f.deliveries("gated report") == 0, "agent_wait delivered it");

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
    f.awaitDone();
    assert(f.agent.run("next", new NullEvents) == "got it");
    auto path = f.agent.log.unwrap("set").path;
    auto conv = restore(path).conversation;
    assert(conv.canFind!(m => m.content.canFind("Background sub-agent sub-1")
        && m.content.canFind("parser at src/p.d:12")), "the resumed conversation holds the result");
}

// Cancelled children are pruned like delivered ones: starting and
// cancelling many keeps only the most recent few. Queued children (the cap
// is held by a hanging one) cancel at once, keeping the test fast.
unittest
{
    import std.format : format;
    import nano.subagent : keepDelivered;
    enum n = keepDelivered + 4;
    ToolCall[] starts = [bg("h", "mock/hang")], cancels;
    foreach (k; 0 .. n)
    {
        starts ~= bg(format("b%s", k), "mock/search");
        cancels ~= call(format("c%s", k), "agent_cancel", format(`{"id":"sub-%s","reason":"r"}`, k + 2));
    }
    auto f = new Fixture([calls(starts), calls(cancels), calls(call("s", "agent_status", `{}`)), LLMResponse("done")]);
    scope (exit) f.cleanup();
    f.agent.subagentMaxConcurrency = 1;
    assert(f.agent.run("go", new NullEvents) == "done");
    auto st = f.toolResult("s");
    assert(st.count("\n") + 1 == keepDelivered + 1, st); // the hanging one plus the kept few
}

// A host that can't serve background children between prompts (ACP)
// refuses them; a blocking one still runs.
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/search")), LLMResponse("refused")]);
    scope (exit) f.cleanup();
    f.agent.backgroundSubagents = false;
    assert(f.agent.run("go", new NullEvents) == "refused");
    assert(f.toolResult("b1").canFind("background sub-agents are not available here"), f.toolResult("b1"));
    assert(!f.agent.subagentsActive);
}

// Loading another session stops the children of the one being left.
unittest
{
    import nano.session : restore, Restored;
    auto f = new Fixture([calls(bg("b1", "mock/hang")), LLMResponse("started")]);
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "started");
    assert(f.agent.subagentsActive);
    Restored r;
    f.agent.loadRestored(r, Option!SessionLog.init);
    assert(!f.agent.subagentsActive, "the loader stopped them");
}

// A provider can repeat a call id across replies (OpenAI's fallback emits
// `call_0` each time): two background starts with the same id still get
// their own log file and progress row key.
unittest
{
    import nano.subagent : SubProgress;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName, stripExtension;
    import std.algorithm : startsWith;
    import std.format : format;
    final class Rows : NullEvents
    {
        string[] handles;
        override void subagents(const SubProgress[] all) { foreach (ref p; all) handles ~= p.handle; }
    }
    auto f = new Fixture([calls(bg("call_0", "mock/search")), calls(bg("call_0", "mock/search")),
        LLMResponse("started both")]);
    f.persist("dupid");
    scope (exit) f.cleanup();
    auto rows = new Rows;
    assert(f.agent.run("go", rows) == "started both");
    assert(rows.handles.canFind("sub-1") && rows.handles.canFind("sub-2"), format("%s", rows.handles));
    f.agent.stopSubagents();
    auto childDir = f.agent.log.unwrap("set").path.stripExtension;
    string[] names;
    foreach (e; dirEntries(childDir, SpanMode.shallow)) names ~= e.name.baseName;
    assert(names.canFind!(n => n.startsWith("sub-1.")) && names.canFind!(n => n.startsWith("sub-2.")), format("%s", names));
}

// `/subagents` lists every sub-agent of the session in mixed states, with
// finished blocking ones kept after their reply (issue #267).
unittest
{
    auto f = new Fixture([calls(call("k1", "agent", `{"task":"blocking one\nsecond line","model":"mock/search"}`),
        bg("b1", "mock/hang"), bg("b2", "mock/search")), LLMResponse("three")]);
    f.persist("list");
    scope (exit) f.cleanup();
    f.agent.subagentMaxConcurrency = 1;
    assert(f.agent.run("go", new NullEvents) == "three");
    size_t forgotten;
    auto all = f.agent.subagentList(forgotten);
    assert(forgotten == 0 && all.length == 3, all.length.to!string);
    assert(all[0].id == "sub-1" && all[0].state == "done" && all[0].task == "blocking one" && !all[0].background
        && all[0].model == "mock/search" && all[0].turns == 2 && all[0].logPath.length);
    assert(all[1].id == "sub-2" && all[1].state == "running" && all[1].background);
    assert(all[2].id == "sub-3" && all[2].state == "queued");
    assert(f.agent.subagentLog("sub-1").isOk && f.agent.subagentLog("sub-3").isErr
        && f.agent.subagentLog("sub-9").isErr);
    // Leaving the session (`/new`, `/restart`) forgets its sub-agents.
    f.agent.restart("sys", Option!(imported!"nano.session".SessionLog).init);
    all = f.agent.subagentList(forgotten);
    assert(forgotten == 0 && all.length == 0, all.length.to!string);
    assert(f.agent.stopSubagentsByUser("sub-1").canFind("No sub-agent sub-1"));
}

// `/subagents stop <id>`: the child reports what it has, marked cancelled,
// and the parent gets it as a background result; an ended one says so.
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/loop")), LLMResponse("started"), LLMResponse("saw it")]);
    f.persist("userstop");
    scope (exit) f.cleanup();
    assert(f.agent.run("go", new NullEvents) == "started");
    auto said = f.agent.stopSubagentsByUser("sub-1");
    assert(said.canFind("Stopped sub-1"), said);
    assert(!f.agent.subagentsActive);
    assert(f.agent.stopSubagentsByUser("sub-1").canFind("already ended (cancelled)"));
    assert(f.agent.stopSubagentsByUser("sub-7").canFind("No sub-agent sub-7"));
    assert(f.agent.backgroundResultsReady());
    assert(f.agent.run("next", new NullEvents) == "saw it");
    auto seen = f.parent.seen[2];
    assert(seen.canFind!(m => m.content.canFind("partial: half done") && m.content.canFind("ended: cancelled")
        && m.content.canFind("cancelled by the user")), "the model got the cancelled result");
    assert(readText(f.agent.log.unwrap("set").path).canFind(`"text":"stopped by the user"`));
}

// `/subagents stop all`: running and queued ones; one that can't report is
// cut off (fake time).
unittest
{
    auto f = new Fixture([calls(bg("b1", "mock/hang"), bg("b2", "mock/loop"), bg("b3", "mock/search")),
        LLMResponse("started")]);
    scope (exit) f.cleanup();
    f.agent.subagentMaxConcurrency = 2;
    assert(f.agent.run("go", new NullEvents) == "started");
    string said;
    {
        auto clock = FakeClock.install(wallNow);
        said = f.agent.stopSubagentsByUser("all");
    }
    assert(said.canFind("sub-1") && said.canFind("sub-2") && said.canFind("sub-3"), said);
    assert(!f.agent.subagentsActive);
    size_t forgotten;
    foreach (ref i; f.agent.subagentList(forgotten)) assert(i.state == "cancelled", i.id ~ " " ~ i.state);
    assert(f.agent.stopSubagentsByUser("all") == "No sub-agent is running.");
    string notice;
    auto text = f.agent.takeBackgroundResults(notice);
    assert(text.canFind("cut off") && text.canFind("cancelled before the sub-agent started"), text);
}
