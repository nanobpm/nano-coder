/// OS sandbox for shell commands: Seatbelt (`sandbox-exec`) on macOS and
/// Landlock (`nano/landlock.d`) on Linux (port of `sandbox.rs`).
///
/// Commands write only to the working directory (in `workspace` mode), its
/// git directories, temp directories, package-manager caches and any extra
/// `writable` paths. `read-only` mode allows only temp directories.
/// `network = false` blocks outbound connections except to localhost.
///
/// Reads are confined too (issue #333): `read_confine = "secrets"` (the
/// default) hides credentials and home secrets (`defaultDenyRead` plus
/// `deny_read`); `"workspace"` allows reads only of the workspace, system and
/// toolchain directories, caches and `readable` paths. On macOS the Seatbelt
/// profile denies the paths; Landlock is allow-list only, so on Linux the
/// denied paths are left out of the read rules (`landlockReadRoots`).
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

import nano.paths : canonicalize, homeDir, isDir, isSymlink, joinPath, normalize;

version (OSX) version = HasOsSandbox;
version (linux) version = HasOsSandbox;

@safe:
import nano.safeio : jsonText, jsonPretty, utf8Text;

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
SandboxMode parseMode(string s) pure
{
    switch (s)
    {
        case "off", "none": return SandboxMode.off;
        case "workspace", "workspace-write": return SandboxMode.workspace;
        case "read-only", "readonly": return SandboxMode.readOnly;
        default:
            throw new Exception(format("unknown sandbox mode %s (expected off, workspace or read-only)", JSONValue(s).jsonText));
    }
}

/// Where the effective sandbox mode came from, for startup diagnostics and
/// `/settings` (issue #118).
enum SandboxSource { interactiveDefault, headlessDefault, config, env, flag }

/// The source's name as shown to users.
string sourceName(SandboxSource s) pure nothrow
{
    final switch (s)
    {
        case SandboxSource.interactiveDefault: return "default";
        case SandboxSource.headlessDefault: return "default-headless";
        case SandboxSource.config: return "config";
        case SandboxSource.env: return "env NANO_CODER_SANDBOX";
        case SandboxSource.flag: return "flag --sandbox";
    }
}

/// The effective sandbox mode and where it was set.
struct ResolvedMode
{
    /// The mode commands run under.
    SandboxMode mode;
    /// Which setting decided it.
    SandboxSource source;
}

/// Resolve the sandbox mode: `--sandbox` flag > `NANO_CODER_SANDBOX` > the
/// config's `[sandbox] mode` > a default that depends on how nano-coder runs:
/// `workspace` for headless runs (ACP, `-p`, piped stdin), where nobody
/// approves commands, and `off` interactively. An explicit `off` at any level
/// wins. Empty `flag`/`env` mean unset; throws on an unknown mode name.
ResolvedMode resolveMode(string flag, string env, bool configSet, SandboxMode configMode, bool headless) pure
{
    if (flag.length) return ResolvedMode(parseMode(flag), SandboxSource.flag);
    if (env.length) return ResolvedMode(parseMode(env), SandboxSource.env);
    if (configSet) return ResolvedMode(configMode, SandboxSource.config);
    return headless ? ResolvedMode(SandboxMode.workspace, SandboxSource.headlessDefault)
        : ResolvedMode(SandboxMode.off, SandboxSource.interactiveDefault);
}

/// Why the OS sandbox can't be applied on this machine, or null when it can.
/// Checked at startup by headless runs so a sandboxed worker fails loudly
/// instead of failing every command.
string unavailableReason(bool network)
{
    version (OSX)
    {
        import std.file : exists;
        return exists("/usr/bin/sandbox-exec") ? null : "sandbox unavailable: /usr/bin/sandbox-exec not found";
    }
    else version (linux)
    {
        import nano.landlock : check;
        return check(network);
    }
    else
        return "sandbox unavailable on this platform";
}

/// Why a probe of the sandbox launcher failed, or null when it succeeded:
/// a non-zero exit, with the launcher's first output line for the reason.
string probeFailure(int status, string output) pure
{
    import std.string : lineSplitter, strip;
    if (status == 0) return null;
    foreach (line; output.lineSplitter)
        if (line.strip.length) return format("sandbox probe failed (exit %s): %s", status, line.strip);
    return format("sandbox probe failed (exit %s)", status);
}

unittest
{
    assert(probeFailure(0, "anything") is null);
    assert(probeFailure(71, "\nsandbox-exec: sandbox_apply: Operation not permitted\n")
        == "sandbox probe failed (exit 71): sandbox-exec: sandbox_apply: Operation not permitted");
    assert(probeFailure(1, "") == "sandbox probe failed (exit 1)");
}

/// Why `c` can't actually be applied in `cwd`, or null when it can: checks the
/// backend, then runs a harmless command through the real launcher, since an
/// already-sandboxed process has the backend yet can't apply it (#118).
string applyFailure(const SandboxConfig c, string cwd)
{
    if (auto why = unavailableReason(c.network)) return why;
    import std.process : execute, Config;
    // command() only throws when the backend is missing, ruled out above.
    auto r = execute(c.command("/bin/sh", "exit 0", cwd), null, Config.none, 4096, cwd);
    return probeFailure(r.status, r.output);
}

/// Cache directories under `$HOME` that build tools write to.
immutable string[] toolCacheDirs = [
    ".cargo/registry", ".cargo/git", ".cargo/.package-cache", ".cargo/.package-cache-mutate",
    ".cargo/.global-cache", ".rustup/tmp", ".rustup/downloads", ".npm", ".cache", "Library/Caches",
    ".gradle", ".m2/repository", "go/pkg/mod", ".bun/install/cache", ".pnpm-store", "Library/pnpm",
    ".local/share/pnpm", ".yarn/berry/cache", ".deno", ".dub",
];

/// How far the sandbox confines reads (issue #333).
enum ReadConfine
{
    /// Reads anywhere except credentials and secrets (`deniedReads`).
    secrets,
    /// Reads only the workspace, system/toolchain dirs, caches, temp dirs and
    /// `readable` paths; secrets stay denied inside those.
    workspace,
    /// No read confinement (reads everywhere, as before #333).
    off,
}

/// The `read_confine` name of `c`.
string readConfineName(ReadConfine c) pure nothrow
{
    final switch (c)
    {
        case ReadConfine.secrets: return "secrets";
        case ReadConfine.workspace: return "workspace";
        case ReadConfine.off: return "off";
    }
}

/// Parse a `read_confine` value; throws on anything else.
ReadConfine parseReadConfine(string s) pure
{
    switch (s)
    {
        case "secrets": return ReadConfine.secrets;
        case "workspace": return ReadConfine.workspace;
        case "off", "none": return ReadConfine.off;
        default:
            throw new Exception(format("unknown read_confine %s (expected secrets, workspace or off)", JSONValue(s).jsonText));
    }
}

/// Paths under `$HOME` that sandboxed commands and the file tools may never
/// read: credentials, keychains, browser profiles, shell history and
/// nano-coder's own config (API keys, `api_key_command`).
immutable string[] defaultDenyRead = [
    ".ssh", ".gnupg", ".aws", ".azure", ".config/gcloud", ".config/gh", ".config/hub", ".netrc", ".git-credentials",
    ".docker/config.json", ".kube", ".password-store", ".pypirc", ".cargo/credentials", ".cargo/credentials.toml",
    ".local/share/keyrings", "Library/Keychains", "Library/Cookies", "Library/Safari",
    "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox",
    "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge", ".mozilla",
    ".config/google-chrome", ".config/chromium", ".config/BraveSoftware", ".config/microsoft-edge",
    ".config/nano-coder", ".bash_history", ".zsh_history", ".zhistory", ".local/share/fish/fish_history",
    ".python_history", ".node_repl_history", ".psql_history", ".mysql_history", ".sqlite_history", ".lesshst",
];

/// Absolute system paths never readable (root-only on most systems anyway).
immutable string[] systemDenyRead = ["/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/master.passwd"];

/// System and toolchain directories `read_confine = "workspace"` still reads.
immutable string[] systemReadDirs = ["/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt",
    "/nix", "/snap", "/proc", "/sys", "/dev", "/run", "/var", "/private", "/System", "/Library", "/Applications",
    "/Developer", "/Library/Developer", "/tmp"];

/// Toolchain installs and config under `$HOME` that `read_confine =
/// "workspace"` still reads (on top of `toolCacheDirs`).
immutable string[] homeReadDirs = [".cargo", ".rustup", ".local/bin", ".local/lib", ".local/share/mise",
    ".local/share/pnpm", ".config/mise", ".nvm", ".volta", ".bun", ".deno", ".dub", ".m2", ".gradle", ".npm",
    ".npmrc", ".cache", "go", ".sdkman", ".pyenv", ".rbenv", ".ghcup", ".gitconfig", ".config/git",
    ".gitignore_global", "Library/Caches", "Library/pnpm", ".yarnrc", ".yarnrc.yml", ".yarn"];

/// What a sandboxed command may read: the mode, the paths it never reads
/// (absolute; each also in canonical form when that differs) and, in
/// `workspace` mode, the roots it may read.
struct ReadPlan
{
    /// The confinement mode.
    ReadConfine confine = ReadConfine.off;
    /// Paths (and everything below) that are never readable.
    string[] denied;
    /// `workspace` mode: the only readable roots (before removing `denied`).
    string[] readable;
}

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
    /// Whether the config file named a `mode` (so an explicit `off` can be
    /// told apart from no setting at all; issue #118).
    bool modeSet;
    /// How far reads are confined (`read_confine`; issue #333).
    ReadConfine readConfine = ReadConfine.secrets;
    /// Extra paths never readable, on top of `defaultDenyRead` (`deny_read`).
    string[] denyRead;
    /// Extra readable paths in `read_confine = "workspace"` (`readable`).
    string[] readable;

    /// A copy with its own arrays (hooks keep one for the session).
    SandboxConfig dup() const pure
    {
        SandboxConfig c = { mode: mode, writable: writable.dup, network: network, toolCaches: toolCaches,
            modeSet: modeSet, readConfine: readConfine, denyRead: denyRead.dup, readable: readable.dup };
        return c;
    }

    /// From the `[sandbox]` table; throws on a bad mode or type.
    static SandboxConfig fromJSON(JSONValue v) pure
    {
        SandboxConfig c;
        if (v.type != JSONType.object) return c;
        if (auto x = "mode" in v) { c.mode = parseMode(x.str); c.modeSet = true; }
        if (auto x = "writable" in v) foreach (w; x.arrayNoRef) c.writable ~= w.str;
        if (auto x = "network" in v) c.network = x.boolean;
        if (auto x = "tool_caches" in v) c.toolCaches = x.boolean;
        if (auto x = "read_confine" in v) c.readConfine = parseReadConfine(x.str);
        if (auto x = "deny_read" in v) foreach (w; x.arrayNoRef) c.denyRead ~= w.str;
        if (auto x = "readable" in v) foreach (w; x.arrayNoRef) c.readable ~= w.str;
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
            foreach (d; trustedGitDirs(cwd)) add(d);
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

    /// The repository's git dirs that may be granted for `cwd`, canonical.
    /// A poisoned `.git` file can point at an unrelated repository: only git
    /// dirs inside the workspace, whose repo contains it, or that git ties
    /// back to this worktree qualify. Used for both write and read grants.
    static string[] trustedGitDirs(string cwd)
    {
        auto cwdReal = canonicalize(cwd);
        if (cwdReal is null) cwdReal = cwd;
        string[] real_;
        foreach (d; gitDirs(cwd))
            if (auto r = canonicalize(d)) real_ ~= r;
        bool worktreeOfCwd;
        foreach (r; real_) worktreeOfCwd = worktreeOfCwd || worktreeBackpointerWithin(r, cwdReal);
        string[] result;
        foreach (r; real_)
        {
            auto parent = parentOf(r);
            if (within(r, cwdReal) || (parent !is null && within(cwdReal, parent)) || worktreeOfCwd)
                if (!result.canFind(r)) result ~= r;
        }
        return result;
    }

    /// Whether reads are confined at all.
    bool confinesReads() const pure nothrow { return active && readConfine != ReadConfine.off; }

    /// The read plan for commands run in `cwd` (issue #333).
    ReadPlan readPlan(string cwd) const
    {
        ReadPlan p;
        if (!confinesReads) return p;
        p.confine = readConfine;
        auto home = homeDir();
        // `/` is never a readable grant, but it is a valid denial.
        void addTo(ref string[] list, string path, bool keepRoot = false)
        {
            auto n = normalize(path);
            if (n.length && (keepRoot || n != "/") && !list.canFind(n)) list ~= n;
            auto r = canonicalize(path);
            if (r !is null && (keepRoot || r != "/") && !list.canFind(r)) list ~= r;
        }
        string expand(string x)
        {
            if (x.startsWith("~/") && home.length) return joinPath(home, x[2 .. $]);
            return joinPath(cwd, x);
        }
        if (home.length) foreach (d; defaultDenyRead) addTo(p.denied, joinPath(home, d), true);
        foreach (d; systemDenyRead) addTo(p.denied, d, true);
        foreach (d; denyRead) addTo(p.denied, expand(d), true);
        if (readConfine == ReadConfine.workspace)
        {
            foreach (d; systemReadDirs) addTo(p.readable, d);
            if (home.length)
            {
                foreach (d; homeReadDirs) addTo(p.readable, joinPath(home, d));
                foreach (d; toolCacheDirs) addTo(p.readable, joinPath(home, d));
            }
            if (cwd != "/") addTo(p.readable, cwd);
            foreach (d; trustedGitDirs(cwd)) addTo(p.readable, d);
            foreach (r; writableRoots(cwd)) addTo(p.readable, r);
            foreach (x; readable) addTo(p.readable, expand(x));
        }
        return p;
    }

    /// The literal denied paths hiding entries from `grep`/`glob` walks
    /// (the policy's per-entry filter), so a search of `~` skips `~/.ssh`
    /// the way the OS sandbox does. Literal paths, matched with
    /// `withinDenied`: never rule text, which would strip trailing spaces
    /// and read `*`/`[` as globs.
    string[] readDeniedPaths(string cwd) const
    {
        return readPlan(cwd).denied;
    }

    /// Why the sandbox would not let a command read `path`, or null (for the
    /// file tools, which run in-process). Checks the path as given and with
    /// symlinks resolved, so a link can't reach a denied target.
    string readRefusal(string path, string cwd) const
    {
        if (!confinesReads) return null;
        auto full = normalize(path.startsWith("/") ? path : joinPath(cwd, path));
        auto resolved = resolveDeepest(full);
        auto plan = readPlan(cwd);
        foreach (p; [full, resolved])
        {
            if (p is null) continue;
            foreach (d; plan.denied)
                if (withinDenied(p, d))
                    return format("%s is outside what the %s sandbox may read: credentials and secrets (%s) are "
                        ~ "never readable", path, mode.modeName, d);
            if (plan.confine == ReadConfine.workspace && !plan.readable.any!(r => within(p, r)))
                return format("%s is outside what the %s sandbox may read: only the workspace, system and toolchain "
                    ~ "directories, caches and `readable` paths are", path, mode.modeName);
        }
        return null;
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
        string reads;
        final switch (readConfine)
        {
            case ReadConfine.secrets: reads = "; they cannot read credentials or secrets (~/.ssh, ~/.aws, ~/.config/gh, ...)"; break;
            case ReadConfine.workspace: reads = "; they can read only the workspace, system and toolchain directories, caches and `readable` paths"; break;
            case ReadConfine.off: break;
        }
        return format("commands run in a %s sandbox: they can write only to %s%s%s%s", mode.modeName, shown.join(", "),
            more > 0 ? format(" and %s cache directories", more) : "",
            network ? "" : "; outbound network is blocked", reads);
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
            return [sandboxExec, "-p", profile(writableRoots(cwd), readPlan(cwd)), shell, "-c", script];
        }
        else version (linux)
        {
            import nano.landlock : check, argv;
            if (auto e = check(network)) throw new Exception(e);
            auto plan = readPlan(cwd);
            auto reads = plan.confine == ReadConfine.off ? null
                : landlockReadRoots(plan, (string d) => listDir(d), (string d) => isDir(d), writableRoots(cwd),
                    (string d) => canonicalize(d));
            // A write root holding a denied path is split too, so the denied
            // path can't be renamed or linked out from under the read rules.
            auto writes = plan.confine == ReadConfine.off ? writableRoots(cwd)
                : landlockWriteRoots(writableRoots(cwd), plan.denied, (string d) => listDir(d),
                    (string d) => isDir(d), (string d) => isSymlink(d));
            return argv(network, writes, plan.confine != ReadConfine.off, reads, shell, script);
        }
        else
            throw new Exception("sandbox unavailable on this platform");
    }

    /// The Seatbelt profile for writable `roots` and read `plan`.
    string profile(const string[] roots, const ReadPlan plan = ReadPlan.init) const
    {
        string allowed;
        foreach (root; roots)
            allowed ~= format(" (%s %s)", isDir(root) ? "subpath" : "literal", quote(root));
        // Roots are listed literally (including /dev/tty); no broad ^/dev/tty
        // regex, which would also grant serial/USB nodes.
        auto p = "(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*" ~ allowed ~ ")\n";
        if (!network)
            p ~= "(deny network-outbound (remote ip))\n(allow network-outbound (remote ip \"localhost:*\"))\n";
        return p ~ seatbeltReadRules(plan);
    }
}

/// The Seatbelt rules confining reads to `plan` (appended after the write
/// rules; later rules win). `workspace` mode denies every read, re-allows
/// `/` itself and the readable roots (and metadata
/// of their ancestors, for `getcwd`/`realpath`); every mode then denies the
/// secret paths. `subpath` covers a path itself, so files work too. Writes
/// to the denied paths and their ancestors' entries are denied as well, so a
/// command can't rename or link a secret out from under the read deny.
string seatbeltReadRules(const ReadPlan plan) pure
{
    import std.array : appender;
    auto o = appender!string;
    final switch (plan.confine)
    {
        case ReadConfine.off: return null;
        case ReadConfine.secrets: break;
        case ReadConfine.workspace:
            // Deny every read, then re-allow the planned roots: the profile
            // starts from (allow default), so a narrower deny would leave other
            // roots (e.g. a mount at /mnt) readable outside the allow-list.
            o ~= "(deny file-read* (subpath \"/\"))\n(allow file-read* (literal \"/\"))\n";
            string[] ancestors;
            foreach (r; plan.readable)
                for (auto a = parentOf(r); a !is null && a != "/"; a = parentOf(a))
                    if (!ancestors.canFind(a)) ancestors ~= a;
            if (ancestors.length)
            {
                o ~= "(allow file-read-metadata";
                foreach (a; ancestors) o ~= " (literal " ~ quote(a) ~ ")";
                o ~= ")
";
            }
            if (plan.readable.length)
            {
                o ~= "(allow file-read*";
                foreach (r; plan.readable) o ~= " (subpath " ~ quote(r) ~ ")";
                o ~= ")
";
            }
            break;
    }
    if (plan.denied.length)
    {
        o ~= "(deny file-read*";
        foreach (d; plan.denied) o ~= " (subpath " ~ quote(d) ~ ")";
        o ~= ")
";
        // A read deny is path-based: renaming or hard-linking a denied path
        // (or a directory above it) to another name would move the secret out
        // from under it. Deny writes to the denied paths themselves and to
        // their ancestors' own entries (`literal`: files can still be created
        // in those directories), so rename, unlink and link are refused.
        o ~= "(deny file-write*";
        foreach (d; plan.denied) o ~= " (subpath " ~ quote(d) ~ ")";
        string[] above;
        foreach (d; plan.denied)
            for (auto a = parentOf(d); a !is null && a != "/"; a = parentOf(a))
                if (!above.canFind(a)) above ~= a;
        foreach (a; above) o ~= " (literal " ~ quote(a) ~ ")";
        o ~= ")
";
    }
    return o.data;
}

/// The Landlock read roots for `plan`. Landlock only allows, so a denied path
/// is removed by splitting each readable root that contains one into its
/// children (from `list`) until no granted root contains a denied path; the
/// denied paths and their ancestors are then simply not granted. `secrets`
/// mode starts from `/`, `workspace` mode from `plan.readable` plus the
/// writable `roots` (which get no read rights of their own, so a write root
/// containing a denied path, e.g. cwd = $HOME, is split the same way).
string[] landlockReadRoots(const ReadPlan plan, scope string[] delegate(string) @safe list,
    scope bool delegate(string) @safe isDirectory, const string[] roots = null,
    scope string delegate(string) @safe resolve = null)
{
    string[] result;
    bool[string] expanded; // directories already split: symlink cycles stop here
    void grant(string root, size_t depth)
    {
        // The helper opens each rule's path following symlinks, so judge (and
        // grant) the resolved target: `alias -> private` must not grant `private`.
        if (resolve !is null)
        {
            auto real_ = resolve(root);
            // An unresolvable root (a dangling link `stale -> missing`, a
            // loop) can't be opened by the helper: granting it would fail
            // every sandboxed command, so it gets no rule (it holds nothing).
            if (real_ is null) return;
            // A symlink found while splitting (`/work/escape -> ~/other`)
            // was never approved: in workspace mode its target must lie in
            // an approved root. Approved roots (depth 0) keep their targets.
            if (depth > 0 && real_ != root && plan.confine == ReadConfine.workspace
                && !plan.readable.any!(r => within(real_, r)) && !roots.any!(r => within(real_, r)))
                return;
            root = real_;
        }
        if (plan.denied.any!(d => within(root, d))) return;
        if (!plan.denied.any!(d => within(d, root) && d != root))
        {
            if (!result.canFind(root)) result ~= root;
            return;
        }
        // A denied path lies strictly below: grant the children instead.
        if (depth > 64 || root in expanded || !isDirectory(root)) return;
        expanded[root] = true;
        foreach (child; list(root)) grant(joinPath(root, child), depth + 1);
    }
    final switch (plan.confine)
    {
        case ReadConfine.off: return null;
        case ReadConfine.secrets: grant("/", 0); break;
        case ReadConfine.workspace:
            foreach (r; plan.readable) grant(r, 0);
            foreach (r; roots) grant(r, 0);
            break;
    }
    return result;
}

/// Marks a Landlock write root that holds a denied path: it keeps its create
/// and write rights but not REMOVE_*/REFER, so nothing in it (the denied
/// path or a directory above it) can be renamed, unlinked or linked away.
enum guardedRoot = "!";

/// The Landlock write roots for `roots`, split around `denied` (issue #333).
/// Read denial is path-based, so a writable root holding a denied path would
/// let a command `mv private pub` and read `pub/key`. Such a root (and every
/// directory between it and the denied path) is granted guarded
/// (`guardedRoot` prefix, see `nano.landlock.ruleSet`); its other children
/// keep full rights. The denied path itself gets no rule. Symlinks met while
/// splitting are skipped: a rule follows links, so `ws/l -> /etc` would grant
/// `/etc`. Fails closed: an unlistable directory grants none of its children.
string[] landlockWriteRoots(const string[] roots, const string[] denied, scope string[] delegate(string) @safe list,
    scope bool delegate(string) @safe isDirectory, scope bool delegate(string) @safe isLink)
{
    string[] result;
    void add(string r) { if (!result.canFind(r)) result ~= r; }
    void split(string root, size_t depth)
    {
        if (denied.any!(d => withinDenied(root, d))) return;
        if (!denied.any!(d => withinDenied(d, root) && d != root)) { add(root); return; }
        add(guardedRoot ~ root);
        if (depth > 64 || !isDirectory(root)) return;
        foreach (child; list(root))
        {
            auto c = joinPath(root, child);
            if (!isLink(c)) split(c, depth + 1);
        }
    }
    foreach (r; roots) split(r, 0);
    return result;
}

/// Entry names of directory `d` (none when it can't be listed).
string[] listDir(string d)
{
    import std.file : dirEntries, SpanMode;
    import std.exception : collectException;
    string[] names;
    // Unlistable: none of its children are granted, which fails closed.
    collectException({
        foreach (e; dirEntries(d, SpanMode.shallow, false))
            if (auto b = baseOf(e.name)) names ~= b;
    }());
    return names;
}

/// Whether `output` of a failed sandboxed command looks like a sandbox denial.
bool looksDenied(scope const(char)[] output) pure nothrow @nogc
{
    static immutable phrases = ["Operation not permitted", "Read-only file system", "Permission denied"];
    foreach (d; phrases)
        if (output.canFind(d)) return true;
    return false;
}

private:

string quote(string path) pure nothrow
{
    return `"` ~ path.replace(`\`, `\\`).replace(`"`, `\"`) ~ `"`;
}

/// `path` equals `root` or lies below it (component-wise).
bool within(string path, string root) pure nothrow
{
    if (root == "/") return path.startsWith("/");
    return path == root || (path.startsWith(root) && path.length > root.length && path[root.length] == '/');
}

/// `within` for denials: on macOS the default filesystem is case-insensitive,
/// so `~/.SSH` names `~/.ssh`; compare case-insensitively there (fails closed).
public bool withinDenied(string path, string root) pure
{
    version (OSX)
    {
        import std.uni : toLower;
        return within(path.toLower, root.toLower);
    }
    else return within(path, root);
}

unittest // denial matching on macOS ignores case (issue #333 review)
{
    version (OSX) assert(withinDenied("/Users/a/.SSH/id", "/Users/a/.ssh"));
    else assert(!withinDenied("/home/a/.SSH/id", "/home/a/.ssh"));
    assert(withinDenied("/etc/x", "/"));
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

/// Absolute `full` with every symlink resolved, dangling ones included (a
/// link to a missing `~/.aws` still names `~/.aws`); at most 40 hops.
string resolveDeepest(string full)
{
    import nano.paths : components, readLink;
    string[] todo;
    foreach_reverse (c; components(full)) if (c != "/") todo ~= c;
    string cur = "/";
    size_t hops;
    while (todo.length)
    {
        auto name = todo[$ - 1];
        todo = todo[0 .. $ - 1];
        if (name == ".") continue;
        if (name == "..") { auto par = parentOf(cur); cur = par is null ? "/" : par; continue; }
        auto next = joinPath(cur, name);
        auto target = readLink(next);
        if (target !is null && ++hops <= 40)
        {
            foreach_reverse (c; components(target)) if (c != "/") todo ~= c;
            if (target.startsWith("/")) cur = "/";
            continue;
        }
        cur = next;
    }
    return cur;
}

void ensureDir(string path)
{
    import std.file : exists, mkdirRecurse;
    try if (!exists(path)) mkdirRecurse(path);
    catch (Exception) {} // the sandbox profile still lists the path; a missing dir just can't be written
}

string tempDirectory()
{
    import std.process : environment;
    auto t = environment.get("TMPDIR");
    return t.length ? t : "/tmp";
}

/// The repository's git directory and, for a worktree, the shared one.
string[] gitDirs(string cwd) nothrow
{
    import nano.safeio : readToEnd;
    import std.process : pipeProcess, wait, Redirect, Config;
    import std.array : appender;
    try
    {
        auto p = pipeProcess(["git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
            Redirect.stdout | Redirect.stderr, null, Config.none, cwd);
        auto raw = readToEnd(p.stdout);
        if (wait(p.pid) != 0) return null;
        // Strict decoding: a lossy one would rewrite a non-UTF-8 path into a
        // different directory and grant it write access. Throws into the catch.
        auto output = utf8Text(raw);
        string[] dirs;
        foreach (l; output.idup.splitLines)
            if (l.strip.length) dirs ~= joinPath(cwd, l.strip);
        return dirs;
    }
    catch (Exception) return null; // git missing or not a repository: no extra writable dirs
}

/// Whether `gitDir` is the per-worktree git directory of the worktree rooted
/// at `cwdReal` (its `gitdir` back-pointer resolves into it).
bool worktreeBackpointerWithin(string gitDir, string cwdReal) nothrow
{
    import std.file : readText;
    try
    {
        auto parent = parentOf(readText(joinPath(gitDir, "gitdir")).strip);
        return parent !is null && canonicalize(parent) == cwdReal;
    }
    catch (Exception) return false; // an unreadable gitdir file: not a linked worktree of this repo
}

version (unittest)
{
    /// A fresh directory outside the temp roots (which are always writable).
    string outsideDir()
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
    bool run(const SandboxConfig c, string cwd, string script, out bool ok, out string text)
    {
        import std.process : execute, Config, environment;
        auto r = execute(c.command("bash", script, cwd), null, Config.none, size_t.max, cwd);
        text = r.output;
        ok = r.status == 0;
        if (text.canFind("sandbox_apply: Operation not permitted"))
        {
            import nano.safeio : stdErr;
            if (environment.get("NANO_SKIP_UNAVAILABLE_SANDBOX_TESTS") is null)
                assert(false, "OS sandbox cannot be applied inside an already-sandboxed process; containment assertions could not run");
            stdErr.writeln("SKIP sandbox test: OS sandbox unavailable");
            return false;
        }
        return true;
    }

    void rmTree(string d)
    {
        import std.file : rmdirRecurse, exists;
        if (exists(d)) rmdirRecurse(d);
    }
}

// rust: sandbox.rs::parses_modes
unittest
{
    assert(parseMode("workspace") == SandboxMode.workspace);
    assert(parseMode("read-only") == SandboxMode.readOnly);
    bool threw;
    try parseMode("nope"); catch (Exception) threw = true; // expected: an unknown mode must throw, which is what this test checks
    assert(threw);
    import nano.toml : parseToml;
    import nano.result : unwrap;
    auto c = SandboxConfig.fromJSON(parseToml("mode = \"read-only\"\nnetwork = false").unwrap("valid TOML"));
    assert(c.mode == SandboxMode.readOnly && !c.network && c.toolCaches);
}

// issue #118: precedence flag > env > config > mode-dependent default
unittest
{
    alias W = SandboxMode.workspace, O = SandboxMode.off, R = SandboxMode.readOnly;
    alias S = SandboxSource;
    // Nothing set: headless defaults to workspace, interactive stays off.
    assert(resolveMode("", "", false, O, true) == ResolvedMode(W, S.headlessDefault));
    assert(resolveMode("", "", false, O, false) == ResolvedMode(O, S.interactiveDefault));
    // Explicit off at each level is respected in headless mode.
    assert(resolveMode("off", "", false, O, true) == ResolvedMode(O, S.flag));
    assert(resolveMode("", "off", false, O, true) == ResolvedMode(O, S.env));
    assert(resolveMode("", "", true, O, true) == ResolvedMode(O, S.config));
    // Higher levels win over lower ones.
    assert(resolveMode("off", "read-only", true, W, true) == ResolvedMode(O, S.flag));
    assert(resolveMode("read-only", "off", true, O, false) == ResolvedMode(R, S.flag));
    assert(resolveMode("", "off", true, R, true) == ResolvedMode(O, S.env));
    assert(resolveMode("", "workspace", true, O, false) == ResolvedMode(W, S.env));
    assert(resolveMode("", "", true, R, false) == ResolvedMode(R, S.config));
    import std.exception : assertThrown;
    assertThrown(resolveMode("bogus", "", false, O, true));
    // The config file distinguishes an explicit off from no setting.
    import nano.toml : parseToml;
    import nano.result : unwrap;
    auto off = SandboxConfig.fromJSON(parseToml("mode = \"off\"").unwrap("valid TOML"));
    assert(off.modeSet && off.mode == O);
    assert(resolveMode("", "", off.modeSet, off.mode, true) == ResolvedMode(O, S.config));
    auto none = SandboxConfig.fromJSON(parseToml("network = true").unwrap("valid TOML"));
    assert(!none.modeSet);
    assert(resolveMode("", "", none.modeSet, none.mode, true).mode == W);
}

// issue #118: a headless run with no sandbox configuration confines shell writes
version (HasOsSandbox) unittest
{
    import std.file : exists;
    auto ws = outsideDir(), other = outsideDir();
    scope (exit) { rmTree(ws); rmTree(other); }
    SandboxConfig c;
    c.mode = resolveMode("", "", c.modeSet, c.mode, true).mode;
    c.toolCaches = false;
    assert(c.active);
    auto target = other ~ "/escape.txt";
    bool ok; string text;
    if (run(c, ws, format(`echo x > %s 2>/dev/null; echo done`, target), ok, text))
    {
        assert(text.canFind("done"), text);
        assert(!exists(target), "headless default sandbox let a write escape the workspace: " ~ text);
    }
}

// rust: sandbox.rs::workspace_mode_confines_writes
version (HasOsSandbox) unittest // workspace mode confines writes
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

// rust: sandbox.rs::read_only_mode_blocks_workspace_writes
version (HasOsSandbox) unittest // read-only mode blocks workspace writes
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

// rust: sandbox.rs::os_sandbox_contains_static_guard_bypasses
version (HasOsSandbox) unittest // an encoded write the static guard can't see is still contained
{
    import std.file : exists;
    import std.array : replace;
    auto ws = outsideDir(), other = outsideDir();
    scope (exit) { rmTree(ws); rmTree(other); }
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false };
    auto target = other ~ "/escape.txt";
    auto script = format(`printf pwned > $'%s' 2>/dev/null; echo done`, target.replace("/", `\x2f`));
    bool ok; string text;
    if (run(c, ws, script, ok, text))
    {
        assert(text.canFind("done"), text);
        assert(!exists(target), "OS sandbox let an encoded write escape the workspace: " ~ text);
    }
    assert(!c.allowsWrite(target, ws));
}

// rust: sandbox.rs::extra_writable_paths
version (HasOsSandbox) unittest // extra writable paths
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

// rust: sandbox.rs::read_only_mode_does_not_grant_device_directories
unittest // device directories only in workspace mode, never /dev/shm or /dev/pts
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

// rust: sandbox.rs::external_git_dir_is_not_granted
unittest // a poisoned .git pointer to an external repo isn't granted
{
    import std.file : write, mkdirRecurse;
    auto ws = outsideDir(), outsider = outsideDir();
    scope (exit) { rmTree(ws); rmTree(outsider); }
    auto fake = outsider ~ "/.git";
    mkdirRecurse(fake);
    write(ws ~ "/.git", "gitdir: " ~ fake ~ "\n");
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false };
    foreach (r; c.writableRoots(ws)) assert(!within(r, canonicalize(fake)), r);
    // Nor made readable in workspace read mode, in either sandbox mode (#333).
    foreach (m; [SandboxMode.workspace, SandboxMode.readOnly])
    {
        SandboxConfig rc = { mode: m, toolCaches: false, readConfine: ReadConfine.workspace };
        foreach (r; rc.readPlan(ws).readable) assert(!within(r, canonicalize(fake)), r);
    }
}

// rust: sandbox.rs::linked_worktree_git_dirs_are_granted
unittest // a linked worktree's git dirs are granted
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

version (HasOsSandbox) unittest // the OS sandbox contains what the static guard can't see
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

// rust: sandbox.rs::root_cwd_is_not_a_writable_root
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

// issue #333: read_confine, deny_read and readable parse; secrets is the default
unittest
{
    import nano.toml : parseToml;
    import nano.result : unwrap;
    import std.exception : assertThrown;
    SandboxConfig d;
    assert(d.readConfine == ReadConfine.secrets);
    auto c = SandboxConfig.fromJSON(parseToml("mode = \"workspace\"\nread_confine = \"workspace\"\n"
        ~ "deny_read = [\"~/secret\"]\nreadable = [\"~/src/lib\"]").unwrap("valid TOML"));
    assert(c.readConfine == ReadConfine.workspace && c.denyRead == ["~/secret"] && c.readable == ["~/src/lib"]);
    assert(c.dup.readable == ["~/src/lib"] && c.dup.readConfine == ReadConfine.workspace);
    assertThrown(parseReadConfine("everything"));
    assert(parseReadConfine("off") == ReadConfine.off);
    SandboxConfig off = { mode: SandboxMode.off };
    assert(off.readPlan("/w").confine == ReadConfine.off, "no sandbox: reads are not confined");
}

// issue #333: the read plan denies home secrets and nano-coder's own config
unittest
{
    auto ws = outsideDir();
    scope (exit) rmTree(ws);
    auto home = homeDir();
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false, denyRead: ["private"] };
    auto plan = c.readPlan(ws);
    assert(plan.confine == ReadConfine.secrets && !plan.readable.length);
    foreach (d; [".ssh", ".aws", ".config/gh", ".netrc", ".config/nano-coder", "Library/Keychains", ".bash_history"])
        assert(plan.denied.canFind(normalize(joinPath(home, d))), d);
    assert(plan.denied.canFind(ws ~ "/private"), "a relative deny_read names a workspace path");
    assert(c.readRefusal(joinPath(home, ".ssh/id_ed25519"), ws).canFind("outside what the workspace sandbox may read"));
    assert(c.readRefusal("~/.ssh".replace("~", home), ws) !is null);
    assert(c.readRefusal(ws ~ "/private/x", ws) !is null);
    assert(c.readRefusal(ws ~ "/src.d", ws) is null);
    assert(c.readRefusal("/usr/bin/env", ws) is null);
    auto denied = c.readDeniedPaths(ws);
    assert(denied.canFind(normalize(joinPath(home, ".ssh"))), denied.join(" "));
    SandboxConfig w = { mode: SandboxMode.workspace, toolCaches: false, readConfine: ReadConfine.workspace };
    assert(w.readRefusal(ws ~ "/a/b.txt", ws) is null);
    assert(w.readRefusal("/usr/lib", ws) is null);
    assert(w.readRefusal(joinPath(home, "Documents/x"), ws).canFind("only the workspace"));
    assert(w.readRefusal(joinPath(home, ".cargo/bin/cargo"), ws) is null, "toolchains stay readable");
    assert(w.readRefusal(joinPath(home, ".ssh/config"), ws) !is null);
    // A symlink inside the workspace can't reach a denied target.
    import std.file : symlink, mkdirRecurse;
    mkdirRecurse(ws ~ "/private");
    symlink(ws ~ "/private", ws ~ "/link");
    assert(c.readRefusal(ws ~ "/link/key", ws) !is null);
}

// issue #333: the generated Seatbelt read rules
unittest
{
    ReadPlan secrets = { confine: ReadConfine.secrets, denied: ["/h/.ssh", "/h/.netrc"] };
    assert(seatbeltReadRules(secrets) == "(deny file-read* (subpath \"/h/.ssh\") (subpath \"/h/.netrc\"))\n"
        ~ "(deny file-write* (subpath \"/h/.ssh\") (subpath \"/h/.netrc\") (literal \"/h\"))\n", seatbeltReadRules(secrets));
    assert(seatbeltReadRules(ReadPlan.init) is null);
    ReadPlan ws = { confine: ReadConfine.workspace, denied: ["/Users/u/.ssh"], readable: ["/usr", "/Users/u/src/p"] };
    auto r = seatbeltReadRules(ws);
    // Every read is denied, not only under /Users: a mount elsewhere (/mnt)
    // stays unreadable unless planned. The secret denial comes last so it wins.
    assert(r == "(deny file-read* (subpath \"/\"))\n(allow file-read* (literal \"/\"))\n"
        ~ "(allow file-read-metadata (literal \"/Users/u/src\") (literal \"/Users/u\") (literal \"/Users\"))\n"
        ~ "(allow file-read* (subpath \"/usr\") (subpath \"/Users/u/src/p\"))\n"
        ~ "(deny file-read* (subpath \"/Users/u/.ssh\"))\n"
        ~ "(deny file-write* (subpath \"/Users/u/.ssh\") (literal \"/Users/u\") (literal \"/Users\"))\n", r);
    // Both the lexical and the canonical form of a denied path are guarded
    // against rename/link (the plan lists both).
    ReadPlan both = { confine: ReadConfine.secrets, denied: ["/tmp/w/private", "/private/tmp/w/private"] };
    auto b = seatbeltReadRules(both);
    assert(b.canFind(`(deny file-write* (subpath "/tmp/w/private") (subpath "/private/tmp/w/private")`), b);
    assert(b.canFind(`(literal "/tmp/w")`) && b.canFind(`(literal "/private/tmp/w")`), b);
    // The full profile appends the read rules after the write rules.
    SandboxConfig c = { mode: SandboxMode.workspace };
    auto p = c.profile(["/w"], secrets);
    assert(p.canFind("(allow file-write* (literal \"/w\"))\n(deny file-read*"), p);
    // Paths are quoted.
    ReadPlan q = { confine: ReadConfine.secrets, denied: [`/h/a "b"`] };
    assert(seatbeltReadRules(q).canFind(`(subpath "/h/a \"b\"")`));
    // A root denial is emitted, not dropped.
    ReadPlan rootDeny = { confine: ReadConfine.secrets, denied: ["/"] };
    assert(seatbeltReadRules(rootDeny).canFind(`(deny file-read* (subpath "/"))`));
}

// issue #333: Landlock read roots leave denied paths (and their ancestors) out
unittest
{
    string[][string] tree = [
        "/": ["usr", "etc", "home", "tmp"],
        "/home": ["u", "v"],
        "/home/u": [".ssh", ".config", "src", ".netrc"],
        "/home/u/.config": ["gh", "git"],
        "/etc": ["hosts", "shadow"],
    ];
    string[] list(string d) { return d in tree ? tree[d] : null; }
    bool dir(string d) { return (d in tree) !is null || d == "/home/u/src" || d == "/usr"; }
    ReadPlan s = { confine: ReadConfine.secrets,
        denied: ["/home/u/.ssh", "/home/u/.netrc", "/home/u/.config/gh", "/etc/shadow"] };
    auto roots = landlockReadRoots(s, &list, &dir);
    assert(roots == ["/usr", "/etc/hosts", "/home/u/.config/git", "/home/u/src", "/home/v", "/tmp"], roots.join(" "));
    foreach (r; roots)
        foreach (d; s.denied) assert(!within(d, r) && !within(r, d), r ~ " exposes " ~ d);
    ReadPlan w = { confine: ReadConfine.workspace, denied: ["/home/u/.ssh"], readable: ["/usr", "/home/u/src", "/home/u"] };
    assert(landlockReadRoots(w, &list, &dir) == ["/usr", "/home/u/src", "/home/u/.config", "/home/u/.netrc"]);
    assert(landlockReadRoots(ReadPlan.init, &list, &dir) is null);
    // A writable root containing a denied path (cwd = $HOME, writable ~/.config)
    // is split too, in both modes, so writing there doesn't re-expose secrets.
    ReadPlan w2 = { confine: ReadConfine.workspace, denied: ["/home/u/.ssh", "/home/u/.config/gh"], readable: ["/usr"] };
    auto wr = landlockReadRoots(w2, &list, &dir, ["/home/u", "/home/u/.config"]);
    assert(wr == ["/usr", "/home/u/.config/git", "/home/u/src", "/home/u/.netrc"], wr.join(" "));
    foreach (r; wr)
        foreach (d; w2.denied) assert(!within(d, r) && !within(r, d), r ~ " exposes " ~ d);
    ReadPlan s2 = { confine: ReadConfine.secrets, denied: ["/home/u/.ssh"] };
    foreach (r; landlockReadRoots(s2, &list, &dir, ["/home/u"])) assert(!within("/home/u/.ssh", r), r);
    // A symlink to a denied path (or to a directory holding one) is judged by
    // its target: `alias -> .ssh` is not granted, `cfg -> .config` is split.
    string res(string p)
    {
        if (p == "/home/u/src/alias") return "/home/u/.ssh";
        if (p == "/home/u/src/cfg") return "/home/u/.config";
        return p;
    }
    tree["/home/u/src"] = ["alias", "cfg", "main.d"];
    ReadPlan w3 = { confine: ReadConfine.workspace, denied: ["/home/u/.ssh", "/home/u/.config/gh"],
        readable: ["/home/u/src/alias", "/home/u/src/cfg", "/home/u/src/main.d"] };
    auto sr = landlockReadRoots(w3, &list, &dir, null, &res);
    assert(sr == ["/home/u/.config/git", "/home/u/src/main.d"], sr.join(" "));
    ReadPlan s3 = { confine: ReadConfine.secrets, denied: ["/home/u/.ssh"] };
    foreach (r; landlockReadRoots(s3, &list, &dir, null, &res)) assert(!within(r, "/home/u/.ssh"), r);
    // A symlink discovered while splitting can't reach an unapproved root;
    // one inside an approved root (or a split of `secrets` mode) still works.
    string res2(string p)
    {
        if (p == "/work/escape") return "/home/u/other";
        if (p == "/work/inside") return "/work/lib";
        if (p == "/approved") return "/home/u/other2";
        return p;
    }
    tree["/work"] = ["escape", "inside", "lib", "private"];
    ReadPlan w4 = { confine: ReadConfine.workspace, denied: ["/work/private"], readable: ["/work", "/approved"] };
    auto er = landlockReadRoots(w4, &list, &dir, null, &res2);
    assert(er == ["/work/lib", "/home/u/other2"], er.join(" "));
    ReadPlan s4 = { confine: ReadConfine.secrets, denied: ["/work/private"] };
    tree["/"] = ["work"];
    assert(landlockReadRoots(s4, &list, &dir, null, &res2).canFind("/home/u/other"));
    // A dangling link found while splitting (`resolve` fails) gets no rule,
    // in both modes, so it can't make the helper reject the whole rule set.
    string resDangling(string p) => p == "/work/stale" ? null : p;
    tree["/work"] = ["stale", "lib", "private"];
    foreach (m; [w4, s4])
        assert(!landlockReadRoots(m, &list, &dir, null, &resDangling).canFind("/work/stale"));
    assert(landlockReadRoots(w4, &list, &dir, null, &resDangling).canFind("/work/lib"));
    // Cyclic links (`a -> .`, `b -> .`) split each directory once, not 2^64 times.
    size_t listed;
    string[] countList(string d) { ++listed; return list(d); }
    string res3(string p) { return p == "/cyc/a" || p == "/cyc/b" ? "/cyc" : p; }
    tree["/cyc"] = ["a", "b", "private", "ok"];
    ReadPlan w5 = { confine: ReadConfine.workspace, denied: ["/cyc/private"], readable: ["/cyc"] };
    assert(landlockReadRoots(w5, &countList, &dir, null, &res3) == ["/cyc/ok"]);
    import std.conv : to;
    assert(listed == 1, listed.to!string);
    // Denying `/` grants nothing.
    ReadPlan s5 = { confine: ReadConfine.secrets, denied: ["/"] };
    assert(landlockReadRoots(s5, &list, &dir).length == 0);
}

// issue #333: sandboxed commands can't read denied paths; normal work still runs
version (HasOsSandbox) unittest
{
    import std.file : write, mkdirRecurse;
    auto ws = outsideDir(), secret = outsideDir();
    scope (exit) { rmTree(ws); rmTree(secret); }
    write(secret ~ "/id_key", "PRIVATE");
    write(ws ~ "/a.txt", "workspace-data");
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false, denyRead: [secret] };
    bool ok; string text;
    if (run(c, ws, format(`cat "%s/id_key"; ls "%s"; cat a.txt; ls /usr/bin >/dev/null && echo listed; true`, secret,
        secret), ok, text))
    {
        assert(!text.canFind("PRIVATE"), "a sandboxed command read a denied file: " ~ text);
        assert(looksDenied(text), text);
        assert(text.canFind("workspace-data") && text.canFind("listed"), text);
    }
    // The real home secrets are denied by default.
    auto gh = joinPath(homeDir(), ".config/gh");
    if (isDir(gh) && run(c, ws, format(`ls "%s" && echo LISTED`, gh), ok, text))
        assert(!text.canFind("LISTED"), "ls ~/.config/gh succeeded under the sandbox: " ~ text);
    // Workspace confinement: only the workspace (and toolchains) are readable.
    auto other = outsideDir();
    scope (exit) rmTree(other);
    write(other ~ "/sibling.txt", "SIBLING");
    SandboxConfig w = { mode: SandboxMode.workspace, toolCaches: false, readConfine: ReadConfine.workspace };
    if (run(w, ws, format(`cat a.txt; cat "%s/sibling.txt"; /bin/sh -c 'echo shell-ok'; true`, other), ok, text))
    {
        assert(text.canFind("workspace-data") && text.canFind("shell-ok"), text);
        assert(!text.canFind("SIBLING"), "read_confine = workspace let a command read a sibling directory: " ~ text);
    }
}

// issue #333 review: a write root holding a denied path is split so the denied
// path (or a directory above it) can't be renamed or linked out of the deny
unittest
{
    string[][string] tree = [
        "/w": ["a.txt", ".sbt", "src", "lnk"],
        "/w/.sbt": ["private", "other"],
    ];
    string[] list(string d) { return d in tree ? tree[d] : null; }
    bool dir(string d) { return (d in tree) !is null || d == "/w/src" || d == "/w/.sbt/private"; }
    bool link(string d) { return d == "/w/lnk"; }
    auto r = landlockWriteRoots(["/w", "/tmp"], ["/w/.sbt/private"], &list, &dir, &link);
    assert(r == ["!/w", "/w/a.txt", "!/w/.sbt", "/w/.sbt/other", "/w/src", "/tmp"], r.join(" "));
    // No root covering the denied path keeps REMOVE/REFER; the denied path gets no rule.
    foreach (x; r)
        if (!x.startsWith(guardedRoot)) assert(!within("/w/.sbt/private", x), x);
    // A symlink met while splitting is never granted (a rule would follow it).
    assert(!r.canFind("/w/lnk"));
    // A root without a denied path is untouched; a root inside one gets nothing.
    assert(landlockWriteRoots(["/w/src"], ["/w/.sbt/private"], &list, &dir, &link) == ["/w/src"]);
    assert(landlockWriteRoots(["/w/.sbt/private"], ["/w/.sbt/private"], &list, &dir, &link).length == 0);
}

// issue #333 review: a denied path inside the workspace can't be renamed,
// hard-linked or have a parent renamed out of the deny and then read
version (HasOsSandbox) unittest
{
    import std.file : write, mkdirRecurse, exists;
    auto ws = outsideDir();
    scope (exit) rmTree(ws);
    mkdirRecurse(ws ~ "/.sbt/private");
    write(ws ~ "/.sbt/private/key", "PRIVATE");
    write(ws ~ "/plain.txt", "x");
    SandboxConfig c = { mode: SandboxMode.workspace, toolCaches: false, denyRead: [".sbt/private"] };
    bool ok; string text;
    if (run(c, ws, `mv .sbt/private .sbt/pub; cat .sbt/pub/key; ln .sbt/private/key hl; cat hl;
        mv .sbt/private/key k2; cat k2; mv .sbt moved; cat moved/private/key; cat .sbt/private/key;
        echo new > fresh.txt && echo created; echo edit >> plain.txt && echo edited; true`, ok, text))
    {
        assert(!text.canFind("PRIVATE"), "a denied path was moved or linked out of the deny: " ~ text);
        assert(exists(ws ~ "/.sbt/private/key"), text);
        assert(text.canFind("created") && text.canFind("edited"), "ordinary workspace writes stopped working: " ~ text);
    }
}
