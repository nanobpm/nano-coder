/// `api_key_command`: run a shell command for a provider's key, bounded by a
/// timeout and by turn cancellation (Rust `run_key_command_bounded`).
///
/// The command runs in its own session (process group) with stdout and
/// stderr going to temp files, so a large or never-closed output can't
/// deadlock the wait. The key is accepted only once the whole group has
/// exited: a backgrounded descendant still running after the leader (which
/// could yet print the rest of the key) fails closed. Every failure kills
/// the group.
module nano.keycmd;

@safe:

import core.time : Duration, MonoTime, msecs, seconds;
import std.format : format;

/// How long a key command may run.
enum keyCommandTimeout = 120.seconds;
/// How long descendants may outlive the leader before the key is refused.
enum keyCommandDrainGrace = 500.msecs;

extern (C) private int setsid() nothrow @nogc;

/// The trimmed key `command` prints; throws with an actionable message.
string runKeyCommand(string provider, string command, Duration timeout = keyCommandTimeout)
{
    import core.sys.posix.signal : SIGKILL;
    import core.thread : Thread;
    import std.file : exists, read, remove, tempDir;
    import std.path : buildPath;
    import std.process : Config, spawnProcess, thisProcessID, tryWait, wait;
    import std.stdio : File;
    import std.string : strip;
    import nano.control : cancelRequested;
    import nano.safeio : killPid;
    import nano.tools : lossyUtf8;

    static shared size_t counter;
    import core.atomic : atomicOp;
    auto stem = buildPath(tempDir, format("nano-coder-d-key-%s-%s", thisProcessID, atomicOp!"+="(counter, 1)));
    auto outPath = stem ~ ".out", errPath = stem ~ ".err";
    scope (exit)
    {
        if (outPath.exists) remove(outPath);
        if (errPath.exists) remove(errPath);
    }
    auto outF = File(outPath, "w"), errF = File(errPath, "w"), inF = File("/dev/null", "r");
    Config cfg;
    cfg.preExecFunction = () nothrow @nogc { setsid(); return true; };
    auto pid = spawnProcess(["sh", "-c", command], inF, outF, errF, null, cfg);
    outF.close();
    errF.close();
    auto group = -pid.processID;
    string what = format("provider %s: api_key_command", provider);
    string stderrText() { return lossyUtf8(cast(const(ubyte)[]) read(errPath)).strip; }
    void fail(string why)
    {
        killPid(group, SIGKILL);
        throw new Exception(format("%s %s", what, why));
    }

    auto deadline = MonoTime.currTime + timeout;
    int status;
    for (;;)
    {
        auto st = tryWait(pid);
        if (st.terminated) { status = st.status; break; }
        if (cancelRequested())
        {
            killPid(group, SIGKILL);
            wait(pid);
            throw new Exception(what ~ " was cancelled");
        }
        if (MonoTime.currTime >= deadline)
        {
            killPid(group, SIGKILL);
            wait(pid);
            throw new Exception(format("%s timed out after %s and was killed", what, timeout));
        }
        Thread.sleep(10.msecs);
    }
    // The leader is gone; wait briefly for the rest of its group.
    auto grace = MonoTime.currTime + keyCommandDrainGrace;
    while (killPid(group, 0) == 0)
    {
        if (MonoTime.currTime >= grace || MonoTime.currTime >= deadline)
            fail("exited but a background process it started is still running (and holding stdout open), "
                ~ "so the key can't be confirmed complete; don't background anything in the command");
        if (cancelRequested()) fail("was cancelled");
        Thread.sleep(10.msecs);
    }
    if (status != 0)
    {
        auto err = stderrText();
        throw new Exception(format("%s failed (exit %s)%s", what, status, err.length ? ": " ~ err : ""));
    }
    auto key = lossyUtf8(cast(const(ubyte)[]) read(outPath)).strip;
    if (!key.length) throw new Exception(what ~ " printed no key");
    return key;
}

// rust: providers/mod.rs::bounded_key_command_returns_the_trimmed_key
// rust: providers/mod.rs::failing_api_key_command_is_an_error
// rust: providers/mod.rs::bounded_key_command_times_out_and_kills_a_hung_command
// rust: providers/mod.rs::bounded_key_command_timeout_kills_descendants_holding_the_pipes
// rust: providers/mod.rs::bounded_key_command_fails_closed_when_no_key_was_captured
// rust: providers/mod.rs::bounded_key_command_fails_closed_when_leader_exits_but_descendant_holds_stdout
// rust: providers/mod.rs::bounded_key_command_drains_large_output_without_deadlock
// rust: providers/mod.rs::bounded_key_command_backgrounded_success_returns_the_key
// rust: providers/mod.rs::bounded_key_command_fails_closed_when_descendant_holds_pipe_before_the_key
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    assert(runKeyCommand("cmd", `printf '  sk-ok\n'`, 5.seconds) == "sk-ok");
    assert(collectExceptionMsg(runKeyCommand("cmd", "echo nope >&2; exit 3", 5.seconds)).canFind("nope"));
    auto t0 = MonoTime.currTime;
    assert(collectExceptionMsg(runKeyCommand("cmd", "sleep 30", 100.msecs)).canFind("timed out"));
    assert(collectExceptionMsg(runKeyCommand("cmd", "sleep 30; printf sk", 100.msecs)).canFind("timed out"));
    assert(collectExceptionMsg(runKeyCommand("cmd", "sleep 30 &", 5.seconds)).canFind("holding stdout open"));
    assert(collectExceptionMsg(runKeyCommand("cmd", "printf sk-part; sleep 30 &", 5.seconds)).canFind("holding stdout open"));
    assert(collectExceptionMsg(runKeyCommand("cmd", "sleep 30 & printf sk-good", 100.msecs)).canFind("holding stdout open"));
    assert(MonoTime.currTime - t0 < 10.seconds, "the failures are prompt");
    // A large output doesn't deadlock; a background job that finishes in
    // the grace period is fine.
    import std.array : replicate;
    assert(runKeyCommand("cmd", "head -c 200000 /dev/zero | tr '\\0' k", 5.seconds) == "k".replicate(200_000));
    assert(runKeyCommand("cmd", "(sleep 0.1) & printf sk-bg; wait", 5.seconds) == "sk-bg");
    assert(runKeyCommand("cmd", "printf sk-ok &", 5.seconds) == "sk-ok");
}

// rust: providers/mod.rs::bounded_key_command_honours_cancellation_and_kills_the_child
// rust: providers/mod.rs::bounded_key_command_cancelled_mid_flight_is_killed
// rust: providers/mod.rs::bounded_key_command_cancel_kills_descendants_holding_the_pipes
// rust: providers/mod.rs::bounded_key_command_cancel_applies_after_the_leader_exits
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    import nano.control : TurnControl;
    auto c = new shared TurnControl;
    c.cancel();
    scope (exit) c.startTurn();
    auto t0 = MonoTime.currTime;
    assert(collectExceptionMsg(runKeyCommand("cmd", "sleep 30", 20.seconds)).canFind("cancelled"));
    assert(collectExceptionMsg(runKeyCommand("cmd", "sleep 30; printf sk", 20.seconds)).canFind("cancelled"));
    assert(collectExceptionMsg(runKeyCommand("cmd", "sleep 30 & printf sk", 20.seconds)).canFind("cancelled"));
    assert(MonoTime.currTime - t0 < 5.seconds);
}
