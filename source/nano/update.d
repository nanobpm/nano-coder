/// Background update check, `/update` and `/relaunch` (update.rs, Rust #154
/// and #172). Interactive terminal sessions only (never `-p`, ACP or CI):
/// a check at startup and then hourly, in the background; the last check and
/// the latest known version persist in `<data dir>/nano-coder/
/// update-check.json`, so a quick restart doesn't check again. A newer
/// release gives one hint per version, at an idle prompt. Offline, the check
/// fails quietly within five seconds. `check_updates = false` or
/// `NANO_CODER_NO_UPDATE_CHECK` / `NO_UPDATE_NOTIFIER` turn it off.
///
/// Two managed channels: npm (`@nanobpm/nano-coder`) and Homebrew
/// (`nanobpm/tap/nano-coder`, Rust #188). The D build is not on crates.io, so
/// there is no cargo channel; anything else (a release tarball, a dev build)
/// is "other" and is never changed by `/update`.
module nano.update;

@safe:
import nano.safeio : jsonText, jsonPretty;
import nano.clock : sleepFor, wallNow;
import nano.arith : saturatingSub;

import std.json;
import std.format : format;
import std.string : strip;
import std.algorithm.searching : startsWith;
import nano.safeio : Chan;

/// How often a running session checks again.
enum long checkIntervalSecs = 60 * 60;
enum npmPackage = "@nanobpm/nano-coder";
enum npmLatestUrl = "https://registry.npmjs.org/" ~ npmPackage ~ "/latest";
enum releasesUrl = "https://github.com/nanobpm/nano-coder/releases";
/// The tap's formula. `brew upgrade` installs whatever it points at, which the
/// release workflow bumps a few minutes after a release, so this (not the
/// GitHub release) is the latest version a brew install can get.
enum brewFormulaUrl = "https://raw.githubusercontent.com/nanobpm/homebrew-tap/main/Formula/nano-coder.rb";
/// The formula `/update` upgrades (tap-qualified, never another tap's).
enum brewFormula = "nanobpm/tap/nano-coder";

/// How this binary was installed, so `/update` knows what may replace it.
enum Channel { npm, brew, other }

/// The channel for an executable path: npm when it, or the file it links to,
/// lies under a `node_modules/@nanobpm/` tree (macOS reports the global bin
/// symlink npm launched it through: Rust #172); brew when either lies in a
/// `Cellar/nano-coder/` keg (the `<prefix>/bin` and `opt` links resolve there).
Channel channelFor(string exe)
{
    import nano.paths : resolveSymlinks;
    auto paths = [exe, exe.length ? resolveSymlinks(exe) : null];
    foreach (p; paths)
        if (hasComponents(p, ["node_modules", "@nanobpm"])) return Channel.npm;
    foreach (p; paths)
        if (hasComponents(p, ["Cellar", "nano-coder"])) return Channel.brew;
    return Channel.other;
}

/// For `<prefix>/Cellar/nano-coder/<version>/bin/nano-coder`, the stable
/// `<prefix>/opt/nano-coder/bin/nano-coder` link that follows upgrades (the
/// versioned keg is gone after `brew upgrade` cleans up); null otherwise.
string brewOptExe(string exe) pure
{
    import std.algorithm : splitter;
    import std.array : array, join;
    auto parts = exe.splitter('/').array;
    if (parts.length < 6) return null;
    auto t = parts[$ - 5 .. $];
    if (t[0] != "Cellar" || t[1] != "nano-coder" || t[3] != "bin" || t[4] != "nano-coder") return null;
    return (parts[0 .. $ - 5] ~ ["opt", "nano-coder", "bin", "nano-coder"]).join("/");
}

/// The release a formula installs, read from its download URL
/// (`…/releases/download/v<version>/…`); null when there is none.
string formulaVersion(string formula) pure
{
    import std.algorithm : findSplit;
    auto r = formula.findSplit("/releases/download/v");
    if (!r[1].length) return null;
    auto v = r[2].findSplit("/")[0];
    return v.length ? v : null;
}

private bool hasComponents(string path, string[] want) pure
{
    import std.algorithm : splitter;
    import std.array : array;
    auto parts = path.splitter('/').array;
    if (parts.length < want.length) return false;
    foreach (i; 0 .. parts.length - want.length + 1)
        if (parts[i .. i + want.length] == want) return true;
    return false;
}

/// `path` without the " (deleted)" Linux appends to /proc/self/exe once the
/// running binary was replaced (as an update does), so a relaunch finds the new one.
string stripDeletedSuffix(string path) pure
{
    import std.string : chomp;
    return path.chomp(" (deleted)");
}

// rust: update.rs::deleted_suffix_is_stripped_from_the_launch_path
unittest
{
    assert(stripDeletedSuffix("/home/u/.cargo/bin/nano-coder (deleted)") == "/home/u/.cargo/bin/nano-coder");
    assert(stripDeletedSuffix("/home/u/.cargo/bin/nano-coder") == "/home/u/.cargo/bin/nano-coder");
}

/// This process's executable.
string launchExe()
{
    import std.file : thisExePath;
    import std.file : exists;
    string exe;
    try exe = stripDeletedSuffix(thisExePath());
    catch (Exception) return null; // no executable path: updates can't relaunch, the caller says so
    // Linux names the versioned keg; after `brew upgrade` only `opt` is valid.
    auto opt = brewOptExe(exe);
    return opt.length && opt.exists ? opt : exe;
}

/// The installer program `/update` runs (null for other).
string installer(Channel c) pure
{
    final switch (c)
    {
        case Channel.npm: return "npm";
        case Channel.brew: return "brew";
        case Channel.other: return null;
    }
}

/// The installer's arguments that install the latest release.
string[] installArgs(Channel c) pure
{
    final switch (c)
    {
        case Channel.npm: return ["install", "-g", npmPackage ~ "@latest"];
        case Channel.brew: return ["upgrade", brewFormula];
        case Channel.other: return null;
    }
}

/// The tap that serves `brewFormula`.
enum brewTap = "nanobpm/tap";

/// One command `/update` runs.
struct InstallStep
{
    string program;
    string[] args;
    string[string] env; /// added to the inherited environment
}

/// Homebrew settings for the upgrade: no `brew update` of every tap, no
/// upgrading or reinstalling of other formulae that depend on upgraded ones,
/// no periodic cleanup of unrelated formulae's old kegs and cache, no hints.
/// Only used once our own tap has been refreshed.
immutable string[string] quietBrewEnv;
shared static this()
{
    quietBrewEnv = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
    ];
}

/// What `/update` runs. A brew install whose tap checkout is known
/// (`tapRepo`) refreshes just that tap, then upgrades with `quietBrewEnv`, so
/// the update touches nano-coder and nothing else. Without it, plain
/// `brew upgrade` (brew refreshes every tap itself). A failed refresh stops
/// before the upgrade: running plain `brew upgrade` there would re-enable the
/// all-tap auto-update and dependents check, and could mask the failure.
InstallStep[] installSteps(Channel c, string tapRepo)
{
    if (c == Channel.other) return null;
    if (c == Channel.brew && tapRepo.length)
        return [InstallStep("git", ["-C", tapRepo, "pull", "--ff-only", "--quiet"]),
            InstallStep(installer(c), installArgs(c), quietBrewEnv.dup)];
    return [InstallStep(installer(c), installArgs(c))];
}

/// The local checkout of `brewTap` (`brew --repository`), or null when it is
/// missing or not a git checkout. Throws when brew cannot be run.
string brewTapRepo()
{
    import std.process : execute;
    import std.file : exists;
    import std.path : buildPath;
    auto r = execute(["brew", "--repository", brewTap]);
    if (r.status != 0) return null;
    auto dir = r.output.strip;
    return dir.length && exists(buildPath(dir, ".git")) ? dir : null;
}

/// The update command for a channel ("" for other).
string installCommand(Channel c) pure { return c == Channel.other ? "" : installer(c) ~ " " ~ installArgs(c).joinWords; }

/// Where the channel's latest version is read (null for other).
string latestUrl(Channel c) pure
{
    final switch (c)
    {
        case Channel.npm: return npmLatestUrl;
        case Channel.brew: return brewFormulaUrl;
        case Channel.other: return null;
    }
}

private string joinWords(string[] a) pure { import std.algorithm : map; import std.array : join; return a.map!shellWord.join(" "); }

/// A word as a POSIX shell would need it to round-trip: bare when it holds
/// only safe characters, otherwise single-quoted (embedded `'` as `'\''`).
string shellWord(string w) pure
{
    import std.algorithm : all;
    import std.array : replace;
    import std.ascii : isAlphaNum;
    if (w.length && w.all!(c => c.isAlphaNum || "-_./=:@%+,".canFindChar(c))) return w;
    return "'" ~ w.replace("'", "'\\''") ~ "'";
}

private bool canFindChar(string set, dchar c) pure { foreach (d; set) if (d == c) return true; return false; }

/// The step as a copy-pasteable shell command: its environment overrides
/// (sorted, as `K=V` prefixes) then the program and arguments, so a manual
/// retry reproduces exactly what `/update` ran.
string stepCommand(InstallStep step)
{
    import std.algorithm : sort;
    import std.array : array;
    string s;
    foreach (k; step.env.keys.array.sort) s ~= k ~ "=" ~ shellWord(step.env[k]) ~ " ";
    return s ~ shellWord(step.program) ~ " " ~ step.args.joinWords;
}

/// Checks are off by environment.
bool disabledByEnv()
{
    import std.process : environment;
    foreach (n; ["NANO_CODER_NO_UPDATE_CHECK", "NO_UPDATE_NOTIFIER"])
        if (environment.get(n, "").length) return true;
    return false;
}

bool isCi()
{
    import std.process : environment;
    return environment.get("CI", "").length > 0;
}

/// Whether `/update` may run: both ends a terminal, not CI.
bool updateAllowed(bool stdinTty, bool stdoutTty, bool ci) pure { return stdinTty && stdoutTty && !ci; }

/// What a check remembers between runs.
struct State
{
    long lastCheck; /// Unix seconds; 0 = never
    string latestKnown, hinted;

    JSONValue toJson() pure const
    {
        JSONValue j = parseJSON("{}");
        if (lastCheck) j["last_check"] = lastCheck;
        if (latestKnown.length) j["latest_known"] = latestKnown;
        if (hinted.length) j["hinted"] = hinted;
        return j;
    }

    static State fromJson(JSONValue j) pure
    {
        State s;
        if (j.type != JSONType.object) return s;
        if (auto v = "last_check" in j) if (v.type == JSONType.integer) s.lastCheck = v.integer;
        if (auto v = "latest_known" in j) if (v.type == JSONType.string) s.latestKnown = v.str;
        if (auto v = "hinted" in j) if (v.type == JSONType.string) s.hinted = v.str;
        return s;
    }
}

/// `<data dir>/nano-coder/update-check.json`.
string defaultStatePath()
{
    import std.path : buildPath, expandTilde;
    import std.process : environment;
    version (OSX) auto base = buildPath(expandTilde("~"), "Library", "Application Support");
    else auto base = environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share"));
    return buildPath(base, "nano-coder", "update-check.json");
}

State loadState(string path)
{
    import std.file : readText;
    try return State.fromJson(parseJSON(readText(path)));
    catch (Exception) return State.init; // no state yet, or a corrupt file: start fresh
}

/// Written atomically; failures are ignored (the check is best-effort).
void saveState(string path, const State s)
{
    import std.file : mkdirRecurse, rename, remove, write;
    import std.path : dirName;
    import std.process : thisProcessID;
    auto tmp = format("%s.%s.tmp", path, thisProcessID);
    try
    {
        mkdirRecurse(path.dirName);
        write(tmp, s.toJson.jsonPretty ~ "\n");
        rename(tmp, path);
    }
    // update state is a cache; failing to save it means checking again sooner
    catch (Exception) { try remove(tmp); catch (Exception) {} }
}

/// Whether release `candidate` is newer than `running`: dotted numbers
/// compared in order, and a release beats a pre-release of the same numbers.
bool isNewer(string candidate, string running) pure
{
    static void parse(string v, out ulong[] nums, out bool pre)
    {
        import std.algorithm : findSplit, splitter;
        import std.conv : to;
        v = v.strip;
        while (v.length && (v[0] == 'v' || v[0] == 'V')) v = v[1 .. $];
        auto core = v.findSplit("+")[0];
        auto parts = core.findSplit("-");
        pre = parts[2].length > 0 || parts[1].length > 0;
        foreach (p; parts[0].splitter('.'))
        {
            ulong n;
            try n = p.to!ulong; catch (Exception) n = 0; // a non-numeric part sorts as 0
            nums ~= n;
        }
    }
    ulong[] c, r;
    bool cp, rp;
    parse(candidate, c, cp);
    parse(running, r, rp);
    foreach (i; 0 .. c.length > r.length ? c.length : r.length)
    {
        auto a = i < c.length ? c[i] : 0, b = i < r.length ? r[i] : 0;
        if (a != b) return a > b;
    }
    return rp && !cp;
}

/// Records a check's result; the version to hint, if it's newer and not yet hinted.
string probeOutcome(ref State s, string running, string latest, long now) pure
{
    s.lastCheck = now;
    if (!latest.length || !isNewer(latest, running)) return null;
    s.latestKnown = latest;
    return s.hinted == latest ? null : latest;
}

/// The latest version the channel's source at `url` reports (npm's registry
/// JSON, or the tap formula's download URL), or null (offline, bad answer).
string fetchLatest(Channel channel, string url)
{
    import core.time : seconds;
    import nano.http : Request, perform;
    Request req;
    req.method = "GET";
    req.url = url;
    req.headers = ["Accept": "application/json", "User-Agent": "nano-coder (https://github.com/nanobpm/nano-coder)"];
    req.connectTimeout = 5.seconds;
    req.idleTimeout = 5.seconds;
    try
    {
        string body_;
        if (perform(req, body_) != 200) return null;
        if (channel == Channel.brew) return formulaVersion(body_);
        auto j = parseJSON(body_);
        if (auto v = "version" in j) if (v.type == JSONType.string && v.str.strip.length) return v.str.strip;
    }
    catch (Exception) {} // offline or a bad response: no update notice
    return null;
}

/// The update checker: state plus the hint waiting for an idle prompt. The
/// background thread owns one; `/update` makes its own for a forced check.
/// Both re-read the state file before changing it, so neither undoes the
/// other's record.
final class Checker
{
    private State state;
    private string statePath, running, url, hint;
    private long nextDue;
    Channel channel;

    this(Channel channel, string statePath, string running, string url = null, long now = unixNow())
    {
        this.channel = channel;
        this.statePath = statePath;
        this.running = running;
        this.url = url.length ? url : latestUrl(channel);
        state = loadState(statePath);
        // A restart inside the interval waits out the rest of it.
        nextDue = state.lastCheck && now - state.lastCheck < checkIntervalSecs ? state.lastCheck + checkIntervalSecs : now;
        // A newer version found earlier and not yet hinted is hinted now.
        if (channel != Channel.other && state.latestKnown.length && isNewer(state.latestKnown, running)
            && state.hinted != state.latestKnown)
            hint = state.latestKnown;
    }

    /// The newest known release, when newer than this one.
    string latestKnown() pure
    {
        return state.latestKnown.length && isNewer(state.latestKnown, running) ? state.latestKnown : null;
    }

    bool hintPending() pure { return hint.length > 0; }

    /// The hint text, once per version (remembered as hinted).
    string takeHint()
    {
        if (!hint.length) return null;
        auto v = hint;
        hint = null;
        state = loadState(statePath);
        state.hinted = v;
        saveState(statePath, state);
        return format("nano-coder %s is available (you have %s) — /update to install it", v, running);
    }

    /// Checks when due (or `force`); returns the registry's latest version.
    string check(bool force, long now = unixNow())
    {
        if (!force && now < nextDue) return latestKnown();
        auto latest = fetchLatest(channel, url);
        state = loadState(statePath);
        auto found = probeOutcome(state, running, latest, now);
        saveState(statePath, state);
        nextDue = now + checkIntervalSecs;
        if (found.length) hint = found;
        return latest;
    }

    /// Seconds until the next check is due.
    long dueIn(long now = unixNow()) pure { return saturatingSub(nextDue, now); }
}

long unixNow()
{
    import std.datetime.systime : Clock;
    return wallNow.toUnixTime;
}

/// The background checker's thread: checks whenever one is due and sends
/// each hint to `hints` (shown at the next idle prompt).
void runChecker(Channel channel, string statePath, string running, Chan!string hints)
{
    import core.thread : Thread;
    import core.time : seconds;
    auto c = new Checker(channel, statePath, running);
    for (;;)
    {
        if (auto h = c.takeHint()) hints.put(h);
        auto wait = c.dueIn();
        if (wait > 0) sleepFor(wait.seconds);
        c.check(false);
    }
}

/// Starts the background checker; its hints arrive on the returned channel.
Chan!string startChecker(Channel channel, string running)
{
    import nano.safeio : spawnDaemon;
    auto hints = Chan!string.make;
    spawnDaemon(&runChecker, channel, defaultStatePath(), running, hints);
    return hints;
}

/// `/update`'s outcome: lines to print.
string[] runInstaller(Channel channel, string exe, string running,
    int delegate(string program, string[] args, const string[string] env) @safe runner,
    string delegate(string exe) @safe versionOf = null, string delegate() @safe tapRepoOf = null)
{
    if (channel == Channel.other)
        return [format("This nano-coder was not installed with npm or Homebrew (install channel: other), so it cannot update itself. "
            ~ "Download the latest release from %s — a locally built binary is never overwritten.", releasesUrl)];
    auto program = installer(channel);
    if (which(program) is null)
        return [format("`%s` is not on PATH, so nano-coder cannot run the update itself. Install it manually with: %s",
            program, installCommand(channel))];
    string tapRepo;
    string shown = installCommand(channel);
    InstallStep[] steps;
    int status;
    // One catch for every process this runs: brew --repository, git, the installer.
    try
    {
        if (channel == Channel.brew)
        {
            // Name the lookup itself if it throws; the loop below then
            // replaces `shown` with each step it actually runs.
            shown = "brew --repository " ~ brewTap;
            tapRepo = tapRepoOf is null ? brewTapRepo() : tapRepoOf();
        }
        steps = installSteps(channel, tapRepo);
        foreach (i, step; steps)
        {
            shown = stepCommand(step);
            // A failed tap refresh (offline, diverged tap, or git missing so
            // the spawn throws) stops the update before any brew run: plain
            // `brew upgrade` would re-enable the all-tap auto-update and
            // dependents check. A spawn failure reaches the catch below with
            // its message intact.
            status = runner(step.program, step.args, step.env);
            if (status != 0) break;
        }
    }
    catch (Exception e) return [format("Could not run `%s`: %s; the running session is unchanged.", shown, e.msg)];
    if (status != 0)
        return [format("`%s` exited with status %s; the running session is unchanged. Try it by hand to see the full error: %s",
            shown, status, shown)];
    auto v = versionOf is null ? installedVersion(exe) : versionOf(exe);
    if (v is null)
        return ["The installer finished but the installed `nano-coder --version` could not be read; the running session is unchanged."];
    auto bare = v;
    while (bare.length && (bare[0] == 'v' || bare[0] == 'V')) bare = bare[1 .. $];
    if (bare != running)
        return [format("Updated to %s — /relaunch to restart into it; your session will resume.", v)];
    return [format("The installer succeeded but `nano-coder --version` still reports %s (this process is %s). "
        ~ "The new version takes effect on the next start.", v, running)];
}

/// Runs the installer attached to the terminal; its exit status.
int spawnInstaller(string program, string[] args, const string[string] env)
{
    import std.process : spawnProcess, wait;
    return wait(spawnProcess([program] ~ args, env));
}

/// `exe --version`'s version, or null.
string installedVersion(string exe)
{
    import std.process : execute;
    import std.algorithm : findSplit;
    try
    {
        auto r = execute([exe, "--version"]);
        if (r.status != 0) return null;
        auto t = r.output.strip;
        if (!t.startsWith("nano-coder ")) return null;
        return t["nano-coder ".length .. $].findSplit(" ")[0];
    }
    catch (Exception) return null; // not runnable or not ours: unknown version
}

/// `program` on PATH, or null.
string which(string program)
{
    import std.algorithm : splitter;
    import std.path : buildPath;
    import std.process : environment;
    import std.file : exists, isFile, getAttributes;
    import std.conv : octal;
    foreach (dir; environment.get("PATH", "").splitter(':'))
    {
        if (!dir.length) continue;
        auto p = buildPath(dir, program);
        try if (p.exists && p.isFile && (getAttributes(p) & octal!111)) return p;
        catch (Exception) {} // unreadable entry on PATH: keep looking
    }
    return null;
}

/// The relaunch argv (without argv[0]): the original arguments with any
/// `--resume`/`--continue` replaced by `--resume <session>`.
string[] relaunchArgv(const string[] argv, string session) pure
{
    string[] out_;
    for (size_t i = 0; i < argv.length; ++i)
    {
        auto a = argv[i];
        if (a == "--resume" || a == "--continue")
        {
            if (i + 1 < argv.length && !argv[i + 1].startsWith("-")) ++i;
            continue;
        }
        if (a.startsWith("--resume=") || a.startsWith("--continue=")) continue;
        out_ ~= a;
    }
    if (session.startsWith("-")) out_ ~= "--resume=" ~ session;
    else out_ ~= ["--resume", session];
    return out_;
}


// rust: update.rs::detects_the_npm_channel_in_both_launcher_states
// rust: update.rs::detects_the_npm_channel_through_the_global_bin_symlink
// rust: update.rs::standalone_and_dev_builds_are_unmanaged
unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, write, symlink, exists;
    import std.path : buildPath;
    assert(channelFor("/usr/lib/node_modules/@nanobpm/nano-coder/bin/nano-coder") == Channel.npm);
    assert(channelFor("/usr/lib/node_modules/@nanobpm/nano-coder-darwin-arm64/bin/nano-coder") == Channel.npm);
    assert(channelFor("/home/u/src/nano-coder/d/nano-coder") == Channel.other);
    assert(channelFor("/opt/nano/nano-coder") == Channel.other);
    assert(channelFor("") == Channel.other);
    // Through the global bin symlink (macOS reports the link, not its target).
    auto root = buildPath(tempDir, "nano-d-update-chan");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto pkg = buildPath(root, "lib", "node_modules", "@nanobpm", "nano-coder", "bin");
    mkdirRecurse(pkg);
    mkdirRecurse(buildPath(root, "bin"));
    write(buildPath(pkg, "nano-coder"), "");
    symlink(buildPath(pkg, "nano-coder"), buildPath(root, "bin", "nano-coder"));
    assert(channelFor(buildPath(root, "bin", "nano-coder")) == Channel.npm);
}

// rust: update.rs::version_comparison_orders_dotted_releases
unittest
{
    assert(isNewer("0.2.0", "0.1.9") && isNewer("1.0.0", "0.99.99") && isNewer("v0.1.10", "0.1.9"));
    assert(!isNewer("0.1.0", "0.1.0") && !isNewer("0.1.0", "0.2.0"));
    assert(isNewer("0.2.0", "0.2.0-rc.1") && !isNewer("0.2.0-rc.1", "0.2.0"));
    assert(isNewer("0.2.1-rc.1", "0.2.0") && isNewer("1.0", "0.9.9") && !isNewer("1.0", "1.0.0"));
}

// rust: update.rs::probe_hints_only_for_newer_unhinted_versions
// rust: update.rs::state_round_trips_through_json, update.rs::save_state_leaves_no_temp_file_and_round_trips
unittest
{
    import std.file : tempDir;
    import std.path : buildPath;
    State s;
    assert(probeOutcome(s, "0.1.0", "0.2.0", 100) == "0.2.0" && s.lastCheck == 100 && s.latestKnown == "0.2.0");
    s.hinted = "0.2.0";
    assert(probeOutcome(s, "0.1.0", "0.2.0", 200) is null);
    assert(probeOutcome(s, "0.1.0", "0.1.0", 300) is null && s.latestKnown == "0.2.0");
    assert(probeOutcome(s, "0.1.0", null, 400) is null && s.lastCheck == 400);
    auto back = State.fromJson(parseJSON(s.toJson.toString));
    assert(back == s);
    assert(State.fromJson(parseJSON(`{}`)) == State.init);
    auto p = buildPath(tempDir, "nano-d-update-state", "update-check.json");
    saveState(p, s);
    assert(loadState(p) == s);
    import std.file : dirEntries, SpanMode;
    import std.algorithm : count;
    assert(dirEntries(buildPath(tempDir, "nano-d-update-state"), SpanMode.shallow).count == 1, "no temp file left");
    assert(loadState(p ~ ".missing") == State.init);
}

// rust: update.rs::a_restart_inside_the_interval_defers_the_startup_check
// rust: update.rs::a_failed_check_is_silent_and_cheap
// rust: update.rs::a_restart_re_arms_a_pending_hint_from_the_persisted_state, update.rs::an_unmanaged_install_never_inherits_a_cached_hint
unittest
{
    import std.file : tempDir, remove;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "nano-d-update-defer.json");
    State s;
    s.lastCheck = 1000;
    s.latestKnown = "0.3.0";
    saveState(p, s);
    scope (exit) remove(p);
    auto c = new Checker(Channel.npm, p, "0.1.0", "http://127.0.0.1:9/latest", 1000 + 60);
    assert(c.dueIn(1060) == checkIntervalSecs - 60);
    // A version known from before and not yet hinted is hinted once.
    assert(c.hintPending());
    assert(!new Checker(Channel.other, p, "0.1.0", "x", 1060).hintPending(), "an unmanaged install never hints");
    auto h = c.takeHint();
    assert(h == "nano-coder 0.3.0 is available (you have 0.1.0) — /update to install it", h);
    assert(c.takeHint() is null && loadState(p).hinted == "0.3.0");
    // Not due: answered from the cache, no request.
    assert(c.check(false, 1100) == "0.3.0");
    // A forced check against nothing fails quietly and records the attempt.
    assert(c.check(true, 2000) is null && !c.hintPending() && loadState(p).lastCheck == 2000);
    assert(new Checker(Channel.npm, p, "0.1.0", "x", 2000 + checkIntervalSecs).dueIn(2000 + checkIntervalSecs) == 0);
}

// rust: update.rs::update_outcome_messages_cover_every_path
// rust: update.rs::a_failing_installer_reports_and_changes_nothing
unittest
{
    import std.algorithm : canFind;
    int ran;
    int delegate(string, string[], const string[string]) @safe ok = (string p, string[] a, const string[string] e) { ran++; assert(e is null); assert(a == ["install", "-g", npmPackage ~ "@latest"]); return 0; };
    auto other = runInstaller(Channel.other, "/x", "0.1.0", ok);
    assert(other[0].canFind("install channel: other") && other[0].canFind(releasesUrl) && !ran);
    if (which("npm") is null) return; // the rest needs npm on PATH
    assert(runInstaller(Channel.npm, "/x", "0.1.0", (string p, string[] a, const string[string] e) @safe => 1)[0].canFind("unchanged"));
    assert(runInstaller(Channel.npm, "/x", "0.1.0", ok, (string e) @safe => "0.2.0")[0].canFind("Updated to 0.2.0 — /relaunch"));
    assert(runInstaller(Channel.npm, "/x", "0.1.0", ok, (string e) @safe => "0.1.0")[0].canFind("still reports 0.1.0"));
    assert(runInstaller(Channel.npm, "/x", "0.1.0", ok, (string e) @safe => cast(string) null)[0].canFind("could not be read"));
}

// rust: update.rs::relaunch_argv_replaces_resume_and_continue
// rust: update.rs::relaunch_argv_uses_the_attached_form_for_dash_prefixed_ids
// rust: main.rs::update_is_refused_outside_an_interactive_non_ci_terminal
unittest
{
    assert(relaunchArgv(["--model", "m/x", "--resume", "old", "--yolo"], "new") == ["--model", "m/x", "--yolo", "--resume", "new"]);
    assert(relaunchArgv(["--continue", "--yolo"], "s") == ["--yolo", "--resume", "s"]);
    assert(relaunchArgv(["--resume=old", "--continue=x"], "s") == ["--resume", "s"]);
    assert(relaunchArgv([], "-dash") == ["--resume=-dash"]);
    assert(updateAllowed(true, true, false) && !updateAllowed(false, true, false));
    assert(!updateAllowed(true, false, false) && !updateAllowed(true, true, true));
}

version (unittest) private string fakeRegistryDir(string tag)
{
    import std.file : tempDir, mkdirRecurse, exists, rmdirRecurse;
    import std.path : buildPath;
    import std.process : thisProcessID;
    auto dir = buildPath(tempDir, format("nano-d-update-%s-%s", tag, thisProcessID));
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

// rust: update.rs::check_against_a_fake_registry_hints_once_and_caches
unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import nano.testserver : serve, Reply;
    auto srv = serve([immutable Reply(200, "content-type: application/json\r\n", `{"version":"0.43.0"}`)]);
    auto dir = fakeRegistryDir("hint");
    scope (exit) rmdirRecurse(dir);
    auto state = buildPath(dir, "state.json");
    auto checker = new Checker(Channel.npm, state, "0.42.1", srv.url ~ "/latest");
    assert(checker.check(true) == "0.43.0");
    srv.finish();
    auto hint = checker.takeHint();
    assert(hint.canFind("0.43.0 is available (you have 0.42.1)") && hint.canFind("/update"), hint);
    assert(checker.takeHint() is null, "hinted once");
    // Persisted: a restarted process knows the version and doesn't re-hint it.
    auto restarted = new Checker(Channel.npm, state, "0.42.1", "http://127.0.0.1:9/unused");
    assert(restarted.latestKnown == "0.43.0");
    assert(restarted.takeHint() is null, "already hinted before the restart");
}

// rust: update.rs::force_check_reports_the_current_version_when_up_to_date
unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import nano.testserver : serve, Reply;
    foreach (reported; ["0.42.1", "0.40.0"])
    {
        auto srv = serve([immutable Reply(200, "content-type: application/json\r\n", `{"version":"` ~ reported ~ `"}`)]);
        auto dir = fakeRegistryDir("current");
        scope (exit) rmdirRecurse(dir);
        auto checker = new Checker(Channel.npm, buildPath(dir, "s.json"), "0.42.1", srv.url ~ "/latest");
        assert(checker.check(true) == reported, "/update can say up to date");
        srv.finish();
        assert(checker.latestKnown is null, "the hint cache stays newer-only");
        assert(checker.takeHint() is null);
    }
}

// rust: update.rs::a_brew_check_reads_the_tap_formula
unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;
    import std.path : buildPath;
    import nano.testserver : serve, Reply;
    auto srv = serve([immutable Reply(200, "content-type: text/plain\r\n",
        "url \"https://github.com/nanobpm/nano-coder/releases/download/v0.43.0/nano-coder-0.43.0-x86_64-apple-darwin.tar.gz\"\n")]);
    auto dir = fakeRegistryDir("brew");
    scope (exit) rmdirRecurse(dir);
    auto checker = new Checker(Channel.brew, buildPath(dir, "s.json"), "0.42.1", srv.url ~ "/nano-coder.rb");
    assert(checker.check(true) == "0.43.0");
    srv.finish();
    assert(checker.takeHint().canFind("0.43.0 is available"));
}

// rust: update.rs::a_keg_path_maps_to_the_stable_opt_link
unittest
{
    assert(brewOptExe("/home/linuxbrew/.linuxbrew/Cellar/nano-coder/0.67.0/bin/nano-coder")
        == "/home/linuxbrew/.linuxbrew/opt/nano-coder/bin/nano-coder");
    assert(brewOptExe("/opt/homebrew/bin/nano-coder") is null);
    assert(brewOptExe("/opt/homebrew/Cellar/other/1.0/bin/nano-coder") is null);
    assert(brewOptExe("nano-coder") is null);
}

// rust: update.rs::detects_the_brew_channel_on_versioned_keg_paths
unittest
{
    assert(channelFor("/home/linuxbrew/.linuxbrew/Cellar/nano-coder/0.67.0/bin/nano-coder") == Channel.brew);
    assert(channelFor("/opt/homebrew/Cellar/nano-coder/0.67.0/bin/nano-coder") == Channel.brew);
    assert(channelFor("/opt/homebrew/Cellar/nano-coder-x/1.0/bin/nano-coder") == Channel.other, "another formula's keg");
}

// rust: update.rs::detects_the_brew_channel_through_the_bin_and_opt_links
unittest
{
    import std.file : mkdirRecurse, write, symlink, rmdirRecurse;
    import std.path : buildPath;
    auto dir = fakeRegistryDir("brewlinks");
    scope (exit) rmdirRecurse(dir);
    auto kegBin = buildPath(dir, "Cellar/nano-coder/0.67.0/bin");
    mkdirRecurse(kegBin);
    write(buildPath(kegBin, "nano-coder"), "");
    mkdirRecurse(buildPath(dir, "bin"));
    symlink("../Cellar/nano-coder/0.67.0/bin/nano-coder", buildPath(dir, "bin/nano-coder"));
    assert(channelFor(buildPath(dir, "bin/nano-coder")) == Channel.brew);
    mkdirRecurse(buildPath(dir, "opt"));
    symlink("../Cellar/nano-coder/0.67.0", buildPath(dir, "opt/nano-coder"));
    assert(channelFor(buildPath(dir, "opt/nano-coder/bin/nano-coder")) == Channel.brew);
}

// rust: update.rs::the_brew_channel_upgrades_the_tap_formula
unittest
{
    assert(installCommand(Channel.brew) == "brew upgrade nanobpm/tap/nano-coder");
    assert(latestUrl(Channel.brew) == brewFormulaUrl);
    assert(installCommand(Channel.npm) == "npm install -g @nanobpm/nano-coder@latest");
    assert(installCommand(Channel.other) == "");
}

// /update on brew refreshes only our tap, then upgrades without brew's
// auto-update, dependents upgrades, or cleanup; a failed refresh stops
// before the upgrade; unknown tap: plain `brew upgrade`.
unittest
{
    import std.algorithm : canFind;
    auto steps = installSteps(Channel.brew, "/tap");
    assert(steps.length == 2);
    assert(steps[0].program == "git" && steps[0].args == ["-C", "/tap", "pull", "--ff-only", "--quiet"] && steps[0].env is null);
    assert(steps[1].program == "brew" && steps[1].args == ["upgrade", brewFormula]);
    assert(steps[1].env["HOMEBREW_NO_AUTO_UPDATE"] == "1" && steps[1].env["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] == "1");
    assert(steps[1].env["HOMEBREW_NO_INSTALL_CLEANUP"] == "1" && steps[1].env["HOMEBREW_NO_ENV_HINTS"] == "1");
    auto plain = installSteps(Channel.brew, null);
    assert(plain.length == 1 && plain[0].args == ["upgrade", brewFormula] && plain[0].env is null);
    assert(stepCommand(plain[0]) == "brew upgrade " ~ brewFormula);
    assert(stepCommand(steps[0]) == "git -C /tap pull --ff-only --quiet");
    assert(stepCommand(steps[1]) == "HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 "
        ~ "HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade " ~ brewFormula);
    auto spaced = installSteps(Channel.brew, "/opt/home brew/tap");
    assert(stepCommand(spaced[0]) == "git -C '/opt/home brew/tap' pull --ff-only --quiet");
    assert(shellWord("it's") == `'it'\''s'` && shellWord("") == "''" && shellWord("a b") == "'a b'");
    assert(stepCommand(InstallStep("my prog", ["x"], ["K": "a b"])) == "K='a b' 'my prog' x");
    assert(installSteps(Channel.npm, "/tap").length == 1 && installSteps(Channel.other, "/tap") is null);
    if (which("brew") is null) return; // runInstaller needs brew on PATH
    string[] ran;
    auto rec = (string p, string[] a, const string[string] e) @safe { ran ~= p; return p == "git" ? 1 : 0; };
    auto out_ = runInstaller(Channel.brew, "/x", "0.1.0", rec, (string e) @safe => "0.2.0", () @safe => "/tap");
    assert(ran == ["git"], "a failed tap refresh stops before brew upgrade");
    assert(out_[0].canFind("git -C /tap pull") && out_[0].canFind("unchanged"), out_[0]);
    ran = null;
    auto failing = (string p, string[] a, const string[string] e) @safe { ran ~= p; return 1; };
    out_ = runInstaller(Channel.brew, "/x", "0.1.0", failing, (string e) @safe => "0.2.0", () @safe => "/tap");
    assert(ran == ["git"], "brew never runs when the tap refresh failed");
    assert(out_[0].canFind("git -C /tap pull") && out_[0].canFind("unchanged"), out_[0]);
    assert(!out_[0].canFind("full error: brew"), "the retry hint names the failed refresh, not brew upgrade");
    ran = null;
    auto noGit = (string p, string[] a, const string[string] e) @safe {
        ran ~= p; if (p == "git") throw new Exception("git: not found"); return 0; };
    out_ = runInstaller(Channel.brew, "/x", "0.1.0", noGit, (string e) @safe => "0.2.0", () @safe => "/tap");
    assert(ran == ["git"], "git missing from PATH stops before brew upgrade too");
    assert(out_[0].canFind("Could not run `git -C /tap pull") && out_[0].canFind("git: not found")
        && out_[0].canFind("unchanged") && !out_[0].canFind("status -1"), out_[0]);
    // No tap checkout (tapRepo null): plain `brew upgrade` is the only step.
    ran = null;
    auto plainRun = (string p, string[] a, const string[string] e) @safe { ran ~= p; return 0; };
    out_ = runInstaller(Channel.brew, "/x", "0.1.0", plainRun, (string e) @safe => "0.2.0", () @safe => cast(string) null);
    assert(ran == ["brew"], "no tap checkout: plain brew upgrade");
    assert(out_[0].canFind("Updated to 0.2.0"), out_[0]);
    // A throwing tap lookup is reported as the lookup, not the unattempted upgrade.
    ran = null;
    out_ = runInstaller(Channel.brew, "/x", "0.1.0", plainRun, (string e) @safe => "0.2.0",
        delegate string() @safe { throw new Exception("lookup boom"); });
    assert(ran is null, "nothing runs when the tap lookup throws");
    assert(out_[0].canFind("Could not run `brew --repository " ~ brewTap ~ "`") && out_[0].canFind("lookup boom"), out_[0]);
}

// rust: update.rs::the_formula_version_is_read_from_its_download_url
unittest
{
    auto formula = "class NanoCoder < Formula\n  on_macos do\n    on_arm do\n"
        ~ "      url \"https://github.com/nanobpm/nano-coder/releases/download/v0.68.1/nano-coder-0.68.1-aarch64-apple-darwin.tar.gz\"\n";
    assert(formulaVersion(formula) == "0.68.1");
    assert(formulaVersion("class NanoCoder < Formula\nend\n") is null);
}
