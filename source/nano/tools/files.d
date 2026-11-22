/// File tools: `read_file`, `write_file`, `edit_file`. Writes and edits of an
/// existing file require that it was read first and has not changed since, so
/// the model never overwrites content it hasn't seen. Writes go through a temp
/// file + rename, re-validated just before the rename.
module nano.tools.files;

@safe:

import std.string : representation;
import nano.safeio : bytesOf, utf8Text;
import nano.safeio : jsonText, jsonPretty;
import nano.arith : saturatingSub, toSize;

import nano.safeio : ownText, readBytes, realPath, statMode, writeTemp, newFileMode;

import std.json;
import std.format : format;
import std.file;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath, dirName, expandTilde;
import std.string : indexOf, lastIndexOf, stripLeft, stripRight, strip, join, startsWith, endsWith;
import std.algorithm : count, min, max, all, any, sort, uniq;
import std.array : replace, split, array;
import std.digest.sha : sha256Of;
import nano.tools;
import nano.llm : ToolDefinition;

enum long defaultReadLimit = 2000;
enum size_t maxLineChars = 2000;

/// What the agent has seen of each file (by content hash), keyed by canonical
/// path so symlinks and relative paths agree.
class ReadState
{
    private ubyte[32][string] seen;

    private static string key(string path)
    {
        auto c = realPath(path);
        return c !is null ? c : path;
    }

    void record(string path, const(void)[] content) { seen[key(path)] = sha256Of(content); }
    /// `record` for content hashed elsewhere (a concurrent read_file).
    void recordDigest(string path, ubyte[32] digest) { seen[key(path)] = digest; }
    void forget(string path) { seen.remove(key(path)); }

    /// Whether the model read `path` and its bytes on disk (`current`) have
    /// changed since: what it saw is stale. False for a file never read.
    bool staleRead(string path, const(ubyte)[] current)
    {
        auto s = key(path) in seen;
        return s !is null && *s != sha256Of(current);
    }

    /// Fail unless `current` (the file's bytes on disk) is what the model last saw.
    void checkFresh(string path, const(ubyte)[] current, string tool)
    {
        auto s = key(path) in seen;
        if (s is null)
            throw new ToolError(format("%s: %s has not been read yet; read it with read_file before changing it", tool, path));
        if (*s != sha256Of(current))
            throw new ToolError(format("%s: %s has changed since it was last read (by a command, a tool or the user); "
                    ~ "read it again before changing it", tool, path));
    }
}

string resolvePath(string p)
{
    return buildNormalizedPath(absolutePath(expandTilde(p)));
}

bool looksBinary(const(ubyte)[] data) pure
{
    import std.algorithm : canFind;
    return data[0 .. min(data.length, 8192)].canFind(ubyte(0));
}

/// Lines as `read_file` numbers them: split on `\n`, a `\r` before it dropped,
/// no trailing empty line (Rust `str::lines`).
string[] textLines(string s) pure
{
    string[] out_;
    size_t st;
    foreach (i, char c; s)
        if (c == '\n')
        {
            auto l = s[st .. i];
            if (l.length && l[$ - 1] == '\r') l = l[0 .. $ - 1];
            out_ ~= l;
            st = i + 1;
        }
    if (st < s.length) out_ ~= s[st .. $];
    return out_;
}

string readFile(JSONValue args, ReadState state)
{
    return readFile(args, (string path, const(ubyte)[] data) => state.record(path, data));
}

/// `read_file` reporting what it showed to `seen` instead of a `ReadState`,
/// so it can run on a worker thread (issue #222): it touches nothing else.
string readFile(JSONValue args, scope void delegate(string path, const(ubyte)[] data) @safe seen)
{
    auto path = resolvePath(requireString(args, "path", "read_file"));
    auto offset = optInt(args, "offset", 1);
    auto limit = optInt(args, "limit", defaultReadLimit);
    if (offset < 1) throw new ToolError("read_file: offset must be 1 or more");
    if (limit < 1) throw new ToolError("read_file: limit must be 1 or more");
    if (!path.exists) throw new ToolError(format("read_file: %s does not exist", path));
    if (path.isDir) throw new ToolError(format("read_file: %s is a directory; use glob or bash ls", path));
    auto data = readBytes(path);
    import std.path : extension;
    import std.uni : toLower;
    // An image returns its metadata only, as `{"image": {...}}`; the agent
    // re-reads it by path, fits it to the model and attaches it (or reports
    // that the model can't view images). Text output never starts with `{`.
    import nano.attachment : sniff, dimensions, mediaType, extension_ = extension;
    auto fmt = sniff(data);
    if (!fmt.isNull)
    {
        uint[2] dims;
        try dims = dimensions(data);
        catch (Exception e) throw new ToolError(format("read_file: %s: read image dimensions: %s", path, e.msg));
        JSONValue img = ["media_type": fmt.get.mediaType, "extension": fmt.get.extension_, "path": path];
        img["width"] = dims[0];
        img["height"] = dims[1];
        img["bytes"] = data.length;
        return JSONValue(["image": img]).jsonText;
    }
    if (looksBinary(data)) throw new ToolError(format("read_file: %s looks like a binary file (%s bytes)", path, data.length));
    import std.utf : validate, UTFException;
    auto text = ownText(data);
    try validate(text);
    catch (UTFException) throw new ToolError(format("read_file: %s is not valid UTF-8 text", path));
    auto lines = textLines(text);
    if (lines.length == 0)
    {
        seen(path, data);
        return "(empty file)";
    }
    if (offset > lines.length)
        throw new ToolError(format("read_file: offset %s is past the end of %s (%s lines)", offset, path, lines.length));
    // Record only once the read has succeeded, so a failed out-of-range read
    // can't authorize a later edit the model never saw.
    seen(path, data);
    auto first = toSize(offset - 1);
    auto last = min(lines.length, first + toSize(limit));
    string out_;
    foreach (n; first .. last)
    {
        auto line = lines[n];
        if (line.length > maxLineChars) line = line[0 .. safeCut(line, maxLineChars)] ~ " [line truncated]";
        out_ ~= format("%6d\t%s\n", n + 1, line);
    }
    if (last < lines.length)
        out_ ~= format("\n(%s more lines; use offset=%s to continue)", lines.length - last, last + 1);
    return out_;
}

/// A byte index ≤ `at` that does not split a UTF-8 sequence.
private size_t safeCut(string s, size_t at) pure
{
    if (at >= s.length) return s.length;
    while (at > 0 && (s[at] & 0xC0) == 0x80) at--;
    return at;
}

/// What the target was when the write was planned: absent, or these bytes.
struct Expect
{
    bool absent;
    const(ubyte)[] bytes;
    static Expect none() pure { return Expect(true, null); }
    static Expect was(const(ubyte)[] b) pure { return Expect(false, b); }
}

private bool linkPresent(string path)
{
    try { getLinkAttributes(path); return true; }
    catch (FileException) return false;
}

private bool isLink(string path)
{
    try return isSymlink(path);
    catch (FileException) return false;
}

/// Write `content` to `path` via a temp file + rename, re-validating `expect`
/// immediately before the rename so an edit by an editor or formatter (or a
/// concurrent create) in the meantime fails instead of being clobbered. The
/// temp file is removed on every error path.
void writeAtomically(string path, const(char)[] content, Expect expect, ReadState state, string tool)
{
    // Write through symlinks: renaming onto the link would replace it.
    if (isLink(path))
    {
        auto r = realPath(path);
        if (r is null) throw new ToolError(format("%s: resolve symlink %s", tool, path));
        path = r;
    }
    try mkdirRecurse(path.dirName);
    catch (FileException e) throw new ToolError(format("%s: create %s: %s", tool, path.dirName, e.msg));
    uint mode = newFileMode;
    if (statMode(path, mode)) mode &= octal!7777;
    else mode = newFileMode;
    string tmp;
    try tmp = writeTemp(path.dirName, path.baseName, content.representation, mode);
    catch (FileException e) throw new ToolError(format("%s: write %s: %s", tool, path, e.msg));
    // best-effort cleanup of the temp file; the original error propagates
    scope (failure) { try remove(tmp); catch (Exception) {} }
    if (expect.absent)
    {
        if (linkPresent(path))
            throw new ToolError(format("%s: %s was created while the write was being prepared; read it again before overwriting it", tool, path));
    }
    else
    {
        ubyte[] current;
        try current = readBytes(path);
        catch (Exception e) throw new ToolError(format("%s: re-read %s: %s", tool, path, e.msg));
        state.checkFresh(path, current, tool);
        if (current != expect.bytes)
            throw new ToolError(format("%s: %s changed while the edit was being prepared; read it again before changing it", tool, path));
    }
    try rename(tmp, path);
    catch (FileException e) throw new ToolError(format("%s: replace %s: %s", tool, path, e.msg));
}

private import std.conv : octal;

string writeFile(JSONValue args, ReadState state)
{
    auto path = resolvePath(requireString(args, "path", "write_file"));
    auto content = requireString(args, "content", "write_file");
    bool existed = path.exists;
    auto expect = Expect.none;
    if (existed)
    {
        // Propagate a read failure (a directory, no permission) rather than
        // treat the path as new and skip the freshness check.
        ubyte[] current;
        try current = readBytes(path);
        catch (Exception e) throw new ToolError(format("write_file: read %s: %s", path, e.msg));
        state.checkFresh(path, current, "write_file");
        expect = Expect.was(current);
    }
    writeAtomically(path, content, expect, state, "write_file");
    state.record(path, content);
    auto lines = content.length ? content.count('\n') + (content[$ - 1] == '\n' ? 0 : 1) : 0;
    return format("%s %s (%s bytes, %s lines)", existed ? "Overwrote" : "Created", path, content.length, lines);
}

/// A located edit: replace each range with the matching `news` entry. `how`
/// names the relaxed rule that found it (empty for an exact match).
struct Located
{
    size_t[2][] ranges;
    string[] news;
    string how;
}

/// `s` with `\n` turned into `\r\n` when `text` uses CRLF anywhere.
private string toFileEndings(string text, string s) pure
{
    return text.indexOf("\r\n") >= 0 && s.indexOf('\r') < 0 ? s.replace("\n", "\r\n") : s;
}

/// The line ending for a replacement over `text[start .. end]`: a multiline
/// region keeps the ending of the line it starts on; a single-line region
/// uses its own line's terminator, else the file's first line ending.
string endingFor(string text, size_t start, size_t end) pure
{
    auto lo = min(start, text.length);
    auto hi = max(min(end, text.length), lo);
    auto nl = text[0 .. lo].lastIndexOf('\n');
    size_t ls = nl < 0 ? 0 : nl + 1;
    auto f = text[ls .. $].indexOf('\n');
    size_t le = f < 0 ? text.length : ls + f;
    bool lineCrlf = text[ls .. le].endsWith("\r");
    if (text[lo .. hi].indexOf('\n') >= 0) return lineCrlf ? "\r\n" : "\n";
    auto f1 = text.indexOf('\n');
    bool fileCrlf = f1 > 0 && text[f1 - 1] == '\r';
    return lineCrlf || fileCrlf ? "\r\n" : "\n";
}

private string toEndingsAt(string text, size_t start, size_t end, string s) pure
{
    return endingFor(text, start, end) == "\r\n" && s.indexOf('\r') < 0 ? s.replace("\n", "\r\n") : s;
}

/// `read_file`'s `{:>6}\t` line-number prefix: the number and the rest.
private bool prefixNum(string line, out ulong num, out string rest) pure
{
    import std.ascii : isDigit;
    import std.conv : to, ConvException;
    auto t = line.indexOf('\t');
    if (t < 0) return false;
    auto field = line[0 .. t];
    auto digits = field.stripLeft(" ");
    if (digits.length == 0 || !digits.all!isDigit) return false;
    try num = digits.to!ulong;
    catch (ConvException) return false;
    if (field != format("%6d", num)) return false;
    rest = line[t + 1 .. $];
    return true;
}

struct Stripped
{
    bool ok;
    string old, new_;
    ulong lo;
}

/// When `old` is copied `read_file` output (every line prefixed, numbers
/// consecutive), `old` with the prefixes removed and its first line number.
/// A `new` line prefixed with a number in old's range is ambiguous: rejected.
Stripped stripLineNumbers(string old, string new_) pure
{
    ulong[] nums;
    foreach (l; textLines(old))
    {
        ulong n;
        string rest;
        if (!prefixNum(l, n, rest)) return Stripped.init;
        nums ~= n;
    }
    if (nums.length == 0) return Stripped.init;
    foreach (i; 1 .. nums.length)
        if (nums[i - 1] == ulong.max || nums[i - 1] + 1 != nums[i]) return Stripped.init;
    auto lo = nums[0], hi = nums[$ - 1];
    foreach (l; textLines(new_))
    {
        ulong n;
        string rest;
        if (prefixNum(l, n, rest) && n >= lo && n <= hi)
            throw new ToolError(format("new_string line(s) start with a number in old_string's copied line range %s..=%s; "
                    ~ "that prefix is ambiguous (line number or intended content?). Resubmit new_string "
                    ~ "without the leading line-number field.", lo, hi));
    }
    string[] parts;
    foreach (l; old.split("\n"))
    {
        ulong n;
        string rest;
        parts ~= prefixNum(l, n, rest) ? rest : l;
    }
    return Stripped(true, parts.join("\n"), new_, lo);
}

/// The 1-based line number byte offset `at` falls on.
private ulong lineAt(string text, size_t at) pure { return text[0 .. at].count('\n') + 1; }

private bool atLineStart(string text, size_t at) pure { return at == 0 || text[at - 1] == '\n'; }

/// The file's lines as [start, end of content, end including terminator].
private size_t[3][] lineSpans(string text) pure
{
    size_t[3][] spans;
    size_t st;
    void add(size_t endIncl)
    {
        auto c = endIncl;
        while (c > st && text[c - 1] == '\n') c--;
        while (c > st && text[c - 1] == '\r') c--;
        spans ~= [st, c, endIncl];
        st = endIncl;
    }
    foreach (i, char ch; text)
        if (ch == '\n') add(i + 1);
    if (st < text.length) add(text.length);
    return spans;
}

/// `old`'s lines without a trailing empty line, and whether it ended in `\n`.
private string[] oldLines(string old, out bool endsNl) pure
{
    endsNl = old.endsWith("\n");
    auto body_ = endsNl ? old[0 .. $ - 1] : old;
    string[] ls;
    foreach (l; body_.split("\n"))
    {
        while (l.length && l[$ - 1] == '\r') l = l[0 .. $ - 1];
        ls ~= l;
    }
    if (ls.length == 0) ls = [""];
    return ls;
}

private string leadingWs(string s) pure { return s[0 .. s.length - s.stripLeft.length]; }

/// `s` without `prefix`, or null when it doesn't start with it.
private bool chop(string s, string prefix, out string rest) pure
{
    if (!s.startsWith(prefix)) return false;
    rest = s[prefix.length .. $];
    return true;
}

/// Re-indent `text` from the replacement's base indentation `had` to the
/// file's `want`, keeping tab/space structure; incompatible whitespace (neither
/// a prefix of the other) is rejected.
string reindent(string text, string had, string want) pure
{
    import std.range : drop, walkLength;
    if (!want.startsWith(had) && !had.startsWith(want))
        throw new ToolError(format("can't re-indent relaxed match: replacement indentation %(%s%) and file indentation "
                ~ "%(%s%) use incompatible whitespace; copy the file's exact indentation into new_string", [had], [want]));
    string[] out_;
    foreach (l; text.split("\n"))
    {
        if (l.strip.length == 0) { out_ ~= l; continue; }
        auto ws = leadingWs(l);
        auto rest = l[ws.length .. $];
        string deeper, extra;
        if (chop(ws, had, deeper)) out_ ~= want ~ deeper ~ rest;
        else if (chop(want, had, extra)) out_ ~= ws ~ extra ~ rest;
        else out_ ~= ws.drop(had.walkLength - want.walkLength) ~ rest;
    }
    return out_.join("\n");
}

/// Match `old` line by line ignoring trailing whitespace (or, with
/// `trimStart`, indentation too). Only a unique match counts; an
/// indentation-relaxed one re-indents the replacement.
private bool matchLines(string text, string old, string new_, bool trimStart, out Located found) pure
{
    auto spans = lineSpans(text);
    bool endsNl;
    auto lines = oldLines(old, endsNl);
    auto k = lines.length;
    if (lines.all!(l => l.strip.length == 0) || spans.length < k) return false;
    string norm(string s) { return trimStart ? s.strip : s.stripRight; }
    string fileLine(size_t i) { return text[spans[i][0] .. spans[i][1]]; }
    auto fileNorm = new string[spans.length];
    foreach (i; 0 .. spans.length) fileNorm[i] = norm(fileLine(i));
    auto oldNorm = new string[k];
    foreach (j; 0 .. k) oldNorm[j] = norm(lines[j]);
    size_t[] hits;
    foreach (i; 0 .. spans.length - k + 1)
    {
        bool ok = true;
        foreach (j; 0 .. k)
            if (fileNorm[i + j] != oldNorm[j]) { ok = false; break; }
        if (ok) hits ~= i;
    }
    auto how = trimStart ? "ignoring indentation" : "ignoring trailing whitespace";
    if (hits.length == 0) return false;
    if (hits.length > 1)
        throw new ToolError(format("old_string matches %s places (%s); add surrounding context to make it unique", hits.length, how));
    auto i = hits[0];
    auto start = spans[i][0];
    auto end = endsNl ? spans[i + k - 1][2] : spans[i + k - 1][1];
    auto repl = new_;
    if (trimStart)
    {
        ptrdiff_t j0 = -1;
        foreach (j, l; lines) if (l.strip.length) { j0 = j; break; }
        if (j0 >= 0)
        {
            auto want = leadingWs(fileLine(i + j0)), had = leadingWs(lines[j0]);
            bool consistent(string hadJ, string wantJ)
            {
                string extra, dropped, r;
                if (chop(want, had, extra)) return chop(wantJ, hadJ, r) && r == extra;
                if (chop(had, want, dropped)) return chop(hadJ, wantJ, r) && r == dropped;
                return true; // incompatible: reindent rejects it below
            }
            foreach (j, ol; lines)
            {
                if (ol.strip.length == 0) continue;
                if (!consistent(leadingWs(ol), leadingWs(fileLine(i + j))))
                    throw new ToolError(format("old_string matches at line %s ignoring indentation, but its indentation shifts "
                            ~ "non-uniformly (line %s differs); copy the file's exact indentation into old_string", i + 1, i + j + 1));
            }
            if (want != had) repl = reindent(repl, had, want);
        }
    }
    found = Located([[start, end]], [toEndingsAt(text, start, end, repl)], how);
    return true;
}

/// Occurrences of `pat` in `text`: non-overlapping, or every start when
/// `overlapping` (so a patch hunk that matches at two overlapping places is
/// seen as ambiguous rather than unique).
private size_t[2][] occurrences(string text, string pat, bool overlapping = false) pure
{
    size_t[2][] r;
    size_t from;
    while (from <= text.length)
    {
        auto i = text[from .. $].indexOf(pat);
        if (i < 0) break;
        auto at = from + i;
        r ~= [at, at + pat.length];
        from = overlapping ? at + 1 : at + pat.length;
    }
    return r;
}

private struct Attempt
{
    string old, new_, how;
    ulong atLine; // 0: anywhere
    bool lineStart; /// exact matches must start at a line boundary
}

/// Exact match of one attempt, in its literal and file-ending forms.
private bool exactMatch(string text, const Attempt a, bool replaceAll, out Located found) pure
{
    auto normalized = toFileEndings(text, a.old);
    auto cands = normalized != a.old ? [a.old, normalized] : [a.old];
    size_t[2][] ranges;
    foreach (c; cands)
        foreach (r; occurrences(text, c, a.lineStart))
            if ((a.atLine == 0 || (lineAt(text, r[0]) == a.atLine && atLineStart(text, r[0])))
                && (!a.lineStart || atLineStart(text, r[0])))
                ranges ~= r;
    ranges.sort!((x, y) => x[0] != y[0] ? x[0] < y[0] : x[1] < y[1]);
    // Coalesce a range contained in the previous one (the LF and CRLF forms of
    // one occurrence); a crossing range is a distinct, conflicting occurrence.
    size_t[2][] kept;
    foreach (r; ranges)
    {
        if (kept.length && r[1] <= kept[$ - 1][1]) continue;
        if (kept.length && r[0] < kept[$ - 1][1])
            throw new ToolError("old_string matches overlapping occurrences ambiguously; add surrounding context to disambiguate");
        kept ~= r;
    }
    if (kept.length == 0) return false;
    string[] news;
    foreach (r; kept) news ~= toEndingsAt(text, r[0], r[1], a.new_);
    if (kept.length == 1 || (replaceAll && a.how.length == 0))
    {
        found = Located(kept, news, a.how);
        return true;
    }
    throw new ToolError(format("old_string occurs %s times; add surrounding context to make it unique or set replace_all", kept.length));
}

/// Find `old` in `text`: exactly (as given, then without `read_file` line
/// numbers), then line by line ignoring trailing whitespace, then ignoring
/// indentation. Relaxed matches must be unique and agree across attempts.
/// With `lineStart`, an exact match must begin a line (whole-line hunks), so a
/// substring inside an indented line falls through to the line-based tiers.
Located locate(string text, string old, string new_, bool replaceAll, bool lineStart = false) pure
{
    Located found;
    auto literal = Attempt(old, new_, "", 0, lineStart);
    if (exactMatch(text, literal, replaceAll, found)) return found;
    Attempt[] attempts = [literal];
    auto s = stripLineNumbers(old, new_);
    if (s.ok)
    {
        attempts ~= Attempt(s.old, s.new_, "after removing read_file line numbers", s.lo);
        if (exactMatch(text, attempts[1], replaceAll, found)) return found;
    }
    foreach (trimStart; [false, true])
    {
        bool have;
        Located chosen;
        foreach (a; attempts)
        {
            Located f;
            if (!matchLines(text, a.old, a.new_, trimStart, f)) continue;
            if (a.atLine && lineAt(text, f.ranges[0][0]) != a.atLine) continue;
            if (!have) { chosen = f; have = true; }
            else if (chosen.ranges != f.ranges)
                throw new ToolError(format("old_string matches multiple distinct locations under relaxed matching "
                        ~ "(lines %s and %s); add surrounding context to make it unique",
                        lineAt(text, chosen.ranges[0][0]), lineAt(text, f.ranges[0][0])));
        }
        if (have) return chosen;
    }
    throw new ToolError("old_string not found; read the file and copy the text exactly" ~ nearMiss(text, attempts[$ - 1].old));
}

/// Lines `lo .. hi` (0-based, inclusive) numbered as `read_file` shows them;
/// long spans keep their first and last 20 lines.
private string numbered(const string[] lines, size_t lo, size_t hi) pure
{
    string fmt(size_t i)
    {
        auto l = lines[i];
        return format("%6d\t%s\n", i + 1, l[0 .. safeCut(l, maxLineChars)]);
    }
    string out_;
    if (hi + 1 - lo > 40)
    {
        foreach (i; lo .. lo + 20) out_ ~= fmt(i);
        out_ ~= "   ...\n";
        foreach (i; hi - 19 .. hi + 1) out_ ~= fmt(i);
    }
    else
        foreach (i; lo .. hi + 1) out_ ~= fmt(i);
    return out_;
}

/// The edited regions with three lines of context either side. Nearby regions
/// merge, distant ones are separated by `...`, and a global budget bounds the
/// total (omitted regions are noted).
string snippet(string text, const size_t[2][] ranges) pure
{
    auto lines = textLines(text);
    if (lines.length == 0) return "(the file is now empty)\n";
    auto mx = lines.length - 1;
    size_t[2][] spans;
    foreach (r; ranges)
    {
        auto first = min(text[0 .. r[0]].count('\n'), mx);
        auto region = text[r[0] .. r[1]];
        if (region.endsWith("\n")) region = region[0 .. $ - 1];
        auto last = min(first + region.count('\n'), mx);
        spans ~= [saturatingSub(first, 3), min(last + 3, mx)];
    }
    spans.sort!((x, y) => x[0] != y[0] ? x[0] < y[0] : x[1] < y[1]);
    size_t[2][] merged;
    foreach (sp; spans)
    {
        if (merged.length && sp[0] <= merged[$ - 1][1] + 1) merged[$ - 1][1] = max(merged[$ - 1][1], sp[1]);
        else merged ~= sp;
    }
    enum maxSnippetLines = 40;
    string out_;
    size_t used;
    foreach (idx, m; merged)
    {
        auto region = numbered(lines, m[0], m[1]);
        auto n = region.count('\n');
        if (idx > 0 && used + n > maxSnippetLines)
        {
            out_ ~= format("   ... (%s more edited region(s) not shown)\n", merged.length - idx);
            break;
        }
        if (idx > 0) out_ ~= "   ...\n";
        out_ ~= region;
        used += n;
    }
    return out_;
}

/// For a failed match: the window sharing the most trimmed lines with `old`,
/// else (a misspelled line) the window with the most shared characters.
string nearMiss(string text, string old) pure
{
    auto lines = textLines(text);
    bool endsNl;
    auto want = oldLines(old, endsNl);
    auto k = min(want.length, lines.length);
    if (k == 0) return "";
    enum maxScan = 2000;
    auto span = lines.length - k + 1;
    auto windows = min(span, maxScan);
    auto scope_ = span > maxScan
        ? format(" (nearest within the first %s of %s candidate positions scanned)", windows, span) : "";
    auto trimmed = new string[want.length];
    foreach (j, w; want) trimmed[j] = w.strip;
    size_t best, bi;
    foreach (i; 0 .. windows)
    {
        size_t sc;
        foreach (j; 0 .. k) if (trimmed[j].length && lines[i + j].strip == trimmed[j]) sc++;
        if (sc > best) { best = sc; bi = i; }
    }
    if (best > 0)
    {
        auto of = trimmed.count!(t => t.length > 0);
        return format(". Closest match (%s of %s lines agree)%s, lines %s-%s:\n%s", best, of, scope_, bi + 1, bi + k,
                numbered(lines, bi, bi + k - 1));
    }
    auto wantCounts = new int[dchar][k];
    foreach (j; 0 .. k) foreach (dchar c; trimmed[j]) wantCounts[j][c]++;
    size_t sbest, si;
    foreach (i; 0 .. windows)
    {
        size_t sc;
        foreach (j; 0 .. k)
        {
            int[dchar] have;
            foreach (dchar c; lines[i + j].strip) have[c]++;
            foreach (c, wc; wantCounts[j]) sc += min(wc, have.get(c, 0));
        }
        if (sc > sbest) { sbest = sc; si = i; }
    }
    if (sbest == 0) return "";
    return format(". Closest lines %s-%s (no lines match exactly)%s:\n%s", si + 1, si + k, scope_, numbered(lines, si, si + k - 1));
}

string editFile(JSONValue args, ReadState state)
{
    auto path = resolvePath(requireString(args, "path", "edit_file"));
    auto oldS = requireString(args, "old_string", "edit_file");
    auto newS = requireString(args, "new_string", "edit_file");
    auto all = optBool(args, "replace_all", false);
    if (!path.exists) throw new ToolError(format("edit_file: %s does not exist; use write_file to create it", path));
    if (oldS.length == 0) throw new ToolError("edit_file: old_string must not be empty (use write_file to create a file)");
    if (oldS == newS) throw new ToolError("edit_file: old_string and new_string are identical");
    ubyte[] bytes;
    try bytes = readBytes(path);
    catch (Exception e) throw new ToolError(format("edit_file: read %s: %s", path, e.msg));
    state.checkFresh(path, bytes, "edit_file");
    import std.utf : UTFException;
    string text;
    try text = utf8Text(bytes);
    catch (UTFException) throw new ToolError(format("edit_file: %s is not valid UTF-8", path));
    Located found;
    try found = locate(text, oldS, newS, all);
    catch (ToolError e) throw new ToolError(format("edit_file: %s: %s", path, e.msg));
    string updated;
    size_t last;
    size_t[2][] newRanges;
    foreach (i, r; found.ranges)
    {
        updated ~= text[last .. r[0]];
        auto at = updated.length;
        updated ~= found.news[i];
        newRanges ~= [at, updated.length];
        last = r[1];
    }
    updated ~= text[last .. $];
    writeAtomically(path, updated, Expect.was(bytes), state, "edit_file");
    state.record(path, updated);
    return format("Replaced %s occurrence(s) in %s%s:\n%s", found.ranges.length, path,
            found.how.length ? " (matched " ~ found.how ~ ")" : "", snippet(updated, newRanges));
}

// ---------------------------------------------------------------------------
// apply_patch: an atomic, content-anchored, multi-file patch.
// ---------------------------------------------------------------------------

/// One hunk of an `*** Update File` section: the `@@` anchor line's text
/// (empty: none), the lines it expects (context and `-`) and the lines that
/// replace them (context and `+`).
struct PatchHunk
{
    string anchor;
    string[] old_, new_;
    bool eof; /// `*** End of File`: the hunk must end at the end of the file
    /// The hunk's last operation (' ', '-' or '+'): whether a line still
    /// follows the replaced region's end, which the line arrays can't tell.
    char lastOp = ' ';
    size_t line; /// 1-based line in the patch where the hunk starts
}

enum PatchKind { add, delete_, update }

/// One file section of a patch. `*** Move File: a -> b` and `*** Update
/// File: a` + `*** Move to: b` are both an update with `moveTo` set.
struct FilePatch
{
    PatchKind kind;
    string path;
    string moveTo; /// null: not moved
    string content; /// add: the new file's text
    PatchHunk[] hunks;
}

private bool isSectionHeader(string l) pure
{
    return l.startsWith("*** ") && l.stripRight != "*** End of File";
}

/// Parse the `*** Begin Patch` ... `*** End Patch` format. Errors name the
/// patch line.
FilePatch[] parsePatch(string patch) pure
{
    auto lines = textLines(patch);
    size_t lo, hi = lines.length;
    while (lo < hi && lines[lo].strip.length == 0) lo++;
    while (hi > lo && lines[hi - 1].strip.length == 0) hi--;
    if (lo == hi || lines[lo].strip != "*** Begin Patch")
        throw new ToolError("apply_patch: the patch must start with a `*** Begin Patch` line");
    if (hi < lo + 2 || lines[hi - 1].strip != "*** End Patch")
        throw new ToolError("apply_patch: the patch must end with an `*** End Patch` line");
    auto end = hi - 1;
    ToolError err(size_t at, string m) { return new ToolError(format("apply_patch: patch line %s: %s", at + 1, m)); }
    string pathOf(size_t at, string p)
    {
        p = p.strip;
        if (!p.length) throw err(at, "missing file path");
        return p;
    }
    FilePatch[] out_;
    size_t i = lo + 1;
    while (i < end)
    {
        auto l = lines[i];
        string rest;
        if (l.strip.length == 0) { i++; continue; }
        if (chop(l, "*** Add File: ", rest))
        {
            auto fp = FilePatch(PatchKind.add, pathOf(i, rest));
            i++;
            string[] body_;
            for (; i < end && !isSectionHeader(lines[i]); i++)
            {
                if (lines[i].length == 0) continue; // a blank separator line, not file content
                if (!lines[i].startsWith("+")) throw err(i, "every line of an added file starts with `+`");
                body_ ~= lines[i][1 .. $];
            }
            fp.content = body_.length ? body_.join("\n") ~ "\n" : "";
            out_ ~= fp;
        }
        else if (chop(l, "*** Delete File: ", rest))
        {
            out_ ~= FilePatch(PatchKind.delete_, pathOf(i, rest));
            i++;
        }
        else if (chop(l, "*** Update File: ", rest) || l.startsWith("*** Move File: "))
        {
            FilePatch fp;
            fp.kind = PatchKind.update;
            string mv;
            if (chop(l, "*** Move File: ", mv))
            {
                auto arrow = mv.indexOf(" -> ");
                if (arrow < 0) throw err(i, "a move is written `*** Move File: <from> -> <to>`");
                fp.path = pathOf(i, mv[0 .. arrow]);
                fp.moveTo = pathOf(i, mv[arrow + 4 .. $]);
            }
            else fp.path = pathOf(i, rest);
            i++;
            if (i < end && chop(lines[i], "*** Move to: ", rest))
            {
                if (fp.moveTo !is null) throw err(i, "the file is already being moved");
                fp.moveTo = pathOf(i, rest);
                i++;
            }
            while (i < end && !isSectionHeader(lines[i]))
            {
                PatchHunk h;
                h.line = i + 1;
                if (lines[i].startsWith("@@"))
                {
                    h.anchor = lines[i][2 .. $].strip;
                    import std.regex : ctRegex, matchFirst;
                    if (!matchFirst(h.anchor, ctRegex!`^-\d+(,\d+)? \+\d+`).empty)
                        throw err(i, "line-number hunk headers are not supported; write `@@` alone or `@@ <a nearby line, such as a signature>`");
                    i++;
                }
                bool any;
                size_t trailingBlank;
                for (; i < end && !lines[i].startsWith("@@") && !isSectionHeader(lines[i]); i++)
                {
                    auto x = lines[i];
                    if (x.stripRight == "*** End of File") { h.eof = true; i++; break; }
                    any = true;
                    if (x.length == 0) { h.old_ ~= ""; h.new_ ~= ""; trailingBlank++; continue; }
                    trailingBlank = 0;
                    h.lastOp = x[0];
                    switch (x[0])
                    {
                    case ' ': h.old_ ~= x[1 .. $]; h.new_ ~= x[1 .. $]; break;
                    case '-': h.old_ ~= x[1 .. $]; break;
                    case '+': h.new_ ~= x[1 .. $]; break;
                    default: throw err(i, "a hunk line starts with ' ' (context), '-' (remove) or '+' (add)");
                    }
                }
                // Bare blank lines at the end of a hunk separate sections; they are not context.
                h.old_ = h.old_[0 .. $ - trailingBlank];
                h.new_ = h.new_[0 .. $ - trailingBlank];
                if (!any) throw err(h.line - 1, "empty hunk");
                if (h.old_ == h.new_) throw err(h.line - 1, "the hunk changes nothing (no '-' or '+' lines)");
                fp.hunks ~= h;
            }
            if (!fp.hunks.length && fp.moveTo is null)
                throw err(i - 1, format("`*** Update File: %s` has no hunks", fp.path));
            out_ ~= fp;
        }
        else
            throw err(i, "expected `*** Add File: `, `*** Delete File: `, `*** Update File: `, `*** Move File: ` or `*** End Patch`");
    }
    if (!out_.length) throw new ToolError("apply_patch: the patch changes no files");
    return out_;
}

/// Every path a patch touches (both ends of a move), as written: the
/// permission policy and the agent's per-path side effects check each one.
string[] patchPaths(string patch) pure
{
    string[] out_;
    foreach (fp; parsePatch(patch))
    {
        out_ ~= fp.path;
        if (fp.moveTo !is null) out_ ~= fp.moveTo;
    }
    return out_;
}

/// Byte offsets just past each line that the `@@` anchor names: the line
/// equal to it, else equal ignoring surrounding whitespace, else containing it.
private size_t[] anchorHits(string text, string anchor) pure
{
    auto spans = lineSpans(text);
    auto a = anchor.strip;
    foreach (tier; 0 .. 3)
    {
        size_t[] hits;
        foreach (sp; spans)
        {
            auto l = text[sp[0] .. sp[1]];
            if (tier == 0 ? l == anchor : tier == 1 ? l.strip == a : l.indexOf(a) >= 0) hits ~= sp[2];
        }
        if (hits.length) return hits;
    }
    return null;
}

/// The hunk's expected lines, to compare with the closest candidate.
private string expectedLines(const PatchHunk h) pure
{
    string o;
    foreach (l; h.old_) o ~= "  | " ~ l ~ "\n";
    return o;
}

/// Apply one hunk to `text` (the file after the earlier hunks).
/// `endAt` is where the replaced region ended in `text`, and `newTail`
/// whether the region's last line is still followed by a line of the hunk
/// (context or added), rather than removed, so the caller can track the
/// final terminator.
private string applyHunk(string text, const PatchHunk h, size_t n, ref string[] notes, string display,
        out size_t endAt, out bool newTail) pure
{
    auto where = format("hunk %s (patch line %s)%s", n, h.line, h.anchor.length ? format(" at `@@ %s`", h.anchor) : "");
    ToolError fail(string m) { return new ToolError(format("apply_patch: %s: %s: %s", display, where, m)); }
    auto oldT = h.old_.length ? h.old_.join("\n") ~ "\n" : "";
    auto newT = h.new_.length ? h.new_.join("\n") ~ "\n" : "";
    size_t[] bases = [0];
    if (h.anchor.length)
    {
        bases = anchorHits(text, h.anchor);
        if (!bases.length) throw fail("the anchor line was not found" ~ nearMiss(text, h.anchor));
    }
    if (h.eof && h.old_.length)
    {
        // `*** End of File`: only the file's last lines can match, and they
        // must still lie after an anchor line when the hunk names one.
        auto spans = lineSpans(text);
        if (spans.length < h.old_.length)
            throw fail("marked `*** End of File` but the file has fewer lines than the hunk expects");
        auto start = spans[spans.length - h.old_.length][0];
        if (!bases.any!(b => b <= start))
            throw fail("marked `*** End of File` but the file's last lines are not after the anchor line");
        bases = [start];
    }
    if (oldT.length == 0)
    {
        // Pure insertion: after the anchor line, else at the end of the file.
        if (bases.length > 1)
            throw fail(format("the anchor matches %s lines (%s, %s, ...) and the hunk has no context lines to tell them apart",
                    bases.length, lineAt(text, bases[0]) - 1, lineAt(text, bases[1]) - 1));
        auto at = h.anchor.length && !h.eof ? bases[0] : text.length;
        auto ins = toEndingsAt(text, at, at, newT);
        endAt = at;
        newTail = ins.length > 0;
        return text[0 .. at] ~ ins ~ text[at .. $];
    }
    Located found;
    bool have;
    string firstError;
    foreach (b; bases)
    {
        Located f;
        try f = locate(text[b .. $], oldT, newT, false, true);
        catch (ToolError e)
        {
            // Only a miss lets another anchor line try; an ambiguity after
            // this anchor is an error even if a later anchor is unique.
            if (!e.msg.startsWith("old_string not found"))
                throw fail(e.msg.replace(" or set replace_all", "").replace("new_string", "the hunk").replace("old_string", "the hunk"));
            if (firstError is null) firstError = e.msg;
            continue;
        }
        foreach (ref r; f.ranges) r = [r[0] + b, r[1] + b];
        if (!have) { found = f; have = true; }
        else if (found.ranges != f.ranges)
            throw fail(format("the hunk matches after more than one anchor line (lines %s and %s); add context lines to make it unique",
                    lineAt(text, found.ranges[0][0]), lineAt(text, f.ranges[0][0])));
    }
    if (!have)
    {
        if (firstError.startsWith("old_string not found"))
            throw fail("the context and '-' lines were not found" ~ nearMiss(text, oldT) ~ "\nThe hunk expects:\n" ~ expectedLines(h));
        throw fail(firstError.replace(" or set replace_all", "").replace("new_string", "the hunk").replace("old_string", "the hunk"));
    }
    auto r = found.ranges[0];
    if (h.eof && r[1] != text.length)
        throw fail(format("marked `*** End of File` but matches at line %s, not at the end of the file", lineAt(text, r[0])));
    if (found.how.length) notes ~= format("%s: %s matched %s", display, where, found.how);
    endAt = r[1];
    // Whether the replaced region still ends with a line of the hunk
    // (context or added) rather than a removal — taken from the hunk's last
    // operation as parsed, never inferred from the line arrays or resulting
    // text: `-a -b +A` and `-a +A -b` have identical arrays but differ here.
    newTail = h.lastOp != '-';
    return text[0 .. r[0]] ~ found.news[0] ~ text[r[1] .. $];
}

/// Apply an update's hunks in order, each to the result of the ones before.
string applyHunks(string text, const PatchHunk[] hunks, ref string[] notes, string display) pure
{
    // Work on text with a final newline so the last line matches like any other.
    // The synthetic terminator follows the file's convention, and is tracked
    // through the hunks: a hunk that deletes the last lines takes it along and
    // exposes an original terminator, which must then stay.
    bool hadNl = text.length == 0 || text.endsWith("\n");
    auto f = text.indexOf('\n');
    auto term = f > 0 && text[f - 1] == '\r' ? "\r\n" : "\n";
    auto work = hadNl ? text : text ~ term;
    bool synthetic = !hadNl;
    foreach (n, h; hunks)
    {
        auto len = work.length;
        size_t endAt;
        bool newTail;
        work = applyHunk(work, h, n + 1, notes, display, endAt, newTail);
        if (synthetic && endAt == len) synthetic = newTail;
    }
    if (synthetic && work.endsWith(term)) work = work[0 .. $ - term.length];
    return work;
}

/// A unified diff of `a` -> `b` with three lines of context.
string unifiedDiff(string from, string to, string a, string b) pure
{
    // A final line with no newline compares unequal to the same text with
    // one: it carries a `\n` (which no line contains) and is printed with
    // the standard `\ No newline at end of file` marker. Carriage returns
    // stay on their lines: a CRLF line and its LF twin differ, and the diff
    // keeps the endings each side had.
    enum noEol = "\n";
    string[] keyed(string s)
    {
        auto ls = s.split("\n");
        if (ls.length && ls[$ - 1].length == 0) ls = ls[0 .. $ - 1];
        if (ls.length && !s.endsWith("\n")) ls[$ - 1] = ls[$ - 1] ~ noEol;
        return ls;
    }
    auto x = keyed(a), y = keyed(b);
    size_t pre;
    while (pre < x.length && pre < y.length && x[pre] == y[pre]) pre++;
    size_t suf;
    while (suf < x.length - pre && suf < y.length - pre && x[$ - 1 - suf] == y[$ - 1 - suf]) suf++;
    auto xm = x[pre .. $ - suf], ym = y[pre .. $ - suf];
    char[] tags;
    string[] text;
    void op(char t, string l) { tags ~= t; text ~= l; }
    foreach (l; x[0 .. pre]) op(' ', l);
    enum maxCells = 4_000_000;
    if (xm.length && ym.length && xm.length * ym.length <= maxCells)
    {
        // Longest common subsequence of the differing middle.
        auto w = ym.length + 1;
        auto dp = new uint[(xm.length + 1) * w];
        foreach_reverse (i; 0 .. xm.length)
            foreach_reverse (j; 0 .. ym.length)
                dp[i * w + j] = xm[i] == ym[j] ? dp[(i + 1) * w + j + 1] + 1 : max(dp[(i + 1) * w + j], dp[i * w + j + 1]);
        size_t i, j;
        while (i < xm.length && j < ym.length)
        {
            if (xm[i] == ym[j]) { op(' ', xm[i]); i++; j++; }
            else if (dp[(i + 1) * w + j] >= dp[i * w + j + 1]) op('-', xm[i++]);
            else op('+', ym[j++]);
        }
        foreach (l; xm[i .. $]) op('-', l);
        foreach (l; ym[j .. $]) op('+', l);
    }
    else
    {
        foreach (l; xm) op('-', l);
        foreach (l; ym) op('+', l);
    }
    foreach (l; x[$ - suf .. $]) op(' ', l);
    string out_ = format("--- %s\n+++ %s\n", from, to);
    enum ctx = 3;
    size_t k;
    while (k < tags.length)
    {
        while (k < tags.length && tags[k] == ' ') k++;
        if (k == tags.length) break;
        auto s = saturatingSub(k, ctx);
        auto e = k;
        // Extend over changes separated by at most 2 * ctx unchanged lines.
        for (;;)
        {
            while (e < tags.length && tags[e] != ' ') e++;
            auto next = e;
            while (next < tags.length && tags[next] == ' ') next++;
            if (next < tags.length && next - e <= 2 * ctx) { e = next; continue; }
            break;
        }
        auto stop = min(e + ctx, tags.length);
        size_t oldStart = 1, newStart = 1, oldN, newN;
        foreach (t; tags[0 .. s]) { if (t != '+') oldStart++; if (t != '-') newStart++; }
        foreach (t; tags[s .. stop]) { if (t != '+') oldN++; if (t != '-') newN++; }
        out_ ~= format("@@ -%s,%s +%s,%s @@\n", oldN ? oldStart : oldStart - 1, oldN, newN ? newStart : newStart - 1, newN);
        foreach (idx; s .. stop)
            out_ ~= text[idx].endsWith(noEol)
                ? tags[idx] ~ text[idx][0 .. $ - noEol.length] ~ "\n\\ No newline at end of file\n"
                : tags[idx] ~ text[idx] ~ "\n";
        k = stop;
    }
    return out_;
}

/// What a patch does to one path, staged in memory until every hunk applied.
private struct Staged
{
    string path; /// resolved
    string display; /// as shown in the result
    bool existed; /// on disk before the patch
    const(ubyte)[] before; /// its bytes then
    bool present; /// after the patch
    bool changed;
    string after; /// the content after the patch, when present and changed
    size_t movedFrom = size_t.max; /// index of the move's source (max: none)
    size_t origin = size_t.max; /// the chain's original source index (max: this entry)
    uint mode; /// permission bits to write with (from disk, or the move's source)
    bool hasMode; /// whether `mode` is known
    uint origMode; /// the path's own permission bits before the patch, for rollback
    bool hasOrigMode; /// whether `origMode` is known
    bool binary; /// `after` holds raw bytes carried through a pure rename
    bool wasLink; /// the path was a symlink before the patch
    string linkTarget; /// its target then, to restore it on rollback
    bool recreated; /// deleted and re-added in this patch: write the entry itself, not through a link
    string pinned; /// the write target resolved at staging (through a symlink); null: resolve at commit
    bool pinnedLink; /// `pinned` came from the path's own symlink (not a symlinked parent)
}

/// One path an apply_patch call touches, as it was on disk when the
/// caller built its hook inputs from it. The tool refuses to commit unless
/// staging reads the same entry: the content it then computes is the
/// content the hooks were shown (staging is deterministic), and an edit that
/// landed while the hooks ran fails the call instead of being overwritten.
struct PatchSnapshot
{
    string path; /// resolved
    bool existed; /// an entry was there (a dangling link counts)
    bool readable; /// its bytes could be read
    const(ubyte)[] before; /// those bytes (through a symlink)
}

/// Capture every path `patch` touches (sources and move destinations), once
/// each by resolved path, before any hook runs. Throws ToolError when the
/// patch doesn't parse.
PatchSnapshot[] patchOriginals(string patch)
{
    PatchSnapshot[] out_;
    bool[string] seen;
    foreach (raw; patchPaths(patch))
    {
        auto path = resolvePath(raw);
        if (path in seen) continue;
        seen[path] = true;
        PatchSnapshot ps;
        ps.path = path;
        ps.existed = linkPresent(path);
        if (ps.existed && !(path.exists && path.isDir))
        {
            try { ps.before = readBytes(path); ps.readable = true; }
            catch (FileException) {} // staging fails the same way and writes nothing
        }
        out_ ~= ps;
    }
    return out_;
}

/// The apply_patch handler's shape: the tool's arguments plus the staged
/// contents its hooks approved (null: stage from disk, with freshness checks).
alias PatchHandler = string delegate(JSONValue args, PatchSnapshot[] originals);

/// `path` relative to the working directory when inside it.
private string displayPath(string path)
{
    auto cwd = getcwd;
    return path.startsWith(cwd ~ "/") ? path[cwd.length + 1 .. $] : path;
}

private string writeTarget(string path)
{
    if (!isLink(path)) return path;
    auto r = realPath(path);
    return r !is null ? r : path;
}

/// The file a staged entry's write lands on: the target resolved (and
/// permission-checked) at staging when there is one; otherwise through a
/// symlink, and through symlinked parent directories of a new file. Deletes
/// act on the entry itself.
private string effectiveTarget(const ref Staged s)
{
    if (!s.present || s.recreated) return s.path;
    if (s.pinned !is null) return s.pinned;
    auto t = writeTarget(s.path);
    if (t != s.path) return t;
    auto r = realPath(s.path);
    if (r !is null) return r;
    auto d = realPath(s.path.dirName);
    return d !is null ? buildPath(d, s.path.baseName) : s.path;
}

/// Fail unless `s`'s path still holds what was staged from it: absent, or
/// the same bytes. Run before any write and again just before each mutation.
/// A symlink staged as one is compared by entry identity and target, not by
/// its referent's bytes: the referent may have been deleted by this patch's
/// own earlier commit (a dangling link is still the unchanged entry), and a
/// retargeted link must fail even when its new target holds identical bytes.
private void checkUnchanged(const ref Staged s)
{
    if (!s.existed)
    {
        if (linkPresent(s.path))
            throw new ToolError(format("apply_patch: %s was created while the patch was being prepared", s.display));
        return;
    }
    if (s.wasLink)
    {
        string current;
        try current = readLink(s.path);
        catch (FileException e)
            throw new ToolError(format("apply_patch: re-read %s: %s", s.display, e.msg));
        if (current != s.linkTarget)
            throw new ToolError(format("apply_patch: %s changed while the patch was being prepared", s.display));
        // Deleting or recreating the entry needs only its identity (the
        // referent may be gone, deleted by this patch). An update writes
        // through the link, so the referent's bytes must be unchanged too.
        if (!s.present || s.recreated) return;
    }
    ubyte[] current;
    try current = readBytes(s.path);
    catch (FileException e) throw new ToolError(format("apply_patch: re-read %s: %s", s.display, e.msg));
    if (current != s.before)
        throw new ToolError(format("apply_patch: %s changed while the patch was being prepared", s.display));
}

/// Remove a leftover temp file, best effort: the error that left it is reported.
private void dropTemp(string tmp)
{
    if (tmp is null || !linkPresent(tmp)) return;
    try remove(tmp);
    catch (FileException) {} // best effort: the caller reports the original error
}

/// Undo one committed entry, unless something else changed it since. A write
/// that went through a symlink is restored to the same pinned target it
/// landed on, never to a freshly re-resolved one.
private void rollBack(const ref Staged s)
{
    if (!s.present)
    {
        if (!s.existed || linkPresent(s.path)) return; // recreated meanwhile: leave it
        if (s.wasLink) { symlink(s.linkTarget, s.path); return; }
        auto tmp = writeTemp(s.path.dirName, s.path.baseName, s.before, s.hasOrigMode ? s.origMode : newFileMode);
        rename(tmp, s.path);
        return;
    }
    auto target = s.recreated ? s.path : (s.pinned !is null ? s.pinned : writeTarget(s.path));
    ubyte[] current;
    try current = readBytes(target);
    catch (FileException) return;
    if (current != s.after.representation) return; // edited since we wrote it: keep that edit
    if (!s.existed) { remove(s.path); return; }
    if (s.recreated && s.wasLink) { remove(s.path); symlink(s.linkTarget, s.path); return; }
    auto tmp = writeTemp(target.dirName, target.baseName, s.before, s.hasOrigMode ? s.origMode : newFileMode);
    rename(tmp, target);
}

/// Test seam: runs just before a failed commit rolls back, so a test can
/// make the restoration itself fail.
version (unittest) private void delegate() beforeRollbackForTest;
/// Test seam: runs before commit entry `i` is re-checked and written.
version (unittest) private void delegate(size_t i) beforeEntryForTest;

/// Write the staged changes. Every target is re-checked against what was
/// staged before anything is written and again just before its own write or
/// delete; a mutation that then fails rolls back the ones before it. The
/// rollback runs in the `catch` that formats the failure, so the message
/// already knows whether restoration worked.
private void commitStaged(Staged[] staged, ReadState state)
{
    foreach (ref s; staged)
        if (s.changed)
        {
            try checkUnchanged(s);
            catch (ToolError e) throw new ToolError(e.msg ~ "; nothing was written");
        }
    size_t done;
    string[] madeDirs; /// directories this commit created, to remove on rollback
    string[] unrolled; /// paths whose rollback failed, reported with the error
    // Undo writes first, then remove the directories they needed, and only
    // then restore deleted entries, whose paths those directories may hold.
    void rollback()
    {
        version (unittest) if (beforeRollbackForTest !is null) beforeRollbackForTest();
        void undo(bool writes)
        {
            foreach_reverse (ref s; staged[0 .. done])
            {
                if (!s.changed || s.present != writes) continue;
                try rollBack(s);
                catch (FileException e)
                    unrolled ~= format("%s (%s)", s.display, e.msg);
            }
        }
        undo(true);
        foreach (d; madeDirs.sort!((a, b) => a.length > b.length))
        {
            try rmdir(d);
            catch (FileException) {} // not empty (someone else's file) or gone: leave it
        }
        undo(false);
    }
    string undone()
    {
        // Claim a rollback only when restoration actually succeeded.
        return unrolled.length
            ? format("; ROLLBACK FAILED for %s; the tree is partially modified", unrolled.join(", "))
            : " (earlier changes were rolled back)";
    }
    ToolError failed;
    foreach (i, ref s; staged)
    {
        // A failed entry is not committed: never roll it back as if it were.
        scope (success) if (failed is null) done = i + 1;
        if (!s.changed) continue;
        if (!s.present && !s.existed) continue;
        version (unittest) if (beforeEntryForTest !is null) beforeEntryForTest(i);
        try
        {
            checkUnchanged(s);
            if (!s.present)
            {
                try remove(s.path);
                catch (FileException e) throw new ToolError(format("apply_patch: delete %s: %s", s.display, e.msg));
                continue;
            }
            // A deleted-then-recreated symlink is replaced, not followed: the
            // entry the patch deleted is gone, so the rename lands on its path.
            // A plain update writes to the target resolved (and permission-
            // checked) at staging, never to a freshly re-resolved link.
            auto path = s.recreated ? s.path : (s.pinned !is null ? s.pinned : writeTarget(s.path));
            for (auto d = path.dirName; !linkPresent(d) && d != d.dirName; d = d.dirName) madeDirs ~= d;
            try mkdirRecurse(path.dirName);
            catch (FileException e) throw new ToolError(format("apply_patch: create %s: %s", path.dirName, e.msg));
            string tmp;
            try
            {
                uint mode = newFileMode;
                if (s.hasMode) mode = s.mode;
                else if (statMode(path, mode)) mode &= octal!7777;
                else mode = newFileMode;
                tmp = writeTemp(path.dirName, path.baseName, s.after.representation, mode);
                // The last moment to notice a concurrent edit before replacing it.
                checkUnchanged(s);
                rename(tmp, path);
            }
            catch (ToolError e)
            {
                dropTemp(tmp);
                throw e;
            }
            catch (FileException e)
            {
                dropTemp(tmp);
                throw new ToolError(format("apply_patch: write %s: %s", s.display, e.msg));
            }
        }
        catch (ToolError e)
        {
            failed = e;
            break;
        }
    }
    if (failed !is null)
    {
        rollback();
        throw new ToolError(failed.msg ~ undone());
    }
    foreach (ref s; staged)
        if (s.changed)
        {
            if (s.present) state.record(s.path, s.after);
            else state.forget(s.path);
        }
}

string applyPatch(JSONValue args, ReadState state, PatchSnapshot[] originals = null)
{
    auto patch = requireString(args, "patch", "apply_patch");
    auto dry = optBool(args, "dry_run", false);
    auto files = parsePatch(patch);
    Staged[] staged;
    size_t[string] index;
    size_t at(string raw)
    {
        auto path = resolvePath(raw);
        if (auto k = path in index) return *k;
        Staged s;
        s.path = path;
        s.display = displayPath(path);
        if (linkPresent(path))
        {
            if (path.exists && path.isDir) throw new ToolError(format("apply_patch: %s is a directory", s.display));
            ubyte[] bytes;
            try bytes = readBytes(path);
            catch (FileException e) throw new ToolError(format("apply_patch: read %s: %s", s.display, e.msg));
            if (state.staleRead(path, bytes))
                throw new ToolError(format("apply_patch: %s has changed since it was last read (by a command, a tool or the user); "
                        ~ "read it again before patching it", s.display));
            s.existed = s.present = true;
            s.before = bytes;
            if (isLink(path))
            {
                s.wasLink = true;
                try s.linkTarget = readLink(path);
                catch (FileException e) throw new ToolError(format("apply_patch: read link %s: %s", s.display, e.msg));
                // Pin the write target the path's permissions were checked
                // against: a link retargeted after staging must fail the
                // freshness check, not redirect the write (or its rollback)
                // to a file nobody approved.
                s.pinned = writeTarget(path);
                s.pinnedLink = s.pinned != path;
            }
            uint mode;
            if (statMode(path, mode))
            {
                s.mode = s.origMode = mode & octal!7777;
                s.hasMode = s.hasOrigMode = true;
            }
        }
        index[path] = staged.length;
        staged ~= s;
        return staged.length - 1;
    }
    // The original as text for a diff, or null when it isn't UTF-8 (a
    // Delete/Add or a move needs no matching, so a binary original is fine).
    bool originalText(size_t k, out string t)
    {
        import std.utf : UTFException;
        try t = utf8Text(staged[k].before);
        catch (UTFException) return false;
        return true;
    }
    string original(size_t k)
    {
        import std.utf : UTFException;
        try return utf8Text(staged[k].before);
        catch (UTFException) throw new ToolError(format("apply_patch: %s is not valid UTF-8", staged[k].display));
    }
    string[] notes;
    foreach (fp; files)
    {
        auto k = at(fp.path);
        final switch (fp.kind)
        {
        case PatchKind.add:
            if (staged[k].present)
                throw new ToolError(format("apply_patch: Add File %s: it already exists; use Update File to change it", staged[k].display));
            if (staged[k].existed) staged[k].recreated = true; // deleted earlier in this patch
            staged[k].present = staged[k].changed = true;
            staged[k].after = fp.content;
            break;
        case PatchKind.delete_:
            if (!staged[k].present) throw new ToolError(format("apply_patch: Delete File %s: it does not exist", staged[k].display));
            staged[k].present = false;
            staged[k].changed = true;
            staged[k].after = null;
            break;
        case PatchKind.update:
            if (!staged[k].present)
                throw new ToolError(format("apply_patch: Update File %s: it does not exist; use Add File to create it", staged[k].display));
            // A pure rename carries the bytes through untouched, so a binary file moves too.
            immutable rawMove = fp.moveTo !is null && fp.hunks.length == 0 && !staged[k].changed;
            auto updated = rawMove ? ownText(staged[k].before.dup)
                : applyHunks(staged[k].changed ? staged[k].after : original(k), fp.hunks, notes, staged[k].display);
            if (fp.moveTo is null)
            {
                staged[k].after = updated;
                staged[k].changed = true;
                break;
            }
            auto d = at(fp.moveTo);
            if (d == k) throw new ToolError(format("apply_patch: Move File %s: the source and destination are the same", staged[k].display));
            if (staged[d].present)
                throw new ToolError(format("apply_patch: Move File %s -> %s: the destination already exists", staged[k].display, staged[d].display));
            staged[k].present = false;
            staged[k].changed = true;
            staged[k].after = null;
            if (staged[d].existed) staged[d].recreated = true; // deleted earlier in this patch
            staged[d].present = staged[d].changed = true;
            staged[d].after = updated;
            staged[d].movedFrom = k;
            // Provenance follows the chain: a move of a move still diffs and
            // reports against the original source, not the intermediate name.
            staged[d].origin = staged[k].origin != size_t.max ? staged[k].origin : k;
            staged[d].mode = staged[k].mode;
            staged[d].hasMode = staged[k].hasMode;
            if (rawMove)
            {
                import std.utf : validate, UTFException;
                try validate(updated);
                catch (UTFException) staged[d].binary = true;
            }
            break;
        }
    }
    // The caller built its hook inputs from `originals`: commit only if
    // staging read exactly those entries, so the content written is the
    // content the hooks approved, and an edit made while they ran is never
    // overwritten. Every path is checked, repeated or not.
    if (!dry)
        foreach (ps; originals)
        {
            auto k = resolvePath(ps.path) in index;
            if (k is null)
                throw new ToolError(format("apply_patch: %s is not part of the patch; nothing was written", displayPath(ps.path)));
            auto st = &staged[*k];
            if (st.existed != ps.existed || (st.existed && (!ps.readable || st.before != ps.before)))
                throw new ToolError(format("apply_patch: %s changed while the patch's hooks ran; nothing was written. "
                        ~ "Read it again before patching it", st.display));
        }
    // Two entries that write the same file (a path and a symlink to it) would
    // each be staged from the original bytes, and the second write would
    // silently drop the first one's edit.
    {
        size_t[string] owner;
        foreach (k, ref s; staged)
        {
            if (!s.changed || (!s.present && !s.existed)) continue;
            auto key = effectiveTarget(s);
            if (auto o = key in owner)
                if (staged[*o].present || s.present)
                    throw new ToolError(format("apply_patch: %s and %s are the same file; change it through one path only",
                            staged[*o].display, s.display));
            owner[key] = k;
        }
    }
    // The summary and diff. A move shows as one rename of its original
    // source, even across a chain of moves.
    auto movedAway = new bool[staged.length];
    foreach (ref s; staged) if (s.present && s.origin != size_t.max) movedAway[s.origin] = true;
    string summary, diff;
    size_t changedFiles;
    foreach (k, ref s; staged)
    {
        if (!s.changed || (!s.existed && !s.present)) continue;
        if (!s.present && movedAway[k]) continue;
        // Unchanged in place. A move destination never is: its source goes.
        // Nor is a symlink replaced by a regular file with the same bytes.
        if (s.present && s.existed && s.movedFrom == size_t.max && !(s.recreated && s.wasLink) && s.after.representation == s.before) continue;
        changedFiles++;
        if (s.present && s.movedFrom != size_t.max)
        {
            auto o = s.origin != size_t.max ? s.origin : s.movedFrom;
            auto src = staged[o].display;
            summary ~= format("  R %s -> %s\n", src, s.display);
            if (s.binary)
            {
                diff ~= format("--- a/%s\n+++ b/%s\n(binary; renamed)\n", src, s.display);
                continue;
            }
            string before;
            if (staged[o].existed && !originalText(o, before))
            {
                diff ~= format("--- a/%s\n+++ b/%s\n(binary; renamed and replaced)\n", src, s.display);
                continue;
            }
            auto d = unifiedDiff("a/" ~ src, "b/" ~ s.display, before, s.after);
            diff ~= d.count('\n') > 2 ? d : d ~ "(renamed; content unchanged)\n";
        }
        else if (!s.present)
        {
            summary ~= format("  D %s\n", s.display);
            // A delete needs no matching, so a binary file may go too.
            string before;
            diff ~= originalText(k, before) ? unifiedDiff("a/" ~ s.display, "/dev/null", before, "")
                : format("--- a/%s\n+++ /dev/null\n(binary; deleted)\n", s.display);
        }
        else if (!s.existed)
        {
            summary ~= format("  A %s\n", s.display);
            diff ~= unifiedDiff("/dev/null", "b/" ~ s.display, "", s.after);
        }
        else
        {
            summary ~= format("  M %s\n", s.display);
            string before;
            diff ~= originalText(k, before) ? unifiedDiff("a/" ~ s.display, "b/" ~ s.display, before, s.after)
                : format("--- a/%s\n+++ b/%s\n(binary; replaced)\n", s.display, s.display);
        }
    }
    if (!dry) commitStaged(staged, state);
    auto head = dry ? format("Dry run: the patch applies cleanly; nothing was written. It would change %s file(s):\n", changedFiles)
        : format("Applied patch to %s file(s):\n", changedFiles);
    auto noteText = notes.length ? "\n" ~ notes.join("\n") ~ "\n" : "";
    return head ~ summary ~ noteText ~ "\n" ~ diff;
}

/// read_file runs on a worker thread; what it read is recorded on the
/// agent's thread afterwards. The receipt is the content's SHA-256, then the
/// path. A failed read records nothing (its receipt is empty).
Concurrency readConcurrency(ReadState state)
{
    static JobResult work(string argsJson, immutable(string)[] context)
    {
        import std.string : representation;
        immutable(ubyte)[] receipt;
        auto text = readFile(parseJSON(argsJson), (string path, const(ubyte)[] data) {
            receipt = sha256Of(data).idup ~ path.representation;
        });
        return JobResult(text, false, false, receipt);
    }
    Concurrency c;
    c.readOnly = true;
    c.offload = (JSONValue a) => Job(&work, a.jsonText, null);
    c.settle = (const ref JobResult r) {
        if (r.receipt.length < 32) return;
        ubyte[32] d = r.receipt[0 .. 32];
        state.recordDigest(utf8Text(r.receipt[32 .. $]), d);
    };
    return c;
}

void register(ToolRegistry tools, ReadState state)
{
    tools.register(ToolDefinition("read_file",
        "Read a file. Text files return numbered lines; use offset/limit to page through large ones (pagination applies to text only). "
        ~ "Image files (PNG, JPEG, GIF, WebP) are returned to vision-capable models as viewable images.",
        parseJSON(`{"type":"object","properties":{
            "path":{"type":"string","description":"File path, absolute or relative to the working directory"},
            "offset":{"type":"integer","description":"1-based first line to return (text files only, default 1)"},
            "limit":{"type":"integer","description":"Maximum number of lines (text files only, default 2000)"}},
            "required":["path"]}`)),
        (JSONValue a) => readFile(a, state), readConcurrency(state));
    tools.register(ToolDefinition("write_file",
        "Create a file, or overwrite one you have read, creating parent directories. Prefer edit_file (one change) or apply_patch (several) for changes to existing files.",
        parseJSON(`{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}`)),
        (JSONValue a) => writeFile(a, state));
    tools.register(ToolDefinition("edit_file",
        "Replace text in a file you have read (read it again if it changed since). old_string must match exactly once unless replace_all is true; "
        ~ "if there is no exact match, a unique match ignoring trailing whitespace or indentation is used. Returns the edited lines with context. "
        ~ "Best for one surgical edit; for changes in several places or files, use apply_patch.",
        parseJSON(`{"type":"object","properties":{
            "path":{"type":"string"},
            "old_string":{"type":"string","description":"Exact text to replace, including whitespace"},
            "new_string":{"type":"string"},
            "replace_all":{"type":"boolean","description":"Replace every occurrence (default false)"}},
            "required":["path","old_string","new_string"]}`)),
        (JSONValue a) => editFile(a, state));
    tools.register(ToolDefinition("apply_patch",
        "Apply a patch that changes one or more files at once, atomically: every hunk must apply or nothing is written. "
        ~ "Use it for multi-location or multi-file changes (and to add, delete or move files); use edit_file for a single surgical edit. "
        ~ "Format (no line numbers; hunks are anchored by content):\n"
        ~ "*** Begin Patch\n*** Update File: src/a.d\n@@ void run(\n context line\n-removed line\n+added line\n context line\n"
        ~ "*** Add File: src/b.d\n+every line of the new file, prefixed with +\n*** Delete File: old.sh\n"
        ~ "*** Move File: from.d -> to.d\n*** End Patch\n"
        ~ "An `@@` line names a nearby line (e.g. a signature) to narrow the search; `@@` alone is allowed. Each hunk needs a few "
        ~ "unchanged context lines and must match exactly one place (trailing whitespace, then indentation, are relaxed if needed); "
        ~ "hunks apply in order, each to the file as the earlier ones left it. A move may be followed by hunks. "
        ~ "Returns the applied unified diff; dry_run returns it without writing.",
        parseJSON(`{"type":"object","properties":{
            "patch":{"type":"string","description":"The patch, from *** Begin Patch to *** End Patch"},
            "dry_run":{"type":"boolean","description":"Check the patch and return its diff without writing anything (default false)"}},
            "required":["patch"]}`)),
        (JSONValue a) => applyPatch(a, state));
    // The richer shape, for callers that carry the hook-approved staged
    // contents into the commit (see PatchHandler).
    tools.registerHandler!PatchHandler("apply_patch", (JSONValue a, PatchSnapshot[] originals) => applyPatch(a, state, originals));
}

version (unittest)
{
    private string tmpFile(string name, string content)
    {
        import std.path : buildPath;
        auto dir = buildPath(tempDir, "nano-coder-files-test");
        mkdirRecurse(dir);
        auto p = buildPath(dir, name);
        if (content !is null) write(p, content);
        else if (p.exists) remove(p);
        return p;
    }

    private JSONValue j(T...)(T kv) pure
    {
        JSONValue o = JSONValue(string[string].init);
        static foreach (i; 0 .. T.length / 2) o[kv[2 * i]] = kv[2 * i + 1];
        return o;
    }
}

version (unittest)
{
    /// A file with `content`, already read (so edits are allowed).
    private string fixture(ReadState st, string name, string content)
    {
        auto p = tmpFile(name, content);
        readFile(j("path", p), st);
        return p;
    }

    private string editErr(T...)(ReadState st, T kv)
    {
        try editFile(j(kv), st);
        catch (ToolError e) return e.msg;
        assert(false, "edit should have failed");
    }

    private bool tempPresent(string path)
    {
        // A long basename is truncated in the temp name (see writeTemp), so
        // match the truncated prefix too.
        auto base = path.baseName;
        enum maxBase = 240 - 20 - 10;
        if (base.length > maxBase) base = base[$ - maxBase .. $];
        auto prefix = "." ~ base ~ ".tmp-";
        foreach (e; dirEntries(path.dirName, SpanMode.shallow))
            if (e.name.baseName.startsWith(prefix)) return true;
        return false;
    }
}

// rust: files.rs::read_pages_with_line_numbers
unittest
{
    auto st = new ReadState;
    auto p = tmpFile("a.txt", "one\ntwo\nthree\n");
    auto all = readFile(j("path", p), st);
    assert(all.indexOf("     1\tone\n") >= 0 && all.indexOf("     3\tthree\n") >= 0);
    auto page = readFile(j("path", p, "offset", 2, "limit", 1), st);
    assert(page.indexOf("     2\ttwo\n") == 0 && page.indexOf("use offset=3") > 0);
    bool threw;
    try readFile(j("path", p, "offset", 9), st); catch (ToolError) threw = true;
    assert(threw);
}

// rust: files.rs::write_creates_parents_and_edit_requires_unique_match
unittest
{
    auto st = new ReadState;
    auto p = tmpFile("nested/dir/c.txt", null);
    assert(writeFile(j("path", p, "content", "a b a\n"), st).startsWith("Created"));
    assert(editErr(st, "path", p, "old_string", "a", "new_string", "x").indexOf("occurs 2 times") >= 0);
    editFile(j("path", p, "old_string", "a b", "new_string", "z b"), st);
    assert(readText(p) == "z b a\n");
    editFile(j("path", p, "old_string", "a", "new_string", "q", "replace_all", true), st);
    assert(readText(p) == "z b q\n");
    editErr(st, "path", p, "old_string", "nope", "new_string", "x");
    assert(writeFile(j("path", p, "content", "new"), st).startsWith("Overwrote"));
}

// rust: files.rs::edits_and_overwrites_require_a_current_read
// rust: files.rs::edit_fails_when_file_changes_mid_call
unittest
{
    auto st = new ReadState;
    auto p = tmpFile("s.txt", "one\n");
    assert(editErr(st, "path", p, "old_string", "one", "new_string", "two").indexOf("has not been read") >= 0);
    bool threw;
    try writeFile(j("path", p, "content", "x"), st); catch (ToolError e) threw = e.msg.indexOf("has not been read") >= 0;
    assert(threw);
    readFile(j("path", p), st);
    write(p, "one\nmore\n");
    assert(editErr(st, "path", p, "old_string", "one", "new_string", "two").indexOf("changed since it was last read") >= 0);
    assert(readText(p) == "one\nmore\n");
    readFile(j("path", p), st);
    editFile(j("path", p, "old_string", "one", "new_string", "two"), st);
    editFile(j("path", p, "old_string", "more", "new_string", "less"), st);
    writeFile(j("path", p, "content", "replaced\n"), st);
    assert(readText(p) == "replaced\n");
}

// rust: files.rs::a_failed_read_does_not_authorize_edits
unittest
{
    auto st = new ReadState;
    auto p = tmpFile("f.txt", "one\ntwo\n");
    bool threw;
    try readFile(j("path", p, "offset", 99), st); catch (ToolError) threw = true;
    assert(threw);
    assert(editErr(st, "path", p, "old_string", "one", "new_string", "x").indexOf("has not been read") >= 0);
}

// rust: files.rs::edit_matches_crlf_files_as_read
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "w.txt", "a\r\nb\r\nc\r\n");
    editFile(j("path", p, "old_string", "a\nb", "new_string", "x\ny"), st);
    assert(readText(p) == "x\r\ny\r\nc\r\n");
}

// rust: files.rs::relaxed_matches_ignore_whitespace_and_line_numbers
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "r.py", "def f():\n    x = 1  \n    return x\n");
    auto out_ = editFile(j("path", p, "old_string", "    x = 1\n", "new_string", "    x = 2\n"), st);
    assert(out_.indexOf("ignoring trailing whitespace") >= 0, out_);
    assert(readText(p) == "def f():\n    x = 2\n    return x\n");
    out_ = editFile(j("path", p, "old_string", "x = 2\nreturn x", "new_string", "x = 3\nif x:\n    return x"), st);
    assert(out_.indexOf("ignoring indentation") >= 0, out_);
    assert(readText(p) == "def f():\n    x = 3\n    if x:\n        return x\n", readText(p));
    out_ = editFile(j("path", p, "old_string", "     2\t    x = 3", "new_string", "    x = 4"), st);
    assert(out_.indexOf("line numbers") >= 0, out_);
    assert(readText(p).indexOf("    x = 4\n") >= 0);
}

// rust: files.rs::relaxed_matches_must_be_unique
unittest
{
    auto st = new ReadState;
    auto body_ = "fn a() {\n    ok()\n}\nfn b() {\n  ok()\n}\n";
    auto p = fixture(st, "u.rs", body_);
    assert(editErr(st, "path", p, "old_string", "ok()", "new_string", "no()").indexOf("occurs 2 times") >= 0);
    auto e = editErr(st, "path", p, "old_string", "\tok()\n", "new_string", "\tno()\n");
    assert(e.indexOf("matches 2 places (ignoring indentation)") >= 0, e);
    assert(readText(p) == body_);
}

// rust: files.rs::a_miss_shows_the_closest_lines
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "m.rs", "fn main() {\n    let x = 1;\n    println!(\"{x}\");\n}\n");
    auto e = editErr(st, "path", p, "old_string", "let x = 1;\nprintln!(\"{y}\");", "new_string", "z");
    assert(e.indexOf("not found") >= 0, e);
    assert(e.indexOf("Closest match (1 of 2 lines agree), lines 2-3") >= 0, e);
    assert(e.indexOf("     3\t    println!(\"{x}\");") >= 0, e);
}

// rust: files.rs::edit_result_shows_the_changed_lines_in_context
unittest
{
    auto st = new ReadState;
    string body_;
    foreach (n; 1 .. 21) body_ ~= format("line %s\n", n);
    auto p = fixture(st, "c.txt", body_);
    auto out_ = editFile(j("path", p, "old_string", "line 10\n", "new_string", "ten\nTEN\n"), st);
    assert(out_.startsWith("Replaced 1 occurrence(s) in "), out_);
    assert(out_.indexOf("     7\tline 7\n") >= 0 && out_.indexOf("    10\tten\n    11\tTEN\n") >= 0, out_);
    assert(out_.indexOf("    14\tline 13\n") >= 0 && out_.indexOf("line 14") < 0 && out_.indexOf("line 6\n") < 0, out_);
}

// rust: files.rs::reindent_shifts_lines_shallower_than_the_match
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "d.py", "if a:\n        x = 1\n    y = 2\n");
    auto out_ = editFile(j("path", p, "old_string", "    x = 1\ny = 2", "new_string", "    x = 9\ny = 9"), st);
    assert(out_.indexOf("ignoring indentation") >= 0, out_);
    assert(readText(p) == "if a:\n        x = 9\n    y = 9\n");
}

// rust: files.rs::replace_all_result_shows_every_changed_region
unittest
{
    auto st = new ReadState;
    string body_;
    foreach (n; 1 .. 31) body_ ~= n == 5 || n == 25 ? "mark\n" : format("line %s\n", n);
    auto p = fixture(st, "ra.txt", body_);
    auto out_ = editFile(j("path", p, "old_string", "mark", "new_string", "DONE", "replace_all", true), st);
    assert(out_.startsWith("Replaced 2 occurrence(s)"), out_);
    assert(out_.indexOf("     5\tDONE\n") >= 0 && out_.indexOf("    25\tDONE\n") >= 0 && out_.indexOf("   ...\n") >= 0, out_);
}

// rust: files.rs::unpadded_tsv_number_is_not_treated_as_a_line_prefix
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "t.tsv", "1\tfoo\n2\tbar\n");
    assert(editErr(st, "path", p, "old_string", "1\tfoo\nmissing", "new_string", "x").indexOf("not found") >= 0);
    assert(readText(p) == "1\tfoo\n2\tbar\n");
}

// rust: files.rs::incompatible_indentation_rejects_the_relaxed_match
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "mix.py", "def f():\n\treturn 1\n");
    auto e = editErr(st, "path", p, "old_string", "    return 1", "new_string", "    return 2");
    assert(e.indexOf("incompatible whitespace") >= 0, e);
    assert(readText(p) == "def f():\n\treturn 1\n");
}

// rust: files.rs::dedent_across_multibyte_whitespace_does_not_panic
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "u.txt", "top\n\u3000a\n\u3000b\n");
    auto out_ = editFile(j("path", p, "old_string", "\u3000 a\n\u3000 b", "new_string", "\u3000 A\n\u3000 B"), st);
    assert(out_.indexOf("ignoring indentation") >= 0, out_);
    assert(readText(p) == "top\n\u3000A\n\u3000B\n");
}

// rust: files.rs::mixed_whitespace_shift_preserves_the_common_prefix
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "mx.py", "def f():\n\tx = 1\n");
    auto out_ = editFile(j("path", p, "old_string", "\t    x = 1", "new_string", "\t    x = 2"), st);
    assert(out_.indexOf("ignoring indentation") >= 0, out_);
    assert(readText(p) == "def f():\n\tx = 2\n");
}

// rust: files.rs::mixed_whitespace_deepen_appends_delta_after_existing_indentation
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "dp.py", "if a:\n\t        x = 1\n\t      y = 2\n");
    auto out_ = editFile(j("path", p, "old_string", "\t    x = 1\n\t  y = 2", "new_string", "\t    x = 9\n\t  y = 9"), st);
    assert(out_.indexOf("ignoring indentation") >= 0, out_);
    assert(readText(p) == "if a:\n\t        x = 9\n\t      y = 9\n");
}

// rust: files.rs::single_line_match_normalizes_multiline_replacement_endings
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "crlf.txt", "a\r\nb\r\nc\r\n");
    editFile(j("path", p, "old_string", "b", "new_string", "x\ny"), st);
    assert(readText(p) == "a\r\nx\r\ny\r\nc\r\n");
}

// rust: files.rs::consecutive_tsv_numbers_do_not_retarget_an_unrelated_block
// rust: files.rs::nonconsecutive_numeric_prefixes_are_not_line_numbers
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "tsv.tsv", "foo\nbar\n");
    assert(editErr(st, "path", p, "old_string", "123456\tfoo\n123457\tbar", "new_string", "x").indexOf("not found") >= 0);
    assert(editErr(st, "path", p, "old_string", "123456\tfoo\n999999\tbar", "new_string", "x").indexOf("not found") >= 0);
    assert(readText(p) == "foo\nbar\n");
}

// rust: files.rs::replace_all_does_not_apply_to_a_stripped_relaxed_match
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "ra2.txt", "foo\nbar\nfoo\n");
    auto out_ = editFile(j("path", p, "old_string", "     1\tfoo", "new_string", "FOO", "replace_all", true), st);
    assert(out_.startsWith("Replaced 1 occurrence(s)"), out_);
    assert(readText(p) == "FOO\nbar\nfoo\n");
}

// rust: files.rs::a_misspelled_single_line_still_gets_a_closest_hint
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "sp.rs", "fn main() {\n    let value = compute();\n}\n");
    auto e = editErr(st, "path", p, "old_string", "let valeu = compute();", "new_string", "z");
    assert(e.indexOf("not found") >= 0 && e.indexOf("no lines match exactly") >= 0, e);
    assert(e.indexOf("    let value = compute();") >= 0, e);
}

// rust: files.rs::snippet_output_is_globally_capped
unittest
{
    import std.algorithm : splitter;
    import std.range : walkLength;
    auto st = new ReadState;
    string body_;
    foreach (n; 1 .. 201) body_ ~= n % 10 == 0 ? "mark\n" : format("line %s\n", n);
    auto p = fixture(st, "big.txt", body_);
    auto out_ = editFile(j("path", p, "old_string", "mark", "new_string", "DONE", "replace_all", true), st);
    assert(out_.startsWith("Replaced 20 occurrence(s)"), out_);
    assert(out_.indexOf("more edited region(s) not shown") >= 0, out_);
    assert(out_.splitter('\n').walkLength < 60, out_);
}

// rust: files.rs::overwrite_propagates_read_errors_instead_of_skipping_freshness
unittest
{
    auto st = new ReadState;
    auto sub = buildPath(tempDir, "nano-coder-files-test", "subdir");
    mkdirRecurse(sub);
    bool threw;
    try writeFile(j("path", sub, "content", "x"), st); catch (ToolError e) threw = e.msg.indexOf("read ") >= 0;
    assert(threw && sub.isDir);
}

// rust: files.rs::new_string_tsv_row_is_not_stripped_as_a_line_prefix
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "n.tsv", "abc\ndef\n");
    auto out_ = editFile(j("path", p, "old_string", "     1\tabc", "new_string", "123456\tabc"), st);
    assert(out_.indexOf("line numbers") >= 0, out_);
    assert(readText(p) == "123456\tabc\ndef\n");
}

// rust: files.rs::bare_blank_line_in_numbered_old_is_not_stripped
// rust: files.rs::numbered_old_with_prefixed_blank_line_strips_and_edits
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "b.txt", "foo\n\nbar\n");
    assert(editErr(st, "path", p, "old_string", "     1\tfoo\n\n     2\tbar", "new_string", "x").indexOf("not found") >= 0);
    assert(readText(p) == "foo\n\nbar\n");
    editFile(j("path", p, "old_string", "     1\tfoo\n     2\t\n     3\tbar", "new_string", "FOO\n\nBAR"), st);
    assert(readText(p) == "FOO\n\nBAR\n");
}

// rust: files.rs::stripped_line_number_match_must_begin_at_line_boundary
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "m.txt", "alpha\nprefix foo suffix\n");
    assert(editErr(st, "path", p, "old_string", "     2\tfoo", "new_string", "BAR").indexOf("not found") >= 0);
    assert(readText(p) == "alpha\nprefix foo suffix\n");
}

// rust: files.rs::nonuniform_indentation_rejects_the_relaxed_match
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "nu.py", "if a:\n    x = 1\n        y = 2\n");
    auto e = editErr(st, "path", p, "old_string", "    x = 1\n    y = 2", "new_string", "    x = 9\n    y = 9");
    assert(e.indexOf("non-uniformly") >= 0, e);
    assert(readText(p) == "if a:\n    x = 1\n        y = 2\n");
}

// rust: files.rs::edit_in_lf_region_of_mixed_file_keeps_lf_replacement
// rust: files.rs::edit_in_crlf_region_of_mixed_file_converts_replacement_to_crlf
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "mix.txt", "a\r\nb\nc\n");
    editFile(j("path", p, "old_string", "b\nc", "new_string", "x\ny"), st);
    assert(readText(p) == "a\r\nx\ny\n");
    auto q = fixture(st, "mix2.txt", "a\nb\r\nc\r\n");
    editFile(j("path", q, "old_string", "b\nc", "new_string", "x\ny"), st);
    assert(readText(q) == "a\nx\r\ny\r\n");
}

// rust: files.rs::prefix_shaped_new_string_in_copied_range_is_rejected
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "amb.tsv", "abc\ndef\n");
    assert(editErr(st, "path", p, "old_string", "     1\tabc", "new_string", "     1\txyz").indexOf("ambiguous") >= 0);
    assert(readText(p) == "abc\ndef\n");
}

// rust: files.rs::old_matching_both_ending_styles_is_not_treated_as_unique
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "both.txt", "a\nb\na\r\nb\r\n");
    assert(editErr(st, "path", p, "old_string", "a\nb", "new_string", "x\ny").indexOf("occurs 2 times") >= 0);
    assert(readText(p) == "a\nb\na\r\nb\r\n");
}

// rust: files.rs::replace_all_normalizes_each_occurrence_to_its_own_region
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "ra3.txt", "mark\nmark\r\n");
    editFile(j("path", p, "old_string", "mark", "new_string", "x\ny", "replace_all", true), st);
    assert(readText(p) == "x\ny\nx\r\ny\r\n", readText(p));
}

// rust: files.rs::overlapping_crlf_and_lf_ranges_are_one_occurrence
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "ov.txt", "a\r\nb");
    editFile(j("path", p, "old_string", "\nb", "new_string", "\nB", "replace_all", true), st);
    assert(readText(p) == "a\r\nB");
}

// rust: files.rs::crossing_crlf_and_lf_ranges_are_ambiguous_not_collapsed
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "cross.txt", "a\r\na\na");
    assert(editErr(st, "path", p, "old_string", "a\na", "new_string", "X", "replace_all", true).indexOf("ambiguously") >= 0);
    assert(readText(p) == "a\r\na\na");
}

// rust: files.rs::literal_prefix_shaped_row_is_edited_in_place_not_rejected
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "tsvl.txt", "     1\tabc\n");
    editFile(j("path", p, "old_string", "     1\tabc", "new_string", "     1\txyz"), st);
    assert(readText(p) == "     1\txyz\n");
}

// rust: files.rs::near_miss_qualifies_a_truncated_scan
unittest
{
    string big;
    foreach (i; 0 .. 3000) big ~= format("line%s\n", i);
    assert(nearMiss(big, "line").indexOf("scanned") >= 0);
}

// rust: files.rs::absent_target_write_refuses_to_clobber_a_concurrent_create
unittest
{
    auto st = new ReadState;
    auto p = tmpFile("race.txt", "created by someone else\n");
    bool threw;
    try writeAtomically(p, "our contents\n", Expect.none, st, "write_file");
    catch (ToolError e) threw = e.msg.indexOf("was created while") >= 0;
    assert(threw);
    assert(readText(p) == "created by someone else\n" && !tempPresent(p));
}

// rust: files.rs::failed_pre_rename_validation_removes_the_temp_file
unittest
{
    auto st = new ReadState;
    auto p = tmpFile("t.txt", "on disk\n");
    st.record(p, "on disk\n");
    bool threw;
    try writeAtomically(p, "new\n", Expect.was("planned-against\n".representation), st, "write_file");
    catch (ToolError e) threw = e.msg.indexOf("changed while") >= 0;
    assert(threw);
    assert(readText(p) == "on disk\n" && !tempPresent(p));
}

// rust: files.rs::line_number_prefix_requires_exact_six_wide_rendering
// rust: files.rs::line_number_prefix_at_u64_max_does_not_overflow
unittest
{
    assert(!stripLineNumbers("000002\tfoo\n", "bar\n").ok);
    assert(!stripLineNumbers("      2\tfoo\n", "bar\n").ok);
    auto s = stripLineNumbers("     2\tfoo\n", "bar\n");
    assert(s.ok && s.lo == 2 && s.old == "foo\n");
    assert(!stripLineNumbers("18446744073709551615\tfoo\n18446744073709551615\tbar\n", "baz\n").ok);
}

// rust: files.rs::relaxed_matching_rejects_ambiguity_across_attempts
unittest
{
    auto st = new ReadState;
    auto p = fixture(st, "amb2.txt", "     2\tfoo\nfoo\n");
    auto e = editErr(st, "path", p, "old_string", "     2\tfoo   ", "new_string", "bar");
    assert(e.indexOf("multiple distinct locations") >= 0, e);
    assert(readText(p) == "     2\tfoo\nfoo\n");
}

// rust: files.rs::writes_through_symlinks
unittest
{
    import std.file : symlink;
    auto st = new ReadState;
    auto target = tmpFile("real.txt", "old\n");
    auto link = target ~ ".link";
    if (link.exists || isLink(link)) remove(link);
    symlink(target, link);
    scope (exit) remove(link);
    readFile(j("path", link), st);
    editFile(j("path", link, "old_string", "old", "new_string", "new"), st);
    writeFile(j("path", link, "content", "newer\n"), st);
    assert(readText(target) == "newer\n");
    assert(isLink(link));
}

// rust: files.rs::read_rejects_binary
unittest
{
    auto st = new ReadState;
    auto p = tmpFile("bin.dat", "ab\0cd");
    bool threw;
    try readFile(j("path", p), st); catch (ToolError e) threw = e.msg.indexOf("binary") > 0;
    assert(threw);
}

// rust: files.rs::string_arg_distinguishes_missing_null_and_wrong_type
// rust: files.rs::read_returns_images_by_magic_bytes
// rust: files.rs::read_detects_image_despite_text_extension
// rust: files.rs::read_image_stores_absolute_source_path
// rust: files.rs::image_reads_authorize_writes_only_once_dispatched_to_the_model
unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm : canFind;
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, readText, getcwd, chdir;
    import std.process : thisProcessID;
    import std.path : isAbsolute;
    import nano.attachment : fakePng, fakeJpeg;
    import std.typecons : tuple;
    auto st = new ReadState;
    auto msg(string json) { return collectExceptionMsg(writeFile(parseJSON(json), st)); }
    assert(msg(`{"content": "x"}`).canFind(`missing required argument "path"`));
    assert(msg(`{"path": null, "content": "x"}`).canFind(`"path" is null`));
    assert(msg(`{"path": 42, "content": "x"}`).canFind("must be a string, got a number"));

    auto dir = buildPath(tempDir, format("nano-files-img-%s", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    ubyte[] gif = bytesOf("GIF89a") ~ cast(ubyte[]) [40, 0, 20, 0] ~ new ubyte[16];
    ubyte[] webp = bytesOf("RIFF\0\0\0\0WEBPVP8X") ~ new ubyte[8] ~ cast(ubyte[]) [39, 0, 0, 19, 0, 0];
    foreach (c; [tuple("a.png", fakePng(40, 20), "image/png"), tuple("a.jpg", fakeJpeg(40, 20), "image/jpeg"),
            tuple("a.gif", gif.idup, "image/gif"), tuple("a.webp", webp.idup, "image/webp"),
            tuple("misleading.txt", fakePng(8, 8), "image/png")])
    {
        auto p = buildPath(dir, c[0]);
        write(p, c[1]);
        auto img = parseJSON(readFile(JSONValue(["path": p]), st))["image"];
        assert(img["media_type"].str == c[2], c[0]);
        if (c[0] != "misleading.txt") assert(img["width"].integer == 40 && img["height"].integer == 20, c[0]);
        assert(img["bytes"].integer > 0 && "data_base64" !in img, c[0]);
    }

    // A relative path is stored absolute (it survives a resume elsewhere).
    auto old = getcwd;
    chdir(dir);
    scope (exit) chdir(old);
    mkdirRecurse("sub");
    write("sub/rel.png", fakePng(8, 8));
    auto stored = parseJSON(readFile(JSONValue(["path": "sub/rel.png"]), st))["image"]["path"].str;
    assert(stored.isAbsolute && stored.endsWith("sub/rel.png"), stored);

    // Reading an image doesn't authorize a write; delivering it does (the
    // agent's markRead, once the model can view it).
    auto pic = buildPath(dir, "a.png");
    assert(msg(JSONValue(["path": pic, "content": "x"]).toString).canFind("has not been read"));
    st.record(pic, fakePng(40, 20));
    writeFile(JSONValue(["path": pic, "content": "replaced"]), st);
    assert(readText(pic) == "replaced");
}

// ---- apply_patch ----

version (unittest)
{
    private string patchErr(ReadState st, string patch, bool dry = false)
    {
        try applyPatch(j("patch", patch, "dry_run", dry), st);
        catch (ToolError e) return e.msg;
        assert(false, "patch should have failed");
    }

    private string pt(string[] body_...) { return "*** Begin Patch\n" ~ body_.join("\n") ~ "\n*** End Patch\n"; }
}

unittest // parse errors name the patch line
{
    auto st = new ReadState;
    assert(patchErr(st, "nope").indexOf("must start with a `*** Begin Patch`") >= 0);
    assert(patchErr(st, "*** Begin Patch\n*** Delete File: x").indexOf("must end with") >= 0);
    assert(patchErr(st, pt()).indexOf("changes no files") >= 0);
    auto e = patchErr(st, pt("*** Update File: a.txt", "@@", " x", "?y"));
    assert(e.indexOf("patch line 5") >= 0 && e.indexOf("starts with ' '") >= 0, e);
    assert(patchErr(st, pt("*** Update File: a.txt", "@@ -1,3 +1,4 @@", "-x")).indexOf("line-number hunk headers") >= 0);
    assert(patchErr(st, pt("*** Update File: a.txt")).indexOf("has no hunks") >= 0);
    assert(patchErr(st, pt("*** Add File: n.txt", "oops")).indexOf("starts with `+`") >= 0);
    assert(patchErr(st, pt("*** Frobnicate: a")).indexOf("expected `*** Add File") >= 0);
    assert(patchErr(st, pt("*** Move File: a.txt b.txt")).indexOf("Move File: <from> -> <to>") >= 0);
    assert(patchErr(st, pt("*** Update File: a.txt", "@@", " same")).indexOf("changes nothing") >= 0);
    assert(patchPaths(pt("*** Move File: a -> b", "*** Delete File: c", "*** Update File: d", "*** Move to: e", "@@", "-x"))
        == ["a", "b", "c", "d", "e"]);
}

unittest // multi-hunk, multi-file update with anchors, add, delete and move
{
    auto st = new ReadState;
    auto a = tmpFile("p-a.d", "void f()\n{\n    int x = 1;\n    return;\n}\nvoid g()\n{\n    int x = 1;\n    return;\n}\n");
    auto b = tmpFile("p-b.txt", "gone\n");
    auto c = tmpFile("p-c.txt", "keep\nme\n");
    auto n = tmpFile("p-new/deep.txt", null);
    auto m = tmpFile("p-moved.txt", null);
    auto out_ = applyPatch(j("patch", pt(
        "*** Update File: " ~ a,
        "@@ void g()",
        " {",
        "-    int x = 1;",
        "+    int x = 2;",
        "@@ void f()",
        " {",
        "     int x = 1;",
        "+    int y = 3;",
        "*** Add File: " ~ n,
        "+hello",
        "+world",
        "*** Delete File: " ~ b,
        "*** Move File: " ~ c ~ " -> " ~ m,
        "@@",
        " keep",
        "-me",
        "+you")), st);
    assert(readText(a) == "void f()\n{\n    int x = 1;\n    int y = 3;\n    return;\n}\nvoid g()\n{\n    int x = 2;\n    return;\n}\n", readText(a));
    assert(readText(n) == "hello\nworld\n" && !b.exists && !c.exists && readText(m) == "keep\nyou\n");
    assert(out_.startsWith("Applied patch to 4 file(s):"), out_);
    assert(out_.indexOf("+++ b/" ~ a) >= 0 && out_.indexOf("-    int x = 1;\n+    int x = 2;\n") >= 0, out_);
    assert(out_.indexOf("--- /dev/null\n+++ b/" ~ n ~ "\n@@ -0,0 +1,2 @@\n+hello\n+world\n") >= 0, out_);
    assert(out_.indexOf("+++ /dev/null") >= 0 && out_.indexOf("  R " ~ c ~ " -> " ~ m) >= 0, out_);
    // Written files count as read: edit_file may follow without a read.
    editFile(j("path", n, "old_string", "hello", "new_string", "hi"), st);
}

unittest // every match tier, reported; ambiguous and missing hunks
{
    auto st = new ReadState;
    auto p = tmpFile("p-tier.py", "def f():\n    x = 1  \n    return x\n");
    auto out_ = applyPatch(j("patch", pt("*** Update File: " ~ p, "@@", "-    x = 1", "+    x = 2")), st);
    assert(out_.indexOf("matched ignoring trailing whitespace") >= 0, out_);
    out_ = applyPatch(j("patch", pt("*** Update File: " ~ p, "@@", "-x = 2", "+x = 3", " return x")), st);
    assert(out_.indexOf("matched ignoring indentation") >= 0, out_);
    assert(readText(p) == "def f():\n    x = 3\n    return x\n", readText(p));
    out_ = applyPatch(j("patch", pt("*** Update File: " ~ p, "@@ def f():", "-    x = 3", "+    x = 4")), st);
    assert(out_.indexOf("matched") < 0, out_);

    auto q = tmpFile("p-amb.txt", "a\nb\na\nb\n");
    auto e = patchErr(st, pt("*** Update File: " ~ q, "@@", "-a", "+z", " b"));
    assert(e.indexOf("p-amb.txt: hunk 1") >= 0 && e.indexOf("occurs 2 times") >= 0 && e.indexOf("replace_all") < 0, e);
    e = patchErr(st, pt("*** Update File: " ~ q, "@@", " a", "-c", "+z"));
    assert(e.indexOf("were not found") >= 0 && e.indexOf("Closest match (1 of 2 lines agree), lines 1-2") >= 0, e);
    assert(e.indexOf("     2\tb") >= 0 && e.indexOf("The hunk expects:\n  | a\n  | c\n") >= 0, e);
    assert(patchErr(st, pt("*** Update File: " ~ q, "@@ nowhere", "-a", "+z")).indexOf("anchor line was not found") >= 0);
    // An anchor narrows an otherwise ambiguous hunk.
    auto r = tmpFile("p-anchor.txt", "one:\n  x\ntwo:\n  x\n");
    applyPatch(j("patch", pt("*** Update File: " ~ r, "@@ two:", "-  x", "+  y")), st);
    assert(readText(r) == "one:\n  x\ntwo:\n  y\n");
    // End of File, a pure insertion after an anchor, and a file without a final newline.
    auto s = tmpFile("p-eof.txt", "x\ny\nx");
    applyPatch(j("patch", pt("*** Update File: " ~ s, "@@", "-x", "+z", "*** End of File", "@@ y", "+inserted")), st);
    assert(readText(s) == "x\ny\ninserted\nz", readText(s));
    assert(readText(q) == "a\nb\na\nb\n" && st.staleRead(q, readBytes(q)) == false);
}

unittest // atomic: one failing hunk or file writes nothing; dry run writes nothing
{
    auto st = new ReadState;
    auto a = tmpFile("p-at1.txt", "one\n");
    auto b = tmpFile("p-at2.txt", "two\n");
    auto n = tmpFile("p-at-new.txt", null);
    auto e = patchErr(st, pt("*** Update File: " ~ a, "@@", "-one", "+ONE", "*** Add File: " ~ n, "+x",
            "*** Update File: " ~ b, "@@", "-three", "+3"));
    assert(e.indexOf("p-at2.txt: hunk 1") >= 0, e);
    assert(readText(a) == "one\n" && readText(b) == "two\n" && !n.exists);
    assert(patchErr(st, pt("*** Add File: " ~ a, "+x")).indexOf("already exists") >= 0);
    assert(patchErr(st, pt("*** Delete File: " ~ n)).indexOf("does not exist") >= 0);
    assert(patchErr(st, pt("*** Move File: " ~ a ~ " -> " ~ b)).indexOf("destination already exists") >= 0);
    auto out_ = applyPatch(j("patch", pt("*** Update File: " ~ a, "@@", "-one", "+ONE", "*** Delete File: " ~ b), "dry_run", true), st);
    assert(out_.startsWith("Dry run:") && out_.indexOf("-one\n+ONE\n") >= 0 && out_.indexOf("  D ") >= 0, out_);
    assert(readText(a) == "one\n" && b.exists);
    // A file read and changed since is stale, as with edit_file.
    readFile(j("path", a), st);
    write(a, "changed\n");
    assert(patchErr(st, pt("*** Update File: " ~ a, "@@", "-changed", "+x")).indexOf("changed since it was last read") >= 0);
    assert(readText(a) == "changed\n");
}

unittest // a move keeps the source's permission bits and carries binary bytes through
{
    import std.file : getAttributes, setAttributes;
    auto st = new ReadState;
    auto src = tmpFile("p-mv-exec.sh", "#!/bin/sh\n");
    auto dst = tmpFile("p-mv-exec2.sh", null);
    setAttributes(src, octal!755);
    applyPatch(j("patch", pt("*** Move File: " ~ src ~ " -> " ~ dst)), st);
    assert(!src.exists && (getAttributes(dst) & octal!777) == octal!755);
    auto bin = tmpFile("p-mv-bin.dat", null);
    auto bin2 = tmpFile("p-mv-bin2.dat", null);
    std.file.write(bin, cast(const(ubyte)[])[0xff, 0xfe, 0x00, 0x80]);
    auto out_ = applyPatch(j("patch", pt("*** Move File: " ~ bin ~ " -> " ~ bin2)), st);
    assert(!bin.exists && readBytes(bin2) == cast(const(ubyte)[])[0xff, 0xfe, 0x00, 0x80]);
    assert(out_.indexOf("(binary; renamed)") >= 0);
    remove(dst);
    remove(bin2);
}

unittest // review round 2: whole-line exact matches, anchors, aliases, binary deletes, symlink rollback
{
    auto st = new ReadState;
    // An exact match must start a line: a substring of an indented line reindents instead.
    auto f = tmpFile("p-ls.txt", "    value = 1\n");
    applyPatch(j("patch", pt("*** Update File: " ~ f, "@@", "-value = 1", "+value = 2", "+return value")), st);
    assert(readText(f) == "    value = 2\n    return value\n", readText(f));
    auto g = tmpFile("p-ls2.txt", "foobar\nbar\n");
    applyPatch(j("patch", pt("*** Update File: " ~ g, "@@", "-bar", "+BAR")), st);
    assert(readText(g) == "foobar\nBAR\n", readText(g));
    // An ambiguity after one anchor is an error even if a later anchor is unique.
    auto a = tmpFile("p-amb.txt", "section\nx\nsection\nx\n");
    assert(patchErr(st, pt("*** Update File: " ~ a, "@@ section", "-x", "+y")).indexOf("2 times") >= 0);
    assert(readText(a) == "section\nx\nsection\nx\n");
    // An End of File hunk still has to lie after its anchor.
    auto e = tmpFile("p-eofa.txt", "z\nanchor\nq\n");
    assert(patchErr(st, pt("*** Update File: " ~ e, "@@ anchor", "-anchor", "-q", "+w", "*** End of File"))
            .indexOf("not after the anchor") >= 0);
    // A binary file can be deleted.
    auto b = tmpFile("p-delbin.dat", null);
    std.file.write(b, cast(const(ubyte)[])[0xff, 0xfe]);
    assert(applyPatch(j("patch", pt("*** Delete File: " ~ b)), st).indexOf("(binary; deleted)") >= 0 && !b.exists);
    // Two paths to one file are rejected rather than losing one edit.
    auto r = tmpFile("p-alias.txt", "x\ny\n");
    auto l = tmpFile("p-alias-link.txt", null);
    symlink(r, l);
    assert(patchErr(st, pt("*** Update File: " ~ r, "@@", "-x", "+X", "*** Update File: " ~ l, "@@", "-y", "+Y"))
            .indexOf("same file") >= 0);
    assert(readText(r) == "x\ny\n");
    // A deleted symlink is restored as a symlink when a later write fails.
    auto blocker = tmpFile("p-blocker", "regular\n");
    auto out_ = patchErr(st, pt("*** Delete File: " ~ l, "*** Add File: " ~ blocker ~ "/child", "+c"));
    assert(isSymlink(l) && readLink(l) == r, out_);
    remove(l);
}

unittest // the unified diff
{
    assert(unifiedDiff("a", "b", "1\n2\n3\n", "1\n2\n3\n") == "--- a\n+++ b\n");
    string lines;
    foreach (i; 1 .. 21) lines ~= format("%s\n", i);
    auto changed = lines.replace("\n2\n", "\ntwo\n").replace("\n19\n", "\nnineteen\n");
    auto d = unifiedDiff("a", "b", lines, changed);
    assert(d == "--- a\n+++ b\n@@ -1,5 +1,5 @@\n 1\n-2\n+two\n 3\n 4\n 5\n@@ -16,5 +16,5 @@\n 16\n 17\n 18\n-19\n+nineteen\n 20\n", d);
}

unittest // review round 3: overlapping hunks, CRLF without a final newline, rollback of directories and modes
{
    import std.file : getAttributes, setAttributes;
    import std.path : buildPath;
    auto st = new ReadState;
    // A hunk that matches at two overlapping places is ambiguous, not unique.
    auto o = tmpFile("p-ovl.txt", "a\na\na\n");
    assert(patchErr(st, pt("*** Update File: " ~ o, "@@", " a", "-a", "+b")).indexOf("ambiguous") >= 0);
    assert(readText(o) == "a\na\na\n");
    // CRLF file without a final newline: deleting the last line keeps the
    // previous line's terminator whole; appending uses CRLF throughout.
    auto c = tmpFile("p-crlf-del.txt", "a\r\nb");
    applyPatch(j("patch", pt("*** Update File: " ~ c, "@@", " a", "-b")), st);
    assert(readText(c) == "a\r\n", readText(c));
    auto c2 = tmpFile("p-crlf-add.txt", "a\r\nb");
    applyPatch(j("patch", pt("*** Update File: " ~ c2, "@@", "+c")), st);
    assert(readText(c2) == "a\r\nb\r\nc", readText(c2));
    auto c3 = tmpFile("p-crlf-mod.txt", "a\r\nb");
    applyPatch(j("patch", pt("*** Update File: " ~ c3, "@@", "-b", "+B")), st);
    assert(readText(c3) == "a\r\nB", readText(c3));
    // A failed commit removes the directories it created before restoring
    // a deleted file at the same path.
    auto a = tmpFile("p-dirrb", "original\n");
    auto blocker = tmpFile("p-dirrb-blocker", "file\n");
    auto e = patchErr(st, pt("*** Delete File: " ~ a, "*** Add File: " ~ buildPath(a, "child"), "+x",
            "*** Add File: " ~ buildPath(blocker, "child"), "+y"));
    assert(e.indexOf("rolled back") >= 0, e);
    assert(a.isFile && readText(a) == "original\n", e);
    auto nd = buildPath(tempDir, "nano-coder-files-test", "p-newdir");
    if (nd.exists) rmdirRecurse(nd);
    patchErr(st, pt("*** Add File: " ~ buildPath(nd, "sub", "f"), "+x", "*** Add File: " ~ buildPath(blocker, "c"), "+y"));
    assert(!nd.exists);
    // Rollback restores a replaced destination with its own permission bits.
    auto dst = tmpFile("p-mode-dst", "dst\n");
    auto src = tmpFile("p-mode-src", "src\n");
    setAttributes(dst, octal!755);
    setAttributes(src, octal!644);
    patchErr(st, pt("*** Delete File: " ~ dst, "*** Move File: " ~ src ~ " -> " ~ dst,
            "*** Add File: " ~ buildPath(blocker, "c"), "+y"));
    assert(readText(dst) == "dst\n" && (getAttributes(dst) & octal!777) == octal!755);
    assert(readText(src) == "src\n" && (getAttributes(src) & octal!777) == octal!644);
    remove(dst); remove(src); remove(a); remove(blocker);
}

unittest // review round 4: final-newline state in diffs, identical move destinations, binary delete-and-add
{
    auto st = new ReadState;
    // A final line without a newline is marked, and gaining one is a change.
    assert(unifiedDiff("a", "b", "x", "y") == "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-x\n\\ No newline at end of file\n+y\n\\ No newline at end of file\n");
    assert(unifiedDiff("a", "b", "x", "x\n") == "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-x\n\\ No newline at end of file\n+x\n");
    auto n = tmpFile("p-noeol.txt", "x");
    auto out_ = applyPatch(j("patch", pt("*** Delete File: " ~ n, "*** Add File: " ~ n, "+x")), st);
    assert(out_.indexOf("1 file(s)") >= 0 && out_.indexOf("No newline") >= 0, out_);
    // Moving onto a deleted file with the same content still moves.
    auto a = tmpFile("p-same-a.txt", "x\n");
    auto b = tmpFile("p-same-b.txt", "x\n");
    out_ = applyPatch(j("patch", pt("*** Delete File: " ~ b, "*** Move File: " ~ a ~ " -> " ~ b)), st);
    assert(out_.indexOf("1 file(s)") >= 0 && out_.indexOf(" R ") >= 0, out_);
    assert(!a.exists && readText(b) == "x\n");
    // A binary file can be replaced by a text one at the same path.
    auto bin = tmpFile("p-binrep.dat", null);
    std.file.write(bin, cast(const(ubyte)[])[0xff, 0xfe]);
    out_ = applyPatch(j("patch", pt("*** Delete File: " ~ bin, "*** Add File: " ~ bin, "+text")), st);
    assert(out_.indexOf("(binary; replaced)") >= 0 && readText(bin) == "text\n", out_);
    remove(n); remove(b); remove(bin);
}

unittest // review round 6: private bounded temp files, EOF newline state, CRLF diffs, symlink replacement, move chains
{
    import std.array : replicate;
    auto st = new ReadState;
    // A long target basename still yields a temp name under the component limit.
    auto longName = tmpFile("p-" ~ "x".replicate(235) ~ ".txt", "v1\n");
    applyPatch(j("patch", pt("*** Update File: " ~ longName, "@@", "-v1", "+v2")), st);
    assert(readText(longName) == "v2\n" && !tempPresent(longName));
    // Deleting an unterminated tail keeps the previous line's terminator, even
    // when its text equals the deleted line's.
    auto t1 = tmpFile("p-eof1.txt", "x\nx");
    applyPatch(j("patch", pt("*** Update File: " ~ t1, "@@", " x", "-x")), st);
    assert(readText(t1) == "x\n", readText(t1));
    auto t2 = tmpFile("p-eof2.txt", "a\nb");
    applyPatch(j("patch", pt("*** Update File: " ~ t2, "@@", "-a", "+A", "-b")), st);
    assert(readText(t2) == "A\n", readText(t2));
    // CRLF vs LF lines differ, and a replacement keeps each side's endings.
    auto d = unifiedDiff("a", "b", "x\r\n", "x\n");
    assert(d == "--- a\n+++ b\n@@ -1,1 +1,1 @@\n-x\r\n+x\n", d);
    auto cr = tmpFile("p-crlf-diff.txt", "x\r\ny\r\n");
    auto out_ = applyPatch(j("patch", pt("*** Update File: " ~ cr, "@@", "-x", "+X")), st);
    assert(out_.indexOf("-x\r\n+X\r\n") >= 0, out_);
    assert(readText(cr) == "X\r\ny\r\n");
    // Deleting a symlink and adding a file at its path replaces the link.
    auto tgt = tmpFile("p-lk-real.txt", "real\n");
    auto lk = tmpFile("p-lk.txt", null);
    if (isLink(lk) || lk.exists) remove(lk);
    symlink(tgt, lk);
    out_ = applyPatch(j("patch", pt("*** Delete File: " ~ lk, "*** Add File: " ~ lk, "+new")), st);
    assert(!isLink(lk) && readText(lk) == "new\n" && readText(tgt) == "real\n", out_);
    // Same bytes still count: the link becomes a regular file (review round 10).
    remove(lk);
    symlink(tgt, lk);
    out_ = applyPatch(j("patch", pt("*** Delete File: " ~ lk, "*** Add File: " ~ lk, "+real")), st);
    assert(!isLink(lk) && readText(lk) == "real\n" && out_.indexOf("to 1 file(s)") >= 0, out_);
    // A plain Update File through a symlink writes through it and keeps the link.
    remove(lk);
    symlink(tgt, lk);
    out_ = applyPatch(j("patch", pt("*** Update File: " ~ lk, "@@", "-real", "+changed")), st);
    assert(isLink(lk) && readText(tgt) == "changed\n", out_);
    // A move chain reports and diffs against the original source.
    auto ma = tmpFile("p-chain-a.txt", "one\ntwo\n");
    auto mb = tmpFile("p-chain-b.txt", null);
    auto mc = tmpFile("p-chain-c.txt", null);
    out_ = applyPatch(j("patch", pt("*** Move File: " ~ ma ~ " -> " ~ mb, "*** Move File: " ~ mb ~ " -> " ~ mc)), st);
    assert(out_.indexOf(" R " ~ ma ~ " -> " ~ mc) >= 0 && out_.indexOf(" D ") < 0, out_);
    assert(out_.indexOf("--- a/" ~ ma ~ "\n+++ b/" ~ mc ~ "\n") >= 0, out_);
    assert(!ma.exists && !mb.exists && readText(mc) == "one\ntwo\n");
    remove(longName); remove(t1); remove(t2); remove(cr); remove(tgt); remove(lk); remove(mc);
}

unittest // review round 7: new files get the umask-filtered default mode; EOF state from the hunk's last operation
{
    import std.file : getAttributes;
    import nano.safeio : newFileMode;
    auto st = new ReadState;
    // New files from write_file and Add File are not left at the private 0600 staging mode.
    auto w = tmpFile("p-mode-write.txt", null);
    if (w.exists) remove(w);
    writeFile(JSONValue(["path": w, "content": "x\n"]), st);
    assert((getAttributes(w) & octal!777) == newFileMode);
    auto ad = tmpFile("p-mode-add.txt", null);
    if (ad.exists) remove(ad);
    applyPatch(j("patch", pt("*** Add File: " ~ ad, "+x")), st);
    assert((getAttributes(ad) & octal!777) == newFileMode);
    // Same line arrays, different last operation: an addition ending the hunk
    // keeps the unterminated tail; a removal ending it exposes a real newline.
    auto t1 = tmpFile("p-eof7a.txt", "a\nb");
    applyPatch(j("patch", pt("*** Update File: " ~ t1, "@@", "-a", "-b", "+A")), st);
    assert(readText(t1) == "A", readText(t1));
    auto t2 = tmpFile("p-eof7b.txt", "a\nb");
    applyPatch(j("patch", pt("*** Update File: " ~ t2, "@@", "-a", "+A", "-b")), st);
    assert(readText(t2) == "A\n", readText(t2));
    auto t3 = tmpFile("p-eof7c.txt", "a\nb");
    applyPatch(j("patch", pt("*** Update File: " ~ t3, "@@", " a", "-b", "+B")), st);
    assert(readText(t3) == "a\nB", readText(t3));
    remove(w); remove(ad); remove(t1); remove(t2); remove(t3);
}

unittest // adversarial: replacing a 0600 file keeps it 0600 (write_file and apply_patch)
{
    import std.file : getAttributes, setAttributes;
    auto st = new ReadState;
    auto w = tmpFile("p-mode-secret-w.txt", "a\n");
    setAttributes(w, octal!600);
    st.record(w, "a\n");
    writeFile(JSONValue(["path": w, "content": "b\n"]), st);
    assert((getAttributes(w) & octal!7777) == octal!600);
    auto p = tmpFile("p-mode-secret-p.txt", "a\n");
    setAttributes(p, octal!600);
    st.record(p, "a\n");
    applyPatch(j("patch", pt("*** Update File: " ~ p, "@@", "-a", "+b")), st);
    assert((getAttributes(p) & octal!7777) == octal!600);
    assert(readText(p) == "b\n");
    remove(w); remove(p);
}

unittest // review round 8: symlink freshness by identity, pinned targets, prepared snapshot, rollback message
{
    import std.file : symlink, remove;
    auto st = new ReadState;
    // Deleting a file and then a symlink to it: the link's own freshness is
    // its identity/target, not its (now dangling) referent's bytes.
    auto realF = tmpFile("p8-real.txt", "x\n");
    auto lk = tmpFile("p8-lk.txt", null);
    if (isLink(lk) || lk.exists) remove(lk);
    symlink(realF, lk);
    auto out_ = applyPatch(j("patch", pt("*** Delete File: " ~ realF, "*** Delete File: " ~ lk)), st);
    assert(out_.indexOf("2 file(s)") >= 0, out_);
    assert(!realF.exists && !isLink(lk) && !lk.exists);
    // checkUnchanged compares a staged symlink by entry identity and target:
    // a retarget to identical bytes fails, an untouched (even dangling) link passes.
    auto t1 = tmpFile("p8-t1.txt", "same\n");
    auto t2 = tmpFile("p8-t2.txt", "same\n");
    auto lk2 = tmpFile("p8-lk2.txt", null);
    if (isLink(lk2) || lk2.exists) remove(lk2);
    symlink(t1, lk2);
    Staged se;
    se.path = lk2;
    se.display = lk2;
    se.existed = se.present = true;
    se.before = readBytes(lk2);
    se.wasLink = true;
    se.linkTarget = readLink(lk2);
    checkUnchanged(se); // untouched: passes even though it is a link
    remove(lk2);
    symlink(t2, lk2); // retargeted to a file with identical bytes
    bool threw;
    try checkUnchanged(se);
    catch (ToolError e) threw = e.msg.indexOf("changed while the patch was being prepared") >= 0;
    assert(threw, "a retargeted link must fail the freshness check");
    remove(lk2);
    symlink(t1, lk2);
    checkUnchanged(se); // restored target: passes again
    remove(t1); remove(t2); remove(lk2);
    // The caller's snapshot gates the commit: an unchanged one commits.
    auto src = tmpFile("p8-src.txt", "approved\n");
    auto dst = tmpFile("p8-dst.txt", null);
    if (dst.exists) remove(dst);
    auto mv = pt("*** Move File: " ~ src ~ " -> " ~ dst);
    applyPatch(j("patch", mv), st, patchOriginals(mv));
    assert(readText(dst) == "approved\n", readText(dst));
    assert(!src.exists);
    // A failure after a committed write rolls it back and says so; a rollback
    // failure is reported as ROLLBACK FAILED, never as a clean rollback.
    auto a = tmpFile("p8-a.txt", "one\n");
    auto b = tmpFile("p8-b.txt", null);
    if (b.exists) remove(b);
    auto blocker = tmpFile("p8-blocker", "file\n");
    auto e3 = patchErr(st, pt("*** Add File: " ~ b, "+x", "*** Add File: " ~ buildPath(blocker, "child"), "+y"));
    assert(e3.indexOf("rolled back") >= 0 && e3.indexOf("ROLLBACK FAILED") < 0, e3);
    assert(!b.exists, e3);
    remove(dst); remove(a); remove(blocker);
    // The rollback itself failing (its directory went read-only) is reported
    // as ROLLBACK FAILED. Root ignores directory permissions, so skip there.
    import core.sys.posix.unistd : geteuid;
    if (geteuid() != 0)
    {
        auto roDir = tmpFile("p8-ro", null);
        if (roDir.exists) rmdirRecurse(roDir);
        mkdirRecurse(roDir);
        auto c = buildPath(roDir, "c.txt");
        auto blocker2 = tmpFile("p8-blocker2", "file\n");
        beforeRollbackForTest = () { setAttributes(roDir, octal!555); };
        scope (exit)
        {
            beforeRollbackForTest = null;
            setAttributes(roDir, octal!755);
            rmdirRecurse(roDir);
            remove(blocker2);
        }
        auto e4 = patchErr(st, pt("*** Add File: " ~ c, "+x", "*** Add File: " ~ buildPath(blocker2, "child"), "+y"));
        assert(e4.indexOf("ROLLBACK FAILED") >= 0 && e4.indexOf("rolled back") < 0, e4);
        assert(c.exists, e4);
    }
}

unittest // the hook-approved commit path is reachable: apply_patch's PatchHandler is retrievable by its exact shape
{
    auto reg = new ToolRegistry;
    register(reg, new ReadState);
    assert(reg.handlerAs!PatchHandler("apply_patch") !is null);
}

unittest // review round 9: snapshot-gated commit, normalized repeats, symlink referents, rollback boundary
{
    import std.file : symlink, remove;
    auto st = new ReadState;
    // A source edited after the hooks' snapshot fails the call: nothing is
    // written and the intervening edit survives.
    auto src = tmpFile("p9-src.txt", "one\n");
    auto dst = tmpFile("p9-dst.txt", null);
    if (dst.exists) remove(dst);
    auto mv = pt("*** Move File: " ~ src ~ " -> " ~ dst);
    auto snap = patchOriginals(mv);
    std.file.write(src, "two\n");
    st.record(src, "two\n");
    bool threw;
    try applyPatch(j("patch", mv), st, snap);
    catch (ToolError e) threw = e.msg.indexOf("changed while the patch's hooks ran") >= 0;
    assert(threw && readText(src) == "two\n" && !dst.exists);
    // A destination created after the snapshot fails it too.
    snap = patchOriginals(mv);
    std.file.write(dst, "theirs\n");
    threw = false;
    try applyPatch(j("patch", mv), st, snap);
    catch (ToolError e) threw = true;
    assert(threw && readText(dst) == "theirs\n" && readText(src) == "two\n");
    remove(dst); remove(src);
    // Repeated paths spelled differently resolve to one entry: the update wins.
    auto d = tmpFile("p9-dir", null);
    if (d.exists) rmdirRecurse(d);
    mkdirRecurse(d);
    scope (exit) rmdirRecurse(d);
    auto rp = pt("*** Add File: " ~ d ~ "/a.txt", "+one", "*** Update File: " ~ d ~ "/./a.txt", "@@", "-one", "+two");
    snap = patchOriginals(rp);
    assert(snap.length == 1, "one snapshot entry per resolved path");
    applyPatch(j("patch", rp), st, snap);
    assert(readText(buildPath(d, "a.txt")) == "two\n");
    // An update through a symlink re-checks the referent's bytes, not just the link.
    auto t = tmpFile("p9-t.txt", "x\n");
    auto lk = tmpFile("p9-lk.txt", null);
    if (isLink(lk) || lk.exists) remove(lk);
    symlink(t, lk);
    Staged se;
    se.path = lk;
    se.display = lk;
    se.existed = se.present = se.changed = true;
    se.before = readBytes(lk);
    se.wasLink = true;
    se.linkTarget = readLink(lk);
    checkUnchanged(se);
    std.file.write(t, "edited\n");
    threw = false;
    try checkUnchanged(se);
    catch (ToolError e) threw = true;
    assert(threw, "an edited referent must fail an update's freshness check");
    se.present = false; // a delete still needs only the entry's identity
    checkUnchanged(se);
    remove(lk); remove(t);
    // A failed entry is outside the rollback boundary: a file another process
    // created with the intended bytes is not removed as if this patch wrote it.
    auto b = tmpFile("p9-b.txt", null);
    auto c = tmpFile("p9-c.txt", null);
    foreach (f; [b, c]) if (f.exists) remove(f);
    beforeEntryForTest = (size_t i) { if (i == 1) std.file.write(c, "y\n"); };
    scope (exit) beforeEntryForTest = null;
    auto e = patchErr(st, pt("*** Add File: " ~ b, "+x", "*** Add File: " ~ c, "+y"));
    assert(e.indexOf("was created while the patch was being prepared") >= 0, e);
    assert(!b.exists, e);
    assert(c.exists && readText(c) == "y\n", e);
    remove(c);
}
