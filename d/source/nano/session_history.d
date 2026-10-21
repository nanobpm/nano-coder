/// `history_search` / `history_read`: look up the original messages of this
/// session, including those a smart compaction folded into its summary
/// (port of `history.rs`). IDs are physical session-log lines.
module nano.session_history;

import std.algorithm : canFind, startsWith, min;
import std.array : join, split;
import std.conv : to, ConvException;
import std.format : format;
import std.json;
import std.string : strip, indexOf;
import nano.llm : Message, Role, ToolDefinition;

enum searchTool = "history_search";
enum readTool = "history_read";

/// Appended once to a failed tool result after a smart compaction.
enum string failedToolHint = "[If you are looking for something from earlier in this session (an error, a command "
    ~ "and its output, what the user asked for), it may only be in the conversation, not on disk: history_search finds the "
    ~ "original messages that the summary folded away.]";

enum size_t defaultLimit = 20, maxLimit = 100, snippetChars = 240, snippetsPerMessage = 3;

class HistoryError : Exception
{
    this(string msg) @safe { super(msg); }
}

bool isHistoryTool(string name) @safe { return name == searchTool || name == readTool; }

/// A call that failed, including a bash command that ran but reported failure.
bool looksFailed(string tool, bool ok, string result) @safe
{
    if (isHistoryTool(tool)) return false;
    if (!ok) return true;
    if (tool != "bash") return false;
    foreach (marker; ["Exit code: ", "Error: command timed out ", "Terminated by signal "])
        if (result.startsWith(marker) || result.canFind("\n" ~ marker)) return true;
    return false;
}

/// Whether this message already consumed the one-time post-compaction hint.
bool consumesHint(const ref Message m) @safe
{
    if (m.role == Role.tool) return m.content.canFind(failedToolHint) || isHistoryTool(m.toolName);
    if (m.role == Role.assistant)
        foreach (ref c; m.toolCalls) if (isHistoryTool(c.name)) return true;
    return false;
}

ToolDefinition[] definitions() @trusted
{
    return [
        ToolDefinition(searchTool,
            "Search the original messages of this session, including those folded into a compaction summary. "
            ~ "Returns matching messages as `#N role: snippet` lines (up to 3 matches each), where #N is the ID the "
            ~ "summary cites; read one whole with history_read. Prefer distinctive patterns (an error code or "
            ~ "phrase, an identifier, a flag) over common words, and use order=oldest for things from early on. "
            ~ "An assistant message that follows tool output is often a paraphrase: read the output it names. "
            ~ "Results are history, not the current state of files.",
            parseJSON(`{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression (case-insensitive); plain text works too"},"role":{"type":"string","enum":["user","assistant","tool"],"description":"Only messages with this role. Command output and errors are in tool messages; omit role to search everything"},"before":{"type":"integer","description":"Only messages with an ID below this"},"after":{"type":"integer","description":"Only messages with an ID above this"},"order":{"type":"string","enum":["newest","oldest"],"description":"Result order (default newest first)"},"limit":{"type":"integer","description":"Maximum messages returned (default 20, max 100)"}},"required":["pattern"]}`)),
        ToolDefinition(readTool,
            "Read one original message of this session in full by its ID (#N from a summary or history_search).",
            parseJSON(`{"type":"object","properties":{"id":{"type":"integer","description":"Message ID (the N in #N)"},"max_output_length":{"type":"integer","description":"Maximum characters to return (default 40000)"}},"required":["id"]}`)),
    ];
}

struct Entry
{
    ulong id;
    Message message;
}

/// The log's message records with their IDs. Torn or unknown lines are skipped.
Entry[] load(string path) @trusted
{
    import std.file : readText;
    import std.string : lineSplitter;
    import nano.session : messageFromRecord;
    Entry[] out_;
    ulong n;
    foreach (line; readText(path).lineSplitter)
    {
        ++n;
        if (!line.startsWith(`{"type":"message"`)) continue;
        try
        {
            auto rec = parseJSON(line);
            if (rec["type"].str == "message") out_ ~= Entry(n, messageFromRecord(rec["data"]));
        }
        catch (Exception) {}
    }
    return out_;
}

string roleName(Role r) @safe
{
    final switch (r)
    {
        case Role.system: return "system";
        case Role.user: return "user";
        case Role.assistant: return "assistant";
        case Role.tool: return "tool";
    }
}

/// `#N role [name] (failed) (YYYY-MM-DD HH:MM:SS)`.
private string label(ulong id, const ref Message m) @safe
{
    auto s = format("#%s %s", id, roleName(m.role));
    if (m.toolName.length) s ~= " " ~ m.toolName;
    if (m.isError) s ~= " (failed)";
    if (m.timestamp.length >= 19) s ~= format(" (%s %s)", m.timestamp[0 .. 10], m.timestamp[11 .. 19]);
    return s;
}

/// Text and tool calls, leaving out history lookups so a search can't find itself.
private string searchable(const ref Message m) @trusted
{
    if (isHistoryTool(m.toolName)) return "";
    string text = m.content;
    foreach (ref c; m.toolCalls)
        if (!isHistoryTool(c.name)) text ~= format("\n[called %s(%s)]", c.name, c.arguments.toString);
    return text;
}

private ulong idArg(JSONValue args, string key, bool required) @trusted
{
    auto v = args.type == JSONType.object ? key in args.object : null;
    if (v is null || v.type == JSONType.null_)
    {
        if (required) throw new HistoryError(key ~ " is required");
        return 0;
    }
    if (v.type == JSONType.uinteger) return v.uinteger;
    if (v.type == JSONType.integer && v.integer > 0) return v.integer;
    if (v.type == JSONType.string)
    {
        auto s = v.str.strip;
        while (s.startsWith("#")) s = s[1 .. $];
        try return s.to!ulong;
        catch (ConvException) {}
    }
    throw new HistoryError(key ~ " must be a positive integer");
}

/// ~240 characters around a match, whitespace collapsed, `…` where cut.
private string snippet(string text, size_t start, size_t end) @trusted
{
    import std.utf : toUTF32, toUTF8, count;
    auto pre = text[0 .. start].toUTF32;
    auto lead = snippetChars / 3;
    auto fromC = pre.length > lead ? pre.length - lead : 0;
    auto from = text[0 .. start].length - pre[fromC .. $].toUTF8.length;
    auto used = pre.length - fromC + text[start .. end].count;
    auto room = snippetChars > used ? snippetChars - used : 0;
    auto post = text[end .. $].toUTF32;
    auto to_ = post.length > room ? end + post[0 .. room].toUTF8.length : text.length;
    auto out_ = text[from .. to_].split.join(" ");
    if (from > 0) out_ = "…" ~ out_;
    if (to_ < text.length) out_ ~= "…";
    return out_;
}

/// `history_search`: matching messages, newest first by default.
string search(string path, JSONValue args) @trusted
{
    import std.regex : regex, matchAll, escaper, Regex;
    import std.array : array;
    auto p = args.type == JSONType.object ? "pattern" in args.object : null;
    if (p is null || p.type != JSONType.string || !p.str.length) throw new HistoryError("pattern must be a non-empty string");
    auto pattern = p.str;
    Regex!char re;
    try re = regex(pattern, "i");
    catch (Exception) re = regex(escaper(pattern).to!string, "i");
    string role;
    if (auto r = "role" in args.object) if (r.type == JSONType.string) role = r.str;
    auto before = idArg(args, "before", false), after = idArg(args, "after", false);
    size_t limit = defaultLimit;
    if (auto l = "limit" in args.object)
    {
        long n = l.type == JSONType.integer ? l.integer : l.type == JSONType.uinteger ? cast(long) l.uinteger : 0;
        if (n > 0) limit = min(cast(size_t) n, maxLimit);
    }
    bool oldestFirst;
    if (auto o = "order" in args.object)
        if (o.type == JSONType.string)
        {
            if (o.str == "oldest") oldestFirst = true;
            else if (o.str != "newest") throw new HistoryError(format(`order must be "newest" or "oldest", not "%s"`, o.str));
        }
    auto messages = load(path);
    size_t[] order;
    foreach (i; 0 .. messages.length) order ~= oldestFirst ? i : messages.length - 1 - i;
    string[] hits;
    size_t total;
    ulong omitFirst = ulong.max, omitLast;
    size_t[string] hidden;
    foreach (i; order)
    {
        auto id = messages[i].id;
        auto m = &messages[i].message;
        if (m.role == Role.system || (before && id >= before) || (after && id <= after)) continue;
        auto text = searchable(*m);
        if (role.length && role != roleName(m.role))
        {
            if (!matchAll(text, re).empty) hidden[roleName(m.role)]++;
            continue;
        }
        size_t count, shownUntil;
        size_t[2][] spans;
        foreach (c; matchAll(text, re))
        {
            if (!c.hit.length && count > 1_000) break;
            ++count;
            auto s = c.pre.length, e = s + c.hit.length;
            if (spans.length < snippetsPerMessage && s >= shownUntil)
            {
                spans ~= [s, e];
                shownUntil = e + snippetChars;
            }
        }
        if (!count) continue;
        ++total;
        if (hits.length >= limit)
        {
            if (id < omitFirst) omitFirst = id;
            if (id > omitLast) omitLast = id;
            continue;
        }
        auto line = label(id, *m);
        if (count > 1) line ~= format(" [%s matches]", count);
        if (m.role == Role.assistant)
        {
            ulong[] tools;
            for (auto j = i; j > 0 && messages[j - 1].message.role == Role.tool; --j) tools ~= messages[j - 1].id;
            if (tools.length == 1) line ~= format(" [after tool output #%s]", tools[0]);
            else if (tools.length > 1) line ~= format(" [after tool output #%s–#%s]", tools[$ - 1], tools[0]);
        }
        line ~= ":";
        foreach (sp; spans) line ~= " " ~ snippet(text, sp[0], sp[1]);
        hits ~= line;
    }
    string hiddenNote;
    if (hidden.length)
    {
        import std.algorithm : sort;
        size_t sum;
        string[] counts;
        foreach (k; hidden.keys.sort) { counts ~= format("%s %s", hidden[k], k); sum += hidden[k]; }
        hiddenNote = format("[role=%s hid %s matching message(s): %s. Tool messages hold command output and errors; "
            ~ "search without role to include them]", role, sum, counts.join(", "));
    }
    if (!hits.length)
    {
        auto o = format("No %smessages match %s.", role.length ? role ~ " " : "", JSONValue(pattern).toString);
        return hiddenNote.length ? o ~ "\n" ~ hiddenNote : o;
    }
    auto out_ = hits.join("\n");
    if (hiddenNote.length) out_ ~= "\n" ~ hiddenNote;
    if (total > hits.length)
        out_ ~= format("\n[%s more %s matching messages not shown (#%s–#%s); use a more distinctive pattern, %s=, or order=%s]",
            total - hits.length, oldestFirst ? "newer" : "older", omitFirst, omitLast, oldestFirst ? "after" : "before",
            oldestFirst ? "newest" : "oldest");
    return out_;
}

/// `history_read`: one message in full, bounded (the whole is spilled to a file).
string read(string path, JSONValue args) @trusted
{
    import nano.tools : truncateOutput, defaultMaxOutput, maxOutputLimit;
    auto id = idArg(args, "id", true);
    size_t limit = defaultMaxOutput;
    if (auto l = "max_output_length" in args.object)
    {
        long n = l.type == JSONType.integer ? l.integer : l.type == JSONType.uinteger ? cast(long) l.uinteger : -1;
        if (n <= 0) throw new HistoryError("max_output_length must be a positive integer");
        limit = min(cast(size_t) n, maxOutputLimit);
    }
    auto messages = load(path);
    const(Entry)* found;
    foreach (ref e; messages) if (e.id == id) found = &e;
    if (found is null)
        throw new HistoryError(format("no message #%s in this session (IDs are log lines; the latest is #%s)", id,
            messages.length ? messages[$ - 1].id : 0));
    auto m = &found.message;
    if (m.role == Role.system) throw new HistoryError(format("message #%s is a system message and cannot be read", id));
    auto text = label(id, *m) ~ "\n";
    if (m.thinking.length) text ~= "[thinking] " ~ m.thinking ~ "\n";
    text ~= m.content;
    foreach (ref c; m.toolCalls) text ~= format("\n[called %s id=%s %s]", c.name, c.id, c.arguments.toString);
    return truncateOutput(text, limit, format("history-%s", id));
}

@trusted unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import std.algorithm : canFind, startsWith;
    import nano.llm : ToolCall;
    import nano.session : SessionLog, restore;
    auto dir = buildPath(tempDir, "nano-d-history-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    // Line 1 is the header; messages are lines 2-6, then a smart replace.
    auto log = new SessionLog(dir, "m", "/w", "h");
    auto msgs = [Message.system("sys"), Message.user("fix the flaky test in auth.rs"),
        Message.assistant("", [ToolCall.fromRaw("c1", "bash", `{"command":"cargo test auth"}`)])];
    string long_;
    foreach (_; 0 .. 400) long_ ~= "a ";
    long_ ~= "error[E0308]: mismatched types at auth.rs:42";
    foreach (_; 0 .. 400) long_ ~= " b";
    msgs ~= Message.toolResult("c1", "bash", long_, true);
    msgs ~= Message.assistant("fixed");
    ulong[] ids;
    foreach (ref m; msgs) ids ~= log.append(m);
    assert(ids == [2, 3, 4, 5, 6], ids.to!string);
    log.replace([Message.system("sys"), Message.user("summary"), Message.assistant("fixed")], 3, 5, "smart", null);

    auto loaded = load(log.path);
    assert(loaded.length == 5 && loaded[0].id == 2 && loaded[$ - 1].id == 6);
    auto r = search(log.path, parseJSON(`{"pattern":"E0308"}`));
    assert(r.startsWith("#5 tool bash (failed)") && r.canFind("…") && r.canFind("error[E0308]"), r);
    assert(search(log.path, parseJSON(`{"pattern":"fixed"}`)).canFind("[after tool output #5]"));
    auto hidden = search(log.path, parseJSON(`{"pattern":"E0308","role":"assistant"}`));
    assert(hidden.startsWith(`No assistant messages match "E0308".`) && hidden.canFind("hid 1 matching message(s): 1 tool"), hidden);
    assert(search(log.path, parseJSON(`{"pattern":"cargo test"}`)).canFind("#4 assistant: [called bash"));
    assert(search(log.path, parseJSON(`{"pattern":"sys"}`)).startsWith("No messages"), "system is never searched");
    // An invalid regex falls back to plain text.
    assert(search(log.path, parseJSON(`{"pattern":"error["}`)).startsWith("#5"));
    auto lim = search(log.path, parseJSON(`{"pattern":"a","limit":1,"order":"oldest"}`));
    assert(lim.startsWith("#3") && lim.canFind("more newer matching messages not shown"), lim);
    bool threw;
    try search(log.path, parseJSON(`{"pattern":""}`)); catch (HistoryError) threw = true;
    assert(threw);

    assert(read(log.path, parseJSON(`{"id":"#4"}`)).canFind(`[called bash id=c1 {"command":"cargo test auth"}]`));
    assert(read(log.path, parseJSON(`{"id":5,"max_output_length":100}`)).canFind("full output saved to"));
    foreach (bad; [`{"id":2}`, `{"id":99}`, `{}`])
    {
        threw = false;
        try read(log.path, parseJSON(bad)); catch (HistoryError) threw = true;
        assert(threw, bad);
    }

    // Restore: a smart replace offers the tools; the hint is consumed once shown.
    auto rs = restore(log.path);
    assert(rs.historyAvailable && !rs.historyHintConsumed);
    auto withHint = Message.toolResult("c2", "bash", "Exit code: 1\n\n" ~ failedToolHint, true);
    log.append(withHint);
    assert(restore(log.path).historyHintConsumed);
    log.replace([Message.system("sys")], 0, 0, "standard", null);
    assert(!restore(log.path).historyAvailable, "a standard replace drops the history tools");

    assert(looksFailed("bash", true, "out\nExit code: 2") && !looksFailed("bash", true, "fine"));
    assert(looksFailed("read_file", false, "") && !looksFailed(searchTool, false, ""));
}
