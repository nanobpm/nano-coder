/// The agent loop: send the conversation, stream the reply, run the tool
/// calls it asks for (after permission checks), feed results back, repeat.
module nano.agent;

import std.json;
import std.format : format;
import std.string : strip;
import std.conv : to;
import nano.llm;
import nano.tools;
import nano.permissions;
import nano.session;
import nano.control;

/// What the loop reports as it works (the CLI renders these).
interface AgentEvents
{
    void text(bool reasoning, string chunk);
    void toolStart(const ref ToolCall call);
    void toolEnd(const ref ToolCall call, string result, bool isError);
    void usage(TokenUsage u);
    /// A steering message joined the conversation mid-turn.
    void userMessage(string text);
    /// A complete model reply (after its deltas went to `text`).
    void assistantMessage(string text, string reasoning);
}

/// Why a turn ended (ACP `stopReason`).
enum StopReason : string
{
    endTurn = "end_turn",
    cancelled = "cancelled",
    maxTurnRequests = "max_turn_requests",
    maxTokens = "max_tokens",
}

class Agent
{
    LLMClient client;
    ToolRegistry tools;
    Policy policy;
    Message[] messages;
    long maxIterations;
    long maxTokens;
    double temperature = double.nan;
    SessionLog log;
    TokenUsage lastUsage;
    /// Steer or cancel the running turn from another thread.
    TurnControl control;
    /// Why the last `run` ended.
    StopReason lastStop;

    this(LLMClient client, ToolRegistry tools, Policy policy, string systemPrompt)
    {
        this.client = client;
        this.tools = tools;
        this.policy = policy;
        this.control = new TurnControl;
        if (systemPrompt.length) push(Message.system(systemPrompt));
    }

    void push(Message m)
    {
        messages ~= m;
        if (log !is null) log.append(m);
    }

    /// Run one user input to completion. Returns the final assistant text,
    /// or `cancelledResponse` when the turn was cancelled. Steers that arrive
    /// too late for this turn stay in `control` for the caller to queue.
    /// Pass `resetControl = false` when the caller already called
    /// `control.startTurn()`, so a cancel routed before `run` began is kept.
    string run(string input, AgentEvents ev, bool resetControl = true)
    {
        if (resetControl) control.startTurn();
        push(Message.user(input));
        string last;
        for (long i = 0; maxIterations <= 0 || i < maxIterations; i++)
        {
            if (control.isCancelled) return cancelled(ev);
            foreach (s; control.takePending)
            {
                push(Message.user(s.text));
                ev.userMessage(s.text);
                control.absorbed(s);
            }
            ChatRequest req;
            req.messages = messages;
            req.tools = tools.definitions;
            req.maxTokens = maxTokens;
            req.temperature = temperature;
            LLMResponse r;
            try r = client.chat(req, (bool t, string s) { ev.text(t, s); });
            catch (Cancelled) return cancelled(ev);
            catch (Exception e)
            {
                if (control.isCancelled) return cancelled(ev);
                throw e;
            }
            lastUsage = r.usage;
            ev.usage(r.usage);
            push(Message.assistant(r.content, r.toolCalls));
            last = r.content;
            if (r.content.length || r.reasoning.length) ev.assistantMessage(r.content, r.reasoning);
            if (r.toolCalls.length == 0)
            {
                bool cut = r.stopReason == "length" || r.stopReason == "max_tokens";
                if (cut) ev.text(false, "\n[the reply hit the output-token limit]");
                // A steer that arrived while the answer was written extends the turn.
                if (control.hasSteers && !control.isCancelled) continue;
                lastStop = cut ? StopReason.maxTokens : StopReason.endTurn;
                return last;
            }
            foreach (call; r.toolCalls)
            {
                ev.toolStart(call);
                bool isError = true;
                auto result = control.isCancelled ? cancelledToolResult : runTool(call, r.stopReason, isError);
                ev.toolEnd(call, result, isError);
                push(Message.toolResult(call.id, call.name, result, isError));
            }
        }
        ev.text(false, format("\n[stopped after %s model calls (max_iterations)]", maxIterations));
        lastStop = StopReason.maxTurnRequests;
        return last;
    }

    private string cancelled(AgentEvents ev)
    {
        ev.text(false, "\n" ~ cancelledResponse);
        lastStop = StopReason.cancelled;
        return cancelledResponse;
    }

    private string runTool(const ref ToolCall call, string stopReason, out bool isError)
    {
        isError = true;
        if (call.invalidArguments.length)
        {
            auto raw = call.invalidArguments.length > 300 ? call.invalidArguments[0 .. 300] ~ "…" : call.invalidArguments;
            auto advice = stopReason == "length" || stopReason == "max_tokens"
                ? "The reply was cut off by the output-token limit; send a smaller call (e.g. write the file in parts)."
                : "Send the arguments as a single JSON object.";
            return format("Invalid arguments for %s (not a JSON object): %s\n%s", call.name, raw, advice);
        }
        if (!tools.has(call.name)) return format("Tool '%s' not found. Available: %s", call.name, toolNames());
        if (auto blocked = policy.check(call.name, call.arguments)) return blocked;
        try
        {
            auto out_ = tools.execute(call.name, call.arguments);
            isError = false;
            return out_;
        }
        catch (ToolError e) return e.msg;
        catch (Exception e) return format("%s failed: %s", call.name, e.msg);
    }

    private string toolNames()
    {
        string s;
        foreach (d; tools.definitions) s ~= (s.length ? ", " : "") ~ d.name;
        return s;
    }
}

version (unittest)
{
    import nano.providers.mock;

    class NullEvents : AgentEvents
    {
        string shown;
        string[] tools;
        void text(bool r, string s) { if (!r) shown ~= s; }
        void toolStart(const ref ToolCall c) { tools ~= c.name; }
        void toolEnd(const ref ToolCall c, string res, bool err) {}
        void usage(TokenUsage u) {}
        string[] steered;
        void userMessage(string t) { steered ~= t; }
        void assistantMessage(string t, string r) {}
    }
}

unittest
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)),
        (JSONValue a) => "echoed " ~ a["text"].str);
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{"text":"hi"}`), ToolCall.fromRaw("c2", "nope", `{}`),
            ToolCall.fromRaw("c3", "echo", `{"text":`)]),
        LLMResponse("done"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    auto ev = new NullEvents;
    assert(agent.run("go", ev) == "done");
    assert(ev.tools == ["echo", "nope", "echo"]);
    auto second = mock.seen[1];
    assert(second[$ - 3].content == "echoed hi" && !second[$ - 3].isError);
    assert(second[$ - 2].isError && second[$ - 1].isError);
    import std.string : indexOf;
    assert(second[$ - 1].content.indexOf("Invalid arguments") == 0);
}

unittest
{
    auto reg = new ToolRegistry;
    bool ran;
    reg.register(ToolDefinition("bash", "", parseJSON(`{}`)), (JSONValue a) { ran = true; return ""; });
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "bash", `{"command":"sudo rm -rf /"}`)]),
        LLMResponse("ok"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, null);
    agent.maxIterations = 5;
    agent.run("x", new NullEvents);
    assert(!ran);
    import std.string : indexOf;
    assert(mock.seen[1][$ - 1].content.indexOf("Blocked") == 0);
}

// A steer sent while a tool runs joins the next model call.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    reg.register(ToolDefinition("work", "", parseJSON(`{}`)), (JSONValue a) {
        agent.control.steer("use the other file");
        return "ok";
    });
    auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c1", "work", `{}`)]), LLMResponse("done")]);
    agent = new Agent(mock, reg, Policy.init, null);
    auto ev = new NullEvents;
    assert(agent.run("go", ev) == "done");
    assert(ev.steered == ["use the other file"]);
    assert(mock.seen[1][$ - 1].role == Role.user && mock.seen[1][$ - 1].content == "use the other file");
}

// A steer that lands during the final answer extends the turn.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    auto mock = new MockClient([LLMResponse("long answer"), LLMResponse("short")]);
    agent = new Agent(mock, reg, Policy.init, null);
    auto ev = new NullEvents;
    agent.control.startTurn();
    // Queued before `run`: absorbed before the first call, so no extension.
    agent.control.steer("make it shorter");
    assert(agent.run("go", ev) == "long answer");
    assert(ev.steered == ["make it shorter"]);
}

// A cancel stops the turn: remaining tool calls are recorded as cancelled.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    int runs;
    reg.register(ToolDefinition("work", "", parseJSON(`{}`)), (JSONValue a) {
        runs++;
        agent.control.cancel();
        return "ok";
    });
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "work", `{}`), ToolCall.fromRaw("c2", "work", `{}`)]),
        LLMResponse("never"),
    ]);
    agent = new Agent(mock, reg, Policy.init, null);
    assert(agent.run("go", new NullEvents) == cancelledResponse);
    assert(runs == 1 && mock.seen.length == 1);
    assert(agent.messages[$ - 1].content == cancelledToolResult && agent.messages[$ - 1].isError);
    // The next turn starts clean.
    agent.client = new MockClient([LLMResponse("fine")]);
    assert(agent.run("again", new NullEvents) == "fine");
}
