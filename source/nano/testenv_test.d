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

import nano.update : gitLocalEnvVars;

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
    // The host's load before the tests start (see loadFactor).
    const startLoad = calibrate();
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
    const scaleText = environment.get("NANO_TEST_BUDGET_SCALE");
    checkBudgets(runs, scaleText.length ? scaleText.to!double : 1.0, true, startLoad);
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
///
/// The limits are wall-clock, and a busy host (other builds, agent workers)
/// slows real processes and sleeps without the code changing. So a module
/// over its limit is judged against the host's current speed: the limit is
/// multiplied by `loadFactor`, from a calibration run in this process at the
/// start (`startLoad`, msecs) and another one now. A fixed sleep still fails
/// on an idle host; the factor is capped at `maxLoadFactor`.
void checkBudgets(ModuleRun[] runs, double scale, bool report = true, long startLoad = 0,
    long delegate() @safe nowLoad = null)
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
    double load = 0; // measured lazily: only a module over its plain limit pays for it
    foreach (ref r; runs)
    {
        const base = limits.get(r.name, defaultBudgetMs) * scale;
        if (r.msecs <= cast(long) base) continue;
        if (load == 0)
        {
            const now = nowLoad is null ? calibrate() : nowLoad();
            load = loadFactor(startLoad > now ? startLoad : now);
            if (report && load > 1)
                stdErr.writefln("host under load: test limits scaled by %.2f (calibration %s ms, %s ms idle)",
                    load, startLoad > now ? startLoad : now, calibrationIdleMs);
        }
        const limit = cast(long)(base * load);
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
    checkBudgets(runs, 1.0, false, 0, () => 0L);
    assert(!runs[0].passed && runs[1].passed);
}

/// What `calibrate` takes on an idle development machine (M-series Mac), in
/// msecs; a slower or busier host scales the limits by its ratio to this.
enum calibrationIdleMs = 40;
/// The most a busy host can stretch a limit: a module far over it fails anyway.
enum maxLoadFactor = 3.0;

/// The limit multiplier for a calibration that took `msecs`: 1 at or below
/// the idle time, growing with it, capped at `maxLoadFactor`.
double loadFactor(long msecs) pure nothrow @nogc
{
    const f = cast(double) msecs / calibrationIdleMs;
    return f < 1 ? 1 : f > maxLoadFactor ? maxLoadFactor : f;
}

unittest
{
    assert(loadFactor(0) == 1 && loadFactor(calibrationIdleMs) == 1);
    assert(loadFactor(calibrationIdleMs * 2) == 2 && loadFactor(calibrationIdleMs * 100) == maxLoadFactor);
}

/// Times a fixed piece of the work the slow tests do: CPU, short sleeps and
/// spawning processes, so it slows down with the host the way they do.
/// Returns msecs.
long calibrate()
{
    import core.time : msecs;
    import std.process : spawnProcess, wait, Config;
    import std.stdio : File;
    import nano.clock : sleepFor;
    const start = monoNow;
    foreach (_; 0 .. 4)
        wait(spawnProcess(["/bin/sh", "-c", ":"], File("/dev/null", "r"), File("/dev/null", "w"),
            File("/dev/null", "w"), null, Config.none));
    foreach (_; 0 .. 4) sleepFor(1.msecs);
    ulong x = 1;
    foreach (ulong i; 0 .. 20_000_000) x = x * 6364136223846793005UL + i;
    // Keep the loop: a result the optimizer can't drop.
    if (x == 42) sleepFor(1.msecs);
    return since(start).total!"msecs";
}

private shared bool hogStop;

/// Burns CPU until `hogStop`: synthetic host load.
private void hog()
{
    import core.atomic : atomicLoad;
    ulong y = 1;
    while (!atomicLoad(hogStop)) foreach (ulong i; 0 .. 1000) y = y * 3 + i;
}

// The guard under synthetic load: busy threads on every core slow the
// calibration, so a module stretched by the same load passes; the same time
// on an idle host fails.
unittest
{
    import core.atomic : atomicStore;
    import std.file : exists;
    import std.parallelism : totalCPUs;
    import nano.safeio : spawnDaemon;
    if (!"scripts/slow-tests".exists) return;
    const idle = calibrate();
    atomicStore(hogStop, false);
    typeof(spawnDaemon(&hog))[] hogs;
    long loaded;
    {
        // Installed before the first start: a partial startup still stops
        // and joins every hog already running.
        scope (exit) { atomicStore(hogStop, true); foreach (ref h; hogs) h.join(); }
        foreach (_; 0 .. totalCPUs * 3) hogs ~= spawnDaemon(&hog);
        loaded = calibrate();
    }
    // External load can shift between samples, so the measured ordering is
    // only a diagnostic; the injected calibrations below are the checks.
    if (loaded <= idle)
    {
        import nano.safeio : stdErr;
        stdErr.writefln("note: synthetic load did not slow calibration (idle %s ms, loaded %s ms)",
            idle, loaded);
    }
    // A module 50% over its limit passes when the host is 2x slower...
    auto runs = [ModuleRun("nano.nonesuch", defaultBudgetMs * 3 / 2, true)];
    checkBudgets(runs, 1.0, false, 0, () => calibrationIdleMs * 2);
    assert(runs[0].passed);
    // ...and fails on an idle host, or when far over even a capped factor.
    runs = [ModuleRun("nano.nonesuch", defaultBudgetMs * 3 / 2, true),
        ModuleRun("nano.nonesuch2", cast(long)(defaultBudgetMs * maxLoadFactor) + 1, true)];
    checkBudgets(runs, 1.0, false, 0, () => calibrationIdleMs / 2);
    assert(!runs[0].passed && !runs[1].passed);
    // The measured load feeds the same path.
    runs = [ModuleRun("nano.nonesuch", cast(long)(defaultBudgetMs * loadFactor(loaded)), true)];
    checkBudgets(runs, 1.0, false, 0, () => loaded);
    assert(runs[0].passed);
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
