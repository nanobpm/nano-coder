/// Slash commands that can run while a turn is in flight (turn_commands.rs).
///
/// During a turn the agent runs on the main thread while the key reader runs
/// on its own, so the reader must not touch agent state. Read-only commands
/// instead show text the agent thread renders into a `LiveView` (at turn
/// start, after each model call and tool, and when the plan changes);
/// settings go through `TurnControl`, which the agent reads at its next step.
module nano.turn_commands;

@safe:

import std.string : strip, indexOf;
import std.algorithm : canFind;

/// Split a trimmed `/…` line into its name and trimmed argument on the first
/// whitespace, so `/trajectory\t--json` classifies like `/trajectory --json`.
string[2] splitCmd(string cmd)
{
    foreach (i, char c; cmd)
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
            return [cmd[0 .. i], cmd[i + 1 .. $].strip];
    return [cmd, ""];
}

/// When a command can run relative to a turn in flight.
enum Timing
{
    /// Read-only: runs straight away from the live view.
    immediate,
    /// A setting the agent reads at its next step (`/mode NAME`, `/model SPEC`).
    nextStep,
    /// Changes the conversation, owns the keyboard, or needs the agent: waits.
    afterTurn,
}

/// When `cmd` (a trimmed `/…` line) can run during a turn (Rust's table).
Timing timing(string cmd)
{
    auto p = splitCmd(cmd);
    auto name = p[0], arg = p[1];
    if (["/help", "/tools", "/skills", "/providers", "/session", "/plan", "/context"].canFind(name) && !arg.length)
        return Timing.immediate;
    if (name == "/trajectory" && ["", "--json", "--markdown", "--md"].canFind(arg)) return Timing.immediate;
    if (name == "/mode" || name == "/verbosity") return arg.length ? Timing.nextStep : Timing.immediate;
    if (name == "/model") return arg.length ? Timing.nextStep : Timing.afterTurn;
    return Timing.afterTurn;
}

/// Text for the read-only commands, rendered on the agent thread and read on
/// the key reader's.
final class LiveView
{
    private string[string] texts;

    void set(string name, string text) @trusted
    {
        synchronized (this) texts[name] = text;
    }

    /// The text for `/name`, or null when none was rendered.
    string get(string name) @trusted
    {
        synchronized (this)
        {
            if (auto t = name in texts) return *t;
            return null;
        }
    }
}

unittest
{
    assert(splitCmd("/trajectory\t--json") == ["/trajectory", "--json"]);
    assert(splitCmd("/plan") == ["/plan", ""]);
    assert(splitCmd("/mode   auto ") == ["/mode", "auto"]);
    with (Timing)
    {
        assert(timing("/help") == immediate && timing("/context") == immediate);
        assert(timing("/plan") == immediate && timing("/plan x") == afterTurn);
        assert(timing("/trajectory") == immediate && timing("/trajectory\t--md") == immediate);
        assert(timing("/trajectory --bogus") == afterTurn);
        assert(timing("/mode") == immediate && timing("/mode plan") == nextStep);
        assert(timing("/model") == afterTurn && timing("/model mock/x") == nextStep);
        assert(timing("/compact") == afterTurn && timing("/restart") == afterTurn && timing("/resume") == afterTurn);
    }
    auto v = new LiveView;
    assert(v.get("/plan") is null);
    v.set("/plan", "p");
    assert(v.get("/plan") == "p");
}
