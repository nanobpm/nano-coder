/// Session trajectory: a turn-grouped ledger rebuilt from a session log
/// (port of `trajectory.rs`). Each turn holds the user input that opened it,
/// one row per thinking block, assistant answer, tool call and tool result
/// (with per-request usage and timing), and compactions; `/trajectory` and
/// `--trajectory ID [--json|--markdown]` render it as plain text, serde-shaped
/// JSON, or Markdown.
module nano.trajectory;

@safe:

import std.algorithm : canFind, map, max, sum, filter;
import std.array : join, replicate, split, array;
import std.conv : to;
import std.format : format;
import std.json;
import std.string : lineSplitter;
import std.typecons : Nullable;

enum Kind { user, think, assistant, tool, toolCall, compact }

/// One ledger row. Optional fields use `null` strings or `-1`.
struct Row
{
    ulong id; // 0 = no log line
    Kind kind;
    string text;
    // Tool / ToolCall / Compact payload.
    string name;
    bool ok;
    string callId; // tool result's call id (null = none), or the call's id
    long toolDurationMs = -1;
    string arguments;
    string compactMode;
    string compactModel;
    // Per-request metrics.
    bool hasUsage;
    long promptTokens, completionTokens, totalTokens;
    string aic; // raw JSON number, or null
    long durationMs = -1;
    string temperature;
    string thinkingLevel;
    string timestamp;

    string cited() const
    {
        return id ? format("#%s %s", id, label) : label;
    }

    string label() const
    {
        final switch (kind)
        {
        case Kind.user: return "USER";
        case Kind.think: return "THINK";
        case Kind.assistant: return "ASSISTANT";
        case Kind.tool:
            auto status = ok ? "ok" : "error";
            return toolDurationMs >= 0 ? format("TOOL %s (%s, %s)", name, formatDuration(toolDurationMs), status)
                : format("TOOL %s (%s)", name, status);
        case Kind.toolCall: return "CALL " ~ name;
        case Kind.compact: return compactMode !is null ? "COMPACT (" ~ compactMode ~ ")" : "COMPACT";
        }
    }

    /// The per-request metric suffix (`1.2k tok, 3.4s`), when known.
    string metric() const
    {
        string[] bits;
        if (hasUsage && totalTokens > 0) bits ~= formatTokens(totalTokens) ~ " tok";
        if (kind != Kind.tool && durationMs >= 0) bits ~= formatDuration(durationMs);
        if (temperature !is null) bits ~= "temp " ~ temperature;
        if (thinkingLevel !is null) bits ~= "thinking " ~ thinkingLevel;
        return bits.length ? bits.join(", ") : null;
    }
}

struct Turn
{
    size_t number; // 0 = preamble
    string input; // null = none
    string response;
    bool hasOutcome;
    string outcomeStatus, outcomeSummary;
    Row[] rows;

    /// Tool count, model calls, output tokens, request time, outcome.
    string summary() const
    {
        bool[string] callIds;
        size_t callRows;
        foreach (ref r; rows)
            if (r.kind == Kind.toolCall) { callRows++; callIds[r.callId] = true; }
        size_t orphans;
        foreach (ref r; rows)
            if (r.kind == Kind.tool && (r.callId is null || r.callId !in callIds)) orphans++;
        auto tools = callRows + orphans;
        ptrdiff_t lastAssistant = -1;
        foreach (i, ref r; rows) if (r.kind == Kind.assistant) lastAssistant = i;
        bool seenThink;
        size_t calls;
        foreach (i, ref r; rows)
        {
            if (r.kind == Kind.think) { seenThink = true; calls++; }
            else if (r.kind == Kind.assistant)
            {
                bool synthetic = i == lastAssistant && response !is null && hasOutcome && !r.hasUsage
                    && r.durationMs < 0 && response == r.text;
                if (synthetic) continue;
                if (seenThink) { seenThink = false; continue; }
                calls++;
            }
        }
        long outTok;
        long dur;
        foreach (ref r; rows)
        {
            if (r.hasUsage && r.completionTokens > 0) outTok += r.completionTokens;
            if (r.durationMs >= 0) dur += r.durationMs;
        }
        string[] bits;
        if (calls) bits ~= format("%s call%s", calls, calls == 1 ? "" : "s");
        if (tools) bits ~= format("%s tool%s", tools, tools == 1 ? "" : "s");
        if (outTok > 0) bits ~= formatTokens(outTok) ~ " out";
        if (dur > 0) bits ~= formatDuration(dur);
        if (hasOutcome) bits ~= outcomeStatus;
        return bits.length ? bits.join(" · ") : "(no activity)";
    }
}

struct Trajectory
{
    string sessionId;
    string createdAt; // RFC 3339 as logged, or null
    Turn[] turns;

    /// Rebuild the ledger from a log's committed records (each with its
    /// physical 1-based line number).
    static Trajectory fromRecords(const JSONValue[] records, const ulong[] lines, const string[] raws = null) @trusted
    {
        Trajectory t;
        auto current = Turn(0);
        size_t next = 1;
        string prevTs;
        void flush(Turn turn)
        {
            if (turn.input !is null && !(turn.rows.length && turn.rows[0].kind == Kind.user))
            {
                Row r;
                r.kind = Kind.user;
                r.text = turn.input;
                turn.rows = r ~ turn.rows;
            }
            if (turn.input !is null || turn.rows.length) t.turns ~= turn;
        }
        foreach (i, ref rec; records)
        {
            auto type = rec["type"].str;
            auto data = "data" in rec ? rec["data"] : JSONValue(null);
            switch (type)
            {
            case "session":
                t.sessionId = data["id"].str;
                if (auto c = "created_at" in data) t.createdAt = c.str;
                break;
            case "input":
                flush(current);
                current = Turn(next++, data["text"].str);
                prevTs = null;
                break;
            case "message":
                appendMessageRows(current, data, lines[i], prevTs, i < raws.length ? raws[i] : null);
                break;
            case "turn_end":
                current.response = str(data, "response", "");
                if (auto o = "outcome" in data)
                    if (o.type == JSONType.object)
                    {
                        current.hasOutcome = true;
                        current.outcomeStatus = (*o)["status"].str;
                        current.outcomeSummary = str(*o, "summary", "");
                    }
                break;
            case "replace":
                Row r;
                r.kind = Kind.compact;
                r.compactMode = str(data, "mode", null);
                r.compactModel = str(data, "model", null);
                r.text = compactText(data, r.compactMode, r.compactModel);
                current.rows ~= r;
                prevTs = null;
                break;
            default: // plan, hooks: not ledger rows
            }
        }
        flush(current);
        return t;
    }

    /// The whole ledger as plain text, every row in full.
    string toPlain() const
    {
        string[] o = ["Trajectory — session " ~ sessionId];
        if (createdAt !is null) o ~= "Started " ~ plainTime(createdAt);
        if (!turns.length) o ~= ["", "(no activity)"];
        foreach (ref turn; turns)
        {
            o ~= "";
            o ~= sanitizeTerminal(turnHeader(turn));
            foreach (ref row; turn.rows)
            {
                auto head = format("  %s %s", bullet(row), row.cited);
                auto m = row.metric;
                if (m !is null) head ~= "  " ~ m;
                o ~= sanitizeTerminal(head);
                foreach (l; splitNl(row.text)) o ~= sanitizeTerminal("      " ~ l);
            }
            if (turn.response !is null)
            {
                auto resp = trim(turn.response);
                string lastText;
                bool haveLast;
                foreach_reverse (ref r; turn.rows)
                    if (r.kind == Kind.assistant) { lastText = r.text; haveLast = true; break; }
                if (resp.length && !(haveLast && trim(lastText) == resp))
                {
                    o ~= sanitizeTerminal("  ● RESPONSE");
                    foreach (l; splitNl(resp)) o ~= sanitizeTerminal("      " ~ l);
                }
            }
            o ~= sanitizeTerminal("  ↳ " ~ turn.summary);
        }
        return o.join("\n");
    }

    /// The ledger as JSON, shaped (and ordered) like Rust's serde output.
    string toJson() const
    {
        J root = J.obj;
        root.add("session_id", J.s(sessionId));
        if (createdAt !is null) root.add("created_at", J.s(createdAt));
        J ts = J.arr;
        foreach (ref turn; turns)
        {
            J tj = J.obj;
            tj.add("number", J.raw(turn.number.to!string));
            if (turn.input !is null) tj.add("input", J.s(turn.input));
            if (turn.response !is null) tj.add("response", J.s(turn.response));
            if (turn.hasOutcome)
            {
                J oj = J.obj;
                oj.add("status", J.s(turn.outcomeStatus));
                oj.add("summary", J.s(turn.outcomeSummary));
                tj.add("outcome", oj);
            }
            J rs = J.arr;
            foreach (ref r; turn.rows) rs.items ~= rowJson(r);
            tj.add("rows", rs);
            ts.items ~= tj;
        }
        root.add("turns", ts);
        return root.pretty(0);
    }

    /// The ledger as Markdown.
    string toMarkdown() const
    {
        string[] o = ["# Trajectory — session `" ~ sessionId ~ "`"];
        if (createdAt !is null) o ~= ["", "_Started " ~ plainTime(createdAt) ~ " " ~ offsetOf(createdAt) ~ "_"];
        foreach (ref turn; turns)
        {
            o ~= ["", "## " ~ turnTitle(turn)];
            if (turn.input !is null) o ~= ["", "> " ~ quoteLines(sanitizeMarkdown(turn.input))];
            o ~= ["", "_" ~ turn.summary ~ "_"];
            foreach (ref row; turn.rows)
            {
                o ~= ["", "### " ~ sanitizeMarkdown(row.cited)];
                auto m = row.metric;
                if (m !is null) o ~= "_" ~ m ~ "_";
                auto text = trim(row.text);
                if (text.length) o ~= ["", fence(sanitizeMarkdown(text))];
            }
            if (turn.response !is null)
            {
                auto resp = trim(turn.response);
                if (resp.length) o ~= ["", "**Response**", "", "> " ~ quoteLines(sanitizeMarkdown(resp))];
            }
        }
        o ~= "";
        return o.join("\n");
    }
}

/// Every committed record of the log at `path`, with physical line numbers.
/// `expectedId`, when given, must match the header (a renamed or misplaced
/// log is refused). A torn trailing line is dropped, as on resume.
Trajectory load(string path, string expectedId = null) @trusted
{
    import std.file : read;
    import nano.session : formatVersion;
    string text;
    try text = cast(string) read(path);
    catch (Exception e)
    {
        // FileException prefixes the path; keep just the OS reason.
        import std.string : indexOf;
        auto msg = e.msg;
        auto cut = msg.indexOf(path ~ ": ");
        if (cut == 0) msg = msg[path.length + 2 .. $];
        throw new Exception(format("read session log %s: %s", path, msg));
    }
    auto committed = text.length;
    while (committed && text[committed - 1] != '\n') committed--;
    if (!committed) throw new Exception(format("session log %s has no committed records", path));
    JSONValue[] records;
    ulong[] lines;
    string[] raws;
    ulong lineNo;
    foreach (line; text[0 .. committed].split('\n')[0 .. $ - 1])
    {
        ++lineNo;
        if (!line.length) continue;
        JSONValue rec;
        try rec = parseJSON(line);
        catch (Exception e) throw new Exception(format("decode record %s of %s: %s", records.length + 1, path, e.msg));
        if ("type" !in rec || rec["type"].type != JSONType.string)
            throw new Exception(format("decode record %s of %s: missing record type", records.length + 1, path));
        if (rec["type"].str == "session")
        {
            if (records.length)
                throw new Exception(format("session record must be first (found at record %s)", records.length + 1));
            auto v = rec["data"]["version"].integer;
            if (v != formatVersion)
                throw new Exception(format("unsupported session format version %s (this build supports %s)", v, formatVersion));
            auto id = rec["data"]["id"].str;
            if (expectedId !is null && id != expectedId)
                throw new Exception(format("session log header id %s does not match %s", JSONValue(id).toString,
                    JSONValue(expectedId).toString));
        }
        else if (!records.length)
            throw new Exception(format("session log %s does not start with a session header", path));
        records ~= rec;
        lines ~= lineNo;
        raws ~= line;
    }
    return Trajectory.fromRecords(records, lines, raws);
}

private:

string str(const JSONValue j, string key, string dflt) @trusted
{
    if (j.type != JSONType.object) return dflt;
    if (auto v = key in j) if (v.type == JSONType.string) return v.str;
    return dflt;
}

void appendMessageRows(ref Turn turn, const JSONValue m, ulong line, ref string prevTs, string rawLine = null) @trusted
{
    auto first = turn.rows.length;
    auto role = m["role"].str;
    auto ts = str(m, "timestamp", null);
    auto content = str(m, "content", "");
    void metrics(ref Row r)
    {
        if (auto u = "usage" in m)
            if (u.type == JSONType.object)
            {
                r.hasUsage = true;
                long n(string k) { if (auto p = k in *u) if (p.type == JSONType.integer) return p.integer; return 0; }
                r.promptTokens = n("prompt_tokens");
                r.completionTokens = n("completion_tokens");
                r.totalTokens = n("total_tokens");
                if (auto a = "aic" in *u)
                    if (a.type == JSONType.float_ || a.type == JSONType.integer || a.type == JSONType.uinteger)
                    {
                        // std.json's float parse can be an ulp off; reread the
                        // logged digits with the correctly-rounded strtod.
                        auto lit = rawNumber(rawLine, "aic");
                        r.aic = serdeFloat(lit !is null ? strtodOf(lit)
                            : a.type == JSONType.float_ ? a.floating : cast(double) a.integer);
                    }
            }
        if (auto d = "duration_ms" in m) if (d.type == JSONType.integer) r.durationMs = d.integer;
        r.temperature = scalarText(m, "temperature");
        r.thinkingLevel = scalarText(m, "thinking_level");
    }
    if (role == "user")
    {
        Row r;
        r.kind = Kind.user;
        r.text = content;
        r.timestamp = ts;
        turn.rows ~= r;
    }
    else if (role == "assistant")
    {
        auto thinking = str(m, "thinking", "");
        if (!thinking.length)
            if (auto blocks = "thinking_blocks" in m)
                if (blocks.type == JSONType.array)
                {
                    string[] parts;
                    foreach (b; blocks.array)
                        if (b.type == JSONType.object)
                            if (auto th = "thinking" in b)
                                if (th.type == JSONType.string) parts ~= th.str;
                    thinking = parts.join("\n\n");
                }
        bool think = thinking.length > 0;
        if (think)
        {
            Row r;
            r.kind = Kind.think;
            r.text = thinking;
            metrics(r);
            r.timestamp = ts;
            turn.rows ~= r;
        }
        const(JSONValue)[] calls;
        if (auto c = "tool_calls" in m) if (c.type == JSONType.array) calls = c.array;
        Row a;
        a.kind = Kind.assistant;
        a.text = !content.length && calls.length
            ? "(calling " ~ calls.map!(c => c["name"].str).join(", ") ~ ")" : content;
        if (!think) metrics(a);
        a.timestamp = ts;
        turn.rows ~= a;
        foreach (c; calls)
        {
            auto mal = "malformed_arguments" in c;
            auto args = "arguments" in c;
            string raw = mal && mal.type == JSONType.string ? mal.str
                : args is null ? "{}" : args.type == JSONType.string ? serdeString(args.str) // legacy: Rust re-encodes the string value
                : args.toString(JSONOptions.doNotEscapeSlashes);
            Row r;
            r.kind = Kind.toolCall;
            r.callId = c["id"].str;
            r.name = c["name"].str;
            r.arguments = raw;
            r.text = raw;
            r.timestamp = ts;
            turn.rows ~= r;
        }
    }
    else if (role == "tool")
    {
        import nano.attachment : Attachment;
        Row r;
        r.kind = Kind.tool;
        r.name = str(m, "name", "tool");
        r.ok = !("is_error" in m && m["is_error"].type == JSONType.true_);
        r.callId = str(m, "tool_call_id", null);
        if (prevTs !is null && ts !is null) r.toolDurationMs = millisBetween(prevTs, ts);
        auto text = content;
        if (auto atts = "attachments" in m)
            if (atts.type == JSONType.array)
                foreach (at; atts.array)
                    if (at.type == JSONType.object)
                    {
                        if (text.length) text ~= "\n";
                        text ~= Attachment.fromJSON(at).placeholder;
                    }
        r.text = text;
        r.timestamp = ts;
        turn.rows ~= r;
    }
    foreach (ref r; turn.rows[first .. $]) r.id = line;
    if (ts !is null) prevTs = ts;
}

string scalarText(const JSONValue m, string key) @trusted
{
    if (auto v = key in m)
    {
        if (v.type == JSONType.string) return v.str;
        if (v.type != JSONType.null_) return v.toString;
    }
    return null;
}

/// Milliseconds from `a` to `b` (RFC 3339), or -1 when negative/unparseable.
long millisBetween(string a, string b) @trusted
{
    import std.datetime.systime : SysTime;
    try
    {
        auto d = (SysTime.fromISOExtString(b) - SysTime.fromISOExtString(a)).total!"msecs";
        return d >= 0 ? d : -1;
    }
    catch (Exception) return -1;
}

string compactText(const JSONValue data, string mode, string model) @trusted
{
    string[] parts;
    if (mode !is null) parts ~= "mode: " ~ mode;
    if (model !is null) parts ~= "model: " ~ model;
    if (auto s = "summarized" in data)
        if (s.type == JSONType.array && s.array.length == 2)
            parts ~= format("folded log lines %s–%s", s.array[0].toString, s.array[1].toString);
    size_t n;
    if (auto ms = "messages" in data) if (ms.type == JSONType.array) n = ms.array.length;
    parts ~= format("%s message(s) retained", n);
    return parts.join(", ");
}

string turnTitle(const ref Turn t)
{
    return t.number == 0 ? "Preamble" : format("Turn %s", t.number);
}

string turnHeader(const ref Turn t)
{
    auto title = turnTitle(t);
    return t.input !is null ? format("── %s ──  %s", title, oneLine(t.input, 60)) : format("── %s ──", title);
}

string bullet(const ref Row r)
{
    final switch (r.kind)
    {
    case Kind.tool: return r.ok ? "•" : "✗";
    case Kind.toolCall: return "→";
    case Kind.think: return "·";
    case Kind.compact: return "↺";
    case Kind.user, Kind.assistant: return "▸";
    }
}

string fence(string text)
{
    size_t longest;
    foreach (l; text.lineSplitter)
    {
        auto t = trimStart(l);
        if (t.length >= 3 && t[0 .. 3] == "```")
        {
            size_t n;
            while (n < t.length && t[n] == '`') n++;
            longest = max(longest, n + 1);
        }
    }
    auto bar = "`".replicate(max(longest, 3));
    return bar ~ "\n" ~ text ~ "\n" ~ bar;
}

/// Split on `\n` like Rust's `str::split`: always at least one piece.
string[] splitNl(string s)
{
    string[] o;
    size_t start;
    foreach (i, char c; s)
        if (c == '\n') { o ~= s[start .. i]; start = i + 1; }
    return o ~ s[start .. $];
}

string quoteLines(string s) { import std.array : replace; return s.replace("\n", "\n> "); }

bool isWs(dchar c) { import std.uni : isWhite; return isWhite(c); }

string trim(string s)
{
    import std.string : strip;
    return strip(s);
}

string trimStart(const(char)[] s)
{
    import std.string : stripLeft;
    return stripLeft(s).idup;
}

string oneLine(string text, size_t maxChars)
{
    import std.array : split;
    return truncate(text.split.join(" "), maxChars);
}

public string truncate(string text, size_t maxChars)
{
    import std.range : walkLength, take;
    if (text.walkLength <= maxChars) return text;
    return text.take(maxChars ? maxChars - 1 : 0).to!string ~ "…";
}

public string formatTokens(long t)
{
    return t >= 1000 ? format("%.1fk", t / 1000.0) : t.to!string;
}

public string formatDuration(long ms)
{
    if (ms < 1000) return format("%sms", ms);
    if (ms < 60_000) return format("%.1fs", ms / 1000.0);
    return format("%sm%02ss", ms / 60_000, (ms % 60_000) / 1000);
}

/// `YYYY-MM-DD HH:MM:SS` of an RFC 3339 stamp, in its own offset.
string plainTime(string ts)
{
    return ts.length >= 19 ? ts[0 .. 10] ~ " " ~ ts[11 .. 19] : ts;
}

/// The `+HH:MM` offset of an RFC 3339 stamp (`Z` reads as `+00:00`).
string offsetOf(string ts)
{
    if (ts.length && (ts[$ - 1] == 'Z' || ts[$ - 1] == 'z')) return "+00:00";
    return ts.length >= 6 ? ts[$ - 6 .. $] : "";
}

string sanitizeMarkdown(string text)
{
    return splitNl(text).map!sanitizeTerminal.join("\n");
}

/// Drop control characters (C0/C1, so no escape sequence survives) and expand
/// tabs to 8-column stops.
public string sanitizeTerminal(string text) @trusted
{
    import std.uni : isControl;
    import std.utf : encode;
    import nano.resume : cells;
    string o;
    size_t col;
    foreach (dchar c; text)
    {
        if (c == '\t')
        {
            auto n = 8 - col % 8;
            o ~= " ".replicate(n);
            col += n;
            continue;
        }
        if (isControl(c)) continue;
        char[4] buf;
        auto len = encode(buf, c);
        o ~= buf[0 .. len].idup;
        col += cells(buf[0 .. len].idup);
    }
    return o;
}

// ---- ordered JSON, pretty-printed the way serde_json does ----

/// A JSON string literal escaped exactly as serde_json does: `"` and `\\`,
/// the short escapes for \b \f \n \r \t, `\u00xx` (lowercase hex) for the
/// other C0 controls, and everything else (DEL, `/`, non-ASCII) verbatim.
public string serdeString(string v)
{
    static immutable hex = "0123456789abcdef";
    string o = `"`;
    foreach (char c; v)
    {
        switch (c)
        {
        case '"': o ~= `\"`; break;
        case '\\': o ~= `\\`; break;
        case '\b': o ~= `\b`; break;
        case '\f': o ~= `\f`; break;
        case '\n': o ~= `\n`; break;
        case '\r': o ~= `\r`; break;
        case '\t': o ~= `\t`; break;
        default:
            if (c < 0x20) o ~= `\u00` ~ hex[c >> 4] ~ hex[c & 15];
            else o ~= c;
        }
    }
    return o ~ `"`;
}

/// The literal text of the last numeric member `key` in a compact JSON line.
string rawNumber(string line, string key)
{
    import std.string : lastIndexOf;
    if (line is null) return null;
    auto pat = `"` ~ key ~ `":`;
    auto at = line.lastIndexOf(pat);
    if (at < 0) return null;
    auto i = at + pat.length;
    while (i < line.length && line[i] == ' ') i++;
    auto start = i;
    while (i < line.length && "+-.0123456789eE".canFind(line[i])) i++;
    return i > start ? line[start .. i] : null;
}

double strtodOf(string text) @trusted
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;
    return strtod(text.toStringz, null);
}

/// Whether decimal `text` reads back as exactly `d` (C `strtod` is correctly
/// rounded; `std.conv.to!double` isn't always).
bool parsesTo(string text, double d) @trusted
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;
    return strtod(text.toStringz, null) == d;
}

/// A finite double the way serde_json (ryu) prints it: the shortest digits
/// that round-trip, always with a fraction or exponent (`2.0`, `1.3876`,
/// `1e-7`, `1.5e300`).
public string serdeFloat(double d) @trusted
{
    import std.math : isFinite, fabs;
    import std.conv : to;
    import std.string : indexOf;
    if (!isFinite(d)) return "null";
    string g;
    foreach (p; 1 .. 18)
    {
        g = format("%.*g", p, d);
        if (parsesTo(g, d)) break;
    }
    auto e = g.indexOf('e');
    if (e < 0) return g.indexOf('.') < 0 ? g ~ ".0" : g;
    // ryu: mantissa without trailing ".0", exponent without '+' or zero padding.
    auto mant = g[0 .. e];
    auto exp = g[e + 1 .. $].to!int;
    auto a = fabs(d);
    if (a >= 1e-5 && a < 1e16)
    {
        // %g chose exponent form where ryu prints plain decimal.
        auto plain = format("%.17f", d);
        foreach (p; 0 .. 18)
        {
            auto t = format("%.*f", p, d);
            if (parsesTo(t, d)) { plain = t; break; }
        }
        return plain.indexOf('.') < 0 ? plain ~ ".0" : plain;
    }
    return mant ~ "e" ~ exp.to!string;
}

struct J
{
    enum T { raw, obj, arr }
    T t;
    string text;
    string[] keys;
    J[] vals;
    J[] items;

    static J raw(string s) { J j; j.t = T.raw; j.text = s; return j; }
    static J s(string v) { return raw(serdeString(v)); }
    static J obj() { J j; j.t = T.obj; return j; }
    static J arr() { J j; j.t = T.arr; return j; }
    void add(string k, J v) { keys ~= k; vals ~= v; }

    string pretty(size_t indent) const
    {
        auto pad = "  ".replicate(indent);
        auto inner = "  ".replicate(indent + 1);
        final switch (t)
        {
        case T.raw: return text;
        case T.obj:
            if (!keys.length) return "{}";
            string o = "{\n";
            foreach (i, k; keys)
                o ~= inner ~ J.s(k).text ~ ": " ~ vals[i].pretty(indent + 1) ~ (i + 1 < keys.length ? ",\n" : "\n");
            return o ~ pad ~ "}";
        case T.arr:
            if (!items.length) return "[]";
            string o = "[\n";
            foreach (i, ref v; items) o ~= inner ~ v.pretty(indent + 1) ~ (i + 1 < items.length ? ",\n" : "\n");
            return o ~ pad ~ "]";
        }
    }
}

J rowJson(const ref Row r)
{
    J j = J.obj;
    if (r.id) j.add("id", J.raw(r.id.to!string));
    final switch (r.kind)
    {
    case Kind.user: j.add("kind", J.s("user")); break;
    case Kind.think: j.add("kind", J.s("think")); break;
    case Kind.assistant: j.add("kind", J.s("assistant")); break;
    case Kind.tool:
        j.add("kind", J.s("tool"));
        j.add("name", J.s(r.name));
        j.add("ok", J.raw(r.ok ? "true" : "false"));
        if (r.callId !is null) j.add("call_id", J.s(r.callId));
        if (r.toolDurationMs >= 0) j.add("duration_ms", J.raw(r.toolDurationMs.to!string));
        break;
    case Kind.toolCall:
        j.add("kind", J.s("tool_call"));
        j.add("id", J.s(r.callId));
        j.add("name", J.s(r.name));
        j.add("arguments", J.s(r.arguments));
        break;
    case Kind.compact:
        j.add("kind", J.s("compact"));
        if (r.compactMode !is null) j.add("mode", J.s(r.compactMode));
        if (r.compactModel !is null) j.add("model", J.s(r.compactModel));
        break;
    }
    j.add("text", J.s(r.text));
    if (r.hasUsage)
    {
        J u = J.obj;
        u.add("prompt_tokens", J.raw(r.promptTokens.to!string));
        u.add("completion_tokens", J.raw(r.completionTokens.to!string));
        u.add("total_tokens", J.raw(r.totalTokens.to!string));
        if (r.aic !is null) u.add("aic", J.raw(r.aic));
        j.add("usage", u);
    }
    if (r.durationMs >= 0) j.add("duration_ms", J.raw(r.durationMs.to!string));
    if (r.temperature !is null) j.add("temperature", J.s(r.temperature));
    if (r.thinkingLevel !is null) j.add("thinking_level", J.s(r.thinkingLevel));
    if (r.timestamp !is null) j.add("timestamp", J.s(r.timestamp));
    return j;
}

public:

/// Show `text` in `$PAGER` (default `less`, run through `sh -c`). False when
/// no pager could be started (exit 126/127), so the caller prints instead.
bool page(string text) @trusted
{
    import std.process : pipeShell, Redirect, wait, environment;
    import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN, SIG_DFL;
    auto pager = environment.get("PAGER", "");
    if (!trim(pager).length) pager = "less";
    string[string] env;
    if (environment.get("LESS") is null) env["LESS"] = "-R";
    auto old = signal(SIGPIPE, SIG_IGN);
    scope (exit) signal(SIGPIPE, old);
    try
    {
        auto p = pipeShell(pager, Redirect.stdin, env);
        try { p.stdin.write(text); p.stdin.close(); }
        catch (Exception) {}
        return pagerRan(wait(p.pid));
    }
    catch (Exception) return false;
}

/// Rows and columns of the terminal on `fd`, or zeros when unknown.
size_t[2] terminalSize(int fd = 1) @trusted
{
    import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
    winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0 && ws.ws_col > 0) return [ws.ws_row, ws.ws_col];
    return [0, 0];
}

bool pagerRan(int code) { return code != 126 && code != 127; }

/// Whether `text` would not fit on a `rows` x `cols` screen with room for the prompt.
bool needsPager(string text, size_t rows, size_t cols)
{
    cols = max(cols, 1);
    auto limit = rows >= 2 ? rows - 2 : 0;
    size_t used;
    foreach (line; text.lineSplitter)
    {
        used += wrappedRows(line, cols);
        if (used > limit) return true;
    }
    return false;
}

/// Terminal rows `line` takes when wrapped at `cols` (a wide glyph never
/// straddles the boundary).
size_t wrappedRows(string line, size_t cols) @trusted
{
    import std.utf : encode;
    import nano.resume : cells;
    size_t rows = 1, col;
    foreach (dchar c; line)
    {
        char[4] buf;
        auto w = cells(buf[0 .. encode(buf, c)].idup);
        if (!w) continue;
        if (col + w > cols && col > 0) { rows++; col = 0; }
        col += w;
    }
    return rows;
}

@trusted unittest
{
    import std.algorithm : canFind;
    string[] lines = [
        `{"type":"session","data":{"created_at":"2026-01-02T03:04:05.123+13:00","cwd":"/w","id":"s1","version":1}}`,
        `{"type":"message","data":{"role":"system","content":"sys"}}`,
        `{"type":"input","data":{"id":"i1","text":"fix\tthe\nbug"}}`,
        `{"type":"message","data":{"role":"user","content":"fix\tthe\nbug","timestamp":"2026-01-02T03:04:06+13:00"}}`,
        `{"type":"message","data":{"role":"assistant","content":"","thinking":"hmm","tool_calls":[{"id":"c1","name":"bash","arguments":{"command":"ls /"}}],"usage":{"prompt_tokens":1000,"completion_tokens":200,"total_tokens":1200},"duration_ms":1500,"timestamp":"2026-01-02T03:04:07+13:00"}}`,
        `{"type":"message","data":{"role":"tool","content":"a\u001b[2Jb","tool_call_id":"c1","name":"bash","timestamp":"2026-01-02T03:04:07.250+13:00"}}`,
        `{"type":"message","data":{"role":"assistant","content":"done","usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3},"duration_ms":40}}`,
        `{"type":"turn_end","data":{"input_id":"i1","response":"done"}}`,
        `{"type":"replace","data":{"messages":[{"role":"system","content":"x"}],"summarized":[2,7],"mode":"smart","model":"mock/m"}}`,
        `{"type":"input","data":{"id":"i2","text":"crash"}}`,
    ];
    JSONValue[] recs;
    ulong[] nums;
    foreach (i, l; lines) { recs ~= parseJSON(l); nums ~= i + 1; }
    auto t = Trajectory.fromRecords(recs, nums);
    assert(t.turns.length == 2);
    auto t1 = t.turns[0];
    assert(t1.number == 1 && t1.rows.length == 7);
    assert(t1.rows[1].kind == Kind.think && t1.rows[1].hasUsage && t1.rows[2].text == "(calling bash)");
    assert(!t1.rows[2].hasUsage, "metrics live on the THINK row");
    assert(t1.rows[3].kind == Kind.toolCall && t1.rows[3].arguments == `{"command":"ls /"}`);
    assert(t1.rows[4].label == "TOOL bash (250ms, ok)" && t1.rows[4].id == 6);
    assert(t1.summary == "2 calls · 1 tool · 202 out · 1.5s", t1.summary);
    // The compaction lands in turn 1; the crashed turn gets a USER row.
    assert(t1.rows[6].label == "COMPACT (smart)");
    assert(t1.rows[6].text == "mode: smart, model: mock/m, folded log lines 2–7, 1 message(s) retained");
    assert(t.turns[1].rows.length == 1 && t.turns[1].rows[0].text == "crash");
    assert(t.turns[1].summary == "(no activity)");
    auto plain = t.toPlain;
    assert(plain.canFind("Started 2026-01-02 03:04:05"));
    assert(plain.canFind("── Turn 1 ──  fix the bug"));
    assert(plain.canFind("      a[2Jb") && !plain.canFind("\x1b"), "escapes stripped");
    assert(plain.canFind("  · #5 THINK  1.2k tok, 1.5s"));
    auto md = t.toMarkdown;
    assert(md.canFind("_Started 2026-01-02 03:04:05 +13:00_"));
    assert(md.canFind("> fix     the\n> bug"));
    auto js = parseJSON(t.toJson);
    assert(js["turns"][0]["rows"][3]["kind"].str == "tool_call");
    assert(t.toJson.canFind(`"kind": "tool",` ~ "\n" ~ `          "name": "bash",`));
}

@trusted unittest
{
    // Synthetic final answer after report_outcome isn't a model call.
    Turn t = Turn(1, "go");
    Row a;
    a.kind = Kind.assistant;
    a.text = "ok";
    a.hasUsage = true;
    a.totalTokens = 5;
    Row fin;
    fin.kind = Kind.assistant;
    fin.text = "all done";
    t.rows = [a, fin];
    t.response = "all done";
    t.hasOutcome = true;
    t.outcomeStatus = "completed";
    assert(t.summary == "1 call · completed", t.summary);
    t.hasOutcome = false;
    assert(t.summary == "2 calls");
}

unittest
{
    assert(fence("a\n```d\nb\n```") == "````\na\n```d\nb\n```\n````");
    assert(formatDuration(999) == "999ms" && formatDuration(61_000) == "1m01s" && formatTokens(1250) == "1.2k");
    assert(needsPager("a\nb\nc", 4, 80) && !needsPager("a\nb", 4, 80));
    assert(wrappedRows("ab漢", 3) == 2 && wrappedRows("", 3) == 1);
    assert(!pagerRan(127) && pagerRan(1));
    assert(sanitizeTerminal("a\tb") == "a       b");
    assert(splitNl("") == [""] && splitNl("a\n") == ["a", ""]);
    assert(serdeString("a\x1b[0m/\"\\\t\x7f€") == `"a\u001b[0m/\"\\\t` ~ "\x7f€\"");
    assert(serdeFloat(1.3876) == "1.3876", serdeFloat(1.3876)); assert(serdeFloat(39.4544) == "39.4544", serdeFloat(39.4544)); assert(serdeFloat(2.0) == "2.0", serdeFloat(2.0));
    double tenth = 0.1, fifth = 0.2;
    assert(serdeFloat(tenth + fifth) == "0.30000000000000004", serdeFloat(tenth + fifth));
    assert(serdeFloat(1e-7) == "1e-7" && serdeFloat(1.5e300) == "1.5e300");
    assert(rawNumber(`{"usage":{"aic":1.3876,"x":1}}`, "aic") == "1.3876" && rawNumber("{}", "aic") is null);
    assert(serdeFloat(strtodOf("1.3876")) == "1.3876");
    assert(serdeFloat(123456789.0) == "123456789.0" && serdeFloat(0.00012) == "0.00012");
}
