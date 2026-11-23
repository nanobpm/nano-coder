/// The agent's operating mode: normal, plan (read-only analysis) or auto (no
/// turn cap). Port of `mode.rs`.
///
/// The mode is live state held by `TurnControl`: `/mode` (and Shift+Tab)
/// change it, and the running turn reads it at each iteration so a change
/// takes effect at the next model call. It is not persisted.
module nano.mode;

@safe:
pure:

import nano.result : Result;
import std.string : strip, toLower;
import std.format : format;

enum AgentMode
{
    /// Full tool access; a positive turn cap asks before stopping.
    normal,
    /// Read-only: mutating tools are gated, only analysis and output.
    plan,
    /// No turn cap.
    auto_,
}

immutable AgentMode[] allModes = [AgentMode.normal, AgentMode.plan, AgentMode.auto_];

/// The next mode in the Shift+Tab cycle.
AgentMode next(AgentMode m) pure nothrow
{
    final switch (m)
    {
        case AgentMode.normal: return AgentMode.plan;
        case AgentMode.plan: return AgentMode.auto_;
        case AgentMode.auto_: return AgentMode.normal;
    }
}

string name(AgentMode m) pure
{
    final switch (m)
    {
        case AgentMode.normal: return "normal";
        case AgentMode.plan: return "plan";
        case AgentMode.auto_: return "auto";
    }
}

string describe(AgentMode m) pure
{
    final switch (m)
    {
        case AgentMode.normal: return "full tools; a positive turn cap asks before stopping";
        case AgentMode.plan: return "read-only: analysis and output, no changes";
        case AgentMode.auto_: return "no turn cap; questions auto-answered when you are away";
    }
}

/// Parse a mode name; the error is Rust's message for an unknown one.
Result!(AgentMode, string) parseMode(string text) pure
{
    alias R = Result!(AgentMode, string);
    switch (text.strip.toLower)
    {
        case "normal": return R.ok(AgentMode.normal);
        case "plan", "planning": return R.ok(AgentMode.plan);
        case "auto", "autonomous": return R.ok(AgentMode.auto_);
        default: return R.err(format!"unknown mode \"%s\" (normal, plan or auto)"(text.strip.toLower));
    }
}

/// Tools that stay available in plan mode: read-only analysis, planning and
/// reporting. Everything else is gated.
immutable string[] planAllowedTools = [
    "read_file", "grep", "glob", "get_time", "plan_add", "plan_update", "plan_show",
    // Timers are session state, not workspace changes: a plan can wait.
    "timer_set", "timer_list", "timer_cancel", "timer_done",
    // Session settings change the harness, not the workspace.
    "session_settings",
    "load_skill",
    "report_outcome", "question", "history_search", "history_read", "sessions_list", "memory_search",
    // Read-only sub-agents: their own calls are checked against plan mode.
    "agent", "agent_status", "agent_read", "agent_cancel", "agent_wait",
];

/// Whether `tool` may run in plan mode.
bool planAllows(string tool) pure nothrow
{
    foreach (t; planAllowedTools) if (t == tool) return true;
    return false;
}

/// Appended to the system prompt while in plan mode.
enum planPromptNote = "\n\nYou are in PLAN MODE: read-only. Do not create, modify or delete "
    ~ "anything, and do not run mutating commands. Analyse, read files, and produce a plan or answer. "
    ~ "Mutating tools are disabled; report_outcome and the plan tools remain available.";

// rust: mode.rs::shift_tab_cycles_normal_plan_auto
// rust: mode.rs::plan_allows_read_only_search_but_not_writes
// rust: mode.rs::parses_mode_names
unittest
{
    assert(planAllows("grep") && planAllows("glob") && planAllows("read_file"));
    assert(!planAllows("bash") && !planAllows("write_file") && !planAllows("edit_file"));
    // rust: mode.rs::plan_allows_every_timer_tool
    import nano.timers : timerToolNames = toolNames;
    foreach (name; timerToolNames) assert(planAllows(name), "plan mode must allow timer tool " ~ name);
    import nano.result : match;
    assert(parseMode(" plan ") == Result!(AgentMode, string).ok(AgentMode.plan));
    assert(parseMode("Autonomous") == Result!(AgentMode, string).ok(AgentMode.auto_));
    assert(parseMode("x").match!(m => "", e => e) == "unknown mode \"x\" (normal, plan or auto)");
    assert(AgentMode.auto_.next == AgentMode.normal);
}
