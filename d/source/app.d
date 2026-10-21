/// nano-coder-d command line: a plain line-based REPL, one-shot `-p`, and the
/// flags of the Rust CLI that this port implements.
module app;

import std.stdio;
import std.json;
import std.format : format;
import std.string : strip, startsWith, indexOf;
import std.file : getcwd, exists, readText;
import std.process : environment;
import core.stdc.stdlib : exit;
import nano.config;
import nano.llm;
import nano.agent;
import nano.providers;
import nano.tools;
import nano.tools.bash : bashDefinition = definition, bashExecute = execute;
import nano.tools.files : ReadState, registerFiles = register;
import nano.tools.search : registerSearch = register;
import nano.permissions;
import nano.session;
import nano.toml : parseToml;
import nano.skills : Skills, skillsDefinition = definition;
import nano.control : TurnControl, FdLineReader;
import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

enum string versionString = "nano-coder-d 0.1.0 (D port of nano-coder; see PORTING.md)";

enum string usage = `Usage: nano-coder-d [--model provider/model] [--config PATH] [-p PROMPT]
                    [--resume [SESSION_ID|last]] [--plan] [--allow RULE]... [--deny RULE]...
                    [--no-session] [--verbose] [--acp]
       nano-coder-d --list-sessions [--all] [--json]
       nano-coder-d --list-models PROVIDER[/model]
       nano-coder-d --version

Reads the Rust nano-coder's config (~/.config/nano-coder/config.toml).
-p runs one prompt and exits; with no -p, prompts are read from stdin (a REPL on a terminal).
--acp serves the Agent Client Protocol (JSON-RPC 2.0, one message per line) on stdin/stdout.
REPL commands: /help /model [spec] /plan /normal /clear /usage /quit
Ctrl-C cancels a running turn; a line typed during a turn steers it.`;

struct Options
{
    string model, configPath, prompt, resume, listModels;
    bool plan, noSession, verbose, hasResume, acp, listSessions, all, json;
    string[] allow, deny;
}

Options parseArgs(string[] args)
{
    Options o;
    for (size_t i = 1; i < args.length; i++)
    {
        auto a = args[i];
        auto eq = a.startsWith("--") ? a.indexOf('=') : -1;
        auto flag = eq > 0 ? a[0 .. eq] : a;
        string value()
        {
            if (eq > 0) return a[eq + 1 .. $];
            if (i + 1 >= args.length) die(flag ~ " needs a value");
            return args[++i];
        }
        switch (flag)
        {
            case "--model", "-m": o.model = value(); break;
            case "--config": o.configPath = value(); break;
            case "-p", "--prompt": o.prompt = value(); break;
            case "--list-models": o.listModels = value(); break;
            case "--allow": o.allow ~= value(); break;
            case "--deny": o.deny ~= value(); break;
            case "--plan": o.plan = true; break;
            case "--acp": o.acp = true; break;
            case "--list-sessions": o.listSessions = true; break;
            case "--all": o.all = true; break;
            case "--json": o.json = true; break;
            case "--no-session": o.noSession = true; break;
            case "--verbose", "-v": o.verbose = true; break;
            case "--resume":
                o.hasResume = true;
                if (eq > 0) o.resume = value();
                else if (i + 1 < args.length && !args[i + 1].startsWith("-")) o.resume = args[++i];
                else o.resume = "last";
                break;
            case "--version", "-V": writeln(versionString); exit(0);
            case "--help", "-h": writeln(usage); exit(0);
            default: die("unknown argument " ~ a ~ "\n\n" ~ usage);
        }
    }
    if ((o.all || o.json) && !o.listSessions) die("--all and --json require --list-sessions");
    if (o.listSessions && (o.hasResume || o.acp || o.listModels.length || o.prompt.length))
        die("--list-sessions can't be combined with --resume, --acp, --list-models or -p");
    return o;
}

/// `--list-sessions [--all] [--json]`: this directory's saved sessions, newest first.
int printSessions(bool all, bool json)
{
    import std.algorithm : filter;
    import std.array : array;
    auto cwd = getcwd();
    auto shown = listSessions(sessionDir).filter!(s => all || s.cwd == cwd).array;
    if (json)
    {
        JSONValue[] items;
        foreach (s; shown)
        {
            JSONValue j = ["id": s.id, "last_used": s.lastUsed.toISOExtString];
            j["prompts"] = s.prompts;
            if (s.cwd.length) j["cwd"] = s.cwd;
            if (s.model.length) j["model"] = s.model;
            if (s.createdAt.length) j["created_at"] = s.createdAt;
            if (s.firstPrompt.length) j["first_prompt"] = s.firstPrompt;
            if (s.lastPrompt.length) j["last_prompt"] = s.lastPrompt;
            if (s.contextPrompt.length) j["context_prompt"] = s.contextPrompt;
            items ~= j;
        }
        writeln(JSONValue(items).toPrettyString);
        return 0;
    }
    if (!shown.length)
    {
        stderr.writefln("No saved sessions%s.", all ? "" : " for " ~ oneLine(cwd) ~ " (--all lists every directory)");
        return 0;
    }
    import std.datetime.systime : Clock;
    auto now = Clock.currTime;
    foreach (s; shown) writeln(listRow(s, now));
    return 0;
}

noreturn die(string msg)
{
    stderr.writeln("nano-coder-d: ", msg);
    exit(2);
}

bool isTerminal(int fd)
{
    import core.sys.posix.unistd : isatty;
    return isatty(fd) != 0;
}

/// Renders agent events on the terminal.
// Ctrl-C handling: cancel the running turn, or exit when idle.
__gshared TurnControl gControl;
shared bool gTurnRunning;

extern (C) void onInterrupt(int) nothrow @nogc @system
{
    import core.sys.posix.unistd : write, _exit;
    if (atomicLoad(gTurnRunning) && gControl !is null)
    {
        gControl.cancel();
        enum msg = "\n[cancelling...]\n";
        write(2, msg.ptr, msg.length);
    }
    else _exit(130);
}

/// Lines read from the terminal on a background thread, so the user can
/// steer a running turn: a line typed mid-turn goes to the agent before its
/// next step; a `/command` waits for the turn to finish.
final class Inbox
{
    private Mutex lock;
    private Condition ready;
    private string[] lines;
    private bool eof;

    this() { lock = new Mutex; ready = new Condition(lock); }

    void put(string line, bool front = false)
    {
        lock.lock();
        scope (exit) lock.unlock();
        if (line is null) eof = true;
        else lines = front ? line ~ lines : lines ~ line;
        ready.notify();
    }

    /// The next line, or null at end of input.
    string take()
    {
        lock.lock();
        scope (exit) lock.unlock();
        while (!lines.length && !eof) ready.wait();
        if (!lines.length) return null;
        auto l = lines[0];
        lines = lines[1 .. $];
        return l;
    }

    void readLoop(Console console)
    {
        // Not readln: see FdLineReader (a blocked readln deadlocks spawnProcess).
        auto input = FdLineReader(0);
        for (;;)
        {
            auto line = input.next();
            if (line is null) { put(null); return; }
            auto text = line.strip;
            if (atomicLoad(gTurnRunning) && text.length && !text.startsWith("/"))
            {
                gControl.steer(text);
                stderr.writeln(console.dim("↪ steer: " ~ text ~ " (read at the agent's next step)"));
            }
            else
            {
                if (atomicLoad(gTurnRunning) && text.length)
                    stderr.writeln(console.dim("[waits for the turn to finish: " ~ text ~ "]"));
                put(text);
            }
        }
    }
}

class Console : AgentEvents
{
    bool color, verbose;
    private bool inReasoning, midLine;

    this(bool color, bool verbose) { this.color = color; this.verbose = verbose; }

    string dim(string s) { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }
    string bold(string s) { return color ? "\x1b[1m" ~ s ~ "\x1b[0m" : s; }
    string red(string s) { return color ? "\x1b[31m" ~ s ~ "\x1b[0m" : s; }

    void text(bool reasoning, string chunk)
    {
        if (reasoning && !verbose) return;
        if (reasoning != inReasoning && midLine) { write("\n"); midLine = false; }
        inReasoning = reasoning;
        write(reasoning ? dim(chunk) : chunk);
        if (chunk.length) midLine = chunk[$ - 1] != '\n';
        stdout.flush();
    }

    void endLine()
    {
        if (midLine) writeln();
        midLine = false;
        inReasoning = false;
    }

    void toolStart(const ref ToolCall call)
    {
        endLine();
        writeln(bold("● " ~ call.name), " ", dim(summary(call)));
        stdout.flush();
    }

    void toolEnd(const ref ToolCall call, string result, bool isError)
    {
        auto lines = result.lineCount;
        if (isError) writeln("  ", red("✗ " ~ result.firstLine));
        else if (verbose) writeln(dim(indent(result)));
        else writeln(dim(format("  ⎿ %s", lines > 1 ? format("%s lines", lines) : result.firstLine)));
        stdout.flush();
    }

    void usage(TokenUsage u) {}
    void userMessage(string text) { endLine(); writeln(dim("↪ " ~ text)); }
    void assistantMessage(string text, string reasoning) {}

    static string summary(const ref ToolCall c)
    {
        if (c.invalidArguments.length) return "(invalid arguments)";
        foreach (k; ["command", "path", "pattern"])
            if (auto v = k in c.arguments)
                if (v.type == JSONType.string)
                {
                    auto s = v.str.firstLine;
                    return s.length > 120 ? s[0 .. 120] ~ "…" : s;
                }
        return c.encodedArguments;
    }
}

size_t lineCount(string s)
{
    import std.algorithm : count;
    return s.length ? s.count('\n') + (s[$ - 1] == '\n' ? 0 : 1) : 0;
}

string firstLine(string s)
{
    auto nl = s.indexOf('\n');
    auto l = nl >= 0 ? s[0 .. nl] : s;
    return l.length > 160 ? l[0 .. 160] ~ "…" : l;
}

string indent(string s)
{
    import std.array : replace;
    auto t = s.length > 2000 ? s[0 .. 2000] ~ "\n…" : s;
    return "    " ~ t.replace("\n", "\n    ");
}

enum string planNote = "\n\nYou are in PLAN MODE: read-only. Do not create, modify or delete files or run commands with side effects; "
    ~ "investigate with the read-only tools and present a plan.";

string buildSystemPrompt(const ref Config c, string cwd, bool plan, const Skills skills = null)
{
    import std.datetime.systime : Clock;
    auto base = c.systemPrompt.length ? c.systemPrompt : "You are a helpful assistant with access to tools.";
    version (OSX) enum os = "macOS";
    else version (linux) enum os = "Linux";
    else enum os = "unknown";
    auto s = format("%s\n\nWorking directory: %s\nPlatform: %s\nToday's date: %s", base, cwd, os,
            Clock.currTime.toISOExtString[0 .. 10]);
    s ~= projectInstructions(cwd);
    if (skills !is null) s ~= skills.renderIndex;
    if (plan) s ~= planNote;
    return s;
}

int main(string[] args)
{
    auto o = parseArgs(args);
    auto cfgPath = o.configPath.length ? o.configPath : Config.defaultPath;
    Config cfg;
    JSONValue rawConfig = JSONValue(string[string].init);
    try
    {
        cfg = Config.load(cfgPath);
        if (cfgPath.exists) rawConfig = parseToml(readText(cfgPath));
    }
    catch (Exception e) die(e.msg);

    if (o.listSessions) return printSessions(o.all, o.json);
    if (o.listModels.length)
    {
        try
        {
            foreach (m; makeClient(resolve(cfg, o.listModels)).listModels) writeln(m);
            return 0;
        }
        catch (Exception e) die(e.msg);
    }

    auto spec = o.model.length ? o.model : cfg.model;
    LLMClient client;
    try client = makeClient(resolve(cfg, spec));
    catch (Exception e) die(e.msg);

    Policy policy;
    try policy = Policy.fromConfig("permissions" in rawConfig ? rawConfig["permissions"] : JSONValue(null));
    catch (Exception e) die("[permissions]: " ~ e.msg);
    try
    {
        foreach (r; o.allow) policy.allow ~= parseRule(r);
        foreach (r; o.deny) policy.deny ~= parseRule(r);
    }
    catch (Exception e) die(e.msg);
    if (o.plan) policy.mode = Mode.plan;

    auto tools = new ToolRegistry;
    auto readState = new ReadState;
    auto bashTimeout = cfg.bashTimeoutSecs;
    tools.register(bashDefinition(bashTimeout), (JSONValue a) => bashExecute(a, bashTimeout));
    registerFiles(tools, readState);
    Agent agent;
    // Read-deny rules hide paths from search results (Policy.readDenied).
    registerSearch(tools, (string path) => agent.policy.readDenied(path, getcwd()));

    auto cwd = getcwd();
    // Skills: the index goes into the system prompt; `load_skill` reads one.
    Skills skills;
    Skills discoverSkills(string dir)
    {
        if (!cfg.skills.enabled) return null;
        auto s = Skills.discover(dir, cfg.skills);
        foreach (w; s.warnings) stderr.writeln("nano-coder-d: skills: ", w);
        return s;
    }
    skills = discoverSkills(cwd);
    if (cfg.skills.enabled && (o.acp || !skills.empty))
        tools.register(skillsDefinition, (JSONValue a) => skills.load(a));
    agent = new Agent(client, tools, policy, buildSystemPrompt(cfg, cwd, o.plan, skills));
    agent.maxIterations = cfg.maxIterations;
    agent.maxTokens = cfg.maxTokens;
    agent.temperature = cfg.temperature;

    if (o.acp)
    {
        import nano.acp : AcpServer, Host;
        Host host;
        bool plan = o.plan;
        host.systemPrompt = (string dir) {
            if (dir != cwd) skills = discoverSkills(dir);
            return buildSystemPrompt(cfg, dir, plan, skills);
        };
        host.makeClient = (string s) => makeClient(resolve(cfg, s));
        host.sessionDir = o.noSession ? null : sessionDir;
        host.version_ = versionString;
        auto server = new AcpServer(agent, host);
        if (!server.serveStdio())
        {
            stderr.writeln("nano-coder-d: no ACP JSON-RPC request received on stdin");
            return 1;
        }
        return 0;
    }

    try
    {
        if (o.hasResume)
        {
            auto path = findSession(sessionDir, o.resume, cwd);
            auto restored = restore(path);
            foreach (m; restored.conversation)
                if (m.role != Role.system) agent.messages ~= m;
            if (!o.noSession) agent.log = new SessionLog(path);
            stderr.writefln("resumed %s (%s messages)", restored.id, agent.messages.length - 1);
            if (restored.pendingInput.length)
                stderr.writefln("the last prompt never finished (the session was interrupted): %s",
                    oneLine(restored.pendingInput));
        }
        else if (!o.noSession)
        {
            agent.log = new SessionLog(sessionDir, spec, cwd);
            foreach (m; agent.messages) agent.log.append(m);
        }
    }
    catch (Exception e) die(e.msg);

    auto console = new Console(isTerminal(1) && environment.get("NO_COLOR") is null, o.verbose);

    gControl = agent.control;
    {
        import core.sys.posix.signal : sigaction, sigaction_t, SIGINT, sigemptyset;
        sigaction_t sa;
        sa.sa_handler = &onInterrupt;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGINT, &sa, null);
    }
    Inbox inbox;

    bool turn(string input)
    {
        atomicStore(gTurnRunning, true);
        scope (exit) atomicStore(gTurnRunning, false);
        bool ok = true;
        try agent.run(input, console);
        catch (Exception e)
        {
            console.endLine();
            stderr.writeln(console.red("error: " ~ e.msg));
            ok = false;
        }
        console.endLine();
        // Steers that arrived after the agent's last step run as the next prompts.
        auto late = agent.control.takePending;
        if (inbox !is null)
            foreach_reverse (t; late) inbox.put(t.text, true);
        return ok;
    }

    if (o.prompt.length) return turn(o.prompt) ? 0 : 1;

    bool interactive = isTerminal(0);
    if (interactive)
    {
        import core.thread : Thread;
        inbox = new Inbox;
        auto reader = new Thread(() => inbox.readLoop(console));
        reader.isDaemon = true;
        reader.start();
    }
    if (interactive)
        writefln("%s\n%s/%s · %s · /help for commands", console.bold("nano-coder-d"), client.providerName,
                client.modelName, cwd);
    for (;;)
    {
        if (interactive) { write(console.bold("\n› ")); stdout.flush(); }
        auto line = inbox !is null ? inbox.take() : readln();
        if (line is null) break;
        auto input = line.strip;
        if (!input.length) continue;
        if (input.startsWith("/"))
        {
            auto sp = input.indexOf(' ');
            auto cmd = sp > 0 ? input[0 .. sp] : input;
            auto arg = sp > 0 ? input[sp + 1 .. $].strip : "";
            switch (cmd)
            {
                case "/quit", "/exit": return 0;
                case "/help": writeln(usage); continue;
                case "/clear":
                    agent.messages = agent.messages[0 .. 1];
                    if (agent.log !is null) agent.log.replace(agent.messages);
                    writeln("conversation cleared");
                    continue;
                case "/usage":
                    writefln("last request: %s input (%s cached), %s output tokens", agent.lastUsage.inputTokens,
                            agent.lastUsage.cachedInputTokens, agent.lastUsage.outputTokens);
                    continue;
                case "/plan", "/normal":
                    bool plan = cmd == "/plan";
                    agent.policy.mode = plan ? Mode.plan : Mode.normal;
                    agent.messages[0].content = buildSystemPrompt(cfg, cwd, plan);
                    writeln(plan ? "plan mode: read-only" : "normal mode");
                    continue;
                case "/model":
                    if (!arg.length) { writeln(client.providerName, "/", client.modelName); continue; }
                    try
                    {
                        client = makeClient(resolve(cfg, arg));
                        agent.client = client;
                        writeln("model: ", client.providerName, "/", client.modelName);
                    }
                    catch (Exception e) stderr.writeln(console.red("error: " ~ e.msg));
                    continue;
                default:
                    stderr.writeln("unknown command ", cmd, " (/help)");
                    continue;
            }
        }
        turn(input);
    }
    return 0;
}
