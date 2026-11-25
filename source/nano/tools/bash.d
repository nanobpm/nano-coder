/// The `bash` tool: run a command with `bash -c` in its own process group,
/// with a timeout and head/tail output truncation.
module nano.tools.bash;

@safe:

import nano.arith : toSize;
import nano.clock : monoNow, sleepFor, stdTimeNow;

import nano.safeio : killPid, readBytes;

import std.json;
import std.format : format;
import std.process;
import std.file : readText, remove, exists, tempDir;
import std.path : buildPath;
import std.stdio : File;
import core.time : seconds, msecs, Duration;
import nano.tools;
import nano.control : cancelRequested;
import nano.llm : ToolDefinition;
import nano.sandbox : SandboxConfig, looksDenied;
import nano.config : defaultBashHeartbeatSecsValue;

enum long defaultTimeoutSecs = 600;

/// The default heartbeat interval: a "still running" note goes to the
/// supervisor-visible stream this often while a command runs. It must stay
/// below common idle-kill windows (the c8ctl-nano worker kills a run after
/// 300 s of silence), so a healthy long command never looks dead. The value
/// lives in `nano.config` (`defaultBashHeartbeatSecsValue`), beside the
/// idle-kill budget it is checked against.
enum long defaultHeartbeatSecs = defaultBashHeartbeatSecsValue;

/// Where a heartbeat line goes: the supervising process's output stream, set
/// by the front-end (the CLI's console, the ACP server's `session/update`).
/// It is NEVER the tool result or the model's context — a heartbeat costs no
/// tokens. Null (the default) means no heartbeat, so embedded uses and unit
/// tests are silent unless they wire a sink.
void delegate(string) @safe heartbeatSink;

/// How often `run` emits a heartbeat. Configurable (`bash_heartbeat_secs` /
/// `NANO_CODER_BASH_HEARTBEAT_SECS`, resolved by
/// `nano.config.bashHeartbeatIntervalSecs`); must stay below the idle-kill
/// window.
Duration heartbeatInterval = defaultHeartbeatSecs.seconds;

/// The heartbeat line for `elapsed` running `command`: a head of the command
/// so the supervisor can tell which call is alive.
string heartbeatText(string command, Duration elapsed)
{
    import std.array : array;
    import std.conv : to;
    import std.regex : regex, replaceAll;
    import std.string : strip;
    import std.utf : byDchar;
    auto total = elapsed.total!"seconds";
    // Decode (invalid bytes become U+FFFD) and cut by code points, never by
    // bytes, so the line stays valid UTF-8; collapse whitespace so a
    // multi-line command stays on one heartbeat line.
    auto chars = command.byDchar.array.to!string
        .replaceAll(regex(`\s+`), " ").strip.to!dstring;
    auto head = chars.length > 60 ? (chars[0 .. 60] ~ "…"d).to!string : chars.to!string;
    return format("… still running (%sm%02ss, %s)", total / 60, total % 60, head);
}

ToolDefinition definition(long defaultTimeout = defaultTimeoutSecs) pure
{
    return ToolDefinition("bash",
        "Run a shell command with `bash -c` and return its stdout, stderr and exit code. "
        ~ "Long output is truncated to its head and tail; the complete output is saved to a file whose path is included.",
        parseJSON(format(`{
            "type": "object",
            "properties": {
                "command": { "type": "string", "description": "Command to run" },
                "timeout_seconds": { "type": "integer", "description": "Kill the command after this many seconds (default %s)" },
                "max_output_length": { "type": "integer", "description": "Maximum characters of stdout and of stderr to return (default %s, max %s)" }
            },
            "required": ["command"]
        }`, defaultTimeout, defaultMaxOutput, maxOutputLimit)));
}

extern (C) private int setsid() nothrow @nogc;

private void newSession() nothrow @nogc
{
    setsid();
}

struct BashResult
{
    string stdout_;
    string stderr_;
    int exitCode;
    bool timedOut;
    bool cancelled;
}

private struct RunStatus
{
    int exitCode;
    bool timedOut;
    bool cancelled;
}

/// The message for a command that could not be started: an executable whose
/// path ends in " (deleted)" was replaced under this session (an upgrade), so
/// say to restart instead of surfacing the raw exec error.
string spawnFailure(string msg) pure
{
    import std.algorithm : canFind;
    if (msg.canFind(" (deleted)"))
        return "nano-coder was upgraded under this session, so the bash tool can't start its helper; "
            ~ "restart nano-coder (" ~ msg ~ ")";
    return "could not start the command: " ~ msg;
}

unittest
{
    import std.algorithm : canFind, startsWith;
    assert(spawnFailure("Failed to execute '/usr/bin/nano-coder (deleted)'").startsWith("nano-coder was upgraded"));
    assert(spawnFailure("Failed to execute 'bash'").startsWith("could not start the command"));
}

/// The failure result a headless run records when its shell is gone: the
/// agent can't write AGENT_RESULT_FILE itself without one, so its work would
/// otherwise be reported as nothing at all.
string fatalResultJson(string msg)
{
    import std.json : JSONValue;
    return JSONValue(["status": "blocked", "summary": "bash tool unavailable: " ~ msg]).toString;
}

/// Write `fatalResultJson` to `$AGENT_RESULT_FILE` when it is set and the
/// agent hasn't written a result yet (never overwrite a real one).
void recordFatalResult(string msg)
{
    import std.file : exists, write;
    auto path = environment.get("AGENT_RESULT_FILE");
    if (!path.length || path.exists) return;
    import std.exception : collectException;
    // Best effort: the ToolError still reports the failure if this can't write.
    collectException(write(path, fatalResultJson(msg)));
}

unittest
{
    import std.json : parseJSON;
    auto j = parseJSON(fatalResultJson("restart nano-coder"));
    assert(j["status"].str == "blocked");
    assert(j["summary"].str == "bash tool unavailable: restart nano-coder");
}

private RunStatus runToFiles(string command, Duration timeout, string outPath, string errPath,
    string cwd = null, const SandboxConfig sandbox = SandboxConfig.init)
{
    auto outF = File(outPath, "w"), errF = File(errPath, "w"), inF = File("/dev/null", "r");
    Config cfg;
    cfg.preExecFunction = () nothrow @nogc { newSession(); return true; };
    // The sandbox fails closed: ToolError when it can't be applied.
    string[] argv = ["bash", "-c", command];
    if (sandbox.active)
    {
        import std.file : getcwd;
        try argv = sandbox.command("bash", command, cwd.length ? cwd : getcwd());
        catch (Exception e) throw new ToolError(e.msg);
    }
    Pid pid;
    try pid = spawnProcess(argv, inF, outF, errF, null, cfg, cwd);
    catch (ProcessException e)
    {
        auto msg = spawnFailure(e.msg);
        recordFatalResult(msg);
        throw new ToolError(msg);
    }
    outF.close();
    errF.close();
    RunStatus r;
    auto started = monoNow;
    auto deadline = started + timeout;
    // The next heartbeat is due one interval in; it stops the moment the loop
    // below breaks (the command finished, timed out or was cancelled).
    auto nextBeat = started + heartbeatInterval;
    // Poll fast at first (most commands finish in milliseconds), backing off
    // to 20 ms for long ones.
    auto poll = 1.msecs;
    for (;;)
    {
        auto st = tryWait(pid);
        if (st.terminated)
        {
            r.exitCode = st.status;
            break;
        }
        bool cancelled = cancelRequested();
        if (cancelled || monoNow >= deadline)
        {
            import core.sys.posix.signal : kill, SIGKILL;
            killPid(-pid.processID, SIGKILL);
            r.exitCode = wait(pid);
            r.cancelled = cancelled;
            r.timedOut = !cancelled;
            break;
        }
        auto now = monoNow;
        if (heartbeatSink !is null && now >= nextBeat)
        {
            heartbeatSink(heartbeatText(command, now - started));
            nextBeat = now + heartbeatInterval;
        }
        sleepFor(poll);
        if (poll < 20.msecs) poll = poll * 2 > 20.msecs ? 20.msecs : poll * 2;
    }
    return r;
}

private string tempStem()
{
    import std.process : thisProcessID;
    static size_t n;
    return buildPath(tempDir, format("nano-coder-bash-%s-%s-%s", thisProcessID, stdTimeNow, ++n));
}

BashResult run(string command, Duration timeout, string cwd = null, const SandboxConfig sandbox = SandboxConfig.init)
{
    auto stem = tempStem();
    auto outPath = stem ~ ".out", errPath = stem ~ ".err";
    scope (exit)
    {
        if (outPath.exists) remove(outPath);
        if (errPath.exists) remove(errPath);
    }
    auto st = runToFiles(command, timeout, outPath, errPath, cwd, sandbox);
    BashResult r;
    r.exitCode = st.exitCode;
    r.timedOut = st.timedOut;
    r.cancelled = st.cancelled;
    r.stdout_ = lossyUtf8(readBytes(outPath));
    r.stderr_ = lossyUtf8(readBytes(errPath));
    return r;
}

string execute(JSONValue args, long defaultTimeout = defaultTimeoutSecs, const SandboxConfig sandbox = SandboxConfig.init)
{
    if (args.type != JSONType.object) throw new ToolError("bash arguments must be a JSON object");
    auto command = requireString(args, "command", "bash");
    {
        import std.string : indexOf;
        auto nul = command.indexOf('\0');
        if (nul >= 0) throw new ToolError(format(`bash argument "command" contains a NUL byte at offset %s`, nul));
    }
    auto secs = optInt(args, "timeout_seconds", defaultTimeout);
    if (secs <= 0) throw new ToolError(`bash argument "timeout_seconds" must be positive`);
    auto limit = optInt(args, "max_output_length", defaultMaxOutput);
    if (limit <= 0 || limit > maxOutputLimit)
        throw new ToolError(format(`bash argument "max_output_length" must be between 1 and %s`, maxOutputLimit));
    auto stem = tempStem();
    auto outPath = stem ~ ".out", errPath = stem ~ ".err";
    scope (exit)
    {
        if (outPath.exists) remove(outPath);
        if (errPath.exists) remove(errPath);
    }
    auto r = runToFiles(command, secs.seconds, outPath, errPath, null, sandbox);
    // Stream-truncate stdout and stderr directly from their temp files so a
    // noisy command never loads its full output into GC memory (issue #307).
    bool checkDenied = sandbox.active && !r.cancelled && !r.timedOut && r.exitCode != 0;
    bool outDenied, errDenied;
    auto o = truncateFile(outPath, toSize(limit), "bash-stdout", outDenied, checkDenied);
    auto e = truncateFile(errPath, toSize(limit), "bash-stderr", errDenied, checkDenied && !outDenied);
    string text;
    if (o.length) text ~= o;
    if (e.length) text ~= (text.length && text[$ - 1] != '\n' ? "\n" : "") ~ "\nStderr:\n" ~ e;
    if (r.cancelled) text ~= "\n\nError: the turn was cancelled; the command was killed";
    else if (r.timedOut) text ~= format("\n\n[killed after %s seconds; raise timeout_seconds if it needs longer]", secs);
    else if (r.exitCode != 0)
    {
        text ~= format("\n\nExit code: %s", r.exitCode);
        if (checkDenied && (outDenied || errDenied))
        {
            import std.file : getcwd;
            text ~= format("\nNote: %s.", sandbox.describe(getcwd()));
        }
    }
    if (!text.length) text = "(no output)";
    return text;
}

// rust: bash.rs::formats_stdout_stderr_and_exit_code
// rust: bash.rs::kills_on_timeout_without_waiting_for_background_children
unittest
{
    auto r = run("echo out; echo err >&2; exit 3", 5.seconds);
    assert(r.stdout_ == "out\n" && r.stderr_ == "err\n" && r.exitCode == 3 && !r.timedOut);
    auto t = run("sleep 5 & sleep 5", 50.msecs);
    assert(t.timedOut);
    import std.string : indexOf;
    auto text = execute(parseJSON(`{"command":"printf hi; false"}`));
    assert(text.indexOf("hi") == 0 && text.indexOf("Exit code: 1") > 0);
}

// rust: bash.rs::validates_arguments, output.rs::validates_limits
unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm.searching : startsWith;
    assert(collectExceptionMsg(execute(parseJSON(`{}`))) == `bash: missing required argument "command"`);
    assert(collectExceptionMsg(execute(parseJSON(`"{bad"`))).startsWith("bash arguments must be a JSON object"));
    foreach (bad; [`0`, `-1`, `1000001`])
        assert(collectExceptionMsg(execute(parseJSON(`{"command":"ls","max_output_length":` ~ bad ~ `}`))).length);
    assert(collectExceptionMsg(execute(parseJSON(`{"command":"true","max_output_length":10}`))) is null);
}

// A call whose command never started throws (a failed tool call, so it is no
// verification check, Rust #158); one that started returns text even when it fails.
// rust: bash.rs::run_checked_rejects_commands_that_never_started
unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm.searching : canFind;
    assert(collectExceptionMsg(execute(parseJSON(`{}`))).canFind("missing required argument"));
    assert(collectExceptionMsg(execute(parseJSON(`{"command":1}`))).length);
    assert(collectExceptionMsg(execute(parseJSON(`{"command":"a\u0000b"}`))).length);
    assert(collectExceptionMsg(execute(parseJSON(`{"command":"ls","timeout_seconds":0}`))).length);
    assert(collectExceptionMsg(execute(parseJSON(`"ls"`))).length);
    assert(execute(parseJSON(`{"command":"exit 3"}`)).canFind("Exit code: 3"));
}

// rust: bash.rs::truncates_and_keeps_full_capture
unittest
{
    import std.algorithm.searching : startsWith, endsWith, findSplitAfter, findSplitBefore;
    import std.file : readText;
    import std.string : lineSplitter;
    import std.range : walkLength;
    auto result = execute(parseJSON(`{"command":"seq 1 100000","max_output_length":20}`));
    assert(result.startsWith("1\n2\n3\n4\n5\n") && result.endsWith("100000\n"), result);
    auto path = result.findSplitAfter("full output saved to ")[1].findSplitBefore(" ...]")[0];
    assert(readText(path).lineSplitter.walkLength == 100000);
}

// Truncation cuts by code points: a multibyte char crossing the 60th byte is
// kept whole, invalid input bytes are replaced, and newlines are collapsed.
unittest
{
    import std.utf : validate;
    import std.array : replicate;
    import std.algorithm : canFind;
    auto t = heartbeatText("x".replicate(59) ~ "éééé", 61.seconds);
    validate(t);
    assert(t.canFind("x".replicate(59) ~ "é…"), t);
    auto bad = heartbeatText("echo \xff\xfe", 1.seconds);
    validate(bad);
    auto ml = heartbeatText("a\nb\r\n  c", 1.seconds);
    assert(!ml.canFind('\n') && ml.canFind("a b c"), ml);
}

// The heartbeat's interval math: the default 60 s stays below the 300 s
// idle-kill window, and a 150 s silent command crosses it at least twice.
unittest
{
    import nano.config : workerIdleKillSecs;
    assert(defaultHeartbeatSecs < workerIdleKillSecs);
    // 150 s of silence with a 60 s interval fires at 60 s and 120 s: ≥ 2 beats.
    assert(150 / defaultHeartbeatSecs >= 2);
}

// A long silent command heartbeats on the wired sink, never in its result, and
// stops when it finishes. The interval is injected short so the test is fast;
// the emission logic is interval-driven, so this stands in for a 150 s run at
// the 60 s default.
unittest
{
    import std.algorithm.searching : canFind;
    import std.conv : to;
    auto savedSink = heartbeatSink;
    auto savedInterval = heartbeatInterval;
    scope (exit) { heartbeatSink = savedSink; heartbeatInterval = savedInterval; }
    import std.file : tempDir, write, exists, remove;
    import std.path : buildPath;
    import std.process : thisProcessID;
    // Gate the command on the sink having seen 2 beats (flag file), with a
    // 5 s shell-side deadline, so a loaded runner cannot starve the poller.
    auto flag = buildPath(tempDir, "nano-hb-" ~ thisProcessID.to!string ~ "-a");
    scope (exit) if (exists(flag)) remove(flag);
    string[] beats;
    heartbeatSink = (string line) { beats ~= line; if (beats.length == 2) write(flag, ""); };
    heartbeatInterval = 40.msecs;
    import std.array : replace;
    auto cmd = "i=0; while [ ! -e '" ~ flag.replace("'", "'\\''") ~ "' ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i+1)); done";
    auto r = run(cmd, 10.seconds);
    assert(!r.timedOut && r.exitCode == 0);
    assert(beats.length >= 2, "expected ≥2 heartbeats, got " ~ beats.length.to!string);
    foreach (b; beats) assert(b.canFind("still running"), b);
    // The beat names the command head so the supervisor can tell calls apart.
    assert(beats[0].canFind("i=0"), beats[0]);
    // Beats come only from run's polling loop, on this thread, so none can
    // follow its return: nothing to wait for here.
}

// The tool result carries no heartbeat text: it is supervisor-only.
unittest
{
    import std.algorithm.searching : canFind;
    auto savedSink = heartbeatSink;
    auto savedInterval = heartbeatInterval;
    scope (exit) { heartbeatSink = savedSink; heartbeatInterval = savedInterval; }
    import std.conv : to;
    import std.file : tempDir, write, exists, remove;
    import std.path : buildPath;
    import std.process : thisProcessID;
    // Gate the command on a beat having arrived (flag file), 5 s deadline.
    auto flag = buildPath(tempDir, "nano-hb-" ~ thisProcessID.to!string ~ "-b");
    scope (exit) if (exists(flag)) remove(flag);
    string[] beats;
    heartbeatSink = (string line) { beats ~= line; write(flag, ""); };
    heartbeatInterval = 30.msecs;
    import std.array : replace;
    auto cmd = "i=0; while [ ! -e '" ~ flag.replace("'", "'\\''") ~ "' ] && [ $i -lt 500 ]; do sleep 0.01; i=$((i+1)); done; printf done";
    JSONValue args; args["command"] = cmd;
    auto text = execute(args);
    assert(beats.length >= 1, "expected ≥1 heartbeat");
    assert(text.canFind("done") && !text.canFind("still running"), text);
}

// No sink wired (the default): a long command runs silent, no heartbeat.
unittest
{
    auto savedSink = heartbeatSink;
    auto savedInterval = heartbeatInterval;
    scope (exit) { heartbeatSink = savedSink; heartbeatInterval = savedInterval; }
    heartbeatSink = null;
    heartbeatInterval = 10.msecs;
    auto r = run("sleep 0.03", 5.seconds);
    assert(r.exitCode == 0); // no crash, no output, no heartbeat
}
