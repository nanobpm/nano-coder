/// Bounded per-session state in `Agent` (issue #312): completed responses
/// kept for idempotent redelivery, and the pinned-request stash.
module nano.agent_bound_test;
@safe:

version (unittest):

import std.conv : to;
import std.file : exists, rmdirRecurse, tempDir;
import std.json : parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.llm;
import nano.option : Option, some, unwrap;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;

private:

Agent agentFor(LLMClient c)
{
    return new Agent(c, new ToolRegistry, Policy.init, "system");
}

// issue #312: completed responses are bounded in memory; an evicted id is
// still redelivered idempotently, from the log's turn_end record.
unittest
{
    import std.array : replicate;
    import nano.session : restore, Restored;
    auto dir = buildPath(tempDir, "nano-d-loop-completed-bound");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    enum cap = 4_096;
    auto big = (string c) => c.replicate(cap / 2 + 1);
    auto agent = agentFor(new MockClient([LLMResponse(big("a")), LLMResponse(big("b")), LLMResponse(big("c"))]));
    agent.completedCap = cap;
    agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    foreach (id; ["in-a", "in-b", "in-c"]) agent.run("go " ~ id, new NullEvents, true, id);
    assert(agent.completedBytes <= cap && agent.completedInputs.length == 1, agent.completedBytes.to!string);
    assert("in-c" in agent.completedInputs && agent.completedEvicted.mayContain("in-a")
        && agent.completedEvicted.mayContain("in-b"));
    // The script is spent: a re-run would fail, so this is the log's copy.
    assert(agent.run("go in-a", new NullEvents, true, "in-a") == big("a"));
    assert(agent.lastStop == StopReason.endTurn);

    // Restoring thousands of turns keeps the responses under the cap.
    auto path = agent.log.unwrap("set above").path;
    {
        auto l = agent.log.unwrap("set above");
        foreach (i; 0 .. 1_000)
        {
            auto id = "bulk-" ~ i.to!string;
            l.input(id, "q");
            l.turnEnd(id, "r".replicate(200) ~ i.to!string, "end_turn");
        }
    }
    auto r = restore(path);
    auto resumed = agentFor(new MockClient([]));
    resumed.completedCap = cap;
    resumed.loadRestored(r, some(new SessionLog(path)));
    assert(resumed.completedBytes <= cap && resumed.completedInputs.length < 30);
    assert("bulk-999" in resumed.completedInputs && "bulk-0" !in resumed.completedInputs);
    assert(resumed.run("q", new NullEvents, true, "bulk-0") == "r".replicate(200) ~ "0");
    assert(resumed.run("q", new NullEvents, true, "in-b") == big("b"));
    // The eviction record does not grow with the number of evicted turns.
    assert(resumed.completedEvicted.byteSize <= 32 * 1024);

    // Restoring thousands of pinned requests keeps the stash bounded.
    Restored rp;
    rp.pinStash = [Message.user("the goal")];
    foreach (i; 0 .. 2_000) rp.pinStash ~= Message.user("request " ~ i.to!string ~ " " ~ "w ".replicate(200));
    auto pinned = agentFor(new MockClient([]));
    pinned.pinTrimFloor = 8_000;
    pinned.loadRestored(rp, Option!SessionLog.init);
    assert(pinned.pinStash.length < 1_000 && pinned.pinStash.length + pinned.pinGap.count == 2_001);
    assert(pinned.pinStash[0].content == "the goal");
}

// issue #312: empty responses still count against the cap, and a logless
// agent never evicts (no log could replay an evicted response).
unittest
{
    import std.array : replicate;
    auto dir = buildPath(tempDir, "nano-d-loop-completed-empty");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    LLMResponse[] script;
    foreach (i; 0 .. 200) script ~= LLMResponse("");
    auto agent = agentFor(new MockClient(script));
    agent.completedCap = 2_048;
    agent.log = some(new SessionLog(dir, "mock/m", "/w"));
    foreach (i; 0 .. 200) agent.run("go", new NullEvents, true, "id-" ~ i.to!string);
    assert(agent.completedBytes <= 2_048 && agent.completedInputs.length < 50);

    auto logless = agentFor(new MockClient([LLMResponse("x".replicate(3_000)), LLMResponse("y".replicate(3_000))]));
    logless.completedCap = 2_048;
    logless.run("go", new NullEvents, true, "a");
    logless.run("go", new NullEvents, true, "b");
    assert("a" in logless.completedInputs && "b" in logless.completedInputs);
    assert(logless.run("go", new NullEvents, true, "a") == "x".replicate(3_000));
}

// issue #312: the log read-back matches decoded fields, whatever the spacing
// or escaping of the record.
unittest
{
    import std.file : write, remove;
    import nano.session : findCompletedTurn;
    auto p = buildPath(tempDir, "nano-find-completed.jsonl");
    scope (exit) if (p.exists) remove(p);
    write(p, `{"type" : "turn_end", "data" : {"input_id" : "a\/b", "response":"r1"}}` ~ "\n"
        ~ `{"type":"turn_\u0065nd","data":{"input_id":"c/d","response":"r2","stop_reason":"max_tokens"}}` ~ "\n");
    assert(findCompletedTurn(p, "a/b").unwrap("spaced, escaped slash").response == "r1");
    auto t = findCompletedTurn(p, "c/d").unwrap("escaped type");
    assert(t.response == "r2" && t.stopReason == "max_tokens");
    assert(findCompletedTurn(p, "zz").isNone);
}

// issue #312: a surrogate-pair id written escaped is found by its decoded form.
unittest
{
    import std.file : write, remove;
    import nano.session : findCompletedTurn;
    auto p = buildPath(tempDir, "nano-find-completed-surrogate.jsonl");
    scope (exit) if (p.exists) remove(p);
    write(p, `{"type":"turn_end","data":{"input_id":"id-\ud83d\ude00","response":"r1"}}` ~ "\n");
    assert(findCompletedTurn(p, "id-\U0001F600").unwrap("surrogate pair").response == "r1");
    assert(findCompletedTurn(p, "id-\uFFFD\uFFFD").isNone);
}

// issue #312: an evicted id redelivered after the live log was removed or
// replaced is still found (the log is recovered before the lookup).
unittest
{
    import std.array : replicate;
    import std.file : remove, rename, write;
    foreach (replace; [false, true])
    {
        auto dir = buildPath(tempDir, "nano-d-loop-completed-gone-" ~ replace.to!string);
        if (dir.exists) rmdirRecurse(dir);
        scope (exit) if (dir.exists) rmdirRecurse(dir);
        auto agent = agentFor(new MockClient([LLMResponse("a".replicate(3_000)), LLMResponse("b".replicate(3_000))]));
        agent.completedCap = 4_096;
        auto l = new SessionLog(dir, "mock/m", "/w");
        l.warn = (string) {};
        agent.log = some(l);
        agent.run("go", new NullEvents, true, "in-a");
        agent.run("go", new NullEvents, true, "in-b");
        assert("in-a" !in agent.completedInputs);
        auto path = l.path;
        if (replace) { rename(path, path ~ ".old"); write(path, "{}\n"); }
        else remove(path);
        assert(agent.run("go", new NullEvents, true, "in-a") == "a".replicate(3_000));
    }
}
