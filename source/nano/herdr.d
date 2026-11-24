/// Herdr integration (<https://herdr.dev/docs/add-herdr-support/>), port of
/// `herdr.rs`.
///
/// When nano-coder runs inside a Herdr pane it reports its state (idle,
/// working, blocked), the command that resumes the current session, and a
/// release on exit, by running `"$HERDR_BIN_PATH" pane report-agent …`.
/// Outside Herdr every call here is a no-op.
///
/// Reports never slow the agent down: they are handed to one background
/// thread that sends only the latest pending report and ignores failures.
module nano.herdr;

@safe:
import nano.clock : monoNow, sleepFor, wallNow;

import core.atomic : atomicLoad, atomicStore, cas;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : to;
import nano.safeio : Locked;

private enum source = "nano-coder";
/// The agent name Herdr shows for the pane.
private enum agent = "nano-coder";
/// The command a resume runs: this binary, not the Rust one.
enum resumeCommand = "nano-coder";
/// How long one report may run before it is abandoned.
private enum timeout = 2.seconds;
/// Herdr's limits on a resume command.
private enum maxResumeArgs = 64, maxResumeBytes = 8 * 1024;

enum State { idle, working, blocked }

/// Set to the pid of the nano-coder reporting to the Herdr pane; inherited by
/// every process it starts, so a nested nano-coder leaves the pane alone.
enum ownerVar = "NANO_CODER_HERDR_OWNER";

/// The pane this process reports to, from Herdr's environment.
struct Pane
{
    string bin, id;

    static Pane fromEnv(scope string delegate(string) @safe get, out bool found)
    {
        return fromEnv(get, 0, found);
    }

    /// ditto, for process `pid`: a pane already claimed by another
    /// nano-coder process (`ownerVar` set to a different pid) is not this
    /// process's, so a nested nano-coder (started from the bash tool, a hook
    /// or a script) doesn't report to, and release, its parent's pane. The
    /// same pid is the process itself after a `/relaunch` exec.
    static Pane fromEnv(scope string delegate(string) @safe get, long pid, out bool found)
    {
        found = false;
        if (get("HERDR_ENV") != "1") return Pane.init;
        auto owner = get(ownerVar);
        if (pid != 0 && owner.length && owner != pid.to!string) return Pane.init;
        auto bin = get("HERDR_BIN_PATH"), id = get("HERDR_PANE_ID");
        if (!bin.length || !id.length) return Pane.init;
        found = true;
        return Pane(bin, id);
    }
}

/// A session to report alongside a state: its ID and the argv that resumes it.
struct Session
{
    string id;
    immutable(string)[] resume;
}

/// The resume argv for `sessionId`, or null when Herdr would reject it
/// (apostrophes or control characters, too many arguments or bytes).
immutable(string)[] resumeArgv(string sessionId, string model, const string[] extra) pure
{
    import std.algorithm : any, canFind;
    import std.uni : isControl;
    immutable(string)[] argv = [resumeCommand, "--resume", sessionId];
    if (model.length) argv ~= ["--model", model];
    argv ~= extra.idup;
    size_t bytes;
    foreach (a; argv)
    {
        bytes += a.length;
        if (a.canFind('\'') || a.any!(c => isControl(c))) return null;
    }
    return argv.length <= maxResumeArgs && bytes <= maxResumeBytes ? argv : null;
}

/// The arguments (after the Herdr binary) for one state report.
string[] reportArgs(string pane, State state, ulong seq, string message) pure
{
    import std.uni : isControl;
    string[] args = ["pane", "report-agent", pane, "--source", source, "--agent", agent, "--state", state.to!string,
        "--seq", seq.to!string];
    if (message.length)
    {
        // Control characters dropped, at most 200 characters.
        string clean;
        size_t n;
        foreach (dchar c; message)
        {
            if (isControl(c)) continue;
            if (n++ == 200) break;
            clean ~= c.to!string;
        }
        args ~= ["--message", clean];
    }
    return args;
}

/// The arguments for a session report. Sent separately from the state
/// report because Herdr before 0.9.2 rejects the trailing resume argv: there
/// only this call fails, and state reports keep working.
string[] sessionArgs(string pane, ulong seq, const Session session) pure
{
    return ["pane", "report-agent-session", pane, "--source", source, "--agent", agent, "--seq", seq.to!string,
        "--agent-session-id", session.id, "--"] ~ session.resume.dup;
}

string[] releaseArgs(string pane, ulong seq) pure
{
    return ["pane", "release-agent", pane, "--source", source, "--agent", agent, "--seq", seq.to!string];
}

/// The model's short name: the part after the last `/`, so
/// `anthropic/claude-sonnet-4.5` shows as `claude-sonnet-4.5`.
string shortModel(string model) pure
{
    import std.string : lastIndexOf;
    auto slash = model.lastIndexOf('/');
    return slash < 0 ? model : model[slash + 1 .. $];
}

/// The arguments for a display-only metadata report: the agent shown as
/// `nano-coder · <model>`, plus a `model` token. An empty model clears both.
/// Metadata changes only what Herdr shows; state and session restore are
/// unaffected, and a Herdr without `report-metadata` just fails the call.
string[] metadataArgs(string pane, string model, string name = null) pure
{
    import std.uni : isControl;
    import std.algorithm : filter;
    import std.conv : text;
    string[] args = ["pane", "report-metadata", pane, "--source", source, "--agent", agent];
    string clean = model.filter!(c => !isControl(c)).text;
    string handle = name.filter!(c => !isControl(c)).text;
    // The session's handle (issue #300) names the pane in place of the
    // generic agent name, so two named sessions are told apart at a glance.
    auto who = handle.length ? handle : agent;
    string[] tokens = handle.length ? ["--token", "name=" ~ handle] : ["--clear-token", "name"];
    if (!clean.length && !handle.length) return args ~ ["--clear-display-agent", "--clear-token", "model", "--clear-token", "name"];
    if (!clean.length) return args ~ ["--display-agent", who, "--clear-token", "model"] ~ tokens;
    return args ~ ["--display-agent", who ~ " · " ~ clean, "--token", "model=" ~ clean] ~ tokens;
}

/// The pending metadata key for a handle and a model: one string, so the
/// reporter's repeat check and release logic treat both as one display.
/// Control characters are filtered from both on send, so `\n` separates.
private string metaKey(string name, string model) pure
{
    return name.length ? name ~ "\n" ~ model : model;
}

/// `metadataArgs` for a `metaKey`.
private string[] metadataFor(string pane, string key) pure
{
    import std.string : indexOf;
    auto nl = key.indexOf('\n');
    return nl < 0 ? metadataArgs(pane, key) : metadataArgs(pane, key[nl + 1 .. $], key[0 .. nl]);
}

unittest // a handle names the pane and rides as a token
{
    auto a = metadataArgs("p", "gpt-5", "perf");
    assert(a[$ - 6 .. $] == ["--display-agent", "perf · gpt-5", "--token", "model=gpt-5", "--token", "name=perf"], a[$ - 6 .. $].to!string);
    assert(metadataFor("p", metaKey("perf", "gpt-5")) == a);
    assert(metadataFor("p", metaKey(null, "gpt-5")) == metadataArgs("p", "gpt-5"));
    auto n = metadataArgs("p", null, "perf");
    assert(n[$ - 6 .. $] == ["--display-agent", "perf", "--clear-token", "model", "--token", "name=perf"], n.to!string);
}

/// The icon the `timer` token shows while a timer is set.
enum timerIcon = "⏰";

/// The arguments for the `timer` token: the icon while a timer is set,
/// cleared otherwise. Herdr shows it where the user's sidebar layout puts
/// `$timer`, for example next to `state_icon`; unset, it takes no space.
string[] timerArgs(string pane, bool on) pure
{
    string[] args = ["pane", "report-metadata", pane, "--source", source, "--agent", agent];
    return args ~ (on ? ["--token", "timer=" ~ timerIcon] : ["--clear-token", "timer"]);
}

/// A report waiting to be sent: sequence numbers for the state report and,
/// when the session changed, the session report that follows it.
private struct Queued
{
    ulong stateSeq;
    State state;
    string message;
    bool hasSession;
    ulong sessionSeq;
    Session session;
}

private struct Reporter
{
    Pane pane;
    /// The newest report not yet sent; older ones are overwritten. Its
    /// sequence number is taken when it is queued, so a report still in
    /// flight at exit carries a lower one than the release and Herdr
    /// ignores it.
    bool hasPending;
    Queued pending;
    /// The last state and session handed over, so repeats are skipped.
    bool hasLast;
    State lastState;
    string lastMessage;
    bool hasLastSession;
    Session lastSession;
    /// The last sequence number used; strictly increasing.
    ulong seq;
    /// The model to show, when it changed since the last metadata report.
    bool hasPendingModel;
    string pendingModel, lastModel;
    /// Whether `lastModel` holds a reported name, so a first empty name
    /// (a clear) is still sent rather than mistaken for a repeat.
    bool hasLastModel;
    /// The current handle and short model name, combined by `metaKey`.
    string curName, curModel;
    /// Whether a timer is set, when that changed since the last report.
    bool hasPendingTimer, pendingTimer, lastTimer;
    /// Whether `lastTimer` holds a reported state, so a first `false` is
    /// still sent (clearing an icon a previous process left behind).
    bool hasLastTimer;
    /// Set by `release`; no metadata is sent afterwards.
    bool released;
    /// A metadata send is running in the worker; `release` waits for it so
    /// its final clear cannot be overtaken by a stale model.
    bool modelInFlight;
}

/// The worker takes the pending model to send, unless the pane was released.
private bool takeModel(ref Reporter r, out string model)
{
    bool take = r.hasPendingModel && !r.released;
    r.hasPendingModel = false;
    if (take) { model = r.pendingModel; r.modelInFlight = true; }
    return take;
}

/// The worker takes the pending timer flag to send, unless the pane was
/// released.
private bool takeTimer(ref Reporter r, out bool on)
{
    bool take = r.hasPendingTimer && !r.released;
    r.hasPendingTimer = false;
    if (take) { on = r.pendingTimer; r.modelInFlight = true; }
    return take;
}

/// Start the release: nothing more is sent. Returns whether a model or the
/// timer icon is shown (so they must be cleared) and the release sequence
/// number.
private ulong beginRelease(ref Reporter r, out bool shown, out bool timerShown)
{
    r.released = true;
    // A pending model (even an empty one, i.e. a clear) may follow a shown
    // one, so it counts as shown: clearing an unshown model is harmless.
    shown = r.lastModel.length > 0 || r.modelInFlight || r.hasPendingModel;
    // A pending clear not yet sent may follow a shown icon: clear it anyway.
    timerShown = r.lastTimer || r.hasPendingTimer || r.modelInFlight;
    r.hasPending = r.hasPendingModel = r.hasPendingTimer = false;
    r.lastModel = null;
    r.hasLastModel = r.hasLastTimer = false;
    r.lastTimer = false;
    return nextSeq(r);
}

/// Undo a release whose exit did not happen (a failed relaunch): reporting
/// starts afresh, so the next state, session, model and timer are all sent
/// again.
private void endRelease(ref Reporter r)
{
    r.released = false;
    r.hasLast = r.hasLastSession = r.hasLastModel = r.hasLastTimer = false;
    r.lastModel = null;
    r.lastTimer = false;
}

/// Queue the timer state `on` unless released or a repeat of the last one.
/// The first state is always sent, even `false`.
private void queueTimer(ref Reporter r, bool on)
{
    if (r.released || (r.hasLastTimer && on == r.lastTimer)) return;
    r.hasLastTimer = true;
    r.lastTimer = on;
    r.pendingTimer = on;
    r.hasPendingTimer = true;
}

/// Queue `name` for display unless released or a repeat of the last one.
private void queueModel(ref Reporter r, string name)
{
    if (r.released || (r.hasLastModel && name == r.lastModel)) return;
    r.hasLastModel = true;
    r.lastModel = name;
    r.pendingModel = name;
    r.hasPendingModel = true;
}

private shared Locked!Reporter gReporter;
private shared bool gActive, gStarted;

/// Start reporting if this process runs inside a Herdr pane (reads the
/// environment once; later calls do nothing). Call from the main thread.
void start()
{
    import std.process : environment;
    start((string k) => environment.get(k));
}

/// ditto, with the environment lookup given (tests).
void start(scope string delegate(string) @safe get)
{
    import nano.safeio : spawnDaemon;
    import std.process : environment, thisProcessID;
    if (!cas(&gStarted, false, true)) return;
    bool found;
    auto pane = claim(get, (string k, string v) { environment[k] = v; }, thisProcessID, found);
    if (!found) return;
    Reporter r;
    r.pane = pane;
    atomicStore(gReporter, new shared Locked!Reporter(r));
    atomicStore(gActive, true);
    spawnDaemon(&worker, pane.bin, pane.id);
}

/// Find this process's pane (as `Pane.fromEnv` for `pid`) and, if found, mark
/// it claimed by `pid` through `set`, so every child inherits the claim. Only
/// `ownerVar` is set: the herdr CLI variables stay usable in children.
private Pane claim(scope string delegate(string) @safe get, scope void delegate(string, string) @safe set,
    long pid, out bool found)
{
    auto pane = Pane.fromEnv(get, pid, found);
    if (found) set(ownerVar, pid.to!string);
    return pane;
}

/// Whether nano-coder is running inside a Herdr pane.
bool active() { return atomicLoad(gActive); }

/// A sequence number above every earlier one, including those from previous
/// runs: microseconds since the epoch, bumped if the clock stalls.
private ulong nextSeq(ref Reporter r)
{
    import std.datetime.systime : Clock;
    import std.datetime : SysTime, UTC;
    import std.algorithm : max;
    auto now = (wallNow(UTC()) - SysTime.fromUnixTime(0, UTC())).total!"usecs".to!ulong;
    r.seq = max(now, r.seq + 1);
    return r.seq;
}

/// Report `state` (with an optional reason) in the background, plus
/// `session` when it differs from the last one reported.
void report(State state, string message = null, Session session = Session.init, bool hasSession = false)
{
    if (!active) return;
    // The worker's `await` wakes on the update.
    atomicLoad(gReporter).update((ref Reporter r) {
        bool newSession = hasSession && !(r.hasLastSession && r.lastSession == session);
        if (r.hasLast && r.lastState == state && r.lastMessage == message && !newSession) return;
        r.hasLast = true;
        r.lastState = state;
        r.lastMessage = message;
        if (newSession)
        {
            r.hasLastSession = true;
            r.lastSession = session;
        }
        Queued q;
        // A session not yet sent from an overwritten report must not be lost.
        if (newSession) { q.hasSession = true; q.session = session; }
        else if (r.hasPending && r.pending.hasSession) { q.hasSession = true; q.session = r.pending.session; }
        q.stateSeq = nextSeq(r);
        q.state = state;
        q.message = message;
        if (q.hasSession) q.sessionSeq = nextSeq(r);
        r.pending = q;
        r.hasPending = true;
    });
}

/// Show `model` (its short name) next to the agent's name in Herdr, in the
/// background. Repeats are skipped.
void showModel(string model)
{
    if (!active) return;
    auto name = shortModel(model);
    atomicLoad(gReporter).update((ref Reporter r) {
        r.curModel = name;
        queueModel(r, metaKey(r.curName, r.curModel));
    });
}

/// Show the session's handle (issue #300; empty clears it) as the pane's
/// agent name in Herdr, alongside the model, in the background.
void showName(string handle)
{
    if (!active) return;
    atomicLoad(gReporter).update((ref Reporter r) {
        r.curName = handle;
        queueModel(r, metaKey(r.curName, r.curModel));
    });
}

/// Forget what metadata (name, model, timer) was sent, so the next
/// `showName`/`showModel`/`showTimer` re-sends it. Called once per turn:
/// something else (another process in the pane) may have cleared it.
void refreshMetadata()
{
    if (!active) return;
    atomicLoad(gReporter).update((ref Reporter r) { forgetMetadata(r); });
}

private void forgetMetadata(ref Reporter r)
{
    r.hasLastModel = r.hasLastTimer = false;
}

/// ditto, for callers that only track the model.
private ulong beginRelease(ref Reporter r, out bool shown)
{
    bool timerShown;
    return beginRelease(r, shown, timerShown);
}

/// Show the timer icon in Herdr while `on` (a timer is set), in the
/// background. Repeats are skipped.
void showTimer(bool on)
{
    if (!active) return;
    atomicLoad(gReporter).update((ref Reporter r) { queueTimer(r, on); });
}

/// Release the pane on exit. Runs in the foreground (bounded by a timeout)
/// so it is sent before the process ends; drops any report still pending.
void release()
{
    if (!active) return;
    Pane pane;
    bool shown, timerShown;
    auto rep = atomicLoad(gReporter);
    ulong seq = rep.update!ulong((ref Reporter r) {
        pane = r.pane;
        return beginRelease(r, shown, timerShown);
    });
    // Let an in-flight metadata send finish (each run is time-bounded) so
    // the clear below is the last metadata Herdr sees.
    rep.await!bool((ref const Reporter r) => !r.modelInFlight, (ref Reporter r) => true);
    // Metadata outlives the release, so clear the model first.
    if (shown) run(pane.bin, metadataArgs(pane.id, null));
    if (timerShown) run(pane.bin, timerArgs(pane.id, false));
    run(pane.bin, releaseArgs(pane.id, seq));
}

/// Resume reporting after `release` when the process keeps running (a
/// failed relaunch): the next state, session, model and timer are reported
/// again.
void reacquire()
{
    if (!active) return;
    atomicLoad(gReporter).update((ref Reporter r) { endRelease(r); });
}

private void worker(string bin, string pane)
{
    for (;;)
    {
        bool hasState;
        auto q = atomicLoad(gReporter).await!Queued(
            (ref const Reporter r) => r.hasPending || r.hasPendingModel || r.hasPendingTimer,
            (ref Reporter r) {
                hasState = r.hasPending;
                r.hasPending = false;
                return r.pending;
            });
        if (hasState)
        {
            run(bin, reportArgs(pane, q.state, q.stateSeq, q.message));
            if (q.hasSession) run(bin, sessionArgs(pane, q.sessionSeq, q.session));
        }
        // Take the model and timer only after state/session reporting, so a
        // release that starts meanwhile discards them instead of waiting on
        // unrelated reports before its own clear and release calls.
        string model;
        bool timerOn;
        bool hasModel, hasTimer;
        atomicLoad(gReporter).update((ref Reporter r) {
            hasModel = takeModel(r, model);
            hasTimer = takeTimer(r, timerOn);
        });
        if (hasModel) run(bin, metadataFor(pane, model));
        if (hasTimer) run(bin, timerArgs(pane, timerOn));
        if (hasModel || hasTimer) atomicLoad(gReporter).update((ref Reporter r) { r.modelInFlight = false; });
    }
}

/// Run the Herdr CLI, ignoring its output and any failure, killing it after
/// `timeout`.
private void run(string bin, string[] args)
{
    import std.process : spawnProcess, tryWait, wait, Config, Pid;
    import std.stdio : File;
    import core.thread : Thread;
    import nano.safeio : killProcess;
    Pid pid;
    try
    {
        auto devNull = File("/dev/null", "r+");
        pid = spawnProcess([bin] ~ args, devNull, devNull, devNull, null, Config.none);
    }
    catch (Exception) return; // herdr missing or not runnable: the integration is best effort
    auto deadline = monoNow + timeout;
    try
    {
        for (;;)
        {
            if (tryWait(pid).terminated) return;
            if (monoNow >= deadline)
            {
                killProcess(pid);
                wait(pid);
                return;
            }
            sleepFor(10.msecs);
        }
    }
    catch (Exception) return; // waiting on herdr is best effort; never block or fail a turn on it
}

// rust: herdr.rs::pane_needs_all_herdr_variables
unittest // the pane needs all of Herdr's variables
{
    string delegate(string) @safe env(string[string] vars)
    {
        return (string k) { auto p = k in vars; return p is null ? null : *p; };
    }
    auto full = ["HERDR_ENV": "1", "HERDR_BIN_PATH": "/bin/herdr", "HERDR_PANE_ID": "p1"];
    bool found;
    assert(Pane.fromEnv(env(full), found) == Pane("/bin/herdr", "p1") && found);
    Pane.fromEnv(env(["HERDR_BIN_PATH": "/bin/herdr", "HERDR_PANE_ID": "p1"]), found);
    assert(!found);
    Pane.fromEnv(env(["HERDR_ENV": "0", "HERDR_BIN_PATH": "/bin/herdr", "HERDR_PANE_ID": "p1"]), found);
    assert(!found);
    Pane.fromEnv(env(["HERDR_ENV": "1", "HERDR_BIN_PATH": "/bin/herdr", "HERDR_PANE_ID": ""]), found);
    assert(!found);
    Pane.fromEnv(env(null), found);
    assert(!found);
}

// rust: herdr.rs::state_report_args
unittest // state report arguments
{
    assert(reportArgs("p1", State.working, 7, null) == ["pane", "report-agent", "p1", "--source", "nano-coder", "--agent",
        "nano-coder", "--state", "working", "--seq", "7"]);
}

// rust: herdr.rs::blocked_report_carries_a_clean_message
unittest // a blocked report carries a clean message
{
    import std.algorithm : countUntil;
    import std.array : replicate;
    auto args = reportArgs("p1", State.blocked, 1, "pick one\x1b[2J");
    auto at = args.countUntil("--message");
    assert(args[at + 1] == "pick one[2J");
    args = reportArgs("p1", State.blocked, 1, "é".replicate(300));
    assert(args[$ - 1] == "é".replicate(200));
}

// rust: herdr.rs::session_report_puts_resume_argv_after_double_dash
unittest // the session report puts the resume argv after `--`
{
    import std.algorithm : countUntil;
    auto session = Session("s1", resumeArgv("s1", "openai/gpt-5", null));
    auto args = sessionArgs("p1", 2, session);
    assert(args[0 .. 2] == ["pane", "report-agent-session"]);
    auto dash = args.countUntil("--");
    assert(args[dash - 4 .. dash] == ["--seq", "2", "--agent-session-id", "s1"]);
    assert(args[dash + 1 .. $] == ["nano-coder", "--resume", "s1", "--model", "openai/gpt-5"]);
}

// rust: herdr.rs::resume_argv_respects_herdr_rules
unittest // the resume argv follows Herdr's rules
{
    import std.array : replicate;
    assert(resumeArgv("s1", null, null) == ["nano-coder", "--resume", "s1"]);
    assert(resumeArgv("s1", "", ["--config", "/tmp/c.toml"]) == ["nano-coder", "--resume", "s1", "--config", "/tmp/c.toml"]);
    assert(resumeArgv("s1", "it's", null) is null);
    assert(resumeArgv("s\n1", null, null) is null);
    string[] many;
    foreach (_; 0 .. 62) many ~= "x";
    assert(resumeArgv("s1", null, many) is null);
    assert(resumeArgv("s1", null, ["y".replicate(9000)]) is null);
}

// rust: herdr.rs::release_args_shape
unittest // release arguments
{
    assert(releaseArgs("p1", 3) == ["pane", "release-agent", "p1", "--source", "nano-coder", "--agent", "nano-coder",
        "--seq", "3"]);
}

unittest // outside Herdr nothing starts and reports are no-ops
{
    if (!active)
    {
        report(State.working);
        release();
    }
}

unittest // the model shows by its short name, and an empty one clears it
{
    assert(shortModel("anthropic/claude-sonnet-4.5") == "claude-sonnet-4.5");
    assert(shortModel("openrouter/moonshotai/kimi-k2") == "kimi-k2");
    assert(shortModel("gpt-5") == "gpt-5");
    assert(metadataArgs("p1", "gpt-5") == ["pane", "report-metadata", "p1", "--source", "nano-coder", "--agent",
        "nano-coder", "--display-agent", "nano-coder · gpt-5", "--token", "model=gpt-5", "--clear-token", "name"]);
    assert(metadataArgs("p1", "gpt\x1b-5")[$ - 3] == "model=gpt-5");
    assert(metadataArgs("p1", null)[$ - 5 .. $] == ["--clear-display-agent", "--clear-token", "model", "--clear-token", "name"]);
}

unittest // a model taken before release is waited for and cleared; none is sent after
{
    Reporter r;
    r.lastModel = r.pendingModel = "gpt-5";
    r.hasPendingModel = true;
    string model;
    assert(takeModel(r, model) && model == "gpt-5" && r.modelInFlight);
    bool shown;
    beginRelease(r, shown);
    assert(shown && r.released);
    r.modelInFlight = false;
    r.pendingModel = "late";
    r.hasPendingModel = true;
    assert(!takeModel(r, model));
}

unittest // an in-flight model counts as shown even before lastModel is set
{
    Reporter r;
    r.modelInFlight = true;
    bool shown;
    beginRelease(r, shown);
    assert(shown);
}

unittest // a pending clear after a shown model still clears on release
{
    Reporter r;
    r.hasPendingModel = true; // showModel queued "" over a shown model
    bool shown;
    beginRelease(r, shown);
    assert(shown && !r.hasPendingModel);
}

unittest // a first empty name still clears a predecessor's model; repeats are skipped
{
    Reporter r;
    queueModel(r, "");
    assert(r.hasPendingModel && r.pendingModel == "");
    r.hasPendingModel = false;
    queueModel(r, "");
    assert(!r.hasPendingModel);
    bool shown;
    beginRelease(r, shown);
    endRelease(r);
    queueModel(r, "");
    assert(r.hasPendingModel, "reacquiring reports an empty name afresh");
}

unittest // after a failed relaunch, model, state and session report again
{
    Reporter r;
    r.lastModel = "gpt-5";
    r.hasLast = r.hasLastSession = true;
    bool shown;
    beginRelease(r, shown);
    endRelease(r);
    assert(!r.released && !r.hasLast && !r.hasLastSession && !r.lastModel.length);
    r.pendingModel = "gpt-5";
    r.hasPendingModel = true;
    string model;
    assert(takeModel(r, model) && model == "gpt-5");
}

unittest // the timer token shows the icon while a timer is set and is cleared otherwise
{
    assert(timerArgs("p1", true) == ["pane", "report-metadata", "p1", "--source", "nano-coder", "--agent", "nano-coder",
        "--token", "timer=⏰"]);
    assert(timerArgs("p1", false)[$ - 2 .. $] == ["--clear-token", "timer"]);
}

unittest // the first timer state is sent even when false; repeats are skipped
{
    Reporter r;
    queueTimer(r, false);
    assert(r.hasPendingTimer && !r.pendingTimer);
    r.hasPendingTimer = false;
    queueTimer(r, false);
    assert(!r.hasPendingTimer);
    queueTimer(r, true);
    assert(r.hasPendingTimer && r.pendingTimer);
}

unittest // after release and reacquire, the first timer state is sent again
{
    Reporter r;
    queueTimer(r, false);
    bool shown, timerShown;
    beginRelease(r, shown, timerShown);
    queueTimer(r, false);
    assert(!r.hasPendingTimer);           // released: nothing queued
    endRelease(r);
    queueTimer(r, false);
    assert(r.hasPendingTimer && !r.pendingTimer);
}

unittest // release clears a shown timer, and nothing is taken after it
{
    Reporter r;
    r.lastTimer = true;
    r.hasPendingTimer = r.pendingTimer = true;
    bool shown, timerShown, on;
    beginRelease(r, shown, timerShown);
    assert(timerShown && !shown && !r.lastTimer);
    assert(!takeTimer(r, on));
}

unittest // release clears the icon when a pending clear was never sent
{
    Reporter r;
    r.lastTimer = r.pendingTimer = true;
    r.hasPendingTimer = true;
    bool on;
    assert(takeTimer(r, on) && on);
    r.modelInFlight = false;            // the icon was sent
    r.lastTimer = r.pendingTimer = false; // showTimer(false), not yet sent
    r.hasPendingTimer = true;
    bool shown, timerShown;
    beginRelease(r, shown, timerShown);
    assert(timerShown);
}

unittest // release clears a model whose pending clear was never sent
{
    Reporter r;
    r.lastModel = null;
    r.hasPendingModel = true;
    bool shown;
    beginRelease(r, shown);
    assert(shown);
}

unittest // a pane claimed by another nano-coder is not reported to; the owner itself (after exec) is
{
    auto full = ["HERDR_ENV": "1", "HERDR_BIN_PATH": "/bin/herdr", "HERDR_PANE_ID": "p1"];
    string delegate(string) @safe env(string[string] m) { return (string k) => m.get(k, null); }
    bool found;
    Pane.fromEnv(env(full), 42, found);
    assert(found);
    auto nested = full.dup;
    nested[ownerVar] = "7";
    Pane.fromEnv(env(nested), 42, found);
    assert(!found);
    Pane.fromEnv(env(nested), 7, found);
    assert(found);
}

unittest // startup claims the pane for its pid; a child inheriting that environment is nested and claims nothing
{
    string[string] env = ["HERDR_ENV": "1", "HERDR_BIN_PATH": "/bin/herdr", "HERDR_PANE_ID": "p1"];
    auto get = (string k) => env.get(k, null);
    auto set = (string k, string v) { env[k] = v; };
    bool found;
    auto pane = claim(get, set, 42, found);
    assert(found && pane == Pane("/bin/herdr", "p1"));
    assert(env[ownerVar] == "42");
    auto before = env.dup;
    // The nested child (pid 43) sees the inherited marker: no pane, nothing changed.
    claim(get, set, 43, found);
    assert(!found);
    assert(env == before);
    assert(env["HERDR_PANE_ID"] == "p1" && env["HERDR_BIN_PATH"] == "/bin/herdr" && env["HERDR_ENV"] == "1");
    // The owner itself after a /relaunch exec keeps its pane.
    claim(get, set, 42, found);
    assert(found);
}

unittest // a nested start() leaves reporting inactive and the environment untouched
{
    // Reset the latch first so the test always exercises start(), then restore it.
    immutable startedBefore = atomicLoad(gStarted);
    atomicStore(gStarted, false);
    scope (exit) atomicStore(gStarted, startedBefore);
    string[string] env = ["HERDR_ENV": "1", "HERDR_BIN_PATH": "/bin/herdr", "HERDR_PANE_ID": "p1", ownerVar: "1"];
    import std.process : environment;
    immutable ownerBefore = environment.get(ownerVar, null);
    start((string k) => env.get(k, null));
    assert(atomicLoad(gStarted)); // start() ran its body rather than returning early
    assert(!active);
    assert(environment.get(ownerVar, null) == ownerBefore); // a nested start claims nothing
}

unittest // a metadata clear from outside is repaired: refreshing re-sends name and model
{
    Reporter r;
    queueModel(r, metaKey("probe", "gpt-5"));
    string m;
    assert(takeModel(r, m) && m == metaKey("probe", "gpt-5"));
    r.modelInFlight = false;
    queueModel(r, metaKey("probe", "gpt-5"));
    assert(!r.hasPendingModel);
    forgetMetadata(r);
    queueModel(r, metaKey("probe", "gpt-5"));
    assert(takeModel(r, m) && m == metaKey("probe", "gpt-5"));
    queueTimer(r, false);
    assert(r.hasPendingTimer);
}
