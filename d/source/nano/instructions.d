/// Instruction files: the user's own (`~/.claude/CLAUDE.md`, `~/.agents/AGENTS.md`,
/// `~/.claude/rules/`) and the repository's (AGENTS.md and friends,
/// `CLAUDE.local.md`, `.claude/rules/`), with Claude Code's `@path` imports
/// (port of `instructions.rs`).
///
/// At session start the user's files come first, then the files from the git
/// root down to the working directory, outermost first. Files in deeper
/// directories, and rules scoped with `paths:` front matter, are attached to
/// the first file-tool result that touches a matching path.
///
/// Imports in project files may not leave the repository unless
/// `instruction_imports_outside_project` is set: a committed `CLAUDE.md` must
/// not be able to send `~/.ssh/...` to the model provider.
module nano.instructions;

import std.algorithm : canFind, startsWith, endsWith, countUntil, sort, filter;
import std.array : array, join, split;
import std.format : format;
import std.path : buildPath, baseName, dirName, extension;
import std.regex : Regex, regex, matchFirst;
import std.string : strip, stripLeft, stripRight, indexOf, lineSplitter, KeepTerminator;
import std.uni : isWhite;
import nano.paths : canonicalize, startsWithPath, isSymlink, homeDir;

/// Per-file cap; longer files are truncated with a note.
enum size_t maxFileBytes = 32 * 1024;
/// Cap on everything added to the system prompt (and to one tool result).
enum size_t maxTotalBytes = 64 * 1024;
/// Imports nest at most this deep (Claude Code: four hops).
enum size_t maxImportDepth = 4;
/// Patterns one rule's `paths` may expand to (brace expansion).
enum size_t maxRulePatterns = 1_000;

immutable string[] defaultFiles = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".github/copilot-instructions.md"];
/// Personal per-directory files, loaded after the main file (not committed).
immutable string[] localFiles = ["CLAUDE.local.md"];
immutable string[] defaultUserFiles = ["~/.claude/CLAUDE.md", "~/.agents/AGENTS.md"];
immutable string[] defaultUserRulesDirs = ["~/.claude/rules"];
/// Project rules directory, relative to the git root.
enum projectRulesDir = ".claude/rules";

private enum omittedMarker = "\n\n[omitted: instruction size limit reached; read the remaining files with read_file]";

/// Where a loaded file came from.
enum Kind { user, project, local, rule, imported }

struct InstructionFile
{
    string path, text;
    Kind kind;
    /// For `Kind.imported`: the file whose `@path` imported this one.
    string importedBy;
    /// From the user's own configuration rather than the repository.
    bool user;
    /// The directory whose search loaded this file (also via imports), or
    /// null for user files loaded outside any directory search.
    string searchDir;
}

/// What to load besides the per-directory project files.
struct Options
{
    /// File names tried in each directory; the first that exists is used.
    string[] names;
    /// User instruction files (`~` already expanded); all that exist load.
    string[] userFiles;
    /// User rules directories.
    string[] userRulesDirs;
    /// Let imports in project files resolve outside the repository.
    bool importsOutsideProject;

    static Options project(const string[] names) { Options o; o.names = names.dup; return o; }
}

private struct ScopedRule
{
    string path;
    /// The body alone; imports resolve when the rule attaches.
    string body;
    Regex!char[] patterns;
    bool attached, user;
}

/// The nearest ancestor (or `start`) holding `.git`, or null.
string gitRoot(string start)
{
    import std.file : exists;
    for (auto d = start;;)
    {
        if (exists(buildPath(d, ".git"))) return d;
        auto up = d.dirName;
        if (up == d) return null;
        d = up;
    }
}

/// Expand a leading `~` (alone or `~/…`) to the home directory.
string expandHome(string path)
{
    auto home = homeDir();
    if (home is null) return path;
    if (path == "~") return home;
    if (path.startsWith("~/")) return buildPath(home, path[2 .. $]);
    return path;
}

private bool isFile_(string p) @trusted
{
    import std.file : exists, isFile;
    try return exists(p) && isFile(p);
    catch (Exception) return false;
}

private bool isDir_(string p) @trusted
{
    import std.file : exists, isDir;
    try return exists(p) && isDir(p);
    catch (Exception) return false;
}

private string canonOr(string p) { auto c = canonicalize(p); return c !is null ? c : p; }

/// A file's text (HTML comments stripped, trimmed, capped), or null when it is
/// missing, unreadable or empty.
string readCapped(string path) @trusted
{
    import std.file : read;
    import std.encoding : sanitize;
    if (!isFile_(path)) return null;
    string raw;
    try raw = sanitize(cast(string) read(path));
    catch (Exception) return null;
    auto text = stripHtmlComments(raw).strip;
    if (!text.length) return null;
    if (text.length <= maxFileBytes) return text;
    size_t end = maxFileBytes;
    while (end > 0 && (text[end] & 0xC0) == 0x80) --end;
    return format("%s\n\n[... truncated: %s of %s bytes shown; read the full file with read_file]", text[0 .. end],
        end, text.length);
}

/// Strip leading blockquote markers; returns the content and the depth.
private string stripBlockquote(string line, out size_t depth)
{
    auto rest = line;
    for (;;)
    {
        size_t spaces;
        while (spaces < rest.length && rest[spaces] == ' ') ++spaces;
        if (spaces > 3 || spaces >= rest.length || rest[spaces] != '>') break;
        rest = rest[spaces + 1 .. $];
        if (rest.startsWith(" ")) rest = rest[1 .. $];
        ++depth;
    }
    return rest;
}

/// 0–3 leading spaces before a fence marker, or -1 (a tab or 4+ spaces).
private ptrdiff_t fenceIndent(string line)
{
    size_t spaces;
    while (spaces < line.length && line[spaces] == ' ') ++spaces;
    if (spaces > 3 || line[spaces .. $].startsWith("\t")) return -1;
    return spaces;
}

private struct Fence
{
    char ch;
    size_t run, depth;
}

/// The opening fence on this line, if any.
private bool fence(string line, out Fence f)
{
    size_t depth;
    line = stripBlockquote(line, depth);
    auto indent = fenceIndent(line);
    if (indent < 0) return false;
    auto t = line[indent .. $];
    if (!t.length || (t[0] != '`' && t[0] != '~')) return false;
    auto ch = t[0];
    size_t run;
    while (run < t.length && t[run] == ch) ++run;
    if (run < 3) return false;
    if (ch == '`' && t[run .. $].canFind('`')) return false;
    f = Fence(ch, run, depth);
    return true;
}

/// Whether this line closes `open` (same container, a long-enough bare run).
private bool closesFence(string line, Fence open)
{
    size_t depth;
    line = stripBlockquote(line, depth);
    if (depth != open.depth) return false;
    auto indent = fenceIndent(line);
    if (indent < 0) return false;
    auto t = line[indent .. $];
    size_t run;
    while (run < t.length && t[run] == open.ch) ++run;
    return run >= open.run && !t[run .. $].strip.length;
}

/// An indented code line (4+ spaces or a leading tab).
private bool isIndentedCode(string line)
{
    size_t depth;
    line = stripBlockquote(line, depth);
    size_t spaces;
    foreach (c; line)
    {
        if (c == ' ') { if (++spaces >= 4) return true; }
        else return c == '\t';
    }
    return false;
}

/// Remove block-level `<!-- ... -->` comments outside code, as Claude Code does.
string stripHtmlComments(string text)
{
    string out_;
    bool inFence, inComment;
    Fence open;
    foreach (line; text.lineSplitter!(KeepTerminator.yes))
    {
        if (inComment)
        {
            auto end = line.indexOf("-->");
            if (end >= 0)
            {
                inComment = false;
                auto rest = line[end + 3 .. $];
                if (rest.strip.length) out_ ~= rest;
            }
            continue;
        }
        if (inFence)
        {
            if (closesFence(line, open)) inFence = false;
            out_ ~= line;
            continue;
        }
        Fence f;
        if (fence(line, f))
        {
            inFence = true;
            open = f;
            out_ ~= line;
            continue;
        }
        if (isIndentedCode(line)) { out_ ~= line; continue; }
        auto t = line.stripLeft;
        if (t.startsWith("<!--"))
        {
            auto body = t[4 .. $];
            auto end = body.indexOf("-->");
            if (end >= 0)
            {
                auto rest = body[end + 3 .. $];
                if (rest.strip.length) out_ ~= rest;
            }
            else inComment = true;
            continue;
        }
        out_ ~= line;
    }
    return out_;
}

/// `@path` references outside code spans and fenced blocks, in order. A
/// reference starts a line or follows whitespace or `(`; `\ ` continues a path.
string[] importRefs(string text)
{
    import std.conv : to;
    string[] refs;
    bool inFence;
    Fence open;
    size_t spanTicks; // 0 = no code span open
    foreach (line; text.lineSplitter)
    {
        if (inFence)
        {
            if (closesFence(line, open)) inFence = false;
            continue;
        }
        Fence f;
        if (!spanTicks && fence(line, f)) { inFence = true; open = f; continue; }
        if (!spanTicks && isIndentedCode(line)) continue;
        auto chars = line.to!(dchar[]);
        size_t i;
        auto t = line.stripLeft;
        if (!spanTicks && (t.startsWith("```") || t.startsWith("~~~")))
        {
            while (i < chars.length && chars[i] == ' ') ++i;
            auto fc = chars[i];
            while (i < chars.length && chars[i] == fc) ++i;
        }
        while (i < chars.length)
        {
            auto c = chars[i];
            if (c == '`')
            {
                auto start = i;
                while (i < chars.length && chars[i] == '`') ++i;
                auto run = i - start;
                if (!spanTicks) spanTicks = run;
                else if (spanTicks == run) spanTicks = 0;
                continue;
            }
            bool starts = i == 0 || isWhite(chars[i - 1]) || chars[i - 1] == '(';
            if (spanTicks || c != '@' || !starts) { ++i; continue; }
            dchar[] path;
            auto j = i + 1;
            while (j < chars.length)
            {
                auto ch = chars[j];
                if (ch == '\\' && j + 1 < chars.length && chars[j + 1] == ' ') { path ~= ' '; j += 2; }
                else if (isWhite(ch) || ch == '`') break;
                else { path ~= ch; ++j; }
            }
            if (path.length && path[0] != '"' && path[0] != '\'') refs ~= path.to!string;
            i = j;
        }
    }
    return refs;
}

/// `@path` imports expand in Claude-format files only: in `AGENTS.md` an
/// `@name` is a mention.
private bool expandsImports(string path, Kind kind)
{
    auto n = path.baseName;
    return kind == Kind.rule || kind == Kind.imported || n == "CLAUDE.md" || n == "CLAUDE.local.md";
}

/// Split a rule's front matter into its `paths` (hasPaths false: applies
/// everywhere) and the body. Accepts a YAML list, `[a, b]` or `a, b`.
string ruleFrontMatter(string text, out bool hasPaths, out string[] paths)
{
    auto lines = text.lineSplitter!(KeepTerminator.yes).array;
    if (!lines.length || lines[0].stripRight != "---") return text;
    size_t offset = lines[0].length;
    string[] yaml;
    bool closed;
    foreach (line; lines[1 .. $])
    {
        offset += line.length;
        if (line.stripRight == "---") { closed = true; break; }
        yaml ~= line.stripRight;
    }
    if (!closed) return text;
    static string unquote(string s)
    {
        s = s.strip;
        bool quoted = s.length >= 2 && ((s[0] == '"' && s[$ - 1] == '"') || (s[0] == '\'' && s[$ - 1] == '\''));
        return quoted ? s[1 .. $ - 1] : s;
    }
    bool inList;
    foreach (line; yaml)
    {
        if (inList)
        {
            auto t = line.stripLeft;
            if (t.startsWith("-") && line.length && (line[0] == ' ' || line[0] == '\t' || line[0] == '-'))
            {
                hasPaths = true;
                paths ~= unquote(t[1 .. $]);
                continue;
            }
            inList = false;
        }
        if (!line.startsWith("paths:")) continue;
        auto value = line[6 .. $].strip;
        if (!value.length)
        {
            inList = true;
            hasPaths = true;
            continue;
        }
        auto inner = value.startsWith("[") && value.endsWith("]") ? value[1 .. $ - 1] : value;
        paths = null;
        foreach (p; splitTopLevel(inner)) paths ~= unquote(p);
        hasPaths = true;
    }
    string[] kept;
    foreach (p; paths) if (p.length) kept ~= p;
    paths = kept;
    return text[offset < text.length ? offset : text.length .. $];
}

/// Split on top-level commas only (not inside `{a,b}` or quotes).
private string[] splitTopLevel(string value)
{
    string[] out_;
    size_t depth, start;
    char quote = 0;
    foreach (i, c; value)
    {
        if (quote) { if (c == quote) quote = 0; continue; }
        if (c == '"' || c == '\'') quote = c;
        else if (c == '{') ++depth;
        else if (c == '}') { if (depth) --depth; }
        else if (c == ',' && !depth) { out_ ~= value[start .. i]; start = i + 1; }
    }
    return out_ ~ value[start .. $];
}

/// Expand `{a,b}` groups; past `budget` patterns, keep the rest unexpanded.
private string[] expandBraces(string pattern, ref size_t budget)
{
    auto open = pattern.indexOf('{');
    if (open < 0) return [pattern];
    auto c = pattern[open .. $].indexOf('}');
    if (c < 0) return [pattern];
    auto close = open + c;
    auto alternatives = pattern[open + 1 .. close].split(",");
    if (alternatives.length < 2 || budget < alternatives.length) return [pattern];
    budget -= alternatives.length;
    string[] out_;
    foreach (alt; alternatives) out_ ~= expandBraces(pattern[0 .. open] ~ alt ~ pattern[close + 1 .. $], budget);
    return out_;
}

private Regex!char[] compilePatterns(const string[] patterns)
{
    import nano.permissions : pathGlob;
    size_t budget = maxRulePatterns;
    Regex!char[] out_;
    foreach (p; patterns)
    {
        string q = p;
        while (q.startsWith("./")) q = q[2 .. $];
        foreach (e; expandBraces(q, budget))
        {
            try out_ ~= regex(pathGlob(e));
            catch (Exception) {}
        }
    }
    return out_;
}

/// `.md` files under `dir`, sorted, following symlinks without looping; with
/// `allowOutside` false, directories whose real path leaves `root` are skipped.
private string[] markdownFiles(string dir, string root, bool allowOutside) @trusted
{
    import std.file : dirEntries, SpanMode;
    bool[string] visited;
    string[] out_;
    void walk(string d)
    {
        auto real_ = canonicalize(d);
        if (real_ is null) return;
        if (!allowOutside && !startsWithPath(real_, root)) return;
        if (real_ in visited) return;
        visited[real_] = true;
        string[] paths;
        try foreach (e; dirEntries(d, SpanMode.shallow, false)) paths ~= e.name;
        catch (Exception) return;
        paths.sort();
        foreach (p; paths)
        {
            if (isDir_(p))
            {
                if (!allowOutside && isSymlink(p))
                {
                    auto target = canonicalize(p);
                    if (target !is null && !startsWithPath(target, root)) continue;
                }
                walk(p);
            }
            else if (p.extension == ".md" && isFile_(p)) out_ ~= p;
        }
    }
    walk(dir);
    return out_;
}

/// Canonicalize the longest existing prefix, so files that do not exist yet
/// still resolve symlinked roots.
private string canonicalizeExisting(string path)
{
    for (auto base = path;;)
    {
        if (auto r = canonicalize(base))
        {
            auto rest = path[base.length .. $];
            while (rest.startsWith("/")) rest = rest[1 .. $];
            return rest.length ? buildPath(r, rest) : r;
        }
        auto up = base.dirName;
        if (up == base) return path;
        base = up;
    }
}

/// The instruction files for one working directory.
class ProjectInstructions
{
    /// Git root (or the working directory outside a repository).
    string root;
    Options options;
    /// Files in the system prompt, in order.
    InstructionFile[] loaded;
    /// Files skipped, with the reason (imports outside the repository, ...).
    string[] warnings;
    private bool[string] searched, initial, seen, initialSeen;
    private string currentSearchDir;
    private ScopedRule[] scoped;
    /// Nested files already attached to a tool result by `nestedFor`.
    private string[] nestedAttached;

    /// Find the user's and the project's instruction files for `cwd`.
    static ProjectInstructions discover(string cwd, Options options)
    {
        auto p = new ProjectInstructions;
        cwd = canonOr(cwd);
        p.root = gitRoot(cwd);
        if (p.root is null) p.root = cwd;
        p.options = options;
        foreach (f; options.userFiles) p.load(f, Kind.user, null, true, 0, false, null);
        foreach (d; options.userRulesDirs) p.loadRules(d, true);
        string[] dirs;
        for (auto d = cwd; startsWithPath(d, p.root);)
        {
            dirs = d ~ dirs;
            auto up = d.dirName;
            if (up == d) break;
            d = up;
        }
        foreach (i, d; dirs)
        {
            p.search(d);
            if (i == 0) p.loadRules(buildPath(p.root, projectRulesDir), false);
        }
        p.initial = p.searched.dup;
        p.initialSeen = p.seen.dup;
        return p;
    }

    /// Load one directory's files (the first of `names`, then the local
    /// files); returns the range added to `loaded`.
    private size_t[2] search(string dir)
    {
        if (dir in searched) return [loaded.length, loaded.length];
        searched[dir] = true;
        // Files deferred by an earlier budget overflow come back first.
        InstructionFile[] pending, kept;
        foreach (f; loaded) (f.searchDir !is null && f.searchDir == dir ? pending : kept) ~= f;
        loaded = kept;
        auto start = loaded.length;
        loaded ~= pending;
        currentSearchDir = dir;
        foreach (n; options.names)
        {
            auto path = buildPath(dir, n);
            if (readCapped(path) !is null)
            {
                load(path, Kind.project, null, false, 0, false, null);
                break;
            }
        }
        foreach (n; localFiles) load(buildPath(dir, n), Kind.local, null, false, 0, false, null);
        currentSearchDir = null;
        return [start, loaded.length];
    }

    private bool inside(string path)
    {
        auto real_ = canonicalize(path);
        return real_ !is null && startsWithPath(real_, canonOr(root));
    }

    /// Load one file (if it exists and is new) and, for Claude-format files,
    /// its imports. `body` (when `hasBody`) replaces the on-disk text.
    private void load(string path, Kind kind, string importedBy, bool user, size_t depth, bool hasBody, string body)
    {
        auto disk = readCapped(path);
        if (disk is null) return;
        if (!user && !options.importsOutsideProject && !inside(path))
        {
            warn(format("skipped %s: links outside the repository (set instruction_imports_outside_project = true to allow)",
                display(path)));
            return;
        }
        auto real_ = canonOr(path);
        if (real_ in seen) return;
        seen[real_] = true;
        auto text = hasBody ? body : disk;
        auto refs = expandsImports(path, kind) ? importRefs(text) : null;
        loaded ~= InstructionFile(path, text, kind, importedBy, user, currentSearchDir);
        if (depth >= maxImportDepth) return;
        foreach (r; refs)
            if (auto target = resolveImport(path, r, user))
                load(target, Kind.imported, path, user, depth + 1, false, null);
    }

    /// A scoped rule's body with its imports, resolved when it attaches.
    private string resolveScopedRule(string path, string body, bool user)
    {
        auto real_ = canonOr(path);
        if (real_ in seen) return null;
        seen[real_] = true;
        auto out_ = body;
        appendRuleImports(path, body, user, 0, out_);
        return out_;
    }

    private void appendRuleImports(string from, string text, bool user, size_t depth, ref string out_)
    {
        if (depth >= maxImportDepth) return;
        foreach (r; importRefs(text))
        {
            auto target = resolveImport(from, r, user);
            if (target is null) continue;
            auto real_ = canonOr(target);
            if (real_ in seen) continue;
            seen[real_] = true;
            auto imported = readCapped(target);
            if (imported is null) continue;
            out_ ~= format("\n\n## %s (imported by %s)\n\n%s", display(target), display(from), imported);
            appendRuleImports(target, imported, user, depth + 1, out_);
        }
    }

    /// Resolve `@reference` in `from`. Missing files are mentions and are
    /// ignored; project imports outside the repository are skipped with a
    /// warning unless allowed.
    private string resolveImport(string from, string reference, bool user)
    {
        auto trimmed = reference;
        while (trimmed.length && ".,;:)!?".canFind(trimmed[$ - 1])) trimmed = trimmed[0 .. $ - 1];
        string target;
        foreach (r; [reference, trimmed])
        {
            if (!r.length) continue;
            auto p = r.startsWith("~") ? expandHome(r) : r.startsWith("/") ? r : buildPath(from.dirName, r);
            if (isFile_(p)) { target = p; break; }
        }
        if (target is null) return null;
        if (!user && !options.importsOutsideProject)
        {
            auto real_ = canonicalize(target);
            if (real_ is null) return null;
            if (!startsWithPath(real_, canonOr(root)))
            {
                warn(format("skipped import @%s in %s: outside the repository (set instruction_imports_outside_project = true to allow)",
                    reference, display(from)));
                return null;
            }
        }
        return target;
    }

    /// Rules under `dir`: unscoped ones load now, `paths:` ones on demand.
    private void loadRules(string dir, bool user)
    {
        auto rootc = canonOr(root);
        auto allowOutside = user || options.importsOutsideProject;
        foreach (path; markdownFiles(dir, rootc, allowOutside))
        {
            if (!allowOutside)
            {
                auto real_ = canonicalize(path);
                if (real_ is null || !startsWithPath(real_, rootc))
                {
                    warn(format("skipped rule %s: links outside the repository (set instruction_imports_outside_project = true to allow)",
                        display(path)));
                    continue;
                }
            }
            auto text = readCapped(path);
            if (text is null) continue;
            bool hasPaths;
            string[] patterns;
            auto body = ruleFrontMatter(text, hasPaths, patterns).strip;
            if (!body.length) continue;
            if (hasPaths)
            {
                auto compiled = compilePatterns(patterns);
                if (!compiled.length)
                {
                    warn(format("rule %s has no usable paths patterns", display(path)));
                    continue;
                }
                scoped ~= ScopedRule(path, body, compiled, false, user);
            }
            // Front matter without `paths` is dropped; imports expand from the body only.
            else load(path, Kind.rule, null, user, 0, true, body);
        }
    }

    /// Record a diagnostic once.
    private void warn(string message)
    {
        if (!warnings.canFind(message)) warnings ~= message;
    }

    /// Repository-relative, `~/`-relative, or as given.
    string display(string path)
    {
        if (path == root) return "";
        if (startsWithPath(path, root)) return path[root.length + (root.endsWith("/") ? 0 : 1) .. $];
        auto home = homeDir();
        if (home !is null && startsWithPath(path, home) && path != home)
            return "~/" ~ path[home.length + (home.endsWith("/") ? 0 : 1) .. $];
        return path;
    }

    private string heading(const ref InstructionFile f)
    {
        final switch (f.kind)
        {
            case Kind.imported: return format("%s (imported by %s)", display(f.path), display(f.importedBy));
            case Kind.rule: return display(f.path) ~ " (rule)";
            case Kind.local: return display(f.path) ~ " (personal, not committed)";
            case Kind.user, Kind.project: return display(f.path);
        }
    }

    /// Text appended to the system prompt (empty when nothing was found).
    string render()
    {
        string out_;
        size_t budget = maxTotalBytes - omittedMarker.length;
        bool truncated;
        static immutable groups = [
            "\n\n# Your instructions\n\nThese instruction files are the user's own, for every project. Follow them.",
            "\n\n# Repository instructions\n\nThese instruction files come from the repository you are working in. "
                ~ "Read and follow them before and while making changes. Files in deeper directories refine the ones above them.",
        ];
        outer: foreach (g, header; groups)
        {
            bool user = g == 0;
            InstructionFile[] files;
            foreach (f; loaded)
                if (f.user == user && (f.searchDir is null || f.searchDir in initial)) files ~= f;
            if (!files.length) continue;
            if (header.length > budget) { truncated = true; break; }
            budget -= header.length;
            out_ ~= header;
            foreach (ref f; files)
            {
                auto section = format("\n\n## %s\n\n%s", heading(f), f.text);
                if (section.length > budget) { truncated = true; break outer; }
                budget -= section.length;
                out_ ~= section;
            }
        }
        if (truncated) out_ ~= omittedMarker;
        return out_;
    }

    /// Instructions that apply to `path` and were not shown yet: files in the
    /// directories between it and the root (outermost first), then rules whose
    /// `paths` match. Rendered for a tool result; null when there are none.
    string nestedFor(string path, string cwd)
    {
        auto absolute = canonicalizeExisting(path.startsWith("/") ? path : buildPath(cwd, path));
        auto dir = isDir_(absolute) ? absolute : absolute.dirName;
        string[] dirs;
        for (auto d = dir; startsWithPath(d, root);)
        {
            dirs = d ~ dirs;
            auto up = d.dirName;
            if (up == d) break;
            d = up;
        }
        if (!dirs.length) return null;
        string out_;
        size_t budget = maxTotalBytes - omittedMarker.length;
        bool truncated;
        foreach (d; dirs)
        {
            auto range = search(d);
            auto files = loaded[range[0] .. range[1]].dup;
            loaded = loaded[0 .. range[0]] ~ loaded[range[1] .. $];
            size_t rendered;
            foreach (ref f; files)
            {
                string note;
                if (f.kind == Kind.imported)
                    note = format("[%s (imported by %s) applies with it:]", display(f.path), display(f.importedBy));
                else
                {
                    auto scope_ = display(f.searchDir !is null ? f.searchDir : f.path.dirName);
                    note = format("[Instructions from %s apply to files under %s/. Follow them for changes there:]",
                        display(f.path), scope_.length ? scope_ : ".");
                }
                auto section = format("\n\n%s\n%s", note, f.text);
                if (section.length > budget)
                {
                    searched.remove(d);
                    warn(format("deferred %s: instruction size limit reached; it stays pending and attaches once budget "
                        ~ "frees (e.g. after compaction)", display(f.path)));
                    truncated = true;
                    break;
                }
                budget -= section.length;
                out_ ~= section;
                ++rendered;
            }
            foreach (ref f; files[0 .. rendered]) nestedAttached ~= f.path;
            loaded ~= files[rendered .. $];
            if (truncated) break;
        }
        if (!truncated && startsWithPath(absolute, root))
        {
            auto rel = absolute == root ? "" : display(absolute);
            foreach (i; 0 .. scoped.length)
            {
                if (scoped[i].attached) continue;
                bool hit;
                foreach (re; scoped[i].patterns) if (!matchFirst(rel, re).empty) { hit = true; break; }
                if (!hit) continue;
                auto checkpoint = seen.dup;
                auto text = resolveScopedRule(scoped[i].path, scoped[i].body, scoped[i].user);
                if (text is null) { scoped[i].attached = true; continue; }
                auto section = format("\n\n[Rule %s applies to %s. Follow it for changes to matching files:]\n%s",
                    display(scoped[i].path), rel, text);
                if (section.length > budget)
                {
                    seen = checkpoint;
                    warn(format("deferred rule %s: instruction size limit reached; it stays pending and attaches once "
                        ~ "budget frees (e.g. after compaction)", display(scoped[i].path)));
                    truncated = true;
                    break;
                }
                budget -= section.length;
                out_ ~= section;
                scoped[i].attached = true;
            }
        }
        if (truncated) out_ ~= omittedMarker;
        return out_.length ? out_ : null;
    }

    /// After compaction, nested instructions attached to old tool results may
    /// be gone: let them attach again.
    void forgetNested()
    {
        searched = initial.dup;
        seen = initialSeen.dup;
        InstructionFile[] kept;
        foreach (f; loaded) if (f.searchDir is null || f.searchDir in initial) kept ~= f;
        loaded = kept;
        nestedAttached = null;
        foreach (ref r; scoped) r.attached = false;
    }

    /// Files in the prompt, for the banner, `/context` and ACP.
    string[] loadedPaths()
    {
        string[] out_;
        foreach (f; loaded) out_ ~= f.path;
        out_ ~= nestedAttached;
        foreach (r; scoped) if (r.attached) out_ ~= r.path;
        return out_;
    }

    /// Rules attached only when a matching file is touched.
    string[] onDemandPaths()
    {
        string[] out_;
        foreach (r; scoped) if (!r.attached) out_ ~= r.path;
        return out_;
    }
}

version (unittest)
{
    private string testDir(string name) @trusted
    {
        import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists;
        auto d = buildPath(canonicalize(tempDir), "nano-d-instr-" ~ name);
        if (exists(d)) rmdirRecurse(d);
        mkdirRecurse(buildPath(d, "repo", ".git"));
        return d;
    }

    private void put(string path, string text) @trusted
    {
        import std.file : mkdirRecurse, write;
        mkdirRecurse(path.dirName);
        write(path, text);
    }

    private ProjectInstructions find(string cwd) { return ProjectInstructions.discover(cwd, Options.project(defaultFiles)); }

    private string[] texts(ProjectInstructions p)
    {
        string[] t;
        foreach (f; p.loaded) t ~= f.text;
        return t;
    }
}

unittest // root to leaf, fallbacks, nested files once
{
    import std.file : rmdirRecurse, mkdirRecurse;
    auto base = testDir("leaf");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    put(buildPath(root, ".github/copilot-instructions.md"), "root copilot");
    put(buildPath(root, "app/CLAUDE.md"), "app claude");
    put(buildPath(root, "app/AGENTS.md"), "app agents");
    put(buildPath(root, "lib/AGENTS.md"), "lib rules");
    put(buildPath(root, "lib/core/AGENTS.md"), "   ");
    mkdirRecurse(buildPath(root, "app/web/src"));
    auto p = find(buildPath(root, "app/web"));
    assert(texts(p) == ["root copilot", "app agents"], texts(p).join("|"));
    auto r = p.render;
    assert(r.indexOf("root copilot") < r.indexOf("app agents") && r.canFind("## app/AGENTS.md") && !r.canFind("# Your instructions"));
    assert(p.nestedFor(buildPath(root, "app/web/src/main.rs"), root) is null);
    auto nested = p.nestedFor(buildPath(root, "lib/core/x.rs"), root);
    assert(nested.canFind("lib/AGENTS.md apply to files under lib/") && nested.canFind("lib rules"), nested);
    assert(p.nestedFor(buildPath(root, "lib/y.rs"), root) is null);
    p.forgetNested();
    assert(p.nestedFor("lib/y.rs", root) !is null, "relative paths resolve against cwd");
    assert(p.nestedFor("/elsewhere/file", root) is null);
}

unittest // outside a repository only the working directory counts; per-file cap
{
    import std.file : rmdirRecurse, mkdirRecurse;
    import std.array : replicate;
    auto base = testDir("norepo");
    scope (exit) rmdirRecurse(base);
    auto cwd = buildPath(base, "work");
    mkdirRecurse(cwd);
    put(buildPath(base, "AGENTS.md"), "parent");
    put(buildPath(cwd, "AGENTS.md"), "x".replicate(maxFileBytes + 10));
    auto p = find(cwd);
    assert(p.loaded.length == 1 && p.loaded[0].text.canFind("[... truncated") && p.loaded[0].text.canFind("read_file"));
}

unittest // user files first; local files follow the main file
{
    import std.file : rmdirRecurse;
    auto base = testDir("user");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo"), home = buildPath(base, "home");
    put(buildPath(home, ".claude/CLAUDE.md"), "user claude");
    put(buildPath(home, ".claude/rules/style.md"), "user rule");
    put(buildPath(root, "AGENTS.md"), "root agents");
    put(buildPath(root, "CLAUDE.md"), "root claude (AGENTS.md wins)");
    put(buildPath(root, "CLAUDE.local.md"), "root local");
    put(buildPath(root, "sub/.claude/CLAUDE.md"), "sub dot-claude");
    Options o;
    o.names = defaultFiles.dup;
    o.userFiles = [buildPath(home, ".claude/CLAUDE.md"), buildPath(home, ".agents/AGENTS.md")];
    o.userRulesDirs = [buildPath(home, ".claude/rules")];
    auto p = ProjectInstructions.discover(buildPath(root, "sub"), o);
    assert(texts(p) == ["user claude", "user rule", "root agents", "root local", "sub dot-claude"], texts(p).join("|"));
    assert(p.loaded[0].user && p.loaded[1].user && !p.loaded[2].user);
    auto r = p.render;
    auto u = r.indexOf("# Your instructions"), rep = r.indexOf("# Repository instructions");
    assert(u < r.indexOf("user rule") && r.indexOf("user rule") < rep);
    assert(r.canFind("## CLAUDE.local.md (personal, not committed)") && r.canFind("style.md (rule)"));
}

unittest // import scanning: code spans, fences, blockquotes
{
    assert(importRefs("See `` @a.md `` and @b.md") == ["b.md"]);
    assert(!importRefs("`` @secret.md ``").length);
    assert(importRefs("a `span\n@inside.md` @out.md") == ["out.md"]);
    assert(importRefs("````\n@secret.md\n```\nstill inside\n<!-- keep -->\n````\n@after.md") == ["after.md"]);
    assert(importRefs("~~~\n@a.md\n```\n@b.md\n~~~\n@c.md") == ["c.md"]);
    assert(importRefs("```\n@secret.md\n```not-a-close\n@still.md\n```\n@after.md") == ["after.md"]);
    assert(importRefs("```\n@secret.md\n    ```\n@still.md\n```\n@after.md") == ["after.md"]);
    assert(importRefs("   ```\n@in.md\n   ```\n@out.md") == ["out.md"]);
    assert(importRefs("``` `code`\n@live.md") == ["live.md"]);
    assert(!importRefs("> ```\n> @secret.md\n> ```").length);
    assert(importRefs("> ```\n> @hidden.md\n> ```\n@real.md") == ["real.md"]);
    assert(!importRefs(">     @secret.md").length && importRefs("> @real.md") == ["real.md"]);
    assert(importRefs("```\n> ```\n@secret.md\n```\n@after.md") == ["after.md"]);
    assert(importRefs("> ```\n```\n> @secret.md\n> ```\n@after.md") == ["after.md"]);
    assert(importRefs(`mail a@b.c, see (@x.md) and @my\ file.md "@q"`) == ["x.md)", "my file.md"]);
    assert(strip_("keep\n<!-- one line -->\n<!-- multi\nline -->\nafter\n```\n<!-- in code -->\n```\n")
        == "keep\nafter\n```\n<!-- in code -->\n```\n");
    assert(strip_("```\n> ```\n<!-- kept -->\n```").canFind("<!-- kept -->"));
    assert(strip_("    <!-- code -->\n").canFind("<!-- code -->"));
}

private string strip_(string s) { return stripHtmlComments(s); }

unittest // front matter and brace groups
{
    bool has;
    string[] p;
    ruleFrontMatter("---\npaths: [a, \"b\"]\n---\nx", has, p);
    assert(has && p == ["a", "b"]);
    ruleFrontMatter("---\npaths:\n- a\n- 'b'\nother: 1\n---\nx", has, p);
    assert(p == ["a", "b"]);
    assert(ruleFrontMatter("---\nname: y\n---\nx", has, p) == "x" && !has);
    ruleFrontMatter("no front matter", has, p);
    assert(!has);
    ruleFrontMatter("---\npaths: []\n---\nx", has, p);
    assert(has && !p.length, "an explicit empty scope is not global");
    ruleFrontMatter("---\npaths: \"src/**/*.{ts,tsx}\"\n---\nx", has, p);
    assert(p == ["src/**/*.{ts,tsx}"]);
    ruleFrontMatter("---\npaths: \"a,b\", c\n---\nx", has, p);
    assert(p == ["a,b", "c"]);
    size_t budget = maxRulePatterns;
    assert(expandBraces("{a,b}/*.{c,d}", budget).length == 4);
    auto c = compilePatterns(["src/**/*.{ts,tsx}"]);
    bool any(string s) { foreach (re; c) if (!matchFirst(s, re).empty) return true; return false; }
    assert(any("src/a/b.ts") && any("src/a/b.tsx") && !any("src/a/b.js"));
    foreach (v; ["}", "{", "a}", "{a", "\"a,b", "a,\"b", "'x,y',z", "{a,{b,c}},d", "a,,b", "", ","]) splitTopLevel(v);
}

unittest // imports: Claude files only, once, inside the repository, four levels
{
    import std.file : rmdirRecurse;
    import std.conv : to;
    auto base = testDir("imports");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    put(buildPath(root, "AGENTS.md"), "Ask @docs/a.md");
    put(buildPath(root, "docs/a.md"), "doc a");
    assert(find(root).loaded.length == 1, "AGENTS.md mentions are not imports");

    put(buildPath(base, "secret.md"), "SECRET");
    put(buildPath(root, "sub/CLAUDE.md"), "see @shared.md, @shared.md and @../../secret.md and @missing.md");
    put(buildPath(root, "sub/shared.md"), "shared");
    auto p = find(buildPath(root, "sub"));
    assert(texts(p) == ["Ask @docs/a.md", "see @shared.md, @shared.md and @../../secret.md and @missing.md", "shared"],
        texts(p).join("|"));
    assert(p.warnings.length == 1 && p.warnings[0].canFind("skipped import @../../secret.md in sub/CLAUDE.md"), p.warnings.to!string);
    assert(p.render.canFind("## sub/shared.md (imported by sub/CLAUDE.md)") && !p.render.canFind("SECRET"));

    auto deep = testDir("depth");
    scope (exit) rmdirRecurse(deep);
    auto r2 = buildPath(deep, "repo");
    put(buildPath(r2, "CLAUDE.md"), "@l1.md");
    foreach (i; 1 .. 7) put(buildPath(r2, format("l%s.md", i)), format("level %s @l%s.md", i, i + 1));
    assert(find(r2).loaded.length == 1 + maxImportDepth);
}

unittest // a committed file symlinked outside the repository is skipped
{
    import std.file : rmdirRecurse, symlink;
    auto base = testDir("symlink");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    put(buildPath(base, "outside.md"), "SECRET");
    symlink(buildPath(base, "outside.md"), buildPath(root, "AGENTS.md"));
    auto p = find(root);
    assert(!p.loaded.length && p.warnings.length && p.warnings[0].canFind("links outside the repository"));
}

unittest // scoped rules attach once per compaction; imports resolve on attach
{
    import std.file : rmdirRecurse;
    auto base = testDir("rules");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    put(buildPath(root, ".claude/rules/always.md"), "---\ndescription: x\n---\nalways rule");
    put(buildPath(root, ".claude/rules/api/ts.md"), "---\npaths:\n  - \"src/api/**/*.{ts,tsx}\"\n---\nts rule, see @../../shared.md");
    put(buildPath(root, ".claude/shared.md"), "shared detail");
    put(buildPath(root, ".claude/rules/docs.md"), "---\npaths: \"*.md\", docs/**\n---\ndocs rule");
    put(buildPath(root, ".claude/rules/empty.md"), "---\npaths: []\n---\nnever");
    auto p = find(root);
    assert(texts(p) == ["always rule"], texts(p).join("|"));
    assert(p.onDemandPaths.length == 2 && p.warnings.length == 1 && p.warnings[0].canFind("no usable paths"));
    assert(p.nestedFor(buildPath(root, "src/api/x.rs"), root) is null);
    auto ts = p.nestedFor(buildPath(root, "src/api/v1/x.tsx"), root);
    assert(ts.canFind("Rule .claude/rules/api/ts.md applies to src/api/v1/x.tsx") && ts.canFind("ts rule"), ts);
    assert(ts.canFind("shared detail") && ts.canFind("imported by"), ts);
    assert(p.onDemandPaths.length == 1 && p.loadedPaths.canFind(buildPath(root, ".claude/rules/api/ts.md")));
    assert(p.nestedFor(buildPath(root, "src/api/y.ts"), root) is null);
    assert(p.nestedFor(buildPath(root, "README.md"), root).canFind("docs rule"));
    assert(p.nestedFor(buildPath(root, "sub/README.md"), root) is null);
    p.forgetNested();
    assert(p.nestedFor(buildPath(root, "src/api/y.ts"), root) !is null);
}

unittest // the render cap bounds the total with one marker
{
    import std.file : rmdirRecurse;
    import std.array : replicate;
    import std.algorithm : count;
    auto base = testDir("cap");
    scope (exit) rmdirRecurse(base);
    auto dir = buildPath(base, "repo");
    auto big = "x".replicate(maxFileBytes - 16);
    foreach (i; 0 .. 8)
    {
        dir = buildPath(dir, format("d%s", i));
        put(buildPath(dir, "AGENTS.md"), format("%s file%s", big, i));
    }
    auto r = find(dir).render;
    assert(r.length <= maxTotalBytes && r.count("[omitted: instruction size limit reached") == 1);
}

unittest // a symlink cycle in the rules directory terminates
{
    import std.file : rmdirRecurse, symlink;
    auto base = testDir("cycle");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    put(buildPath(root, ".claude/rules/a/r.md"), "rule a");
    symlink(buildPath(root, ".claude/rules"), buildPath(root, ".claude/rules/a/loop"));
    assert(texts(find(root)) == ["rule a"]);
}
