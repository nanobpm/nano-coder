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

import nano.safeio : ownText, readBytes, realPath, statMode, chmodPath;

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
    void forget(string path) { seen.remove(key(path)); }

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
        state.record(path, data);
        return "(empty file)";
    }
    if (offset > lines.length)
        throw new ToolError(format("read_file: offset %s is past the end of %s (%s lines)", offset, path, lines.length));
    // Record only once the read has succeeded, so a failed out-of-range read
    // can't authorize a later edit the model never saw.
    state.record(path, data);
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
    import std.process : thisProcessID;
    auto tmp = buildPath(path.dirName, format(".%s.tmp-%s", path.baseName, thisProcessID));
    // best-effort cleanup of the temp file; the original error propagates
    scope (failure) { try remove(tmp); catch (Exception) {} }
    try write(tmp, content);
    catch (FileException e) throw new ToolError(format("%s: write %s: %s", tool, tmp, e.msg));
    uint mode;
    if (statMode(path, mode)) chmodPath(tmp, mode & octal!7777);
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

/// Non-overlapping occurrences of `pat` in `text`.
private size_t[2][] occurrences(string text, string pat) pure
{
    size_t[2][] r;
    size_t from;
    while (from <= text.length)
    {
        auto i = text[from .. $].indexOf(pat);
        if (i < 0) break;
        auto at = from + i;
        r ~= [at, at + pat.length];
        from = at + pat.length;
    }
    return r;
}

private struct Attempt
{
    string old, new_, how;
    ulong atLine; // 0: anywhere
}

/// Exact match of one attempt, in its literal and file-ending forms.
private bool exactMatch(string text, const Attempt a, bool replaceAll, out Located found) pure
{
    auto normalized = toFileEndings(text, a.old);
    auto cands = normalized != a.old ? [a.old, normalized] : [a.old];
    size_t[2][] ranges;
    foreach (c; cands)
        foreach (r; occurrences(text, c))
            if (a.atLine == 0 || (lineAt(text, r[0]) == a.atLine && atLineStart(text, r[0])))
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
Located locate(string text, string old, string new_, bool replaceAll) pure
{
    Located found;
    auto literal = Attempt(old, new_, "", 0);
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
        (JSONValue a) => readFile(a, state));
    tools.register(ToolDefinition("write_file",
        "Create a file, or overwrite one you have read, creating parent directories. Prefer edit_file for changes to existing files.",
        parseJSON(`{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}`)),
        (JSONValue a) => writeFile(a, state));
    tools.register(ToolDefinition("edit_file",
        "Replace text in a file you have read (read it again if it changed since). old_string must match exactly once unless replace_all is true; "
        ~ "if there is no exact match, a unique match ignoring trailing whitespace or indentation is used. Returns the edited lines with context.",
        parseJSON(`{"type":"object","properties":{
            "path":{"type":"string"},
            "old_string":{"type":"string","description":"Exact text to replace, including whitespace"},
            "new_string":{"type":"string"},
            "replace_all":{"type":"boolean","description":"Replace every occurrence (default false)"}},
            "required":["path","old_string","new_string"]}`)),
        (JSONValue a) => editFile(a, state));
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
        auto prefix = "." ~ path.baseName ~ ".tmp-";
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
