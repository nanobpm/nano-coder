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
    privateTempDir();
    installRunner();
}

/// Point TMPDIR (and so `std.file.tempDir`, and every child process) at a
/// directory of this process's own: tests name their scratch directories by
/// purpose (`nano-d-mem-index`), so two test runs at once (two worktrees, or
/// ci.sh while a pre-push hook runs) would otherwise delete and overwrite
/// each other's files (issue #253).
private void privateTempDir()
{
    import std.file : mkdirRecurse;
    import std.path : buildPath;
    import std.process : environment;
    auto base = environment.get("TMPDIR", "/tmp");
    const ownTemp = buildPath(base, ownTempName);
    mkdirRecurse(ownTemp);
    environment["TMPDIR"] = ownTemp;
}

/// The name of this process's temp directory.
private string ownTempName()
{
    import std.conv : to;
    import std.process : thisProcessID;
    return "nano-test-" ~ thisProcessID.to!string;
}

/// Remove the directory `privateTempDir` made (TMPDIR still names it).
private void removeTempDir()
{
    import std.file : exists, rmdirRecurse;
    import std.path : baseName;
    import std.process : environment;
    const ownTemp = environment.get("TMPDIR");
    if (ownTemp is null || ownTemp.baseName != ownTempName || !ownTemp.exists) return;
    try rmdirRecurse(ownTemp);
    catch (Exception) {} // best effort: a leftover temp dir fails nothing
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
    /// Why it failed (the thrown error, or the time limit); null when it passed.
    string reason;
}

/// A module's unittest function, as druntime lists it.
struct TestEntry
{
    string name;
    void function() run;
}

/// The last dotted component: `core.exception.AssertError` -> `AssertError`.
private string findLastDot(string s) pure nothrow @nogc
{
    foreach_reverse (i, c; s) if (c == '.') return s[i + 1 .. $];
    return s;
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
    import nano.safeio : Chan, Shared, spawn, spawnDaemon, stdErr;
    immutable(TestEntry)[] all;
    foreach (m; ModuleInfo)
        if (m !is null && m.unitTest !is null) all ~= immutable TestEntry(m.name, cast(void function() @safe) m.unitTest);
    const jobs = environment.get("NANO_TEST_JOBS", "1").to!size_t;
    const serial = listedModules("scripts/serial-tests");
    // The host's load before the tests start (see loadFactor).
    const startLoad = calibrate();
    auto results = Chan!ModuleRun.make;
    auto queue = Chan!size_t.make;
    const scaleText = environment.get("NANO_TEST_BUDGET_SCALE");
    const scale = scaleText.length ? scaleText.to!double : 1.0;
    auto running = Shared!(immutable(Running)[]).make;
    auto limits = hardLimits(scale);
    spawnDaemon(&watchdog, running);
    if (jobs > 1)
    {
        // Modules that change process-wide state go first, alone.
        foreach (i, e; all) if (e.name in serial) queue.put(i);
        queue.close();
        runQueue(all, queue, results, running, limits);
        queue = Chan!size_t.make;
        foreach (i, e; all) if (e.name !in serial) queue.put(i);
    }
    else foreach (i; 0 .. all.length) queue.put(i);
    queue.close();
    if (jobs <= 1) runQueue(all, queue, results, running, limits);
    else
    {
        typeof(spawn(&runQueue, all, queue, results, running, limits))[] workers;
        foreach (_; 0 .. jobs) workers ~= spawn(&runQueue, all, queue, results, running, limits);
        foreach (ref w; workers) w.join();
    }
    results.close();
    ModuleRun[] runs;
    ModuleRun r;
    while (results.take(r)) runs ~= r;
    checkBudgets(runs, scale, true, startLoad);
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
    // Our own summary, last: druntime's names no module, and the reasons are
    // otherwise far above in the output.
    stdErr.writeln(summary(runs));
    removeTempDir();
    size_t passed;
    foreach (x; runs) if (x.passed) passed++;
    return UnitTestResult(runs.length, passed, false, false);
}

/// The final line: how many modules passed, or which failed and why, e.g.
/// `1/107 modules FAILED unittests: nano.memory_test (time limit 2330/2250 ms)`.
string summary(const ModuleRun[] runs)
{
    import std.algorithm : filter, map, sort;
    import std.array : array, join;
    import std.format : format;
    ModuleRun[] failed = runs.filter!(r => !r.passed).map!(r => ModuleRun(r.name, r.msecs, r.passed, r.reason)).array;
    if (!failed.length) return format("%s modules passed unittests", runs.length);
    failed.sort!((a, b) => a.name < b.name);
    return format("%s/%s modules FAILED unittests: %s", failed.length, runs.length,
        failed.map!(r => r.reason.length ? format("%s (%s)", r.name, r.reason) : r.name).join(", "));
}

unittest
{
    assert(summary([ModuleRun("a", 1, true)]) == "1 modules passed unittests");
    assert(summary([ModuleRun("b", 2330, false, "time limit 2330/2250 ms"), ModuleRun("a", 1, true),
            ModuleRun("a2", 1, false, "AssertError at x.d(3)")])
        == "2/3 modules FAILED unittests: a2 (AssertError at x.d(3)), b (time limit 2330/2250 ms)");
}

/// Run modules from `queue` until it is empty, reporting each to `results`.
// @trusted: calls the @system-typed module test functions (@safe code, see
// above) and catches Throwable: a failed assert is an Error, and a runner must
// report it and go on, as druntime's does.
void runQueue(immutable(TestEntry)[] all, imported!"nano.safeio".Chan!size_t queue,
    imported!"nano.safeio".Chan!ModuleRun results, imported!"nano.safeio".Shared!(immutable(Running)[]) running,
    immutable(HardLimit)[] limits) @trusted
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
        immutable entry = immutable Running(all[i].name, hardLimitOf(limits, all[i].name), start);
        running.update((ref immutable(Running)[] r) { r ~= entry; });
        scope (exit) running.update((ref immutable(Running)[] r) {
            import std.algorithm : remove;
            import std.array : array;
            import std.algorithm : filter;
            r = r.filter!(x => x != entry).array;
        });
        bool ok = true;
        string reason;
        try all[i].run();
        catch (Throwable t) // a failed assert is an Error: report it like druntime and run the rest
        {
            import std.format : format;
            ok = false;
            stdErr.writeln(t.toString);
            reason = format("%s at %s(%s)", typeid(t).name.findLastDot, t.file, t.line);
        }
        results.put(ModuleRun(all[i].name, since(start).total!"msecs", ok, reason));
    }
}

/// A module whose tests are running: its hard limit and when it started.
struct Running
{
    string name;
    long hardLimitMs;
    imported!"core.time".MonoTime start;
}

/// The least hard limit: below it the watchdog never ends the run.
enum minHardLimitMs = 10_000;

/// Each module's hard limit, in msecs: twice its budget at the most load
/// `checkBudgets` allows, so a module the watchdog stops would have failed
/// its budget anyway. The `""` key holds the default.
immutable(HardLimit)[] hardLimits(double scale)
{
    import std.array : split;
    import std.conv : to;
    HardLimit[] r;
    long hard(long budget) { const h = cast(long)(budget * scale * maxLoadFactor * 2); return h > minHardLimitMs ? h : minHardLimitMs; }
    foreach (name, rest; listedModules("scripts/slow-tests")) r ~= HardLimit(name, hard(rest.split[0].to!long));
    r ~= HardLimit("", hard(defaultBudgetMs));
    return r.idup;
}

/// A module's hard limit (`""`: the default).
struct HardLimit { string name; long ms; }

/// `module`'s hard limit in `limits`, else the default entry's.
long hardLimitOf(const HardLimit[] limits, string module_) pure
{
    long fallback = minHardLimitMs;
    foreach (l; limits)
    {
        if (l.name == module_) return l.ms;
        if (l.name == "") fallback = l.ms;
    }
    return fallback;
}

/// The first running module past its hard limit at `now`, if any.
imported!"nano.option".Option!Running overdue(const Running[] running, imported!"core.time".MonoTime now)
{
    import nano.option : some, Option;
    foreach (r; running)
        if ((now - r.start).total!"msecs" > r.hardLimitMs) return some(Running(r.name, r.hardLimitMs, r.start));
    return Option!Running.init;
}

unittest
{
    import core.time : MonoTime, msecs;
    auto t0 = monoNow;
    auto rs = [Running("a", 100, t0), Running("b", 50, t0 + 10.msecs)];
    assert(overdue(rs, t0 + 60.msecs).isNone);
    import nano.option : unwrap;
    assert(overdue(rs, t0 + 61.msecs).unwrap("b is overdue").name == "b");
    assert(overdue(rs, t0 + 101.msecs).unwrap("a is overdue").name == "a");
    assert(hardLimitOf(hardLimits(1.0), "nano.nonesuch") >= minHardLimitMs);
    assert(hardLimitOf([HardLimit("x", 20_000), HardLimit("", 12_000)], "x") == 20_000);
    assert(hardLimitOf([HardLimit("x", 20_000), HardLimit("", 12_000)], "y") == 12_000);
}

/// Ends the run when a module's tests outlive their hard limit: a test that
/// hangs (a refused retry loop, a lost wakeup) can't be joined, so the run
/// names the module and exits failing instead of never finishing (#358).
void watchdog(imported!"nano.safeio".Shared!(immutable(Running)[]) running)
{
    import core.time : msecs;
    import nano.clock : sleepFor;
    import nano.safeio : exitProcess, stdErr;
    while (true)
    {
        sleepFor(250.msecs);
        foreach (r; overdue(running.get(), monoNow))
        {
            stdErr.writefln("%s: unit tests still running after %s ms, over the %s ms hard limit: "
                ~ "the module hangs; failing the run", r.name, since(r.start).total!"msecs", r.hardLimitMs);
            stdErr.writefln("1 module FAILED unittests: %s (hung past %s ms)", r.name, r.hardLimitMs);
            stdErr.flush();
            exitProcess(1);
        }
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
        import std.format : format;
        const why = format("time limit %s/%s ms", r.msecs, limit);
        r.reason = r.reason.length ? r.reason ~ "; " ~ why : why;
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
    assert(runs[0].reason == "time limit 1001/1000 ms", runs[0].reason);
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
