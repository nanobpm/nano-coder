/// Compaction and the output cap: summary retries after a cap rejection,
/// cut-off and empty summaries, cancel and streaming (agent.rs tests).
module nano.agent_compaction_test;
@safe:

version (unittest):

import std.algorithm : canFind, count, startsWith;
import std.json : JSONValue, parseJSON;
import nano.agent;
import nano.llm;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.tools : ToolRegistry;
import ctx = nano.context;

private:

bool isSummaryRequest(const ref ChatRequest req)
{
    return req.messages.length && req.messages[0].content.startsWith(ctx.summarySystemPrompt);
}

/// Rejects a request whose `max_tokens` is over `cap` (only summary requests
/// with `summaryOnly`), with or without the limit in the message, and
/// answers `reply` otherwise.
class CapClient : LLMClient
{
    long cap;
    bool numberless, summaryOnly, recordSummaryOnly;
    string reply;
    long[] seen;
    void delegate() @safe onReject;

    this(long cap, string reply) { this.cap = cap; this.reply = reply; }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto summary = isSummaryRequest(req);
        if (!recordSummaryOnly || summary) seen ~= req.maxTokens;
        if (req.maxTokens > cap && (!summaryOnly || summary))
        {
            if (onReject !is null) onReject();
            import std.format : format;
            throw new Exception(numberless ? "max_tokens is too large for this model"
                : format("max_tokens: %s > %s, which is the maximum allowed number of output tokens", req.maxTokens, cap));
        }
        return LLMResponse(summary ? "SUMMARY: compacted" : reply);
    }

    string[] listModels() { return ["cap"]; }
    string modelName() pure const { return "cap"; }
    string providerName() pure const { return "cap"; }
}

Agent agentFor(LLMClient c)
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) => "echo");
    return new Agent(c, reg, Policy.init, "system");
}

LLMResponse toolCall(string id)
{
    return LLMResponse("", "", [ToolCall.fromRaw(id, "echo", `{}`)]);
}

// A chat request clamped by the window below the 32,768 base is rejected with
// no number in the error: the retry halves what was sent, not the base.
// rust: agent.rs::a_chat_output_cap_fallback_halves_the_sent_budget
unittest
{
    auto c = new CapClient(0, "recovered");
    c.numberless = true;
    auto agent = agentFor(c);
    agent.maxTokens = 32_768;
    agent.configuredWindow = 16_000;
    // Reject only the first request.
    c.cap = 1;
    c.onReject = () { c.cap = long.max; };
    assert(agent.run("ping", new NullEvents) == "recovered");
    assert(c.seen.length == 2, "an over-cap request, then the halved retry");
    assert(c.seen[0] <= 16_384, "clamped below the base's half");
    assert(c.seen[1] == c.seen[0] / 2, "the retry halves the sent budget");
}

// rust: agent.rs::a_compaction_summary_cap_fallback_halves_the_sent_budget
unittest
{
    auto c = new CapClient(7_000, "pong");
    c.numberless = c.summaryOnly = c.recordSummaryOnly = true;
    auto agent = agentFor(c);
    agent.run("ping", new NullEvents);
    CompactReport report;
    assert(agent.compact(report));
    assert(report.fallback is null, "the summary succeeded on the halved retry");
    assert(c.seen.length >= 2);
    assert(c.seen[0] == 12_288, "the first summary sent the full budget");
    assert(c.seen[1] == 6_144, "the retry halved the sent budget");
}

// rust: agent.rs::a_compaction_summary_is_retried_after_learning_the_output_cap
unittest
{
    auto c = new CapClient(8_000, "pong");
    c.summaryOnly = true;
    auto agent = agentFor(c);
    agent.run("ping", new NullEvents);
    CompactReport report;
    assert(agent.compact(report));
    assert(report.fallback is null, "retried, not the dropped-history fallback");
    assert(c.seen.count!(m => m > 8_000) >= 1, "the over-cap summary was tried first");
    assert(c.seen[$ - 1] <= 8_000, "the retry is within the learned cap");
}

// A probe publishing a larger window (or max output) between the summary's
// output-cap rejection and its retry must not raise the retry above the
// learned cap: the retry would be rejected again and history dropped.
unittest
{
    foreach (bumpWindow; [true, false])
    {
        auto c = new CapClient(8_000, "pong");
        c.summaryOnly = c.recordSummaryOnly = true;
        auto agent = agentFor(c);
        agent.run("ping", new NullEvents);
        c.onReject = () {
            if (bumpWindow) agent.configuredWindow = 1_000_000;
            else agent.capabilities.maxOutput = 64_000;
        };
        CompactReport report;
        assert(agent.compact(report));
        assert(report.fallback is null, "retried within the learned cap, not dropped");
        assert(c.seen.length == 2);
        assert(c.seen[1] <= 8_000, "the probe did not raise the retry");
    }
}

// The cap is learned (here: published) between sending and handling the
// rejection; the retry still compares against what was sent.
// rust: agent.rs::an_output_limit_rejection_is_retried_against_the_sent_budget
unittest
{
    auto c = new CapClient(8_000, "recovered");
    auto agent = agentFor(c);
    c.onReject = () { agent.capabilities.maxOutput = 8_000; };
    assert(agent.run("go", new NullEvents) == "recovered");
    assert(agent.lastStop == StopReason.endTurn);
    assert(c.seen.length == 2, "one rejected attempt, one retry");
    assert(c.seen[0] > 8_000 && c.seen[1] <= 8_000);
}

// rust: agent.rs::a_summary_cut_off_at_the_output_limit_is_flagged
unittest
{
    auto cut = LLMResponse("SUMMARY: step 1 half do");
    cut.stopReason = "length";
    auto agent = agentFor(new MockClient([toolCall("c1"), LLMResponse("done"), cut]));
    agent.run("ping", new NullEvents);
    CompactReport report;
    assert(agent.compact(report));
    assert(report.fallback is null && report.truncated);
    assert(report.toString.canFind("hit the output limit"));
    auto summary = agent.messages[1].content;
    import std.string : strip;
    assert(summary.canFind("SUMMARY: step 1 half do") && summary.canFind(ctx.summaryTruncatedNote.strip));
}

// rust: agent.rs::an_empty_summary_at_the_output_limit_names_the_cause
unittest
{
    auto empty = LLMResponse("");
    empty.stopReason = "length";
    auto agent = agentFor(new MockClient([toolCall("c1"), LLMResponse("done"), empty]));
    agent.run("ping", new NullEvents);
    CompactReport report;
    assert(agent.compact(report));
    assert(report.fallback.canFind("output limit"));
}

// A cancel pending when compaction would summarize stops before the call.
// rust: agent.rs::cancelled_compaction_does_not_issue_the_summary_call
unittest
{
    auto mock = new MockClient([toolCall("c1"), LLMResponse("done")]);
    auto agent = agentFor(mock);
    agent.run("ping", new NullEvents);
    agent.control.cancel();
    CompactReport report;
    assert(!agent.compact(report), "a cancelled compaction summarizes nothing");
    assert(mock.seen.length == 2, "no summary call");
}

/// Streams the summary (a sink is passed) and counts it; a summary request
/// without a sink fails like a dropped idle connection.
class StreamOnlySummary : LLMClient
{
    int streamed;
    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        if (!isSummaryRequest(req)) return LLMResponse("ok");
        if (sink is null) throw new Exception("error sending request: idle connection dropped");
        streamed++;
        sink(false, "streamed");
        return LLMResponse("SUMMARY: streamed");
    }
    string[] listModels() { return ["s"]; }
    string modelName() pure const { return "s"; }
    string providerName() pure const { return "s"; }
}

// rust: agent.rs::compaction_streams_the_summary_request
unittest
{
    auto c = new StreamOnlySummary;
    auto agent = agentFor(c);
    agent.run("one", new NullEvents);
    agent.run("two", new NullEvents);
    CompactReport report;
    assert(agent.compact(report));
    assert(report.fallback is null, "no fallback to dropping messages");
    assert(c.streamed == 1);
    auto s = agent.messages[1].content;
    assert(s.canFind("SUMMARY: streamed") && s.canFind(ctx.pinnedRequestsPrefix) && s.canFind("one") && s.canFind("two"));
}
