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

import std.json;
import std.file;
import std.path;
import std.format : format;
import std.string : strip, startsWith;
static import std.string;
import std.datetime.systime : SysTime, Clock;
import std.algorithm : sort, any, filter;
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
    /// Size of the log this summary was made from.
    ulong logBytes;
    /// The log file (not serialized).
    string path;

    /// Fields in serde order as (key, JSON value); unset optional fields are omitted.
    string[2][] fields() const
    {
        static string q(string s) { return JSONValue(s).toString(JSONOptions.doNotEscapeSlashes); }
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
        f ~= ["log_bytes", logBytes.to!string];
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
    static Summary fromJson(const(char)[] line) @trusted
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
        s.prompts = cast(size_t) j["prompts"].integer;
        s.firstPrompt = opt("first_prompt");
        s.firstTellingPrompt = opt("first_telling_prompt");
        s.lastPrompt = opt("last_prompt");
        s.contextPrompt = opt("context_prompt");
        s.title = opt("title");
        s.logBytes = cast(ulong) j["log_bytes"].integer;
        return s;
    }
}

/// Whether a prompt says too little to identify a session by itself.
bool isTerse(string text)
{
    auto t = text.strip;
    return t.startsWith("/") || (t.walkLength < 24 && t.split.length <= 4);
}

/// Prompts are kept only to name and describe the session: the title request
/// uses at most 600 characters of one, so keep only that prefix.
private string clipPrompt(string text)
{
    return text.take(600).to!string;
}

/// Fold one input record into `s` (count, first/last and context prompts).
private void foldInput(ref Summary s, string text)
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
private bool missingTellingPrompt(const ref Summary s)
{
    if (s.firstTellingPrompt !is null) return false;
    foreach (p; [s.firstPrompt, s.lastPrompt, s.contextPrompt])
        if (p !is null && !isTerse(p)) return true;
    return false;
}

/// Committed (newline-terminated) lines of `bytes`.
private const(char)[][] committedLines(const(ubyte)[] bytes) @trusted
{
    size_t committed = bytes.length;
    while (committed && bytes[committed - 1] != '\n') committed--;
    return (cast(const(char)[]) bytes[0 .. committed]).split('\n').filter!(l => l.length > 0).array;
}

/// The input text of a committed log line, or null when it isn't an input record.
private string inputText(const(char)[] line) @trusted
{
    if (!line.startsWith(`{"type":"input"`)) return null;
    try
    {
        auto rec = parseJSON(line);
        if (rec["type"].str != "input") return null;
        return rec["data"]["text"].str;
    }
    catch (Exception) return null;
}

/// Fold every committed input record in `path` after byte offset `from`
/// (only the tail is read), so a concurrent writer's prompt is never lost.
private void foldInputsSince(string path, ulong from, ref Summary s) @trusted
{
    import std.stdio : File;
    auto f = File(path, "rb");
    f.seek(from);
    ubyte[] tail;
    foreach (chunk; f.byChunk(64 * 1024)) tail ~= chunk;
    foreach (line; committedLines(tail))
        if (auto t = inputText(line)) foldInput(s, t);
}

/// Summarize the session log at `path`. Only the header and input records are
/// decoded. Throws when the log isn't resumable: no valid id, or a first
/// record that isn't a matching header of this format version.
Summary summarize(string path) @trusted
{
    auto bytes = cast(ubyte[]) read(path);
    Summary s;
    s.path = path;
    s.lastUsed = timeLastModified(path);
    s.id = path.baseName.stripExtension;
    s.logBytes = bytes.length;
    try validateId(s.id);
    catch (Exception e) throw new Exception(format("session log %s has an invalid id", path));
    auto lines = committedLines(bytes);
    bool ok;
    if (lines.length)
    {
        try
        {
            auto h = parseJSON(lines[0]);
            auto d = h["data"];
            if (h["type"].str == "session" && d["version"].integer == formatVersion && d["id"].str == s.id)
            {
                ok = true;
                s.createdAt = d["created_at"].str;
                if (auto c = "cwd" in d) if (c.type == JSONType.string) s.cwd = c.str;
                if (auto m = "model" in d) if (m.type == JSONType.string) s.model = m.str;
            }
        }
        catch (Exception) {}
    }
    if (!ok) throw new Exception(format("session log %s has no resumable header", path));
    foreach (line; lines[1 .. $])
        if (auto t = inputText(line)) foldInput(s, t);
    return s;
}

private string indexPath(string dir)
{
    return buildPath(dir, indexFile);
}

private ulong sizeOr0(string path) @trusted
{
    try return getSize(path);
    catch (Exception) return 0;
}

/// Index lines parsed into `map` (latest wins, titles monotonic). Unreadable
/// lines are skipped: the index is only a cache.
private void mergeLines(const(ubyte)[] bytes, ref Summary[string] map, ref size_t lines) @trusted
{
    foreach (raw; (cast(const(char)[]) bytes).split('\n'))
    {
        auto line = raw.strip;
        if (!line.length) continue;
        lines++;
        Summary s;
        try s = Summary.fromJson(line);
        catch (Exception) continue;
        // A later line without a title must not hide one an earlier line recorded.
        if (s.title is null)
            if (auto prev = s.id in map) s.title = prev.title;
        map[s.id] = s;
    }
}

/// The index's summaries by id and its line count.
private Summary[string] load(string dir, out size_t lines) @trusted
{
    Summary[string] map;
    ubyte[] bytes;
    try bytes = cast(ubyte[]) read(indexPath(dir));
    catch (Exception) return map;
    mergeLines(bytes, map, lines);
    return map;
}

/// Append summaries, one `write` per line so concurrent writers don't
/// interleave within a line. A short write fails the update (no retry).
private void append(string dir, const Summary[] summaries) @trusted
{
    import core.sys.posix.fcntl : open, O_WRONLY, O_CREAT, O_APPEND;
    import core.sys.posix.unistd : write, close;
    import std.string : toStringz;
    if (!summaries.length) return;
    int fd = open(indexPath(dir).toStringz, O_WRONLY | O_CREAT | O_APPEND, octal!"644");
    if (fd < 0) throw new Exception("open session index " ~ indexPath(dir));
    scope (exit) close(fd);
    foreach (ref s; summaries)
    {
        auto line = s.toJson ~ "\n";
        if (write(fd, line.ptr, line.length) != cast(long) line.length) throw new Exception("short write to session index");
    }
}

import std.conv : octal;

/// Rewrite the index with one line per session (atomically, via rename),
/// merging whatever was appended since byte `since` (sampled before the read).
private void rewrite(string dir, const Summary[string] summaries, ulong since) @trusted
{
    import std.process : thisProcessID;
    Summary[string] merged;
    foreach (k, v; summaries) merged[k] = cast(Summary) v;
    try
    {
        import std.stdio : File;
        auto f = File(indexPath(dir), "rb");
        if (f.size >= since)
        {
            f.seek(since);
            ubyte[] rest;
            foreach (chunk; f.byChunk(64 * 1024)) rest ~= chunk;
            size_t n;
            mergeLines(rest, merged, n);
        }
    }
    catch (Exception) {}
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
Summary update(string path, ulong from, string model) @trusted
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
bool setTitle(string path, string title) @trusted
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
string titleSource(const ref Summary s)
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
string cleanTitle(string reply)
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

/// Every resumable session with at least one prompt in `dir`, newest first.
/// Sessions the index lacks, or whose log changed since it was indexed, are
/// summarized from their logs, and the index is updated. A missing directory
/// is no sessions; other filesystem errors propagate.
Summary[] list(string dir) @trusted
{
    if (!dir.exists) return null;
    auto indexLen = sizeOr0(indexPath(dir));
    size_t lines;
    auto index = load(dir, lines);
    Summary[string] current;
    Summary[] updates;
    foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
    {
        auto name = e.name.baseName;
        if (name.extension != ".jsonl" || name == indexFile) continue;
        auto id = name.stripExtension;
        try validateId(id);
        catch (Exception) continue;
        if (!e.isFile) continue;
        auto size = e.size;
        Summary s;
        auto cached = id in index;
        if (cached !is null && cached.logBytes == size) s = *cached;
        else
        {
            try s = summarize(e.name);
            catch (FileException err) throw err;
            catch (Exception) continue; // not resumable
            if (cached !is null)
            {
                // Keep a model and title the index learned after the session started.
                if (cached.model !is null) s.model = cached.model;
                if (s.title is null) s.title = cached.title;
            }
            updates ~= s;
        }
        if (cached !is null) index.remove(id);
        s.path = e.name;
        current[id] = s;
    }
    try
    {
        if (lines + updates.length > current.length * 2 + 64 || index.length) rewrite(dir, current, indexLen);
        else append(dir, updates);
    }
    catch (Exception) {} // only a cache
    auto out_ = current.byValue.filter!(s => s.prompts > 0).array;
    out_.sort!((a, b) => a.lastUsed > b.lastUsed);
    return out_;
}

version (unittest)
{
    private string testDir(string name) @trusted
    {
        auto d = buildPath(tempDir, "nano-d-index-" ~ name);
        if (d.exists) rmdirRecurse(d);
        mkdirRecurse(d);
        return d;
    }

    private string writeLog(string dir, string id, string[] prompts, string cwd = "/w") @trusted
    {
        import nano.session : SessionLog;
        auto log = new SessionLog(dir, "p/m", cwd, id);
        foreach (i, p; prompts) log.input(format("in-%s", i), p);
        return log.path;
    }
}

@trusted unittest
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

@trusted unittest
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

@trusted unittest
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

@trusted unittest
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

@trusted unittest
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

version (unittest) private bool canFindSlashEscape(string s)
{
    import std.algorithm : canFind;
    return s.canFind(`\/`);
}
