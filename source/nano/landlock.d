/// Landlock backend of the OS sandbox on Linux (port of the Linux half of
/// `sandbox.rs`).
///
/// Rust builds the ruleset in the parent and applies it in a `pre_exec` hook.
/// D's `std.process` has no such hook, so the sandboxed argv re-executes this
/// binary with `--landlock-exec`. That fresh process is single-threaded, so it
/// can safely build the ruleset, set `no_new_privs`, restrict itself and
/// `execv` the shell. The parent checks the ABI first, so an unsupported
/// kernel fails closed with Rust's message before anything runs.
module nano.landlock;

version (linux):

import std.format : format;

@safe:

import std.conv : to;

/// The internal flag that marks a helper invocation.
enum execFlag = "--landlock-exec";

private:

extern (C) long syscall(long number, ...) nothrow @nogc @system;
extern (C) int prctl(int option, ulong a2, ulong a3, ulong a4, ulong a5) nothrow @nogc @system;

// The generic syscall numbers (the same on x86_64 and aarch64).
enum long sysCreateRuleset = 444, sysAddRule = 445, sysRestrictSelf = 446;
enum uint createRulesetVersion = 1, rulePathBeneath = 1;
enum int prSetNoNewPrivs = 38;
enum int oPath = 0x200000, oCloexec = 0x80000;

enum ulong readFile = 1UL << 2, readDir = 1UL << 3;
enum ulong writeFile = 1UL << 1, removeDir = 1UL << 4, removeFile = 1UL << 5, makeChar = 1UL << 6,
    makeDir = 1UL << 7, makeReg = 1UL << 8, makeSock = 1UL << 9, makeFifo = 1UL << 10, makeBlock = 1UL << 11,
    makeSym = 1UL << 12, refer = 1UL << 13, truncate = 1UL << 14, ioctlDev = 1UL << 15;
enum ulong bindTcp = 1UL << 0, connectTcp = 1UL << 1;

struct RulesetAttr
{
    ulong handledAccessFs, handledAccessNet;
}

align(1) struct PathBeneathAttr
{
align(1):
    ulong allowedAccess;
    int parentFd;
}

static assert(PathBeneathAttr.sizeof == 12);

/// The kernel's Landlock ABI version (negative when unsupported).
/// `@trusted`: a raw syscall whose only pointer argument is null.
long abi() @trusted nothrow @nogc
{
    return syscall(sysCreateRuleset, null, size_t(0), createRulesetVersion);
}

/// `strerror(errno)` copied into a D string.
/// `@trusted`: reads the C string before anything else can overwrite it.
string lastError() @trusted
{
    import core.stdc.errno : errno;
    import core.stdc.string : strerror;
    import std.string : fromStringz;
    return strerror(errno).fromStringz.idup;
}

/// The handled access rights for this kernel, or an error (fail closed).
string rights(bool network, out long abiVersion, out ulong fs, out ulong net)
{
    abiVersion = abi();
    if (abiVersion < 1)
        return "sandbox unavailable: this kernel does not support Landlock (Linux 5.13+ with Landlock enabled)";
    // Without REFER (ABI 2) cross-directory renames, and without TRUNCATE
    // (ABI 3) truncation, escape the write boundary: require ABI 3.
    if (abiVersion < 3)
        return "sandbox unavailable: enforcing the write boundary needs Landlock ABI 3 (Linux 6.2+); "
            ~ "on older kernels cross-directory renames and file truncation cannot be confined";
    fs = writeFile | removeDir | removeFile | makeChar | makeDir | makeReg | makeSock | makeFifo | makeBlock
        | makeSym | refer | truncate;
    // IOCTL_DEV (ABI 5) is the only right that confines device ioctls; below
    // it the lexical device guards in permissions are the compensating control.
    if (abiVersion >= 5) fs |= ioctlDev;
    if (!network)
    {
        if (abiVersion < 4)
            return "sandbox unavailable: blocking the network needs Landlock ABI 4 (Linux 6.7+); set network = true";
        net = bindTcp | connectTcp;
    }
    return null;
}

public:

/// Why the sandbox can't apply on this kernel, or null.
string check(bool network)
{
    long v;
    ulong fs, net;
    return rights(network, v, fs, net);
}

/// The argv that runs `shell -c script` writing only to `roots` and, when
/// `confineReads`, reading only `reads` (issue #333).
string[] argv(bool network, const string[] roots, bool confineReads, const string[] reads, string shell,
    string script)
{
    import std.file : thisExePath;
    return helperArgs(thisExePath, network, roots, confineReads, reads) ~ [shell, "-c", script];
}

/// The helper's argv prefix: [exe, execFlag, network, n, roots..., m|"-", reads...].
string[] helperArgs(string exe, bool network, const string[] roots, bool confineReads, const string[] reads) pure
{
    import std.conv : to;
    return [exe, execFlag, network ? "1" : "0", roots.length.to!string] ~ roots.dup
        ~ [confineReads ? reads.length.to!string : "-"] ~ reads.dup;
}

/// A rule the helper adds: a path and the rights granted beneath it.
struct Rule
{
    /// The path (directory or file).
    string path;
    /// Granted access rights.
    ulong access;
}

/// The Landlock rules for `roots` (writable) and `reads` (readable), given
/// the handled `fs` rights; files get only file rights. The directory test is
/// injected so the rule set is unit-tested without a Landlock kernel.
Rule[] ruleSet(ulong fs, const string[] roots, bool confineReads, const string[] reads,
    scope bool delegate(string) @safe isDirectory)
{
    // Device-node creation is handled but granted nowhere, so mknod fails
    // closed everywhere (a node in the workspace could reach a raw device).
    auto granted = fs & ~(makeChar | makeBlock | readFile | readDir);
    Rule[] rules;
    foreach (root; roots)
        // No read rights here: a writable root may contain a denied path
        // (e.g. cwd = $HOME), so the caller passes write roots through the
        // read splitting (`landlockReadRoots`) and they arrive in `reads`.
        rules ~= Rule(root, isDirectory(root) ? granted : granted & (writeFile | truncate | ioctlDev));
    if (confineReads)
        foreach (r; reads) rules ~= Rule(r, isDirectory(r) ? readFile | readDir : readFile);
    return rules;
}

/// Restrict this process to writing `roots` and, when `confineReads`,
/// reading `reads` (call it single-threaded, before exec).
string restrict(bool network, const string[] roots, bool confineReads, const string[] reads) @trusted
{
    import core.sys.posix.fcntl : open;
    import core.sys.posix.unistd : close;
    import std.string : toStringz;
    import nano.paths : isDir;
    long v;
    ulong fs, net;
    if (auto e = rights(network, v, fs, net)) return e;
    if (confineReads) fs |= readFile | readDir;
    auto attr = RulesetAttr(fs, net);
    auto size = v >= 4 ? RulesetAttr.sizeof : ulong.sizeof;
    auto fd = syscall(sysCreateRuleset, &attr, size, 0u).to!int;
    if (fd < 0) return "sandbox unavailable: landlock_create_ruleset: " ~ lastError();
    scope (exit) close(fd);
    foreach (r; ruleSet(fs, roots, confineReads, reads, (string p) => isDir(p)))
    {
        auto parent = open(r.path.toStringz, oPath | oCloexec);
        if (parent < 0) continue;
        scope (exit) close(parent);
        auto rule = PathBeneathAttr(r.access, parent);
        if (syscall(sysAddRule, fd, rulePathBeneath, &rule, 0u) < 0)
            return format("sandbox: landlock_add_rule %s: %s", r.path, lastError());
    }
    if (prctl(prSetNoNewPrivs, 1, 0, 0, 0) != 0) return "sandbox: prctl(PR_SET_NO_NEW_PRIVS): " ~ lastError();
    if (syscall(sysRestrictSelf, fd, 0u) != 0) return "sandbox: landlock_restrict_self: " ~ lastError();
    return null;
}

/// The helper: `args` = [exe, execFlag, network, n, roots..., m|"-", reads..., shell, "-c", script].
/// Only returns on failure (exit status 126, like a shell's "cannot execute").
int helperMain(string[] args) @trusted
{
    import std.conv : to;
    import std.stdio : stderr;
    import std.string : toStringz;
    import core.sys.posix.unistd : execvp;
    string fail(string e) { stderr.writeln(e); return e; }
    try
    {
        auto network = args[2] == "1";
        auto n = args[3].to!size_t;
        auto roots = args[4 .. 4 + n];
        auto confineReads = args[4 + n] != "-";
        auto m = confineReads ? args[4 + n].to!size_t : 0;
        auto reads = args[5 + n .. 5 + n + m];
        auto rest = args[5 + n + m .. $];
        if (rest.length < 1) { fail("sandbox: no command"); return 126; }
        if (auto e = restrict(network, roots, confineReads, reads)) { fail(e); return 126; }
        const(char)*[] cargs;
        foreach (a; rest) cargs ~= a.toStringz;
        cargs ~= null;
        execvp(cargs[0], cargs.ptr);
        fail(format("sandbox: exec %s: %s", rest[0], lastError()));
    }
    catch (Exception e) fail("sandbox: bad helper arguments: " ~ e.msg);
    return 126;
}

// Run the helper before `main` (or the unittest runner) does anything else.
shared static this() @trusted
{
    import core.runtime : Runtime;
    import core.stdc.stdlib : exit;
    import std.stdio : stdout, stderr;
    auto a = Runtime.args;
    if (a.length > 1 && a[1] == execFlag)
    {
        auto rc = helperMain(a);
        stderr.flush();
        exit(rc);
    }
}

unittest // issue #333: the helper argv carries the read set, or "-" when reads aren't confined
{
    assert(helperArgs("/x", true, ["/w"], false, null) == ["/x", execFlag, "1", "1", "/w", "-"]);
    assert(helperArgs("/x", false, ["/w"], true, ["/usr", "/home/u/a"])
        == ["/x", execFlag, "0", "1", "/w", "2", "/usr", "/home/u/a"]);
}

unittest // issue #333: the Landlock rule set grants reads only on the read roots, never on write roots
{
    auto fs = writeFile | truncate | makeDir | makeChar;
    bool dir(string p) { return p != "/w/file" && p != "/r/file"; }
    auto off = ruleSet(fs, ["/w"], false, null, &dir);
    assert(off.length == 1 && off[0].access == (writeFile | truncate | makeDir));
    auto on = ruleSet(fs | readFile | readDir, ["/w", "/w/file"], true, ["/usr", "/r/file"], &dir);
    assert(on.length == 4);
    assert(on[0] == Rule("/w", writeFile | truncate | makeDir));
    assert(on[1] == Rule("/w/file", writeFile | truncate));
    assert(on[2] == Rule("/usr", readFile | readDir));
    assert(on[3] == Rule("/r/file", readFile));
    foreach (r; on) assert(!(r.access & makeChar), r.path);
}
