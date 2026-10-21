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
import nano.lineedit : LineEditor, Outcome, K, enterKeyMode, leaveKeyMode, fdSource, writeFd, terminalWidth, terminalHeight;
import nano.frameui : FrameUi;
import nano.settings_dialog : SettingsUi, SettingsHost, runSettings, pickModel, onVerbosity;
import nano.commands : helpText, unescapePrompt;
import core.thread : Thread;
import nano.claude_hooks : HookManager, listingField, label, isProject;
import nano.skills : Skills, skillsDefinition = definition;
import nano.memory : MemoryStore = Store, MemoryMode, memoryDefinitions = definitions, runMemory = run, memoryDefaultDir = defaultDir, projectKey, Scope;
import nano.control : TurnControl, FdLineReader;
import nano.instructions : ProjectInstructions, InstructionOptions = Options, expandHome;
import core.atomic : atomicLoad, atomicStore, cas;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

enum string packageVersion = "0.1.0";
enum string versionString = "nano-coder-d " ~ packageVersion ~ " (D port of nano-coder; see PORTING.md)";

enum string usage = `Usage: nano-coder-d [--model provider/model] [--config PATH] [-p PROMPT]
                    [--resume [SESSION_ID|last]] [--plan] [--sandbox off|workspace|read-only]
                    [--allow RULE]... [--deny RULE]...
                    [--no-session] [--no-hooks] [--verbosity quiet|normal|verbose|debug] [--acp]
       nano-coder-d --list-sessions [--all] [--json]
       nano-coder-d --trajectory SESSION_ID [--json|--markdown]
       nano-coder-d --list-models PROVIDER[/model]
       nano-coder-d --login github-copilot|muse
       nano-coder-d --version

Reads the Rust nano-coder's config (~/.config/nano-coder/config.toml).
-p runs one prompt and exits; with no -p, prompts are read from stdin (a REPL on a terminal).
--acp serves the Agent Client Protocol (JSON-RPC 2.0, one message per line) on stdin/stdout.
REPL commands: /help lists them (/model, /mode, /verbosity, /providers, /restart, /resume, ...)
Ctrl-C cancels a running turn; a line typed during a turn steers it.`;

struct Options
{
    string model, configPath, prompt, resume, listModels, sandbox, login, trajectory, verbosity;
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
            case "--verbose", "-v": o.verbosity = "verbose"; break;
            case "--verbosity": o.verbosity = value(); break;
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
    if (pageable)
    {
        if (gFrame !is null) gFrame.suspend();
        scope (exit) if (gFrame !is null) gFrame.resume();
        if (nano.trajectory.page(text)) return;
    }
    writeln(text);
}

noreturn die(string msg)
{
    stderr.writeln("nano-coder-d: ", msg);
    exit(2);
}

bool isTerminal(int fd)
{
    import core.sys.posix.unistd : isatty;
    import nano.lineedit : ttyOut;
    if (fd == 1 || fd == 2) if (gFrame !is null) fd = ttyOut;
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

// The output detail level (ui.rs's global verbosity), read live by Console.
import nano.ui : Verbosity, parseVerbosity, verbosityListing, providersListing;

/// The `/settings` prompts on the line editor.
final class EditorUi : SettingsUi
{
    private LineEditor e;
    this(LineEditor e) { this.e = e; }

    ptrdiff_t select(string prompt, const string[] labels, size_t initial)
    {
        return e.select(prompt, labels, initial);
    }

    string input(string prompt, string initial) { return value(prompt, initial, false); }
    string secret(string prompt) { return value(prompt, "", true); }
    void say(string line) @trusted { writeln(line); stdout.flush(); }

    private string value(string prompt, string initial, bool masked) @trusted
    {
        auto p = prompt ~ ": ";
        auto r = e.readValue(p, "\x1b[1m" ~ p ~ "\x1b[0m", initial, masked);
        if (r.outcome != Outcome.line) return null;
        return r.text;
    }
}
static import nano.ui;
shared Verbosity gVerbosity = Verbosity.normal;

// Rust's `timestamps` (on by default): a dim "HH:MM:SS " before the prompt and
// each transcript block; continuation lines are padded to align under it.
shared bool gTimestamps = true;

/// The visible width of a non-empty stamp ("HH:MM:SS ").
enum size_t stampWidth = 9;

string stamp(bool color) @trusted
{
    import std.datetime.systime : Clock;
    if (!atomicLoad(gTimestamps)) return "";
    auto t = Clock.currTime;
    auto s = format("%02d:%02d:%02d", t.hour, t.minute, t.second);
    return color ? "\x1b[2m" ~ s ~ "\x1b[0m " : s ~ " ";
}

/// `text` with `stamp` before the first line and its width in spaces before the rest.
string stampBlock(string stamp, string text)
{
    import std.array : replace;
    if (!stamp.length) return text;
    auto pad = spaces(stampWidth);
    auto body = text.length && text[$ - 1] == '\n' ? text[0 .. $ - 1] : text;
    return stamp ~ body.replace("\n", "\n" ~ pad) ~ (body.length < text.length ? "\n" : "");
}

private string spaces(size_t n) { import std.array : replicate; return " ".replicate(n); }
Verbosity verbosity() @trusted { return atomicLoad(gVerbosity); }
void setVerbosity(Verbosity v) @trusted { atomicStore(gVerbosity, v); }

// The pinned status line (status.rs), when installed, and what it shows.
import nano.status : StatusLine, Stats, Activity, RateMeter, tildePath;
__gshared StatusLine gStatus;
/// The frame renderer, when `renderer = "frame"` drives the terminal.
__gshared FrameUi gFrame;

/// The status bar text for the frame's last line.
string frameStatus(size_t width) @trusted
{
    import nano.status : renderStatus = render;
    if (environment.get("AGENTIC_NO_STATUS") !is null) return "";
    synchronized (gStatsLock) return renderStatus(gStats, width);
}
__gshared Stats gStats;
__gshared Object gStatsLock;
shared bool gResized;
shared static this() { gStatsLock = new Object; }

/// Change the status line's stats and redraw it (no-op without one).
void updateStatus(scope void delegate(ref Stats) @safe f) @trusted
{
    if (gStatus is null && gFrame is null) return;
    synchronized (gStatsLock) f(gStats);
    if (gStatus !is null) gStatus.draw();
    if (gFrame !is null) gFrame.redraw();
}

/// The agent's side of the status line: model, context, plan, mode, tokens.
void statusFromAgent(ref Stats s, Agent agent, string cwdShown) @trusted
{
    import nano.thinking : wireValue;
    import nano.context : CompactionMode;
    s.provider = agent.client.providerName;
    s.model = agent.client.modelName;
    s.cwd = cwdShown;
    bool calibrated;
    s.tokens = agent.estimateContextTokens(calibrated);
    s.calibrated = calibrated;
    string source;
    s.window = agent.contextWindow(source);
    s.messages = agent.messages.length;
    auto progress = agent.plan.progress;
    s.hasPlan = progress[1] > 0;
    s.planDone = progress[0];
    s.planTotal = progress[1];
    s.mode = agent.control.mode;
    auto th = agent.thinking();
    auto w = wireValue(th);
    s.thinking = w.isNull ? null : w.str;
    s.sessionInputTokens = agent.sessionInputTokens;
    s.sessionOutputTokens = agent.sessionOutputTokens;
    s.autoCompact = agent.autoCompact;
    s.threshold = agent.autoCompactThreshold;
    s.smartCompact = agent.compactionMode == CompactionMode.smart;
    s.compactions = agent.compactions;
}

class Console : AgentEvents
{
    bool color, tty;
    private bool inReasoning, midLine;
    /// Tool output previews and expanded thinking (verbosity verbose or debug).
    bool verbose() const { return verbosity >= Verbosity.verbose; }
    /// Quiet shows only final answers: the last assistant text of the turn
    /// is kept for the end, as are whether answer deltas were dropped (a turn
    /// that turns louder mid-answer reprints the whole answer).
    bool quiet() const { return verbosity == Verbosity.quiet; }
    string finalAnswer;
    bool droppedAnswer;
    // The reasoning block being shown (as in Rust's legacy renderer): a live
    // one-line view redrawn in place, then "∴ Thought for Ns · N chars", or
    // the full text when expanded (Ctrl-O or --verbose).
    private bool thinking, blockExpanded, streamedThinking;
    private string thinkText, lastThinking;
    private long thinkStart, lastDraw;
    // The thinking block's stamp, and whether an answer segment is streaming
    // (its first line got a stamp, so later lines are padded under it).
    private string blockStamp;
    private bool answering;

    string stamp() { return .stamp(color); }

    /// Writes `t` with every line that starts here indented by `pad`.
    private void writeAligned(string t, size_t pad)
    {
        import std.algorithm : splitter;
        import std.array : replicate;
        if (!pad) { write(t); if (t.length) midLine = t[$ - 1] != '\n'; return; }
        size_t i;
        while (i < t.length)
        {
            auto nl = t[i .. $].indexOf('\n');
            auto seg = nl >= 0 ? t[i .. i + nl + 1] : t[i .. $];
            if (!midLine) write(" ".replicate(pad));
            write(seg);
            midLine = seg[$ - 1] != '\n';
            i += seg.length;
        }
    }

    this(bool color, bool tty = false)
    {
        this.color = color;
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
        auto fixed = prefix.walkLength + suffix.length + 1 + (blockStamp.length ? stampWidth : 0);
        auto room = w > fixed ? w - fixed : 0;
        auto flat = sanitizeLine(thinkText.split.join(" "));
        auto count = flat.walkLength;
        auto tail = count > room ? "…" ~ flat.drop(count - room + 1).to!string : flat;
        return color ? "\r\x1b[2K" ~ blockStamp ~ "\x1b[38;5;245m" ~ prefix ~ "\x1b[2m" ~ tail ~ suffix ~ "\x1b[0m"
            : "\r\x1b[2K" ~ blockStamp ~ prefix ~ tail ~ suffix;
    }

    private void thinkingDelta(string chunk)
    {
        import std.string : stripLeft;
        if (!thinking)
        {
            if (midLine) { write("\n"); midLine = false; }
            thinking = true;
            answering = false;
            blockStamp = stamp();
            thinkText = null;
            thinkStart = nowMs();
            lastDraw = long.min / 2;
            blockExpanded = verbose || atomicLoad(gThinkingExpanded);
            if (blockExpanded) write(blockStamp ~ thinkStyle("∴ Thinking ") ~ dim("(ctrl+o to collapse)") ~ "\n");
        }
        bool first = !thinkText.length;
        thinkText ~= chunk;
        if (blockExpanded)
        {
            auto t = first ? chunk.stripLeft : chunk;
            if (t.length) writeAligned(thinkStyle(t), blockStamp.length ? stampWidth : 0);
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
            write(clear ~ blockStamp ~ thinkStyle(format("∴ Thought for %.1fs", secs)) ~ dim(format(" · %s chars (ctrl+o to expand)", chars))
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
                {
                    write((tty ? "\r\x1b[2K" : "\n") ~ blockStamp ~ thinkStyle("∴ Thinking ") ~ dim("(ctrl+o to collapse)") ~ "\n");
                    midLine = false;
                    writeAligned(thinkStyle(sanitizeBlock(std.string.stripLeft(thinkText))), blockStamp.length ? stampWidth : 0);
                }
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

    private RateMeter meter;

    void text(bool reasoning, string chunk)
    {
        if (gStatus !is null || gFrame !is null)
        {
            auto rate = meter.record(chunk.length, nowMs);
            if (rate > 0) updateStatus((ref Stats s) { if (s.activity == Activity.thinking) s.tokensPerSec = rate; });
        }
        if (quiet)
        {
            if (!reasoning && chunk.length) droppedAnswer = true;
            return;
        }
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
            if (!answering)
            {
                if (midLine) write("\n");
                midLine = false;
                auto st = stamp();
                write(st);
                midLine = st.length > 0;
                answering = true;
            }
            writeAligned(chunk, atomicLoad(gTimestamps) ? stampWidth : 0);
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
            answering = false;
            writeln(stampBlock(stamp(), text));
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
            answering = false;
            inReasoning = false;
        }
    }

    /// plan_add/plan_update show as the checklist, not as calls.
    private bool quietTool(const ref ToolCall call) { return !verbose && (call.name == "plan_add" || call.name == "plan_update"); }

    void toolStart(const ref ToolCall call)
    {
        string name = call.name;
        updateStatus((ref Stats s) {
            s.activity = Activity.tool;
            s.tool = name;
            s.tokensPerSec = 0;
            if (name == "history_search") s.historySearches++;
            if (name == "history_read") s.historyReads++;
        });
        meter.reset();
        if (quiet || quietTool(call)) return;
        endLine();
        writeln(stamp(), color ? "\x1b[38;5;114m●\x1b[0m " : "● ", bold(call.name), " ", dim(summary(call)));
        stdout.flush();
    }

    /// Runs on the agent's thread after each model call and tool (refreshes the live view).
    void delegate() afterStep;

    void toolEnd(const ref ToolCall call, string result, bool isError)
    {
        scope (exit) if (afterStep !is null) afterStep();
        updateStatus((ref Stats s) { s.activity = Activity.thinking; });
        if (quiet || (quietTool(call) && !isError)) return;
        auto st = stamp();
        auto w = (isTerminal(1) ? terminalWidth() : 80);
        write(stampBlock(st, toolResult(!isError, sanitizeBlock(result), verbose, w > 8 + st.length ? w - 8 - (st.length ? stampWidth : 0) : 1)));
        stdout.flush();
    }

    void usage(TokenUsage u)
    {
        if (afterStep !is null) afterStep();
    }
    void userMessage(string text)
    {
        if (quiet) return;
        endLine();
        writeln(stampBlock(stamp(), dim("↪ " ~ text)));
    }
    void assistantMessage(string text, string reasoning)
    {
        finalAnswer = text;
        if (quiet) return;
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

/// A tool result as Rust's `tool_result`: `⎿ first line (+N lines)` (red
/// `⎿ error:` for failures); verbose shows up to ten lines.
string toolResult(bool ok, string output, bool verbose, size_t width, bool color = true)
{
    import std.algorithm : min;
    import std.array : split;
    import std.string : stripRight;
    enum previewLines = 10;
    auto lines = output.stripRight.split('\n');
    if (output.stripRight.length == 0) lines = null;
    string mark = ok ? "⎿" : "⎿ error:";
    string on = !color ? "" : ok ? "\x1b[2m" : "\x1b[38;5;203m", off = color ? "\x1b[0m" : "";
    if (!lines.length) return format("  %s%s (no output)%s\n", on, mark, off);
    if (verbose)
    {
        string text;
        foreach (i, l; lines[0 .. min($, previewLines)])
            text ~= format("  %s%s %s%s\n", on, i == 0 ? mark : " ", fitText(l.stripRight("\r"), width), off);
        if (lines.length > previewLines)
            text ~= format("  %s  … +%s lines%s\n", color ? "\x1b[2m" : "", lines.length - previewLines, off);
        return text;
    }
    auto more = lines.length > 1 ? format(" (+%s lines)", lines.length - 1) : "";
    return format("  %s%s %s%s%s\n", on, mark, fitText(lines[0].stripRight("\r"), width > more.length ? width - more.length : 0), more, off);
}

/// `text` cut to `width` characters, ending in `…` when cut.
string fitText(string text, size_t width)
{
    import std.range : walkLength, take;
    import std.conv : to;
    if (text.walkLength <= width) return text;
    return (width ? text.take(width - 1).to!string : "") ~ "…";
}

unittest
{
    assert(toolResult(true, "a\nb\nc\n", false, 80, false) == "  ⎿ a (+2 lines)\n");
    assert(toolResult(false, "boom", false, 80, false) == "  ⎿ error: boom\n");
    assert(toolResult(true, "", false, 80, false) == "  ⎿ (no output)\n");
    assert(toolResult(true, "abcdef", false, 4, false) == "  ⎿ abc…\n");
    assert(toolResult(true, "x\ny", true, 80, false) == "  ⎿ x\n    y\n");
}

/// The configured context window: top-level `context_window`, else the provider's.
size_t windowFor(const ref Config c, const ref ProviderConfig p)
{
    return c.contextWindow > 0 ? cast(size_t) c.contextWindow : p.contextWindow > 0 ? cast(size_t) p.contextWindow : 0;
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

/// Redraw the status line after the terminal is resized (SIGWINCH sets a
/// flag; a daemon thread redraws, as signal handlers can't write safely).
void watchResize() @trusted
{
    import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset;
    enum SIGWINCH = 28; // macOS and Linux
    import core.thread : Thread;
    import core.time : msecs;
    extern (C) static void onWinch(int) nothrow @nogc { atomicStore(gResized, true); }
    static bool watching;
    if (watching) return;
    watching = true;
    sigaction_t sa;
    sa.sa_handler = &onWinch;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGWINCH, &sa, null);
    auto t = new Thread({
        for (;;)
        {
            Thread.sleep(100.msecs);
            if (cas(&gResized, true, false) && gStatus !is null) gStatus.draw();
        }
    });
    t.isDaemon = true;
    t.start();
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
        configuredWindow = windowFor(cfg, rp.config);
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

    auto console = new Console(isTerminal(1) && environment.get("NO_COLOR") is null, isTerminal(1));
    setVerbosity(cfg.verbosity);
    atomicStore(gTimestamps, cfg.timestamps);
    if (o.verbosity.length)
    {
        try setVerbosity(parseVerbosity(o.verbosity));
        catch (Exception e) die(e.msg);
    }
    agent.onPlanChanged = () {
        if (console.quiet) return;
        console.endLine();
        auto st = console.stamp();
        write(stampBlock(st, checklist(agent.plan, (isTerminal(1) ? terminalWidth() : 80) - 4 - (st.length ? stampWidth : 0),
            console.color)));
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

    // Recently used models lead the `/model` type-ahead (recents.rs).
    static import nano.recents;
    import nano.commands : Suggestion, modelSuggestionSource;
    auto recentsPath = nano.recents.defaultPath();
    auto recents = nano.recents.load(recentsPath);
    if (recents.canonicalize(cfg.providers, cfg.defaultProvider)) nano.recents.save(recentsPath, recents);
    string currentSpec() { return nano.recents.canonical(client.providerName ~ "/" ~ client.modelName, cfg.providers, cfg.defaultProvider); }
    modelSuggestionSource = () @trusted {
        import std.algorithm : canFind, sort;
        Suggestion[] out_;
        void push(string value, string note)
        {
            if (value.length && !out_.canFind!(x => x.value == value)) out_ ~= Suggestion(value, note);
        }
        push(currentSpec(), "current");
        synchronized foreach (r; recents.models) push(r, "recent");
        bool configured(string n) { return cfg.userProviders.canFind(n) || n == cfg.defaultProvider; }
        auto names = cfg.providers.keys.dup;
        names.sort!((a, b) => configured(a) != configured(b) ? configured(a) : a < b);
        string kindOf(string n)
        {
            auto p = cfg.providers[n];
            if (!p.hasKind) return "provider";
            final switch (p.kind)
            {
                case ProviderKind.openai: return "openai";
                case ProviderKind.anthropic: return "anthropic";
                case ProviderKind.githubCopilot: return "githubcopilot";
                case ProviderKind.muse: return "muse";
                case ProviderKind.mock: return "mock";
            }
        }
        string providerNote(string n)
        {
            auto m = cfg.providers[n].defaultModel;
            return kindOf(n) ~ (m.length ? " -> " ~ m : "") ~ (n == cfg.defaultProvider ? ", default provider" : "");
        }
        foreach (n; names)
            if (auto m = cfg.providers[n].defaultModel)
                push(n ~ "/" ~ m, n == cfg.defaultProvider ? "default provider" : providerNote(n));
        foreach (n; names) push(n, providerNote(n));
        return out_;
    };

    /// Switch the model (history carries over); the "Model set to" text.
    string switchModel(string spec)
    {
        auto previous = currentSpec();
        auto rp = resolve(cfg, spec);
        client = makeClient(rp);
        agent.client = client;
        agent.configuredWindow = windowFor(cfg, rp.config);
        agent.learnedWindow = 0;
        agent.learnedMaxOutput = 0;
        agent.refreshCapabilities();
        synchronized
        {
            recents.record(previous);
            recents.record(nano.recents.canonical(spec, cfg.providers, cfg.defaultProvider));
            nano.recents.save(recentsPath, recents);
        }
        auto text = format("Model set to %s (provider %s)", client.modelName, client.providerName);
        foreach (w; settingWarnings(agent)) text ~= "\nWarning: " ~ w;
        return text;
    }
    agent.onModelRequest = (string spec) {
        try console.note(switchModel(spec));
        catch (Exception e) console.note(console.red(format("[/model %s: %s]", spec, e.msg)));
    };

    // The status line's agent stats (cwd shown with ~ for home).
    string cwdShown = tildePath(cwd, environment.get("HOME", ""));
    void refreshStatus()
    {
        updateStatus((ref Stats s) { statusFromAgent(s, agent, cwdShown); });
    }

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
        refreshStatus();
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
                    case "/verbosity": return verbosityListing(verbosity);
                    case "/providers": return providersListing(cfg.providers, cfg.defaultProvider);
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
                if (name == "/verbosity")
                {
                    try
                    {
                        auto v = parseVerbosity(arg);
                        setVerbosity(v);
                        return format("Verbosity set to %s (%s); /settings saves it", nano.ui.name(v), nano.ui.describe(v));
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

    SettingsHost settingsHost()
    {
        SettingsHost h;
        h.cfg = &cfg;
        h.agent = agent;
        h.configPath = cfgPath;
        h.recents = () @trusted => recents.models;
        h.switchModel = (string spec) @trusted {
            try { switchModel(spec); return cast(string) null; }
            catch (Exception e) return e.msg;
        };
        h.listModels = (string name) @trusted => makeClient(resolve(cfg, name)).listModels();
        h.refreshSystem = () @trusted { agent.messages[0].content = systemFor(cwd, sysPlan); };
        h.refreshClient = (string name) @trusted {
            if (agent.client.providerName != name) return cast(string) null;
            try { switchModel(name ~ "/" ~ agent.client.modelName); return cast(string) null; }
            catch (Exception e) return e.msg;
        };
        onVerbosity = (Verbosity v) @trusted { setVerbosity(v); };
        return h;
    }

    bool turn(string input)
    {
        syncMode();
        atomicStore(gTurnRunning, true);
        scope (exit) atomicStore(gTurnRunning, false);
        updateStatus((ref Stats s) { s.activity = Activity.thinking; s.tokensPerSec = 0; });
        scope (exit)
        {
            refreshStatus();
            updateStatus((ref Stats s) { s.activity = Activity.idle; s.tokensPerSec = 0; });
        }
        bool ok = true;
        // With the line editor, keys typed during the turn steer it (a
        // `/command` waits for the turn to end); Ctrl-C or Esc Esc cancels.
        shared bool turnDone;
        Thread keys;
        if (editor !is null)
        {
            if (verbosity >= Verbosity.verbose)
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
        console.finalAnswer = null;
        console.droppedAnswer = false;
        try agent.run(input, console);
        catch (Exception e)
        {
            console.endLine();
            stderr.writeln(console.red("error: " ~ e.msg));
            ok = false;
        }
        console.endLine();
        // Quiet shows only the final answer; a turn that got louder after
        // answer deltas were dropped reprints the whole answer (ui.rs).
        if ((console.quiet || console.droppedAnswer) && console.finalAnswer.length)
        {
            writeln(console.finalAnswer);
            stdout.flush();
        }
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
        editor = new LineEditor(fdSource(0), (string s) @trusted {
            import std.algorithm.searching : canFind;
            // The editor's erase-to-end-of-screen wipes the status row too.
            writeFd(1, gStatus !is null && s.canFind("\x1b[J") ? s ~ gStatus.sequence() : s);
        }, () => terminalWidth());
        editor.rows = () => terminalHeight();
        editor.onAction = (K k) @trusted {
            bool inTurn = atomicLoad(gTurnRunning);
            if (k == K.toggleThinking)
            {
                console.toggleThinking(inTurn);
                return;
            }
            AgentMode m = nextMode(agent.control.mode());
            agent.control.mode = m;
            updateStatus((ref Stats s) { s.mode = m; });
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
    // Legacy: a status line pinned under a scroll region. Frame: the app
    // owns the screen and re-renders it (`renderer`).
    void useRenderer(string mode)
    {
        if (editor is null) return;
        if (mode == "frame" && gFrame is null)
        {
            if (gStatus !is null) { gStatus.teardown(); gStatus = null; }
            gFrame = FrameUi.install((size_t w) @trusted => frameStatus(w));
            if (gFrame is null) return;
            editor.frameDraw = (string[] rows) @trusted { gFrame.draw(rows); };
            editor.frameCommit = (string line) @trusted { gFrame.commit(line); };
            refreshStatus();
        }
        else if (mode == "legacy" && gFrame !is null)
        {
            auto lines = gFrame.uninstall();
            gFrame = null;
            editor.frameDraw = null;
            editor.frameCommit = null;
            // The frame's redraws cleared the scrollback: replay its transcript.
            write("\x1b[H\x1b[2J\x1b[3J");
            foreach (l; lines) writeln(l);
            stdout.flush();
            gStatus = StatusLine.install(() @trusted { synchronized (gStatsLock) return gStats; });
            if (gStatus !is null) { refreshStatus(); watchResize(); }
        }
        else if (mode == "legacy" && gStatus is null)
        {
            gStatus = StatusLine.install(() @trusted { synchronized (gStatsLock) return gStats; });
            if (gStatus !is null) { refreshStatus(); watchResize(); }
        }
    }
    useRenderer(cfg.renderer);
    scope (exit) if (gStatus !is null) gStatus.teardown();
    scope (exit) if (gFrame !is null) { gFrame.uninstall(); gFrame = null; }
    if (interactive && editor is null)
    {
        import core.thread : Thread;
        inbox = new Inbox;
        auto reader = new Thread(() => inbox.readLoop(console));
        reader.isDaemon = true;
        reader.start();
    }
    if (interactive)
    {
        // The startup banner, as Rust's (one stamped block).
        import std.algorithm : map;
        import std.array : join;
        string[] banner = [
            "nano-coder-d v" ~ packageVersion,
            format("Model: %s (provider: %s)", client.modelName, client.providerName),
        ];
        if (agent.log !is null) banner ~= format("Session: %s (resume with --resume %s)", agent.log.id, agent.log.id);
        if (instructions !is null)
        {
            foreach (f; instructions.loadedPaths) banner ~= "Instructions: " ~ f;
            foreach (w; instructions.warnings) banner ~= "Instructions warning: " ~ w;
        }
        if (skills !is null && skills.names.length) banner ~= "Skills: " ~ skills.names.join(", ");
        if (skills !is null) foreach (w; skills.warnings) banner ~= "Skills warning: " ~ w;
        banner ~= "Type /help for commands";
        writeln(stampBlock(console.stamp(), banner.join("\n")));
    }
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
            refreshStatus();
            write("\n");
            stdout.flush();
            // The prompt's stamp is redrawn with the submission time (Rust's restamp).
            editor.restyle = () @trusted => console.stamp() ~ console.bold("› ");
            auto r = editor.readLine(.stamp(false) ~ "› ", console.stamp() ~ console.bold("› "));
            editor.restyle = null;
            if (r.outcome == Outcome.eof) break;
            if (r.outcome != Outcome.line) continue;
            line = r.text;
            if (auto lit = unescapePrompt(line)) line = "\x00" ~ lit; // `//…`: a prompt starting with /
        }
        else
        {
            if (interactive) { write("\n" ~ console.stamp() ~ console.bold("› ")); stdout.flush(); }
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
                case "/restart":
                {
                    // A brand-new session in place: new ID, just the system
                    // prompt, default mode, empty plan, counters zeroed. The
                    // previous log stays on disk and is still resumable.
                    import nano.session : newSessionId;
                    SessionLog log;
                    try
                    {
                        if (!o.noSession)
                            log = new SessionLog(sessionDir, agent.client.providerName ~ "/" ~ agent.client.modelName, cwd);
                    }
                    catch (Exception e) { writeln(console.red("error: " ~ e.msg)); continue; }
                    agent.restart(systemFor(cwd, false), log);
                    sysPlan = false;
                    agent.useHooks(loadHooks(cwd), false);
                    if (gFrame !is null) gFrame.clear();
                    else if (gStatus !is null) gStatus.clear();
                    else if (editor !is null) { write("\x1b[H\x1b[2J\x1b[3J"); stdout.flush(); }
                    refreshStatus();
                    if (log !is null) writefln("Session: %s (resume with --resume %s)", log.id, log.id);
                    else writefln("Session: %s", newSessionId());
                    continue;
                }
                case "/providers":
                    writeln(providersListing(cfg.providers, cfg.defaultProvider));
                    continue;
                case "/verbosity":
                    if (!arg.length) writeln(verbosityListing(verbosity));
                    else
                    {
                        try
                        {
                            auto v = parseVerbosity(arg);
                            setVerbosity(v);
                            writefln("Verbosity set to %s (%s); /settings saves it", nano.ui.name(v), nano.ui.describe(v));
                        }
                        catch (Exception e) writeln(e.msg);
                    }
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
                case "/settings":
                    if (editor is null) { writeln("/settings needs an interactive terminal"); continue; }
                    {
                        auto h = settingsHost();
                        foreach (n; runSettings(new EditorUi(editor), h)) writeln(n);
                        useRenderer(cfg.renderer);
                    }
                    refreshStatus();
                    continue;
                case "/model":
                    if (!arg.length && editor !is null)
                    {
                        auto h = settingsHost();
                        if (auto picked = pickModel(new EditorUi(editor), h))
                        {
                            try writeln(switchModel(picked));
                            catch (Exception e) stderr.writeln(console.red("error: " ~ e.msg));
                        }
                        continue;
                    }
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
