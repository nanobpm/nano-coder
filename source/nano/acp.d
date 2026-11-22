/// Agent Client Protocol server (`--acp`): JSON-RPC 2.0, one message per
/// line on stdin and stdout. Port of src/acp.rs.
///
/// Methods: `initialize`, `session/new`, `session/load`, `session/prompt`
/// and `session/cancel`. Over ACP, prompts can run the slash commands
/// `/tools`, `/settings` and `/model <spec>`; any other `/…` prompt is
/// rejected rather than sent to the model, and `//…` sends a prompt that
/// starts with `/`. Turn progress goes out as `session/update` notifications.
///
/// A reader thread parses stdin. While a turn runs, it routes each message
/// itself, as Rust's `select!` does: `session/cancel` cancels the turn,
/// plain prompts steer it, and anything else is deferred until the turn ends.
/// Steers that miss the turn are queued as prompts in the position they
/// arrived (or dropped, with a `cancelled` reply, if the turn was cancelled).
module nano.acp;

@safe:
import nano.safeio : jsonText, jsonPretty;
import nano.clock : stdTimeNow;
import nano.arith : saturatingSub;
import nano.option : Option, some, none, match, ifSome, NotNull;

import nano.safeio : spawnDaemon, stdErr, stdOut;

import std.json;
import std.format : format;
import std.string : strip, startsWith, indexOf;
import std.algorithm : canFind;
import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import nano.agent;
import nano.claude_hooks : HookManager;
import nano.control;
import nano.llm;
import nano.session;
import nano.plan : Plan;

enum int protocolVersion = 1;

import nano.paths : debugQuote;
import nano.commands : isCommand;
import nano.thinking : wireValue, sessionSetting, label;
import nano.result : orThrow, unwrap, unwrapErr;
import nano.temperature : label;
import std.array : join;

/// Commands `handle` services over ACP. Reaching the slash fallback with one
/// of these means only its arguments were not accepted.
immutable string[] acpCommandRoots = ["/compact", "/settings", "/tools", "/plan", "/providers", "/model"];

JSONValue rpcResult(JSONValue id, JSONValue result) pure
{
    JSONValue m = ["jsonrpc": JSONValue("2.0")];
    m["id"] = id;
    m["result"] = result;
    return m;
}

JSONValue rpcError(JSONValue id, long code, string message) pure
{
    JSONValue m = ["jsonrpc": JSONValue("2.0")];
    m["id"] = id;
    m["error"] = JSONValue(["code": JSONValue(code), "message": JSONValue(message)]);
    return m;
}

private JSONValue get(JSONValue v, string key) pure
{
    if (v.type != JSONType.object) return JSONValue(null);
    if (auto p = key in v) return *p;
    return JSONValue(null);
}

private string getStr(JSONValue v, string key) pure
{
    auto x = get(v, key);
    return x.type == JSONType.string ? x.str : null;
}

/// The text of a `session/prompt`: its text content blocks, joined.
string promptText(JSONValue params) pure
{
    string out_;
    auto p = get(params, "prompt");
    if (p.type == JSONType.array)
        foreach (item; p.arrayNoRef) if (auto t = getStr(item, "text")) out_ ~= t;
    return out_;
}

/// A `//…` line is a prompt that starts with `/`: the text with one `/`
/// removed. null for other lines.
string unescapePrompt(string line) pure
{
    import std.string : stripLeft;
    auto t = line.stripLeft;
    return t.startsWith("//") ? t[1 .. $] : null;
}

/// Reject a slash prompt no command handled (a non-null note), or return
/// the turn text in `text`.
string enforceSlashInvariant(ref string text) pure
{
    auto trimmed = text.strip;
    if (isCommand(trimmed))
    {
        import nano.commands : rejection;
        // An unknown command gets its did-you-mean; a known one reaches here
        // only when ACP doesn't service it (or not with these arguments).
        if (auto r = rejection(trimmed)) return r;
        auto sp = trimmed.indexOf(' ');
        auto word = sp > 0 ? trimmed[0 .. sp] : trimmed;
        if (acpCommandRoots.canFind(word)) return format("Can't run %s over ACP", debugQuote(trimmed));
        return format("Can't run %s: this command is not available over ACP", word);
    }
    if (auto u = unescapePrompt(trimmed)) text = u;
    return null;
}

/// ACP `PromptResponse.usage` for one turn: the tokens the provider reported
/// between the turn's start and end (input, output), summed over its model
/// calls. A null JSON value when the provider reported nothing (the field is
/// optional in ACP). Counters reset mid-turn by /clear never go negative.
JSONValue turnUsage(const ulong[2] before, const ulong[2] after) pure
{
    auto input = saturatingSub(after[0], before[0]);
    auto output = saturatingSub(after[1], before[1]);
    if (input == 0 && output == 0) return JSONValue(null);
    return JSONValue(["inputTokens": input, "outputTokens": output, "totalTokens": input + output]);
}

// rust: acp.rs::turn_usage_is_the_delta_of_the_session_counters
unittest
{
    assert(turnUsage([1_000, 50], [13_087, 54]) == JSONValue(["inputTokens": 12_087UL, "outputTokens": 4UL, "totalTokens": 12_091UL]));
    assert(turnUsage([10, 5], [10, 5]).type == JSONType.null_, "nothing reported, no usage field");
    assert(turnUsage([10, 5], [3, 7]) == JSONValue(["inputTokens": 0UL, "outputTokens": 2UL, "totalTokens": 2UL]));
}

/// Whether `msg` is a JSON-RPC 2.0 request or notification.
bool isJsonRpcRequest(JSONValue msg) pure
{
    return getStr(msg, "jsonrpc") == "2.0" && getStr(msg, "method") !is null;
}

enum DuringTurn { cancel, steer, defer }

/// How a message arriving mid-turn is routed; `steerText` is set for steer.
DuringTurn classifyDuringTurn(JSONValue msg, string active, out string steerText) pure
{
    auto params = get(msg, "params");
    auto requested = getStr(params, "sessionId");
    bool forActive = requested is null || requested == active;
    auto method = getStr(msg, "method");
    if (method == "session/cancel" && forActive) return DuringTurn.cancel;
    if (method == "session/prompt" && forActive)
    {
        auto text = promptText(params);
        auto trimmed = text.strip;
        if (!trimmed.length) return DuringTurn.defer;
        auto u = unescapePrompt(trimmed);
        if (isCommand(trimmed)) return DuringTurn.defer;
        steerText = u !is null ? u : text;
        return DuringTurn.steer;
    }
    return DuringTurn.defer;
}

/// The ACP tool kind, for client display.
string toolKind(string name) pure
{
    switch (name)
    {
    case "bash": return "execute";
    case "read_file": return "read";
    case "grep", "glob": return "search";
    case "write_file", "edit_file": return "edit";
    case "plan_add", "plan_update", "plan_show", "report_outcome": return "think";
    default: return "other";
    }
}

private JSONValue textBlock(string t) pure { return JSONValue(["type": JSONValue("text"), "text": JSONValue(t)]); }

/// What the server needs from the host program.
struct Host
{
    /// The system prompt for a session in `cwd`.
    string delegate(string cwd) systemPrompt;
    /// Build a client for `provider/model`; throws on a bad spec.
    LLMClient delegate(string spec) makeClient;
    /// Session logs live here; null disables session/load and logging.
    string sessionDir;
    string version_;
    /// Load the user hooks for a session in `cwd` (null = no hooks).
    HookManager delegate(string cwd) loadHooks;
    /// `_meta` for session/new and session/load: loaded instruction files,
    /// on-demand rules, skills and warnings (called after `systemPrompt`).
    JSONValue delegate() sessionMeta;
    /// Configured and preset provider names, for `/providers`.
    string[] delegate() providerNames;
    /// The configured `model` and `system_prompt`, for `/settings`.
    string configModel, configSystemPrompt;
}

/// Input id for idempotent prompts: `messageId`, or `_meta.inputId`.
string inputId(JSONValue params) pure
{
    if (params.type != JSONType.object) return null;
    auto v = "messageId" in params.objectNoRef;
    if (v is null)
        if (auto m = "_meta" in params.objectNoRef)
            if (m.type == JSONType.object) v = "inputId" in m.objectNoRef;
    return v !is null && v.type == JSONType.string && v.str.length ? v.str : null;
}

unittest
{
    assert(inputId(parseJSON(`{"messageId": "m1", "_meta": {"inputId": "i"}}`)) == "m1");
    assert(inputId(parseJSON(`{"_meta": {"inputId": "i"}}`)) == "i");
    assert(inputId(parseJSON(`{"messageId": ""}`)) is null);
    assert(inputId(parseJSON(`{}`)) is null);
}

/// Message routing shared by the stdin reader thread and the turn loop: a
/// sendable handle (copies share one state). Messages wait as JSON text;
/// during a turn, cancels and steers bypass the queue.
struct AcpRouter
{
    import nano.safeio : Shared;
    private static struct State
    {
        immutable(string)[] items; /// queued messages, as JSON text
        bool eof, turnActive, sawValid;
        string sessionId;
        immutable(size_t)[] steerMarks; /// queue length when each steer arrived
    }
    private Shared!State state;
    private NotNull!(shared TurnControl) control;

    /// Routing for `control` (the agent's).
    static AcpRouter make(shared TurnControl control) { return AcpRouter(Shared!State.make, NotNull!(shared TurnControl)(atomicLoad(control))); }

    /// Route one input line. Returns a reply to send at once (a cancel's
    /// result), or null.
    string receive(string line)
    {
        auto l = line.strip;
        if (!l.length) return null;
        JSONValue msg;
        try msg = parseJSON(l);
        catch (Exception e)
        {
            auto seen = state.get.sawValid;
            stdErr.writeln(seen ? "ACP parse error: " ~ e.msg
                : "input doesn't look like ACP JSON-RPC (expected JSON-RPC 2.0, one message per line): " ~ e.msg);
            return null;
        }
        immutable valid = isJsonRpcRequest(msg);
        auto ctl = atomicLoad(control);
        return state.update!string((ref State st) {
            if (valid) st.sawValid = true;
            if (st.turnActive)
            {
                string steerText;
                final switch (classifyDuringTurn(msg, st.sessionId, steerText))
                {
                case DuringTurn.cancel:
                    ctl.cancel();
                    auto id = get(msg, "id");
                    return id.type != JSONType.null_ ? rpcResult(id, JSONValue(string[string].init)).toString : null;
                case DuringTurn.steer:
                    st.steerMarks ~= st.items.length;
                    ctl.steer(Steer(steerText, get(msg, "id")));
                    return null;
                case DuringTurn.defer:
                    break;
                }
            }
            st.items ~= l;
            return null;
        });
    }

    /// Input has ended.
    void close() { state.update((ref State st) { st.eof = true; }); }

    /// The next queued message (waits); false at end of input.
    bool pop(out JSONValue m)
    {
        auto text = state.await!string((ref const State st) => st.items.length || st.eof, (ref State st) {
            if (!st.items.length) return string.init;
            auto t = st.items[0];
            st.items = st.items[1 .. $];
            return t;
        });
        if (text is null) return false;
        m = parseJSON(text);
        return true;
    }

    /// Whether any valid JSON-RPC request arrived.
    bool sawValid() { return state.get.sawValid; }

    /// The session cancels and steers are matched against.
    void sessionId(string id) { state.update((ref State st) { st.sessionId = id; }); }

    /// A turn starts: cancels and steers now go to it.
    void startTurn()
    {
        auto ctl = atomicLoad(control);
        state.update((ref State st) {
            ctl.startTurn();
            st.steerMarks = null;
            st.turnActive = true;
        });
    }

    /// The turn ended: messages queue again. `finish` runs under the lock,
    /// so no message is routed meanwhile; it gets the queue (parsed), the
    /// steer marks and the session, and returns whether it changed the queue.
    void endTurn(scope bool delegate(ref JSONValue[] items, const(size_t)[] marks, string session) @safe finish)
    {
        state.update((ref State st) {
            st.turnActive = false;
            JSONValue[] items;
            foreach (t; st.items) items ~= parseJSON(t);
            if (!finish(items, st.steerMarks, st.sessionId)) return;
            immutable(string)[] back;
            foreach (m; items) back ~= m.jsonText;
            st.items = back;
        });
    }
}

/// The stdin reader (runs via `spawn`): routes each line, writing an
/// immediate reply straight to stdout.
private void readAcpStdin(AcpRouter router)
{
    // FdLineReader, not std.stdio: see its comment.
    auto input = FdLineReader(0);
    for (string line; (line = input.next()) !is null;)
        if (auto reply = router.receive(line)) writeStdoutLine(reply);
    router.close();
}

/// One message to stdout (each line whole: `File` locks per call).
private void writeStdoutLine(string l)
{
    stdOut.writeln(l);
    stdOut.flush();
}

final class AcpServer : AgentEvents
{
    mixin imported!"nano.subagent".SubAgentEvents;
    private NotNull!Agent agent;
    private Host host;
    private void delegate(string line) writeLine_;
    private NotNull!Mutex outLock;
    private AcpRouter router;
    private string sessionId_;
    private size_t messageSeq;

    /// `writeLine` gets one JSON message per call (defaults to stdout).
    this(Agent agent, Host host, void delegate(string) @safe writeLine = null)
    {
        this.agent = agent;
        // The ACP orchestrator runs its own verification (Rust #158).
        agent.verifyBeforeComplete = false;
        this.host = host;
        outLock = new Mutex;
        router = AcpRouter.make(agent.control.nonNull);
        writeLine_ = writeLine !is null ? writeLine : (string l) => writeStdoutLine(l);
        agent.onPlanChanged = () {
            JSONValue u = ["sessionUpdate": "plan"];
            u["entries"] = agent.plan.acpEntries;
            u["_meta"] = JSONValue(["plan": agent.plan.toJSON]);
            update(u);
        };
    }

    void send(JSONValue msg) { writeOut(msg.jsonText); }

    /// A bash "still running" heartbeat: a `session/update` the supervising
    /// worker sees on the JSON-RPC stream. It is not part of the model's
    /// context or any tool result — pure liveness, no token cost.
    void heartbeat(string line)
    {
        update(JSONValue(["sessionUpdate": JSONValue("agent_thought_chunk"), "content": textBlock(line)]));
    }

    private void writeOut(string line)
    {
        outLock.lock();
        scope (exit) outLock.unlock();
        writeLine_(line);
    }

    void notify(string method, JSONValue params)
    {
        JSONValue m = ["jsonrpc": JSONValue("2.0"), "method": JSONValue(method)];
        m["params"] = params;
        send(m);
    }

    private void update(JSONValue u)
    {
        JSONValue p = ["sessionId": sessionId is null ? JSONValue(null) : JSONValue(sessionId)];
        p["update"] = u;
        notify("session/update", p);
    }

    // ---- AgentEvents: progress becomes session/update ----

    void text(bool reasoning, string chunk) pure {}
    void usage(TokenUsage u) pure {}

    void userMessage(string t)
    {
        update(JSONValue(["sessionUpdate": JSONValue("user_message_chunk"), "content": textBlock(t)]));
    }

    /// Nothing to retract over ACP: the client has the streamed chunks.
    void responseRestarted() pure {}
    void generationStart() pure {}

    void assistantMessage(string t, string reasoning)
    {
        if (reasoning.length)
            update(JSONValue(["sessionUpdate": JSONValue("agent_thought_chunk"), "content": textBlock(reasoning)]));
        if (t.length)
            update(JSONValue(["sessionUpdate": JSONValue("agent_message_chunk"),
                "messageId": JSONValue(format("msg-%s", ++messageSeq)), "content": textBlock(t)]));
    }

    void toolStart(const ref ToolCall call)
    {
        JSONValue u = ["sessionUpdate": JSONValue("tool_call"), "toolCallId": JSONValue(call.id),
            "title": JSONValue(call.name), "kind": JSONValue(toolKind(call.name)), "status": JSONValue("in_progress")];
        u["rawInput"] = parseJSON(call.arguments.jsonText);
        update(u);
    }

    void toolEnd(const ref ToolCall call, string result, bool isError)
    {
        toolUpdate(call.id, result, isError);
    }

    /// Sub-agent progress: an in-progress update on each `agent` call
    /// (a `tool_call` upsert, as later calls haven't started on the client).
    void subagents(const imported!"nano.subagent".SubProgress[] all)
    {
        import nano.subagent : progressLine;
        foreach (ref p; all)
        {
            // A call whose final result already went out keeps its terminal
            // status: a late progress note must not flip it back to
            // in_progress (a cancelled call would appear to run forever).
            if (p.callId in terminalCalls) continue;
            if (p.done)
            {
                terminalCalls[p.callId] = true;
                update(JSONValue(["sessionUpdate": JSONValue("tool_call_update"), "toolCallId": JSONValue(p.callId),
                    "status": JSONValue("completed"),
                    "content": JSONValue([JSONValue(["type": JSONValue("content"), "content": textBlock(progressLine(p))])])]));
                continue;
            }
            update(JSONValue(["sessionUpdate": JSONValue("tool_call"), "toolCallId": JSONValue(p.callId),
                "title": JSONValue("agent"), "kind": JSONValue(toolKind("agent")), "status": JSONValue("in_progress"),
                "content": JSONValue([JSONValue(["type": JSONValue("content"), "content": textBlock(progressLine(p))])])]));
        }
    }

    /// Calls whose final tool result (or done progress) went out; later
    /// progress for them is dropped.
    private bool[string] terminalCalls;

    private void toolUpdate(string id, string output, bool isError)
    {
        terminalCalls[id] = true;
        update(JSONValue(["sessionUpdate": JSONValue("tool_call_update"), "toolCallId": JSONValue(id),
            "status": JSONValue(isError ? "failed" : "completed"), "rawOutput": JSONValue(output),
            "content": JSONValue([JSONValue(["type": JSONValue("content"), "content": textBlock(output)])])]));
    }

    // ---- input ----

    /// Feed one input line (as the reader thread does for each stdin line).
    void receive(string line)
    {
        if (auto reply = router.receive(line)) writeOut(reply);
    }

    /// Input has ended.
    void close() { router.close(); }

    /// Run until input ends. Returns whether any valid JSON-RPC request arrived.
    bool run()
    {
        JSONValue msg;
        while (router.pop(msg)) handle(msg);
        return router.sawValid;
    }

    /// Serve stdin on a reader thread until it ends.
    bool serveStdio()
    {
        spawnDaemon(&readAcpStdin, router);
        return run();
    }

    private string sessionId() pure { return sessionId_; }
    private void sessionId(string id) { sessionId_ = id; router.sessionId(id); }

    // ---- handling ----

    private void handle(JSONValue msg)
    {
        auto id = get(msg, "id");
        bool hasId = id.type != JSONType.null_;
        auto params = get(msg, "params");
        auto method = getStr(msg, "method");
        void reply(JSONValue r) { if (hasId) send(r); }
        switch (method)
        {
        case "initialize":
            reply(rpcResult(id, JSONValue([
                "protocolVersion": JSONValue(protocolVersion),
                "agentInfo": JSONValue(["name": "nano-coder", "version": host.version_]),
                "agentCapabilities": JSONValue(["loadSession": JSONValue(host.sessionDir !is null),
                    "tools": JSONValue(true), "hooks": JSONValue(false), "compact": JSONValue(true),
                    "_meta": JSONValue(["planSeed": JSONValue(agent.planTools)])]),
            ])));
            return;
        case "session/new":
            if (auto e = applyCwd(params)) { reply(rpcError(id, -32602, e)); return; }
            try
            {
                Plan seed;
                bool seeded;
                if (params.type == JSONType.object)
                    if (auto m = "_meta" in params.objectNoRef)
                        if (m.type == JSONType.object)
                            if (auto p = "plan" in m.objectNoRef)
                                if (p.type != JSONType.null_)
                                {
                                    // A bad plan fails the request, as below.
                                    seed = Plan.fromJSON(*p).orThrow!(e => new Exception(e));
                                    seeded = true;
                                }
                newSession();
                if (seeded)
                {
                    // The client already showed the model the plan (e.g. in a resume prompt).
                    auto inPrompt = "planInPrompt" in params["_meta"].objectNoRef;
                    agent.setPlan(seed, !(inPrompt !is null && inPrompt.type == JSONType.true_));
                }
                auto meta = sessionMeta();
                if (!agent.plan.empty) meta["plan"] = agent.plan.toJSON;
                reply(rpcResult(id, JSONValue(["sessionId": JSONValue(sessionId), "_meta": meta])));
            }
            catch (Exception e) reply(rpcError(id, -32603, e.msg));
            return;
        case "session/load":
            auto want = getStr(params, "sessionId");
            if (want is null) { reply(rpcError(id, -32602, "session/load requires params.sessionId")); return; }
            if (auto e = applyCwd(params)) { reply(rpcError(id, -32602, e)); return; }
            try
            {
                loadSession_(want);
                reply(rpcResult(id, JSONValue(["sessionId": JSONValue(sessionId), "_meta": sessionMeta()])));
            }
            catch (Exception e) reply(rpcError(id, -32603, e.msg));
            return;
        case "session/cancel":
            // Nothing is running; a notification gets no reply.
            reply(rpcResult(id, JSONValue(string[string].init)));
            return;
        case "session/prompt":
            auto requested = getStr(params, "sessionId");
            if (requested !is null && requested != sessionId)
            {
                reply(rpcError(id, -32602, format("session %s is not active (active: %s); call session/load first",
                    debugQuote(requested), sessionId is null ? "none" : sessionId)));
                return;
            }
            if (sessionId is null) newSession();
            auto text = promptText(params);
            auto r = command(text.strip, id);
            if (r.type != JSONType.null_) { reply(r); return; }
            if (auto note = enforceSlashInvariant(text))
            {
                reply(rpcResult(id, JSONValue(["stopReason": "end_turn", "response": note])));
                return;
            }
            runTurn(id, text, inputId(params));
            return;
        default:
            if (hasId && method !is null) reply(rpcError(id, -32601, "method not found: " ~ method));
        }
    }

    private JSONValue sessionMeta()
    {
        return host.sessionMeta !is null ? host.sessionMeta() : JSONValue(string[string].init);
    }

    /// Slash commands available over ACP; JSONValue.init when `text` isn't one.
    private JSONValue command(string text, JSONValue id)
    {
        if (text == "/compact" || text.startsWith("/compact "))
        {
            import nano.commands : parseCompactArgs;
            import nano.context : CompactionMode;
            CompactionMode mode;
            string focus;
            bool hasMode = parseCompactArgs(text["/compact".length .. $], mode, focus);
            CompactReport rep;
            bool done;
            // Manual: the reply reports it, so skip the auto-compaction notice.
            auto notice = agent.onCompacted;
            agent.onCompacted = null;
            scope (exit) agent.onCompacted = notice;
            // A cancel left from an earlier turn must not stop this one.
            agent.control.nonNull.startTurn();
            try done = agent.compact(rep, CompactTrigger.manual, hasMode ? new CompactionMode(mode) : null, focus.length ? focus : null);
            catch (Exception e) return rpcError(id, -32603, e.msg);
            if (!done) return rpcResult(id, JSONValue(["stopReason": JSONValue("end_turn"), "compacted": JSONValue(false)]));
            JSONValue b = ["stopReason": JSONValue("end_turn"), "compacted": JSONValue(true)];
            b["before"] = rep.messagesBefore;
            b["after"] = rep.messagesAfter;
            b["tokensBefore"] = rep.tokensBefore;
            b["tokensAfter"] = rep.tokensAfter;
            b["summarized"] = rep.summarized;
            b["mode"] = rep.mode == CompactionMode.smart ? "smart" : "standard";
            b["fallback"] = rep.fallback is null ? JSONValue(null) : JSONValue(rep.fallback);
            b["truncated"] = rep.truncated;
            return rpcResult(id, b);
        }
        if (text == "/plan")
        {
            JSONValue b = ["stopReason": JSONValue("end_turn"), "plan": agent.plan.toJSON];
            b["text"] = agent.plan.render(true, size_t.max);
            return rpcResult(id, b);
        }
        if (text == "/providers")
        {
            import std.algorithm : sort;
            string[] names = host.providerNames !is null ? host.providerNames() : null;
            names.sort();
            return rpcResult(id, JSONValue(["stopReason": JSONValue("end_turn"), "providers": JSONValue(names)]));
        }
        if (text == "/tools")
        {
            JSONValue[] names;
            foreach (d; agent.offeredTools) names ~= JSONValue(d.name);
            return rpcResult(id, JSONValue(["stopReason": JSONValue("end_turn"), "tools": JSONValue(names)]));
        }
        if (text == "/settings")
        {
            import std.math : isNaN;
            JSONValue s = ["provider": agent.client.providerName, "provider_model": agent.client.modelName];
            s["model"] = host.configModel;
            auto temp = agent.temperatureNow;
            s["temperature"] = isNaN(temp.effective) ? JSONValue(null) : JSONValue(temp.effective);
            s["temperature_source"] = label(temp.source);
            auto th = agent.thinking();
            s["thinking"] = wireValue(th);
            s["thinking_source"] = label(th.source);
            s["max_tokens"] = agent.effectiveMaxTokens;
            s["system_prompt"] = host.configSystemPrompt is null ? JSONValue(null) : JSONValue(host.configSystemPrompt);
            s["session_id"] = sessionId is null ? JSONValue(null) : JSONValue(sessionId);
            return rpcResult(id, JSONValue(["stopReason": JSONValue("end_turn"), "settings": s]));
        }
        if (text.startsWith("/model ") && host.makeClient !is null)
        {
            try agent.client = host.makeClient(text[7 .. $].strip);
            catch (Exception e) return rpcError(id, -32602, e.msg);
            agent.refreshCapabilities();
            auto temp = agent.temperatureNow;
            auto th = agent.thinking();
            JSONValue body_ = ["stopReason": "end_turn", "provider": agent.client.providerName,
                "model": agent.client.modelName];
            import std.math : isNaN;
            body_["temperature"] = isNaN(temp.effective) ? JSONValue(null) : JSONValue(temp.effective);
            body_["temperature_source"] = label(temp.source);
            body_["thinking"] = wireValue(th);
            body_["thinking_source"] = label(th.source);
            string[] warnings;
            if (temp.warning.length) warnings ~= temp.warning;
            if (th.warning.length) warnings ~= th.warning;
            if (warnings.length) body_["warning"] = warnings.join("\n");
            return rpcResult(id, body_);
        }
        if (text == "/thinking" || text.startsWith("/thinking "))
        {
            auto arg = text["/thinking".length .. $].strip;
            if (arg.length)
            {
                auto setting = sessionSetting(arg);
                if (setting.isErr) return rpcError(id, -32602, setting.unwrapErr("isErr"));
                agent.sessionThinking = setting.unwrap("isOk");
            }
            auto th = agent.thinking();
            JSONValue body_ = ["stopReason": "end_turn"];
            body_["thinking"] = wireValue(th);
            body_["thinking_source"] = label(th.source);
            body_["thinking_levels"] = JSONValue(th.levels);
            if (th.warning.length) body_["warning"] = th.warning;
            return rpcResult(id, body_);
        }
        return JSONValue.init;
    }

    private string applyCwd(JSONValue params)
    {
        import std.file : exists, isDir, chdir;
        import std.path : isAbsolute;
        auto cwd = getStr(params, "cwd");
        if (!cwd.length) return null;
        if (!cwd.isAbsolute || !cwd.exists || !cwd.isDir)
            return format("cwd %s must be an existing absolute directory", debugQuote(cwd));
        try chdir(cwd);
        catch (Exception e) return format("cannot enter cwd %s: %s", debugQuote(cwd), e.msg);
        return null;
    }

    private void newSession()
    {
        import std.file : getcwd;
        auto cwd = getcwd();
        auto sys = host.systemPrompt !is null ? host.systemPrompt(cwd) : null;
        agent.messages = sys.length ? [Message.system(sys)] : null;
        agent.replaceLog(Option!SessionLog.init);
        agent.completedInputs = null;
        agent.completedStops = null;
        agent.completedOutcomes = null;
        agent.plan = Plan.init;
        agent.restoreRecall(JSONValue.init);
        if (host.sessionDir !is null)
        {
            auto log = new SessionLog(host.sessionDir, agent.client.providerName ~ "/" ~ agent.client.modelName, cwd);
            scope (failure) log.close();
            foreach (m; agent.messages) log.append(m);
            agent.replaceLog(some(log));
            sessionId = log.id;
        }
        else
        {
            import std.datetime.systime : Clock;
            sessionId = format("session-%x", stdTimeNow);
        }
        if (host.loadHooks !is null) agent.useHooks(host.loadHooks(cwd), false);
    }

    private void loadSession_(string want)
    {
        if (host.sessionDir is null) throw new Exception("sessions are disabled (--no-session)");
        import std.file : getcwd;
        auto path = findSession(host.sessionDir, want);
        auto sys = host.systemPrompt !is null ? host.systemPrompt(getcwd()) : null;
        // Lock the log first, then read the state the lock covers: a writer
        // finishing a turn while the lock wait blocks would otherwise be
        // adopted from a pre-turn snapshot and the turn re-run. The live
        // conversation is kept until the lock and restore succeed.
        auto log = new SessionLog(path);
        // Close on failure only until the agent adopts the log: after
        // `loadRestored` takes it (even if it throws later) it is the agent's
        // live writer, and a hook or replay failure must not close it.
        scope (failure) if (!agent.ownsLog(log)) log.close();
        auto restored = restore(log.path);
        auto prior = agent.messages;
        scope (failure) if (!agent.ownsLog(log)) agent.messages = prior;
        agent.messages = sys.length ? [Message.system(sys)] : null;
        agent.loadRestored(restored, some(log)); // ACP has no channel for the dropped-state notes
        sessionId = log.id;
        if (host.loadHooks !is null) agent.useHooks(host.loadHooks(getcwd()), true);
        replayHistory();
        // As on the CLI resume: drop the full-log parse and the replaced
        // conversation, then hand the freed heap back to the OS so a
        // long-lived ACP worker does not keep the load's peak.
        restored = Restored.init;
        prior = null;
        releaseHeap();
    }

    /// Replay the conversation as session/update notifications.
    private void replayHistory()
    {
        foreach (m; agent.replayMessages)
        {
            final switch (m.role)
            {
            case Role.system: break;
            case Role.user: userMessage(m.content); break;
            case Role.assistant:
                assistantMessage(m.content, null);
                foreach (c; m.toolCalls) toolStart(c);
                break;
            // As shown live: the model-facing text plus any image marker.
            case Role.tool: toolUpdate(m.toolCallId, toolResultDisplay(m.content, m.attachments), m.isError); break;
            }
        }
    }

    /// Run one prompt turn; the reader thread routes cancels and steers meanwhile.
    private void runTurn(JSONValue id, string text, string givenId = null)
    {
        router.startTurn();
        immutable ulong[2] tokensBefore = [agent.sessionInputTokens, agent.sessionOutputTokens];
        string response;
        try response = agent.run(text, this, false, givenId);
        catch (Exception e)
        {
            response = "Error: " ~ e.msg;
            agent.lastStop = StopReason.endTurn;
        }
        router.endTurn((ref JSONValue[] items, const(size_t)[] marks, string session) {
            string stop = agent.lastStop;
            if (id.type != JSONType.null_)
            {
                auto reply = JSONValue(["stopReason": stop, "response": response]);
                // Extension: the model's explicit completed/blocked report.
                if (agent.hasOutcome && stop == "end_turn") reply["_meta"] = JSONValue(["outcome": agent.lastOutcome.toJSON]);
                auto usage = turnUsage(tokensBefore, [agent.sessionInputTokens, agent.sessionOutputTokens]);
                if (usage.type != JSONType.null_) reply["usage"] = usage;
                send(rpcResult(id, reply));
            }
            // Steers folded into this turn are answered by it.
            foreach (s; agent.control.takeAbsorbed)
                if (s.tag.type != JSONType.null_)
                {
                    JSONValue meta = ["steered": JSONValue(true)];
                    meta["inputOf"] = id;
                    send(rpcResult(s.tag, JSONValue(["stopReason": JSONValue(stop), "_meta": meta])));
                }
            // Steers that arrived too late: dropped on cancel, else queued as
            // prompts at the position each one arrived.
            auto leftover = agent.control.takePending;
            if (agent.lastStop == StopReason.cancelled)
            {
                foreach (s; leftover)
                    if (s.tag.type != JSONType.null_) send(rpcResult(s.tag, JSONValue(["stopReason": "cancelled"])));
                return false;
            }
            items = requeueSteers(items, leftover, marks, session);
            return true;
        });
    }
}

/// Insert steers that missed their turn into `deferred` as prompts, each at
/// the position `deferred` had when it arrived. `leftover` are the last
/// steers to arrive, so they match the tail of `marks`.
JSONValue[] requeueSteers(JSONValue[] deferred, Steer[] leftover, const(size_t)[] marks, string active) pure
{
    import std.algorithm : min;
    auto first = saturatingSub(marks.length, leftover.length);
    foreach_reverse (i, s; leftover)
    {
        auto mark = first + i < marks.length ? marks[first + i] : deferred.length;
        // A steer unescaped from `//…` is re-escaped so it is not read as a command.
        auto text = s.text.startsWith("/") ? "/" ~ s.text : s.text;
        JSONValue params = ["sessionId": active is null ? JSONValue(null) : JSONValue(active)];
        params["prompt"] = JSONValue([textBlock(text)]);
        JSONValue prompt = ["jsonrpc": JSONValue("2.0"), "method": JSONValue("session/prompt")];
        prompt["params"] = params;
        if (s.tag.type != JSONType.null_) prompt["id"] = s.tag;
        auto at = min(mark, deferred.length);
        deferred = deferred[0 .. at] ~ prompt ~ deferred[at .. $];
    }
    return deferred;
}

// rust: acp.rs::leftover_steers_keep_their_arrival_position
unittest
{
    // Leftover steers keep their arrival position among deferred messages.
    JSONValue p(string t)
    {
        return parseJSON(`{"method":"session/prompt","params":{"prompt":[{"type":"text","text":` ~ JSONValue(t).toString ~ `}]}}`);
    }
    auto deferred = [p("early"), p("/plan"), parseJSON(`{"method":"session/set_mode"}`)];
    auto out_ = requeueSteers(deferred, [Steer("a", JSONValue(1)), Steer("b", JSONValue(2))], [0, 2, 3], null);
    string[] order;
    foreach (m; out_) order ~= getStr(m, "method") == "session/prompt" ? promptText(get(m, "params")) : getStr(m, "method");
    assert(order == ["early", "/plan", "a", "session/set_mode", "b"], order.format!"%s");
}

unittest
{
    string t = "/exin";
    assert(enforceSlashInvariant(t) !is null);
    t = "//etc/hosts is odd";
    assert(enforceSlashInvariant(t) is null && t == "/etc/hosts is odd");
    t = "/model";
    assert(enforceSlashInvariant(t) == `Can't run "/model" over ACP`);
    t = "/usr/lib is big";
    assert(enforceSlashInvariant(t) is null && t == "/usr/lib is big");
    // An escaped prompt steers; a real command waits.
    string s;
    auto prompt = (string x) => parseJSON(`{"method":"session/prompt","params":{"prompt":[{"type":"text","text":` ~ JSONValue(x).toString ~ `}]}}`);
    assert(classifyDuringTurn(prompt("//x"), null, s) == DuringTurn.steer && s == "/x");
    assert(classifyDuringTurn(prompt("/plan"), null, s) == DuringTurn.defer);
    assert(classifyDuringTurn(parseJSON(`{"method":"session/cancel","params":{"sessionId":"other"}}`), "me", s) == DuringTurn.defer);
    // Requeued escaped steers are re-escaped.
    auto q = requeueSteers(null, [Steer("/x")], [0], null);
    assert(promptText(get(q[0], "params")) == "//x");
    assert(isJsonRpcRequest(parseJSON(`{"jsonrpc":"2.0","method":"session/cancel"}`)));
    assert(!isJsonRpcRequest(parseJSON(`{}`)) && !isJsonRpcRequest(parseJSON(`null`)));
}

// rust: acp.rs::path_leading_prompts_reach_the_model_over_acp
unittest // a prompt starting with a path is a prompt, not a command (Rust #173)
{
    string t = "\n/workspace is the only path you share with the user.\n\nWrite a FEEL expression to /workspace/answer.feel";
    auto orig = t;
    assert(enforceSlashInvariant(t) is null && t == orig);
    t = "/tmp/foo is empty, why?";
    assert(enforceSlashInvariant(t) is null && t == "/tmp/foo is empty, why?");
    string s;
    auto prompt = parseJSON(`{"method":"session/prompt","params":{"prompt":[{"type":"text","text":"/tmp/x is odd"}]}}`);
    assert(classifyDuringTurn(prompt, null, s) == DuringTurn.steer && s == "/tmp/x is odd");
}

// End to end: a prompt runs a tool, streams updates and returns its stop reason.
// rust: agent.rs::emits_acp_updates_for_messages_and_tools
unittest
{
    import nano.providers.mock;
    import nano.tools;
    import nano.permissions : Policy;
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("echo", "", parseJSON(`{"type":"object"}`)), (JSONValue a) => "pong");
    auto mock = new MockClient([LLMResponse("", "", [ToolCall.fromRaw("c1", "echo", `{}`)]), LLMResponse("done")]);
    auto agent = new Agent(mock, reg, Policy.init, null);
    string[] lines;
    auto srv = new AcpServer(agent, Host((string cwd) => "sys", null, null, "test"), (string l) { lines ~= l; });
    srv.receive(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`);
    srv.receive(`{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}`);
    srv.receive(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"prompt":[{"type":"text","text":"hi"}]}}`);
    srv.receive(`{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"prompt":[{"type":"text","text":"/nope"}]}}`);
    srv.close();
    assert(srv.run());
    auto j = (size_t i) => parseJSON(lines[i]);
    assert(j(0)["result"]["protocolVersion"].integer == 1);
    auto sid = j(1)["result"]["sessionId"].str;
    string[] kinds;
    foreach (l; lines[2 .. $])
    {
        auto m = parseJSON(l);
        if ("method" in m) { assert(m["params"]["sessionId"].str == sid); kinds ~= m["params"]["update"]["sessionUpdate"].str; }
    }
    assert(kinds == ["tool_call", "tool_call_update", "agent_message_chunk"], kinds.format!"%s");
    auto r3 = parseJSON(lines[$ - 2]);
    assert(r3["id"].integer == 3 && r3["result"]["stopReason"].str == "end_turn" && r3["result"]["response"].str == "done");
    auto r4 = parseJSON(lines[$ - 1]);
    assert(r4["id"].integer == 4 && r4["result"]["response"].str.canFind("Unknown command /nope"));
    assert(agent.messages[0].content == "sys");
}

// session/load replays a logged session as it was shown live: a failed tool
// is "failed", and a tool result keeps its image marker.
// rust: agent.rs::failed_tool_reports_failed_status_and_replay_covers_history
// rust: agent.rs::replay_shows_the_image_marker_on_persisted_tool_results
unittest
{
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import nano.attachment : Attachment;
    import nano.option : some;
    import nano.permissions : Policy;
    import nano.providers.mock;
    import nano.session : SessionLog;
    import nano.tools;
    auto dir = buildPath(tempDir, "nano-acp-replay");
    if (exists(dir)) rmdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    JSONValue[] updates(string[] lines)
    {
        JSONValue[] u;
        foreach (l; lines)
        {
            auto m = parseJSON(l);
            if ("method" in m) u ~= m["params"]["update"];
        }
        return u;
    }
    static class Sink { string[] lines; }
    AcpServer server(LLMResponse[] script, Sink sink)
    {
        auto reg = new ToolRegistry;
        reg.register(ToolDefinition("broken", "fails", parseJSON(`{"type":"object"}`)), (JSONValue a) {
            throw new ToolError("boom");
            return "";
        });
        auto agent = new Agent(new MockClient(script), reg, Policy.init, null);
        return new AcpServer(agent, Host((string cwd) => "sys", null, dir, "test"), (string l) { sink.lines ~= l; });
    }

    auto live = new Sink;
    auto srv = server([LLMResponse("", "", [ToolCall.fromRaw("b1", "broken", `{}`)]), LLMResponse("sorry")], live);
    srv.receive(`{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}`);
    srv.receive(`{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"prompt":[{"type":"text","text":"try"}]}}`);
    srv.close();
    assert(srv.run());
    auto sid = parseJSON(live.lines[0])["result"]["sessionId"].str;
    auto u = updates(live.lines);
    assert(u[1]["status"].str == "failed", u[1].toString);

    auto replayed = new Sink;
    srv = server([], replayed);
    srv.receive(`{"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"` ~ sid ~ `"}}`);
    srv.close();
    assert(srv.run());
    u = updates(replayed.lines);
    string[] kinds;
    foreach (x; u) kinds ~= x["sessionUpdate"].str;
    assert(kinds == ["user_message_chunk", "tool_call", "tool_call_update", "agent_message_chunk"], kinds.format!"%s");
    assert(u[0]["content"]["text"].str == "try");
    assert(u[2]["toolCallId"].str == "b1" && u[2]["status"].str == "failed", "replay matches the live status");

    // A persisted image result.
    auto log = new SessionLog(dir, "mock/m", "/w");
    auto sys = Message.system("sys");
    log.append(sys);
    auto call = Message.assistant("");
    call.toolCalls = [ToolCall.fromRaw("t1", "read_file", `{}`)];
    log.append(call);
    Attachment img;
    img.mediaType = "image/png";
    img.path = "x.png";
    img.width = 12;
    img.height = 34;
    img.extension = "png";
    auto res = Message.toolResult("t1", "read_file", "saw it");
    res.attachments = [img];
    log.append(res);
    auto shown = new Sink;
    srv = server([], shown);
    srv.receive(`{"jsonrpc":"2.0","id":1,"method":"session/load","params":{"sessionId":"` ~ log.id ~ `"}}`);
    srv.close();
    assert(srv.run());
    JSONValue upd;
    foreach (x; updates(shown.lines)) if (x["sessionUpdate"].str == "tool_call_update") upd = x;
    auto raw = upd["rawOutput"].str;
    assert(raw.canFind("[image: x.png, 12×34]") && raw.canFind("saw it"), raw);
}

// rust: acp.rs::escaped_prompts_steer_mid_turn_while_commands_defer
// rust: acp.rs::only_jsonrpc_requests_count_as_valid_acp
// rust: acp.rs::only_unabsorbed_steers_are_requeued
// rust: acp.rs::requeued_escaped_steers_are_re_escaped
// rust: acp.rs::slash_prompts_never_reach_the_model_over_acp
unittest
{
    JSONValue prompt(string t)
    {
        return parseJSON(`{"method":"session/prompt","params":{"prompt":[{"type":"text","text":` ~ JSONValue(t).toString ~ `}]}}`);
    }
    string s;
    assert(classifyDuringTurn(prompt("//usr/lib is big"), null, s) == DuringTurn.steer && s == "/usr/lib is big");
    assert(classifyDuringTurn(prompt("keep going"), null, s) == DuringTurn.steer && s == "keep going");
    assert(classifyDuringTurn(prompt("/plan"), null, s) == DuringTurn.defer);
    assert(classifyDuringTurn(prompt("   "), null, s) == DuringTurn.defer);

    assert(isJsonRpcRequest(parseJSON(`{"jsonrpc": "2.0", "method": "initialize", "id": 1}`)));
    assert(isJsonRpcRequest(parseJSON(`{"jsonrpc": "2.0", "method": "session/cancel"}`)));
    foreach (bad; [`{}`, `null`, `42`, `{"method": "initialize"}`, `{"jsonrpc": "2.0"}`, `{"jsonrpc": "2.0", "method": 1}`])
        assert(!isJsonRpcRequest(parseJSON(bad)), bad);

    string[] order(JSONValue[] xs)
    {
        string[] o;
        foreach (m; xs) o ~= getStr(m, "method") == "session/prompt" ? promptText(get(m, "params")) : getStr(m, "method");
        return o;
    }
    // Three steers arrived; the first was absorbed into the turn.
    auto q = requeueSteers([parseJSON(`{"method": "cmd"}`)], [Steer("b"), Steer("c")], [0, 0, 1], null);
    assert(order(q) == ["b", "cmd", "c"], order(q).format!"%s");
    q = requeueSteers(null, [Steer("/usr/lib is big")], [0], "s");
    assert(promptText(get(q[0], "params")) == "//usr/lib is big");
    q = requeueSteers(null, [Steer("keep going")], [0], "s");
    assert(promptText(get(q[0], "params")) == "keep going");

    string t = "/exin";
    assert(enforceSlashInvariant(t).startsWith("Unknown command /exin. Did you mean /exit?"), enforceSlashInvariant(t));
    foreach (h; ["/help", "/help me"])
    {
        t = h;
        assert(enforceSlashInvariant(t) == "Can't run /help: this command is not available over ACP", h);
    }
    foreach (cmd; ["/settings foo", "/plan foo", "/tools foo", "/providers foo", "/model"])
    {
        t = cmd;
        assert(enforceSlashInvariant(t) == format(`Can't run "%s" over ACP`, cmd), enforceSlashInvariant(t));
    }
    t = "  /exin";
    assert(enforceSlashInvariant(t) !is null);
    t = "//usr/lib is big";
    assert(enforceSlashInvariant(t) is null && t == "/usr/lib is big");
    t = "hello world\n";
    assert(enforceSlashInvariant(t) is null && t == "hello world\n");
}
