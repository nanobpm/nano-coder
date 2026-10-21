/// Read-only search tools: `grep` and `glob`. Both walk the tree respecting
/// .gitignore files (nested), skip `.git`, symlinks and (for grep) binary files,
/// and return results sorted by path, capped by `limit`.
module nano.tools.search;

import std.json;
import std.format : format;
import std.file;
import std.path;
import std.regex;
import std.string : splitLines, strip, startsWith, endsWith, indexOf, lineSplitter;
import std.algorithm : sort, canFind, min;
import std.array : appender;
import nano.tools;
import nano.tools.files : resolvePath, looksBinary;
import nano.llm : ToolDefinition;

enum long defaultLimit = 250;
enum long maxLimit = 5000;

/// Translate a glob to an anchored regex. `*` and `?` stay within one path
/// segment; `**/` matches zero or more directories; `**` alone matches anything.
string globToRegex(string glob)
{
    auto r = appender!string;
    r.put('^');
    for (size_t i = 0; i < glob.length; i++)
    {
        char c = glob[i];
        if (c == '*')
        {
            if (i + 1 < glob.length && glob[i + 1] == '*')
            {
                i++;
                if (i + 1 < glob.length && glob[i + 1] == '/')
                {
                    i++;
                    r.put("(?:.*/)?");
                }
                else r.put(".*");
            }
            else r.put("[^/]*");
        }
        else if (c == '?') r.put("[^/]");
        else if (c == '[')
        {
            auto end = glob.indexOf(']', i + 1);
            if (end < 0) { r.put(`\[`); continue; }
            auto cls = glob[i + 1 .. end];
            if (cls.length && cls[0] == '!') cls = "^" ~ cls[1 .. $];
            r.put('[');
            r.put(cls);
            r.put(']');
            i = end;
        }
        else if (c == '{')
        {
            auto end = glob.indexOf('}', i + 1);
            if (end < 0) { r.put(`\{`); continue; }
            r.put("(?:");
            foreach (k, alt; glob[i + 1 .. end].split_(','))
            {
                if (k) r.put('|');
                r.put(escapeRe(alt));
            }
            r.put(')');
            i = end;
        }
        else r.put(escapeRe([c]));
    }
    r.put('$');
    return r.data;
}

private string[] split_(string s, char sep)
{
    import std.array : split;
    return s.split(sep);
}

private string escapeRe(string s)
{
    auto r = appender!string;
    foreach (c; s)
    {
        if (`\.+*?()|[]{}^$`.canFind(c)) r.put('\\');
        r.put(c);
    }
    return r.data;
}

struct IgnoreRule
{
    Regex!char re;
    bool negate;
    bool dirOnly;
    bool anchored; // matches the path relative to `base`, else the basename
    string base;   // directory (relative to root) holding the .gitignore
}

/// Gitignore rules collected while walking.
struct Ignores
{
    IgnoreRule[] rules;
    Denied denied;

    void load(string root, string relDir)
    {
        auto file = buildPath(root, relDir, ".gitignore");
        // Same checks as discovered files: no symlinks or special files, deny
        // rules apply, and the read is bounded.
        if (!file.exists || file.isSymlink || !file.isFile || file.getSize > 1 << 20) return;
        if (denied !is null && denied(file)) return;
        foreach (raw; readText(file).lineSplitter)
        {
            auto line = raw.strip;
            if (!line.length || line[0] == '#') continue;
            IgnoreRule r;
            r.base = relDir;
            if (line[0] == '!') { r.negate = true; line = line[1 .. $]; }
            if (line.endsWith("/")) { r.dirOnly = true; line = line[0 .. $ - 1]; }
            if (line.startsWith("/")) { r.anchored = true; line = line[1 .. $]; }
            else if (line.indexOf('/') >= 0) r.anchored = true;
            if (!line.length) continue;
            try r.re = regex(globToRegex(line));
            catch (Exception) continue;
            rules ~= r;
        }
    }

    /// Is `rel` (relative to root) ignored? Last matching rule wins.
    bool ignored(string rel, bool isDir) const
    {
        bool result;
        foreach (r; rules)
        {
            if (r.dirOnly && !isDir) continue;
            string subject;
            if (r.base.length)
            {
                if (!rel.startsWith(r.base ~ "/")) continue;
                subject = rel[r.base.length + 1 .. $];
            }
            else subject = rel;
            if (!r.anchored) subject = baseName(subject);
            if (!matchFirst(subject, r.re).empty) result = !r.negate;
        }
        return result;
    }
}

/// Whether Read-deny rules hide an absolute path (null: nothing is hidden).
alias Denied = bool delegate(string path);

/// Every regular file under `root` (relative paths, sorted), honouring
/// .gitignore and leaving out paths `denied` hides.
string[] walk(string root, Denied denied = null)
{
    string[] found;
    Ignores ig;
    ig.denied = denied;
    void visit(string relDir)
    {
        ig.load(root, relDir);
        auto saved = ig.rules.length;
        string[] names;
        foreach (DirEntry e; dirEntries(relDir.length ? buildPath(root, relDir) : root, SpanMode.shallow, false))
            names ~= e.name.baseName;
        names.sort();
        foreach (name; names)
        {
            if (name == ".git") continue;
            auto rel = relDir.length ? relDir ~ "/" ~ name : name;
            auto full = buildPath(root, rel);
            if (full.isSymlink) continue;
            bool dir = full.isDir;
            if (ig.ignored(rel, dir)) continue;
            if (denied !is null && denied(full)) continue;
            if (dir) visit(rel);
            else if (full.isFile) found ~= rel;
        }
        ig.rules = ig.rules[0 .. saved];
    }
    visit("");
    found.sort();
    return found;
}

private void readLimit(JSONValue args, out long limit)
{
    limit = optInt(args, "limit", defaultLimit);
    if (limit < 1 || limit > maxLimit) throw new ToolError(format("limit must be between 1 and %s", maxLimit));
}

/// A filename filter: patterns without `/` match the basename at any depth.
private bool delegate(string) globFilter(string pattern)
{
    if (!pattern.length) return (string) => true;
    auto re = regex(globToRegex(pattern));
    bool byName = pattern.indexOf('/') < 0;
    return (string rel) => !matchFirst(byName ? baseName(rel) : rel, re).empty;
}

string grep(JSONValue args, Denied denied = null)
{
    auto pattern = requireString(args, "pattern", "grep");
    auto root = resolvePath(optString(args, "path", "."));
    auto mode = optString(args, "output_mode", "content");
    if (!["content", "files", "count"].canFind(mode)) throw new ToolError(`output_mode must be "content", "files" or "count"`);
    long limit;
    readLimit(args, limit);
    Regex!char re;
    try re = regex(pattern);
    catch (Exception e) throw new ToolError("grep: invalid regular expression: " ~ e.msg);
    if (!root.exists) throw new ToolError(format("grep: %s does not exist", root));
    auto filter = globFilter(optString(args, "glob", ""));
    string[] files;
    string base;
    // A named file is searched even if .gitignore would skip it; deny rules still apply.
    if (root.isFile) { files = denied !is null && denied(root) ? null : [baseName(root)]; base = dirName(root); }
    else { files = walk(root, denied); base = root; }
    auto out_ = appender!string;
    long results;
    bool capped;
    auto cwd = getcwd();
    foreach (rel; files)
    {
        if (!filter(rel)) continue;
        auto full = buildPath(base, rel);
        ubyte[] data;
        try data = cast(ubyte[]) read(full);
        catch (Exception) continue;
        if (looksBinary(data)) continue;
        auto shown = full.startsWith(cwd ~ "/") ? full[cwd.length + 1 .. $] : full;
        long n;
        size_t lineNo;
        foreach (line; (cast(string) data).lineSplitter)
        {
            lineNo++;
            bool hit;
            try hit = !matchFirst(line, re).empty;
            catch (Exception) break; // invalid UTF-8
            if (!hit) continue;
            n++;
            if (mode == "content")
            {
                if (results >= limit) { capped = true; break; }
                auto l = line.length > 500 ? line[0 .. 500] ~ "…" : line;
                out_.put(format("%s:%s:%s\n", shown, lineNo, l));
                results++;
            }
        }
        if (n && mode != "content")
        {
            if (results >= limit) { capped = true; break; }
            out_.put(mode == "files" ? shown ~ "\n" : format("%s:%s\n", shown, n));
            results++;
        }
        if (capped) break;
    }
    if (results == 0) return "(no matches)";
    if (capped) out_.put(format("[limit of %s reached; narrow the search or raise limit]\n", limit));
    return out_.data;
}

string glob(JSONValue args, Denied denied = null)
{
    auto pattern = requireString(args, "pattern", "glob");
    auto root = resolvePath(optString(args, "path", "."));
    long limit;
    readLimit(args, limit);
    if (!root.exists || !root.isDir) throw new ToolError(format("glob: %s is not a directory", root));
    auto filter = globFilter(pattern);
    auto out_ = appender!string;
    long n;
    auto cwd = getcwd();
    foreach (rel; walk(root, denied))
    {
        if (!filter(rel)) continue;
        if (n >= limit)
        {
            out_.put(format("[limit of %s reached; narrow the pattern or raise limit]\n", limit));
            break;
        }
        auto full = buildPath(root, rel);
        out_.put((full.startsWith(cwd ~ "/") ? full[cwd.length + 1 .. $] : full) ~ "\n");
        n++;
    }
    return n ? out_.data : "(no matches)";
}

/// `denied` reports paths Read-deny rules hide from search results.
void register(ToolRegistry tools, Denied denied = null)
{
    tools.register(ToolDefinition("grep",
        "Search file contents under a path for a regular expression. Read-only. Respects .gitignore, skips .git, symlinks and binary files. "
        ~ "Output defaults to matching lines as `path:line:text`; use output_mode `files` for just the paths or `count` for per-file match counts. "
        ~ "Results are sorted by path and capped by `limit` (matching lines in content mode, files otherwise); hitting the cap is reported.",
        parseJSON(`{"type":"object","properties":{
            "pattern":{"type":"string","description":"Regular expression to search for"},
            "path":{"type":"string","description":"File or directory to search (default: working directory)"},
            "glob":{"type":"string","description":"Only search files matching this glob, e.g. \"*.rs\" (any depth) or \"src/**/*.rs\""},
            "output_mode":{"type":"string","enum":["content","files","count"],"description":"Default content"},
            "limit":{"type":"integer","description":"Max results to return (default 250, max 5000)"}},
            "required":["pattern"]}`)),
        (JSONValue a) => grep(a, denied));
    tools.register(ToolDefinition("glob",
        "List files under a path whose name matches a glob pattern. Read-only. A pattern without `/` matches the file name at any depth (\"*.rs\"); "
        ~ "a pattern with `/` matches the path relative to the search root, where `*` stays within one directory and `**` crosses directories (\"src/**/*.rs\"). "
        ~ "Respects .gitignore, skips .git and symlinks. Results are sorted by path and capped by `limit`.",
        parseJSON(`{"type":"object","properties":{
            "pattern":{"type":"string","description":"Glob pattern, e.g. \"*.toml\" or \"src/**/*.rs\""},
            "path":{"type":"string","description":"Directory to list from (default: working directory)"},
            "limit":{"type":"integer","description":"Max paths to return (default 250, max 5000)"}},
            "required":["pattern"]}`)),
        (JSONValue a) => glob(a, denied));
}

unittest
{
    assert(!matchFirst("src/a/b.d", regex(globToRegex("src/**/*.d"))).empty);
    assert(!matchFirst("src/b.d", regex(globToRegex("src/**/*.d"))).empty);
    assert(matchFirst("src/a/b.d", regex(globToRegex("src/*.d"))).empty);
    assert(!matchFirst("x.toml", regex(globToRegex("*.{toml,json}"))).empty);
}

unittest
{
    auto root = buildPath(tempDir, "nano-coder-d-search-test");
    if (root.exists) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "src/deep"));
    mkdirRecurse(buildPath(root, "target"));
    mkdirRecurse(buildPath(root, ".git"));
    write(buildPath(root, ".gitignore"), "target/\n*.log\n!keep.log\n");
    write(buildPath(root, "src/a.d"), "module a;\nint needle = 1;\n");
    write(buildPath(root, "src/deep/b.d"), "needle needle\n");
    write(buildPath(root, "target/out.d"), "needle\n");
    write(buildPath(root, "x.log"), "needle\n");
    write(buildPath(root, "keep.log"), "needle\n");
    write(buildPath(root, ".git/config"), "needle\n");
    write(buildPath(root, "bin.dat"), "needle\0");
    assert(walk(root) == [".gitignore", "bin.dat", "keep.log", "src/a.d", "src/deep/b.d"]);
    JSONValue a = ["pattern": "*.d", "path": root];
    auto g = glob(a);
    assert(g.indexOf("src/a.d") >= 0 && g.indexOf("src/deep/b.d") >= 0 && g.indexOf("target") < 0);
    JSONValue q = ["pattern": "need+le", "path": root, "output_mode": "count"];
    auto c = grep(q);
    assert(c.indexOf("src/deep/b.d:1") >= 0 && c.indexOf("keep.log:1") >= 0 && c.indexOf("bin.dat") < 0);
    JSONValue l = ["pattern": "needle", "path": root];
    l["limit"] = 1;
    assert(grep(l).indexOf("limit of 1 reached") >= 0);
}

unittest
{
    import std.file : mkdirRecurse, write, rmdirRecurse, tempDir;
    auto root = buildPath(tempDir, "nano-d-search-deny");
    if (root.exists) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "secrets"));
    write(buildPath(root, "a.txt"), "token\n");
    write(buildPath(root, ".env"), "token\n");
    write(buildPath(root, "secrets", "k"), "token\n");
    scope (exit) rmdirRecurse(root);
    Denied d = (string p) => p.baseName == ".env" || p.baseName == "secrets";
    auto args = (string extra) => parseJSON(`{"pattern":"token","path":` ~ JSONValue(root).toString ~ extra ~ `}`);
    assert(walk(root, d) == ["a.txt"]);
    auto g = grep(args(`,"output_mode":"files"`), d);
    assert(g.canFind("a.txt") && !g.canFind(".env") && !g.canFind("secrets"), g);
    // A denied file named explicitly is not searched either.
    auto e = grep(parseJSON(`{"pattern":"token","path":` ~ JSONValue(buildPath(root, ".env")).toString ~ `}`), d);
    assert(e == "(no matches)", e);
    assert(!glob(parseJSON(`{"pattern":"*","path":` ~ JSONValue(root).toString ~ `}`), d).canFind(".env"));
}
