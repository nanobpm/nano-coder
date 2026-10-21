/// Session logs (JSONL: a header line, then one message per line) and
/// project instructions (AGENTS.md and friends).
module nano.session;

import std.json;
import std.format : format;
import std.file;
import std.path;
import std.stdio : File;
import std.string : strip, lineSplitter;
import std.stdio : fileno;
import std.datetime.systime : Clock;
import std.process : environment;
import std.algorithm : sort, filter, map;
import std.array : array;
import nano.llm;

string sessionDir()
{
    if (auto x = environment.get("NANO_CODER_D_SESSIONS")) return x;
    version (OSX)
        return buildPath(expandTilde("~"), "Library", "Application Support", "nano-coder-d", "sessions");
    else
        return buildPath(environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share")), "nano-coder-d", "sessions");
}

/// Session log format version (Rust `session::FORMAT_VERSION`).
enum int formatVersion = 1;

/// The current local time as RFC 3339 with offset and microseconds, as
/// chrono writes it (`2026-10-21T11:24:12.855560+13:00`).
string nowStamp()
{
    return stamp(Clock.currTime);
}

/// `t` in local time as RFC 3339 with offset and microseconds (chrono's form).
string stamp(SysTime when)
{
    auto t = when.toLocalTime;
    auto off = t.utcOffset;
    auto mins = off.total!"minutes";
    char sign = mins < 0 ? '-' : '+';
    if (mins < 0) mins = -mins;
    return format("%04d-%02d-%02dT%02d:%02d:%02d.%06d%s%02d:%02d", t.year, cast(int) t.month, t.day, t.hour,
        t.minute, t.second, t.fracSecs.total!"usecs", sign, mins / 60, mins % 60);
}

/// A new session id: `sess-YYYYmmddTHHMMSS-xxxxxxxx` (UTC).
string newSessionId()
{
    import std.random : uniform;
    import std.datetime.timezone : UTC;
    auto t = Clock.currTime(UTC());
    return format("sess-%04d%02d%02dT%02d%02d%02d-%08x", t.year, cast(int) t.month, t.day, t.hour, t.minute,
        t.second, uniform!uint);
}

/// Session ids name files: 1-128 of [A-Za-z0-9._-], not starting with '.'.
void validateId(string id)
{
    import std.algorithm : all;
    import std.ascii : isAlphaNum;
    bool ok = id.length && id.length <= 128 && id[0] != '.'
        && id.all!(c => c.isAlphaNum || c == '-' || c == '_' || c == '.');
    if (!ok)
        throw new Exception(format("invalid session id %s: use 1-128 of [A-Za-z0-9._-], not starting with '.'",
            JSONValue(id).toString));
}

/// A message as a session-log record body (Rust's serde form of `Message`).
JSONValue messageRecord(const ref Message m)
{
    JSONValue j = ["role": roleName(m.role), "content": m.content];
    if (m.extra.type == JSONType.object)
        foreach (k, v; m.extra.object) j[k] = v;
    if (m.toolCalls.length)
    {
        JSONValue[] calls;
        foreach (c; m.toolCalls)
        {
            JSONValue cj = ["id": c.id, "name": c.name];
            // Rust's shape: malformed text is kept beside an empty object.
            cj["arguments"] = c.invalidArguments.length ? parseJSON("{}") : parseJSON(c.arguments.toString);
            if (c.invalidArguments.length) cj["malformed_arguments"] = c.invalidArguments;
            if (c.itemId.length) cj["item_id"] = c.itemId;
            calls ~= cj;
        }
        j["tool_calls"] = calls;
    }
    if (m.attachments.length)
    {
        JSONValue[] list;
        foreach (ref a; m.attachments) list ~= a.toJSON;
        j["attachments"] = list;
    }
    if (m.toolCallId.length) j["tool_call_id"] = m.toolCallId;
    if (m.toolName.length) j["name"] = m.toolName;
    if (m.isError) j["is_error"] = true;
    if (m.timestamp.length) j["timestamp"] = m.timestamp;
    if (m.thinking.length) j["thinking"] = m.thinking;
    if (m.thinkingBlocks.length)
    {
        JSONValue[] blocks;
        foreach (ref b; m.thinkingBlocks) blocks ~= parseJSON(b.toString);
        j["thinking_blocks"] = blocks;
    }
    if (m.hasUsage)
        j["usage"] = JSONValue(["prompt_tokens": m.usage.inputTokens, "completion_tokens": m.usage.outputTokens,
            "total_tokens": m.usage.inputTokens + m.usage.outputTokens]);
    if (m.durationMs >= 0) j["duration_ms"] = m.durationMs;
    if (m.stopReason.length) j["stop_reason"] = m.stopReason;
    if (m.logLine) j["log_line"] = m.logLine;
    return j;
}

/// Parse a message record body.
Message messageFromRecord(JSONValue j)
{
    import std.algorithm : countUntil;
    Message m;
    auto names = ["system", "user", "assistant", "tool"];
    auto r = names.countUntil(j["role"].str);
    if (r < 0) throw new Exception("unknown role " ~ j["role"].str);
    m.role = cast(Role) r;
    JSONValue extra = string[string].init;
    foreach (k, v; j.object)
    {
        switch (k)
        {
        case "role": break;
        case "content": m.content = v.type == JSONType.string ? v.str : ""; break;
        case "tool_calls":
            foreach (c; v.array)
            {
                auto args = c["arguments"];
                auto mal = "malformed_arguments" in c;
                // Legacy logs held malformed text as a string `arguments`.
                auto raw = mal && mal.type == JSONType.string ? mal.str
                    : args.type == JSONType.string ? args.str : args.toString;
                auto call = ToolCall.fromRaw(c["id"].str, c["name"].str, raw);
                if (auto iid = "item_id" in c) if (iid.type == JSONType.string) call.itemId = iid.str;
                m.toolCalls ~= call;
            }
            break;
        case "attachments":
            if (v.type == JSONType.array)
                foreach (a; v.array)
                    if (a.type == JSONType.object) m.attachments ~= Attachment.fromJSON(a);
            break;
        case "tool_call_id": m.toolCallId = v.str; break;
        case "name": m.toolName = v.str; break;
        case "is_error": m.isError = v.type == JSONType.true_; break;
        case "timestamp": m.timestamp = v.str; break;
        case "thinking": m.thinking = v.str; break;
        case "thinking_blocks":
            if (v.type == JSONType.array) m.thinkingBlocks = v.array.dup;
            break;
        case "usage":
            m.hasUsage = true;
            if (auto p = "prompt_tokens" in v) m.usage.inputTokens = p.integer;
            if (auto p = "completion_tokens" in v) m.usage.outputTokens = p.integer;
            break;
        case "duration_ms": m.durationMs = v.integer; break;
        case "stop_reason": m.stopReason = v.str; break;
        case "log_line": if (v.type == JSONType.integer) m.logLine = v.integer; break; // direct records: the physical line wins
        default: extra[k] = v;
        }
    }
    if (extra.object.length) m.extra = extra;
    return m;
}

/// One log line. `type` comes first and `/` is not escaped, byte-for-byte
/// like serde: Rust's session index finds records by the `{"type":"input"` prefix.
private string record(string type, JSONValue data)
{
    return `{"type":` ~ JSONValue(type).toString ~ `,"data":` ~ data.toString(JSONOptions.doNotEscapeSlashes) ~ "}\n";
}

/// An append-only session log in the Rust nano-coder's format (version 1):
/// one `{"type":…,"data":…}` record per line, a `session` header first.
/// Only newline-terminated lines are committed; a torn last line from a crash
/// is dropped on resume and truncated away before the next append.
class SessionLog
{
    string id;
    string path;
    private File f;
    /// Lines written so far: the next record's physical line is `lines + 1`.
    private ulong lines;

    /// Create a new log in `dir`.
    this(string dir, string model, string cwd, string id = null)
    {
        this.id = id.length ? id : newSessionId();
        validateId(this.id);
        mkdirRecurse(dir);
        path = buildPath(dir, this.id ~ ".jsonl");
        if (path.exists) throw new Exception("session log " ~ path ~ " already exists");
        f = File(path, "a");
        JSONValue h = ["id": this.id, "created_at": nowStamp(), "cwd": cwd, "model": model];
        h["version"] = formatVersion;
        write_(record("session", h));
    }

    /// Continue an existing log (after `restore` read it).
    this(string existingPath)
    {
        path = existingPath;
        id = existingPath.baseName.stripExtension;
        validateId(id);
        auto bytes = cast(ubyte[]) read(path);
        size_t committed = bytes.length;
        while (committed && bytes[committed - 1] != '\n') committed--;
        if (committed < bytes.length)
        {
            // Drop a torn trailing record so later appends stay line-aligned.
            import std.file : write_file = write;
            write_file(path, bytes[0 .. committed]);
        }
        foreach (b; bytes[0 .. committed]) if (b == '\n') ++lines;
        f = File(path, "a");
    }

    private void write_(string line)
    {
        f.write(line);
        f.flush();
        ++lines;
    }

    /// Log a message; returns its physical line (its `#N` ID).
    ulong append(const ref Message m)
    {
        auto j = messageRecord(m);
        if ("log_line" in j) () @trusted { j.object.remove("log_line"); }(); // a direct record's ID is its line
        write_(record("message", j));
        return lines;
    }

    /// A prompt starts a turn.
    void input(string inputId, string text)
    {
        write_(record("input", JSONValue(["id": inputId, "text": text, "recorded_at": nowStamp()])));
    }

    /// The hook configuration files that apply to this session (audit trail):
    /// each `[path, source label, content hash]`.
    void hooks(const string[3][] files)
    {
        JSONValue[] list;
        foreach (f; files) list ~= JSONValue(["path": f[0], "source": f[1], "hash": f[2]]);
        write_(record("hooks", JSONValue(["files": JSONValue(list), "recorded_at": JSONValue(nowStamp())])));
    }

    /// The task plan after a change; the latest one wins.
    void plan(JSONValue plan)
    {
        JSONValue d = ["recorded_at": nowStamp()];
        d["plan"] = plan;
        write_(record("plan", d));
    }

    /// The turn for `inputId` finished. `stopReason` is omitted for `end_turn`.
    void turnEnd(string inputId, string response, string stopReason, JSONValue outcome = JSONValue.init)
    {
        JSONValue d = ["input_id": inputId, "response": response];
        if (outcome.type == JSONType.object) d["outcome"] = outcome;
        d["recorded_at"] = nowStamp();
        if (stopReason.length && stopReason != "end_turn") d["stop_reason"] = stopReason;
        write_(record("turn_end", d));
        import core.sys.posix.unistd : fsync;
        fsync(fileno(f.getFP));
    }

    /// The conversation was replaced wholesale (e.g. `/clear` keeps only the system prompt).
    /// Compaction also records the folded log-line range, its mode and model.
    void replace(const Message[] messages, ulong first = 0, ulong last = 0, string mode = null, string model = null)
    {
        JSONValue[] ms;
        foreach (ref m; messages) ms ~= messageRecord(m);
        JSONValue d = ["recorded_at": nowStamp()];
        d["messages"] = ms;
        if (first) d["summarized"] = JSONValue([JSONValue(first), JSONValue(last)]);
        if (mode !is null) d["mode"] = mode;
        if (model !is null) d["model"] = model;
        write_(record("replace", d));
    }
}

/// What a session log restores to.
struct Restored
{
    string id, cwd, model, createdAt;
    Message[] conversation;
    /// The text of an input whose turn never ended (a crash mid-turn).
    string pendingInput;
    /// The latest plan record (`{goal, items}`), or null.
    JSONValue plan;
    /// The latest compaction was smart: the history tools are offered.
    bool historyAvailable;
    /// The one-time history hint was already shown after that compaction.
    bool historyHintConsumed;
}

/// Read a session log (Rust format), dropping a torn last line.
Restored restore(string path)
{
    import std.algorithm : countUntil;
    Restored r;
    auto text = readText(path);
    auto committed = text.length;
    while (committed && text[committed - 1] != '\n') committed--;
    if (!committed) throw new Exception("session log " ~ path ~ " has no committed records");
    string pendingId;
    size_t index;
    ulong lineNo;
    foreach (line; text[0 .. committed].lineSplitter)
    {
        ++lineNo;
        if (!line.length) continue;
        JSONValue rec;
        try rec = parseJSON(line);
        catch (Exception e) throw new Exception(format("decode record %s of %s: %s", index + 1, path, e.msg));
        auto type = rec["type"].str;
        auto data = "data" in rec ? rec["data"] : JSONValue(null);
        if (type == "session")
        {
            if (index) throw new Exception(format("session record must be first (found at record %s)", index + 1));
            auto v = data["version"].integer;
            if (v != formatVersion)
                throw new Exception(format("unsupported session format version %s (this build supports %s)", v, formatVersion));
            r.id = data["id"].str;
            if (r.id != path.baseName.stripExtension)
                throw new Exception(format("session log header id %s does not match %s", JSONValue(r.id).toString,
                    JSONValue(path.baseName.stripExtension).toString));
            if (auto c = "cwd" in data) r.cwd = c.str;
            if (auto m = "model" in data) r.model = m.str;
            if (auto c = "created_at" in data) r.createdAt = c.str;
        }
        else if (!index) throw new Exception("session log " ~ path ~ " does not start with a session header");
        else switch (type)
        {
        case "input":
            pendingId = data["id"].str;
            r.pendingInput = data["text"].str;
            break;
        case "message":
            r.conversation ~= messageFromRecord(data);
            r.conversation[$ - 1].logLine = lineNo;
            {
                import nano.session_history : consumesHint;
                if (r.historyAvailable && consumesHint(r.conversation[$ - 1])) r.historyHintConsumed = true;
            }
            break;
        case "turn_end":
            if (data["input_id"].str == pendingId) { pendingId = null; r.pendingInput = null; }
            break;
        case "replace":
            r.conversation = null;
            foreach (m; data["messages"].array) r.conversation ~= messageFromRecord(m);
            {
                auto mode = "mode" in data;
                r.historyAvailable = mode !is null && mode.type == JSONType.string && mode.str == "smart";
                r.historyHintConsumed = false;
            }
            if ("pending_position" !in data || data["pending_position"].type == JSONType.null_)
            {
                pendingId = null;
                r.pendingInput = null;
            }
            break;
        case "plan":
            r.plan = data["plan"];
            break;
        default: // hooks: audit only
            break;
        }
        index++;
    }
    return r;
}

import std.datetime.systime : SysTime;
import std.string : startsWith;
import std.algorithm : canFind;
public import nano.session_index : Summary, isTerse;

/// Every resumable session in `dir`, newest first (via the summary index).
Summary[] listSessions(string dir)
{
    import nano.session_index : list;
    return list(dir);
}

/// Find a session log by id, or "last" for the newest one started in `cwd`.
string findSession(string dir, string which, string cwd = null)
{
    if (which == "last" || !which.length)
    {
        foreach (s; listSessions(dir))
            if (cwd is null || s.cwd == cwd) return s.path;
        throw new Exception(format("no saved session for %s; run with --list-sessions to see them", cwd));
    }
    validateId(which);
    auto p = buildPath(dir, which ~ ".jsonl");
    if (!p.exists) throw new Exception("no session " ~ which ~ " in " ~ dir);
    return p;
}

/// How long ago `then` was, briefly.
string ago(SysTime then, SysTime now)
{
    auto minutes = (now - then).total!"minutes";
    if (minutes < 1) return "just now";
    if (minutes < 60) return format("%sm ago", minutes);
    if (minutes < 1440) return format("%sh ago", minutes / 60);
    if (minutes < 2880) return "yesterday";
    if (minutes < 10080) return format("%sd ago", minutes / 1440);
    static immutable months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return format("%s %s", months[then.month - 1], then.day);
}

/// One line of text: whitespace collapsed and control characters dropped.
string oneLine(string text)
{
    import std.array : split, join;
    import std.uni : isControl;
    string o;
    foreach (dchar c; text.split.join(" ")) if (!c.isControl) o ~= c;
    return o;
}

/// A plain list row: `<id>  <ago>  <project>  N prompts  <topic>`, fitted to 100 columns after the id.
string listRow(const ref Summary s, SysTime now)
{
    import std.range : walkLength, take;
    import std.conv : to;
    auto project = s.cwd.length ? oneLine(s.cwd.baseName) : "?";
    auto prompts = s.prompts == 1 ? "1 prompt" : format("%s prompts", s.prompts);
    auto topic = oneLine(s.lastPrompt);
    if (s.title !is null) topic = oneLine(s.title) ~ " · " ~ topic;
    else if (s.contextPrompt.length) topic ~= "  ← " ~ oneLine(s.contextPrompt);
    auto line = format("%-10s  %s  %s  %s", ago(s.lastUsed, now), project, prompts, topic);
    if (line.walkLength > 100) line = line.take(99).to!string ~ "…";
    return oneLine(s.id) ~ "  " ~ line;
}

unittest
{
    auto dir = buildPath(tempDir, "nano-coder-d-session-test");
    if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    assert(log.id.startsWith("sess-"));
    auto m1 = Message.user("hello");
    auto m2 = Message.assistant("", [ToolCall.fromRaw("c", "bash", `{"command":"ls"}`)]);
    m2.hasUsage = true;
    m2.usage.inputTokens = 5;
    m2.stopReason = "tool_use";
    log.input("in-1", "hello");
    log.append(m1);
    log.append(m2);
    log.turnEnd("in-1", "", "end_turn");
    log.input("in-2", "crash here");
    // Arguments are stored as JSON values, records as {"type","data"}.
    auto lines = readText(log.path).lineSplitter.array;
    assert(lines[1].startsWith(`{"type":"input","data":{`) && !lines[0].canFind(`\/`), lines[0]);
    auto rec = parseJSON(lines[3]);
    assert(rec["type"].str == "message" && rec["data"]["tool_calls"][0]["arguments"]["command"].str == "ls");
    assert(parseJSON(lines[0])["data"]["version"].integer == 1);
    assert(!("stop_reason" in parseJSON(lines[4])["data"]));
    // A torn last line is ignored, then truncated when the log is reopened.
    std.file.append(log.path, `{"type":"message","data":{"ro`);
    auto r = restore(findSession(dir, "last", "/x"));
    assert(r.conversation.length == 2 && r.conversation[1].toolCalls[0].name == "bash");
    assert(r.conversation[1].hasUsage && r.conversation[1].usage.inputTokens == 5);
    assert(r.pendingInput == "crash here" && r.model == "mock/m" && r.cwd == "/x");
    auto again = new SessionLog(log.path);
    again.append(m1);
    assert(restore(log.path).conversation.length == 3);
    // replace wins over earlier messages; unknown fields round-trip.
    auto m3 = messageFromRecord(parseJSON(`{"role":"assistant","content":"x","thinking_blocks":[{"t":1}]}`));
    again.replace([m3]);
    auto r2 = restore(log.path);
    assert(r2.conversation.length == 1 && messageRecord(r2.conversation[0])["thinking_blocks"][0]["t"].integer == 1);
    assert(findSession(dir, log.id) == log.path);
    auto list = listSessions(dir);
    assert(list.length == 1 && list[0].prompts == 2 && list[0].lastPrompt == "crash here");
    import std.exception : assertThrown;
    assertThrown(findSession(dir, "../etc"));
    assertThrown(findSession(dir, "last", "/elsewhere"));
    // A header from another format version is refused.
    std.file.write(buildPath(dir, "v9.jsonl"), `{"type":"session","data":{"version":9,"id":"v9","created_at":"x"}}` ~ "\n");
    assertThrown(restore(buildPath(dir, "v9.jsonl")));
}

unittest
{
    assert(isTerse("do it") && isTerse("/model x") && !isTerse("Fix the flaky deploy test"));
    auto now = Clock.currTime;
    import core.time : minutes, hours;
    assert(ago(now - 5.minutes, now) == "5m ago" && ago(now - 3.hours, now) == "3h ago");
}

@trusted unittest
{
    // Malformed arguments and Responses item ids round-trip in Rust's shape.
    auto m = Message.assistant("", [ToolCall.fromRaw("c1", "bash", "{oops")]);
    m.toolCalls[0].itemId = "fc_1";
    auto rec = messageRecord(m);
    auto call = rec["tool_calls"][0];
    assert(call["arguments"].object.length == 0 && call["malformed_arguments"].str == "{oops" && call["item_id"].str == "fc_1");
    auto back = messageFromRecord(rec);
    assert(back.toolCalls[0].invalidArguments == "{oops" && back.toolCalls[0].itemId == "fc_1");
    auto legacy = messageFromRecord(parseJSON(`{"role":"assistant","content":"","tool_calls":[{"id":"c","name":"bash","arguments":"{bad"}]}`));
    assert(legacy.toolCalls[0].invalidArguments == "{bad");
}
