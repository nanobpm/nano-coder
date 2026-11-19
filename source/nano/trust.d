/// Per-repository trust: what a cloned repository can inject into the agent
/// (its skills, its skill lock and its `.claude/settings*.json` hooks) loads
/// only once the user has trusted that repository. `--yolo` and `--acp` trust
/// without asking; an interactive start asks once and remembers a yes.
module nano.trust;

@safe:
import nano.clock : monoNow;

import std.algorithm : canFind, any, startsWith, endsWith;
import std.array : array;
import std.file : exists, isDir, isFile, readText, mkdirRecurse, dirEntries, SpanMode;
import std.path : buildPath, baseName, dirName, expandTilde, pathSplitter;
import std.process : environment;
import std.string : splitLines, strip, toLower, lineSplitter;
import std.utf : validate;
import nano.skills : canonical;

/// How deep below a skills directory to look for a `SKILL.md`.
enum maxScanDepth = 4;

/// Where trusted repository roots are kept, one canonical path per line.
string trustFile()
{
    if (auto x = environment.get("NANO_CODER_TRUST_FILE")) return x;
    if (auto x = environment.get("XDG_CONFIG_HOME")) return buildPath(x, "nano-coder", "trusted-projects");
    return buildPath(expandTilde("~"), ".config", "nano-coder", "trusted-projects");
}

/// The directory trust is granted for: the repository root (or `cwd` itself).
string trustRoot(string cwd)
{
    import nano.skills : gitRoot;
    auto c = canonical(cwd);
    if (c is null) c = cwd;
    auto r = gitRoot(c);
    return r !is null ? (canonical(r) is null ? r : canonical(r)) : c;
}

/// Inputs to the trust decision that do not come from the filesystem.
struct Options
{
    /// `--yolo` / `--acp`: trust without asking.
    bool yolo, acp;
    /// A human can answer (stdin and stdout are terminals, no `-p`).
    bool interactive;
    /// Whether project hooks / workspace skills could load at all: a
    /// disabled resource is not gated, so it never drives the question.
    bool hooksEnabled = true, skillsEnabled = true;
}

/// Which gated resources a repository carries.
struct Gated
{
    bool skills, hooks;

    /// Detect what `root` carries that could actually load.
    static Gated detect(string root, const string[] skillDirs, bool aiLock, bool skillsEnabled, bool hooksEnabled)
    {
        Gated g;
        if (skillsEnabled)
        {
            g.skills = aiLock && isFileAt(buildPath(root, "ai.lock"));
            foreach (d; skillDirs)
                if (!g.skills && dirHasSkill(root, buildPath(root, d))) g.skills = true;
        }
        g.hooks = hooksEnabled && (isFileAt(buildPath(root, ".claude/settings.json"))
            || isFileAt(buildPath(root, ".claude/settings.local.json")));
        return g;
    }

    bool empty() pure const { return !skills && !hooks; }

    /// The `<resources>` phrase for the trust question.
    string describe() pure const
    {
        return skills && hooks ? "skills and hooks" : skills ? "skills" : hooks ? "hooks" : "nothing";
    }
}

private bool isFileAt(string p)
{
    try return exists(p) && isFile(p);
    catch (Exception) return false; // unreadable counts as absent
}

/// Whether `answer` is an affirmative (`y`/`yes`, any case and padding).
bool isYes(string answer) pure { return ["y", "yes"].canFind(answer.strip.toLower); }

/// The trust question for `root`.
string trustQuestion(string root, Gated gated) pure
{
    return "Trust this repo? " ~ escapeDebug(root) ~ " has " ~ gated.describe
        ~ " that can run commands or steer the agent.\nLoad its skills and hooks? [y/N] ";
}

/// `s` with control characters escaped, so a crafted path can't drive the terminal.
string escapeDebug(string s) pure
{
    import std.format : format;
    string o;
    foreach (dchar c; s)
    {
        if (c == '\n') o ~= `\n`;
        else if (c == '\r') o ~= `\r`;
        else if (c == '\t') o ~= `\t`;
        else if (c == '\\') o ~= `\\`;
        else if (c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0)) o ~= format(`\u{%x}`, cast(uint) c);
        else o ~= c;
    }
    return o;
}

/// Decide trust for `root` (no memoisation). `confirm` asks the question and
/// returns true on a yes; `note` gets the one-line non-interactive warning.
bool decideRoot(string root, const string[] skillDirs, bool aiLock, Options opts, string file,
    scope bool delegate(string root, Gated gated) @safe confirm, scope void delegate(string msg) @safe note)
{
    // `--yolo` / `--acp` trust without asking, even an empty root.
    if (opts.yolo || opts.acp) return true;
    // A remembered root is trusted with no question, even non-interactively.
    if (isRemembered(root, file)) return true;
    auto gated = Gated.detect(root, skillDirs, aiLock, opts.skillsEnabled, opts.hooksEnabled);
    // Nothing to gate: no question, but an unapproved root stays untrusted.
    if (gated.empty) return false;
    if (!opts.interactive)
    {
        if (note !is null)
            note("not loading skills or hooks from untrusted " ~ escapeDebug(root)
                ~ " (start interactively to trust it, or pass --yolo)");
        return false;
    }
    if (confirm is null || !confirm(root, gated)) return false;
    remember(root, file);
    return true;
}

/// Whether `path`'s canonical target is a file inside `boundary`, clear of `.git`.
private bool withinBoundary(string path, string boundary)
{
    auto real_ = canonical(path);
    return real_ !is null && underPath(real_, boundary) && !real_.pathSplitter.canFind(".git") && isFileAt(real_);
}

private bool underPath(string path, string root) pure
{
    return path == root || path.startsWith(root.endsWith("/") ? root : root ~ "/");
}

/// Whether `dir` carries a `SKILL.md` within `maxScanDepth`, walked the way
/// discovery walks it: canonical targets only, confined to the repository
/// (for the configured dir) and to the configured dir (below it), skipping
/// `.git` and dot entries. Each canonical directory is rescanned only when
/// reached by a shorter path, so symlink cycles cannot blow the walk up.
bool dirHasSkill(string repoRoot, string dir)
{
    auto repo = canonical(repoRoot);
    auto boundary = canonical(dir);
    if (repo is null || boundary is null || !underPath(boundary, repo)) return false;
    size_t[string] visited;
    bool scan(string d, size_t depth)
    {
        auto real_ = canonical(d);
        if (real_ is null || !underPath(real_, boundary) || real_.pathSplitter.canFind(".git")) return false;
        if (auto seen = real_ in visited)
            if (*seen <= depth) return false;
        visited[real_] = depth;
        if (withinBoundary(buildPath(real_, "SKILL.md"), boundary)) return true;
        if (depth >= maxScanDepth) return false;
        string[] children;
        try
        {
            if (!isDir(real_)) return false;
            foreach (e; dirEntries(real_, SpanMode.shallow, false))
                if (!e.name.baseName.startsWith(".")) children ~= e.name;
        }
        catch (Exception) return false; // an unreadable directory can't hold a skill we would load
        foreach (c; children)
            if (scan(c, depth + 1)) return true;
        return false;
    }
    return scan(dir, 0);
}

/// The exact line persisting `root`, or null when the line-based file can't
/// hold it losslessly (invalid UTF-8, a line break, empty): such a root is
/// never matched or remembered.
string trustKey(string root) pure
{
    if (!root.length || root.canFind('\n') || root.canFind('\r')) return null;
    try validate(root);
    catch (Exception) return null; // a non-UTF-8 root can't be stored as a trust line: never trusted
    return root;
}

/// Whether `root` is recorded in `file`. Only complete, newline-terminated
/// records count: a partial trailing record fails the whole lookup closed.
bool isRemembered(string root, string file)
{
    auto key = trustKey(root);
    if (key is null || file is null) return false;
    string text;
    try
    {
        if (!exists(file)) return false;
        text = readText(file);
    }
    catch (Exception) return false; // an unreadable trust file trusts nothing (fail closed)
    if (text.length && !text.endsWith("\n")) return false;
    // An exact line only: a padded entry never authorizes the trimmed root.
    return text.lineSplitter.canFind!(l => l == key);
}

/// Back-compat name.
alias isTrusted = isRemembered;

/// Append `root` to `file`, once. The read, the checks and the append run
/// under an exclusive `flock` on the file, and the key and its newline go out
/// in one write, so concurrent approvals never splice. Nothing is written
/// when the existing content can't be read or lacks a final newline (the
/// root stays trusted for this process only).
void remember(string root, string file)
{
    import core.sys.posix.fcntl : O_RDWR, O_APPEND, O_CREAT;
    import nano.safeio : openPath, closeFd, readFd, writeFd;
    auto key = trustKey(root);
    if (key is null || file is null) return;
    try mkdirRecurse(dirName(file));
    catch (Exception) {} // if the dir can't be made, the open below fails and nothing is remembered: asked again next time
    auto fd = openPath(file, O_RDWR | O_APPEND | O_CREAT, octal600);
    if (fd < 0) return;
    scope (exit) closeFd(fd);
    if (flock(fd, lockEx) != 0) return;
    scope (exit) flock(fd, lockUn);
    ubyte[] existing;
    ubyte[4096] buf;
    for (;;)
    {
        ptrdiff_t n;
        try n = readFd(fd, buf[]);
        catch (Exception) return; // unreadable: don't append blind; the user is asked again next time
        if (n < 0) return;
        if (n == 0) break;
        existing ~= buf[0 .. n];
    }
    auto text = cast(const(char)[]) existing;
    if (text.lineSplitter.canFind!(l => l == key)) return;
    if (text.length && !text.endsWith("\n")) return;
    try writeFd(fd, cast(const(ubyte)[]) (key ~ "\n"));
    catch (Exception) {} // not remembered: the user is asked again next time (fail closed)
}

private enum octal600 = 0x180;
private extern (C) int flock(int, int) nothrow @nogc;
private enum lockEx = 2, lockUn = 8;

version (unittest)
{
    private enum skillDirs = [".claude/skills", ".agents/skills"];

    /// A fresh canonical temp directory per test.
    private string freshRoot(string name)
    {
        import std.file : tempDir, rmdirRecurse;
        auto d = buildPath(tempDir, "nano-d-trust-" ~ name);
        if (d.exists) rmdirRecurse(d);
        mkdirRecurse(d);
        return canonical(d);
    }

    private string withHook(string root)
    {
        import std.file : write;
        mkdirRecurse(buildPath(root, ".claude"));
        write(buildPath(root, ".claude/settings.json"),
            `{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}`);
        return root;
    }

    private void addSkill(string dir)
    {
        import std.file : write;
        mkdirRecurse(dir);
        write(buildPath(dir, "SKILL.md"), "# x\n");
    }

    private Options opts(bool interactive, bool yolo, bool acp) pure
    {
        Options o;
        o.interactive = interactive;
        o.yolo = yolo;
        o.acp = acp;
        return o;
    }

    /// A scripted asker: `answer` null is EOF.
    private struct Asker
    {
        string answer;
        bool asked;
        string noted;
        bool confirm(string root, Gated gated) pure { asked = true; return answer !is null && isYes(answer); }
        void note(string msg) pure { noted = msg; }
    }

    private bool decide(string root, Options o, string file, ref Asker a)
    {
        return decideRoot(root, skillDirs, true, o, file, &a.confirm, &a.note);
    }

    private Gated detect(string root, bool skillsOn = true, bool hooksOn = true)
    {
        return Gated.detect(root, skillDirs, true, skillsOn, hooksOn);
    }
}

// rust: trust.rs::no_gated_resources_stays_gated_without_a_question
unittest
{
    auto root = freshRoot("empty");
    auto file = buildPath(root, "trusted-projects");
    auto a = Asker("y");
    assert(!decide(root, opts(true, false, false), file, a), "an empty, unapproved root is not granted trust");
    assert(!a.asked && !file.exists);
}

// rust: trust.rs::non_interactive_note_escapes_control_characters_in_the_path
unittest
{
    auto weird = withHook(buildPath(freshRoot("weird"), "re\x1bpo\nname"));
    auto a = Asker("y");
    assert(!decide(weird, opts(false, false, false), buildPath(weird, "../trusted-projects"), a));
    assert(a.noted.length && !a.noted.canFind('\x1b') && !a.noted.canFind('\n'), a.noted);
    assert(a.noted.canFind(`re\u{1b}po\nname`), a.noted);
}

// rust: trust.rs::yolo_and_acp_trust_even_an_empty_root
unittest
{
    foreach (o; [opts(true, true, false), opts(false, false, true), opts(false, true, true)])
    {
        auto root = freshRoot("yolo-acp");
        Asker a;
        assert(decide(root, o, buildPath(root, "trusted-projects"), a) && !a.asked);
    }
}

// rust: trust.rs::remembered_empty_root_is_trusted
// rust: trust.rs::remembered_root_is_trusted_even_non_interactively
unittest
{
    import std.file : write;
    auto root = freshRoot("remembered");
    auto file = buildPath(root, "trusted-projects");
    write(file, root ~ "\n");
    Asker a;
    assert(decide(root, opts(false, false, false), file, a) && !a.asked);
    withHook(root);
    assert(decide(root, opts(false, false, false), file, a) && a.noted is null, "no note for a remembered root");
}

// rust: trust.rs::detection_follows_symlinked_skill_dirs
unittest
{
    import std.file : symlink;
    auto root = freshRoot("symlinked-dir");
    addSkill(buildPath(root, "real/x"));
    mkdirRecurse(buildPath(root, ".claude"));
    symlink(buildPath(root, "real"), buildPath(root, ".claude/skills"));
    assert(detect(root).skills, "a skill behind a symlinked skills dir is still gated");
}

// rust: trust.rs::yolo_trusts_without_asking
// rust: trust.rs::acp_trusts_without_asking
// rust: trust.rs::non_interactive_is_untrusted_with_a_note
// rust: trust.rs::empty_answer_is_no
// rust: trust.rs::eof_answer_is_no
unittest
{
    auto root = withHook(freshRoot("hooked"));
    auto file = buildPath(root, "trusted-projects");
    Asker a;
    assert(decide(root, opts(true, true, false), file, a) && !a.asked && !file.exists, "--yolo never asks or remembers");
    assert(decide(root, opts(false, false, true), file, a) && !a.asked, "--acp never asks");
    assert(!decide(root, opts(false, false, false), file, a) && !a.asked);
    assert(a.noted.canFind("not loading skills or hooks from untrusted") && a.noted.canFind("--yolo"), a.noted);
    a = Asker("");
    assert(!decide(root, opts(true, false, false), file, a) && a.asked && !file.exists, "an empty answer is no");
    a = Asker(null);
    assert(!decide(root, opts(true, false, false), file, a) && a.asked, "EOF is no");
}

// rust: trust.rs::yes_variants_trust_and_remember_once
unittest
{
    import std.algorithm : count;
    foreach (answer; ["y", "Y", "yes", "  YES  "])
    {
        auto root = withHook(freshRoot("yes"));
        auto file = buildPath(root, "trusted-projects");
        auto a = Asker(answer);
        assert(decide(root, opts(true, false, false), file, a), answer);
        assert(readText(file).lineSplitter.count!(l => l == root) == 1, "remembered once");
        auto b = Asker(null);
        assert(decide(root, opts(true, false, false), file, b) && !b.asked, "a remembered root is not asked again");
    }
}

// rust: trust.rs::trailing_whitespace_entry_does_not_authorize_trimmed_root
// rust: trust.rs::remember_round_trips_an_exact_match
unittest
{
    import std.file : write;
    import std.algorithm : count;
    auto dir = freshRoot("exact");
    auto file = buildPath(dir, "trusted-projects");
    auto root = buildPath(dir, "repo");
    write(file, root ~ " \n");
    assert(!isRemembered(root, file), "a padded entry must not authorize the trimmed root");
    write(file, "");
    remember(root, file);
    assert(isRemembered(root, file));
    remember(root, file);
    assert(readText(file).lineSplitter.count!(l => l.length > 0) == 1, "remembered once");
}

// rust: trust.rs::remember_fails_closed_when_existing_file_is_unreadable
unittest
{
    import std.file : write, setAttributes;
    auto dir = freshRoot("unreadable");
    auto file = buildPath(dir, "trusted-projects");
    auto existing = buildPath(dir, "existing"), fresh = buildPath(dir, "fresh");
    write(file, existing ~ "\n");
    setAttributes(file, 0x80); // 0o200: write-only
    remember(fresh, file);
    setAttributes(file, 0x180);
    assert(readText(file) == existing ~ "\n", "the unreadable file is left untouched");
    assert(!isRemembered(fresh, file));
}

// rust: trust.rs::remember_never_splices_onto_a_newline_less_final_entry
unittest
{
    import std.file : write;
    auto dir = freshRoot("splice");
    auto file = buildPath(dir, "trusted-projects");
    auto first = buildPath(dir, "first"), second = buildPath(dir, "second");
    write(file, first);
    remember(second, file);
    assert(readText(file) == first, "the unterminated entry is left untouched");
    assert(!isRemembered(first, file) && !isRemembered(second, file) && !isRemembered(first ~ second, file));
    write(file, first ~ "\n");
    remember(second, file);
    assert(isRemembered(first, file) && isRemembered(second, file), "appended as its own line");
    assert(!isRemembered(first ~ second, file));
}

// rust: trust.rs::is_remembered_rejects_an_unterminated_record
unittest
{
    import std.file : write;
    auto dir = freshRoot("unterminated");
    auto file = buildPath(dir, "trusted-projects");
    auto parent = buildPath(dir, "parent"), repo = buildPath(parent, "repo"), other = buildPath(dir, "other");
    write(file, parent);
    assert(!isRemembered(parent, file) && !isRemembered(repo, file));
    write(file, other ~ "\n" ~ parent);
    assert(!isRemembered(other, file) && !isRemembered(parent, file), "a partial trailing record invalidates lookup");
    write(file, repo ~ "\n");
    assert(isRemembered(repo, file) && !isRemembered(parent, file));
}

// rust: trust.rs::concurrent_remembers_never_splice_or_lose_an_entry
// (threads, each with its own open file description: flock serialises them
// exactly as it does separate processes)
unittest
{
    import nano.safeio : spawn;
    import std.format : format;
    auto dir = freshRoot("concurrent");
    auto file = buildPath(dir, "trusted-projects");
    static bool approve(string root, string file) @safe { remember(root, file); return true; }
    string[] roots;
    foreach (i; 0 .. 8) roots ~= buildPath(dir, format("repo-%s", i));
    typeof(spawn(&approve, "", ""))[] hs;
    foreach (r; roots) hs ~= spawn(&approve, r, file);
    foreach (ref h; hs) h.join();
    auto lines = readText(file).splitLines;
    foreach (l; lines) assert(roots.canFind(l), "unexpected or spliced entry: " ~ l);
    foreach (r; roots) assert(isRemembered(r, file), "no approval was lost: " ~ r);
    assert(lines.length == roots.length);
}

// rust: trust.rs::newline_bearing_path_is_not_representable
// rust: trust.rs::non_utf8_paths_are_not_conflated
unittest
{
    auto dir = freshRoot("keys");
    auto file = buildPath(dir, "trusted-projects");
    assert(trustKey("/tmp/re\npo") is null);
    remember("/tmp/re\npo", file);
    assert(!file.exists || readText(file).length == 0, "it is not persisted");
    assert(!isRemembered("/tmp/re\npo", file));
    string a = "/tmp/repo\xFF", b = "/tmp/repo\xFE";
    assert(trustKey(a) is null && trustKey(b) is null, "non-UTF-8 paths have no key");
    remember(a, file);
    assert(!isRemembered(a, file) && !isRemembered(b, file));
}

// rust: trust.rs::disabled_project_hooks_are_not_gated
// rust: trust.rs::hook_only_repo_stays_ungated_when_hooks_disabled
unittest
{
    auto root = withHook(freshRoot("hooks-off"));
    assert(detect(root).hooks);
    assert(!detect(root, true, false).hooks && detect(root, true, false).empty);
    auto o = opts(true, false, false);
    o.hooksEnabled = false;
    auto a = Asker("y");
    assert(!decide(root, o, buildPath(root, "trusted-projects"), a) && !a.asked);
}

// rust: trust.rs::detects_workspace_skills
// rust: trust.rs::empty_skill_dir_is_not_gated
// rust: trust.rs::ai_lock_is_gated
// rust: trust.rs::disabled_skills_are_not_gated
unittest
{
    import std.file : write;
    auto root = freshRoot("skills");
    mkdirRecurse(buildPath(root, ".agents/skills"));
    assert(detect(root).empty, "an empty skills dir carries no skill");
    addSkill(buildPath(root, ".claude/skills/x"));
    auto g = detect(root);
    assert(g.skills && !g.hooks && g.describe == "skills");
    assert(detect(root, false).empty, "skills are not gated when they cannot load");
    auto lock = freshRoot("ai-lock");
    write(buildPath(lock, "ai.lock"), "{}");
    assert(detect(lock).skills, "ai.lock is a gated skill source");
    assert(!detect(lock, false).skills);
}

// rust: trust.rs::scan_terminates_on_symlink_cycles
// rust: trust.rs::scan_finds_skill_through_shorter_path_despite_cycle
unittest
{
    import std.file : symlink;
    import std.format : format;
    import core.time : MonoTime, seconds;
    auto root = freshRoot("cycles");
    auto skills = buildPath(root, ".claude/skills");
    mkdirRecurse(skills);
    foreach (i; 0 .. 8) symlink(skills, buildPath(skills, format("loop%s", i)));
    auto t0 = monoNow;
    assert(!detect(root).skills, "a cycle with no SKILL.md carries no skill");
    assert(monoNow - t0 < 5.seconds, "the cycle must not blow up the scan");
    addSkill(buildPath(skills, "real"));
    assert(detect(root).skills, "a real skill is found even alongside a cycle");
}

// rust: trust.rs::detection_rejects_a_skills_dir_symlinked_outside_the_repo
// rust: trust.rs::detection_rejects_a_subdirectory_symlinked_outside_the_skills_root
// rust: trust.rs::detection_rejects_a_skill_file_symlinked_outside_the_skills_root
unittest
{
    import std.file : symlink;
    auto external = freshRoot("external");
    addSkill(buildPath(external, "x"));
    auto a = freshRoot("ext-dir");
    mkdirRecurse(buildPath(a, ".claude"));
    symlink(external, buildPath(a, ".claude/skills"));
    assert(detect(a).empty, "a skills dir symlinked outside the repo is not gated");
    auto b = freshRoot("ext-sub");
    mkdirRecurse(buildPath(b, ".claude/skills"));
    symlink(external, buildPath(b, ".claude/skills/ext"));
    assert(!detect(b).skills, "a skill reachable only by escaping the skills root is not gated");
    auto c = freshRoot("ext-file");
    mkdirRecurse(buildPath(c, ".claude/skills/x"));
    symlink(buildPath(external, "x/SKILL.md"), buildPath(c, ".claude/skills/x/SKILL.md"));
    assert(!detect(c).skills, "a SKILL.md symlinked outside the skills root is not gated");
}

// rust: trust.rs::detection_skips_a_skill_file_symlinked_through_a_dot_git
// rust: trust.rs::detection_skips_a_dot_git_entry_inside_the_skills_root
unittest
{
    import std.file : symlink;
    auto a = freshRoot("git-link");
    addSkill(buildPath(a, ".claude/skills/.git"));
    mkdirRecurse(buildPath(a, ".claude/skills/x"));
    symlink(buildPath(a, ".claude/skills/.git/SKILL.md"), buildPath(a, ".claude/skills/x/SKILL.md"));
    assert(!detect(a).skills, "a SKILL.md resolving under a .git component is not gated");
    auto b = freshRoot("git-entry");
    addSkill(buildPath(b, ".claude/skills/.git/x"));
    assert(!detect(b).skills, "a SKILL.md under a .git component is not gated");
}

// rust: trust.rs::describe_covers_both
// rust: trust.rs::trust_file_honours_env_override
unittest
{
    assert(Gated(true, true).describe == "skills and hooks");
    assert(Gated(false, true).describe == "hooks");
    auto old = environment.get("NANO_CODER_TRUST_FILE");
    environment["NANO_CODER_TRUST_FILE"] = "hunter2";
    scope (exit) { if (old is null) environment.remove("NANO_CODER_TRUST_FILE"); else environment["NANO_CODER_TRUST_FILE"] = old; }
    assert(trustFile() == "hunter2");
}
