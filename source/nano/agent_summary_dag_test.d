/// Layered compaction (issue #274): summary nodes, condensation and
/// expanding a node with history_read.
module nano.agent_summary_dag_test;
@safe:

version (unittest):

import std.algorithm : any, canFind, count, startsWith;
import std.conv : to;
import std.file : exists, readText, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.string : lineSplitter;
import nano.agent;
import nano.llm;
import nano.option : some, unwrap;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;
import ctx = nano.context;
import dag = nano.summary_dag;
import hist = nano.session_history;

private:

Agent logged(string name, MockClient mock)
{
    auto dir = buildPath(tempDir, "nano-d-summary-dag-" ~ name);
    if (dir.exists) rmdirRecurse(dir);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    agent.compactionSummaryDag = true;
    return agent;
}

bool compactAs(Agent agent, ctx.CompactionMode mode)
{
    CompactReport report;
    return agent.compact(report, CompactTrigger.manual, &mode);
}

JSONValue[] replaces(Agent agent)
{
    JSONValue[] rs;
    foreach (line; readText(agent.log.unwrap("logged").path).lineSplitter)
    {
        auto r = parseJSON(line);
        if (r["type"].str == "replace") rs ~= r;
    }
    return rs;
}

// Extract mode: every compaction adds a level-0 node, the old nodes are
// carried forward verbatim, and condensation is deterministic (no calls).
unittest
{
    LLMResponse[] replies;
    foreach (i; 0 .. 10) replies ~= LLMResponse("answer " ~ i.to!string);
    auto mock = new MockClient(replies);
    auto agent = logged("extract", mock);
    agent.summaryDagBudgetBytes = 200;
    foreach (i; 0 .. 10)
    {
        agent.run("step " ~ i.to!string ~ " detail-" ~ i.to!string, new NullEvents);
        assert(compactAs(agent, ctx.CompactionMode.extract));
    }
    assert(mock.seen.length == 10, "extract compaction and its condensation make no model call");
    auto summary = agent.messages[1].content;
    assert(summary.startsWith(ctx.smartSummaryPrefix), summary);
    assert(summary.canFind(dag.expandNote));
    auto live = dag.parse(summary);
    assert(live.length >= 2 && live.length < 10, live.length.to!string);
    assert(live.any!(n => n.level >= 1), "older nodes were condensed");
    // Every compaction persists its new nodes: one leaf, at most one condensed.
    auto rs = replaces(agent);
    assert(rs.length == 10);
    foreach (r; rs)
    {
        auto ns = r["data"]["summary_nodes"].arrayNoRef;
        assert(ns.length == 1 || ns.length == 2);
        assert(ns[0]["level"].integer == 0);
        assert("summarized" in r["data"], "the flat range is still recorded");
    }

    // history_read expands the oldest live node down to the first span.
    auto path = agent.log.unwrap("logged").path;
    auto top = live[0];
    assert(top.level >= 1);
    auto text = hist.read(path, parseJSON(`{"node":"` ~ dag.nodeName(top.id) ~ `"}`));
    assert(text.canFind("It condensed"), text);
    uint leaf = top.id;
    for (;;)
    {
        auto got = hist.read(path, parseJSON(`{"node":"` ~ dag.nodeName(leaf) ~ `"}`));
        auto ns = dag.parse(got);
        if (ns[0].level == 0)
        {
            assert(got.canFind("Original messages"), got);
            assert(got.canFind("detail-0"), "the first span's detail is reachable: " ~ got);
            break;
        }
        leaf = ns[0].children[0];
    }
    // The node name works as the id too, and search filters by a node's range.
    assert(hist.read(path, parseJSON(`{"id":"S1"}`)).canFind("detail-0"));
    auto found = hist.search(path, parseJSON(`{"pattern":"detail-","node":"S1"}`));
    assert(found.canFind("detail-0") && !found.canFind("detail-1 "), found);
    import std.exception : assertThrown;
    assertThrown!(hist.HistoryError)(hist.read(path, parseJSON(`{"node":"S999"}`)));
}

// Model mode: at most one condensation call per compaction, and only the new
// span (not the previous summary) goes to the summarizer.
unittest
{
    LLMResponse[] replies;
    foreach (i; 0 .. 8)
    {
        replies ~= LLMResponse("answer " ~ i.to!string);
        replies ~= LLMResponse("SUMMARY " ~ i.to!string ~ ": " ~ "x".to!string ~ "work done in this span with many words");
        // Spare replies for a condensation call; an unused one is the next
        // turn's answer, which the test does not check.
        replies ~= LLMResponse("CONDENSED " ~ i.to!string);
    }
    auto mock = new MockClient(replies);
    auto agent = logged("smart", mock);
    agent.summaryDagBudgetBytes = 100;
    foreach (i; 0 .. 5)
    {
        auto before = mock.seen.length;
        agent.run("step " ~ i.to!string, new NullEvents);
        assert(compactAs(agent, ctx.CompactionMode.smart));
        size_t condensations, summaries;
        foreach (req; mock.seen[before .. $])
        {
            if (req[0].content == dag.condenseSystemPrompt) ++condensations;
            if (req[0].content.startsWith(ctx.summarySystemPrompt))
            {
                ++summaries;
                assert(!req[1].content.canFind("[[node "), "the previous summary is not re-summarized");
            }
        }
        assert(summaries == 1 && condensations <= 1, i.to!string ~ ":" ~ summaries.to!string ~ "/" ~ condensations.to!string ~ "/" ~ (mock.seen.length - before).to!string);
    }
    assert(dag.parse(agent.messages[1].content).any!(n => n.level >= 1));
}

// Off by default: a smart summary stays flat.
unittest
{
    auto mock = new MockClient([LLMResponse("a"), LLMResponse("SUMMARY")]);
    auto agent = logged("off", mock);
    agent.compactionSummaryDag = false;
    agent.run("ping", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    assert(!agent.messages[1].content.canFind("[[node "));
    assert(("summary_nodes" in replaces(agent)[0]["data"].objectNoRef) is null);
}

// Flat, then layered: the flat summary's content goes to the summarizer
// instead of being dropped (and the leaf's range covers it), and node IDs
// stay unique across a flat reset, so each reads back its own node.
unittest
{
    auto mock = new MockClient([LLMResponse("a0"), LLMResponse("FLATSUM"), LLMResponse("a1"), LLMResponse("LEAF1"),
        LLMResponse("a2"), LLMResponse("FLAT2"), LLMResponse("a3"), LLMResponse("fresh-marker")]);
    auto agent = logged("flat-then-layered", mock);
    agent.compactionSummaryDag = false;
    agent.run("first", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    assert(!agent.messages[1].content.canFind("[[node "));
    agent.compactionSummaryDag = true;
    agent.run("second", new NullEvents);
    auto before = mock.seen.length;
    assert(compactAs(agent, ctx.CompactionMode.smart));
    assert(mock.seen[before][1].content.canFind("FLATSUM"), "the flat summary is summarized, not dropped");
    auto first = dag.parse(agent.messages[1].content);
    assert(first.length == 1 && first[0].first == 1, "the leaf covers the folded flat summary's history");
    // Reset the node list with a flat compaction, then layer again.
    agent.compactionSummaryDag = false;
    agent.run("third", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    agent.compactionSummaryDag = true;
    agent.run("fourth", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    auto live = dag.parse(agent.messages[1].content);
    assert(live.length == 1 && live[0].id == 2, "a new ID after the reset");
    auto path = agent.log.unwrap("logged").path;
    auto got = hist.read(path, parseJSON(`{"node":"S2"}`));
    assert(got.canFind("fresh-marker") && !got.canFind("LEAF1"), got);
    assert(hist.read(path, parseJSON(`{"node":"S1"}`)).canFind("LEAF1"), "the archived node is intact");
}

// Resume between a flat reset and the next layered compaction: the new
// agent seeds its ID high-water mark from the log, so S1 is not reissued.
unittest
{
    auto mock = new MockClient([LLMResponse("a1"), LLMResponse("LEAF1"), LLMResponse("a2"), LLMResponse("FLAT2"),
        LLMResponse("a3"), LLMResponse("fresh-marker")]);
    auto agent = logged("resume-high", mock);
    agent.run("first", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    agent.compactionSummaryDag = false;
    agent.run("second", new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    // "Resume": a fresh agent over the same log and messages.
    auto resumed = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    resumed.messages = agent.messages.dup;
    resumed.log = agent.log;
    resumed.compactionSummaryDag = true;
    resumed.run("third", new NullEvents);
    assert(compactAs(resumed, ctx.CompactionMode.smart));
    auto live = dag.parse(resumed.messages[1].content);
    assert(live.length == 1 && live[0].id == 2, "a new ID after resume");
    auto path = resumed.log.unwrap("logged").path;
    assert(hist.read(path, parseJSON(`{"node":"S1"}`)).canFind("LEAF1"), "the archived node is intact");
    assert(hist.read(path, parseJSON(`{"node":"S2"}`)).canFind("fresh-marker"));
}

// Switching sessions on the same Agent (`loadRestored` → `replaceLog`): the
// ID high-water mark seeded from session A must not carry over to session B,
// whose archived nodes reach higher, or B's IDs would be reissued.
unittest
{
    auto mockB = new MockClient([LLMResponse("b1"), LLMResponse("B-LEAF1"), LLMResponse("b2"), LLMResponse("B-LEAF2"),
        LLMResponse("b3"), LLMResponse("B-FLAT")]);
    auto b = logged("switch-b", mockB);
    b.run("one", new NullEvents);
    assert(compactAs(b, ctx.CompactionMode.smart));
    b.run("two", new NullEvents);
    assert(compactAs(b, ctx.CompactionMode.smart));
    b.compactionSummaryDag = false;
    b.run("three", new NullEvents);
    assert(compactAs(b, ctx.CompactionMode.smart));

    auto mockA = new MockClient([LLMResponse("a1"), LLMResponse("A-LEAF1"), LLMResponse("a2"),
        LLMResponse("switched-marker")]);
    auto a = logged("switch-a", mockA);
    a.run("first", new NullEvents);
    assert(compactAs(a, ctx.CompactionMode.smart));
    // Adopt session B on the same Agent.
    auto bPath = b.log.unwrap("logged").path;
    a.messages = b.messages.dup;
    a.replaceLog(some(new SessionLog(bPath)));
    a.run("second", new NullEvents);
    assert(compactAs(a, ctx.CompactionMode.smart));
    auto live = dag.parse(a.messages[1].content);
    assert(live.length == 1 && live[0].id == 3, "B's archived S1/S2 are not reissued");
    assert(hist.read(bPath, parseJSON(`{"node":"S2"}`)).canFind("B-LEAF2"));
    assert(hist.read(bPath, parseJSON(`{"node":"S3"}`)).canFind("switched-marker"));
}

// Expanding a leaf over a long range stops collecting digests at the output
// limit instead of building the whole listing first.
unittest
{
    LLMResponse[] replies;
    foreach (i; 0 .. 40) replies ~= LLMResponse("reply-" ~ i.to!string);
    replies ~= LLMResponse("BIGLEAF");
    auto agent = logged("expand-bounded", new MockClient(replies));
    foreach (i; 0 .. 40) agent.run("question number " ~ i.to!string, new NullEvents);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    auto path = agent.log.unwrap("logged").path;
    auto full = hist.read(path, parseJSON(`{"node":"S1","max_output_length":100000}`));
    assert(full.canFind("question number 39") && !full.canFind("more log lines"), full);
    auto small = hist.read(path, parseJSON(`{"node":"S1","max_output_length":300}`));
    assert(!small.canFind("question number 39"), small);
}

// A truncated condensation (stop reason length / max_tokens) is not persisted
// as an incomplete prefix: the deterministic text is used instead.
unittest
{
    foreach (stop; ["length", "max_tokens"])
    {
        LLMResponse[] replies;
        foreach (i; 0 .. 8)
        {
            replies ~= LLMResponse("answer " ~ i.to!string);
            replies ~= LLMResponse("SUMMARY " ~ i.to!string ~ ": work done in this span with many words");
            auto cut = LLMResponse("TRUNCATED-PREFIX");
            cut.stopReason = stop;
            replies ~= cut;
        }
        auto mock = new MockClient(replies);
        auto agent = logged("truncated-" ~ stop, mock);
        agent.summaryDagBudgetBytes = 100;
        size_t condensations;
        foreach (i; 0 .. 5)
        {
            auto before = mock.seen.length;
            agent.run("step " ~ i.to!string, new NullEvents);
            assert(compactAs(agent, ctx.CompactionMode.smart));
            foreach (req; mock.seen[before .. $])
                if (req[0].content == dag.condenseSystemPrompt) ++condensations;
        }
        assert(condensations >= 1, "a condensation call was made");
        foreach (r; replaces(agent))
            foreach (n; r["data"]["summary_nodes"].arrayNoRef)
                assert(!n.toString.canFind("TRUNCATED-PREFIX"), n.toString);
    }
}

// A log deleted before the first layered compaction is recovered (revalidated)
// before its node IDs are scanned, rather than throwing.
unittest
{
    import std.file : remove;
    auto mock = new MockClient([LLMResponse("a"), LLMResponse("SUMMARY")]);
    auto agent = logged("revalidate", mock);
    agent.run("ping", new NullEvents);
    remove(agent.log.unwrap("logged").path);
    assert(compactAs(agent, ctx.CompactionMode.smart));
    assert(dag.parse(agent.messages[1].content).length == 1);
}

// The condensation call counts its retried stream attempts, whether it
// succeeds or fails into the deterministic fallback (issue #340).
unittest
{
    import nano.http : RequestException;
    foreach (fail; [false, true])
    {
        LLMResponse[] replies;
        foreach (i; 0 .. 8)
        {
            replies ~= LLMResponse("answer " ~ i.to!string);
            replies ~= LLMResponse("SUMMARY " ~ i.to!string ~ ": work done in this span with many words");
            replies ~= LLMResponse("CONDENSED " ~ i.to!string);
        }
        size_t condensations;
        auto mock = new class MockClient
        {
            this() { super(replies); }
            override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
            {
                auto r = super.chat(req, sink);
                if (req.messages[0].content != dag.condenseSystemPrompt) return r;
                ++condensations;
                if (fail)
                {
                    auto e = new RequestException("condense: network unavailable");
                    e.retried = RetrySpend(TokenUsage(0, 0), 3);
                    throw e;
                }
                r.retried = RetrySpend(TokenUsage(0, 0), 3);
                return r;
            }
        };
        auto agent = logged(fail ? "condense-retried-fail" : "condense-retried", mock);
        agent.summaryDagBudgetBytes = 100;
        foreach (i; 0 .. 5)
        {
            agent.run("step " ~ i.to!string, new NullEvents);
            assert(compactAs(agent, ctx.CompactionMode.smart));
        }
        assert(condensations >= 1, "a condensation call was made");
        assert(agent.uncountedRequests == 3 * condensations, agent.uncountedRequests.to!string);
    }
}

// An aborted condensation attempt (a cancel exception or a dropped stream)
// counts its reported usage, or one uncounted request when it reported none,
// on top of its retried attempts (issue #340).
unittest
{
    import nano.control : Cancelled;
    import nano.http : StreamInterrupted;
    foreach (kind; 0 .. 4)
    {
        immutable withUsage = kind >= 2;
        LLMResponse[] replies;
        foreach (i; 0 .. 8)
        {
            replies ~= LLMResponse("answer " ~ i.to!string);
            replies ~= LLMResponse("SUMMARY " ~ i.to!string ~ ": work done in this span with many words");
            replies ~= LLMResponse("CONDENSED " ~ i.to!string);
        }
        size_t condensations;
        auto mock = new class MockClient
        {
            this() { super(replies); }
            override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
            {
                auto r = super.chat(req, sink);
                if (req.messages[0].content != dag.condenseSystemPrompt) return r;
                ++condensations;
                immutable u = withUsage ? TokenUsage(7, 0) : TokenUsage(0, 0);
                if (kind % 2 == 0)
                {
                    auto e = new Cancelled;
                    e.usage = u;
                    e.retried = RetrySpend(TokenUsage(0, 0), 2);
                    throw e;
                }
                auto e = new StreamInterrupted("condense: stream dropped");
                e.usage = u;
                e.retried = RetrySpend(TokenUsage(0, 0), 2);
                throw e;
            }
        };
        auto agent = logged("condense-aborted-" ~ kind.to!string, mock);
        agent.summaryDagBudgetBytes = 100;
        foreach (i; 0 .. 5)
        {
            agent.run("step " ~ i.to!string, new NullEvents);
            assert(compactAs(agent, ctx.CompactionMode.smart));
        }
        assert(condensations >= 1, "a condensation call was made");
        immutable perCall = withUsage ? 2 : 3;
        assert(agent.uncountedRequests == perCall * condensations, agent.uncountedRequests.to!string);
        if (withUsage) assert(agent.sessionInputTokens >= 7 * condensations, agent.sessionInputTokens.to!string);
    }
}
