/// The `bash` tool: run a command with `bash -c` in its own process group,
/// with a timeout and head/tail output truncation.
module nano.tools.bash;

@safe:

import nano.safeio : killPid;

import std.json;
import std.format : format;
import std.process;
import std.file : readText, remove, exists, tempDir;
import std.path : buildPath;
import std.stdio : File;
import core.time : seconds, msecs, Duration, MonoTime;
import core.thread : Thread;
import nano.tools;
import nano.control : cancelRequested;
import nano.llm : ToolDefinition;
import nano.sandbox : SandboxConfig, looksDenied;

enum long defaultTimeoutSecs = 600;

ToolDefinition definition(long defaultTimeout = defaultTimeoutSecs)
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

BashResult run(string command, Duration timeout, string cwd = null, const SandboxConfig sandbox = SandboxConfig.init)
{
    import std.process : thisProcessID;
    import std.datetime.systime : Clock;
    static size_t n;
    auto stem = buildPath(tempDir, format("nano-coder-d-bash-%s-%s-%s", thisProcessID, Clock.currStdTime, ++n));
    auto outPath = stem ~ ".out", errPath = stem ~ ".err";
    scope (exit)
    {
        if (outPath.exists) remove(outPath);
        if (errPath.exists) remove(errPath);
    }
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
    auto pid = spawnProcess(argv, inF, outF, errF, null, cfg, cwd);
    outF.close();
    errF.close();
    BashResult r;
    auto deadline = MonoTime.currTime + timeout;
    for (;;)
    {
        auto st = tryWait(pid);
        if (st.terminated)
        {
            r.exitCode = st.status;
            break;
        }
        bool cancelled = cancelRequested();
        if (cancelled || MonoTime.currTime >= deadline)
        {
            import core.sys.posix.signal : kill, SIGKILL;
            killPid(-pid.processID, SIGKILL);
            r.exitCode = wait(pid);
            r.cancelled = cancelled;
            r.timedOut = !cancelled;
            break;
        }
        Thread.sleep(20.msecs);
    }
    import std.file : read;
    r.stdout_ = lossyUtf8(cast(const(ubyte)[]) read(outPath));
    r.stderr_ = lossyUtf8(cast(const(ubyte)[]) read(errPath));
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
    auto r = run(command, secs.seconds, null, sandbox);
    string text;
    auto o = truncateOutput(r.stdout_, cast(size_t) limit, "bash-stdout");
    auto e = truncateOutput(r.stderr_, cast(size_t) limit, "bash-stderr");
    if (o.length) text ~= o;
    if (e.length) text ~= (text.length && text[$ - 1] != '\n' ? "\n" : "") ~ "\nStderr:\n" ~ e;
    if (r.cancelled) text ~= "\n\nError: the turn was cancelled; the command was killed";
    else if (r.timedOut) text ~= format("\n\n[killed after %s seconds; raise timeout_seconds if it needs longer]", secs);
    else if (r.exitCode != 0)
    {
        text ~= format("\n\nExit code: %s", r.exitCode);
        if (sandbox.active && looksDenied(r.stdout_ ~ r.stderr_))
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
    auto t = run("sleep 5 & sleep 5", 300.msecs);
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
    assert(collectExceptionMsg(execute(parseJSON(`{}`))) == `bash argument "command" must be set`);
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
    assert(collectExceptionMsg(execute(parseJSON(`{}`))).canFind("must be set"));
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
