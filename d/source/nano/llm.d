/// Provider-neutral conversation types and the client interface.
module nano.llm;

import std.json;

enum Role { system, user, assistant, tool }

string roleName(Role r)
{
    final switch (r)
    {
        case Role.system: return "system";
        case Role.user: return "user";
        case Role.assistant: return "assistant";
        case Role.tool: return "tool";
    }
}

struct ToolCall
{
    string id;
    string name;
    /// Decoded arguments; an empty object when `invalidArguments` is set.
    JSONValue arguments;
    /// The raw text when the model's arguments were not a JSON object.
    string invalidArguments;

    static ToolCall fromRaw(string id, string name, string raw)
    {
        ToolCall c = ToolCall(id, name);
        import std.string : strip;
        auto text = raw.strip;
        if (text.length == 0)
        {
            c.arguments = JSONValue(string[string].init);
            return c;
        }
        try
        {
            auto v = parseJSON(text);
            if (v.type == JSONType.object)
            {
                c.arguments = v;
                return c;
            }
        }
        catch (Exception) {}
        c.arguments = JSONValue(string[string].init);
        c.invalidArguments = raw;
        return c;
    }

    string encodedArguments() const
    {
        return invalidArguments.length ? invalidArguments : arguments.toString;
    }
}

struct Message
{
    Role role;
    string content;
    ToolCall[] toolCalls;
    /// For `Role.tool`: the call this answers.
    string toolCallId;
    string toolName;
    bool isError;

    // Session-log metadata (not sent to providers), as in Rust's `Message`.
    /// When the message joined the conversation (RFC 3339 with offset).
    string timestamp;
    /// Assistant: the reasoning text of the reply.
    string thinking;
    /// Assistant: provider-reported usage for the request (if `hasUsage`).
    TokenUsage usage;
    bool hasUsage;
    /// Assistant: wall-clock duration of the request in ms (-1: unknown).
    long durationMs = -1;
    /// Assistant: the provider's stop reason, normalised (`end_turn`, `tool_use`, `max_tokens`).
    string stopReason;
    /// The message's physical line in the session log (0: not logged), its
    /// `#N` ID for smart compaction and the history tools.
    ulong logLine;
    /// Fields the D port doesn't model (e.g. Anthropic `thinking_blocks`),
    /// kept so a resumed Rust log round-trips them.
    JSONValue extra;

    static Message system(string c) { return Message(Role.system, c); }
    static Message user(string c) { return Message(Role.user, c); }
    static Message assistant(string c, ToolCall[] calls = null)
    {
        auto m = Message(Role.assistant, c);
        m.toolCalls = calls;
        return m;
    }
    static Message toolResult(string id, string name, string content, bool error = false)
    {
        auto m = Message(Role.tool, content);
        m.toolCallId = id;
        m.toolName = name;
        m.isError = error;
        return m;
    }

    JSONValue toJson() const
    {
        JSONValue j = ["role": roleName(role), "content": content];
        if (toolCalls.length)
        {
            JSONValue[] calls;
            foreach (c; toolCalls)
            {
                JSONValue cj = ["id": c.id, "name": c.name];
                cj["arguments"] = c.encodedArguments;
                calls ~= cj;
            }
            j["tool_calls"] = calls;
        }
        if (toolCallId.length) j["tool_call_id"] = toolCallId;
        if (toolName.length) j["name"] = toolName;
        if (isError) j["is_error"] = true;
        return j;
    }

    static Message fromJson(JSONValue j)
    {
        import std.algorithm : countUntil;
        Message m;
        auto names = ["system", "user", "assistant", "tool"];
        auto r = names.countUntil(j["role"].str);
        if (r < 0) throw new Exception("unknown role " ~ j["role"].str);
        m.role = cast(Role) r;
        if (auto c = "content" in j) m.content = c.type == JSONType.string ? c.str : "";
        if (auto calls = "tool_calls" in j)
            foreach (c; calls.array)
                m.toolCalls ~= ToolCall.fromRaw(c["id"].str, c["name"].str, c["arguments"].str);
        if (auto v = "tool_call_id" in j) m.toolCallId = v.str;
        if (auto v = "name" in j) m.toolName = v.str;
        if (auto v = "is_error" in j) m.isError = v.boolean;
        return m;
    }
}

struct TokenUsage
{
    long inputTokens;
    long outputTokens;
    long cachedInputTokens;
}

struct LLMResponse
{
    string content;
    string reasoning;
    ToolCall[] toolCalls;
    TokenUsage usage;
    string stopReason;
}

struct ToolDefinition
{
    string name;
    string description;
    JSONValue parameters;
}

struct ChatRequest
{
    const(Message)[] messages;
    const(ToolDefinition)[] tools;
    long maxTokens;
    /// NaN means "send none".
    double temperature = double.nan;
    /// The resolved thinking control (kind `none` sends nothing).
    import nano.thinking : ThinkingRequest = Request;
    ThinkingRequest thinking;
}

/// Receives streamed text: `reasoning` is true for thinking output.
alias StreamSink = void delegate(bool reasoning, string text);

/// What an endpoint reports about the current model.
struct Capabilities
{
    import std.typecons : Nullable;
    import nano.thinking : Reported;
    import nano.vision : Vision;
    Nullable!Reported thinking;
    Nullable!Vision vision;
}

/// A client that can ask its endpoint what the model supports.
interface CapabilityProbe
{
    Capabilities probeCapabilities();
}

interface LLMClient
{
    LLMResponse chat(const ref ChatRequest req, StreamSink sink);
    string[] listModels();
    string modelName() const;
    string providerName() const;
}

/// Splits `<think>...</think>` out of streamed content, across chunk boundaries.
struct ThinkSplitter
{
    private bool inThink;
    private string pending;

    void push(string text, scope void delegate(bool, string) emit)
    {
        import std.string : indexOf;
        pending ~= text;
        for (;;)
        {
            string tag = inThink ? "</think>" : "<think>";
            auto at = pending.indexOf(tag);
            if (at >= 0)
            {
                if (at > 0) emit(inThink, pending[0 .. at]);
                pending = pending[at + tag.length .. $];
                inThink = !inThink;
                continue;
            }
            // keep a possible partial tag at the end
            size_t keep = 0;
            foreach (n; 1 .. tag.length)
                if (pending.length >= n && pending[$ - n .. $] == tag[0 .. n]) keep = n;
            if (pending.length > keep) emit(inThink, pending[0 .. $ - keep]);
            pending = pending[$ - keep .. $];
            return;
        }
    }

    void finish(scope void delegate(bool, string) emit)
    {
        if (pending.length) emit(inThink, pending);
        pending = null;
    }
}

unittest
{
    auto ok = ToolCall.fromRaw("1", "bash", `{"command":"ls"}`);
    assert(ok.invalidArguments is null && ok.arguments["command"].str == "ls");
    auto bad = ToolCall.fromRaw("2", "bash", `{"command":`);
    assert(bad.invalidArguments == `{"command":`);
    assert(bad.encodedArguments == `{"command":`);
}

unittest
{
    string thought, said;
    ThinkSplitter s;
    void emit(bool r, string t) { if (r) thought ~= t; else said ~= t; }
    foreach (chunk; ["hi <thi", "nk>pon", "der</th", "ink> done"]) s.push(chunk, &emit);
    s.finish(&emit);
    assert(thought == "ponder" && said == "hi  done");
}

unittest
{
    auto m = Message.assistant("x", [ToolCall.fromRaw("c1", "read_file", `{"path":"a"}`)]);
    auto back = Message.fromJson(parseJSON(m.toJson.toString));
    assert(back.toolCalls[0].arguments["path"].str == "a");
}
