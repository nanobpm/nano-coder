/// The agent loop: send the conversation, stream the reply, run the tool
/// calls it asks for (after permission checks), feed results back, repeat.
module nano.agent;

import std.json;
import std.format : format;
import std.string : strip;
import std.array : join;
import std.conv : to;
import nano.llm;
import nano.tools;
import nano.permissions;
import nano.session;
import nano.control;
import nano.claude_hooks : HookManager, Decision, applyUpdatedInput, maxStopBlocks;

/// What the loop reports as it works (the CLI renders these).
interface AgentEvents
{
    void text(bool reasoning, string chunk);
    void toolStart(const ref ToolCall call);
    void toolEnd(const ref ToolCall call, string result, bool isError);
    void usage(TokenUsage u);
    /// A steering message joined the conversation mid-turn.
    void userMessage(string text);
    /// A complete model reply (after its deltas went to `text`).
    void assistantMessage(string text, string reasoning);
}

/// Wrap text the model should read as a system note, not user words.
string wrapReminder(string text)
{
    return "<system-reminder>\n" ~ text ~ "\n</system-reminder>";
}

/// Why a turn ended (ACP `stopReason`).
enum StopReason : string
{
    endTurn = "end_turn",
    cancelled = "cancelled",
    maxTurnRequests = "max_turn_requests",
    maxTokens = "max_tokens",
}

class Agent
{
    LLMClient client;
    ToolRegistry tools;
    Policy policy;
    Message[] messages;
    long maxIterations;
    long maxTokens;
    double temperature = double.nan;
    SessionLog log;
    TokenUsage lastUsage;
    /// Steer or cancel the running turn from another thread.
    TurnControl control;
    /// Why the last `run` ended.
    StopReason lastStop;
    /// Claude Code-compatible user hooks (null = none).
    HookManager hooks;
    /// Whether this agent continues a restored session (`SessionStart` source).
    bool resumed;
    private bool sessionStarted;
    private string pendingStartContext;
    private int stopBlocks;

    this(LLMClient client, ToolRegistry tools, Policy policy, string systemPrompt)
    {
        this.client = client;
        this.tools = tools;
        this.policy = policy;
        this.control = new TurnControl;
        if (systemPrompt.length) push(Message.system(systemPrompt));
    }

    void push(Message m)
    {
        import nano.session : nowStamp;
        if (!m.timestamp.length) m.timestamp = nowStamp();
        messages ~= m;
        if (log !is null) log.append(m);
    }

    /// Run one user input to completion. Returns the final assistant text,
    /// or `cancelledResponse` when the turn was cancelled. Steers that arrive
    /// too late for this turn stay in `control` for the caller to queue.
    /// Pass `resetControl = false` when the caller already called
    /// `control.startTurn()`, so a cancel routed before `run` began is kept.
    string run(string input, AgentEvents ev, bool resetControl = true)
    {
        import std.datetime.systime : Clock;
        // Every input carries an id; the log pairs it with a turn_end record,
        // so an input without one marks a turn a crash interrupted.
        auto inputId = format("in-%s-%s", (Clock.currStdTime - 621_355_968_000_000_000L) / 10_000, ++inputCounter);
        if (log !is null) log.input(inputId, input);
        string response;
        try response = runTurn(input, ev, resetControl);
        catch (Exception e)
        {
            if (log !is null) log.turnEnd(inputId, "Error: " ~ e.msg, "end_turn");
            throw e;
        }
        if (log !is null) log.turnEnd(inputId, response, cast(string) lastStop);
        return response;
    }

    private size_t inputCounter;

    private string runTurn(string input, AgentEvents ev, bool resetControl)
    {
        if (resetControl) control.startTurn();
        stopBlocks = 0;
        if (hooks !is null)
        {
            syncHookSession();
            if (!sessionStarted)
            {
                // Runs once; its context waits for the first accepted prompt.
                sessionStarted = true;
                auto start = hooks.runSessionStart(resumed ? "resume" : "startup");
                if (auto ctx = start.contextBlock) pendingStartContext = ctx;
            }
            auto o = hooks.runUserPromptSubmit(input);
            if (o.blocked)
            {
                push(Message.user(input));
                auto reason = o.blockReason.strip.length ? o.blockReason : "Your message was blocked by a UserPromptSubmit hook.";
                push(Message.assistant(reason, null));
                ev.text(false, reason);
                ev.assistantMessage(reason, null);
                lastStop = StopReason.endTurn;
                return reason;
            }
            string[] extra;
            if (pendingStartContext !is null) extra ~= pendingStartContext;
            pendingStartContext = null;
            if (auto ctx = o.contextBlock) extra ~= ctx;
            if (extra.length) input ~= "\n\n" ~ wrapReminder(extra.join("\n\n"));
        }
        push(Message.user(input));
        string last;
        for (long i = 0; maxIterations <= 0 || i < maxIterations; i++)
        {
            if (control.isCancelled) return cancelled(ev);
            foreach (s; control.takePending)
            {
                push(Message.user(s.text));
                ev.userMessage(s.text);
                control.absorbed(s);
            }
            ChatRequest req;
            req.messages = messages;
            req.tools = tools.definitions;
            req.maxTokens = maxTokens;
            req.temperature = temperature;
            LLMResponse r;
            import std.datetime.stopwatch : StopWatch, AutoStart;
            auto sw = StopWatch(AutoStart.yes);
            try r = client.chat(req, (bool t, string s) { ev.text(t, s); });
            catch (Cancelled) return cancelled(ev);
            catch (Exception e)
            {
                if (control.isCancelled) return cancelled(ev);
                throw e;
            }
            lastUsage = r.usage;
            ev.usage(r.usage);
            auto reply = Message.assistant(r.content, r.toolCalls);
            reply.thinking = r.reasoning;
            reply.usage = r.usage;
            reply.hasUsage = r.usage != TokenUsage.init;
            reply.durationMs = sw.peek.total!"msecs";
            reply.stopReason = r.toolCalls.length ? "tool_use"
                : (r.stopReason == "length" || r.stopReason == "max_tokens") ? "max_tokens" : "end_turn";
            push(reply);
            last = r.content;
            if (r.content.length || r.reasoning.length) ev.assistantMessage(r.content, r.reasoning);
            if (r.toolCalls.length == 0)
            {
                bool cut = r.stopReason == "length" || r.stopReason == "max_tokens";
                if (cut) ev.text(false, "\n[the reply hit the output-token limit]");
                // A steer that arrived while the answer was written extends the turn.
                if (control.hasSteers && !control.isCancelled) continue;
                // A blocking Stop hook keeps the turn going (capped per turn).
                if (hooks !is null && !cut && stopBlocks < maxStopBlocks && !control.isCancelled
                    && (maxIterations <= 0 || i + 1 < maxIterations))
                {
                    auto o = hooks.runStop(stopBlocks > 0);
                    if (o.blocked)
                    {
                        stopBlocks++;
                        auto reason = o.blockReason.strip.length ? o.blockReason : "A Stop hook asked the agent to keep going.";
                        push(Message.user(wrapReminder(reason)));
                        ev.userMessage(reason);
                        continue;
                    }
                }
                lastStop = cut ? StopReason.maxTokens : StopReason.endTurn;
                return last;
            }
            foreach (call; r.toolCalls)
            {
                ev.toolStart(call);
                bool isError = true;
                auto result = control.isCancelled ? cancelledToolResult : runTool(call, r.stopReason, isError);
                ev.toolEnd(call, result, isError);
                push(Message.toolResult(call.id, call.name, result, isError));
            }
        }
        ev.text(false, format("\n[stopped after %s model calls (max_iterations)]", maxIterations));
        lastStop = StopReason.maxTurnRequests;
        return last;
    }

    private string cancelled(AgentEvents ev)
    {
        ev.text(false, "\n" ~ cancelledResponse);
        lastStop = StopReason.cancelled;
        return cancelledResponse;
    }

    private string runTool(const ref ToolCall call, string stopReason, out bool isError)
    {
        isError = true;
        if (call.invalidArguments.length)
        {
            auto raw = call.invalidArguments.length > 300 ? call.invalidArguments[0 .. 300] ~ "…" : call.invalidArguments;
            auto advice = stopReason == "length" || stopReason == "max_tokens"
                ? "The reply was cut off by the output-token limit; send a smaller call (e.g. write the file in parts)."
                : "Send the arguments as a single JSON object.";
            return format("Invalid arguments for %s (not a JSON object): %s\n%s", call.name, raw, advice);
        }
        if (!tools.has(call.name)) return format("Tool '%s' not found. Available: %s", call.name, toolNames());
        if (auto blocked = policy.check(call.name, call.arguments)) return blocked;
        // PreToolUse hooks run after the permission check, before the tool:
        // they can deny the call, rewrite its input, or add context.
        JSONValue args = call.arguments;
        string[] context;
        if (hooks !is null)
        {
            auto o = hooks.runPreToolUse(call.name, call.arguments, call.id);
            if (auto ctx = o.contextBlock) context ~= ctx;
            string deny;
            if (o.denies) deny = o.blockReason.length ? o.blockReason : "blocked by a PreToolUse hook";
            else if (o.decision == Decision.ask)
                deny = o.blockReason.strip.length ? o.blockReason
                    : "a PreToolUse hook requested confirmation (ask), which nano cannot prompt for yet; blocking the call";
            else if (o.updatedInput.type != JSONType.null_)
            {
                args = applyUpdatedInput(call.name, call.arguments, o.updatedInput);
                // The rewritten input must pass the policy too, or a hook could
                // rewrite a command or path past the user's rules.
                if (auto blocked = policy.check(call.name, args)) deny = blocked;
            }
            if (deny !is null) return withContext(deny, context);
        }
        string out_;
        try
        {
            out_ = tools.execute(call.name, args);
            isError = false;
        }
        catch (ToolError e) out_ = e.msg;
        catch (Exception e) out_ = format("%s failed: %s", call.name, e.msg);
        if (hooks !is null)
        {
            auto o = hooks.runPostToolUse(call.name, args, out_, call.id);
            if (auto ctx = o.contextBlock) context ~= ctx;
            if (o.blocked && o.blockReason.strip.length) context ~= o.blockReason;
        }
        return withContext(out_, context);
    }

    private static string withContext(string text, string[] context)
    {
        foreach (c; context) text ~= "\n\n" ~ wrapReminder(c);
        return text;
    }

    /// Attach `h` for a fresh (`resumed = false`) or restored session:
    /// `SessionStart` runs again on the next prompt, and the hook config files
    /// are recorded in the session log for the audit trail.
    void useHooks(HookManager h, bool resumed)
    {
        hooks = h;
        this.resumed = resumed;
        sessionStarted = false;
        pendingStartContext = null;
        if (h is null || log is null || !h.files.length) return;
        import nano.claude_hooks : label;
        string[3][] files;
        foreach (f; h.files) files ~= [f.path, f.source.label, f.hash];
        log.hooks(files);
    }

    private void syncHookSession()
    {
        hooks.setSession(log !is null ? log.id : "", log !is null ? log.path : "",
            policy.mode == Mode.plan ? "plan" : "default");
    }

    private string toolNames()
    {
        string s;
        foreach (d; tools.definitions) s ~= (s.length ? ", " : "") ~ d.name;
        return s;
    }
}

version (unittest)
{
    import nano.providers.mock;

    class NullEvents : AgentEvents
    {
        string shown;
        string[] tools;
        void text(bool r, string s) { if (!r) shown ~= s; }
        void toolStart(const ref ToolCall c) { tools ~= c.name; }
        void toolEnd(const ref ToolCall c, string res, bool err) {}
        void usage(TokenUsage u) {}
        string[] steered;
        void userMessage(string t) { steered ~= t; }
        void assistantMessage(string t, string r) {}
    }
}

unittest
{
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "echo", parseJSON(`{"type":"object"}`)),
        (JSONValue a) => "echoed " ~ a["text"].str);
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{"text":"hi"}`), ToolCall.fromRaw("c2", "nope", `{}`),
            ToolCall.fromRaw("c3", "echo", `{"text":`)]),
        LLMResponse("done"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    auto ev = new NullEvents;
    assert(agent.run("go", ev) == "done");
    assert(ev.tools == ["echo", "nope", "echo"]);
    auto second = mock.seen[1];
    assert(second[$ - 3].content == "echoed hi" && !second[$ - 3].isError);
    assert(second[$ - 2].isError && second[$ - 1].isError);
    import std.string : indexOf;
    assert(second[$ - 1].content.indexOf("Invalid arguments") == 0);
}

unittest
{
    auto reg = new ToolRegistry;
    bool ran;
    reg.register(ToolDefinition("bash", "", parseJSON(`{}`)), (JSONValue a) { ran = true; return ""; });
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "bash", `{"command":"sudo rm -rf /"}`)]),
        LLMResponse("ok"),
    ]);
    auto agent = new Agent(mock, reg, Policy.init, null);
    agent.maxIterations = 5;
    agent.run("x", new NullEvents);
    assert(!ran);
    import std.string : indexOf;
    assert(mock.seen[1][$ - 1].content.indexOf("Blocked") == 0);
}

// A steer sent while a tool runs joins the next model call.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    reg.register(ToolDefinition("work", "", parseJSON(`{}`)), (JSONValue a) {
        agent.control.steer("use the other file");
        return "ok";
    });
    auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c1", "work", `{}`)]), LLMResponse("done")]);
    agent = new Agent(mock, reg, Policy.init, null);
    auto ev = new NullEvents;
    assert(agent.run("go", ev) == "done");
    assert(ev.steered == ["use the other file"]);
    assert(mock.seen[1][$ - 1].role == Role.user && mock.seen[1][$ - 1].content == "use the other file");
}

// A steer that lands during the final answer extends the turn.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    auto mock = new MockClient([LLMResponse("long answer"), LLMResponse("short")]);
    agent = new Agent(mock, reg, Policy.init, null);
    auto ev = new NullEvents;
    agent.control.startTurn();
    // Queued before `run`: absorbed before the first call, so no extension.
    agent.control.steer("make it shorter");
    assert(agent.run("go", ev) == "long answer");
    assert(ev.steered == ["make it shorter"]);
}

// A cancel stops the turn: remaining tool calls are recorded as cancelled.
unittest
{
    auto reg = new ToolRegistry;
    Agent agent;
    int runs;
    reg.register(ToolDefinition("work", "", parseJSON(`{}`)), (JSONValue a) {
        runs++;
        agent.control.cancel();
        return "ok";
    });
    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "work", `{}`), ToolCall.fromRaw("c2", "work", `{}`)]),
        LLMResponse("never"),
    ]);
    agent = new Agent(mock, reg, Policy.init, null);
    assert(agent.run("go", new NullEvents) == cancelledResponse);
    assert(runs == 1 && mock.seen.length == 1);
    assert(agent.messages[$ - 1].content == cancelledToolResult && agent.messages[$ - 1].isError);
    // The next turn starts clean.
    agent.client = new MockClient([LLMResponse("fine")]);
    assert(agent.run("again", new NullEvents) == "fine");
}

// Claude hooks in the loop: prompt context and blocking, PreToolUse deny and
// rewrite (re-checked against the policy), PostToolUse context, Stop blocks.
unittest
{
    import nano.claude_hooks : Hook, Event;
    import std.algorithm : canFind;
    import std.file : tempDir;
    import core.time : seconds;
    Hook hook(Event e, string command, string matcher = null)
    {
        Hook h;
        h.event = e;
        h.command = command;
        h.matcher = matcher;
        h.timeout = 10.seconds;
        return h;
    }
    string[] ran;
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("bash", "", parseJSON(`{}`)), (JSONValue a) { ran ~= a["command"].str; return "ran"; });
    reg.register(ToolDefinition("echo", "", parseJSON(`{}`)), (JSONValue a) { ran ~= "echo"; return "echoed"; });

    // UserPromptSubmit: context is attached; exit 2 rejects without a model call.
    auto mock = new MockClient([LLMResponse("ok")]);
    auto agent = new Agent(mock, reg, Policy.init, "sys");
    agent.hooks = new HookManager([hook(Event.sessionStart, "echo started"),
        hook(Event.userPromptSubmit, `grep -q forbidden && { echo no secrets >&2; exit 2; }; echo ctx`)], tempDir);
    assert(agent.run("hello", new NullEvents) == "ok");
    auto first = mock.seen[0][$ - 1].content;
    assert(first.canFind("hello") && first.canFind("started") && first.canFind("ctx") && first.canFind("<system-reminder>"), first);
    assert(agent.run("forbidden words", new NullEvents) == "no secrets");
    assert(mock.seen.length == 1);
    assert(agent.messages[$ - 1].content == "no secrets");

    // PreToolUse: deny blocks, rewrites apply but pass the policy again.
    mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{}`), ToolCall.fromRaw("c2", "bash", `{"command":"ls"}`),
            ToolCall.fromRaw("c3", "bash", `{"command":"pwd"}`)]),
        LLMResponse("done"),
    ]);
    agent = new Agent(mock, reg, Policy.init, null);
    agent.hooks = new HookManager([
        hook(Event.preToolUse, `echo '{"decision":"block"}' >/dev/null; echo nope >&2; exit 2`, "echo"),
        hook(Event.preToolUse, `grep -q '"ls"' && echo '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"echo patched"}}}' || echo '{"hookSpecificOutput":{"updatedInput":{"command":"sudo rm -rf /"}}}'`, "Bash"),
        hook(Event.postToolUse, `echo '{"hookSpecificOutput":{"additionalContext":"post-note"}}'`, "Bash"),
    ], tempDir);
    ran = null;
    agent.run("go", new NullEvents);
    auto results = mock.seen[1][$ - 3 .. $];
    assert(results[0].content == "nope", results[0].content);
    assert(results[1].content.canFind("ran") && results[1].content.canFind("post-note"), results[1].content);
    assert(results[2].content.canFind("Blocked"), "a rewrite past the policy is blocked: " ~ results[2].content);
    assert(ran == ["echo patched"], ran.join(","));

    // Stop: a block keeps the turn going, capped per turn.
    mock = new MockClient([LLMResponse("a"), LLMResponse("b"), LLMResponse("c"), LLMResponse("d"), LLMResponse("e")]);
    agent = new Agent(mock, reg, Policy.init, null);
    agent.hooks = new HookManager([hook(Event.stop, `echo '{"decision":"block","reason":"more"}'`)], tempDir);
    assert(agent.run("go", new NullEvents) == "d");
    assert(mock.seen.length == 4 && mock.seen[1][$ - 1].content.canFind("more"));
}
