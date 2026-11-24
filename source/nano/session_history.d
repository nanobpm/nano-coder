/// `history_search` / `history_read`: look up the original messages of this
/// session, including those a smart compaction folded into its summary
/// (port of `history.rs`). IDs are physical session-log lines.
module nano.session_history;

@safe:
import nano.safeio : jsonText, jsonPretty;
import nano.arith : saturatingSub, toSize;

import std.algorithm : canFind, startsWith, min;
import std.array : join, split;
import std.conv : to, ConvException;
import std.format : format;
import std.json;
import std.string : strip, indexOf;
import nano.llm : Message, Role, ToolDefinition;

enum searchTool = "history_search";
enum readTool = "history_read";
/// `sessions_list` (issue #271): the sessions this one can read from.
enum sessionsTool = "sessions_list";

/// Appended once to a failed tool result after a smart compaction.
enum string failedToolHint = "[If you are looking for something from earlier in this session (an error, a command "
    ~ "and its output, what the user asked for), it may only be in the conversation, not on disk: history_search finds the "
    ~ "original messages that the summary folded away.]";

enum size_t defaultLimit = 20, maxLimit = 100, snippetChars = 240, snippetsPerMessage = 3;

class HistoryError : Exception
{
    this(string msg) pure @safe { super(msg); }
}

bool isHistoryTool(string name) pure @safe { return name == searchTool || name == readTool || name == sessionsTool; }

/// A call that failed, including a bash command that ran but reported failure.
bool looksFailed(string tool, bool ok, string result) pure @safe
{
    if (isHistoryTool(tool)) return false;
    if (!ok) return true;
    if (tool != "bash") return false;
    foreach (marker; ["Exit code: ", "Error: command timed out ", "Terminated by signal "])
        if (result.startsWith(marker) || result.canFind("\n" ~ marker)) return true;
    return false;
}

/// Whether this message already consumed the one-time post-compaction hint.
bool consumesHint(const ref Message m) pure @safe
{
    if (m.role == Role.tool) return m.content.canFind(failedToolHint) || isHistoryTool(m.toolName);
    if (m.role == Role.assistant)
        foreach (ref c; m.toolCalls) if (isHistoryTool(c.name)) return true;
    return false;
}

ToolDefinition[] definitions(bool crossSession = true) pure
{
    // Without cross-session history the schemas keep their previous shape
    // (issue #271): no `session` property is advertised at all.
    immutable sessionProp = `,"session":{"type":"string","description":"Read another session: its handle, id, a unique id prefix, or a title from sessions_list. Omit for this session."}`;
    return [
        ToolDefinition(searchTool,
            "Search the original messages of this session, including those folded into a compaction summary. "
            ~ "Returns matching messages as `#N role: snippet` lines (up to 3 matches each), where #N is the ID the "
            ~ "summary cites; read one whole with history_read. Prefer distinctive patterns (an error code or "
            ~ "phrase, an identifier, a flag) over common words, and use order=oldest for things from early on. "
            ~ "An assistant message that follows tool output is often a paraphrase: read the output it names. "
            ~ "Results are history, not the current state of files.",
            parseJSON(`{"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression (case-insensitive); plain text works too"},"role":{"type":"string","enum":["user","assistant","tool"],"description":"Only messages with this role. Command output and errors are in tool messages; omit role to search everything"},"before":{"type":"integer","description":"Only messages with an ID below this"},"after":{"type":"integer","description":"Only messages with an ID above this"},"order":{"type":"string","enum":["newest","oldest"],"description":"Result order (default newest first)"},"limit":{"type":"integer","description":"Maximum messages returned (default 20, max 100)"}` ~ (crossSession ? sessionProp : "") ~ `},"required":["pattern"]}`)),
        ToolDefinition(readTool,
            "Read one original message of this session in full by its ID (#N from a summary or history_search).",
            parseJSON(`{"type":"object","properties":{"id":{"type":"integer","description":"Message ID (the N in #N)"},"max_output_length":{"type":"integer","description":"Maximum characters to return (default 40000)"}` ~ (crossSession ? sessionProp : "") ~ `},"required":["id"]}`)),
    ];
}

/// The `sessions_list` definition, offered only with `cross_session_history`
/// (issue #271): without the setting the history tools keep their old shape.
ToolDefinition sessionsDefinition() pure
{
    return ToolDefinition(sessionsTool,
        "List this machine's nano-coder sessions, live ones first, then newest first: id, short title, working directory, "
        ~ "last activity, whether a process currently has the session open ([live pid N], with its current directory "
        ~ "when it moved) and whether session_send can reach it ([messages]). At most `limit` (default 50) are shown. Pass an id, a unique id "
        ~ "prefix or a title as the `session` argument of history_search/history_read to read that session's "
        ~ "history. Reading a session from another working directory may be blocked by the permission policy.",
        parseJSON(`{"type":"object","properties":{"filter":{"type":"string","description":"Only sessions whose id, handle, title or working directory contains this (case-insensitive)"},"live":{"type":"boolean","description":"Only sessions a process currently has open"},"messages":{"type":"boolean","description":"Only sessions session_send can reach"},"limit":{"type":"integer","description":"Maximum sessions listed (default 50, max 500); the result says how many more matched"}}}`));
}

struct Entry
{
    ulong id;
    Message message;
}

/// The log's message records with their IDs. Torn or unknown lines are skipped.
/// `want`: decode only the lines it accepts (by ID), so a caller that needs a
/// few messages of a long log holds only those; the log is streamed, never
/// read whole (issue #263).
Entry[] load(string path, scope bool delegate(ulong id) @safe want = null)
{
    import nano.session : messageFromRecord, eachLogLine;
    Entry[] out_;
    eachLogLine(path, (line, n) {
        if (want !is null && !want(n)) return;
        // Cheap pre-filter; any JSON spacing is valid, and a line with a
        // `\u` escape may spell the type escaped, so it reaches the decoder.
        if (!mayBeMessage(line)) return;
        try
        {
            Message m;
            if (recordMessage(parseJSON(line), m)) out_ ~= Entry(n, m);
        }
        catch (Exception) {} // skip a torn or corrupt line, like the resume loader does
    }, false); // lossless: replay rehydrates compacted payloads from here
    return out_;
}

unittest // escaped_type_reaches_the_decoder
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "nano-d-history-escaped-type.jsonl");
    write(p, `{"type":"mess\u0061ge","data":{"role":"tool","content":"out","tool_call_id":"c"}}` ~ "\n");
    scope (exit) remove(p);
    auto es = load(p);
    assert(es.length == 1 && es[0].message.content == "out");
}

/// Whether `line` may be a message record, without decoding it. A record
/// as nano writes it starts `{"type":"<type>",`, so its type is read from
/// that prefix: a compaction snapshot (`replace`, whose embedded `"messages"`
/// would pass a substring check) is skipped without parsing its megabytes
/// (issue #234). Any other spelling (other spacing, an escaped type) falls
/// back to the substring check and reaches the decoder.
bool mayBeMessage(const(char)[] line) pure @safe
{
    if (auto t = writtenType(line)) return t == "message" || t == "plan_archive";
    return line.canFind(`"message"`) || line.canFind(`"plan_archive"`) || line.canFind(`\u`);
}

/// The type a line's `{"type":"<type>"` prefix names, or null when the line
/// is not spelled that way (or the type is escaped). Needs only the line's
/// first bytes, so a streamed line can be judged before it is buffered.
private const(char)[] writtenType(const(char)[] line) pure @safe
{
    enum prefix = `{"type":"`;
    if (!line.startsWith(prefix)) return null;
    auto rest = line[prefix.length .. $];
    immutable q = rest.indexOf('"');
    return q > 0 && !rest[0 .. q].canFind('\\') ? rest[0 .. q] : null;
}

/// A streamed line's head: false only for a line known not to be a message.
bool headMayBeMessage(const(char)[] head) pure @safe
{
    auto t = writtenType(head);
    return t is null || t == "message" || t == "plan_archive";
}

/// The message a decoded record shows the history tools, if any: a
/// `message` record as is, and a `plan_archive` (a finished plan replaced by
/// a new one, issue #346) as its full checklist with notes, so details that
/// only lived in the plan stay searchable. Throws on a malformed record.
private bool recordMessage(const JSONValue rec, out Message m)
{
    import nano.session : messageFromRecord;
    import nano.plan : Plan;
    import nano.result : match;
    immutable type = rec["type"].str;
    if (type == "message") { m = messageFromRecord(rec["data"]); return true; }
    if (type != "plan_archive") return false;
    return Plan.fromJSON(rec["data"]["plan"]).match!(
        (p) { m = Message.auto_("[Archived plan]\n" ~ p.render(true, size_t.max)); return true; },
        (e) => false);
}

unittest // plan_archive_is_searchable
{
    Message m;
    auto rec = parseJSON(`{"type":"plan_archive","data":{"plan":{"goal":"g","items":[{"id":1,"title":"t","status":"done","notes":["needle note"]}]}}}`);
    assert(recordMessage(rec, m) && m.content.canFind("needle note"));
    assert(mayBeMessage(`{"type":"plan_archive","data":{}}`) && headMayBeMessage(`{"type":"plan_archive"`));
    assert(!recordMessage(parseJSON(`{"type":"plan","data":{}}`), m));
}

unittest
{
    assert(mayBeMessage(`{"type":"message","data":{}}`));
    assert(!mayBeMessage(`{"type":"replace","data":{"messages":[{"type":"message"}]}}`));
    assert(!mayBeMessage(`{"type":"plan","data":{}}`));
    assert(mayBeMessage(`{"type":"mess\u0061ge","data":{}}`), "an escaped type reaches the decoder");
    assert(mayBeMessage(`{ "type" : "message", "data":{}}`), "other spacing reaches the decoder");
    assert(!mayBeMessage(`{ "type" : "plan", "data":{}}`));
}

/// One message record parsed from a streamed line, or none when the line is
/// not a decodable message record.
private bool messageLine(const(char)[] line, out Message m)
{
    if (!mayBeMessage(line)) return false;
    try return recordMessage(parseJSON(line), m);
    catch (Exception) return false; // a corrupt record is skipped alone; later records stay readable
}

string roleName(Role r) pure @safe
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
private string label(ulong id, const ref Message m) pure @safe
{
    auto s = format("#%s %s", id, roleName(m.role));
    if (m.toolName.length) s ~= " " ~ m.toolName;
    if (m.isError) s ~= " (failed)";
    if (m.timestamp.length >= 19) s ~= format(" (%s %s)", m.timestamp[0 .. 10], m.timestamp[11 .. 19]);
    return s;
}

/// Text and tool calls, leaving out history lookups so a search can't find itself.
private string searchable(const ref Message m) pure
{
    if (isHistoryTool(m.toolName)) return "";
    string text = m.content;
    foreach (ref c; m.toolCalls)
        if (!isHistoryTool(c.name)) text ~= format("\n[called %s(%s)]", c.name, c.arguments.jsonText);
    return text;
}

private ulong idArg(JSONValue args, string key, bool required) pure
{
    auto v = args.type == JSONType.object ? key in args.objectNoRef : null;
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
private string snippet(string text, size_t start, size_t end) pure
{
    import std.utf : toUTF32, toUTF8, count;
    auto pre = text[0 .. start].toUTF32;
    auto lead = snippetChars / 3;
    auto fromC = saturatingSub(pre.length, lead);
    auto from = text[0 .. start].length - pre[fromC .. $].toUTF8.length;
    auto used = pre.length - fromC + text[start .. end].count;
    auto room = saturatingSub(snippetChars, used);
    auto post = text[end .. $].toUTF32;
    auto to_ = post.length > room ? end + post[0 .. room].toUTF8.length : text.length;
    auto out_ = text[from .. to_].split.join(" ");
    if (from > 0) out_ = "…" ~ out_;
    if (to_ < text.length) out_ ~= "…";
    return out_;
}

/// `history_search`: matching messages, newest first by default.
string search(string path, JSONValue args)
{
    import std.regex : regex, matchAll, escaper, Regex;
    import std.array : array;
    auto p = args.type == JSONType.object ? "pattern" in args.objectNoRef : null;
    if (p is null || p.type != JSONType.string || !p.str.length) throw new HistoryError("pattern must be a non-empty string");
    auto pattern = p.str;
    Regex!char re;
    try re = regex(pattern, "i");
    catch (Exception) re = regex(escaper(pattern).to!string, "i"); // not a valid regex: search for the pattern literally instead
    string role;
    if (auto r = "role" in args.objectNoRef) if (r.type == JSONType.string) role = r.str;
    auto before = idArg(args, "before", false), after = idArg(args, "after", false);
    size_t limit = defaultLimit;
    if (auto l = "limit" in args.objectNoRef)
    {
        // Phobos tags any unsigned value `uinteger` (even `JSONValue(1u)`),
        // so clamp the actual value to the signed range rather than reading
        // every unsigned limit as "unbounded".
        long n = l.type == JSONType.integer ? l.integer
            : l.type == JSONType.uinteger ? (l.uinteger > ulong(long.max) ? long.max : long(l.uinteger)) : 0;
        if (n > 0) limit = min(toSize(n), maxLimit);
    }
    bool oldestFirst;
    if (auto o = "order" in args.objectNoRef)
        if (o.type == JSONType.string)
        {
            if (o.str == "oldest") oldestFirst = true;
            else if (o.str != "newest") throw new HistoryError(format(`order must be "newest" or "oldest", not "%s"`, o.str));
        }
    // Stream the log (issue #271): only the `limit` newest/oldest hits are
    // retained, plus the run of tool messages before one assistant hit, so a
    // huge session's search stays bounded no matter its size.
    import nano.session : foreachLogLineSkippingTorn, maxRecordBytes;
    import std.algorithm : min;
    string[] hits;
    size_t total;
    ulong omitFirst = ulong.max, omitLast;
    size_t[string] hidden;
    // The run of tool messages since the last non-tool message, as scalars
    // so a long run costs nothing: first id, last id, count.
    ulong runFirst, runLast;
    size_t runLen;
    void runAdd(ulong id) { if (!runLen) runFirst = id; runLast = id; ++runLen; }
    struct Kept { ulong id; string line; }
    Kept[] kept;
    ulong n;
    size_t skippedBig; // records above the cap, unsearched (issue #289)
    foreachLogLineSkippingTorn(path, (const(char)[] logLine) {
        ++n;
        Message m;
        if (!logLine.length || !messageLine(logLine, m)) return; // empty: a record skipped by type, unread
        auto id = n;
        if (m.role == Role.system || (before && id >= before) || (after && id <= after))
        {
            // Excluded from hits, but adjacency still holds across the cutoff.
            if (m.role == Role.tool) runAdd(id);
            else runLen = 0;
            return;
        }
        auto text = searchable(m);
        if (role.length && role != roleName(m.role))
        {
            if (!matchAll(text, re).empty) hidden[roleName(m.role)]++;
            if (m.role == Role.tool) runAdd(id);
            else runLen = 0;
            return;
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
        // The tools just before it: the run tracked above (reset below for
        // this assistant message itself).
        immutable toolsLen = runLen, toolsFirst = runFirst, toolsLast = runLast;
        if (m.role == Role.tool) runAdd(id);
        else runLen = 0;
        if (!count) return;
        ++total;
        auto line = label(id, m);
        if (count > 1) line ~= format(" [%s matches]", count);
        if (m.role == Role.assistant)
        {
            if (toolsLen == 1) line ~= format(" [after tool output #%s]", toolsFirst);
            else if (toolsLen > 1)
                line ~= format(" [after tool output #%s–#%s]", toolsFirst, toolsLast);
        }
        line ~= ":";
        foreach (sp; spans) line ~= " " ~ snippet(text, sp[0], sp[1]);
        if (oldestFirst)
        {
            if (kept.length < limit) kept ~= Kept(id, line);
            else
            {
                if (id < omitFirst) omitFirst = id;
                if (id > omitLast) omitLast = id;
            }
        }
        else
        {
            kept ~= Kept(id, line);
            if (kept.length > limit)
            {
                foreach (drop; kept[0 .. $ - limit])
                {
                    if (drop.id < omitFirst) omitFirst = drop.id;
                    if (drop.id > omitLast) omitLast = drop.id;
                }
                kept = kept[$ - limit .. $].dup;
            }
        }
    // An oversized record's role is unknown: it breaks any tool-output run.
    }, (head) => headMayBeMessage(head), (size_t) { ++skippedBig; runLen = 0; });
    if (oldestFirst) foreach (ref k; kept) hits ~= k.line;
    else foreach_reverse (ref k; kept) hits ~= k.line;
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
    if (skippedBig)
    {
        if (hiddenNote.length) hiddenNote ~= "\n";
        hiddenNote ~= format("[incomplete: %s record(s) over %s bytes were too large to search]",
            skippedBig, maxRecordBytes);
    }
    if (!hits.length)
    {
        auto o = format("No %smessages match %s.", role.length ? role ~ " " : "", JSONValue(pattern).jsonText);
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
string read(string path, JSONValue args)
{
    import nano.tools : truncateOutput, defaultMaxOutput, maxOutputLimit;
    auto id = idArg(args, "id", true);
    size_t limit = defaultMaxOutput;
    if (auto l = "max_output_length" in args.objectNoRef)
    {
        // Clamp the actual unsigned value (see `search` above): an unsigned
        // 100 must stay 100, and an unsigned 0 must still be rejected.
        long n = l.type == JSONType.integer ? l.integer
            : l.type == JSONType.uinteger ? (l.uinteger > ulong(long.max) ? long.max : long(l.uinteger)) : -1;
        if (n <= 0) throw new HistoryError("max_output_length must be a positive integer");
        limit = min(toSize(n), maxOutputLimit);
    }
    // Stream the log (issue #271): only the target message is retained, so
    // reading one message from a huge session stays bounded.
    import nano.session : foreachLogLineSkippingTorn;
    import nano.session : maxRecordBytes;
    Message found;
    bool have;
    ulong latest, n;
    size_t bigBytes; // the target's size when it was skipped as oversized
    foreachLogLineSkippingTorn(path, (const(char)[] logLine) {
        ++n;
        // Only the asked-for line is decoded; the others just track the
        // latest ID for the error (issue #234).
        if (!logLine.length || !mayBeMessage(logLine)) return;
        if (n == id)
        {
            Message m;
            if (!messageLine(logLine, m)) return;
            found = m;
            have = true;
        }
        latest = n;
    }, (head) => headMayBeMessage(head), (size_t b) {
        if (n + 1 == id) bigBytes = b;
    });
    if (!have && bigBytes)
        throw new HistoryError(format("message #%s is a %s-byte record, too large to read (limit %s bytes)",
            id, bigBytes, maxRecordBytes));
    if (!have)
        throw new HistoryError(format("no message #%s in this session (IDs are log lines; the latest is #%s)", id, latest));
    auto m = &found;
    if (m.role == Role.system) throw new HistoryError(format("message #%s is a system message and cannot be read", id));
    auto text = label(id, *m) ~ "\n";
    // Reasoning models may carry their content only in thinking blocks; other
    // providers log plain text (replay blocks such as `reasoning_content` have
    // no readable `thinking`), so the logged text fills in when no block did.
    bool emitted;
    foreach (b; m.thinkingBlocks)
        if (b.type == JSONType.object)
            if (auto t = "thinking" in b.objectNoRef)
                if (t.type == JSONType.string)
                {
                    text ~= "[thinking] " ~ t.str ~ "\n";
                    emitted = true;
                }
    if (!emitted && m.thinking.length) text ~= "[thinking] " ~ m.thinking ~ "\n";
    text ~= m.content;
    foreach (ref c; m.toolCalls) text ~= format("\n[called %s id=%s %s]", c.name, c.id, c.arguments.jsonText);
    return truncateOutput(text, limit, format("history-%s", id));
}

// rust: history.rs::read_returns_one_message_whole_or_bounded
// rust: session.rs::standard_replace_does_not_offer_history_tools
unittest
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

    // A compressed log streams through the same search/read (issue #271):
    // gunzip as it is read, never inflated whole.
    import nano.session : gzipLog, logText;
    import std.file : rename, write;
    auto gzPath = log.path ~ ".gz";
    write(gzPath, gzipLog(logText(log.path)));
    // The plain twin wins when both exist, so move the plain one away.
    rename(log.path, log.path ~ ".bak");
    auto gzSearch = search(gzPath, parseJSON(`{"pattern":"fixed"}`));
    assert(gzSearch.canFind("#6 assistant"), gzSearch);
    assert(read(gzPath, parseJSON(`{"id":"#4"}`)).canFind("cargo test auth"));
    assert(load(gzPath).length == 6, "the archive streams like the plain log: " ~ load(gzPath).length.to!string);
}



// Issue #271 review: one corrupt message record is skipped alone; later
// records stay readable.
unittest
{
    Message m;
    assert(!messageLine(`{"type":"message","data":{"role":42}}`, m));
    assert(!messageLine(`{"type":"message",`, m));
}

unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "nano-history-corrupt-mid.jsonl");
    scope (exit) remove(p);
    write(p, `{"type":"session","data":{}}` ~ "\n"
        ~ `{"type":"message","data":{"role":42}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"user","content":"after"}}` ~ "\n");
    auto es = load(p);
    assert(es.length == 1 && es[0].id == 3, "the record after a corrupt one is still loaded");
}

// A search never parses a compaction snapshot (issue #234): a `replace`
// record's embedded messages match the query but are not hits (they are the
// same conversation as the message records, restated), and its megabytes are
// skipped by type rather than decoded, so a search allocates far less than
// the snapshot's size.
unittest
{
    import core.memory : GC;
    import std.array : appender;
    import std.conv : text;
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "nano-d-history-replace-skip.jsonl");
    auto o = appender!string;
    o.put(`{"type":"session","data":{"version":1,"id":"s","created_at":"x"}}` ~ "\n");
    o.put(`{"type":"message","data":{"role":"user","content":"find needle here"}}` ~ "\n");
    o.put(`{"type":"replace","data":{"messages":[`);
    foreach (i; 0 .. 20_000)
        o.put(text(i ? "," : "", `{"role":"tool","tool_call_id":"c`, i, `","content":"needle in snapshot `, i, `"}`));
    o.put(`]}}` ~ "\n");
    write(p, o.data);
    scope (exit) remove(p);
    immutable before = GC.stats.allocatedInCurrentThread;
    auto r = search(p, parseJSON(`{"pattern":"needle"}`));
    immutable spent = GC.stats.allocatedInCurrentThread - before;
    assert(r.startsWith("#2 user") && !r.canFind("snapshot"), r);
    assert(spent < o.data.length / 4, text("search allocated ", spent, " B for a ", o.data.length, " B log"));
}

// Issue #289 (PR review): replay's `load` is lossless, while the history
// tools say when a record above `maxRecordBytes` was skipped instead of
// reporting it as absent.
unittest
{
    import std.array : replicate;
    import std.algorithm : canFind;
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    import nano.session : maxRecordBytes;
    auto p = buildPath(tempDir, "nano-d-history-oversized.jsonl");
    scope (exit) remove(p);
    write(p, `{"type":"session","data":{}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"user","content":"` ~ "q".replicate(maxRecordBytes) ~ `"}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"user","content":"after"}}` ~ "\n");
    auto es = load(p);
    assert(es.length == 2 && es[0].id == 2 && es[0].message.content.length == maxRecordBytes, "replay is lossless");
    auto o = search(p, parseJSON(`{"pattern":"zzz"}`));
    assert(o.canFind("too large to search"), o);
    bool threw;
    try read(p, parseJSON(`{"id":2}`));
    catch (HistoryError e) threw = e.msg.canFind("too large to read");
    assert(threw, "an oversized target is not reported missing");
}

// Issue #289 (PR review): an oversized record's role is unknown, so it ends
// a tool-output run; the next assistant hit is not labelled as following it.
unittest
{
    import std.array : replicate;
    import std.algorithm : canFind;
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    import nano.session : maxRecordBytes;
    auto p = buildPath(tempDir, "nano-d-history-oversized-run.jsonl");
    scope (exit) remove(p);
    write(p, `{"type":"session","data":{}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"tool","tool_call_id":"c","content":"out"}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"user","content":"` ~ "q".replicate(maxRecordBytes) ~ `"}}` ~ "\n"
        ~ `{"type":"message","data":{"role":"assistant","content":"needle"}}` ~ "\n");
    auto o = search(p, parseJSON(`{"pattern":"needle"}`));
    assert(o.canFind("assistant") && !o.canFind("after tool output"), o);
}
