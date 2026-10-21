/// The `mock` provider kind (`providers/mock.rs`): an offline client that
/// triggers tool calls from keywords, so the harness can be tried without a
/// model endpoint. (Unit tests script replies with `MockClient` instead.)
module nano.providers.demo;

import nano.llm;
import std.format : format;
import std.json;
import std.uni : toLower, isAlphaNum;
import std.string : indexOf;
import std.algorithm : canFind, splitter;

class DemoClient : LLMClient
{
    private string provider, model;
    private long calls;
    /// Delay between streamed words (ms); 0 in tests.
    long textDelayMs = 15, thinkingDelayMs = 40;

    this(string provider, string model)
    {
        this.provider = provider;
        this.model = model;
    }

    LLMResponse chat(const ref ChatRequest req, StreamSink sink)
    {
        auto r = reply(req);
        if (sink !is null)
            foreach (part; [r.reasoning, r.content])
            {
                bool thinking = part is r.reasoning && r.reasoning.length > 0;
                size_t start;
                foreach (i, ch; part)
                    if (ch == ' ' || i + 1 == part.length)
                    {
                        sink(thinking, part[start .. i + 1]);
                        start = i + 1;
                        pause(thinking ? thinkingDelayMs : textDelayMs);
                    }
            }
        return r;
    }

    private static void pause(long ms) @trusted
    {
        import core.thread : Thread;
        import core.time : msecs;
        if (ms > 0) Thread.sleep(ms.msecs);
    }

    private LLMResponse reply(const ref ChatRequest req)
    {
        auto callId = ++calls;
        static TokenUsage usage(long completion) { return TokenUsage(50, completion); }
        if (req.messages.length)
        {
            auto last = &req.messages[$ - 1];
            if (last.role == Role.tool)
            {
                LLMResponse r;
                r.content = format("Based on the %s tool result: %s", last.toolName.length ? last.toolName : "unknown", last.content);
                r.usage = usage(30);
                r.stopReason = "stop";
                return r;
            }
            if (last.role == Role.user)
            {
                string name, args;
                if (pickTool(last.content, name, args))
                {
                    bool available;
                    foreach (ref t; req.tools) if (t.name == name) available = true;
                    if (available)
                    {
                        LLMResponse r;
                        r.toolCalls = [ToolCall.fromRaw(format("call_%s", callId), name, args)];
                        r.usage = usage(20);
                        r.stopReason = "tool_calls";
                        return r;
                    }
                }
            }
        }
        LLMResponse r;
        r.content = format("This is a mock response from %s (call #%s). I'm simulating an LLM agent. Try asking me "
            ~ "about the time, or to list files or run a command, to see tool calls in action.", model, callId);
        r.usage = usage(30);
        r.stopReason = "stop";
        r.reasoning = thinkingFor(req);
        return r;
    }

    /// The tool a prompt's keywords ask for (name and JSON arguments).
    static bool pickTool(string content, out string name, out string args)
    {
        content = content.toLower;
        // Whole words, so "task" doesn't match "ask".
        if (hasWord(content, "question") || hasWord(content, "ask"))
        {
            name = "question";
            args = `{"questions":[{"question":"Which way should I go?","header":"Direction","options":[{"label":"Left"},{"label":"Right"}]}]}`;
            return true;
        }
        if (content.canFind("time") || content.canFind("clock"))
        {
            name = "get_time";
            args = "{}";
            return true;
        }
        if (content.canFind("file") || content.canFind("list"))
        {
            name = "bash";
            args = `{"command":"ls -la"}`;
            return true;
        }
        if (content.canFind("bash") || content.canFind("command") || content.canFind("run"))
        {
            auto command = content.canFind("echo") ? "echo hello world" : content.canFind("sleep") ? "sleep 3"
                : content.canFind("pwd") ? "pwd" : "ls -la";
            name = "bash";
            args = JSONValue(["command": command]).toString;
            return true;
        }
        return false;
    }

    private static bool hasWord(string haystack, string needle)
    {
        size_t start;
        foreach (i, dchar c; haystack)
        {
            if (!isAlphaNum(c))
            {
                if (haystack[start .. i] == needle) return true;
                start = i + (c < 0x80 ? 1 : imported!"std.utf".codeLength!char(c));
            }
        }
        return haystack[start .. $] == needle;
    }

    /// Mock reasoning when the latest user message mentions "think".
    private static string thinkingFor(const ref ChatRequest req)
    {
        foreach_reverse (ref m; req.messages)
            if (m.role == Role.user)
                return m.content.toLower.canFind("think")
                    ? "The user wants me to think this through. First I should restate the problem, then consider what "
                        ~ "tools might help, weigh the options, and check for edge cases. Nothing here needs a tool, so a "
                        ~ "direct answer is best. I will keep it short."
                    : "";
        return "";
    }

    string[] listModels() { return [model]; }
    string modelName() const { return model; }
    string providerName() const { return provider; }
}

unittest
{
    string n, a;
    assert(DemoClient.pickTool("What TIME is it?", n, a) && n == "get_time");
    assert(DemoClient.pickTool("please ask me", n, a) && n == "question");
    assert(!DemoClient.pickTool("finish the task", n, a));
    assert(DemoClient.pickTool("run echo", n, a) && n == "bash" && a == `{"command":"echo hello world"}`);

    auto c = new DemoClient("mock", "mock");
    c.textDelayMs = c.thinkingDelayMs = 0;
    ChatRequest req;
    auto msgs = [Message(Role.user, "list the files")];
    req.messages = msgs;
    auto tools = [ToolDefinition("bash", "", JSONValue.init)];
    req.tools = tools;
    auto r = c.chat(req, null);
    assert(r.toolCalls.length == 1 && r.toolCalls[0].name == "bash" && r.toolCalls[0].id == "call_1");

    Message res;
    res.role = Role.tool;
    res.toolName = "bash";
    res.content = "a.txt";
    msgs ~= res;
    req.messages = msgs;
    assert(c.chat(req, null).content == "Based on the bash tool result: a.txt");

    msgs = [Message(Role.user, "think about it")];
    req.messages = msgs;
    string shown;
    r = c.chat(req, (bool thinking, string s) { if (!thinking) shown ~= s; });
    assert(r.reasoning.length && shown == r.content && r.content.canFind("call #3"));
}
