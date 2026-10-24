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

import core.atomic : atomicLoad, atomicStore;

/// The result recorded for tool calls skipped because of a cancel.
enum string cancelledToolResult = "Error: the turn was cancelled before this tool call ran.";
/// The response of a cancelled turn.
enum string cancelledResponse = "[turn cancelled]";

private shared bool gCancel;

/// Whether the running turn has been cancelled. Safe from any thread or a
/// signal handler. Blocking tools and the HTTP client poll this.
bool cancelRequested() @safe nothrow @nogc { return atomicLoad(gCancel); }

/// Raised inside the agent when a cancel interrupts a model call.
class Cancelled : Exception
{
    this() pure nothrow @safe { super(cancelledResponse); }
}

/// A steering message. `tag` is the ACP request id that sent it, if any. It is
/// kept as JSON text so a `Steer` holds no mutable references and can cross
/// threads.
struct Steer
{
    import std.json : JSONValue;
    string text;
    private string tagJson;

    this(string text, JSONValue tag = JSONValue.init)
    {
        import std.json : JSONType;
        this.text = text;
        if (tag.type != JSONType.null_) tagJson = tag.toString;
    }

    /// The ACP request id, or JSON null.
    JSONValue tag() const
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
    }
    private Locked!State state;
    private int mode_;

    this() shared { state = new shared Locked!State; }

    /// The live agent mode; the running turn reads it at each iteration.
    AgentMode mode() shared { return cast(AgentMode) atomicLoad(mode_); }

    /// Change the live mode (from the key reader or a command).
    void mode(AgentMode m) shared { atomicStore(mode_, cast(int) m); }

    /// Ask the running turn to switch model (`/model` mid-turn).
    void requestModel(string spec) shared { state.update((ref State s) { s.modelRequest = spec; }); }

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
    private string pending;
    private bool eof;

    /// The next line without its newline; null at end of input.
    string next()
    {
        import nano.safeio : readFd;
        import std.string : indexOf;
        for (;;)
        {
            auto nl = pending.indexOf('\n');
            if (nl >= 0)
            {
                auto line = pending[0 .. nl];
                pending = pending[nl + 1 .. $];
                return line;
            }
            if (eof)
            {
                auto rest = pending;
                pending = null;
                return rest.length ? rest : null;
            }
            ubyte[65536] buf;
            auto n = readFd(fd, buf[]);
            if (n <= 0) eof = true;
            else pending ~= cast(string) buf[0 .. n].idup;
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
    writeFd(fds[1], cast(const(ubyte)[]) data);
    close(fds[1]);
    auto r = FdLineReader(fds[0]);
    assert(r.next == "a" && r.next == "" && r.next == "bc" && r.next == "last" && r.next is null);
    close(fds[0]);
}
