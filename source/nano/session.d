/// Session logs (JSONL: a header line, then one message per line) and
/// project instructions (AGENTS.md and friends).
module nano.session;

@safe:

import std.conv : to;

import nano.safeio : jsonText, jsonPretty;
import nano.clock : wallNow;

import nano.safeio : readBytes, jsonUnsigned;
import nano.arith : toSize;
import nano.loghandles : Held, openHere, shareHandle;
import std.string : representation;

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
import std.algorithm : sort, filter, map, min;
import std.array : array;
import std.math : isNaN;
import nano.llm;
import nano.option : Option, some, none, ifSome, match;
import nano.plan : Plan;
import nano.history : RecentInputs;

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
/// A corrupt or truncated stream throws `FileException`, so readers that
/// report unreadable files handle it too.
private string gunzipLog(const(ubyte)[] bytes, string path) @trusted
{
    import std.file : FileException;
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
            zs.next_in = bytes.ptr + fed;
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
            throw new FileException(path, format("gunzip: %s",
                zs.msg !is null ? zs.msg[0 .. strlen(zs.msg)] : "corrupt stream"));
        if (rc == Z_BUF_ERROR && zs.avail_in == 0 && fed == bytes.length && zs.avail_out != 0)
            throw new FileException(path, "gunzip: truncated stream");
    }
    import std.exception : assumeUnique;
    import std.string : assumeUTF;
    return out_[0 .. used].assumeUTF.assumeUnique;
}

/// One zlib buffer window over `remaining` bytes: zlib's sizes are 32-bit.
package uint zlibWindow(size_t remaining) pure nothrow @nogc @safe
{
    // The mask keeps the low 32 bits, which range propagation admits as a uint.
    return remaining > uint.max ? uint.max : remaining & uint.max;
}

// zlib's C API writes only within the caller's buffers (sizes tracked in
// avail_in/avail_out); the stream struct is plain C data.
/// The gzip-compressed bytes of `text` (a session log's whole content).
ubyte[] gzipLog(const(char)[] text) { return gzipLog(text.representation); }

/// ditto, for raw bytes (a log read from disk, compressed unvalidated).
ubyte[] gzipLog(const(ubyte)[] text)
{
    import std.array : appender;
    auto o = appender!(ubyte[]);
    o.reserve(text.length / 4 + 256);
    bool given;
    gzipChunks(() { if (given) return (const(ubyte)[]).init; given = true; return text; },
        (const(ubyte)[] c) { o ~= c; });
    return o.data;
}

/// Compress the file at `src` into the new file `dst` (created exclusively
/// with `mode`), 64 KiB at a time (issue #313: tidy-up compresses a huge log
/// without holding it, a doubling buffer and a copy at once). Returns the
/// compressed size.
private ulong gzipFile(string src, string dst, uint mode)
{
    import std.stdio : File;
    import nano.safeio : writeFd, closeFd;
    auto f = File(src, "rb");
    scope (exit) f.close();
    auto fd = createPrivateFd(dst, mode);
    scope (exit) closeFd(fd);
    auto buf = new ubyte[](64 * 1024);
    ulong written;
    gzipChunks(() => f.rawRead(buf), (const(ubyte)[] c) {
        writeAllFd(fd, c, dst);
        written += c.length;
    });
    return written;
}

/// Deflate (gzip wrapper) every chunk `next` returns until it returns an
/// empty one, handing each compressed chunk to `put` (valid only during the
/// call). Input and output stay bounded to one chunk and a 64 KiB window.
private void gzipChunks(scope const(ubyte)[] delegate() @safe next,
    scope void delegate(const(ubyte)[]) @safe put) @trusted
{
    import etc.c.zlib : z_stream, deflateInit2, deflate, deflateEnd, Z_FINISH, Z_NO_FLUSH, Z_STREAM_END, Z_BUF_ERROR;
    z_stream zs;
    if (deflateInit2(&zs, 6, 8 /* Z_DEFLATED */, 15 + 16 /* gzip wrapper */, 8, 0) != 0)
        throw new Exception("deflate init failed");
    scope (exit) deflateEnd(&zs);
    auto out_ = new ubyte[](64 * 1024);
    const(ubyte)[] chunk = next();
    size_t fed;
    bool last = chunk.length == 0;
    for (;;)
    {
        // zlib counts in 32-bit uints: feed in windows of at most uint.max,
        // so a >4 GiB chunk compresses whole, never its wrapped prefix.
        if (zs.avail_in == 0 && !last)
        {
            if (fed == chunk.length)
            {
                chunk = next();
                fed = 0;
                last = chunk.length == 0;
            }
            if (!last)
            {
                immutable n = zlibWindow(chunk.length - fed);
                zs.next_in = chunk.ptr + fed;
                zs.avail_in = n;
                fed += n;
            }
        }
        zs.next_out = out_.ptr;
        zs.avail_out = zlibWindow(out_.length);
        auto rc = deflate(&zs, last ? Z_FINISH : Z_NO_FLUSH);
        // No pointer into the caller's chunk outlives this iteration's use.
        if (immutable got = out_.length - zs.avail_out) put(out_[0 .. got]);
        if (rc == Z_STREAM_END) break;
        if (rc != 0 && rc != Z_BUF_ERROR) throw new Exception("deflate failed compressing a session log");
    }
}

/// Feed every committed (newline-terminated) line of the log at `path` to
/// `sink`, without holding the whole log: a plain log is read in 64 KiB
/// chunks and a compressed one is inflated as it is read (issue #271: the
/// history tools and the session index must stay bounded on a huge log, so
/// they stream instead of `logText`-ing it whole). A trailing partial line
/// (a torn write) is not committed and never reaches `sink`, matching
/// `committedLines`.
void streamLogLines(string path, scope void delegate(const(char)[] line) @safe sink)
{
    streamLogLinesUntil(path, (line) { sink(line); return true; });
}

/// `streamLogLines` whose `sink` returns false to stop reading: nothing
/// past that line is read or inflated (issue #271: the permission-header
/// probe must not scan a denied session's whole log).
void streamLogLinesUntil(string path, scope bool delegate(const(char)[] line) @safe sink,
    scope bool delegate(const(char)[] head) @safe keep = null)
{
    import std.stdio : File;
    auto f = File(path, "rb");
    scope (exit) f.close();
    ubyte[] carry;
    bool skipping;
    if (isCompressedLog(path))
    {
        auto gz = GunzipStream(path);
        scope (exit) gz.close();
        auto buf = new ubyte[](64 * 1024);
        for (;;)
        {
            auto got = gz.read(f, buf);
            if (!got.length) break;
            if (!feedChunk(carry, skipping, got, sink, keep)) return;
        }
    }
    else
    {
        auto buf = new ubyte[](64 * 1024);
        for (;;)
        {
            auto got = f.rawRead(buf);
            if (!got.length) break;
            if (!feedChunk(carry, skipping, got, sink, keep)) return;
        }
    }
}

/// The bytes of a line's start that a `keep` predicate sees.
enum size_t lineHeadBytes = 64;

/// Split one chunk into newline-terminated lines for `sink`, carrying a
/// partial line over to the next chunk (a torn tail is dropped). `keep`, if
/// set, sees each line's first `lineHeadBytes` (or the whole of a shorter
/// line): a line it rejects is skipped unbuffered, so a multi-megabyte
/// record the caller doesn't want is never assembled (issue #234).
private bool feedChunk(ref ubyte[] carry, ref bool skipping, const(ubyte)[] chunk,
    scope bool delegate(const(char)[]) @safe sink, scope bool delegate(const(char)[]) @safe keep)
{
    import nano.safeio : asChars;
    size_t start;
    foreach (i, b; chunk)
        if (b == '\n')
        {
            if (skipping) skipping = false;
            else if (!emitLine(carry, chunk[start .. i], sink, keep)) return false;
            carry = null;
            start = i + 1;
        }
    if (start < chunk.length && !skipping)
    {
        carry ~= chunk[start .. $];
        if (keep !is null && carry.length >= lineHeadBytes && !keep(asChars(carry[0 .. lineHeadBytes])))
        {
            skipping = true;
            carry = null;
        }
    }
    return true;
}

/// One line split out of the stream: the carried prefix plus the chunk
/// slice, validated as UTF-8 (a malformed line is lossy-copied so a bad byte
/// can't kill the stream; it fails to parse where decoded, as before).
private bool emitLine(ref ubyte[] carry, const(ubyte)[] tail, scope bool delegate(const(char)[]) @safe sink,
    scope bool delegate(const(char)[]) @safe keep)
{
    import nano.safeio : asChars, lossyText, utf8View;
    import std.utf : UTFException;
    const(ubyte)[] line = carry.length ? carry ~ tail : tail;
    carry = null;
    if (keep !is null && !keep(asChars(line[0 .. min(line.length, lineHeadBytes)]))) return true;
    const(char)[] text;
    try text = utf8View(line);
    catch (UTFException) text = lossyText(line);
    return sink(text);
}

/// An incremental gzip reader over a log file: the gzip wrapper needs raw
/// inflate with windowBits 31, like `gunzipLog`, but the plain and
/// compressed bytes stay bounded to their read buffers.
private struct GunzipStream
{
    import std.stdio : File;
    import nano.safeio : InflateStream;
    private InflateStream zs;
    private ubyte[] inBuf;
    private string path;
    private bool ended;

    /// A reader over the log at `path`.
    this(string path) { this.path = path; }

    /// The next inflated bytes: `buf`'s filled prefix, valid until the next
    /// read (the line splitter copies only a line that spans reads); empty at
    /// the stream's end. Throws on a corrupt or truncated stream.
    ubyte[] read(ref File f, ubyte[] buf)
    {
        if (ended) return null;
        if (zs.isNone) zs = InflateStream.open(path);
        if (!inBuf) inBuf = new ubyte[](64 * 1024);
        for (;;)
        {
            if (zs.availIn == 0)
            {
                auto got = f.rawRead(inBuf);
                if (!got.length) throw new Exception("gunzip " ~ path ~ ": truncated stream");
                zs.feed(got);
            }
            auto rc = zs.inflateInto(buf);
            immutable used = zlibWindow(buf.length) - zs.availOut;
            if (rc == InflateStream.Rc.streamEnd)
            {
                ended = true;
                return used ? buf[0 .. used] : null;
            }
            if (rc == InflateStream.Rc.error)
                throw new Exception("gunzip " ~ path ~ ": " ~ zs.errorMessage);
            if (used) return buf[0 .. used];
            // Z_BUF_ERROR with no output means zlib can make no progress: with
            // input still buffered that is a stuck stream, not a read more.
            if (zs.availIn) throw new Exception("gunzip " ~ path ~ ": corrupt stream (no progress)");
            // else zlib wants more input; loop to read it.
        }
    }

    /// End the zlib stream (idempotent).
    void close()
    {
        zs.close();
    }
}

/// `streamLogLines` for the history tools: a torn trailing line is dropped
/// by the streamer and callers skip undecodable records themselves, but a
/// missing or unreadable log or a corrupt/truncated archive throws, so a
/// search never reports partial results as complete.
void foreachLogLineSkippingTorn(string path, scope void delegate(const(char)[]) @safe sink)
{
    streamLogLines(path, sink);
}

/// `foreachLogLineSkippingTorn` that skips, unbuffered, each line whose
/// first `lineHeadBytes` `keep` rejects. A skipped line still counts as a
/// line for `sink`'s caller: it is reported as an empty line.
void foreachLogLineSkippingTorn(string path, scope void delegate(const(char)[]) @safe sink,
    scope bool delegate(const(char)[] head) @safe keep)
{
    streamLogLinesUntil(path, (line) { sink(line); return true; }, (head) {
        if (keep(head)) return true;
        sink(null);
        return false;
    });
}

/// The working directory recorded in the log's header (null for older logs
/// or an unreadable header), read from the first line only (issue #271:
/// `sessions_list` checks a session's workspace before its log is opened or
/// its cached metadata shown, so the check must not read the log whole).
string logHeaderCwd(string path)
{
    string cwd;
    try
        streamLogLinesUntil(path, (line) {
            auto h = parseJSON(line);
            if (h["type"].str != "session") return false;
            auto d = h["data"].objectNoRef;
            if (auto c = "cwd" in d)
                if (c.type == JSONType.string) cwd = c.str;
            return false; // the header is the first line: stop reading
        });
    catch (Exception) {} // an unreadable or corrupt header is no cwd, as documented
    return cwd;
}

/// The model a saved session will resume with: the latest `settings` record's
/// `model` field, else the header's `model`, or null if unreadable (issue #297).
/// Used at `--resume` startup to select the saved model before constructing the
/// startup client, so a disabled or failing default provider does not block
/// resuming a session whose own provider is usable. `fromHeader` is true when
/// the model came from the header, which stores the spec verbatim (it may be a
/// bare model containing `/`), not from a canonical `settings` record.
string logSavedModel(string path, out bool fromHeader)
{
    string model;
    try
        streamLogLines(path, (line) {
            // Fast path: skip lines that cannot be the header or a settings record.
            if (!line.canFind(`"type":"session"`) && !line.canFind(`"type": "session"`)
                && !line.canFind(`"type":"settings"`) && !line.canFind(`"type": "settings"`))
                return;
            JSONValue obj;
            try obj = parseJSON(line);
            catch (Exception) return; // a corrupt line does not block startup peeking
            if (obj.type != JSONType.object) return;
            auto t = "type" in obj, d = "data" in obj;
            if (t is null || t.type != JSONType.string || d is null || d.type != JSONType.object) return;
            if (t.str != "session" && t.str != "settings") return;
            if (auto m = "model" in *d)
                if (m.type == JSONType.string && m.str.length) { model = m.str; fromHeader = t.str == "session"; }
        });
    catch (Exception) {} // an unreadable or corrupt log falls back to config model
    return model;
}

unittest // logSavedModel: header model, overridden by settings.model, corrupt lines ignored
{
    auto dir = buildPath(tempDir, "nano-coder-saved-model-test");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "openai/gpt-4o", "/tmp");
    auto p = log.path;
    log.close();
    bool hdr;
    assert(logSavedModel(p, hdr) == "openai/gpt-4o" && hdr);

    auto log2 = new SessionLog(p);
    SessionSettings s1;
    s1.verbosity = "verbose";
    log2.settings(s1);
    SessionSettings s2;
    s2.model = "anthropic/claude-sonnet";
    log2.settings(s2);
    log2.close();
    assert(logSavedModel(p, hdr) == "anthropic/claude-sonnet" && !hdr);

    // Corrupt line and non-string model field are ignored.
    std.file.append(p, "{not json\n");
    std.file.append(p, `{"type":"settings","data":{"model":123}}` ~ "\n");
    assert(logSavedModel(p, hdr) == "anthropic/claude-sonnet" && !hdr);
    assert(logSavedModel(buildPath(dir, "missing.jsonl"), hdr) is null);
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

unittest // a corrupt or truncated gzip log is a FileException, not a bare Exception
{
    import std.exception : assertThrown;
    import std.file : FileException;
    // A gzip header followed by garbage, and a header with no body.
    immutable ubyte[] corrupt = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 0xff, 0xff, 0xff, 0xff];
    immutable ubyte[] truncated = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3];
    assertThrown!FileException(gunzipLog(corrupt, "x.jsonl.gz"));
    assertThrown!FileException(gunzipLog(truncated, "x.jsonl.gz"));
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
    return format("%04d-%02d-%02dT%02d:%02d:%02d.%06d%s%02d:%02d", t.year, int(t.month), t.day, t.hour,
        t.minute, t.second, t.fracSecs.total!"usecs", sign, mins / 60, mins % 60);
}

/// A new session id: `sess-YYYYmmddTHHMMSS-xxxxxxxx` (UTC).
string newSessionId()
{
    import std.random : uniform;
    import std.datetime.timezone : UTC;
    auto t = wallNow(UTC());
    return format("sess-%04d%02d%02dT%02d%02d%02d-%08x", t.year, int(t.month), t.day, t.hour, t.minute,
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
    if (m.stopBlocked) j["stop_blocked"] = true;
    if (m.steered) j["steered"] = true;
    if (m.fromSession.length) j["from_session"] = m.fromSession;
    if (m.hookContext) j["hook_context"] = true;
    if (m.pinText.length) j["pin_text"] = m.pinText;
    if (m.subLog.length) j["sub_log"] = m.subLog;
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
    m.role = r.to!Role;
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
        case "log_line": { ulong n; if (jsonUnsigned(v, n)) m.logLine = n; } break; // direct records: the physical line wins
        case "auto_initiated": m.autoInitiated = v.type == JSONType.true_; break;
        case "stop_blocked": m.stopBlocked = v.type == JSONType.true_; break;
        case "steered": m.steered = v.type == JSONType.true_; break;
        case "from_session": if (v.type == JSONType.string) m.fromSession = v.str; break;
        case "hook_context": m.hookContext = v.type == JSONType.true_; break;
        case "pin_text": if (v.type == JSONType.string) m.pinText = v.str; break;
        case "sub_log": if (v.type == JSONType.string) m.subLog = v.str; break;
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
    /// The shared registration of `f` (its refcount), tied to the handle
    /// rather than the path: a recovery that re-registers the path must not
    /// let an old sharer's `close` release the replacement handle.
    private Held* held;
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
        held = shareHandle(path, f);
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
            auto archive = File(path, "r");
            awaitLock(archive, path);
            if (!sameFile(archive, path)) throw new Exception("session log " ~ path ~ " was removed");
            auto plain = path[0 .. $ - ".gz".length];
            // Never replace an existing plain log: an interrupted earlier
            // resume may have left one that has since been resumed and locked
            // by another writer — the archive's lock does not cover that
            // inode, and renaming over it would orphan its live appends.
            if (plain.exists)
            {
                archive.close();
                throw new Exception("cannot resume archive " ~ path ~ ": the plain log " ~ plain
                    ~ " already exists; remove one of the two copies first");
            }
            auto tmp = format("%s.tmp-%s", plain, thisProcessID);
            scope (failure) if (tmp.exists) remove(tmp);
            gunzipFile(path, tmp, modeOf(path)); // streamed: never the whole log in RAM (#313)
            publishOver(tmp, plain); // fsync the copy, link, sync the entry, unlink
            remove(path);
            archive.close();
            path = plain;
        }
        id = path.baseName.stripExtension;
        validateId(id);
        // Lock before reading or truncating, so tidy-up cannot compress or
        // delete the log underneath this writer.
        if (auto shared_ = path in openHere)
        {
            // This process already holds the log open and locked: share that
            // locked handle (a second open would be a separate, unlocked
            // file description once the first closes).
            held = *shared_;
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
            held = shareHandle(path, f);
        }
        scope (failure) close();
        // Count the committed lines in fixed-size chunks: a long session's
        // log can run to hundreds of MB, and reading it whole here (on top of
        // `restore`'s own read) doubled a resume's peak heap.
        size_t committed, size;
        {
            auto r = File(path, "rb");
            auto buf = new ubyte[](64 * 1024);
            for (;;)
            {
                auto chunk = r.rawRead(buf);
                if (!chunk.length) break;
                foreach (i, b; chunk)
                    if (b == '\n') { ++lines; committed = size + i + 1; }
                size += chunk.length;
            }
        }
        if (committed < size)
        {
            // Drop a torn trailing record so later appends stay line-aligned
            // (rare: a crash mid-write), so the whole read is fine here.
            import std.file : write_file = write;
            write_file(path, readBytes(path)[0 .. committed]);
        }
    }

    /// Tests: the next write fails (Rust `fail_next_persist`).
    bool failNextWrite;

    /// Tests: invoked with each recovery candidate's path right after its
    /// exclusive create, so a test can swap the destination before the
    /// post-sync identity re-check (simulating a concurrent replacement).
    void delegate(string) swapAfterCreate;

    /// Tests: whether `close` has released this writer's handle.
    bool isOpenForWrite() const @safe { return f.isOpen; }

    /// Close the log (releasing its lock); a closed log must not be written.
    void close()
    {
        if (!f.isOpen) return;
        // AA removal does not run destructors: close the shared handle
        // explicitly when the last writer goes, releasing the lock.
        if (held !is null && --held.refs == 0)
        {
            held.file.close();
            // Only drop the path's registration if it is still this handle.
            if (auto cur = path in openHere)
                if (*cur is held) openHere.remove(path);
        }
        held = null;
        f.detach();
    }

    private void write_(string line)
    {
        if (failNextWrite)
        {
            failNextWrite = false;
            throw new Exception("session log write failed (injected)");
        }
        if (!sameFile(f, path))
        {
            recoverReplaced();
            // The header itself hit the replacement: name the recovery id.
            { import std.string : assumeUTF; if (lines == 0) line = withHeaderId(line.representation, id).assumeUTF.idup; }
        }
        f.write(line);
        f.flush();
        ++lines;
    }

    /// Recover now if the path no longer names the held file, so a reader
    /// of `path` (the idempotency read-back, issue #312) sees this session's
    /// records rather than a missing or foreign file.
    void revalidate()
    {
        if (f.isOpen && !sameFile(f, path)) recoverReplaced();
    }

    /// Where the warning about a replaced log goes (tests capture it).
    void delegate(string) warn;
    /// Called after a recovery moved this session to a new id (oldId, newId),
    /// so the owner can move state keyed on the id (the handle claim). Runs
    /// on the append path: whatever it throws is swallowed.
    void delegate(string oldId, string newId) onIdChange;
    /// Like `onIdChange`, for the peer listener (issue #338): it moves the
    /// session's socket to the new id. A separate slot so the handle claim
    /// and the listener don't overwrite each other's hook.
    void delegate(string oldId, string newId) onIdChangeListener;

    /// Show `msg` to the user: through `warn` when set, else on stderr.
    void report(string msg)
    {
        if (warn) warn(msg);
        else
        {
            import nano.safeio : stdErr;
            import std.exception : collectException;
            // Best-effort diagnostic: a closed or unwritable stderr must not
            // abort the caller's pending write after a successful recovery.
            if (collectException(stdErr.writeln("\n", msg)) !is null) {}
        }
    }

    /// The path no longer names the file this writer holds open (something
    /// moved, deleted or rewrote the live log). Appending on would write into
    /// an orphan nobody can read again (issue #237), so move to a file that
    /// holds every record: the path itself when it is gone or a prefix of
    /// ours (append what it lacks), else a recovery file next to it. Always
    /// tell the user.
    private void recoverReplaced()
    {
        auto ours = readAll(f);
        string target = path, how;
        File next;
        bool done;
        import std.exception : collectException;
        // A failed in-place repair falls through to the recovery log below.
        collectException(() {
            // Whatever path leaves the in-place repair undone (non-prefix
            // rewrite, contention, a throw) must release `next`: the loop
            // below reassigns it, which would leak the fd and keep a lock
            // on the foreign file at the original path.
            scope (exit) if (!done && next.isOpen) next.close();
            if (!path.exists)
            {
                // Removed or moved away: put our records back at the path.
                {
                    auto tmp = format("%s.tmp-%s", path, thisProcessID);
                    scope (failure) if (tmp.exists) remove(tmp);
                    writePrivate(tmp, ours, octal!600);
                    publishOver(tmp, path);
                    next = openExistingForAppend(path);
                    // Locked, still at the path, AND holding exactly our
                    // records: a replacement that slipped in between the
                    // publish and this reopen must not count as restored.
                    if (tryLock(next) != LockResult.contended && sameFile(next, path)
                        && readAll(next) == ours && sameFile(next, path))
                    {
                        syncLog(next, path);
                        done = true;
                        how = "it was removed; restored it from this session's records";
                    }
                    else next.close(); // contended or re-replaced: no fd leak into the loop below
                }
            }
            else
            {
                // Lock first, then compare the whole locked file's bytes
                // (not just its length) and re-check the path still names it.
                // A contention or an inode change abandons the in-place
                // repair for the recovery log below: close `next` first, or
                // the loop's `next = createPrivate(...)` overwrites and
                // leaks the fd.
                next = openExistingForAppend(path);
                if (tryLock(next) == LockResult.contended || !sameFile(next, path))
                {
                    next.close();
                    return;
                }
                auto theirs = readAll(next);
                if (theirs.length <= ours.length && ours[0 .. theirs.length] == theirs)
                {
                    // The replacement may be wider than our private log
                    // (e.g. 0644): narrow it before appending private
                    // records, or fall back to a private recovery log.
                    import nano.safeio : fchmodFd;
                    if (fchmodFd(fileno(next.getFP), octal!600) != 0) return;
                    // Re-verify immediately before appending: a writer that
                    // ignores flock (or rewrote the inode meanwhile) would
                    // make the suffix land against a stale prefix, a gap or
                    // overlap. Any change: fall back to the recovery log.
                    if (!sameFile(next, path) || readAll(next) != theirs) return;
                    next.rawWrite(ours[theirs.length .. $]);
                    syncLog(next, path);
                    // And confirm the result is exactly our records at the path.
                    if (!sameFile(next, path) || readAll(next) != ours) return;
                    done = true;
                    how = "it was replaced; appended the records the new file was missing";
                }
            }
        }());
        if (!done)
        {
            // The path holds something else: keep the whole session in a
            // recovery log beside it, a resumable session of its own: its
            // header names the recovery id (same line count, so `#N` IDs hold).
            auto dir = path.dirName;
            auto stem = recoveryStem(id);
            bool made;
            foreach (n; 1 .. 1000)
            {
                auto rid = format("%s.recovered-%s", stem, n);
                target = buildPath(dir, rid ~ ".jsonl");
                // A name whose compressed archive exists belongs to an
                // earlier recovered session tidy-up compressed: reusing it
                // would shadow that archive (`findSession` prefers the plain
                // log) and strand its history, so skip to the next name.
                if (target.exists || (target ~ ".gz").exists) continue;
                // Exclusive create, then lock before anything else can, and
                // confirm the locked inode is still the one at the path.
                import std.exception : collectException;
                // Lost the race for this name (or cannot create it): try the next.
                // The exclusive-create descriptor itself is kept (never a
                // reopen of the name), so a swap of the path cannot hand us
                // someone else's file.
                if (collectException(next = createPrivate(target)) !is null) continue;
                // A name whose lock another writer won, or whose path no
                // longer names our inode: close our fd and try the next name.
                // Never unlink it: the path may now hold another writer's
                // records (or a replacement), and removing it could orphan them.
                bool locked = collectException(awaitLock(next, target)) is null;
                if (!locked || !sameFile(next, target)) { next.close(); continue; }
                // Test seam: let a test swap the destination now, so the
                // post-sync re-check below is exercised against a real race.
                if (swapAfterCreate !is null) swapAfterCreate(target);
                {
                    // A failed write or sync closes the candidate: never leak it.
                    scope (failure) next.close();
                    next.rawWrite(withHeaderId(ours, rid));
                    syncLog(next, target);
                }
                // An in-place rewrite of the same inode (a writer that
                // ignores flock) is invisible to `sameFile`: adopt the
                // candidate only if it holds exactly our records under the
                // recovery header, else close it and try the next name.
                if (readAll(next) != withHeaderId(ours, rid)) { next.close(); continue; }
                // Revalidate after the write+sync, before adopting: if another
                // process replaced `target` meanwhile, `next` is now an
                // unlinked inode and adopting it would send this session's
                // appends into a file nobody can read back. Close it and try
                // the next name rather than report a successful recovery.
                if (!sameFile(next, target)) { next.close(); continue; }
                made = true;
                break;
            }
            if (!made) throw new Exception("session log " ~ path ~ " was replaced and no recovery log could be created");
            how = "it was replaced by a different file; this session continues in " ~ target
                ~ " (resume it with --resume " ~ target.baseName.stripExtension ~ ")";
        }
        immutable old = path;
        immutable oldId = id;
        close();
        f = next;
        path = target;
        id = path.baseName.stripExtension;
        held = shareHandle(path, f);
        // A new id moves the attachments dir (`<id>.attachments`): copy the
        // stored images there so the recovered session still sees them,
        // leaving the originals for the old log.
        if (id != oldId) copyAttachments(buildPath(old.dirName, oldId ~ ".attachments"),
            buildPath(path.dirName, id ~ ".attachments"));
        auto msg = "WARNING: session log " ~ old ~ " no longer names the file this session was writing: "
            ~ how ~ ". Nothing was lost.";
        report(msg);
        if (id != oldId && onIdChange)
        {
            import std.exception : collectException;
            // The recovery already succeeded: a failing hook must not fail the write.
            if (auto e = collectException(onIdChange(oldId, id))) report("WARNING: " ~ e.msg);
        }
        if (id != oldId && onIdChangeListener)
        {
            import std.exception : collectException;
            // As above: the recovery succeeded whatever the hook does.
            if (auto e = collectException(onIdChangeListener(oldId, id))) report("WARNING: " ~ e.msg);
        }
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
    void input(string inputId, string text, string fromSession = null)
    {
        auto d = JSONValue(["id": inputId, "text": text, "recorded_at": nowStamp()]);
        // A peer-sent input records its sender's full session id (issue #272).
        if (fromSession.length) d["from_session"] = fromSession;
        write_(record("input", d));
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

    /// A finished plan replaced by a new one (issue #346): an audit record
    /// so the history tools can still find it; resume ignores it.
    void planArchive(JSONValue plan)
    {
        JSONValue d = ["recorded_at": nowStamp()];
        d["plan"] = plan;
        write_(record("plan_archive", d));
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

    /// A background sub-agent event (issue #266): its result delivered,
    /// cancelled or stopped with the session. Audit only: a resume ignores it.
    void subagent(string id, string event, string text)
    {
        write_(record("subagent", JSONValue(["id": id, "event": event, "text": text, "recorded_at": nowStamp()])));
    }

    /// A session setting the agent changed (`session_settings`, issue #293).
    /// Audit only: a resumed session starts from the config again.
    void setting(string key, string old, string next, string reason)
    {
        write_(record("setting", JSONValue(["key": key, "old": old, "new": next, "reason": reason,
            "recorded_at": nowStamp()])));
    }

    /// A runtime setting changed (`/model`, `/mode`, `/verbosity`, `/thinking`,
    /// `/subagents`, the context settings; issue #297): only the fields `s`
    /// names are recorded, and on restore the latest record of each field
    /// wins, so a resumed session carries on with the settings it stopped
    /// with.
    void settings(const SessionSettings s)
    {
        JSONValue d = ["recorded_at": nowStamp()];
        if (s.model.length) d["model"] = s.model;
        if (s.mode.length) d["mode"] = s.mode;
        if (s.verbosity.length) d["verbosity"] = s.verbosity;
        if (s.thinking.length) d["thinking"] = s.thinking;
        if (s.subagents >= 0) d["subagents"] = s.subagents != 0;
        if (s.compactionMode.length) d["compaction_mode"] = s.compactionMode;
        if (s.autoCompact >= 0) d["auto_compact"] = s.autoCompact != 0;
        if (!s.autoCompactThreshold.isNaN) d["auto_compact_threshold"] = s.autoCompactThreshold;
        if (s.contextWindow >= 0) d["context_window"] = s.contextWindow;
        if (s.contextWindow > 0) d["context_window_source"] = s.contextWindowFromProvider ? "provider" : "user";
        if (s.messages >= 0) d["session_messages"] = s.messages != 0;
        if (s.messagesConfirm >= 0) d["session_messages_confirm"] = s.messagesConfirm != 0;
        write_(record("settings", d));
    }

    /// The session's handle after `/name` (issue #300); null records a
    /// cleared handle. The latest record wins.
    void name(string handle)
    {
        JSONValue d = ["recorded_at": nowStamp()];
        d["name"] = handle.length ? JSONValue(handle) : JSONValue(null);
        write_(record("name", d));
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
        Option!size_t pinnedBase = Option!size_t.init, string trigger = null)
    {
        JSONValue[] ms;
        foreach (ref m; messages) ms ~= messageRecord(m);
        JSONValue d = ["recorded_at": nowStamp()];
        d["messages"] = ms;
        if (trigger.length) d["trigger"] = trigger;
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

/// Folded tool results and assistant replies whose payload (`slimPayload`)
/// is longer than this keep only their log reference in the replay stash
/// (live compactions and resumes alike).
enum size_t stashSlimBytes = 512;

/// The bytes of a message's payload that a stashed copy can drop and read
/// back from its log record: content, reasoning, and tool-call arguments.
size_t slimPayload(const ref Message m) pure nothrow
{
    // Calls and provider reasoning items can hold arbitrarily large JSON
    // that is costly to measure, so any structured payload counts as over
    // the threshold: slimming it is always safe (the log holds it).
    if (m.toolCalls.length || m.thinkingBlocks.length) return size_t.max;
    return m.content.length + m.thinking.length;
}

/// Whether a stashed copy of `m` keeps only its log reference: a tool result
/// or assistant reply with a large payload and no attachments.
bool stashSlimmable(const ref Message m) pure nothrow
{
    return (m.role == Role.tool || m.role == Role.assistant) && !m.attachments.length
        && slimPayload(m) > stashSlimBytes;
}

/// Drop the payload `stashSlimmable` measures; `rehydrateStash` restores it.
void slimMessage(ref Message m) pure nothrow
{
    m.content = null;
    m.thinking = null;
    m.thinkingBlocks = null;
    m.toolCalls = null;
}

/// Recover `pinText` for a user message logged before it was recorded: a
/// legacy prompt with hook context appended (`<input>\n\n<system-reminder>…`)
/// gets the logged input it starts with (the longest such) as its user-typed
/// part. A message that already has one, or is exactly an input, is left alone.
void backfillPinText(ref Message m, const string[] inputs) pure
{
    InputKey[] keys;
    foreach (i; inputs) keys ~= InputKey.of(i);
    backfillPinText(m, keys);
}

/// A logged input's identity (length and hash): `restore` keeps these, not
/// every input's text, to backfill `pinText` (issue #263).
struct InputKey
{
    size_t length, hash;

    /// The key of `text`.
    static InputKey of(const(char)[] text) pure nothrow @nogc => InputKey(text.length, hashOf(text));

    /// Whether this input is the same key (length and hash) as `other`.
    bool opEquals(const ref InputKey other) const pure nothrow @nogc => length == other.length && hash == other.hash;
}

/// `backfillPinText` over input keys: the user-typed part is the matching
/// prefix of the message's own content.
void backfillPinText(ref Message m, const InputKey[] inputs) pure
{
    import std.algorithm : any, canFind, startsWith;
    import std.string : stripLeft;
    if (m.role != Role.user || m.pinText.length || m.hookContext) return;
    enum wrapStart = "<system-reminder>";
    if (!m.content.canFind(wrapStart)) return;
    // The exact-match checks hash the content once, however many inputs share
    // its length: comparing keys, not re-running `matches` per input.
    const contentKey = InputKey.of(m.content);
    if ((inputs.length && inputs[$ - 1] == contentKey) || inputs.any!(k => k == contentKey)) return;
    size_t found;
    // Each distinct prefix length is hashed once, however many inputs share it.
    size_t[size_t] prefixHash;
    foreach_reverse (ref input; inputs)
        // A length inside a multi-byte character cannot be a typed prefix,
        // and `stripLeft` would throw decoding the split character.
        if (m.content.length > input.length && input.length > found
            && (m.content[input.length] & 0xC0) != 0x80
            && m.content[input.length .. $].stripLeft.startsWith(wrapStart))
        {
            auto h = prefixHash.require(input.length, hashOf(m.content[0 .. input.length]));
            if (h == input.hash) found = input.length;
        }
    if (found) m.pinText = m.content[0 .. found];
}

unittest
{
    // A candidate length that splits a UTF-8 character is skipped, not decoded.
    Message m;
    m.role = Role.user;
    m.content = "\u00e9\n\n<system-reminder>x</system-reminder>";
    backfillPinText(m, [InputKey.of("\u00e9"), InputKey.of("x")]);
    assert(m.pinText == "\u00e9");
    Message n;
    n.role = Role.user;
    n.content = "\u00e9\n\n<system-reminder>x</system-reminder>";
    backfillPinText(n, [InputKey.of("x")]);
    assert(n.pinText.length == 0);
}

/// A digest of what makes two logged messages the same (role, content, tool
/// calls and results, thinking blocks), so `restore` keeps one word per
/// original for `backfillLogLines` instead of the decoded message (issue #263).
private size_t contentDigest(const ref Message m)
{
    size_t h = hashOf(m.role);
    h = hashOf(m.content, h);
    h = hashOf(m.toolCallId, h);
    h = hashOf(m.toolName, h);
    h = hashOf(m.isError, h);
    if (m.toolCalls.length)
    {
        // The calls as logged: their normalized record, not the raw fields.
        auto j = messageRecord(m);
        h = hashOf(j["tool_calls"].toString, h);
    }
    if (m.thinkingBlocks.length) h = hashOf(JSONValue(m.thinkingBlocks.dup).toString, h);
    return h;
}

/// `contentDigest` plus every other field `slimMessage` drops (plain
/// reasoning) and the timestamp `rehydrateStash` checks, so a folded copy is
/// slimmed only when its direct record restores it exactly.
private size_t recoveryDigest(const ref Message m)
{
    size_t h = contentDigest(m);
    h = hashOf(m.thinking, h);
    return hashOf(m.timestamp, h);
}

unittest // a folded copy differing only in discarded fields or timestamp is not recovered
{
    Message a;
    a.role = Role.assistant;
    a.content = "x";
    a.thinking = "reasoning";
    a.timestamp = "2026-01-01T00:00:00Z";
    auto b = a;
    assert(recoveryDigest(a) == recoveryDigest(b));
    b.thinking = "other";
    assert(contentDigest(a) == contentDigest(b));
    assert(recoveryDigest(a) != recoveryDigest(b));
    b = a;
    b.timestamp = "2026-01-02T00:00:00Z";
    assert(recoveryDigest(a) != recoveryDigest(b));
}

unittest // structured payloads (calls, reasoning items) always count as large
{
    Message m;
    m.role = Role.assistant;
    assert(!stashSlimmable(m));
    m.toolCalls = [ToolCall.fromRaw("c", "write_file", `{"content":"` ~ "y" ~ `"}`)];
    assert(stashSlimmable(m));
}

/// A direct message record `backfillLogLines` may match: its line and digest.
private struct Original
{
    ulong logLine;
    size_t digest;
}

/// Backfill stable `[#N]` IDs onto a `replace` record's retained messages
/// from the direct records they came from (Rust `backfill_log_lines`): logs
/// from before stable IDs stored retained messages without `log_line`. Each
/// un-IDed non-system message takes the first unclaimed original with the
/// same content past the summarized range (folded originals are not retained).
private void backfillLogLines(Message[] messages, const Original[] originals, ulong summarizedEnd)
{
    bool[] claimed;
    foreach (ref m; messages)
    {
        if (m.logLine || m.role == Role.system) continue;
        if (!claimed.length) claimed = new bool[originals.length];
        immutable d = contentDigest(m);
        foreach (i, ref o; originals)
            if (!claimed[i] && o.logLine > summarizedEnd && o.digest == d)
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

/// The session's runtime settings as a `settings` record logs them (issue
/// #297): every field is absent-by-default, so a record changes only what it
/// names and the latest record of each field wins on restore. The header's
/// `model` is the starting value; a record's `model` supersedes it.
struct SessionSettings
{
    /// `provider/model` (empty: unchanged).
    string model;
    /// `/mode` name: normal, plan or auto (empty: unchanged).
    string mode;
    /// `/verbosity` name (empty: unchanged).
    string verbosity;
    /// `/thinking`: "reset" (clear override), "default", "off" or a level name (empty: unchanged).
    string thinking;
    /// `/subagents`: 1 on, 0 off, -1 unchanged.
    int subagents = -1;
    /// Compaction mode name: standard, smart or extract (empty: unchanged).
    string compactionMode;
    /// Auto-compaction: 1 on, 0 off, -1 unchanged.
    int autoCompact = -1;
    /// The auto-compaction threshold (NaN: unchanged).
    double autoCompactThreshold = double.nan;
    /// The context-window override in tokens; 0 clears it (-1: unchanged).
    long contextWindow = -1;
    /// `contextWindow` is a snapshot of the provider's own `context_window`
    /// (a model switch records it), not an explicit override: a resume must
    /// not carry it to another provider (issue #315).
    bool contextWindowFromProvider;
    /// Inter-session messages (`/messages on|off`, issue #336): 1 on, 0 off, -1 unchanged.
    int messages = -1;
    /// `/messages confirm on|off` (issue #336): 1 on, 0 off, -1 unchanged.
    int messagesConfirm = -1;

    /// Field-wise: the NaN "unchanged" threshold equals itself, which a
    /// struct's default bitwise equality rejects.
    bool opEquals(const ref SessionSettings o) const pure nothrow @nogc
    {
        import std.math : isNaN;
        return model == o.model && mode == o.mode && verbosity == o.verbosity && thinking == o.thinking
            && subagents == o.subagents && compactionMode == o.compactionMode && autoCompact == o.autoCompact
            && (autoCompactThreshold == o.autoCompactThreshold
                || (autoCompactThreshold.isNaN && o.autoCompactThreshold.isNaN))
            && contextWindow == o.contextWindow && contextWindowFromProvider == o.contextWindowFromProvider
            && messages == o.messages
            && messagesConfirm == o.messagesConfirm;
    }
}

/// What a session log restores to.
struct Restored
{
    string id, cwd, model, createdAt;
    /// The runtime settings the log's `settings` records restore (issue #297);
    /// `settings.model`, when set, supersedes `model`.
    SessionSettings settings;
    Message[] conversation;
    /// The newest prompts typed in this session, oldest first (bounded by the
    /// editor history's caps), for Up/Down recall after a resume. Prompts
    /// sent by another session are not included.
    string[] recentInputs;
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
    /// The `completed` ids oldest first, so a bounded holder drops the
    /// oldest responses first (issue #312).
    string[] completedOrder;
    /// The latest plan record (`{goal, items}`), or null.
    JSONValue plan;
    /// The latest timers record (`{last_id, items}`), or null.
    JSONValue timers;
    /// The session's handle (issue #300) as of the latest `name` record.
    string name;
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
    /// Per `replayStash` entry: its content was dropped because the log's
    /// direct record at its `logLine` holds the same text (issue #263), so a
    /// replay reads it back from the log rather than the resumed session
    /// holding every folded tool output. Shorter than `replayStash` when the
    /// trailing entries keep their content.
    bool[] replayStashSlim;
    /// Index, in the compacted conversation, of the restated in-flight input
    /// the latest compaction folded (its original is in `replayStash`).
    Option!size_t replayRestated;
    /// The latest compaction was smart: the history tools are offered.
    bool historyAvailable;
    /// The one-time history hint was already shown after that compaction.
    bool historyHintConsumed;
}

/// The end of the JSON value starting at `s[i]` (a raw scan: strings are
/// skipped escape-aware, containers by depth; nothing is decoded).
private size_t skipJSONValue(const(char)[] s, size_t i) pure nothrow @nogc
{
    size_t depth;
    while (i < s.length)
    {
        immutable c = s[i];
        if (c == '"')
        {
            for (++i; i < s.length && s[i] != '"'; ++i)
                if (s[i] == '\\') ++i;
            ++i;
            if (!depth) return i;
            continue;
        }
        if (c == '{' || c == '[') depth++;
        else if (c == '}' || c == ']')
        {
            if (!depth) return i;
            if (!--depth) return i + 1;
        }
        else if (!depth && (c == ',' || c == ' ' || c == '\t' || c == '\r' || c == '\n')) return i;
        ++i;
    }
    return i;
}

/// Decode the JSON escapes in the raw key text `key` in place of the slice
/// (a fresh copy only when it has any); false for a malformed escape.
private bool unescapeKey(ref const(char)[] key) pure @safe
{
    import std.ascii : isHexDigit;
    import std.utf : encode;
    size_t i;
    while (i < key.length && key[i] != '\\') ++i;
    if (i == key.length) return true;
    char[] o = key[0 .. i].dup;
    for (; i < key.length; ++i)
    {
        if (key[i] != '\\') { o ~= key[i]; continue; }
        if (++i >= key.length) return false;
        switch (key[i])
        {
            case '"': case '\\': case '/': o ~= key[i]; break;
            case 'b': o ~= '\b'; break;
            case 'f': o ~= '\f'; break;
            case 'n': o ~= '\n'; break;
            case 'r': o ~= '\r'; break;
            case 't': o ~= '\t'; break;
            case 'u':
                if (i + 4 >= key.length) return false;
                dchar c = 0;
                foreach (h; key[i + 1 .. i + 5])
                {
                    if (!h.isHexDigit) return false;
                    c = c * 16 + (h <= '9' ? h - '0' : (h | 0x20) - 'a' + 10);
                }
                i += 4;
                // Surrogates never spell a key we compare against: keep them
                // distinct but harmless.
                if (c >= 0xD800 && c <= 0xDFFF) c = 0xFFFD;
                char[4] buf;
                o ~= buf[0 .. encode(buf, c)];
                break;
            default: return false;
        }
    }
    key = o;
    return true;
}

/// Call `dg` with each top-level key (JSON escapes decoded) and the raw text of its
/// value in the JSON object `obj`, without parsing the values (issue #244: a
/// superseded compaction snapshot is skimmed, not decoded). Stops when `dg`
/// returns false; false for text that isn't an object.
private bool skimObject(const(char)[] obj, scope bool delegate(const(char)[] key, const(char)[] raw) @safe dg)
    => skimObjectAt(obj, (k, s, e) => dg(k, obj[s .. e]));

/// `skimObject`, giving each value as its `[start, end)` offsets in `obj`.
private bool skimObjectAt(const(char)[] obj, scope bool delegate(const(char)[] key, size_t start, size_t end) @safe dg)
{
    import std.ascii : isWhite;
    size_t i;
    void ws() { while (i < obj.length && obj[i].isWhite) ++i; }
    ws();
    if (i >= obj.length || obj[i] != '{') return false;
    ++i;
    for (;;)
    {
        ws();
        if (i >= obj.length) return false;
        if (obj[i] == '}') return true;
        if (obj[i] != '"') return false;
        auto ke = skipJSONValue(obj, i);
        if (ke > obj.length || ke < i + 2) return false;
        const(char)[] key = obj[i + 1 .. ke - 1];
        // An escaped key (`"folded\u005fbase"`) must compare by its decoded
        // value, or a delta could be misread as a full snapshot.
        if (!unescapeKey(key)) return false;
        i = ke;
        ws();
        if (i >= obj.length || obj[i] != ':') return false;
        ++i;
        ws();
        auto ve = skipJSONValue(obj, i);
        if (ve > obj.length) return false;
        if (!dg(key, i, ve)) return true;
        i = ve;
        ws();
        if (i < obj.length && obj[i] == ',') ++i;
    }
}

unittest // escaped_keys_are_decoded_before_comparison
{
    assert(skimField(`{"folded\u005fbase":[1],"x":2}`, "folded_base") == "[1]");
    assert(skimField(`{"a\"b":3}`, `a"b`) == "3");
    assert(skimField(`{"bad\uZZZZ":1}`, "bad") is null);
}

/// The raw value of top-level `key` in the JSON object `obj`, or null.
private const(char)[] skimField(const(char)[] obj, string key)
{
    const(char)[] found;
    skimObject(obj, (k, v) { if (k == key) { found = v; return false; } return true; });
    return found;
}

/// The decoded string of the record's top-level `type`, or null when it is
/// not a readable string. The raw value keeps its escapes, so an escaped
/// spelling (`"repla\u0063e"`) must decode to the type the full decoder sees,
/// or the skim scan and `restore` disagree on the record.
private const(char)[] skimType(const(char)[] line) => skimString(line, "type");

/// The decoded string value of top-level `key` in `obj`, or null when it is
/// not a readable string; escapes are decoded so comparisons match what the
/// full decoder sees.
private const(char)[] skimString(const(char)[] obj, string key)
{
    auto raw = skimField(obj, key);
    if (raw.length < 2 || raw[0] != '"' || raw[$ - 1] != '"') return null;
    const(char)[] type = raw[1 .. $ - 1];
    // A malformed escape fails closed: the record is not skimmed by type.
    if (!unescapeKey(type)) return null;
    return type;
}

unittest // escaped_type_decodes_before_comparison
{
    assert(skimType(`{"type":"replace","data":{}}`) == "replace");
    assert(skimType(`{"type":"repla\u0063e","data":{}}`) == "replace");
    assert(skimType(`{"type":"mes\u0073age"}`) == "message");
    assert(skimType(`{"type":"bad\uZZZZ"}`) is null);
    assert(skimType(`{"type":3}`) is null);
    assert(skimString(`{"role":"t\u006fol"}`, "role") == "tool");
}

/// Whether `raw` is a JSON integer `jsonUnsigned` accepts (no leading `-`
/// except the zero-valued `-0`, which std.json decodes to integer 0; fits a
/// ulong), and its value. The skim scan must read numbers exactly as
/// `restore`'s full decode does: a signed read would keep a `-1` floor or
/// pending position the full decode drops, and drop a `uinteger` above
/// `long.max` the full decode keeps (issue #240).
private bool rawUnsigned(const(char)[] raw, out ulong v) pure nothrow @nogc
{
    import std.ascii : isDigit;
    if (!raw.length) return false;
    auto digits = raw;
    // `-0` parses to integer 0, which `jsonUnsigned` accepts; any other
    // negative is rejected there and here.
    if (digits[0] == '-')
    {
        if (raw != "-0") return false;
        digits = raw[1 .. $];
    }
    ulong acc;
    foreach (c; digits)
    {
        if (!c.isDigit) return false;
        immutable uint d = c - '0';
        if (acc > (ulong.max - d) / 10) return false;
        acc = acc * 10 + d;
    }
    v = acc;
    return true;
}

unittest
{
    ulong v;
    assert(rawUnsigned("0", v) && v == 0);
    assert(rawUnsigned("-0", v) && v == 0); // std.json decodes -0 to integer 0
    assert(rawUnsigned("42", v) && v == 42);
    assert(rawUnsigned("18446744073709551615", v) && v == ulong.max);
    assert(!rawUnsigned("-1", v));
    assert(!rawUnsigned("-00", v));
    assert(!rawUnsigned("-42", v));
    assert(!rawUnsigned("18446744073709551616", v)); // above ulong.max
    assert(!rawUnsigned("1.5", v));
    assert(!rawUnsigned("", v));
    assert(!rawUnsigned("-", v));
}

/// Call `dg` with the raw text of each element of the raw JSON array `arr`.
private void skimArray(const(char)[] arr, scope void delegate(const(char)[] elem) @safe dg)
{
    import std.ascii : isWhite;
    size_t i;
    while (i < arr.length && arr[i].isWhite) ++i;
    if (i >= arr.length || arr[i] != '[') return;
    ++i;
    for (;;)
    {
        while (i < arr.length && arr[i].isWhite) ++i;
        if (i >= arr.length || arr[i] == ']') return;
        auto e = skipJSONValue(arr, i);
        if (e == i) return;
        dg(arr[i .. e]);
        i = e;
        while (i < arr.length && arr[i].isWhite) ++i;
        if (i < arr.length && arr[i] == ',') ++i;
    }
}

/// The number of elements of the raw JSON array `arr` (0 if not an array).
private size_t skimCount(const(char)[] arr) pure nothrow @nogc
{
    import std.ascii : isWhite;
    size_t i, n;
    while (i < arr.length && arr[i].isWhite) ++i;
    if (i >= arr.length || arr[i] != '[') return 0;
    ++i;
    for (;;)
    {
        while (i < arr.length && arr[i].isWhite) ++i;
        if (i >= arr.length || arr[i] == ']') return n;
        auto e = skipJSONValue(arr, i);
        if (e == i) return n;
        n++;
        i = e;
        while (i < arr.length && arr[i].isWhite) ++i;
        if (i < arr.length && arr[i] == ',') ++i;
    }
}

/// Stream the committed lines of a session log (a torn last line is
/// dropped) to `dg` with their 1-based line numbers, so a reader holds one
/// line rather than the whole log. `requireCommitted`: a log without a
/// committed record throws (a resume needs its header). A plain log is read
/// line by line rather than whole (issue #244); a compressed one is inflated.
void eachLogLine(string path, scope void delegate(const(char)[] line, ulong lineNo) @safe dg,
    bool requireCommitted = true, scope bool delegate(const(char)[] head) @safe keep = null)
{
    eachLogLineUntil(path, (const(char)[] line, ulong lineNo) { dg(line, lineNo); return true; },
        requireCommitted, keep);
}

/// `eachLogLine` whose `dg` returns false to stop reading: no further line
/// is read from the file, so an early-stopping caller never scans to EOF.
/// `keep`, if set, sees each line's first `lineHeadBytes`; a rejected line
/// is skipped unbuffered (never assembled) but still counts for `lineNo`.
void eachLogLineUntil(string path, scope bool delegate(const(char)[] line, ulong lineNo) @safe dg,
    bool requireCommitted = true, scope bool delegate(const(char)[] head) @safe keep = null)
{
    // One streaming reader for plain and compressed logs alike (64 KB reads,
    // a bounded inflate window): neither the file nor a decompressed copy is
    // ever held whole.
    ulong lineNo;
    streamLogLinesUntil(path, (line) {
        if (line.length && line[$ - 1] == '\r') line = line[0 .. $ - 1];
        return dg(line, ++lineNo);
    }, keep is null ? null : (const(char)[] head) {
        if (keep(head)) return true;
        ++lineNo;
        return false;
    });
    if (!lineNo && requireCommitted) throw new Exception("session log " ~ path ~ " has no committed records");
}

/// A finished turn as its `turn_end` record holds it.
struct CompletedTurn
{
    /// The final response.
    string response;
    /// The stop reason (`end_turn` when not recorded).
    string stopReason = "end_turn";
    /// The recorded outcome object, or null.
    JSONValue outcome;
}

/// The last `turn_end` record for input `inputId` in the log at `path`, read
/// back when a bounded in-memory record dropped it (issue #312); none when
/// the log is gone or holds no such record. Throws if the log is unreadable.
Option!CompletedTurn findCompletedTurn(string path, string inputId)
{
    Option!CompletedTurn found;
    if (!path.exists) return found;
    eachLogLine(path, (const(char)[] line, ulong) {
        // Decoded comparison: any spacing or escaping `restore` accepts.
        if (skimType(line) != "turn_end") return;
        // The skim decodes each lone surrogate escape to U+FFFD, so a
        // surrogate-pair id only prefilters here; parseJSON decides.
        auto sid = skimString(skimField(line, "data"), "input_id");
        if (sid is null) return;
        import std.algorithm.searching : canFind;
        if (sid != inputId && !sid.canFind("\uFFFD")) return;
        auto rec = parseJSON(line);
        auto data = "data" in rec;
        if (data is null || data.type != JSONType.object) return;
        auto id = "input_id" in *data;
        if (id is null || id.type != JSONType.string || id.str != inputId) return;
        CompletedTurn t;
        if (auto resp = "response" in *data) if (resp.type == JSONType.string) t.response = resp.str;
        if (auto st = "stop_reason" in *data) if (st.type == JSONType.string) t.stopReason = st.str;
        if (auto oc = "outcome" in *data) if (oc.type == JSONType.object) t.outcome = *oc;
        found = some(t);
    }, false, (const(char)[] head) {
        // Skip, unbuffered, any record whose head already names another
        // type (a multi-MB `replace` snapshot is never assembled). A head
        // whose type isn't readable yet is kept; the full skim decides.
        auto t = skimType(head);
        return t is null || t == "turn_end";
    });
    return found;
}

unittest // findCompletedTurn skips large non-turn_end records unassembled
{
    import core.memory : GC;
    import std.array : replicate;
    import std.file : tempDir, remove, write;
    import std.path : buildPath;
    auto big = `{"type":"replace","data":"` ~ "x".replicate(4_000_000) ~ `"}`;
    auto text = big ~ "\n" ~ `{ "type" : "turn_end", "data":{"input_id":"in-1","response":"ok"}}` ~ "\n";
    auto p = buildPath(tempDir, "nano-d-findturn-big.jsonl"), gz = p ~ ".gz";
    write(p, text);
    write(gz, gzipLog(text));
    big = null;
    text = null;
    scope (exit) { remove(p); remove(gz); }
    foreach (path; [p, gz])
    {
        auto before = GC.stats.allocatedInCurrentThread;
        auto t = findCompletedTurn(path, "in-1");
        auto used = GC.stats.allocatedInCurrentThread - before;
        assert(t.isSome, path);
        foreach (c; t) assert(c.response == "ok", path);
        assert(used < 1_000_000, path);
    }
}

unittest // eachLogLineUntil stops reading at the first false
{
    import std.file : tempDir, remove;
    import std.path : buildPath;
    import std.conv : to;
    import nano.clock : monoNow;
    auto p = buildPath(tempDir, "nano-until-" ~ to!string(monoNow.ticks) ~ ".jsonl");
    scope (exit) remove(p);
    std.file.write(p, "a\nb\nc\nd\n");
    ulong last;
    eachLogLineUntil(p, (const(char)[] l, ulong n) { last = n; return n < 2; });
    assert(last == 2);
}

/// Pass 1 of `restore` (issue #244): the line of the latest `replace` that
/// supersedes all earlier compaction state (a full restatement: no
/// `folded_base` / `pinned_base` delta), and its `summarized` end, found by
/// skimming record types without decoding any record. 0 when there is none.
/// `floor` is the lowest `summarized` end of that replace and every later
/// delta replace (an omitted range counts as 0), since `backfillLogLines`
/// reads originals past each one's range.
private ulong lastFullReplace(string path, out ulong floor, out ulong pinReset, out ulong lastReplace)
{
    ulong at;
    eachLogLine(path, (line, lineNo) {
        auto type = skimType(line);
        if (type != "replace") return;
        lastReplace = lineNo;
        auto data = skimField(line, "data");
        bool delta, pinDelta, pins;
        ulong fl = 0;
        // Fail closed: an unreadable `data` is never taken as a full snapshot.
        immutable ok = skimObject(data, (k, v) {
            if ((k == "folded_base" || k == "pinned_base") && v != "null") delta = true;
            if (k == "pinned_base" && v != "null") pinDelta = true;
            else if (k == "pinned_requests") pins = true;
            else if (k == "summarized")
            {
                // `[first, last]`: the second element, as `restore` reads it
                // (unsigned: a `-1` or a `uinteger` above long.max must land
                // exactly where the full decode lands).
                const(char)[][] parts;
                skimArray(v, (e) { parts ~= e; });
                ulong last;
                if (parts.length == 2 && rawUnsigned(parts[1], last)) fl = last;
            }
            return true;
        });
        if (!ok) delta = true;
        // A full `pinned_requests` restatement replaces the pinned stash.
        if (ok && pins && !pinDelta) pinReset = lineNo;
        if (!delta) { at = lineNo; floor = fl; }
        else if (at && fl < floor) floor = fl;
    });
    return at;
}

/// The size above which a superseded replace record's pinned requests and
/// messages snapshot are cut out before it is decoded. Every record in the
/// tests, so the skim-vs-full-decode equivalence tests cover the cut.
version (unittest) private enum pinSkimBytes = 0;
else private enum pinSkimBytes = 4096;

/// `line` with its record's `data.<key>` emptied to `[]`, or `line`
/// itself when it has none.
private const(char)[] withoutField(const(char)[] line, string key)
{
    size_t ds, de, ps, pe;
    bool data, pins;
    skimObjectAt(line, (k, s, e) {
        if (k != "data") return true;
        ds = s;
        de = e;
        data = true;
        return false;
    });
    if (!data) return line;
    skimObjectAt(line[ds .. de], (k, s, e) {
        if (k != key) return true;
        ps = ds + s;
        pe = ds + e;
        pins = true;
        return false;
    });
    return pins ? line[0 .. ps] ~ "[]" ~ line[pe .. $] : line;
}

unittest // withoutField_empties_only_that_field
{
    assert(withoutField(`{"type":"replace","data":{"a":1,"pinned_requests":[{"x":"]"}],"b":2}}`, "pinned_requests")
        == `{"type":"replace","data":{"a":1,"pinned_requests":[],"b":2}}`);
    assert(withoutField(`{"type":"replace","data":{"a":1}}`, "messages") == `{"type":"replace","data":{"a":1}}`);
}

/// Read a session log (Rust format), dropping a torn last line.
///
/// `slimStash` drops large folded tool outputs that the log's direct records
/// repeat (issue #263); the caller must then give `Agent.loadRestored` a log
/// on `path` to read them back. Pass false when no log will be supplied (a
/// `--no-session` load), or those folded turns would replay empty.
Restored restore(string path, bool slimStash = true) => restoreLog(path, true, slimStash);

/// `restore`, optionally decoding every record (`skipSuperseded` false: the
/// reference the two-pass restore is tested against).
private Restored restoreLog(string path, bool skipSuperseded, bool slimStash = true)
{
    import std.algorithm : countUntil;
    Restored r;
    // Records before the latest full `replace` only matter for what that
    // replace doesn't restate (issue #244): inputs, turn ends, plan, timers,
    // the pending input, and the originals `backfillLogLines` reads past its
    // summarized range. Superseded snapshots and messages are skimmed.
    ulong floorL;
    ulong pinReset, lastReplace;
    immutable skipBefore = skipSuperseded ? lastFullReplace(path, floorL, pinReset, lastReplace) : 0;
    // Per decoded replace: the length of its `messages` snapshot when a later
    // replace supersedes it, so the snapshot was not decoded.
    Option!size_t cutMessages;
    // The conversation length before `skipBefore`, without building it.
    size_t skimmedLen;
    string pendingId;
    // Every logged input's key (not its text: issue #263), to backfill
    // `pinText` on legacy messages.
    InputKey[] inputs;
    // The newest typed prompts, for the editor's Up/Down history (bounded).
    RecentInputs recentInputs;
    // A typed input awaiting its user message (see the "input" case).
    Option!string typedCandidate;
    void flushTyped()
    {
        typedCandidate.ifSome((string t) { recentInputs.put(t); });
        typedCandidate = none;
    }
    // A user message's effect on recall history: the typed input it
    // answers is kept unless the message was automatic; a local steer is kept.
    void noteUserMessage(bool isUser, bool autoInit, bool steered, bool fromPeer,
        scope Option!string delegate() @safe content)
    {
        if (isUser && !typedCandidate.isNone)
        {
            if (!autoInit) flushTyped();
            typedCandidate = none;
        }
        else if (isUser && steered && !fromPeer)
            content().ifSome((string c) { flushTyped(); recentInputs.put(c); });
    }
    Message[] rustStash;
    // Per `rustStash` entry: its content was dropped (`Restored.replayStashSlim`).
    bool[] stashSlim;
    // Every direct message record's line and digest, for `backfillLogLines`
    // (the decoded messages would hold the whole log until the end).
    Original[] originals;
    // The large direct tool results by line: a folded copy that matches
    // drops its content (issue #263).
    size_t[ulong] toolKeys;
    void noteTool(ulong lineNo, ref const Message m)
    {
        if (stashSlimmable(m)) toolKeys[lineNo] = recoveryDigest(m);
    }
    // Plan replay is bounded by the latest full snapshot (issue #205): deltas
    // before it are already folded in, so applying them would redo merges the
    // snapshot supersedes. `planAt` replays only the suffix from `planFrom`.
    JSONValue[] planDeltas;
    size_t planFrom;
    JSONValue planAt(size_t from)
    {
        import nano.result : unwrap;
        Plan p;
        if (r.plan.type == JSONType.object)
        {
            auto restored = Plan.fromJSON(r.plan);
            if (!restored.isErr) p = restored.unwrap("checked");
        }
        foreach (d; planDeltas[from .. $]) applyPlanDelta(p, d);
        return p.toJSON;
    }
    size_t index;
    eachLogLine(path, (line, lineNo) {
        if (!line.length) return;
        if (index && lineNo < skipBefore)
        {
            auto type = skimType(line);
            if (type == "message")
            {
                skimmedLen++;
                if (lineNo <= floorL)
                {
                    // Only a large tool result's or reply's key outlives
                    // the skim: such a line is decoded below for `toolKeys`.
                    auto data = skimField(line, "data");
                    auto role = skimString(data, "role");
                    // Recall history reads the user messages the skim
                    // skips: the same rule as the full decode below.
                    if (role == "user")
                    {
                        bool flag(string k) { return skimField(data, k) == "true"; }
                        noteUserMessage(true, flag("auto_initiated"), flag("steered"),
                            skimField(data, "from_session").length > 0, delegate Option!string() {
                                // The full JSON decoder, not `unescapeKey`: it keeps
                                // surrogate pairs, so recall matches the full decode.
                                auto raw = skimField(data, "content");
                                if (raw.length < 2 || raw[0] != '"') return Option!string.init;
                                try
                                {
                                    auto v = parseJSON(raw);
                                    if (v.type == JSONType.string) return some(v.str);
                                }
                                catch (JSONException) {} // malformed content: no recall entry, as the full decode
                                return Option!string.init;
                            });
                    }
                    // Structured payloads (calls, reasoning items) are
                    // slimmable at any size (`slimPayload`), so mirror that.
                    if ((role != "tool" && role != "assistant")
                        || (data.length <= stashSlimBytes
                            && !skimCount(skimField(data, "tool_calls"))
                            && !skimCount(skimField(data, "thinking_blocks"))))
                    {
                        index++;
                        return;
                    }
                }
                // An original past the latest summarized range: decoded
                // below, for `backfillLogLines` only.
            }
            if (type == "replace")
            {
                // Superseded: only its effect on the pending input outlives
                // the latest full replace. Mirror the full decode: a readable
                // position refreshes the pending snapshot (base included, so a
                // dropped input's stale fields match), anything else drops it.
                auto data = skimField(line, "data");
                skimmedLen = skimCount(skimField(data, "messages"));
                auto posRaw = skimField(data, "pending_position");
                ulong posVal;
                if (r.hasPending && rawUnsigned(posRaw, posVal))
                {
                    r.pending.position = toSize(posVal);
                    r.pending.hasContinuation = false;
                    r.pending.answer = null;
                    r.pending.count = 0;
                    r.pending.hasBase = true;
                    r.pending.base = skimmedLen;
                    r.pending.recallNotes = 0;
                }
                else
                {
                    r.hasPending = false;
                    r.pendingInput = null;
                    pendingId = null;
                }
                if (!posRaw.length || posRaw == "null")
                {
                    pendingId = null;
                    r.pendingInput = null;
                }
                index++;
                return;
            }
        }
        // A replace before the latest full pinned restatement: its pinned
        // requests are replaced, so they are not decoded. On a log written
        // before compaction pinned only user requests they can be most of
        // the line (issue #301: 12 MB).
        // Likewise a replace's `messages` snapshot, when a later replace
        // restates the conversation: only its length matters until then.
        cutMessages = Option!size_t.init;
        if (skipSuperseded && line.length > pinSkimBytes && lineNo < lastReplace && skimType(line) == "replace")
        {
            if (lineNo < pinReset) line = withoutField(line, "pinned_requests");
            size_t n = skimCount(skimField(skimField(line, "data"), "messages"));
            line = withoutField(line, "messages");
            cutMessages = some(n);
        }
        JSONValue rec;
        try rec = parseJSON(line);
        catch (Exception e) throw new Exception(format("decode record %s of %s: %s", index + 1, path, e.msg));
        auto type = rec["type"].str;
        auto data = "data" in rec ? rec["data"] : JSONValue(null);
        // The session header must still be first: plan records are consumed
        // below, but never before the header validates the log.
        if (!index && type != "session")
            throw new Exception("session log " ~ path ~ " does not start with a session header");
        if (type == "plan")
        {
            // A snapshot supersedes every earlier delta: drop them (bounding
            // memory as well as replay) and restart the suffix here.
            planDeltas = null;
            planFrom = 0;
            r.plan = data["plan"];
            index++;
            return;
        }
        if (type == "plan_delta")
        {
            planDeltas ~= data;
            index++;
            return;
        }
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
            inputs ~= InputKey.of(r.pendingInput);
            // Held until its message shows whether a timer or background
            // result generated it (`auto_initiated`); a peer's is never kept.
            flushTyped();
            if ("from_session" !in data) typedCandidate = some(r.pendingInput);
            r.hasPending = true;
            r.pending = PendingInput(pendingId, r.pendingInput,
                lineNo < skipBefore ? skimmedLen : r.conversation.length);
            break;
        case "message":
            {
                // The first message after an input is its user message: an
                // automatic one is not something the user typed. A local
                // steer (typed during a running turn) is.
                auto role = "role" in data;
                immutable isUser = role !is null && role.type == JSONType.string && role.str == "user";
                bool flag(string k) { auto v = k in data; return v !is null && v.type == JSONType.true_; }
                noteUserMessage(isUser, flag("auto_initiated"), flag("steered"), ("from_session" in data) !is null, delegate Option!string() {
                    auto c = "content" in data;
                    return c !is null && c.type == JSONType.string ? some(c.str) : Option!string.init;
                });
            }
            if (lineNo < skipBefore)
            {
                auto o = messageFromRecord(data);
                if (lineNo > floorL) originals ~= Original(lineNo, contentDigest(o));
                noteTool(lineNo, o);
                break;
            }
            r.conversation ~= messageFromRecord(data);
            r.conversation[$ - 1].logLine = lineNo;
            backfillPinText(r.conversation[$ - 1], inputs);
            originals ~= Original(lineNo, contentDigest(r.conversation[$ - 1]));
            noteTool(lineNo, r.conversation[$ - 1]);
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
                if (iid !in r.completed) r.completedOrder ~= iid;
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
            cutMessages.match!((size_t n) { r.conversation = new Message[n]; }, () {
                foreach (m; data["messages"].arrayNoRef) r.conversation ~= messageFromRecord(m);
            });
            {
                ulong floor;
                if (auto sum = "summarized" in data)
                    if (sum.type == JSONType.array && sum.arrayNoRef.length == 2)
                    {
                        ulong fu;
                        if (jsonUnsigned(sum.arrayNoRef[1], fu)) floor = fu;
                    }
                backfillLogLines(r.conversation, originals, floor);
            }
            foreach (ref m; r.conversation) backfillPinText(m, inputs);
            {
                // An in-flight input survives a mid-turn compaction at
                // `pending_position`, with its continuation snapshot. Every
                // number here is read through `jsonUnsigned`: the writer
                // logs them from a `size_t`, which std.json tags `uinteger`,
                // and an integer-only check misreads a self-written log
                // (issue #240).
                auto pos = "pending_position" in data;
                ulong posN;
                if (r.hasPending && pos !is null && jsonUnsigned(*pos, posN))
                {
                    r.pending.position = toSize(posN);
                    r.pending.hasContinuation = false;
                    r.pending.answer = null;
                    r.pending.count = 0;
                    auto c = "continuation" in data;
                    if (c !is null && c.type == JSONType.array && c.arrayNoRef.length == 2)
                    {
                        ulong cn;
                        r.pending.hasContinuation = true;
                        r.pending.answer = c.arrayNoRef[0].str;
                        r.pending.count = jsonUnsigned(c.arrayNoRef[1], cn) ? toSize(cn) : 0;
                    }
                    r.pending.hasBase = true;
                    r.pending.base = r.conversation.length;
                    auto rn = "pending_recall_notes" in data;
                    ulong rnn;
                    r.pending.recallNotes = rn !is null && jsonUnsigned(*rn, rnn) ? toSize(rnn) : 0;
                }
                else
                {
                    r.hasPending = false;
                    r.pendingInput = null;
                    pendingId = null;
                }
            }
            {
                static Message[] decode(const JSONValue v, const InputKey[] inputs)
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
                auto pins = "pinned_requests" in data, pinBase = "pinned_base" in data;
                // Logs written before compaction pinned only user requests
                // hold every folded turn in `pinned_requests` (issue #301: one
                // had 6,998, 12 MB, kept for the session's life). Only user
                // messages can be pinned, so the others shrink to an empty
                // placeholder that keeps the `pinned_base` indexes right;
                // `Agent.loadRestored` drops them.
                static Message[] pinsOnly(Message[] ms)
                {
                    foreach (ref m; ms)
                        if (m.role != Role.user)
                        {
                            Message p;
                            p.role = Role.tool;
                            m = p;
                        }
                    return ms;
                }
                // Folded turns whose large tool output matches its direct
                // record drop it: a replay reads it back from the log, and the
                // resumed session no longer holds every folded output (issue
                // #263). A Rust log's pinned block shares the stash, but only
                // its user requests are pinned, and those are never slimmed.
                bool[] slim(Message[] ms)
                {
                    auto o = new bool[ms.length];
                    if (!slimStash) return o;
                    foreach (i, ref m; ms)
                        if (stashSlimmable(m))
                            if (auto k = m.logLine in toolKeys)
                                if (*k == recoveryDigest(m))
                                {
                                    slimMessage(m);
                                    o[i] = true;
                                }
                    return o;
                }
                // Rust's cumulative stash of folded turns: full, or a delta on a base.
                auto folded = "folded" in data, base = "folded_base" in data;
                bool active;
                ulong foldedBaseN;
                if (folded !is null && base !is null && jsonUnsigned(*base, foldedBaseN))
                {
                    auto b = toSize(foldedBaseN);
                    auto delta = decode(*folded, inputs);
                    auto keep = b < rustStash.length ? b : rustStash.length;
                    if (keep + delta.length > 0)
                    {
                        auto flags = slim(delta); // before the copy: it drops content in place
                        rustStash = rustStash[0 .. keep] ~ delta;
                        stashSlim = stashSlim[0 .. keep] ~ flags;
                        active = true;
                    }
                }
                else if (folded !is null)
                {
                    auto full = decode(*folded, inputs);
                    if (full.length) { rustStash = full; stashSlim = slim(full); active = true; }
                }
                if (!active) { rustStash = null; stashSlim = null; }
                // Shared, not copied (issue #244): neither is mutated in place
                // (a later delta builds a new array), and an append to one
                // never shows through the other's length.
                r.replayStash = rustStash;
                r.replayStashSlim = stashSlim;
                r.replayRestated = Option!size_t.init;
                if (auto at = "restated" in data)
                {
                    ulong atN;
                    if (active && jsonUnsigned(*at, atN)) r.replayRestated = some(toSize(atN));
                }
                // The pinned block: a full `pinned_requests` restatement, or a
                // delta extending the first `pinned_base` of the stash so far
                // (issue #205). With neither, a Rust log's folded stash is it.
                ulong pinBaseN;
                if (pins !is null && pinBase !is null && jsonUnsigned(*pinBase, pinBaseN))
                {
                    auto b = toSize(pinBaseN);
                    auto kept = b < r.pinStash.length ? r.pinStash[0 .. b] : r.pinStash;
                    r.pinStash = kept ~ pinsOnly(decode(*pins, inputs));
                }
                else r.pinStash = pins !is null ? pinsOnly(decode(*pins, inputs)) : rustStash;
            }
            {
                auto mode = "mode" in data;
                r.historyAvailable = mode !is null && mode.type == JSONType.string
                    && (mode.str == "smart" || mode.str == "extract");
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
            break;
        case "timers":
            r.timers = data["timers"];
            break;
        case "name":
            if (auto n = "name" in data) r.name = n.type == JSONType.string ? n.str : null;
            break;
        case "recall":
            r.recall = data["recall"];
            break;
        case "settings":
            // The latest record of each field wins (issue #297); a field a
            // record omits keeps its earlier value. Hand-edited or corrupt
            // fields with the wrong JSON type or out-of-range values are
            // ignored instead of failing the resume.
            if (auto v = "model" in data)
                if (v.type == JSONType.string) r.settings.model = v.str;
            if (auto v = "mode" in data)
                if (v.type == JSONType.string) r.settings.mode = v.str;
            if (auto v = "verbosity" in data)
                if (v.type == JSONType.string) r.settings.verbosity = v.str;
            if (auto v = "thinking" in data)
                if (v.type == JSONType.string) r.settings.thinking = v.str;
            if (auto v = "subagents" in data)
                if (v.type == JSONType.true_ || v.type == JSONType.false_)
                    r.settings.subagents = v.type == JSONType.true_ ? 1 : 0;
            if (auto v = "compaction_mode" in data)
                if (v.type == JSONType.string) r.settings.compactionMode = v.str;
            if (auto v = "auto_compact" in data)
                if (v.type == JSONType.true_ || v.type == JSONType.false_)
                    r.settings.autoCompact = v.type == JSONType.true_ ? 1 : 0;
            if (auto v = "auto_compact_threshold" in data)
            {
                double t = double.nan;
                ulong n;
                if (v.type == JSONType.float_) t = v.floating;
                else if (jsonUnsigned(*v, n)) t = n;
                if (t > 0.0 && t <= 1.0) r.settings.autoCompactThreshold = t;
            }
            if (auto v = "context_window" in data)
            {
                ulong n;
                if (jsonUnsigned(*v, n) && n <= long.max)
                {
                    r.settings.contextWindow = n.to!long;
                    // The source travels with its window. Only a record
                    // marked "user" is an explicit override; a legacy
                    // unmarked (or unknown) one is treated as a provider
                    // snapshot, so a resume never promotes it (issue #315).
                    auto src = "context_window_source" in data;
                    r.settings.contextWindowFromProvider = !(src !is null && src.type == JSONType.string
                        && src.str == "user");
                }
            }
            if (auto v = "session_messages" in data)
                if (v.type == JSONType.true_ || v.type == JSONType.false_)
                    r.settings.messages = v.type == JSONType.true_ ? 1 : 0;
            if (auto v = "session_messages_confirm" in data)
                if (v.type == JSONType.true_ || v.type == JSONType.false_)
                    r.settings.messagesConfirm = v.type == JSONType.true_ ? 1 : 0;
            break;
        default: // hooks, setting: audit only
            break;
        }
        index++;
    });
    // Apply the deltas after the latest full snapshot, if any remain.
    if (planDeltas.length > planFrom) r.plan = planAt(planFrom);
    flushTyped();
    r.recentInputs = recentInputs.lines;
    return r;
}

/// Apply one `plan_delta` record to `p` (issue #205): keep the first `base`
/// items, apply the goal change, drop removed ids and upsert the rest. A base
/// past the plan's length (a hand-edited or torn log) restarts the plan from
/// the delta's items.
private void applyPlanDelta(ref Plan p, JSONValue data)
{
    import nano.plan : PlanItem;
    import nano.result : unwrap;
    import std.algorithm : countUntil;
    auto base = "base" in data;
    // `planDelta` writes `base` from a size_t, which toJSON tags uinteger —
    // an integer-only check reads a self-written log as a torn one and
    // restarts the plan from the delta's items.
    ulong bu = ulong.max;
    auto b = base is null || !jsonUnsigned(*base, bu) ? size_t.max : toSize(bu);
    if (b > p.items.length) p = Plan.init;
    else if (b < p.items.length) p.items = p.items[0 .. b];
    if (auto g = "goal" in data)
        if (g.type == JSONType.string) p.goal = g.str;
    if (auto dr = "drop" in data)
        if (dr.type == JSONType.array)
        {
            bool[uint] gone;
            foreach (x; dr.arrayNoRef)
            {
                ulong id;
                if (jsonUnsigned(x, id) && id <= uint.max) gone[id.to!uint] = true;
            }
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
        ulong n; // ids above long.max can't name an item: treat as absent
        return jsonUnsigned(*v, n) && n <= long.max ? n.to!long : -1;
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
/// EINTR is retried: a signal that interrupted the call (SIGCHLD from a
/// spawned test or hook process) says nothing about the lock's state, and
/// macOS returns it even for a non-blocking flock.
private LockResult tryLock(ref File f) @trusted
{
    import core.stdc.errno : errno, EWOULDBLOCK, EAGAIN, EINTR;
    for (;;)
    {
        if (flock(fileno(f.getFP), LOCK_EX | LOCK_NB) == 0) return LockResult.acquired;
        immutable err = errno;
        if (err == EINTR) continue;
        return err == EWOULDBLOCK || err == EAGAIN ? LockResult.contended : LockResult.unsupported;
    }
}

/// Every byte `f` holds, read from its start (the position is left at EOF).
private ubyte[] readAll(ref File f)
{
    import std.stdio : SEEK_END;
    f.flush();
    f.seek(0);
    ubyte[] all;
    auto buf = new ubyte[](64 * 1024);
    for (;;)
    {
        auto chunk = f.rawRead(buf);
        if (!chunk.length) break;
        all ~= chunk;
    }
    f.seek(0, SEEK_END);
    return all;
}

/// The id stem for a recovery log of session `id`: any earlier
/// `.recovered-N` suffix dropped (so repeats do not stack), and cut short
/// enough that `<stem>.recovered-999` still passes `validateId`.
string recoveryStem(string id) pure
{
    import std.ascii : isDigit;
    import std.string : lastIndexOf;
    auto stem = id;
    auto at = stem.lastIndexOf(".recovered-");
    if (at >= 0)
    {
        auto n = stem[at + ".recovered-".length .. $];
        bool digits = n.length > 0;
        foreach (c; n) digits = digits && c.isDigit;
        if (digits) stem = stem[0 .. at];
    }
    enum room = 128 - ".recovered-999".length;
    if (stem.length > room) stem = stem[0 .. room];
    return stem;
}

/// `text` with its first line's `session` header renamed to `newId`; other
/// lines and the line count are untouched. Text without a parseable header
/// line comes back unchanged (an empty `newId` also leaves it unchanged).
const(ubyte)[] withHeaderId(const(ubyte)[] text, string newId)
{
    import std.algorithm : countUntil;
    import std.exception : collectException;
    import std.string : assumeUTF;
    if (!newId.length) return text;
    auto nl = text.countUntil('\n');
    if (nl < 0) return text;
    JSONValue j;
    // Not a JSON header line: nothing to rename, keep the bytes as they are.
    if (collectException(j = parseJSON(text[0 .. nl].assumeUTF)) !is null) return text;
    if (j.type != JSONType.object || "type" !in j || j["type"].type != JSONType.string
        || j["type"].str != "session" || "data" !in j || j["data"].type != JSONType.object)
        return text;
    j["data"]["id"] = newId;
    return record("session", j["data"]).representation ~ text[nl + 1 .. $];
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

/// Copy every file of the attachments dir `from` into `to` (best-effort:
/// a failed copy leaves that image unavailable, never aborts recovery).
private void copyAttachments(string from, string to)
{
    import std.file : dirEntries, SpanMode, isDir, mkdirRecurse, copy;
    import std.exception : collectException;
    // The whole traversal is best-effort: an unreadable dir or a failing
    // entry stat must not abort recovery (the warning and the pending
    // record still have to be written).
    collectException(() {
        if (!from.exists || !from.isDir) return;
        collectException(mkdirRecurse(to));
        foreach (e; dirEntries(from, SpanMode.shallow))
        {
            bool file;
            if (collectException(file = e.isFile) !is null || !file) continue;
            auto dest = buildPath(to, e.name.baseName);
            if (!dest.exists) collectException(copy(e.name, dest));
        }
    }());
}

/// Flush and fsync `f` (the log at `path`) and its parent directory, so
/// recovered records survive a power loss before being reported. Throws.
private void syncLog(ref File f, string path)
{
    import nano.safeio : fsyncFd;
    f.flush();
    if (fsyncFd(fileno(f.getFP)) != 0) throw new Exception("cannot sync " ~ path);
    syncDirOf(path);
}

/// `path` opened for appending without ever creating it.
private File openExistingForAppend(string path) { return openLog(path, false); }

/// `path` opened read/write + append + close-on-exec; `create` makes it
/// exclusively (0600), keeping that very descriptor.
private File openLog(string path, bool create) @trusted
{
    import core.sys.posix.fcntl : open, fcntl, O_RDWR, O_APPEND, O_CREAT, O_EXCL, F_SETFD, FD_CLOEXEC;
    import nano.safeio : fchmodFd;
    import std.string : toStringz;
    import core.stdc.errno : errno, ENOENT;
    import std.exception : ErrnoException;
    // O_RDWR: a writer that finds its log replaced reads its own records
    // back to recover them. Close-on-exec: a `/relaunch` exec must not
    // inherit the fd and its flock, or the new image's resume is contended.
    version (linux) enum int cloexec = 0x80000; // O_CLOEXEC
    else version (OSX) enum int cloexec = 0x1000000;
    else enum int cloexec = 0;
    auto fd = create
        ? open(path.toStringz, O_RDWR | O_APPEND | O_CREAT | O_EXCL | cloexec, octal!600)
        : open(path.toStringz, O_RDWR | O_APPEND | cloexec);
    if (fd < 0)
    {
        immutable err = errno;
        if (create) throw new ErrnoException("cannot create " ~ path, err);
        if (err == ENOENT) throw new Exception("session log " ~ path ~ " does not exist");
        throw new ErrnoException("cannot open session log " ~ path, err);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC); // also where O_CLOEXEC is unknown
    if (create) fchmodFd(fd, octal!600); // never wider, whatever the umask
    File f;
    f.fdopen(fd, "a+");
    return f;
}

@("openExistingForAppend distinguishes a missing log from an access failure")
unittest
{
    import std.file : tempDir, write, remove, setAttributes;
    import std.path : buildPath;
    import std.exception : collectExceptionMsg;
    import std.algorithm : canFind;
    auto missing = buildPath(tempDir, "nano-oefa-missing-" ~ __LINE__.stringof);
    assert(collectExceptionMsg(openExistingForAppend(missing)).canFind("does not exist"));
    auto ro = buildPath(tempDir, "nano-oefa-ro-" ~ __LINE__.stringof);
    write(ro, "");
    scope (exit) remove(ro);
    setAttributes(ro, octal!444);
    auto msg = collectExceptionMsg(openExistingForAppend(ro));
    if (msg is null) return; // root bypasses permission bits
    assert(!msg.canFind("does not exist") && msg.canFind("cannot open"), msg);
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
    import nano.safeio : closeFd;
    auto fd = createPrivateFd(path, mode);
    scope (exit) closeFd(fd);
    writeAllFd(fd, data, path);
}

/// A new file at `path` created exclusively, write-only, owner-only `mode`;
/// the caller closes the descriptor.
private int createPrivateFd(string path, uint mode)
{
    import core.sys.posix.fcntl : O_WRONLY, O_CREAT, O_EXCL;
    import nano.safeio : openPath, fchmodFd, closeFd;
    auto fd = openPath(path, O_WRONLY | O_CREAT | O_EXCL, mode & octal!600);
    if (fd < 0) throw new Exception("cannot create " ~ path);
    scope (failure) closeFd(fd);
    fchmodFd(fd, mode & octal!600);
    return fd;
}

/// Write all of `data` to `fd` (named `path` in errors).
private void writeAllFd(int fd, const(ubyte)[] data, string path)
{
    import nano.safeio : writeFd;
    while (data.length)
    {
        auto n = writeFd(fd, data);
        if (n <= 0) throw new Exception("cannot write " ~ path);
        data = data[n .. $];
    }
}

/// Inflate the compressed log at `src` into the new file `dst` (created
/// exclusively with `mode`) through `GunzipStream`, 64 KiB at a time (issue
/// #313: reopening an archive never holds the whole log in RAM).
private void gunzipFile(string src, string dst, uint mode)
{
    import std.stdio : File;
    import nano.safeio : closeFd;
    auto f = File(src, "rb");
    scope (exit) f.close();
    auto gz = GunzipStream(src);
    scope (exit) gz.close();
    auto fd = createPrivateFd(dst, mode);
    scope (exit) closeFd(fd);
    auto buf = new ubyte[](64 * 1024);
    for (;;)
    {
        auto got = gz.read(f, buf);
        if (!got.length) break;
        writeAllFd(fd, got, dst);
    }
}

/// A new session log opened for appending, created owner-only (0600).
/// The descriptor from the exclusive create itself is returned (read/write,
/// append, close-on-exec): reopening the name would race a replacement.
private File createPrivate(string path)
{
    return openLog(path, true);
}

/// fsync `path`'s parent directory, so a created or removed directory entry
/// survives a power loss. Tolerated only where the filesystem refuses
/// directory handles or directory fsync outright (EINVAL): every other
/// failure throws, so a caller that removes the source after publishing
/// never retires it without a durable destination entry.
private void syncDirOf(string path) @trusted
{
    import core.stdc.errno : errno, EINVAL;
    // Plain O_RDONLY: druntime lacks O_DIRECTORY on macOS, and the parent
    // of a path is a directory by construction.
    import core.sys.posix.fcntl : O_RDONLY;
    import nano.safeio : openPath, fsyncFd, closeFd;
    auto fd = openPath(path.dirName, O_RDONLY);
    if (fd < 0)
    {
        if (errno == EINVAL) return;
        throw new Exception("cannot open the directory of " ~ path);
    }
    scope (exit) closeFd(fd);
    if (fsyncFd(fd) != 0 && errno != EINVAL)
        throw new Exception("cannot sync the directory of " ~ path);
}

/// Publish the fully written temp file `tmp` as `dest` durably: fsync the
/// data, link the name over any existing destination, sync the directory
/// entry, then unlink the temp name. A crash anywhere leaves either the old
/// or the new file whole at `dest` (never a truncated one), and a failure
/// before the link leaves the original intact. The caller deletes the
/// replaced original (when there is one) only after this returns.
private void publishOver(string tmp, string dest) @trusted
{
    import core.sys.posix.fcntl : O_RDONLY;
    import core.sys.posix.unistd : link, unlink;
    import nano.safeio : openPath, fsyncFd, closeFd;
    import std.string : toStringz;
    auto fd = openPath(tmp, O_RDONLY);
    if (fd < 0) throw new Exception("cannot open " ~ tmp);
    scope (exit) closeFd(fd);
    if (fsyncFd(fd) != 0) throw new Exception("cannot sync " ~ tmp);
    if (link(tmp.toStringz, dest.toStringz) != 0) throw new Exception("cannot publish " ~ dest);
    syncDirOf(dest);
    unlink(tmp.toStringz);
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
    import nano.session_index : titledIds, indexFile, list;
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
    // Refresh the index first: a handle recorded after a session's last
    // indexing (issue #300) is only in its log until a listing re-reads it.
    try { list(dir, true); named = titledIds(dir); }
    catch (Exception) mayDelete = false; // unknown titles: compress only, delete nothing
    tidyDir(dir, now, compressAfterDays, retentionDays, mayDelete, named, result);
    // Sub-agent logs sit one level down (<session>/sub-<call>.jsonl): the
    // same rules apply to them, except that a named (retained) parent
    // session keeps its children too: compressed, never deleted.
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
        if (e.isDir && !e.name.baseName.endsWith(".attachments"))
            tidyDir(e.name, now, compressAfterDays, retentionDays, mayDelete && e.name.baseName !in named, named, result);
    try std.file.write(stampPath, "");
    catch (Exception) {} // a stamp that won't write just tidies again next start
    return result;
}

/// One directory's pass of `tidySessions` (also used for the child-log
/// directories one level down).
private void tidyDir(string dir, SysTime now, long compressAfterDays, long retentionDays,
        bool mayDelete, const bool[string] named, ref TidyResult result)
{
    import nano.session_index : indexFile;
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
                import std.file : setTimes;
                auto gz = e.name ~ ".gz";
                auto before = getSize(e.name);
                auto tmp = format("%s.tmp-%s", gz, thisProcessID);
                scope (failure) if (tmp.exists) remove(tmp);
                // Streamed (issue #313): the log is never held whole.
                // Gzip can grow a short log: keep the original then.
                if (gzipFile(e.name, tmp, modeOf(e.name)) >= before)
                {
                    remove(tmp);
                    continue;
                }
                // Keep the last activity time: retention and the picker
                // measure age from it, not from compression.
                auto mtime = timeLastModified(e.name);
                setTimes(tmp, mtime, mtime);
                // Sync the archive and its directory entry before unlinking
                // the original: a power loss must not lose both.
                publishOver(tmp, gz);
                remove(e.name);
                result.freedBytes += before - getSize(gz);
                ++result.compressed;
            }
        }
        catch (Exception) {} // one unreadable log must not stop the pass
    }
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

// issue #297: settings records round-trip; the latest record of each field
// wins, a record changes only what it names, and a log without any keeps the
// defaults (the header's model is the starting value).
unittest
{
    auto dir = buildPath(tempDir, "nano-coder-session-settings");
    if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/a", "/x");
    auto sys = Message.system("sys");
    log.append(sys);
    // Old log, no settings records: every field is "unchanged".
    auto r0 = restore(log.path);
    auto noSettings = SessionSettings.init;
    assert(r0.model == "mock/a" && r0.settings == noSettings);
    SessionSettings s1;
    s1.model = "mock/b";
    s1.mode = "plan";
    s1.verbosity = "verbose";
    s1.thinking = "high";
    s1.subagents = 0;
    s1.compactionMode = "smart";
    s1.autoCompact = 1;
    s1.autoCompactThreshold = 0.7;
    s1.contextWindow = 50_000;
    log.settings(s1);
    SessionSettings s2;
    s2.model = "mock/c";
    s2.subagents = 1;
    log.settings(s2);
    auto r = restore(log.path);
    assert(r.model == "mock/a", "the header keeps the creation-time model");
    assert(r.settings.model == "mock/c", "the latest record wins");
    assert(r.settings.mode == "plan" && r.settings.verbosity == "verbose" && r.settings.thinking == "high");
    assert(r.settings.subagents == 1 && r.settings.compactionMode == "smart");
    assert(r.settings.autoCompact == 1);
    // JSON text round-trips a double only approximately.
    assert(imported!"std.math".isClose(r.settings.autoCompactThreshold, 0.7));
    assert(r.settings.contextWindow == 50_000);
    // A record names only what changed: the earlier record's fields survive.
    auto lines = readText(log.path).lineSplitter.array;
    auto rec = parseJSON(lines[$ - 1]);
    assert(rec["type"].str == "settings" && rec["data"]["model"].str == "mock/c");
    assert("mode" !in rec["data"] && rec["data"]["subagents"].boolean == true);
    assert("recorded_at" in rec["data"]);
    // A resumed log keeps accepting appends after the records.
    auto again = new SessionLog(log.path);
    auto more = Message.user("more");
    again.append(more);
    assert(restore(log.path).settings.model == "mock/c");
    assert(!restore(log.path).settings.contextWindowFromProvider, "written without the provider mark: a user override");
    assert(imported!"std.algorithm".canFind(readText(log.path), `"context_window_source":"user"`));
    // A provider snapshot keeps its source; a later override drops it.
    SessionSettings snap;
    snap.contextWindow = 128_000;
    snap.contextWindowFromProvider = true;
    again.settings(snap);
    assert(restore(log.path).settings.contextWindowFromProvider);
    SessionSettings explicitSame;
    explicitSame.contextWindow = 128_000;
    again.settings(explicitSame);
    assert(!restore(log.path).settings.contextWindowFromProvider);
    // A legacy record with no source mark is provider-derived, not an override.
    {
        import std.file : append;
        append(log.path, `{"type":"settings","data":{"context_window":90000}}` ~ "\n");
    }
    assert(restore(log.path).settings.contextWindow == 90_000);
    assert(restore(log.path).settings.contextWindowFromProvider, "unmarked legacy snapshot promoted to an override");
}

// issue #336: the messaging switch and its confirm setting round-trip; the
// latest record wins and a record that omits them leaves them unchanged.
unittest
{
    auto dir = buildPath(tempDir, "nano-coder-session-settings-messages");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/a", "/x");
    auto sys = Message.system("sys");
    log.append(sys);
    assert(restore(log.path).settings.messages == -1 && restore(log.path).settings.messagesConfirm == -1);
    SessionSettings on;
    on.messages = 1;
    on.messagesConfirm = 0;
    log.settings(on);
    SessionSettings other;
    other.verbosity = "quiet";
    log.settings(other);
    auto r = restore(log.path);
    assert(r.settings.messages == 1 && r.settings.messagesConfirm == 0);
    SessionSettings off;
    off.messages = 0;
    log.settings(off);
    std.file.append(log.path, `{"type":"settings","data":{"session_messages":"yes","session_messages_confirm":1}}` ~ "\n");
    r = restore(log.path);
    assert(r.settings.messages == 0 && r.settings.messagesConfirm == 0, "wrong types are ignored");
    SessionSettings conf;
    conf.messagesConfirm = 1;
    log.settings(conf);
    assert(restore(log.path).settings.messagesConfirm == 1);
}

// issue #297: a settings record with a cleared context window (0) restores
// as 0, distinct from "never recorded" (-1).
unittest
{
    auto dir = buildPath(tempDir, "nano-coder-session-settings-clear");
    if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/a", "/x");
    auto sys = Message.system("sys");
    log.append(sys);
    SessionSettings s;
    s.contextWindow = 0;
    log.settings(s);
    auto r = restore(log.path);
    assert(r.settings.contextWindow == 0);
}

// issue #297: corrupt or hand-edited `settings` records with wrong JSON types
// or out-of-range numeric values are ignored per-field instead of failing the
// resume; uinteger context_window values still decode via jsonUnsigned.
unittest
{
    auto dir = buildPath(tempDir, "nano-coder-session-settings-corrupt");
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/a", "/x");
    auto sys = Message.system("sys");
    log.append(sys);
    SessionSettings good;
    good.model = "mock/good";
    good.mode = "plan";
    good.verbosity = "verbose";
    good.thinking = "high";
    good.subagents = 1;
    good.compactionMode = "smart";
    good.autoCompact = 1;
    good.autoCompactThreshold = 0.75;
    good.contextWindow = 64_000;
    log.settings(good);
    log.close();
    // Append a malformed settings record with wrong types and out-of-range numbers.
    std.file.append(log.path, `{"type":"settings","data":{"model":123,"mode":true,"verbosity":[],`
        ~ `"thinking":{},"subagents":"yes","compaction_mode":42,"auto_compact":"no",`
        ~ `"auto_compact_threshold":"bad","context_window":"nope"}}` ~ "\n");
    std.file.append(log.path, `{"type":"settings","data":{"auto_compact_threshold":-0.5,"context_window":-10}}` ~ "\n");
    std.file.append(log.path, `{"type":"settings","data":{"auto_compact_threshold":1.5}}` ~ "\n");
    auto r = restore(log.path);
    assert(r.settings.model == "mock/good");
    assert(r.settings.mode == "plan");
    assert(r.settings.verbosity == "verbose");
    assert(r.settings.thinking == "high");
    assert(r.settings.subagents == 1);
    assert(r.settings.compactionMode == "smart");
    assert(r.settings.autoCompact == 1);
    assert(imported!"std.math".isClose(r.settings.autoCompactThreshold, 0.75));
    assert(r.settings.contextWindow == 64_000);
    // A valid integer threshold (1) and large positive context_window still apply.
    std.file.append(log.path, `{"type":"settings","data":{"auto_compact_threshold":1,"context_window":200000}}` ~ "\n");
    auto r2 = restore(log.path);
    assert(r2.settings.autoCompactThreshold == 1.0);
    assert(r2.settings.contextWindow == 200_000);
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

// Many same-length inputs: the exact-match checks hash the message content
// once, and the backfill still picks the matching prefix (issue #263 review).
unittest
{
    import std.format : format;
    // 64 distinct inputs of one length; none is a prefix of the wire message.
    string[] same;
    foreach (i; 0 .. 64) same ~= format("%016d", i);
    auto wire = "answer 42\n\n<system-reminder>ctx</system-reminder>";
    auto m = Message.user(wire);
    backfillPinText(m, same);
    assert(m.pinText is null, "no same-length input is a prefix");
    // One of them is exactly the message: it must be recognised, not rehashed
    // per candidate into a wrong prefix.
    auto exact = Message.user(same[7]);
    backfillPinText(exact, same);
    assert(exact.pinText is null, "an exact input match is left alone");
    // A real prefix among many same-length decoys is still found.
    auto p = Message.user("answer 42\n\n<system-reminder>ctx</system-reminder>");
    backfillPinText(p, same ~ ["answer 42"]);
    assert(p.pinText == "answer 42");
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
    auto sb = Message.auto_("<system-reminder>no</system-reminder>");
    sb.stopBlocked = true;
    auto st = Message.user("steer");
    st.steered = true;
    st.fromSession = "sess-peer-full";
    log.replace([Message.auto_("note"), hook, sb, st], 1, 2, "standard", "m", [p]);
    auto r = restore(log.path);
    assert(r.pinStash.length == 1 && r.pinStash[0].pinText == "goal");
    assert(r.conversation[0].autoInitiated && r.conversation[1].hookContext
        && r.conversation[2].stopBlocked && !r.conversation[0].stopBlocked
        && r.conversation[3].steered && !r.conversation[2].steered
        && r.conversation[3].fromSession == "sess-peer-full");
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

// `SessionLog.replace` writes `pinned_base`, `folded_base` and `restated`
// from a `size_t`, which std.json tags `uinteger`; `restore` must read its
// own log back (issue #240 — an integer-only check dropped the delta's base,
// so a resume restored only the delta and lost the earlier pins).
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-uintbase-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w");
    static Message pin(string text)
    {
        auto m = Message.user(text);
        m.pinText = text;
        return m;
    }

    // First compaction pins one request and folds two turns (full forms).
    log.replace([Message.auto_("s1")], 1, 2, "standard", "m", [pin("one")], null,
        [Message.user("t1"), Message.assistant("a1")]);
    // Second compaction adds a pinned delta on `pinned_base` 1, a folded delta
    // on `folded_base` 2, and restates the in-flight input at conversation
    // index 0 — all three bases written as `uinteger`.
    log.replace([Message.auto_("s2")], 3, 4, "standard", "m", [pin("two")], null,
        [Message.user("t2")], some(size_t(2)), some(size_t(0)), some(size_t(1)));
    auto r = restore(log.path);
    assert(r.pinStash.length == 2 && r.pinStash[0].pinText == "one" && r.pinStash[1].pinText == "two",
        "a self-written pinned delta extends the kept prefix, not replaces it");
    assert(r.replayStash.length == 3 && r.replayStash[0].content == "t1"
        && r.replayStash[2].content == "t2", "a self-written folded delta extends the stash");
    assert(!r.replayRestated.isNone, "a self-written `restated` reads back");
    foreach (at; r.replayRestated) assert(at == 0);

    // A mid-turn compaction's pending fields are uinteger-tagged too.
    auto log2 = new SessionLog(dir, "mock/m", "/w");
    log2.input("in-1", "work");
    auto p = PendingInput("in-1", "work", 1);
    p.hasContinuation = true;
    p.answer = "half";
    p.count = 2;
    p.recallNotes = 3;
    log2.replace([Message.user("work")], 0, 0, null, null, null, &p);
    auto r2 = restore(log2.path);
    assert(r2.hasPending && r2.pending.position == 1, "pending_position reads back");
    assert(r2.pending.hasContinuation && r2.pending.answer == "half" && r2.pending.count == 2,
        "the continuation snapshot reads back");
    assert(r2.pending.recallNotes == 3, "pending_recall_notes reads back");

    // A `uinteger`-tagged base in the log itself: parseJSON tags a number
    // above long.max `uinteger` on every Phobos, so this exercises the
    // integer-only misread directly (a base past the stash keeps it whole).
    import std.file : write;
    static JSONValue rec(Message m) { return messageRecord(m); }
    auto path3 = buildPath(dir, "ub.jsonl");
    write(path3, `{"type":"session","data":{"version":1,"id":"ub","created_at":"x"}}` ~ "\n"
        ~ JSONValue(["type": JSONValue("replace"), "data": JSONValue([
            "messages": JSONValue([rec(Message.user("s"))]),
            "pinned_requests": JSONValue([rec(pin("one"))]),
        ])]).toString ~ "\n"
        ~ `{"type":"replace","data":{"messages":[],"pinned_base":18446744073709551615,"pinned_requests":[]}}` ~ "\n");
    auto r3 = restore(path3);
    assert(r3.pinStash.length == 1 && r3.pinStash[0].pinText == "one",
        "a uinteger-tagged pinned_base reads as a base, not as a torn log");
}

// Guard for the class (issue #240): `restore` must never gate a numeric read
// on the `integer` tag alone — a `size_t` round-trips through std.json as
// `uinteger`. Every number `restore` reads goes through `jsonUnsigned` (or
// `jsonSigned`), which accepts both tags; this test fails if a direct
// `.type == JSONType.integer` comparison creeps back into `restore`.
unittest
{
    import std.algorithm : canFind, findSplit, splitter;
    import std.file : readText;
    import std.string : indexOf;
    const src = readText(__FILE__);
    const start = src.indexOf("private Restored restoreLog(string path");
    assert(start >= 0, "restore's definition is found in this file");
    const rest = src[start .. $];
    const tail = rest.findSplit("\n}\n")[2]; // restore's body ends at its first column-0 `}`
    const body = rest[0 .. $ - tail.length];
    assert(body.canFind("jsonUnsigned"), "restore reads numbers through jsonUnsigned");
    assert(!body.canFind("JSONType.integer"),
        "restore compares no .type against JSONType.integer directly: a size_t logs as uinteger");
    // messageFromRecord decodes embedded records too: `log_line` is a ulong.
    const mstart = src.indexOf("Message messageFromRecord(JSONValue j)");
    assert(mstart >= 0, "messageFromRecord's definition is found in this file");
    const mrest = src[mstart .. $];
    const mbody = mrest[0 .. $ - mrest.findSplit("\n}\n")[2].length];
    foreach (line; mbody.splitter('\n'))
        if (line.canFind(`"log_line"`))
            assert(line.canFind("jsonUnsigned") && !line.canFind("JSONType.integer"),
                "messageFromRecord reads log_line through jsonUnsigned: a ulong logs as uinteger");
}

// An embedded record's `log_line` (a ulong, tagged uinteger) round-trips.
unittest
{
    auto m = Message.user("x");
    m.logLine = 42;
    auto j = messageRecord(m);
    assert(j["log_line"].type == JSONType.uinteger);
    assert(messageFromRecord(j).logLine == 42);
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
    // A uinteger-tagged base — what `planDelta` itself writes from a size_t —
    // applies as a base, not as a torn log restarting the plan.
    {
        auto p4 = Plan.fromJSON(parseJSON(
            `{"goal":"g","items":[{"id":1,"title":"a","status":"pending"},{"id":2,"title":"b","status":"pending"}]}`)).unwrap("a valid plan");
        JSONValue d;
        d["base"] = JSONValue(2u);
        d["drop"] = JSONValue([JSONValue(1u)]);
        d["upserts"] = JSONValue([parseJSON(`{"id":2,"title":"b","status":"done"}`)]);
        applyPlanDelta(p4, d);
        assert(p4.goal == "g" && p4.items.length == 1 && p4.items[0].id == 2
            && p4.items[0].status == Status.done, "a uinteger base keeps the first items");
        // An out-of-shape base still restarts the plan from the delta's items.
        auto p5 = p4;
        JSONValue d5;
        d5["base"] = JSONValue("two");
        d5["upserts"] = JSONValue([parseJSON(`{"id":9,"title":"z","status":"pending"}`)]);
        applyPlanDelta(p5, d5);
        assert(p5.items.length == 1 && p5.items[0].id == 9, "a malformed base restarts the plan");
    }
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

// A titled (retained) session keeps its sub-agent logs: they may be
// compressed but are never deleted; an untitled one's expire (#231 review).
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, setTimes;
    import core.time : days;
    import nano.session_index : list, setTitle;
    auto dir = buildPath(tempDir, "nano-d-tidy-children");
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    string childOf(string id)
    {
        auto t = new SessionLog(dir, "mock/m", "/w", id);
        t.input("in-1", "a session " ~ id);
        t.close();
        auto sub = buildPath(dir, id);
        mkdirRecurse(sub);
        auto c = buildPath(sub, "sub-x.jsonl");
        std.file.write(c, "{}\n");
        setTimes(c, wallNow - 200.days, wallNow - 200.days);
        return c;
    }
    auto keptChild = childOf("kept");
    auto goneChild = childOf("gone");
    list(dir);
    setTitle(buildPath(dir, "kept.jsonl"), "Keep me");
    auto r = tidySessions(dir, 0, 180);
    assert(keptChild.exists, "a titled session's child log is retained");
    assert(!goneChild.exists && r.deleted == 1, format("%s", r));
}

// Review fixes for issue #205 (round 8): an archive resume never replaces an
// existing plain log, and a plan replay applies only the deltas after the
// latest full snapshot.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import std.exception : assertThrown;
    import nano.plan : Plan;
    import nano.result : unwrap;
    auto dir = buildPath(tempDir, "nano-d-r8-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    // Both names present: the archive resume refuses and leaves both intact.
    auto a = new SessionLog(dir, "mock/m", "/w", "both");
    a.input("in-1", "archived prompt");
    a.close();
    auto gz = a.path ~ ".gz";
    std.file.write(gz, gzipLog(readText(a.path)));
    std.file.write(a.path, "plain twin\n");
    import std.exception : collectException;
    auto ex = collectException!Exception(new SessionLog(gz));
    assert(ex !is null && ex.msg.canFind("already exists"), ex !is null ? ex.msg : "no throw");
    assert(readText(a.path) == "plain twin\n" && gz.exists, "both copies survive");
    remove(a.path);
    // Without the twin the archive resumes as before.
    auto back = new SessionLog(gz);
    back.close();
    assert(back.path == a.path && a.path.exists && !gz.exists);

    // Plan replay: deltas before the latest snapshot are already folded in.
    auto log = new SessionLog(dir, "mock/m", "/w", "planreplay");
    log.plan(parseJSON(`{"items":[{"id":1,"title":"first","status":"pending"}]}`));
    log.planDelta(JSONValue(null), [parseJSON(`{"id":1,"title":"first","status":"done"}`)], [], 1);
    log.plan(parseJSON(`{"items":[{"id":1,"title":"first","status":"done"},{"id":2,"title":"second","status":"pending"}]}`));
    log.planDelta(JSONValue(null), [parseJSON(`{"id":2,"title":"second","status":"done"}`)], [], 2);
    log.close();
    auto p = Plan.fromJSON(restore(log.path).plan).unwrap("a valid plan");
    import nano.plan : Status;
    assert(p.items.length == 2 && p.items[0].status == Status.done && p.items[1].status == Status.done,
        "the snapshot plus its later deltas restore the plan");
}

/// Collect garbage and return the free GC pools to the OS: after a burst
/// of short-lived allocation (loading a session) the heap otherwise stays
/// at its peak.
void releaseHeap() nothrow
{
    import core.memory : GC;
    GC.collect();
    GC.minimize();
}

// A long log with many superseded full compaction snapshots (issue #244)
// restores, skimming them, to exactly what decoding every record gives:
// inputs, turn ends, the pending input across compactions, the retained
// messages' backfilled log lines, and the Rust folded stash (held once).
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    import std.conv : text;
    auto dir = buildPath(tempDir, "nano-d-skim-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto log = `{"type":"session","data":{"version":1,"id":"skim","created_at":"x"}}` ~ "\n";
    ulong lines = 1;
    JSONValue[] folded;
    Message[] live;
    void add(string type, JSONValue data) { log ~= line(type, data); lines++; }
    foreach (round; 0 .. 12)
    {
        auto first = lines + 1;
        ulong lastIn;
        foreach (t; 0 .. 5)
        {
            lastIn = lines + 1;
            auto id = text("in-", round, "-", t);
            auto q = text("question ", round, " ", t);
            add("input", JSONValue(["id": id, "text": q]));
            auto u = Message.user(q ~ "\n\n<system-reminder>ctx</system-reminder>");
            add("message", rec(u));
            add("message", rec(Message.assistant(text("answer ", round, " ", t))));
            live ~= u;
            if (t < 4 || round % 3) add("turn_end", JSONValue(["input_id": JSONValue(id), "response": JSONValue("ok")]));
        }
        if (round == 4) add("plan", JSONValue(["plan": parseJSON(`{"goal":"g","items":[]}`)]));
        if (round == 6) add("timers", JSONValue(["timers": parseJSON(`{"last_id":1,"items":[]}`)]));
        foreach (m; live[0 .. $ - 1]) folded ~= rec(m);
        // Retained: the latest exchange, without log lines (backfilled).
        JSONValue d = ["messages": JSONValue([rec(Message.user("summary")), rec(live[$ - 1]),
            rec(Message.assistant(text("answer ", round, " 4")))])];
        d["folded"] = folded;
        d["summarized"] = JSONValue([JSONValue(first), JSONValue(lastIn - 1)]);
        if (round % 3 == 0) d["pending_position"] = 1;
        live = live[$ - 1 .. $];
        add("replace", d);
    }
    add("input", JSONValue(["id": "tail", "text": "still going"]));
    add("message", rec(Message.user("still going")));
    auto path = buildPath(dir, "skim.jsonl");
    write(path, log ~ `{"type":"mess`); // and a torn last line
    auto skimmed = restoreLog(path, true), full = restoreLog(path, false);
    assert(skimmed == full, "skimming superseded snapshots restores the same state");
    assert(skimmed.conversation.length == 4 && skimmed.conversation[1].logLine && skimmed.conversation[2].logLine,
        "retained messages get their log lines");
    assert(skimmed.completed.length == full.completed.length && skimmed.hasPending);
    assert(skimmed.replayStash.length == folded.length && skimmed.pinStash.ptr is skimmed.replayStash.ptr,
        "the Rust folded stash is held once");
}

unittest // skim_floor_counts_later_delta_replaces (issue #244)
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-skimdelta-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto log = `{"type":"session","data":{"version":1,"id":"skimdelta","created_at":"x"}}` ~ "\n";
    ulong lines = 1;
    void add(string type, JSONValue data) { log ~= line(type, data); lines++; }
    auto early = Message.user("early question");
    add("input", JSONValue(["id": "in-0", "text": "early question"]));
    add("message", rec(early));
    add("message", rec(Message.assistant("early answer")));
    JSONValue full = ["messages": JSONValue([rec(Message.user("summary"))])];
    full["folded"] = JSONValue([rec(early)]);
    full["summarized"] = JSONValue([JSONValue(2), JSONValue(lines)]);
    add("replace", full);
    // A later delta replace, with no `summarized`, retaining the early message
    // without its log line: backfill must still find the original.
    JSONValue delta = ["messages": JSONValue([rec(Message.user("summary 2")), rec(early)])];
    delta["folded"] = JSONValue(cast(JSONValue[]) []);
    delta["folded_base"] = 1;
    add("replace", delta);
    auto path = buildPath(dir, "skimdelta.jsonl");
    write(path, log);
    auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
    assert(skimmed == fullR, "a later delta lowers the skim floor");
}

unittest // escaped_delta_key_is_not_a_full_snapshot (issue #244)
{
    import std.array : replace;
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-skimesc-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto log = `{"type":"session","data":{"version":1,"id":"skimesc","created_at":"x"}}` ~ "\n";
    auto one = Message.user("one"), two = Message.user("two");
    log ~= line("message", rec(one));
    JSONValue full = ["messages": JSONValue([rec(Message.user("summary"))])];
    full["folded"] = JSONValue([rec(one)]);
    log ~= line("replace", full);
    JSONValue delta = ["messages": JSONValue([rec(Message.user("summary 2"))])];
    delta["folded"] = JSONValue([rec(two)]);
    delta["folded_base"] = 1;
    log ~= line("replace", delta).replace(`"folded_base"`, `"folded\u005fbase"`);
    auto path = buildPath(dir, "skimesc.jsonl");
    write(path, log);
    auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
    assert(skimmed == fullR, "an escaped delta key still marks a delta");
    assert(skimmed.replayStash.length == 2, "the earlier folded stash survives");
}

unittest // escaped_type_delta_lowers_the_skim_floor (issue #244)
{
    import std.array : replace;
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-skimesctype-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto log = `{"type":"session","data":{"version":1,"id":"skimesctype","created_at":"x"}}` ~ "\n";
    ulong lines = 1;
    void add(string type, JSONValue data) { log ~= line(type, data); lines++; }
    auto early = Message.user("early question");
    add("input", JSONValue(["id": "in-0", "text": "early question"]));
    add("message", rec(early));
    add("message", rec(Message.assistant("early answer")));
    JSONValue full = ["messages": JSONValue([rec(Message.user("summary"))])];
    full["folded"] = JSONValue([rec(early)]);
    full["summarized"] = JSONValue([JSONValue(2), JSONValue(lines)]);
    add("replace", full);
    // A later delta replace whose `type` is spelled with an escape and which
    // omits `summarized`: the floor must still lower to 0 so backfill finds
    // the retained original, exactly as full decoding restores it.
    JSONValue delta = ["messages": JSONValue([rec(Message.user("summary 2")), rec(early)])];
    delta["folded"] = JSONValue(cast(JSONValue[]) []);
    delta["folded_base"] = 1;
    log ~= line("replace", delta).replace(`"type":"replace"`, `"type":"repla\u0063e"`);
    lines++;
    auto path = buildPath(dir, "skimesctype.jsonl");
    write(path, log);
    auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
    assert(skimmed == fullR, "an escaped-type delta still lowers the skim floor");
}

unittest // skim_floor_reads_summarized_unsigned (issue #244)
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-skimflooru-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    // A full replace whose `summarized` end is signed-hostile: `-1` (which
    // the full decode's jsonUnsigned rejects, leaving the floor at 0) and a
    // uinteger above long.max (which a signed skim read rejects but the full
    // decode accepts). The skimmed restore must land where the full one does.
    foreach (i, end; [`-1`, `18446744073709551615`])
    {
        immutable id = "skimflooru" ~ i.to!string;
        auto log = `{"type":"session","data":{"version":1,"id":"` ~ id ~ `","created_at":"x"}}` ~ "\n";
        auto early = Message.user("early question");
        log ~= line("input", JSONValue(["id": "in-0", "text": "early question"]));
        log ~= line("message", rec(early));
        log ~= line("message", rec(Message.assistant("early answer")));
        // Retain the early message (without its log line) so a wrong skim
        // floor changes its backfilled log line and fails the comparison.
        JSONValue full = ["messages": JSONValue([rec(Message.user("summary")), rec(early)])];
        full["folded"] = JSONValue([rec(early)]);
        auto rl = line("replace", full);
        // Splice the raw summarized end in unquoted through the existing
        // `folded` field, past std.json's tagging.
        import std.array : replace;
        rl = rl.replace(`"folded":`, `"summarized":[2,` ~ end ~ `],"folded":`);
        log ~= rl;
        auto path = buildPath(dir, id ~ ".jsonl");
        write(path, log);
        auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
        assert(skimmed == fullR, "a signed-hostile summarized end (" ~ end ~ ") skims like the full decode");
        // `-1` leaves the floor at 0, so backfill claims the early original;
        // above-long.max keeps the floor past it, so it is never claimed.
        assert(skimmed.conversation[1].logLine == (i == 0 ? 3 : 0),
            "the hostile end (" ~ end ~ ") moves the retained message's log line");
    }
}

unittest // skim_pending_position_reads_unsigned (issue #244)
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-skimposu-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    // An in-flight input preserved by the first full replace, then a
    // superseded delta whose `pending_position` is signed-hostile: `-1` (full
    // decode drops the pending input), `-0` (full decode keeps it: std.json
    // parses -0 to integer 0, which jsonUnsigned accepts), and a uinteger
    // above long.max (full decode keeps it). A final full replace re-reads
    // whatever pending state survived the skimmed delta, so a skim that
    // disagrees with the full decode loses (or keeps) the input.
    foreach (i, pos; [`-1`, `-0`, `18446744073709551615`])
    {
        immutable id = "skimposu" ~ i.to!string;
        auto log = `{"type":"session","data":{"version":1,"id":"` ~ id ~ `","created_at":"x"}}` ~ "\n";
        log ~= line("input", JSONValue(["id": "in-0", "text": "crash here"]));
        // The first snapshot preserves the in-flight input at position 0.
        JSONValue full = ["messages": JSONValue([rec(Message.user("summary"))])];
        full["folded"] = JSONValue(cast(JSONValue[]) []);
        full["pending_position"] = 0;
        log ~= line("replace", full);
        JSONValue delta = ["messages": JSONValue([rec(Message.user("summary 2"))])];
        delta["folded"] = JSONValue(cast(JSONValue[]) []);
        delta["folded_base"] = 1;
        auto dl = line("replace", delta);
        import std.array : replace;
        dl = dl.replace(`"folded_base":1`, `"folded_base":1,"pending_position":` ~ pos);
        log ~= dl;
        // A later full replace with position 0: it cannot restore a pending
        // flag the skimmed delta wrongly cleared, and it keeps one the full
        // decode kept. Continuation snapshots are compared only while the
        // input is active, since inactive pending fields can retain stale
        // values.
        JSONValue last = ["messages": JSONValue([rec(Message.user("summary 3"))])];
        last["folded"] = JSONValue(cast(JSONValue[]) []);
        last["pending_position"] = 0;
        log ~= line("replace", last);
        auto path = buildPath(dir, id ~ ".jsonl");
        write(path, log);
        auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
        assert(skimmed == fullR, "a signed-hostile pending_position (" ~ pos ~ ") skims like the full decode");
        immutable survives = pos != `-1`;
        assert(skimmed.hasPending == survives,
            "the pending input " ~ (survives ? "survives " : "is dropped by ") ~ pos ~ " exactly as the full decode");
        if (survives) assert(skimmed.pendingInput == "crash here", "the input text survives " ~ pos);
    }
}

@("a session log's fd is close-on-exec, so a relaunched image can lock it (#237)")
unittest
{
    import std.process : spawnProcess, wait, Config;
    auto dir = buildPath(tempDir, format("nano-coder-cloexec-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    scope (exit) log.close();
    immutable fd = log.f.fileno;
    auto resumed = new SessionLog(log.path); // shared in-process handle
    resumed.close();
    // Exec level: an exec'd image must not see the fd (and its flock).
    auto script = format("test ! -e /dev/fd/%s", fd);
    // inheritFDs: std.process closes nothing, so only FD_CLOEXEC can.
    auto pid = spawnProcess(["/bin/sh", "-c", script], null, Config.inheritFDs);
    assert(wait(pid) == 0, "the log fd survived exec");
}

@("a log replaced under a live writer loses nothing silently (#237)")
unittest
{
    import std.algorithm : canFind, count;
    auto dir = buildPath(tempDir, format("nano-coder-replaced-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    string[] warned;

    // 1. Replaced by a copy (a prefix of ours): the path gets the rest.
    {
        auto log = new SessionLog(dir, "mock/m", "/x");
        log.warn = (string m) { warned ~= m; };
        log.input("i1", "first");
        auto p = log.path;
        auto text = readText(p);
        rename(p, p ~ ".moved");
        std.file.write(p, text);
        setAttributes(p, octal!644); // a world-readable replacement
        log.input("i2", "second");
        log.close();
        assert((getAttributes(p) & octal!777) == octal!600, "the replacement is narrowed before appending");
        auto now = readText(p);
        assert(now.canFind("first") && now.canFind("second"), now);
        assert(now.count('\n') == 3);
        assert(warned.length == 1 && warned[0].canFind("missing"), warned[0]);
    }
    // 2. Removed: the path is restored with every record.
    {
        auto log = new SessionLog(dir, "mock/m", "/x");
        log.warn = (string m) { warned ~= m; };
        log.input("i1", "alpha");
        auto p = log.path;
        remove(p);
        log.input("i2", "beta");
        log.close();
        auto now = readText(p);
        assert(now.canFind("alpha") && now.canFind("beta"), now);
        assert(warned.length == 2 && warned[1].canFind("removed"));
    }
    // 3. Rewritten with different content (e.g. compacted): a recovery log.
    {
        auto log = new SessionLog(dir, "mock/m", "/x");
        log.warn = (string m) { warned ~= m; };
        log.input("i1", "gamma");
        auto p = log.path;
        remove(p);
        std.file.write(p, "{\"type\":\"session\",\"data\":{}}\n");
        log.input("i2", "delta");
        auto rec = log.path;
        log.input("i3", "epsilon");
        {
            // The foreign file at the original path must not stay locked
            // by a leaked in-place-repair fd while this writer lives on.
            auto probe = File(p, "r+");
            immutable probeLock = tryLock(probe);
            assert(probeLock == LockResult.acquired,
                "a leaked fd still locks the rewritten path (probe: " ~ probeLock.to!string ~ ")");
            probe.close();
        }
        log.close();
        assert(rec != p && rec.exists);
        auto now = readText(rec);
        assert(now.canFind("gamma") && now.canFind("delta") && now.canFind("epsilon"), now);
        assert(readText(p) == "{\"type\":\"session\",\"data\":{}}\n");
        assert(warned.length == 3 && warned[2].canFind(rec));
        validateId(log.id);
        // The recovery is a resumable session: its header names its id.
        restore(rec); // throws on a header id mismatch
        assert(parseJSON(readText(rec).lineSplitter.front)["data"]["id"].str == log.id);
        assert(findSession(dir, log.id) == rec);
    }
    // 4. Rewritten with different content of the same length: not a prefix.
    {
        auto log = new SessionLog(dir, "mock/m", "/x");
        log.warn = (string m) { warned ~= m; };
        log.input("i1", "zeta");
        auto p = log.path;
        auto text = readText(p);
        remove(p);
        { import std.array : replace; std.file.write(p, text.replace("zeta", "ZETA")); }
        log.input("i2", "eta");
        auto rec = log.path;
        log.close();
        assert(rec != p, "an equal-length rewrite must not be treated as a prefix");
        assert(readText(rec).canFind("zeta") && readText(rec).canFind("eta"));
        assert(readText(p).canFind("ZETA") && !readText(p).canFind("eta"));
    }
}

@("recovery ids stay valid for long and repeatedly recovered ids (#237)")
unittest
{
    auto longId = new char[](128);
    longId[] = 'a';
    auto stem = recoveryStem(longId.idup);
    validateId(stem ~ ".recovered-999");
    assert(recoveryStem("sess-x.recovered-3") == "sess-x");
    assert(recoveryStem("sess-x.recovered-") == "sess-x.recovered-");
    assert(withHeaderId("{\"type\":\"session\",\"data\":{\"id\":\"a\"}}\nrest\n".representation, "b")
        == "{\"type\":\"session\",\"data\":{\"id\":\"b\"}}\nrest\n".representation);
    assert(withHeaderId("not json\n".representation, "b") == "not json\n".representation);
}

@("closing an old sharer after an in-place recovery keeps the recovered handle (#237)")
unittest
{
    import std.algorithm : canFind;
    auto dir = buildPath(tempDir, format("nano-coder-sharers-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto a = new SessionLog(dir, "mock/m", "/x");
    a.warn = (string) {};
    auto b = new SessionLog(a.path); // shares a's handle
    auto p = a.path;
    remove(p);
    a.input("i1", "after-removal"); // recovers in place: a new handle at p
    b.close(); // must not close a's recovered handle
    assert(a.isOpenForWrite);
    a.input("i2", "still-writing");
    a.close();
    assert(readText(p).canFind("still-writing"));
    assert(p !in openHere);
}

@("a contended in-place repair falls through to a recovery log and leaks no fd (#237)")
unittest
{
    import std.algorithm : canFind, count;
    auto dir = buildPath(tempDir, format("nano-coder-contended-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    log.warn = (string) {};
    log.input("i1", "kappa");
    auto p = log.path;
    // Replace the path with a foreign file whose lock another handle holds:
    // the in-place repair is contended, so recovery must fall through to a
    // recovery log — closing the contended fd it opened, not leaking it.
    auto foreign = buildPath(dir, "foreign.jsonl");
    std.file.write(foreign, "{\"type\":\"session\",\"data\":{}}\n");
    auto holder = openExistingForAppend(foreign);
    assert(tryLock(holder) == LockResult.acquired);
    scope (exit) holder.close();
    rename(foreign, p);
    log.input("i2", "lambda");
    auto rec = log.path;
    log.close();
    assert(rec != p && rec.exists, "a contended in-place repair recovers to a recovery log");
    auto now = readText(rec);
    assert(now.canFind("kappa") && now.canFind("lambda"), now);
    assert(now.count('\n') == 3, now); // header + both records: nothing lost
    assert(readText(p) == "{\"type\":\"session\",\"data\":{}}\n", "the foreign file is untouched");
    // A leaked fd keeps its flock after close(): the recovered log's lock
    // must be free again.
    auto probe = openExistingForAppend(rec);
    scope (exit) probe.close();
    immutable probeLock = tryLock(probe);
    assert(probeLock == LockResult.acquired,
        "no leaked fd still locks the recovery log (probe: " ~ probeLock.to!string ~ ")");
    restore(rec); // a resumable session: its header names the recovery id
}

@("a contended recovery name is skipped, never unlinked, and the next name used (#237)")
unittest
{
    import std.algorithm : canFind, count;
    import std.file : dirEntries, SpanMode;
    auto dir = buildPath(tempDir, format("nano-coder-racename-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    log.warn = (string) {};
    log.input("i1", "mu");
    auto p = log.path;
    // Rewrite the path with foreign content so recovery needs a recovery log,
    // then sit on the first recovery name's lock: recovery must skip the
    // contended name (closing its fd and removing the empty, header-less file
    // it published) and continue at N+1 — not abort the whole recovery.
    remove(p);
    std.file.write(p, "{\"type\":\"session\",\"data\":{}}\n");
    auto stem = recoveryStem(log.id);
    auto first = buildPath(dir, stem ~ ".recovered-1.jsonl");
    auto squatter = createPrivate(first);
    assert(tryLock(squatter) == LockResult.acquired);
    scope (exit) squatter.close();
    log.input("i2", "nu");
    auto rec = log.path;
    log.close();
    assert(rec == buildPath(dir, stem ~ ".recovered-2.jsonl"), rec);
    auto now = readText(rec);
    assert(now.canFind("mu") && now.canFind("nu"), now);
    assert(now.count('\n') == 3, now);
    // The contended name is left exactly as the squatter had it: present,
    // empty, and still exclusively the squatter's (no second writer, no
    // leaked fd, no partial header).
    assert(readText(first) == "", "the skipped name stays header-less for its lock holder");
    auto probe = openExistingForAppend(rec);
    scope (exit) probe.close();
    immutable probeLock = tryLock(probe);
    assert(probeLock == LockResult.acquired,
        "the adopted recovery log is free after close (probe: " ~ probeLock.to!string ~ ")");
    assert(dirEntries(dir, "*.recovered-*.jsonl", SpanMode.shallow).array.length == 2,
        "no extra empty recovery files left behind");
    restore(rec);
}

@("a recovery log under a new id keeps the session's attachments (#237)")
unittest
{
    auto dir = buildPath(tempDir, format("nano-coder-recatt-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    log.warn = (string) {};
    log.input("i1", "img");
    auto p = log.path, oldId = log.id;
    auto oldAtt = buildPath(dir, oldId ~ ".attachments");
    mkdirRecurse(oldAtt);
    std.file.write(buildPath(oldAtt, "blob.png"), "PNG");
    remove(p);
    std.file.write(p, "{\"type\":\"session\",\"data\":{}}\n");
    log.input("i2", "after");
    log.close();
    assert(log.id != oldId);
    assert(readText(buildPath(dir, log.id ~ ".attachments", "blob.png")) == "PNG");
    assert(buildPath(oldAtt, "blob.png").exists, "the originals stay for the old log");
}

@("recovery skips a name whose compressed archive already exists (#237)")
unittest
{
    import std.algorithm : canFind, count;
    auto dir = buildPath(tempDir, format("nano-coder-recgz-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    log.warn = (string) {};
    log.input("i1", "pi");
    auto p = log.path;
    auto stem = recoveryStem(log.id);
    // An earlier recovered session was tidied up to `<stem>.recovered-1.jsonl.gz`.
    // A later recovery must not take the plain `recovered-1` name: that would
    // shadow the archive (`findSession` prefers a plain log) and strand it.
    auto gz = buildPath(dir, stem ~ ".recovered-1.jsonl.gz");
    std.file.write(gz, "x");
    remove(p);
    std.file.write(p, "{\"type\":\"session\",\"data\":{}}\n");
    log.input("i2", "rho");
    auto rec = log.path;
    log.close();
    assert(rec == buildPath(dir, stem ~ ".recovered-2.jsonl"), rec);
    auto now = readText(rec);
    assert(now.canFind("pi") && now.canFind("rho"), now);
    assert(gz.exists, "the earlier archive is left in place");
    // And the archive stays resumable by its own id once the plain squat is gone.
    assert(findSession(dir, stem ~ ".recovered-1") == gz);
    restore(rec);
}

@("a destination replaced after the final sync is not adopted (#237)")
unittest
{
    import std.algorithm : canFind;
    auto dir = buildPath(tempDir, format("nano-coder-recswap-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    log.warn = (string) {};
    log.input("i1", "sigma");
    auto p = log.path;
    auto stem = recoveryStem(log.id);
    // Force the recovery-log path, and pre-create the first recovery name so
    // the loop adopts the second. Then swap that second name between the
    // recovery's create+lock and its post-sync identity re-check: the writer
    // must detect the swap, close the unlinked candidate, and fall to the
    // next name instead of adopting (and appending to) an unlinked inode.
    remove(p);
    std.file.write(p, "{\"type\":\"session\",\"data\":{}}\n");
    auto first = buildPath(dir, stem ~ ".recovered-1.jsonl");
    std.file.write(first, ""); // taken, so the loop moves to recovered-2
    // A swap hook: when recovery creates recovered-2, replace the path with a
    // foreign file before the post-sync sameFile re-check runs.
    auto second = buildPath(dir, stem ~ ".recovered-2.jsonl");
    log.swapAfterCreate = (string created) {
        if (created == second)
        {
            remove(created);
            std.file.write(created, "{\"type\":\"session\",\"data\":{}}\n");
        }
    };
    log.input("i2", "tau");
    auto rec = log.path;
    log.close();
    // The swapped candidate (recovered-2) was not adopted; recovery used the next.
    assert(rec == buildPath(dir, stem ~ ".recovered-3.jsonl"), rec);
    auto now = readText(rec);
    assert(now.canFind("sigma") && now.canFind("tau"), now);
    restore(rec);
}

// An in-place rewrite of the recovery candidate (same inode, so `sameFile`
// still matches) must not be adopted: recovery verifies the bytes.
unittest
{
    import std.algorithm : canFind;
    import std.array : replicate;
    auto dir = buildPath(tempDir, format("nano-coder-recinplace-%s", thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/x");
    log.warn = (string) {};
    log.input("i1", "sigma");
    auto p = log.path;
    auto stem = recoveryStem(log.id);
    remove(p);
    std.file.write(p, "{\"type\":\"session\",\"data\":{}}\n");
    auto first = buildPath(dir, stem ~ ".recovered-1.jsonl");
    log.swapAfterCreate = (string created) {
        // Same inode: truncate-and-write, longer than our records.
        if (created == first)
            std.file.write(created, "{\"type\":\"session\",\"data\":{\"id\":\"foreign\"}}\n" ~ "x".replicate(8192) ~ "\n");
    };
    log.input("i2", "tau");
    auto rec = log.path;
    log.close();
    assert(rec == buildPath(dir, stem ~ ".recovered-2.jsonl"), rec);
    auto now = readText(rec);
    assert(now.canFind("sigma") && now.canFind("tau") && !now.canFind("foreign"), now);
    restore(rec);
}

// Issue #271 review: `streamLogLinesUntil` stops at the first false, and
// `logHeaderCwd` reads only the header.
unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "nano-stream-until.jsonl");
    scope (exit) remove(p);
    write(p, `{"type":"session","data":{"cwd":"/w"}}` ~ "\n" ~ "not json\n" ~ "x\n");
    size_t seen;
    streamLogLinesUntil(p, (line) { ++seen; return false; });
    assert(seen == 1);
    assert(logHeaderCwd(p) == "/w");
}

// A replace whose pinned requests a later full restatement replaces is
// decoded without them (issue #301), and restores exactly what decoding
// every record gives, even when its folded delta keeps it un-skimmed.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    import std.array : replicate;
    auto dir = buildPath(tempDir, "nano-d-skimpins-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto log = `{"type":"session","data":{"version":1,"id":"skimpins","created_at":"x"}}` ~ "\n";
    auto goal = Message.user("goal");
    log ~= line("message", rec(goal));
    JSONValue first = ["messages": JSONValue([rec(Message.user("summary"))])];
    first["folded"] = JSONValue([rec(goal)]);
    first["pinned_requests"] = JSONValue([rec(goal), rec(Message.toolResult("c", "bash", "x".replicate(8192)))]);
    log ~= line("replace", first);
    JSONValue second = ["messages": JSONValue([rec(Message.user("summary 2"))])];
    second["folded"] = JSONValue(cast(JSONValue[]) []);
    second["folded_base"] = 1;
    second["pinned_requests"] = JSONValue([rec(Message.user("restated"))]);
    log ~= line("replace", second);
    auto path = buildPath(dir, "skimpins.jsonl");
    write(path, log);
    auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
    assert(skimmed == fullR, "cutting superseded pins restores the same state");
    assert(skimmed.pinStash.length == 1 && skimmed.pinStash[0].content == "restated");
}

// A short assistant turn with a tool call or reasoning item is slimmable at
// any size, so the skim must still decode it before the floor.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-skimcall-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto log = `{"type":"session","data":{"version":1,"id":"skimcall","created_at":"x"}}` ~ "\n";
    ulong lines = 1;
    void add(string type, JSONValue data) { log ~= line(type, data); lines++; }
    auto q = Message.user("q");
    auto call = Message.assistant("x", [ToolCall.fromRaw("c1", "read_file", `{"path":"a"}`)]);
    auto think = Message.assistant("y");
    think.thinkingBlocks = [JSONValue(["t": 1])];
    call.logLine = 3;
    think.logLine = 4;
    add("message", rec(q));
    add("message", rec(call));
    add("message", rec(think));
    JSONValue full = ["messages": JSONValue([rec(Message.user("summary"))])];
    full["folded"] = JSONValue([rec(q), rec(call), rec(think)]);
    full["summarized"] = JSONValue([JSONValue(2), JSONValue(lines)]);
    add("replace", full);
    auto path = buildPath(dir, "skimcall.jsonl");
    write(path, log);
    auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
    assert(skimmed == fullR, "short structured replies are slimmed alike");
    assert(skimmed.replayStashSlim == [false, true, true]);
}

// A line `keep` rejects by its head is skipped whole, whether it is short or
// spans many read chunks, plain or gzipped; the lines around it arrive
// intact, and the skipped one is reported as an empty line (issue #234).
unittest
{
    import std.array : replicate;
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto big = `{"type":"replace","data":"` ~ "x".replicate(200_000) ~ `"}`;
    auto text = `{"type":"message","data":1}` ~ "\n" ~ `{"type":"plan"}` ~ "\n" ~ big ~ "\n"
        ~ `{"type":"message","data":2}` ~ "\n";
    auto p = buildPath(tempDir, "nano-d-stream-keep.jsonl"), gz = p ~ ".gz";
    write(p, text);
    write(gz, gzipLog(text));
    scope (exit) { remove(p); remove(gz); }
    foreach (path; [p, gz])
    {
        string[] seen;
        foreachLogLineSkippingTorn(path, (line) { seen ~= line.idup; },
            (head) => !head.startsWith(`{"type":"replace"`) && !head.startsWith(`{"type":"plan"`));
        assert(seen == [`{"type":"message","data":1}`, "", "", `{"type":"message","data":2}`], path);
    }
}

// `eachLogLine` streams a compressed log through a bounded inflate window
// rather than inflating it whole (issue #306): reading a gzipped log whose
// lines are small allocates far less than its decompressed size.
unittest
{
    import core.memory : GC;
    import std.algorithm : max;
    import std.array : appender;
    import std.conv : text;
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto o = appender!string;
    o.put(`{"type":"session","data":{"version":1,"id":"g","created_at":"t"}}` ~ "\n");
    foreach (i; 0 .. 40_000) o.put(text(`{"type":"input","data":{"id":"i`, i, `","text":"prompt `, i, `"}}`, "\n"));
    auto p = buildPath(tempDir, "nano-d-eachline-gz.jsonl.gz");
    write(p, gzipLog(o.data));
    scope (exit) remove(p);
    ulong lines;
    GC.collect();
    immutable before = GC.stats.usedSize;
    size_t peak;
    eachLogLine(p, (line, n) {
        lines = n;
        if (n % 1000 == 0) peak = max(peak, GC.stats.usedSize);
    });
    assert(lines == 40_001);
    // Inflated chunks are short-lived garbage; what's held at once (live
    // and not yet collected) stays well under the inflated size.
    assert(peak - before < o.data.length / 4, text("read held ", peak - before, " B for ", o.data.length, " B inflated"));
}

unittest // a resumed session's typed prompts come back for Up/Down recall; peer-sent ones don't
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-recent-inputs-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w");
    log.input("in-1", "fix the race");
    log.turnEnd("in-1", "", "end_turn");
    log.input("in-2", "from a peer", "sess-other");
    log.turnEnd("in-2", "", "end_turn");
    log.input("in-3", "now add a test");
    auto um = Message.user("now add a test");
    log.append(um);
    auto steer = Message.user("also the docs"); // typed while the turn ran
    steer.steered = true;
    log.append(steer);
    auto peerSteer = Message.user("peer steer");
    peerSteer.steered = true;
    peerSteer.fromSession = "sess-other";
    log.append(peerSteer);
    log.turnEnd("in-3", "", "end_turn");
    log.input("in-4", "timer fired"); // a timer's turn: not typed
    auto am = Message.auto_("timer fired");
    log.append(am);
    log.turnEnd("in-4", "", "end_turn");
    log.input("in-5", "last one");
    log.close();
    assert(restore(log.path).recentInputs == ["fix the race", "now add a test", "also the docs", "last one"]);
}

unittest // compacted_log_recall_matches_full_decode: the skim keeps steers, drops automatic inputs
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-d-skimrecall-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    static JSONValue rec(Message m) { return messageRecord(m); }
    string line(string type, JSONValue data) { return JSONValue(["type": JSONValue(type), "data": data]).toString ~ "\n"; }
    auto log = `{"type":"session","data":{"version":1,"id":"skimrecall","created_at":"x"}}` ~ "\n";
    ulong lines = 1;
    void add(string type, JSONValue data) { log ~= line(type, data); lines++; }
    add("input", JSONValue(["id": "in-1", "text": "typed \"one\""]));
    auto first = Message.user("typed \"one\"");
    add("message", rec(first));
    auto steer = Message.user("a steer \u00e9");
    steer.steered = true;
    add("message", rec(steer));
    auto peerSteer = Message.user("peer steer");
    peerSteer.steered = true;
    peerSteer.fromSession = "sess-other";
    add("message", rec(peerSteer));
    import std.array : replace;
    // A surrogate-pair escape must decode to the character, not U+FFFD.
    auto rocket = Message.user("ROCKET");
    rocket.steered = true;
    log ~= line("message", rec(rocket)).replace("ROCKET", `go \ud83d\ude80`);
    lines++;
    add("turn_end", JSONValue(["input_id": "in-1", "response": "", "stop_reason": "end_turn"]));
    add("input", JSONValue(["id": "in-2", "text": "timer fired"]));
    add("message", rec(Message.auto_("timer fired")));
    add("turn_end", JSONValue(["input_id": "in-2", "response": "", "stop_reason": "end_turn"]));
    JSONValue full = ["messages": JSONValue([rec(Message.user("summary"))])];
    full["folded"] = JSONValue([rec(first)]);
    full["summarized"] = JSONValue([JSONValue(2), JSONValue(lines)]);
    add("replace", full);
    auto path = buildPath(dir, "skimrecall.jsonl");
    write(path, log);
    auto skimmed = restoreLog(path, true), fullR = restoreLog(path, false);
    assert(fullR.recentInputs == ["typed \"one\"", "a steer \u00e9", "go \U0001F680"]);
    assert(skimmed.recentInputs == fullR.recentInputs);
}

// Issue #313: compressing a log in tidy-up, reopening an archive and
// streaming its lines keep GC allocation bounded, not proportional to the
// log's uncompressed size.
unittest
{
    import core.memory : GC;
    import std.array : appender;
    import std.conv : to;
    import std.file : tempDir, remove, exists, getSize;
    import nano.clock : monoNow;
    auto base = buildPath(tempDir, "nano-gz-bound-" ~ to!string(monoNow.ticks));
    auto plain = base ~ ".jsonl", gz = base ~ ".jsonl.gz", back = base ~ ".back";
    scope (exit) foreach (p; [plain, gz, back]) if (p.exists) remove(p);
    {
        auto o = appender!string;
        foreach (i; 0 .. 120_000)
            o ~= `{"type":"text","data":{"text":"line ` ~ to!string(i) ~ ` of a long session log"}}` ~ "\n";
        std.file.write(plain, o.data);
    }
    immutable size = getSize(plain);
    assert(size > 6 << 20, "the log is large enough to show a leak");
    enum bound = 2 << 20;
    GC.collect();
    auto before = GC.stats.allocatedInCurrentThread;
    gzipFile(plain, gz, octal!600);
    immutable zipped = GC.stats.allocatedInCurrentThread - before;
    assert(zipped < bound, "gzipFile allocated " ~ to!string(zipped));
    before = GC.stats.allocatedInCurrentThread;
    gunzipFile(gz, back, octal!600);
    immutable unzipped = GC.stats.allocatedInCurrentThread - before;
    assert(unzipped < bound, "gunzipFile allocated " ~ to!string(unzipped));
    assert(getSize(back) == size, "the round trip keeps every byte");
    before = GC.stats.allocatedInCurrentThread;
    ulong lines;
    eachLogLineUntil(gz, (const(char)[] l, ulong n) { lines = n; return true; });
    immutable streamed = GC.stats.allocatedInCurrentThread - before;
    assert(lines == 120_000);
    assert(streamed < bound, "eachLogLineUntil allocated " ~ to!string(streamed));
    assert(gzipLog(readBytes(back)) .length > 0 && logText(gz).length == size, "gzipLog still compresses whole text");
    // Byte-for-byte: same-length corruption, reordering or duplication of
    // chunks must fail, since tidy-up deletes the original after compressing.
    assert(std.file.read(back) == std.file.read(plain), "the round trip preserves the log exactly");
    assert(logText(gz) == std.file.readText(plain), "the archive decompresses to the original");
}
