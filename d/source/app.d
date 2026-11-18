/// nano-coder-d command line: a plain line-based REPL, one-shot `-p`, and the
/// flags of the Rust CLI that this port implements.
module app;

@safe:
import nano.arith : saturatingSub;
import nano.option : Option, some, none, match, ifSome, unwrap, notNull, NotNull, nullable;

import nano.safeio : Chan, Isolated, Join, JoinHandle, Locked, Shared, deepCopy, spawn, spawnDaemon, exitProcess, stdErr, stdinLine, stdOut;

import std.stdio;
import std.json;
import std.format : format;
import std.string : strip, stripRight, startsWith, indexOf;
import nano.turn_commands : LiveView, splitCmd, timing, Timing;
import nano.markdown : MarkdownStream, renderMarkdownText = render;
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
static import nano.herdr;
import nano.frame : glyphMark, foldMark, expandedBody, expandedResult;
import core.time : MonoTime, seconds;
import std.sumtype : match;
import nano.question : QuestionBroker, Question, Answer, Answered, Away, Dismissed, sanitizeLine, questionDefinition = definition;
import nano.lineedit : LineEditor, Outcome, K, ParkedDraft, enterKeyMode, leaveKeyMode, fdSource, writeFd, terminalWidth, terminalHeight;
import nano.frameui : FrameUi;
import nano.settings_dialog : SettingsUi, SettingsHost, runSettings, pickModel, onVerbosity;
import nano.commands : helpText, isCommand, unescapePrompt;
import core.thread : Thread;
import nano.claude_hooks : HookManager, listingField, label, isProject;
import nano.skills : Skills, skillsDefinition = definition;
import nano.memory : MemoryStore = Store, MemoryMode, memorySessionTools = sessionTools, memoryDefaultDir = defaultDir, projectKey, Scope;
import nano.control : TurnControl, FdLineReader;
import nano.instructions : ProjectInstructions, InstructionOptions = Options, expandHome;
import core.atomic : atomicLoad, atomicStore, cas;

enum string packageVersion = "0.1.0";
enum string versionString = "nano-coder-d " ~ packageVersion ~ " (D port of nano-coder; see PORTING.md)";

enum string usage = `Usage: nano-coder-d [--model provider/model] [--config PATH] [-p PROMPT]
                    [--resume [SESSION_ID|last]] [--plan] [--sandbox off|workspace|read-only]
                    [--allow RULE]... [--deny RULE]...
                    [--no-session] [--no-hooks] [--yolo] [--wait-timers] [--verbosity quiet|normal|verbose|debug] [--acp]
       nano-coder-d --list-sessions [--all] [--json]
       nano-coder-d --trajectory SESSION_ID [--json|--markdown]
       nano-coder-d --list-models PROVIDER[/model]
       nano-coder-d --login github-copilot|muse
       nano-coder-d --version

Reads the Rust nano-coder's config (~/.config/nano-coder/config.toml).
-p runs one prompt and exits (--wait-timers: first wait for the timers the agent set,
running each as it fires); with no -p, prompts are read from stdin (a REPL on a terminal).
--acp serves the Agent Client Protocol (JSON-RPC 2.0, one message per line) on stdin/stdOut.
REPL commands: /help lists them (/model, /mode, /verbosity, /providers, /restart, /resume, ...)
Ctrl-C cancels a running turn; a line typed during a turn steers it.
A repository's own skills and .claude/settings*.json hooks load only once you trust it: an
interactive start asks "Trust this repo?" and remembers a yes; -p and piped runs skip them.
--yolo trusts the repository without asking (as --acp does).`;

struct Options
{
    string model, configPath, prompt, resume, listModels, sandbox, login, trajectory, verbosity;
    bool waitTimers, yolo, markdown, plan, noSession, noHooks, verbose, hasResume, acp, listSessions, all, json;
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
            case "--wait-timers": o.waitTimers = true; break;
            case "--no-hooks": o.noHooks = true; break;
            case "--yolo": o.yolo = true; break;
            case "--verbose", "-v": o.verbosity = "verbose"; break;
            case "--verbosity": o.verbosity = value(); break;
            case "--resume":
                o.hasResume = true;
                if (eq > 0) o.resume = value();
                else if (i + 1 < args.length && !args[i + 1].startsWith("-")) o.resume = args[++i];
                else o.resume = "";
                break;
            case "--version", "-V": writeln(versionString); exitProcess(0);
            case "--help", "-h": writeln(usage); exitProcess(0);
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
    void delegate(string) @safe note = toDelegate((string s) { stdErr.writeln(s); });
    void delegate(long) @safe sleep = toDelegate((long n) { Thread.sleep(n.seconds); });
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
int printSessions(string sessionDir, bool all, bool json)
{
    import nano.resume : printList;
    try printList(sessionDir, getcwd(), all, json);
    catch (Exception e) die(e.msg);
    return 0;
}

/// `--trajectory ID [--json|--markdown]`: a saved session's turn-by-turn ledger.
int printTrajectory(string sessionDir, string id, bool json, bool markdown)
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
/// doesn't fit on one screen. In a session (`inSession`), page it whatever the
/// length: printed, the ledger would stay in the transcript and the terminal
/// scrollback, while the pager is a view dismissed with `q`.
void showTrajectory(const ref imported!"nano.trajectory".Trajectory t, bool inSession = false)
{
    static import nano.trajectory;
    auto text = t.toPlain;
    auto size = nano.trajectory.terminalSize(1);
    bool pageable = isTerminal(0) && isTerminal(1)
        && (inSession || (size[0] && nano.trajectory.needsPager(text, size[0], size[1])));
    if (pageable)
    {
        if (gFrame) gFrame.suspend();
        scope (exit) if (gFrame) gFrame.resume();
        if (nano.trajectory.page(text)) return;
    }
    writeln(text);
}

noreturn die(string msg)
{
    stdErr.writeln("nano-coder-d: ", msg);
    exitProcess(2);
}

bool isTerminal(int fd)
{
    import core.sys.posix.unistd : isatty;
    import nano.lineedit : ttyOut;
    // `ttyOut` is set by the main thread when the frame renderer starts.
    if (fd == 1 || fd == 2) if (gFrame) fd = ttyOut;
    return isatty(fd) != 0;
}

/// Renders agent events on the terminal.
// Ctrl-C handling: cancel the running turn, or exit when idle.
/// The running agent's controls, for the key reader and the SIGINT handler.
@nullable("null until the agent is built; the SIGINT handler checks") shared TurnControl gControl_;
shared(TurnControl) gControl() nothrow @nogc { return atomicLoad(gControl_); }
void gControl(shared TurnControl c) nothrow @nogc { atomicStore(gControl_, c); }
shared bool gTurnRunning;

/// Route SIGINT to `onInterrupt`.
void installSigint()
{
    import core.sys.posix.signal : SIGINT;
    import nano.safeio : onSignal;
    onSignal(SIGINT, &onInterrupt);
}

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

/// Piped stdin (no line editor): read lines on a thread. Text typed during a
/// turn steers it; everything else (and `/commands`) goes to `inbox` for the
/// main loop. `color` styles the notes. Runs via `spawn`: it reaches only
/// its arguments and `shared` globals.
void readStdinLines(Chan!string inbox, bool color)
{
    string dim(string s) { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }
    // Not readln: see FdLineReader (a blocked readln deadlocks spawnProcess).
    auto input = FdLineReader(0);
    for (;;)
    {
        auto line = input.next();
        if (line is null) { inbox.close(); return; }
        auto text = line.strip;
        if (atomicLoad(gTurnRunning) && text.length
            && (!text.startsWith("/") || (!isCommand(text) && unescapePrompt(text) is null)))
        {
            gControl.steer(text);
            stdErr.writeln(dim("↪ steer: " ~ text ~ " (read at the agent's next step)"));
        }
        else
        {
            if (atomicLoad(gTurnRunning) && text.length)
                stdErr.writeln(dim("[waits for the turn to finish: " ~ text ~ "]"));
            inbox.put(text);
        }
    }
}

/// The next line from `inbox`, or null at end of input.
string takeLine(Chan!string inbox)
{
    string l;
    return inbox.take(l) ? l : null;
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

/// Run a `/queue` edit and say what happened. `steers`: the running turn's
/// controls, so unread steers are listed and editable (null between turns).
string runQueueCommand(MessageQueue queue, shared TurnControl steers, string args)
{
    try return queueApply(queue, atomicLoad(steers), queueParse(args));
    catch (QueueUsage e) return "[" ~ e.msg ~ "]";
}

/// What a `/command` typed mid-turn may use on the key thread: the shared
/// turn controls, the live view, and a frozen copy of the config.
struct MidTurn
{
    NotNull!(shared TurnControl) control;
    LiveView view;
    /// One element (a slice keeps `MidTurn` assignable).
    immutable(Config)[] cfg;
}

/// A `/command` typed during a turn: its output if it runs now, else null (held).
string midTurnCommand(string text, MidTurn ctx)
{
    auto control = atomicLoad(ctx.control);
    auto view = ctx.view;
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
                case "/version": return versionString;
                case "/mode": return modeListing(control.mode);
                case "/verbosity": return verbosityListing(verbosity);
                case "/providers": return providersListing(ctx.cfg[0].providers, ctx.cfg[0].defaultProvider);
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
                    control.mode = m;
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
            if (name == "/thinking")
            {
                import std.typecons : Nullable;
                import nano.thinking : Thinking, setSession;
                Nullable!Thinking check;
                try setSession(check, arg);
                catch (Exception e) return format("[thinking: %s]", e.msg);
                control.requestThinking(arg);
                auto shown = check.isNull ? "the config level" : check.get.toString;
                return format("[thinking: %s — from the agent's next step]", shown);
            }
            if (name == "/model")
            {
                // Validate now so a bad spec is reported at once and never queued.
                try resolve(ctx.cfg[0], arg);
                catch (Exception e) return format("[%s: %s]", text, e.msg);
                control.requestModel(arg);
                return format("Model switch to %s queued; applies at the next model call (the history carries over)", arg);
            }
            return null;
    }
}


/// The turn's key reader (its own thread): owns the line editor until
/// `*done`, then hands it back. Lines that wait for the turn go to `held`.
/// The idle-compaction hold: `idle_compact_hold_secs`, or the default.
imported!"core.time".Duration idleCompactHoldFor(const ref Config cfg) @safe
{
    import core.time : seconds;
    import nano.lineedit : idleCompactHold;
    return cfg.idleCompactHoldSecs > 0 ? cfg.idleCompactHoldSecs.seconds : idleCompactHold;
}

/// Whether the idle prompt runs a due idle compaction now: quiet for the
/// hold, no queued Ctrl-C, no armed exit window (Rust `deliver_idle_compact`).
bool deliverIdleCompact(bool due, imported!"core.time".Duration quietFor, imported!"core.time".Duration hold,
    bool interruptQueued, bool exitArmed) @safe pure nothrow @nogc
{
    return due && quietFor >= hold && !interruptQueued && !exitArmed;
}

// rust: main.rs::deliver_idle_compact_waits_for_a_quiet_prompt
@safe unittest
{
    import core.time : seconds;
    auto hold = 180.seconds, quiet = hold, fresh = 5.seconds;
    assert(deliverIdleCompact(true, quiet, hold, false, false), "due and quiet for the hold: compact");
    assert(!deliverIdleCompact(true, fresh, hold, false, false), "a fresh draft or keystroke holds it");
    assert(!deliverIdleCompact(false, quiet, hold, false, false), "not due (off, under threshold, spent)");
    assert(!deliverIdleCompact(true, quiet, hold, true, false), "a queued Ctrl-C wins");
    assert(!deliverIdleCompact(true, quiet, hold, false, true), "an armed exit window holds it");
}

// rust: main.rs::idle_compact_hold_defaults_to_the_named_constant
@safe unittest
{
    import nano.lineedit : idleCompactHold;
    Config c;
    assert(c.idleCompact, "on by default");
    assert(idleCompactHoldFor(c) == idleCompactHold);
    c.idleCompactHoldSecs = 7;
    import core.time : seconds;
    assert(idleCompactHoldFor(c) == 7.seconds);
}

Isolated!LineEditor turnKeys(Isolated!LineEditor owned, ConsoleLink console, shared(bool)* done, Chan!string held,
    QuestionBroker questions, MessageQueue queue, MidTurn mid)
{
    auto editor = owned.unwrap;
    readTurnKeys(editor, console, done, held, questions, queue, mid);
    // Isolated: this thread got the editor isolated and kept no other reference.
    return Isolated!LineEditor.assumeIsolated(editor);
}

private void readTurnKeys(LineEditor editor, ConsoleLink console, shared(bool)* done, Chan!string held,
    QuestionBroker questions, MessageQueue queue, MidTurn mid)
{
    while (!atomicLoad(*done))
    {
        // The glyph placeholder becomes the busy spinner (nano.frame).
        auto r = editor.readLine("↪ ", .stamp(true) ~ glyphMark ~ " ", true,
            () => atomicLoad(*done) || questions.pending !is null);
        final switch (r.outcome)
        {
            case Outcome.stopped:
                if (auto qs = questions.pending)
                {
                    console.endLine();
                    nano.herdr.report(nano.herdr.State.blocked, qs.length ? sanitizeLine(qs[0].question) : null);
                    // The user's time at the picker isn't working time.
                    if (gFrame) gFrame.pauseWork(true);
                    bool delegate() @safe away = null;
                    if (mid.control.mode() == AgentMode.auto_)
                    {
                        // Auto mode: give the user a chance to answer, then
                        // answer for them (Rust's AUTO_AWAY_SECS).
                        console.note(format("[auto: answering for you in %ss — the user is away]", autoAwaySecs));
                        auto deadline = MonoTime.currTime + autoAwaySecs.seconds;
                        away = () @safe => MonoTime.currTime >= deadline;
                    }
                    auto answer = askQuestions(editor, qs, away);
                    if (answer.match!((Away _) => true, _ => false))
                        console.note("[auto: no answer — making the best decision]");
                    questions.resolve(answer);
                    if (gFrame) gFrame.pauseWork(false);
                    nano.herdr.report(nano.herdr.State.working);
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
                    stdErr.writeln(console.dim("[cancelling...]"));
                }
                break;
            case Outcome.line, Outcome.queue:
                auto text = r.text.strip;
                if (!text.length) break;
                if (auto qa = queueArgs(text))
                {
                    // `/queue` only touches the queue, so it runs at once.
                    stdErr.writeln(console.dim(runQueueCommand(queue, gControl, qa[0 .. $ - 1])));
                    break;
                }
                if (isCommand(text))
                {
                    // Read-only commands and settings run now (turn_commands.rs).
                    if (auto shown = midTurnCommand(text, mid))
                    {
                        console.note(shown);
                        break;
                    }
                    held.put(text);
                    stdErr.writeln(console.dim("[waits for the turn to finish: " ~ text ~ "]"));
                }
                else if (r.outcome == Outcome.queue)
                {
                    auto id = queue.push(text);
                    stdErr.writeln(console.dim(format("↧ queued #%s (%s waiting) — /queue remove %s to drop",
                        id, queue.length, id)));
                }
                else
                {
                    // `//…` steers with a message that starts with `/`.
                    if (auto unescaped = unescapePrompt(text)) text = unescaped;
                    auto id = queue.reserveId();
                    gControl.steerWithId(text, id);
                    // The frame shows the steer as a user message once the
                    // agent reads it, so the note needn't repeat the text.
                    stdErr.writeln(console.dim(format("↪ steer #%s: the agent reads this at its next step — "
                        ~ "/queue remove %s to withdraw", id, id)));
                }
                break;
        }
    }
}

/// `/update`: a fresh check, then the channel's installer attached to the
/// terminal (frame and key mode handed back while it runs).
void updateCommand(bool frameUi)
{
    import nano.update;
    if (!updateAllowed(isTerminal(0), frameUi || isTerminal(1), isCi()))
    {
        writeln("/update only runs in an interactive terminal outside CI; install the update with your package manager");
        return;
    }
    auto channel = channelFor(launchExe());
    if (channel == Channel.npm)
    {
        auto latest = new Checker(channel, defaultStatePath(), packageVersion).check(true);
        if (latest.length && !isNewer(latest, packageVersion))
        {
            writefln("nano-coder-d is up to date (%s)", latest);
            return;
        }
    }
    string[] lines;
    {
        stdOut.flush();
        if (gFrame) gFrame.suspend();
        leaveKeyMode();
        scope (exit) { enterKeyMode(0); if (gFrame) gFrame.resume(); }
        lines = runInstaller(channel, launchExe(), packageVersion, (string p, string[] a) @safe => spawnInstaller(p, a));
    }
    foreach (l; lines) writeln(l);
}

/// The interactive line editor. Built here, not in `runMain`, so its
/// callbacks can reach only what is passed in (sendable handles) and
/// globals: the editor moves to the turn's key reader thread.
LineEditor makeEditor(ConsoleLink console, shared TurnControl control)
{
    auto editor = new LineEditor(fdSource(0), (string[] rows) { gFrame.draw(rows); },
        (string line) { gFrame.commit(line); }, () => terminalWidth());
    editor.rows = () => terminalHeight();
    editor.onAction = (K k) {
        bool inTurn = atomicLoad(gTurnRunning);
        // The system prompt follows at the next turn (`syncMode`).
        AgentMode m = nextMode(control.mode());
        control.mode = m;
        updateStatus((ref Stats s) { s.mode = m; });
        if (inTurn) console.note(console.dim(format("[mode: %s — %s]", m.name, m.describe)));
        else console.note(format("Mode: %s (%s)", m.name, m.describe));
    };
    // Ctrl-O works at the prompt and mid-turn: the frame owns the folds.
    editor.onToggle = () { if (auto f = gFrame) f.toggleExpand(); };
    return editor;
}

/// A frozen copy of `cfg`, for another thread.
immutable(Config) frozenConfig(const ref Config cfg)
{
    // Isolated: a deep copy made just here.
    return Isolated!Config.assumeIsolated(deepCopy(cfg)).freeze;
}

/// How long auto mode waits for the user to answer a question.
enum autoAwaySecs = 15;

/// Ask each question with a picker; dismissing any one dismisses them all.
/// When `away` turns true before the user answers, the answer is `Away`.
Answer askQuestions(LineEditor editor, const Question[] qs, bool delegate() @safe away = null)
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
        import nano.question : questionPrompt;
        string[] body_;
        auto prompt = questionPrompt(q.question, terminalWidth(), body_);
        auto at = editor.select(prompt, labels, 0, away, body_);
        if (at == -2) return Answer(Away());
        if (at < 0) return Answer(Dismissed());
        if (at == custom)
        {
            auto r = editor.readLine("Answer: ", "\x1b[1mAnswer:\x1b[0m ", false, away);
            if (r.outcome == Outcome.stopped) return Answer(Away());
            if (r.outcome != Outcome.line) return Answer(Dismissed());
            answers ~= r.text;
        }
        else answers ~= q.options[at].label;
    }
    return Answer(Answered(answers.idup));
}

// The output detail level (ui.rs's global verbosity), read live by Console.
import nano.ui : Verbosity, parseVerbosity, verbosityListing, providersListing;

/// The `/settings` prompts on the line editor.
final class EditorUi : SettingsUi
{
    private NotNull!LineEditor e;
    this(LineEditor e) { this.e = e; }

    ptrdiff_t select(string prompt, const string[] labels, size_t initial)
    {
        return e.select(prompt, labels, initial);
    }

    string input(string prompt, string initial) { return value(prompt, initial, false); }
    string secret(string prompt) { return value(prompt, "", true); }
    void say(string line) { writeln(line); stdOut.flush(); }

    private string value(string prompt, string initial, bool masked)
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

string stamp(bool color)
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

// rust: ui.rs::stamps_the_first_line_and_aligns_the_rest
unittest
{
    assert(stampBlock("12:00:00 ", "● Plan\n  ☐ one\n") == "12:00:00 ● Plan\n           ☐ one\n");
    assert(stampBlock("", "x\n") == "x\n");
}

private string spaces(size_t n) { import std.array : replicate; return " ".replicate(n); }
Verbosity verbosity() { return atomicLoad(gVerbosity); }
void setVerbosity(Verbosity v) { atomicStore(gVerbosity, v); }

// What the frame's status bar shows (status.rs).
import nano.status : Stats, Activity, RateMeter, tildePath;
import nano.agent_status : statusFromAgent;
/// The frame renderer (`FrameUi.init` when off): set by the main thread,
/// used by any.
@nullable("set by the module constructor below") shared Locked!FrameUi gFrameCell;
shared static this() { gFrameCell = new shared Locked!FrameUi; }
/// The running frame renderer, or `FrameUi.init`.
FrameUi gFrame() { return atomicLoad(gFrameCell).get(); }
/// ditto
void gFrame(FrameUi f) { atomicLoad(gFrameCell).update((ref FrameUi v) { v = f; }); }

/// The status bar text for the frame's last line.
string frameStatus(size_t width)
{
    import nano.status : renderStatus = render;
    if (environment.get("AGENTIC_NO_STATUS") !is null) return "";
    auto stats = gStats.get;
    return renderStatus(stats, width);
}

/// The status bar's figures, read and changed under their lock by the turn
/// and the renderer.
@nullable("set by the module constructor below") shared Locked!Stats gStats;
shared static this() { gStats = new shared Locked!Stats; }

/// Change the status bar's stats and redraw it (no-op without a frame).
void updateStatus(scope void delegate(ref Stats) @safe f)
{
    if (!gFrame) return;
    gStats.update(f);
    gFrame.redraw();
}

/// The agent's side of the status line: model, context, plan, mode, tokens.

/// The console's line state (what's on the current line, the thinking
/// block, held-back markdown). It lives in a `Shared` cell, so the main
/// thread and the turn's key reader print through the same state, one at a
/// time.
struct Screen
{
    bool color, tty;
    private bool midLine;
    private bool thinking, blockExpanded, streamedThinking;
    private string thinkText;
    private long thinkStart;
    // The thinking block's stamp, and whether an answer segment is streaming
    // (its first line got a stamp, so later lines are padded under it).
    private string blockStamp;
    private bool answering;
    // Answers on a color terminal have their markdown rendered a block at a
    // time (markdown.rs MarkdownStream); piped and NO_COLOR output keep it raw.
    private MarkdownStream markdown;
    bool verbose() const { return verbosity >= Verbosity.verbose; }
    bool renderMarkdown() const { return tty && color; }

    /// Prints any streamed markdown still held back (the answer segment
    /// ended, or the turn stopped mid-block).
    private void flushMarkdown()
    {
        if (!markdown.holding) return;
        auto rest = markdown.finish(answerWidth());
        if (rest.length) writeAligned(rest, answerPad());
    }

    string stamp() { return .stamp(color); }
    string dim(string s) { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }

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

    private static long nowMs()
    {
        import core.time : MonoTime;
        return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    private string thinkStyle(string s) { return color ? "\x1b[38;5;245m" ~ s ~ "\x1b[0m" : s; }

    private void thinkingDelta(string chunk)
    {
        import std.string : stripLeft;
        if (!thinking)
        {
            flushMarkdown();
            if (midLine) { write("\n"); midLine = false; }
            thinking = true;
            answering = false;
            blockStamp = stamp();
            thinkText = null;
            thinkStart = nowMs();
            blockExpanded = verbose;
            if (blockExpanded) write(blockStamp ~ thinkStyle("∴ Thinking") ~ "\n");
        }
        bool first = !thinkText.length;
        thinkText ~= chunk;
        if (blockExpanded)
        {
            auto t = first ? chunk.stripLeft : chunk;
            if (t.length) writeAligned(thinkStyle(t), blockStamp.length ? stampWidth : 0);
        }
        stdOut.flush();
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
            auto line = blockStamp ~ thinkStyle(format("∴ Thought for %.1fs", secs)) ~ dim(format(" · %s chars", chars));
            write(line ~ "\n");
            // Ctrl-O shows the reasoning under the summary.
            if (gFrame && chars)
                write(foldMark("", 1, line ~ "\n" ~ expandedBody(thinkText, color ? "\x1b[38;5;245m" : "")));
        }
        midLine = false;
        stdOut.flush();
    }

    /// A streamed chunk of reasoning or answer.
    void text(bool reasoning, string chunk)
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
        auto shown = renderMarkdown ? markdown.push(chunk, answerWidth()) : chunk;
        if (shown.length) writeAligned(shown, answerPad());
        stdOut.flush();
    }

    void note(string text)
    {
        flushMarkdown();
        if (midLine) write("\n");
        midLine = false;
        answering = false;
        writeln(stampBlock(stamp(), text));
        stdOut.flush();
    }

    void endLine()
    {
        finishThinking();
        flushMarkdown();
        if (midLine) writeln();
        midLine = false;
        answering = false;
    }

    /// The model call ended: reasoning that didn't stream shows now, like a
    /// block that just ended.
    void endReasoning(string reasoning)
    {
        flushMarkdown();
        if (!streamedThinking && reasoning.length && !thinking) thinkingDelta(reasoning);
        finishThinking();
        streamedThinking = false;
    }
}

private size_t answerPad() { return atomicLoad(gTimestamps) ? stampWidth : 0; }
private size_t answerWidth()
{
    auto w = terminalWidth(), pad = answerPad();
    return w > pad + 10 ? w - pad : 10;
}

/// The console as other threads see it: a sendable handle to its `Screen`.
struct ConsoleLink
{
    private Shared!Screen screen;
    bool color;
    string dim(string s) { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }
    /// A line of its own, mid-stream or not (the live thinking line redraws below it).
    void note(string text) { screen.update((ref Screen s) { s.note(text); }); }
    void endLine() { screen.update((ref Screen s) { s.endLine(); }); }
}

class Console : AgentEvents
{
    immutable bool color, tty;
    /// The shared line state; hand `link` to other threads.
    ConsoleLink link;
    /// Tool output previews and expanded thinking (verbosity verbose or debug).
    bool verbose() const { return verbosity >= Verbosity.verbose; }
    /// Quiet shows only final answers: the last assistant text of the turn
    /// is kept for the end, as are whether answer deltas were dropped (a turn
    /// that turns louder mid-answer reprints the whole answer).
    bool quiet() const { return verbosity == Verbosity.quiet; }
    string finalAnswer;
    bool droppedAnswer;
    bool renderMarkdown() const { return tty && color; }

    /// A whole answer as shown on this console: markdown rendered for a
    /// color terminal, verbatim otherwise.
    string display(string text) { return renderMarkdown ? renderMarkdownText(text, answerWidth()) : text; }

    string stamp() { return .stamp(color); }

    this(bool color, bool tty = false)
    {
        this.color = color;
        this.tty = tty;
        link = ConsoleLink(Shared!Screen.make(Screen(color, tty)), color);
    }

    private static long nowMs()
    {
        import core.time : MonoTime;
        return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    string dim(string s) { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }
    string bold(string s) { return color ? "\x1b[1m" ~ s ~ "\x1b[0m" : s; }
    string red(string s) { return color ? "\x1b[31m" ~ s ~ "\x1b[0m" : s; }

    private RateMeter meter;

    void text(bool reasoning, string chunk)
    {
        if (gFrame)
        {
            auto rate = meter.record(chunk.length, nowMs);
            if (rate > 0) updateStatus((ref Stats s) { if (s.activity == Activity.thinking) s.tokensPerSec = rate; });
        }
        if (quiet)
        {
            if (!reasoning && chunk.length) droppedAnswer = true;
            return;
        }
        link.screen.update((ref Screen s) { s.text(reasoning, chunk); });
    }

    /// A line of its own, mid-stream or not (the live thinking line redraws below it).
    void note(string text) { link.note(text); }

    void endLine() { link.endLine(); }

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
        meter.reset(nowMs);
        if (quiet || quietTool(call)) return;
        endLine();
        auto line = stamp() ~ (color ? "\x1b[38;5;114m●\x1b[0m " : "● ") ~ bold(call.name) ~ " " ~ dim(summary(call));
        writeln(line);
        // Ctrl-O shows the full arguments under the call.
        if (gFrame) write(foldMark(call.id, 1, line ~ "\n" ~ expandedBody(argsText(call), color ? "\x1b[2m" : "")));
        stdOut.flush();
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
        auto clean = sanitizeBlock(result);
        auto shown = stampBlock(st, toolResult(!isError, clean, verbose, w > 8 + st.length ? w - 8 - (st.length ? stampWidth : 0) : 1));
        write(shown);
        // Ctrl-O shows every line, together with the call's arguments.
        if (gFrame) write(foldMark(call.id, shown.lineCount, stampBlock(st, expandedResult(!isError, clean, color))));
        stdOut.flush();
    }

    void usage(TokenUsage u)
    {
        // The call's final rate (reported output over the generation), then a
        // fresh meter for the next call so its rate isn't diluted by this one.
        if (gFrame)
        {
            auto rate = meter.finish(u.outputTokens, nowMs);
            if (rate > 0) updateStatus((ref Stats s) { s.tokensPerSec = rate; });
        }
        meter.reset(nowMs);
        if (afterStep !is null) afterStep();
    }
    void userMessage(string text)
    {
        if (quiet) return;
        endLine();
        writeln(stampBlock(stamp(), dim("↪ " ~ text)));
    }
    /// Close the abandoned partial so the resent reply starts a fresh segment
    /// instead of joining the stale prefix.
    void responseRestarted()
    {
        if (!quiet) endLine();
    }

    void assistantMessage(string text, string reasoning)
    {
        finalAnswer = text;
        if (quiet) return;
        link.screen.update((ref Screen s) { s.endReasoning(reasoning); });
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
    return format("  %s%s %s%s%s\n", on, mark, fitText(lines[0].stripRight("\r"), saturatingSub(width, more.length)), more, off);
}

/// A tool call's arguments as shown expanded: pretty JSON, or the raw text
/// when the model's arguments weren't a JSON object.
string argsText(const ref ToolCall c)
{
    return c.invalidArguments.length ? c.invalidArguments : c.arguments.toPrettyString;
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

/// The configured context window: top-level `context_window`, else the
/// provider's (0: none), and which one it is.
ConfiguredWindow windowFor(const ref Config c, const ref ProviderConfig p)
{
    if (c.contextWindow > 0) return ConfiguredWindow(cast(size_t) c.contextWindow, "context_window in config");
    if (p.contextWindow > 0) return ConfiguredWindow(cast(size_t) p.contextWindow, "provider context_window");
    return ConfiguredWindow.init;
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

string buildSystemPrompt(const ref Config c, string cwd, bool plan, const Skills skills, string memoryIndex = null,
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
    s ~= skills.renderIndex;
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
Option!ProjectInstructions discoverInstructions(const ref Config c, string dir)
{
    import std.process : environment;
    if (!c.projectInstructions || environment.get("AGENTIC_NO_PROJECT_INSTRUCTIONS") !is null) return typeof(return).init;
    InstructionOptions o;
    o.names = c.projectInstructionFiles.dup;
    foreach (f; c.userInstructionFiles) o.userFiles ~= expandHome(f);
    foreach (d; c.userRulesDirs) o.userRulesDirs ~= expandHome(d);
    o.importsOutsideProject = c.instructionImportsOutsideProject;
    return some(ProjectInstructions.discover(dir, o));
}

/// `/context`: window use, token totals, compaction settings.
string toolsListing(Agent agent) { return agent.toolsListing; }

string skillsListing(const Skills skills)
{
    if (skills.empty) return "No skills found.";
    string[] out_;
    foreach (sk; skills.skills) out_ ~= format("  %-20s %s", sk.name, firstLine(sk.description));
    return out_.join("\n");
}

string sessionText(Agent agent)
{
    return agent.log.match!(l => format("session %s\nlog: %s", l.id, l.path), () => "not recording (--no-session)");
}

/// `/timers`: the agent's active timers.
string timersText(Agent agent)
{
    return agent.timers.empty ? "No timers set. The agent sets one with the timer_set tool."
        : agent.timers.list(agent.timerNow()).stripRight;
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
    auto loaded = agent.instructions.match!(pi => pi.loadedPaths, () => string[].init);
    auto onDemand = agent.instructions.match!(pi => pi.onDemandPaths, () => string[].init);
    if (!loaded.length)
        out_ ~= "Instructions: none (no AGENTS.md, CLAUDE.md or .github/copilot-instructions.md found)";
    else out_ ~= "Instructions: " ~ loaded.join(", ");
    if (onDemand.length) out_ ~= "On-demand rules: " ~ onDemand.join(", ");
    out_ ~= format("Session:      %s input, %s output tokens", agent.sessionInputTokens, agent.sessionOutputTokens);
    if (agent.hasSessionAic) out_ ~= format("AI Credits:   %.2f used this session", agent.sessionAic);
    out_ ~= agent.autoCompact
        ? format("Auto-compact: at %.0f%% (~%s tokens); compacted %s time(s)", agent.autoCompactThreshold * 100,
            cast(size_t)(window * agent.autoCompactThreshold), agent.compactions)
        : "Auto-compact: off";
    out_ ~= format("Compaction:   %s mode (/compact --smart or --standard overrides once)", modeName(agent.compactionMode));
    return out_.join("\n");
}

/// The agent, for `main`'s exit (title requests may still be in flight).
Option!Agent mainAgent; /// the REPL's agent (main thread only); none if startup ended early

int main(string[] args)
{
    auto rc = runMain(args);
    import core.time : dur;
    if (mainAgent.match!(a => !a.settleTitles(dur!"seconds"(3)), () => false))
    {
        // A title request is still running: druntime teardown would race the
        // thread, so leave without it (Rust likewise drops pending tasks).
        import core.sys.posix.unistd : _exit;
        stdOut.flush();
        stdErr.flush();
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

    // `session_dir` relocates the logs; `persist_sessions = false` saves none.
    immutable sessionDir = nano.session.sessionDir(cfg.sessionDir);
    if (!cfg.persistSessions) o.noSession = true;
    if (o.trajectory !is null) return printTrajectory(sessionDir, o.trajectory, o.json, o.markdown);
    if (o.listSessions) return printSessions(sessionDir, o.all, o.json);
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
            import std.algorithm : map;
            import std.array : array;
            auto rp = resolve(cfg, o.listModels);
            // A curated list (`list_models = "configured"`) needs no request.
            auto configured = rp.config.configuredModels;
            auto models = configured !is null ? configured.map!(m => m[0]).array : makeClient(rp).listModels;
            foreach (m; models) writeln(rp.name, "/", m);
            return 0;
        }
        catch (Exception e) die(e.msg);
    }

    auto spec = o.model.length ? o.model : cfg.model;
    LLMClient client;
    ConfiguredWindow configuredWindow;
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
    // Read-deny rules hide paths from search results (Policy.readDenyScan).
    // The deny rules and working directory are resolved once per search, so
    // each walked entry is judged lexically (Rust #160).
    registerSearch(tools, (string root) @safe {
        import nano.permissions : ReadDenyScan;
        ReadDenyScan scan;
        if (!agent.policy.readDenyScan(getcwd(), scan)) return cast(bool delegate(string) @safe) null;
        auto forRoot = scan.forRoot(root);
        return (string path) @safe => forRoot.denied(path);
    });

    auto cwd = getcwd();
    // Repository trust gates the repo's own skills, skill lock and hooks.
    bool trusted(string dir)
    {
        import nano.trust : trustRoot, decideRoot, TrustOptions = Options, Gated, isYes, trustQuestion, trustFile;
        static bool[string] decided;
        auto root = trustRoot(dir);
        if (auto d = root in decided) return *d;
        TrustOptions to;
        to.yolo = o.yolo;
        to.acp = o.acp;
        to.interactive = !o.prompt.length && isTerminal(0) && isTerminal(1);
        // A resource that can't load isn't gated (and never drives the question).
        to.hooksEnabled = !(cfg.disableHooks || o.noHooks || cfg.disableProjectHooks);
        to.skillsEnabled = cfg.skills.enabled && environment.get("NANO_CODER_NO_SKILLS") is null;
        bool confirm(string r, Gated g)
        {
            stdErr.write(trustQuestion(r, g));
            stdErr.flush;
            auto line = stdinLine();
            return line.length && isYes(line);
        }
        void note(string msg) { stdErr.writeln("nano-coder-d: ", msg); }
        auto ok = decideRoot(root, cfg.skills.dirs, cfg.skills.aiLock, to, trustFile, &confirm, &note);
        decided[root] = ok;
        return ok;
    }
    // Skills: the index goes into the system prompt; `load_skill` reads one.
    // Off is an empty set (as in Rust), not null.
    // NANO_CODER_NO_SKILLS turns skills off for one run (as in Rust).
    bool skillsOn = cfg.skills.enabled && environment.get("NANO_CODER_NO_SKILLS") is null;
    Skills skills;
    Skills discoverSkills(string dir)
    {
        if (!skillsOn) return new Skills;
        auto sc = cfg.skills;
        if (!trusted(dir)) { sc.dirs = null; sc.aiLock = false; }
        auto s = Skills.discover(dir, sc);
        foreach (w; s.warnings) stdErr.writeln("nano-coder-d: skills: ", w);
        return s;
    }
    skills = discoverSkills(cwd);
    if (skillsOn && (o.acp || !skills.empty))
        tools.register(skillsDefinition, (JSONValue a) => skills.load(a));
    // Memory: read-only when no human vets saves live (ACP, -p, piped stdio) and in plan mode.
    Option!MemoryStore memory;
    bool memoryWritable = cfg.memory == MemoryMode.on && !o.acp && !o.prompt.length && isTerminal(0) && isTerminal(1);
    if (cfg.memory != MemoryMode.off)
    {
        auto dir = cfg.memoryDir.length ? cfg.memoryDir : memoryDefaultDir();
        if (dir.length) memory = some(new MemoryStore(dir, projectKey(cwd), cfg.memoryExpiryDays < 0 ? 0 : cfg.memoryExpiryDays));
    }
    // A helper, not a foreach-body delegate: D closures share the loop variable.
    ToolHandler asToolError(string delegate(JSONValue) @safe handler)
    {
        return (JSONValue a) {
            try return handler(a);
            catch (Exception e) throw new ToolError(e.msg);
        };
    }
    foreach (store; memory)
        foreach (t; memorySessionTools(store, memoryWritable, () => agent.control.mode == AgentMode.plan,
                () => agent.log.match!(l => l.id, () => string.init)))
            tools.register(t.definition, asToolError(t.handler));
    // Instruction files, discovered once per working directory.
    Option!ProjectInstructions instructions;
    string instructionsDir;
    // Every caller installs the prompt it builds at once, so the ids its
    // memory index renders in full go straight to the agent (recall skips them).
    bool[string] indexShown;
    string systemFor(string dir, bool plan)
    {
        indexShown = null;
        // `agent` is null only on the first call: the agent is built from this prompt.
        auto index = memory.match!(m => m.indexWithRendered(memoryWritable && !plan, indexShown), () => string.init);
        if (agent !is null) agent.indexShown = indexShown;
        if (instructionsDir is null || instructionsDir != dir)
        {
            instructionsDir = dir;
            instructions = discoverInstructions(cfg, dir);
            if (agent !is null) agent.instructions = instructions;
        }
        return buildSystemPrompt(cfg, dir, plan, skills, index, instructions.match!(pi => pi.render, () => string.init));
    }
    auto questions = QuestionBroker.make;
    tools.register(questionDefinition, (JSONValue a) => questions.run(a));
    agent = new Agent(client, tools, policy, systemFor(cwd, o.plan));
    mainAgent = some(agent);
    agent.memory = memory;
    agent.indexShown = indexShown;
    agent.instructions = instructions;
    agent.sessionTitles = cfg.sessionTitles;
    agent.titleModel = cfg.titleModel;
    agent.titleClient = (string spec) => makeClient(resolve(cfg, spec));
    agent.planTools = cfg.planTools;
    agent.timerTools = !o.acp; // ACP has no idle loop to fire them
    agent.outcomeTool = cfg.outcomeTool;
    agent.remindersEnabled = cfg.reminders;
    agent.questions = questions;
    if (o.plan) agent.control.mode = AgentMode.plan;
    HookManager loadHooks(string dir)
    {
        import nano.claude_hooks : LoadOptions;
        LoadOptions lo;
        lo.disableHooks = cfg.disableHooks || o.noHooks;
        lo.disableProjectHooks = cfg.disableProjectHooks || !trusted(dir);
        lo.claudeUserHooks = cfg.claudeUserHooks;
        lo.nanoHooks = cfg.hooks;
        lo.sandbox = cfg.sandbox;
        auto m = HookManager.load(lo, dir);
        if (auto notice = m.startupNotice) stdErr.writeln(notice);
        foreach (sk; m.skipped)
            if (!sk.source.isProject)
                stdErr.writefln("hooks: skipped %s (%s): %s", listingField(sk.eventName), sk.source.label, listingField(sk.reason));
        return m;
    }
    agent.maxIterations = cfg.maxIterations;
    agent.maxTokens = cfg.maxTokens;
    agent.setConfiguredWindow(configuredWindow);
    agent.autoCompact = cfg.autoCompact;
    agent.idleCompact = cfg.idleCompact;
    agent.verifyBeforeComplete = cfg.verifyBeforeComplete;
    agent.compactionPinRequests = cfg.compactionPinRequests;
    agent.autoCompactThreshold = cfg.autoCompactThreshold;
    {
        import nano.context : parseCompactionMode;
        if (!parseCompactionMode(cfg.compactionMode, agent.compactionMode))
            die(`compaction_mode must be "standard" or "smart", got "` ~ cfg.compactionMode ~ `"`);
    }
    bool compactingByHand;
    agent.onCompacted = (ref const CompactReport r) {
        // Manual compactions are reported by /compact itself.
        if (!compactingByHand) stdErr.writeln("[agent] auto-", r.toString);
    };
    agent.temperature = cfg.temperature;
    agent.globalThinking = cfg.thinking;
    agent.globalVision = cfg.vision;
    agent.markRead = (string p, const(ubyte)[] b) { readState.record(p, b); };
    agent.providerLookup = (string name) => name in cfg.providers;
    agent.refreshCapabilities();
    // A configured temperature or thinking level that is adjusted or ignored.
    if (!o.acp && !o.prompt.length) foreach (w; settingWarnings(agent)) stdErr.writeln("Warning: ", w);

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
        host.providerNames = () => enabledProviderNames(cfg.providers);
        host.configModel = cfg.model;
        host.configSystemPrompt = cfg.systemPrompt;
        host.sessionMeta = () {
            JSONValue meta = ["projectInstructions": JSONValue(instructions.match!(pi => pi.loadedPaths, () => string[].init)),
                "skills": JSONValue(skills.names)];
            foreach (pi; instructions)
            {
                if (auto od = pi.onDemandPaths) meta["projectInstructionsOnDemand"] = od;
                if (pi.warnings.length) meta["instructionWarnings"] = pi.warnings;
            }
            if (skills.warnings.length) meta["skillWarnings"] = skills.warnings;
            return meta;
        };
        auto server = new AcpServer(agent, host);
        stdErr.writefln("ACP harness ready (provider: %s, model: %s)", client.providerName, client.modelName);
        if (!server.serveStdio())
        {
            stdErr.writeln("no valid ACP requests received on stdin — is the client speaking ACP "
                ~ "(JSON-RPC 2.0, one message per line)?");
            return 2;
        }
        return 0;
    }

    /// Load a saved session into the agent: its conversation, plan and log.
    void loadSession(string path)
    {
        auto restored = restore(path);
        foreach (note; agent.loadRestored(restored, o.noSession ? Option!SessionLog(none) : some(new SessionLog(path))))
            stdErr.writeln("nano-coder-d: ignoring ", note);
        updateStatus((ref Stats s) { s.historySearches = s.historyReads = 0; });
        if (!agent.timers.empty)
            stdErr.writefln("%s timer%s still set (/timers lists them)", agent.timers.items.length,
                agent.timers.items.length == 1 ? "" : "s");
        stdErr.writefln("resumed %s (%s messages)", restored.id, agent.messages.length - 1);
        if (restored.pendingInput.length)
            stdErr.writefln("the last prompt never finished (the session was interrupted): %s",
                oneLine(restored.pendingInput));
    }

    try
    {
        if (o.hasResume) loadSession(findSession(sessionDir, o.resume, cwd));
        else if (!o.noSession)
        {
            auto log = new SessionLog(sessionDir, spec, cwd);
            foreach (m; agent.messages) log.append(m);
            agent.log = some(log);
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
        stdOut.flush();
    };

    gControl = agent.control.nonNull;
    installSigint();
    Chan!string inbox;
    // none in -p/piped runs, and while a turn lends it to the key reader.
    Option!LineEditor editor;
    string[] held; // lines to run before reading the prompt again
    auto queue = MessageQueue.make; // Ctrl-Enter messages: one runs per following turn

    // Recently used models lead the `/model` type-ahead (recents.rs).
    static import nano.recents;
    import nano.commands : Suggestion, modelSuggestionSource;
    auto recentsPath = nano.recents.defaultPath();
    auto recents = nano.recents.load(recentsPath);
    if (recents.canonicalize(cfg.providers, cfg.defaultProvider)) nano.recents.save(recentsPath, recents);
    string currentSpec() { return nano.recents.canonical(client.providerName ~ "/" ~ client.modelName, cfg.providers, cfg.defaultProvider); }
    modelSuggestionSource = () {
        import std.algorithm : canFind, sort;
        Suggestion[] out_;
        void push(string value, string note)
        {
            if (value.length && !out_.canFind!(x => x.value == value)) out_ ~= Suggestion(value, note);
        }
        // A current or recent model on a hidden provider stays usable but isn't offered.
        import nano.config : specVisible;
        if (specVisible(currentSpec(), cfg.providers, cfg.defaultProvider)) push(currentSpec(), "current");
        synchronized foreach (r; recents.models)
            if (specVisible(r, cfg.providers, cfg.defaultProvider)) push(r, "recent");
        bool configured(string n) { return cfg.userProviders.canFind(n) || n == cfg.defaultProvider; }
        auto names = enabledProviderNames(cfg.providers);
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
        // A curated list (`list_models = "configured"`) offers each of its models.
        foreach (n; names)
            foreach (m; cfg.providers[n].configuredModels) push(n ~ "/" ~ m[0], m[1]);
        foreach (n; names) push(n, providerNote(n));
        return out_;
    };

    /// Switch the model (history carries over); the "Model set to" text.
    /// `queued`: a `/model` from mid-turn, already taken off the queue; a
    /// direct switch also drops one still queued.
    string switchModel(string spec, bool queued = false)
    {
        auto previous = currentSpec();
        LLMClient build(string s, out ConfiguredWindow w)
        {
            auto rp = resolve(cfg, s);
            auto c = makeClient(rp);
            w = windowFor(cfg, rp.config);
            return c;
        }
        if (queued)
        {
            ConfiguredWindow w;
            auto c = build(spec, w);
            agent.useClient(c, w);
        }
        else agent.setModel(spec, &build);
        client = agent.client;
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
        try console.note(switchModel(spec, true));
        catch (Exception e) console.note(console.red(format("[/model %s: %s]", spec, e.msg)));
    };

    // The status line's agent stats (cwd shown with ~ for home).
    string cwdShown = tildePath(cwd, environment.get("HOME", ""));
    void refreshStatus()
    {
        updateStatus((ref Stats s) { statusFromAgent(s, agent, cwdShown); });
    }

    // Read-only commands typed mid-turn show this, rendered on the agent thread.
    auto view = LiveView.make;
    void refreshView()
    {
        view.set("/tools", toolsListing(agent));
        view.set("/skills", skillsListing(skills));
        view.set("/session", sessionText(agent));
        view.set("/plan", planText(agent));
        view.set("/timers", timersText(agent));
        view.set("/context", contextReport(agent));
        view.set("log", agent.log.match!(l => l.path, () => string.init));
        refreshStatus();
    }
    console.afterStep = &refreshView;

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

    // `h.cfg` points at runMain's `cfg`, which outlives every settings
    // dialog (they all run inside runMain).
    SettingsHost settingsHost()
    {
        auto h = SettingsHost(&cfg, notNull(agent));
        h.configPath = cfgPath;
        h.recents = () => recents.models;
        h.switchModel = (string spec) {
            try { switchModel(spec); return cast(string) null; }
            catch (Exception e) return e.msg;
        };
        h.listModels = (string name) => makeClient(resolve(cfg, name)).listModels();
        h.refreshSystem = () { agent.messages[0].content = systemFor(cwd, sysPlan); };
        h.refreshClient = (string name) {
            if (agent.client.providerName != name) return cast(string) null;
            try { switchModel(name ~ "/" ~ agent.client.modelName); return ""; }
            catch (Exception e) return e.msg;
        };
        onVerbosity = (Verbosity v) { setVerbosity(v); };
        return h;
    }

    /// Run `work` (a turn, or an idle compaction) with the key reader live:
    /// keys typed meanwhile steer, Ctrl-C or Esc Esc cancels, and steers left
    /// over afterwards run as the next prompts.
    bool driven(scope bool delegate() @safe work) @safe
    {
        // With the line editor, keys typed during the turn steer it (a
        // `/command` waits for the turn to end); Ctrl-C or Esc Esc cancels.
        auto turnDone = new shared(bool);
        Join!(Isolated!LineEditor) keys;
        Chan!string heldLines;
        bool keysStarted;
        foreach (ed; editor)
        {
            if (verbosity >= Verbosity.verbose)
                stdErr.writeln(console.dim("[running: Enter sends a message to steer the agent, Ctrl-Enter queues it for later "
                    ~ "(/queue lists, edits, removes), Esc Esc or Ctrl-C to cancel]"));
            refreshView();
            heldLines = Chan!string.make;
            auto mid = MidTurn(agent.control, view, [frozenConfig(cfg)]);
            // Isolated: `editor` is none until the join hands it back, and its
            // callbacks (built by `makeEditor`) reach only shared state.
            auto owned = Isolated!LineEditor.assumeIsolated(ed);
            editor = none;
            keys = spawn(&turnKeys, imported!"core.lifetime".move(owned), console.link, turnDone, heldLines, questions, queue, mid);
            keysStarted = true;
        }
        bool keysRunning = keysStarted;
        void stopKeys()
        {
            if (!keysRunning) return;
            keysRunning = false;
            atomicStore(*turnDone, true);
            editor = some(keys.join().unwrap);
            string line;
            while (heldLines.tryTake(line)) held ~= line;
        }
        scope (exit) stopKeys(); // when `work` throws
        bool ok = work();
        // Stop the key reader before taking the late steers: one typed between
        // the take and the stop would land in `control` and never run.
        stopKeys();
        // Steers that arrived after the agent's last step run as the next prompts.
        // One the user steered at the prompt keeps its `/queue` id.
        auto late = agent.control.takePending;
        // A cancelled turn drops them (Rust: only a successful cancelled outcome).
        if (ok && agent.control.nonNull.isCancelled)
        {
            foreach (t; late) stdErr.writeln(console.dim("[steer dropped: " ~ t.text ~ "]"));
            late = null;
        }
        if (inbox)
            foreach_reverse (t; late) inbox.put(t.text, true);
        // Keyed on the reader, not on `editor` (which `stopKeys` has handed back).
        if (keysStarted)
        {
            // Re-escape a steer starting with `/` so it runs as a message.
            string asLine(string text) { return text.startsWith("/") ? "/" ~ text : text; }
            foreach (t; late) if (t.id >= 0) queue.pushWithId(t.id, asLine(t.text));
            foreach_reverse (t; late) if (t.id < 0) held = asLine(t.text) ~ held;
        }
        return ok;
    }

    bool turn(string input) @safe
    {
        syncMode();
        nano.herdr.report(nano.herdr.State.working);
        if (gFrame) gFrame.busy(true);
        scope (exit) if (gFrame) gFrame.busy(false);
        atomicStore(gTurnRunning, true);
        scope (exit) atomicStore(gTurnRunning, false);
        updateStatus((ref Stats s) { s.activity = Activity.thinking; s.tokensPerSec = 0; });
        scope (exit)
        {
            refreshStatus();
            updateStatus((ref Stats s) { s.activity = Activity.idle; s.tokensPerSec = 0; });
        }
        return driven(() @safe {
            bool ok = true;
            console.finalAnswer = null;
            console.droppedAnswer = false;
            try agent.run(input, console);
            catch (Exception e)
            {
                console.endLine();
                stdErr.writeln(console.red("error: " ~ e.msg));
                ok = false;
            }
            console.endLine();
            // Quiet shows only the final answer; a turn that got louder after
            // answer deltas were dropped reprints the whole answer (ui.rs).
            if ((console.quiet || console.droppedAnswer) && console.finalAnswer.length)
            {
                writeln(console.display(console.finalAnswer));
                stdOut.flush();
            }
            return ok;
        });
    }


    if (o.prompt.length)
    {
        bool ok = turn(o.prompt);
        // --wait-timers: sleep until each timer the agent set fires and run
        // it as the next prompt, until none are left (Ctrl-C stops waiting).
        while (ok && o.waitTimers && !agent.timers.empty && !agent.control.nonNull.isCancelled)
        {
            import core.thread : Thread;
            import core.time : msecs;
            stdOut.flush(); // the answer before the notes
            auto wait = agent.timers.nextDue - agent.timerNow();
            if (wait > 0)
            {
                stdErr.writeln(console.dim(format("[waiting %s for timer %s]", imported!"nano.timers".describe(wait),
                    agent.timers.items[0].id)));
                // Idle Ctrl-C exits (130) via the SIGINT handler.
                while (agent.timers.nextDue > agent.timerNow()) Thread.sleep(500.msecs);
            }
            string notice;
            auto fired = agent.takeFiredTimers(notice);
            if (fired is null) continue;
            stdErr.writeln(console.dim(notice));
            agent.automaticInput = true;
            ok = turn(fired);
        }
        if (ok && !o.waitTimers && !agent.timers.empty)
        {
            stdOut.flush();
            stdErr.writeln(console.dim(format("[%s timer%s didn't fire: the run ended first (--wait-timers waits for them)]",
                agent.timers.items.length, agent.timers.items.length == 1 ? "" : "s")));
        }
        return ok ? 0 : 1;
    }

    bool interactive = isTerminal(0);
    Chan!string updateHints; // update hints for an idle prompt
    if (interactive && isTerminal(1) && environment.get("TERM", "") != "dumb"
        && environment.get("NANO_CODER_PLAIN_INPUT") is null && enterKeyMode(0))
    {
        // The app owns the screen and re-renders it (`nano.frameui`); the
        // editor draws only through it.
        gFrame = FrameUi.install(&frameStatus);
        if (!gFrame)
        {
            leaveKeyMode();
            die("could not start the terminal renderer");
        }
        editor = some(makeEditor(console.link, agent.control.nonNull));
        questions.interactive = true;
        refreshStatus();
        // The background update check (Rust #154): interactive terminal
        // sessions installed through npm only.
        import nano.update : channelFor, launchExe, disabledByEnv, isCi, startChecker, Channel;
        if (!o.acp && cfg.checkUpdates && !disabledByEnv && !isCi && channelFor(launchExe) == Channel.npm)
            updateHints = startChecker(Channel.npm, packageVersion);
    }
    scope (exit) leaveKeyMode();
    scope (exit) if (gFrame) { gFrame.uninstall(); gFrame = FrameUi.init; }
    if (interactive && editor.isNone)
    {
        import core.thread : Thread;
        inbox = Chan!string.make;
        bool color = console.color;
        spawnDaemon(&readStdinLines, inbox, color);
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
        agent.log.ifSome((SessionLog l) { banner ~= format("Session: %s (resume with --resume %s)", l.id, l.id); });
        foreach (pi; instructions)
        {
            foreach (f; pi.loadedPaths) banner ~= "Instructions: " ~ f;
            foreach (w; pi.warnings) banner ~= "Instructions warning: " ~ w;
        }
        if (skills.names.length) banner ~= "Skills: " ~ skills.names.join(", ");
        foreach (w; skills.warnings) banner ~= "Skills warning: " ~ w;
        if (auto note = cfg.retiredRendererNotice) banner ~= note;
        banner ~= "Type /help for commands";
        writeln(stampBlock(console.stamp(), banner.join("\n")));
    }
    import core.time : MonoTime, msecs;
    enum exitWindow = 2000.msecs; // Rust's DOUBLE_INTERRUPT_WINDOW
    MonoTime exitArmedAt;         // first idle Ctrl-C of a pending pair (zero = disarmed)
    ParkedDraft parkedDraft;      // a stale draft set aside for a timer turn
    bool hasParkedDraft;
    bool quietPrompt;             // redraw the prompt in place (no separating blank line)
    // Herdr (interactive only): flags a resumed session needs to behave the same.
    string[] herdrExtra;
    if (editor.isSome)
    {
        import std.path : absolutePath;
        nano.herdr.start();
        if (o.configPath.length) herdrExtra = ["--config", absolutePath(o.configPath)];
    }
    scope (exit) nano.herdr.release();
    // Repeat the resume instruction on exit, so it is still on screen (and in
    // scrollback) after a long session pushed the banner away. Re-read the
    // log: `/restart` and `/resume` may have switched sessions.
    void goodbye()
    {
        writeln("\nGoodbye!");
        agent.log.ifSome((SessionLog l) { writefln("Session: %s (resume with --resume %s)", l.id, l.id); });
        stdOut.flush();
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
        else if (editor.isSome)
        {
            auto ed = editor.unwrap("checked on the line above");
            refreshStatus();
            if (!quietPrompt) write("\n");
            quietPrompt = false;
            stdOut.flush();
            // Ready for input: tell Herdr, with the session to resume (re-read
            // each time so `/resume` and `/restart` are picked up).
            string resumeId = nano.herdr.active ? agent.log.match!(l => l.id, () => string.init) : null;
            if (resumeId.length)
            {
                auto resume = nano.herdr.resumeArgv(resumeId, agent.client.providerName ~ "/" ~ agent.client.modelName, herdrExtra);
                if (resume !is null)
                    nano.herdr.report(nano.herdr.State.idle, null, nano.herdr.Session(resumeId, resume), true);
                else nano.herdr.report(nano.herdr.State.idle);
            }
            else nano.herdr.report(nano.herdr.State.idle);
            // The prompt's stamp is redrawn with the submission time (Rust's restamp).
            ed.restyle = () => console.stamp() ~ console.bold("› ");
            // While the Ctrl-C exit hint is armed, end the read when the window
            // lapses so the stale hint is cleared (Rust's DoublePress deadline).
            bool delegate() @safe lapse = null;
            // A timer turn is over: put back the draft it parked, unless
            // something newer was typed or sent meanwhile.
            if (hasParkedDraft)
            {
                ed.restoreDraft(parkedDraft);
                hasParkedDraft = false;
            }
            // A due timer ends the read too, unless a fresh draft holds it
            // (one idle for a minute is abandoned: Rust #178).
            // An update hint ends it too, to be shown above the prompt.
            string updateHint;
            if (updateHints && updateHints.tryTake(updateHint)) writeln(console.dim(updateHint));
            updateHint = null;
            // An idle compaction is due once the prompt (and any draft) sat
            // untouched for the hold, unless the exit window is armed (#186).
            auto promptShown = MonoTime.currTime;
            auto idleHold = idleCompactHoldFor(cfg);
            bool idleNow() @safe
            {
                return deliverIdleCompact(agent.idleCompactDuePolled(), MonoTime.currTime - ed.quietSince(promptShown),
                    idleHold, false, exitArmedAt != MonoTime.zero);
            }
            lapse = () @safe => (exitArmedAt != MonoTime.zero && MonoTime.currTime - exitArmedAt > exitWindow)
                || (!ed.holdsTimer(MonoTime.currTime) && agent.timers.anyDue(agent.timerNow()))
                || idleNow()
                || (updateHints && updateHints.tryTake(updateHint));
            auto r = ed.readLine(.stamp(false) ~ "› ", console.stamp() ~ glyphMark ~ " ", false, lapse);
            ed.restyle = null;
            syncMode(); // Shift-Tab at the prompt switched the mode
            if (r.outcome == Outcome.eof) break;
            if (r.outcome == Outcome.stopped && !ed.holdsTimer(MonoTime.currTime) && agent.timers.anyDue(agent.timerNow()))
            {
                // Park a stale draft so the timer turn can't take it as a steer.
                hasParkedDraft = ed.parkDraft(parkedDraft);
                string notice;
                line = agent.takeFiredTimers(notice);
                writeln(console.dim(notice));
                agent.automaticInput = true;
                line = "\x00" ~ line;
            }
            else if (r.outcome == Outcome.stopped && idleNow())
            {
                // Park the draft so keys typed meanwhile steer nothing stale.
                hasParkedDraft = ed.parkDraft(parkedDraft);
                writeln(console.dim("compacting (idle)… Esc Esc to cancel"));
                stdOut.flush();
                updateStatus((ref Stats s) { s.activity = Activity.idleCompacting; });
                IdleCompactReport rep;
                bool did;
                string failed;
                compactingByHand = true;
                driven(() @safe {
                    try did = agent.runIdleCompaction(rep);
                    catch (Exception e) failed = e.msg;
                    return true;
                });
                compactingByHand = false;
                updateStatus((ref Stats s) { s.activity = Activity.idle; });
                if (did) writeln(console.dim("[" ~ rep.toString ~ "]"));
                else if (failed.length) writeln(console.dim("[idle compaction failed: " ~ failed ~ "]"));
                else if (agent.control.nonNull.isCancelled) writeln(console.dim("[idle compaction cancelled]"));
                continue;
            }
            else if (r.outcome == Outcome.stopped && updateHint.length)
            {
                writeln(console.dim(updateHint));
                quietPrompt = true;
                continue;
            }
            else if (r.outcome == Outcome.stopped)
            {
                exitArmedAt = MonoTime.zero; // window lapsed: drop the hint, re-arm on the next press
                quietPrompt = true;
                continue;
            }
            if (r.outcome == Outcome.interrupt)
            {
                auto now = MonoTime.currTime;
                if (exitArmedAt != MonoTime.zero && now - exitArmedAt <= exitWindow) break;
                exitArmedAt = now;
                ed.hint = console.dim("(Ctrl-C again to exit)");
                quietPrompt = true;
                continue;
            }
            if (line is null) // not a fired timer
            {
                if (r.outcome != Outcome.line) continue;
                line = r.text;
                if (auto lit = unescapePrompt(line)) line = "\x00" ~ lit; // `//…`: a prompt starting with /
            }
        }
        else
        {
            if (interactive) { write("\n" ~ console.stamp() ~ console.bold("› ")); stdOut.flush(); }
            line = inbox ? takeLine(inbox) : stdinLine();
        }
        if (line is null) break;
        bool literal = line.startsWith("\x00");
        if (literal) line = line[1 .. $];
        auto input = line.strip;
        if (!input.length) continue;
        if (!literal && isCommand(input))
        {
            auto sp = input.indexOf(' ');
            auto cmd = sp > 0 ? input[0 .. sp] : input;
            auto arg = sp > 0 ? input[sp + 1 .. $].strip : "";
            {
                // Never send a `/…` line to the model: refuse unknown commands
                // and arguments a command doesn't take.
                import nano.commands : commandTable = commands, commandRejection = rejection;
                import std.algorithm.searching : find;
                auto known = commandTable.find!(c => c.name == cmd);
                if (known.length ? arg.length && !known[0].args.length : true)
                {
                    auto note = commandRejection(input);
                    writeln(note !is null ? note : format("Can't run %s: unexpected arguments "
                        ~ "(/help lists commands and their arguments)", JSONValue(input).toString(JSONOptions.doNotEscapeSlashes)));
                    continue;
                }
            }
            switch (cmd)
            {
                case "/quit", "/exit": goodbye(); return 0;
                case "/help": writeln(editor.isSome ? helpText() : usage); continue;
                case "/restart":
                {
                    // A brand-new session in place: new ID, just the system
                    // prompt, default mode, empty plan, counters zeroed. The
                    // previous log stays on disk and is still resumable.
                    import nano.session : newSessionId;
                    Option!SessionLog log;
                    try
                    {
                        if (!o.noSession)
                            log = some(new SessionLog(sessionDir, agent.client.providerName ~ "/" ~ agent.client.modelName, cwd));
                    }
                    catch (Exception e) { writeln(console.red("error: " ~ e.msg)); continue; }
                    agent.restart(systemFor(cwd, false), log);
                    updateStatus((ref Stats s) { s.historySearches = s.historyReads = 0; });
                    sysPlan = false;
                    agent.useHooks(loadHooks(cwd), false);
                    if (gFrame) gFrame.clear();
                    refreshStatus();
                    log.match!(l => writefln("Session: %s (resume with --resume %s)", l.id, l.id),
                        () => writefln("Session: %s", newSessionId()));
                    continue;
                }
                case "/update":
                    updateCommand(editor.isSome);
                    continue;
                case "/relaunch":
                {
                    // At the idle prompt the queue is empty (queued messages
                    // run before it shows) and the draft was this command, so
                    // there is nothing to confirm discarding.
                    import nano.update : launchExe, relaunchArgv;
                    import nano.safeio : execProgram;
                    auto id = agent.log.match!(l => l.id, () => string.init);
                    if (!id.length)
                    {
                        writeln("This session isn't saved (--no-session), so a relaunch cannot resume it. "
                            ~ "Use /restart for a fresh session.");
                        continue;
                    }
                    auto exe = launchExe();
                    // Printed after the frame hands the terminal back, so it stays on screen.
                    if (gFrame) gFrame.suspend();
                    writefln("\nRelaunching into session %s (resume later with --resume %s)", id, id);
                    stdOut.flush();
                    leaveKeyMode();
                    nano.herdr.release();
                    auto err = execProgram(exe, [exe] ~ relaunchArgv(args[1 .. $], id));
                    enterKeyMode(0);
                    if (gFrame) gFrame.resume();
                    writefln("Relaunch failed: could not exec %s: %s", exe, err);
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
                    try done = agent.compact(rep, CompactTrigger.manual, hasMode ? new CompactionMode(mode) : null, focus);
                    catch (Exception e) { stdErr.writeln(console.red("error: " ~ e.msg)); continue; }
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
                    writeln(runQueueCommand(queue, agent.control.nonNull, arg));
                    continue;
                case "/plan":
                    writeln(planText(agent));
                    continue;
                case "/timers":
                    writeln(timersText(agent));
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
                case "/version":
                    writeln(versionString);
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
                    auto current = agent.log.match!(l => l.id, () => string.init);
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
                    catch (Exception) {} // an invalid ID or unreadable path is reported as "no saved session" just below
                    if (!ok) { writefln("No saved session %s: /resume without an ID lists them", JSONValue(id).toString); continue; }
                    try loadSession(path);
                    catch (Exception e) { writeln(e.msg); continue; }
                    writefln("Resumed session %s (resume later with --resume %s)", id, id);
                    continue;
                }
                case "/trajectory":
                {
                    static import nano.trajectory;
                    string logPath = agent.log.match!(l => l.path, () => string.init);
                    if (!logPath.length) { writeln("Session persistence is disabled: no trajectory to show"); continue; }
                    if (arg.length && arg != "--json" && arg != "--markdown" && arg != "--md")
                    {
                        writefln("Unknown option %s; use /trajectory [--json|--markdown]", JSONValue(arg).toString);
                        continue;
                    }
                    nano.trajectory.Trajectory t;
                    try t = nano.trajectory.load(logPath);
                    catch (Exception e) { writeln("Could not read the session log: ", e.msg); continue; }
                    if (arg == "--json") writeln(t.toJson);
                    else if (arg.length) writeln(t.toMarkdown);
                    else showTrajectory(t, true);
                    continue;
                }
                case "/session":
                    writeln(sessionText(agent));
                    continue;
                case "/hooks":
                    write(agent.hooks.match!(h => h.listing, () => "No hooks loaded.\n"));
                    continue;
                case "/memory":
                    if (memory.isNone) { writeln("memory is off"); continue; }
                    auto store = memory.unwrap("checked on the line above");
                    try
                    {
                        if (arg.startsWith("forget "))
                        {
                            writeln(store.forget(arg[7 .. $]));
                            continue;
                        }
                        if (arg.length)
                        {
                            writefln("Unknown /memory argument %s; use /memory or /memory forget <id>.",
                                JSONValue(arg).toString(JSONOptions.doNotEscapeSlashes));
                            continue;
                        }
                        // Plan mode has no memory_save tool either.
                        bool writable = memoryWritable && agent.control.mode != AgentMode.plan;
                        auto all = store.all();
                        if (!all.length)
                        {
                            writefln(writable ? "No memories yet. The model saves them with memory_save; files live under %s."
                                : "No memories yet. Memory is read-only here, so the model cannot save them; files live under %s.",
                                store.root);
                            continue;
                        }
                        writefln("%s memor%s (memory is %s; edit the files under %s%s):", all.length,
                            all.length == 1 ? "y" : "ies", cfg.memory == MemoryMode.on ? "on" : "read-only",
                            store.root, writable ? ", or /memory forget <id>" : "");
                        import nano.memory : recallStats;
                        auto stats = recallStats(store);
                        foreach (x; all)
                        {
                            import nano.memory : scopeName = name;
                            import std.string : lineSplitter;
                            auto first = x.e.text.lineSplitter.empty ? "" : x.e.text.lineSplitter.front.strip;
                            auto row = format("  %s %s %s%s", scopeName(x.s), x.e.label, sanitizeLine(first),
                                x.e.evidence !is null ? " (check: " ~ sanitizeLine(x.e.evidence) ~ ")" : "");
                            if (x.e.isRule) row ~= " [rule]";
                            // Recall noise: how often a memory was recalled from a
                            // tool call, and how often that was followed by reading it.
                            if (auto st = x.e.id in stats) row ~= format(" (recalled %s×, used %s×)", (*st)[0], (*st)[1]);
                            writeln(row);
                        }
                    }
                    catch (Exception e) stdErr.writeln(console.red("error: " ~ e.msg));
                    continue;
                case "/settings":
                    if (editor.isNone) { writeln("/settings needs an interactive terminal"); continue; }
                    {
                        auto h = settingsHost();
                        foreach (n; runSettings(new EditorUi(editor.unwrap("checked above")), h)) writeln(n);
                    }
                    refreshStatus();
                    continue;
                case "/model":
                    if (!arg.length && editor.isSome)
                    {
                        auto h = settingsHost();
                        if (auto picked = pickModel(new EditorUi(editor.unwrap("checked above")), h))
                        {
                            try writeln(switchModel(picked));
                            catch (Exception e) stdErr.writeln(console.red("error: " ~ e.msg));
                        }
                        else writefln("Model unchanged: %s (provider %s)", client.modelName, client.providerName);
                        continue;
                    }
                    if (!arg.length) { writeln(client.providerName, "/", client.modelName); continue; }
                    try writeln(switchModel(arg));
                    catch (Exception e) stdErr.writeln(console.red("error: " ~ e.msg));
                    continue;
                default:
                    stdErr.writeln("unknown command ", cmd, " (/help)");
                    continue;
            }
        }
        turn(input);
    }
    goodbye();
    return 0;
}

// nano.nullaudit for this module (dub test leaves app.d out, so
// null_audit_test.d can't import it): fails the build on a field or global
// holding a bare class reference.
static assert(imported!"nano.nullaudit".bareRefs!(app)().length == 0,
    "bare class references (use NotNull!C, Option!C or @nullable(\"why\")): "
    ~ imported!"std.array".join(imported!"nano.nullaudit".bareRefs!(app)(), ", "));
