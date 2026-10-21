/// File tools: `read_file`, `write_file`, `edit_file`. Writes and edits of an
/// existing file require that it was read first and has not changed since, so
/// the model never overwrites content it hasn't seen.
module nano.tools.files;

import std.json;
import std.format : format;
import std.file;
import std.path : absolutePath, buildNormalizedPath, dirName, expandTilde;
import std.string : splitLines, indexOf, stripRight, strip, join, lineSplitter, KeepTerminator;
import std.algorithm : count, min, max;
import std.array : replace, split;
import std.digest.sha : sha256Of;
import nano.tools;
import nano.llm : ToolDefinition;

enum long defaultReadLimit = 2000;
enum size_t maxLineChars = 2000;

/// What the agent has seen of each file (by content hash).
class ReadState
{
    private ubyte[32][string] seen;

    void record(string path, const(void)[] content) { seen[path] = sha256Of(content); }
    void forget(string path) { seen.remove(path); }

    /// Ok to overwrite `path`? It must not exist, or must match what was read.
    void checkFresh(string path, string tool)
    {
        if (!path.exists) return;
        auto s = path in seen;
        if (s is null)
            throw new ToolError(format("%s: read %s before changing it", tool, path));
        if (*s != sha256Of(cast(const(void)[]) read(path)))
            throw new ToolError(format("%s: %s changed since you last read it; read it again first", tool, path));
    }
}

string resolvePath(string p)
{
    return buildNormalizedPath(absolutePath(expandTilde(p)));
}

bool looksBinary(const(ubyte)[] data)
{
    import std.algorithm : canFind;
    return data[0 .. min(data.length, 8192)].canFind(cast(ubyte) 0);
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
    auto data = cast(ubyte[]) read(path);
    import std.path : extension;
    import std.uni : toLower;
    auto ext = path.extension.toLower;
    if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".gif" || ext == ".webp")
        throw new ToolError(format("read_file: %s is an image; image viewing is not ported to nano-coder-d yet", path));
    if (looksBinary(data)) throw new ToolError(format("read_file: %s looks binary", path));
    import std.utf : validate, UTFException;
    auto text = cast(string) data;
    try validate(text);
    catch (UTFException) throw new ToolError(format("read_file: %s is not valid UTF-8 text", path));
    state.record(path, data);
    if (text.length == 0) return "(empty file)";
    auto lines = text.splitLines;
    if (offset > lines.length)
        throw new ToolError(format("read_file: offset %s is past the end of %s (%s lines)", offset, path, lines.length));
    auto first = cast(size_t) offset - 1;
    auto last = min(lines.length, first + cast(size_t) limit);
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
private size_t safeCut(string s, size_t at)
{
    while (at > 0 && (s[at] & 0xC0) == 0x80) at--;
    return at;
}

string writeFile(JSONValue args, ReadState state)
{
    auto path = resolvePath(requireString(args, "path", "write_file"));
    auto content = requireString(args, "content", "write_file");
    if (path.exists && path.isDir) throw new ToolError(format("write_file: %s is a directory", path));
    state.checkFresh(path, "write_file");
    bool existed = path.exists;
    mkdirRecurse(path.dirName);
    write(path, content);
    state.record(path, content);
    auto lines = content.length ? content.count('\n') + (content[$ - 1] == '\n' ? 0 : 1) : 0;
    return format("%s %s (%s bytes, %s lines)", existed ? "Overwrote" : "Created", path, content.length, lines);
}

string editFile(JSONValue args, ReadState state)
{
    auto path = resolvePath(requireString(args, "path", "edit_file"));
    auto oldS = requireString(args, "old_string", "edit_file");
    auto newS = requireString(args, "new_string", "edit_file");
    auto all = optBool(args, "replace_all", false);
    if (!path.exists) throw new ToolError(format("edit_file: %s does not exist; use write_file to create it", path));
    if (oldS.length == 0) throw new ToolError("edit_file: old_string must not be empty");
    if (oldS == newS) throw new ToolError("edit_file: old_string and new_string are identical");
    state.checkFresh(path, "edit_file");
    auto text = readText(path);
    string updated, how;
    size_t at;
    auto n = text.count(oldS);
    if (n == 1 || (n > 1 && all))
    {
        at = text.indexOf(oldS);
        updated = all ? text.replace(oldS, newS) : text[0 .. at] ~ newS ~ text[at + oldS.length .. $];
    }
    else if (n > 1)
        throw new ToolError(format("edit_file: old_string occurs %s times in %s; add surrounding context to make it unique, or set replace_all", n, path));
    else
    {
        auto m = fuzzyFind(text, oldS);
        if (m.count == 0)
            throw new ToolError(format("edit_file: old_string not found in %s; read the file again and copy the text exactly", path));
        if (m.count > 1)
            throw new ToolError(format("edit_file: old_string matches %s places in %s (ignoring whitespace); add context", m.count, path));
        at = m.start;
        how = m.how;
        auto replacement = newS;
        if (text[m.start .. m.end].length && text[m.end - 1] == '\n' && (newS.length == 0 || newS[$ - 1] != '\n'))
            replacement ~= "\n";
        updated = text[0 .. m.start] ~ replacement ~ text[m.end .. $];
    }
    write(path, updated);
    state.record(path, updated);
    return format("Edited %s%s\n%s", path, how.length ? " (matched " ~ how ~ ")" : "",
            snippet(updated, at, newS.length));
}

struct FuzzyMatch
{
    size_t count, start, end;
    string how;
}

/// Find `needle` as a run of whole lines, comparing lines with trailing
/// whitespace trimmed, then also ignoring indentation.
FuzzyMatch fuzzyFind(string text, string needle)
{
    auto hay = text.lineSplitter!(KeepTerminator.yes).array_;
    auto want = needle.stripRight("\n").splitLines;
    if (want.length == 0) return FuzzyMatch.init;
    size_t[] offsets = [0];
    foreach (l; hay) offsets ~= offsets[$ - 1] + l.length;
    foreach (mode; 0 .. 2)
    {
        string norm(string s) { s = s.stripRight; return mode ? s.strip : s; }
        FuzzyMatch m;
        m.how = mode ? "ignoring indentation" : "ignoring trailing whitespace";
        if (hay.length >= want.length)
            foreach (i; 0 .. hay.length - want.length + 1)
            {
                bool ok = true;
                foreach (j, w; want)
                    if (norm(hay[i + j]) != norm(w)) { ok = false; break; }
                if (ok)
                {
                    if (m.count++ == 0)
                    {
                        m.start = offsets[i];
                        m.end = offsets[i + want.length];
                    }
                }
            }
        if (m.count) return m;
    }
    return FuzzyMatch.init;
}

private string[] array_(R)(R r)
{
    string[] a;
    foreach (x; r) a ~= x;
    return a;
}

/// The edited region with 3 lines of context, numbered.
string snippet(string text, size_t at, size_t len)
{
    auto firstLine = text[0 .. min(at, text.length)].count('\n');
    auto lastLine = text[0 .. min(at + len, text.length)].count('\n');
    auto lines = text.splitLines;
    auto from = firstLine > 3 ? firstLine - 3 : 0;
    auto to = min(lines.length, lastLine + 4);
    string out_;
    foreach (n; from .. to) out_ ~= format("%6d\t%s\n", n + 1, lines[n]);
    return out_;
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
        auto dir = buildPath(tempDir, "nano-coder-d-files-test");
        mkdirRecurse(dir);
        auto p = buildPath(dir, name);
        if (content !is null) write(p, content);
        else if (p.exists) remove(p);
        return p;
    }

    private JSONValue j(T...)(T kv)
    {
        JSONValue o = JSONValue(string[string].init);
        static foreach (i; 0 .. T.length / 2) o[kv[2 * i]] = kv[2 * i + 1];
        return o;
    }
}

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

unittest
{
    auto st = new ReadState;
    auto p = tmpFile("w.txt", "orig\n");
    bool threw;
    try writeFile(j("path", p, "content", "x"), st); catch (ToolError) threw = true;
    assert(threw, "overwrite without read must fail");
    readFile(j("path", p), st);
    write(p, "changed behind our back\n");
    threw = false;
    try editFile(j("path", p, "old_string", "changed", "new_string", "x"), st); catch (ToolError) threw = true;
    assert(threw, "stale edit must fail");
    readFile(j("path", p), st);
    editFile(j("path", p, "old_string", "behind", "new_string", "in front of"), st);
    assert(readText(p) == "changed in front of our back\n");
    auto fresh = tmpFile("new/deep.txt", null);
    writeFile(j("path", fresh, "content", "hi"), st);
    assert(readText(fresh) == "hi");
}

unittest
{
    auto st = new ReadState;
    auto p = tmpFile("f.d", "void f()\n{\n    int x = 1;   \n    return;\n}\n");
    readFile(j("path", p), st);
    auto r = editFile(j("path", p, "old_string", "int x = 1;\nreturn;", "new_string", "    int x = 2;\n    return;"), st);
    assert(r.indexOf("ignoring indentation") > 0);
    assert(readText(p) == "void f()\n{\n    int x = 2;\n    return;\n}\n");
    bool threw;
    auto q = tmpFile("dup.txt", "a\na\n");
    readFile(j("path", q), st);
    try editFile(j("path", q, "old_string", "a", "new_string", "b"), st); catch (ToolError) threw = true;
    assert(threw);
    editFile(j("path", q, "old_string", "a", "new_string", "b", "replace_all", true), st);
    assert(readText(q) == "b\nb\n");
}
