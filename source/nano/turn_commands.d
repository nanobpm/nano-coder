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
string[2] splitCmd(string cmd) pure nothrow
{
    import std.ascii : isWhite;
    // Any whitespace separates (a vertical tab too, as Rust's split_whitespace).
    foreach (i, char c; cmd)
        if (isWhite(c))
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
Timing timing(string cmd) pure nothrow
{
    auto p = splitCmd(cmd);
    auto name = p[0], arg = p[1];
    if (["/help", "/tools", "/skills", "/providers", "/session", "/plan", "/timers", "/context", "/version"].canFind(name) && !arg.length)
        return Timing.immediate;
    if (name == "/trajectory" && ["", "--json", "--markdown", "--md"].canFind(arg)) return Timing.immediate;
    if (name == "/mode" || name == "/verbosity") return arg.length ? Timing.nextStep : Timing.immediate;
    if (name == "/model") return arg.length ? Timing.nextStep : Timing.afterTurn;
    // `/thinking LEVEL` applies from the agent's next step; bare `/thinking`
    // lists the levels of the model in use, after the turn.
    if (name == "/thinking") return arg.length ? Timing.nextStep : Timing.afterTurn;
    // `/subagents on|off` changes the next request's tools; `--save` writes
    // the config, so it waits for the turn.
    if (name == "/subagents" && (arg == "on" || arg == "off")) return Timing.nextStep;
    return Timing.afterTurn;
}

/// Text for the read-only commands, rendered on the agent thread and read on
/// the key reader's.
struct LiveView
{
    import nano.safeio : Shared;
    private static struct State { immutable(string)[] names, texts; }
    private Shared!State state;

    /// A new, empty view.
    static LiveView make() { return LiveView(Shared!State.make); }

    void set(string name, string text)
    {
        state.update((ref State s) {
            foreach (i, n; s.names)
                if (n == name)
                {
                    s.texts = s.texts[0 .. i] ~ text ~ s.texts[i + 1 .. $];
                    return;
                }
            s.names ~= name;
            s.texts ~= text;
        });
    }

    /// The text for `/name`, or null when none was rendered.
    string get(string name)
    {
        auto s = state.get;
        foreach (i, n; s.names)
            if (n == name) return s.texts[i];
        return null;
    }
}

unittest
{
    assert(splitCmd("/trajectory\t--json") == ["/trajectory", "--json"]);
    assert(splitCmd("/plan") == ["/plan", ""]);
    assert(splitCmd("/mode   auto ") == ["/mode", "auto"]);
    with (Timing)
    {
        assert(timing("/version") == immediate && timing("/version x") != immediate);
        assert(timing("/help") == immediate && timing("/context") == immediate);
        assert(timing("/plan") == immediate && timing("/plan x") == afterTurn);
        assert(timing("/trajectory") == immediate && timing("/trajectory\t--md") == immediate);
        assert(timing("/trajectory --bogus") == afterTurn);
        assert(timing("/mode") == immediate && timing("/mode plan") == nextStep);
        assert(timing("/model") == afterTurn && timing("/model mock/x") == nextStep);
        assert(timing("/thinking") == afterTurn && timing("/thinking high") == nextStep);
        assert(timing("/subagents off") == nextStep && timing("/subagents on") == nextStep);
        assert(timing("/subagents off --save") == afterTurn && timing("/subagents") == afterTurn);
        assert(timing("/compact") == afterTurn && timing("/restart") == afterTurn && timing("/resume") == afterTurn);
    }
    auto v = LiveView.make;
    assert(v.get("/plan") is null);
    v.set("/plan", "p");
    assert(v.get("/plan") == "p");
}

// rust: turn_commands.rs::timing_sorts_commands_by_what_they_touch
unittest
{
    with (Timing)
    {
        foreach (c; ["/help", "/version", "/tools", "/skills", "/providers", "/session", "/plan", "/context", "/mode",
                "/verbosity", "/trajectory", "/trajectory --json", "/trajectory --markdown", "/trajectory --md"])
            assert(timing(c) == immediate, c);
        foreach (c; ["/mode plan", "/verbosity quiet", "/mode  auto ", "/model mock/x", "/model  anthropic/claude-x "])
            assert(timing(c) == nextStep, c);
        foreach (c; ["/compact", "/compact --smart", "/restart", "/settings", "/model", "/exit", "/quit",
                "/plan extra", "/version extra", "/trajectory --bogus", "/trajectory extra", "/trajectory --json extra"])
            assert(timing(c) == afterTurn, c);
        assert(splitCmd("/model\nmock/x") == ["/model", "mock/x"] && splitCmd("/help") == ["/help", ""]);
        assert(timing("/trajectory\t--json") == timing("/trajectory --json") && timing("/model\tmock/x") == nextStep);
    }
}
