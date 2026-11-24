/// Session trajectory: a turn-grouped ledger rebuilt from a session log
/// (port of `trajectory.rs`). Each turn holds the user input that opened it,
/// one row per thinking block, assistant answer, tool call and tool result
/// (with per-request usage and timing), and compactions; `/trajectory` and
/// `--trajectory ID [--json|--markdown]` render it as plain text, serde-shaped
/// JSON, or Markdown.
module nano.trajectory;

@safe:
import nano.safeio : jsonText, jsonPretty, jsonWholeAsDouble, jsonSigned;
import nano.arith : saturatingSub;

import std.algorithm : canFind, map, max, sum, filter;
import std.array : join, replicate, split, array;
import std.conv : to;
import std.format : format;
import std.json;
import std.string : lineSplitter;
import std.typecons : Nullable;

enum Kind { user, think, assistant, tool, toolCall, compact, subagent }

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
    /// An `agent` result: the sub-agent's own log, and its rows (expanded
    /// by `load` when the log is there).
    string subLog;
    Row[] sub;
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

    string cited() pure const
    {
        return id ? format("#%s %s", id, label) : label;
    }

    string label() pure const
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
        case Kind.subagent: return compactModel !is null ? format("SUB-AGENT %s (%s)", name, compactModel)
            : "SUB-AGENT " ~ name;
        }
    }

    /// The per-request metric suffix (`1.2k tok, 3.4s`), when known.
    string metric() pure const
    {
        string[] bits;
        if (hasUsage && totalTokens > 0) bits ~= formatTokens(totalTokens) ~ " tok";
        if (kind == Kind.subagent && aic !is null) bits ~= aic ~ " AIC";
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
    string summary() pure const
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
    static Trajectory fromRecords(const JSONValue[] records, const ulong[] lines, const string[] raws = null)
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
            case "subagent_usage":
                current.rows ~= subagentUsageRow(data, lines[i], i < raws.length ? raws[i] : null);
                break;
            default: // plan, hooks: not ledger rows
            }
        }
        flush(current);
        return t;
    }

    /// Every request's usage in the session, sub-agents included (issue
    /// #341): main-agent rows plus one `subagent_usage` row per finished
    /// sub-agent. Rows expanded from a child log are not counted again.
    Totals totals() pure const
    {
        Totals t;
        foreach (ref turn; turns)
            foreach (ref r; turn.rows)
            {
                if (!r.hasUsage) continue;
                auto into = r.kind == Kind.subagent ? &t.subagents : &t.main;
                into.inputTokens += r.promptTokens;
                into.outputTokens += r.completionTokens;
                if (r.aic !is null)
                {
                    into.hasAic = true;
                    into.aic += r.aic.to!double;
                }
                if (r.kind == Kind.subagent) t.subagentCount++;
            }
        return t;
    }

    /// The whole ledger as plain text, every row in full.
    string toPlain() pure const
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
                if (row.subLog.length) o ~= sanitizeTerminal("      ↳ sub-agent log: " ~ row.subLog);
                foreach (ref sr; row.sub)
                {
                    o ~= sanitizeTerminal(format("      │ %s %s", bullet(sr), sr.cited));
                    foreach (l; splitNl(sr.text)) o ~= sanitizeTerminal("      │     " ~ l);
                }
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
        auto tl = totals.line;
        if (tl !is null) o ~= ["", tl];
        return o.join("\n");
    }

    /// The ledger as JSON, shaped (and ordered) like Rust's serde output.
    string toJson() pure const
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
        auto tot = totals;
        if (tot.subagentCount)
        {
            J tj = J.obj;
            tj.add("main", usageJson(tot.main));
            tj.add("subagents", usageJson(tot.subagents));
            tj.add("subagent_count", J.raw(tot.subagentCount.to!string));
            root.add("totals", tj);
        }
        return root.pretty(0);
    }

    /// The ledger as Markdown.
    string toMarkdown() pure const
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
                if (row.subLog.length) o ~= ["", "_Sub-agent log: `" ~ sanitizeMarkdown(row.subLog) ~ "`_"];
                foreach (ref sr; row.sub)
                {
                    o ~= ["", "#### ↳ " ~ sanitizeMarkdown(sr.cited)];
                    auto st = trim(sr.text);
                    if (st.length) o ~= ["", fence(sanitizeMarkdown(st))];
                }
            }
            if (turn.response !is null)
            {
                auto resp = trim(turn.response);
                if (resp.length) o ~= ["", "**Response**", "", "> " ~ quoteLines(sanitizeMarkdown(resp))];
            }
        }
        auto tl = totals.line;
        if (tl !is null) o ~= ["", "_" ~ tl ~ "_"];
        o ~= "";
        return o.join("\n");
    }
}

/// Summed usage of one side (main agent or sub-agents).
struct UsageSum
{
    long inputTokens, outputTokens;
    bool hasAic;
    double aic = 0;
}

/// Session usage totals, split into the main agent and its sub-agents.
struct Totals
{
    UsageSum main, subagents;
    size_t subagentCount;

    /// `Total: …` (null when nothing was spent).
    string line() pure const
    {
        auto all = main.inputTokens + main.outputTokens + subagents.inputTokens + subagents.outputTokens;
        if (all <= 0 && !main.hasAic && !subagents.hasAic) return null;
        string s = format("Total: %s tok", formatTokens(all));
        if (main.hasAic || subagents.hasAic) s ~= format(", %s AIC", serdeFloat(main.aic + subagents.aic));
        if (subagentCount)
        {
            s ~= format(" (sub-agents ×%s: %s tok", subagentCount,
                formatTokens(subagents.inputTokens + subagents.outputTokens));
            if (subagents.hasAic) s ~= format(", %s AIC", serdeFloat(subagents.aic));
            s ~= ")";
        }
        return s;
    }
}

/// Every committed record of the log at `path`, with physical line numbers.
/// `expectedId`, when given, must match the header (a renamed or misplaced
/// log is refused). A torn trailing line is dropped, as on resume.
Trajectory load(string path, string expectedId = null)
{
    import nano.session : formatVersion, logText;
    string text;
    try text = logText(path);
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
                throw new Exception(format("session log header id %s does not match %s", JSONValue(id).jsonText,
                    JSONValue(expectedId).jsonText));
        }
        else if (!records.length)
            throw new Exception(format("session log %s does not start with a session header", path));
        records ~= rec;
        lines ~= lineNo;
        raws ~= line;
    }
    auto t = Trajectory.fromRecords(records, lines, raws);
    // Sub-agents' logs (the `agent` tool) expand under their results.
    import std.file : exists;
    foreach (ref turn; t.turns)
        foreach (ref row; turn.rows)
        {
            if (!row.subLog.length) continue;
            // Session tidying may have compressed the child log since.
            auto sub = row.subLog.exists ? row.subLog
                : (row.subLog ~ ".gz").exists ? row.subLog ~ ".gz" : null;
            if (sub !is null)
                foreach (ref st; load(sub).turns) row.sub ~= st.rows;
        }
    return t;
}

private:

string str(const JSONValue j, string key, string dflt) pure
{
    if (j.type != JSONType.object) return dflt;
    if (auto v = key in j) if (v.type == JSONType.string) return v.str;
    return dflt;
}

/// A `subagent_usage` record's row (issue #341). The child log is kept in
/// `text` only, not `subLog`, so `load` does not expand it a second time.
Row subagentUsageRow(const JSONValue d, ulong line, string rawLine)
{
    Row r;
    r.id = line;
    r.kind = Kind.subagent;
    r.name = str(d, "id", "");
    r.compactModel = str(d, "model", null);
    auto log = str(d, "log", "");
    r.text = log.length ? "log: " ~ log : "";
    r.timestamp = str(d, "recorded_at", null);
    if (d.type != JSONType.object) return r;
    long n(string k) { long x; if (auto p = k in d) if (jsonSigned(*p, x)) return x; return 0; }
    r.hasUsage = true;
    r.promptTokens = n("input_tokens");
    r.completionTokens = n("output_tokens");
    r.totalTokens = r.promptTokens + r.completionTokens;
    if (auto a = "aic" in d)
        if (a.type == JSONType.float_ || a.type == JSONType.integer || a.type == JSONType.uinteger)
        {
            auto lit = rawNumber(rawLine, "aic");
            r.aic = serdeFloat(lit !is null ? strtodOf(lit)
                : a.type == JSONType.float_ ? a.floating : jsonWholeAsDouble(*a));
        }
    return r;
}

void appendMessageRows(ref Turn turn, const JSONValue m, ulong line, ref string prevTs, string rawLine = null)
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
                long n(string k) { long x; if (auto p = k in *u) if (jsonSigned(*p, x)) return x; return 0; }
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
                            : a.type == JSONType.float_ ? a.floating : jsonWholeAsDouble(*a));
                    }
            }
        if (auto d = "duration_ms" in m) { long x; if (jsonSigned(*d, x)) r.durationMs = x; }
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
                    foreach (b; blocks.arrayNoRef)
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
        if (auto c = "tool_calls" in m) if (c.type == JSONType.array) calls = c.arrayNoRef;
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
                : args.jsonText(JSONOptions.doNotEscapeSlashes);
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
                foreach (at; atts.arrayNoRef)
                    if (at.type == JSONType.object)
                    {
                        if (text.length) text ~= "\n";
                        text ~= Attachment.fromJSON(at).placeholder;
                    }
        r.text = text;
        r.subLog = str(m, "sub_log", null);
        r.timestamp = ts;
        turn.rows ~= r;
    }
    foreach (ref r; turn.rows[first .. $]) r.id = line;
    if (ts !is null) prevTs = ts;
}

string scalarText(const JSONValue m, string key) pure
{
    if (auto v = key in m)
    {
        if (v.type == JSONType.string) return v.str;
        if (v.type != JSONType.null_) return v.jsonText;
    }
    return null;
}

/// Milliseconds from `a` to `b` (RFC 3339), or -1 when negative/unparseable.
long millisBetween(string a, string b)
{
    import std.datetime.systime : SysTime;
    try
    {
        auto d = (SysTime.fromISOExtString(b) - SysTime.fromISOExtString(a)).total!"msecs";
        return d >= 0 ? d : -1;
    }
    catch (Exception) return -1; // an unparsable timestamp has no duration (-1)
}

string compactText(const JSONValue data, string mode, string model) pure
{
    string[] parts;
    if (mode !is null) parts ~= "mode: " ~ mode;
    if (model !is null) parts ~= "model: " ~ model;
    if (auto s = "summarized" in data)
        if (s.type == JSONType.array && s.arrayNoRef.length == 2)
            parts ~= format("folded log lines %s–%s", s.arrayNoRef[0].jsonText, s.arrayNoRef[1].jsonText);
    size_t n;
    if (auto ms = "messages" in data) if (ms.type == JSONType.array) n = ms.arrayNoRef.length;
    parts ~= format("%s message(s) retained", n);
    return parts.join(", ");
}

string turnTitle(const ref Turn t) pure
{
    return t.number == 0 ? "Preamble" : format("Turn %s", t.number);
}

string turnHeader(const ref Turn t) pure
{
    auto title = turnTitle(t);
    return t.input !is null ? format("── %s ──  %s", title, oneLine(t.input, 60)) : format("── %s ──", title);
}

string bullet(const ref Row r) pure
{
    final switch (r.kind)
    {
    case Kind.tool: return r.ok ? "•" : "✗";
    case Kind.toolCall: return "→";
    case Kind.think: return "·";
    case Kind.compact: return "↺";
    case Kind.subagent: return "⇣";
    case Kind.user, Kind.assistant: return "▸";
    }
}

string fence(string text) pure
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
string[] splitNl(string s) pure
{
    string[] o;
    size_t start;
    foreach (i, char c; s)
        if (c == '\n') { o ~= s[start .. i]; start = i + 1; }
    return o ~ s[start .. $];
}

string quoteLines(string s) pure { import std.array : replace; return s.replace("\n", "\n> "); }

bool isWs(dchar c) pure { import std.uni : isWhite; return isWhite(c); }

string trim(string s) pure
{
    import std.string : strip;
    return strip(s);
}

string trimStart(const(char)[] s) pure
{
    import std.string : stripLeft;
    return stripLeft(s).idup;
}

string oneLine(string text, size_t maxChars) pure
{
    import std.array : split;
    return truncate(text.split.join(" "), maxChars);
}

public string truncate(string text, size_t maxChars) pure
{
    import std.range : walkLength, take;
    if (text.walkLength <= maxChars) return text;
    return text.take(maxChars ? maxChars - 1 : 0).to!string ~ "…";
}

public string formatTokens(long t) pure
{
    return t >= 1000 ? format("%.1fk", t / 1000.0) : t.to!string;
}

public string formatDuration(long ms) pure
{
    if (ms < 1000) return format("%sms", ms);
    if (ms < 60_000) return format("%.1fs", ms / 1000.0);
    return format("%sm%02ss", ms / 60_000, (ms % 60_000) / 1000);
}

/// `YYYY-MM-DD HH:MM:SS` of an RFC 3339 stamp, in its own offset.
string plainTime(string ts) pure
{
    return ts.length >= 19 ? ts[0 .. 10] ~ " " ~ ts[11 .. 19] : ts;
}

/// The `+HH:MM` offset of an RFC 3339 stamp (`Z` reads as `+00:00`).
string offsetOf(string ts) pure
{
    if (ts.length && (ts[$ - 1] == 'Z' || ts[$ - 1] == 'z')) return "+00:00";
    return ts.length >= 6 ? ts[$ - 6 .. $] : "";
}

string sanitizeMarkdown(string text) pure
{
    return splitNl(text).map!sanitizeTerminal.join("\n");
}

/// Drop control characters (C0/C1) and whole escape sequences (CSI to its
/// final byte, OSC to BEL or ST; a lone ESC drops alone), so no escape body
/// shows as text, and the U+2028/U+2029 separators a terminal folds into a
/// row; expand tabs to 8-column stops measured in cells. `keepNewlines`
/// keeps `\n` (resetting the column) for multi-line text (main.rs
/// sanitize_terminal_text / sanitize_terminal_line).
public string terminalSafe(string text, bool keepNewlines = false) pure
{
    import std.uni : isControl;
    import std.utf : decode, encode;
    import nano.resume : cells;
    string o;
    size_t col, i;
    while (i < text.length)
    {
        dchar c = decode(text, i);
        if (c == '\x1b')
        {
            if (i < text.length && text[i] == '[')
            {
                ++i;
                while (i < text.length)
                {
                    auto f = decode(text, i);
                    if (f >= '@' && f <= '~') break;
                }
            }
            else if (i < text.length && text[i] == ']')
            {
                ++i;
                while (i < text.length)
                {
                    auto f = decode(text, i);
                    if (f == '\x07') break;
                    if (f == '\x1b' && i < text.length && text[i] == '\\') { ++i; break; }
                }
            }
            continue;
        }
        if (c == '\t')
        {
            auto n = 8 - col % 8;
            o ~= " ".replicate(n);
            col += n;
            continue;
        }
        if (c == '\n' && keepNewlines) { o ~= '\n'; col = 0; continue; }
        if (c == '\u2028' || c == '\u2029' || isControl(c)) continue;
        // The frame's private-use wrap marks (U+E002-U+E004) are metadata,
        // never text: a literal one would be read as a wrap or verbatim mark.
        if (c >= '\uE002' && c <= '\uE004') c = '\uFFFD';
        char[4] buf;
        auto len = encode(buf, c);
        o ~= buf[0 .. len].idup;
        col += cells(buf[0 .. len].idup);
    }
    return o;
}

// rust: main.rs::sanitize_strips_whole_ansi_sequences
unittest
{
    assert(terminalSafe("\x1b[31mred\x1b[0m") == "red");
    assert(terminalSafe("a\x1b]52;c;Zm8=\x07b") == "ab");
    assert(terminalSafe("a\x1b]0;title\x1b\\b") == "ab");
    assert(terminalSafe("a\x1bZb") == "aZb");
}

// rust: main.rs::sanitize_terminal_expands_tabs_to_spaces, main.rs::sanitize_terminal_tab_stops_track_unicode_cell_width
unittest
{
    assert(terminalSafe("     1\tleft\tright", true) == "     1  left    right");
    assert(terminalSafe("     1\tleft\tright") == "     1  left    right");
    assert(terminalSafe("a\tb", true) == "a       b");
    assert(terminalSafe("ab\tc\nx\ty", true) == "ab      c\nx       y");
    assert(terminalSafe("hi\x1b[2J\tthere") == "hi      there");
    foreach (keep; [false, true])
    {
        assert(terminalSafe("界\tX", keep) == "界" ~ " ".replicate(6) ~ "X");
        assert(terminalSafe("界界\tX", keep) == "界界" ~ " ".replicate(4) ~ "X");
        assert(terminalSafe("e\u0301\tX", keep) == "e\u0301" ~ " ".replicate(7) ~ "X");
    }
}

// rust: main.rs::sanitize_terminal_text_preserves_line_feeds, main.rs::sanitize_terminal_text_strips_control_and_escape_sequences, main.rs::sanitize_terminal_text_strips_unicode_line_separators
unittest
{
    assert(terminalSafe("one\ntwo\nthree", true) == "one\ntwo\nthree");
    assert(terminalSafe("one\x1b[2J\ntwo", true) == "one\ntwo");
    assert(terminalSafe("one\ntwo") == "onetwo", "a single-line field drops the line feed");
    assert(terminalSafe("hi\x1b[2Jthere", true) == "hithere");
    assert(terminalSafe("a\x07\x00b\tc", true) == "ab      c");
    assert(terminalSafe("plain — label", true) == "plain — label");
    assert(terminalSafe("mem-evil\u2028forged row", true) == "mem-evilforged row");
    assert(terminalSafe("head\u2029forged row", true) == "headforged row");
    assert(terminalSafe("café — label", true) == "café — label");
    assert(terminalSafe("/tmp/a\uE003b\uE002c\uE004d") == "/tmp/a\uFFFDb\uFFFDc\uFFFDd");
}

/// Drop control characters (C0/C1, so no escape sequence survives) and expand
/// tabs to 8-column stops (trajectory.rs sanitize_terminal: escape bodies
/// stay as text, only the bytes that drive a terminal go).
public string sanitizeTerminal(string text) pure
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
public string serdeString(string v) pure
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
string rawNumber(string line, string key) pure
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

double strtodOf(string text) pure
{
    import nano.safeio : cStrtod;
    return cStrtod(text);
}

/// Whether decimal `text` reads back as exactly `d` (C `strtod` is correctly
/// rounded; `std.conv.to!double` isn't always).
bool parsesTo(string text, double d) pure
{
    return strtodOf(text) == d;
}

/// A finite double the way serde_json (ryu) prints it: the shortest digits
/// that round-trip, always with a fraction or exponent (`2.0`, `1.3876`,
/// `1e-7`, `1.5e300`).
public string serdeFloat(double d) pure
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

    static J raw(string s) pure { J j; j.t = T.raw; j.text = s; return j; }
    static J s(string v) pure { return raw(serdeString(v)); }
    static J obj() pure { J j; j.t = T.obj; return j; }
    static J arr() pure { J j; j.t = T.arr; return j; }
    void add(string k, J v) pure { keys ~= k; vals ~= v; }

    string pretty(size_t indent) pure const
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

J usageJson(const ref UsageSum u) pure
{
    J j = J.obj;
    j.add("input_tokens", J.raw(u.inputTokens.to!string));
    j.add("output_tokens", J.raw(u.outputTokens.to!string));
    if (u.hasAic) j.add("aic", J.raw(serdeFloat(u.aic)));
    return j;
}

J rowJson(const ref Row r) pure
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
    case Kind.subagent:
        j.add("kind", J.s("subagent"));
        j.add("name", J.s(r.name));
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
    if (r.subLog.length)
    {
        j.add("sub_log", J.s(r.subLog));
        J rs = J.arr;
        foreach (ref sr; r.sub) rs.items ~= rowJson(sr);
        j.add("sub_rows", rs);
    }
    return j;
}

public:

/// Show `text` in `$PAGER` (default `less`, run through `sh -c`). False when
/// no pager could be started (exit 126/127), so the caller prints instead.
bool page(string text)
{
    import std.process : pipeShell, Redirect, wait, environment;
    import nano.safeio : withSigpipeIgnored;
    auto pager = environment.get("PAGER", "");
    if (!trim(pager).length) pager = "less";
    string[string] env;
    if (environment.get("LESS") is null) env["LESS"] = "-R";
    return withSigpipeIgnored(() {
        try
        {
            auto p = pipeShell(pager, Redirect.stdin, env);
            try { p.stdin.write(text); p.stdin.close(); }
            catch (Exception) {} // the pager quit early (EPIPE): fine, it has what it showed
            return pagerRan(wait(p.pid));
        }
        catch (Exception) return false; // no pager: the caller prints the text instead
    });
}

/// Rows and columns of the terminal on `fd`, or zeros when unknown.
size_t[2] terminalSize(int fd = 1) nothrow
{
    import safeio = nano.safeio;
    return safeio.terminalSize(fd);
}

bool pagerRan(int code) pure nothrow { return code != 126 && code != 127; }

/// Whether `text` would not fit on a `rows` x `cols` screen with room for the prompt.
bool needsPager(string text, size_t rows, size_t cols) pure
{
    cols = max(cols, 1);
    auto limit = saturatingSub(rows, 2);
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
size_t wrappedRows(string line, size_t cols) pure
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

// rust: trajectory.rs::tool_invocation_is_counted_once_for_call_and_result
// rust: trajectory.rs::rows_cite_their_session_log_line
// rust: trajectory.rs::json_and_markdown_round_trip
// rust: trajectory.rs::plain_render_sanitizes_untrusted_input
// rust: trajectory.rs::plain_render_lists_turns_and_summaries
// rust: trajectory.rs::crashed_input_materializes_opening_user_row
// rust: trajectory.rs::compaction_becomes_a_row
// rust: trajectory.rs::groups_records_into_turns_and_rows
unittest
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

// rust: trajectory.rs::synthetic_final_answer_is_not_a_model_call
unittest
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

// rust: trajectory.rs::sanitize_terminal_strips_control_sequences
// rust: trajectory.rs::a_pager_that_could_not_start_falls_back
// rust: trajectory.rs::needs_pager_counts_wrapped_rows
// rust: trajectory.rs::durations_and_tokens_format_readably
// rust: trajectory.rs::markdown_fences_survive_embedded_backticks
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

unittest
{
    // A uinteger-tagged aic (JSONValue(2u)) with no raw line must be read, not throw.
    Turn t;
    string prev;
    auto m = parseJSON(`{"role":"assistant","content":"x","usage":{}}`);
    m["usage"]["aic"] = JSONValue(2u);
    appendMessageRows(t, m, 1, prev);
    bool seen;
    foreach (r; t.rows) if (r.aic !is null) { seen = true; assert(r.aic == "2" || r.aic == "2.0", r.aic); }
    assert(seen);
}

unittest
{
    // uinteger-tagged usage counts and duration_ms are read, not dropped to 0.
    Turn t;
    string prev;
    auto m = parseJSON(`{"role":"assistant","content":"x","usage":{}}`);
    m["usage"]["prompt_tokens"] = JSONValue(5u);
    m["usage"]["completion_tokens"] = JSONValue(6u);
    m["usage"]["total_tokens"] = JSONValue(11u);
    m["duration_ms"] = JSONValue(42u);
    appendMessageRows(t, m, 1, prev);
    bool seen;
    foreach (r; t.rows) if (r.hasUsage)
    {
        seen = true;
        assert(r.promptTokens == 5 && r.completionTokens == 6 && r.totalTokens == 11);
        assert(r.durationMs == 42);
    }
    assert(seen);
}

// Issue #341: a `subagent_usage` record is one row, counted once in the
// totals (beside the main agent's own usage), in every output format; a
// log without it has no sub-agent totals.
unittest
{
    auto recs = [
        `{"type":"session","data":{"id":"s1","version":1}}`,
        `{"type":"input","data":{"id":"i1","text":"go"}}`,
        `{"type":"message","data":{"role":"assistant","content":"ok","usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"aic":0.25}}}`,
        `{"type":"subagent_usage","data":{"version":1,"id":"sub-1","log":"/l/c.jsonl","model":"mock/b","input_tokens":1000,"output_tokens":200,"aic":1.5}}`,
        `{"type":"turn_end","data":{"input_id":"i1","response":"ok"}}`,
    ];
    JSONValue[] parsed;
    ulong[] lines;
    foreach (i, l; recs) { parsed ~= parseJSON(l); lines ~= i + 1; }
    auto t = Trajectory.fromRecords(parsed, lines, recs);
    auto tot = t.totals;
    assert(tot.subagentCount == 1);
    assert(tot.main.inputTokens == 100 && tot.main.outputTokens == 20 && tot.main.aic == 0.25);
    assert(tot.subagents.inputTokens == 1000 && tot.subagents.outputTokens == 200 && tot.subagents.aic == 1.5);
    auto plain = t.toPlain;
    assert(plain.canFind("SUB-AGENT sub-1 (mock/b)"), plain);
    assert(plain.canFind("Total: 1.3k tok, 1.75 AIC (sub-agents ×1: 1.2k tok, 1.5 AIC)"), plain);
    assert(t.toMarkdown.canFind("SUB-AGENT sub-1"));
    auto j = parseJSON(t.toJson);
    assert(j["totals"]["subagents"]["input_tokens"].integer == 1000);
    assert(j["turns"][0]["rows"][2]["kind"].str == "subagent");
    // An old log without the record: no sub-agent totals, JSON unchanged.
    auto old = Trajectory.fromRecords(parsed[0 .. 3] ~ parsed[4], [1UL, 2, 3, 5], recs[0 .. 3] ~ recs[4]);
    assert(old.totals.subagentCount == 0 && "totals" !in parseJSON(old.toJson));
}
