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

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;

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

/// A steering message. `tag` is the ACP request id that sent it, if any.
struct Steer
{
    string text;
    import std.json : JSONValue;
    JSONValue tag;
}

final class TurnControl
{
    private Mutex lock;
    private Steer[] steers;
    private Steer[] absorbed_;

    this() @trusted { lock = new Mutex; }

    /// Queue a message for the running turn. It is added before the next model call.
    void steer(string text) @trusted { steer(Steer(text)); }

    /// ditto
    void steer(Steer s) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        steers ~= s;
    }

    bool hasSteers() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        return steers.length > 0;
    }

    /// Steers not yet added to the conversation, oldest first.
    Steer[] takePending() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        auto out_ = steers;
        steers = null;
        return out_;
    }

    /// Record a steer the agent added to the conversation.
    void absorbed(Steer s) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        absorbed_ ~= s;
    }

    /// Steers added to the conversation since the turn began.
    Steer[] takeAbsorbed() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        auto out_ = absorbed_;
        absorbed_ = null;
        return out_;
    }

    /// Stop the turn at the next opportunity. Also safe from a signal handler.
    void cancel() @safe nothrow @nogc { atomicStore(gCancel, true); }

    bool isCancelled() @safe nothrow @nogc { return cancelRequested(); }

    /// Clear a previous cancel. Called when a turn begins.
    void startTurn() @trusted
    {
        atomicStore(gCancel, false);
        lock.lock();
        scope (exit) lock.unlock();
        absorbed_ = null;
    }
}

unittest
{
    auto c = new TurnControl;
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
    string next() @trusted
    {
        import core.sys.posix.unistd : read;
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
            auto n = read(fd, buf.ptr, buf.length);
            if (n <= 0) eof = true;
            else pending ~= cast(string) buf[0 .. n].idup;
        }
    }
}

@trusted unittest
{
    import core.sys.posix.unistd : pipe, write, close;
    int[2] fds;
    assert(pipe(fds) == 0);
    auto data = "a\n\nbc\nlast";
    write(fds[1], data.ptr, data.length);
    close(fds[1]);
    auto r = FdLineReader(fds[0]);
    assert(r.next == "a" && r.next == "" && r.next == "bc" && r.next == "last" && r.next is null);
    close(fds[0]);
}
