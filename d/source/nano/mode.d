/// The agent's operating mode: normal, plan (read-only analysis) or auto (no
/// turn cap). Port of `mode.rs`.
///
/// The mode is live state held by `TurnControl`: `/mode` (and Shift+Tab)
/// change it, and the running turn reads it at each iteration so a change
/// takes effect at the next model call. It is not persisted.
module nano.mode;

@safe:

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
AgentMode next(AgentMode m)
{
    final switch (m)
    {
        case AgentMode.normal: return AgentMode.plan;
        case AgentMode.plan: return AgentMode.auto_;
        case AgentMode.auto_: return AgentMode.normal;
    }
}

string name(AgentMode m)
{
    final switch (m)
    {
        case AgentMode.normal: return "normal";
        case AgentMode.plan: return "plan";
        case AgentMode.auto_: return "auto";
    }
}

string describe(AgentMode m)
{
    final switch (m)
    {
        case AgentMode.normal: return "full tools; a positive turn cap asks before stopping";
        case AgentMode.plan: return "read-only: analysis and output, no changes";
        case AgentMode.auto_: return "no turn cap; questions auto-answered when you are away";
    }
}

/// Parse a mode name; throws with Rust's message for an unknown one.
AgentMode parseMode(string text)
{
    switch (text.strip.toLower)
    {
        case "normal": return AgentMode.normal;
        case "plan", "planning": return AgentMode.plan;
        case "auto", "autonomous": return AgentMode.auto_;
        default: throw new Exception(format!"unknown mode \"%s\" (normal, plan or auto)"(text.strip.toLower));
    }
}

/// Tools that stay available in plan mode: read-only analysis, planning and
/// reporting. Everything else is gated.
immutable string[] planAllowedTools = [
    "read_file", "grep", "glob", "get_time", "plan_add", "plan_update", "plan_show", "load_skill",
    "report_outcome", "question", "history_search", "history_read", "memory_search",
];

/// Whether `tool` may run in plan mode.
bool planAllows(string tool)
{
    foreach (t; planAllowedTools) if (t == tool) return true;
    return false;
}

/// Appended to the system prompt while in plan mode.
enum planPromptNote = "\n\nYou are in PLAN MODE: read-only. Do not create, modify or delete "
    ~ "anything, and do not run mutating commands. Analyse, read files, and produce a plan or answer. "
    ~ "Mutating tools are disabled; report_outcome and the plan tools remain available.";

unittest
{
    assert(planAllows("grep") && planAllows("glob") && planAllows("read_file"));
    assert(!planAllows("bash") && !planAllows("write_file") && !planAllows("edit_file"));
    assert(parseMode(" plan ") == AgentMode.plan);
    assert(parseMode("Autonomous") == AgentMode.auto_);
    bool threw;
    try parseMode("x");
    catch (Exception e) threw = e.msg == "unknown mode \"x\" (normal, plan or auto)";
    assert(threw);
    assert(AgentMode.auto_.next == AgentMode.normal);
}
