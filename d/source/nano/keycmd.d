/// `api_key_command`: run a shell command for a provider's key, bounded by a
/// timeout and by turn cancellation (Rust `run_key_command_bounded`).
///
/// The command runs in its own session (process group). Stdout is a pipe,
/// drained as it fills, so a large output can't deadlock the wait; stderr
/// goes to a temp file. The key is accepted only once the leader has exited
/// and stdout has reached EOF: anything still holding it (a backgrounded
/// descendant, even one that left the group with `setsid`) could yet print
/// more, so it fails closed. Every failure kills the group.
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
    import core.sys.posix.poll : pollfd, POLLIN;
    import core.sys.posix.signal : SIGKILL;
    import std.file : exists, read, remove, tempDir;
    import std.path : buildPath;
    import std.process : Config, pipe, spawnProcess, thisProcessID, tryWait, wait;
    import std.stdio : File;
    import std.string : strip;
    import nano.control : cancelRequested;
    import nano.safeio : killPid, pollFds, readFd, setNonBlocking;
    import nano.tools : lossyUtf8;

    static shared size_t counter;
    import core.atomic : atomicOp;
    auto errPath = buildPath(tempDir, format("nano-coder-d-key-%s-%s.err", thisProcessID, atomicOp!"+="(counter, 1)));
    scope (exit) if (errPath.exists) remove(errPath);
    // Stdout is a pipe: EOF comes only once every process holding it has
    // closed it, including one that left the process group (`setsid`).
    auto outPipe = pipe();
    auto errF = File(errPath, "w"), inF = File("/dev/null", "r");
    Config cfg;
    cfg.preExecFunction = () nothrow @nogc { setsid(); return true; };
    auto pid = spawnProcess(["sh", "-c", command], inF, outPipe.writeEnd, errF, null, cfg);
    outPipe.writeEnd.close();
    errF.close();
    auto outFd = outPipe.readEnd.fileno;
    setNonBlocking(outFd);
    auto group = -pid.processID;
    string what = format("provider %s: api_key_command", provider);
    string stderrText() { return lossyUtf8(cast(const(ubyte)[]) read(errPath)).strip; }
    bool exited;
    int status;
    void fail(string why)
    {
        killPid(group, SIGKILL);
        if (!exited) wait(pid);
        throw new Exception(format("%s %s", what, why));
    }

    ubyte[] captured;
    ubyte[4096] buf;
    bool eof;
    // Reads what's ready, waiting up to 10ms for it.
    void drain()
    {
        pollfd[1] fds = [pollfd(outFd, POLLIN, 0)];
        if (pollFds(fds[], 10) <= 0) return;
        for (;;)
        {
            auto n = readFd(outFd, buf[]);
            if (n > 0) { captured ~= buf[0 .. n]; continue; }
            if (n == 0) eof = true;
            return; // EOF, or nothing more right now (EAGAIN)
        }
    }

    auto deadline = MonoTime.currTime + timeout;
    MonoTime grace;
    for (;;)
    {
        if (!eof) drain();
        else
        {
            import core.thread : Thread;
            Thread.sleep(10.msecs);
        }
        if (!exited)
        {
            auto st = tryWait(pid);
            if (st.terminated) { exited = true; status = st.status; grace = MonoTime.currTime + keyCommandDrainGrace; }
        }
        if (exited && eof) break;
        if (cancelRequested()) fail("was cancelled");
        auto now = MonoTime.currTime;
        if (!exited && now >= deadline) fail(format("timed out after %s and was killed", timeout));
        if (exited && (now >= grace || now >= deadline))
            fail("exited but a background process it started is still running (and holding stdout open), "
                ~ "so the key can't be confirmed complete; don't background anything in the command");
    }
    killPid(group, SIGKILL); // stdout is closed: nothing left in the group can add to the key
    if (status != 0)
    {
        auto err = stderrText();
        throw new Exception(format("%s failed (exit %s)%s", what, status, err.length ? ": " ~ err : ""));
    }
    auto key = lossyUtf8(captured).strip;
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

/// A command fragment that backgrounds a process outside the command's
/// process group, holding stdout open; null when neither tool is available.
version (unittest) private string escapee()
{
    import std.process : executeShell;
    if (executeShell("command -v setsid").status == 0) return "setsid sleep 5 &";
    if (executeShell("command -v perl").status == 0) return "perl -e 'use POSIX; POSIX::setsid(); sleep 5' &";
    return null;
}

// rust: providers/mod.rs::bounded_key_command_fails_closed_on_process_group_escapee_holding_stdout
// rust: providers/mod.rs::bounded_key_command_fails_closed_on_keyless_process_group_escapee
// rust: providers/mod.rs::bounded_key_command_cancel_applies_despite_process_group_escapee
unittest
{
    import std.algorithm : canFind;
    import std.exception : collectExceptionMsg;
    import nano.control : TurnControl;
    auto e = escapee();
    if (e is null) return;
    auto t0 = MonoTime.currTime;
    // The key printed, then an escapee holds stdout: not confirmed complete.
    auto msg = collectExceptionMsg(runKeyCommand("cmd", "printf sk-maybe-partial; " ~ e, 100.msecs));
    assert(msg.canFind("holding stdout open"), msg);
    // No key at all: fails promptly rather than hanging on the open pipe.
    msg = collectExceptionMsg(runKeyCommand("cmd", e, 100.msecs));
    assert(msg.canFind("holding stdout open"), msg);
    assert(MonoTime.currTime - t0 < 4.seconds, "an escapee blocked the bound");
    // Cancellation applies too.
    auto c = new shared TurnControl;
    c.cancel();
    scope (exit) c.startTurn();
    msg = collectExceptionMsg(runKeyCommand("cmd", e ~ " printf sk", 20.seconds));
    assert(msg.canFind("cancelled"), msg);
}
