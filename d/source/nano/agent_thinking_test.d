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
import nano.config : KindedClient, ProviderConfig, ProviderKind;
import nano.llm;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.thinking : Request, Source, Thinking;
import nano.tools : ToolRegistry;

private:

/// What one request sent: its temperature (NaN: none) and thinking.
struct Sent { double temperature; Request thinking; long maxTokens; }

/// A scripted Anthropic model that records what each request sent.
class Claude : MockClient, KindedClient
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
    ProviderKind kind() const { return ProviderKind.anthropic; }
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

/// A test double that names no provider API.
class Kindless : MockClient
{
    this() { super([]); }
    override string providerName() const { return "mock"; }
}

// The kind comes from the live client: a kindless one gets the provider's
// temperature unclamped, though its config says Anthropic.
// rust: agent.rs::temperature_ignores_config_kind_for_a_kindless_client
unittest
{
    import nano.temperature : TSource = Source;
    auto agent = new Agent(new Kindless, new ToolRegistry, Policy.init, "sys");
    auto pc = new ProviderConfig;
    pc.hasKind = true;
    pc.kind = ProviderKind.anthropic;
    pc.temperature = 1.5;
    agent.providerLookup = (string name) => cast(const(ProviderConfig)*) pc;
    auto r = agent.temperatureNow;
    assert(r.effective == 1.5 && r.source == TSource.provider && r.warning is null, r.warning);
}

// rust: agent.rs::temperature_resolves_for_a_custom_mock_provider
unittest
{
    import nano.config : Config, resolve;
    import nano.providers : makeClient;
    import nano.temperature : TSource = Source;
    Config c;
    ProviderConfig demo;
    demo.hasKind = true;
    demo.kind = ProviderKind.mock;
    demo.temperature = 0.2;
    c.providers["demo"] = demo;
    auto client = makeClient(resolve(c, "demo/foo"));
    assert(client.providerName == "demo");
    auto agent = new Agent(client, new ToolRegistry, Policy.init, "sys");
    agent.providerLookup = (string name) => name in c.providers;
    auto r = agent.temperatureNow;
    assert(r.effective == 0.2 && r.source == TSource.provider);
}

// A model that always thinks gets no custom temperature, compaction included;
// one that thinks only when asked keeps it for compaction.
// rust: agent.rs::compaction_sends_no_temperature_to_an_always_thinking_model
// rust: agent.rs::compaction_keeps_the_temperature_when_turns_think_on_anthropic
unittest
{
    auto fable = agentFor(new Claude("claude-fable-5", []));
    fable.temperature = 0.5;
    assert(fable.thinking.alwaysAnthropicThinking);
    auto c = fable.temperatureFor(fable.thinking.alwaysAnthropicThinking);
    assert(c.fixed.length && isNaN(c.effective));
    fable.sessionThinking = session("high");
    c = fable.temperatureFor(fable.thinking.alwaysAnthropicThinking);
    assert(c.fixed.length && isNaN(c.effective), "a level does not unlock the temperature");

    auto sonnet = agentFor(new Claude("claude-sonnet-4-6", []));
    sonnet.temperature = 0.5;
    sonnet.sessionThinking = session("high");
    assert(sonnet.temperatureNow.fixed.length, "turns that think drop it");
    c = sonnet.temperatureFor(sonnet.thinking.alwaysAnthropicThinking);
    assert(!c.fixed.length && c.effective == 0.5, "compaction keeps it");
    sonnet.sessionThinking.nullify();
    c = sonnet.temperatureFor(sonnet.thinking.alwaysAnthropicThinking);
    assert(!c.fixed.length && c.effective == 0.5);
}

string shown(Agent agent)
{
    import nano.agent_status : statusFromAgent;
    import nano.status : Stats;
    Stats s;
    statusFromAgent(s, agent, "~");
    return s.thinking;
}

/// An OpenAI-kinded double.
class Gpt : MockClient, KindedClient
{
    this() { super([]); }
    override string modelName() const { return "gpt-5"; }
    ProviderKind kind() const { return ProviderKind.openai; }
}

// rust: agent.rs::status_bar_reports_nothing_for_a_dropped_level
unittest
{
    auto agent = new Agent(new Gpt, new ToolRegistry, Policy.init, "sys");
    auto pc = new ProviderConfig;
    pc.dropParams = ["reasoning_effort"];
    agent.providerLookup = (string name) => cast(const(ProviderConfig)*) pc;
    agent.sessionThinking = session("high");
    assert(agent.thinking.dropped);
    assert(shown(agent) is null, "a dropped level is not shown as sent");
}

// A level changed while a step runs shows once a request sends it.
// rust: agent.rs::status_line_reflects_the_level_the_request_sends_not_a_reread
unittest
{
    string[] seen;
    auto claude = new Claude("claude-sonnet-4-6", [toolCall("c1"), LLMResponse("done")]);
    auto agent = agentFor(claude, (Agent a) {
        a.sessionThinking = session("high");
        seen ~= shown(a);
    });
    agent.sessionThinking = session("low");
    agent.run("go", new NullEvents);
    assert(claude.sent[0].thinking == effort("low") && claude.sent[1].thinking == effort("high"));
    assert(seen == ["low"], "step 1 shows what its request sent");
    assert(shown(agent) == "high", "between turns: what the next request sends");
}

// A max_tokens change that drops a budget level shows on the next refresh.
// rust: agent.rs::refreshing_stats_tracks_a_max_tokens_driven_thinking_change
unittest
{
    auto agent = agentFor(new Claude("claude-sonnet-4-5", []));
    agent.maxTokens = 16_384;
    agent.sessionThinking = session("high");
    assert(shown(agent).length, "a budget level that fits is shown");
    agent.maxTokens = 1024;
    assert(shown(agent) is null, "too small a max_tokens drops it");
    agent.maxTokens = 16_384;
    assert(shown(agent).length);
}

/// Streams each reply's thinking, then its content.
class Thinker : MockClient
{
    LLMResponse[] replies;
    this(LLMResponse[] script) { super(script); replies = script; }
    override LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto n = seen.length;
        if (n < replies.length && replies[n].reasoning.length) sink(true, replies[n].reasoning);
        return super.chat(req, sink);
    }
}

class Order : NullEvents
{
    string[] names;
    override void text(bool reasoning, string chunk) { names ~= (reasoning ? "thinking-delta:" : "text-delta:") ~ chunk; }
    override void assistantMessage(string text, string reasoning) { names ~= "message:" ~ text ~ "|" ~ reasoning; }
    override void responseRestarted() { names ~= "restart"; }
}

// rust: agent.rs::streams_deltas_and_reports_thinking_before_the_answer
unittest
{
    auto thought = LLMResponse("answer");
    thought.reasoning = "reasoning";
    thought.thinkingBlocks = [parseJSON(`{"type":"thinking","thinking":"reasoning","signature":"s"}`)];
    auto mock = new Thinker([thought, LLMResponse("later")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    auto ev = new Order;
    agent.run("hi", ev);
    assert(ev.names == ["thinking-delta:reasoning", "text-delta:answer", "message:answer|reasoning"], imported!"std.conv".to!string(ev.names));
    agent.run("again", new NullEvents);
    assert(mock.seen[1][2].thinkingBlocks.length == 1, "the signed block is replayed");
}

// rust: agent.rs::logs_thinking_usage_and_duration_with_assistant_messages
unittest
{
    import std.file : exists, readText, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.string : lineSplitter;
    import nano.option : some;
    import nano.session : SessionLog;
    auto first = toolCall("c1");
    first.reasoning = "call the tool";
    first.usage = TokenUsage(10, 1);
    auto second = LLMResponse("done");
    second.reasoning = "now answer";
    second.usage = TokenUsage(20, 1);
    auto agent = agentFor(new MockClient([first, second]));
    auto dir = buildPath(tempDir, "nano-log-thinking");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.append(agent.messages[0]);
    agent.log = some(log);
    assert(agent.run("ping", new NullEvents) == "done");
    JSONValue[] assistants, others;
    foreach (line; readText(log.path).lineSplitter)
    {
        auto j = parseJSON(line);
        if (j["type"].str != "message") continue;
        if (j["data"]["role"].str == "assistant") assistants ~= j["data"];
        else others ~= j["data"];
    }
    assert(assistants.length == 2);
    assert(assistants[0]["thinking"].str == "call the tool" && assistants[0]["usage"]["prompt_tokens"].integer == 10);
    assert(assistants[1]["thinking"].str == "now answer" && assistants[1]["usage"]["prompt_tokens"].integer == 20);
    foreach (a; assistants) assert("duration_ms" in a.objectNoRef);
    foreach (o; others) assert("duration_ms" !in o.objectNoRef && "usage" !in o.objectNoRef, o.toString);
}

// rust: agent.rs::read_file_binary_error_notes_vision_capability
// rust: agent.rs::only_read_file_decodes_image_results
unittest
{
    import std.algorithm : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import nano.tools.files : ReadState, registerFiles = register;
    auto dir = buildPath(tempDir, "nano-binary-hint");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto bin = buildPath(dir, "blob.bin");
    write(bin, cast(const(ubyte)[]) [0, 1, 2, 3, 255, 0, 42]);
    Message toolResult(bool vision, ToolCall call)
    {
        auto reg = new ToolRegistry;
        registerFiles(reg, new ReadState);
        reg.register(ToolDefinition("shot", "shot", parseJSON(`{"type":"object"}`)), (JSONValue a) =>
            `{"image":{"media_type":"image/png","path":"/nope.png","width":1,"height":1,"bytes":3}}`);
        auto agent = new Agent(new MockClient([LLMResponse("", "", [call]), LLMResponse("ok")]), reg, Policy.init, "sys");
        agent.globalVision = vision;
        agent.run("read", new NullEvents);
        return agent.messages[$ - 2];
    }
    auto read = ToolCall.fromRaw("c1", "read_file", JSONValue(["path": bin]).toString);
    auto t = toolResult(true, read);
    assert(t.isError && t.content.canFind("looks like a binary file") && t.content.canFind("can view images"), t.content);
    t = toolResult(false, read);
    assert(t.content.canFind("can't view images"), t.content);
    t = toolResult(true, ToolCall.fromRaw("c1", "shot", `{}`));
    assert(!t.isError && !t.attachments.length && t.content.canFind(`"image"`), t.content);
}

// rust: agent.rs::mid_reply_restart_emits_a_reset_event_before_resending
unittest
{
    auto mock = new MockClient([LLMResponse("!drop:partial reply "), LLMResponse("!drop:partial reply "),
        LLMResponse("the full answer")]);
    auto agent = new Agent(mock, new ToolRegistry, Policy.init, "sys");
    auto ev = new Order;
    agent.run("hi", ev);
    import std.algorithm : count;
    assert(ev.names.count("restart") == 2, imported!"std.conv".to!string(ev.names));
    assert(ev.names[0] == "text-delta:partial reply " && ev.names[1] == "restart", imported!"std.conv".to!string(ev.names));
    assert(ev.names[$ - 1] == "message:the full answer|");
}
