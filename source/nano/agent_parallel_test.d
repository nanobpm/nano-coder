/// Read-only tool calls of one reply run concurrently (issue #222): runs of
/// consecutive read-only calls overlap, barriers run alone, and what is
/// observable (results, order, ids) matches one call at a time.
module nano.agent_parallel_test;
@safe:

version (unittest):

import core.atomic : atomicLoad, atomicOp, atomicStore;
import std.conv : to;
import std.file : mkdirRecurse, rmdirRecurse, exists, readText, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.control : cancelledResponse, cancelledToolResult;
import nano.llm;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.tools : Concurrency, Job, JobResult, ToolRegistry;
import nano.tools.files : ReadState, registerFiles = register;
import nano.tools.search : registerSearch = register;

private:

/// Calls of a rendezvous that have started, and the release a test gives.
shared int arrived;
shared bool released;

/// Waits (bounded) until `context[0]` calls have arrived: only calls that
/// run at the same time all see "together".
JobResult rendezvous(string argsJson, immutable(string)[] context)
{
    import nano.clock : monoNow, since, sleepFor;
    import core.time : msecs, seconds;
    atomicOp!"+="(arrived, 1);
    auto want = context[0].to!int;
    auto start = monoNow;
    while (atomicLoad(arrived) < want && since(start) < 10.seconds) sleepFor(1.msecs);
    return JobResult(atomicLoad(arrived) >= want ? "together " ~ argsJson : "alone " ~ argsJson);
}

/// Waits (bounded) for the test's release.
JobResult held(string argsJson, immutable(string)[] context)
{
    import nano.clock : monoNow, since, sleepFor;
    import core.time : msecs, seconds;
    auto start = monoNow;
    while (!atomicLoad(released) && since(start) < 10.seconds) sleepFor(1.msecs);
    return JobResult("held");
}

ToolDefinition def(string name) { return ToolDefinition(name, name, parseJSON(`{"type":"object"}`)); }

LLMResponse reply(ToolCall[] calls) { return LLMResponse("", "", calls); }

ToolCall call(string id, string name, string args = `{}`) { return ToolCall.fromRaw(id, name, args); }

/// The tool results of a finished turn, as (id, name, content, error).
string[] results(Agent agent)
{
    string[] r;
    foreach (ref m; agent.messages)
        if (m.role == Role.tool) r ~= [m.toolCallId, m.toolName, m.content, m.isError.to!string].to!string;
    return r;
}

// N read-only calls overlap: each waits for all the others, so a sequential
// run would see "alone" (after its timeout); results keep call order and ids.
unittest
{
    atomicStore(arrived, 0);
    auto reg = new ToolRegistry;
    Concurrency c;
    c.readOnly = true;
    c.offload = (JSONValue a) => Job(&rendezvous, a.toString, ["3"]);
    reg.register(def("meet"), (JSONValue a) => "sequential", c);
    auto mock = new MockClient([
        reply([call("a", "meet", `{"n":1}`), call("b", "meet", `{"n":2}`), call("c", "meet", `{"n":3}`)]),
        LLMResponse("done"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "done");
    assert(results(agent) == [
        `["a", "meet", "together {\"n\":1}", "false"]`,
        `["b", "meet", "together {\"n\":2}", "false"]`,
        `["c", "meet", "together {\"n\":3}", "false"]`,
    ], results(agent).to!string);
}

/// The real file and search tools, each call run alone.
ToolRegistry sequentialFiles()
{
    // Re-register each read-only tool without its concurrency.
    auto inner = new ToolRegistry;
    registerFiles(inner, new ReadState);
    registerSearch(inner);
    auto reg = new ToolRegistry;
    foreach (d; inner.definitions)
    {
        auto h = (string n) => (JSONValue a) => inner.execute(n, a);
        reg.register(d, h(d.name));
    }
    return reg;
}

ToolRegistry concurrentFiles()
{
    auto reg = new ToolRegistry;
    registerFiles(reg, new ReadState);
    registerSearch(reg);
    return reg;
}

// Results in `messages` are identical to one call at a time, for reads,
// searches, errors and repeats (the loop detector sees the same sequence).
unittest
{
    auto root = buildPath(tempDir, "nano-parallel-identical");
    if (root.exists) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "src"));
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "src/a.d"), "module a;\nint needle = 1;\n");
    write(buildPath(root, "src/b.d"), "needle\n");
    auto a = buildPath(root, "src/a.d");
    ToolCall[] calls = [
        call("1", "read_file", `{"path":"` ~ a ~ `"}`),
        call("2", "grep", `{"pattern":"needle","path":"` ~ root ~ `"}`),
        call("3", "glob", `{"pattern":"*.d","path":"` ~ root ~ `"}`),
        call("4", "read_file", `{"path":"` ~ root ~ `/missing"}`),
        call("5", "grep", `{"pattern":"(","path":"` ~ root ~ `"}`),
    ];
    foreach (i; 0 .. 6) calls ~= call("r" ~ i.to!string, "glob", `{"pattern":"*.d","path":"` ~ root ~ `"}`);
    string[] run(ToolRegistry reg)
    {
        auto agent = new Agent(new MockClient([reply(calls), LLMResponse("done")]), reg, Policy.init, "sys");
        agent.run("go", new NullEvents);
        return results(agent);
    }
    auto seq = run(sequentialFiles);
    auto par = run(concurrentFiles);
    assert(seq.length == calls.length);
    assert(seq == par, "sequential:\n" ~ seq.to!string ~ "\nconcurrent:\n" ~ par.to!string);
}

// An edit is a barrier: read, edit, read keeps the edit between the reads,
// and the concurrent read_file records what it read (the edit is allowed).
unittest
{
    auto root = buildPath(tempDir, "nano-parallel-barrier");
    if (root.exists) rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto f = buildPath(root, "f.txt");
    write(f, "old\n");
    auto agent = new Agent(new MockClient([
        reply([
            call("1", "read_file", `{"path":"` ~ f ~ `"}`),
            call("2", "glob", `{"pattern":"*.txt","path":"` ~ root ~ `"}`),
            call("3", "edit_file", `{"path":"` ~ f ~ `","old_string":"old","new_string":"new"}`),
            call("4", "read_file", `{"path":"` ~ f ~ `"}`),
            call("5", "grep", `{"pattern":"new","path":"` ~ root ~ `"}`),
        ]),
        LLMResponse("done"),
    ]), concurrentFiles, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "done");
    string[] tool;
    foreach (ref m; agent.messages) if (m.role == Role.tool) tool ~= m.content;
    import std.algorithm : canFind;
    assert(tool[0].canFind("old") && !tool[2].canFind("has not been read"), tool[2]);
    assert(tool[3].canFind("new") && tool[4].canFind("f.txt:1:new"), tool.to!string);
    assert(readText(f) == "new\n");
}

// A cancel mid-run: the calls that hadn't finished report the usual
// interrupted result, the one that finished keeps its result, every worker
// is joined, and the turn ends cancelled.
unittest
{
    atomicStore(released, false);
    auto reg = new ToolRegistry;
    Agent agent;
    Concurrency slow;
    slow.readOnly = true;
    slow.offload = (JSONValue a) => Job(&held, a.toString, null);
    reg.register(def("slow"), (JSONValue a) => "sequential", slow);
    // Runs on the agent's thread while the workers wait: cancels, then lets
    // them finish (after the cancel).
    reg.register(def("stop"), (JSONValue a) {
        agent.control.cancel();
        atomicStore(released, true);
        return "stopped";
    }, Concurrency(true));
    auto mock = new MockClient([
        reply([call("a", "slow"), call("b", "stop"), call("c", "slow")]),
        LLMResponse("never"),
    ]);
    agent = new Agent(mock, reg, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == cancelledResponse);
    assert(mock.seen.length == 1);
    assert(results(agent) == [
        `["a", "slow", "` ~ cancelledToolResult ~ `", "true"]`,
        `["b", "stop", "` ~ cancelledToolResult ~ `", "true"]`,
        `["c", "slow", "` ~ cancelledToolResult ~ `", "true"]`,
    ], results(agent).to!string);
    // The next turn starts clean.
    agent.client = new MockClient([LLMResponse("fine")]);
    assert(agent.run("again", new NullEvents) == "fine");
}

// Only read-only calls join a run: a barrier tool between two read-only
// calls runs alone, after the first and before the second.
unittest
{
    auto reg = new ToolRegistry;
    string[] order;
    reg.register(def("look"), (JSONValue a) { order ~= "look"; return "seen"; }, Concurrency(true));
    reg.register(def("change"), (JSONValue a) { order ~= "change"; return "changed"; });
    auto mock = new MockClient([
        reply([call("1", "look"), call("2", "look"), call("3", "change"), call("4", "look"), call("5", "look")]),
        LLMResponse("done"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == "done");
    assert(order == ["look", "look", "change", "look", "look"], order.to!string);
}

/// Returns at once, counting itself in `arrived`.
JobResult quick(string argsJson, immutable(string)[] context)
{
    atomicOp!"+="(arrived, 1);
    return JobResult("quick");
}

/// Set by `Agent.worker` (through its test hook) once it has read the cancel
/// flag for its `afterCancel` metadata. `stop` waits for this instead of a
/// fixed delay, so the cancel is ordered after the worker's actual read.
shared bool workerRecorded;

/// How many workers have read their `afterCancel` metadata.
shared int fastDone;

void recordWorker() @safe
{
    atomicOp!"+="(fastDone, 1);
    atomicStore(workerRecorded, true);
}

// A worker that finished before a cancel keeps its result, even though the
// agent collects it only after the cancel.
unittest
{
    import nano.clock : monoNow, since, sleepFor;
    import core.time : msecs, seconds;
    atomicStore(arrived, 0);
    atomicStore(workerRecorded, false);
    atomicStore(Agent.workerRecordedHook, &recordWorker);
    scope (exit) atomicStore(Agent.workerRecordedHook, null);
    auto reg = new ToolRegistry;
    Agent agent;
    Concurrency fast;
    fast.readOnly = true;
    fast.offload = (JSONValue a) => Job(&quick, a.toString, null);
    reg.register(def("fast"), (JSONValue a) => "sequential", fast);
    // On the agent's thread: waits for the worker to record its completion
    // metadata, then cancels.
    reg.register(def("stop"), (JSONValue a) {
        auto start = monoNow;
        while (!atomicLoad(workerRecorded) && since(start) < 10.seconds) sleepFor(1.msecs);
        agent.control.cancel();
        return "stopped";
    }, Concurrency(true));
    auto mock = new MockClient([reply([call("a", "fast"), call("b", "stop")]), LLMResponse("never")]);
    agent = new Agent(mock, reg, Policy.init, "sys");
    assert(agent.run("go", new NullEvents) == cancelledResponse);
    assert(results(agent) == [
        `["a", "fast", "quick", "false"]`,
        `["b", "stop", "` ~ cancelledToolResult ~ `", "true"]`,
    ], results(agent).to!string);
}

// A call still running when a cancel arrives reports the interrupted result,
// not the loop-stop result, even when an earlier finished call tripped the
// loop detector: cancellation outranks the loop stop for an unfinished call.
unittest
{
    import nano.agent : loopStoppedToolResult;
    import std.algorithm : canFind;
    import nano.clock : monoNow, since, sleepFor;
    import core.time : msecs, seconds;
    atomicStore(arrived, 0);
    atomicStore(fastDone, 0);
    atomicStore(released, false);
    atomicStore(Agent.workerRecordedHook, &recordWorker);
    scope (exit) atomicStore(Agent.workerRecordedHook, null);
    auto reg = new ToolRegistry;
    Agent agent;
    // The five identical calls run `quick`, counting each past its metadata
    // read so the cancel lands only once all five are recorded finished.
    Concurrency fast;
    fast.readOnly = true;
    fast.offload = (JSONValue a) => Job(&quick, a.toString, null);
    reg.register(def("fast"), (JSONValue a) => "sequential", fast);
    Concurrency slow;
    slow.readOnly = true;
    slow.offload = (JSONValue a) => Job(&held, a.toString, null);
    reg.register(def("slow"), (JSONValue a) => "sequential", slow);
    // Runs on the agent's thread while the workers run: waits for the five
    // `fast` workers to be recorded finished (so the fifth trips the loop
    // detector), then cancels while `slow` is still blocked, then releases it.
    reg.register(def("stop"), (JSONValue a) {
        auto start = monoNow;
        while (atomicLoad(fastDone) < 5 && since(start) < 10.seconds) sleepFor(1.msecs);
        agent.control.cancel();
        atomicStore(released, true);
        return "stopped";
    }, Concurrency(true));
    auto mock = new MockClient([
        reply([
            call("a", "fast", `{"n":1}`), call("b", "fast", `{"n":1}`),
            call("c", "fast", `{"n":1}`), call("d", "fast", `{"n":1}`),
            call("e", "fast", `{"n":1}`), call("f", "slow"), call("g", "stop"),
        ]),
        LLMResponse("never"),
    ]);
    agent = new Agent(mock, reg, Policy.init, "sys");
    agent.run("go", new NullEvents);
    auto r = results(agent);
    // The five finished `fast` calls tripped the loop detector, so the turn
    // is ending; but the interrupted `slow` call keeps the cancelled result,
    // not the loop-stop one.
    assert(r[5] == `["f", "slow", "` ~ cancelledToolResult ~ `", "true"]`, r.to!string);
    assert(!r[5].canFind(loopStoppedToolResult), r[5]);
    // The fifth fast call did trip the loop detector's hard stop.
    assert(r[4].canFind("repeated too many times"), r[4]);
}

