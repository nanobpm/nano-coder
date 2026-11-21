/// The output budget against the context window: `max_tokens` shrinks so
/// prompt and output fit, and compaction runs early when they would not
/// (agent.rs tests).
module nano.agent_budget_test;
@safe:

import std.string : representation;

version (unittest):

import std.algorithm : startsWith;
import std.array : replicate;
import std.json : JSONValue, parseJSON;
import nano.agent;
import nano.llm;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.tools : ToolRegistry;
import ctx = nano.context;

/// An agent with a configured `window`, a 0.99 compaction threshold,
/// `max_tokens` 16,384 and a `big` tool whose result is `chars` characters.
private Agent budgeted(MockClient mock, size_t window, size_t chars)
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("big", "big", parseJSON(`{"type":"object"}`)),
        (JSONValue) => "word ".replicate(chars / 5));
    auto agent = new Agent(mock, reg, Policy.init, "system");
    agent.configuredWindow = window;
    agent.autoCompactThreshold = 0.99;
    agent.maxTokens = 16_384;
    return agent;
}

private LLMResponse bigCall(string id)
{
    return LLMResponse("", "", [ToolCall.fromRaw(id, "big", `{}`)]);
}

private bool isSummary(const MockClient m, size_t i)
{
    return m.seen[i][0].content.startsWith(ctx.summarySystemPrompt);
}

// rust: agent.rs::max_tokens_shrinks_so_prompt_and_output_fit_the_window
unittest
{
    enum window = 24_000;
    auto mock = new MockClient([bigCall("b1"), LLMResponse("done")]);
    auto agent = budgeted(mock, window, 40_000);
    agent.run("go", new NullEvents);
    auto tokens = agent.estimateContextTokens();
    assert(mock.seen.length == 2, "no compaction");
    assert(!isSummary(mock, 1));
    auto sent = mock.maxTokensSeen[1];
    assert(sent >= ctx.minOutputReserve && sent < 16_384, "lowered");
    // The prompt estimate here includes the final "done", a few tokens.
    assert(tokens + sent <= window);
}

// rust: agent.rs::max_tokens_is_sent_unchanged_when_the_window_has_room
unittest
{
    auto mock = new MockClient([bigCall("b1"), LLMResponse("done")]);
    auto agent = budgeted(mock, 200_000, 4_000);
    agent.run("go", new NullEvents);
    assert(mock.maxTokensSeen == [16_384, 16_384]);
    assert(!isSummary(mock, 0) && !isSummary(mock, 1));
}

// A small window nearly filled by one tool result leaves fewer than
// minOutputReserve tokens free. With auto-compaction off nothing opens room,
// so the request caps max_tokens to the real room instead of flooring it.
// rust: agent.rs::max_tokens_is_capped_to_the_room_when_compaction_is_disabled
unittest
{
    enum window = 12_000;
    auto mock = new MockClient([bigCall("b1"), LLMResponse("done")]);
    auto agent = budgeted(mock, window, 40_000);
    agent.autoCompact = false;
    agent.run("go", new NullEvents);
    auto tokens = agent.estimateContextTokens();
    assert(mock.seen.length == 2, "no compaction when disabled");
    auto sent = mock.maxTokensSeen[1];
    assert(sent >= 1, "request stays valid");
    assert(sent < ctx.minOutputReserve, "capped below the floor");
    assert(tokens + sent <= window);
}

// Two clipped tool results leave less than minOutputReserve free, though the
// prompt is far below the 0.99 threshold: compaction runs anyway.
// rust: agent.rs::compacts_below_the_threshold_when_output_would_not_fit
unittest
{
    enum window = 24_000;
    auto mock = new MockClient([bigCall("b1"), bigCall("b2"), LLMResponse("SUMMARY"), LLMResponse("done")]);
    auto agent = budgeted(mock, window, 40_000);
    assert(agent.run("go", new NullEvents) == "done");
    assert(mock.seen.length == 4, "call, call, summary, call");
    assert(isSummary(mock, 2), "the third request is the summary");
    assert(agent.compactions >= 1);
}

/// A prompt-only window as Copilot reports it (`max_prompt_tokens`), with the
/// combined prompt + output window when it is advertised (0: none).
private void promptOnly(Agent agent, size_t window, size_t total)
{
    agent.configuredWindow = 0;
    agent.capabilities.window = window;
    agent.capabilities.windowSource = "Copilot /models max_prompt_tokens";
    agent.capabilities.promptCap = true;
    agent.capabilities.totalWindow = total;
}

// Only `max_prompt_tokens` is advertised; an overflow taught a 110K total cap,
// above the prompt cap. That learned total is then the only prompt + output
// limit, so max_tokens is capped to the room left in it.
// rust: agent.rs::a_learned_window_is_the_combined_cap_when_no_total_is_advertised
unittest
{
    enum learned = 110_000;
    auto mock = new MockClient([LLMResponse("done")]);
    auto agent = budgeted(mock, 100_000, 0);
    promptOnly(agent, 100_000, 0);
    agent.learnedWindow = learned;
    // ~96K tokens: under the prompt cap, within the reserve of the learned window.
    agent.run("w".replicate(384_000), new NullEvents);
    auto tokens = agent.estimateContextTokens();
    assert(mock.seen.length == 1, "no compaction");
    auto sent = mock.maxTokensSeen[0];
    assert(sent < 16_384, "capped to the learned combined window's room");
    assert(tokens + sent <= learned);
}

// A learned 110K total, below the advertised 128K combined window, is the
// effective combined limit.
// rust: agent.rs::a_learned_window_tightens_the_effective_combined_window
unittest
{
    enum learned = 110_000;
    auto mock = new MockClient([LLMResponse("done")]);
    auto agent = budgeted(mock, 100_000, 0);
    promptOnly(agent, 100_000, 128_000);
    agent.learnedWindow = learned;
    agent.run("w".replicate(384_000), new NullEvents);
    auto tokens = agent.estimateContextTokens();
    assert(mock.seen.length == 1, "no compaction");
    auto sent = mock.maxTokensSeen[0];
    assert(sent < 16_384, "capped to the learned combined window's room");
    assert(tokens + sent <= learned);
}

// A learned window below the prompt-only one is a total cap, so the output
// reservation counts again.
// rust: agent.rs::a_lower_learned_window_restores_the_output_reservation
unittest
{
    enum learned = 16_000;
    auto mock = new MockClient([bigCall("b1"), LLMResponse("done")]);
    auto agent = budgeted(mock, 24_000, 36_000);
    promptOnly(agent, 24_000, 0);
    agent.learnedWindow = learned;
    agent.run("go", new NullEvents);
    auto tokens = agent.estimateContextTokens();
    assert(mock.seen.length == 2, "no compaction");
    auto sent = mock.maxTokensSeen[1];
    assert(sent < 16_384, "capped to the learned window's room");
    assert(tokens + sent <= learned);
}

// The prompt cap doesn't consume output tokens, but the advertised combined
// window still bounds the whole request.
// rust: agent.rs::a_prompt_only_window_is_capped_to_the_combined_window
unittest
{
    enum combined = 110_000;
    auto mock = new MockClient([LLMResponse("done")]);
    auto agent = budgeted(mock, 100_000, 0);
    promptOnly(agent, 100_000, combined);
    agent.run("w".replicate(384_000), new NullEvents);
    auto tokens = agent.estimateContextTokens();
    assert(mock.seen.length == 1, "no tool call, no compaction");
    auto sent = mock.maxTokensSeen[0];
    assert(sent < 16_384, "capped to the combined window's room");
    assert(tokens + sent <= combined);
}

// No output reservation comes out of a prompt-only cap, but the estimation
// margin does: a prompt between the margin-protected limit (98K) and the raw
// 0.99 threshold (99K) compacts.
// rust: agent.rs::a_prompt_only_window_keeps_the_estimation_margin
unittest
{
    auto mock = new MockClient([LLMResponse("SUMMARY"), LLMResponse("done")]);
    auto agent = budgeted(mock, 100_000, 0);
    promptOnly(agent, 100_000, 0);
    agent.push(Message.user("q"));
    agent.push(Message.assistant("a".replicate(392_000)));
    assert(agent.run("go", new NullEvents) == "done");
    assert(mock.seen.length == 2, "summary, then the real call");
    assert(isSummary(mock, 0), "the first request is the compaction summary");
    assert(agent.compactions >= 1);
}

// A 102K combined window over a 100K prompt cap: a ~97.7K prompt is under
// the prompt threshold but leaves less than the output reserve, so the
// reservation against the combined window triggers compaction.
// rust: agent.rs::prompt_only_window_compacts_against_the_combined_window
unittest
{
    auto mock = new MockClient([LLMResponse("SUMMARY"), LLMResponse("done")]);
    auto agent = budgeted(mock, 100_000, 0);
    promptOnly(agent, 100_000, 102_000);
    agent.push(Message.user("q"));
    agent.push(Message.assistant("a".replicate(388_000)));
    assert(agent.run("go", new NullEvents) == "done");
    assert(mock.seen.length == 2, "summary, then the real call");
    assert(isSummary(mock, 0), "the first request is the compaction summary");
    assert(agent.compactions >= 1);
}

private class Reports : MockClient, CapabilityProbe
{
    this() { super(null); }
    Capabilities probeCapabilities()
    {
        Capabilities c;
        c.window = 65_536;
        c.windowSource = "test";
        return c;
    }
    override string modelName() pure const { return "claude-test"; }
}

// The window's sources in order: config, then what the endpoint reports,
// then the model name. (D probes even when config sets the window; skipping
// that probe is part of the background-probe gap.)
// rust: agent.rs::detected_window_sits_between_config_and_model_name
unittest
{
    auto agent = new Agent(new Reports, new ToolRegistry, Policy.init, null);
    string source;
    agent.contextWindow(source);
    assert(source == "known for the model name");
    agent.refreshCapabilities();
    assert(agent.contextWindow(source) == 65_536 && source == "reported by the endpoint (test)");
    agent.setConfiguredWindow(ConfiguredWindow(32_000, "context_window in config"));
    agent.refreshCapabilities();
    assert(agent.contextWindow(source) == 32_000 && source == "context_window in config");
    agent.setConfiguredWindow(ConfiguredWindow(48_000, "provider context_window"));
    assert(agent.contextWindow(source) == 48_000 && source == "provider context_window");
}

// rust: agent.rs::estimate_is_anchored_to_reported_usage
unittest
{
    LLMResponse hi = LLMResponse("hi");
    hi.usage.inputTokens = 1_000;
    hi.usage.outputTokens = 50;
    auto agent = new Agent(new MockClient([hi]), new ToolRegistry, Policy.init, "system");
    bool calibrated;
    assert(agent.estimateContextTokens(calibrated) > 0 && !calibrated);
    agent.run("go", new NullEvents);
    assert(agent.estimateContextTokens(calibrated) == 1_050 && calibrated);
    agent.push(Message.user("abcdefgh"));
    assert(agent.estimateContextTokens(calibrated) == 1_050 + 2 + 4 && calibrated);
    assert(agent.sessionInputTokens == 1_000);
}

// A newer image after the usage anchor displaces the anchored one into a
// placeholder (one image slot), so the anchor's full-image charge is stale and
// the estimate recomputes the conversation as the wire plan sends it.
// rust: agent.rs::calibrated_estimate_recomputes_when_a_suffix_image_displaces_a_prefix_image
unittest
{
    import nano.attachment : Attachment, sha256Hex, store;
    import nano.vision : Vision;
    LLMResponse ok = LLMResponse("ok");
    ok.usage.inputTokens = 5_000;
    auto agent = new Agent(new MockClient([ok]), new ToolRegistry, Policy.init, "system");
    agent.capabilities.vision = Vision(1);
    auto bytes = "calib-displace-image".representation;
    auto img = Attachment("image/png", "x.png", sha256Hex(bytes), 1000, 1000, bytes.length, "png");
    store(agent.attachmentsDir, img, bytes);
    auto look = Message.user("look");
    look.attachments = [img];
    agent.push(look);
    agent.run("go", new NullEvents);
    bool calibrated;
    assert(agent.estimateContextTokens(calibrated) == 5_000 && calibrated, "no suffix image: the anchor stands");
    auto again = Message.user("again");
    again.attachments = [img];
    agent.push(again);
    auto tokens = agent.estimateContextTokens(calibrated);
    assert(!calibrated, "a displaced prefix image invalidates the anchor");
    size_t tools_;
    foreach (d; agent.offeredTools())
        tools_ += ctx.textTokens(d.name) + ctx.textTokens(d.description) + ctx.textTokens(() { return d.parameters.toString; }());
    const(bool[])[] avail;
    foreach (ref m; agent.messages) { bool[] row; foreach (_; m.attachments) row ~= true; avail ~= row; }
    assert(tokens == ctx.messagesTokens(agent.messages, 1, avail) + tools_, "recomputes as the wire plan sends it");
    auto stale = 5_000 + ctx.messagesTokens(agent.messages[$ - 1 .. $], 1, avail[$ - 1 .. $]);
    assert(tokens < stale, "no double charge");
}

// How a probed window merges with the other sources. D derives the window on
// demand, so the "stats" follow automatically.
// rust: agent.rs::a_background_probe_refines_a_default_window_source
// rust: agent.rs::a_looser_probe_does_not_replace_a_learned_window_stat
// rust: agent.rs::a_stricter_probe_replaces_a_learned_window_stat
// rust: agent.rs::an_equal_probe_replaces_a_learned_window_stat_source
unittest
{
    import std.algorithm : startsWith;
    auto mock = new MockClient(null);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, null);
    string source;
    agent.contextWindow(source);
    // A probe refines a default (or model-name) window.
    agent.capabilities.window = 8_192;
    agent.capabilities.windowSource = "max_model_len";
    assert(agent.contextWindow(source) == 8_192 && source.startsWith("reported by the endpoint"), source);
    // A learned window is binding against a looser probe...
    agent.learnedWindow = 100_000;
    agent.capabilities.window = 200_000;
    assert(agent.contextWindow(source) == 100_000 && source == "learned from a context-overflow error", source);
    // ...a stricter one replaces it...
    agent.learnedWindow = 200_000;
    agent.capabilities.window = 128_000;
    assert(agent.contextWindow(source) == 128_000 && source.startsWith("reported by the endpoint"), source);
    // ...and an equal one relabels the source as the endpoint's.
    agent.learnedWindow = 128_000;
    assert(agent.contextWindow(source) == 128_000 && source.startsWith("reported by the endpoint"), source);
}

// rust: agent.rs::a_configured_window_preserves_the_probed_output_limit
unittest
{
    auto agent = new Agent(new MockClient(null), new ToolRegistry, Policy.init, null);
    agent.setConfiguredWindow(ConfiguredWindow(200_000, "context_window in config"));
    agent.capabilities.maxOutput = 16_000;
    string source;
    assert(agent.contextWindow(source) == 200_000 && source == "context_window in config");
    assert(agent.effectiveMaxTokens == 16_000, "the endpoint's output limit stands beside a configured window");
}
