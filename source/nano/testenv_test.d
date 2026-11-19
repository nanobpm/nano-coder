/// The unit-test process's environment. `dub test` started from a git hook
/// (pre-push, a rebase `exec`) inherits `GIT_DIR` and friends, which point
/// every `git` the tests run in their temp directories at the enclosing
/// repository instead: tests then commit to its current branch, add
/// worktrees and branches, and `git init --bare` turns it bare. Clearing
/// git's repository variables before any test runs keeps the tests hermetic.
module nano.testenv_test;
@safe:
import nano.clock : monoNow, since;

version (unittest):

import core.runtime : UnitTestResult;

/// `git rev-parse --local-env-vars`.
immutable string[] gitLocalEnvVars = [
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX",
    "GIT_SHALLOW_FILE", "GIT_COMMON_DIR",
];

shared static this()
{
    import std.process : environment;
    foreach (name; gitLocalEnvVars) environment.remove(name);
    installRunner();
}

// @trusted: Runtime's unittest hook is a plain (@system) global setter, set
// once at startup before any test runs.
private void installRunner() @trusted
{
    import core.runtime : Runtime;
    Runtime.extendedModuleUnitTester = &runModuleTests;
}

/// One module's unittests and how long they took.
struct ModuleRun
{
    string name;
    long msecs;
    bool passed;
}

/// A module's unittest function, as druntime lists it.
struct TestEntry
{
    string name;
    void function() run;
}

/// Runs every module's unittests, like druntime's default runner, timing each
/// one. `NANO_TEST_JOBS=N` runs N modules at a time (default 1: serial);
/// `NANO_TEST_TIMES=N` prints the N slowest modules.
// @trusted: druntime's ModuleInfo walk and module test functions are typed
// @system, but every module is `@safe:` (check-safe), so the tests are @safe code.
UnitTestResult runModuleTests() @trusted
{
    import std.algorithm : sort;
    import std.conv : to;
    import std.process : environment;
    import nano.safeio : Chan, spawn, stdErr;
    immutable(TestEntry)[] all;
    foreach (m; ModuleInfo)
        if (m !is null && m.unitTest !is null) all ~= immutable TestEntry(m.name, cast(void function() @safe) m.unitTest);
    const jobs = environment.get("NANO_TEST_JOBS", "1").to!size_t;
    const serial = listedModules("scripts/serial-tests");
    auto results = Chan!ModuleRun.make;
    auto queue = Chan!size_t.make;
    if (jobs > 1)
    {
        // Modules that change process-wide state go first, alone.
        foreach (i, e; all) if (e.name in serial) queue.put(i);
        queue.close();
        runQueue(all, queue, results);
        queue = Chan!size_t.make;
        foreach (i, e; all) if (e.name !in serial) queue.put(i);
    }
    else foreach (i; 0 .. all.length) queue.put(i);
    queue.close();
    if (jobs <= 1) runQueue(all, queue, results);
    else
    {
        typeof(spawn(&runQueue, all, queue, results))[] workers;
        foreach (_; 0 .. jobs) workers ~= spawn(&runQueue, all, queue, results);
        foreach (ref w; workers) w.join();
    }
    results.close();
    ModuleRun[] runs;
    ModuleRun r;
    while (results.take(r)) runs ~= r;
    checkBudgets(runs);
    size_t passed;
    foreach (x; runs) if (x.passed) passed++;
    auto top = environment.get("NANO_TEST_TIMES");
    if (top.length)
    {
        runs.sort!((a, b) => a.msecs > b.msecs);
        long total;
        foreach (x; runs) total += x.msecs;
        stdErr.writefln("slowest modules (total %s ms, %s job%s):", total, jobs, jobs == 1 ? "" : "s");
        foreach (x; runs[0 .. $ < top.to!size_t ? $ : top.to!size_t])
            stdErr.writefln("%7s ms  %s", x.msecs, x.name);
    }
    return UnitTestResult(runs.length, passed, false, true);
}

/// Run modules from `queue` until it is empty, reporting each to `results`.
// @trusted: calls the @system-typed module test functions (@safe code, see
// above) and catches Throwable: a failed assert is an Error, and a runner must
// report it and go on, as druntime's does.
void runQueue(immutable(TestEntry)[] all, imported!"nano.safeio".Chan!size_t queue,
    imported!"nano.safeio".Chan!ModuleRun results) @trusted
{
    import std.process : environment;
    import nano.safeio : stdErr;
    const trace = environment.get("NANO_TEST_TRACE").length > 0;
    size_t i;
    while (queue.take(i))
    {
        if (trace) stdErr.writefln("test start %s", all[i].name);
        scope (exit) if (trace) stdErr.writefln("test end %s", all[i].name);
        const start = monoNow;
        bool ok = true;
        try all[i].run();
        catch (Throwable t) // a failed assert is an Error: report it like druntime and run the rest
        {
            ok = false;
            stdErr.writeln(t.toString);
        }
        results.put(ModuleRun(all[i].name, since(start).total!"msecs", ok));
    }
}

/// Default per-module unit-test time limit (scripts/slow-tests lists more).
enum defaultBudgetMs = 1000;

/// Fail (mark not passed) each module whose tests took longer than its limit
/// in scripts/slow-tests: a fixed sleep or a long real timeout in a test shows
/// up here instead of slowly growing the suite.
void checkBudgets(ModuleRun[] runs, bool report = true)
{
    import std.array : split;
    import std.conv : to;
    import std.file : exists;
    import std.process : environment;
    import nano.safeio : stdErr;
    long[string] limits;
    enum file = "scripts/slow-tests";
    if (!file.exists) return; // not run from the repo root: no budgets
    foreach (name, rest; listedModules(file)) limits[name] = rest.split[0].to!long;
    const scaleText = environment.get("NANO_TEST_BUDGET_SCALE");
    const scale = scaleText.length ? scaleText.to!double : 1.0;
    foreach (ref r; runs)
    {
        const limit = cast(long)(limits.get(r.name, defaultBudgetMs) * scale);
        if (r.msecs <= limit) continue;
        r.passed = false;
        if (report) stdErr.writefln("%s: unit tests took %s ms, over the %s ms limit (%s); shorten the waits "
            ~ "(timeout/grace parameters, nano.clock.FakeClock) or raise the limit with a reason",
            r.name, r.msecs, limit, file);
    }
}

unittest // a module over its limit fails; listed modules get theirs
{
    // checkBudgets reads scripts/slow-tests; the default applies to others.
    auto runs = [ModuleRun("nano.nonesuch", defaultBudgetMs + 1, true), ModuleRun("nano.nonesuch2", 1, true)];
    import std.file : exists;
    if (!"scripts/slow-tests".exists) return;
    checkBudgets(runs, false);
    assert(!runs[0].passed && runs[1].passed);
}

/// `module rest-of-line` entries of a scripts/ list (`#` comments, blank
/// lines skipped); empty when the file is missing.
string[string] listedModules(string file)
{
    import std.algorithm : findSplit, startsWith;
    import std.file : exists, readText;
    import std.string : lineSplitter, strip;
    string[string] r;
    if (!file.exists) return r;
    foreach (line; file.readText.lineSplitter)
    {
        auto l = line.strip;
        if (!l.length || l.startsWith("#")) continue;
        auto parts = l.findSplit(" ");
        r[parts[0]] = parts[2].strip;
    }
    return r;
}
