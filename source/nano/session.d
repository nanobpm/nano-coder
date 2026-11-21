/// Session logs (JSONL: a header line, then one message per line) and
/// project instructions (AGENTS.md and friends).
module nano.session;

@safe:
import nano.safeio : jsonText, jsonPretty;
import nano.clock : wallNow;

import nano.safeio : readBytes;

import std.json;
import std.format : format;
import std.file;
import std.path;
import std.stdio : File;
import std.string : strip, lineSplitter, endsWith;
import std.stdio : fileno;
import std.datetime.systime : Clock;
import core.time : dur;
import std.process : environment, thisProcessID;
import std.algorithm : sort, filter, map;
import std.array : array;
import nano.llm;
import nano.option : Option, some, ifSome;

/// The extension tidy-up compresses a session log to (`<id>.jsonl.gz`).
enum string compressedExtension = ".jsonl.gz";

/// Whether `path` names a gzip-compressed session log.
bool isCompressedLog(string path) pure
{
    return path.endsWith(compressedExtension);
}

/// The id a log file (plain or compressed) belongs to, extensions stripped.
string logIdOf(string path) pure
{
    import std.string : endsWith;
    auto name = path.baseName;
    return name.endsWith(compressedExtension) ? name[0 .. $ - compressedExtension.length] : name.stripExtension;
}

/// The whole log at `path` as text, gunzipping a compressed log (issue #205:
/// every reader — resume, the picker, history, the index, the trajectory —
/// sees compressed logs transparently).
string logText(string path)
{
    import nano.safeio : readRawText;
    if (!isCompressedLog(path)) return readRawText(path);
    return gunzipLog(readBytes(path), path);
}

// zlib's C API writes only within the caller's buffers (sizes tracked in
// avail_in/avail_out); the stream struct is plain C data.
private string gunzipLog(const(ubyte)[] bytes, string path) @trusted
{
    import etc.c.zlib : z_stream, inflateInit2, inflate, inflateEnd, Z_FINISH, Z_NO_FLUSH, Z_STREAM_END, Z_OK, Z_BUF_ERROR;
    import core.stdc.string : strlen;
    // A gzip wrapper needs raw inflate with windowBits 31 (15 + the 16 that
    // asks for the gzip header); std.zlib's uncompress expects a zlib stream.
    z_stream zs;
    if (inflateInit2(&zs, 15 + 16) != 0 /* Z_OK */)
        throw new Exception("inflate init failed for " ~ path);
    scope (exit) inflateEnd(&zs);
    auto out_ = new ubyte[](bytes.length ? bytes.length * 4 : 64);
    // zlib counts in 32-bit uints: feed the input and expose the output in
    // windows of at most uint.max, advancing by what zlib actually consumed
    // and wrote, so >4 GiB buffers never wrap.
    size_t fed, used;
    for (;;)
    {
        if (zs.avail_in == 0 && fed < bytes.length)
        {
            immutable n = zlibWindow(bytes.length - fed);
            zs.next_in = cast(ubyte*) bytes.ptr + fed;
            zs.avail_in = n;
            fed += n;
        }
        if (used == out_.length) out_.length = out_.length * 2;
        immutable window = zlibWindow(out_.length - used);
        zs.next_out = out_.ptr + used;
        zs.avail_out = window;
        auto rc = inflate(&zs, fed < bytes.length ? Z_NO_FLUSH : Z_FINISH);
        used += window - zs.avail_out;
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK && rc != Z_BUF_ERROR)
            throw new Exception(format("gunzip %s: %s", path,
                zs.msg !is null ? zs.msg[0 .. strlen(zs.msg)] : "corrupt stream"));
        if (rc == Z_BUF_ERROR && zs.avail_in == 0 && fed == bytes.length && zs.avail_out != 0)
            throw new Exception("gunzip " ~ path ~ ": truncated stream");
    }
    return cast(string) out_[0 .. used];
}

/// One zlib buffer window over `remaining` bytes: zlib's sizes are 32-bit.
package uint zlibWindow(size_t remaining) pure nothrow @nogc @safe
{
    return remaining > uint.max ? uint.max : cast(uint) remaining;
}

// zlib's C API writes only within the caller's buffers (sizes tracked in
// avail_in/avail_out); the stream struct is plain C data.
/// The gzip-compressed bytes of `text` (a session log's whole content).
ubyte[] gzipLog(const(char)[] text) @trusted
{
    import etc.c.zlib : z_stream, deflateInit2, deflate, deflateEnd, Z_FINISH, Z_NO_FLUSH, Z_STREAM_END, Z_BUF_ERROR;
    z_stream zs;
    if (deflateInit2(&zs, 6, 8 /* Z_DEFLATED */, 15 + 16 /* gzip wrapper */, 8, 0) != 0)
        throw new Exception("deflate init failed");
    scope (exit) deflateEnd(&zs);
    auto out_ = new ubyte[](text.length / 4 + 256);
    // Chunked like gunzipLog: a >4 GiB log must compress whole, never as
    // its wrapped-length prefix (tidy-up deletes the original afterwards).
    size_t fed, used;
    for (;;)
    {
        if (zs.avail_in == 0 && fed < text.length)
        {
            immutable n = zlibWindow(text.length - fed);
            zs.next_in = cast(ubyte*) text.ptr + fed;
            zs.avail_in = n;
            fed += n;
        }
        if (used == out_.length) out_.length = out_.length * 2;
        immutable window = zlibWindow(out_.length - used);
        zs.next_out = out_.ptr + used;
        zs.avail_out = window;
        auto rc = deflate(&zs, fed < text.length ? Z_NO_FLUSH : Z_FINISH);
        used += window - zs.avail_out;
        if (rc == Z_STREAM_END) break;
        if (rc != 0 && rc != Z_BUF_ERROR) throw new Exception("deflate failed compressing a session log");
    }
    return out_[0 .. used].dup;
}

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
    return stamp(wallNow);
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
    auto t = wallNow(UTC());
    return format("sess-%04d%02d%02dT%02d%02d%02d-%08x", t.year, cast(int) t.month, t.day, t.hour, t.minute,
        t.second, uniform!uint);
}

/// Session ids name files: 1-128 of [A-Za-z0-9._-], not starting with '.'.
void validateId(string id) pure
{
    import std.algorithm : all;
    import std.ascii : isAlphaNum;
    bool ok = id.length && id.length <= 128 && id[0] != '.'
        && id.all!(c => c.isAlphaNum || c == '-' || c == '_' || c == '.');
    if (!ok)
        throw new Exception(format("invalid session id %s: use 1-128 of [A-Za-z0-9._-], not starting with '.'",
            JSONValue(id).jsonText(JSONOptions.doNotEscapeSlashes)));
}

/// A message as a session-log record body (Rust's serde form of `Message`).
JSONValue messageRecord(const ref Message m) pure
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
            cj["arguments"] = c.invalidArguments.length ? parseJSON("{}") : parseJSON(c.arguments.jsonText);
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
        foreach (ref b; m.thinkingBlocks) blocks ~= parseJSON(b.jsonText);
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
Message messageFromRecord(JSONValue j) pure
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
                    : args.type == JSONType.string ? args.str : args.jsonText;
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
private string record(string type, JSONValue data) pure
{
    return `{"type":` ~ JSONValue(type).jsonText ~ `,"data":` ~ data.jsonText(JSONOptions.doNotEscapeSlashes) ~ "}\n";
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
        f = createPrivate(path);
        // A brand-new file: only an unsupported filesystem can refuse.
        if (tryLock(f) == LockResult.contended) throw new Exception("session log " ~ path ~ " is locked");
        shareHandle(path, f);
        scope (failure) close();
        JSONValue h = ["id": this.id, "created_at": nowStamp(), "cwd": cwd, "model": model];
        h["version"] = formatVersion;
        write_(record("session", h));
    }

    /// Continue an existing log (after `restore` read it). A compressed log
    /// (`<id>.jsonl.gz`, written by the tidy-up) is decompressed back to its
    /// plain name first, so appends stay line-aligned text (issue #205).
    this(string existingPath)
    {
        path = existingPath;
        if (isCompressedLog(path))
        {
            // Hold the archive's lock while decompressing so a concurrent
            // tidy-up cannot delete it; publish the plain copy atomically
            // (temp file + rename) before retiring the archive, so a crash
            // never leaves a truncated `.jsonl` that would shadow it.
            import std.file : write_file = write, rename;
            auto archive = File(path, "r");
            awaitLock(archive, path);
            if (!sameFile(archive, path)) throw new Exception("session log " ~ path ~ " was removed");
            auto plain = path[0 .. $ - ".gz".length];
            auto tmp = format("%s.tmp-%s", plain, thisProcessID);
            scope (failure) if (tmp.exists) remove(tmp);
            writePrivate(tmp, cast(const(ubyte)[]) logText(path), modeOf(path));
            rename(tmp, plain);
            remove(path);
            archive.close();
            path = plain;
        }
        id = path.baseName.stripExtension;
        validateId(id);
        // Lock before reading or truncating, so tidy-up cannot compress or
        // delete the log underneath this writer.
        if (auto held = path in openHere)
        {
            // This process already holds the log open and locked: share that
            // locked handle (a second open would be a separate, unlocked
            // file description once the first closes).
            f = held.file;
            held.refs++;
        }
        else
        {
            // Open without creating (never recreate a log tidy-up removed),
            // lock, then verify the path still names the inode we locked.
            f = openExistingForAppend(path);
            awaitLock(f, path);
            if (!sameFile(f, path)) { f.close(); throw new Exception("session log " ~ path ~ " was removed"); }
            shareHandle(path, f);
        }
        scope (failure) close();
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
    }

    /// Tests: the next write fails (Rust `fail_next_persist`).
    bool failNextWrite;

    /// Close the log (releasing its lock); a closed log must not be written.
    void close()
    {
        if (!f.isOpen) return;
        // AA removal does not run destructors: close the shared handle
        // explicitly when the last writer goes, releasing the lock.
        if (auto held = path in openHere)
            if (--held.refs == 0)
            {
                held.file.close();
                openHere.remove(path);
            }
        f.detach();
    }

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

    /// A plan change as a delta against the plan the log so far restores to
    /// (issue #205: a full snapshot per `plan_update` rewrites every note on
    /// every change). `goal` when it changed, `upserts` the added/updated
    /// items (each with its full notes), `drop` the removed item ids, `base`
    /// how many items the plan so far holds (a resume applies the delta onto
    /// the first `base` of them). A malformed base is no corruption: the
    /// resume then takes the delta's items as the whole plan.
    void planDelta(JSONValue goal, JSONValue[] upserts, uint[] drop, size_t base)
    {
        JSONValue d = ["recorded_at": nowStamp()];
        if (goal.type != JSONType.null_) d["goal"] = goal;
        if (upserts.length) d["upserts"] = upserts;
        if (drop.length) d["drop"] = JSONValue(drop.map!(i => JSONValue(i)).array);
        d["base"] = base;
        write_(record("plan_delta", d));
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
    /// `pinStash`: the user requests this compaction adds to the pinned block
    /// (resume rebuilds the block from them). `pinnedBase` is how many requests
    /// earlier compactions already stashed: the new requests extend that prefix
    /// rather than restating it, so a session's log holds each request once
    /// (issue #205 — a full restatement per compaction is quadratic). A plain
    /// replacement passes the whole stash with no base (the full form, which a
    /// resume still reads).
    /// `pending`: an in-flight input that survives the replacement (a
    /// mid-turn compaction), with its continuation snapshot.
    /// `folded`: the real turns this compaction folded, extending the first
    /// `foldedBase` turns of the previous stash when that is set; `restated`:
    /// the index of the restated in-flight input in `messages`.
    void replace(const Message[] messages, ulong first = 0, ulong last = 0, string mode = null, string model = null,
        const Message[] pinStash = null, scope const(PendingInput)* pending = null, const Message[] folded = null,
        Option!size_t foldedBase = Option!size_t.init, Option!size_t restated = Option!size_t.init,
        Option!size_t pinnedBase = Option!size_t.init)
    {
        JSONValue[] ms;
        foreach (ref m; messages) ms ~= messageRecord(m);
        JSONValue d = ["recorded_at": nowStamp()];
        d["messages"] = ms;
        if (pinStash.length || !pinnedBase.isNone)
        {
            JSONValue[] ps;
            foreach (ref m; pinStash) ps ~= messageRecord(m);
            d["pinned_requests"] = ps;
            pinnedBase.ifSome((size_t b) { d["pinned_base"] = b; });
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
void backfillPinText(ref Message m, const string[] inputs) pure
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
    auto text = logText(path);
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
            if (r.id != logIdOf(path))
                throw new Exception(format("session log header id %s does not match %s", JSONValue(r.id).jsonText,
                    JSONValue(logIdOf(path)).jsonText));
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
                // The pinned block: a full `pinned_requests` restatement, or a
                // delta extending the first `pinned_base` of the stash so far
                // (issue #205). With neither, a Rust log's folded stash is it.
                auto pins = "pinned_requests" in data, pinBase = "pinned_base" in data;
                if (pins !is null && pinBase !is null && pinBase.type == JSONType.integer)
                {
                    auto b = cast(size_t) pinBase.integer;
                    auto kept = b < r.pinStash.length ? r.pinStash[0 .. b] : r.pinStash;
                    r.pinStash = kept ~ decode(*pins, inputs);
                }
                else r.pinStash = pins !is null ? decode(*pins, inputs) : rustStash.dup;
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
        case "plan_delta":
            // A plan change against the plan so far (issue #205): keep the
            // first `base` items, apply the goal change, drop removed ids and
            // upsert the rest. A base past the plan's length (a hand-edited
            // or torn log) restarts the plan from the delta's items.
            {
                import nano.plan : Plan, PlanItem;
                import nano.result : unwrap;
                import std.algorithm : countUntil;
                auto base = "base" in data;
                auto b = base !is null && base.type == JSONType.integer && base.integer >= 0
                    ? cast(size_t) base.integer : size_t.max;
                Plan p;
                if (r.plan.type == JSONType.object)
                {
                    auto restored = Plan.fromJSON(r.plan);
                    if (!restored.isErr) p = restored.unwrap("checked");
                }
                if (b > p.items.length) p = Plan.init;
                else if (b < p.items.length) p.items = p.items[0 .. b];
                if (auto g = "goal" in data)
                    if (g.type == JSONType.string) p.goal = g.str;
                if (auto dr = "drop" in data)
                    if (dr.type == JSONType.array)
                    {
                        bool[uint] gone;
                        foreach (x; dr.arrayNoRef)
                            if (x.type == JSONType.integer && x.integer >= 0) gone[cast(uint) x.integer] = true;
                        p.items = p.items.filter!(i => i.id !in gone).array;
                    }
                // Merge the upserts as raw items, then validate the whole
                // plan: an item's `after` may name an item restored earlier.
                auto items = p.toJSON["items"].arrayNoRef.dup;
                static long idOf(const JSONValue i)
                {
                    if (i.type != JSONType.object) return -1;
                    auto v = "id" in i;
                    if (v is null) return -1;
                    if (v.type == JSONType.integer) return v.integer;
                    if (v.type == JSONType.uinteger) return cast(long) v.uinteger;
                    return -1;
                }
                if (auto up = "upserts" in data)
                    if (up.type == JSONType.array)
                        foreach (x; up.arrayNoRef)
                        {
                            if (x.type != JSONType.object) continue;
                            JSONValue[string] fields;
                            foreach (k, v; x.objectNoRef) if (k != "after") fields[k] = v;
                            auto shape = JSONValue(fields);
                            auto parsed = Plan.fromJSON(JSONValue(["items": JSONValue([shape])]));
                            if (parsed.isErr) continue;
                            auto itemId = parsed.unwrap("checked").items[0].id;
                            auto at = items.countUntil!(i => idOf(i) == itemId);
                            if (at >= 0) items[at] = x;
                            else items ~= x;
                        }
                auto merged = Plan.fromJSON(JSONValue(["goal": JSONValue(p.goal), "items": JSONValue(items)]));
                if (merged.isErr)
                {
                    // Drop dependencies on unknown items rather than the plan.
                    bool[long] known;
                    foreach (i; items) known[idOf(i)] = true;
                    foreach (ref i; items)
                    {
                        auto a = "after" in i;
                        if (a is null) continue;
                        if (a.type == JSONType.array)
                            i["after"] = JSONValue(a.arrayNoRef.filter!(d => idOf(JSONValue(["id": d])) in known).array);
                        else i["after"] = JSONValue(JSONValue[].init);
                    }
                    merged = Plan.fromJSON(JSONValue(["goal": JSONValue(p.goal), "items": JSONValue(items)]));
                }
                if (!merged.isErr) p = merged.unwrap("checked");
                r.plan = p.toJSON;
            }
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
/// A compressed log (`<id>.jsonl.gz`) is found by the same id.
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
    if (p.exists) return p;
    auto z = p ~ ".gz";
    if (z.exists) return z;
    throw new Exception("no session " ~ which ~ " in " ~ dir);
}

// ---------------------------------------------------------------------------
// Tidy-up (issue #205): compress idle logs, expire old ones.

/// What `tidySessions` did.
struct TidyResult
{
    size_t compressed, deleted;
    ulong freedBytes;
}

/// The stamp file whose mtime rate-limits the tidy-up to once a day.
private enum string tidyStampFile = ".tidy-stamp";

/// How a non-blocking lock attempt ended.
package enum LockResult { acquired, contended, unsupported }

/// Take an exclusive advisory lock on `f` without waiting. `unsupported`
/// is any other flock failure (ENOLCK, EOPNOTSUPP, ...): writers carry on
/// best-effort, but destructive maintenance must treat it as not held.
/// The lock lives until `f` is closed; flock marks the open file description.
private LockResult tryLock(ref File f) @trusted
{
    import core.stdc.errno : errno, EWOULDBLOCK, EAGAIN;
    if (flock(fileno(f.getFP), LOCK_EX | LOCK_NB) == 0) return LockResult.acquired;
    return errno == EWOULDBLOCK || errno == EAGAIN ? LockResult.contended : LockResult.unsupported;
}

/// A locked log handle shared by this thread's writers of one path.
private struct Held { File file; size_t refs; }

/// Logs this thread holds open and locked, so an in-process reopen shares
/// the locked handle instead of opening an unlocked second description.
private Held[string] openHere;

private void shareHandle(string path, File f)
{
    openHere[path] = Held(f, 1);
}

/// Lock `f` for a writer, waiting briefly while a tidy-up holds it (a
/// compression or expiry takes milliseconds). Still contended after the
/// wait, throw: an unlocked writer could append to a log tidy-up is
/// compressing or deleting. An unsupported filesystem proceeds best-effort.
private void awaitLock(ref File f, string path)
{
    import nano.clock : sleepFor;
    import core.time : msecs;
    foreach (attempt; 0 .. 40)
    {
        if (tryLock(f) != LockResult.contended) return;
        sleepFor(25.msecs);
    }
    throw new Exception("session log " ~ path ~ " is locked by another process (tidy-up?); try again");
}

/// `path` opened for appending without ever creating it.
private File openExistingForAppend(string path) @trusted
{
    import core.sys.posix.fcntl : open, O_WRONLY, O_APPEND;
    import std.string : toStringz;
    auto fd = open(path.toStringz, O_WRONLY | O_APPEND);
    if (fd < 0) throw new Exception("session log " ~ path ~ " does not exist");
    File f;
    f.fdopen(fd, "a");
    return f;
}

/// Whether `path` still names the inode `f` has open (tidy-up may have
/// removed or replaced it while we waited for the lock).
private bool sameFile(ref File f, string path) @trusted
{
    import core.sys.posix.sys.stat : fstat, stat, stat_t;
    import std.string : toStringz;
    stat_t a, b;
    if (fstat(fileno(f.getFP), &a) != 0 || stat(path.toStringz, &b) != 0) return false;
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

import std.conv : octal;

/// `path`'s permission bits (0600 when it cannot be read).
private uint modeOf(string path)
{
    import nano.safeio : statMode;
    uint mode;
    return statMode(path, mode) ? mode & octal!777 : octal!600;
}

/// Write `data` to a new file `path` created with mode `mode & 0600`
/// (never wider than owner-only, whatever the umask), failing if it exists.
private void writePrivate(string path, const(ubyte)[] data, uint mode)
{
    import core.sys.posix.fcntl : O_WRONLY, O_CREAT, O_EXCL;
    import nano.safeio : openPath, fchmodFd, writeFd, closeFd;
    auto fd = openPath(path, O_WRONLY | O_CREAT | O_EXCL, mode & octal!600);
    if (fd < 0) throw new Exception("cannot create " ~ path);
    scope (exit) closeFd(fd);
    fchmodFd(fd, mode & octal!600);
    while (data.length)
    {
        auto n = writeFd(fd, data);
        if (n <= 0) throw new Exception("cannot write " ~ path);
        data = data[n .. $];
    }
}

/// A new session log opened for appending, created owner-only (0600).
private File createPrivate(string path)
{
    writePrivate(path, null, octal!600);
    return File(path, "a");
}

private extern (C) int flock(int, int) nothrow @nogc;
private enum LOCK_EX = 2, LOCK_NB = 4, LOCK_UN = 8;

/// Compress logs idle for `compressAfterDays` and delete logs untouched for
/// `retentionDays` (0: keep forever), except named (titled) sessions. Runs at
/// most once a day per directory (the `.tidy-stamp` mtime), never touches a
/// log another process holds the lock on, and leaves a log whose plain and
/// compressed names both exist alone. Best-effort: an unreadable or
/// unwritable entry is skipped.
TidyResult tidySessions(string dir, long compressAfterDays, long retentionDays)
{
    import nano.session_index : titledIds, indexFile;
    TidyResult result;
    if (!dir.exists || (compressAfterDays <= 0 && retentionDays <= 0)) return result;
    auto stampPath = buildPath(dir, tidyStampFile);
    auto now = wallNow;
    if (stampPath.exists && now - timeLastModified(stampPath) < dur!"days"(1)) return result;
    // Titles name the sessions retention keeps.
    bool[string] named;
    // Without the titles, any deletion could hit a named session: fail
    // closed and only compress this pass.
    bool mayDelete = retentionDays > 0;
    try named = titledIds(dir);
    catch (Exception) mayDelete = false; // unknown titles: compress only, delete nothing
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
    {
        auto name = e.name.baseName;
        immutable compressed = name.endsWith(compressedExtension);
        if (!compressed && (!name.endsWith(".jsonl") || name == indexFile)) continue;
        auto id = logIdOf(e.name);
        try validateId(id);
        catch (Exception) continue; // not a session log name: skip
        if (!e.isFile) continue;
        auto age = now - e.timeLastModified;
        try
        {
            // Both names exist: an interrupted resume or a human's doing.
            // The plain copy may be incomplete, so leave both alone.
            if (buildPath(dir, id ~ (compressed ? ".jsonl" : ".jsonl.gz")).exists) continue;
            // Hold the lock for the whole operation, so no resume can open
            // and append to a log this pass then removes.
            auto held = File(e.name, "r");
            scope (exit) held.close();
            // Only a lock actually acquired proves no writer has the log.
            if (tryLock(held) != LockResult.acquired || !sameFile(held, e.name)) continue;
            // Re-sample the age under the lock: a session may have
            // appended and closed since the directory scan.
            age = now - timeLastModified(e.name);
            if (mayDelete && age >= dur!"days"(retentionDays) && id !in named)
            {
                result.freedBytes += getSize(e.name);
                remove(e.name);
                ++result.deleted;
            }
            else if (!compressed && compressAfterDays > 0 && age >= dur!"days"(compressAfterDays))
            {
                import std.file : rename, setTimes;
                auto gz = e.name ~ ".gz";
                auto before = getSize(e.name);
                auto packed = gzipLog(cast(const(char)[]) readBytes(e.name));
                // Gzip can grow a short log: keep the original then.
                if (packed.length >= before) continue;
                auto tmp = format("%s.tmp-%s", gz, thisProcessID);
                scope (failure) if (tmp.exists) remove(tmp);
                writePrivate(tmp, cast(const(ubyte)[]) packed, modeOf(e.name));
                // Keep the last activity time: retention and the picker
                // measure age from it, not from compression.
                auto mtime = timeLastModified(e.name);
                setTimes(tmp, mtime, mtime);
                rename(tmp, gz);
                remove(e.name);
                result.freedBytes += before - getSize(gz);
                ++result.compressed;
            }
        }
        catch (Exception) {} // one unreadable log must not stop the pass
    }
    try std.file.write(stampPath, "");
    catch (Exception) {} // a stamp that won't write just tidies again next start
    return result;
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
string oneLine(string text) pure
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
    auto now = wallNow;
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
    // A compaction that folds no new request still logs its base, so the
    // stash built so far survives a resume (it must not fall back to `folded`).
    log.replace([Message.auto_("s1")], 1, 2, "standard", "m", [p], null, [Message.user("f")]);
    log.replace([Message.auto_("s2")], 3, 4, "standard", "m", null, null, [Message.assistant("a")],
        Option!size_t.init, Option!size_t.init, some(size_t(1)));
    auto rk = restore(log.path);
    assert(rk.pinStash.length == 1 && rk.pinStash[0].pinText == "goal", "an empty delta keeps the stash");

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

// A compaction's pinned block is logged as a delta: `pinned_requests` holds
// only the requests that compaction adds, extending the first `pinned_base`
// of the stash so far (issue #205); a full restatement (no base) still reads.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-pindelta-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    JSONValue rep(JSONValue[] pins, long base = -1)
    {
        JSONValue d = ["messages": JSONValue([rec(Message.user("summary"))])];
        d["pinned_requests"] = pins;
        if (base >= 0) d["pinned_base"] = base;
        return d;
    }
    auto path = buildPath(dir, "pd.jsonl");
    write(path, `{"type":"session","data":{"version":1,"id":"pd","created_at":"x"}}` ~ "\n"
        ~ line("replace", rep([rec(Message.user("one")), rec(Message.user("two"))]))
        ~ line("replace", rep([rec(Message.user("three"))], 2))
        ~ line("replace", rep(cast(JSONValue[]) [], 3)));
    auto r = restore(path);
    assert(r.pinStash.length == 3 && r.pinStash[0].content == "one" && r.pinStash[1].content == "two"
        && r.pinStash[2].content == "three", "the delta extends the kept prefix");
    // A base past the stash keeps the whole stash rather than corrupting it.
    auto path2 = buildPath(dir, "pd2.jsonl");
    write(path2, `{"type":"session","data":{"version":1,"id":"pd2","created_at":"x"}}` ~ "\n"
        ~ line("replace", rep([rec(Message.user("one"))]))
        ~ line("replace", rep([rec(Message.user("two"))], 9)));
    auto r2 = restore(path2);
    assert(r2.pinStash.length == 2 && r2.pinStash[1].content == "two");
}

// Plan changes log as deltas applied onto the plan so far, with a full
// `plan` snapshot resetting the chain (issue #205).
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import nano.plan : Plan, Status;
    import nano.result : unwrap;
    auto dir = buildPath(tempDir, "nano-d-plandelta-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.plan(parseJSON(`{"goal":"g","items":[{"id":1,"title":"a","status":"pending"},{"id":2,"title":"b","status":"pending"}]}`));
    log.planDelta(JSONValue("g2"), [parseJSON(`{"id":2,"title":"b","status":"done","notes":["n"]}`),
        parseJSON(`{"id":3,"title":"c","status":"pending"}`)], [1], 2);
    auto r = restore(log.path);
    auto p = Plan.fromJSON(r.plan).unwrap("a valid plan");
    assert(p.goal == "g2" && p.items.length == 2 && p.items[0].id == 2 && p.items[1].id == 3);
    assert(p.items[0].status == Status.done && p.items[0].notes == ["n"]);
    // A base past the plan's length restarts the plan from the delta's items.
    log.planDelta(JSONValue(null), [parseJSON(`{"id":7,"title":"z","status":"pending"}`)], null, 99);
    auto p2 = Plan.fromJSON(restore(log.path).plan).unwrap("a valid plan");
    assert(p2.goal.length == 0 && p2.items.length == 1 && p2.items[0].id == 7);
    // A full snapshot replaces the delta chain.
    log.plan(parseJSON(`{"items":[{"id":1,"title":"x","status":"pending"}]}`));
    auto p3 = Plan.fromJSON(restore(log.path).plan).unwrap("a valid plan");
    assert(p3.goal.length == 0 && p3.items.length == 1 && p3.items[0].title == "x");
}

// gzip round-trip: a compressed log reads back byte-for-byte, and the tidy-up
// compresses idle logs, expires old ones, keeps named sessions, skips logs in
// use, and runs at most once a day (issue #205).
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import core.time : days, hours;
    auto dir = buildPath(tempDir, "nano-d-tidy-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto text = `{"type":"session","data":{"version":1,"id":"x","created_at":"x"}}` ~ "\n"
        ~ `{"type":"input","data":{"id":"in-1","text":"hello"}}` ~ "\n";
    auto gzPath = buildPath(dir, "x.jsonl.gz");
    std.file.write(gzPath, gzipLog(text));
    assert(logText(gzPath) == text, "gzip round-trips");
    remove(gzPath);

    string makeLog(string id, string prompt)
    {
        auto log = new SessionLog(dir, "mock/m", "/w", id);
        log.input("in-1", prompt);
        log.turnEnd("in-1", "", "end_turn");
        log.close();
        return log.path;
    }
    auto old = makeLog("old-log", "an old session that should be compressed");
    auto kept = makeLog("kept-log", "a named session that must survive retention");
    auto fresh = makeLog("fresh-log", "a session too new to touch");
    // Name `kept` via the index (before ageing: naming may touch the log).
    import nano.session_index : setTitle;
    setTitle(kept, "Keep me");
    foreach (p; [old, kept]) setTimes(p, wallNow - 20.days, wallNow - 20.days);
    auto r = tidySessions(dir, 14, 0);
    assert(r.compressed == 2 && r.deleted == 0, format("%s", r));
    assert(!old.exists && (old ~ ".gz").exists && !kept.exists && (kept ~ ".gz").exists);
    assert(fresh.exists, "a fresh log is not compressed");
    assert(restore(old ~ ".gz").completed.length == 1, "a compressed log restores");
    assert(findSession(dir, "old-log") == old ~ ".gz", "a compressed log is found by id");
    assert(listSessions(dir).length == 3, "compressed logs list");
    // Rate-limited: a second pass the same day does nothing.
    auto again = makeLog("second-old", "another old session");
    setTimes(again, wallNow - 20.days, wallNow - 20.days);
    assert(tidySessions(dir, 14, 0).compressed == 0, "the stamp rate-limits the pass");
    // A log another process holds is left alone.
    auto inUse = new SessionLog(dir, "mock/m", "/w", "in-use");
    setTimes(inUse.path, wallNow - 20.days, wallNow - 20.days);
    std.file.write(buildPath(dir, tidyStampFile), "");
    setTimes(buildPath(dir, tidyStampFile), wallNow - 2.days, wallNow - 2.days);
    auto r2 = tidySessions(dir, 14, 30);
    assert(r2.compressed == 1, "the second old log compresses once the stamp ages");
    assert(inUse.path.exists && !(inUse.path ~ ".gz").exists, "a locked log is skipped");
    inUse.close();
    // Retention: old unnamed logs go, named and fresh ones stay.
    setTimes(kept ~ ".gz", wallNow - 200.days, wallNow - 200.days);
    setTimes(old ~ ".gz", wallNow - 200.days, wallNow - 200.days);
    setTimes(again ~ ".gz", wallNow - 200.days, wallNow - 200.days);
    setTimes(buildPath(dir, tidyStampFile), wallNow - 2.days, wallNow - 2.days);
    auto r3 = tidySessions(dir, 14, 180);
    assert(r3.deleted == 2 && !(old ~ ".gz").exists && !(again ~ ".gz").exists);
    assert((kept ~ ".gz").exists, "a named session survives retention");
    assert(fresh.exists, "a fresh log survives retention");
    // Resuming a compressed log decompresses it back to its plain name.
    auto resumed = new SessionLog(kept ~ ".gz");
    auto more = Message.user("more");
    resumed.append(more);
    assert(kept.exists && !(kept ~ ".gz").exists);
    assert(restore(kept).conversation[$ - 1].content == "more");
}

// Review fixes for issue #205: highly compressible logs (> 4x) decompress;
// compression keeps the log's mtime; a plain/archive twin is left alone;
// a live log refuses a second writer; the index caches an archive by its
// on-disk size.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, timeLastModified;
    import std.path : buildPath;
    import std.array : replicate;
    import core.time : days;
    import nano.session_index : list;
    import std.math : abs;
    auto dir = buildPath(tempDir, "nano-d-tidy2-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    // Z_BUF_ERROR growth: repetitive text compresses far beyond 4x.
    auto big = `{"type":"input","data":{"id":"in-1","text":"aaaa"}}` ~ "\n";
    big = big.replicate(5000);
    auto z = buildPath(dir, "big.jsonl.gz");
    std.file.write(z, gzipLog(big));
    assert(logText(z) == big, "a log expanding past the initial buffer reads back");
    remove(z);

    auto log = new SessionLog(dir, "mock/m", "/w", "aged");
    log.input("in-1", "an aged session to archive");
    log.turnEnd("in-1", "", "end_turn");
    // A second writer on a live log is refused.
    log.close();
    auto when = wallNow - 20.days;
    setTimes(log.path, when, when);
    // A twin pair is left alone (the plain copy may be a torn decompression).
    auto twin = new SessionLog(dir, "mock/m", "/w", "twin");
    twin.close();
    setTimes(twin.path, when, when);
    std.file.write(twin.path ~ ".gz", gzipLog("x\n"));
    setTimes(twin.path ~ ".gz", when, when);
    auto r = tidySessions(dir, 14, 0);
    assert(r.compressed == 1);
    assert(twin.path.exists && (twin.path ~ ".gz").exists, "twins are left alone");
    auto gz = log.path ~ ".gz";
    assert(abs((timeLastModified(gz) - when).total!"seconds") <= 1, "compression keeps the mtime");
    // The index records the archive's on-disk size, so later listings hit the cache.
    auto first = list(dir);
    auto s = first.filter!(x => x.id == "aged").array;
    assert(s.length == 1 && s[0].archiveBytes == getSize(gz));
}

// A plan delta whose upserted item depends on an earlier item restores the
// update instead of dropping it (dependencies validate against the whole plan).
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import nano.plan : Plan;
    import nano.result : unwrap;
    auto dir = buildPath(tempDir, "nano-d-plandep-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w", "dep");
    log.plan(parseJSON(`{"items":[{"id":1,"title":"a","status":"pending"},{"id":2,"title":"b","status":"pending","after":[1]}]}`));
    log.planDelta(JSONValue(null), [parseJSON(`{"id":2,"title":"b","status":"done","after":[1]}`)], [], 2);
    log.close();
    auto p = Plan.fromJSON(restore(log.path).plan).unwrap("a valid plan");
    assert(p.items.length == 2 && p.items[1].after == [1u]);
    import nano.plan : Status;
    assert(p.items[1].status == Status.done, "the dependent upsert applied");
}

// Round-3 review fixes for issue #205: zlib windows never exceed 32 bits; a
// resume never recreates a removed log; an in-process reopen shares the
// locked handle; a contended writer fails instead of running unlocked;
// tidy-up re-reads the age under the lock and keeps named sessions when the
// index is unreadable.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import std.exception : assertThrown;
    import core.time : days;
    assert(zlibWindow(10) == 10);
    assert(zlibWindow(cast(size_t) uint.max) == uint.max);
    static if (size_t.sizeof > 4)
    {
        assert(zlibWindow(cast(size_t) uint.max + 1) == uint.max, "output window capped");
        assert(zlibWindow(4UL << 30) == uint.max, "a 4 GiB input is never fed as 0 bytes");
    }
    auto dir = buildPath(tempDir, "nano-d-tidy3-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // A removed log is reported, not recreated as a headerless file.
    auto gone = new SessionLog(dir, "mock/m", "/w", "gone");
    gone.close();
    remove(gone.path);
    assertThrown(new SessionLog(gone.path));
    assert(!gone.path.exists, "resume must not recreate a removed log");

    // An in-process reopen shares the locked handle: after the first writer
    // closes, the log is still locked against tidy-up.
    auto a = new SessionLog(dir, "mock/m", "/w", "shared");
    a.input("in-1", "shared session");
    auto b = new SessionLog(a.path);
    a.close();
    auto probe = File(b.path, "r");
    assert(tryLock(probe) == LockResult.contended, "the reopened writer still holds the lock");
    probe.close();
    b.close();
    auto probe2 = File(b.path, "r");
    assert(tryLock(probe2) == LockResult.acquired, "the last close releases the lock");

    // While another description holds the lock, a writer fails rather than
    // appending unlocked.
    {
        import nano.clock : FakeClock;
        auto clock = FakeClock.install(wallNow); // the bounded wait is instant
        assertThrown(new SessionLog(b.path));
    }
    probe2.close();

    // Retention re-reads the age under the lock: a log touched after the scan
    // sampled it is kept. (Simulated: fresh mtime means nothing is deleted.)
    auto fresh = new SessionLog(dir, "mock/m", "/w", "fresh2");
    fresh.close();
    assert(tidySessions(dir, 0, 30).deleted == 0);

    // An unreadable/corrupt index disables deletion (titles unknown).
    import nano.session_index : list, indexFile;
    auto old = new SessionLog(dir, "mock/m", "/w", "old3");
    old.input("in-1", "old session");
    old.close();
    list(dir); // build the index
    auto idx = buildPath(dir, indexFile);
    std.file.append(idx, "{not json\n");
    setTimes(old.path, wallNow - 200.days, wallNow - 200.days);
    std.file.write(buildPath(dir, tidyStampFile), "");
    setTimes(buildPath(dir, tidyStampFile), wallNow - 2.days, wallNow - 2.days);
    auto r = tidySessions(dir, 0, 180);
    assert(r.deleted == 0 && old.path.exists, "a corrupt index must not let retention delete");
}

// Review fixes for issue #205 (round 4): a titled log whose summary fails
// (truncated) keeps title protection via the strict index; archives and
// decompressed logs stay owner-only; gzip that grows a log keeps the
// original; a failed construction releases the log's registration.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, setTimes, getAttributes;
    import core.time : days;
    import nano.session_index : list, setTitle;
    auto dir = buildPath(tempDir, "nano-d-tidy-r4");
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // Title protection survives a log that no longer summarizes.
    auto t = new SessionLog(dir, "mock/m", "/w", "titled");
    t.input("in-1", "a titled session whose log is later truncated");
    t.close();
    list(dir);
    setTitle(t.path, "Keep me");
    std.file.write(t.path, ""); // truncated: no header, not resumable
    setTimes(t.path, wallNow - 200.days, wallNow - 200.days);
    auto r = tidySessions(dir, 0, 180);
    assert(r.deleted == 0 && t.path.exists, "a titled archive in the index is protected");
    remove(t.path);

    // Permissions: logs, archives and decompressed copies are owner-only.
    auto p = new SessionLog(dir, "mock/m", "/w", "private");
    foreach (i; 0 .. 50) p.input(format("in-%s", i), "a repetitive prompt that compresses well");
    p.close();
    assert((getAttributes(p.path) & octal!777) == octal!600, "a new log is 0600");
    setTimes(p.path, wallNow - 20.days, wallNow - 20.days);
    setTimes(buildPath(dir, tidyStampFile), wallNow - 2.days, wallNow - 2.days);
    auto r2 = tidySessions(dir, 14, 0);
    assert(r2.compressed == 1 && r2.freedBytes > 0 && r2.freedBytes < 1_000_000, format("%s", r2));
    assert((getAttributes(p.path ~ ".gz") & octal!777) == octal!600, "an archive is 0600");
    auto back = new SessionLog(p.path ~ ".gz");
    back.close();
    assert((getAttributes(p.path) & octal!777) == octal!600, "a decompressed log is 0600");

    // Gzip that does not shrink the log keeps the original.
    auto tiny = buildPath(dir, "tiny.jsonl");
    std.file.write(tiny, "x\n");
    setTimes(tiny, wallNow - 20.days, wallNow - 20.days);
    setTimes(buildPath(dir, tidyStampFile), wallNow - 2.days, wallNow - 2.days);
    auto r3 = tidySessions(dir, 14, 0);
    assert(r3.compressed == 0 && r3.freedBytes == 0 && tiny.exists && !(tiny ~ ".gz").exists, format("%s", r3));

    // A construction that fails after registering releases the lock.
    auto f = new SessionLog(dir, "mock/m", "/w", "fails");
    f.close();
    std.file.write(f.path, "\xff\xfe not a log\n");
    {
        import std.exception : collectException;
        collectException(new SessionLog(f.path).close()); // either outcome: only the registration matters
    }
    assert(f.path !in openHere, "no stale registration after a failed open");
}
