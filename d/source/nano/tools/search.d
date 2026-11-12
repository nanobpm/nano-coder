/// Read-only search tools: `grep` and `glob`. Both walk the tree respecting
/// .gitignore files (nested), skip `.git`, symlinks and (for grep) binary files,
/// and return results sorted by path, capped by `limit`.
module nano.tools.search;

@safe:

import nano.safeio : listDir, ownText, readCapped;

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
/// Larger files are skipped, and a file read stops one byte past this, so a
/// growing file or one huge line can't be buffered whole (Rust #160).
enum ulong maxFileBytes = 16 * 1024 * 1024;
/// Rules kept from one .gitignore.
enum size_t maxIgnoreRules = 1_024;
/// Rules compiled across a whole walk; once spent, further .gitignore files
/// add none (fail-open toward visibility, Rust #160).
enum size_t maxTotalIgnoreRules = 16_384;
/// Longer rules are dropped: a rule compiles to a regex that grows with it.
enum size_t maxIgnoreRuleChars = 1_024;

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
    /// Rules this walk may still compile.
    size_t budget = maxTotalIgnoreRules;

    void load(string root, string relDir)
    {
        auto file = buildPath(root, relDir, ".gitignore");
        // Same checks as discovered files: no symlinks or special files, deny
        // rules apply, and the read is bounded.
        if (!file.exists || file.isSymlink || !file.isFile || file.getSize > 1 << 20) return;
        if (denied !is null && denied(file)) return;
        size_t added;
        foreach (raw; readText(file).lineSplitter)
        {
            if (added >= min(maxIgnoreRules, budget)) break;
            IgnoreRule r;
            if (!parseIgnoreLine(raw, relDir, r)) continue;
            rules ~= r;
            ++added;
        }
        budget -= added;
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

/// One .gitignore line as a rule; false for blanks, comments, and over-long
/// or invalid rules.
bool parseIgnoreLine(string raw, string relDir, out IgnoreRule r)
{
    import std.utf : count;
    auto line = raw.strip;
    if (line.count > maxIgnoreRuleChars) return false;
    if (!line.length || line[0] == '#') return false;
    r.base = relDir;
    if (line[0] == '!') { r.negate = true; line = line[1 .. $]; }
    if (line.endsWith("/")) { r.dirOnly = true; line = line[0 .. $ - 1]; }
    if (line.startsWith("/")) { r.anchored = true; line = line[1 .. $]; }
    else if (line.indexOf('/') >= 0) r.anchored = true;
    if (!line.length) return false;
    try r.re = regex(globToRegex(line));
    catch (Exception) return false;
    return true;
}

/// Whether Read-deny rules hide an absolute path (null: nothing is hidden).
alias Denied = bool delegate(string path) @safe;

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
        foreach (DirEntry e; listDir(relDir.length ? buildPath(root, relDir) : root, SpanMode.shallow))
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
private bool delegate(string) @safe globFilter(string pattern)
{
    if (!pattern.length) return (string) => true;
    auto re = regex(globToRegex(pattern));
    bool byName = pattern.indexOf('/') < 0;
    return (string rel) => !matchFirst(byName ? baseName(rel) : rel, re).empty;
}

/// Makes the deny check for a walk under a root (null: nothing is denied).
alias DenyScan = Denied delegate(string root) @safe;

/// ditto: search with the deny check prepared for the search root.
string grep(JSONValue args, DenyScan scan)
{
    auto root = resolvePath(optString(args, "path", "."));
    return grep(args, scan is null ? null : scan(root));
}

/// ditto
string glob(JSONValue args, DenyScan scan)
{
    auto root = resolvePath(optString(args, "path", "."));
    return glob(args, scan is null ? null : scan(root));
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
        try data = readCapped(full, maxFileBytes);
        catch (Exception) continue;
        if (data is null) continue; // over the cap
        if (looksBinary(data)) continue;
        auto shown = full.startsWith(cwd ~ "/") ? full[cwd.length + 1 .. $] : full;
        long n;
        size_t lineNo;
        foreach (line; ownText(data).lineSplitter)
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

/// `scan` prepares, per search root, the check for paths Read-deny rules
/// hide from search results.
void register(ToolRegistry tools, DenyScan denied = null)
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

// rust: search.rs::binary_exclusion_is_independent_of_mode_and_limit
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

// rust: search.rs::read_deny_rules_filter_discovered_files
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

// rust: search.rs::grep_content_is_sorted_with_line_numbers_and_no_ignored_files
// rust: search.rs::grep_files_and_count_modes, search.rs::grep_on_a_single_explicit_file
// rust: search.rs::grep_rejects_bad_arguments, search.rs::grep_reports_limit_truncation_and_no_matches
// rust: search.rs::nested_gitignore_and_negation, search.rs::symlinks_are_not_followed_so_walks_cannot_loop
// rust: search.rs::glob_matches_by_name_and_by_path_sorted, search.rs::grep_glob_filter_limits_by_file_name_and_path
unittest
{
    import std.file : symlink;
    auto root = buildPath(tempDir, "nano-d-search-more");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "b/sub"));
    mkdirRecurse(buildPath(root, "a"));
    write(buildPath(root, "b/.gitignore"), "*.tmp\n!keep.tmp\n");
    write(buildPath(root, "b/x.tmp"), "hit\n");
    write(buildPath(root, "b/keep.tmp"), "hit\n");
    write(buildPath(root, "b/sub/z.txt"), "one\nhit two\n");
    write(buildPath(root, "a/y.txt"), "hit\n");
    symlink(root, buildPath(root, "a/loop"));
    import std.array : replace;
    string rel(string s) { import std.string : stripRight; return s.replace(root ~ "/", "").stripRight; }
    JSONValue j(string extra) { return parseJSON(`{"pattern":"hit","path":` ~ JSONValue(root).toString ~ extra ~ `}`); }
    // Content mode: path:line:text, sorted; nested .gitignore with negation.
    assert(rel(grep(j(``))) == "a/y.txt:1:hit\nb/keep.tmp:1:hit\nb/sub/z.txt:2:hit two", rel(grep(j(``))));
    assert(rel(grep(j(`,"output_mode":"files"`))) == "a/y.txt\nb/keep.tmp\nb/sub/z.txt");
    assert(grep(j(`,"output_mode":"count"`)).canFind("b/sub/z.txt:1"));
    assert(rel(grep(j(`,"glob":"*.txt"`))) == "a/y.txt:1:hit\nb/sub/z.txt:2:hit two");
    assert(rel(grep(j(`,"glob":"b/**/*.txt"`))) == "b/sub/z.txt:2:hit two");
    assert(grep(parseJSON(`{"pattern":"nope","path":` ~ JSONValue(root).toString ~ `}`)) == "(no matches)");
    // A single explicit file.
    auto one = grep(parseJSON(`{"pattern":"two","path":` ~ JSONValue(buildPath(root, "b/sub/z.txt")).toString ~ `}`));
    assert(one.canFind(":2:hit two"), one);
    // Bad arguments are errors.
    bool threw;
    try grep(parseJSON(`{"pattern":"(","path":` ~ JSONValue(root).toString ~ `}`)); catch (ToolError) threw = true;
    assert(threw);
    threw = false;
    try grep(parseJSON(`{"pattern":"x","output_mode":"weird"}`)); catch (ToolError) threw = true;
    assert(threw);
    // Globs match by name at any depth, by path with a slash; symlinks aren't walked.
    assert(rel(glob(parseJSON(`{"pattern":"*.txt","path":` ~ JSONValue(root).toString ~ `}`))) == "a/y.txt\nb/sub/z.txt");
    assert(rel(glob(parseJSON(`{"pattern":"b/*/*.txt","path":` ~ JSONValue(root).toString ~ `}`))) == "b/sub/z.txt");
}

version (unittest)
{
    private string tmpRoot(string name)
    {
        import std.file : mkdirRecurse, rmdirRecurse, tempDir;
        auto root = buildPath(tempDir, name).absolutePath;
        if (root.exists) rmdirRecurse(root);
        mkdirRecurse(root);
        import nano.paths : resolveSymlinks;
        return resolveSymlinks(root);
    }

    private DenyScan scanOf(string[] denyRules, string cwd)
    {
        import nano.permissions : Policy, parseRule, ReadDenyScan;
        Policy p;
        foreach (r; denyRules) p.deny ~= parseRule(r);
        return (string root) @safe {
            ReadDenyScan scan;
            if (!p.readDenyScan(cwd, scan)) return cast(Denied) null;
            auto f = scan.forRoot(root);
            return (string path) @safe => f.denied(path);
        };
    }

    private string files(string pattern, string path, DenyScan scan = null)
    {
        import std.array : replace;
        import std.string : stripRight;
        auto out_ = grep(parseJSON(`{"pattern":` ~ JSONValue(pattern).toString ~ `,"path":` ~ JSONValue(path).toString
            ~ `,"output_mode":"files"}`), scan);
        return out_.replace(path ~ "/", "").stripRight;
    }
}

// Rust #160: resource bounds on the walk and on reads.
// rust: search.rs::search_file_bounds_peak_memory_at_the_cap
// rust: search.rs::capped_reader_stops_at_cap_plus_one_for_over_cap_lines
// rust: search.rs::search_file_accepts_content_just_under_the_cap
// rust: search.rs::global_ignore_rule_budget_spans_directories
// rust: search.rs::oversized_single_ignore_rule_is_dropped
unittest
{
    import std.array : replicate, join;
    import std.file : write, mkdir, rmdirRecurse;
    import nano.safeio : readCapped;
    auto root = tmpRoot("nano-d-search-bounds");
    scope (exit) rmdirRecurse(root);
    // An over-cap single line yields nothing; content exactly at the cap is searched.
    write(buildPath(root, "oneline.log"), "needle " ~ "x".replicate(cast(size_t) maxFileBytes * 2));
    assert(files("needle", root) == "(no matches)");
    write(buildPath(root, "oneline.log"), "needle\n" ~ "x".replicate(cast(size_t) maxFileBytes + 1024));
    assert(files("needle", root) == "(no matches)", "a match before the cap crossing leaked");
    auto exact = "needle\n" ~ "x".replicate(cast(size_t) maxFileBytes - 8) ~ "\n";
    assert(exact.length == maxFileBytes);
    write(buildPath(root, "oneline.log"), exact);
    assert(files("needle", root) == "oneline.log");
    assert(readCapped(buildPath(root, "oneline.log"), 10) is null && readCapped(buildPath(root, "oneline.log"), maxFileBytes).length == maxFileBytes);
    rmdirRecurse(root);
    mkdir(root);
    // The walk-wide rule budget spans directories: once spent, later
    // .gitignore files add nothing.
    enum perDir = 512;
    auto dirs = maxTotalIgnoreRules / perDir + 2;
    string rules;
    foreach (r; 0 .. perDir) rules ~= format("f%s\n", r);
    foreach (i; 0 .. dirs)
    {
        auto sub = buildPath(root, format("d%03d", i));
        mkdir(sub);
        write(buildPath(sub, ".gitignore"), rules);
        write(buildPath(sub, "f0"), "needle\n");
    }
    assert(files("needle", root) == format("d%03d/f0\nd%03d/f0", dirs - 2, dirs - 1), files("needle", root));
    rmdirRecurse(root);
    mkdir(root);
    // An over-long rule is dropped; its neighbours still apply.
    auto longRule = "**/" ~ "a".replicate(maxIgnoreRuleChars * 4);
    IgnoreRule r;
    assert(!parseIgnoreLine(longRule, "", r) && parseIgnoreLine("a".replicate(maxIgnoreRuleChars), "", r));
    write(buildPath(root, ".gitignore"), longRule ~ "\n*.log\n");
    write(buildPath(root, "a.rs"), "needle\n");
    write(buildPath(root, "b.log"), "needle\n");
    assert(files("needle", root) == "a.rs");
}

// rust: search.rs::read_deny_scan_matches_read_denied_without_per_entry_stat
// rust: search.rs::symlinked_search_root_cannot_bypass_read_deny
unittest
{
    import std.file : write, mkdirRecurse, rmdirRecurse, symlink;
    import nano.permissions : Policy, parseRule, ReadDenyScan;
    auto root = tmpRoot("nano-d-search-denyscan");
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "config"));
    mkdirRecurse(buildPath(root, "src"));
    Policy p;
    p.deny ~= parseRule("Read(**/.env)");
    ReadDenyScan scan;
    assert(p.readDenyScan(root, scan));
    assert(scan.denied(buildPath(root, "config/.env")) && !scan.denied(buildPath(root, "src/main.rs")));
    auto alias_ = buildPath(root, "alias");
    symlink(root, alias_);
    assert(p.readDenyScan(alias_, scan));
    assert(scan.denied(buildPath(alias_, "config/.env")), "symlinked cwd leaks a denied path");
    assert(!scan.denied(buildPath(alias_, "src/main.rs")));
    assert(!Policy.init.readDenyScan(root, scan));

    // A symlinked search root can't bypass a rule keyed to the realDir path.
    auto cwd = tmpRoot("nano-d-search-symroot");
    scope (exit) rmdirRecurse(cwd);
    auto realDir = buildPath(cwd, "real");
    mkdirRecurse(realDir);
    write(buildPath(realDir, "secret.txt"), "needle\n");
    write(buildPath(realDir, "open.txt"), "needle\n");
    symlink(realDir, buildPath(cwd, "alias"));
    auto alias2 = buildPath(cwd, "alias");
    auto s = scanOf(["Read(" ~ buildPath(realDir, "secret.txt") ~ ")"], cwd);
    assert(files("needle", alias2, s) == "open.txt", files("needle", alias2, s));
    auto listed = glob(parseJSON(`{"pattern":"**/*","path":` ~ JSONValue(alias2).toString ~ `}`), s);
    assert(listed.canFind("open.txt") && !listed.canFind("secret.txt"), listed);
    assert(grep(parseJSON(`{"pattern":"needle","path":` ~ JSONValue(buildPath(alias2, "secret.txt")).toString ~ `}`), s)
        == "(no matches)");
    s = scanOf(["Read(**/alias/secret.txt)"], cwd);
    assert(files("needle", alias2, s) == "open.txt");
    assert(files("needle", realDir, s) == "open.txt\nsecret.txt", "real walk wrongly filtered");
    s = scanOf(["Read(real/secret.txt)"], cwd);
    assert(files("needle", alias2, s) == "open.txt", "cwd-relative resolved rule bypassed via alias");
    s = scanOf(["Read(alias/secret.txt)"], cwd);
    assert(files("needle", alias2, s) == "open.txt", "root-relative alias rule not honoured");
    s = scanOf(["Read(other/secret.txt)"], cwd);
    assert(files("needle", alias2, s) == "open.txt\nsecret.txt");
}
