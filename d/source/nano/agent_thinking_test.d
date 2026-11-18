/// Thinking levels against temperature and the output cap (agent.rs tests):
/// what each request sends, and what the session log records about it.
module nano.agent_thinking_test;
@safe:

version (unittest):

import std.algorithm : canFind, filter, map;
import std.array : array, replicate;
import std.json : JSONValue, parseJSON;
import std.math : isNaN;
import std.typecons : Nullable;
import nano.agent;
import nano.config : ProviderConfig, ProviderKind;
import nano.llm;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.thinking : Request, Source, Thinking;
import nano.tools : ToolRegistry;

private:

/// What one request sent: its temperature (NaN: none) and thinking.
struct Sent { double temperature; Request thinking; long maxTokens; }

/// A scripted Anthropic model that records what each request sent.
class Claude : MockClient
{
    string model;
    Sent[] sent;
    this(string model, LLMResponse[] script) { super(script); this.model = model; }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        sent ~= Sent(req.temperature, req.thinking, req.maxTokens);
        return super.chat(req, sink);
    }
    override string modelName() const { return model; }
    override string providerName() const { return "anthropic"; }
}

Agent agentFor(LLMClient c, void delegate(Agent) @safe tool = null)
{
    auto reg = new ToolRegistry;
    Agent agent;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)), (JSONValue a) {
        if (tool !is null) tool(agent);
        return "pong";
    });
    agent = new Agent(c, reg, Policy.init, "system");
    auto anthropic = new ProviderConfig;
    anthropic.hasKind = true;
    anthropic.kind = ProviderKind.anthropic;
    agent.providerLookup = (string name) => cast(const(ProviderConfig)*) anthropic;
    return agent;
}

LLMResponse toolCall(string id) { return LLMResponse("", "", [ToolCall.fromRaw(id, "echo", `{}`)]); }

Request effort(string l) { Request r; r.kind = Request.Kind.effort; r.level = l; return r; }

Nullable!Thinking session(string l) { return Nullable!Thinking(Thinking.parse(l)); }

string[] loggedLevels(Agent agent)
{
    return agent.messages.filter!(m => m.role == Role.assistant).map!(m => m.thinkingLevel).array;
}

// A level set mid-turn applies from the next step, which drops the
// temperature in its own request (Anthropic requires the default then).
// rust: agent.rs::a_mid_turn_thinking_change_applies_from_the_next_step_and_drops_the_temperature
// rust: agent.rs::a_thinking_level_set_mid_turn_applies_from_the_next_step
unittest
{
    auto c = new Claude("claude-sonnet-4-6", [toolCall("c1"), LLMResponse("done")]);
    auto agent = agentFor(c, (Agent a) { a.control.requestThinking("high"); });
    agent.temperature = 0.5;
    agent.run("go", new NullEvents);
    assert(c.sent.length == 2);
    assert(c.sent[0].temperature == 0.5 && c.sent[0].thinking == Request.init);
    assert(c.sent[1].temperature.isNaN && c.sent[1].thinking == effort("high"),
        "the thinking-on step drops the temperature");
    assert(agent.thinking().source == Source.session);
    assert(loggedLevels(agent) == [null, "high (set for this session)"]);
}

// rust: agent.rs::a_small_max_tokens_caps_the_thinking_budget_with_a_warning
unittest
{
    auto agent = agentFor(new Claude("claude-sonnet-4-5", []));
    agent.maxTokens = 4096;
    agent.sessionThinking = session("high");
    assert(agent.thinking().warning.canFind("caps the high thinking budget"), agent.thinking().warning);
}

// A budget that can't fit under max_tokens sends no level, so nothing locks
// the temperature; a level that was also adjusted keeps both warnings.
// rust: agent.rs::no_room_for_a_budget_drops_the_level_everywhere
unittest
{
    auto agent = agentFor(new Claude("claude-sonnet-4-5", []));
    agent.maxTokens = 1024;
    agent.temperature = 0.5;
    agent.sessionThinking = session("high");
    auto r = agent.thinking();
    assert(r.effective == Thinking.init && r.request() == Request.init);
    assert(r.warning.canFind("leaves no room"));
    assert(agent.temperatureNow().fixed is null, "no thinking means no temperature lock");

    agent.sessionThinking = session("xhigh");
    r = agent.thinking();
    assert(r.effective == Thinking.init);
    assert(r.warning.canFind("using") && r.warning.canFind("leaves no room"), r.warning);
}

// After an overflow compacts, the retry re-resolves the level against the
// room it now has: no budget fit before, the full one fits after.
// rust: agent.rs::overflow_retry_reresolves_thinking_against_the_post_compaction_room
unittest
{
    auto c = new Claude("claude-sonnet-4-5", [
        LLMResponse("!error:HTTP 400: This model's maximum context length is 18000 tokens. However, you requested 19000 tokens."),
        LLMResponse("SUMMARY: done"), LLMResponse("done")]);
    auto agent = agentFor(c);
    agent.configuredWindow = 18_000;
    agent.maxTokens = 16_384;
    agent.autoCompact = false;
    agent.sessionThinking = session("high");
    agent.push(Message.user("x".replicate(64_000)));
    assert(agent.run("go", new NullEvents) == "done");
    assert(c.sent.length == 3, "overflow, summary, retry");
    assert(c.sent[0].thinking == Request.init, "no room before compaction");
    assert(c.sent[0].maxTokens < 1025);
    assert(c.sent[1].thinking == Request.init);
    Request budget; budget.kind = Request.Kind.budget; budget.budget = 16_384;
    assert(c.sent[2].thinking == budget, "the retry sends the level");
    assert(c.sent[2].maxTokens >= 15_000);
    assert(loggedLevels(agent)[$ - 1] == "high (set for this session)");
}

// rust: agent.rs::thinking_level_is_sent_and_drops_the_temperature_on_anthropic
unittest
{
    auto c = new Claude("claude-sonnet-4-6", [LLMResponse("a"), LLMResponse("b"), LLMResponse("c")]);
    auto agent = agentFor(c);
    agent.temperature = 0.5;
    agent.run("a", new NullEvents);
    agent.sessionThinking = session("high");
    assert(agent.thinking().source == Source.session);
    assert(agent.temperatureNow().fixed.length);
    agent.run("b", new NullEvents);
    agent.sessionThinking = session("off");
    agent.run("c", new NullEvents);
    Request off; off.kind = Request.Kind.off;
    assert(c.sent.map!(s => s.thinking).array == [Request.init, effort("high"), off]);
    assert(c.sent[0].temperature == 0.5 && c.sent[1].temperature.isNaN && c.sent[2].temperature == 0.5);
    assert(loggedLevels(agent) == [null, "high (set for this session)", "off (set for this session)"]);
    // Every reply records the temperature it was sent with.
    assert(agent.messages.filter!(m => m.role == Role.assistant).map!(m => m.temperature).array
        == ["0.5 (global setting)", "model default (required: the model accepts no temperature)", "0.5 (global setting)"]);
    agent.sessionThinking.nullify();
    assert(agent.thinking().effective == Thinking.init && agent.thinking().source == Source.global);
}
