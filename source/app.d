/// nano-coder command line: a plain line-based REPL, one-shot `-p`, and the
/// flags of the Rust CLI that this port implements.
module app;

@safe:
import nano.safeio : jsonText, jsonPretty;
import nano.clock : monoNow, sleepFor, wallNow;
import nano.arith : saturatingSub, toSize;
import nano.option : Option, some, none, match, ifSome, unwrap, notNull, NotNull, nullable;
import nano.result : match, unwrap, unwrapErr, orThrow;

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
import nano.tools.bash : bashDefinition = definition, bashExecute = execute,
    bashHeartbeatSink = heartbeatSink, bashHeartbeatInterval = heartbeatInterval;
import nano.tools.files : ReadState, registerFiles = register;
import nano.tools.search : Denied, DenyRules, DenyScan, registerSearch = register;
import nano.permissions;
import nano.session;
import nano.toml : parseToml;
import nano.plan : Plan, checklist;
import nano.queue : MessageQueue, QueuedMessage, QueueUsage, queueParse = parse, queueApply = apply;
import nano.mode : AgentMode, allModes, parseMode, planPromptNote, name, describe, nextMode = next;
static import nano.herdr;
import nano.frame : glyphMark, foldMark, refoldMark, expandedBody, expandedResult, dropSoftWraps, escapeMarks, rawModelText;
import core.time : MonoTime, seconds;
import std.sumtype : match;
import nano.trajectory : terminalSafe;
import nano.question : QuestionBroker, Question, Answer, Answered, Away, Dismissed, questionDefinition = definition;
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

enum string packageVersion = "1.18.0";
enum string versionString = "nano-coder " ~ packageVersion;

enum string usage = `Usage: nano-coder [--model provider/model] [--config PATH] [-p PROMPT]
                    [--resume [SESSION_ID|last]] [--plan] [--sandbox off|workspace|read-only]
                    [--allow RULE]... [--deny RULE]...
                    [--no-session] [--no-hooks] [--yolo] [--wait-timers] [--verbosity quiet|normal|verbose|debug] [--acp]
       nano-coder --list-sessions [--all] [--json]
       nano-coder --trajectory SESSION_ID [--json|--markdown]
       nano-coder --list-models PROVIDER[/model]
       nano-coder --login github-copilot|muse
       nano-coder --version

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

/// A command line that doesn't parse; `main` prints it and exits 2.
class UsageError : Exception
{
    this(string msg) pure @safe { super(msg); }
}

/// The command line (Rust parse_args_from). Throws `UsageError`.
Options parseArgs(string[] args)
{
    static void fail(string msg) { throw new UsageError(msg); }
    Options o;
    for (size_t i = 1; i < args.length; i++)
    {
        auto a = args[i];
        auto eq = a.startsWith("--") ? a.indexOf('=') : -1;
        auto flag = eq > 0 ? a[0 .. eq] : a;
        string value()
        {
            if (eq > 0) return a[eq + 1 .. $];
            if (i + 1 >= args.length) fail(flag ~ " needs a value");
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
            default: fail("unknown argument " ~ a ~ "\n\n" ~ usage);
        }
    }
    if (o.json && o.markdown) fail("--json and --markdown are mutually exclusive");
    if (o.markdown && o.trajectory is null) fail("--markdown requires --trajectory <id>");
    if (o.json && o.trajectory is null && !o.listSessions) fail("--json requires --trajectory <id> or --list-sessions");
    if (o.all && !o.listSessions) fail("--all requires --list-sessions");
    if (o.listSessions && o.trajectory !is null) fail("--list-sessions and --trajectory are mutually exclusive");
    if (o.hasResume && o.trajectory !is null) fail("--resume and --trajectory are mutually exclusive");
    if (o.listSessions && (o.hasResume || o.acp || o.listModels.length || o.prompt.length || o.login.length))
        fail("--list-sessions can't be combined with --resume, --acp, --list-models, --login or -p");
    if (o.hasResume && o.login.length) fail("--resume and --login are mutually exclusive");
    if (o.hasResume && o.listModels.length) fail("--resume and --list-models are mutually exclusive");
    return o;
}

// rust: main.rs::list_sessions_and_resume_are_mutually_exclusive, main.rs::list_sessions_and_trajectory_are_mutually_exclusive
// rust: main.rs::list_sessions_conflicts_with_other_action_modes, main.rs::resume_conflicts_with_other_action_modes
// rust: main.rs::resume_attached_form_names_dash_prefixed_ids
unittest
{
    bool ok(string[] a...)
    {
        try { parseArgs(["nano-coder"] ~ a); return true; }
        catch (UsageError) return false;
    }
    assert(ok("--list-sessions") && ok("--resume", "sess-1") && ok("--resume") && ok("--trajectory", "sess-1"));
    assert(!ok("--list-sessions", "--resume", "sess-1") && !ok("--resume", "sess-1", "--list-sessions"));
    assert(!ok("--list-sessions", "--resume"));
    assert(!ok("--list-sessions", "--trajectory", "sess-1") && !ok("--trajectory", "sess-1", "--list-sessions", "--json"));
    assert(ok("--login", "github-copilot") && ok("--list-models", "openai") && ok("--acp"));
    assert(!ok("--list-sessions", "--login", "github-copilot") && !ok("--list-sessions", "--list-models", "openai"));
    assert(!ok("--list-sessions", "--acp") && !ok("--acp", "--list-sessions"));
    assert(!ok("--resume", "--login", "github-copilot") && !ok("--login", "github-copilot", "--resume", "sess-1"));
    assert(!ok("--resume", "--trajectory", "sess-1") && !ok("--trajectory", "sess-1", "--resume"));
    assert(!ok("--resume", "--list-models", "openai") && !ok("--list-models", "openai", "--resume=sess-1"));
    assert(ok("--acp", "--resume", "sess-1"));
    assert(parseArgs(["nano-coder", "--resume", "sess-1"]).resume == "sess-1");
    auto bare = parseArgs(["nano-coder", "--resume"]);
    assert(bare.hasResume && bare.resume == "");
    assert(parseArgs(["nano-coder", "--resume=-sess"]).resume == "-sess");
    assert(!ok("--resume", "-sess"), "a dash-prefixed id needs the attached form");
}

/// `--login PROVIDER`: interactive device-flow sign-in.
int runLogin(string provider)
{
    import core.thread : Thread;
    import core.time : seconds;
    import std.functional : toDelegate;
    void delegate(string) @safe note = toDelegate((string s) { stdErr.writeln(s); });
    void delegate(long) @safe sleep = toDelegate((long n) { sleepFor(n.seconds); });
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
    import nano.session : validateId, findSession;
    import std.path : buildPath;
    static import nano.trajectory;
    try
    {
        validateId(id);
        auto t = nano.trajectory.load(findSession(sessionDir, id), id);
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
    stdErr.writeln("nano-coder: ", msg);
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
        // An explicit null marks the end: `tryTake` can't tell a closed
        // channel from an empty one, and the background poll uses it.
        if (line is null) { inbox.put(null); inbox.close(); return; }
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
string queueArgs(string text) pure
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
                return parseMode(arg).match!((m) {
                    control.mode = m;
                    return format("Mode set to %s (%s); applies from the agent's next step", m.name, m.describe);
                }, e => e);
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
                import nano.thinking : Thinking, sessionSetting;
                auto setting = sessionSetting(arg);
                if (setting.isErr) return format("[thinking: %s]", setting.unwrapErr("isErr"));
                auto check = setting.unwrap("isOk");
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
            if (name == "/subagents")
            {
                control.requestSubagents(arg == "on");
                return format("Sub-agents %s queued; applies from the agent's next model request (running sub-agents finish)", arg);
            }
            return null;
    }
}


/// The turn's key reader (its own thread): owns the line editor until
/// `*done`, then hands it back. Lines that wait for the turn go to `held`.
/// The idle-compaction hold: `idle_compact_hold_secs`, or the default.
imported!"core.time".Duration idleCompactHoldFor(const ref Config cfg) pure @safe
{
    import core.time : seconds;
    import nano.lineedit : idleCompactHold;
    return cfg.idleCompactHoldSecs > 0 ? cfg.idleCompactHoldSecs.seconds : idleCompactHold;
}

/// Whether the idle prompt runs a due idle compaction now: quiet for the
/// The working clock stops while a picker waits on the user, and resumes
/// when this guard leaves scope, however it leaves (Rust WorkClock::pause).
struct PickerPause
{
    private void delegate(bool) @safe set;
    @disable this(this);
    this(void delegate(bool) @safe set)
    {
        this.set = set;
        if (set) set(true);
    }
    ~this()
    {
        if (set) set(false);
    }
}

// rust: main.rs::the_work_clock_guard_brackets_a_picker
unittest
{
    bool[] seen;
    void record(bool p) @safe { seen ~= p; }
    {
        auto p = PickerPause(&record);
        assert(seen == [true], "a picker pauses the working clock");
    }
    assert(seen == [true, false], "leaving the scope resumes it");
    import std.exception : collectException;
    auto e = collectException({
        auto p = PickerPause(&record);
        throw new Exception("picker failed");
    }());
    assert(e.msg == "picker failed");
    assert(seen == [true, false, true, false], "an exception resumes it too");
    auto none = PickerPause(null); // no frame: nothing to pause
}

/// What of a model call's `full` answer still needs printing after `streamed`
/// (Rust's assistant-message reconciliation): the missing tail of a
/// cut-short stream; the whole answer (`fresh`: on its own line) when the
/// stream disagrees; nothing when it matched or nothing streamed (a quiet
/// stretch, whose answer the turn's end reprints).
string answerCatchUp(string streamed, string full, out bool fresh) pure nothrow @nogc
{
    import std.algorithm : startsWith;
    import std.string : strip, stripRight;
    fresh = false;
    // Whitespace at either end isn't a difference (providers trim the answer).
    import std.string : stripLeft;
    auto shown = streamed.stripLeft, answer = full.strip;
    if (!shown.length || shown.stripRight == answer) return null;
    if (answer.startsWith(shown)) return answer[shown.length .. $];
    fresh = true;
    return answer;
}

// rust: ui.rs::assistant_message_reconciles_a_partial_stream
unittest
{
    bool fresh;
    assert(answerCatchUp("Here ", "Here is the answer.", fresh) == "is the answer." && !fresh, "the missing tail");
    assert(answerCatchUp("answer.", "Here is the answer.", fresh) == "Here is the answer." && fresh,
        "a stream that disagrees is followed by the whole answer");
    assert(answerCatchUp("Here is the answer.", "Here is the answer.", fresh) is null && !fresh);
    assert(answerCatchUp("", "Here is the answer.", fresh) is null, "nothing streamed: nothing to reconcile");
    assert(answerCatchUp("\n Here is the answer.\n", "Here is the answer.", fresh) is null, "trimmed, not different");
    assert(answerCatchUp("Here ", "Here is", fresh) == "is");
}

/// What a finished plain turn reprints (Rust turn_print): nothing unless the
/// answer was hidden (quiet) or partly dropped (it got louder mid-answer);
/// then the final answer, or the whole response at the turn cap so its stop
/// note isn't lost with the dropped deltas.
string turnReprint(bool quiet, bool truncated, string finalAnswer, string response, bool maxTurns) pure nothrow @nogc
{
    if (!quiet && !truncated) return null;
    return maxTurns && response.length ? response : finalAnswer;
}

// rust: main.rs::turn_print_repairs_truncation_before_the_max_turn_fallback
unittest
{
    enum response = "full final answer\n[stopped after 3 LLM calls without a final answer]";
    assert(turnReprint(false, true, "full final answer", response, true) == response,
        "a truncated max-turn answer is reprinted in full, stop note included");
    assert(turnReprint(true, false, "full final answer", response, true) == response);
    assert(turnReprint(false, false, "full final answer", response, true) is null,
        "an untruncated answer was streamed (its stop note too)");
    assert(turnReprint(true, false, "answer", "answer", false) == "answer");
}

/// Whether a due timer runs now at the idle prompt (Rust deliver_due_timer):
/// a queued interrupt, a fresh draft and an armed Ctrl-C exit window each
/// hold it back (a timer firing mid-window would steal the second press).
bool deliverDueTimer(bool due, bool draftHolds, bool interruptQueued, bool exitArmed) pure nothrow @nogc
{
    return due && !draftHolds && !interruptQueued && !exitArmed;
}

// rust: main.rs::deliver_due_timer_yields_to_interrupt_and_draft
unittest
{
    assert(deliverDueTimer(true, false, false, false), "due, nothing else: fire");
    assert(!deliverDueTimer(true, false, true, false), "a queued interrupt beats a due timer");
    assert(!deliverDueTimer(true, true, false, false), "a fresh draft holds the timer back");
    assert(!deliverDueTimer(true, true, true, false));
    assert(!deliverDueTimer(true, false, false, true), "an armed exit window holds the timer back");
    assert(!deliverDueTimer(true, true, true, true));
    assert(!deliverDueTimer(false, false, false, false), "a timer that isn't due never fires");
    assert(!deliverDueTimer(false, false, true, false) && !deliverDueTimer(false, false, false, true));
}

/// Whether end of input waits for pending timers instead of ending the
/// session: only a headless `--wait-timers` run (its driver may close stdin
/// while the timers are the point); Ctrl-D at a terminal always exits (#150).
bool suppressEofForTimers(bool waitTimers, bool steerable) pure nothrow @nogc
{
    return waitTimers && !steerable;
}

// rust: main.rs::eof_suppression_is_headless_wait_timers_only
unittest
{
    assert(suppressEofForTimers(true, false), "headless --wait-timers suppresses EOF");
    assert(!suppressEofForTimers(true, true), "interactive EOF still exits under --wait-timers");
    assert(!suppressEofForTimers(false, false) && !suppressEofForTimers(false, true));
}

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
    // A command or text line typed during the turn (see `steerRoute`).
    void routeTurnLine(string text, Outcome outcome)
    {
        if (isCommand(text))
        {
            // Read-only commands and settings run now (turn_commands.rs).
            if (auto shown = midTurnCommand(text, mid))
            {
                console.note(shown);
                return;
            }
            held.put(text);
            stdErr.writeln(console.dim("[waits for the turn to finish: " ~ text ~ "]"));
        }
        else if (outcome == Outcome.queue)
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
    }
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
                    nano.herdr.report(nano.herdr.State.blocked, qs.length ? terminalSafe(qs[0].question) : null);
                    // The user's time at the picker isn't working time.
                    auto paused = PickerPause((bool p) @safe { if (gFrame) gFrame.pauseWork(p); });
                    bool delegate() @safe away = null;
                    if (mid.control.mode() == AgentMode.auto_)
                    {
                        // Auto mode: give the user a chance to answer, then
                        // answer for them (Rust's AUTO_AWAY_SECS).
                        console.note(format("[auto: answering for you in %ss — the user is away]", autoAwaySecs));
                        auto deadline = monoNow + autoAwaySecs.seconds;
                        away = () @safe => monoNow >= deadline;
                    }
                    auto answer = askQuestions(editor, qs, away);
                    if (answer.match!((Away _) => true, _ => false))
                        console.note("[auto: no answer — making the best decision]");
                    questions.resolve(answer);
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
                final switch (steerRoute(text, r.outcome == Outcome.line))
                {
                    case SteerRoute.ignore: break;
                    case SteerRoute.queueCommand:
                        // `/queue` only touches the queue, so it runs at once.
                        stdErr.writeln(console.dim(runQueueCommand(queue, gControl, queueArgs(text)[0 .. $ - 1])));
                        break;
                    case SteerRoute.command, SteerRoute.enqueue, SteerRoute.steer:
                        routeTurnLine(text, r.outcome);
                        break;
                }
                break;
        }
    }
}

/// Where a line typed during a turn goes (Rust classify_steer_input): `/queue`
/// edits run at once on either key; other commands run now or wait
/// (`midTurnCommand`); text steers on Enter and queues on Ctrl-Enter.
enum SteerRoute { ignore, queueCommand, command, enqueue, steer }

SteerRoute steerRoute(string text, bool steer) pure
{
    if (!text.length) return SteerRoute.ignore;
    if (queueArgs(text) !is null) return SteerRoute.queueCommand;
    if (isCommand(text)) return SteerRoute.command;
    return steer ? SteerRoute.steer : SteerRoute.enqueue;
}

// rust: main.rs::classify_steer_input_routes_line_queue_and_commands
// rust: main.rs::slash_escaped_lines_steer_or_queue_instead_of_deferring
unittest
{
    with (SteerRoute)
    {
        assert(steerRoute("keep going", true) == steer && steerRoute("keep going", false) == enqueue);
        assert(steerRoute("/thinking off", true) == command && steerRoute("/thinking", true) == command);
        assert(steerRoute("/queue add hello", true) == queueCommand && steerRoute("/queue add hello", false) == queueCommand);
        assert(steerRoute("/help", true) == command && steerRoute("/model", false) == command);
        assert(steerRoute("", true) == ignore && steerRoute("", false) == ignore);
        assert(steerRoute("//usr/lib is big", true) == steer && steerRoute("//usr/lib is big", false) == enqueue);
        assert(steerRoute("/plan", true) == command);
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
    if (channel != Channel.other)
    {
        auto latest = new Checker(channel, defaultStatePath(), packageVersion).check(true);
        if (latest.length && !isNewer(latest, packageVersion))
        {
            writefln("nano-coder is up to date (%s)", latest);
            return;
        }
    }
    string[] lines;
    {
        stdOut.flush();
        if (gFrame) gFrame.suspend();
        leaveKeyMode();
        scope (exit) { enterKeyMode(0); if (gFrame) gFrame.resume(); }
        lines = runInstaller(channel, launchExe(), packageVersion, (string p, string[] a, const string[string] e) @safe => spawnInstaller(p, a, e));
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

/// Builds sub-agents' clients (on their threads) from a frozen config.
final class ConfigClients : imported!"nano.subagent".SubClientFactory
{
    private Config cfg;
    this(immutable Config cfg) immutable { this.cfg = cfg; }
    LLMClient make(string spec) const { return makeClient(resolve(cfg, spec)); }
}

/// Give `agent` sub-agents from `cfg`: clients from a frozen copy (so
/// `/subagents on` works even when the config starts them off), the limits,
/// and the `[[subagent_models]]` that resolve (each one that doesn't is
/// reported on stderr when `report`: at startup, not on the later
/// re-runs after a provider edit).
void configureSubagents(Agent agent, const ref Config cfg, bool report)
{
    import nano.subagent : SubLimits, SubCandidate;
    import nano.arith : toSize;
    import nano.config : usableSubagentModels;
    agent.subagentClients = new immutable ConfigClients(frozenConfig(cfg));
    agent.subagentModel = cfg.subagentModel;
    agent.subagentMaxConcurrency = cfg.subagentMaxConcurrency > 0 ? toSize(cfg.subagentMaxConcurrency) : 1;
    SubLimits lim;
    if (cfg.subagentTimeoutSecs > 0) lim.timeoutSecs = cfg.subagentTimeoutSecs;
    if (cfg.subagentMaxTurns > 0) lim.turns = toSize(cfg.subagentMaxTurns);
    if (cfg.subagentMaxTokens > 0) lim.tokens = cfg.subagentMaxTokens;
    agent.subagentLimits = lim;
    string[] warnings = cfg.warnings.dup;
    immutable(SubCandidate)[] cands;
    foreach (m; usableSubagentModels(cfg, warnings))
    {
        auto l = lim;
        if (m.timeoutSecs > 0) l.timeoutSecs = m.timeoutSecs;
        if (m.maxTurns > 0) l.turns = toSize(m.maxTurns);
        if (m.maxTokens > 0) l.tokens = m.maxTokens;
        cands ~= SubCandidate(m.model, m.use, l);
    }
    agent.subagentCandidates = cands;
    if (report) foreach (w; warnings) stdErr.writeln("nano-coder: warning: ", terminalSafe(w));
}

/// Write `subagents = on` into the user config file; says where, or why
/// it could not.
string saveSubagentsSetting(ref Config cfg, bool on)
{
    import nano.settings : Changes, save;
    cfg.subagents = on;
    Changes ch;
    ch.subagents = true;
    try save(cfg, ch, null, cfg.path);
    catch (Exception e) return "could not save: " ~ e.msg;
    return "saved to " ~ cfg.path;
}

/// Run `/subagents [on|off] [--save]` on `agent`: show the state, or switch
/// the `agent` tool for the session (and the user config with `--save`).
string subagentsCommand(Agent agent, ref Config cfg, string arg)
{
    import nano.subagent : parseToggle, statusText;
    import nano.result : unwrap, unwrapErr;
    auto p = parseToggle(arg);
    if (p.isErr) return p.unwrapErr("isErr");
    auto t = p.unwrap("isOk");
    auto model = agent.subagentModel.length ? agent.subagentModel : agent.client.providerName ~ "/" ~ agent.client.modelName;
    if (t.show) return statusText(agent.subagentsOffered, agent.subagentCandidates, model, agent.subagentLimits);
    if (!agent.subagentsEnabled) return "Sub-agents are not available in this session";
    agent.control.takeSubagentsRequest(); // a direct switch supersedes a queued one
    auto was = agent.subagentsOn;
    agent.subagentsOn = t.on;
    auto msg = format("Sub-agents %s for this session", t.on ? "on" : "off");
    if (was != t.on) msg ~= " (the tool list changed, so the provider's prompt cache is rebuilt once)";
    if (t.save) msg ~= "; " ~ saveSubagentsSetting(cfg, t.on);
    return msg;
}

/// A frozen copy of `cfg`, for another thread.
immutable(Config) frozenConfig(const ref Config cfg) pure
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
            labels ~= opt.description.length ? terminalSafe(opt.label) ~ " — " ~ terminalSafe(opt.description)
                : terminalSafe(opt.label);
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
    this(LineEditor e) pure { this.e = e; }

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
    return formatStamp(color, wallNow);
}

private string formatStamp(T)(bool color, T t)
{
    auto s = format("%02d:%02d:%02d", t.hour, t.minute, t.second);
    return color ? "\x1b[2m" ~ s ~ "\x1b[0m " : s ~ " ";
}

/// The stamp for a saved message's RFC 3339 `timestamp`, in local time; the
/// current time when it is missing or unreadable (sessions from before
/// timestamps were logged).
string stampAt(bool color, string timestamp)
{
    import std.datetime.systime : SysTime;
    if (!atomicLoad(gTimestamps)) return "";
    if (timestamp.length)
        try return formatStamp(color, SysTime.fromISOExtString(timestamp).toLocalTime);
        catch (Exception) {} // malformed: fall back to now
    return stamp(color);
}

unittest
{
    import std.datetime.systime : SysTime;
    auto was = atomicLoad(gTimestamps);
    scope (exit) atomicStore(gTimestamps, was);
    atomicStore(gTimestamps, true);
    auto t = SysTime.fromISOExtString("2026-01-02T03:04:05.250+13:00").toLocalTime;
    assert(stampAt(false, "2026-01-02T03:04:05.250+13:00") == format("%02d:%02d:%02d ", t.hour, t.minute, t.second));
    assert(stampAt(false, "garbage").length == 9);
    assert(stampAt(false, "").length == 9);
}

/// `text` with `stamp` before the first line and its width in spaces before the rest.
string stampBlock(string stamp, string text) pure
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

private string spaces(size_t n) pure { import std.array : replicate; return " ".replicate(n); }
Verbosity verbosity() { return atomicLoad(gVerbosity); }
/// The built-in tools every session offers: bash, the file tools and
/// search (`deny` hides read-denied paths from search results).
void registerBuiltinTools(ToolRegistry tools, const ref Config cfg, ReadState readState, DenyScan deny,
    DenyRules denyRules = null)
{
    auto bashTimeout = cfg.bashTimeoutSecs;
    auto sandbox = cfg.sandbox;
    tools.register(bashDefinition(bashTimeout), (JSONValue a) => bashExecute(a, bashTimeout, sandbox));
    registerFiles(tools, readState);
    registerSearch(tools, deny, denyRules);
}

// rust: main.rs::builtin_tools_include_search_and_no_echo
unittest
{
    import std.algorithm : canFind, map;
    import std.array : array;
    Config c;
    auto reg = new ToolRegistry;
    registerBuiltinTools(reg, c, new ReadState, (string root) @safe => Denied.init);
    auto names = reg.definitions.map!(d => d.name).array;
    assert(names.canFind("grep") && names.canFind("glob") && names.canFind("bash") && names.canFind("edit_file"));
    assert(!names.canFind("echo"), "no vestigial echo tool");
}

void setVerbosity(Verbosity v)
{
    atomicStore(gVerbosity, v);
    // Existing tool results and thoughts follow the switch, not just new ones.
    if (auto f = gFrame) f.setVerbose(v >= Verbosity.verbose);
}

// What the frame's status bar shows (status.rs).
import nano.status : Stats, Activity, RateMeter;
import nano.paths : tildePath;
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
    import nano.frame : fit;
    string rows;
    if (stats.subagents.length)
    {
        import nano.subagent : progressLine;
        import nano.trajectory : terminalSafe;
        // Formatted now, not when the child last reported: the elapsed time
        // moves during a long model request that sends no progress.
        auto now = monoNow;
        foreach (ref l; stats.subagents)
        {
            auto p = l.at(now);
            rows ~= fit("\x1b[2m  " ~ terminalSafe(progressLine(p)) ~ "\x1b[0m", width ? width : 1) ~ "\n";
        }
    }
    return rows ~ renderStatus(stats, width);
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
    if (!gStatusBatched) gFrame.redraw();
}

/// Set while a transcript replays: status changes still land in `gStats`
/// but skip the redraw (each copies the whole retained transcript), so a
/// tool-heavy resume redraws once, at the final idle reset.
bool gStatusBatched;

/// The agent's side of the status line: model, context, plan, mode, tokens.

/// The console's line state (what's on the current line, the thinking
/// block, held-back markdown). It lives in a `Shared` cell, so the main
/// thread and the turn's key reader print through the same state, one at a
/// time.
/// Raw model text is neutralised only when it lands in the frame
/// transcript, where its control bytes could forge marks; piped
/// (non-frame) output keeps the model's bytes verbatim.
string rawShownIn(string text, bool framed)
{
    return framed ? rawModelText(text) : text;
}

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
    // The model call's finished thinking block (its fold id and how long it
    // thought), and reasoning streamed after its answer started: that joins
    // the block instead of opening a second one that splits the answer.
    private string thinkId;
    private long thinkMs, lateStart, lateMs;
    private bool late, thoughtThisCall;
    private string lateText;
    private static size_t thinkSeq;
    // The answer text streamed since the model call began (for `reconcile`).
    private string streamedAnswer;
    // Answers on a color terminal have their markdown rendered a block at a
    // time (markdown.rs MarkdownStream); piped and NO_COLOR output keep it raw
    // (sanitised by `rawShown` only inside the frame).
    private MarkdownStream markdown;
    bool verbose() const { return verbosity >= Verbosity.verbose; }
    bool renderMarkdown() pure const { return tty && color; }
    string rawShown(string text)
    {
        bool framed = (gFrame ? true : false);
        version (unittest) framed = framed || testFrame;
        return rawShownIn(text, framed);
    }

    // Tests capture the output here, as the frame transcript would see it.
    version (unittest) private string captured;
    version (unittest) private bool capturing;
    version (unittest) private bool testFrame;
    private bool framed() { version (unittest) if (testFrame) return true; return !!gFrame; }
    private void write(Args...)(Args args)
    {
        version (unittest) if (capturing) { import std.conv : text; captured ~= text(args); return; }
        .write(args);
    }
    private void writeln(Args...)(Args args) { write(args, "\n"); }

    /// Prints any streamed markdown still held back (the answer segment
    /// ended, or the turn stopped mid-block).
    private void flushMarkdown()
    {
        if (!markdown.holding) return;
        auto rest = markdown.finish(answerWidth());
        if (rest.length) writeAligned(rest, answerPad());
    }

    string stamp() { return .stamp(color); }
    string dim(string s) pure { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }

    /// Writes `t` with every line that starts here indented by `pad`.
    private void writeAligned(string t, size_t pad)
    {
        import std.algorithm : splitter;
        import std.array : replicate;
        // Soft-wrap marks are for the frame; anything else gets plain text.
        if (!framed) t = dropSoftWraps(t);
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
        return monoNow.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    private string thinkStyle(string s) pure { return color ? "\x1b[38;5;245m" ~ s ~ "\x1b[0m" : s; }

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
            // The frame folds the reasoning (its verbose mode expands the
            // fold), so Ctrl-O and a verbosity switch can collapse it.
            blockExpanded = verbose && !gFrame;
            if (blockExpanded) write(blockStamp ~ thinkStyle("∴ Thinking") ~ "\n");
        }
        bool first = !thinkText.length;
        thinkText ~= chunk;
        if (blockExpanded)
        {
            auto t = first ? chunk.stripLeft : chunk;
            if (t.length) writeAligned(thinkStyle(escapeMarks(rawShown(t))), blockStamp.length ? stampWidth : 0);
        }
        stdOut.flush();
    }

    private string thoughtLine(long ms, string text)
    {
        import std.string : strip;
        import std.range : walkLength;
        return blockStamp ~ thinkStyle(format("∴ Thought for %.1fs", ms / 1000.0))
            ~ dim(format(" · %s chars", text.strip.walkLength));
    }

    private void finishThinking()
    {
        import std.conv : to;
        if (!thinking) return;
        thinking = false;
        thinkMs = nowMs() - thinkStart;
        thinkId = null;
        thoughtThisCall = true;
        if (blockExpanded)
        {
            if (midLine) write("\n");
        }
        else
        {
            auto line = thoughtLine(thinkMs, thinkText);
            write(line ~ "\n");
            // Ctrl-O shows the reasoning under the summary.
            if (framed)
            {
                // Its own id, so reasoning that streams after the answer can rewrite it.
                thinkId = "think-" ~ (++thinkSeq).to!string;
                write(foldMark(thinkId, 1, line ~ "\n" ~ expandedBody(thinkText, color ? "\x1b[38;5;245m" : "")));
            }
        }
        midLine = false;
        stdOut.flush();
    }

    /// Reasoning that arrives after this call's thinking block closed and
    /// its answer began: held back, so the answer is not split.
    private bool lateReasoning(string chunk)
    {
        import std.string : strip;
        // The call-lifetime flag, not `answering`: a mid-turn note clears
        // `answering` without ending the call.
        if (thinking || !thoughtThisCall) return false;
        // Whitespace is kept as a separator, but alone opens nothing.
        lateText ~= chunk;
        if (!late && !chunk.strip.length) return true;
        late = true;
        if (!lateStart) lateStart = nowMs();
        return true;
    }

    /// Joins held-back reasoning to the call's thinking block. The frame
    /// rewrites the block in place; an append-only console (or an expanded
    /// block already printed) shows it after the answer instead.
    private void mergeLate()
    {
        if (!late) { lateText = null; return; }
        if (lateStart) { thinkMs += nowMs() - lateStart; lateMs += nowMs() - lateStart; }
        immutable lateFor = lateMs;
        late = false;
        lateStart = 0;
        lateMs = 0;
        auto rest = lateText;
        lateText = null;
        if (framed && thinkId.length)
        {
            thinkText ~= rest;
            auto line = thoughtLine(thinkMs, thinkText);
            write(refoldMark(thinkId, line ~ "\n", line ~ "\n" ~ expandedBody(thinkText, color ? "\x1b[38;5;245m" : "")));
            stdOut.flush();
            return;
        }
        flushMarkdown();
        if (midLine) write("\n");
        midLine = false;
        answering = false;
        thinkingDelta(rest);
        // Time the late reasoning as it streamed, not this replay.
        thinkStart = nowMs() - lateFor;
        finishThinking();
    }

    /// A streamed chunk of reasoning or answer.
    void text(bool reasoning, string chunk)
    {
        if (reasoning)
        {
            import std.string : strip;
            // Blank reasoning opens no block and doesn't count as streamed:
            // the call's full reasoning still shows at its end.
            if (lateReasoning(chunk)) { if (late) streamedThinking = true; return; }
            if (!thinking && !chunk.strip.length) return;
            streamedThinking = true;
            thinkingDelta(chunk);
            return;
        }
        if (!chunk.length) return;
        streamedAnswer ~= chunk;
        if (late && lateStart) { thinkMs += nowMs() - lateStart; lateMs += nowMs() - lateStart; lateStart = 0; }
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
        auto shown = renderMarkdown ? markdown.push(chunk, answerWidth()) : rawShown(chunk);
        if (shown.length) writeAligned(shown, answerPad());
        stdOut.flush();
    }

    void note(string text)
    {
        flushMarkdown();
        if (midLine) write("\n");
        midLine = false;
        answering = false;
        writeln(stampBlock(stamp(), escapeMarks(text)));
        stdOut.flush();
    }

    void endLine()
    {
        finishThinking();
        flushMarkdown();
        mergeLate();
        // The call is over: its thinking block is closed, so reasoning from a
        // later call never refolds it.
        thinkId = null;
        thoughtThisCall = false;
        if (midLine) writeln();
        midLine = false;
        answering = false;
    }

    /// The model call's full answer: what the stream missed shows now. A
    /// cut-short stream gets its missing tail; one that disagrees with the
    /// answer is followed by the whole answer on a line of its own.
    void reconcile(string full)
    {
        bool fresh;
        auto rest = answerCatchUp(streamedAnswer, full, fresh);
        streamedAnswer = null;
        if (!rest.length) return;
        if (fresh) endLine();
        text(false, rest);
        streamedAnswer = null;
    }

    /// A resent reply follows: what streamed before is abandoned.
    void restart() pure
    {
        streamedAnswer = null;
        late = false;
        lateText = null;
        lateStart = 0;
        lateMs = 0;
        thinkId = null;
        thoughtThisCall = false;
    }

    /// The model call ended: reasoning that didn't stream shows now, like a
    /// block that just ended.
    void endReasoning(string reasoning)
    {
        flushMarkdown();
        mergeLate();
        if (!streamedThinking && reasoning.length && !thinking) thinkingDelta(reasoning);
        finishThinking();
        streamedThinking = false;
        thinkId = null;
        thoughtThisCall = false;
    }
}

// rust: ui.rs::trailing_thinking_never_overwrites_previous_response_reasoning
unittest
{
    Screen s;
    s.text(true, "  ");
    assert(!s.thinking && !s.streamedThinking, "blank reasoning must not hide the call's full reasoning");
}

// A call ended by endLine (restart, quiet reply, interrupted call) closes
// its thinking block: the next call's late reasoning gets its own block.
unittest
{
    import std.algorithm : canFind, filter;
    import std.array : array;
    import std.string : representation;
    import std.conv : to;
    import nano.frame : Transcript;
    Screen s;
    s.capturing = true;
    s.testFrame = true;
    s.text(true, "x");
    s.text(false, "A");
    s.endLine();
    s.text(false, "B");
    s.text(true, "y");
    s.endReasoning("y");
    Transcript t;
    t.feed(s.captured.representation);
    auto thoughts = t.lines.filter!(l => l.canFind("Thought for")).array;
    assert(thoughts.length == 2, t.lines.to!string);
    assert(thoughts[0].canFind("1 chars") && thoughts[1].canFind("1 chars"), t.lines.to!string);
}

// A mid-turn note doesn't end the call: late reasoning still joins its
// block, and whitespace-only deltas survive as separators.
unittest
{
    import std.algorithm : canFind, filter;
    import std.array : array;
    import std.string : representation;
    import std.conv : to;
    import nano.frame : Transcript;
    Screen s;
    s.capturing = true;
    s.testFrame = true;
    s.text(true, "first");
    s.text(false, "A");
    s.note("mode changed");
    s.text(true, " ");
    s.text(true, "\n");
    s.text(true, "second");
    s.text(false, "B");
    s.endReasoning("first \nsecond");
    Transcript t;
    t.feed(s.captured.representation);
    auto thoughts = t.lines.filter!(l => l.canFind("Thought for")).array;
    assert(thoughts.length == 1 && thoughts[0].canFind("13 chars"), t.lines.to!string);
}

// rust: ui.rs::trailing_thinking_merges_interleaved_reasoning_fragments
unittest
{
    import std.algorithm : canFind, count, endsWith, filter;
    import std.array : array;
    import std.string : representation;
    import nano.frame : Transcript;
    import std.conv : to;
    import std.string : lastIndexOf;
    // The frame: reasoning after the answer started rewrites the reply's one
    // thinking block, and the answer stays contiguous.
    Screen s;
    s.capturing = true;
    s.testFrame = true;
    s.text(true, "first ");
    s.text(false, "A");
    s.text(true, "second");
    s.text(false, "B");
    s.endReasoning("first second");
    Transcript t;
    t.feed(s.captured.representation);
    auto thoughts = t.lines.filter!(l => l.canFind("Thought for")).array;
    assert(thoughts.length == 1 && thoughts[0].canFind("12 chars"), t.lines.to!string);
    assert(t.cur.endsWith(" AB") || t.cur == "AB", t.cur);
    assert(t.toggle());
    assert(t.lines.canFind("    first second"), t.lines.to!string);
    // A later answer chunk carries on the same line.
    s.captured = null;
    s.text(false, "C");
    t.feed(s.captured.representation);
    assert(t.cur.endsWith(" ABC") || t.cur == "ABC", t.cur);

    // An append-only console: the answer is not split either; the late
    // reasoning shows after it.
    Screen p;
    p.capturing = true;
    p.text(true, "first ");
    p.text(false, "A");
    p.text(true, "second");
    p.text(false, "B");
    p.endReasoning("first second");
    auto out_ = p.captured;
    assert(out_.canFind("AB\n") && out_.count("Thought for") == 2, out_);
    assert(out_.indexOf("AB") < out_.lastIndexOf("Thought for"), out_);
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
    string dim(string s) pure { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }
    /// A line of its own, mid-stream or not (the live thinking line redraws below it).
    void note(string text) { screen.update((ref Screen s) { s.note(text); }); }
    void endLine() { screen.update((ref Screen s) { s.endLine(); }); }
}

class Console : AgentEvents
{
    mixin AgentEventDefaults;
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
    /// Whether the answer segment streaming now, or the last one closed,
    /// had deltas dropped while quiet. Per segment (ui.rs truncation
    /// guard): a suppressed intermediate answer doesn't make a final answer
    /// that streamed in full reprint.
    bool droppedAnswer;
    private bool segmentDropped;

    /// A new turn: nothing dropped yet.
    void beginAnswerGuard() pure { droppedAnswer = segmentDropped = false; }

    /// Whether the turn's final answer has to be printed again at the end.
    bool answerMayBeTruncated() pure const { return segmentDropped || droppedAnswer; }
    bool renderMarkdown() pure const { return tty && color; }

    /// A whole answer as shown on this console: markdown rendered for a
    /// color terminal, verbatim otherwise.
    string display(string text)
    {
        if (!renderMarkdown) return rawShownIn(text, (gFrame ? true : false));
        auto shown = renderMarkdownText(text, answerWidth());
        return gFrame ? shown : dropSoftWraps(shown);
    }

    /// While replaying a saved session: the message's own timestamp, so
    /// replayed lines carry their original time.
    string replayTime;
    string stamp() { return replayTime.length ? stampAt(color, replayTime) : .stamp(color); }

    this(bool color, bool tty = false)
    {
        this.color = color;
        this.tty = tty;
        link = ConsoleLink(Shared!Screen.make(Screen(color, tty)), color);
    }

    private static long nowMs()
    {
        import core.time : MonoTime;
        return monoNow.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    string dim(string s) pure { return color ? "\x1b[2m" ~ s ~ "\x1b[0m" : s; }
    string bold(string s) pure { return color ? "\x1b[1m" ~ s ~ "\x1b[0m" : s; }
    string red(string s) pure { return color ? "\x1b[31m" ~ s ~ "\x1b[0m" : s; }

    private RateMeter meter;

    void text(bool reasoning, string chunk)
    {
        if (gFrame)
        {
            auto rate = meter.record(chunk.length, nowMs);
            if (rate > 0) updateStatus((ref Stats s) { if (s.activity == Activity.thinking) s.tokensPerSec = rate; });
        }
        // An answer delta belongs to a new segment: the closed one's guard ends.
        if (!reasoning && chunk.length) droppedAnswer = false;
        if (quiet)
        {
            if (!reasoning && chunk.length) segmentDropped = true;
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
        import nano.trajectory : terminalSafe;
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
        auto line = stamp() ~ (color ? "\x1b[38;5;114m●\x1b[0m " : "● ") ~ bold(escapeMarks(terminalSafe(call.name))) ~ " " ~ dim(terminalSafe(summary(call)));
        writeln(line);
        // Ctrl-O shows the full arguments under the call.
        if (gFrame) write(foldMark(call.id, 1, line ~ "\n" ~ expandedBody(sanitizeBlock(argsText(call)), color ? "\x1b[2m" : "")));
        stdOut.flush();
    }

    private imported!"nano.status".LiveSubagent[string] subRows;
    /// Sub-agents: a live row per running one (above the status bar); each prints a
    /// line when it finishes (the `agent` result follows in call order).
    void subagents(const imported!"nano.subagent".SubProgress[] all)
    {
        import nano.subagent : progressLine;
        import nano.trajectory : terminalSafe;
        import nano.status : LiveSubagent;
        // Rows for the running ones (frame renderer), kept by call id; a
        // finished one collapses to its line in the transcript.
        foreach (ref p; all)
        {
            // The session-unique handle: provider call ids can repeat.
            string id = p.handle.length ? p.handle : p.callId;
            if (p.done) subRows.remove(id);
            else subRows[id] = LiveSubagent(p, monoNow);
        }
        import std.algorithm : sort;
        immutable(LiveSubagent)[] rows;
        foreach (id; subRows.keys.sort) rows ~= subRows[id];
        auto label = rows.length ? format("agent ×%s", rows.length) : "agent";
        updateStatus((ref Stats s) { s.tool = label; s.subagents = rows; });
        if (quiet) return;
        foreach (ref p; all)
            if (p.done)
            {
                endLine();
                writeln(stamp() ~ "  " ~ dim(terminalSafe(progressLine(p))));
            }
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
        {
            // A plan tool's result is the rendered plan: show its marks as symbols.
            import std.algorithm.searching : startsWith;
            import nano.plan : planSymbols;
            if (renderMarkdown && call.name.startsWith("plan_")) clean = planSymbols(clean);
        }
        auto shown = stampBlock(st, toolResult(!isError, clean, verbose && !gFrame, w > 8 + st.length ? w - 8 - (st.length ? stampWidth : 0) : 1));
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
        writeln(stampBlock(stamp(), dim("↪ " ~ escapeMarks(text))));
    }
    /// Close the abandoned partial so the resent reply starts a fresh segment
    /// instead of joining the stale prefix.
    /// The previous generation's rate is stale once the next one starts
    /// (a steer continues the turn without going idle); the meter's clock
    /// starts here so a one-shot reply is rated over the whole call.
    void generationStart()
    {
        meter.reset(nowMs);
        if (gFrame) updateStatus((ref Stats s) { s.tokensPerSec = 0; });
    }

    void responseRestarted()
    {
        segmentDropped = false;
        link.screen.update((ref Screen s) { s.restart(); });
        if (!quiet) endLine();
    }

    void assistantMessage(string text, string reasoning)
    {
        finalAnswer = text;
        // The segment closes: its guard is the turn's until the next one.
        droppedAnswer = segmentDropped;
        segmentDropped = false;
        // Quiet still closes a segment that streamed before the switch, so
        // the next answer starts its own line (ui.rs).
        if (quiet)
        {
            link.screen.update((ref Screen s) { s.restart(); });
            endLine();
            return;
        }
        link.screen.update((ref Screen s) { s.reconcile(text); s.endReasoning(reasoning); });
    }

    /// One-line call summary; literal wrap marks in model-supplied
    /// arguments are escaped so they cannot forge transcript metadata.
    static string summary(const ref ToolCall c)
    {
        return escapeMarks(rawSummary(c));
    }

    private static string rawSummary(const ref ToolCall c)
    {
        if (c.invalidArguments.length) return "(invalid arguments)";
        foreach (k; ["command", "path", "pattern", "text", "name", "id"])
            if (auto v = k in c.arguments)
                if (v.type == JSONType.string)
                {
                    // One line: runs of whitespace (newlines too) become a space.
                    import std.regex : regex, replaceAll;
                    return fitText(v.str.replaceAll(regex(`\s+`), " ").strip, 121);
                }
        if (c.arguments.type == JSONType.object && c.arguments.jsonText == "{}") return "";
        return c.encodedArguments;
    }
}

/// A tool result as Rust's `tool_result`: `⎿ first line (+N lines)` (red
/// `⎿ error:` for failures); verbose shows up to ten lines.
string toolResult(bool ok, string output, bool verbose, size_t width, bool color = true) pure
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
            text ~= format("  %s  %s%s\n", color ? "\x1b[2m" : "",
                fitText(format("… +%s lines", lines.length - previewLines), width), off);
        return text;
    }
    auto more = lines.length > 1 ? format(" (+%s lines)", lines.length - 1) : "";
    // The count is cut too when the width can't hold it (a narrow pane).
    auto row = fitText(fitText(lines[0].stripRight("\r"), saturatingSub(width, more.length)) ~ more, width);
    return format("  %s%s %s%s\n", on, mark, row, off);
}

// rust: frame.rs::tool_result_count_rows_are_bounded_to_the_width
// rust: frame.rs::tool_result_preview_strips_terminal_escapes
// rust: ui.rs::plain_tool_result_strips_terminal_escapes
unittest
{
    import std.algorithm : canFind;
    import std.array : join;
    import std.conv : to;
    import std.algorithm : map;
    import std.range : iota;
    import std.string : lineSplitter;
    import nano.frame : visibleWidth;
    // The caller passes the width left after the `  ⎿ ` prefix (4 cells).
    auto output = iota(40).map!(i => "line " ~ i.to!string).join("\n");
    foreach (width; 3 .. 24)
        foreach (verbose; [false, true])
            foreach (line; toolResult(true, output, verbose, width).lineSplitter)
                assert(visibleWidth(line) <= width + 4, line);
    auto shown = toolResult(true, sanitizeBlock("note \x1b]0;pwned\x07 \x1b[2J done"), true, 120, false);
    assert(!shown.canFind('\x1b') && !shown.canFind('\x07'), shown);
    assert(shown.canFind("note") && shown.canFind("done"), shown);
}

/// A tool call's arguments as shown expanded: pretty JSON, or the raw text
/// when the model's arguments weren't a JSON object.
string argsText(const ref ToolCall c) pure
{
    if (c.invalidArguments.length) return c.invalidArguments;
    if (c.arguments.type == JSONType.object && c.arguments.jsonText == "{}") return "";
    return c.arguments.jsonPretty;
}

/// `text` cut to `width` characters, ending in `…` when cut.
string fitText(string text, size_t width) pure
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
ConfiguredWindow windowFor(const ref Config c, const ref ProviderConfig p) pure
{
    if (c.contextWindow > 0) return ConfiguredWindow(toSize(c.contextWindow), "context_window in config");
    if (p.contextWindow > 0) return ConfiguredWindow(toSize(p.contextWindow), "provider context_window");
    return ConfiguredWindow.init;
}

/// Untrusted multi-line text for the terminal: lines kept, every other
/// control character (so any escape sequence) dropped, tabs expanded.
string sanitizeBlock(string s) pure
{
    import std.encoding : sanitize;
    import nano.trajectory : terminalSafe;
    // Repair malformed UTF-8 first: terminalSafe decodes and would throw.
    return terminalSafe(sanitize(s), true);
}

/// The longest prefix of `s` of at most `max` bytes that does not end
/// inside a UTF-8 sequence, so a byte cap never splits a character.
string utf8Prefix(string s, size_t max) pure nothrow @nogc
{
    if (s.length <= max) return s;
    size_t n = max;
    while (n > 0 && (s[n] & 0xC0) == 0x80) --n;
    return s[0 .. n];
}

size_t lineCount(string s) pure
{
    import std.algorithm : count;
    return s.length ? s.count('\n') + (s[$ - 1] == '\n' ? 0 : 1) : 0;
}

string firstLine(string s) pure
{
    auto nl = s.indexOf('\n');
    auto l = nl >= 0 ? s[0 .. nl] : s;
    return l.length > 160 ? utf8Prefix(l, 160) ~ "…" : l;
}

unittest
{
    import std.array : replicate;
    import std.utf : validate;
    // A byte cap landing inside a multi-byte character must not split it.
    auto l = firstLine("a".replicate(159) ~ "é tail");
    validate(l);
    assert(l == "a".replicate(159) ~ "…");
    validate(indent("b".replicate(1999) ~ "€x"));
    // Malformed input is repaired, not thrown on.
    assert(sanitizeBlock("ok \xC3") .length > 0);
    assert(utf8Prefix("é", 1) == "");
}

string indent(string s) pure
{
    import std.array : replace;
    auto t = s.length > 2000 ? utf8Prefix(s, 2000) ~ "\n…" : s;
    return "    " ~ t.replace("\n", "\n    ");
}

alias planNote = planPromptNote;
import nano.system_prompt : buildSystemPrompt;


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

/// `/tools`: one line per tool, sanitized here so every caller (the idle
/// command and the mid-turn view) prints no raw control sequences.
string toolsListing(Agent agent) pure { return sanitizeBlock(agent.toolsListing); }

/// `/skills`: one line per skill, sanitized here for the same reason as
/// `toolsListing` (skill names and descriptions come from files on disk).
string skillsListing(const Skills skills) pure
{
    if (skills.empty) return "No skills found.";
    string[] out_;
    foreach (sk; skills.skills) out_ ~= format("  %-20s %s", sk.name, firstLine(sk.description));
    return sanitizeBlock(out_.join("\n"));
}

unittest
{
    import std.algorithm.searching : canFind;
    import nano.skills : Skill;
    // The mid-turn view stores the listing as-is, so it must already be clean.
    auto sk = new Skills;
    sk.skills ~= Skill("evil\x1b]0;t\x07", "desc \x1b[2J here", "/x");
    auto listed = skillsListing(sk);
    assert(!listed.canFind('\x1b') && !listed.canFind('\x07'), listed);
    assert(listed.canFind("here"));
}

string sessionText(Agent agent) pure
{
    return agent.log.match!(l => format("session %s\nlog: %s", l.id, l.path), () => "not recording (--no-session)");
}

/// `/timers`: the agent's active timers.
string timersText(Agent agent)
{
    return agent.timers.empty ? "No timers set. The agent sets one with the timer_set tool."
        : agent.timers.list(agent.timerNow(), true).stripRight;
}

/// Transparent to an output-limit continuation: system messages
/// (compaction), timer firings/nudges and hook-only context are not user
/// input, so one between a reminder and the reply keeps the accumulated
/// answer. Shared by replayAnswerQuiet (forward walk) and replayTranscript
/// (backward walk) so the two cannot drift apart.
bool replayTransparent(const ref Message x) pure nothrow @safe
{
    return x.role == Role.system || (x.role == Role.user && (x.hookContext || (x.timer && !x.continuation)));
}

/// What of an assistant message a quiet replay shows (Rust ui.rs quiet
/// mode): live, an answer's deltas stream only while nothing supersedes
/// them — a tool call or a Stop-hook rejection hides them, and an
/// output-limit chunk a later tool call discarded never prints. A replay
/// sees whole messages, so the same rule is: nothing with tool calls,
/// nothing a rejection supersedes, and of an output-limit continuation
/// only the chunks that stood — a chunk a continuation carried into the
/// segment's accepted answer shows there, one a tool call or rejection
/// discarded doesn't.
string replayAnswerQuiet(const Message[] msgs, size_t i) pure nothrow @safe
{
    import nano.llm : isLengthStop;
    const m = msgs[i];
    if (m.toolCalls.length || stopRejected(msgs, i)) return null;
    if (!isLengthStop(m.stopReason)) return m.content;
    // A cut-off chunk: the continuation reminder carries the answer on.
    size_t k = i + 1;
    while (k < msgs.length && replayTransparent(msgs[k])) k++;
    // The log cut short on the chunk (a crash before the reminder): it was
    // the turn's visible tail, so it shows.
    if (k >= msgs.length) return m.content;
    // No reminder: the request/continuation budget ran out and the turn
    // finished on the cut-off chunk, which stood — unless a steer or a
    // rejection superseded it (stopRejected above already covers those).
    if (msgs[k].role == Role.user && !msgs[k].continuation) return m.content;
    if (msgs[k].role != Role.user) return null;
    // A chunk resolves to the accepted answer from itself on: itself plus
    // the later chunks of its segment (the segment's final chunk is its own
    // text). replayTranscript prints that once, at the segment's first
    // chunk, suppressing the chunks a reminder continues.
    // The segment runs from the reminder on; the first message that closes
    // it decides whether the accumulated chunks stood.
    string kept = m.content;
    bool afterCut = false; // the previous segment message was a cut-off chunk
    for (size_t j = k + 1; j < msgs.length; j++)
    {
        const n = msgs[j];
        if (replayTransparent(n)) continue;
        final switch (n.role)
        {
        case Role.system: break;
        case Role.user:
            // A further reminder continues the segment.
            if (n.continuation) { afterCut = false; break; }
            // A rejection or steer discarded it; so did a new prompt that
            // arrived while a reminder still awaited its reply.
            if (n.stopBlocked || n.steered || !afterCut) return null;
            // A new turn after a capped chunk: the budget ended the turn on
            // the accumulated answer, which stood.
            return kept;
        case Role.assistant:
            // Discarded with the tool call that replaced the answer.
            if (n.toolCalls.length) return null;
            if (stopRejected(msgs, j)) return null;
            if (isLengthStop(n.stopReason)) { kept ~= n.content; afterCut = true; break; }
            return kept ~ n.content;
        case Role.tool: return null;
        }
    }
    // The log ends on a capped chunk: the turn's visible tail.
    if (afterCut) return kept;
    return null; // the log ends mid-segment: no accepted answer to show
}

/// What quiet replay prints for assistant message `msgs[i]` — replayAnswerQuiet
/// unless an earlier chunk of the same continuation segment already printed
/// the accumulated whole. Live quiet prints an accepted answer once, at turn
/// end; replay prints it whole at the segment's first cut-off chunk (which
/// accumulates the later chunks), so every later chunk a reminder continues —
/// including the segment's final, non-length-stop chunk — is suppressed. A
/// chunk only suppresses when an earlier cut-off chunk of its segment is in
/// the log to carry the whole: a log truncated to mid-segment (e.g. after a
/// compaction) still shows the tail it has.
string replayQuietShown(const Message[] msgs, size_t i) pure nothrow @safe
{
    import nano.llm : isLengthStop;
    if (msgs[i].role != Role.assistant) return null;
    // Walk the segment backward: over transparent messages, then a
    // continuation reminder, to the chunk that reminder continues.
    size_t back = i;
    while (back > 0)
    {
        size_t k = back;
        while (k > 0 && replayTransparent(msgs[k - 1])) k--;
        if (k == 0 || msgs[k - 1].role != Role.user || !msgs[k - 1].continuation) break;
        back = k - 1; // the reminder; the chunk it continues precedes it
        while (back > 0 && replayTransparent(msgs[back - 1])) back--;
        if (back > 0 && msgs[back - 1].role == Role.assistant && isLengthStop(msgs[back - 1].stopReason))
            return null; // an earlier cut-off chunk prints the whole
    }
    return replayAnswerQuiet(msgs, i);
}

unittest
{
    import nano.agent : wrapReminder;
    auto cont = Message.auto_(wrapReminder("cut off"));
    cont.continuation = true;
    Message cut(string text)
    {
        auto m = Message.assistant(text);
        m.stopReason = "max_tokens";
        return m;
    }

    // The accepted answer of a continued segment prints exactly once, at the
    // segment's first cut-off chunk — the final chunk is not a length stop,
    // yet its text is already in that whole.
    auto ok = [cut("one "), cont, cut("two "), cont, Message.assistant("three")];
    assert(replayQuietShown(ok, 0) == "one two three");
    assert(replayQuietShown(ok, 2) is null, "a continued chunk is suppressed");
    assert(replayQuietShown(ok, 4) is null, "the segment's final chunk is suppressed too");
    size_t prints;
    foreach (j; 0 .. ok.length) if (replayQuietShown(ok, j) !is null) prints++;
    assert(prints == 1, "the accepted answer prints exactly once");

    // A log truncated to mid-segment (a compaction boundary) has no earlier
    // chunk to carry the whole: the tail it has still shows.
    auto tail = [cont, Message.assistant("three")];
    assert(replayQuietShown(tail, 1) == "three", "a truncated log shows the tail it has");
    auto tail2 = [cont, cut("two "), cont, Message.assistant("three")];
    assert(replayQuietShown(tail2, 1) == "two three", "the first in-log chunk carries the whole");
    assert(replayQuietShown(tail2, 3) is null);

    // Transparent messages between a chunk and its reminder keep the segment.
    auto tick = Message.auto_(wrapReminder("timer"));
    tick.timer = true;
    auto timed = [cut("one "), cont, tick, cut("two "), cont, tick, Message.assistant("three")];
    assert(replayQuietShown(timed, 0) == "one two three");
    assert(replayQuietShown(timed, 3) is null);
    assert(replayQuietShown(timed, 6) is null);

    // A segment a tool call discarded prints nothing; the fresh answer shows.
    auto call = Message.assistant("", [ToolCall.fromRaw("c1", "echo", `{}`)]);
    auto discarded = [cut("lost "), cont, call, Message.toolResult("c1", "echo", "pong"), Message.assistant("fresh")];
    assert(replayQuietShown(discarded, 0) is null);
    assert(replayQuietShown(discarded, 2) is null);
    assert(replayQuietShown(discarded, 4) == "fresh");

    // A rejected segment prints nothing either.
    auto rej = Message.auto_(wrapReminder("keep going"));
    rej.stopBlocked = true;
    auto blocked = [cut("lost "), cont, Message.assistant("draft"), rej, Message.assistant("final")];
    assert(replayQuietShown(blocked, 0) is null);
    assert(replayQuietShown(blocked, 2) is null, "a rejected draft stays hidden");
    assert(replayQuietShown(blocked, 4) == "final");

    // Plain turns and capped answers are unaffected.
    auto plain = [Message.assistant("hi"), Message.assistant("bye")];
    assert(replayQuietShown(plain, 0) == "hi" && replayQuietShown(plain, 1) == "bye");
    auto capped = [cut("capped"), Message.user("next"), Message.assistant("ok")];
    assert(replayQuietShown(capped, 0) == "capped");
    assert(replayQuietShown(capped, 2) == "ok");
}

unittest
{
    import nano.agent : wrapReminder;
    import std.json : JSONValue;
    auto cont = Message.auto_(wrapReminder("cut off"));
    cont.continuation = true;
    Message cut(string text)
    {
        auto m = Message.assistant(text);
        m.stopReason = "max_tokens";
        return m;
    }

    // The cited sequence: a discarded chunk must not print; only the
    // accepted answer shows.
    auto call = Message.assistant("", [ToolCall.fromRaw("c1", "echo", `{}`)]);
    assert(call.toolCalls.length == 1, "fromRaw builds the call");
    auto msgs = [cut("lost "), cont, call, Message.toolResult("c1", "echo", "pong"), Message.assistant("fresh")];
    assert(replayAnswerQuiet(msgs, 0) is null, "a chunk a tool call discarded is dropped");
    assert(msgs.length == 5 && msgs[2].toolCalls.length == 1 && msgs[3].role == Role.tool, "the sequence's layout");
    assert(replayAnswerQuiet(msgs, 2) is null, "an answer carrying tool calls stays hidden in quiet");
    assert(replayAnswerQuiet(msgs, 4) == "fresh");

    // A continuation that stood: a cut-off chunk resolves to the accepted
    // answer from itself on (itself plus the later chunks of its segment);
    // the segment's final chunk is its own text. replayTranscript prints the
    // whole once, at the segment's first chunk, suppressing the rest.
    auto ok = [cut("one "), cont, cut("two "), cont, Message.assistant("three")];
    assert(replayAnswerQuiet(ok, 0) == "one two three", "ok0=" ~ replayAnswerQuiet(ok, 0));
    assert(replayAnswerQuiet(ok, 2) == "two three", "ok2=" ~ replayAnswerQuiet(ok, 2));
    assert(replayAnswerQuiet(ok, 4) == "three", "ok4=" ~ replayAnswerQuiet(ok, 4));

    // A chunk the log cuts short on (crash before the reminder) shows: it
    // was the turn's visible tail.
    auto torn = [cut("half a file")];
    assert(replayAnswerQuiet(torn, 0) == "half a file");

    // A chunk a Stop-hook rejection supersedes is dropped.
    auto rej = Message.auto_(wrapReminder("keep going"));
    rej.stopBlocked = true;
    auto blocked = [cut("lost "), cont, Message.assistant("draft"), rej, Message.assistant("final")];
    assert(replayAnswerQuiet(blocked, 0) is null, "a chunk whose segment ends rejected is dropped");
    assert(replayAnswerQuiet(blocked, 2) is null);
    assert(replayAnswerQuiet(blocked, 4) == "final");

    // A chunk a mid-turn steer supersedes is dropped too.
    auto steer = Message.user("shorter");
    steer.steered = true;
    auto steered = [cut("lost "), cont, steer, Message.assistant("short")];
    assert(replayAnswerQuiet(steered, 0) is null, "a chunk whose segment a steer cut short is dropped");
    assert(replayAnswerQuiet(steered, 3) == "short");

    // A system message between a chunk and its reminder (a compaction
    // boundary) is skipped, as stopRejected skips it.
    auto compacted = [cut("lost "), Message.system("summary"), cont, call, Message.assistant("fresh")];
    assert(replayAnswerQuiet(compacted, 0) is null);
    assert(replayAnswerQuiet(compacted, 4) == "fresh");

    // Plain answers are unaffected: shown unless tool calls or a rejection.
    auto plain = [Message.assistant("hi"), Message.assistant("bye")];
    assert(replayAnswerQuiet(plain, 0) == "hi" && replayAnswerQuiet(plain, 1) == "bye");

    // A capped answer (budget exhausted, no reminder) followed by a new
    // prompt stood: it shows, single- and multi-chunk.
    auto capped = [cut("capped"), Message.user("next"), Message.assistant("ok")];
    assert(replayAnswerQuiet(capped, 0) == "capped", "a capped turn's answer stays after a new prompt");
    auto capped2 = [cut("one "), cont, cut("two"), Message.user("next"), Message.assistant("ok")];
    assert(replayAnswerQuiet(capped2, 0) == "one two", "a capped multi-chunk answer shows whole");
    assert(replayAnswerQuiet(capped2, 2) == "two");
    // A new prompt while a reminder awaits its reply still discards.
    auto aborted = [cut("lost"), cont, Message.user("next"), Message.assistant("ok")];
    assert(replayAnswerQuiet(aborted, 0) is null, "aborted0=[" ~ replayAnswerQuiet(aborted, 0) ~ "]");

    // A timer firing during a continued answer keeps the retained prefix.
    auto tick = Message.auto_(wrapReminder("timer"));
    tick.timer = true;
    auto timed = [cut("one "), cont, tick, Message.assistant("two")];
    assert(replayAnswerQuiet(timed, 0) == "one two", "a timer during a continuation keeps the prefix");
    auto timed2 = [cut("one "), tick, cont, Message.assistant("two")];
    assert(replayAnswerQuiet(timed2, 0) == "one two", "a timer before the reminder is transparent");
    auto timed3 = [cut("one "), cont, tick, cut("two "), cont, Message.assistant("three")];
    assert(replayAnswerQuiet(timed3, 3) == "two three", "a timer before a continued chunk keeps it continued");

    // Hook-only context (a resumed turn's SessionStart block) is model-only
    // like a timer: it never printed live, so it is transparent — a resumed
    // interrupted turn (`cut → reminder → hookContext → answer`) keeps the
    // cutoff prefix its continuation stood on.
    auto hook = Message.user(wrapReminder("session context"));
    hook.hookContext = true;
    auto hooked = [cut("one "), cont, hook, Message.assistant("two")];
    assert(replayAnswerQuiet(hooked, 0) == "one two", "hook context between reminder and reply keeps the prefix");
    assert(replayAnswerQuiet(hooked, 3) == "two");
    auto hooked2 = [cut("one "), cont, hook, cut("two "), cont, Message.assistant("three")];
    assert(replayAnswerQuiet(hooked2, 0) == "one two three", "hook context mid-segment keeps the segment");
    assert(replayAnswerQuiet(hooked2, 3) == "two three");
    assert(replayAnswerQuiet(hooked2, 5) == "three");
}

/// Rebuild the transcript of a loaded session on the frame (Rust
/// `replay_history` in frame mode): the frame owns the screen, so without
/// this a resumed or relaunched session opens with an empty transcript.
/// Prompts, answers, tool calls and results show as they did live, stamped
/// with their saved times; after a
/// compaction the pre-compaction turns replay instead of the summary.
void replayTranscript(Agent agent, Console console)
{
    auto msgs = agent.replayMessages;
    // Hold the frame while the history is written: each line would otherwise
    // render its own synchronized frame, and a real terminal shows the whole
    // conversation scrolling past. Released last (scope exits run in
    // reverse), so the replay and the status bar appear in one frame.
    auto frame = gFrame;
    if (frame) frame.hold(true);
    scope (exit) if (frame) frame.hold(false);
    // Each toolEnd would refresh the view (a token estimate over the whole
    // conversation): quadratic on long sessions, so refresh once at the end.
    auto after = console.afterStep;
    console.afterStep = null;
    scope (exit) { console.afterStep = after; if (after !is null) after(); }
    // Batch status redraws until the final idle reset below.
    const wasBatched = gStatusBatched;
    gStatusBatched = true;
    scope (exit) gStatusBatched = wasBatched;
    // Tool calls whose header waits for its result, so each header shows
    // directly above its own output (several calls in one message would
    // otherwise stack every header above all the results).
    size_t[2][] pending; // [message, call] index into msgs
    void flushPending()
    {
        foreach (p; pending)
        {
            console.replayTime = msgs[p[0]].timestamp;
            console.toolStart(msgs[p[0]].toolCalls[p[1]]);
        }
        pending = null;
    }
    scope (exit) console.replayTime = null;
    foreach (i, ref m; msgs)
    {
        if (m.role != Role.tool) flushPending();
        console.replayTime = m.timestamp;
        final switch (m.role)
        {
        case Role.system: break;
        case Role.user:
        {
            // A Stop hook's rejection printed live as a user message
            // (`ev.userMessage(b.reason)`, agent.d): replay shows the reason
            // the same way (quiet keeps it hidden), unwrapped from its
            // reminder. New logs flag it `stopBlocked`; older logs have the
            // unflagged automatic wrapped reminder `stopRejected` recognises.
            if (rejectionAt(msgs, i))
            {
                auto reason = rejectionReason(m);
                if (reason.strip.length) console.userMessage(sanitizeBlock(reason));
                break;
            }
            // Model-only reminders (hook context, output-limit continuations,
            // timer firings and nudges) were never typed by the user.
            // Stop-hook reminders and idle-timer turns are autoInitiated.
            if (m.hookContext || m.continuation || m.timer || m.autoInitiated) break;
            // Hook context appended to the prompt was never shown live.
            auto typed = m.pinText.length ? m.pinText : m.content;
            // A steer rendered live through the shared user-message renderer
            // (`↪`, hidden in quiet mode), not as a fresh `›` prompt.
            if (m.steered) { if (typed.strip.length) console.userMessage(sanitizeBlock(typed)); break; }
            if (typed.strip.length)
                writeln(stampBlock(console.stamp(), console.bold("› ") ~ escapeMarks(sanitizeBlock(typed))));
            break;
        }
        case Role.assistant:
            // Escape literal markers before rendering, keeping the renderer's
            // own soft-wrap / verbatim markers.
            // Quiet mode shows only final answers live (no tool calls);
            // an output-limit cut-off has no tool calls, so it stays — but
            // only when its continuation stood: a chunk a later tool call
            // or rejection discarded never printed live.
            // A Stop hook rejecting the answer supersedes it: live quiet
            // mode keeps only the answer that finally stood.
            // Live quiet prints an accepted answer once, at turn end; replay
            // prints it whole at the segment's first cut-off chunk (which
            // accumulates the later chunks), suppressing every later chunk a
            // reminder continues — their text is already in that whole.
            const shown = console.quiet ? replayQuietShown(msgs, i) : m.content;
            if (shown.strip.length) writeln(stampBlock(console.stamp(), console.display(escapeMarks(sanitizeBlock(shown))).stripRight));
            foreach (j, ref c; m.toolCalls) pending ~= [i, j];
            break;
        case Role.tool:
            foreach (k, p; pending)
            {
                auto c = msgs[p[0]].toolCalls[p[1]];
                if (c.id != m.toolCallId) continue;
                console.replayTime = msgs[p[0]].timestamp;
                console.toolStart(c);
                console.replayTime = m.timestamp;
                console.toolEnd(c, toolResultDisplay(m.content, m.attachments), m.isError);
                pending = pending[0 .. k] ~ pending[k + 1 .. $];
                break;
            }
            break;
        }
    }
    flushPending();
    if (!agent.plan.empty && !console.quiet) writeln(escapeMarks(sanitizeBlock(planText(agent, console.renderMarkdown))));
    // toolStart/toolEnd drive the live status; the replay leaves it idle
    // (and this one redraw covers every batched change).
    gStatusBatched = wasBatched;
    updateStatus((ref Stats s) { s.activity = Activity.idle; s.tool = null; s.tokensPerSec = 0;
        s.historySearches = s.historyReads = 0; });
    stdOut.flush();
}

/// Whether the answer `msgs[i]` was superseded within its turn: the next
/// non-system message is a Stop hook's rejection or a mid-turn steer. New
/// logs flag both explicitly (`stop_blocked`, `steered`); for older logs, fall
/// back to an unflagged automatic wrapped reminder (an idle timer turn's
/// message is automatic but starts with the raw notice). System messages
/// (e.g. a compaction summary between stash and conversation) are skipped.
bool stopRejected(const Message[] msgs, size_t i) pure nothrow @nogc @safe
{
    import std.algorithm.searching : startsWith;
    size_t k = i + 1;
    while (k < msgs.length && msgs[k].role == Role.system) k++;
    if (k >= msgs.length) return false;
    return msgs[k].steered || rejectionAt(msgs, k);
}

/// Whether `msgs[i]` is a Stop hook's rejection of the answer before it:
/// flagged `stop_blocked` in new logs; in older logs an unflagged automatic
/// wrapped reminder (an idle timer turn's message is automatic but starts
/// with the raw notice). The same shape `stopRejected` looks for one message
/// later. A mid-turn steer supersedes too but is not a rejection: it shows
/// through the steer path instead.
/// The reason a Stop-hook rejection message carries, as printed live: the
/// wrapped reminder unwrapped for both flagged and legacy (unflagged) logs,
/// falling back to the raw content when it is not wrapped so nothing is lost.
string rejectionReason(const ref Message m) @safe
{
    import nano.agent : unwrapReminder;
    auto unwrapped = unwrapReminder(m.content);
    return unwrapped !is null ? unwrapped : m.content;
}

unittest
{
    import nano.agent : wrapReminder;
    auto legacy = Message.auto_(wrapReminder("keep going"));
    assert(rejectionReason(legacy) == "keep going", "a legacy wrapped rejection is unwrapped");
    auto flagged = Message.auto_(wrapReminder("multi\nline"));
    flagged.stopBlocked = true;
    assert(rejectionReason(flagged) == "multi\nline");
    auto raw = Message.auto_("bare reason");
    raw.stopBlocked = true;
    assert(rejectionReason(raw) == "bare reason", "a flagged unwrapped message is not dropped");
    // A malformed wrapper whose delimiters overlap at the newline passes both
    // delimiter checks but cannot be sliced: the raw content is the reason.
    auto malformed = Message.auto_("<system-reminder>\n</system-reminder>");
    assert(rejectionReason(malformed) == "<system-reminder>\n</system-reminder>",
        "an overlapping wrapper falls back to the raw reason");
}

bool rejectionAt(const Message[] msgs, size_t i) pure nothrow @nogc @safe
{
    import std.algorithm.searching : startsWith;
    if (i >= msgs.length) return false;
    const n = &msgs[i];
    if (n.role != Role.user) return false;
    if (n.stopBlocked) return true;
    return n.autoInitiated && !n.steered && !n.continuation && !n.timer && !n.hookContext
        && n.content.startsWith("<system-reminder>");
}

unittest
{
    import nano.agent : wrapReminder;
    auto hook = Message.auto_(wrapReminder("keep going"));
    auto cont = Message.auto_(wrapReminder("cut off"));
    cont.continuation = true;
    // Mid-turn timers are flagged `timer`; an idle timer turn's input isn't.
    auto timerNew = Message.auto_(wrapReminder("Timer 1, set at 10:00, fired: check"));
    timerNew.timer = true;
    auto timerOld = Message.auto_("Timer 2, set at 10:00, fired: check");
    auto msgs = [Message.assistant("first"), hook, Message.assistant("second"), cont, Message.assistant("third"),
        timerNew, Message.assistant("fourth"), timerOld, Message.assistant("tail")];
    assert(stopRejected(msgs, 0));
    assert(!stopRejected(msgs, 2));
    assert(!stopRejected(msgs, 4));
    assert(!stopRejected(msgs, 6));
    assert(!stopRejected(msgs, 8));
    // An unflagged user message (a new turn) never supersedes; a flagged
    // Stop-hook rejection does regardless of its content.
    auto flagged = Message.auto_("reason");
    flagged.stopBlocked = true;
    auto turns = [Message.assistant("a1"), Message.user("<system-reminder>next"), Message.assistant("a2"),
        flagged, Message.assistant("a3")];
    assert(!stopRejected(turns, 0));
    assert(stopRejected(turns, 2));
    assert(!stopRejected(turns, 4));
    // Answer -> mid-turn steer -> answer: only the final answer stands.
    auto steer = Message.user("shorter");
    steer.steered = true;
    auto steered = [Message.assistant("a1"), steer, Message.assistant("a2")];
    assert(stopRejected(steered, 0));
    assert(!stopRejected(steered, 2));
    // A compaction boundary inserts a system message between an answer and
    // its rejection (or a steer): it is skipped.
    auto compacted = [Message.assistant("a1"), Message.system("summary"), flagged, Message.assistant("a2"),
        Message.system("summary"), steer, Message.assistant("a3"), Message.system("summary")];
    assert(stopRejected(compacted, 0));
    assert(stopRejected(compacted, 3));
    assert(!stopRejected(compacted, 6));

    // rejectionAt is the per-message shape stopRejected looks for one
    // message later: a flagged rejection or a legacy unflagged automatic
    // wrapped reminder. A steer supersedes but is not a rejection, and
    // other automatic messages (continuation, timer, hook context) are not.
    assert(rejectionAt(msgs, 1), "the legacy wrapped reminder is a rejection");
    assert(rejectionAt(turns, 3), "a flagged rejection is one regardless of content");
    assert(!rejectionAt(turns, 1), "a user-typed reminder lookalike is not");
    assert(!rejectionAt(steered, 1), "a steer supersedes but is no rejection");
    assert(!rejectionAt(msgs, 3), "a continuation reminder is not");
    assert(!rejectionAt(msgs, 5), "a flagged timer is not");
    assert(!rejectionAt(msgs, 7), "an idle timer turn's raw notice is not");
    assert(!rejectionAt(msgs, 0), "an assistant message is not");
    assert(!rejectionAt(msgs, msgs.length), "out of range is not");
    auto hookCtx = Message.auto_(wrapReminder("session context"));
    hookCtx.hookContext = true;
    assert(!rejectionAt([hookCtx], 0), "hook context is not");
}

unittest
{
    import nano.agent : unwrapReminder, wrapReminder;
    assert(unwrapReminder(wrapReminder("keep going")) == "keep going");
    assert(unwrapReminder(wrapReminder("multi\nline\nreason")) == "multi\nline\nreason");
    assert(unwrapReminder("plain") is null);
    assert(unwrapReminder("<system-reminder>\nonly prefix") is null);
    assert(unwrapReminder("") is null);
    // A malformed wrapper whose delimiters overlap at the newline is not a
    // wrapper: slicing it would invert the bounds, so it falls back to raw.
    assert(unwrapReminder("<system-reminder>\n</system-reminder>") is null);
    // The empty wrapper is the shortest valid one.
    assert(unwrapReminder("<system-reminder>\n\n</system-reminder>") == "");
}

/// The plan for `/plan` and replay; `symbols` (a rendering terminal) shows
/// item marks as ☐/◐/☑/⊘/☒ like rendered markdown task lists.
string planText(Agent agent, bool symbols = false) pure
{
    import nano.plan : planSymbols;
    if (agent.plan.empty) return "No plan yet. The agent makes one with the plan_add tool.";
    auto text = agent.plan.render(true, size_t.max).stripRight;
    return symbols ? planSymbols(text) : text;
}

string modeListing(AgentMode current) pure
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
        ? format("Auto-compact: at %.0f%% (~%s tokens); compacted %s time(s)", agent.effectiveAutoCompactThreshold * 100,
            imported!"std.conv".to!size_t(window * agent.effectiveAutoCompactThreshold), agent.compactions)
        : "Auto-compact: off";
    out_ ~= format("Compaction:   %s mode (/compact --smart, --standard or --extract overrides once)", modeName(agent.compactionMode));
    return out_.join("\n");
}

// A negative configured threshold is clamped for the report too: building
// it (as refreshView does before every turn) must not throw on the token count.
unittest
{
    import std.algorithm : canFind;
    import nano.providers.mock : MockClient;
    import nano.tools : ToolRegistry;
    import nano.permissions : Policy;
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "system");
    agent.configuredWindow = 100_000;
    agent.autoCompact = true;
    agent.autoCompactThreshold = -0.5;
    auto report = contextReport(agent);
    assert(report.canFind("Auto-compact: at 10% (~10000 tokens)"), report);
}

/// The agent, for `main`'s exit (title requests may still be in flight).
Option!Agent mainAgent; /// the REPL's agent (main thread only); none if startup ended early

/// The program (source/entry.d's `main` calls it, so `dub test` builds
/// and tests this module like any other).
int appMain(string[] args)
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
    Options o;
    try o = parseArgs(args);
    catch (UsageError e) die(e.msg);
    auto cfgPath = o.configPath.length ? o.configPath : Config.defaultPath;
    Config cfg;
    JSONValue rawConfig = JSONValue(string[string].init);
    if (o.login.length) return runLogin(o.login);
    try
    {
        cfg = Config.load(cfgPath);
        if (cfgPath.exists) rawConfig = parseToml(readText(cfgPath)).orThrow!(e => new Exception(e));
    }
    catch (Exception e) die(e.msg);

    // `session_dir` relocates the logs; `persist_sessions = false` saves none.
    immutable sessionDir = nano.session.sessionDir(cfg.sessionDir);
    if (sessionDir == nano.session.sessionDir())
        if (auto n = nano.session.adoptPreviewSessions(nano.session.previewSessionDir(), sessionDir))
            stdErr.writefln("nano-coder: moved %s session(s) from the nano-coder-d preview into %s", n, sessionDir);
    // Compress and expire old logs (issue #205), at most once a day.
    try
    {
        auto tidy = nano.session.tidySessions(sessionDir, cfg.sessionCompressAfterDays, cfg.sessionRetentionDays);
        if (tidy.compressed || tidy.deleted)
            stdErr.writefln("nano-coder: tidied session logs in %s (%s compressed, %s expired, %.1f MB freed)",
                sessionDir, tidy.compressed, tidy.deleted, tidy.freedBytes / 1_048_576.0);
    }
    catch (Exception) {} // tidy-up is best-effort; the session starts anyway
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
    ConfiguredWindow configuredWindow;
    LLMClient client = () {
        try
        {
            auto rp = resolve(cfg, spec);
            configuredWindow = windowFor(cfg, rp.config);
            return makeClient(rp);
        }
        catch (Exception e) die(e.msg);
    }();

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
    // The closures below are registered before the agent exists (it is built
    // from their tools and prompt), so they reach it through `built`, which is
    // set once it is.
    Option!Agent built;
    // Read-deny rules hide paths from search results (Policy.readDenyScan).
    // The deny rules and working directory are resolved once per search, so
    // each walked entry is judged lexically (Rust #160).
    registerBuiltinTools(tools, cfg, readState, (string root) @safe {
        import nano.permissions : ReadDenyScan;
        ReadDenyScan scan;
        // Before the agent exists, the policy it will be built with.
        immutable has = built.match!(a => a.policy.readDenyScan(getcwd(), scan),
            () => policy.readDenyScan(getcwd(), scan));
        if (!has) return Denied.init;
        auto forRoot = scan.forRoot(root);
        return (string path) @safe => forRoot.denied(path);
    }, () @safe {
        // The same rules as text, for a search on a worker thread (#222).
        auto sources = built.match!(a => a.policy.readDenySources, () => policy.readDenySources);
        return sources.length ? getcwd() ~ sources : null;
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
        void note(string msg) { stdErr.writeln("nano-coder: ", msg); }
        auto ok = decideRoot(root, cfg.skills.dirs, cfg.skills.aiLock, to, trustFile, &confirm, &note);
        decided[root] = ok;
        return ok;
    }
    // Skills: the index goes into the system prompt; `load_skill` reads one.
    // Off is an empty set (as in Rust), not null.
    // NANO_CODER_NO_SKILLS turns skills off for one run (as in Rust).
    bool skillsOn = cfg.skills.enabled && environment.get("NANO_CODER_NO_SKILLS") is null;
    Skills discoverSkills(string dir)
    {
        if (!skillsOn) return new Skills;
        auto sc = cfg.skills;
        if (!trusted(dir)) { sc.dirs = null; sc.aiLock = false; }
        auto s = Skills.discover(dir, sc);
        foreach (w; s.warnings) stdErr.writeln("nano-coder: skills: ", w);
        return s;
    }
    Skills skills = discoverSkills(cwd);
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
        foreach (t; memorySessionTools(store, memoryWritable,
                () => built.match!(a => a.control.mode == AgentMode.plan, () => o.plan),
                () => built.match!(a => a.log.match!(l => l.id, () => string.init), () => string.init)))
            // Search never prompts, and changes nothing another tool reads
            // unless the session is writable: then it bumps `last_used` and
            // rewrites the memory files (nano/memory.d `searchInner`), which
            // would race a concurrent call's recall processing and any file
            // worker reading the store. So it may run alongside other
            // read-only calls only when it runs read-only itself — a writable
            // session keeps it a barrier (#222).
            tools.register(t.definition, asToolError(t.handler),
                Concurrency(t.definition.name == imported!"nano.memory".searchTool && !memoryWritable));
    // Instruction files, discovered once per working directory and re-read
    // before each turn (`reloadInstructions`).
    Option!ProjectInstructions instructions;
    string instructionsDir;
    // Every caller installs the prompt it builds at once, so the ids its
    // memory index renders in full go straight to the agent (recall skips them).
    bool[string] indexShown;
    string systemFor(string dir, bool plan)
    {
        indexShown = null;
        // `built` is empty only on the first call: the agent is built from this prompt.
        auto index = memory.match!(m => m.indexWithRendered(memoryWritable && !plan, indexShown), () => string.init);
        foreach (a; built) a.indexShown = indexShown;
        if (instructionsDir is null || instructionsDir != dir)
        {
            instructionsDir = dir;
            instructions = discoverInstructions(cfg, dir);
            foreach (a; built) a.instructions = instructions;
        }
        return buildSystemPrompt(cfg, dir, wallNow.toISOExtString[0 .. 10], plan, skills, index,
            instructions.match!(pi => pi.render, () => string.init));
    }
    auto questions = QuestionBroker.make;
    tools.register(questionDefinition, (JSONValue a) => questions.run(a));
    Agent agent = new Agent(client, tools, policy, systemFor(cwd, o.plan));
    built = some(agent);
    mainAgent = some(agent);
    // Exiting stops every sub-agent, background ones included; their logs
    // stay. Installed before the `--acp` and `-p` returns: a child thread
    // left waiting on its parent would otherwise hang process exit.
    scope (exit) agent.stopSubagents();
    agent.memory = memory;
    agent.indexShown = indexShown;
    agent.instructions = instructions;
    agent.sessionTitles = cfg.sessionTitles;
    agent.crossSessionHistory = cfg.crossSessionHistory;
    agent.titleModel = cfg.titleModel;
    agent.titleClient = (string spec) => makeClient(resolve(cfg, spec));
    // The provider the last switch resolved: a background probe builds its
    // client from a deep copy, so `api_key_command` doesn't run again on the
    // agent thread before the probe starts.
    ResolvedProvider lastResolved;
    agent.probeClient = (string spec) {
        import nano.safeio : deepCopy;
        if (lastResolved.name.length && spec == lastResolved.name ~ "/" ~ lastResolved.model)
            return makeClient(deepCopy(lastResolved));
        // Unknown spec: skip the optional probe rather than re-resolve here.
        throw new Exception("no resolved provider for " ~ spec);
    };
    agent.subagentsOn = cfg.subagents;
    configureSubagents(agent, cfg, true);
    agent.planTools = cfg.planTools;
    agent.timerTools = !o.acp; // ACP has no idle loop to fire them
    // Nor to serve background sub-agents between prompts (issue #266).
    // Piped stdin blocks on its read, so nothing serves them there either.
    agent.backgroundSubagents = !o.acp && isTerminal(0);
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
        agent.compactionMode = parseCompactionMode(cfg.compactionMode).match!(m => m, () => die(
            `compaction_mode must be "standard" or "smart", got "` ~ cfg.compactionMode ~ `"`));
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
        {
            // The release notice, sent once (#282). No network here: notes
            // the build lacks give a compare link.
            import nano.release_notes : embedded, lastVersionPath, startupNotice;
            import std.array : join;
            host.releaseNotice = startupNotice(lastVersionPath(), packageVersion, cfg.showReleaseNotes, embedded()).join("\n");
        }
        host.loadHooks = &loadHooks;
        host.providerNames = () => enabledProviderNames(cfg.providers);
        host.configModel = cfg.model;
        host.configSystemPrompt = cfg.systemPrompt;
        host.saveSubagents = (bool on) => saveSubagentsSetting(cfg, on);
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
        // The bash heartbeat keeps a supervising worker (c8ctl-nano) from
        // idle-killing a healthy long command: a `session/update` note on the
        // JSON-RPC stream every interval, never in the model's context or the
        // tool result.
        bashHeartbeatInterval = bashHeartbeatIntervalSecs(cfg.bashHeartbeatSecs).seconds;
        bashHeartbeatSink = (string line) => server.heartbeat(line);
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
    /// Load a saved session; returns its diagnostics so a frame caller can
    /// print them after clearing and replaying the transcript.
    string[] loadSession(string path)
    {
        string[] notes;
        // Lock the log first, then read the state the lock covers: a writer
        // finishing a turn while the lock wait blocks would otherwise be
        // adopted from a pre-turn snapshot and the turn re-run. A failure
        // before adoption closes the incoming log (loadRestored rolls the
        // live session back itself once it takes the log).
        Option!SessionLog newLog;
        Restored restored;
        if (!o.noSession)
        {
            auto incoming = new SessionLog(path);
            // Close on failure only until the agent adopts the log: after
            // `loadRestored` adopts it (even if it throws afterwards) it is
            // the agent's live writer.
            scope (failure) if (!agent.ownsLog(incoming)) incoming.close();
            newLog = some(incoming);
            restored = restore(incoming.path);
            foreach (note; agent.loadRestored(restored, newLog))
                notes ~= "nano-coder: ignoring " ~ note;
        }
        else
        {
            // No log to read slimmed folded outputs back from: keep them.
            restored = restore(path, false);
            foreach (note; agent.loadRestored(restored, newLog))
                notes ~= "nano-coder: ignoring " ~ note;
        }
        updateStatus((ref Stats s) { s.historySearches = s.historyReads = 0; });
        if (!agent.timers.empty)
            notes ~= format("%s timer%s still set (/timers lists them)", agent.timers.items.length,
                agent.timers.items.length == 1 ? "" : "s");
        notes ~= format("resumed %s (%s messages)", restored.id, agent.messages.length - 1);
        if (restored.pendingInput.length)
            notes ~= format("the last prompt never finished (the session was interrupted): %s",
                oneLine(restored.pendingInput));
        // Reading a long session's log parses every record of it (a log can
        // run to hundreds of MB of superseded compaction snapshots); the
        // agent keeps only the live state. Drop the parse and hand the freed
        // heap back to the OS, or the GC keeps the load's peak for the
        // life of the process.
        restored = Restored.init;
        releaseHeap();
        return notes;
    }

    try
    {
        if (o.hasResume) foreach (n; loadSession(findSession(sessionDir, o.resume, cwd))) stdErr.writeln(n);
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
    // The bash heartbeat keeps a supervising worker (c8ctl-nano) from
    // idle-killing a healthy long command: a "still running" note on stdout
    // every interval, never in the model's context or the tool result.
    bashHeartbeatInterval = bashHeartbeatIntervalSecs(cfg.bashHeartbeatSecs).seconds;
    bashHeartbeatSink = (string line) => console.note(console.dim(line));
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
    import nano.commands : modelSuggestionSource, modelSuggestions;
    auto recentsPath = nano.recents.defaultPath();
    auto recents = nano.recents.load(recentsPath);
    if (recents.canonicalize(cfg.providers, cfg.defaultProvider)) nano.recents.save(recentsPath, recents);
    string currentSpec() { return nano.recents.canonical(client.providerName ~ "/" ~ client.modelName, cfg.providers, cfg.defaultProvider); }
    modelSuggestionSource = () {
        string[] recent;
        synchronized recent = recents.models.dup;
        return modelSuggestions(cfg, currentSpec(), recent);
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
            lastResolved = rp;
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
        view.set("/plan", planText(agent, console.renderMarkdown));
        view.set("/timers", timersText(agent));
        view.set("/context", contextReport(agent));
        view.set("log", agent.log.match!(l => l.path, () => string.init));
        refreshStatus();
    }
    console.afterStep = &refreshView;

    // The system prompt's plan section follows the mode; Shift-Tab mid-turn
    // only switches the live mode, so the prompt catches up at the next turn.
    agent.promptPlan = o.plan;
    void syncMode() { agent.syncModePrompt((bool plan) => systemFor(cwd, plan)); }

    // Re-read the instruction files (AGENTS.md, CLAUDE.md, rules, your own
    // files) so edits apply without a restart. A change to what they put in
    // the system prompt rebuilds it (true); a change to on-demand rules (or
    // their imports) only swaps the rules. A change starts attachment over:
    // a rule or nested file may attach once more, but never stays stale.
    bool reloadInstructions()
    {
        static string text(Option!ProjectInstructions i) { return i.match!(pi => pi.render, () => string.init); }
        auto fresh = discoverInstructions(cfg, cwd);
        // Same files read (texts, imports, rules), and the nested directories
        // searched for tool calls still read the same: nothing to do.
        const sameFiles = instructionsDir == cwd && instructions.match!(
            old => fresh.match!(f => old.sameFiles(f), () => false),
            () => fresh.match!(f => false, () => true));
        if (sameFiles && !instructions.match!(pi => pi.nestedChanged, () => false)) return false;
        const sameText = instructionsDir == cwd && text(fresh) == text(instructions);
        instructionsDir = cwd;
        instructions = fresh;
        agent.instructions = fresh;
        if (sameText) return false;
        agent.installSystem(systemFor(cwd, agent.promptPlan), indexShown);
        return true;
    }

    // `h.cfg` points at runMain's `cfg`, which outlives every settings
    // dialog (they all run inside runMain).
    SettingsHost settingsHost()
    {
        auto h = SettingsHost(&cfg, notNull(agent));
        h.configPath = cfgPath;
        h.recents = () => recents.models;
        h.switchModel = (string spec) {
            try { switchModel(spec); return string.init; }
            catch (Exception e) return e.msg;
        };
        h.listModels = (string name) => makeClient(resolve(cfg, name)).listModels();
        h.refreshSystem = () { agent.messages[0].content = systemFor(cwd, agent.promptPlan); };
        h.refreshClient = (string name) {
            import nano.settings : editRebuilds;
            // Sub-agents build clients from a config frozen at startup;
            // re-freeze after every provider edit so children see the new
            // credentials/endpoints (and a newly added provider).
            configureSubagents(agent, cfg, false);
            if (!editRebuilds(cfg, name, agent.client.providerName)) return string.init;
            // The client's own provider was edited: keep its model. Otherwise the
            // configured model now resolves to the edited provider: build that.
            auto spec = agent.client.providerName == name ? name ~ "/" ~ agent.client.modelName : cfg.model;
            try { switchModel(spec); return ""; }
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
        if (reloadInstructions())
            stdErr.writeln(console.dim("[instruction files changed: the system prompt now follows them]"));
        syncMode();
        nano.herdr.report(nano.herdr.State.working);
        nano.herdr.showTimer(!agent.timers.empty);
        // Follow timers set or cancelled during the turn too, not only the
        // state sampled here and at the idle prompt.
        if (nano.herdr.active && agent.onTimersChanged is null)
            agent.onTimersChanged = () { nano.herdr.showTimer(!agent.timers.empty); };
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
            console.beginAnswerGuard();
            string response;
            try response = agent.run(input, console);
            catch (Exception e)
            {
                console.endLine();
                stdErr.writeln(console.red("error: " ~ e.msg));
                ok = false;
            }
            console.endLine();
            // Quiet shows only the final answer; a turn that got louder after
            // answer deltas were dropped reprints the whole answer (ui.rs).
            auto reprint = turnReprint(console.quiet, console.answerMayBeTruncated, console.finalAnswer, response,
                agent.lastStop == StopReason.maxTurnRequests);
            if (reprint.length)
            {
                writeln(console.display(reprint));
                stdOut.flush();
            }
            return ok;
        });
    }


    // --wait-timers: sleep until the next timer the agent set fires and
    // return it as the next (literal, "\x00"-marked) prompt; null once none
    // are left or Ctrl-C stopped the run.
    string awaitTimerTurn()
    {
        import core.thread : Thread;
        import core.time : msecs;
        while (!agent.timers.empty && !agent.control.nonNull.isCancelled)
        {
            stdOut.flush(); // the answer before the notes
            auto wait = agent.timers.nextDue - agent.timerNow();
            if (wait > 0)
            {
                stdErr.writeln(console.dim(format("[waiting %s for timer %s]", imported!"nano.timers".describe(wait),
                    agent.timers.items[0].id)));
                // Idle Ctrl-C exits (130) via the SIGINT handler.
                while (agent.timers.nextDue > agent.timerNow()) sleepFor(500.msecs);
            }
            string notice;
            auto fired = agent.takeFiredTimers(notice);
            if (fired is null) continue;
            stdErr.writeln(console.dim(notice));
            agent.automaticInput = true;
            return "\x00" ~ fired;
        }
        return null;
    }

    // The plain (no-editor) prompt's read: while background sub-agents run
    // it polls, serving their tool calls and running a finished one's result
    // as a turn, as the editor prompt does (issue #266).
    string plainLine()
    {
        import nano.clock : sleepFor;
        import core.time : msecs;
        string l;
        while (agent.subagentsActive || agent.backgroundResultsReady())
        {
            if (inbox.tryTake(l)) return l;
            if (agent.backgroundResultsReady())
            {
                string notice;
                auto text = agent.takeBackgroundResults(notice);
                if (text is null) continue;
                writeln(console.dim(notice));
                agent.automaticInput = true;
                return "\x00" ~ text;
            }
            sleepFor(20.msecs);
        }
        return takeLine(inbox);
    }

    if (o.prompt.length)
    {
        bool ok = turn(o.prompt);
        while (ok && o.waitTimers)
        {
            auto next = awaitTimerTurn();
            if (next is null) break;
            ok = turn(next[1 .. $]);
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
    Chan!string releaseNotice; // the fetched release notice, recorded once shown
    if (interactive && isTerminal(1) && environment.get("TERM", "") != "dumb"
        && environment.get("NANO_CODER_PLAIN_INPUT") is null && enterKeyMode(0))
    {
        // The app owns the screen and re-renders it (`nano.frameui`); the
        // editor draws only through it.
        gFrame = FrameUi.install(&frameStatus);
        if (auto f = gFrame) f.setVerbose(verbosity >= Verbosity.verbose);
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
        if (!o.acp && cfg.checkUpdates && !disabledByEnv && !isCi && channelFor(launchExe) != Channel.other)
            updateHints = startChecker(channelFor(launchExe), packageVersion);
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
            "nano-coder v" ~ packageVersion,
            format("Model: %s (provider: %s)", client.modelName, client.providerName),
        ];
        agent.log.ifSome((SessionLog l) { banner ~= format("Session: %s (resume with nano-coder --resume %s)", l.id, l.id); });
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
    // The frame owns the screen: rebuild a resumed session's transcript on it.
    if (gFrame && o.hasResume)
    {
        replayTranscript(agent, console);
        // The replay read the folded turns' outputs back from the log
        // (issue #263): hand that transient heap back too.
        releaseHeap();
    }
    // What changed since the version that ran last (#282): after the replay,
    // so it is the last thing on screen. Notes the build lacks are fetched in
    // the background and shown at the idle prompt, like an update hint.
    if (interactive)
    {
        import nano.release_notes : embedded, lastVersionPath, needsFetch, runNotice, startupNotice;
        // The record is updated only once the fetched notice is on screen, so
        // quitting before it lands shows it again next start.
        import std.array : join;
        auto notesPath = lastVersionPath();
        auto notes = embedded();
        // Only the line editor's idle prompt drains the hints; without it, the
        // synchronous path shows the compare link.
        if (editor.isSome && needsFetch(notesPath, packageVersion, cfg.showReleaseNotes, notes))
        {
            releaseNotice = Chan!string.make;
            spawnDaemon(&runNotice, notesPath, packageVersion, releaseNotice);
        }
        else if (auto lines = startupNotice(notesPath, packageVersion, cfg.showReleaseNotes, notes))
            writeln(stampBlock(console.stamp(), lines.join("\n")));
    }
    import core.time : MonoTime, msecs;
    import nano.lineedit : DoublePress, interruptWindowMs;
    auto exitPress = DoublePress(interruptWindowMs); // idle Ctrl-C twice exits
    static long monoMs() @safe { return (monoNow - MonoTime.zero).total!"msecs"; }
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
        agent.log.ifSome((SessionLog l) { writefln("Session: %s (resume with nano-coder --resume %s)", l.id, l.id); });
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
            // Background sub-agents still running: the pane shows activity.
            if (agent.subagentsActive) nano.herdr.report(nano.herdr.State.working);
            else if (resumeId.length)
            {
                auto resume = nano.herdr.resumeArgv(resumeId, agent.client.providerName ~ "/" ~ agent.client.modelName, herdrExtra);
                if (resume !is null)
                    nano.herdr.report(nano.herdr.State.idle, null, nano.herdr.Session(resumeId, resume), true);
                else nano.herdr.report(nano.herdr.State.idle);
            }
            else nano.herdr.report(nano.herdr.State.idle);
            nano.herdr.showModel(agent.client.modelName);
            nano.herdr.showTimer(!agent.timers.empty);
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
            string fetchedNotice;
            // Shows the fetched release notice, then records the version: once shown, it is done.
            void showNotice() @safe
            {
                import nano.release_notes : lastVersionPath, writeLastVersion;
                writeln(console.dim(fetchedNotice));
                writeLastVersion(lastVersionPath(), packageVersion);
                releaseNotice = Chan!string.init; // sent once
                fetchedNotice = null;
            }
            if (releaseNotice && releaseNotice.tryTake(fetchedNotice)) showNotice();
            // An idle compaction is due once the prompt (and any draft) sat
            // untouched for the hold, unless the exit window is armed (#186).
            auto promptShown = monoNow;
            auto idleHold = idleCompactHoldFor(cfg);
            bool idleNow() @safe
            {
                return deliverIdleCompact(agent.idleCompactDuePolled(), monoNow - ed.quietSince(promptShown),
                    idleHold, false, exitPress.armed);
            }
            bool timerNow() @safe
            {
                return deliverDueTimer(agent.timers.anyDue(agent.timerNow()), ed.holdsTimer(monoNow), false,
                    exitPress.armed);
            }
            // A finished background sub-agent's result runs as a turn, like a
            // fired timer (issue #266); polling also serves their tool calls.
            bool subNow() @safe
            {
                return deliverDueTimer(agent.backgroundResultsReady(), ed.holdsTimer(monoNow), false, exitPress.armed);
            }
            // Esc Esc at the idle prompt stops background sub-agents.
            bool stopBackground;
            ed.onIdleEscEsc = () @safe { if (agent.subagentsActive) stopBackground = true; };
            lapse = () @safe => exitPress.deadline.match!(d => monoMs() > d, () => false)
                || stopBackground
                || timerNow()
                || subNow()
                || idleNow()
                || (updateHints && updateHints.tryTake(updateHint))
                || (releaseNotice && releaseNotice.tryTake(fetchedNotice));
            auto r = ed.readLine(.stamp(false) ~ "› ", console.stamp() ~ glyphMark ~ " ", false, lapse);
            ed.restyle = null;
            syncMode(); // Shift-Tab at the prompt switched the mode
            ed.onIdleEscEsc = null;
            // Show a hint or notice the lapse already took before anything else:
            // the timer and idle branches below would otherwise drop it, and the
            // channel can't deliver it again.
            immutable shownHint = updateHint.length || fetchedNotice.length;
            if (updateHint.length) writeln(console.dim(updateHint));
            updateHint = null;
            if (fetchedNotice.length) showNotice();
            // Honour an idle Esc Esc whatever ended the read (a line typed
            // before the lapse check keeps its text).
            if (stopBackground)
            {
                agent.stopSubagents();
                writeln(console.dim("[background sub-agents stopped]"));
                if (r.outcome == Outcome.stopped) { quietPrompt = true; continue; }
            }
            if (r.outcome == Outcome.eof) break;
            if (r.outcome == Outcome.stopped && timerNow())
            {
                // Park a stale draft so the timer turn can't take it as a steer.
                hasParkedDraft = ed.parkDraft(parkedDraft);
                string notice;
                line = agent.takeFiredTimers(notice);
                writeln(console.dim(notice));
                agent.automaticInput = true;
                line = "\x00" ~ line;
            }
            else if (r.outcome == Outcome.stopped && subNow())
            {
                hasParkedDraft = ed.parkDraft(parkedDraft);
                string notice;
                line = agent.takeBackgroundResults(notice);
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
            else if (r.outcome == Outcome.stopped && shownHint)
            {
                quietPrompt = true;
                continue;
            }
            else if (r.outcome == Outcome.stopped)
            {
                exitPress.disarm(); // window lapsed: drop the hint, re-arm on the next press
                quietPrompt = true;
                continue;
            }
            if (r.outcome == Outcome.interrupt)
            {
                if (exitPress.press(monoMs())) break;
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
            line = inbox ? plainLine() : stdinLine();
            // Headless --wait-timers: input is done, but pending timers still
            // run, each as the next prompt, until none are left (#150).
            if (line is null && suppressEofForTimers(o.waitTimers, interactive))
                line = awaitTimerTurn();
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
                        ~ "(/help lists commands and their arguments)", JSONValue(input).jsonText(JSONOptions.doNotEscapeSlashes)));
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
                    try agent.restartWith(() => o.noSession ? Option!SessionLog(none)
                            : some(new SessionLog(sessionDir, agent.client.providerName ~ "/" ~ agent.client.modelName, cwd)),
                        () => systemFor(cwd, false));
                    catch (Exception e) { writeln(console.red("error: " ~ e.msg)); continue; }
                    auto log = agent.log;
                    updateStatus((ref Stats s) { s.historySearches = s.historyReads = 0; });
                    agent.useHooks(loadHooks(cwd), false);
                    if (gFrame) gFrame.clear();
                    refreshStatus();
                    log.match!(l => writefln("Session: %s (resume with nano-coder --resume %s)", l.id, l.id),
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
                    // exec doesn't return, so the scope guard can't collect them.
                    agent.stopSubagents();
                    auto exe = launchExe();
                    // Printed after the frame hands the terminal back, so it stays on screen.
                    if (gFrame) gFrame.suspend();
                    writefln("\nRelaunching into session %s (resume later with nano-coder --resume %s)", id, id);
                    stdOut.flush();
                    leaveKeyMode();
                    nano.herdr.release();
                    auto err = execProgram(exe, [exe] ~ relaunchArgv(args[1 .. $], id));
                    nano.herdr.reacquire();
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
                    import nano.thinking : statusText, sessionSetting;
                    if (arg.length)
                    {
                        auto setting = sessionSetting(arg);
                        if (setting.isErr) { writeln(setting.unwrapErr("isErr")); continue; }
                        agent.sessionThinking = setting.unwrap("isOk");
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
                    writeln(planText(agent, console.renderMarkdown));
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
                    parseMode(arg).match!((m) {
                        agent.control.mode = m;
                        syncMode();
                        writefln("Mode set to %s (%s)", m.name, m.describe);
                    }, e => writeln(e));
                    continue;
                case "/version":
                    writeln(versionString);
                    continue;
                case "/subagents":
                    writeln(escapeMarks(sanitizeBlock(subagentsCommand(agent, cfg, arg))));
                    continue;
                case "/changes":
                {
                    // No fetch here: it would block the prompt; notes the build
                    // lacks give a compare link.
                    import nano.release_notes : changesCommand, embedded;
                    import std.array : join;
                    writeln(changesCommand(arg, packageVersion, embedded()).join("\n"));
                    continue;
                }
                case "/tools":
                    writeln(escapeMarks(toolsListing(agent)));
                    continue;
                case "/skills":
                    writeln(escapeMarks(skillsListing(skills)));
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
                    // findSession also resolves a compressed (archived) log.
                    string path;
                    bool ok;
                    try { validateId(id); path = nano.session.findSession(sessionDir, id); ok = path.isFile; }
                    catch (Exception) {} // an invalid ID or unreadable path is reported as "no saved session" just below
                    if (!ok) { writefln("No saved session %s: /resume without an ID lists them", JSONValue(id).jsonText); continue; }
                    string[] loadNotes;
                    agent.stopSubagents(); // they belong to the session being left
                    try loadNotes = loadSession(path);
                    catch (Exception e) { writeln(e.msg); continue; }
                    if (gFrame) { gFrame.clear(); replayTranscript(agent, console); releaseHeap(); }
                    foreach (n; loadNotes) stdErr.writeln(n);
                    stdErr.flush();
                    writefln("Resumed session %s (resume later with nano-coder --resume %s)", id, id);
                    continue;
                }
                case "/trajectory":
                {
                    static import nano.trajectory;
                    string logPath = agent.log.match!(l => l.path, () => string.init);
                    if (!logPath.length) { writeln("Session persistence is disabled: no trajectory to show"); continue; }
                    if (arg.length && arg != "--json" && arg != "--markdown" && arg != "--md")
                    {
                        writefln("Unknown option %s; use /trajectory [--json|--markdown]", JSONValue(arg).jsonText);
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
                    {
                        import nano.memory : memoryCommand;
                        auto store = memory.unwrap("checked on the line above");
                        // Plan mode has no memory_save tool, and can't forget.
                        auto plan = agent.control.mode == AgentMode.plan;
                        write(memoryCommand(store, arg, memoryWritable, plan, cfg.memory == MemoryMode.on));
                    }
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

// rust: ui.rs::truncation_guard_tracks_suppressed_deltas_not_quiet_start, ui.rs::entering_quiet_alone_does_not_flag_truncation
unittest
{
    auto was = verbosity;
    scope (exit) setVerbosity(was);
    auto c = new Console(false);
    setVerbosity(Verbosity.quiet);
    c.beginAnswerGuard();
    setVerbosity(Verbosity.normal);
    assert(!c.answerMayBeTruncated, "a quiet start with no suppressed delta must not flag truncation");
    setVerbosity(Verbosity.quiet);
    c.beginAnswerGuard();
    c.text(false, "hello");
    assert(c.answerMayBeTruncated, "a suppressed non-empty delta flags truncation");
}

// rust: ui.rs::truncation_guard_resets_per_answer_segment, ui.rs::non_streamed_final_message_clears_an_earlier_suppressed_segments_guard
unittest
{
    auto was = verbosity;
    scope (exit) setVerbosity(was);
    auto c = new Console(false);
    setVerbosity(Verbosity.quiet);
    c.beginAnswerGuard();
    c.text(false, "intermediate");
    assert(c.answerMayBeTruncated, "the suppressed intermediate delta flags truncation");
    c.assistantMessage("intermediate", null);
    setVerbosity(Verbosity.normal);
    // Normal deltas go to the screen; only the guard matters here, so the
    // final segment is a non-streamed message (the quiet-start case below
    // streams quietly).
    c.assistantMessage("final answer", null);
    assert(!c.answerMayBeTruncated, "a final message after an earlier quiet segment must not be reprinted");

    setVerbosity(Verbosity.quiet);
    c.beginAnswerGuard();
    c.text(false, "A");
    c.assistantMessage("A", null);
    c.text(false, "final prefix");
    assert(c.answerMayBeTruncated, "a final answer whose own prefix was suppressed must be reprinted");
    c.responseRestarted();
    assert(!c.answerMayBeTruncated, "a restart discards the dropped partial");
}

// rust: ui.rs::summarizes_tool_calls
unittest
{
    ToolCall c;
    c.name = "bash";
    c.arguments = parseJSON(`{"command":"ls\n  -la"}`);
    assert(Console.summary(c) == "ls -la");
    c.arguments = parseJSON(`{}`);
    assert(Console.summary(c) == "");
    assert(fitText("abcdef", 4) == "abc…");
    import std.array : replicate;
    c.arguments = parseJSON(`{"path":"` ~ "é".replicate(200) ~ `"}`);
    import std.utf : validate;
    validate(Console.summary(c));
}

// rust: ui.rs::tool_args_text_keeps_malformed_arguments_verbatim
unittest
{
    auto bad = ToolCall.fromRaw("c1", "bash", `{"command": "ls",`);
    assert(bad.invalidArguments.length && argsText(bad) == `{"command": "ls",`);
    ToolCall ok;
    ok.arguments = parseJSON(`{"command":"ls"}`);
    assert(argsText(ok) == ok.arguments.toPrettyString);
    ok.arguments = parseJSON(`{}`);
    assert(argsText(ok) == "");
}

// rust: ui.rs::quiet_assistant_message_closes_the_plain_stream, ui.rs::response_restart_resets_the_plain_stream
unittest
{
    auto was = verbosity;
    scope (exit) setVerbosity(was);
    auto c = new Console(false);
    void streaming() { c.link.screen.update((ref Screen s) { s.answering = true; s.midLine = true; }); }
    bool closed()
    {
        bool r;
        c.link.screen.update((ref Screen s) { r = !s.answering && !s.midLine; });
        return r;
    }
    setVerbosity(Verbosity.normal);
    streaming();
    setVerbosity(Verbosity.quiet);
    c.assistantMessage("first", null);
    assert(closed, "a quiet-closed segment ends the line and the stream");
    setVerbosity(Verbosity.normal);
    streaming();
    c.responseRestarted();
    assert(closed, "a restart closes the abandoned partial");
}

// rust: main.rs::next_step_setting_accepts_any_whitespace_separator
unittest
{
    import std.algorithm : canFind, startsWith;
    import nano.option : notNull;
    Config c;
    auto ctx = MidTurn(notNull(new shared TurnControl), LiveView.make, [frozenConfig(c)]);
    foreach (sep; ["\t", "\n", "\x0b", "  ", " "])
    {
        auto note = midTurnCommand("/mode" ~ sep ~ "plan", ctx);
        assert(note.startsWith("Mode set to"), "separator not recognised: " ~ note);
    }
    assert(midTurnCommand("/mode bogus", ctx).canFind("bogus"), "a bad mode is reported");
    assert(midTurnCommand("/modex plan", ctx) is null, "not a setting: held for after the turn");
}

// Read-only commands mid-turn show what the agent thread last rendered
// after a step (refreshView), so they follow the live stats, plan and timers;
// /trajectory without a session log says so, whatever whitespace splits it.
// rust: turn_commands.rs::non_space_whitespace_routes_like_a_space
// rust: turn_commands.rs::trajectory_without_a_session_says_so
// rust: turn_commands.rs::output_uses_the_live_stats_and_plan
// rust: turn_commands.rs::context_window_source_follows_live_stats
unittest
{
    import std.algorithm : canFind, startsWith;
    import nano.option : notNull;
    Config c;
    auto ctx = MidTurn(notNull(new shared TurnControl), LiveView.make, [frozenConfig(c)]);
    foreach (cmd; ["/trajectory", "/trajectory --json", "/trajectory\t--json", "/trajectory\t"])
        assert(midTurnCommand(cmd, ctx).canFind("Session persistence is disabled"), cmd);
    assert(midTurnCommand("/trajectory\t--json", ctx) == midTurnCommand("/trajectory --json", ctx));
    ctx.view.set("/context", "500 of 1000 tokens (context window known for the model name)");
    assert(midTurnCommand("/context", ctx).canFind("known for the model name"));
    ctx.view.set("/context", "500 of 8000 tokens (context window learned from a context-overflow error)");
    assert(midTurnCommand("/context", ctx).canFind("learned from a context-overflow error"), "the latest render is shown");
    ctx.view.set("/plan", "1. write the tests");
    assert(midTurnCommand("/plan", ctx).canFind("write the tests"));
    atomicLoad(ctx.control).mode = AgentMode.plan;
    assert(midTurnCommand("/mode", ctx).startsWith("Mode: plan"), midTurnCommand("/mode", ctx));
    assert(midTurnCommand("/compact", ctx) is null && midTurnCommand("/plan extra", ctx) is null);
}

// Model-supplied tool arguments with literal wrap marks reach the transcript
// as U+FFFD, never as metadata that changes how the row wraps or is copied.
unittest
{
    import std.algorithm : canFind;
    import std.json : parseJSON;
    import nano.frame : Transcript, softWrapMark, verbatimMark, sepWrapMark;
    import nano.llm : ToolCall;
    foreach (m; [softWrapMark, verbatimMark, sepWrapMark])
    {
        ToolCall c;
        c.name = "bash";
        c.arguments = parseJSON(`{"command":"cat /tmp/a` ~ m ~ `b"}`);
        auto s = Console.summary(c);
        assert(!s.canFind(m) && s.canFind("a\uFFFDb"), s);
        Transcript t;
        t.feed(cast(const(ubyte)[]) ("● bash " ~ s ~ "\n"));
        assert(t.lines.length == 1 && !t.lines[0].canFind(m) && t.lines[0].canFind("\uFFFD"), t.lines[0]);
        assert(escapeMarks("↪ x" ~ m) == "↪ x\uFFFD");
    }
}

// Piped (non-frame) answers keep the model's bytes verbatim; only the
// frame transcript neutralises control bytes.
unittest
{
    Screen s;
    s.capturing = true;
    assert(rawShownIn("a\x1b[1mb\rc\x07", false) == "a\x1b[1mb\rc\x07");
    s.text(false, "x\x1by\r");
    import std.algorithm : canFind;
    assert(s.captured.canFind("x\x1by\r"), s.captured);
    s.testFrame = true;
    assert(rawShownIn("a\x1bb", true) != "a\x1bb");
}

// Expanded (verbose) reasoning in the frame can't forge a refold mark
// with raw ESC/BEL bytes, nor a wrap mark with private-use chars.
unittest
{
    import std.algorithm : canFind;
    Screen s;
    s.capturing = true;
    s.testFrame = true;
    auto prev = verbosity();
    setVerbosity(Verbosity.verbose);
    scope (exit) setVerbosity(prev);
    s.text(true, "x\x1b]8771;Zm9v;bar\x07y\uE002z");
    assert(!s.captured.canFind("\x1b]8771;Zm9v"), s.captured);
    assert(!s.captured.canFind("\x07y"), s.captured);
    assert(!s.captured.canFind("\uE002"), s.captured);
}
