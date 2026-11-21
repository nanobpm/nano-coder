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

/// The pane this process reports to, from Herdr's environment.
struct Pane
{
    string bin, id;

    static Pane fromEnv(scope string delegate(string) @safe get, out bool found)
    {
        found = false;
        if (get("HERDR_ENV") != "1") return Pane.init;
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
string[] metadataArgs(string pane, string model) pure
{
    import std.uni : isControl;
    import std.algorithm : filter;
    import std.conv : text;
    string[] args = ["pane", "report-metadata", pane, "--source", source, "--agent", agent];
    string clean = model.filter!(c => !isControl(c)).text;
    if (!clean.length) return args ~ ["--clear-display-agent", "--clear-token", "model"];
    return args ~ ["--display-agent", agent ~ " · " ~ clean, "--token", "model=" ~ clean];
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
    /// Whether a timer is set, when that changed since the last report.
    bool hasPendingTimer, pendingTimer, lastTimer;
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
    r.hasLastModel = false;
    r.lastTimer = false;
    return nextSeq(r);
}

/// Undo a release whose exit did not happen (a failed relaunch): reporting
/// starts afresh, so the next state, session, model and timer are all sent
/// again.
private void endRelease(ref Reporter r)
{
    r.released = false;
    r.hasLast = r.hasLastSession = r.hasLastModel = false;
    r.lastModel = null;
    r.lastTimer = false;
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
    if (!cas(&gStarted, false, true)) return;
    bool found;
    auto pane = Pane.fromEnv(get, found);
    if (!found) return;
    Reporter r;
    r.pane = pane;
    atomicStore(gReporter, new shared Locked!Reporter(r));
    atomicStore(gActive, true);
    spawnDaemon(&worker, pane.bin, pane.id);
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
    auto now = cast(ulong)((wallNow(UTC()) - SysTime.fromUnixTime(0, UTC())).total!"usecs");
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
    atomicLoad(gReporter).update((ref Reporter r) { queueModel(r, name); });
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
    atomicLoad(gReporter).update((ref Reporter r) {
        if (r.released || on == r.lastTimer) return;
        r.lastTimer = on;
        r.pendingTimer = on;
        r.hasPendingTimer = true;
    });
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
        if (hasModel) run(bin, metadataArgs(pane, model));
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
        "nano-coder", "--display-agent", "nano-coder · gpt-5", "--token", "model=gpt-5"]);
    assert(metadataArgs("p1", "gpt\x1b-5")[$ - 1] == "model=gpt-5");
    assert(metadataArgs("p1", null)[$ - 3 .. $] == ["--clear-display-agent", "--clear-token", "model"]);
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
