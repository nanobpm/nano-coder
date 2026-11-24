/// Summaries of saved sessions for `--resume`: where each ran, how much was
/// said, and the last prompt, so sessions can be told apart (Rust
/// `session_index.rs`).
///
/// Summaries are cached in `.index.jsonl` in the session directory, one JSON
/// object per line; the latest line for an ID wins. Writers only append (one
/// `write` per line), so several running nano-coders can share the file
/// without locking. A summary records the size of the log it was made from:
/// when the log has grown since, it is rebuilt from the log. The cache's stem
/// `.index` is not a valid session id, so it can never hide a real log.
module nano.session_index;

@safe:

import std.utf : UTFException;

import nano.safeio : lossyText, utf8View;

import nano.arith : toSize, toLong;

import std.string : representation;
import nano.clock : wallNow;

import std.json;
import std.file;
import std.path;
import std.format : format;
import std.string : strip, startsWith, endsWith, indexOf;
static import std.string;
import std.datetime.systime : SysTime, Clock;
import std.algorithm : sort, any, filter, canFind, splitter, map;
import std.array : array, join, split;
import std.range : walkLength, take;
import std.conv : to;
import std.typecons : Nullable;
import nano.session : validateId, formatVersion, stamp;

enum string indexFile = ".index.jsonl";

/// What the session picker shows for one saved session.
struct Summary
{
    string id;
    /// Working directory the session started in (null for older logs).
    string cwd;
    /// `provider/model` last used (null for older logs).
    string model;
    /// RFC 3339, as written in the log header.
    string createdAt;
    /// When the log was last written.
    SysTime lastUsed;
    /// Prompts typed (input records).
    size_t prompts;
    string firstPrompt;
    /// The first prompt that says something (not terse), used to name the session.
    string firstTellingPrompt;
    string lastPrompt;
    /// When the last prompt says little on its own, the most recent one before it that says more.
    string contextPrompt;
    /// A few-word title from the model (`session_titles = true`); kept only here.
    string title;
    /// The user-chosen handle (issue #300) as of the log's latest `name` record.
    string name;
    /// Size of the log this summary was made from.
    ulong logBytes;
    /// On-disk size of a compressed log (`<id>.jsonl.gz`) this summary was
    /// made from, 0 for a plain log: the archive's cache fingerprint, kept
    /// apart from the uncompressed `logBytes` append offset.
    ulong archiveBytes;
    /// The log file (not serialized).
    string path;

    /// Fields in serde order as (key, JSON value); unset optional fields are omitted.
    string[2][] fields() const
    {
        static string q(string s) { import nano.trajectory : serdeString; return serdeString(s); }
        string[2][] f = [["id", q(id)]];
        void opt(string key, string v)
        {
            if (v !is null) f ~= [key, q(v)];
        }
        opt("cwd", cwd);
        opt("model", model);
        opt("created_at", createdAt);
        f ~= ["last_used", q(stamp(lastUsed))];
        f ~= ["prompts", prompts.to!string];
        opt("first_prompt", firstPrompt);
        opt("first_telling_prompt", firstTellingPrompt);
        opt("last_prompt", lastPrompt);
        opt("context_prompt", contextPrompt);
        opt("title", title);
        opt("name", name);
        f ~= ["log_bytes", logBytes.to!string];
        if (archiveBytes) f ~= ["archive_bytes", archiveBytes.to!string];
        return f;
    }

    /// Rust's compact serde form (`/` is not escaped).
    string toJson() const
    {
        string o = "{";
        foreach (i, kv; fields) o ~= (i ? "," : "") ~ `"` ~ kv[0] ~ `":` ~ kv[1];
        return o ~ "}";
    }

    /// `serde_json::to_string_pretty` form, indented by `indent` spaces.
    string toPrettyJson(size_t indent = 0) const
    {
        import std.array : replicate;
        auto pad = " ".replicate(indent);
        string o = "{\n";
        auto f = fields;
        foreach (i, kv; f) o ~= pad ~ `  "` ~ kv[0] ~ `": ` ~ kv[1] ~ (i + 1 < f.length ? ",\n" : "\n");
        return o ~ pad ~ "}";
    }

    /// Parse one index line; throws on anything malformed.
    static Summary fromJson(const(char)[] line)
    {
        auto j = parseJSON(line);
        Summary s;
        s.id = j["id"].str;
        string opt(string key)
        {
            if (auto v = key in j) if (v.type == JSONType.string) return v.str;
            return null;
        }
        s.cwd = opt("cwd");
        s.model = opt("model");
        s.createdAt = opt("created_at");
        s.lastUsed = SysTime.fromISOExtString(j["last_used"].str);
        s.prompts = toSize(j["prompts"].integer);
        s.firstPrompt = opt("first_prompt");
        s.firstTellingPrompt = opt("first_telling_prompt");
        s.lastPrompt = opt("last_prompt");
        s.contextPrompt = opt("context_prompt");
        s.title = opt("title");
        s.name = opt("name");
        s.logBytes = j["log_bytes"].integer.to!ulong;
        if (auto a = "archive_bytes" in j)
            if (a.type == JSONType.integer && a.integer > 0) s.archiveBytes = a.integer.to!ulong;
        return s;
    }
}

/// Whether a prompt says too little to identify a session by itself.
bool isTerse(string text) pure
{
    auto t = text.strip;
    return t.startsWith("/") || (t.walkLength < 24 && t.split.length <= 4);
}

/// Prompts are kept only to name and describe the session: the title request
/// uses at most 600 characters of one, so keep only that prefix.
private string clipPrompt(string text) pure
{
    return text.take(600).to!string;
}

/// Fold one input record into `s` (count, first/last and context prompts).
private void foldInput(ref Summary s, string text) pure
{
    s.prompts++;
    if (s.firstPrompt is null) s.firstPrompt = clipPrompt(text);
    if (s.firstTellingPrompt is null && !isTerse(text)) s.firstTellingPrompt = clipPrompt(text);
    auto previous = s.lastPrompt;
    s.lastPrompt = clipPrompt(text);
    if (previous !is null && !isTerse(previous)) s.contextPrompt = previous;
    // Context is only worth showing when the last prompt needs it.
    if (!isTerse(s.lastPrompt)) s.contextPrompt = null;
}

/// A pre-upgrade index line that predates `first_telling_prompt` yet holds a
/// non-terse prompt: folding onto it would misname the session, so rebuild.
private bool missingTellingPrompt(const ref Summary s) pure
{
    if (s.firstTellingPrompt !is null) return false;
    foreach (p; [s.firstPrompt, s.lastPrompt, s.contextPrompt])
        if (p !is null && !isTerse(p)) return true;
    return false;
}

/// Committed (newline-terminated) lines of `bytes`: valid UTF-8 lines are
/// zero-copy views into `bytes`; only a malformed line is copied, with its
/// invalid bytes replaced by U+FFFD (it then fails to parse where decoded).
private const(char)[][] committedLines(const(ubyte)[] bytes) pure
{
    size_t committed = bytes.length;
    while (committed && bytes[committed - 1] != '\n') committed--;
    return bytes[0 .. committed].splitter(ubyte('\n')).filter!(l => l.length > 0).map!(viewOrLossy).array;
}

/// `l` as a view when valid UTF-8, else a sanitized copy.
private const(char)[] viewOrLossy(const(ubyte)[] l) pure
{
    import std.utf : UTFException;
    try return utf8View(l);
    catch (UTFException) return lossyText(l);
}

unittest
{
    import std.string : representation;
    auto bytes = "ab\ncd\nxy".representation;
    auto ls = committedLines(bytes);
    assert(ls == ["ab", "cd"]);
    assert(&ls[0][0] == cast(const(char)*) &bytes[0], "valid lines are views, not copies");
    const(ubyte)[] bad = [0x61, 0xff, 0x0a];
    assert(committedLines(bad) == ["a\uFFFD"]);
}

/// The input text of a committed log line, or null when it isn't an input record.
private string inputText(const(char)[] line) pure
{
    if (!line.canFind(`"input"`)) return null; // cheap pre-filter; any JSON spacing is valid
    try
    {
        auto rec = parseJSON(line);
        if (rec["type"].str != "input") return null;
        return rec["data"]["text"].str;
    }
    catch (Exception) return null; // a corrupt line has no input text
}

/// Fold every committed input record in `path` after byte offset `from`
/// (only the tail is read), so a concurrent writer's prompt is never lost.
private void foldInputsSince(string path, ulong from, ref Summary s)
{
    import nano.safeio : readFrom;
    auto tail = readFrom(path, from);
    foreach (line; committedLines(tail)) foldLine(s, line);
}

/// Fold one committed log line into `s`: an input's text or a handle.
private void foldLine(ref Summary s, const(char)[] line) pure
{
    if (auto t = inputText(line)) foldInput(s, t);
    else foldName(s, line);
}

/// A `name` record (issue #300) sets the handle; a null name clears it.
private void foldName(ref Summary s, const(char)[] line) pure
{
    if (!line.canFind(`"name"`)) return;
    try
    {
        auto rec = parseJSON(line);
        if (rec["type"].str != "name") return;
        auto n = rec["data"]["name"];
        s.name = n.type == JSONType.string ? n.str : null;
    }
    catch (JSONException) {} // a corrupt line names nothing
}

/// Summarize the session log at `path`. Only the header and input records are
/// decoded. Throws when the log isn't resumable: no valid id, or a first
/// record that isn't a matching header of this format version.
Summary summarize(string path)
{
    import nano.session : isCompressedLog, logIdOf, logText, streamLogLinesUntil;
    Summary s;
    s.path = path;
    s.lastUsed = timeLastModified(path);
    s.id = logIdOf(path);
    try validateId(s.id);
    catch (Exception e) throw new Exception(format("session log %s has an invalid id", path));
    bool ok, first = true;
    void header(const(char)[] line)
    {
        try
        {
            auto h = parseJSON(line);
            auto d = h["data"];
            if (h["type"].str == "session" && d["version"].integer == formatVersion && d["id"].str == s.id)
            {
                ok = true;
                s.createdAt = d["created_at"].str;
                if (auto c = "cwd" in d) if (c.type == JSONType.string) s.cwd = c.str;
                if (auto m = "model" in d) if (m.type == JSONType.string) s.model = m.str;
            }
        }
        catch (Exception) {} // skip a corrupt line; a missing header is reported just below
    }
    if (isCompressedLog(path))
    {
        // An archive: summarized once and cached by its size.
        auto text = logText(path);
        s.logBytes = text.length;
        auto lines = committedLines(text.representation);
        if (lines.length) header(lines[0]);
        if (!ok) throw new Exception(format("session log %s has no resumable header", path));
        foreach (line; lines[1 .. $]) foldLine(s, line);
        return s;
    }
    // A live log is streamed, and a record that isn't an input is skipped by
    // its head without being read whole: a long session's log can run to
    // hundreds of MB, and summarizing it after a turn once held all of it.
    s.logBytes = getSize(path);
    streamLogLinesUntil(path, (line) {
        if (first)
        {
            first = false;
            header(line);
            return ok;
        }
        foldLine(s, line);
        return true;
    }, (head) => first || mayBeInput(head));
    if (!ok) throw new Exception(format("session log %s has no resumable header", path));
    return s;
}

/// A streamed line's head: false only for a record known not to be an input
/// (its `{"type":"<type>"` prefix names another type).
private bool mayBeInput(const(char)[] head) pure @safe
{
    enum prefix = `{"type":"`;
    if (!head.startsWith(prefix)) return true;
    auto rest = head[prefix.length .. $];
    immutable q = rest.indexOf('"');
    return q <= 0 || rest[0 .. q].canFind('\\') || rest[0 .. q] == "input" || rest[0 .. q] == "name";
}

private string indexPath(string dir) pure
{
    return buildPath(dir, indexFile);
}

private ulong sizeOr0(string path)
{
    try return getSize(path);
    catch (Exception) return 0; // no file: size 0
}

/// Index lines parsed into `map` (latest wins, titles monotonic). Unreadable
/// lines are skipped: the index is only a cache.
private void mergeLines(const(ubyte)[] bytes, ref Summary[string] map, ref size_t lines, bool strict = false)
{
    foreach (rawBytes; bytes.splitter(ubyte('\n')))
    {
        const(char)[] raw;
        try raw = utf8View(rawBytes);
        catch (UTFException) { if (rawBytes.length) lines++; continue; } // invalid UTF-8: unreadable
        auto line = raw.strip;
        if (!line.length) continue;
        lines++;
        Summary s;
        try s = Summary.fromJson(line);
        catch (Exception)
        {
            // Strict callers (retention) must not guess at titles a corrupt line hid.
            if (strict) throw new Exception("session index has a corrupt line");
            continue; // skip a corrupt index line; the log rebuilds it
        }
        // A later line without a title must not hide one an earlier line recorded.
        if (s.title is null)
            if (auto prev = s.id in map) s.title = prev.title;
        map[s.id] = s;
    }
}

/// The index's summaries by id and its line count.
/// `strict` (retention's title check): only a missing index reads as empty;
/// an unreadable index or a corrupt line throws instead of hiding titles.
private Summary[string] load(string dir, out size_t lines, bool strict = false)
{
    import nano.safeio : readBytes;
    Summary[string] map;
    ubyte[] bytes;
    if (strict && !indexPath(dir).exists) return map;
    if (strict) bytes = readBytes(indexPath(dir));
    else
    {
        try bytes = readBytes(indexPath(dir));
        catch (Exception) return map; // no index yet: start empty and rebuild
    }
    mergeLines(bytes, map, lines, strict);
    return map;
}

/// Append summaries, one `write` per line so concurrent writers don't
/// interleave within a line. A short write fails the update (no retry).
private void append(string dir, const Summary[] summaries)
{
    import core.sys.posix.fcntl : O_WRONLY, O_CREAT, O_APPEND;
    import nano.safeio : closeFd, openPath, writeFd;
    if (!summaries.length) return;
    int fd = openPath(indexPath(dir), O_WRONLY | O_CREAT | O_APPEND, octal!"644");
    if (fd < 0) throw new Exception("open session index " ~ indexPath(dir));
    scope (exit) closeFd(fd);
    foreach (ref s; summaries)
    {
        auto line = s.toJson ~ "\n";
        if (writeFd(fd, line.representation) != toLong(line.length)) throw new Exception("short write to session index");
    }
}

import std.conv : octal;

/// Rewrite the index with one line per session (atomically, via rename),
/// merging whatever was appended since byte `since` (sampled before the read).
private void rewrite(string dir, const Summary[string] summaries, ulong since)
{
    import nano.safeio : readFrom;
    import std.process : thisProcessID;
    Summary[string] merged;
    foreach (k, v; summaries) merged[k] = v;
    try
    {
        import std.stdio : File;
        auto f = File(indexPath(dir), "rb");
        if (f.size >= since)
        {
            auto rest = readFrom(indexPath(dir), since);
            size_t n;
            mergeLines(rest, merged, n);
        }
    }
    catch (Exception) {} // lines appended since are lost to this rewrite only; the logs rebuild them
    auto ids = merged.keys.sort.array;
    string text;
    foreach (id; ids) text ~= merged[id].toJson ~ "\n";
    auto tmp = buildPath(dir, format("%s.tmp-%s", indexFile, thisProcessID));
    std.file.write(tmp, text);
    rename(tmp, indexPath(dir));
}

/// Record the session log at `path` in the index after a turn and return the
/// resulting summary. `from` is the log's size before the turn's input was
/// appended: when the cached summary covers exactly that much, only the tail
/// is folded; otherwise the summary is rebuilt from the whole log. `model` is
/// the `provider/model` now in use (null keeps the recorded one).
Summary update(string path, ulong from, string model)
{
    auto dir = path.dirName;
    auto id = path.baseName.stripExtension;
    auto lastUsed = timeLastModified(path);
    auto size = getSize(path);
    auto indexLen = sizeOr0(indexPath(dir));
    size_t lines;
    auto index = load(dir, lines);
    Summary s;
    string cachedTitle;
    auto cached = id in index;
    if (cached !is null)
    {
        cachedTitle = cached.title;
        if (cached.logBytes == from && !missingTellingPrompt(*cached))
        {
            s = *cached;
            foldInputsSince(path, from, s);
        }
        else s = summarize(path);
        index.remove(id);
    }
    else s = summarize(path);
    s.path = path;
    s.lastUsed = lastUsed;
    s.logBytes = size;
    if (s.title is null) s.title = cachedTitle;
    if (model !is null) s.model = model;
    // Compact instead of appending once the file has grown well past one line per session.
    if (lines > index.length * 2 + 64)
    {
        index[s.id] = s;
        rewrite(dir, index, indexLen);
    }
    else append(dir, [s]);
    return s;
}

/// Give the session log at `path` a title in the index. False when the index
/// already has one (another process won the race), which is left alone.
bool setTitle(string path, string title)
{
    auto dir = path.dirName;
    auto s = summarize(path);
    size_t lines;
    auto indexed = load(dir, lines);
    if (auto prev = s.id in indexed)
    {
        if (prev.title !is null) return false;
        // Keep a model learned after the session started.
        if (prev.model !is null) s.model = prev.model;
    }
    s.title = title;
    append(dir, [s]);
    return true;
}

/// The prompts a title is made from: the first telling prompt and, when
/// different, the latest telling one. Null while every prompt is terse.
string titleSource(const ref Summary s) pure
{
    string last;
    foreach (p; [s.lastPrompt, s.contextPrompt])
        if (p !is null && !isTerse(p))
        {
            last = p;
            break;
        }
    auto first = s.firstTellingPrompt;
    if (first !is null && last !is null && first != last) return first ~ "\n\n" ~ last;
    if (first !is null) return first;
    return last;
}

/// Tidy a model's title reply: first line, no control characters, quotes,
/// labels or trailing period, at most six words and 60 characters (ellipsis
/// included). Null when nothing usable is left.
string cleanTitle(string reply) pure
{
    import std.uni : isWhite, isControl;
    import std.string : lineSplitter, chompPrefix;
    import std.algorithm : stripLeft, stripRight;
    string line;
    foreach (l; reply.lineSplitter)
    {
        if (l.strip.length)
        {
            line = l.strip;
            break;
        }
    }
    if (line is null) return null;
    string kept;
    foreach (dchar c; line) if (!isControl(c)) kept ~= c;
    bool wrapper(dchar c)
    {
        return c == '"' || c == '\'' || c == '`' || c == '*' || c == '#' || c == '_' || isWhite(c);
    }
    auto t = kept.stripLeft!wrapper.stripRight!wrapper;
    if (t.startsWith("Title:")) t = t["Title:".length .. $];
    t = t.stripLeft!wrapper.stripRight!wrapper;
    while (t.length && t[$ - 1] == '.') t = t[0 .. $ - 1];
    t = t.strip;
    if (!t.length) return null;
    auto words = t.split;
    auto title = words.take(6).join(" ");
    bool elided = words.length > 6;
    if (title.walkLength > 60) elided = true;
    if (elided) title = std.string.stripRight(title.take(59).to!string) ~ "…";
    return title;
}

/// Ids of every titled session, from the strictly loaded index alone (no
/// picker filters, no cache rewrite). Titles are only ever recorded in the
/// index (`setTitle`) — `summarize` never populates `Summary.title` — so
/// scanning the logs can only re-derive what the index holds, at a startup
/// cost proportional to the whole (decompressed) history. Throws when the
/// index is unreadable or corrupt.
bool[string] titledIds(string dir)
{
    bool[string] named;
    if (!dir.exists) return named;
    size_t lines;
    // A handle (issue #300) protects a session as a title does.
    foreach (id, s; load(dir, lines, true)) if (s.title !is null || s.name !is null) named[id] = true;
    return named;
}

/// Every resumable session with at least one prompt in `dir`, newest first.
/// Sessions the index lacks, or whose log changed since it was indexed, are
/// summarized from their logs, and the index is updated. A missing directory
/// is no sessions; other filesystem errors propagate. `strictIndex` also
/// fails on an unreadable or corrupt index (see `load`). `skip` hides a log
/// from the listing entirely (issue #271: a session the permission policy
/// denies is neither summarized nor reported from cached metadata, so its
/// title or first request can't leak); a skipped log's cached record is
/// still carried into any index rewrite, so hiding it never erases its title
/// (which protects the log from retention).
Summary[] list(string dir, bool strictIndex = false, scope bool delegate(string path) @safe skip = null)
{
    if (!dir.exists) return null;
    auto indexLen = sizeOr0(indexPath(dir));
    size_t lines;
    auto index = load(dir, lines, strictIndex);
    Summary[string] current;
    Summary[] updates;
    Summary[string] skippedTitled;
    Summary[string] denied; // hidden from the listing, kept in the index
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
    {
        auto name = e.name.baseName;
        immutable compressed = name.endsWith(".jsonl.gz");
        if (!compressed && (name.extension != ".jsonl" || name == indexFile)) continue;
        auto id = compressed ? name[0 .. $ - ".jsonl.gz".length] : name.stripExtension;
        try validateId(id);
        catch (Exception) continue; // not a session log name: skip
        if (!e.isFile) continue;
        if (skip !is null && skip(e.name))
        {
            // Denied: hide it entirely (issue #271), but keep its cached
            // record so a rewrite doesn't drop its title.
            if (auto c = id in index) { denied[id] = *c; index.remove(id); }
            continue;
        }
        if (compressed && buildPath(dir, id ~ ".jsonl").exists)
        {
            // The plain twin wins. An archive resume may publish it after the
            // iterator passed it: remember the title so the rewrite keeps it.
            auto cached_ = id in index;
            if (cached_ is null) cached_ = id in denied;
            if (cached_ !is null && (cached_.title !is null || cached_.name !is null)) skippedTitled[id] = *cached_;
            continue;
        }
        auto size = e.size;
        Summary s;
        auto cached = id in index;
        // A denied archive visited first moved the shared record to `denied`.
        if (cached is null) cached = id in denied;
        immutable hit = cached !is null && (compressed
            ? cached.archiveBytes == size
            : cached.archiveBytes == 0 && cached.logBytes == size);
        if (hit) s = *cached;
        else
        {
            try s = summarize(e.name);
            // One unreadable or truncated log must not hide every other
            // session (issue #300: it blocked unrelated resumes); strict
            // callers (retention) still fail rather than act on a partial view.
            catch (FileException err) { if (strictIndex) throw err; else continue; }
            catch (Exception)
            {
                // Not resumable (e.g. truncated): keep a titled entry whose
                // file still exists, or the rewrite below would drop the
                // title and a later tidy pass could delete a named session.
                // Zero prompts keeps it out of picker results.
                if (cached !is null && (cached.title !is null || cached.name !is null))
                {
                    // Zero prompts keeps it out of picker results while the
                    // rewrite below keeps its title.
                    current[id] = *cached;
                    current[id].prompts = 0;
                    index.remove(id);
                }
                continue;
            }
            if (cached !is null)
            {
                // Keep a model and title the index learned after the session started.
                if (cached.model !is null) s.model = cached.model;
                if (s.title is null) s.title = cached.title;
            }
            s.archiveBytes = compressed ? size : 0;
            updates ~= s;
        }
        if (cached !is null) index.remove(id);
        s.path = e.name;
        current[id] = s;
    }
    // A titled archive skipped for a plain twin the listing never yielded:
    // keep its title (zero prompts hides it) and a zero log size, which no
    // real log has, so the next listing summarizes the plain log afresh.
    foreach (id, k; skippedTitled)
    {
        if (id in current) continue;
        k.prompts = 0;
        k.logBytes = 0;
        k.archiveBytes = 0;
        current[id] = k;
        index.remove(id);
    }
    try
    {
        if (lines + updates.length > current.length * 2 + 64 || index.length)
        {
            Summary[string] all = current.dup;
            foreach (id, d; denied) if (id !in all) all[id] = d;
            rewrite(dir, all, indexLen);
        }
        else append(dir, updates);
    }
    catch (Exception) {} // only a cache
    auto out_ = current.byValue.filter!(s => s.prompts > 0).array;
    out_.sort!((a, b) => a.lastUsed > b.lastUsed);
    return out_;
}

version (unittest)
{
    private string testDir(string name)
    {
        auto d = buildPath(tempDir, "nano-d-index-" ~ name);
        if (d.exists) rmdirRecurse(d);
        mkdirRecurse(d);
        return d;
    }

    private string writeLog(string dir, string id, string[] prompts, string cwd = "/w")
    {
        import nano.session : SessionLog;
        auto log = new SessionLog(dir, "p/m", cwd, id);
        foreach (i, p; prompts) log.input(format("in-%s", i), p);
        return log.path;
    }
}

// rust: session_index.rs::prompts_are_clipped_to_the_title_input_size
// rust: session_index.rs::no_context_when_last_prompt_is_telling
// rust: session_index.rs::terse_prompts
// rust: session_index.rs::summarizes_prompts_and_header
unittest
{
    // Terse and telling prompts, and the context shown for a terse last one.
    Summary s;
    foldInput(s, "hi");
    foldInput(s, "Fix the flaky deploy test in CI please");
    foldInput(s, "do it");
    assert(s.prompts == 3 && s.firstPrompt == "hi" && s.firstTellingPrompt == "Fix the flaky deploy test in CI please");
    assert(s.lastPrompt == "do it" && s.contextPrompt == "Fix the flaky deploy test in CI please");
    foldInput(s, "Now also update the release notes for it");
    assert(s.contextPrompt is null);
    assert(titleSource(s) == "Fix the flaky deploy test in CI please\n\nNow also update the release notes for it");
    Summary terse;
    foldInput(terse, "hi");
    assert(titleSource(terse) is null);
    // Prompts are clipped to the title's input size.
    Summary big;
    import std.array : replicate;
    foldInput(big, "x".replicate(5000));
    assert(big.firstPrompt.length == 600);
}

// rust: session_index.rs::clean_title_strips_terminal_control_characters
// rust: session_index.rs::cleans_title_replies
unittest
{
    assert(cleanTitle("\"Fixing the deploy test.\"\nmore") == "Fixing the deploy test");
    assert(cleanTitle("Title: **Port nano-coder to D**") == "Port nano-coder to D");
    assert(cleanTitle("one two three four five six seven") == "one two three four five six…");
    assert(cleanTitle("\x1b]0;evil\x07Safe title") == "]0;evilSafe title");
    assert(cleanTitle("  \n ``` \n") is null);
    import std.array : replicate;
    auto long_ = cleanTitle("a".replicate(80));
    assert(long_.walkLength == 60 && long_[$ - 3 .. $] == "…");
}

// rust: session_index.rs::update_folds_the_turns_input_into_the_cached_summary
// rust: session_index.rs::title_survives_updates_and_rebuilds
// rust: session_index.rs::update_records_current_model_and_list_keeps_it
// rust: session_index.rs::list_indexes_skips_empty_and_refreshes_stale
unittest
{
    auto dir = testDir("list");
    writeLog(dir, "s1", ["first prompt that is telling enough here", "go"]);
    writeLog(dir, "empty", []);
    std.file.write(buildPath(dir, "bad.jsonl"), "{\"type\":\"input\",\"data\":{\"text\":\"x\"}}\n");
    std.file.write(buildPath(dir, ".hidden.jsonl"), "x\n");
    auto l = list(dir);
    assert(l.length == 1 && l[0].id == "s1" && l[0].prompts == 2 && l[0].cwd == "/w" && l[0].model == "p/m");
    assert(l[0].contextPrompt == "first prompt that is telling enough here");
    // The index now caches s1 and empty; a second listing reuses it.
    auto idx = readText(buildPath(dir, indexFile));
    assert(idx.startsWith(`{"id":"`) && !idx.canFindSlashEscape);
    auto again = list(dir);
    assert(again.length == 1 && again[0].logBytes == l[0].logBytes);
    // A grown log is rebuilt; a model learned via update survives.
    auto path = buildPath(dir, "s1.jsonl");
    auto from = getSize(path);
    import nano.session : SessionLog;
    auto log = new SessionLog(path);
    log.input("in-9", "third prompt");
    auto u = update(path, from, "other/model");
    assert(u.prompts == 3 && u.model == "other/model" && u.lastPrompt == "third prompt");
    auto l2 = list(dir);
    assert(l2[0].prompts == 3 && l2[0].model == "other/model");
    // Titles: set once, kept across updates and rebuilds.
    assert(setTitle(path, "Deploy fix"));
    assert(!setTitle(path, "Another"));
    from = getSize(path);
    log.input("in-10", "fourth");
    assert(update(path, from, null).title == "Deploy fix");
    assert(list(dir)[0].title == "Deploy fix");
    // A torn or corrupt index line is skipped.
    std.file.append(buildPath(dir, indexFile), "{not json\n\xff\xfe\n");
    assert(list(dir)[0].title == "Deploy fix");
}

// rust: session_index.rs::update_folds_an_input_a_concurrent_writer_appended_since_from
// rust: session_index.rs::update_rescans_when_the_cache_is_stale
unittest
{
    // A stale cache (log grew behind the index) falls back to a full scan.
    auto dir = testDir("stale");
    auto path = writeLog(dir, "s", ["alpha prompt with enough words in it"]);
    list(dir);
    import nano.session : SessionLog;
    auto log = new SessionLog(path);
    log.input("a", "beta"); // another process, no index update
    auto from = getSize(path);
    log.input("b", "gamma");
    auto u = update(path, from, null);
    assert(u.prompts == 3, format("%s", u.prompts));
    // A concurrent writer's prompt after `from` is folded too.
    from = getSize(path);
    log.input("c", "delta");
    log.input("d", "epsilon");
    assert(update(path, from, null).prompts == 5);
}

// rust: session_index.rs::update_compacts_the_index_without_a_listing
unittest
{
    // The index compacts once it grows well past one line per session.
    auto dir = testDir("compact");
    auto path = writeLog(dir, "s", ["one"]);
    import nano.session : SessionLog;
    auto log = new SessionLog(path);
    foreach (i; 0 .. 80)
    {
        auto from = getSize(path);
        log.input(format("x%s", i), "more");
        update(path, from, null);
    }
    import std.algorithm : count;
    assert(readText(buildPath(dir, indexFile)).count('\n') < 70);
    assert(list(dir)[0].prompts == 81);
}

version (unittest) private bool canFindSlashEscape(string s) pure
{
    import std.algorithm : canFind;
    return s.canFind(`\/`);
}

// rust: session_index.rs::cache_filename_cannot_collide_with_a_session_id
unittest
{
    import std.exception : assertThrown;
    assertThrown(validateId(indexFile.stripExtension), "the cache file stem must not be a valid session id");
    auto dir = testDir("collide");
    scope (exit) rmdirRecurse(dir);
    writeLog(dir, "index", ["A prompt from the session named index"]);
    import std.algorithm : map;
    assert(list(dir).map!(s => s.id).array == ["index"], "a session named `index` is listed, not hidden by the cache");
    assert(indexPath(dir).exists);
}

// rust: session_index.rs::index_is_compacted_and_forgets_deleted_logs
unittest
{
    auto dir = testDir("compact");
    scope (exit) rmdirRecurse(dir);
    auto keep = writeLog(dir, "k", ["Keep this session around"]);
    foreach (_; 0 .. 100) update(keep, 0, null);
    auto gone = writeLog(dir, "gone", []);
    list(dir);
    std.file.remove(gone);
    list(dir);
    size_t lines;
    assert(load(dir, lines).length == 1 && lines == 1);
    std.file.write(indexPath(dir), "not json\n");
    assert(list(dir).length == 1);
}

// rust: session_index.rs::list_propagates_directory_errors_except_not_found
unittest
{
    import std.exception : assertThrown;
    auto dir = testDir("errors");
    scope (exit) rmdirRecurse(dir);
    assert(list(buildPath(dir, "does-not-exist")).length == 0, "a missing directory means no sessions");
    std.file.write(buildPath(dir, "a-file"), "x");
    assertThrown(list(buildPath(dir, "a-file")), "a non-NotFound directory error propagates");
}

// rust: session_index.rs::list_skips_invalid_id_even_on_cache_hit
unittest
{
    auto dir = testDir("hidden");
    scope (exit) rmdirRecurse(dir);
    auto hidden = buildPath(dir, ".hidden.jsonl");
    std.file.write(hidden, `{"type":"input","data":{"id":"i1","text":"hi"}}` ~ "\n");
    Summary cached;
    cached.id = ".hidden";
    cached.lastUsed = wallNow;
    cached.prompts = 1;
    cached.firstPrompt = cached.lastPrompt = "hi";
    cached.logBytes = getSize(hidden);
    append(dir, [cached]);
    assert(list(dir).length == 0, "an invalid id is not listed from the cache");
}

// rust: session_index.rs::list_skips_non_regular_jsonl_entries
unittest
{
    auto dir = testDir("nonregular");
    scope (exit) rmdirRecurse(dir);
    writeLog(dir, "s", ["A real session prompt"]);
    mkdirRecurse(buildPath(dir, "notalog.jsonl"));
    auto sessions = list(dir);
    assert(sessions.length == 1 && sessions[0].id == "s", "the directory entry is skipped");
}

/// Two indexed sessions `a` and `b`.
version (unittest) private string twoSessions(string name)
{
    auto dir = testDir(name);
    writeLog(dir, "a", ["Session a's prompt"]);
    writeLog(dir, "b", ["Session b's prompt"]);
    list(dir);
    return dir;
}

// rust: session_index.rs::load_isolates_a_non_utf8_line_instead_of_discarding_the_index
unittest
{
    auto dir = twoSessions("utf8");
    scope (exit) rmdirRecurse(dir);
    size_t lines;
    assert(load(dir, lines).length == 2);
    std.file.append(indexPath(dir), "\xff\xfe not utf8\n".representation);
    auto after = load(dir, lines);
    assert(after.length == 2, "the two good lines survive the corrupt one");
    assert(lines == 3, "the corrupt line still counts toward compaction");
    assert(after["a"].prompts == 1 && after["b"].prompts == 1);
}

/// Append a newer summary of `b` (another model) after `prefix`, then rewrite
/// from the state read before it.
version (unittest) private void rewriteAfter(string dir, const(ubyte)[] prefix)
{
    size_t lines;
    auto current = load(dir, lines);
    auto since = getSize(indexPath(dir));
    auto newer = summarize(buildPath(dir, "b.jsonl"));
    newer.model = "anthropic/claude";
    std.file.append(indexPath(dir), prefix ~ (newer.toJson ~ "\n").representation);
    rewrite(dir, current, since);
    auto sessions = list(dir);
    assert(sessions.length == 2);
    assert(sessions.filter!(s => s.id == "b").front.model == "anthropic/claude", "the line appended since the read survives");
}

// rust: session_index.rs::rewrite_isolates_a_corrupt_tail_line_instead_of_discarding_later_ones
unittest
{
    auto dir = twoSessions("corrupt-tail");
    scope (exit) rmdirRecurse(dir);
    rewriteAfter(dir, "\xff\xfe not utf8\n".representation);
}

// rust: session_index.rs::rewrite_merges_lines_appended_since_the_read
unittest
{
    auto dir = twoSessions("merge");
    scope (exit) rmdirRecurse(dir);
    rewriteAfter(dir, null);
}

// rust: session_index.rs::summarize_rejects_ids_open_would_refuse
// rust: session_index.rs::summarize_rejects_logs_open_would_refuse
unittest
{
    import std.exception : assertThrown;
    auto dir = testDir("refuse");
    scope (exit) rmdirRecurse(dir);
    auto good = writeLog(dir, "good", ["A prompt in a badly named log"]);
    std.file.copy(good, buildPath(dir, ".hidden.jsonl"));
    assertThrown(summarize(buildPath(dir, ".hidden.jsonl")), "an invalid id does not summarize");
    std.file.copy(good, buildPath(dir, "renamed.jsonl"));
    assertThrown(summarize(buildPath(dir, "renamed.jsonl")), "a renamed log does not summarize");
    std.file.write(buildPath(dir, "headerless.jsonl"), `{"type":"input","data":{"id":"i1","text":"hi"}}` ~ "\n");
    assertThrown(summarize(buildPath(dir, "headerless.jsonl")), "an input-only log does not summarize");
    auto s = summarize(good);
    assert(s.id == "good" && s.prompts == 1);
}

// rust: session_index.rs::update_rescans_a_legacy_line_missing_the_first_telling_prompt
unittest
{
    import nano.session : SessionLog;
    auto dir = testDir("legacy-telling");
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "p/m", "/w", "s");
    log.input("i1", "Investigate the flaky deploy test");
    auto legacy = summarize(log.path);
    legacy.firstTellingPrompt = null;
    append(dir, [legacy]);
    auto from = getSize(log.path);
    log.input("i2", "Now fix the retry logic in the deployer");
    update(log.path, from, null);
    auto s = list(dir)[0];
    assert(s.firstTellingPrompt == "Investigate the flaky deploy test", s.firstTellingPrompt);
    assert(titleSource(s) == "Investigate the flaky deploy test\n\nNow fix the retry logic in the deployer", titleSource(s));
}

// Round-5 review fix for issue #205: `titledIds` reads the index alone —
// titles are only ever recorded there, so a tidy-up pass must not scan or
// decompress logs (startup cost proportional to the whole history).
unittest
{
    import nano.session : SessionLog;
    auto dir = testDir("titled-index-only");
    scope (exit) rmdirRecurse(dir);
    auto titled = writeLog(dir, "titled-one", ["A prompt worth naming"]);
    auto plain = writeLog(dir, "plain-one", ["A prompt without a name"]);
    assert(titledIds(dir).length == 0, "no index entries yet: nothing titled");
    list(dir); // index both logs without titles
    setTitle(titled, "Keep me");
    auto named = titledIds(dir);
    assert(named.length == 1 && "titled-one" in named, "the index title is reported");
    // A log the index has no title for is not scanned into protection, even
    // though it sits right there in the directory.
    assert("plain-one" !in named, "an untitled log is not scanned");
    // A corrupt index hides titles: strict load throws so retention fails closed.
    std.file.append(indexPath(dir), cast(const(ubyte)[]) "{not json\n");
    import std.exception : assertThrown;
    assertThrown(titledIds(dir), "a corrupt index must not read as 'nothing titled'");
}

// Round-8 review fix for issue #205: a titled log that can no longer be
// summarized keeps its title across a listing's index rewrite, so a later
// tidy pass still treats it as named — and it stays out of picker results.
unittest
{
    auto dir = testDir("titled-truncated");
    scope (exit) rmdirRecurse(dir);
    auto path = writeLog(dir, "titled-gone", ["A prompt worth naming"]);
    list(dir);
    setTitle(path, "Keep me");
    std.file.write(path, ""); // truncated: no header, not resumable
    // The listing between truncation and retention must not drop the title.
    auto listed = list(dir);
    assert(!listed.any!(s => s.id == "titled-gone"), "an unresumable log is not in picker results");
    auto named = titledIds(dir);
    assert("titled-gone" in named, "the title survives the index rewrite");
    // And retention therefore keeps the named log.
    import nano.session : tidySessions;
    import std.file : setTimes, exists;
    import nano.clock : wallNow;
    import core.time : days;
    setTimes(path, wallNow - 200.days, wallNow - 200.days);
    std.file.write(buildPath(dir, ".tidy-stamp"), "");
    setTimes(buildPath(dir, ".tidy-stamp"), wallNow - 2.days, wallNow - 2.days);
    auto r = tidySessions(dir, 0, 180);
    assert(r.deleted == 0 && path.exists, "a named log is never deleted");
}

// Issue #271 review: a session hidden by `skip` keeps its index record (and
// so its title) when the listing rewrites the index.
unittest
{
    auto dir = testDir("skip-keeps-title");
    scope (exit) rmdirRecurse(dir);
    auto denied = writeLog(dir, "denied", ["Fix the deploy test please"]);
    auto gone = writeLog(dir, "gone", ["Write the release notes now"]);
    list(dir);
    assert(setTitle(denied, "Keep me"));
    import std.file : remove;
    remove(gone); // a stale index entry forces a rewrite
    auto shown = list(dir, false, (string p) => p == denied);
    assert(shown.length == 0, "the denied session is hidden");
    assert("denied" in titledIds(dir), "its title survives the rewrite");
}

// Issue #271 review: a denied archive visited before its allowed plain twin
// must not strip the twin's title, whichever order the directory yields.
unittest
{
    auto dir = testDir("denied-archive-twin");
    scope (exit) rmdirRecurse(dir);
    auto plain = writeLog(dir, "twin", ["Fix the deploy test please"]);
    auto gone = writeLog(dir, "gone", ["Write the release notes now"]);
    list(dir);
    assert(setTitle(plain, "Keep me"));
    auto archive = plain ~ ".gz";
    std.file.write(archive, "not read: denied");
    std.file.append(plain, ""); // unchanged size; the title must still come from the record
    import std.file : remove;
    remove(gone); // a stale index entry forces a rewrite
    auto shown = list(dir, false, (string p) => p == archive);
    assert(shown.length == 1 && shown[0].title == "Keep me", "the plain twin keeps its title");
    assert("twin" in titledIds(dir), "its title survives the forced rewrite");
}

// Summarizing a live log streams it and skips every record that isn't an
// input by its head (issue #306): a log of one huge compaction snapshot is
// summarized without allocating anything like its size.
unittest
{
    import core.memory : GC;
    import std.array : replicate;
    import std.conv : text;
    import nano.session : newSessionId;
    auto dir = buildPath(tempDir, "nano-d-index-stream-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto p = buildPath(dir, "s1.jsonl");
    auto big = `{"type":"replace","data":{"messages":"` ~ "x".replicate(4_000_000) ~ `"}}` ~ "\n";
    write(p, `{"type":"session","data":{"version":1,"id":"s1","created_at":"t"}}` ~ "\n"
        ~ `{"type":"input","data":{"id":"i1","text":"first prompt"}}` ~ "\n" ~ big
        ~ `{"type":"input","data":{"id":"i2","text":"second prompt"}}` ~ "\n");
    immutable before = GC.stats.allocatedInCurrentThread;
    auto s = summarize(p);
    immutable spent = GC.stats.allocatedInCurrentThread - before;
    assert(s.prompts == 2 && s.logBytes == getSize(p), text(s.prompts, " ", s.logBytes));
    assert(spent < big.length / 4, text("summarize allocated ", spent, " B for a ", big.length, " B record"));
}

// Issue #300: the latest `name` record in the log is the summary's handle; a
// null name clears it; it round-trips through the index line.
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists;
    import std.path : buildPath;
    import nano.session : SessionLog;
    auto dir = buildPath(tempDir, "nano-index-name");
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w", "s-named");
    log.input("i1", "Fix the parser's error recovery");
    log.name("perf");
    assert(summarize(log.path).name == "perf");
    log.name("perf-2");
    auto s = summarize(log.path);
    assert(s.name == "perf-2");
    assert(Summary.fromJson(s.toJson).name == "perf-2");
    log.name(null);
    assert(summarize(log.path).name is null, "a cleared handle");
    log.name("again");
    log.close();
    assert(list(dir)[0].name == "again");
}

// Issue #300: a strict listing whose index update fails throws, so
// retention (which then reads titles from that index) fails closed instead
// of trusting a stale index that may lack a newer handle.
unittest
{
    import std.conv : octal;
    import std.file : setAttributes;
    import std.exception : assertThrown, assertNotThrown;
    auto dir = testDir("strict-index-write");
    scope (exit) { setAttributes(indexPath(dir), octal!644); rmdirRecurse(dir); }
    writeLog(dir, "first", ["A first prompt"]);
    list(dir, true);
    writeLog(dir, "second", ["A second prompt"]);
    setAttributes(indexPath(dir), octal!444);
    assertNotThrown(list(dir), "a plain listing treats the index as a cache");
    assertThrown(list(dir, true), "strict: an index it couldn't update is an error");
}

// Issue #300 review: a handle-only session (no title) keeps its index entry
// — and so its retention protection — when its log becomes unresumable.
unittest
{
    import nano.session : SessionLog;
    auto dir = testDir("named-truncated");
    scope (exit) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock/m", "/w", "s-handle");
    log.input("i1", "A prompt worth keeping");
    log.name("keep");
    log.close();
    list(dir);
    std.file.write(log.path, ""); // truncated: not resumable
    list(dir);
    assert("s-handle" in titledIds(dir), "the cached handle survives the rewrite");
}
