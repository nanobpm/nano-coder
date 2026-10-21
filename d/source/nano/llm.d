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
    /// Responses API output-item id (`fc_*`), replayed so reasoning models
    /// can pair a preserved reasoning item with its call.
    string itemId;

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
    /// Images attached to a tool result (`read_file`). Not sent as text:
    /// request builders encode the newest few per the model.
    Attachment[] attachments;

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
    /// Assistant: provider reasoning items replayed on later requests.
    JSONValue[] thinkingBlocks;
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
    /// Provider reasoning items to replay with this reply (Anthropic signed
    /// `thinking`/`redacted_thinking` blocks, OpenAI `reasoning_content`,
    /// Responses `reasoning` items).
    JSONValue[] thinkingBlocks;
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
    /// The model's vision capability; null sends every attachment as text.
    import std.typecons : Nullable;
    import nano.vision : Vision;
    Nullable!Vision vision;
    /// Where attachments are stored; null for requests that carry no images
    /// (compaction).
    string attachmentsDir;

    /// The attachment occurrences this request sends as images: the newest
    /// `vision.maxImages` that are intact on disk. Keyed by occurrence
    /// (message index, attachment index), so the same image read twice
    /// counts twice. Computed once per request (it hashes the stored files).
    AttachmentPlan attachmentPlan() const @trusted
    {
        import nano.attachment : exists;
        AttachmentPlan plan;
        size_t[2][] available;
        foreach (mi, ref m; messages)
            foreach (ai, ref a; m.attachments)
                if (attachmentsDir.length && exists(attachmentsDir, a))
                {
                    available ~= [mi, ai];
                    plan.available[[mi, ai]] = true;
                }
        size_t max = vision.isNull ? 0 : vision.get.maxImages;
        auto keep = max < available.length ? max : available.length;
        foreach (k; available[$ - keep .. $]) plan.sendable[k] = true;
        return plan;
    }

    /// Message `mi`'s attachments for the wire: image data, or the text
    /// standing in for it (sent earlier, or no longer available).
    ResolvedAttachment[] resolveAttachments(size_t mi, const ref AttachmentPlan plan) const @trusted
    {
        import nano.attachment : readForLimits, ImageLimits;
        import std.format : format;
        ResolvedAttachment[] out_;
        foreach (ai, ref a; messages[mi].attachments)
        {
            auto gone = format("[image: %s, %s×%s (no longer available)]", a.path, a.width, a.height);
            size_t[2] key = [mi, ai];
            if (key in plan.sendable)
            {
                // Fit the stored bytes to the *active* model's limits.
                auto limits = vision.isNull ? ImageLimits.init : vision.get.imageLimits;
                auto ready = readForLimits(attachmentsDir, a, limits);
                out_ ~= ready.isNull ? ResolvedAttachment(false, ImageData.init, gone) : ResolvedAttachment(true, ready.get, null);
            }
            else if (key in plan.available)
                out_ ~= ResolvedAttachment(false, ImageData.init, format("[image omitted: %s (sent earlier)]", a.path));
            else out_ ~= ResolvedAttachment(false, ImageData.init, gone);
        }
        return out_;
    }
}

public import nano.attachment : Attachment, ImageData;

/// One attachment on the wire: an image, or placeholder text.
struct ResolvedAttachment
{
    bool isImage;
    ImageData image;
    string text;
}

/// Which attachment occurrences are intact on disk, and which of those are
/// within the image quota.
struct AttachmentPlan
{
    bool[size_t[2]] available, sendable;
    /// Whether the request carries at least one real image.
    bool carriesImage() const { return sendable.length > 0; }
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

/// Show a whole (non-streamed) response through `sink`.
LLMResponse reportWhole(LLMResponse r, StreamSink sink)
{
    if (sink !is null)
    {
        if (r.reasoning.length) sink(true, r.reasoning);
        if (r.content.length) sink(false, r.content);
    }
    return r;
}
