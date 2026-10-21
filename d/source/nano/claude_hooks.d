/// Claude Code-compatible user hooks (port of `src/claude_hooks.rs`).
///
/// Reads the `hooks` key from Claude Code's settings files (and nano's own
/// `[hooks]` config) and runs external `command` hooks on the agent
/// lifecycle. The protocol (input JSON on stdin, exit codes, JSON output) is
/// Claude Code's, so existing hook scripts work unchanged. A `PreToolUse`
/// hook that crashes, times out or exits with an unexpected code blocks the
/// tool call (fail-safe) rather than silently letting it through.
module nano.claude_hooks;

import std.json;
import std.algorithm : canFind, any, map, sort, uniq;
import std.array : array, join, replace;
import std.conv : to;
import std.format : format;
import std.string : strip, startsWith, split;
import std.file : exists, readText, getcwd;
import std.path : buildPath;
import core.time : Duration, seconds, msecs, MonoTime;
import nano.permissions : ruleMatches, validateRule;
import nano.sandbox : SandboxConfig;

/// Per-field cap on hook output, in characters (Claude Code's).
enum fieldCap = 10_000;
/// Cap on raw stdout/stderr before the result counts as a failure.
enum outputCap = 1_000_000;
/// Default per-hook timeout in seconds (Claude's default).
enum defaultTimeoutSecs = 60;
/// Blocking `Stop` hooks are capped per turn to avoid loops.
enum maxStopBlocks = 3;

enum Event
{
    sessionStart,
    userPromptSubmit,
    preToolUse,
    postToolUse,
    stop,
}

string claudeName(Event e) @safe pure nothrow
{
    final switch (e)
    {
    case Event.sessionStart: return "SessionStart";
    case Event.userPromptSubmit: return "UserPromptSubmit";
    case Event.preToolUse: return "PreToolUse";
    case Event.postToolUse: return "PostToolUse";
    case Event.stop: return "Stop";
    }
}

private bool eventFromName(string name, out Event e) @safe pure nothrow
{
    switch (name)
    {
    case "SessionStart": e = Event.sessionStart; return true;
    case "UserPromptSubmit": e = Event.userPromptSubmit; return true;
    case "PreToolUse": e = Event.preToolUse; return true;
    case "PostToolUse": e = Event.postToolUse; return true;
    case "Stop": e = Event.stop; return true;
    default: return false;
    }
}

/// Where a hook came from.
enum Source
{
    project, /// `.claude/settings.json` at the repository root
    projectLocal, /// `.claude/settings.local.json`
    userClaude, /// `~/.claude/settings.json`
    userNano, /// nano's own `[hooks]`
}

string label(Source s) @safe pure nothrow
{
    final switch (s)
    {
    case Source.project: return "project";
    case Source.projectLocal: return "local";
    case Source.userClaude, Source.userNano: return "user";
    }
}

bool isProject(Source s) @safe pure nothrow
{
    return s == Source.project || s == Source.projectLocal;
}

/// A supported, runnable hook.
struct Hook
{
    Event event;
    string matcher; /// null = none
    string ifRule; /// null = none
    string command;
    bool hasArgs; /// exec form (`args` present, possibly empty)
    string[] args;
    Duration timeout = defaultTimeoutSecs.seconds;
    Source source = Source.userNano;
}

/// A hook nano could not run, and why.
struct Skipped
{
    string eventName;
    string reason;
    Source source;
}

/// A settings file that was read, with a content hash for the audit log.
struct LoadedFile
{
    string path;
    Source source;
    string hash;
}

/// Config inputs for loading hooks.
struct LoadOptions
{
    bool disableHooks;
    bool disableProjectHooks;
    bool claudeUserHooks = true;
    /// nano's `[hooks]` table (event name -> groups), as JSON.
    JSONValue nanoHooks;
    /// Home directory for `~/.claude/settings.json` (tests override it).
    string home;
    /// Project hooks run inside this sandbox when it is active.
    SandboxConfig sandbox;
}

enum Decision
{
    none,
    allow,
    ask,
    deny,
}

/// The combined result of every hook that ran for one event. Decisions
/// combine as deny beats ask beats allow; all context values are kept.
struct Outcome
{
    bool blocked;
    string blockReason; /// null = none
    Decision decision;
    JSONValue updatedInput; /// JSONType.null_ = none
    string[] context;
    string stop; /// null = none
    string[] systemMessages;

    private void absorb(HookResult r)
    {
        if (r.blocked)
        {
            blocked = true;
            if (blockReason is null) blockReason = r.reason;
            else if (r.reason.length) blockReason = r.reason;
        }
        if (r.decision > decision) decision = r.decision;
        if (r.updatedInput.type != JSONType.null_) updatedInput = r.updatedInput;
        context ~= r.context;
        if (r.stop !is null && stop is null) stop = r.stop;
        if (r.systemMessage !is null) systemMessages ~= r.systemMessage;
    }

    /// The combined additional context as one block, or null.
    string contextBlock() const
    {
        return context.length ? context.join("\n\n") : null;
    }

    /// Whether this (tool) outcome denies the call outright.
    bool denies() const
    {
        return blocked || decision == Decision.deny;
    }
}

private struct HookResult
{
    bool blocked;
    string reason;
    Decision decision;
    JSONValue updatedInput;
    string[] context;
    string stop;
    string systemMessage;
}

/// The loaded hook set plus the runtime context for executing them.
class HookManager
{
    Hook[] hooks;
    Skipped[] skipped;
    LoadedFile[] files;
    string projectDir;
    string sessionId;
    string transcriptPath;
    string permissionMode = "default";
    SandboxConfig sandbox;

    this(Hook[] hooks, string projectDir)
    {
        this.hooks = hooks;
        this.projectDir = projectDir;
    }

    /// Load hooks from every source: nano's `[hooks]`, `~/.claude/settings.json`,
    /// then the project's `.claude/settings.json` and `.claude/settings.local.json`
    /// at the repository root. A duplicate handler is kept once.
    static HookManager load(const ref LoadOptions opts, string cwd)
    {
        import nano.skills : gitRoot;
        auto root = gitRoot(cwd);
        auto m = new HookManager(null, root.length ? root : cwd);
        m.sandbox = SandboxConfig(opts.sandbox.mode, opts.sandbox.writable.dup, opts.sandbox.network, opts.sandbox.toolCaches);
        if (opts.disableHooks) return m;
        if (opts.nanoHooks.type == JSONType.object) m.ingestGroups(opts.nanoHooks, Source.userNano);
        if (opts.claudeUserHooks)
        {
            import std.process : environment;
            auto home = opts.home.length ? opts.home : environment.get("HOME", "");
            if (home.length) m.ingestFile(buildPath(home, ".claude", "settings.json"), Source.userClaude);
        }
        if (!opts.disableProjectHooks)
        {
            m.ingestFile(buildPath(m.projectDir, ".claude", "settings.json"), Source.project);
            m.ingestFile(buildPath(m.projectDir, ".claude", "settings.local.json"), Source.projectLocal);
        }
        m.dedup();
        return m;
    }

    private void ingestFile(string path, Source source)
    {
        import std.file : FileException, isFile;
        import std.utf : validate, UTFException;
        if (!exists(path)) return;
        string text;
        try
        {
            text = readText(path);
            validate(text);
        }
        catch (Exception e)
        {
            skipped ~= Skipped(path, "could not read settings file: " ~ e.msg, source);
            return;
        }
        auto hash = contentHash(text);
        JSONValue settings;
        try
        {
            settings = parseJSON(text);
            if (settings.type != JSONType.object) throw new JSONException("expected a JSON object");
        }
        catch (Exception e)
        {
            skipped ~= Skipped(path, "could not parse settings file: " ~ e.msg, source);
            return;
        }
        files ~= LoadedFile(path, source, hash);
        if (auto d = "disableAllHooks" in settings)
            if (d.type == JSONType.true_) return;
        if (auto h = "hooks" in settings)
        {
            if (h.type == JSONType.object) ingestGroups(*h, source);
            else skipped ~= Skipped(path, "`hooks` is not an object", source);
        }
    }

    private void ingestGroups(JSONValue groups, Source source)
    {
        foreach (eventName; groups.object.keys.sort.release)
        {
            auto list = groups[eventName];
            Event event;
            bool known = eventFromName(eventName, event);
            if (list.type != JSONType.array)
            {
                skipped ~= Skipped(eventName, "expected a list of matcher groups", source);
                continue;
            }
            foreach (group; list.array)
            {
                if (group.type != JSONType.object) continue;
                auto matcher = optString(group, "matcher");
                auto entries = "hooks" in group;
                if (entries is null || entries.type != JSONType.array) continue;
                foreach (entry; entries.array)
                {
                    if (entry.type != JSONType.object) continue;
                    if (!known)
                    {
                        skipped ~= Skipped(eventName, format("event `%s` not supported", eventName), source);
                        continue;
                    }
                    auto kind = optString(entry, "type");
                    if (kind is null) kind = "command";
                    if (kind != "command")
                    {
                        skipped ~= Skipped(eventName, format("handler type `%s` not supported", kind), source);
                        continue;
                    }
                    auto command = optString(entry, "command");
                    if (command is null || !command.strip.length)
                    {
                        skipped ~= Skipped(eventName, "command hook has no `command`", source);
                        continue;
                    }
                    // Validate the `if` filter now: a malformed rule would
                    // otherwise silently never match while listed as loaded.
                    auto ifRule = optString(entry, "if");
                    if (ifRule !is null && !ifRule.strip.length) ifRule = null;
                    if (ifRule !is null)
                        if (auto err = validateRule(ifRule))
                        {
                            skipped ~= Skipped(eventName, format("invalid `if` filter %s: %s", JSONValue(ifRule).toString, err), source);
                            continue;
                        }
                    Hook h;
                    h.event = event;
                    h.matcher = matcher !is null && matcher.length ? matcher : null;
                    h.ifRule = ifRule;
                    h.command = command;
                    if (auto a = "args" in entry)
                        if (a.type == JSONType.array)
                        {
                            h.hasArgs = true;
                            foreach (x; a.array) h.args ~= x.type == JSONType.string ? x.str : x.toString;
                        }
                    if (auto t = "timeout" in entry)
                    {
                        if (t.type == JSONType.integer && t.integer >= 0) h.timeout = timeoutOf(t.integer);
                        else if (t.type == JSONType.uinteger) h.timeout = timeoutOf(t.uinteger);
                    }
                    h.source = source;
                    hooks ~= h;
                }
            }
        }
    }

    /// Drop duplicate handlers (same event, matcher, `if` rule and command and
    /// args), keeping the first. Shell form (no args) stays distinct from exec
    /// form with no args.
    private void dedup()
    {
        bool[string] seen;
        Hook[] kept;
        foreach (h; hooks)
        {
            auto key = JSONValue([JSONValue(claudeName(h.event)), JSONValue(h.matcher), JSONValue(h.ifRule),
                JSONValue(h.command), h.hasArgs ? JSONValue(h.args) : JSONValue(null)]).toString;
            if (key in seen) continue;
            seen[key] = true;
            kept ~= h;
        }
        hooks = kept;
    }

    void setSession(string id, string transcript, string mode)
    {
        sessionId = id;
        transcriptPath = transcript;
        permissionMode = mode;
    }

    /// One-line startup notice for project hooks, or null.
    string startupNotice() const
    {
        string[] events;
        size_t n;
        foreach (h; hooks)
            if (h.source.isProject)
            {
                n++;
                events ~= claudeName(h.event);
            }
        size_t nSkipped;
        foreach (s; skipped) if (s.source.isProject) nSkipped++;
        if (!n && !nSkipped) return null;
        events = events.sort.uniq.array;
        auto notice = format("hooks: %s from .claude/settings.json (%s)", n, events.length ? events.join(", ") : "none");
        if (nSkipped) notice ~= format("; %s skipped", nSkipped);
        return notice;
    }

    /// The `/hooks` listing: loaded hooks, skipped hooks, files read.
    string listing() const
    {
        string out_;
        if (!hooks.length) out_ ~= "No hooks loaded.\n";
        else
        {
            out_ ~= "Hooks:\n";
            foreach (h; hooks)
                out_ ~= format("  [%s] %s %s -> %s\n", h.source.label, claudeName(h.event),
                    listingField(h.matcher !is null ? h.matcher : "*"), listingField(h.command));
        }
        if (skipped.length)
        {
            out_ ~= "Skipped:\n";
            foreach (s; skipped)
                out_ ~= format("  [%s] %s: %s\n", s.source.label, listingField(s.eventName), listingField(s.reason));
        }
        if (files.length)
        {
            out_ ~= "Loaded from:\n";
            foreach (f; files) out_ ~= format("  [%s] %s (%s)\n", f.source.label, listingField(f.path), f.hash);
        }
        return out_;
    }

    private const(Hook)[] selected(Event event, string claudeTool, string nanoTool, JSONValue args, string trigger) const
    {
        const(Hook)[] r;
        foreach (ref h; hooks)
        {
            if (h.event != event) continue;
            bool ok;
            if (nanoTool !is null) ok = matcherSelects(h.matcher, claudeTool, nanoTool) && ifSelects(h.ifRule, nanoTool, args);
            else if (trigger !is null) ok = sourceMatcherSelects(h.matcher, trigger);
            else ok = true;
            if (ok) r ~= h;
        }
        return r;
    }

    private JSONValue commonInput(Event event) const
    {
        JSONValue m = JSONValue(string[string].init);
        m["session_id"] = sessionId;
        m["transcript_path"] = transcriptPath;
        string cwd;
        try cwd = getcwd();
        catch (Exception) cwd = projectDir;
        m["cwd"] = cwd;
        m["permission_mode"] = permissionMode;
        m["hook_event_name"] = claudeName(event);
        return m;
    }

    Outcome runSessionStart(string trigger)
    {
        auto input = commonInput(Event.sessionStart);
        input["source"] = trigger;
        return runAll(selected(Event.sessionStart, null, null, JSONValue.init, trigger), Event.sessionStart, input);
    }

    Outcome runUserPromptSubmit(string prompt)
    {
        auto input = commonInput(Event.userPromptSubmit);
        input["prompt"] = prompt;
        return runAll(selected(Event.userPromptSubmit, null, null, JSONValue.init, null), Event.userPromptSubmit, input);
    }

    /// Called after the permission check allowed the call, before it runs.
    Outcome runPreToolUse(string nanoTool, JSONValue args, string toolUseId)
    {
        auto claude = claudeToolName(nanoTool);
        auto input = commonInput(Event.preToolUse);
        input["tool_name"] = claude;
        input["tool_input"] = toolInputFor(nanoTool, args);
        input["tool_use_id"] = toolUseId;
        return runAll(selected(Event.preToolUse, claude, nanoTool, args, null), Event.preToolUse, input);
    }

    Outcome runPostToolUse(string nanoTool, JSONValue args, string response, string toolUseId)
    {
        auto claude = claudeToolName(nanoTool);
        auto input = commonInput(Event.postToolUse);
        input["tool_name"] = claude;
        input["tool_input"] = toolInputFor(nanoTool, args);
        input["tool_response"] = response;
        input["tool_use_id"] = toolUseId;
        return runAll(selected(Event.postToolUse, claude, nanoTool, args, null), Event.postToolUse, input);
    }

    Outcome runStop(bool stopHookActive)
    {
        auto input = commonInput(Event.stop);
        input["stop_hook_active"] = stopHookActive;
        return runAll(selected(Event.stop, null, null, JSONValue.init, null), Event.stop, input);
    }

    private Outcome runAll(const(Hook)[] selected, Event event, JSONValue input)
    {
        Outcome o;
        auto json = input.toString;
        foreach (ref h; selected) o.absorb(interpret(event, h, execute(h, json, projectDir, h.source.isProject ? sandbox : SandboxConfig.init)));
        return o;
    }
}

private Duration timeoutOf(ulong secs) @safe pure nothrow
{
    // Durations are hnsecs in a long; anything that does not fit fails closed
    // at run time rather than wrapping to a tiny or negative timeout.
    return secs > long.max / 10_000_000 ? Duration.max : (cast(long) secs).seconds;
}

private string optString(JSONValue o, string key)
{
    if (auto v = key in o)
        if (v.type == JSONType.string) return v.str;
    return null;
}

// ---------------------------------------------------------------------------
// Matching.
// ---------------------------------------------------------------------------

/// A `matcher` selects a tool call when it matches the Claude name or the nano
/// name (`Edit|Write` and `edit_file` both work): exact, `A|B` alternation, or
/// a full-match regex. Absent, empty or `*` matches everything.
bool matcherSelects(string matcher, string claudeTool, string nanoTool)
{
    if (matcher is null) return true;
    auto m = matcher.strip;
    if (!m.length || m == "*") return true;
    foreach (p; m.split('|'))
        if (p.strip == claudeTool || p.strip == nanoTool) return true;
    return fullMatch(m, claudeTool) || fullMatch(m, nanoTool);
}

/// A `SessionStart` matcher selects on the source trigger (`startup`/`resume`).
bool sourceMatcherSelects(string matcher, string source)
{
    if (matcher is null) return true;
    auto m = matcher.strip;
    if (!m.length || m == "*") return true;
    foreach (p; m.split('|'))
        if (p.strip == source) return true;
    return fullMatch(m, source);
}

private bool fullMatch(string pattern, string text)
{
    import std.regex : regex, matchFirst;
    try return !matchFirst(text, regex("^(?:" ~ pattern ~ ")$")).empty;
    catch (Exception) return false;
}

private bool ifSelects(string ifRule, string nanoTool, JSONValue args)
{
    return ifRule is null || ruleMatches(ifRule, nanoTool, args);
}

// ---------------------------------------------------------------------------
// Tool-name and input translation (nano <-> Claude).
// ---------------------------------------------------------------------------

string claudeToolName(string nanoTool) @safe pure nothrow
{
    switch (nanoTool)
    {
    case "bash": return "Bash";
    case "read_file": return "Read";
    case "write_file": return "Write";
    case "edit_file": return "Edit";
    case "grep": return "Grep";
    case "glob": return "Glob";
    default: return nanoTool;
    }
}

/// nano's tool arguments presented as Claude's `tool_input`.
JSONValue toolInputFor(string nanoTool, JSONValue args)
{
    string[] keys;
    switch (nanoTool)
    {
    case "read_file": keys = ["offset", "limit"]; break;
    case "write_file": keys = ["content"]; break;
    case "edit_file": keys = ["old_string", "new_string", "replace_all"]; break;
    default: return args;
    }
    JSONValue m = JSONValue(string[string].init);
    if (args.type != JSONType.object) return m;
    if (auto p = "path" in args) m["file_path"] = *p;
    foreach (k; keys)
        if (auto v = k in args) m[k] = *v;
    return m;
}

/// Translate a hook's `updatedInput` (Claude `tool_input` space) back into
/// nano's argument space, merged onto the original arguments.
JSONValue applyUpdatedInput(string nanoTool, JSONValue original, JSONValue updated)
{
    if (updated.type != JSONType.object) return original;
    JSONValue r = JSONValue(string[string].init);
    if (original.type == JSONType.object)
        foreach (k, v; original.object) r[k] = v;
    bool fileTool = nanoTool == "read_file" || nanoTool == "write_file" || nanoTool == "edit_file";
    foreach (k, v; updated.object) r[fileTool && k == "file_path" ? "path" : k] = v;
    return r;
}

// ---------------------------------------------------------------------------
// Running one hook.
// ---------------------------------------------------------------------------

private string shellQuote(string text) pure
{
    return "'" ~ text.replace("'", `'\''`) ~ "'";
}

/// Raw result of running the hook process.
struct ProcessRun
{
    bool exited;
    int exit; /// valid when `exited`
    bool signalled;
    bool timedOut;
    string launchError; /// null = none
    string stdout_;
    string stderr_;
}

extern (C) private int setsid() nothrow @nogc;

/// Grace period after the deadline (or after the hook exits) for the pipes to
/// close before the hook's process group is killed and the run fails closed.
enum graceTime = 2.seconds;

/// Run `hook` with `input` on stdin, in a new session (no controlling
/// terminal) and its own process group, bounded by its timeout. Output past
/// `outputCap`, a descendant still holding a pipe past the deadline, or a read
/// error each fail the run (closed) rather than parsing partial output.
ProcessRun execute(const ref Hook hook, string input, string projectDir, const SandboxConfig sandbox = SandboxConfig.init)
{
    import std.process : spawnProcess, pipe, tryWait, wait, Config, Pid;
    import core.sys.posix.poll : pollfd, poll, POLLIN, POLLOUT, POLLHUP, POLLERR;
    import core.sys.posix.unistd : read, write, close;
    import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
    import core.sys.posix.signal : killpg, SIGKILL, signal, SIGPIPE, SIG_IGN;
    import core.stdc.errno : errno, EINTR, EAGAIN;

    ProcessRun r;
    if (hook.timeout == Duration.max)
    {
        r.launchError = "hook timeout is not representable";
        return r;
    }
    string[] argv;
    if (hook.hasArgs)
    {
        argv ~= expandProjectDir(hook.command, projectDir);
        foreach (a; hook.args) argv ~= expandProjectDir(a, projectDir);
    }
    else argv = ["bash", "-c", hook.command];
    if (sandbox.active)
    {
        // Fail closed: a hook that can't be sandboxed counts as failed (so a
        // PreToolUse hook blocks the call).
        string script = hook.command;
        if (hook.hasArgs) script = argv.map!shellQuote.join(" ");
        try argv = sandbox.command("bash", script, projectDir);
        catch (Exception e)
        {
            r.launchError = "sandbox could not be applied: " ~ e.msg;
            return r;
        }
    }

    // A hook that exits without reading stdin must not kill nano with SIGPIPE.
    signal(SIGPIPE, SIG_IGN);
    auto inP = pipe(), outP = pipe(), errP = pipe();
    Config cfg;
    cfg.preExecFunction = () @trusted nothrow @nogc { setsid(); return true; };
    Pid pid;
    try pid = spawnProcess(argv, inP.readEnd, outP.writeEnd, errP.writeEnd,
        ["CLAUDE_PROJECT_DIR": projectDir, "NANO_CODER": "1"], cfg, projectDir);
    catch (Exception e)
    {
        r.launchError = "could not start hook: " ~ e.msg;
        return r;
    }
    int inFd = inP.writeEnd.fileno, outFd = outP.readEnd.fileno, errFd = errP.readEnd.fileno;
    foreach (fd; [inFd, outFd, errFd]) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

    auto bytes = cast(const(ubyte)[]) input;
    size_t written;
    bool inOpen = true, outOpen = true, errOpen = true, overflow;
    string readError;
    ubyte[] outBuf, errBuf;
    if (!bytes.length)
    {
        inP.writeEnd.close();
        inOpen = false;
    }
    auto start = MonoTime.currTime;
    auto deadline = start + hook.timeout;
    bool exited;
    MonoTime exitedAt;
    ubyte[8192] chunk;

    void drain(int fd, ref ubyte[] buf, ref bool open)
    {
        for (;;)
        {
            auto n = read(fd, chunk.ptr, chunk.length);
            if (n > 0)
            {
                auto room = buf.length < outputCap ? outputCap - buf.length : 0;
                buf ~= chunk[0 .. n < room ? n : room];
                if (n > room) overflow = true;
                continue;
            }
            if (n == 0) open = false;
            else if (errno == EINTR) continue;
            else if (errno != EAGAIN)
            {
                if (readError is null) readError = format("read failed (errno %s)", errno);
                open = false;
            }
            return;
        }
    }

    for (;;)
    {
        if (!exited)
        {
            auto st = tryWait(pid);
            if (st.terminated)
            {
                exited = true;
                exitedAt = MonoTime.currTime;
                r.exited = st.status >= 0;
                r.exit = st.status;
                r.signalled = st.status < 0;
            }
        }
        if (exited && !outOpen && !errOpen && !inOpen) break;
        auto now = MonoTime.currTime;
        if (!exited && now >= deadline)
        {
            killpg(pid.processID, SIGKILL);
            // Bounded reap; a stuck reap is abandoned.
            auto reapBy = MonoTime.currTime + graceTime;
            while (!tryWait(pid).terminated && MonoTime.currTime < reapBy) {
                import core.thread : Thread;
                Thread.sleep(10.msecs);
            }
            r = ProcessRun.init;
            r.timedOut = true;
            break;
        }
        // The hook exited but a descendant still holds a pipe: wait out the
        // deadline plus a grace period, then fail closed.
        auto ioLimit = (deadline > exitedAt ? deadline : exitedAt) + graceTime;
        if (exited && now >= ioLimit)
        {
            killpg(pid.processID, SIGKILL);
            r.launchError = "hook did not finish its I/O before the deadline; a descendant may still be running";
            break;
        }
        pollfd[3] fds;
        size_t nfds;
        if (outOpen) fds[nfds++] = pollfd(outFd, POLLIN);
        if (errOpen) fds[nfds++] = pollfd(errFd, POLLIN);
        if (inOpen) fds[nfds++] = pollfd(inFd, POLLOUT);
        poll(fds.ptr, cast(uint) nfds, 20);
        if (outOpen) drain(outFd, outBuf, outOpen);
        if (errOpen) drain(errFd, errBuf, errOpen);
        if (inOpen)
        {
            auto n = write(inFd, bytes.ptr + written, bytes.length - written);
            if (n > 0) written += n;
            else if (n < 0 && errno != EAGAIN && errno != EINTR) written = bytes.length; // EPIPE: hook closed stdin
            if (written >= bytes.length)
            {
                inP.writeEnd.close();
                inOpen = false;
            }
        }
    }
    if (inOpen) inP.writeEnd.close();
    if (r.timedOut) return r;
    import nano.tools : lossyUtf8;
    r.stdout_ = lossyUtf8(outBuf);
    r.stderr_ = lossyUtf8(errBuf);
    if (r.launchError is null)
    {
        if (overflow) r.launchError = format("hook output exceeded %s bytes", outputCap);
        else if (readError !is null) r.launchError = "could not read hook output: " ~ readError;
    }
    return r;
}

private string expandProjectDir(string text, string dir) @safe pure
{
    return text.replace("${CLAUDE_PROJECT_DIR}", dir).replace("$CLAUDE_PROJECT_DIR", dir);
}

/// Interpret a process run per the Claude protocol, with nano's fail-closed
/// `PreToolUse` behaviour.
private HookResult interpret(Event event, const ref Hook hook, ProcessRun run)
{
    HookResult r;
    string failure = run.launchError;
    if (failure is null)
    {
        if (run.timedOut) failure = format("hook timed out after %ss", hook.timeout.total!"seconds");
        else if (run.signalled || !run.exited) failure = "hook was terminated";
        else if (run.exit != 0 && run.exit != 2) failure = format("hook exited with code %s", run.exit);
    }
    if (failure !is null)
    {
        if (event == Event.preToolUse)
        {
            r.blocked = true;
            r.decision = Decision.deny;
            r.reason = format("%s (%s)", hook.command, failure);
        }
        return r;
    }
    if (run.exit == 2)
    {
        r.blocked = true;
        r.reason = cap(run.stderr_.strip);
        if (event == Event.preToolUse) r.decision = Decision.deny;
        return r;
    }
    auto trimmed = run.stdout_.strip;
    JSONValue parsed;
    bool isJson;
    if (trimmed.startsWith("{"))
    {
        try
        {
            parsed = parseJSON(trimmed);
            isJson = parsed.type == JSONType.object;
        }
        catch (Exception) {}
    }
    if (isJson) applyJsonOutput(event, parsed, r);
    else if (trimmed.length && (event == Event.sessionStart || event == Event.userPromptSubmit))
        r.context ~= cap(trimmed);
    return r;
}

private void applyJsonOutput(Event event, JSONValue json, ref HookResult r)
{
    static string getStr(JSONValue v, string key)
    {
        if (v.type != JSONType.object) return null;
        if (auto x = key in v)
            if (x.type == JSONType.string) return cap(x.str);
        return null;
    }
    if (auto c = "continue" in json)
        if (c.type == JSONType.false_)
        {
            auto s = getStr(json, "stopReason");
            r.stop = s !is null ? s : "";
        }
    if (auto m = getStr(json, "systemMessage")) r.systemMessage = m;
    switch (getStr(json, "decision"))
    {
    case "block":
        r.blocked = true;
        r.reason = getStr(json, "reason");
        break;
    case "approve", "allow":
        if (event == Event.preToolUse) r.decision = Decision.allow;
        break;
    default:
        break;
    }
    if (auto specific = "hookSpecificOutput" in json)
    {
        if (auto ctx = getStr(*specific, "additionalContext")) r.context ~= ctx;
        if (event == Event.preToolUse && specific.type == JSONType.object)
        {
            switch (getStr(*specific, "permissionDecision"))
            {
            case "allow": r.decision = Decision.allow; break;
            case "deny":
                r.decision = Decision.deny;
                r.blocked = true;
                auto why = getStr(*specific, "permissionDecisionReason");
                if (why !is null) r.reason = why;
                break;
            case "ask": r.decision = Decision.ask; break;
            default: break;
            }
            if (auto u = "updatedInput" in *specific) r.updatedInput = *u;
        }
    }
    if (auto ctx = getStr(json, "additionalContext")) r.context ~= ctx;
}

/// Single-line sanitiser for config-derived text in the `/hooks` listing:
/// control characters become visible control pictures and U+2028/U+2029
/// become ␤, so a crafted command cannot forge an extra listing row.
string listingField(string text)
{
    import std.utf : byDchar;
    string out_;
    foreach (dchar c; text.byDchar)
    {
        if (c == '\u2028' || c == '\u2029') out_ ~= '\u2424';
        else if (c <= 0x1f) out_ ~= cast(dchar)(0x2400 + c);
        else if (c == 0x7f) out_ ~= '\u2421';
        else out_ ~= c;
    }
    return out_;
}

/// Cap a field at `fieldCap` characters (not bytes); over the cap keep
/// `fieldCap - 1` characters plus an ellipsis.
string cap(string text)
{
    import std.utf : byDchar;
    import std.range : take;
    import std.algorithm : count;
    if (text.byDchar.take(fieldCap + 1).count <= fieldCap) return text;
    string kept;
    foreach (c; text.byDchar.take(fieldCap - 1)) kept ~= c;
    return kept ~ "…";
}

/// A short, stable hash of a settings file's contents: Rust's
/// `DefaultHasher` (SipHash-1-3, zero keys) over `str`'s `Hash`, so both
/// ports log the same value.
string contentHash(string text) @safe pure
{
    auto data = cast(const(ubyte)[]) text ~ cast(ubyte) 0xff;
    return format!"%016x"(sipHash13(data));
}

private ulong sipHash13(const(ubyte)[] data) @safe pure nothrow
{
    import core.bitop : rol;
    ulong v0 = 0x736f6d6570736575, v1 = 0x646f72616e646f6d, v2 = 0x6c7967656e657261, v3 = 0x7465646279746573;
    void round()
    {
        v0 += v1; v1 = rol(v1, 13); v1 ^= v0; v0 = rol(v0, 32);
        v2 += v3; v3 = rol(v3, 16); v3 ^= v2;
        v0 += v3; v3 = rol(v3, 21); v3 ^= v0;
        v2 += v1; v1 = rol(v1, 17); v1 ^= v2; v2 = rol(v2, 32);
    }
    auto len = data.length;
    size_t i;
    for (; i + 8 <= len; i += 8)
    {
        ulong m;
        foreach (j; 0 .. 8) m |= cast(ulong) data[i + j] << (8 * j);
        v3 ^= m;
        round();
        v0 ^= m;
    }
    ulong b = cast(ulong)(len & 0xff) << 56;
    foreach (j; 0 .. len - i) b |= cast(ulong) data[i + j] << (8 * j);
    v3 ^= b;
    round();
    v0 ^= b;
    v2 ^= 0xff;
    round();
    round();
    round();
    return v0 ^ v1 ^ v2 ^ v3;
}

// ---------------------------------------------------------------------------
// Tests (ported from src/claude_hooks.rs).
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.file : mkdirRecurse, write, rmdirRecurse, tempDir, setAttributes;
    import std.array : replicate;

    private string tdir(string name)
    {
        auto d = buildPath(tempDir, "nano-d-hooks-" ~ name);
        if (exists(d)) rmdirRecurse(d);
        mkdirRecurse(d);
        return d;
    }

    private string script(string dir, string name, string body_)
    {
        auto p = buildPath(dir, name);
        write(p, body_);
        setAttributes(p, octal!755);
        return p;
    }

    import std.conv : octal;

    private Hook cmd(Event e, string command)
    {
        Hook h;
        h.event = e;
        h.command = command;
        h.timeout = 10.seconds;
        return h;
    }

    private HookManager with_(Hook[] hooks, string dir)
    {
        auto m = new HookManager(hooks, dir);
        m.sessionId = "s1";
        return m;
    }

    private JSONValue j(string s) { return parseJSON(s); }

    private HookManager loadProject(string dir, string settings, bool disable = false, bool noProject = false)
    {
        mkdirRecurse(buildPath(dir, ".git"));
        mkdirRecurse(buildPath(dir, ".claude"));
        if (settings !is null) write(buildPath(dir, ".claude", "settings.json"), settings);
        LoadOptions o;
        o.disableHooks = disable;
        o.disableProjectHooks = noProject;
        o.claudeUserHooks = false;
        return HookManager.load(o, dir);
    }
}

unittest // matcher_matches_claude_and_nano_names, source_matcher_alternation_and_wildcard
{
    assert(matcherSelects("Edit|Write", "Edit", "edit_file"));
    assert(matcherSelects("edit_file", "Edit", "edit_file"));
    assert(matcherSelects("Bash", "Bash", "bash"));
    assert(!matcherSelects("Read", "Bash", "bash"));
    assert(matcherSelects(null, "Bash", "bash"));
    assert(matcherSelects("*", "Bash", "bash"));
    assert(matcherSelects("Edit|Write|Read", "Read", "read_file"));
    assert(matcherSelects("Ed.*", "Edit", "edit_file"), "regex matcher");
    assert(sourceMatcherSelects("startup|resume", "startup"));
    assert(sourceMatcherSelects("startup|resume", "resume"));
    assert(!sourceMatcherSelects("startup|resume", "clear"));
    assert(sourceMatcherSelects("*", "clear"));
    assert(sourceMatcherSelects(null, "clear"));
    assert(!sourceMatcherSelects("resume", "startup"));
}

unittest // translates_tool_input_both_ways
{
    auto args = j(`{"path": "a.txt", "old_string": "x", "new_string": "y"}`);
    auto input = toolInputFor("edit_file", args);
    assert(input["file_path"].str == "a.txt" && input["old_string"].str == "x" && ("path" in input) is null);
    auto back = applyUpdatedInput("edit_file", args, j(`{"file_path": "b.txt", "new_string": "z"}`));
    assert(back["path"].str == "b.txt" && back["new_string"].str == "z" && back["old_string"].str == "x");
    assert(claudeToolName("grep") == "Grep" && claudeToolName("glob") == "Glob");
}

unittest // grep_and_glob_hooks_match_claude_names, reads_tool_input_command_like_a_claude_script
{
    auto dir = tdir("grep");
    auto h = cmd(Event.preToolUse, "exit 2");
    h.matcher = "Grep";
    auto m = with_([h], dir);
    assert(m.runPreToolUse("grep", j(`{"pattern": "needle"}`), "t1").denies);
    assert(!m.runPreToolUse("read_file", j(`{"path": "a.txt"}`), "t2").denies);

    auto guard = script(dir, "guard.sh", "#!/usr/bin/env bash\nread -r line\necho \"$line\" | grep -q 'rm -rf' && exit 2\nexit 0\n");
    auto m2 = with_([cmd(Event.preToolUse, guard ~ " ")], dir);
    assert(m2.runPreToolUse("bash", j(`{"command": "rm -rf /"}`), "t1").denies);
    assert(!m2.runPreToolUse("bash", j(`{"command": "ls"}`), "t2").denies);
}

unittest // pre_tool_use_json_permission_decision, fails closed on crash; post crash non-blocking
{
    auto dir = tdir("json");
    auto deny = script(dir, "deny.sh", "#!/usr/bin/env bash\ncat >/dev/null\necho '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"nope\"}}'\n");
    auto o = with_([cmd(Event.preToolUse, deny)], dir).runPreToolUse("bash", j(`{"command": "ls"}`), "t1");
    assert(o.denies && o.blockReason == "nope" && o.decision == Decision.deny);
    assert(with_([cmd(Event.preToolUse, "exit 7")], dir).runPreToolUse("bash", j(`{"command": "ls"}`), "t1").denies);
    assert(!with_([cmd(Event.postToolUse, "exit 7")], dir).runPostToolUse("bash", j(`{"command": "ls"}`), "ok", "t1").blocked);
}

unittest // session_start_matcher_selects_on_source_trigger, plain text becomes context
{
    auto dir = tdir("start");
    auto s = cmd(Event.sessionStart, "echo from-startup");
    s.matcher = "startup";
    auto r = cmd(Event.sessionStart, "echo from-resume");
    r.matcher = "resume";
    auto m = with_([s, r, cmd(Event.sessionStart, "echo always")], dir);
    auto onStart = m.runSessionStart("startup").contextBlock;
    assert(onStart.canFind("from-startup") && !onStart.canFind("from-resume") && onStart.canFind("always"));
    auto onResume = m.runSessionStart("resume").contextBlock;
    assert(onResume.canFind("from-resume") && !onResume.canFind("from-startup") && onResume.canFind("always"));
    assert(with_([cmd(Event.sessionStart, "echo hello world")], dir).runSessionStart("startup").contextBlock == "hello world");
}

unittest // hook_that_ignores_large_stdin_does_not_deadlock; user_prompt_submit_exit_2_blocks_with_stderr
{
    auto dir = tdir("stdin");
    auto big = JSONValue(["command": JSONValue("x".replicate(1_000_000))]);
    assert(!with_([cmd(Event.postToolUse, "echo done")], dir).runPostToolUse("bash", big, "ok", "t1").blocked);
    auto o = with_([cmd(Event.userPromptSubmit, "echo secret-detected >&2; exit 2")], dir).runUserPromptSubmit("hi");
    assert(o.blocked && o.blockReason == "secret-detected");
}

unittest // hook_receives_env_and_updated_input; input JSON reaches the hook
{
    auto dir = tdir("env");
    auto up = script(dir, "update.sh", "#!/usr/bin/env bash\ncat >/dev/null\n[ \"$NANO_CODER\" = 1 ] || exit 2\n[ -d \"$CLAUDE_PROJECT_DIR\" ] || exit 2\necho '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"echo patched\"}}}'\n");
    auto o = with_([cmd(Event.preToolUse, up)], dir).runPreToolUse("bash", j(`{"command": "echo original"}`), "t1");
    assert(o.decision == Decision.allow && o.updatedInput["command"].str == "echo patched");

    auto rec = buildPath(dir, "input.json");
    with_([cmd(Event.preToolUse, "cat > " ~ rec)], dir).runPreToolUse("write_file", j(`{"path": "a.txt", "content": "c"}`), "t9");
    auto got = parseJSON(readText(rec));
    assert(got["hook_event_name"].str == "PreToolUse" && got["tool_name"].str == "Write" && got["tool_use_id"].str == "t9");
    assert(got["tool_input"]["file_path"].str == "a.txt" && got["session_id"].str == "s1" && got["permission_mode"].str == "default");
}

unittest // exec form expands ${CLAUDE_PROJECT_DIR} and passes args verbatim
{
    auto dir = tdir("exec");
    auto h = cmd(Event.sessionStart, "/bin/echo");
    h.hasArgs = true;
    h.args = ["${CLAUDE_PROJECT_DIR}/x", "a b", "$HOME"];
    assert(with_([h], dir).runSessionStart("startup").contextBlock == dir ~ "/x a b $HOME");
}

unittest // if_rule_narrows_tool_hooks; stop_block_keeps_going; timeout_blocks_pre_tool_use_only
{
    auto dir = tdir("if");
    auto h = cmd(Event.preToolUse, "exit 2");
    h.ifRule = "Bash(git push *)";
    auto m = with_([h], dir);
    assert(!m.runPreToolUse("bash", j(`{"command": "ls"}`), "t1").denies);
    assert(m.runPreToolUse("bash", j(`{"command": "git push origin main"}`), "t2").denies);
    auto s = with_([cmd(Event.stop, `echo '{"decision":"block","reason":"keep going"}'`)], dir).runStop(false);
    assert(s.blocked && s.blockReason == "keep going");
    auto t = cmd(Event.preToolUse, "sleep 5");
    t.timeout = 200.msecs;
    auto start = MonoTime.currTime;
    assert(with_([t], dir).runPreToolUse("bash", j(`{"command": "ls"}`), "t1").denies);
    assert(MonoTime.currTime - start < 3.seconds);
    auto tp = cmd(Event.postToolUse, "sleep 5");
    tp.timeout = 200.msecs;
    assert(!with_([tp], dir).runPostToolUse("bash", j(`{"command": "ls"}`), "ok", "t1").blocked);
}

unittest // loads_and_dedups_from_settings_files; disable flags; disableAllHooks
{
    auto dir = tdir("load");
    auto m = loadProject(dir, `{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}],
        "Nope":[{"hooks":[{"type":"command","command":"x"}]}],
        "PostToolUse":[{"hooks":[{"type":"http","command":"x"}]}]}}`);
    assert(m.hooks.length == 1 && m.hooks[0].event == Event.preToolUse);
    assert(m.skipped.length == 2 && m.startupNotice !is null && m.files.length == 1);
    assert(m.files[0].hash.length == 16);

    auto one = `{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}`;
    assert(loadProject(tdir("off1"), one, true).hooks.length == 0);
    assert(loadProject(tdir("off2"), one, false, true).hooks.length == 0);
    auto d = loadProject(tdir("off3"), `{"disableAllHooks":true,"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}`);
    assert(d.hooks.length == 0 && d.files.length == 1);

    auto missing = loadProject(tdir("missing"), null);
    assert(missing.hooks.length == 0 && missing.skipped.length == 0);
}

unittest // nano [hooks] and ~/.claude/settings.json load alongside the project; duplicates collapse
{
    import nano.toml : parseToml;
    auto dir = tdir("sources");
    auto home = buildPath(dir, "home");
    mkdirRecurse(buildPath(home, ".claude"));
    write(buildPath(home, ".claude", "settings.json"), `{"hooks":{"Stop":[{"hooks":[{"command":"echo user"}]}]}}`);
    auto proj = buildPath(dir, "proj");
    mkdirRecurse(buildPath(proj, ".git"));
    mkdirRecurse(buildPath(proj, ".claude"));
    write(buildPath(proj, ".claude", "settings.json"), `{"hooks":{"Stop":[{"hooks":[{"command":"echo nano"}]}]}}`);
    LoadOptions o;
    o.home = home;
    o.nanoHooks = parseToml("[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ncommand = \"echo nano\"\ntimeout = 5\n")["hooks"];
    auto m = HookManager.load(o, proj);
    assert(m.hooks.length == 2, m.listing);
    assert(m.hooks[0].source == Source.userNano && m.hooks[0].timeout == 5.seconds);
    assert(m.hooks[1].source == Source.userClaude);
}

unittest // unreadable_settings_file_is_reported_not_silently_skipped
{
    import core.sys.posix.unistd : geteuid;
    if (geteuid() == 0) return; // root reads mode-0 files
    auto dir = tdir("unreadable");
    auto m0 = loadProject(dir, `{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}`);
    auto settings = buildPath(dir, ".claude", "settings.json");
    setAttributes(settings, 0);
    LoadOptions o;
    o.claudeUserHooks = false;
    auto m = HookManager.load(o, dir);
    setAttributes(settings, octal!644);
    assert(m.hooks.length == 0 && m.skipped.length == 1);
    assert(m.skipped[0].reason.canFind("could not read settings file"), m.skipped[0].reason);
}

unittest // dedup_keeps_entries_with_distinct_if_rules, shell vs exec, empty-argument boundaries
{
    auto dir = tdir("dedup");
    auto push = cmd(Event.preToolUse, "echo hi");
    push.matcher = "Bash";
    push.ifRule = "Bash(git push *)";
    auto commit = push;
    commit.ifRule = "Bash(git commit *)";
    auto noRule = push;
    noRule.ifRule = null;
    auto m = with_([push, commit, noRule, push], dir);
    m.dedup();
    assert(m.hooks.length == 3);

    auto shell = cmd(Event.preToolUse, "echo hi");
    auto direct = shell;
    direct.hasArgs = true;
    m = with_([shell, direct], dir);
    m.dedup();
    assert(m.hooks.length == 2);

    auto emptyArg = direct, two = direct, joined = direct;
    emptyArg.args = [""];
    two.args = ["a", "b"];
    joined.args = ["a\0b"];
    m = with_([direct, emptyArg, two, joined], dir);
    m.dedup();
    assert(m.hooks.length == 4);
}

unittest // over-cap output fails closed for PreToolUse and is bounded
{
    auto dir = tdir("cap");
    assert(with_([cmd(Event.preToolUse, `head -c 2000000 /dev/zero | tr '\0' 'a'`)], dir)
        .runPreToolUse("bash", j(`{"command": "ls"}`), "t1").denies);
    assert(!with_([cmd(Event.postToolUse, `head -c 5000000 /dev/zero | tr '\0' 'b'`)], dir)
        .runPostToolUse("bash", j(`{"command": "ls"}`), "ok", "t1").blocked);
}

unittest // detached descendant / unfinished I/O cannot hang the runner and fails closed
{
    auto dir = tdir("detached");
    // macOS has no setsid(1); perl's POSIX::setsid leaves the hook's group too.
    auto h = cmd(Event.preToolUse, `printf '%s' '{"hookSpecificOutput":{"permissionDecision":"deny"}}'; perl -MPOSIX -e 'setsid; sleep 3' & exit 0`);
    h.timeout = 300.msecs;
    auto start = MonoTime.currTime;
    auto o = with_([h], dir).runPreToolUse("bash", j(`{"command": "ls"}`), "t1");
    assert(MonoTime.currTime - start < 3.seconds);
    assert(o.denies);
    auto ok = cmd(Event.preToolUse, `perl -MPOSIX -e 'setsid; sleep 3' & exit 0`);
    ok.timeout = 300.msecs;
    assert(with_([ok], dir).runPreToolUse("bash", j(`{"command": "ls"}`), "t1").denies, "unfinished I/O fails closed");
}

unittest // unrepresentable_timeout_fails_closed_instead_of_panicking; new session
{
    auto dir = tdir("timeout");
    auto h = cmd(Event.preToolUse, "echo hi");
    h.timeout = timeoutOf(ulong.max);
    assert(with_([h], dir).runPreToolUse("bash", j(`{"command": "ls"}`), "t1").denies);
    auto s = cmd(Event.preToolUse, `echo "$$ $(ps -o sess= -p $$ | tr -d ' ') $(ps -o pgid= -p $$ | tr -d ' ')"`);
    auto run = execute(s, "{}", dir);
    assert(run.launchError is null);
    auto parts = run.stdout_.strip.split(' ');
    assert(parts.length >= 3 && parts[0] == parts[2], "the hook leads its own process group: " ~ run.stdout_);
}

unittest // malformed_if_filter_is_reported_as_skipped; blank_if_filter_is_normalized_to_none
{
    auto m = loadProject(tdir("badif"), `{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
        {"type":"command","command":"echo bad","if":"Bash(git push *"},
        {"type":"command","command":"echo good","if":"Bash(git push *)"}]}]}}`);
    assert(m.hooks.length == 1 && m.hooks[0].command == "echo good");
    assert(m.skipped.length == 1 && m.skipped[0].reason.canFind("invalid `if` filter"));
    auto b = loadProject(tdir("blankif"), `{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi","if":"   "}]}]}}`);
    assert(b.hooks.length == 1 && b.hooks[0].ifRule is null);
    assert(b.selected(Event.preToolUse, "Bash", "bash", j(`{"command":"ls"}`), null).length == 1);
}

unittest // listing_neutralises_line_breaks_in_config_fields
{
    import std.string : lineSplitter;
    auto dir = tdir("listing");
    auto h = cmd(Event.stop, "evil\n  [user] Stop * -> forged");
    h.matcher = "Stop\n  [user] forged";
    h.source = Source.project;
    auto m = with_([h], dir);
    m.skipped ~= Skipped("Bad\n  [user] forged", "broken\n  [user] forged", Source.project);
    m.files ~= LoadedFile(buildPath(dir, ".claude/settings.json\n  [user] forged"), Source.project, "abc123");
    auto listing = m.listing;
    foreach (line; listing.lineSplitter)
        if (line.startsWith("  [")) assert(line.startsWith("  [project]"), line);
    assert(listing.canFind("evil␊  [user] Stop * -> forged"), listing);
}

unittest // cap_counts_characters_not_bytes
{
    import std.range : walkLength;
    auto emoji = "🦀".replicate(4_000);
    assert(cap(emoji) == emoji);
    auto atCap = "a".replicate(fieldCap);
    assert(cap(atCap) == atCap);
    auto capped = cap("🦀".replicate(fieldCap + 10));
    assert(capped.endsWith("…") && capped.walkLength == fieldCap);
    assert(cap("x".replicate(fieldCap + 1)).walkLength == fieldCap);
}

import std.algorithm : endsWith;

unittest // read errors fail PreToolUse closed; content hash matches Rust's DefaultHasher
{
    ProcessRun run;
    run.exited = true;
    run.launchError = "could not read hook output: injected read failure";
    auto h = cmd(Event.preToolUse, "true");
    auto r = interpret(Event.preToolUse, h, run);
    assert(r.blocked && r.decision == Decision.deny);
    // Values printed by rustc's std::collections::hash_map::DefaultHasher.
    assert(contentHash("") == "30406ea523c53def");
    assert(contentHash(`{"hooks":{}}`) == "6647320c7e280bfa");
    assert(contentHash("a fairly long settings text that spans more than eight bytes") == "1a7f6a17e1f1d383");
}

// Project hooks run inside an active sandbox (user hooks don't); a project
// hook that can't be sandboxed fails closed.
version (OSX) unittest
{
    import nano.sandbox : SandboxMode;
    import nano.paths : canonicalize;
    import std.file : mkdirRecurse, rmdirRecurse, exists, getcwd;
    import std.process : thisProcessID;
    auto base = getcwd ~ format("/.dub/hook-sbx-%s", thisProcessID);
    auto ws = base ~ "/ws", outside = base ~ "/out";
    mkdirRecurse(ws);
    mkdirRecurse(outside);
    scope (exit) rmdirRecurse(base);
    Hook hook(Source src, string file)
    {
        Hook h;
        h.event = Event.userPromptSubmit;
        h.command = format("echo x > %s/%s; echo x > inside-%s; exit 0", outside, file, file);
        h.timeout = 10.seconds;
        h.source = src;
        return h;
    }
    auto m = new HookManager([hook(Source.project, "project"), hook(Source.userClaude, "user")], ws);
    m.sandbox.mode = SandboxMode.workspace;
    m.sandbox.toolCaches = false;
    m.runUserPromptSubmit("hi");
    assert(exists(ws ~ "/inside-project") && exists(ws ~ "/inside-user"));
    assert(!exists(outside ~ "/project"), "a sandboxed project hook wrote outside the workspace");
    assert(exists(outside ~ "/user"), "user hooks run outside the sandbox");

    // Exec form goes through the sandbox too, quoted.
    Hook ex;
    ex.event = Event.userPromptSubmit;
    ex.command = "/bin/sh";
    ex.args = ["-c", format("echo x > '%s/exec'; echo it's ok", outside)];
    ex.hasArgs = true;
    ex.timeout = 10.seconds;
    ex.source = Source.project;
    auto run = execute(ex, "{}", ws, m.sandbox);
    assert(run.exited && !exists(outside ~ "/exec"), run.stdout_ ~ run.stderr_);
}
