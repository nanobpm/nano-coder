/// Extract compaction: a summary built from the transcript in code, with no
/// model call (issue #273, after pi-vcc).
///
/// Smart compaction already pins the user's requests verbatim and lets the
/// agent read any original message by its `#N` ID, so the summary's job is
/// mostly to say *where* to look. This one is deterministic and instant: it
/// lists the files the agent touched, the commands it ran and how they
/// ended, error lines and links, and the agent's last conclusions, each
/// with the `#N` of its source. The caller adds the smart-summary prefix,
/// the history note, the plan and the pinned requests, as for a model
/// summary.
module nano.extract;

@safe:
pure:

import std.algorithm : canFind, startsWith, endsWith, min;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.string : indexOf, lineSplitter, strip, stripLeft, toLower;
import nano.context : clip, isErrorLine, isSummaryMessage;
import nano.arith : saturatingSub;
import nano.llm : Message, Role;

/// Caps per section, newest kept: enough to point at the work without the
/// summary growing with session length.
enum extractMaxFiles = 40;
enum extractMaxCommands = 30;
enum extractMaxSignals = 40;
enum extractMaxConclusions = 3;
/// The earlier summary carried forward is clipped to this many characters,
/// so repeated compactions plateau instead of nesting.
enum extractEarlierChars = 6_000;

private struct Entry
{
    string key;
    string text;
}

/// Keeps the last occurrence of each key, in order of last occurrence.
private struct Recent
{
pure:
    Entry[] items;

    void put(string key, string text)
    {
        foreach (i, ref e; items)
            if (e.key == key)
            {
                items = items[0 .. i] ~ items[i + 1 .. $];
                break;
            }
        items ~= Entry(key, text);
    }

    string[] last(size_t n) const
    {
        string[] out_;
        foreach (ref e; items[saturatingSub(items.length, n) .. $]) out_ ~= e.text;
        return out_;
    }
}

private string str(JSONValue v, string key)
{
    if (v.type != JSONType.object) return null;
    auto p = key in v;
    return p !is null && p.type == JSONType.string ? p.str : null;
}

private string oneLine(string s, size_t maxChars)
{
    import std.array : replace;
    return clip(s.strip.replace("\r", "").replace("\n", " ⏎ "), maxChars);
}

private string at(ulong line) { return line ? format(" (#%s)", line) : ""; }

/// Paths a patch adds, updates, deletes or moves (`*** Update File: x`).
private string[] patchPaths(string patch)
{
    string[] paths;
    foreach (l; patch.lineSplitter)
        foreach (p; ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move File: "])
            if (l.startsWith(p)) paths ~= l[p.length .. $].strip;
    return paths;
}

/// URLs in `text`, trailing punctuation trimmed.
private string[] urls(string text)
{
    string[] out_;
    size_t i;
    while (i < text.length)
    {
        auto rest = text[i .. $];
        auto h = rest.indexOf("http");
        if (h < 0) break;
        auto s = rest[h .. $];
        if (!(s.startsWith("https://") || s.startsWith("http://"))) { i += h + 4; continue; }
        size_t e;
        while (e < s.length && !" \t\n\r\"'<>()[]{}`".canFind(s[e])) e++;
        auto u = s[0 .. e];
        while (u.length && ".,;:!?".canFind(u[$ - 1])) u = u[0 .. $ - 1];
        if (u.length > "https://".length) out_ ~= u;
        i += h + (e ? e : 1);
    }
    return out_;
}

/// The body of an earlier summary, without the note, plan and pinned
/// requests compaction appended (they are rebuilt every time).
private string earlierBody(string content)
{
    auto nl = content.indexOf('\n');
    auto body_ = nl < 0 ? "" : content[nl + 1 .. $];
    foreach (marker; ["\n\n[This summary covers", "\n\n[Your plan", "\n\n[The user's requests"])
    {
        auto k = body_.indexOf(marker);
        if (k >= 0) body_ = body_[0 .. k];
    }
    return body_.strip;
}

/// First line of every extract summary body; marks one to merge, not nest.
enum string extractHeader = "Built from the transcript without a model call: it lists where things are, not what they "
    ~ "say. Read any (#N) with history_read for the exact text.";

private enum filesTitle = "## Files touched (newest last)", commandsTitle = "## Commands (newest last)",
    signalsTitle = "## Errors and links", wordsTitle = "## The agent's last words before compacting",
    earlierTitle = "## Earlier summary (abridged)";

/// The summary body for `messages` (the span being compacted).
string extractSummary(const Message[] messages)
{
    string earlier;
    Recent files, commands, signals;
    string[] conclusions;
    // An earlier extract summary is merged entry by entry (older first), so
    // repeated compactions keep each section capped instead of nesting.
    void merge(string body_)
    {
        string title;
        string[] last;
        foreach (l; body_.lineSplitter)
        {
            if (l.startsWith("## ")) { title = l; continue; }
            if (!l.startsWith("- ")) continue;
            auto item = l[2 .. $];
            if (title == filesTitle)
            {
                auto c = item.indexOf(": ");
                files.put(c < 0 ? item : item[0 .. c], item);
            }
            else if (title == commandsTitle) commands.put(item, item);
            else if (title == signalsTitle) signals.put(item, item);
            else if (title == wordsTitle) last ~= item;
        }
        conclusions = last;
        // An earlier summary's own abridged text (from a model summary
        // before a switch to extract) is carried as is.
        auto k = body_.indexOf(earlierTitle ~ "\n");
        if (k >= 0)
        {
            auto rest = body_[k + earlierTitle.length + 1 .. $];
            auto e = rest.indexOf("\n\n## ");
            earlier = e < 0 ? rest : rest[0 .. e];
        }
    }
    // Tool name and arguments by call id, to describe each result.
    string[string] callName, callCommand;

    foreach (ref m; messages)
    {
        final switch (m.role)
        {
            case Role.system:
                break;
            case Role.user:
                // The user's own words are pinned verbatim by the caller; a
                // folded earlier summary is carried forward, clipped.
                if (isSummaryMessage(m))
                {
                    auto b = earlierBody(m.content);
                    if (b.startsWith(extractHeader)) merge(b);
                    else earlier = b;
                }
                foreach (u; urls(m.content)) signals.put(u, u ~ at(m.logLine));
                break;
            case Role.assistant:
                foreach (ref c; m.toolCalls)
                {
                    callName[c.id] = c.name;
                    auto args = c.arguments;
                    switch (c.name)
                    {
                        case "bash":
                            callCommand[c.id] = str(args, "command");
                            break;
                        case "read_file":
                            if (auto p = str(args, "path")) files.put(p, format("%s: read%s", p, at(m.logLine)));
                            break;
                        case "write_file":
                        case "edit_file":
                            if (auto p = str(args, "path"))
                                files.put(p, format("%s: %s%s", p, c.name == "write_file" ? "written" : "edited", at(m.logLine)));
                            break;
                        case "apply_patch":
                            foreach (p; patchPaths(str(args, "patch")))
                                files.put(p, format("%s: patched%s", p, at(m.logLine)));
                            break;
                        default:
                            break;
                    }
                }
                if (m.content.strip.length)
                {
                    foreach (u; urls(m.content)) signals.put(u, u ~ at(m.logLine));
                    conclusions ~= oneLine(m.content, 1_500) ~ at(m.logLine);
                    if (conclusions.length > extractMaxConclusions) conclusions = conclusions[1 .. $];
                }
                break;
            case Role.tool:
                auto name = m.toolCallId in callName;
                string firstError;
                size_t errors;
                foreach (l; m.content.lineSplitter)
                {
                    if (!isErrorLine(l)) continue;
                    auto t = oneLine(l, 240);
                    if (!t.length) continue;
                    if (!firstError.length) firstError = t;
                    if (errors++ < 3) signals.put(t, t ~ at(m.logLine));
                }
                foreach (u; urls(m.content)) signals.put(u, u ~ at(m.logLine));
                auto cmd = m.toolCallId in callCommand;
                if (name !is null && *name == "bash" && cmd !is null && (*cmd).length)
                {
                    auto outcome = m.isError ? "failed" : "ok";
                    if (m.isError && firstError.length) outcome ~= ": " ~ firstError;
                    commands.put(*cmd ~ "#" ~ m.toolCallId, format("`%s` → %s%s", oneLine(*cmd, 300), outcome, at(m.logLine)));
                }
                else if (m.isError)
                    signals.put(m.toolCallId, format("%s failed: %s%s", name is null ? "tool" : *name,
                        firstError.length ? firstError : oneLine(m.content, 240), at(m.logLine)));
                break;
        }
    }

    string[] parts = [extractHeader];
    void section(string title, const string[] lines)
    {
        if (lines.length) parts ~= title ~ "\n" ~ lines.join("\n");
    }
    if (earlier.length) parts ~= earlierTitle ~ "\n" ~ clip(earlier, extractEarlierChars);
    string[] bullets(const string[] xs)
    {
        string[] o;
        foreach (x; xs) o ~= "- " ~ x;
        return o;
    }
    section(filesTitle, bullets(files.last(extractMaxFiles)));
    section(commandsTitle, bullets(commands.last(extractMaxCommands)));
    section(signalsTitle, bullets(signals.last(extractMaxSignals)));
    section(wordsTitle, bullets(conclusions));
    return parts.join("\n\n");
}

unittest // sections, #N citations, newest kept, earlier summary folded
{
    import nano.context : smartSummaryPrefix;
    import nano.llm : ToolCall;
    Message at_(Message m, ulong line) { m.logLine = line; return m; }
    Message tool(string id, string name, string content, bool err, ulong line)
    {
        auto t = Message(Role.tool, content);
        t.toolCallId = id;
        t.toolName = name;
        t.isError = err;
        t.logLine = line;
        return t;
    }
    auto ms = [
        Message.system("sys"),
        at_(Message.user(smartSummaryPrefix ~ "\nold facts\n\n[This summary covers messages #1–#9. ...]"), 0),
        at_(Message.user("fix it, see https://github.com/o/r/issues/7."), 10),
        at_(Message.assistant("", [ToolCall.fromRaw("c1", "bash", `{"command":"cargo build"}`),
            ToolCall.fromRaw("c2", "read_file", `{"path":"src/a.rs"}`)]), 11),
        tool("c1", "bash", "   Compiling a\nerror[E0599]: no method named `x`\nwarning: unused", true, 12),
        tool("c2", "read_file", "fn main() {}", false, 13),
        at_(Message.assistant("", [ToolCall.fromRaw("c3", "apply_patch", `{"patch":"*** Update File: src/a.rs\n@@\n-x\n+y"}`)]), 14),
        tool("c3", "apply_patch", "ok", false, 15),
        at_(Message.assistant("Fixed: renamed the call."), 16),
    ];
    auto s = extractSummary(ms);
    assert(s.canFind("## Earlier summary (abridged)\nold facts"), s);
    assert(!s.canFind("This summary covers"), "the old note is rebuilt, not carried");
    assert(s.canFind("- src/a.rs: patched (#14)") && !s.canFind("src/a.rs: read"), "one line per file, newest wins");
    assert(s.canFind("- `cargo build` → failed: error[E0599]: no method named `x` (#12)"), s);
    assert(s.canFind("- https://github.com/o/r/issues/7 (#10)"), "trailing punctuation trimmed");
    assert(!s.canFind("warning: unused"), "warnings are not signals");
    assert(s.canFind("- Fixed: renamed the call. (#16)"), s);
    assert(extractSummary(ms) == s, "deterministic");
}

unittest // an earlier extract summary is merged, not nested: compacting again is stable
{
    import nano.context : smartSummaryPrefix;
    import nano.llm : ToolCall;
    auto a = Message.assistant("", [ToolCall.fromRaw("c1", "read_file", `{"path":"src/a.rs"}`)]);
    a.logLine = 5;
    auto first = smartSummaryPrefix ~ "\n" ~ extractSummary([a, Message.assistant("ok\n- not a bullet\n## nor a title")]);
    auto ack = Message.assistant("Acknowledged.");
    string s = first;
    foreach (i; 0 .. 5) s = smartSummaryPrefix ~ "\n" ~ extractSummary([Message.user(s), ack]);
    assert(!s.canFind(earlierTitle) && s.canFind("- src/a.rs: read (#5)"), s);
    auto again = smartSummaryPrefix ~ "\n" ~ extractSummary([Message.user(first)]);
    assert(again.canFind("- ok ⏎ - not a bullet ⏎ ## nor a title"), "multi-line words stay one entry: " ~ again);
    assert(smartSummaryPrefix ~ "\n" ~ extractSummary([Message.user(s), ack]) == s, "a fixed point");
}

unittest // caps: sections keep only the newest entries
{
    import nano.llm : ToolCall;
    Message[] ms;
    foreach (i; 0 .. 100)
    {
        auto a = Message.assistant("", [ToolCall.fromRaw(format("c%s", i), "read_file", format(`{"path":"f%s"}`, i))]);
        a.logLine = i + 1;
        ms ~= a;
    }
    auto s = extractSummary(ms);
    assert(s.canFind("- f99: read (#100)") && s.canFind("- f60: read") && !s.canFind("- f59: read"), s);
}

unittest // repeated compactions plateau: the earlier summary is clipped
{
    import nano.context : smartSummaryPrefix;
    string summary = smartSummaryPrefix ~ "\nseed";
    size_t[] sizes;
    foreach (i; 0 .. 10)
    {
        auto big = Message.assistant(format("conclusion %s ", i) ~ "x".replicate(5_000));
        summary = smartSummaryPrefix ~ "\n" ~ extractSummary([Message.user(summary), big]);
        sizes ~= summary.length;
    }
    // Bounded by the clipped earlier summary plus one span's sections.
    assert(sizes[$ - 1] == sizes[$ - 2] && sizes[$ - 1] < extractEarlierChars + 2_500, format("%s", sizes));
}

private string replicate(string s, size_t n)
{
    import std.array : r = replicate;
    return r(s, n);
}
