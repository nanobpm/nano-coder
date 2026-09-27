//! The agent's operating mode: normal, plan (read-only analysis) or auto
//! (no turn cap, questions answered automatically when the user is away).
//!
//! The mode is shared, live state: Shift+Tab cycles it at the prompt or
//! mid-turn, and the running turn reads it at each iteration so a change
//! takes effect at the next model call. It is not persisted — each session
//! starts in `Normal`.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AgentMode {
    /// Full tool access; the turn cap prompts before stopping.
    #[default]
    Normal,
    /// Read-only: mutating tools are gated, only analysis and output.
    Plan,
    /// No turn cap; a pending question is answered automatically after a
    /// timeout ("the user is away from the keyboard").
    Auto,
}

impl AgentMode {
    pub const ALL: &[AgentMode] = &[AgentMode::Normal, AgentMode::Plan, AgentMode::Auto];

    /// The next mode in the Shift+Tab cycle.
    pub fn next(self) -> Self {
        match self {
            AgentMode::Normal => AgentMode::Plan,
            AgentMode::Plan => AgentMode::Auto,
            AgentMode::Auto => AgentMode::Normal,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            AgentMode::Normal => "normal",
            AgentMode::Plan => "plan",
            AgentMode::Auto => "auto",
        }
    }

    pub fn describe(self) -> &'static str {
        match self {
            AgentMode::Normal => "full tools; the turn cap asks before stopping",
            AgentMode::Plan => "read-only: analysis and output, no changes",
            AgentMode::Auto => "no turn cap; questions auto-answered when you are away",
        }
    }
}

impl fmt::Display for AgentMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for AgentMode {
    type Err = String;
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        match text.trim().to_ascii_lowercase().as_str() {
            "normal" => Ok(AgentMode::Normal),
            "plan" | "planning" => Ok(AgentMode::Plan),
            "auto" | "autonomous" => Ok(AgentMode::Auto),
            other => Err(format!("unknown mode {other:?} (normal, plan or auto)")),
        }
    }
}

/// Tools that stay available in plan mode: read-only analysis, planning and
/// reporting. Everything else — `bash`, `write_file`, `edit_file` and any
/// other mutating tool — is gated.
const PLAN_ALLOWED_TOOLS: &[&str] = &[
    "read_file",
    "get_time",
    "echo",
    "plan_add",
    "plan_update",
    "plan_show",
    "load_skill",
    "report_outcome",
    "question",
];

/// Whether `tool` may run in plan mode.
pub fn plan_allows(tool: &str) -> bool {
    PLAN_ALLOWED_TOOLS.contains(&tool)
}

/// A note appended to the system prompt while in plan mode, so the model
/// knows to analyse rather than change anything.
pub const PLAN_PROMPT_NOTE: &str = "\n\nYou are in PLAN MODE: read-only. Do not create, modify or delete \
     anything, and do not run mutating commands. Analyse, read files, and produce a plan or answer. \
     Mutating tools are disabled; report_outcome and the plan tools remain available.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shift_tab_cycles_normal_plan_auto() {
        assert_eq!(AgentMode::Normal.next(), AgentMode::Plan);
        assert_eq!(AgentMode::Plan.next(), AgentMode::Auto);
        assert_eq!(AgentMode::Auto.next(), AgentMode::Normal);
    }

    #[test]
    fn parses_mode_names() {
        assert_eq!("normal".parse::<AgentMode>(), Ok(AgentMode::Normal));
        assert_eq!(" plan ".parse::<AgentMode>(), Ok(AgentMode::Plan));
        assert_eq!("AUTO".parse::<AgentMode>(), Ok(AgentMode::Auto));
        assert!("sideways".parse::<AgentMode>().is_err());
    }
}
