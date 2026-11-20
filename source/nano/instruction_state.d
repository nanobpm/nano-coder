/// Instruction files as values: what was read from disk (`Read`, `DirRead`,
/// `RuleRead`, all gathered by `nano.instructions`) and what has been shown
/// to the model (`State`), with pure transitions between them.
///
/// The shell reads; this module decides. `begin` turns the files read at
/// session start into the system prompt's files, `attach` decides what a
/// file-tool call adds to its result (nested directories' files, rules
/// scoped with `paths:`), `forget` lets them attach again after compaction,
/// and `render` writes the system prompt's section. Nothing here touches the
/// disk, so whether instructions changed is a comparison of two reads.
module nano.instruction_state;
@safe:

import std.algorithm : canFind, endsWith;
import std.format : format;
import nano.paths : startsWithPath;

pure:

/// Cap on everything added to the system prompt (and to one tool result).
enum size_t maxTotalBytes = 64 * 1024;

enum omittedMarker = "\n\n[omitted: instruction size limit reached; read the remaining files with read_file]";

/// Where a loaded file came from.
enum Kind { user, project, local, rule, imported }

/// A file shown to the model.
struct InstructionFile
{
    string path, text;
    Kind kind;
    /// For `Kind.imported`: the file whose `@path` imported this one.
    string importedBy;
    /// From the user's own configuration rather than the repository.
    bool user;
    /// The directory whose search loaded this file (also via imports), or
    /// null for files loaded outside any directory search.
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

    static Options project(const string[] names) pure { Options o; o.names = names.dup; return o; }
}

/// One file as read, with the imports it reaches (resolved and read too).
/// A read is a snapshot: two reads are equal when the files say the same.
struct Read
{
    /// As found, and canonical (the key that shows a file only once).
    string path, real_;
    /// Null when the file is missing, unreadable or empty.
    string text;
    Kind kind;
    string importedBy;
    bool user;
    /// Set when the file, or the import leading to it, was refused (outside
    /// the repository, ...): the warning to record. Nothing loads.
    string refused;
    Read[] imports;
}

/// A file read in a directory search, or a warning raised while reading.
struct Source
{
    /// The directory searched, or null (user files, rules).
    string searchDir;
    Read read;
}

/// One directory's files as read: the first of the configured names that
/// exists, then the personal files (present or not, so adding one changes
/// the read).
struct DirRead
{
    string dir;
    Read[] files;
}

/// A rule scoped with `paths:`, attached when a matching file is touched.
struct RuleRead
{
    string path, real_;
    /// The whole file, and the body after the front matter.
    string source, body;
    bool user;
    /// What the body imports.
    Read[] imports;
}

/// Everything read at session start, fixed for the session.
struct Startup
{
    /// Git root (or the working directory outside a repository), and the
    /// home directory, for display.
    string root, home;
    /// User files, rules and the root-to-cwd directories' files, in order.
    Source[] sources;
    /// The directories searched at start.
    string[] initialDirs;
    RuleRead[] rules;
}

/// What has been shown to the model.
struct State
{
    /// The system prompt's files.
    InstructionFile[] loaded;
    /// Canonical paths shown (in the prompt or a tool result), and those
    /// shown at start.
    string[] seen, initialSeen;
    /// Nested directories whose files all attached, with what they read
    /// (deferred ones too, so an edit there is seen).
    string[] searched;
    DirRead[] searchedReads;
    /// Files deferred by the budget, attached first when their directory is
    /// searched again (they stay in `seen`; an edit to one changes the
    /// directory's read, which reloads everything).
    InstructionFile[] pending;
    /// Paths of nested files and scoped rules attached to tool results.
    string[] nestedAttached, attachedRules;
    /// Diagnostics, each once.
    string[] warnings;
}

/// Whether two session starts read the same files (instructions unchanged).
bool sameFiles(const Startup a, const Startup b)
{
    return a.root == b.root && a.sources == b.sources && a.rules == b.rules;
}

/// Repository-relative, `~/`-relative, or as given.
string display(string path, string root, string home)
{
    if (path == root) return "";
    if (startsWithPath(path, root)) return path[root.length + (root.endsWith("/") ? 0 : 1) .. $];
    if (home !is null && startsWithPath(path, home) && path != home)
        return "~/" ~ path[home.length + (home.endsWith("/") ? 0 : 1) .. $];
    return path;
}

/// The system prompt's files and the state at session start.
State begin(const Startup st)
{
    Acc acc;
    foreach (s; st.sources) acc.flatten(s.read, s.searchDir);
    State s;
    s.loaded = acc.files;
    s.seen = acc.seen;
    s.initialSeen = acc.seen.dup;
    s.warnings = acc.warnings;
    return s;
}

/// Whether `dir` still has files to attach (not searched at start or since).
bool needsRead(const State s, const Startup st, string dir)
{
    return !st.initialDirs.canFind(dir) && !s.searched.canFind(dir);
}

/// What `attach` returns: the new state and the text for the tool result
/// (null when nothing applies).
struct Attached
{
    State state;
    string text;
}

/// Instructions for a file-tool call: the files of `dirs` (the directories
/// from the root down to the touched path that `needsRead`, as read now),
/// outermost first, then the scoped rules whose patterns matched (`ruleHits`,
/// one per `st.rules`; considered only when `inRoot`). Each shows once; what
/// doesn't fit in the budget is deferred and attaches on a later call.
Attached attach(const State s, const Startup st, const DirRead[] dirs, const bool[] ruleHits, string rel, bool inRoot)
{
    State n = copy(s);
    string out_;
    size_t budget = maxTotalBytes - omittedMarker.length;
    bool truncated;
    string show(string p) { return display(p, st.root, st.home); }
    foreach (d; dirs)
    {
        if (!needsRead(n, st, d.dir)) continue;
        Acc acc;
        InstructionFile[] stillPending;
        foreach (f; n.pending) (f.searchDir == d.dir ? acc.files : stillPending) ~= f;
        n.pending = stillPending;
        acc.seen = n.seen;
        acc.warnings = n.warnings;
        foreach (f; d.files) acc.flatten(f, d.dir);
        n.warnings = acc.warnings;
        n.seen = acc.seen;
        size_t rendered;
        foreach (f; acc.files)
        {
            string note;
            if (f.kind == Kind.imported)
                note = format("[%s (imported by %s) applies with it:]", show(f.path), show(f.importedBy));
            else
            {
                import std.path : dirName;
                auto scope_ = show(f.searchDir !is null ? f.searchDir : f.path.dirName);
                note = format("[Instructions from %s apply to files under %s/. Follow them for changes there:]",
                    show(f.path), scope_.length ? scope_ : ".");
            }
            auto section = format("\n\n%s\n%s", note, f.text);
            if (section.length > budget)
            {
                warn(n.warnings, format("deferred %s: instruction size limit reached; it stays pending and attaches "
                    ~ "once budget frees (e.g. after compaction)", show(f.path)));
                truncated = true;
                break;
            }
            budget -= section.length;
            out_ ~= section;
            ++rendered;
        }
        foreach (f; acc.files[0 .. rendered]) n.nestedAttached ~= f.path;
        n.pending ~= acc.files[rendered .. $];
        // The first read stands until compaction: a retried deferral keeps
        // its pending text, so a later read must not hide an edit.
        if (!n.searchedReads.canFind!(r => r.dir == d.dir)) n.searchedReads ~= dupRead(d);
        if (truncated) break;
        n.searched ~= d.dir;
    }
    if (!truncated && inRoot)
        foreach (i, rule; st.rules)
        {
            if (n.attachedRules.canFind(rule.path) || i >= ruleHits.length || !ruleHits[i]) continue;
            if (n.seen.canFind(rule.real_)) { n.attachedRules ~= rule.path; continue; }
            auto seen = n.seen ~ rule.real_;
            auto warnings = n.warnings.dup;
            string text = rule.body;
            ruleImports(rule.imports, rule.path, st, seen, warnings, text);
            auto section = format("\n\n[Rule %s applies to %s. Follow it for changes to matching files:]\n%s",
                show(rule.path), rel, text);
            n.warnings = warnings;
            if (section.length > budget)
            {
                warn(n.warnings, format("deferred rule %s: instruction size limit reached; it stays pending and "
                    ~ "attaches once budget frees (e.g. after compaction)", show(rule.path)));
                truncated = true;
                break;
            }
            budget -= section.length;
            out_ ~= section;
            n.seen = seen;
            n.attachedRules ~= rule.path;
        }
    if (truncated) out_ ~= omittedMarker;
    return Attached(n, out_.length ? out_ : null);
}

/// After compaction, nested instructions attached to old tool results may be
/// gone: let them attach again.
State forget(const State s)
{
    State n = copy(s);
    n.seen = s.initialSeen.dup;
    n.searched = null;
    n.searchedReads = null;
    n.pending = null;
    n.nestedAttached = null;
    n.attachedRules = null;
    return n;
}

/// Text appended to the system prompt (empty when nothing was found).
string render(const Startup st, const State s)
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
        const(InstructionFile)[] files;
        foreach (ref f; s.loaded) if (f.user == user) files ~= f;
        if (!files.length) continue;
        if (header.length > budget) { truncated = true; break; }
        budget -= header.length;
        out_ ~= header;
        foreach (ref f; files)
        {
            auto section = format("\n\n## %s\n\n%s", heading(f, st), f.text);
            if (section.length > budget) { truncated = true; break outer; }
            budget -= section.length;
            out_ ~= section;
        }
    }
    if (truncated) out_ ~= omittedMarker;
    return out_;
}

/// Files in the prompt or attached, for the banner, `/context` and ACP.
string[] loadedPaths(const Startup st, const State s)
{
    string[] out_;
    foreach (ref f; s.loaded) out_ ~= f.path;
    out_ ~= s.nestedAttached;
    foreach (r; st.rules) if (s.attachedRules.canFind(r.path)) out_ ~= r.path;
    return out_;
}

/// Rules not attached yet.
string[] onDemandPaths(const Startup st, const State s)
{
    string[] out_;
    foreach (r; st.rules) if (!s.attachedRules.canFind(r.path)) out_ ~= r.path;
    return out_;
}

private:

/// Files gathered from reads, showing each once.
struct Acc
{
    InstructionFile[] files;
    string[] seen, warnings;

    /// `r` and its imports, depth first, as the model sees them.
    void flatten(const Read r, string searchDir) pure
    {
        if (r.refused.length) { warn(warnings, r.refused); return; }
        if (r.text is null || seen.canFind(r.real_)) return;
        seen ~= r.real_;
        files ~= InstructionFile(r.path, r.text, r.kind, r.importedBy, r.user, searchDir);
        foreach (c; r.imports) flatten(c, searchDir);
    }
}

/// A scoped rule's imports, appended under headings; each file once.
void ruleImports(const Read[] imports, string from, const Startup st, ref string[] seen, ref string[] warnings,
    ref string out_)
{
    foreach (c; imports)
    {
        if (c.refused.length) { warn(warnings, c.refused); continue; }
        if (seen.canFind(c.real_)) continue;
        seen ~= c.real_;
        if (c.text is null) continue;
        out_ ~= format("\n\n## %s (imported by %s)\n\n%s", display(c.path, st.root, st.home),
            display(from, st.root, st.home), c.text);
        ruleImports(c.imports, c.path, st, seen, warnings, out_);
    }
}

void warn(ref string[] warnings, string message)
{
    if (!warnings.canFind(message)) warnings ~= message;
}

string heading(const ref InstructionFile f, const Startup st)
{
    string show(string p) { return display(p, st.root, st.home); }
    final switch (f.kind)
    {
        case Kind.imported: return format("%s (imported by %s)", show(f.path), show(f.importedBy));
        case Kind.rule: return show(f.path) ~ " (rule)";
        case Kind.local: return show(f.path) ~ " (personal, not committed)";
        case Kind.user, Kind.project: return show(f.path);
    }
}

DirRead dupRead(const DirRead d)
{
    DirRead r;
    r.dir = d.dir;
    foreach (f; d.files) r.files ~= dupRead(f);
    return r;
}

Read dupRead(const Read f)
{
    Read r = Read(f.path, f.real_, f.text, f.kind, f.importedBy, f.user, f.refused);
    foreach (c; f.imports) r.imports ~= dupRead(c);
    return r;
}

State copy(const State s)
{
    State n;
    n.loaded = s.loaded.dup;
    n.seen = s.seen.dup;
    n.initialSeen = s.initialSeen.dup;
    n.searched = s.searched.dup;
    foreach (r; s.searchedReads) n.searchedReads ~= dupRead(r);
    n.pending = s.pending.dup;
    n.nestedAttached = s.nestedAttached.dup;
    n.attachedRules = s.attachedRules.dup;
    n.warnings = s.warnings.dup;
    return n;
}

// Tests of the transitions on hand-made reads, with no disk.

version (unittest) Read file(string path, string text, Read[] imports = null)
{
    return Read(path, path, text, Kind.project, null, false, null, imports);
}

unittest // begin shows each file once, imports depth first, warnings once
{
    Startup st;
    st.root = "/r";
    auto shared_ = Read("/r/s.md", "/r/s.md", "shared", Kind.imported, "/r/CLAUDE.md");
    auto refused = Read(null, null, null, Kind.imported, null, false, "skipped import");
    st.sources = [Source("/r", file("/r/CLAUDE.md", "top", [shared_, refused, shared_]))];
    st.initialDirs = ["/r"];
    auto s = begin(st);
    assert(s.loaded.length == 2 && s.loaded[1].text == "shared" && s.warnings == ["skipped import"]);
    assert(render(st, s).canFind("## s.md (imported by CLAUDE.md)"));
}

unittest // attach: a directory once, deferral re-reads, forget starts over
{
    Startup st;
    st.root = "/r";
    st.initialDirs = ["/r"];
    auto s = begin(st);
    auto pkg = DirRead("/r/pkg", [file("/r/pkg/AGENTS.md", "pkg rule")]);
    assert(needsRead(s, st, "/r/pkg") && !needsRead(s, st, "/r"));
    auto a = attach(s, st, [pkg], null, "pkg/x", true);
    assert(a.text.canFind("pkg rule") && !needsRead(a.state, st, "/r/pkg"));
    assert(a.state.searchedReads == [pkg] && loadedPaths(st, a.state) == ["/r/pkg/AGENTS.md"]);
    assert(attach(a.state, st, [pkg], null, "pkg/y", true).text is null);
    auto f = forget(a.state);
    assert(needsRead(f, st, "/r/pkg") && attach(f, st, [pkg], null, "pkg/x", true).text.canFind("pkg rule"));
    // Too big: deferred and pending, retried on the next call; after
    // compaction the directory is read afresh.
    import std.array : replicate;
    auto big = DirRead("/r/big", [file("/r/big/AGENTS.md", "x".replicate(maxTotalBytes))]);
    auto d = attach(s, st, [big], null, "big/x", true);
    assert(d.text == omittedMarker && needsRead(d.state, st, "/r/big") && d.state.warnings[0].canFind("deferred"));
    assert(d.state.pending.length == 1 && attach(d.state, st, [big], null, "big/x", true).text == omittedMarker);
    auto small = DirRead("/r/big", [file("/r/big/AGENTS.md", "fits now")]);
    assert(attach(forget(d.state), st, [small], null, "big/x", true).text.canFind("fits now"));
}

unittest // scoped rules: matched ones attach once with their imports
{
    Startup st;
    st.root = "/r";
    auto detail = Read("/r/d.md", "/r/d.md", "detail", Kind.imported, "/r/rules/a.md");
    st.rules = [RuleRead("/r/rules/a.md", "/r/rules/a.md", "src", "rule a", false, [detail]),
        RuleRead("/r/rules/b.md", "/r/rules/b.md", "src", "rule b", false)];
    auto s = begin(st);
    auto a = attach(s, st, null, [true, false], "a/x", true);
    assert(a.text.canFind("rule a") && a.text.canFind("## d.md (imported by rules/a.md)") && !a.text.canFind("rule b"));
    assert(onDemandPaths(st, a.state) == ["/r/rules/b.md"]);
    assert(attach(a.state, st, null, [true, false], "a/y", true).text is null);
    assert(attach(s, st, null, [true, true], "x", false).text is null, "outside the root: no rules");
}

unittest // sameFiles compares what was read
{
    Startup a, b;
    a.root = b.root = "/r";
    a.sources = [Source("/r", file("/r/AGENTS.md", "one"))];
    b.sources = [Source("/r", file("/r/AGENTS.md", "one"))];
    assert(sameFiles(a, b));
    b.sources[0].read.text = "two";
    assert(!sameFiles(a, b));
    b.sources[0].read.text = "one";
    b.rules = [RuleRead("/r/x.md", "/r/x.md", "s", "b", false)];
    assert(!sameFiles(a, b));
}
