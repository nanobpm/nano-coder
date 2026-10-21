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

import std.json;
import std.format : format;
import std.string : strip, startsWith, indexOf;
import std.algorithm : canFind;
import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import nano.agent;
import nano.claude_hooks : HookManager;
import nano.control;
import nano.llm;
import nano.session;

enum int protocolVersion = 1;

import nano.paths : debugQuote;
import nano.thinking : wireValue, setSession, label;
import nano.temperature : label;
import std.array : join;

/// Commands `handle` services over ACP. Reaching the slash fallback with one
/// of these means only its arguments were not accepted.
immutable string[] acpCommandRoots = ["/tools", "/settings", "/model"];

JSONValue rpcResult(JSONValue id, JSONValue result)
{
    JSONValue m = ["jsonrpc": JSONValue("2.0")];
    m["id"] = id;
    m["result"] = result;
    return m;
}

JSONValue rpcError(JSONValue id, long code, string message)
{
    JSONValue m = ["jsonrpc": JSONValue("2.0")];
    m["id"] = id;
    m["error"] = JSONValue(["code": JSONValue(code), "message": JSONValue(message)]);
    return m;
}

private JSONValue get(JSONValue v, string key)
{
    if (v.type != JSONType.object) return JSONValue(null);
    if (auto p = key in v) return *p;
    return JSONValue(null);
}

private string getStr(JSONValue v, string key)
{
    auto x = get(v, key);
    return x.type == JSONType.string ? x.str : null;
}

/// The text of a `session/prompt`: its text content blocks, joined.
string promptText(JSONValue params)
{
    string out_;
    auto p = get(params, "prompt");
    if (p.type == JSONType.array)
        foreach (item; p.array) if (auto t = getStr(item, "text")) out_ ~= t;
    return out_;
}

/// A `//…` line is a prompt that starts with `/`: the text with one `/`
/// removed. null for other lines.
string unescapePrompt(string line)
{
    import std.string : stripLeft;
    auto t = line.stripLeft;
    return t.startsWith("//") ? t[1 .. $] : null;
}

/// Reject a slash prompt no command handled (a non-null note), or return
/// the turn text in `text`.
string enforceSlashInvariant(ref string text)
{
    auto trimmed = text.strip;
    if (trimmed.startsWith("/") && unescapePrompt(trimmed) is null)
    {
        auto sp = trimmed.indexOf(' ');
        auto word = sp > 0 ? trimmed[0 .. sp] : trimmed;
        if (acpCommandRoots.canFind(word)) return format("Can't run %s over ACP", debugQuote(trimmed));
        if (word[1 .. $].canFind('/'))
            return format("Unknown command %s. To send a message starting with a path, type //%s", word, word[1 .. $]);
        return format("Can't run %s: this command is not available over ACP", word);
    }
    if (auto u = unescapePrompt(trimmed)) text = u;
    return null;
}

/// Whether `msg` is a JSON-RPC 2.0 request or notification.
bool isJsonRpcRequest(JSONValue msg)
{
    return getStr(msg, "jsonrpc") == "2.0" && getStr(msg, "method") !is null;
}

enum DuringTurn { cancel, steer, defer }

/// How a message arriving mid-turn is routed; `steerText` is set for steer.
DuringTurn classifyDuringTurn(JSONValue msg, string active, out string steerText)
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
        if (trimmed.startsWith("/") && u is null) return DuringTurn.defer;
        steerText = u !is null ? u : text;
        return DuringTurn.steer;
    }
    return DuringTurn.defer;
}

/// The ACP tool kind, for client display.
string toolKind(string name)
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

private JSONValue textBlock(string t) { return JSONValue(["type": JSONValue("text"), "text": JSONValue(t)]); }

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
}

/// FIFO of parsed messages shared by the reader thread and the turn loop.
private final class Inbox
{
    Mutex lock;
    Condition ready;
    JSONValue[] items;
    bool eof;

    this() { lock = new Mutex; ready = new Condition(lock); }

    void push(JSONValue m)
    {
        lock.lock();
        scope (exit) lock.unlock();
        items ~= m;
        ready.notify();
    }

    void close()
    {
        lock.lock();
        scope (exit) lock.unlock();
        eof = true;
        ready.notify();
    }

    /// The next message; false at end of input.
    bool pop(out JSONValue m)
    {
        lock.lock();
        scope (exit) lock.unlock();
        while (!items.length && !eof) ready.wait();
        if (!items.length) return false;
        m = items[0];
        items = items[1 .. $];
        return true;
    }
}

final class AcpServer : AgentEvents
{
    private Agent agent;
    private Host host;
    private void delegate(string line) writeLine_;
    private Mutex outLock;
    private Inbox inbox;
    private string sessionId;
    private size_t messageSeq;
    // Turn routing, shared with the reader thread (guarded by inbox.lock).
    private shared bool turnActive;
    private size_t[] steerMarks;
    private bool sawValid;

    /// `writeLine` gets one JSON message per call (defaults to stdout).
    this(Agent agent, Host host, void delegate(string) writeLine = null)
    {
        this.agent = agent;
        this.host = host;
        outLock = new Mutex;
        inbox = new Inbox;
        writeLine_ = writeLine !is null ? writeLine : (string l) {
            import std.stdio : stdout;
            stdout.writeln(l);
            stdout.flush();
        };
        agent.onPlanChanged = () {
            JSONValue u = ["sessionUpdate": "plan"];
            u["entries"] = agent.plan.acpEntries;
            u["_meta"] = JSONValue(["plan": agent.plan.toJSON]);
            update(u);
        };
    }

    void send(JSONValue msg)
    {
        outLock.lock();
        scope (exit) outLock.unlock();
        writeLine_(msg.toString);
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

    void text(bool reasoning, string chunk) {}
    void usage(TokenUsage u) {}

    void userMessage(string t)
    {
        update(JSONValue(["sessionUpdate": JSONValue("user_message_chunk"), "content": textBlock(t)]));
    }

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
        u["rawInput"] = parseJSON(call.arguments.toString);
        update(u);
    }

    void toolEnd(const ref ToolCall call, string result, bool isError)
    {
        toolUpdate(call.id, result, isError);
    }

    private void toolUpdate(string id, string output, bool isError)
    {
        update(JSONValue(["sessionUpdate": JSONValue("tool_call_update"), "toolCallId": JSONValue(id),
            "status": JSONValue(isError ? "failed" : "completed"), "rawOutput": JSONValue(output),
            "content": JSONValue([JSONValue(["type": JSONValue("content"), "content": textBlock(output)])])]));
    }

    // ---- input ----

    /// Feed one input line (the reader thread calls this for each stdin line).
    void receive(string line)
    {
        import std.stdio : stderr;
        auto l = line.strip;
        if (!l.length) return;
        JSONValue msg;
        try msg = parseJSON(l);
        catch (Exception e)
        {
            stderr.writeln(sawValid ? "ACP parse error: " ~ e.msg
                : "input doesn't look like ACP JSON-RPC (expected JSON-RPC 2.0, one message per line): " ~ e.msg);
            return;
        }
        if (isJsonRpcRequest(msg)) sawValid = true;
        inbox.lock.lock();
        scope (exit) inbox.lock.unlock();
        if (atomicLoad(turnActive))
        {
            string steerText;
            switch (classifyDuringTurn(msg, sessionId, steerText))
            {
            case DuringTurn.cancel:
                agent.control.cancel();
                auto id = get(msg, "id");
                if (id.type != JSONType.null_) send(rpcResult(id, JSONValue(string[string].init)));
                return;
            case DuringTurn.steer:
                steerMarks ~= inbox.items.length;
                agent.control.steer(Steer(steerText, get(msg, "id")));
                return;
            default:
                break;
            }
        }
        inbox.items ~= msg;
        inbox.ready.notify();
    }

    /// Input has ended.
    void close() { inbox.close(); }

    /// Run until input ends. Returns whether any valid JSON-RPC request arrived.
    bool run()
    {
        JSONValue msg;
        while (inbox.pop(msg)) handle(msg);
        return sawValid;
    }

    /// Serve stdin on a reader thread until it ends.
    bool serveStdio()
    {
        import core.thread : Thread;
        // FdLineReader, not std.stdio: see its comment.
        auto reader = new Thread({
            auto input = FdLineReader(0);
            for (string line; (line = input.next()) !is null;) receive(line);
            close();
        });
        reader.isDaemon = true;
        reader.start();
        return run();
    }

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
                "agentInfo": JSONValue(["name": "nano-coder-d", "version": host.version_]),
                "agentCapabilities": JSONValue(["loadSession": JSONValue(host.sessionDir !is null),
                    "tools": JSONValue(true), "hooks": JSONValue(false), "compact": JSONValue(false)]),
            ])));
            return;
        case "session/new":
            if (auto e = applyCwd(params)) { reply(rpcError(id, -32602, e)); return; }
            try
            {
                newSession();
                reply(rpcResult(id, JSONValue(["sessionId": JSONValue(sessionId), "_meta": JSONValue(string[string].init)])));
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
                reply(rpcResult(id, JSONValue(["sessionId": JSONValue(sessionId), "_meta": JSONValue(string[string].init)])));
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
            runTurn(id, text);
            return;
        default:
            if (hasId && method !is null) reply(rpcError(id, -32601, "method not found: " ~ method));
        }
    }

    /// Slash commands available over ACP; JSONValue.init when `text` isn't one.
    private JSONValue command(string text, JSONValue id)
    {
        if (text == "/tools")
        {
            JSONValue[] names;
            foreach (d; agent.tools.definitions) names ~= JSONValue(d.name);
            return rpcResult(id, JSONValue(["stopReason": JSONValue("end_turn"), "tools": JSONValue(names)]));
        }
        if (text == "/settings")
        {
            JSONValue s = ["provider": agent.client.providerName, "provider_model": agent.client.modelName];
            s["max_tokens"] = agent.maxTokens;
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
                try setSession(agent.sessionThinking, arg);
                catch (Exception e) return rpcError(id, -32602, e.msg);
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
        agent.log = null;
        if (host.sessionDir !is null)
        {
            agent.log = new SessionLog(host.sessionDir, agent.client.providerName ~ "/" ~ agent.client.modelName, cwd);
            foreach (m; agent.messages) agent.log.append(m);
            sessionId = agent.log.id;
        }
        else
        {
            import std.datetime.systime : Clock;
            sessionId = format("session-%x", Clock.currStdTime);
        }
        if (host.loadHooks !is null) agent.useHooks(host.loadHooks(cwd), false);
    }

    private void loadSession_(string want)
    {
        if (host.sessionDir is null) throw new Exception("sessions are disabled (--no-session)");
        import std.file : getcwd;
        auto path = findSession(host.sessionDir, want);
        auto sys = host.systemPrompt !is null ? host.systemPrompt(getcwd()) : null;
        agent.messages = sys.length ? [Message.system(sys)] : null;
        auto restored = restore(path);
        foreach (m; restored.conversation)
            if (m.role != Role.system) agent.messages ~= m;
        agent.historyAvailable = restored.historyAvailable;
        agent.historyHintPending = restored.historyAvailable && !restored.historyHintConsumed;
        agent.log = new SessionLog(path);
        sessionId = agent.log.id;
        if (host.loadHooks !is null) agent.useHooks(host.loadHooks(getcwd()), true);
        replayHistory();
    }

    /// Replay the conversation as session/update notifications.
    private void replayHistory()
    {
        foreach (m; agent.messages)
        {
            switch (m.role)
            {
            default: break;
            case Role.user: userMessage(m.content); break;
            case Role.assistant:
                assistantMessage(m.content, null);
                foreach (c; m.toolCalls) toolStart(c);
                break;
            case Role.tool: toolUpdate(m.toolCallId, m.content, m.isError); break;
            }
        }
    }

    /// Run one prompt turn; the reader thread routes cancels and steers meanwhile.
    private void runTurn(JSONValue id, string text)
    {
        {
            inbox.lock.lock();
            scope (exit) inbox.lock.unlock();
            agent.control.startTurn();
            steerMarks = null;
            atomicStore(turnActive, true);
        }
        string response;
        try response = agent.run(text, this, false);
        catch (Exception e)
        {
            response = "Error: " ~ e.msg;
            agent.lastStop = StopReason.endTurn;
        }
        inbox.lock.lock();
        scope (exit) inbox.lock.unlock();
        atomicStore(turnActive, false);
        auto stop = cast(string) agent.lastStop;
        if (id.type != JSONType.null_)
        {
            auto reply = JSONValue(["stopReason": stop, "response": response]);
            // Extension: the model's explicit completed/blocked report.
            if (agent.hasOutcome && stop == "end_turn") reply["_meta"] = JSONValue(["outcome": agent.lastOutcome.toJSON]);
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
            return;
        }
        inbox.items = requeueSteers(inbox.items, leftover, steerMarks, sessionId);
    }
}

/// Insert steers that missed their turn into `deferred` as prompts, each at
/// the position `deferred` had when it arrived. `leftover` are the last
/// steers to arrive, so they match the tail of `marks`.
JSONValue[] requeueSteers(JSONValue[] deferred, Steer[] leftover, size_t[] marks, string active)
{
    import std.algorithm : min;
    auto first = marks.length > leftover.length ? marks.length - leftover.length : 0;
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

// End to end: a prompt runs a tool, streams updates and returns its stop reason.
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
    assert(r4["id"].integer == 4 && r4["result"]["response"].str.canFind("not available over ACP"));
    assert(agent.messages[0].content == "sys");
}
