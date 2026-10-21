/// nano-coder-d command line: a plain line-based REPL, one-shot `-p`, and the
/// flags of the Rust CLI that this port implements.
module app;

import std.stdio;
import std.json;
import std.format : format;
import std.string : strip, stripRight, startsWith, indexOf;
import nano.turn_commands : LiveView, splitCmd, timing, Timing;
import std.array : join;
static import std.string;
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
import nano.plan : Plan, checklist;
import nano.queue : MessageQueue, QueuedMessage, QueueUsage, queueParse = parse, queueApply = apply;
import nano.mode : AgentMode, allModes, parseMode, planPromptNote, name, describe, nextMode = next;
import nano.question : QuestionBroker, Question, Answer, sanitizeLine, questionDefinition = definition;
import nano.lineedit : LineEditor, Outcome, K, enterKeyMode, leaveKeyMode, fdSource, writeFd, terminalWidth;
import nano.commands : helpText, unescapePrompt;
import core.thread : Thread;
import nano.claude_hooks : HookManager, listingField, label, isProject;
import nano.skills : Skills, skillsDefinition = definition;
import nano.memory : MemoryStore = Store, MemoryMode, memoryDefinitions = definitions, runMemory = run, memoryDefaultDir = defaultDir, projectKey, Scope;
import nano.control : TurnControl, FdLineReader;
import nano.instructions : ProjectInstructions, InstructionOptions = Options, expandHome;
import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

enum string versionString = "nano-coder-d 0.1.0 (D port of nano-coder; see PORTING.md)";

enum string usage = `Usage: nano-coder-d [--model provider/model] [--config PATH] [-p PROMPT]
                    [--resume [SESSION_ID|last]] [--plan] [--sandbox off|workspace|read-only]
                    [--allow RULE]... [--deny RULE]...
                    [--no-session] [--no-hooks] [--verbose] [--acp]
       nano-coder-d --list-sessions [--all] [--json]
       nano-coder-d --trajectory SESSION_ID [--json|--markdown]
       nano-coder-d --list-models PROVIDER[/model]
       nano-coder-d --login github-copilot|muse
       nano-coder-d --version

Reads the Rust nano-coder's config (~/.config/nano-coder/config.toml).
-p runs one prompt and exits; with no -p, prompts are read from stdin (a REPL on a terminal).
--acp serves the Agent Client Protocol (JSON-RPC 2.0, one message per line) on stdin/stdout.
REPL commands: /help /model [spec] /plan /mode [normal|plan] /clear /usage /memory [forget ID] /hooks /tools /skills /session /resume /trajectory /quit
Ctrl-C cancels a running turn; a line typed during a turn steers it.`;

struct Options
{
    string model, configPath, prompt, resume, listModels, sandbox, login, trajectory;
    bool markdown, plan, noSession, noHooks, verbose, hasResume, acp, listSessions, all, json;
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
            case "--login": o.login = value(); break;
            case "--allow": o.allow ~= value(); break;
            case "--deny": o.deny ~= value(); break;
            case "--plan": o.plan = true; break;
            case "--sandbox": o.sandbox = value(); break;
            case "--acp": o.acp = true; break;
            case "--list-sessions": o.listSessions = true; break;
            case "--all": o.all = true; break;
            case "--json": o.json = true; break;
            case "--markdown": o.markdown = true; break;
            case "--trajectory": o.trajectory = value(); break;
            case "--no-session": o.noSession = true; break;
            case "--no-hooks": o.noHooks = true; break;
            case "--verbose", "-v": o.verbose = true; break;
            case "--resume":
                o.hasResume = true;
                if (eq > 0) o.resume = value();
                else if (i + 1 < args.length && !args[i + 1].startsWith("-")) o.resume = args[++i];
                else o.resume = "";
                break;
            case "--version", "-V": writeln(versionString); exit(0);
            case "--help", "-h": writeln(usage); exit(0);
            default: die("unknown argument " ~ a ~ "\n\n" ~ usage);
        }
    }
    if (o.json && o.markdown) die("--json and --markdown are mutually exclusive");
    if (o.markdown && o.trajectory is null) die("--markdown requires --trajectory <id>");
    if (o.json && o.trajectory is null && !o.listSessions) die("--json requires --trajectory <id> or --list-sessions");
    if (o.all && !o.listSessions) die("--all requires --list-sessions");
    if (o.listSessions && o.trajectory !is null) die("--list-sessions and --trajectory are mutually exclusive");
    if (o.hasResume && o.trajectory !is null) die("--resume and --trajectory are mutually exclusive");
    if (o.listSessions && (o.hasResume || o.acp || o.listModels.length || o.prompt.length || o.login.length))
        die("--list-sessions can't be combined with --resume, --acp, --list-models, --login or -p");
    if (o.hasResume && o.login.length) die("--resume and --login are mutually exclusive");
    return o;
}

/// `--login PROVIDER`: interactive device-flow sign-in.
int runLogin(string provider)
{
    import core.thread : Thread;
    import core.time : seconds;
    import std.functional : toDelegate;
    void delegate(string) @safe note = toDelegate((string s) @trusted { stderr.writeln(s); });
    void delegate(long) @safe sleep = toDelegate((long n) @trusted { Thread.sleep(n.seconds); });
    try
    {
        switch (provider)
        {
            case "github-copilot":
                import nano.copilot : copilotLogin = login;
                writeln("Saved GitHub Copilot credentials to ", copilotLogin(note, sleep));
                return 0;
            case "muse":
                import nano.muse : museLogin = login;
                writeln("Saved Muse Code credentials to ", museLogin(note, sleep));
                return 0;
            default:
                die(format("unknown provider %(%s%) for --login; supported: github-copilot, muse (other providers use API keys)", [provider]));
        }
    }
    catch (Exception e) die(e.msg);
    assert(0);
}

/// `--list-sessions [--all] [--json]`: this directory's saved sessions, newest first.
int printSessions(bool all, bool json)
{
    import nano.resume : printList;
    try printList(sessionDir, getcwd(), all, json);
    catch (Exception e) die(e.msg);
    return 0;
}

/// `--trajectory ID [--json|--markdown]`: a saved session's turn-by-turn ledger.
int printTrajectory(string id, bool json, bool markdown)
{
    import nano.session : validateId;
    import std.path : buildPath;
    static import nano.trajectory;
    try
    {
        validateId(id);
        auto t = nano.trajectory.load(buildPath(sessionDir, id ~ ".jsonl"), id);
        if (json) writeln(t.toJson);
        else if (markdown) writeln(t.toMarkdown);
        else showTrajectory(t);
    }
    catch (Exception e) die(e.msg);
    return 0;
}

/// Print the plain ledger, or page it when both ends are a terminal and it
/// doesn't fit on one screen.
void showTrajectory(const ref nano.trajectory.Trajectory t)
{
    static import nano.trajectory;
    auto text = t.toPlain;
    auto size = nano.trajectory.terminalSize(1);
    bool pageable = isTerminal(0) && isTerminal(1) && size[0] && nano.trajectory.needsPager(text, size[0], size[1]);
    if (!(pageable && nano.trajectory.page(text))) writeln(text);
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

/// Keys during a turn (runs on its own thread until `done`).
/// `/queue …` (not `/queueX`): the parsed edit, or null.
string queueArgs(string text)
{
    if (!text.startsWith("/queue")) return null;
    auto rest = text["/queue".length .. $];
    if (rest.length && rest[0] != ' ' && rest[0] != '\t') return null;
    return rest ~ "\0"; // non-null even when empty; the NUL is stripped by the caller
}

/// Run a `/queue` edit and say what happened.
string runQueueCommand(MessageQueue queue, string args)
{
    try return queueApply(queue, queueParse(args));
    catch (QueueUsage e) return "[" ~ e.msg ~ "]";
}

void turnKeys(LineEditor editor, Console console, shared(bool)* done, ref string[] held, QuestionBroker questions,
    MessageQueue queue, string delegate(string) midTurn = null)
{
    while (!atomicLoad(*done))
    {
        auto r = editor.readLine("↪ ", console.dim("↪ "), true,
            () @trusted => atomicLoad(*done) || questions.pending !is null);
        final switch (r.outcome)
        {
            case Outcome.stopped:
                if (auto qs = questions.pending)
                {
                    console.endLine();
                    questions.resolve(askQuestions(editor, qs));
                    break;
                }
                return;
            case Outcome.eof:
                gControl.cancel();
                return;
            case Outcome.cancel, Outcome.interrupt:
                if (!gControl.isCancelled)
                {
                    gControl.cancel();
                    stderr.writeln(console.dim("[cancelling...]"));
                }
                break;
            case Outcome.line, Outcome.queue:
                auto text = r.text.strip;
                if (!text.length) break;
                if (auto qa = queueArgs(text))
                {
                    // `/queue` only touches the queue, so it runs at once.
                    stderr.writeln(console.dim(runQueueCommand(queue, qa[0 .. $ - 1])));
                    break;
                }
                if (text.startsWith("/") && unescapePrompt(text) is null)
                {
                    // Read-only commands and settings run now (turn_commands.rs).
                    if (midTurn !is null)
                        if (auto shown = midTurn(text))
                        {
                            console.note(shown);
                            break;
                        }
                    held ~= text;
                    stderr.writeln(console.dim("[waits for the turn to finish: " ~ text ~ "]"));
                }
                else if (r.outcome == Outcome.queue)
                {
                    auto id = queue.push(text);
                    stderr.writeln(console.dim(format("↧ queued #%s (%s waiting) — /queue remove %s to drop",
                        id, queue.length, id)));
                }
                else
                {
                    gControl.steer(text);
                    stderr.writeln(console.dim("↪ steer: " ~ text ~ " (read at the agent's next step)"));
                }
                break;
        }
    }
}

/// Ask each question with a picker; dismissing any one dismisses them all.
Answer askQuestions(LineEditor editor, const Question[] qs)
{
    string[] answers;
    foreach (ref q; qs)
    {
        string[] labels;
        foreach (ref opt; q.options)
            labels ~= opt.description.length ? sanitizeLine(opt.label) ~ " — " ~ sanitizeLine(opt.description)
                : sanitizeLine(opt.label);
        ptrdiff_t custom = -1;
        if (q.custom)
        {
            custom = labels.length;
            labels ~= "Type your own answer";
        }
        auto at = editor.select(sanitizeLine(q.question), labels);
        if (at < 0) return Answer(Answer.Kind.dismissed);
        if (at == custom)
        {
            auto r = editor.readLine("Answer: ", "\x1b[1mAnswer:\x1b[0m ");
            if (r.outcome != Outcome.line) return Answer(Answer.Kind.dismissed);
            answers ~= r.text;
        }
        else answers ~= q.options[at].label;
    }
    return Answer(Answer.Kind.answers, answers);
}

/// Ctrl-O: show thinking in full (shared by the prompt and the turn's key reader).
shared bool gThinkingExpanded;

class Console : AgentEvents
{
    bool color, verbose, tty;
    private bool inReasoning, midLine;
    // The reasoning block being shown (as in Rust's legacy renderer): a live
    // one-line view redrawn in place, then "∴ Thought for Ns · N chars", or
    // the full text when expanded (Ctrl-O or --verbose).
    private bool thinking, blockExpanded, streamedThinking;
    private string thinkText, lastThinking;
    private long thinkStart, lastDraw;

    this(bool color, bool verbose, bool tty = false)
    {
        this.color = color;
        this.verbose = verbose;
        this.tty = tty;
    }

    private static long nowMs() @trusted
    {
        import core.time : MonoTime;
        return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    private string thinkStyle(string s) { return color ? "\x1b[38;5;245m" ~ s ~ "\x1b[0m" : s; }

    /// The one-line view of a streaming block.
    private string collapsedLine()
    {
        import std.array : split, join;
        import std.range : walkLength, drop;
        import std.conv : to;
        enum prefix = "∴ Thinking: ", suffix = "  (ctrl+o to expand)";
        auto w = isTerminal(1) ? terminalWidth() : 80;
        auto fixed = prefix.walkLength + suffix.length + 1;
        auto room = w > fixed ? w - fixed : 0;
        auto flat = sanitizeLine(thinkText.split.join(" "));
        auto count = flat.walkLength;
        auto tail = count > room ? "…" ~ flat.drop(count - room + 1).to!string : flat;
        return color ? "\r\x1b[2K\x1b[38;5;245m" ~ prefix ~ "\x1b[2m" ~ tail ~ suffix ~ "\x1b[0m"
            : "\r\x1b[2K" ~ prefix ~ tail ~ suffix;
    }

    private void thinkingDelta(string chunk)
    {
        import std.string : stripLeft;
        if (!thinking)
        {
            if (midLine) { write("\n"); midLine = false; }
            thinking = true;
            thinkText = null;
            thinkStart = nowMs();
            lastDraw = long.min / 2;
            blockExpanded = verbose || atomicLoad(gThinkingExpanded);
            if (blockExpanded) write(thinkStyle("∴ Thinking ") ~ dim("(ctrl+o to collapse)") ~ "\n");
        }
        bool first = !thinkText.length;
        thinkText ~= chunk;
        if (blockExpanded)
        {
            auto t = first ? chunk.stripLeft : chunk;
            write(thinkStyle(t));
            if (t.length) midLine = t[$ - 1] != '\n';
        }
        else if (tty && nowMs() - lastDraw >= 50)
        {
            lastDraw = nowMs();
            write(collapsedLine());
            midLine = true;
        }
        stdout.flush();
    }

    private void finishThinking()
    {
        import std.string : strip;
        import std.range : walkLength;
        if (!thinking) return;
        thinking = false;
        if (blockExpanded)
        {
            if (midLine) write("\n");
        }
        else
        {
            auto secs = (nowMs() - thinkStart) / 1000.0;
            auto chars = thinkText.strip.walkLength;
            auto clear = tty ? "\r\x1b[2K" : "";
            write(clear ~ thinkStyle(format("∴ Thought for %.1fs", secs)) ~ dim(format(" · %s chars (ctrl+o to expand)", chars))
                ~ "\n");
        }
        midLine = false;
        auto t = thinkText.strip;
        if (t.length) lastThinking = sanitizeBlock(t);
        stdout.flush();
    }

    /// Ctrl-O. Mid-block it switches the live view; between turns it prints a
    /// note (with the last thinking when expanding). Returns whether it printed.
    bool toggleThinking(bool inTurn)
    {
        synchronized (this)
        {
            bool expanded = !atomicLoad(gThinkingExpanded);
            atomicStore(gThinkingExpanded, expanded);
            if (thinking)
            {
                blockExpanded = expanded;
                if (expanded)
                    write((tty ? "\r\x1b[2K" : "\n") ~ thinkStyle("∴ Thinking ") ~ dim("(ctrl+o to collapse)") ~ "\n"
                        ~ thinkStyle(sanitizeBlock(std.string.stripLeft(thinkText))));
                else
                {
                    write("\n" ~ collapsedLine());
                }
                midLine = true;
                stdout.flush();
                return false;
            }
            if (inTurn) return false;
            string note = !expanded ? dim("thinking will be collapsed") ~ "\n"
                : !lastThinking.length ? dim("thinking will be shown in full (no thinking yet)") ~ "\n"
                : thinkStyle("∴ Last thinking ") ~ dim("(shown in full from now on; ctrl+o to collapse)") ~ "\n"
                    ~ thinkStyle(lastThinking) ~ "\n";
            write("\r\x1b[2K" ~ note);
            stdout.flush();
            return true;
        }
    }

    string dim(string s) { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }
    string bold(string s) { return color ? "\x1b[1m" ~ s ~ "\x1b[0m" : s; }
    string red(string s) { return color ? "\x1b[31m" ~ s ~ "\x1b[0m" : s; }

    void text(bool reasoning, string chunk)
    {
        synchronized (this)
        {
            if (reasoning)
            {
                streamedThinking = true;
                thinkingDelta(chunk);
                return;
            }
            if (!chunk.length) return;
            finishThinking();
            write(chunk);
            midLine = chunk[$ - 1] != '\n';
            stdout.flush();
        }
    }

    /// A line of its own, mid-stream or not (the live thinking line redraws below it).
    void note(string text)
    {
        synchronized (this)
        {
            if (midLine) write("\n");
            midLine = false;
            writeln(text);
            stdout.flush();
        }
    }

    void endLine()
    {
        synchronized (this)
        {
            finishThinking();
            if (midLine) writeln();
            midLine = false;
            inReasoning = false;
        }
    }

    /// plan_add/plan_update show as the checklist, not as calls.
    private bool quiet(const ref ToolCall call) { return !verbose && (call.name == "plan_add" || call.name == "plan_update"); }

    void toolStart(const ref ToolCall call)
    {
        if (quiet(call)) return;
        endLine();
        writeln(bold("● " ~ call.name), " ", dim(summary(call)));
        stdout.flush();
    }

    /// Runs on the agent's thread after each model call and tool (refreshes the live view).
    void delegate() afterStep;

    void toolEnd(const ref ToolCall call, string result, bool isError)
    {
        scope (exit) if (afterStep !is null) afterStep();
        if (quiet(call) && !isError) return;
        auto lines = result.lineCount;
        if (isError) writeln("  ", red("✗ " ~ result.firstLine));
        else if (verbose) writeln(dim(indent(result)));
        else writeln(dim(format("  ⎿ %s", lines > 1 ? format("%s lines", lines) : result.firstLine)));
        stdout.flush();
    }

    void usage(TokenUsage u)
    {
        if (afterStep !is null) afterStep();
    }
    void userMessage(string text) { endLine(); writeln(dim("↪ " ~ text)); }
    void assistantMessage(string text, string reasoning)
    {
        synchronized (this)
        {
            // Reasoning that didn't stream shows now, like a block that just ended.
            if (!streamedThinking && reasoning.length && !thinking) thinkingDelta(reasoning);
            finishThinking();
            streamedThinking = false;
        }
    }

    static string summary(const ref ToolCall c)
    {
        if (c.invalidArguments.length) return "(invalid arguments)";
        foreach (k; ["command", "path", "pattern", "text", "name", "id"])
            if (auto v = k in c.arguments)
                if (v.type == JSONType.string)
                {
                    auto s = v.str.firstLine;
                    return s.length > 120 ? s[0 .. 120] ~ "…" : s;
                }
        return c.encodedArguments;
    }
}

/// Untrusted multi-line text for the terminal: lines kept, every other
/// control character (so any escape sequence) dropped, tabs expanded.
string sanitizeBlock(string s)
{
    import nano.trajectory : sanitizeTerminal;
    import std.algorithm : map;
    import std.array : join, split;
    return s.split('\n').map!sanitizeTerminal.join("\n");
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

alias planNote = planPromptNote;

string buildSystemPrompt(const ref Config c, string cwd, bool plan, const Skills skills = null, string memoryIndex = null,
    string instructions = null)
{
    import std.datetime.systime : Clock;
    auto base = c.systemPrompt.length ? c.systemPrompt : "You are a helpful assistant with access to tools.";
    version (OSX) enum os = "macOS";
    else version (linux) enum os = "Linux";
    else enum os = "unknown";
    auto s = format("%s\n\nWorking directory: %s\nPlatform: %s\nToday's date: %s", base, cwd, os,
            Clock.currTime.toISOExtString[0 .. 10]);
    s ~= instructions;
    if (skills !is null) s ~= skills.renderIndex;
    s ~= memoryIndex;
    if (plan) s ~= planNote;
    return s;
}

/// Warnings for the current model's temperature and thinking settings.
string[] settingWarnings(Agent agent)
{
    string[] w;
    auto t = agent.temperatureNow;
    if (t.warning.length) w ~= t.warning;
    auto th = agent.thinking();
    if (th.warning.length) w ~= th.warning;
    return w;
}

/// The instruction files for `dir`, or null when disabled (config
/// `project_instructions`, env `AGENTIC_NO_PROJECT_INSTRUCTIONS`).
ProjectInstructions discoverInstructions(const ref Config c, string dir)
{
    import std.process : environment;
    if (!c.projectInstructions || environment.get("AGENTIC_NO_PROJECT_INSTRUCTIONS") !is null) return null;
    InstructionOptions o;
    o.names = c.projectInstructionFiles.dup;
    foreach (f; c.userInstructionFiles) o.userFiles ~= expandHome(f);
    foreach (d; c.userRulesDirs) o.userRulesDirs ~= expandHome(d);
    o.importsOutsideProject = c.instructionImportsOutsideProject;
    return ProjectInstructions.discover(dir, o);
}

/// `/context`: window use, token totals, compaction settings.
string toolsListing(Agent agent)
{
    string[] out_;
    foreach (d; agent.tools.definitions) out_ ~= format("  %-14s %s", d.name, firstLine(d.description));
    return out_.join("\n");
}

string skillsListing(const Skills skills)
{
    if (skills is null || skills.empty) return "No skills found.";
    string[] out_;
    foreach (sk; skills.skills) out_ ~= format("  %-20s %s", sk.name, firstLine(sk.description));
    return out_.join("\n");
}

string sessionText(Agent agent)
{
    return agent.log is null ? "not recording (--no-session)" : format("session %s\nlog: %s", agent.log.id, agent.log.path);
}

string planText(Agent agent)
{
    return agent.plan.empty ? "No plan yet. The agent makes one with the plan_add tool."
        : agent.plan.render(true, size_t.max).stripRight;
}

string modeListing(AgentMode current)
{
    string[] out_ = [format("Mode: %s (%s)", current.name, current.describe)];
    foreach (m; allModes) out_ ~= format("  %-8s %s", m.name, m.describe);
    return (out_ ~ "(Shift+Tab cycles; /mode NAME sets it directly)").join("\n");
}

string contextReport(Agent agent)
{
    import nano.context : formatTokens, modeName;
    import std.array : join;
    bool calibrated;
    auto tokens = agent.estimateContextTokens(calibrated);
    string source;
    auto window = agent.contextWindow(source);
    string[] out_;
    out_ ~= format("Model:        %s/%s", agent.client.providerName, agent.client.modelName);
    out_ ~= format("Context:      %s%s of %s tokens (%.1f%%)%s", calibrated ? "" : "~", tokens, window,
        window ? tokens * 100.0 / window : 0.0, calibrated ? ", anchored to reported usage" : ", estimated");
    out_ ~= format("Window:       %s (%s)", formatTokens(window), source);
    out_ ~= format("Messages:     %s", agent.messages.length);
    out_ ~= "Temperature:  " ~ agent.temperatureNow.describe;
    out_ ~= "Thinking:     " ~ agent.thinking().describe;
    auto vision = agent.vision;
    out_ ~= "Vision:       " ~ (vision.isNull ? "no" : format("yes (up to %s image(s), %s bytes each)", vision.get.maxImages, vision.get.maxImageBytes));
    if (agent.instructions is null || !agent.instructions.loadedPaths.length)
        out_ ~= "Instructions: none (no AGENTS.md, CLAUDE.md or .github/copilot-instructions.md found)";
    else out_ ~= "Instructions: " ~ agent.instructions.loadedPaths.join(", ");
    if (agent.instructions !is null && agent.instructions.onDemandPaths.length)
        out_ ~= "On-demand rules: " ~ agent.instructions.onDemandPaths.join(", ");
    out_ ~= format("Session:      %s input, %s output tokens", agent.sessionInputTokens, agent.sessionOutputTokens);
    out_ ~= agent.autoCompact
        ? format("Auto-compact: at %.0f%% (~%s tokens); compacted %s time(s)", agent.autoCompactThreshold * 100,
            cast(size_t)(window * agent.autoCompactThreshold), agent.compactions)
        : "Auto-compact: off";
    out_ ~= format("Compaction:   %s mode (/compact --smart or --standard overrides once)", modeName(agent.compactionMode));
    return out_.join("\n");
}

/// The agent, for `main`'s exit (title requests may still be in flight).
__gshared Agent mainAgent;

int main(string[] args)
{
    auto rc = runMain(args);
    import core.time : dur;
    if (mainAgent !is null && !mainAgent.settleTitles(dur!"seconds"(3)))
    {
        // A title request is still running: druntime teardown would race the
        // thread, so leave without it (Rust likewise drops pending tasks).
        import core.sys.posix.unistd : _exit;
        stdout.flush();
        stderr.flush();
        _exit(rc);
    }
    return rc;
}

int runMain(string[] args)
{
    auto o = parseArgs(args);
    auto cfgPath = o.configPath.length ? o.configPath : Config.defaultPath;
    Config cfg;
    JSONValue rawConfig = JSONValue(string[string].init);
    if (o.login.length) return runLogin(o.login);
    try
    {
        cfg = Config.load(cfgPath);
        if (cfgPath.exists) rawConfig = parseToml(readText(cfgPath));
    }
    catch (Exception e) die(e.msg);

    if (o.trajectory !is null) return printTrajectory(o.trajectory, o.json, o.markdown);
    if (o.listSessions) return printSessions(o.all, o.json);
    if (o.hasResume && (o.resume == "" || o.resume == "last"))
    {
        import nano.resume : pickOutcome, Pick, printList, resumeLast = last;
        try
        {
            if (o.resume == "last") o.resume = resumeLast(sessionDir, getcwd());
            else if (o.acp) die("--resume needs a session ID with --acp");
            else if (isTerminal(0) && isTerminal(2))
            {
                string id;
                if (pickOutcome(sessionDir, getcwd(), null, id) != Pick.selected) return 0;
                o.resume = id;
            }
            else
            {
                // No terminal to pick in: list what could be resumed.
                printList(sessionDir, getcwd(), false, false);
                return 0;
            }
        }
        catch (Exception e) die(e.msg);
    }
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
    size_t configuredWindow;
    try
    {
        auto rp = resolve(cfg, spec);
        configuredWindow = rp.config.contextWindow > 0 ? cast(size_t) rp.config.contextWindow : 0;
        client = makeClient(rp);
    }
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
    {
        import nano.sandbox : parseMode;
        auto env = environment.get("NANO_CODER_SANDBOX");
        try
        {
            if (env.length) cfg.sandbox.mode = parseMode(env);
        }
        catch (Exception e) die("NANO_CODER_SANDBOX: " ~ e.msg);
        try
        {
            if (o.sandbox.length) cfg.sandbox.mode = parseMode(o.sandbox);
        }
        catch (Exception e) die(e.msg);
    }
    policy.sandbox = cfg.sandbox;

    auto tools = new ToolRegistry;
    auto readState = new ReadState;
    auto bashTimeout = cfg.bashTimeoutSecs;
    tools.register(bashDefinition(bashTimeout), (JSONValue a) => bashExecute(a, bashTimeout, cfg.sandbox));
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
    // Memory: read-only when no human vets saves live (ACP, -p, piped stdio) and in plan mode.
    MemoryStore memory;
    bool memoryWritable = cfg.memory == MemoryMode.on && !o.acp && !o.prompt.length && isTerminal(0) && isTerminal(1);
    if (cfg.memory != MemoryMode.off)
    {
        auto dir = cfg.memoryDir.length ? cfg.memoryDir : memoryDefaultDir();
        if (dir.length) memory = new MemoryStore(dir, projectKey(cwd), cfg.memoryExpiryDays < 0 ? 0 : cfg.memoryExpiryDays);
    }
    if (memory !is null)
    {
        // A helper, not a foreach-body delegate: D closures share the loop variable.
        ToolHandler memoryHandler(string name)
        {
            return (JSONValue a) {
                bool ro = !memoryWritable || agent.control.mode == AgentMode.plan;
                try return runMemory(memory, name, a, agent.log !is null ? agent.log.id : null, ro);
                catch (Exception e) throw new ToolError(e.msg);
            };
        }
        foreach (d; memoryDefinitions(memoryWritable)) tools.register(d, memoryHandler(d.name));
    }
    // Instruction files, discovered once per working directory.
    ProjectInstructions instructions;
    string instructionsDir;
    string systemFor(string dir, bool plan)
    {
        auto index = memory !is null ? memory.index(memoryWritable && !plan) : null;
        if (instructionsDir is null || instructionsDir != dir)
        {
            instructionsDir = dir;
            instructions = discoverInstructions(cfg, dir);
            if (agent !is null) agent.instructions = instructions;
        }
        return buildSystemPrompt(cfg, dir, plan, skills, index, instructions !is null ? instructions.render : null);
    }
    auto questions = new QuestionBroker;
    tools.register(questionDefinition, (JSONValue a) => questions.run(a));
    agent = new Agent(client, tools, policy, systemFor(cwd, o.plan));
    mainAgent = agent;
    agent.instructions = instructions;
    agent.sessionTitles = cfg.sessionTitles;
    agent.titleModel = cfg.titleModel;
    agent.titleClient = (string spec) => makeClient(resolve(cfg, spec));
    if (instructions !is null && !o.acp && !o.prompt.length)
    {
        foreach (f; instructions.loadedPaths) stderr.writeln("Instructions: ", f);
        foreach (w; instructions.warnings) stderr.writeln("Instructions warning: ", w);
    }
    agent.planTools = cfg.planTools;
    agent.outcomeTool = cfg.outcomeTool;
    agent.remindersEnabled = cfg.reminders;
    agent.questions = questions;
    if (o.plan) agent.control.mode = AgentMode.plan;
    HookManager loadHooks(string dir)
    {
        import nano.claude_hooks : LoadOptions;
        LoadOptions lo;
        lo.disableHooks = cfg.disableHooks || o.noHooks;
        lo.disableProjectHooks = cfg.disableProjectHooks;
        lo.claudeUserHooks = cfg.claudeUserHooks;
        lo.nanoHooks = cfg.hooks;
        lo.sandbox = cfg.sandbox;
        auto m = HookManager.load(lo, dir);
        if (auto notice = m.startupNotice) stderr.writeln(notice);
        foreach (sk; m.skipped)
            if (!sk.source.isProject)
                stderr.writefln("hooks: skipped %s (%s): %s", listingField(sk.eventName), sk.source.label, listingField(sk.reason));
        return m;
    }
    agent.maxIterations = cfg.maxIterations;
    agent.maxTokens = cfg.maxTokens;
    agent.configuredWindow = configuredWindow;
    agent.autoCompact = cfg.autoCompact;
    agent.autoCompactThreshold = cfg.autoCompactThreshold;
    {
        import nano.context : parseCompactionMode;
        if (!parseCompactionMode(cfg.compactionMode, agent.compactionMode))
            die(`compaction_mode must be "standard" or "smart", got "` ~ cfg.compactionMode ~ `"`);
    }
    bool compactingByHand;
    agent.onCompacted = (ref const CompactReport r) {
        // Manual compactions are reported by /compact itself.
        if (!compactingByHand) stderr.writeln("[agent] auto-", r.toString);
    };
    agent.temperature = cfg.temperature;
    agent.globalThinking = cfg.thinking;
    agent.globalVision = cfg.vision;
    agent.markRead = (string p, const(ubyte)[] b) { readState.record(p, b); };
    agent.providerLookup = (string name) => name in cfg.providers;
    agent.refreshCapabilities();
    // A configured temperature or thinking level that is adjusted or ignored.
    if (!o.acp && !o.prompt.length) foreach (w; settingWarnings(agent)) stderr.writeln("Warning: ", w);

    if (o.acp)
    {
        import nano.acp : AcpServer, Host;
        Host host;
        bool plan = o.plan;
        host.systemPrompt = (string dir) {
            if (dir != cwd) skills = discoverSkills(dir);
            return systemFor(dir, plan);
        };
        host.makeClient = (string s) => makeClient(resolve(cfg, s));
        host.sessionDir = o.noSession ? null : sessionDir;
        host.version_ = versionString;
        host.loadHooks = &loadHooks;
        auto server = new AcpServer(agent, host);
        if (!server.serveStdio())
        {
            stderr.writeln("nano-coder-d: no ACP JSON-RPC request received on stdin");
            return 1;
        }
        return 0;
    }

    /// Load a saved session into the agent: its conversation, plan and log.
    void loadSession(string path)
    {
        auto restored = restore(path);
        agent.messages = agent.messages[0 .. 1];
        foreach (m; restored.conversation)
            if (m.role != Role.system) agent.messages ~= m;
        agent.log = o.noSession ? null : new SessionLog(path);
        agent.historyAvailable = restored.historyAvailable;
        agent.historyHintPending = restored.historyAvailable && !restored.historyHintConsumed;
        agent.plan = Plan.init;
        if (restored.plan.type == JSONType.object)
        {
            try agent.plan = Plan.fromJSON(restored.plan);
            catch (Exception e) stderr.writeln("nano-coder-d: ignoring the saved plan: ", e.msg);
        }
        stderr.writefln("resumed %s (%s messages)", restored.id, agent.messages.length - 1);
        if (restored.pendingInput.length)
            stderr.writefln("the last prompt never finished (the session was interrupted): %s",
                oneLine(restored.pendingInput));
    }

    try
    {
        if (o.hasResume) loadSession(findSession(sessionDir, o.resume, cwd));
        else if (!o.noSession)
        {
            agent.log = new SessionLog(sessionDir, spec, cwd);
            foreach (m; agent.messages) agent.log.append(m);
        }
    }
    catch (Exception e) die(e.msg);
    agent.useHooks(loadHooks(cwd), o.hasResume);

    auto console = new Console(isTerminal(1) && environment.get("NO_COLOR") is null, o.verbose, isTerminal(1));
    agent.onPlanChanged = () {
        console.endLine();
        write(checklist(agent.plan, (isTerminal(1) ? terminalWidth() : 80) - 4, console.color));
        stdout.flush();
    };

    gControl = agent.control;
    {
        import core.sys.posix.signal : sigaction, sigaction_t, SIGINT, sigemptyset;
        sigaction_t sa;
        sa.sa_handler = &onInterrupt;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGINT, &sa, null);
    }
    Inbox inbox;
    LineEditor editor;
    string[] held; // lines to run before reading the prompt again
    auto queue = new MessageQueue; // Ctrl-Enter messages: one runs per following turn

    /// Switch the model (history carries over); the "Model set to" text.
    string switchModel(string spec)
    {
        auto rp = resolve(cfg, spec);
        client = makeClient(rp);
        agent.client = client;
        agent.configuredWindow = rp.config.contextWindow > 0 ? cast(size_t) rp.config.contextWindow : 0;
        agent.learnedWindow = 0;
        agent.learnedMaxOutput = 0;
        agent.refreshCapabilities();
        auto text = format("Model set to %s (provider %s)", client.modelName, client.providerName);
        foreach (w; settingWarnings(agent)) text ~= "\nWarning: " ~ w;
        return text;
    }
    agent.onModelRequest = (string spec) {
        try console.note(switchModel(spec));
        catch (Exception e) console.note(console.red(format("[/model %s: %s]", spec, e.msg)));
    };

    // Read-only commands typed mid-turn show this, rendered on the agent thread.
    auto view = new LiveView;
    void refreshView()
    {
        view.set("/tools", toolsListing(agent));
        view.set("/skills", skillsListing(skills));
        view.set("/session", sessionText(agent));
        view.set("/plan", planText(agent));
        view.set("/context", contextReport(agent));
        view.set("log", agent.log is null ? null : agent.log.path);
    }
    console.afterStep = &refreshView;

    /// A `/command` typed during a turn: its output if it runs now, else null (held).
    string midTurn(string text)
    {
        static import nano.trajectory;
        auto p = splitCmd(text);
        auto name = p[0], arg = p[1];
        final switch (timing(text))
        {
            case Timing.afterTurn:
                return null;
            case Timing.immediate:
                switch (name)
                {
                    case "/help": return helpText().stripRight;
                    case "/mode": return modeListing(agent.control.mode);
                    case "/trajectory":
                        auto path = view.get("log");
                        if (path is null) return "Session persistence is disabled: no trajectory to show";
                        try
                        {
                            auto t = nano.trajectory.load(path);
                            return arg == "--json" ? t.toJson : arg.length ? t.toMarkdown : t.toPlain;
                        }
                        catch (Exception e) return "Could not read the session log: " ~ e.msg;
                    default: return view.get(name);
                }
            case Timing.nextStep:
                if (name == "/mode")
                {
                    try
                    {
                        auto m = parseMode(arg);
                        agent.control.mode = m;
                        return format("Mode set to %s (%s); applies from the agent's next step", m.name, m.describe);
                    }
                    catch (Exception e) return e.msg;
                }
                if (name == "/model")
                {
                    // Validate now so a bad spec is reported at once and never queued.
                    try resolve(cfg, arg);
                    catch (Exception e) return format("[%s: %s]", text, e.msg);
                    agent.control.requestModel(arg);
                    return format("Model switch to %s queued; applies at the next model call (the history carries over)", arg);
                }
                return null;
        }
    }

    // The system prompt's plan section follows the mode; Shift-Tab mid-turn
    // only switches the live mode, so the prompt catches up at the next turn.
    bool sysPlan = o.plan;
    void syncMode()
    {
        bool plan = agent.control.mode == AgentMode.plan;
        if (plan == sysPlan) return;
        agent.messages[0].content = systemFor(cwd, plan);
        sysPlan = plan;
    }

    bool turn(string input)
    {
        syncMode();
        atomicStore(gTurnRunning, true);
        scope (exit) atomicStore(gTurnRunning, false);
        bool ok = true;
        // With the line editor, keys typed during the turn steer it (a
        // `/command` waits for the turn to end); Ctrl-C or Esc Esc cancels.
        shared bool turnDone;
        Thread keys;
        if (editor !is null)
        {
            if (o.verbose)
                stderr.writeln(console.dim("[running: Enter sends a message to steer the agent, Ctrl-Enter queues it for later "
                    ~ "(/queue lists, edits, removes), Esc Esc or Ctrl-C to cancel]"));
            refreshView();
            keys = new Thread(() => turnKeys(editor, console, &turnDone, held, questions, queue, &midTurn));
            keys.start();
        }
        scope (exit)
            if (keys !is null)
            {
                atomicStore(turnDone, true);
                keys.join();
            }
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
        if (editor !is null) foreach_reverse (t; late) held = t.text ~ held;
        return ok;
    }

    if (o.prompt.length) return turn(o.prompt) ? 0 : 1;

    bool interactive = isTerminal(0);
    if (interactive && isTerminal(1) && environment.get("TERM", "") != "dumb"
        && environment.get("NANO_CODER_PLAIN_INPUT") is null && enterKeyMode(0))
    {
        editor = new LineEditor(fdSource(0), (string s) => writeFd(1, s), () => terminalWidth());
        editor.onAction = (K k) @trusted {
            bool inTurn = atomicLoad(gTurnRunning);
            if (k == K.toggleThinking)
            {
                console.toggleThinking(inTurn);
                return;
            }
            AgentMode m = nextMode(agent.control.mode());
            agent.control.mode = m;
            if (inTurn) console.note(console.dim(format("[mode: %s — %s]", m.name, m.describe)));
            else
            {
                syncMode();
                console.note(format("Mode: %s (%s)", m.name, m.describe));
            }
        };
        questions.interactive = true;
    }
    scope (exit) leaveKeyMode();
    if (interactive && editor is null)
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
        string line;
        QueuedMessage next;
        if (held.length)
        {
            line = held[0];
            held = held[1 .. $];
        }
        else if (queue.pop(next))
        {
            writeln(console.dim(format("↧ queued #%s: %s", next.id, next.text.strip)));
            line = next.text;
        }
        else if (editor !is null)
        {
            write("\n");
            stdout.flush();
            auto r = editor.readLine("› ", console.bold("› "));
            if (r.outcome == Outcome.eof) break;
            if (r.outcome != Outcome.line) continue;
            line = r.text;
            if (auto lit = unescapePrompt(line)) line = "\x00" ~ lit; // `//…`: a prompt starting with /
        }
        else
        {
            if (interactive) { write(console.bold("\n› ")); stdout.flush(); }
            line = inbox !is null ? inbox.take() : readln();
        }
        if (line is null) break;
        bool literal = line.startsWith("\x00");
        if (literal) line = line[1 .. $];
        auto input = line.strip;
        if (!input.length) continue;
        if (!literal && input.startsWith("/"))
        {
            auto sp = input.indexOf(' ');
            auto cmd = sp > 0 ? input[0 .. sp] : input;
            auto arg = sp > 0 ? input[sp + 1 .. $].strip : "";
            switch (cmd)
            {
                case "/quit", "/exit": return 0;
                case "/help": writeln(editor !is null ? helpText() : usage); continue;
                case "/clear":
                    agent.messages = agent.messages[0 .. 1];
                    if (agent.log !is null) agent.log.replace(agent.messages);
                    if (!agent.plan.empty) agent.setPlan(Plan.init, false);
                    agent.historyAvailable = agent.historyHintPending = false;
                    writeln("conversation cleared");
                    continue;
                case "/compact":
                {
                    import nano.commands : parseCompactArgs;
                    import nano.context : CompactionMode;
                    CompactionMode mode;
                    string focus;
                    bool hasMode = parseCompactArgs(arg, mode, focus);
                    writeln("Compacting...");
                    CompactReport rep;
                    compactingByHand = true;
                    scope (exit) compactingByHand = false;
                    agent.control.startTurn();
                    bool done;
                    try done = agent.compact(rep, CompactTrigger.manual, hasMode ? &mode : null, focus);
                    catch (Exception e) { stderr.writeln(console.red("error: " ~ e.msg)); continue; }
                    writeln(done ? "Conversation " ~ rep.toString : "Nothing to compact");
                    continue;
                }
                case "/thinking":
                    import nano.thinking : statusText, setSession;
                    if (arg.length)
                    {
                        try setSession(agent.sessionThinking, arg);
                        catch (Exception e) { writeln(e.msg); continue; }
                        auto r = agent.thinking();
                        writeln("Thinking set to ", r.describe);
                        if (r.warning.length) writeln("Warning: ", r.warning);
                    }
                    else
                    {
                        auto r = agent.thinking();
                        writeln(statusText(r, client.modelName));
                    }
                    continue;
                case "/context":
                    writeln(contextReport(agent));
                    continue;
                case "/usage":
                    writefln("last request: %s input (%s cached), %s output tokens", agent.lastUsage.inputTokens,
                            agent.lastUsage.cachedInputTokens, agent.lastUsage.outputTokens);
                    continue;
                case "/queue":
                    writeln(runQueueCommand(queue, arg));
                    continue;
                case "/plan":
                    writeln(planText(agent));
                    continue;
                case "/mode":
                    if (!arg.length)
                    {
                        writeln(modeListing(agent.control.mode));
                        continue;
                    }
                    try
                    {
                        auto m = parseMode(arg);
                        agent.control.mode = m;
                        syncMode();
                        writefln("Mode set to %s (%s)", m.name, m.describe);
                    }
                    catch (Exception e) writeln(e.msg);
                    continue;
                case "/tools":
                    writeln(toolsListing(agent));
                    continue;
                case "/skills":
                    writeln(skillsListing(skills));
                    continue;
                case "/resume":
                {
                    import nano.resume : pickOutcome, Pick, listRows, resumeLast = last;
                    import std.array : join;
                    if (o.noSession) { writeln("Sessions aren't saved (--no-session), so there is nothing to resume"); continue; }
                    auto current = agent.log !is null ? agent.log.id : null;
                    string id = arg;
                    try
                    {
                        if (!arg.length && !(isTerminal(0) && isTerminal(2)))
                        {
                            auto rows = listRows(sessionDir, cwd, current);
                            writeln(rows.length ? "Saved sessions (switch with /resume ID):\n" ~ rows.join("\n")
                                : "No saved sessions for this directory");
                            continue;
                        }
                        if (!arg.length)
                        {
                            final switch (pickOutcome(sessionDir, cwd, current, id))
                            {
                                case Pick.selected: break;
                                case Pick.empty: continue;
                                case Pick.cancelled: writeln("Session unchanged"); continue;
                            }
                        }
                        else if (arg == "last") id = resumeLast(sessionDir, cwd, current);
                    }
                    catch (Exception e) { writeln(e.msg); continue; }
                    if (id == current) { writefln("Already in session %s", id); continue; }
                    import std.path : buildPath;
                    import std.file : isFile;
                    auto path = buildPath(sessionDir, id ~ ".jsonl");
                    bool ok;
                    try { validateId(id); ok = path.exists && path.isFile; }
                    catch (Exception) {}
                    if (!ok) { writefln("No saved session %s: /resume without an ID lists them", JSONValue(id).toString); continue; }
                    try loadSession(path);
                    catch (Exception e) { writeln(e.msg); continue; }
                    writefln("Resumed session %s (resume later with --resume %s)", id, id);
                    continue;
                }
                case "/trajectory":
                {
                    static import nano.trajectory;
                    if (agent.log is null) { writeln("Session persistence is disabled: no trajectory to show"); continue; }
                    if (arg.length && arg != "--json" && arg != "--markdown" && arg != "--md")
                    {
                        writefln("Unknown option %s; use /trajectory [--json|--markdown]", JSONValue(arg).toString);
                        continue;
                    }
                    nano.trajectory.Trajectory t;
                    try t = nano.trajectory.load(agent.log.path);
                    catch (Exception e) { writeln("Could not read the session log: ", e.msg); continue; }
                    if (arg == "--json") writeln(t.toJson);
                    else if (arg.length) writeln(t.toMarkdown);
                    else showTrajectory(t);
                    continue;
                }
                case "/session":
                    writeln(sessionText(agent));
                    continue;
                case "/hooks":
                    write(agent.hooks !is null ? agent.hooks.listing : "No hooks loaded.\n");
                    continue;
                case "/memory":
                    if (memory is null) { writeln("memory is off"); continue; }
                    try
                    {
                        if (arg.startsWith("forget "))
                        {
                            writeln(memory.forget(arg[7 .. $]));
                            continue;
                        }
                        auto all = memory.all();
                        if (!all.length) writeln("no memories saved");
                        foreach (x; all)
                        {
                            import nano.memory : scopeName = name;
                            writefln("%-7s %s %s%s", scopeName(x.s), x.e.label, x.e.text,
                                x.e.evidence !is null ? " (check: " ~ x.e.evidence ~ ")" : "");
                        }
                        writefln("store: %s (remove one with /memory forget <id>)", memory.root);
                    }
                    catch (Exception e) stderr.writeln(console.red("error: " ~ e.msg));
                    continue;
                case "/model":
                    if (!arg.length) { writeln(client.providerName, "/", client.modelName); continue; }
                    try writeln(switchModel(arg));
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
