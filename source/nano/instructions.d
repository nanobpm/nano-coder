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

@safe:

import std.algorithm : canFind, startsWith, endsWith, countUntil, sort, filter;
import std.array : array, join, split;
import std.format : format;
import std.path : buildPath, baseName, dirName, extension;
import std.regex : Regex, regex, matchFirst;
import std.string : strip, stripLeft, stripRight, indexOf, lineSplitter, KeepTerminator;
import std.uni : isWhite;
import nano.paths : canonicalize, startsWithPath, isSymlink, homeDir;
public import nano.instruction_state : InstructionFile, Kind, Options, maxTotalBytes;
import nano.instruction_state : Read, DirRead, RuleRead, Source, Startup, State, begin, attach, forget, needsRead;
static import st = nano.instruction_state;

/// Per-file cap; longer files are truncated with a note.
enum size_t maxFileBytes = 32 * 1024;
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

private bool isFile_(string p) nothrow
{
    import std.file : exists, isFile;
    try return exists(p) && isFile(p);
    catch (Exception) return false; // unreadable counts as absent (nothrow probe)
}

private bool isDir_(string p) nothrow
{
    import std.file : exists, isDir;
    try return exists(p) && isDir(p);
    catch (Exception) return false; // unreadable counts as absent (nothrow probe)
}

private string canonOr(string p) { auto c = canonicalize(p); return c !is null ? c : p; }

/// A file's text (HTML comments stripped, trimmed, capped), or null when it is
/// missing, unreadable or empty.
string readCapped(string path)
{
    import nano.safeio : readRawText;
    import std.encoding : sanitize;
    if (!isFile_(path)) return null;
    string raw;
    try raw = sanitize(readRawText(path));
    catch (Exception) return null; // unreadable instructions file: treated as absent
    auto text = stripHtmlComments(raw).strip;
    if (!text.length) return null;
    if (text.length <= maxFileBytes) return text;
    size_t end = maxFileBytes;
    while (end > 0 && (text[end] & 0xC0) == 0x80) --end;
    return format("%s\n\n[... truncated: %s of %s bytes shown; read the full file with read_file]", text[0 .. end],
        end, text.length);
}

/// Strip leading blockquote markers; returns the content and the depth.
private string stripBlockquote(string line, out size_t depth) pure
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
private ptrdiff_t fenceIndent(string line) pure
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
private bool fence(string line, out Fence f) pure
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
private bool closesFence(string line, Fence open) pure
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
private bool isIndentedCode(string line) pure
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
string stripHtmlComments(string text) pure
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
string[] importRefs(string text) pure
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
private bool expandsImports(string path, Kind kind) pure nothrow
{
    auto n = path.baseName;
    return kind == Kind.rule || kind == Kind.imported || n == "CLAUDE.md" || n == "CLAUDE.local.md";
}

/// Split a rule's front matter into its `paths` (hasPaths false: applies
/// everywhere) and the body. Accepts a YAML list, `[a, b]` or `a, b`.
string ruleFrontMatter(string text, out bool hasPaths, out string[] paths) pure nothrow
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
private string[] splitTopLevel(string value) pure nothrow
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
private string[] expandBraces(string pattern, ref size_t budget) pure
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
            catch (Exception) {} // an invalid glob in a paths: list matches nothing; the others still apply
        }
    }
    return out_;
}

/// `.md` files under `dir`, sorted, following symlinks without looping; with
/// `allowOutside` false, directories whose real path leaves `root` are skipped.
private string[] markdownFiles(string dir, string root, bool allowOutside)
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
        catch (Exception) return; // an unreadable directory contributes no instruction files
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

/// Reads instruction files from disk into `Read` values: imports resolved
/// (and refused, with the warning, outside the repository unless allowed)
/// and read too, down to `maxImportDepth`. Reading has no memory of what was
/// shown; that is `State`'s job.
private struct Reader
{
    string root, home;
    Options options;

    private string display(string path) { return st.display(path, root, home); }

    private bool inside(string path)
    {
        auto real_ = canonicalize(path);
        return real_ !is null && startsWithPath(real_, canonOr(root));
    }

    /// One file and what it imports. `body` (when not null) replaces the
    /// on-disk text (a rule without its front matter). `visited` holds the
    /// shallowest depth each file was reached at in this read: reaching it
    /// again no shallower adds nothing, so cycles and repeats stop.
    Read file(string path, Kind kind, string importedBy, bool user, size_t depth, ref size_t[string] visited,
        string body = null)
    {
        auto r = Read(path, canonOr(path), null, kind, importedBy, user);
        auto disk = readCapped(path);
        if (disk is null) return r;
        if (!user && !options.importsOutsideProject && !inside(path))
        {
            r.refused = format("skipped %s: links outside the repository (set instruction_imports_outside_project = "
                ~ "true to allow)", display(path));
            return r;
        }
        r.text = body !is null ? body : disk;
        if (depth < maxImportDepth && expandsImports(path, kind))
            r.imports = imports(path, r.text, user, depth, visited);
        return r;
    }

    /// The files `text` (in `from`, at `depth`) imports, in order.
    Read[] imports(string from, string text, bool user, size_t depth, ref size_t[string] visited)
    {
        Read[] out_;
        foreach (ref_; importRefs(text))
        {
            string warning;
            auto target = resolve(from, ref_, user, warning);
            if (warning !is null) out_ ~= Read(null, null, null, Kind.imported, from, user, warning);
            if (target is null) continue;
            auto real_ = canonOr(target);
            if (auto at = real_ in visited) if (*at <= depth + 1) continue;
            visited[real_] = depth + 1;
            out_ ~= file(target, Kind.imported, from, user, depth + 1, visited);
        }
        return out_;
    }

    /// Resolve `@reference` in `from`. Missing files are mentions and are
    /// ignored; project imports outside the repository are refused (with
    /// `warning`) unless allowed.
    string resolve(string from, string reference, bool user, out string warning)
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
                warning = format("skipped import @%s in %s: outside the repository (set "
                    ~ "instruction_imports_outside_project = true to allow)", reference, display(from));
                return null;
            }
        }
        return target;
    }

    /// One directory's files: the first of `options.names` that exists,
    /// then the personal files.
    DirRead dir(string d)
    {
        auto r = DirRead(d);
        foreach (n; options.names)
        {
            auto path = buildPath(d, n);
            if (readCapped(path) is null) continue;
            size_t[string] visited;
            r.files ~= file(path, Kind.project, null, false, 0, visited);
            break;
        }
        foreach (n; localFiles)
        {
            size_t[string] visited;
            r.files ~= file(buildPath(d, n), Kind.local, null, false, 0, visited);
        }
        return r;
    }

    /// Rules under `d`: unscoped ones go to `sources` (loaded at start),
    /// `paths:` ones to `rules` with their compiled patterns.
    void rules(string d, bool user, ref Source[] sources, ref RuleRead[] rules, ref Regex!char[][] patterns)
    {
        auto rootc = canonOr(root);
        auto allowOutside = user || options.importsOutsideProject;
        void refuse(string warning) { sources ~= Source(null, Read(null, null, null, Kind.rule, null, user, warning)); }
        foreach (path; markdownFiles(d, rootc, allowOutside))
        {
            if (!allowOutside)
            {
                auto real_ = canonicalize(path);
                if (real_ is null || !startsWithPath(real_, rootc))
                {
                    refuse(format("skipped rule %s: links outside the repository (set "
                        ~ "instruction_imports_outside_project = true to allow)", display(path)));
                    continue;
                }
            }
            auto text = readCapped(path);
            if (text is null) continue;
            bool hasPaths;
            string[] globs;
            auto body = ruleFrontMatter(text, hasPaths, globs).strip;
            if (!body.length) continue;
            size_t[string] visited;
            if (hasPaths)
            {
                auto compiled = compilePatterns(globs);
                if (!compiled.length)
                {
                    refuse(format("rule %s has no usable paths patterns", display(path)));
                    continue;
                }
                auto real_ = canonOr(path);
                visited[real_] = 0;
                rules ~= RuleRead(path, real_, text, body, user, imports(path, body, user, 0, visited));
                patterns ~= compiled;
            }
            // Front matter without `paths` is dropped; imports expand from the body only.
            else sources ~= Source(null, file(path, Kind.rule, null, user, 0, visited, body));
        }
    }
}

/// The instruction files for one working directory: what was read at start,
/// and what has been shown since. The reading is here; the decisions are the
/// pure functions of `nano.instruction_state`.
class ProjectInstructions
{
    Options options;
    private Startup startup;
    private State state;
    /// Compiled `paths:` patterns, one list per `startup.rules`.
    private Regex!char[][] patterns;

    /// Git root (or the working directory outside a repository).
    string root() const pure { return startup.root; }
    /// Files in the system prompt, in order.
    InstructionFile[] loaded() pure { return state.loaded; }
    /// Files skipped, with the reason (imports outside the repository, ...).
    string[] warnings() pure { return state.warnings; }

    private Reader reader() { return Reader(startup.root, startup.home, options); }

    /// Find the user's and the project's instruction files for `cwd`.
    static ProjectInstructions discover(string cwd, Options options)
    {
        auto p = new ProjectInstructions;
        cwd = canonOr(cwd);
        auto git = gitRoot(cwd);
        p.options = options;
        p.startup.root = git !is null ? git : cwd;
        p.startup.home = homeDir();
        auto r = p.reader();
        with (p.startup)
        {
            foreach (f; options.userFiles)
            {
                size_t[string] visited;
                sources ~= Source(null, r.file(f, Kind.user, null, true, 0, visited));
            }
            foreach (d; options.userRulesDirs) r.rules(d, true, sources, rules, p.patterns);
            foreach (i, d; dirsDown(cwd, p.startup.root))
            {
                foreach (f; r.dir(d).files) sources ~= Source(d, f);
                initialDirs ~= d;
                if (i == 0) r.rules(buildPath(p.startup.root, projectRulesDir), false, sources, rules, p.patterns);
            }
        }
        p.state = begin(p.startup);
        return p;
    }

    /// Whether `other` read the same files at its start (same texts, same
    /// imports, same rules): if so, nothing in the prompt or the on-demand
    /// rules changed.
    bool sameFiles(const ProjectInstructions other) const pure { return st.sameFiles(startup, other.startup); }

    /// Repository-relative, `~/`-relative, or as given.
    string display(string path) const pure { return st.display(path, startup.root, startup.home); }

    /// Text appended to the system prompt (empty when nothing was found).
    string render() const pure { return st.render(startup, state); }

    /// Instructions that apply to `path` and were not shown yet: files in the
    /// directories between it and the root (outermost first), then rules whose
    /// `paths` match. Rendered for a tool result; null when there are none.
    string nestedFor(string path, string cwd)
    {
        auto absolute = canonicalizeExisting(path.startsWith("/") ? path : buildPath(cwd, path));
        auto dir = isDir_(absolute) ? absolute : absolute.dirName;
        auto dirs = dirsDown(dir, root);
        if (!dirs.length) return null;
        auto r = reader();
        DirRead[] reads;
        foreach (d; dirs) if (needsRead(state, startup, d)) reads ~= r.dir(d);
        const inRoot = startsWithPath(absolute, root);
        auto rel = !inRoot || absolute == root ? "" : display(absolute);
        bool[] hits;
        foreach (compiled; patterns)
        {
            bool hit;
            if (inRoot) foreach (re; compiled) if (!matchFirst(rel, re).empty) { hit = true; break; }
            hits ~= hit;
        }
        auto a = attach(state, startup, reads, hits, rel, inRoot);
        state = a.state;
        return a.text;
    }

    /// After compaction, nested instructions attached to old tool results may
    /// be gone: let them attach again.
    void forgetNested() pure { state = forget(state); }

    /// Whether a directory searched for a tool call (attached or deferred)
    /// reads differently now: a file edited, added or removed, imports
    /// included.
    bool nestedChanged()
    {
        auto r = reader();
        foreach (read; state.searchedReads) if (r.dir(read.dir) != read) return true;
        return false;
    }

    /// Files in the prompt, for the banner, `/context` and ACP.
    string[] loadedPaths() const pure { return st.loadedPaths(startup, state); }

    /// Rules attached only when a matching file is touched.
    string[] onDemandPaths() const pure { return st.onDemandPaths(startup, state); }
}

/// `from` and its ancestors up to `root`, outermost first (none when `from`
/// is outside `root`).
private string[] dirsDown(string from, string root)
{
    string[] dirs;
    for (auto d = from; startsWithPath(d, root);)
    {
        dirs = d ~ dirs;
        auto up = d.dirName;
        if (up == d) break;
        d = up;
    }
    return dirs;
}

version (unittest)
{
    private string testDir(string name)
    {
        import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists;
        auto d = buildPath(canonicalize(tempDir), "nano-d-instr-" ~ name);
        if (exists(d)) rmdirRecurse(d);
        mkdirRecurse(buildPath(d, "repo", ".git"));
        return d;
    }

    private void put(string path, string text)
    {
        import std.file : mkdirRecurse, write;
        mkdirRecurse(path.dirName);
        write(path, text);
    }

    private ProjectInstructions find(string cwd) { return ProjectInstructions.discover(cwd, Options.project(defaultFiles)); }

    private string[] texts(ProjectInstructions p) pure
    {
        string[] t;
        foreach (f; p.loaded) t ~= f.text;
        return t;
    }
}

// rust: instructions.rs::loads_root_to_leaf_with_fallbacks_and_nested_files_once
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

// rust: instructions.rs::outside_a_repository_only_the_working_directory_counts
// rust: instructions.rs::per_file_truncation_marker_mentions_read_file
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

// rust: instructions.rs::loaded_paths_keeps_a_scoped_rule_after_it_attaches
// rust: instructions.rs::user_files_come_first_and_local_files_follow_the_main_file
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

// rust: instructions.rs::a_closing_fence_must_match_the_openers_blockquote_container
// rust: instructions.rs::code_span_state_is_preserved_across_line_breaks
// rust: instructions.rs::fence_close_requires_a_bare_marker_and_small_indent
// rust: instructions.rs::html_comments_are_stripped_outside_code_blocks
// rust: instructions.rs::imports_inside_blockquote_containers_are_skipped_like_top_level
// rust: instructions.rs::longer_fences_are_not_closed_by_shorter_inner_runs
// rust: instructions.rs::multi_backtick_code_spans_skip_their_contents
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

private string strip_(string s) pure { return stripHtmlComments(s); }

// rust: instructions.rs::front_matter_forms
// rust: instructions.rs::inline_paths_keep_brace_groups
// rust: instructions.rs::inline_paths_with_braces_match
// rust: instructions.rs::split_top_level_adversarial
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

// rust: instructions.rs::agents_md_mentions_are_not_imports
// rust: instructions.rs::imports_expand_in_claude_files_once_and_stay_inside_the_repository
// rust: instructions.rs::imports_stop_after_four_levels
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

// rust: instructions.rs::a_committed_instruction_file_symlinked_outside_the_repo_is_skipped
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

// rust: instructions.rs::scoped_rule_imports_are_expanded_and_deduplicated
// rust: instructions.rs::scoped_rules_attach_to_matching_files_once_per_compaction
// rust: instructions.rs::on_demand_paths_excludes_already_attached_rules
// rust: instructions.rs::rule_with_explicit_empty_paths_is_skipped_not_loaded_globally
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

unittest // comparing reads sees rule and import edits
{
    import std.file : rmdirRecurse;
    import std.array : replicate;
    auto base = testDir("reread");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    put(buildPath(root, ".claude/rules/a.md"), "---\npaths: \"a/**\"\n---\nrule a, see @../detail.md");
    put(buildPath(root, ".claude/detail.md"), "detail");
    put(buildPath(root, "AGENTS.md"), "top");
    // What was read is kept: later reads of the same files compare equal.
    auto old = find(root);
    assert(find(root).sameFiles(old));
    // An imported file changes: the reads differ, the system text doesn't.
    put(buildPath(root, ".claude/detail.md"), "detail, revised");
    auto fresh = find(root);
    assert(!fresh.sameFiles(old) && fresh.render == old.render);
    // The rule itself changes.
    put(buildPath(root, ".claude/rules/a.md"), "---\npaths: \"a/**\"\n---\nrule a, revised");
    assert(!find(root).sameFiles(fresh));
    // A cycle of self-imports is read once, not 100^4 times.
    put(buildPath(root, ".claude/rules/loop.md"), "---\npaths: \"l/**\"\n---\n" ~ "@loop.md ".replicate(100));
    assert(find(root).sameFiles(find(root)));
    // A nested directory that attached: edits there are seen.
    put(buildPath(root, "pkg/AGENTS.md"), "pkg rule");
    auto withNested = find(root);
    assert(withNested.nestedFor(buildPath(root, "pkg/x"), root).canFind("pkg rule"));
    assert(!withNested.nestedChanged());
    put(buildPath(root, "pkg/AGENTS.md"), "pkg rule, revised");
    assert(withNested.nestedChanged());
    // A file a scoped rule imported first is not a change when its directory is searched.
    put(buildPath(root, ".claude/rules/s.md"), "---\npaths: \"s/**\"\n---\nsee @../../pkg/AGENTS.md");
    auto shared_ = find(root);
    assert(shared_.nestedFor(buildPath(root, "s/x"), root).canFind("pkg rule, revised"));
    shared_.nestedFor(buildPath(root, "pkg/x"), root);
    assert(!shared_.nestedChanged());
    // Compaction drops the snapshots with the attachments.
    put(buildPath(root, "pkg/AGENTS.md"), "pkg rule, third");
    assert(shared_.nestedChanged());
    shared_.forgetNested();
    assert(!shared_.nestedChanged());
    // A file added where a search found nothing is seen too.
    auto empty = find(root);
    assert(empty.nestedFor(buildPath(root, "none/x"), root) is null);
    assert(!empty.nestedChanged());
    put(buildPath(root, "none/AGENTS.md"), "new here");
    assert(empty.nestedChanged());
    // A fresh discovery attaches the current text.
    assert(find(root).nestedFor(buildPath(root, "a/x"), root).canFind("rule a, revised"));
}

// rust: instructions.rs::render_cap_bounds_total_with_header_and_single_marker
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

// rust: instructions.rs::a_symlink_cycle_in_rules_does_not_loop_forever
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

// rust: instructions.rs::a_fence_looking_line_inside_an_open_span_does_not_open_a_fence
// rust: instructions.rs::an_indented_continuation_line_can_close_an_open_span
// rust: instructions.rs::indented_code_blocks_preserve_comments_and_imports
// rust: instructions.rs::rejected_fence_candidate_does_not_break_an_open_span
unittest
{
    import std.algorithm : canFind;
    // A fence-looking line inside an open code span is span content.
    assert(importRefs("``open\n```\n@hidden.md\n``\n@live.md") == ["live.md"]);
    assert(importRefs("`open\n~~~\n@hidden.md\n`\n@live.md") == ["live.md"]);
    assert(importRefs("```\n@hidden.md\n```\n@live.md") == ["live.md"]);
    // An indented continuation line can close an open span.
    assert(importRefs("`open\n    `\n@live.md") == ["live.md"]);
    assert(importRefs("``open\n    ``\n@live.md") == ["live.md"]);
    assert(importRefs("``open\n    `\n@secret.md").length == 0);
    assert(importRefs("text\n\n    @secret.md").length == 0);
    // Indented code keeps its comments and imports.
    assert(stripHtmlComments("text\n\n    <!-- example -->\n").canFind("<!-- example -->"));
    assert(importRefs("text\n\n    @code.md\n@live.md") == ["live.md"]);
    assert(stripHtmlComments("text\n\n\t<!-- tabbed -->\n").canFind("<!-- tabbed -->"));
    assert(stripHtmlComments("   <!-- shallow -->\nkeep\n") == "keep\n");
    // A rejected fence candidate doesn't break an open span.
    assert(importRefs("``open\n``` `x`\n@secret.md").length == 0);
    assert(importRefs("`open\n``` `x`\n@secret.md").length == 0);
    assert(importRefs("``open\n~~~ `x`\n@secret.md").length == 0);
    assert(importRefs("``open\n`` `x`\n@after.md") == ["after.md"]);
}

// rust: instructions.rs::front_matter_imports_are_not_expanded_when_front_matter_is_dropped
// rust: instructions.rs::a_dormant_scoped_rules_import_does_not_suppress_a_rendered_file
// rust: instructions.rs::a_scoped_rule_already_imported_is_not_re_emitted
// rust: instructions.rs::scoped_rule_import_shared_with_loaded_file_is_not_duplicated
// rust: instructions.rs::rules_nested_deeper_than_eight_directories_are_still_loaded
unittest // imports through rules
{
    import std.algorithm : count;
    import std.file : rmdirRecurse;
    auto base = testDir("ruleimports");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    {
        put(buildPath(root, "secret.md"), "SECRET BODY");
        put(buildPath(root, ".claude/rules/x.md"), "---\ndescription: see @secret.md\n---\nrule body");
        auto r = find(root).render;
        assert(r.canFind("rule body") && !r.canFind("SECRET BODY"), "dropped front matter isn't scanned for imports");
    }
    {
        put(buildPath(root, ".claude/shared-detail.md"), "shared detail");
        put(buildPath(root, ".claude/rules/a-scoped.md"), "---\npaths:\n  - \"src/**\"\n---\nscoped, see @../shared-detail.md");
        put(buildPath(root, ".claude/rules/b-plain.md"), "plain rule, see @../shared-detail.md");
        auto r = find(root).render;
        assert(r.canFind("shared detail"), "a dormant rule's import doesn't suppress it: " ~ r);
    }
    {
        put(buildPath(root, ".claude/rules/dup.md"), "---\npaths: docs/**\n---\ndup body");
        put(buildPath(root, "CLAUDE.md"), "@.claude/rules/dup.md");
        auto p = find(root);
        assert(p.render.count("dup body") == 1);
        assert(p.nestedFor(buildPath(root, "docs/x.md"), root) is null, "an imported rule isn't attached again");
    }
    {
        put(buildPath(root, "CLAUDE.md"), "root, see @shared.md");
        put(buildPath(root, "shared.md"), "shared once");
        put(buildPath(root, ".claude/rules/api.md"), "---\npaths:\n  - \"src/**\"\n---\nrule, see @shared.md");
        auto out_ = find(root).nestedFor(buildPath(root, "src/x.rs"), root);
        assert(out_.canFind("rule, see") && !out_.canFind("shared once"), out_);
    }
    {
        put(buildPath(root, ".claude/rules/a/b/c/d/e/f/g/h/i/j/k/deep.md"), "---\npaths:\n  - \"src/**\"\n---\ndeep rule");
        auto out_ = find(root).nestedFor(buildPath(root, "src/y.rs"), root);
        assert(out_.canFind("deep rule"), out_);
    }
}

// rust: instructions.rs::repeated_blocked_outside_import_warns_only_once
// rust: instructions.rs::nested_attached_files_stay_listed_in_loaded_paths
unittest
{
    import std.algorithm : count, filter, any;
    import std.file : rmdirRecurse;
    import std.conv : to;
    auto base = testDir("warnonce");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    auto outside = buildPath(base, "secret.txt");
    put(outside, "SECRET");
    put(buildPath(root, "CLAUDE.md"), format("@%1$s\n@%1$s\n@%1$s", outside));
    auto p = find(root);
    assert(p.warnings.filter!(w => w.canFind("skipped import")).count == 1, p.warnings.to!string);
    assert(!p.render.canFind("SECRET"));

    put(buildPath(root, "a/AGENTS.md"), "nested agents");
    p = find(root);
    bool listed() { return p.loadedPaths.any!(x => x.canFind("a/AGENTS.md")); }
    assert(!listed, "not attached yet");
    assert(p.nestedFor(buildPath(root, "a/x.rs"), root).canFind("nested agents"));
    assert(listed, "an attached nested file stays in loadedPaths: " ~ p.loadedPaths.to!string);
    p.forgetNested();
    assert(!listed, "reset by forgetNested");
    p.nestedFor(buildPath(root, "a/x.rs"), root);
    assert(p.loadedPaths.count!(x => x.canFind("a/AGENTS.md")) == 1);
}

// rust: instructions.rs::a_rules_root_that_is_itself_an_out_of_root_symlink_is_not_walked
// rust: instructions.rs::an_out_of_root_directory_symlink_in_rules_is_not_walked
unittest // out-of-root symlinks in rules dirs aren't walked
{
    import std.algorithm : any;
    import std.file : rmdirRecurse, mkdirRecurse, symlink;
    import std.conv : to;
    auto base = testDir("rulelinks");
    scope (exit) rmdirRecurse(base);
    auto ext = buildPath(base, "ext");
    foreach (i; 0 .. 3) put(buildPath(ext, format("sub/f%s.md", i)), format("external rule %s", i));

    auto root = buildPath(base, "repo");
    mkdirRecurse(buildPath(root, ".claude"));
    symlink(ext, buildPath(root, ".claude/rules"));
    assert(markdownFiles(buildPath(root, ".claude/rules"), root, false).length == 0);
    assert(markdownFiles(buildPath(root, ".claude/rules"), root, true).length == 3, "user rules dirs may leave the root");

    rmdirRecurse(root);
    mkdirRecurse(buildPath(root, ".git"));
    put(buildPath(root, ".claude/rules/real.md"), "real rule body");
    symlink(ext, buildPath(root, ".claude/rules/link"));
    auto p = find(root);
    assert(p.warnings.length == 0, p.warnings.to!string);
    assert(texts(p) == ["real rule body"], texts(p).to!string);

    put(buildPath(root, ".claude/rules/actual/inner.md"), "inner rule body");
    symlink(buildPath(root, ".claude/rules/actual"), buildPath(root, ".claude/rules/alias"));
    auto files = markdownFiles(buildPath(root, ".claude/rules"), root, false);
    assert(files.any!(f => f.endsWith("inner.md")), files.to!string);
}

// rust: instructions.rs::nested_for_does_not_reorder_already_searched_startup_directories
// rust: instructions.rs::nested_scope_heading_uses_search_dir_not_a_dot_claude_trim
// rust: instructions.rs::on_demand_scoped_rules_are_bounded_with_a_single_marker
unittest
{
    import std.algorithm : count;
    import std.array : replicate;
    import std.file : rmdirRecurse;
    auto base = testDir("order");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    put(buildPath(root, "CLAUDE.md"), "root main body");
    put(buildPath(root, ".claude/rules/zzz.md"), "unscoped rule body");
    auto p = find(root);
    auto before = p.render;
    assert(before.indexOf("root main body") < before.indexOf("unscoped rule body"));
    p.nestedFor(buildPath(root, "x.rs"), root);
    p.nestedFor(buildPath(root, "sub/y.rs"), root);
    assert(p.render == before, "nestedFor doesn't reorder searched startup directories");

    rmdirRecurse(base);
    base = testDir("order");
    put(buildPath(root, "AGENTS.md"), "root");
    put(buildPath(root, "pkg.claude/AGENTS.md"), "scoped body");
    auto nested = find(root).nestedFor(buildPath(root, "pkg.claude/src/main.rs"), root);
    assert(nested.canFind("apply to files under pkg.claude/") && !nested.canFind("under pkg/"), nested);

    rmdirRecurse(base);
    base = testDir("order");
    auto big = "x".replicate(maxFileBytes - 64);
    foreach (i; 0 .. 8)
        put(buildPath(root, format(".claude/rules/r%s.md", i)), format("---\npaths:\n  - \"src/**\"\n---\n%s rule%s", big, i));
    auto out_ = find(root).nestedFor(buildPath(root, "src/x.rs"), root);
    assert(out_.length <= maxTotalBytes && out_.count("[omitted: instruction size limit reached") == 1);
}

// rust: instructions.rs::overflow_directory_stays_pending_for_a_later_call
// rust: instructions.rs::overflow_imported_file_in_subdir_stays_pending_for_a_later_call
// rust: instructions.rs::overflow_scoped_rule_stays_pending_for_a_later_call
// rust: instructions.rs::oversized_group_commits_what_fits_and_defers_the_first_unrendered_file
unittest // files past the budget stay pending for a later call
{
    import std.algorithm : any;
    import std.array : replicate;
    import std.file : rmdirRecurse;
    import std.conv : to;
    enum marker = "[omitted: instruction size limit reached";
    auto base = testDir("overflow");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    bool warned(ProjectInstructions p, string name)
    {
        return p.warnings.any!(w => w.canFind("deferred") && w.canFind(name));
    }
    void reset() { rmdirRecurse(base); testDir("overflow"); }

    auto big16 = "x".replicate(maxFileBytes - 16), big64 = "x".replicate(maxFileBytes - 64);
    put(buildPath(root, "AGENTS.md"), "root file");
    put(buildPath(root, "a/AGENTS.md"), big16 ~ " file_a");
    put(buildPath(root, "a/b/AGENTS.md"), big16 ~ " file_b");
    auto p = find(root);
    auto first = p.nestedFor(buildPath(root, "a/b/x.rs"), root);
    assert(first.canFind("file_a") && !first.canFind("file_b") && first.canFind(marker));
    assert(warned(p, "a/b/AGENTS.md"), p.warnings.to!string);
    assert(p.nestedFor(buildPath(root, "a/b/y.rs"), root).canFind("file_b"));

    reset();
    put(buildPath(root, "a/CLAUDE.md"), "@shared/foo.md\n" ~ big64 ~ " main_file");
    put(buildPath(root, "a/shared/foo.md"), big64 ~ " import_file");
    p = find(root);
    first = p.nestedFor(buildPath(root, "a/x.rs"), root);
    assert(first.canFind("main_file") && !first.canFind("import_file") && first.canFind(marker));
    assert(warned(p, "foo.md"), p.warnings.to!string);
    assert(!p.render.canFind("import_file"), "a pending import stays out of the system prompt");
    assert(p.nestedFor(buildPath(root, "a/y.rs"), root).canFind("import_file"));

    reset();
    put(buildPath(root, ".claude/rules/a.md"), "---\npaths:\n  - \"src/**\"\n---\n" ~ big64 ~ " rule_a");
    put(buildPath(root, ".claude/rules/b.md"), "---\npaths:\n  - \"src/**\"\n---\n" ~ big64 ~ " rule_b");
    p = find(root);
    first = p.nestedFor(buildPath(root, "src/x.rs"), root);
    assert(first.canFind(marker));
    bool aFirst = first.canFind("rule_a");
    assert(aFirst != first.canFind("rule_b"), "exactly one rule fits");
    assert(p.nestedFor(buildPath(root, "src/y.rs"), root).canFind(aFirst ? "rule_b" : "rule_a"));

    reset();
    put(buildPath(root, "a/AGENTS.md"), big16 ~ " main_file");
    put(buildPath(root, "a/CLAUDE.local.md"), big16 ~ " local_file");
    p = find(root);
    first = p.nestedFor(buildPath(root, "a/x.rs"), root);
    assert(first.canFind("main_file") != first.canFind("local_file") && first.canFind(marker), first);
    assert(p.warnings.any!(w => w.canFind("deferred")));
    auto second = p.nestedFor(buildPath(root, "a/y.rs"), root);
    assert(second.canFind(first.canFind("main_file") ? "local_file" : "main_file") && !second.canFind(marker));
}

// rust: instructions.rs::compaction_while_a_file_is_deferred_reloads_without_duplicates
unittest
{
    import std.algorithm : any, count;
    import std.array : replicate;
    import std.file : rmdirRecurse;
    import std.conv : to;
    auto base = testDir("compactdefer");
    scope (exit) rmdirRecurse(base);
    auto root = buildPath(base, "repo");
    auto pad = "x".replicate(maxFileBytes - 168);
    put(buildPath(root, "a/CLAUDE.md"), "@shared/foo.md\n@shared/bar.md\n" ~ pad ~ " main_file");
    put(buildPath(root, "a/shared/foo.md"), pad ~ " foo_file");
    put(buildPath(root, "a/shared/bar.md"), "bar_file");
    auto p = find(root);
    auto first = p.nestedFor(buildPath(root, "a/x.rs"), root);
    assert(first.canFind("main_file") && first.canFind("foo_file") && !first.canFind("bar_file"), first[$ - 300 .. $]);
    assert(p.warnings.any!(w => w.canFind("deferred") && w.canFind("bar.md")), p.warnings.to!string);
    p.forgetNested();
    auto second = p.nestedFor(buildPath(root, "a/y.rs"), root);
    assert(second.count("main_file") == 1 && second.count("foo_file") == 1 && second.count("bar_file") == 0);
    auto third = p.nestedFor(buildPath(root, "a/z.rs"), root);
    assert(third.count("bar_file") == 1 && !third.canFind("main_file") && !third.canFind("foo_file"), third);
    assert(p.nestedFor(buildPath(root, "a/w.rs"), root) is null);
}
