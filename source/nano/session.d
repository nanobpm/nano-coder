/// Session logs (JSONL: a header line, then one message per line) and
/// project instructions (AGENTS.md and friends).
module nano.session;

@safe:

import nano.safeio : readBytes;

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
import nano.option : Option, some, ifSome;

/// The session log directory: `NANO_CODER_SESSIONS`, else the configured
/// `session_dir` (`~` expanded), else the platform data folder.
string sessionDir(string configured = null)
{
    if (auto x = environment.get("NANO_CODER_SESSIONS")) return x;
    if (configured.length) return expandTilde(configured);
    version (OSX)
        return buildPath(expandTilde("~"), "Library", "Application Support", "nano-coder", "sessions");
    else
        return buildPath(environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share")), "nano-coder", "sessions");
}

/// Where the D preview (`nano-coder-d`) kept its logs before it became
/// `nano-coder`: the default `sessions` folder under the old app name.
string previewSessionDir()
{
    version (OSX)
        return buildPath(expandTilde("~"), "Library", "Application Support", "nano-coder-d", "sessions");
    else
        return buildPath(environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share")), "nano-coder-d", "sessions");
}

/// Move the D preview's session logs (with their spill and attachment
/// folders) from `from` into `to`, once. An entry whose name already exists
/// in `to` stays behind; the preview's index cache is dropped (the listing
/// rescans unindexed logs). `from` is removed when it ends up empty, so later
/// starts find nothing to do. Returns how many entries moved.
size_t adoptPreviewSessions(string from, string to)
{
    import std.exception : collectException;
    import nano.session_index : indexFile;
    if (!from.exists || !from.isDir) return 0;
    mkdirRecurse(to);
    size_t moved;
    foreach (name; dirEntries(from, SpanMode.shallow).map!(e => e.name.baseName).array)
    {
        auto src = buildPath(from, name), dst = buildPath(to, name);
        if (name == indexFile) { collectException(remove(src)); continue; }
        if (dst.exists) continue;
        if (collectException(rename(src, dst)) is null) ++moved;
    }
    if (dirEntries(from, SpanMode.shallow).empty) collectException(rmdir(from));
    return moved;
}

unittest
{
    auto root = buildPath(tempDir, "nano-coder-adopt-test");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto from = buildPath(root, "old"), to = buildPath(root, "new");
    mkdirRecurse(buildPath(from, "sess-a.spill"));
    write(buildPath(from, "sess-a.jsonl"), "a");
    write(buildPath(from, "sess-b.jsonl"), "old b");
    write(buildPath(from, ".index.jsonl"), "{}");
    mkdirRecurse(to);
    write(buildPath(to, "sess-b.jsonl"), "new b");
    assert(adoptPreviewSessions(from, to) == 2);
    assert(readText(buildPath(to, "sess-a.jsonl")) == "a");
    assert(buildPath(to, "sess-a.spill").isDir);
    assert(readText(buildPath(to, "sess-b.jsonl")) == "new b", "an existing log is never overwritten");
    assert(!buildPath(to, ".index.jsonl").exists);
    assert(readText(buildPath(from, "sess-b.jsonl")) == "old b");
    remove(buildPath(from, "sess-b.jsonl"));
    assert(adoptPreviewSessions(from, to) == 0);
    assert(!from.exists, "an emptied preview folder is removed");
    assert(adoptPreviewSessions(from, to) == 0);
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
            JSONValue(id).toString(JSONOptions.doNotEscapeSlashes)));
}

/// A message as a session-log record body (Rust's serde form of `Message`).
JSONValue messageRecord(const ref Message m)
{
    JSONValue j = ["role": roleName(m.role), "content": m.content];
    if (m.extra.type == JSONType.object)
        foreach (k, v; m.extra.objectNoRef) j[k] = v;
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
    if (m.hasUsage && m.usage.hasAic) j["usage"]["aic"] = m.usage.aic;
    if (m.durationMs >= 0) j["duration_ms"] = m.durationMs;
    if (m.temperature.length) j["temperature"] = m.temperature;
    if (m.thinkingLevel.length) j["thinking_level"] = m.thinkingLevel;
    if (m.stopReason.length) j["stop_reason"] = m.stopReason;
    if (m.logLine) j["log_line"] = m.logLine;
    if (m.autoInitiated) j["auto_initiated"] = true;
    if (m.continuation) j["continuation"] = true;
    if (m.timer) j["timer"] = true;
    if (m.hookContext) j["hook_context"] = true;
    if (m.pinText.length) j["pin_text"] = m.pinText;
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
    foreach (k, v; j.objectNoRef)
    {
        switch (k)
        {
        case "role": break;
        case "content": m.content = v.type == JSONType.string ? v.str : ""; break;
        case "tool_calls":
            foreach (c; v.arrayNoRef)
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
                foreach (a; v.arrayNoRef)
                    if (a.type == JSONType.object) m.attachments ~= Attachment.fromJSON(a);
            break;
        case "tool_call_id": m.toolCallId = v.str; break;
        case "name": m.toolName = v.str; break;
        case "is_error": m.isError = v.type == JSONType.true_; break;
        case "timestamp": m.timestamp = v.str; break;
        case "thinking": m.thinking = v.str; break;
        case "thinking_blocks":
            if (v.type == JSONType.array) m.thinkingBlocks = v.arrayNoRef.dup;
            break;
        case "usage":
            m.hasUsage = true;
            if (auto p = "prompt_tokens" in v) m.usage.inputTokens = p.integer;
            if (auto p = "completion_tokens" in v) m.usage.outputTokens = p.integer;
            if (auto p = "aic" in v)
            {
                if (p.type == JSONType.float_) { m.usage.hasAic = true; m.usage.aic = p.floating; }
                else if (p.type == JSONType.integer) { m.usage.hasAic = true; m.usage.aic = p.integer; }
            }
            break;
        case "duration_ms": m.durationMs = v.integer; break;
        case "stop_reason": m.stopReason = v.str; break;
        case "temperature": if (v.type == JSONType.string) m.temperature = v.str; break;
        case "thinking_level": if (v.type == JSONType.string) m.thinkingLevel = v.str; break;
        case "log_line": if (v.type == JSONType.integer) m.logLine = v.integer; break; // direct records: the physical line wins
        case "auto_initiated": m.autoInitiated = v.type == JSONType.true_; break;
        case "hook_context": m.hookContext = v.type == JSONType.true_; break;
        case "pin_text": if (v.type == JSONType.string) m.pinText = v.str; break;
        // Sub-kinds of an automatic turn.
        case "continuation": m.continuation = v.type == JSONType.true_; break;
        case "timer": m.timer = v.type == JSONType.true_; break;
        default: extra[k] = v;
        }
    }
    if (extra.objectNoRef.length) m.extra = extra;
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
        auto bytes = readBytes(path);
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

    /// Tests: the next write fails (Rust `fail_next_persist`).
    bool failNextWrite;

    private void write_(string line)
    {
        if (failNextWrite)
        {
            failNextWrite = false;
            throw new Exception("session log write failed (injected)");
        }
        f.write(line);
        f.flush();
        ++lines;
    }

    /// Log a message; returns its physical line (its `#N` ID).
    ulong append(const ref Message m)
    {
        auto j = messageRecord(m);
        if ("log_line" in j) j.objectNoRef.remove("log_line"); // a direct record's ID is its line
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

    /// The timers after a change; the latest record wins.
    void timers(JSONValue timers)
    {
        JSONValue d = ["recorded_at": nowStamp()];
        d["timers"] = timers;
        write_(record("timers", d));
    }

    /// The memory-recall state after a change (`{seen, fired}`); the latest
    /// record wins. A compaction appends an empty one.
    void recall(JSONValue recall)
    {
        JSONValue d = ["recorded_at": nowStamp()];
        d["recall"] = recall;
        write_(record("recall", d));
    }

    /// The turn for `inputId` finished. `stopReason` is omitted for `end_turn`.
    /// `historyCalls`: history_search / history_read calls in the turn.
    void turnEnd(string inputId, string response, string stopReason, JSONValue outcome = JSONValue.init,
        uint historyCalls = 0)
    {
        JSONValue d = ["input_id": inputId, "response": response];
        if (outcome.type == JSONType.object) d["outcome"] = outcome;
        if (historyCalls) d["history_calls"] = historyCalls;
        d["recorded_at"] = nowStamp();
        if (stopReason.length && stopReason != "end_turn") d["stop_reason"] = stopReason;
        write_(record("turn_end", d));
        import core.sys.posix.unistd : fsync;
        fsync(fileno(f.getFP));
    }

    /// The conversation was replaced wholesale (e.g. `/clear` keeps only the system prompt).
    /// Compaction also records the folded log-line range, its mode and model.
    /// `pinStash`: the user requests folded by compactions so far (resume
    /// rebuilds the pinned block from them).
    /// `pending`: an in-flight input that survives the replacement (a
    /// mid-turn compaction), with its continuation snapshot.
    /// `folded`: the real turns this compaction folded, extending the first
    /// `foldedBase` turns of the previous stash when that is set; `restated`:
    /// the index of the restated in-flight input in `messages`.
    void replace(const Message[] messages, ulong first = 0, ulong last = 0, string mode = null, string model = null,
        const Message[] pinStash = null, scope const(PendingInput)* pending = null, const Message[] folded = null,
        Option!size_t foldedBase = Option!size_t.init, Option!size_t restated = Option!size_t.init)
    {
        JSONValue[] ms;
        foreach (ref m; messages) ms ~= messageRecord(m);
        JSONValue d = ["recorded_at": nowStamp()];
        d["messages"] = ms;
        if (pinStash.length)
        {
            JSONValue[] ps;
            foreach (ref m; pinStash) ps ~= messageRecord(m);
            d["pinned_requests"] = ps;
        }
        if (pending !is null)
        {
            d["pending_position"] = pending.position;
            if (pending.hasContinuation) d["continuation"] = JSONValue([JSONValue(pending.answer), JSONValue(pending.count)]);
            if (pending.recallNotes) d["pending_recall_notes"] = pending.recallNotes;
        }
        if (folded.length || foldedBase.isSome)
        {
            JSONValue[] fs;
            foreach (ref m; folded) fs ~= messageRecord(m);
            d["folded"] = fs;
            foldedBase.ifSome((size_t b) { d["folded_base"] = b; });
        }
        restated.ifSome((size_t i) { d["restated"] = i; });
        if (first) d["summarized"] = JSONValue([JSONValue(first), JSONValue(last)]);
        if (mode !is null) d["mode"] = mode;
        if (model !is null) d["model"] = model;
        write_(record("replace", d));
    }
}

/// Recover `pinText` for a user message logged before it was recorded: a
/// legacy prompt with hook context appended (`<input>\n\n<system-reminder>…`)
/// gets the logged input it starts with (the longest such) as its user-typed
/// part. A message that already has one, or is exactly an input, is left alone.
void backfillPinText(ref Message m, const string[] inputs)
{
    import std.algorithm : canFind, startsWith;
    import std.string : stripLeft;
    if (m.role != Role.user || m.pinText.length || m.hookContext) return;
    enum wrapStart = "<system-reminder>";
    if ((inputs.length && inputs[$ - 1] == m.content) || !m.content.canFind(wrapStart)) return;
    if (inputs.canFind(m.content)) return;
    string found;
    foreach_reverse (input; inputs)
        if (m.content.length > input.length && m.content.startsWith(input)
            && m.content[input.length .. $].stripLeft.startsWith(wrapStart) && input.length > found.length)
            found = input;
    if (found.length) m.pinText = found;
}

/// The same logged message: role, content, tool calls and results, thinking blocks.
private bool sameContent(const ref Message a, const ref Message b)
{
    static string calls(const ref Message m)
    {
        auto j = messageRecord(m);
        auto c = "tool_calls" in j;
        return c is null ? "" : c.toString;
    }
    static string blocks(const ref Message m) { return JSONValue(m.thinkingBlocks.dup).toString; }
    return a.role == b.role && a.content == b.content && a.toolCallId == b.toolCallId && a.toolName == b.toolName
        && a.isError == b.isError && calls(a) == calls(b) && blocks(a) == blocks(b);
}

/// Backfill stable `[#N]` IDs onto a `replace` record's retained messages
/// from the direct records they came from (Rust `backfill_log_lines`): logs
/// from before stable IDs stored retained messages without `log_line`. Each
/// un-IDed non-system message takes the first unclaimed original with the
/// same content past the summarized range (folded originals are not retained).
private void backfillLogLines(Message[] messages, const Message[] originals, ulong summarizedEnd)
{
    auto claimed = new bool[originals.length];
    foreach (ref m; messages)
    {
        if (m.logLine || m.role == Role.system) continue;
        foreach (i, ref o; originals)
            if (!claimed[i] && o.logLine > summarizedEnd && sameContent(o, m))
            {
                m.logLine = o.logLine;
                claimed[i] = true;
                break;
            }
    }
}

/// An input that was accepted but whose turn has not ended (Rust
/// `PendingInput`): redelivering its id resumes the turn.
struct PendingInput
{
    string id, text;
    /// Conversation length when the input was accepted; its user message, if
    /// recorded, is at this index.
    size_t position;
    /// The in-flight output-limit continuation: the answer carried across
    /// cut-off chunks and how many continuations ran (issue #114).
    bool hasContinuation;
    string answer;
    size_t count;
    /// The conversation length the snapshot already accounts for: recovery
    /// replays only later messages over it (none: from `position`, empty).
    bool hasBase;
    size_t base;
    /// Recall notes already attached for this input.
    size_t recallNotes;
}

/// What a session log restores to.
struct Restored
{
    string id, cwd, model, createdAt;
    Message[] conversation;
    /// The text of an input whose turn never ended (a crash mid-turn).
    string pendingInput;
    /// That input in full, when `hasPending`.
    bool hasPending;
    PendingInput pending;
    /// Finished turns by input id: response, stop reason and any outcome
    /// (redelivering one of these ids replays the recorded answer).
    string[string] completed;
    string[string] completedStops;
    JSONValue[string] completedOutcomes;
    /// The latest plan record (`{goal, items}`), or null.
    JSONValue plan;
    /// The latest timers record (`{last_id, items}`), or null.
    JSONValue timers;
    /// The memory-recall state (`{seen, fired}`) as of the latest recall
    /// record, reset by a later replace; null when the session never had one.
    JSONValue recall;
    /// The user requests folded by compactions (`pinned_requests`, or a Rust
    /// log's `folded` stash), for rebuilding the pinned block.
    Message[] pinStash;
    /// The real turns folded by the compactions since the last plain
    /// replacement (Rust's `folded` stash): a replay shows these in place of
    /// the synthetic summary.
    Message[] replayStash;
    /// Index, in the compacted conversation, of the restated in-flight input
    /// the latest compaction folded (its original is in `replayStash`).
    Option!size_t replayRestated;
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
    // Every logged input's text, to backfill `pinText` on legacy messages.
    string[] inputs;
    Message[] rustStash;
    // Every direct message record, with its line, for `backfillLogLines`.
    Message[] originals;
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
            inputs ~= r.pendingInput;
            r.hasPending = true;
            r.pending = PendingInput(pendingId, r.pendingInput, r.conversation.length);
            break;
        case "message":
            r.conversation ~= messageFromRecord(data);
            r.conversation[$ - 1].logLine = lineNo;
            backfillPinText(r.conversation[$ - 1], inputs);
            originals ~= r.conversation[$ - 1];
            {
                import nano.session_history : consumesHint;
                if (r.historyAvailable && consumesHint(r.conversation[$ - 1])) r.historyHintConsumed = true;
            }
            break;
        case "turn_end":
            if (data["input_id"].str == pendingId) { pendingId = null; r.pendingInput = null; r.hasPending = false; }
            {
                auto iid = data["input_id"].str;
                auto resp = "response" in data;
                r.completed[iid] = resp !is null && resp.type == JSONType.string ? resp.str : "";
                auto st = "stop_reason" in data;
                if (st !is null && st.type == JSONType.string && st.str != "end_turn") r.completedStops[iid] = st.str;
                else r.completedStops.remove(iid);
                auto oc = "outcome" in data;
                if (oc !is null && oc.type == JSONType.object) r.completedOutcomes[iid] = *oc;
                else r.completedOutcomes.remove(iid);
            }
            break;
        case "replace":
            r.conversation = null;
            foreach (m; data["messages"].arrayNoRef) r.conversation ~= messageFromRecord(m);
            {
                ulong floor;
                if (auto sum = "summarized" in data)
                    if (sum.type == JSONType.array && sum.arrayNoRef.length == 2) floor = sum.arrayNoRef[1].integer;
                backfillLogLines(r.conversation, originals, floor);
            }
            foreach (ref m; r.conversation) backfillPinText(m, inputs);
            {
                // An in-flight input survives a mid-turn compaction at
                // `pending_position`, with its continuation snapshot.
                auto pos = "pending_position" in data;
                if (r.hasPending && pos !is null && pos.type == JSONType.integer)
                {
                    r.pending.position = cast(size_t) pos.integer;
                    r.pending.hasContinuation = false;
                    r.pending.answer = null;
                    r.pending.count = 0;
                    auto c = "continuation" in data;
                    if (c !is null && c.type == JSONType.array && c.arrayNoRef.length == 2)
                    {
                        r.pending.hasContinuation = true;
                        r.pending.answer = c.arrayNoRef[0].str;
                        r.pending.count = cast(size_t) c.arrayNoRef[1].integer;
                    }
                    r.pending.hasBase = true;
                    r.pending.base = r.conversation.length;
                    auto rn = "pending_recall_notes" in data;
                    r.pending.recallNotes = rn !is null && rn.type == JSONType.integer ? cast(size_t) rn.integer : 0;
                }
                else
                {
                    r.hasPending = false;
                    r.pendingInput = null;
                    pendingId = null;
                }
            }
            {
                static Message[] decode(const JSONValue v, const string[] inputs)
                {
                    Message[] o;
                    if (v.type == JSONType.array)
                        foreach (m; v.arrayNoRef)
                        {
                            o ~= messageFromRecord(m);
                            backfillPinText(o[$ - 1], inputs);
                        }
                    return o;
                }
                // Rust's cumulative stash of folded turns: full, or a delta on a base.
                auto folded = "folded" in data, base = "folded_base" in data;
                bool active;
                if (folded !is null && base !is null && base.type == JSONType.integer)
                {
                    auto b = cast(size_t) base.integer;
                    auto delta = decode(*folded, inputs);
                    if ((b < rustStash.length ? b : rustStash.length) + delta.length > 0)
                    {
                        rustStash = rustStash[0 .. (b < rustStash.length ? b : rustStash.length)] ~ delta;
                        active = true;
                    }
                }
                else if (folded !is null)
                {
                    auto full = decode(*folded, inputs);
                    if (full.length) { rustStash = full; active = true; }
                }
                if (!active) rustStash = null;
                r.replayStash = rustStash.dup;
                r.replayRestated = Option!size_t.init;
                if (auto at = "restated" in data)
                    if (active && at.type == JSONType.integer && at.integer >= 0) r.replayRestated = some(cast(size_t) at.integer);
                auto pins = "pinned_requests" in data;
                r.pinStash = pins !is null ? decode(*pins, inputs) : rustStash.dup;
            }
            {
                auto mode = "mode" in data;
                r.historyAvailable = mode !is null && mode.type == JSONType.string && mode.str == "smart";
                r.historyHintConsumed = false;
            }
            // The replacement drops recalled notes from context, so recall
            // resets here while decoding, not only in the empty record the
            // writer appends after it (a crash between the two must not
            // suppress those memories for good). A later record still wins.
            r.recall = parseJSON(`{"seen":[],"fired":[]}`);
            if ("pending_position" !in data || data["pending_position"].type == JSONType.null_)
            {
                pendingId = null;
                r.pendingInput = null;
            }
            break;
        case "plan":
            r.plan = data["plan"];
            break;
        case "timers":
            r.timers = data["timers"];
            break;
        case "recall":
            r.recall = data["recall"];
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

// rust: providers/openai.rs::parses_tool_calls_and_bad_arguments
unittest
{
    auto dir = buildPath(tempDir, "nano-coder-session-test");
    if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    assert(log.id.startsWith("sess-"));
    auto m1 = Message.user("hello");
    auto m2 = Message.assistant("", [ToolCall.fromRaw("c", "bash", `{"command":"ls"}`)]);
    m2.hasUsage = true;
    m2.usage.inputTokens = 5;
    m2.usage.hasAic = true;
    m2.usage.aic = 0.25;
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
    assert(r.conversation[1].usage.hasAic && r.conversation[1].usage.aic == 0.25);
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

// rust: session_index.rs::set_title_does_not_replace_an_existing_title
// rust: session_index.rs::title_source_skips_terse_prompts
unittest
{
    assert(isTerse("do it") && isTerse("/model x") && !isTerse("Fix the flaky deploy test"));
    auto now = Clock.currTime;
    import core.time : minutes, hours;
    assert(ago(now - 5.minutes, now) == "5m ago" && ago(now - 3.hours, now) == "3h ago");
}

unittest
{
    // Malformed arguments and Responses item ids round-trip in Rust's shape.
    auto m = Message.assistant("", [ToolCall.fromRaw("c1", "bash", "{oops")]);
    m.toolCalls[0].itemId = "fc_1";
    auto rec = messageRecord(m);
    auto call = rec["tool_calls"][0];
    assert(call["arguments"].objectNoRef.length == 0 && call["malformed_arguments"].str == "{oops" && call["item_id"].str == "fc_1");
    auto back = messageFromRecord(rec);
    assert(back.toolCalls[0].invalidArguments == "{oops" && back.toolCalls[0].itemId == "fc_1");
    auto legacy = messageFromRecord(parseJSON(`{"role":"assistant","content":"","tool_calls":[{"id":"c","name":"bash","arguments":"{bad"}]}`));
    assert(legacy.toolCalls[0].invalidArguments == "{bad");
}

// rust: session.rs::replace_clears_recall_state_while_decoding
unittest // replace_clears_recall_state_while_decoding
{
    auto dir = buildPath(tempDir, "nano-coder-session-recall");
    if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    auto sys = Message.system("sys");
    log.append(sys);
    assert(restore(log.path).recall.type == JSONType.null_, "never recorded");
    log.recall(parseJSON(`{"seen":["mem-1"],"fired":["mem-1"]}`));
    assert(restore(log.path).recall["seen"][0].str == "mem-1", "the latest record restores");
    // A crash after the replace but before the empty recall record that
    // follows it: the replace alone resets recall.
    log.replace([Message.system("sys"), Message.user("summary")], 2, 2, "standard", null);
    auto r = restore(log.path);
    assert(r.recall["seen"].arrayNoRef.length == 0 && r.recall["fired"].arrayNoRef.length == 0, r.recall.toString);
    // A later record still wins.
    log.recall(parseJSON(`{"seen":["mem-2"],"fired":[]}`));
    assert(restore(log.path).recall["seen"][0].str == "mem-2");
}

// rust: session.rs::legacy_logs_recover_pin_text_from_the_input_record
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    import std.algorithm : find;
    auto dir = buildPath(tempDir, "nano-d-pin66-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto wire = "Fix the race.\n\n<system-reminder>\nuse nightly\n</system-reminder>";
    auto typed = "Rename <system-reminder> to <note>";
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto path = buildPath(dir, "s66.jsonl");
    write(path, `{"type":"session","data":{"version":1,"id":"s66","created_at":"x"}}` ~ "\n"
        ~ line("input", JSONValue(["id": "in-1", "text": "Fix the race."]))
        ~ line("message", rec(Message.user(wire)))
        ~ line("input", JSONValue(["id": "in-2", "text": typed]))
        ~ line("message", rec(Message.user(typed))));
    auto r = restore(path);
    assert(r.conversation.find!(m => m.content == wire)[0].pinText == "Fix the race.");
    assert(r.conversation.find!(m => m.content == typed)[0].pinText is null);

    auto m = Message.user(wire);
    backfillPinText(m, ["Fix the race."]);
    assert(m.pinText == "Fix the race.");
    auto a = Message.assistant(wire);
    backfillPinText(a, ["Fix the race."]);
    assert(a.pinText is null);
    // A follow-up with its own exact input never matches the older shorter one.
    auto follow = "Fix the race.\n\n<system-reminder>Rename this tag to <note>.</system-reminder>";
    foreach (inputs; [["Fix the race.", follow], [follow, "Fix the race."]])
    {
        auto f = Message.user(follow);
        backfillPinText(f, inputs);
        assert(f.pinText is null);
    }
}

// The pinned-request stash rides on the replace record (D's `pinned_requests`,
// or a Rust log's cumulative `folded` stash) and the flags round-trip.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-pinstash-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w");
    auto hook = Message.user("<system-reminder>ctx</system-reminder>");
    hook.hookContext = true;
    auto p = Message.user("goal\n\n<system-reminder>x</system-reminder>");
    p.pinText = "goal";
    log.replace([Message.auto_("note"), hook], 1, 2, "standard", "m", [p]);
    auto r = restore(log.path);
    assert(r.pinStash.length == 1 && r.pinStash[0].pinText == "goal");
    assert(r.conversation[0].autoInitiated && r.conversation[1].hookContext);
    log.replace([Message.user("x")]);
    assert(restore(log.path).pinStash.length == 0, "a plain replace clears the stash");

    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    JSONValue rep(JSONValue[] folded, long base = -1)
    {
        JSONValue d = ["messages": JSONValue(cast(JSONValue[]) [])];
        d["folded"] = folded;
        if (base >= 0) d["folded_base"] = base;
        return d;
    }
    auto path = buildPath(dir, "rust.jsonl");
    write(path, `{"type":"session","data":{"version":1,"id":"rust","created_at":"x"}}` ~ "\n"
        ~ line("replace", rep([rec(Message.user("one")), rec(Message.assistant("a"))]))
        ~ line("replace", rep([rec(Message.user("two"))], 1)));
    auto rr = restore(path);
    assert(rr.pinStash.length == 2 && rr.pinStash[0].content == "one" && rr.pinStash[1].content == "two");
}
