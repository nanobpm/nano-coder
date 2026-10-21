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

enum string versionString = "nano-coder-d 0.1.0 (D port of nano-coder; see PORTING.md)";

enum string usage = `Usage: nano-coder-d [--model provider/model] [--config PATH] [-p PROMPT]
                    [--resume [SESSION_ID|last]] [--plan] [--allow RULE]... [--deny RULE]...
                    [--no-session] [--verbose]
       nano-coder-d --list-models PROVIDER[/model]
       nano-coder-d --version

Reads the Rust nano-coder's config (~/.config/nano-coder/config.toml).
-p runs one prompt and exits; with no -p, prompts are read from stdin (a REPL on a terminal).
REPL commands: /help /model [spec] /plan /normal /clear /usage /quit`;

struct Options
{
    string model, configPath, prompt, resume, listModels;
    bool plan, noSession, verbose, hasResume;
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
    return o;
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

string buildSystemPrompt(const ref Config c, string cwd, bool plan)
{
    import std.datetime.systime : Clock;
    auto base = c.systemPrompt.length ? c.systemPrompt : "You are a helpful assistant with access to tools.";
    version (OSX) enum os = "macOS";
    else version (linux) enum os = "Linux";
    else enum os = "unknown";
    auto s = format("%s\n\nWorking directory: %s\nPlatform: %s\nToday's date: %s", base, cwd, os,
            Clock.currTime.toISOExtString[0 .. 10]);
    s ~= projectInstructions(cwd);
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
    registerSearch(tools);

    auto cwd = getcwd();
    auto agent = new Agent(client, tools, policy, buildSystemPrompt(cfg, cwd, o.plan));
    agent.maxIterations = cfg.maxIterations;
    agent.maxTokens = cfg.maxTokens;
    agent.temperature = cfg.temperature;

    try
    {
        if (o.hasResume)
        {
            auto path = findSession(sessionDir, o.resume);
            foreach (m; loadSession(path))
                if (m.role != Role.system) agent.messages ~= m;
            if (!o.noSession) agent.log = new SessionLog(path);
            stderr.writefln("resumed %s (%s messages)", path, agent.messages.length - 1);
        }
        else if (!o.noSession)
        {
            agent.log = new SessionLog(sessionDir, spec, cwd);
            foreach (m; agent.messages) agent.log.append(m);
        }
    }
    catch (Exception e) die(e.msg);

    auto console = new Console(isTerminal(1) && environment.get("NO_COLOR") is null, o.verbose);

    bool turn(string input)
    {
        try
        {
            agent.run(input, console);
            console.endLine();
            return true;
        }
        catch (Exception e)
        {
            console.endLine();
            stderr.writeln(console.red("error: " ~ e.msg));
            return false;
        }
    }

    if (o.prompt.length) return turn(o.prompt) ? 0 : 1;

    bool interactive = isTerminal(0);
    if (interactive)
        writefln("%s\n%s/%s · %s · /help for commands", console.bold("nano-coder-d"), client.providerName,
                client.modelName, cwd);
    for (;;)
    {
        if (interactive) { write(console.bold("\n› ")); stdout.flush(); }
        auto line = readln();
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
