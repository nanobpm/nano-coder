/// Steering and cancellation for the running turn (Rust `TurnControl`).
///
/// A TurnControl is shared between the thread running the agent and the
/// threads that read input (the REPL's stdin reader, the ACP reader, or a
/// SIGINT handler). `cancel` raises a flag that the agent checks between
/// steps. Blocking work polls `cancelRequested`, so libcurl aborts its
/// transfer and bash kills the command's process group.
///
/// Only one turn runs per process at a time, so the flag that blocking work
/// polls is process-wide.
module nano.control;

@safe:

import std.algorithm : countUntil;

import nano.safeio : lossyText;

import std.conv : to;

import nano.arith : toSize;

import std.string : representation;

import nano.option : NotNull;
import core.atomic : atomicLoad, atomicStore;
import core.time : MonoTime;
import nano.clock : monoNow;

/// The result recorded for tool calls skipped because of a cancel.
enum string cancelledToolResult = "Error: the turn was cancelled before this tool call ran.";
/// The response of a cancelled turn.
enum string cancelledResponse = "[turn cancelled]";

private shared bool gCancel;

/// A narrower cancellation scope than the process-wide flag: a sub-agent's
/// per-child abort. Blocking work (the HTTP client, retry waits) polls the
/// innermost scope on its thread first, so a parent stopping one child
/// interrupts that child's in-flight request without cancelling its own
/// turn. A scope is a `shared(bool)*` the child publishes and the parent's
/// `SubAbort.abort` sets; `pushCancelScope`/`popCancelScope` install it on
/// the child's thread (its whole run sits inside).
///
/// The stack is thread-local: several children run at once, and a shared
/// stack would let one child's pop remove a sibling's scope and make every
/// thread's `cancelRequested` poll the top child's abort cell — stopping
/// one child would cancel the parent's turn and its siblings. Thread-local,
/// only the pushing thread's blocking work sees the scope.
private shared(bool)*[256] cancelScopes;
private size_t cancelScopeDepth;
/// This thread's cancellation deadline (`MonoTime.max`: none). Thread-local
/// like the scope stack: a background probe sets one so its blocking calls
/// bail on their own once it passes, whether or not the owner polls.
private MonoTime cancelDeadline = MonoTime.max;

/// Whether the running turn has been cancelled. Safe from any thread or a
/// signal handler. Blocking tools and the HTTP client poll this.
bool cancelRequested() @safe nothrow @nogc
{
    if (cancelScopeDepth > 0)
    {
        auto scope_ = cancelScopes[cancelScopeDepth - 1];
        if (scope_ !is null && atomicLoad(*scope_)) return true;
    }
    if (cancelDeadline != MonoTime.max && monoNow >= cancelDeadline) return true;
    return atomicLoad(gCancel);
}

/// Poll `scope_` first on this thread until `popCancelScope`. The
/// parameter is escaping (not `scope`), so DIP1000 rejects a pointer to a
/// stack local from a `@safe` caller: only a GC-owned flag (the child's
/// abort cell) can be installed, and it lives as long as the slot does.
void pushCancelScope(shared(bool)* scope_) @safe nothrow @nogc
{
    if (cancelScopeDepth >= cancelScopes.length) return; // deeper than ever nested: fall back to the global flag
    cancelScopes[cancelScopeDepth] = scope_;
    cancelScopeDepth++;
}

/// Cancel this thread's blocking work once `monoNow` reaches `at`
/// (`MonoTime.max` clears it). Thread-local, so it never affects the turn.
void setCancelDeadline(MonoTime at) @safe nothrow @nogc
{
    cancelDeadline = at;
}

/// Whether this thread's cancellation deadline has passed.
bool pastCancelDeadline() @safe nothrow @nogc
{
    return cancelDeadline != MonoTime.max && monoNow >= cancelDeadline;
}

/// Remove the scope `pushCancelScope` installed (LIFO, on this thread).
void popCancelScope() @safe nothrow @nogc
{
    if (cancelScopeDepth == 0) return;
    cancelScopeDepth--;
    cancelScopes[cancelScopeDepth] = null;
}

/// Raised inside the agent when a cancel interrupts a model call.
class Cancelled : Exception
{
    /// Usage the provider reported before the cancel (e.g. a usage chunk),
    /// so it is still counted (issue #340). Zero when none arrived.
    imported!"nano.llm".TokenUsage usage;
    this() pure nothrow @safe { super(cancelledResponse); }
}

unittest
{
    // A thread deadline cancels this thread's blocking work once it passes.
    import core.time : seconds;
    import std.datetime.date : DateTime;
    import std.datetime.systime : SysTime;
    import std.datetime.timezone : UTC;
    import nano.clock : FakeClock;
    auto clock = FakeClock.install(SysTime(DateTime(2026, 1, 2, 3, 4, 5), UTC()));
    setCancelDeadline(monoNow + 5.seconds);
    assert(!cancelRequested && !pastCancelDeadline);
    clock.advance(5.seconds);
    assert(cancelRequested && pastCancelDeadline);
    setCancelDeadline(MonoTime.max);
    assert(!cancelRequested && !pastCancelDeadline);
}

unittest
{
    import core.atomic : atomicLoad, atomicStore;
    assert(!cancelRequested);
    auto hit = new shared bool;
    pushCancelScope(hit);
    assert(!cancelRequested);
    atomicStore(*hit, true);
    assert(cancelRequested);
    popCancelScope();
    // A stack flag cannot be installed: the parameter escapes.
    static assert(!__traits(compiles, () @safe { shared bool local; pushCancelScope(&local); }));
    assert(!cancelRequested);
    // A null slot falls back to the flag.
    pushCancelScope(null);
    assert(!cancelRequested);
    popCancelScope();
}

unittest
{
    // The scope stack is thread-local: a child's scope neither leaks onto
    // the parent thread nor is popped by a sibling. Two "children" run at
    // once; aborting one must not cancel the other or the parent.
    import core.atomic : atomicStore;
    import nano.safeio : Chan, spawn;
    static struct Go
    {
        shared(bool)* abortCell;
        Chan!bool entered, leave;
        Chan!bool seenCancelled;
    }
    static void child(Go g)
    {
        pushCancelScope(g.abortCell);
        g.entered.put(true);
        bool stop;
        g.leave.take(stop);
        g.seenCancelled.put(cancelRequested);
        popCancelScope();
    }
    // Heap-allocated so the `Chan` members are not `scope` on the copy
    // `spawn` makes.
    auto abortA = new shared bool;
    auto abortB = new shared bool;
    auto a = new Go(abortA, Chan!bool.make, Chan!bool.make, Chan!bool.make);
    auto b = new Go(abortB, Chan!bool.make, Chan!bool.make, Chan!bool.make);
    auto ha = spawn(&child, *a);
    auto hb = spawn(&child, *b);
    bool got;
    a.entered.take(got);
    b.entered.take(got);
    // Both scopes are live on their own threads; the parent sees neither.
    assert(!cancelRequested);
    atomicStore(*abortA, true);
    a.leave.put(true);
    b.leave.put(true);
    bool seenA, seenB;
    a.seenCancelled.take(seenA);
    b.seenCancelled.take(seenB);
    ha.join();
    hb.join();
    assert(seenA, "the aborted child sees its own scope");
    assert(!seenB, "a sibling's abort does not reach this child");
    assert(!cancelRequested, "no scope leaks onto the parent thread");
}

/// A steering message. `tag` is the ACP request id that sent it, if any. It is
/// kept as JSON text so a `Steer` holds no mutable references and can cross
/// threads.
struct Steer
{
    import std.json : JSONValue;
    string text;
    private string tagJson;
    /// The interactive queue id (shared with queued messages) so `/queue`
    /// can list, edit or withdraw the steer before the agent reads it; -1
    /// for none (ACP and piped steers).
    long id = -1;
    /// Sent by a peer session (issue #272): a turn that reads it, or runs
    /// it later as a prompt, keeps the peer loop guard.
    bool fromPeer;
    /// The sending peer's full session id (empty unless `fromPeer`).
    string sender;
    /// The peer message's hop and thread (issue #350; 0/null unless `fromPeer`).
    uint hop;
    /// ditto
    string thread;

    this(string text, JSONValue tag = JSONValue.init)
    {
        import std.json : JSONType;
        this.text = text;
        if (tag.type != JSONType.null_) tagJson = tag.toString;
    }

    /// The ACP request id, or JSON null.
    JSONValue tag() pure const
    {
        import std.json : parseJSON;
        return tagJson is null ? JSONValue.init : parseJSON(tagJson);
    }
}

import nano.mode : AgentMode;

/// Live controls for the running turn, shared by the turn and the threads
/// that steer or cancel it. Every member is `shared`: state sits in a
/// `Locked`, the mode in an atomic, so the compiler checks each access.
final class TurnControl
{
    import nano.safeio : Locked;
    private static struct State
    {
        immutable(Steer)[] steers, absorbed;
        string modelRequest;
        /// A `/thinking` argument typed mid-turn (null: none).
        string thinkingRequest;
        /// A `/subagents on|off` typed mid-turn: 0 none, 1 on, 2 off.
        int subagentsRequest;
    }
    private NotNull!(shared Locked!State) state;
    private int mode_;

    this() shared { state = new shared Locked!State; }

    /// The live agent mode; the running turn reads it at each iteration.
    AgentMode mode() pure shared { return atomicLoad(mode_).to!AgentMode; }

    /// Change the live mode (from the key reader or a command).
    void mode(AgentMode m) pure shared { atomicStore(mode_, int(m)); }

    /// Ask the running turn to switch model (`/model` mid-turn).
    void requestModel(string spec) shared { state.update((ref State s) { s.modelRequest = spec; }); }

    /// Ask the running turn to use a thinking level (`/thinking` mid-turn):
    /// the argument as typed (a level, `default`, `off` or `reset`).
    void requestThinking(string arg) shared { state.update((ref State s) { s.thinkingRequest = arg; }); }

    /// Ask the running turn to switch the `agent` tool on or off from its
    /// next model request (`/subagents on|off` mid-turn).
    void requestSubagents(bool on) shared { state.update((ref State s) { s.subagentsRequest = on ? 1 : 2; }); }

    /// The pending `/subagents` request, cleared: 0 none, 1 on, 2 off.
    int takeSubagentsRequest() shared
    {
        int r;
        state.update((ref State s) { r = s.subagentsRequest; s.subagentsRequest = 0; });
        return r;
    }

    /// The pending thinking request, cleared; null when none.
    string takeThinkingRequest() shared
    {
        string r;
        state.update((ref State s) { r = s.thinkingRequest; s.thinkingRequest = null; });
        return r;
    }

    /// The pending model request, cleared; null when none.
    string takeModelRequest() shared
    {
        string r;
        state.update((ref State s) { r = s.modelRequest; s.modelRequest = null; });
        return r;
    }

    /// Queue a steering message for the running turn.
    void steer(string text) shared { steer(Steer(text)); }

    /// ditto
    void steer(Steer m) shared { state.update((ref State s) { s.steers ~= m; }); }

    /// Queue a steer carrying a `/queue` id, so it can be edited or
    /// withdrawn until the agent reads it.
    void steerWithId(string text, size_t id, bool fromPeer = false, string sender = null,
        uint hop = 0, string thread = null) shared
    {
        auto m = Steer(text);
        m.id = id;
        m.fromPeer = fromPeer;
        m.sender = sender;
        m.hop = hop;
        m.thread = thread;
        steer(m);
    }

    /// Withdraw every unread peer steer (its session is being left, so it
    /// must not reach the next one); returns how many.
    size_t dropPeerSteers() shared
    {
        import std.algorithm : filter;
        import std.array : array;
        return state.update!size_t((ref State s) {
            auto before = s.steers.length;
            s.steers = s.steers.filter!(m => !m.fromPeer).array;
            return before - s.steers.length;
        });
    }

    /// Bytes held by unread steers, so a sender that can add them (a peer
    /// session) is admitted against a budget that frees as they are read.
    size_t pendingSteerBytes() shared
    {
        size_t n;
        foreach (m; state.get.steers) n += m.text.length + m.sender.length + m.thread.length;
        return n;
    }

    /// Id-carrying steers the agent has not read yet, oldest first.
    immutable(Steer)[] pendingSteers() shared
    {
        import std.algorithm : filter;
        import std.array : array;
        return state.get.steers.filter!(m => m.id >= 0).array;
    }

    /// Withdraw unread steers by id; returns how many were removed. A steer
    /// the agent already read is gone from the list, so it is not counted.
    size_t removeSteers(const size_t[] ids) shared
    {
        import std.algorithm : canFind, filter;
        import std.array : array;
        return state.update!size_t((ref State s) {
            auto before = s.steers.length;
            s.steers = s.steers.filter!(m => m.id < 0 || !ids.canFind(toSize(m.id))).array;
            return before - s.steers.length;
        });
    }

    /// Rewrite an unread steer; false when none has that id (never sent, or
    /// already read by the agent).
    bool editSteer(size_t id, string text) shared
    {
        return state.update!bool((ref State s) {
            foreach (i, m; s.steers)
                if (m.id >= 0 && m.id == id)
                {
                    Steer edited = m;
                    edited.text = text;
                    s.steers = s.steers[0 .. i] ~ edited ~ s.steers[i + 1 .. $];
                    return true;
                }
            return false;
        });
    }

    /// Withdraw every unread id-carrying steer; returns how many.
    size_t clearSteers() shared
    {
        import std.algorithm : filter;
        import std.array : array;
        return state.update!size_t((ref State s) {
            auto before = s.steers.length;
            s.steers = s.steers.filter!(m => m.id < 0).array;
            return before - s.steers.length;
        });
    }

    /// Whether steering messages are waiting.
    bool hasSteers() shared { return state.get.steers.length > 0; }

    /// The waiting steering messages, cleared.
    Steer[] takePending() shared
    {
        Steer[] r;
        state.update((ref State s) { r = s.steers.dup; s.steers = null; });
        return r;
    }

    /// Record a steering message the turn took in.
    void absorbed(Steer m) shared { state.update((ref State s) { s.absorbed ~= m; }); }

    /// The steering messages taken in this turn, cleared.
    Steer[] takeAbsorbed() shared
    {
        Steer[] r;
        state.update((ref State s) { r = s.absorbed.dup; s.absorbed = null; });
        return r;
    }

    /// Cancel the running turn. Safe from a signal handler.
    void cancel() shared nothrow @nogc { atomicStore(gCancel, true); }

    /// Whether the running turn was cancelled.
    bool isCancelled() shared nothrow @nogc { return cancelRequested(); }

    /// Clear a previous cancel. Called when a turn begins.
    void startTurn() shared
    {
        atomicStore(gCancel, false);
        state.update((ref State s) { s.absorbed = null; });
    }
}

unittest
{
    auto c = new shared TurnControl;
    c.startTurn();
    assert(!c.isCancelled && !c.hasSteers);
    c.steer("a");
    c.steer("b");
    assert(c.takePending == [Steer("a"), Steer("b")] && !c.hasSteers);
    c.cancel();
    assert(cancelRequested);
    c.startTurn();
    assert(!cancelRequested);
}

/// Reads lines from a file descriptor with raw read(2), bypassing std.stdio.
///
/// A thread blocked in `readln` holds stdin's FILE lock, and std.process's
/// spawnProcess flushes (so locks) every stdio stream before forking, so a
/// stdin reader thread must not use std.stdio or tool commands deadlock.
struct FdLineReader
{
    int fd;
    private ubyte[] pending;
    private bool eof;

    /// The next line without its newline; null at end of input.
    string next()
    {
        import nano.safeio : readFd;
        import std.string : indexOf;
        for (;;)
        {
            auto nl = pending.countUntil(ubyte('\n'));
            if (nl >= 0)
            {
                auto line = lossyText(pending[0 .. nl]);
                pending = pending[nl + 1 .. $];
                return line.length ? line : "";
            }
            if (eof)
            {
                auto rest = pending;
                pending = null;
                return rest.length ? lossyText(rest) : null;
            }
            ubyte[65536] buf;
            auto n = readFd(fd, buf[]);
            if (n <= 0) eof = true;
            else pending ~= buf[0 .. n];
        }
    }
}

unittest
{
    import nano.safeio : closeFd, pipeFds, writeFd;
    alias close = closeFd;
    int[2] fds;
    assert(pipeFds(fds) == 0);
    auto data = "a\n\nbc\nlast";
    writeFd(fds[1], data.representation);
    close(fds[1]);
    auto r = FdLineReader(fds[0]);
    assert(r.next == "a" && r.next == "" && r.next == "bc" && r.next == "last" && r.next is null);
    close(fds[0]);
}

unittest
{
    // Invalid UTF-8 becomes U+FFFD as the line is read, so the `string`
    // handed on always decodes.
    import nano.safeio : closeFd, pipeFds, writeFd;
    import std.utf : validate;
    int[2] fds;
    assert(pipeFds(fds) == 0);
    ubyte[] data = [0x61, 0xff, 0x0a, 0xe2, 0x82];
    writeFd(fds[1], data);
    closeFd(fds[1]);
    auto r = FdLineReader(fds[0]);
    assert(r.next == "a\uFFFD");
    auto last = r.next;
    validate(last);
    assert(last == "\uFFFD\uFFFD" && r.next is null);
    closeFd(fds[0]);
}

// A peer steer's budget counts its retained sender id too: a huge id with a
// tiny body must not slip past the byte cap.
unittest
{
    auto c = new shared TurnControl;
    import std.array : replicate;
    c.steerWithId("hi", 1, true, "x".replicate(1000));
    assert(c.pendingSteerBytes == 1002);
}
