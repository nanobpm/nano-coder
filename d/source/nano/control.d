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

final class TurnControl
{
    private Mutex lock;
    private string[] steers;

    this() @trusted { lock = new Mutex; }

    /// Queue a message for the running turn. It is added before the next model call.
    void steer(string text) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        steers ~= text;
    }

    bool hasSteers() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        return steers.length > 0;
    }

    /// Steers not yet added to the conversation, oldest first.
    string[] takePending() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        auto out_ = steers;
        steers = null;
        return out_;
    }

    /// Stop the turn at the next opportunity. Also safe from a signal handler.
    void cancel() @safe nothrow @nogc { atomicStore(gCancel, true); }

    bool isCancelled() @safe nothrow @nogc { return cancelRequested(); }

    /// Clear a previous cancel. Called when a turn begins.
    void startTurn() @safe nothrow @nogc { atomicStore(gCancel, false); }
}

unittest
{
    auto c = new TurnControl;
    c.startTurn();
    assert(!c.isCancelled && !c.hasSteers);
    c.steer("a");
    c.steer("b");
    assert(c.takePending == ["a", "b"] && !c.hasSteers);
    c.cancel();
    assert(cancelRequested);
    c.startTurn();
    assert(!cancelRequested);
}
