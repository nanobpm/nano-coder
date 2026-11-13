/// Background update check, `/update` and `/relaunch` (update.rs, Rust #154
/// and #172). Interactive terminal sessions only (never `-p`, ACP or CI):
/// a check at startup and then hourly, in the background; the last check and
/// the latest known version persist in `<data dir>/nano-coder-d/
/// update-check.json`, so a quick restart doesn't check again. A newer
/// release gives one hint per version, at an idle prompt. Offline, the check
/// fails quietly within five seconds. `check_updates = false` or
/// `NANO_CODER_NO_UPDATE_CHECK` / `NO_UPDATE_NOTIFIER` turn it off.
///
/// The D port ships only through npm (`@nanobpm/nano-coder-d`), so there is
/// no cargo channel: anything else (a release tarball, a dev build) is
/// "other" and is never changed by `/update`.
module nano.update;

@safe:

import std.json;
import std.format : format;
import std.string : strip;
import std.algorithm.searching : startsWith;
import nano.safeio : Chan;

/// How often a running session checks again.
enum long checkIntervalSecs = 60 * 60;
enum npmPackage = "@nanobpm/nano-coder-d";
enum npmLatestUrl = "https://registry.npmjs.org/" ~ npmPackage ~ "/latest";
enum releasesUrl = "https://github.com/nanobpm/nano-coder/releases";

/// How this binary was installed, so `/update` knows what may replace it.
enum Channel { npm, other }

/// The channel for an executable path: npm when it, or the file it links to,
/// lies under a `node_modules/@nanobpm/` tree (macOS reports the global bin
/// symlink npm launched it through: Rust #172).
Channel channelFor(string exe)
{
    import nano.paths : resolveSymlinks;
    foreach (p; [exe, exe.length ? resolveSymlinks(exe) : null])
        if (hasComponents(p, ["node_modules", "@nanobpm"])) return Channel.npm;
    return Channel.other;
}

private bool hasComponents(string path, string[] want)
{
    import std.algorithm : splitter;
    import std.array : array;
    auto parts = path.splitter('/').array;
    if (parts.length < want.length) return false;
    foreach (i; 0 .. parts.length - want.length + 1)
        if (parts[i .. i + want.length] == want) return true;
    return false;
}

/// This process's executable.
string launchExe()
{
    import std.file : thisExePath;
    import std.string : chomp;
    try return thisExePath().chomp(" (deleted)");
    catch (Exception) return null;
}

/// The update command for a channel ("" for other).
string installCommand(Channel c) { return c == Channel.npm ? "npm " ~ installArgs(c).joinWords : ""; }
string[] installArgs(Channel c) { return c == Channel.npm ? ["install", "-g", npmPackage ~ "@latest"] : null; }

private string joinWords(string[] a) { import std.array : join; return a.join(" "); }

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
bool updateAllowed(bool stdinTty, bool stdoutTty, bool ci) { return stdinTty && stdoutTty && !ci; }

/// What a check remembers between runs.
struct State
{
    long lastCheck; /// Unix seconds; 0 = never
    string latestKnown, hinted;

    JSONValue toJson() const
    {
        JSONValue j = parseJSON("{}");
        if (lastCheck) j["last_check"] = lastCheck;
        if (latestKnown.length) j["latest_known"] = latestKnown;
        if (hinted.length) j["hinted"] = hinted;
        return j;
    }

    static State fromJson(JSONValue j)
    {
        State s;
        if (j.type != JSONType.object) return s;
        if (auto v = "last_check" in j) if (v.type == JSONType.integer) s.lastCheck = v.integer;
        if (auto v = "latest_known" in j) if (v.type == JSONType.string) s.latestKnown = v.str;
        if (auto v = "hinted" in j) if (v.type == JSONType.string) s.hinted = v.str;
        return s;
    }
}

/// `<data dir>/nano-coder-d/update-check.json`.
string defaultStatePath()
{
    import std.path : buildPath, expandTilde;
    import std.process : environment;
    version (OSX) auto base = buildPath(expandTilde("~"), "Library", "Application Support");
    else auto base = environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share"));
    return buildPath(base, "nano-coder-d", "update-check.json");
}

State loadState(string path)
{
    import std.file : readText;
    try return State.fromJson(parseJSON(readText(path)));
    catch (Exception) return State.init;
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
        write(tmp, s.toJson.toPrettyString ~ "\n");
        rename(tmp, path);
    }
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
            try n = p.to!ulong; catch (Exception) n = 0;
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
string probeOutcome(ref State s, string running, string latest, long now)
{
    s.lastCheck = now;
    if (!latest.length || !isNewer(latest, running)) return null;
    s.latestKnown = latest;
    return s.hinted == latest ? null : latest;
}

/// The latest version the registry reports, or null (offline, bad answer).
string fetchLatest(string url)
{
    import core.time : seconds;
    import nano.http : Request, perform;
    Request req;
    req.method = "GET";
    req.url = url;
    req.headers = ["Accept": "application/json", "User-Agent": "nano-coder-d (https://github.com/nanobpm/nano-coder)"];
    req.connectTimeout = 5.seconds;
    req.idleTimeout = 5.seconds;
    try
    {
        string body_;
        if (perform(req, body_) != 200) return null;
        auto j = parseJSON(body_);
        if (auto v = "version" in j) if (v.type == JSONType.string && v.str.strip.length) return v.str.strip;
    }
    catch (Exception) {}
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

    this(Channel channel, string statePath, string running, string url = npmLatestUrl, long now = unixNow())
    {
        this.channel = channel;
        this.statePath = statePath;
        this.running = running;
        this.url = url;
        state = loadState(statePath);
        // A restart inside the interval waits out the rest of it.
        nextDue = state.lastCheck && now - state.lastCheck < checkIntervalSecs ? state.lastCheck + checkIntervalSecs : now;
        // A newer version found earlier and not yet hinted is hinted now.
        if (channel != Channel.other && state.latestKnown.length && isNewer(state.latestKnown, running)
            && state.hinted != state.latestKnown)
            hint = state.latestKnown;
    }

    /// The newest known release, when newer than this one.
    string latestKnown()
    {
        return state.latestKnown.length && isNewer(state.latestKnown, running) ? state.latestKnown : null;
    }

    bool hintPending() { return hint.length > 0; }

    /// The hint text, once per version (remembered as hinted).
    string takeHint()
    {
        if (!hint.length) return null;
        auto v = hint;
        hint = null;
        state = loadState(statePath);
        state.hinted = v;
        saveState(statePath, state);
        return format("nano-coder-d %s is available (you have %s) — /update to install it", v, running);
    }

    /// Checks when due (or `force`); returns the registry's latest version.
    string check(bool force, long now = unixNow())
    {
        if (!force && now < nextDue) return latestKnown();
        auto latest = fetchLatest(url);
        state = loadState(statePath);
        auto found = probeOutcome(state, running, latest, now);
        saveState(statePath, state);
        nextDue = now + checkIntervalSecs;
        if (found.length) hint = found;
        return latest;
    }

    /// Seconds until the next check is due.
    long dueIn(long now = unixNow()) { return nextDue > now ? nextDue - now : 0; }
}

long unixNow()
{
    import std.datetime.systime : Clock;
    return Clock.currTime.toUnixTime;
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
        if (wait > 0) Thread.sleep(wait.seconds);
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
    int delegate(string program, string[] args) @safe runner, string delegate(string exe) @safe versionOf = null)
{
    if (channel == Channel.other)
        return [format("This nano-coder-d was not installed with npm (install channel: other), so it cannot update itself. "
            ~ "Download the latest release from %s — a locally built binary is never overwritten.", releasesUrl)];
    if (which("npm") is null)
        return [format("`npm` is not on PATH, so nano-coder-d cannot run the update itself. Install it manually with: %s",
            installCommand(channel))];
    int status;
    try status = runner("npm", installArgs(channel));
    catch (Exception e) return [format("Could not run `%s`: %s", installCommand(channel), e.msg)];
    if (status != 0)
        return [format("`%s` exited with status %s; the running session is unchanged. Try it by hand to see the full error: %s",
            installCommand(channel), status, installCommand(channel))];
    auto v = versionOf is null ? installedVersion(exe) : versionOf(exe);
    if (v is null)
        return ["The installer finished but the installed `nano-coder-d --version` could not be read; the running session is unchanged."];
    auto bare = v;
    while (bare.length && (bare[0] == 'v' || bare[0] == 'V')) bare = bare[1 .. $];
    if (bare != running)
        return [format("Updated to %s — /relaunch to restart into it; your session will resume.", v)];
    return [format("The installer succeeded but `nano-coder-d --version` still reports %s (this process is %s). "
        ~ "The new version takes effect on the next start.", v, running)];
}

/// Runs the installer attached to the terminal; its exit status.
int spawnInstaller(string program, string[] args)
{
    import std.process : spawnProcess, wait;
    return wait(spawnProcess([program] ~ args));
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
        if (!t.startsWith("nano-coder-d ")) return null;
        return t["nano-coder-d ".length .. $].findSplit(" ")[0];
    }
    catch (Exception) return null;
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
        catch (Exception) {}
    }
    return null;
}

/// The relaunch argv (without argv[0]): the original arguments with any
/// `--resume`/`--continue` replaced by `--resume <session>`.
string[] relaunchArgv(const string[] argv, string session)
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

version (unittest)
{
    import std.file : tempDir, exists, remove, mkdirRecurse, rmdirRecurse, write, symlink;
    import std.path : buildPath;
}

// rust: update.rs::detects_the_npm_channel_in_both_launcher_states
// rust: update.rs::detects_the_npm_channel_through_the_global_bin_symlink
// rust: update.rs::standalone_and_dev_builds_are_unmanaged
unittest
{
    assert(channelFor("/usr/lib/node_modules/@nanobpm/nano-coder-d/bin/nano-coder-d") == Channel.npm);
    assert(channelFor("/usr/lib/node_modules/@nanobpm/nano-coder-d-darwin-arm64/bin/nano-coder-d") == Channel.npm);
    assert(channelFor("/home/u/src/nano-coder/d/nano-coder-d") == Channel.other);
    assert(channelFor("/opt/nano/nano-coder-d") == Channel.other);
    assert(channelFor("") == Channel.other);
    // Through the global bin symlink (macOS reports the link, not its target).
    auto root = buildPath(tempDir, "nano-d-update-chan");
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto pkg = buildPath(root, "lib", "node_modules", "@nanobpm", "nano-coder-d", "bin");
    mkdirRecurse(pkg);
    mkdirRecurse(buildPath(root, "bin"));
    write(buildPath(pkg, "nano-coder-d"), "");
    symlink(buildPath(pkg, "nano-coder-d"), buildPath(root, "bin", "nano-coder-d"));
    assert(channelFor(buildPath(root, "bin", "nano-coder-d")) == Channel.npm);
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
// rust: update.rs::state_round_trips_through_json
unittest
{
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
    assert(loadState(p ~ ".missing") == State.init);
}

// rust: update.rs::a_restart_inside_the_interval_defers_the_startup_check
// rust: update.rs::a_failed_check_is_silent_and_cheap
unittest
{
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
    auto h = c.takeHint();
    assert(h == "nano-coder-d 0.3.0 is available (you have 0.1.0) — /update to install it", h);
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
    int delegate(string, string[]) @safe ok = (string p, string[] a) { ran++; assert(a == ["install", "-g", npmPackage ~ "@latest"]); return 0; };
    auto other = runInstaller(Channel.other, "/x", "0.1.0", ok);
    assert(other[0].canFind("install channel: other") && other[0].canFind(releasesUrl) && !ran);
    if (which("npm") is null) return; // the rest needs npm on PATH
    assert(runInstaller(Channel.npm, "/x", "0.1.0", (string p, string[] a) @safe => 1)[0].canFind("unchanged"));
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
