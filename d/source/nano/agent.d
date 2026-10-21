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

/// What the loop reports as it works (the CLI renders these).
interface AgentEvents
{
    void text(bool reasoning, string chunk);
    void toolStart(const ref ToolCall call);
    void toolEnd(const ref ToolCall call, string result, bool isError);
    void usage(TokenUsage u);
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

    this(LLMClient client, ToolRegistry tools, Policy policy, string systemPrompt)
    {
        this.client = client;
        this.tools = tools;
        this.policy = policy;
        if (systemPrompt.length) push(Message.system(systemPrompt));
    }

    void push(Message m)
    {
        messages ~= m;
        if (log !is null) log.append(m);
    }

    /// Run one user input to completion. Returns the final assistant text.
    string run(string input, AgentEvents ev)
    {
        push(Message.user(input));
        string last;
        for (long i = 0; maxIterations <= 0 || i < maxIterations; i++)
        {
            ChatRequest req;
            req.messages = messages;
            req.tools = tools.definitions;
            req.maxTokens = maxTokens;
            req.temperature = temperature;
            auto r = client.chat(req, (bool t, string s) { ev.text(t, s); });
            lastUsage = r.usage;
            ev.usage(r.usage);
            push(Message.assistant(r.content, r.toolCalls));
            last = r.content;
            if (r.toolCalls.length == 0)
            {
                if (r.stopReason == "length" || r.stopReason == "max_tokens")
                    ev.text(false, "\n[the reply hit the output-token limit]");
                return last;
            }
            foreach (call; r.toolCalls)
            {
                ev.toolStart(call);
                bool isError;
                auto result = runTool(call, r.stopReason, isError);
                ev.toolEnd(call, result, isError);
                push(Message.toolResult(call.id, call.name, result, isError));
            }
        }
        ev.text(false, format("\n[stopped after %s model calls (max_iterations)]", maxIterations));
        return last;
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
