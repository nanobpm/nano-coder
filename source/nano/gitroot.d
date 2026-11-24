/// Finding the git repository that holds a directory, the way git does.
///
/// Instructions, skills, trust and hooks all look for the nearest ancestor
/// holding `.git`. Like git, the walk honours `GIT_CEILING_DIRECTORIES`: it
/// never moves up into a listed directory. That keeps a directory outside any
/// repository from picking up an unrelated one higher up, and it is how the
/// unit tests stay hermetic when the host's temp directory sits inside a git
/// checkout (a Nano Workforce worker's TMPDIR is under its workspace's `.git`,
/// issue #374).
module nano.gitroot;

@safe:

import std.path : buildPath, dirName;

/// The nearest directory at or above `start` holding `.git`, or null. The walk
/// stops before it would enter a directory listed in `GIT_CEILING_DIRECTORIES`.
string gitRoot(string start)
{
    return gitRootBelow(start, ceilingDirs());
}

/// `gitRoot` with the ceiling directories given rather than read from the
/// environment.
string gitRootBelow(string start, const string[] ceilings)
{
    import std.file : exists;
    for (auto d = start;;)
    {
        if (exists(buildPath(d, ".git"))) return d;
        auto up = d.dirName;
        if (up == d || isCeiling(up, ceilings)) return null;
        d = up;
    }
}

/// The directories in `GIT_CEILING_DIRECTORIES` (colon-separated, absolute
/// entries only, as git reads it), each also in its canonical form.
string[] ceilingDirs()
{
    import std.process : environment;
    import nano.safeio : realPath;
    string[] dirs;
    foreach (entry; parseCeilings(environment.get("GIT_CEILING_DIRECTORIES", "")))
    {
        dirs ~= entry;
        auto real_ = realPath(entry);
        if (real_ !is null && real_ != entry) dirs ~= real_;
    }
    return dirs;
}

/// The absolute entries of a `GIT_CEILING_DIRECTORIES` value, trailing
/// slashes removed.
string[] parseCeilings(string value) pure
{
    import std.algorithm : splitter;
    string[] dirs;
    foreach (entry; value.splitter(':'))
    {
        if (!entry.length || entry[0] != '/') continue;
        while (entry.length > 1 && entry[$ - 1] == '/') entry = entry[0 .. $ - 1];
        dirs ~= entry;
    }
    return dirs;
}

/// Whether `dir` is one of `ceilings`.
bool isCeiling(string dir, const string[] ceilings) pure nothrow @nogc
{
    foreach (c; ceilings) if (c == dir) return true;
    return false;
}

unittest
{
    assert(parseCeilings("") == []);
    assert(parseCeilings("/a/b/:relative::/c") == ["/a/b", "/c"]);
    assert(parseCeilings("/") == ["/"]);
    assert(isCeiling("/a", ["/b", "/a"]) && !isCeiling("/a/b", ["/a"]));
}

unittest // the walk finds a repository, but never crosses a ceiling
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    auto base = buildPath(tempDir, "nano-d-gitroot");
    scope (exit) rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "repo", ".git"));
    mkdirRecurse(buildPath(base, "repo", "top", "sub"));
    const sub = buildPath(base, "repo", "top", "sub");
    assert(gitRootBelow(sub, []) == buildPath(base, "repo"));
    // The repository is the ceiling: the walk stops before entering it ...
    assert(gitRootBelow(sub, [buildPath(base, "repo")]) is null);
    // ... but a start directory that is itself a ceiling is still checked.
    assert(gitRootBelow(buildPath(base, "repo"), [buildPath(base, "repo")]) == buildPath(base, "repo"));
}
