//! Slash commands that can run while a turn is in flight.
//!
//! During a turn the turn future holds `&mut Agent`, so `run_command` (which
//! takes the agent) has to wait until the turn ends. The read-only commands
//! here instead read a [`Snapshot`] taken from the agent when the turn
//! starts, plus the live shared stats and the plan the agent publishes on
//! `TurnControl`. `run_command` builds its output the same way, so a command
//! shows the same thing during a turn as after it.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::agent::Agent;
use crate::context::ContextStats;
use crate::plan::Plan;
use crate::providers::ProviderConfig;

/// When a command can run relative to a turn in flight.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Timing {
    /// Read-only: runs straight away from the snapshot and live stats.
    Immediate,
    /// A setting the agent reads at its next step (`/mode NAME`,
    /// `/verbosity LEVEL`): applied straight away through shared state.
    NextStep,
    /// Changes the conversation, owns the keyboard, or switches the client:
    /// waits for the turn to finish.
    AfterTurn,
}

/// When `cmd` (a trimmed `/…` line) can run during a turn.
pub fn timing(cmd: &str) -> Timing {
    let (name, arg) = cmd.split_once(char::is_whitespace).map(|(n, a)| (n, a.trim())).unwrap_or((cmd, ""));
    match (name, arg) {
        ("/help" | "/tools" | "/skills" | "/providers" | "/session" | "/plan" | "/context", "") => Timing::Immediate,
        // Only the supported export forms run early; anything else defers so
        // the between-turns command reports the unknown option (as it does for
        // every other command given arguments it doesn't take).
        ("/trajectory", "" | "--json" | "--markdown" | "--md") => Timing::Immediate,
        // Without an argument these just show the current value.
        ("/mode" | "/verbosity", "") => Timing::Immediate,
        ("/mode" | "/verbosity", _) => Timing::NextStep,
        _ => Timing::AfterTurn,
    }
}

/// A command's output: a transcript block, or text to emit verbatim
/// (`/trajectory --json|--markdown`, see `Renderer::print_raw`).
#[derive(Debug, PartialEq)]
pub enum Output {
    Block(String),
    Raw(String),
}

/// What the read-only commands need from the agent, captured before a turn
/// borrows it. None of it changes during a turn.
#[derive(Debug, Default, Clone)]
pub struct Snapshot {
    /// The mode-independent tool definitions, captured unfiltered. `/tools`
    /// filters them by the *live* mode at render time (see
    /// [`Snapshot::tools`]) so a `/mode` change mid-turn is reflected in the
    /// next listing instead of showing the turn-start mode's tools.
    tools: Vec<crate::tools::ToolDefinition>,
    skills: String,
    /// The effective provider configs and the default provider's name. The
    /// `/providers` listing is rendered from these on demand (see
    /// [`Snapshot::providers`]): building it eagerly would run
    /// `settings::key_status` — a synchronous credential-file read for
    /// GitHub Copilot when its env var is unset — on every turn, even when
    /// `/providers` is never used.
    providers: BTreeMap<String, ProviderConfig>,
    default_provider: String,
    session: String,
    session_path: Option<PathBuf>,
    system_tokens: usize,
    instruction_files: Vec<String>,
    skills_count: Option<usize>,
    compaction_mode: String,
    window_source: String,
}

impl Snapshot {
    pub fn capture(agent: &Agent) -> Self {
        // Captured for every mode: `Agent::tool_definitions()` applies the
        // capture-time mode's filter, which would bake a Plan-mode capture's
        // missing mutating tools in permanently; `tool_definitions_all_modes`
        // returns the full superset so `/tools` can re-filter by the live mode
        // when it renders.
        let tools = agent.tool_definitions_all_modes();

        let found = agent.skills();
        let mut skills: Vec<String> = Vec::new();
        if found.is_empty() {
            skills.push(format!(
                "No skills found (looked in {}, ai.lock and {}).",
                agent.config().skills.dirs.join(", "),
                agent.config().skills.user_dirs.join(", ")
            ));
        }
        for skill in &found.skills {
            skills.push(format!("  {} - {}\n      {}", skill.name, skill.description, skill.dir.display()));
        }
        for warning in &found.warnings {
            skills.push(format!("Warning: {warning}"));
        }

        let (user, default_provider) = agent.config().effective_providers();
        let providers = crate::providers::effective_providers(&user);

        let session = match (agent.session_id(), agent.session_path()) {
            (Some(id), Some(path)) => format!("Session {id}: {}", path.display()),
            _ => "Session persistence is disabled".to_string(),
        };

        Self {
            tools,
            skills: skills.join("\n"),
            providers,
            default_provider,
            session,
            session_path: agent.session_path().map(PathBuf::from),
            system_tokens: crate::context::text_tokens(&agent.system_prompt()),
            instruction_files: agent.project_instruction_files(),
            skills_count: (!found.is_empty() || !found.warnings.is_empty()).then_some(found.skills.len()),
            compaction_mode: agent.config().compaction_mode.as_str().to_string(),
            window_source: agent.context_window_with_source().1,
        }
    }

    /// The output of a read-only command (see [`timing`]), or `None` for any
    /// other command. `stats` and `plan` are the live values.
    pub fn output(&self, cmd: &str, stats: &ContextStats, plan: &Plan) -> Option<Output> {
        let block = |text: String| Some(Output::Block(text));
        match cmd {
            "/help" => block(crate::commands::help_text()),
            "/tools" => block(self.tools(stats.mode)),
            "/skills" => block(self.skills.clone()),
            "/providers" => block(self.providers()),
            "/session" => block(self.session.clone()),
            "/plan" if plan.is_empty() => block("No plan yet. The agent makes one with the plan_add tool.".into()),
            "/plan" => block(plan.render(true, usize::MAX).trim_end().to_string()),
            "/context" => block(self.context(stats)),
            "/mode" => {
                let current = stats.mode;
                let mut out = vec![format!("Mode: {current} ({})", current.describe())];
                for mode in crate::mode::AgentMode::ALL {
                    out.push(format!("  {:<8} {}", mode.to_string(), mode.describe()));
                }
                out.push("(Shift+Tab cycles; /mode NAME sets it directly)".to_string());
                block(out.join("\n"))
            }
            "/verbosity" => {
                let current = crate::ui::verbosity();
                let mut out = vec![format!("Verbosity: {current} ({})", current.describe())];
                for level in crate::ui::Verbosity::ALL {
                    out.push(format!("  {:<8} {}", level.to_string(), level.describe()));
                }
                block(out.join("\n"))
            }
            _ if cmd == "/trajectory" || cmd.starts_with("/trajectory ") => {
                Some(self.trajectory(cmd["/trajectory".len()..].trim()))
            }
            _ => None,
        }
    }

    /// The `/tools` listing, rendered from the captured definitions but
    /// filtered by the *live* mode: a `/mode` change mid-turn takes effect on
    /// the agent's next step, so the listing must reflect the mode that step
    /// will actually run under, not the mode the snapshot was captured in.
    fn tools(&self, mode: crate::mode::AgentMode) -> String {
        let mut out = vec!["Available tools:".to_string()];
        for def in &self.tools {
            if mode == crate::mode::AgentMode::Plan && !crate::mode::plan_allows(&def.name) {
                continue;
            }
            out.push(format!("  {} - {}", def.name, def.description));
        }
        out.join("\n")
    }

    /// The `/providers` listing, rendered on demand: `settings::key_status`
    /// can read a credential file, so this runs only when the listing is
    /// actually requested, not when the snapshot is captured.
    fn providers(&self) -> String {
        let mut out = vec![format!("Providers (default: {}):", self.default_provider)];
        for (name, provider) in &self.providers {
            let kind = provider.kind.map(|k| format!("{k:?}").to_lowercase()).unwrap_or_else(|| "?".into());
            let key = crate::settings::key_status(provider);
            let url = provider.base_url.clone().unwrap_or_else(|| match provider.kind {
                Some(crate::providers::ProviderKind::GithubCopilot) => "(from session token)".into(),
                _ => "-".into(),
            });
            out.push(format!("  {name:<14} {kind:<14} {url:<55} {key}"));
        }
        out.join("\n")
    }

    fn context(&self, stats: &ContextStats) -> String {
        let mut out: Vec<String> = Vec::new();
        out.push(format!("Model:        {}/{}", stats.provider, stats.model));
        out.push(format!(
            "Context:      {}{} of {} tokens ({:.1}%){}",
            if stats.calibrated { "" } else { "~" },
            stats.tokens,
            stats.window,
            stats.percent(),
            if stats.calibrated { ", anchored to reported usage" } else { ", estimated" }
        ));
        out.push(format!("Messages:     {}", stats.messages));
        out.push(format!("System prompt: {} tokens", self.system_tokens));
        if self.instruction_files.is_empty() {
            out.push(
                "Instructions: none (no AGENTS.md, CLAUDE.md or .github/copilot-instructions.md found)".to_string(),
            );
        } else {
            out.push(format!("Instructions: {}", self.instruction_files.join(", ")));
        }
        if let Some(count) = self.skills_count {
            out.push(format!("Skills:       {count} (/skills to list them)"));
        }
        if let Some((done, total)) = stats.plan {
            out.push(format!("Plan:         {done}/{total} done (/plan to show it)"));
        }
        out.push(format!(
            "Session:      {} input, {} output tokens",
            stats.session_input_tokens, stats.session_output_tokens
        ));
        if let Some(aic) = stats.session_aic {
            out.push(format!("AI Credits:   {aic:.2} used this session"));
        }
        match stats.auto_compact {
            Some(t) => out.push(format!(
                "Auto-compact: at {:.0}% (~{} tokens); compacted {} time(s)",
                t * 100.0,
                (stats.window as f64 * t) as usize,
                stats.compactions
            )),
            None => out.push("Auto-compact: off".to_string()),
        }
        out.push(format!(
            "Compaction:   {} mode (/compact --smart or --standard overrides once)",
            self.compaction_mode
        ));
        if stats.history_searches + stats.history_reads > 0 {
            out.push(format!(
                "History:      {} search(es), {} read(s) this session",
                stats.history_searches, stats.history_reads
            ));
        }
        out.push(format!("(context window {})", self.window_source));
        out.join("\n")
    }

    /// The session trajectory, read from the log: plain text (a block), or
    /// JSON/Markdown to emit verbatim.
    fn trajectory(&self, arg: &str) -> Output {
        match self.load_trajectory() {
            Err(note) => Output::Block(note),
            Ok(traj) => match arg {
                "--json" => Output::Raw(traj.to_json()),
                "--markdown" | "--md" => Output::Raw(traj.to_markdown()),
                "" => Output::Block(traj.to_plain()),
                other => Output::Block(format!("Unknown option {other:?}; use /trajectory [--json|--markdown]")),
            },
        }
    }

    /// The session's trajectory, or why there is none to show.
    pub fn load_trajectory(&self) -> Result<crate::trajectory::Trajectory, String> {
        let Some(path) = &self.session_path else {
            return Err("Session persistence is disabled: no trajectory to show".to_string());
        };
        let records = crate::session::read_records_at(path, None)
            .map_err(|e| format!("Could not read the session log: {e:#}"))?;
        Ok(crate::trajectory::Trajectory::from_records(&records))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mode::AgentMode;

    #[test]
    fn timing_sorts_commands_by_what_they_touch() {
        for cmd in ["/help", "/tools", "/skills", "/providers", "/session", "/plan", "/context", "/mode", "/verbosity"]
        {
            assert_eq!(timing(cmd), Timing::Immediate, "{cmd}");
        }
        for cmd in ["/trajectory", "/trajectory --json", "/trajectory --markdown", "/trajectory --md"] {
            assert_eq!(timing(cmd), Timing::Immediate, "{cmd}");
        }
        for cmd in ["/mode plan", "/verbosity quiet", "/mode  auto "] {
            assert_eq!(timing(cmd), Timing::NextStep, "{cmd}");
        }
        for cmd in
            ["/compact", "/compact --smart", "/restart", "/settings", "/model", "/model mock/x", "/exit", "/quit"]
        {
            assert_eq!(timing(cmd), Timing::AfterTurn, "{cmd}");
        }
        // A read-only command given arguments it doesn't take is not run early.
        assert_eq!(timing("/plan extra"), Timing::AfterTurn);
        // Only the supported `/trajectory` forms run early: an unknown option
        // defers to the between-turns command, which reports the bad option.
        for cmd in ["/trajectory --bogus", "/trajectory extra", "/trajectory --json extra"] {
            assert_eq!(timing(cmd), Timing::AfterTurn, "{cmd}");
        }
    }

    #[test]
    fn output_uses_the_live_stats_and_plan() {
        let snapshot =
            Snapshot { compaction_mode: "smart".into(), window_source: "from config".into(), ..Default::default() };
        let stats = ContextStats { mode: AgentMode::Plan, tokens: 500, window: 1000, ..Default::default() };
        let Some(Output::Block(mode)) = snapshot.output("/mode", &stats, &Plan::default()) else { panic!() };
        assert!(mode.starts_with("Mode: plan"), "{mode}");
        let Some(Output::Block(context)) = snapshot.output("/context", &stats, &Plan::default()) else { panic!() };
        assert!(context.contains("500 of 1000 tokens (50.0%)"), "{context}");
        assert!(context.contains("Compaction:   smart mode"), "{context}");
        assert!(context.ends_with("(context window from config)"), "{context}");

        let Some(Output::Block(empty)) = snapshot.output("/plan", &stats, &Plan::default()) else { panic!() };
        assert!(empty.starts_with("No plan yet"), "{empty}");
        let mut plan = Plan::default();
        plan.apply("plan_add", &serde_json::json!({"items": ["write the tests"]})).unwrap();
        let Some(Output::Block(shown)) = snapshot.output("/plan", &stats, &plan) else { panic!() };
        assert!(shown.contains("write the tests"), "{shown}");

        assert_eq!(snapshot.output("/compact", &stats, &plan), None);
        assert_eq!(snapshot.output("hello", &stats, &plan), None);
    }

    #[test]
    fn trajectory_without_a_session_says_so() {
        let snapshot = Snapshot::default();
        for cmd in ["/trajectory", "/trajectory --json"] {
            let Some(Output::Block(note)) = snapshot.output(cmd, &ContextStats::default(), &Plan::default()) else {
                panic!("{cmd}")
            };
            assert!(note.contains("Session persistence is disabled"), "{note}");
        }
    }

    #[test]
    fn tools_listing_follows_the_live_mode() {
        // One allowed and one mutating tool: the captured definitions are
        // mode-independent, so the listing is filtered by the mode in force
        // when `/tools` runs, not the mode at snapshot capture.
        let snapshot = Snapshot {
            tools: vec![
                crate::tools::ToolDefinition::new("read_file", "read a file", serde_json::json!({})),
                crate::tools::ToolDefinition::new("edit_file", "edit a file", serde_json::json!({})),
            ],
            ..Default::default()
        };
        let normal = ContextStats { mode: AgentMode::Normal, ..Default::default() };
        let plan = ContextStats { mode: AgentMode::Plan, ..Default::default() };

        let Some(Output::Block(all)) = snapshot.output("/tools", &normal, &Plan::default()) else { panic!() };
        assert!(all.contains("read_file"), "{all}");
        assert!(all.contains("edit_file"), "{all}");

        let Some(Output::Block(filtered)) = snapshot.output("/tools", &plan, &Plan::default()) else { panic!() };
        assert!(filtered.contains("read_file"), "{filtered}");
        assert!(!filtered.contains("edit_file"), "{filtered}");
    }
}
