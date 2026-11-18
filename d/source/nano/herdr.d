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

import core.atomic : atomicLoad, atomicStore, cas;
import core.time : Duration, MonoTime, msecs, seconds;
import std.conv : to;
import nano.safeio : Locked;

private enum source = "nano-coder";
/// The agent name Herdr shows for the pane.
private enum agent = "nano-coder";
/// The command a resume runs: this binary, not the Rust one.
enum resumeCommand = "nano-coder-d";
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
immutable(string)[] resumeArgv(string sessionId, string model, const string[] extra)
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
string[] reportArgs(string pane, State state, ulong seq, string message)
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
string[] sessionArgs(string pane, ulong seq, const Session session)
{
    return ["pane", "report-agent-session", pane, "--source", source, "--agent", agent, "--seq", seq.to!string,
        "--agent-session-id", session.id, "--"] ~ session.resume.dup;
}

string[] releaseArgs(string pane, ulong seq)
{
    return ["pane", "release-agent", pane, "--source", source, "--agent", agent, "--seq", seq.to!string];
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
    auto now = cast(ulong)((Clock.currTime(UTC()) - SysTime.fromUnixTime(0, UTC())).total!"usecs");
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

/// Release the pane on exit. Runs in the foreground (bounded by a timeout)
/// so it is sent before the process ends; drops any report still pending.
void release()
{
    if (!active) return;
    Pane pane;
    ulong seq = atomicLoad(gReporter).update!ulong((ref Reporter r) {
        r.hasPending = false;
        pane = r.pane;
        return nextSeq(r);
    });
    run(pane.bin, releaseArgs(pane.id, seq));
}

private void worker(string bin, string pane)
{
    for (;;)
    {
        auto q = atomicLoad(gReporter).await!Queued((ref const Reporter r) => r.hasPending, (ref Reporter r) {
            r.hasPending = false;
            return r.pending;
        });
        run(bin, reportArgs(pane, q.state, q.stateSeq, q.message));
        if (q.hasSession) run(bin, sessionArgs(pane, q.sessionSeq, q.session));
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
    auto deadline = MonoTime.currTime + timeout;
    try
    {
        for (;;)
        {
            if (tryWait(pid).terminated) return;
            if (MonoTime.currTime >= deadline)
            {
                killProcess(pid);
                wait(pid);
                return;
            }
            Thread.sleep(10.msecs);
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
    assert(args[dash + 1 .. $] == ["nano-coder-d", "--resume", "s1", "--model", "openai/gpt-5"]);
}

// rust: herdr.rs::resume_argv_respects_herdr_rules
unittest // the resume argv follows Herdr's rules
{
    import std.array : replicate;
    assert(resumeArgv("s1", null, null) == ["nano-coder-d", "--resume", "s1"]);
    assert(resumeArgv("s1", "", ["--config", "/tmp/c.toml"]) == ["nano-coder-d", "--resume", "s1", "--config", "/tmp/c.toml"]);
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
