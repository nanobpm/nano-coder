/// OS sandbox for shell commands: Seatbelt (`sandbox-exec`) on macOS and
/// Landlock (`nano/landlock.d`) on Linux (port of `sandbox.rs`).
///
/// Commands can read everywhere but write only to the working directory (in
/// `workspace` mode), its git directories, temp directories, package-manager
/// caches and any extra `writable` paths. `read-only` mode allows only temp
/// directories. `network = false` blocks outbound connections except to
/// localhost.
///
/// The sandbox fails closed: when it is enabled but can't be applied (no
/// `sandbox-exec`, or a kernel without Landlock ABI 3, or ABI 4 when the
/// network is blocked), the command does not run.
module nano.sandbox;

import std.algorithm : canFind, any, filter, count;
import std.array : join;
import std.format : format;
import std.json;
import std.string : startsWith, endsWith, replace, strip, splitLines;

import nano.paths : canonicalize, homeDir, isDir, joinPath, normalize;

version (OSX) version = HasOsSandbox;
version (linux) version = HasOsSandbox;

@safe:

enum SandboxMode { off, workspace, readOnly }

string modeName(SandboxMode m) pure nothrow
{
    final switch (m)
    {
        case SandboxMode.off: return "off";
        case SandboxMode.workspace: return "workspace";
        case SandboxMode.readOnly: return "read-only";
    }
}

/// Parse a mode name; throws with the Rust message on anything else.
SandboxMode parseMode(string s)
{
    switch (s)
    {
        case "off", "none": return SandboxMode.off;
        case "workspace", "workspace-write": return SandboxMode.workspace;
        case "read-only", "readonly": return SandboxMode.readOnly;
        default:
            throw new Exception(format("unknown sandbox mode %s (expected off, workspace or read-only)", JSONValue(s).toString));
    }
}

/// Cache directories under `$HOME` that build tools write to.
immutable string[] toolCacheDirs = [
    ".cargo/registry", ".cargo/git", ".cargo/.package-cache", ".cargo/.package-cache-mutate",
    ".cargo/.global-cache", ".rustup/tmp", ".rustup/downloads", ".npm", ".cache", "Library/Caches",
    ".gradle", ".m2/repository", "go/pkg/mod", ".bun/install/cache", ".pnpm-store", "Library/pnpm",
    ".local/share/pnpm", ".yarn/berry/cache", ".deno", ".dub",
];

/// Single device nodes commands need for I/O (a file each, safe in every mode).
immutable string[] deviceNodes = ["/dev/null", "/dev/zero", "/dev/tty", "/dev/stdout", "/dev/stderr",
    "/dev/ptmx", "/dev/dtracehelper"];

/// Device directories granted as a subtree. Only `/dev/fd`: its entries are the
/// process's own open descriptors. `/dev/pts` and `/dev/shm` are host-shared and
/// deliberately excluded; grant them through `writable` if really needed.
immutable string[] deviceDirs = ["/dev/fd"];

struct SandboxConfig
{
    SandboxMode mode;
    /// Extra writable paths (`~/…`, absolute, or relative to the working directory).
    string[] writable;
    /// Allow outbound network connections.
    bool network = true;
    /// In workspace mode, also allow writes to package-manager caches.
    bool toolCaches = true;

    /// From the `[sandbox]` table; throws on a bad mode or type.
    static SandboxConfig fromJSON(JSONValue v) @trusted
    {
        SandboxConfig c;
        if (v.type != JSONType.object) return c;
        if (auto x = "mode" in v) c.mode = parseMode(x.str);
        if (auto x = "writable" in v) foreach (w; x.array) c.writable ~= w.str;
        if (auto x = "network" in v) c.network = x.boolean;
        if (auto x = "tool_caches" in v) c.toolCaches = x.boolean;
        return c;
    }

    bool active() const pure nothrow { return mode != SandboxMode.off; }

    /// Canonical paths commands may write to when run in `cwd`.
    string[] writableRoots(string cwd) const
    {
        string[] roots;
        void add(string path)
        {
            // Never grant `/` (e.g. TMPDIR=/ or a symlink resolving there).
            auto r = canonicalize(path);
            if (r !is null && r != "/" && !roots.canFind(r)) roots ~= r;
        }
        auto home = homeDir();
        auto cwdReal = canonicalize(cwd);
        if (cwdReal is null) cwdReal = cwd;
        if (mode == SandboxMode.workspace)
        {
            if (cwd != "/") add(cwd);
            auto dirs = gitDirs(cwd);
            bool worktreeOfCwd;
            foreach (d; dirs)
                if (auto r = canonicalize(d))
                    worktreeOfCwd = worktreeOfCwd || worktreeBackpointerWithin(r, cwdReal);
            foreach (d; dirs)
            {
                // A poisoned `.git` file can point at an unrelated repository:
                // grant only git dirs inside the workspace, whose repo contains
                // it, or that git ties back to this worktree.
                auto r = canonicalize(d);
                if (r is null) continue;
                auto parent = parentOf(r);
                if (within(r, cwdReal) || (parent !is null && within(cwdReal, parent)) || worktreeOfCwd) add(d);
            }
            if (toolCaches && home.length)
            {
                auto homeReal = canonicalize(home);
                foreach (cache; toolCacheDirs)
                {
                    auto path = joinPath(home, cache);
                    ensureDir(path);
                    // A cache symlinked outside home would widen the grant.
                    auto r = canonicalize(path);
                    if (r !is null && r != "/" && homeReal !is null && within(r, homeReal)) add(r);
                }
            }
        }
        auto temp = tempDirectory();
        add(temp);
        // macOS per-user temp: $TMPDIR is .../T/; its sibling C/ holds caches.
        if (auto t = canonicalize(temp))
            if (t.endsWith("/T"))
                if (auto p = parentOf(t)) add(p);
        add("/tmp");
        add("/var/tmp");
        foreach (d; deviceNodes) add(d);
        if (mode == SandboxMode.workspace) foreach (d; deviceDirs) add(d);
        foreach (extra; writable)
        {
            bool tilde = extra.startsWith("~/") && home.length;
            bool relative = !tilde && !extra.startsWith("/");
            auto path = tilde ? joinPath(home, extra[2 .. $]) : joinPath(cwd, extra);
            ensureDir(path);
            if (relative)
            {
                // A relative extra names a workspace subdirectory; a symlink
                // escaping the workspace must not widen the grant.
                auto r = canonicalize(path);
                if (r !is null && r != "/" && within(r, cwdReal)) add(r);
            }
            else add(path);
        }
        return roots;
    }

    /// Whether the sandbox would let a command write `path` (for the file
    /// tools, which run in-process).
    bool allowsWrite(string path, string cwd) const
    {
        if (!active) return true;
        auto full = path.startsWith("/") ? path : joinPath(cwd, path);
        // Resolve the deepest existing ancestor, so symlinks can't escape.
        string[] rest;
        string existing = full;
        string resolved;
        while (true)
        {
            if (auto r = canonicalize(existing))
            {
                resolved = r;
                foreach_reverse (part; rest) resolved = joinPath(resolved, part);
                break;
            }
            auto parent = parentOf(existing);
            auto name = baseOf(existing);
            if (parent is null || name is null) return false;
            rest ~= name;
            existing = parent;
        }
        resolved = normalize(resolved);
        foreach (root; writableRoots(cwd))
            if (within(resolved, root)) return true;
        return false;
    }

    /// A short description for messages to the model.
    string describe(string cwd) const
    {
        string[] shown;
        size_t total;
        foreach (r; writableRoots(cwd))
        {
            if (within(r, "/dev")) continue;
            ++total;
            if (shown.length < 6) shown ~= r;
        }
        auto more = total - shown.length;
        return format("commands run in a %s sandbox: they can write only to %s%s%s", mode.modeName, shown.join(", "),
            more > 0 ? format(" and %s cache directories", more) : "",
            network ? "" : "; outbound network is blocked");
    }

    /// The argv that runs `shell -c script` inside the sandbox; throws when the
    /// sandbox can't be applied here (fail closed).
    string[] command(string shell, string script, string cwd) const
    {
        version (OSX)
        {
            enum sandboxExec = "/usr/bin/sandbox-exec";
            import std.file : exists;
            if (!exists(sandboxExec)) throw new Exception("sandbox unavailable: " ~ sandboxExec ~ " not found");
            return [sandboxExec, "-p", profile(writableRoots(cwd)), shell, "-c", script];
        }
        else version (linux)
        {
            import nano.landlock : check, argv;
            if (auto e = check(network)) throw new Exception(e);
            return argv(network, writableRoots(cwd), shell, script);
        }
        else
            throw new Exception("sandbox unavailable on this platform");
    }

    /// The Seatbelt profile for `roots`.
    string profile(const string[] roots) const
    {
        string allowed;
        foreach (root; roots)
            allowed ~= format(" (%s %s)", isDir(root) ? "subpath" : "literal", quote(root));
        // Roots are listed literally (including /dev/tty); no broad ^/dev/tty
        // regex, which would also grant serial/USB nodes.
        auto p = "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*" ~ allowed ~ ")\n";
        if (!network)
            p ~= "(deny network-outbound (remote ip))\n(allow network-outbound (remote ip \"localhost:*\"))\n";
        return p;
    }
}

/// Whether `output` of a failed sandboxed command looks like a sandbox denial.
bool looksDenied(string output) pure
{
    return ["Operation not permitted", "Read-only file system", "Permission denied"].any!(d => output.canFind(d));
}

private:

string quote(string path) pure
{
    return `"` ~ path.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
}

/// `path` equals `root` or lies below it (component-wise).
bool within(string path, string root) pure nothrow
{
    if (root == "/") return path.startsWith("/");
    return path == root || (path.startsWith(root) && path.length > root.length && path[root.length] == '/');
}

string parentOf(string p) pure nothrow
{
    while (p.length > 1 && p[$ - 1] == '/') p = p[0 .. $ - 1];
    if (p == "/" || !p.length) return null;
    foreach_reverse (i, c; p)
        if (c == '/') return i == 0 ? "/" : p[0 .. i];
    return null;
}

string baseOf(string p) pure nothrow
{
    while (p.length > 1 && p[$ - 1] == '/') p = p[0 .. $ - 1];
    if (p == "/" || !p.length) return null;
    foreach_reverse (i, c; p)
        if (c == '/') return p[i + 1 .. $];
    return p;
}

void ensureDir(string path) @trusted
{
    import std.file : exists, mkdirRecurse;
    try if (!exists(path)) mkdirRecurse(path);
    catch (Exception) {}
}

string tempDirectory() @trusted
{
    import std.process : environment;
    auto t = environment.get("TMPDIR");
    return t.length ? t : "/tmp";
}

/// The repository's git directory and, for a worktree, the shared one.
string[] gitDirs(string cwd) @trusted
{
    import std.process : pipeProcess, wait, Redirect, Config;
    import std.array : appender;
    try
    {
        auto p = pipeProcess(["git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
            Redirect.stdout | Redirect.stderr, null, Config.none, cwd);
        auto output = appender!string;
        foreach (chunk; p.stdout.byChunk(4096)) output ~= cast(const(char)[]) chunk;
        if (wait(p.pid) != 0) return null;
        string[] dirs;
        foreach (l; output.data.splitLines)
            if (l.strip.length) dirs ~= joinPath(cwd, l.strip);
        return dirs;
    }
    catch (Exception) return null;
}

/// Whether `gitDir` is the per-worktree git directory of the worktree rooted
/// at `cwdReal` (its `gitdir` back-pointer resolves into it).
bool worktreeBackpointerWithin(string gitDir, string cwdReal) @trusted
{
    import std.file : readText;
    try
    {
        auto parent = parentOf(readText(joinPath(gitDir, "gitdir")).strip);
        return parent !is null && canonicalize(parent) == cwdReal;
    }
    catch (Exception) return false;
}

version (unittest)
{
    /// A fresh directory outside the temp roots (which are always writable).
    string outsideDir() @trusted
    {
        import std.file : getcwd, mkdirRecurse;
        import std.process : thisProcessID;
        static int n;
        mkdirRecurse(getcwd ~ "/.dub");
        auto d = canonicalize(getcwd ~ "/.dub") ~ format("/sbx-test-%s-%s", thisProcessID, ++n);
        mkdirRecurse(d);
        return d;
    }

    /// Run `script` sandboxed in `cwd`: (success, stdout+stderr), or a skip when
    /// the sandbox can't apply (already inside one), announced unless opted in.
    bool run(const SandboxConfig c, string cwd, string script, out bool ok, out string text) @trusted
    {
        import std.process : execute, Config, environment;
        auto r = execute(c.command("bash", script, cwd), null, Config.none, size_t.max, cwd);
        text = r.output;
        ok = r.status == 0;
        if (text.canFind("sandbox_apply: Operation not permitted"))
        {
            import std.stdio : stderr;
            if (environment.get("NANO_SKIP_UNAVAILABLE_SANDBOX_TESTS") is null)
                assert(false, "OS sandbox cannot be applied inside an already-sandboxed process; containment assertions could not run");
            stderr.writeln("SKIP sandbox test: OS sandbox unavailable");
            return false;
        }
        return true;
    }

    void rmTree(string d) @trusted
    {
        import std.file : rmdirRecurse, exists;
        if (exists(d)) rmdirRecurse(d);
    }
}

@trusted unittest
{
    assert(parseMode("workspace") == SandboxMode.workspace);
    assert(parseMode("read-only") == SandboxMode.readOnly);
    bool threw;
    try parseMode("nope"); catch (Exception) threw = true;
    assert(threw);
    import nano.toml : parseToml;
    auto c = SandboxConfig.fromJSON(parseToml("mode = \"read-only\"\nnetwork = false"));
    assert(c.mode == SandboxMode.readOnly && !c.network && c.toolCaches);
}

version (HasOsSandbox) @trusted unittest // workspace mode confines writes
{
    import std.file : write, exists;
    auto ws = outsideDir(), other = outsideDir();
    scope (exit) { rmTree(ws); rmTree(other); }
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false };
    auto victim = other ~ "/keep.txt";
    write(victim, "data");
    auto script = format(`echo hi > inside.txt && mkdir -p sub && echo ok > "${TMPDIR:-/tmp}"/nano-sbx-$$ && rm -f "${TMPDIR:-/tmp}"/nano-sbx-$$ && echo x > /dev/null && echo wrote-inside; rm -f %s; echo x > %s/new.txt; true`, victim, other);
    bool ok; string text;
    if (run(c, ws, script, ok, text))
    {
        assert(text.canFind("wrote-inside"), text);
        assert(exists(ws ~ "/inside.txt"));
        assert(exists(victim), "sandboxed rm deleted a file outside the workspace: " ~ text);
        assert(!exists(other ~ "/new.txt"), text);
    }
    assert(c.allowsWrite("inside.txt", ws));
    assert(c.allowsWrite("new/dir/file", ws));
    assert(!c.allowsWrite(victim, ws));
    assert(!c.allowsWrite("../x", ws));
}

version (HasOsSandbox) @trusted unittest // read-only mode blocks workspace writes
{
    import std.file : exists;
    auto ws = outsideDir();
    scope (exit) rmTree(ws);
    SandboxConfig c = { mode: SandboxMode.readOnly };
    bool ok; string text;
    if (run(c, ws, "echo hi > inside.txt; ls >/dev/null && echo listed", ok, text))
    {
        assert(text.canFind("listed"), text);
        assert(!exists(ws ~ "/inside.txt"), text);
    }
    assert(!c.allowsWrite("inside.txt", ws));
}

version (HasOsSandbox) @trusted unittest // extra writable paths
{
    import std.file : exists;
    auto ws = outsideDir(), extra = outsideDir();
    scope (exit) { rmTree(ws); rmTree(extra); }
    SandboxConfig c = { mode: SandboxMode.readOnly, writable: [extra] };
    bool ok; string text;
    if (run(c, ws, format(`echo hi > "%s/f.txt"`, extra), ok, text))
    {
        assert(ok, text);
        assert(exists(extra ~ "/f.txt"));
    }
}

@trusted unittest // device directories only in workspace mode, never /dev/shm or /dev/pts
{
    import std.file : exists;
    auto ws = outsideDir();
    scope (exit) rmTree(ws);
    SandboxConfig ro = { mode: SandboxMode.readOnly };
    auto roots = ro.writableRoots(ws);
    foreach (d; deviceDirs) assert(!roots.canFind(d), d);
    assert(!ro.allowsWrite("/dev/shm/x", ws));
    assert(ro.allowsWrite("/dev/null", ws));
    SandboxConfig w = { mode: SandboxMode.workspace, toolCaches: false };
    auto wr = w.writableRoots(ws);
    if (exists("/dev/fd")) assert(wr.canFind(canonicalize("/dev/fd")), wr.join(" "));
    assert(!wr.canFind("/dev/shm") && !wr.canFind("/dev/pts"));
    assert(!w.allowsWrite("/dev/shm/x", ws));
}

@trusted unittest // a poisoned .git pointer to an external repo isn't granted
{
    import std.file : write, mkdirRecurse;
    auto ws = outsideDir(), outsider = outsideDir();
    scope (exit) { rmTree(ws); rmTree(outsider); }
    auto fake = outsider ~ "/.git";
    mkdirRecurse(fake);
    write(ws ~ "/.git", "gitdir: " ~ fake ~ "\n");
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false };
    foreach (r; c.writableRoots(ws)) assert(!within(r, canonicalize(fake)), r);
}

@trusted unittest // a linked worktree's git dirs are granted
{
    import std.file : write, mkdirRecurse;
    import std.process : execute, Config;
    auto base = outsideDir();
    scope (exit) rmTree(base);
    auto main = base ~ "/main", wt = base ~ "/wt";
    mkdirRecurse(main);
    void git(string[] args, string dir)
    {
        auto r = execute(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ~ args,
            null, Config.none, size_t.max, dir);
        assert(r.status == 0, r.output);
    }
    git(["init", "-q", "-b", "main"], main);
    write(main ~ "/seed", "x");
    git(["add", "-A"], main);
    git(["commit", "-qm", "seed", "--no-verify"], main);
    git(["worktree", "add", "-q", wt], main);
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false };
    auto common = canonicalize(main ~ "/.git");
    assert(c.writableRoots(wt).any!(r => within(r, common)), c.writableRoots(wt).join(" "));
}

version (HasOsSandbox) @trusted unittest // the OS sandbox contains what the static guard can't see
{
    import std.file : exists;
    auto ws = outsideDir(), other = outsideDir();
    scope (exit) { rmTree(ws); rmTree(other); }
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false };
    auto target = other ~ "/escape.txt";
    auto script = format("printf pwned > $'%s' 2>/dev/null; echo done", target.replace("/", `\x2f`));
    bool ok; string text;
    if (run(c, ws, script, ok, text))
    {
        assert(text.canFind("done"), text);
        assert(!exists(target), "OS sandbox let an encoded write escape the workspace: " ~ text);
    }
    assert(!c.allowsWrite(target, ws));
}

unittest // a root cwd is never a writable root
{
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false };
    assert(!c.writableRoots("/").canFind("/"));
    assert(!c.allowsWrite("/etc/hosts", "/"));
}

unittest // network = false denies outbound except localhost
{
    SandboxConfig c = { mode: SandboxMode.readOnly, network: false };
    auto p = c.profile(["/tmp"]);
    assert(p.canFind("(deny file-write*)") && p.canFind(`(allow network-outbound (remote ip "localhost:*"))`));
    assert(c.describe("/").canFind("outbound network is blocked"));
}
