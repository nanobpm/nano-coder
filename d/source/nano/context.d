/// Context-window accounting and compaction helpers (port of `context.rs`).
module nano.context;

@safe:

import std.algorithm : canFind, min, max;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.string : toLower, strip, startsWith;
import std.uni : asLowerCase;
import nano.llm : Message, Role;

/// Used when neither config nor the model name gives a window.
enum size_t defaultContextWindow = 128_000;
/// Tokens kept verbatim at the end of the conversation when auto-compacting.
enum size_t keepRecentTokens = 20_000;
/// Target length of the summary text itself.
enum long summaryMaxTokens = 4_096;
/// Extra output room for reasoning models writing the summary.
enum long summaryReasoningAllowance = 8_192;
/// Output tokens a request aims to keep free.
enum size_t minOutputReserve = 4096;

/// Tokens kept free beyond prompt + output: the prompt estimate can undercount.
size_t outputMargin(size_t window) { return window / 50; }

/// `max_tokens` for a summary request: room for the summary plus reasoning,
/// never above the configured value, at most a quarter of the window.
long summaryOutputBudget(size_t window, long configured)
{
    configured = max(configured, 1L);
    auto floor = min(summaryMaxTokens, configured);
    return max(min(configured, summaryMaxTokens + summaryReasoningAllowance, cast(long)(window / 4)), floor);
}

enum string summaryTruncatedNote = "\n\n[This summary was cut off at the output limit, so its end is missing. "
    ~ "Check the current state (files, git, the plan) before redoing any work.]";

enum string summaryPrefix = "[Summary of the earlier conversation, written when the context was compacted]";

enum string summarySystemPrompt = "You are compacting an AI agent's conversation so it can keep working with a smaller context. "
    ~ "Write a summary that lets the agent continue without the original messages. Include:\n"
    ~ "- the user's goals, requirements and constraints (quote exact wording where it matters);\n"
    ~ "- decisions made and why;\n"
    ~ "- work completed: files created or edited (with paths), commands run and their key results, "
    ~ "commits, branches, pull requests and URLs (with exact names and numbers);\n"
    ~ "- the current state and what was in progress when the summary was written;\n"
    ~ "- open problems, errors still unresolved, and the next steps;\n"
    ~ "- identifiers and values the agent will need again.\n"
    ~ "Be concise but do not drop facts the agent would otherwise have to rediscover; keep the summary under about "
    ~ "2,500 words. Do not invent anything. Output only the summary.";

/// Starts a smart-compaction summary; its presence enables the history tools.
enum string smartSummaryPrefix =
    "[Summary of the earlier conversation, written when the context was compacted (smart compaction)]";

/// Added to the summarizer prompt in smart mode.
enum string smartSummaryInstructions = "\n\nEach message in the transcript is labelled [#N], its ID in the session log. "
    ~ "The agent can later read any message in full by that ID, so the summary can stay short: after a fact whose exact text "
    ~ "may matter (an error message, a command and its output, a file's contents, the user's exact wording), cite its source "
    ~ "as (#N) instead of copying long text. Cite only IDs that appear in the transcript.";

/// Note after a smart summary telling the agent how to recover originals.
/// `first`/`last` are 0 when the range is unknown.
string smartSummaryNote(ulong first, ulong last)
{
    auto covered = first ? format("messages #%s–#%s", first, last) : "the earlier messages";
    return format("[This summary covers %s. The originals are kept verbatim in the session log; the summary is "
        ~ "lossy and may leave out or blur the detail you need. For anything from that period (an exact error, a command and "
        ~ "its output, what the user asked for), use history_search, then history_read to see a message by its #N ID. Don't "
        ~ "look on disk or re-run commands to recover what was said: that shows the current state, not what happened. Search "
        ~ "for distinctive text (an error code or phrase, an identifier, a flag) rather than common words, use order=oldest "
        ~ "for things established early, and try another pattern before concluding something isn't there. Long "
        ~ "outputs were shortened before summarizing, so details from the middle of a long output are the likeliest to be missing, "
        ~ "and an assistant message describing an output may paraphrase it: read the output itself. Retrieved messages "
        ~ "are history, not the current state of files.]", covered);
}

/// How compaction treats the history it folds away.
enum CompactionMode { standard, smart }

string modeName(CompactionMode m) { return m == CompactionMode.smart ? "smart" : "standard"; }

bool parseCompactionMode(string s, out CompactionMode m)
{
    switch (s.toLower)
    {
        case "standard": m = CompactionMode.standard; return true;
        case "smart": m = CompactionMode.smart; return true;
        default: return false;
    }
}

/// `12.3k`-style token count.
string formatTokens(size_t tokens)
{
    if (tokens < 1_000) return tokens.to!string;
    if (tokens < 100_000) return format("%.1fk", tokens / 1_000.0);
    if (tokens < 1_000_000) return format("%sk", tokens / 1_000);
    return format("%.2fM", tokens / 1_000_000.0);
}

/// Rough token count for text (about four characters per token).
size_t textTokens(string text) { return (text.length + 3) / 4; }

/// Tokens for one message: content, each tool call, framing overhead.
size_t messageTokens(const ref Message m) @trusted
{
    size_t calls;
    foreach (ref c; m.toolCalls) calls += textTokens(c.name) + textTokens(c.arguments.toString) + 4;
    return textTokens(m.content) + calls + 4;
}

size_t messagesTokens(const Message[] ms)
{
    size_t n;
    foreach (ref m; ms) n += messageTokens(m);
    return n;
}

/// Context window by model family, for models whose provider config has none.
size_t windowForModel(string model)
{
    static immutable string[] needles = ["claude", "gpt-4.1", "gpt-5", "gpt-4o", "o4-mini", "o3", "o1", "gemini",
        "deepseek", "grok", "mistral-large", "codestral", "kimi-k3", "kimi", "gpt-oss", "mock"];
    static immutable size_t[] windows = [200_000, 1_047_576, 400_000, 128_000, 200_000, 200_000, 200_000, 1_048_576,
        128_000, 256_000, 128_000, 256_000, 1_000_000, 256_000, 131_072, 16_000];
    auto m = model.toLower;
    foreach (i, n; needles) if (m.canFind(n)) return windows[i];
    return 0;
}

/// Does this provider error say the request did not fit the context window?
bool isContextOverflow(string error)
{
    auto e = error.toLower;
    foreach (n; ["context_length_exceeded", "maximum context length", "context length", "context window", "context size",
            "prompt is too long", "input is too long", "too many tokens", "reduce the length",
            "exceeds the available context"])
        if (e.canFind(n)) return true;
    return false;
}

private size_t firstCapture(string error, const string[] patterns) @trusted
{
    import std.regex : regex, matchFirst;
    foreach (p; patterns)
    {
        auto m = matchFirst(error, regex(p, "i"));
        if (!m.empty)
        {
            try return m[1].to!size_t;
            catch (Exception) {}
        }
    }
    return 0;
}

/// The window size stated in a context-overflow error, or 0.
size_t limitFromError(string error)
{
    return firstCapture(error, [`maximum context length is (\d+)`, `context size \((\d+) tokens\)`, `> ?(\d+) maximum`,
        `context window (?:of|is) (\d+)`, `limit of (\d+) tokens`]);
}

/// Does this error say `max_tokens` exceeded the model's output cap?
bool isOutputCapError(string error)
{
    auto e = error.toLower;
    foreach (n; ["maximum allowed number of output tokens", "maximum number of output tokens", "maximum output tokens",
            "max_output_tokens", "completion tokens", "max_tokens is too large", "max_tokens too large",
            "max_tokens must be less than or equal to", "max_tokens: "])
        if (e.canFind(n)) return true;
    return false;
}

/// The output cap stated in an output-cap rejection, or 0.
size_t outputCapFromError(string error)
{
    return firstCapture(error, [`max_tokens:\s*\d+\s*>\s*(\d+)`, `at most (\d+) completion tokens`,
        `output tokens(?: for [^ ]+)? is (\d+)`, `maximum output tokens (?:is|of) (\d+)`,
        `max_tokens must be less than or equal to (\d+)`, `maximum of (\d+) (?:completion|output) tokens`]);
}

/// Keep the head (2/3) and tail (1/3) of text longer than `maxChars`.
string clip(string text, size_t maxChars) @trusted
{
    import std.utf : toUTF32, toUTF8;
    if (text.length <= maxChars) return text;
    auto chars = text.toUTF32;
    if (chars.length <= maxChars) return text;
    return format("%s\n…[%s characters omitted]…\n%s", chars[0 .. maxChars * 2 / 3].toUTF8, chars.length - maxChars,
        chars[$ - maxChars / 3 .. $].toUTF8);
}

/// Shorten an oversized message in place. Returns whether it was clipped.
bool clipMessage(ref Message m, size_t maxTokens)
{
    if (textTokens(m.content) <= maxTokens) return false;
    m.content = clip(m.content, maxTokens * 4);
    return true;
}

/// Render messages as a plain transcript for the summarizer, newest content
/// kept when it exceeds `maxChars`. With `ids`, blocks carry `[#N]` labels.
string renderTranscript(const Message[] messages, size_t maxChars, bool ids) @trusted
{
    string[] blocks;
    foreach (ref m; messages)
    {
        string block;
        final switch (m.role)
        {
            case Role.system: continue;
            case Role.user: block = "USER:\n" ~ clip(m.content, 6_000); break;
            case Role.assistant:
                block = "ASSISTANT:";
                if (m.content.strip.length) block ~= "\n" ~ clip(m.content, 6_000);
                foreach (ref c; m.toolCalls)
                    block ~= format("\n[called %s(%s)]", c.name, clip(c.arguments.toString, 1_500));
                break;
            case Role.tool:
                block = format("TOOL %s (%s):\n%s", m.isError ? "failed" : "result", m.toolName.length ? m.toolName : "tool",
                    clip(m.content, 2_000));
                break;
        }
        if (ids && m.logLine) block = format("[#%s] %s", m.logLine, block);
        else if (ids && m.role == Role.user && (m.content.startsWith(summaryPrefix) || m.content.startsWith(smartSummaryPrefix)))
            block = "[earlier summary] " ~ block;
        blocks ~= block;
    }
    string[] kept;
    size_t total;
    foreach_reverse (b; blocks)
    {
        if (total + b.length > maxChars)
        {
            kept ~= "…[earlier messages omitted]…";
            break;
        }
        total += b.length + 2;
        kept ~= b;
    }
    string[] ordered;
    foreach_reverse (b; kept) ordered ~= b;
    return ordered.join("\n\n");
}

unittest
{
    assert(formatTokens(999) == "999" && formatTokens(12_345) == "12.3k" && formatTokens(123_456) == "123k"
        && formatTokens(1_234_567) == "1.23M");
    assert(windowForModel("claude-sonnet-4") == 200_000 && windowForModel("GPT-4o-mini") == 128_000);
    assert(windowForModel("kimi-k3") == 1_000_000 && windowForModel("llama") == 0);
    assert(summaryOutputBudget(1_000_000, 32_000) == summaryMaxTokens + summaryReasoningAllowance);
    assert(summaryOutputBudget(8_000, 32_000) == summaryMaxTokens, "a small window keeps the floor");
    assert(summaryOutputBudget(1_000_000, 1_000) == 1_000);
    assert(isContextOverflow("Error: context_length_exceeded") && !isContextOverflow("rate limited"));
    assert(limitFromError("This model's maximum context length is 131072 tokens") == 131_072);
    assert(limitFromError("request (140000 tokens) exceeds the context size (32768 tokens)") == 32_768);
    assert(limitFromError("prompt is too long: 210000 tokens > 200000 maximum") == 200_000);
    assert(limitFromError("too long") == 0);
    assert(isOutputCapError("max_tokens: 64000 > 32000, which is the maximum allowed") && !isOutputCapError("context window"));
    assert(outputCapFromError("max_tokens: 64000 > 32000, which is the maximum") == 32_000);
    assert(outputCapFromError("supports at most 16384 completion tokens") == 16_384);
    assert(outputCapFromError("max_tokens must be less than or equal to 4096") == 4_096);
    auto c = clip("abcdefghij", 6);
    assert(c == "abcd\n…[4 characters omitted]…\nij", c);
}

@trusted unittest // transcripts: roles, tool calls, ids, newest kept
{
    import std.json : parseJSON;
    import nano.llm : ToolCall;
    auto call = ToolCall.fromRaw("c1", "bash", `{"command":"ls"}`);
    auto a = Message.assistant("", [call]);
    a.logLine = 3;
    auto t = Message(Role.tool, "out");
    t.toolName = "bash";
    t.isError = true;
    auto ms = [Message.system("sys"), Message.user(summaryPrefix ~ "\nold"), Message.user("hi"), a, t];
    auto r = renderTranscript(ms, 10_000, true);
    assert(!r.canFind("sys") && r.canFind("[earlier summary] USER:") && r.canFind("USER:\nhi"), r);
    assert(r.canFind(`[#3] ASSISTANT:` ~ "\n" ~ `[called bash({"command":"ls"})]`) && r.canFind("TOOL failed (bash):\nout"), r);
    auto small = renderTranscript(ms, 40, false);
    assert(small.startsWith("…[earlier messages omitted]…") && small.canFind("TOOL failed"), small);
}
