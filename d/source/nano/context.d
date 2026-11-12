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

/// `512 B` / `14 KB` / `2.3 MB`.
string formatBytes(size_t bytes)
{
    if (bytes < 1024) return format("%s B", bytes);
    if (bytes < 1_048_576) return format("%.0f KB", bytes / 1024.0);
    return format("%.1f MB", bytes / 1_048_576.0);
}

/// Rough token count for text (about four characters per token).
size_t textTokens(string text) { return (text.length + 3) / 4; }

/// Tokens for one message: content, each tool call, framing overhead.
size_t messageTokens(const ref Message m)
{
    size_t calls;
    foreach (ref c; m.toolCalls) calls += textTokens(c.name) + textTokens(c.arguments.toString) + 4;
    return textTokens(m.content) + calls + 4;
}

/// Token estimate for one image from its dimensions (Anthropic's ~w*h/750),
/// capped at the largest image `read_file` sends.
size_t imageTokens(const ref imported!"nano.attachment".Attachment a)
{
    import nano.attachment : MAX_DIMENSION;
    enum size_t max = (cast(size_t) MAX_DIMENSION * MAX_DIMENSION + 749) / 750;
    auto e = (cast(size_t) a.width * a.height + 749) / 750;
    return e < 1 ? 1 : e > max ? max : e;
}

/// Tokens for `ms`, mirroring the wire plan: the newest `maxImages`
/// attachments count as images, the rest as their placeholder text. (Rust
/// also leaves out of the quota attachments whose stored file is gone; D
/// assumes they are all present.)
size_t messagesTokens(const Message[] ms, size_t maxImages = 0)
{
    size_t total, n;
    foreach (ref m; ms) total += m.attachments.length;
    auto omitted = total > maxImages ? total - maxImages : 0;
    foreach (ref m; ms)
    {
        n += messageTokens(m);
        foreach (ref a; m.attachments)
        {
            if (omitted) { omitted--; n += textTokens(a.placeholder); }
            else n += imageTokens(a);
        }
    }
    return n;
}

unittest
{
    import nano.llm : Message, Role, Attachment;
    auto m = Message(Role.tool, "x");
    m.attachments = [Attachment("image/png", "/a.png", "", 750, 750), Attachment("image/png", "/b.png", "", 75, 10)];
    auto base = messageTokens(m);
    // One image slot: the newest is an image (1 token), the older a placeholder.
    assert(messagesTokens([m], 1) == base + textTokens(m.attachments[0].placeholder) + 1);
    assert(messagesTokens([m], 2) == base + 750 + 1);
    assert(messagesTokens([m]) == base + textTokens(m.attachments[0].placeholder) + textTokens(m.attachments[1].placeholder));
}

/// Context window by model family, for models whose provider config has none.
/// `max_tokens` when none is configured and the endpoint published no cap
/// (issue #114): large enough for whole-file writes, still explicit.
enum long defaultMaxOutputTokens = 32_768;

/// A known output cap for a model whose `/models` doesn't publish one
/// (most specific needle first).
size_t outputLimitForModel(string model)
{
    import std.uni : toLower;
    import std.algorithm : canFind;
    auto m = model.toLower;
    static immutable needles = ["gpt-4o", "gpt-4-turbo", "gpt-3.5"];
    static immutable size_t[] limits = [16_384, 4_096, 4_096];
    foreach (i, n; needles) if (m.canFind(n)) return limits[i];
    return 0;
}

unittest
{
    assert(outputLimitForModel("GPT-4o-mini") == 16_384 && outputLimitForModel("gpt-4-turbo") == 4_096);
    assert(outputLimitForModel("claude") == 0);
}

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

private size_t firstCapture(string error, const string[] patterns)
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

/// Keep the head (2/3) and tail (1/3) of text longer than `maxChars`. The
/// omission marker is charged against the allowance, so the result never
/// exceeds `maxChars` (Rust #161).
string clip(string text, size_t maxChars)
{
    import std.utf : toUTF32, toUTF8;
    if (text.length <= maxChars) return text;
    auto chars = text.toUTF32;
    if (chars.length <= maxChars) return text;
    auto marker = format("\n…[%s characters omitted]…\n", chars.length - maxChars);
    auto markerLen = marker.toUTF32.length;
    // An allowance smaller than the marker itself: a bare head cut.
    if (markerLen >= maxChars) return chars[0 .. maxChars].toUTF8;
    auto budget = maxChars - markerLen;
    return chars[0 .. budget * 2 / 3].toUTF8 ~ marker ~ chars[$ - budget / 3 .. $].toUTF8;
}

/// Maximum error lines pinned when clipping a tool result (issue #67).
enum clipErrorLines = 20;
/// Context lines kept around each pinned error line.
enum clipErrorContext = 1;

/// A line worth pinning when a long tool result is clipped (`error`,
/// `panic`, `failed`, `traceback`, `exception`); `warning:` lines never are,
/// even when they name an error, so warnings can't exhaust the pins.
bool isErrorLine(string line)
{
    import std.string : stripLeft;
    auto lower = line.stripLeft.toLower;
    if (lower.startsWith("warning:")) return false;
    return lower.canFind("error") || lower.canFind("panic") || lower.canFind("failed")
        || lower.canFind("traceback") || lower.canFind("exception");
}

/// Clip a tool result for the compaction transcript like `clip`, but also
/// pin up to `clipErrorLines` error lines from the omitted middle, each with
/// `clipErrorContext` lines of context (port of Rust `clip_tool_result`, #161).
///
/// The result is a selection of whole lines of the original (in order, each
/// at most once) with every omitted run replaced by a gap marker. Each line
/// is admitted by one charge against `maxChars` (its characters plus any
/// change in the number of gaps), so the budget always holds. Order: a small
/// head and tail floor, error lines not already kept, their context, then the
/// rest of the allowance grows the head (2/3) and tail.
string clipToolResult(string text, size_t maxChars)
{
    import std.utf : toUTF32, toUTF8;
    auto all = text.toUTF32;
    auto total = all.length;
    if (total <= maxChars) return text;
    dstring[] lines;
    {
        size_t start;
        foreach (i, c; all)
            if (c == '\n') { lines ~= all[start .. i + 1]; start = i + 1; }
        if (start < all.length) lines ~= all[start .. $];
    }
    dstring bareD(size_t i)
    {
        auto l = lines[i];
        while (l.length && l[$ - 1] == '\n') l = l[0 .. $ - 1];
        while (l.length && l[$ - 1] == '\r') l = l[0 .. $ - 1];
        return l;
    }
    string bare(size_t i) { return bareD(i).toUTF8; }
    size_t[] errorLines;
    foreach (i; 0 .. lines.length) if (isErrorLine(bare(i))) errorLines ~= i;
    auto marker = format("…[%s characters omitted; error lines pinned]…\n", total - maxChars);
    auto markerLen = marker.toUTF32.length;
    if (!errorLines.length || maxChars < markerLen + 64) return clip(text, maxChars);
    enum long gap = 2; // "…\n" for every gap after the first
    auto n = lines.length;
    auto lens = new size_t[n];
    foreach (i, l; lines) lens[i] = l.length;
    auto kept = new bool[n];
    auto clipped = new string[n];
    auto hasClip = new bool[n];
    size_t used = markerLen; // nothing kept: one gap, rendered as the full marker
    long cost(size_t i, size_t len)
    {
        bool left = i > 0 && !kept[i - 1];
        bool right = i + 1 < n && !kept[i + 1];
        return cast(long) len + (cast(long) left + cast(long) right - 1) * gap;
    }
    bool tryKeep(size_t i)
    {
        if (kept[i]) return true;
        auto c = cost(i, lens[i]);
        if (cast(long) used + c > cast(long) maxChars) return false;
        used = cast(size_t)(cast(long) used + c);
        kept[i] = true;
        return true;
    }
    size_t sumLens(size_t a, size_t b) { size_t t; foreach (k; a .. b) t += lens[k]; return t; }
    // 1. Head and tail floors (whole lines), so both ends always show.
    auto floor = (maxChars - markerLen) / 6;
    size_t headEnd;
    while (headEnd < n && sumLens(0, headEnd + 1) <= floor && tryKeep(headEnd)) ++headEnd;
    size_t tailStart = n;
    while (tailStart > headEnd && sumLens(tailStart - 1, n) <= floor && tryKeep(tailStart - 1)) --tailStart;
    // 1b. An oversized boundary line keeps a budgeted excerpt (head: prefix;
    //     tail: suffix), so the opening command and the exit status survive.
    string excerpt(dstring s, size_t keep, bool fromEnd)
    {
        auto k = min(keep, s.length);
        return fromEnd ? "…" ~ s[$ - k .. $].toUTF8 : s[0 .. k].toUTF8 ~ "…";
    }
    size_t endsNl(size_t i) { return lines[i].length && lines[i][$ - 1] == '\n' ? 1 : 0; }
    void admitClipped(size_t i, string s, long base)
    {
        auto l = cast(long) s.toUTF32.length;
        if (cast(long) used + base + l <= cast(long) maxChars)
        {
            used = cast(size_t)(cast(long) used + base + l);
            kept[i] = true;
            clipped[i] = s;
            hasClip[i] = true;
        }
    }
    if (headEnd == 0 && n > 1 && floor > 8 && !isErrorLine(bare(0)))
    {
        auto base = cost(0, 0);
        auto room = min(floor, cast(size_t) max(0L, cast(long) maxChars - cast(long) used - base));
        if (room > 8)
        {
            admitClipped(0, excerpt(bareD(0), room - 2, false) ~ (endsNl(0) ? "\n" : ""), base);
            if (kept[0]) headEnd = 1;
        }
    }
    if (tailStart == n && n > 1 && headEnd < n && !kept[n - 1] && floor > 8 && !isErrorLine(bare(n - 1)))
    {
        auto i = n - 1;
        auto base = cost(i, 0);
        auto room = min(floor, cast(size_t) max(0L, cast(long) maxChars - cast(long) used - base));
        if (room > 8)
        {
            auto nl = endsNl(i);
            admitClipped(i, excerpt(bareD(i), room - 1 - nl, true) ~ (nl ? "\n" : ""), base);
            if (kept[i]) tailStart = i;
        }
    }
    // 2. Pin error lines not already kept, whole while they fit; only the
    //    first pin may be budget-clipped.
    size_t[] pinned;
    foreach (i; errorLines)
    {
        if (kept[i]) continue; // already retained: no pin, no duplicate
        if (pinned.length == clipErrorLines) break;
        if (tryKeep(i)) { pinned ~= i; continue; }
        if (!pinned.length)
        {
            auto base = cost(i, 0);
            auto room = cast(size_t) max(0L, cast(long) maxChars - cast(long) used - base - 1);
            admitClipped(i, clip(bare(i), room) ~ "\n", base);
            if (kept[i]) pinned ~= i;
        }
        break; // a later error that cannot fit whole stops pinning
    }
    // 3. Context around each pin, whole lines only, while they fit; a context
    //    line that is itself an unpinned error is not admitted.
    foreach (i; pinned)
    {
        auto lo = i >= clipErrorContext ? i - clipErrorContext : 0;
        auto hi = min(i + clipErrorContext, n - 1);
        foreach (j; lo .. hi + 1)
            if (!kept[j] && !isErrorLine(bare(j))) tryKeep(j);
    }
    // 4. Grow the head (2/3 of what is left) then the tail, then the head again.
    auto spare = maxChars - used;
    auto headTarget = used + spare * 2 / 3;
    while (headEnd < n && !kept[headEnd])
    {
        if (cast(long) used + cost(headEnd, lens[headEnd]) > cast(long) headTarget) break;
        tryKeep(headEnd);
        ++headEnd;
    }
    while (headEnd < n && kept[headEnd]) ++headEnd;
    while (tailStart > headEnd && (kept[tailStart - 1] || tryKeep(tailStart - 1))) --tailStart;
    while (headEnd < tailStart && (kept[headEnd] || tryKeep(headEnd))) ++headEnd;
    // Render: kept lines in order, the first gap as the full marker.
    import std.array : appender;
    auto out_ = appender!string;
    bool firstGap = true, inGap;
    foreach (i; 0 .. n)
    {
        if (kept[i])
        {
            inGap = false;
            out_ ~= hasClip[i] ? clipped[i] : lines[i].toUTF8;
        }
        else if (!inGap)
        {
            inGap = true;
            out_ ~= firstGap ? marker : "…\n";
            firstGap = false;
        }
    }
    return out_[];
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
string renderTranscript(const Message[] messages, size_t maxChars, bool ids)
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
                    clipToolResult(m.content, 2_000));
                // The summary request carries no images; note each one seen.
                foreach (ref a; m.attachments) block ~= "\n" ~ a.placeholder;
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
    assert(clip("abcdefghij", 6) == "abcdef", "an allowance under the marker: a bare head cut");
}

// rust: context.rs::transcript_keeps_the_newest_messages
unittest // transcripts: roles, tool calls, ids, newest kept
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

version (unittest)
{
    private size_t nchars(string s) { import std.utf : count; return s.count; }
    private size_t occurrences(string hay, string needle) { import std.algorithm : count; return hay.count(needle); }
}

// Rust #161: error lines pinned when a tool result is clipped for compaction.
// rust: context.rs::clipped_tool_result_pins_an_error_line_from_the_middle
// rust: context.rs::clipped_tool_result_without_error_lines_clips_as_before
// rust: context.rs::clipped_tool_result_never_exceeds_the_budget
// rust: context.rs::clipped_tool_result_pins_respect_cumulative_budget
// rust: context.rs::clipped_tool_result_shrunk_window_does_not_drop_later_windows
// rust: context.rs::clipped_tool_result_keeps_context_and_tail
// rust: context.rs::error_line_detection_is_small_and_fixed
// rust: context.rs::clipped_tool_result_ignores_warnings_that_name_errors
// rust: context.rs::clip_stays_within_budget_marker_included
// rust: context.rs::clip_stays_within_a_sub_marker_budget
unittest
{
    import std.array : replicate;
    import std.string : splitLines;
    // A middle error in a 50k result survives the transcript.
    {
        string content;
        while (content.length < 30_000) content ~= "   Compiling lease-0.1.0 (/work/lease)\n";
        content ~= "error[E0599]: no method named `refresh_lease_v42_fast` found for struct `TokenCache`\n";
        while (content.length < 50_000) content ~= "test lease::tests::case_123 ... ok\n";
        auto text = renderTranscript([Message.toolResult("call_1", "bash", content)], 100_000, false);
        assert(text.canFind("error[E0599]: no method named `refresh_lease_v42_fast` found for struct `TokenCache`"), text);
        assert(text.canFind("error lines pinned"), text);
    }
    // No error lines: plain clip.
    {
        auto content = "x".replicate(50_000);
        auto text = renderTranscript([Message.toolResult("call_1", "bash", content)], 100_000, false);
        assert(text.canFind("characters omitted") && !text.canFind("error lines pinned"));
        assert(text == "TOOL result (bash):\n" ~ clip(content, 2_000));
    }
    // Many errors: pins capped, budget holds.
    {
        string content;
        foreach (i; 0 .. 200)
        {
            content ~= format("error: failure number %s in the middle of the log\n", i);
            content ~= "padding line to spread the diagnostics out across the log\n".replicate(20);
        }
        auto text = renderTranscript([Message.toolResult("call_1", "bash", content)], 1_000_000, false);
        auto body_ = text["TOOL result (bash):\n".length .. $];
        assert(nchars(body_) <= 2_000);
        assert(occurrences(body_, "error: failure number") <= clipErrorLines + 4);
        auto buried = "ordinary build output line\n".replicate(200) ~ "\ncompiling crate-a\nerror: boom\nnote: see above\n"
            ~ "test crate::case ... ok\n".replicate(200);
        auto c = clipToolResult(buried, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error: boom") && c.canFind("note: see above"), c);
    }
    // Many small windows: cumulative budget, tail kept.
    {
        auto content = "head line\n".replicate(300);
        foreach (i; 0 .. 20)
        {
            content ~= format("ctx before %s\nerror: separated failure %s %s\nctx after %s\n", i, i, "x".replicate(40), i);
            content ~= "plain padding\n".replicate(30);
        }
        content ~= "FINAL TAIL MARKER\n";
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error lines pinned") && c.canFind("FINAL TAIL MARKER")
            && c.canFind("separated failure 0 "), c);
    }
    // A shrunk first window doesn't drop a later one.
    {
        auto content = "head\n".replicate(400) ~ "\n" ~ "c".replicate(1_200) ~ "\nerror: first failure\n" ~ "d".replicate(1_200)
            ~ "\n" ~ "pad\n".replicate(50) ~ "\nnote: a\nerror: second failure\nnote: b\n" ~ "tail\n".replicate(400);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error: first failure") && c.canFind("error: second failure"), c);
    }
    // Context and tail.
    {
        auto content = "ordinary build output line that nobody cares about\n".replicate(400)
            ~ "  --> src/lease.rs:41:9\n" ~ "error[E0308]: mismatched types: expected `Lease`, found `()`\n"
            ~ "  = note: this error originates in the macro\n" ~ "more ordinary output after the failure\n".replicate(400)
            ~ "error: could not compile `lease` due to 1 previous error\n" ~ "exit status: 101\n";
        auto c = clipToolResult(content, 2_000);
        assert(c.canFind("error[E0308]: mismatched types") && c.canFind("--> src/lease.rs:41:9")
            && c.canFind("= note: this error originates") && c.canFind("exit status: 101") && nchars(c) <= 2_000, c);
    }
    // Detection.
    assert(isErrorLine("error[E0308]: mismatched types"));
    assert(isErrorLine("thread 'main' panicked at src/store.rs:10"));
    assert(isErrorLine("test result: FAILED. 3 passed; 2 failed"));
    assert(isErrorLine("Traceback (most recent call last):"));
    assert(isErrorLine("java.lang.IllegalStateException: boom"));
    assert(!isErrorLine("warning: unused variable: `tmp`"));
    assert(!isErrorLine("warning: unused import: std::error::Error"));
    assert(!isErrorLine("  warning: previous error occurred here"));
    assert(!isErrorLine("WARNING: the build failed to cache"));
    assert(!isErrorLine("   Compiling lease-0.1.0 (/work/lease)"));
    assert(!isErrorLine("test lease::tests::case_123 ... ok"));
    // Warnings naming errors aren't pinned.
    {
        string content;
        foreach (i; 0 .. 40) content ~= format("warning: unused import: std::error::Error (number %s)\n", i);
        content ~= "error[E0308]: mismatched types: expected `Lease`, found `()`\n";
        content ~= "ordinary build output line that nobody cares about\n".replicate(400);
        auto c = clipToolResult(content, 2_000);
        assert(c.canFind("error[E0308]: mismatched types"), c);
        auto ls = c.splitLines;
        size_t k;
        while (k < ls.length && !ls[k].canFind("error[E0308]")) ++k;
        foreach (l; ls[k .. min(k + 3, $)]) assert(!l.canFind("warning:"), c);
    }
    // clip holds its budget, marker included, and below the marker length.
    foreach (m; [40, 100, 2_000])
    {
        auto c = clip("x".replicate(10_000), m);
        assert(nchars(c) <= m && c.canFind("characters omitted"), c);
    }
    assert(nchars(clip("line of build output\n".replicate(500), 300)) <= 300);
    foreach (m; [0, 1, 8, 20, 28]) assert(nchars(clip("x".replicate(10_000), m)) <= m);
    {
        auto c = clip("x".replicate(10_000), 40);
        assert(c.canFind("characters omitted") && nchars(c) <= 40, c);
    }
}

// rust: context.rs::clipped_tool_result_clips_context_before_the_error_line
// rust: context.rs::clipped_tool_result_keeps_every_error_of_a_merged_window
// rust: context.rs::clipped_tool_result_does_not_pin_errors_the_head_already_retains
// rust: context.rs::clipped_tool_result_does_not_pin_an_error_the_tail_already_retains
// rust: context.rs::clipped_tool_result_borrows_head_tail_allowance_for_a_long_error_line
// rust: context.rs::clipped_tool_result_keeps_tail_excerpt_when_all_preceding_lines_fit
// rust: context.rs::clipped_tool_result_keeps_a_budgeted_excerpt_of_a_context_line_at_the_budget_edge
// rust: context.rs::clipped_tool_result_drops_multi_context_that_cannot_fit_but_keeps_the_error
unittest
{
    import std.array : replicate;
    import std.string : splitLines, indexOf;
    {
        auto pad = "x".replicate(1_200);
        auto content = "ordinary build output line\n".replicate(200) ~ pad
            ~ "\nerror[E0308]: mismatched types: expected `Lease`, found `()`\n" ~ pad ~ "\n"
            ~ "more ordinary output after the failure\n".replicate(200);
        auto c = clipToolResult(content, 2_000);
        assert(c.canFind("error[E0308]: mismatched types: expected `Lease`, found `()`") && nchars(c) <= 2_000, c);
    }
    {
        auto pad = "y".replicate(900);
        auto content = "ordinary build output line\n".replicate(200) ~ pad ~ "\nerror[E0308]: first failure here\n" ~ pad
            ~ "\nerror[E0599]: second failure here\n" ~ pad ~ "\n" ~ "more ordinary output after the failure\n".replicate(200);
        auto c = clipToolResult(content, 2_000);
        assert(c.canFind("error[E0308]: first failure here") && c.canFind("error[E0599]: second failure here") && nchars(c) <= 2_000, c);
    }
    {
        string content;
        foreach (i; 0 .. 20) content ~= format("error: NN %s\n", i);
        content ~= "ordinary build output line that pads the log out\n".replicate(300);
        content ~= "error: buried middle diagnostic\n";
        content ~= "more ordinary output after the failure\n".replicate(300);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error: buried middle diagnostic"), c);
        assert(occurrences(c, "error: NN 0\n") == 1, c);
    }
    {
        auto content = "ordinary build output line that pads the log out\n".replicate(300) ~ "error: buried middle diagnostic\n"
            ~ "more ordinary output after the failure\n".replicate(300);
        foreach (i; 0 .. 5) content ~= format("error: final failure %s\n", i);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error: buried middle diagnostic"), c);
        assert(occurrences(c, "error: final failure 4") == 1, c);
    }
    {
        enum diagnostic = "MID-LINE-DIAGNOSTIC-THAT-MUST-SURVIVE";
        auto content = "ordinary build output line that pads the log out\n".replicate(300)
            ~ format("error: %s %s %s\n", "x".replicate(600), diagnostic, "y".replicate(600))
            ~ "more ordinary output after the failure\n".replicate(300);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind(diagnostic), c);
        foreach (l; c.splitLines) if (l.canFind(diagnostic)) assert(!l.canFind("characters omitted"), l);
    }
    {
        auto content = "cargo test\nerror: boom\n" ~ "x".replicate(2500) ~ "exit status: 101";
        auto c = clipToolResult(content, 2000);
        assert(nchars(c) <= 2000 && c.startsWith("cargo test\n") && c.canFind("exit status: 101"), c);
    }
    {
        enum error = "error: boom happened here";
        auto content = error ~ "\n" ~ "c".replicate(260) ~ "\n" ~ "tail line of test output\n".replicate(40);
        auto c = clipToolResult(content, 200);
        assert(nchars(c) <= 200 && c.canFind(error), c);
        if (!c.startsWith(error ~ "\n"))
        {
            auto at = c.indexOf("error lines pinned]…\n");
            assert(at >= 0, c);
            auto pinned = c[at + "error lines pinned]…\n".length .. $];
            auto end = pinned.indexOf("\n…\n");
            auto window = (end >= 0 ? pinned[0 .. end] : pinned).splitLines;
            assert(window.canFind!(l => l.canFind("characters omitted]…")), c);
            assert(window.canFind!(l => l.canFind(error)), c);
        }
    }
    {
        enum error = "error[E0308]: mismatched types";
        auto pad = "c".replicate(1_500);
        auto content = "head\n".replicate(600) ~ pad ~ "\n" ~ error ~ "\n" ~ pad ~ "\n" ~ "tail\n".replicate(600);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind(error), c);
        auto ls = c.splitLines;
        size_t k;
        while (k < ls.length && !ls[k].canFind("error lines pinned")) ++k;
        assert(ls[min(k + 1, $) .. min(k + 4, $)].canFind!(l => l.canFind(error)), c);
    }
}

// rust: context.rs::clipped_tool_result_window_ends_before_the_first_unselected_error
// rust: context.rs::clipped_tool_result_keeps_complete_diagnostics_before_clipping
// rust: context.rs::clipped_tool_result_budget_clip_keeps_the_end_of_an_oversized_error_line
// rust: context.rs::clipped_tool_result_long_errors_at_both_ends_stay_within_budget
// rust: context.rs::clipped_tool_result_handles_crlf_offsets
// rust: context.rs::clipped_tool_result_keeps_head_errors_when_a_long_pin_needs_room
// rust: context.rs::clipped_tool_result_never_duplicates_a_line_and_holds_the_budget
// rust: context.rs::clipped_tool_result_keeps_excerpts_of_oversized_boundary_lines
unittest
{
    import std.array : replicate;
    import std.algorithm : endsWith;
    {
        auto content = "head\n".replicate(300);
        foreach (i; 0 .. clipErrorLines) content ~= format("error: selected failure %s\nctx\n", i);
        content ~= format("error: unselected huge %s\n", "u".replicate(5_000));
        content ~= "tail\n".replicate(300);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error: selected failure 0") && !c.canFind("uuuu") && c.canFind("error lines pinned"), c);
    }
    {
        auto content = "head\n".replicate(300);
        foreach (i; 0 .. 20) content ~= format("error: adjacent failure %02d %s\n", i, "e".replicate(50));
        content ~= "tail\n".replicate(300);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error: adjacent failure 00 "), c);
        size_t keptN;
        foreach (i; 0 .. 20) if (c.canFind(format("error: adjacent failure %02d ", i))) ++keptN;
        assert(keptN >= 10, c);
        assert(c.canFind("error: adjacent failure 00 " ~ "e".replicate(50)), c);
    }
    {
        auto content = "head\n".replicate(300) ~ format("error: %s TAIL-DIAGNOSTIC-AT-END\n", "x".replicate(3_000)) ~ "tail\n".replicate(300);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("TAIL-DIAGNOSTIC-AT-END"), c);
    }
    {
        string long_(string tag) { return format("error: %s %s\n", tag, "z".replicate(700)); }
        auto content = "intro\n".replicate(40) ~ long_("HEAD-END") ~ "pad line\n".replicate(400) ~ "error: buried pin\n"
            ~ "pad line\n".replicate(400) ~ long_("TAIL-START") ~ "outro\n".replicate(40);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && c.canFind("error: buried pin"), c);
    }
    {
        auto content = "ordinary build output line\r\n".replicate(300) ~ "error: crlf buried diagnostic\r\n" ~ "more output after\r\n".replicate(300);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && occurrences(c, "error: crlf buried diagnostic") == 1, c);
    }
    {
        auto content = "intro\n".replicate(30) ~ "error: early diagnostic\n" ~ "pad line\n".replicate(400)
            ~ format("error: long middle %s\n", "m".replicate(1_300)) ~ "pad line\n".replicate(400);
        auto c = clipToolResult(content, 2_000);
        assert(nchars(c) <= 2_000 && occurrences(c, "error: early diagnostic") == 1 && occurrences(c, "error: long middle") == 1, c);
    }
    foreach (budget; [300, 700, 2_000])
        foreach (pad; [0, 5, 37, 120])
            foreach (errLen; [10, 400, 900])
            {
                auto content = "h\n".replicate(pad);
                foreach (k; 0 .. 4) content ~= format("error: E%s %s\n", k, "q".replicate(errLen));
                content ~= "m\n".replicate(500);
                foreach (k; 4 .. 8) content ~= format("error: E%s %s\n", k, "q".replicate(errLen));
                content ~= "t\n".replicate(pad);
                auto c = clipToolResult(content, budget);
                assert(nchars(c) <= budget, format("%s/%s/%s: %s", budget, pad, errLen, nchars(c)));
                foreach (k; 0 .. 8) assert(occurrences(c, format("error: E%s ", k)) <= 1, c);
            }
    {
        auto first = "$ cargo test " ~ "a".replicate(2500);
        auto last = "b".replicate(2500) ~ " exit status: 101";
        auto out_ = clipToolResult(first ~ "\nerror: boom\n" ~ last, 2000);
        assert(nchars(out_) <= 2000 && out_.startsWith("$ cargo test") && out_.endsWith("exit status: 101"), out_);
        assert(occurrences(out_, "error: boom") == 1);
        out_ = clipToolResult(first ~ "\nerror: boom\n" ~ last ~ "\n", 2000);
        assert(nchars(out_) <= 2000 && out_.startsWith("$ cargo test") && out_.endsWith("exit status: 101\n"), out_);
    }
}
