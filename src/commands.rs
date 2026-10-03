//! The interactive slash commands: one table for `/help` and the command
//! menu shown while a `/command` is being typed. Commands with a known
//! argument set (`/model`, `/mode`, `/verbosity`) also get a type-ahead
//! menu and Tab completion for their first argument, with the current
//! value, recently used models and configured providers hoisted to the top.

use crate::config::Config;
use crate::providers::{self, ProviderConfig};

pub struct Command {
    pub name: &'static str,
    /// Argument synopsis (empty when the command takes none).
    pub args: &'static str,
    pub description: &'static str,
}

pub const COMMANDS: &[Command] = &[
    Command { name: "/help", args: "", description: "Show this help" },
    Command {
        name: "/compact",
        args: "[--smart|--standard] [focus]",
        description: "Summarize older messages to free context (optional mode and focus)",
    },
    Command { name: "/context", args: "", description: "Show context-window use and token totals" },
    Command { name: "/settings", args: "", description: "View/edit settings" },
    Command { name: "/verbosity", args: "[quiet|normal|verbose|debug]", description: "Show or set output detail" },
    Command { name: "/plan", args: "", description: "Show the agent's task plan with notes" },
    Command { name: "/memory", args: "[forget ID]", description: "List cross-session memories (or forget one by id)" },
    Command {
        name: "/queue",
        args: "[list|add text|remove N...|edit N text|clear]",
        description: "Show or edit the queued messages",
    },
    Command { name: "/tools", args: "", description: "List available tools" },
    Command { name: "/skills", args: "", description: "List skills the agent can load" },
    Command {
        name: "/model",
        args: "[provider/model]",
        description: "Show the model and pick a new one (or switch directly)",
    },
    Command { name: "/mode", args: "[normal|plan|auto]", description: "Show or set the agent mode (Shift+Tab cycles)" },
    Command {
        name: "/thinking",
        args: "[level|default|off|reset]",
        description: "Show or set the thinking level for this session",
    },
    Command { name: "/providers", args: "", description: "List configured providers" },
    Command { name: "/session", args: "", description: "Show the session ID and log path" },
    Command {
        name: "/trajectory",
        args: "[--json|--markdown]",
        description: "Show this session's turn-by-turn trajectory in your pager (or export it)",
    },
    Command { name: "/resume", args: "[ID|last]", description: "Switch to a saved session: pick one, or give its ID" },
    Command { name: "/restart", args: "", description: "Start a fresh session (clean context) without exiting" },
    Command { name: "/exit", args: "", description: "Exit the agent" },
    Command { name: "/quit", args: "", description: "Exit the agent (alias for /exit)" },
];

/// Split `/compact` arguments into a one-off mode override and the focus.
pub fn parse_compact_args(args: &str) -> (Option<crate::config::CompactionMode>, Option<&str>) {
    let args = args.trim();
    let (first, rest) = args.split_once(char::is_whitespace).unwrap_or((args, ""));
    let mode = match first {
        "--smart" => Some(crate::config::CompactionMode::Smart),
        "--standard" => Some(crate::config::CompactionMode::Standard),
        _ => None,
    };
    let focus = if mode.is_some() { rest.trim() } else { args };
    (mode, Some(focus).filter(|f| !f.is_empty()))
}

/// Commands whose name starts with `prefix`.
pub fn matching(prefix: &str) -> Vec<&'static Command> {
    COMMANDS.iter().filter(|c| c.name.starts_with(prefix)).collect()
}

/// What Tab turns `prefix` into: the command (plus a space when it takes
/// arguments) if only one matches, else the longest common prefix.
pub fn complete(prefix: &str) -> Option<String> {
    let found = matching(prefix);
    match found.as_slice() {
        [] => None,
        [only] => Some(format!("{}{}", only.name, if only.args.is_empty() { "" } else { " " })),
        [first, rest @ ..] => {
            let mut common = first.name.to_string();
            for c in rest {
                let len = common.chars().zip(c.name.chars()).take_while(|(a, b)| a == b).count();
                common = common.chars().take(len).collect();
            }
            (common.len() > prefix.len()).then_some(common)
        }
    }
}

/// One row in the argument type-ahead: the value Tab completes to, plus a
/// short annotation shown dimmed after it.
pub struct Suggestion {
    pub value: String,
    pub note: String,
}

/// The line parsed as `command` + the start of its first argument. Only the
/// first argument is completed; a line already past it yields nothing.
fn split_command(line: &str) -> Option<(&str, &str)> {
    let (command, rest) = line.split_once(char::is_whitespace)?;
    let rest = rest.trim_start();
    if rest.contains(char::is_whitespace) {
        return None;
    }
    Some((command, rest))
}

/// Argument suggestions for the line being typed, in display order. `line`
/// must be the full line (`/model oll`); the returned rows are the
/// candidates that start with the argument typed so far. Empty unless the
/// command has a known argument set.
pub fn suggestions(config: &Config, recents: &[String], line: &str) -> Vec<Suggestion> {
    let Some((command, prefix)) = split_command(line) else { return Vec::new() };
    let all: Vec<Suggestion> = match command {
        "/model" => model_suggestions(config, recents),
        "/mode" => crate::mode::AgentMode::ALL
            .iter()
            .map(|m| Suggestion { value: m.as_str().to_string(), note: m.describe().to_string() })
            .collect(),
        "/verbosity" => crate::ui::Verbosity::ALL
            .iter()
            .map(|v| Suggestion { value: v.to_string(), note: v.describe().to_string() })
            .collect(),
        "/thinking" => thinking_suggestions(),
        _ => Vec::new(),
    };
    all.into_iter().filter(|s| s.value.starts_with(prefix)).collect()
}

/// True when the line is past the name of a command with a known argument
/// set, so its argument type-ahead should be drawn (even when the typed
/// prefix matches nothing, to say so).
pub fn has_argument_menu(line: &str) -> bool {
    matches!(split_command(line), Some(("/model" | "/mode" | "/verbosity" | "/thinking", _)))
}

/// `/thinking` candidates: the special values, then the named levels. Which
/// levels the current model takes shows in `/thinking`; another one is
/// fitted to the nearest it has.
fn thinking_suggestions() -> Vec<Suggestion> {
    let special = [
        ("default", "send no level; the model decides"),
        ("off", "turn thinking off, where the model allows it"),
        ("reset", "drop the session level; use the configured one"),
    ];
    special
        .iter()
        .map(|(value, note)| Suggestion { value: value.to_string(), note: note.to_string() })
        .chain(crate::thinking::ORDER.iter().map(|level| Suggestion { value: level.to_string(), note: String::new() }))
        .collect()
}

/// `/model` candidates, most-taken pathways first: the current model, then
/// recently used models, then each configured provider's default model
/// (configured providers before untouched presets), then the remaining
/// providers (whose default model, when they have one, Tab fills in).
/// Duplicates are dropped, keeping the earliest rank.
fn model_suggestions(config: &Config, recents: &[String]) -> Vec<Suggestion> {
    let (user, default_provider) = config.effective_providers();
    let all = providers::effective_providers(&user);
    let mut out: Vec<Suggestion> = Vec::new();
    let mut push = |value: String, note: String| {
        if !value.is_empty() && !out.iter().any(|s| s.value == value) {
            out.push(Suggestion { value, note });
        }
    };

    let current = config.model.trim();
    if !current.is_empty() {
        // Canonicalize to match how recents are stored, so the current model
        // and its recents entry dedupe into one row.
        push(crate::recents::canonical(current, &all, &default_provider), "current".to_string());
    }
    for spec in recents {
        push(spec.to_string(), "recent".to_string());
    }
    // A provider the user has an entry for (or the default provider) is a
    // pathway already taken; its default model outranks untouched presets.
    let configured = |name: &str| user.contains_key(name) || name == default_provider;
    let mut names: Vec<&String> = all.keys().collect();
    names.sort_by_key(|name| !configured(name));
    for name in &names {
        let provider = &all[*name];
        if let Some(model) = provider.default_model.as_deref().filter(|m| !m.is_empty()) {
            push(format!("{name}/{model}"), default_note(name, provider, &default_provider));
        }
    }
    for name in &names {
        push((*name).clone(), provider_note(name, &all[*name], &default_provider));
    }
    out
}

/// Annotation for a `provider/default-model` row.
fn default_note(name: &str, provider: &ProviderConfig, default_provider: &str) -> String {
    if name == default_provider {
        "default provider".to_string()
    } else {
        provider_note(name, provider, default_provider)
    }
}

/// Annotation for a bare provider row: its kind, and the default model Tab
/// would fill in.
fn provider_note(name: &str, provider: &ProviderConfig, default_provider: &str) -> String {
    let kind = provider.kind.map(|k| format!("{k:?}").to_lowercase()).unwrap_or_else(|| "provider".into());
    let default = match provider.default_model.as_deref().filter(|m| !m.is_empty()) {
        Some(model) => format!(" -> {model}"),
        None => String::new(),
    };
    let marker = if name == default_provider { ", default provider" } else { "" };
    format!("{kind}{default}{marker}")
}

/// What Tab turns the line into. A `/command` still being typed completes
/// like `complete`; past the command name the first argument completes
/// against the suggestion list: a unique match in full, an exact provider
/// name to its default model, otherwise the longest common prefix.
pub fn complete_line(config: &Config, recents: &[String], line: &str) -> Option<String> {
    if split_command(line).is_none() {
        return complete(line);
    }
    let (command, prefix) = split_command(line)?;
    let found = suggestions(config, recents, line);
    let completed = match found.as_slice() {
        [] => None,
        [only] => Some(only.value.clone()),
        [first, rest @ ..] => {
            let mut common = first.value.clone();
            for s in rest {
                let len = common.chars().zip(s.value.chars()).take_while(|(a, b)| a == b).count();
                common = common.chars().take(len).collect();
            }
            if common.len() > prefix.len() {
                // Several matches: extend to the common prefix.
                Some(common)
            } else {
                // No common progress: when the typed text is itself a
                // candidate (e.g. the provider `ollama`), descend to the
                // top-ranked spec under it (a recent or its default model).
                found.iter().find(|s| s.value.starts_with(&format!("{prefix}/"))).map(|s| s.value.clone())
            }
        }
    };
    completed.map(|arg| format!("{command} {arg}"))
}

/// Width of the name column; longer synopses just push their description over.
const NAME_COLUMN: usize = 20;

fn column_width() -> usize {
    COMMANDS.iter().map(|c| synopsis(c).chars().count()).filter(|w| *w <= NAME_COLUMN).max().unwrap_or(NAME_COLUMN)
}

fn synopsis(c: &Command) -> String {
    if c.args.is_empty() { c.name.to_string() } else { format!("{} {}", c.name, c.args) }
}

pub fn help_text() -> String {
    let width = column_width();
    let mut out = String::from("Commands:");
    for c in COMMANDS {
        out.push_str(&format!("\n  {:width$}  {}", synopsis(c), c.description));
    }
    out.push_str("\nType / to list commands as you type; Tab completes commands and /model, /mode, /verbosity arguments; Esc hides the list.");
    out.push_str("\nKeys: Enter during a turn steers the running turn, Ctrl-Enter queues the message (/queue lists, edits, removes), Esc Esc or Ctrl-C cancels the turn, Ctrl-O expands/collapses thinking, Shift+Tab cycles the mode (normal/plan/auto)");
    out
}

/// Menu rows for the line being typed: empty unless it is a `/command`
/// without arguments yet. Each row fits in `cols` columns; at most
/// `max_rows` rows are returned.
pub fn menu(line: &str, cols: usize, max_rows: usize) -> Vec<String> {
    if !line.starts_with('/') || line.contains(char::is_whitespace) || max_rows == 0 {
        return Vec::new();
    }
    let found = matching(line);
    if found.is_empty() {
        return vec![fit("  no matching command (/help lists them)", cols, &[(0, "\x1b[2m")])];
    }
    let width = column_width();
    let shown = if found.len() > max_rows { max_rows.saturating_sub(1) } else { found.len() };
    let typed = line.chars().count();
    let mut rows: Vec<String> = found[..shown]
        .iter()
        .map(|c| {
            let plain = format!("  {:width$}  {}", synopsis(c), c.description);
            let name_end = 2 + c.name.chars().count();
            // Typed part bold, the rest of the name cyan, the rest dim.
            fit(&plain, cols, &[(0, ""), (2, "\x1b[1m"), (2 + typed, "\x1b[0;36m"), (name_end, "\x1b[0;2m")])
        })
        .collect();
    if shown < found.len() {
        rows.push(fit(&format!("  ... {} more", found.len() - shown), cols, &[(0, "\x1b[2m")]));
    }
    rows
}

/// Menu rows for an argument type-ahead (`/model oll`): matching candidates
/// with the typed part bold, the rest of the value cyan, the note dim.
pub fn suggestion_menu(suggestions: &[Suggestion], line: &str, cols: usize, max_rows: usize) -> Vec<String> {
    if max_rows == 0 {
        return Vec::new();
    }
    let typed = split_command(line).map(|(_, prefix)| prefix.chars().count()).unwrap_or(0);
    let width = suggestions.iter().map(|s| s.value.chars().count()).max().unwrap_or(0);
    if suggestions.is_empty() {
        return vec![fit("  no match (any provider/model ID works)", cols, &[(0, "\x1b[2m")])];
    }
    let shown = if suggestions.len() > max_rows { max_rows.saturating_sub(1) } else { suggestions.len() };
    let mut rows: Vec<String> = suggestions[..shown]
        .iter()
        .map(|s| {
            let plain = format!("  {:width$}  {}", s.value, s.note);
            let value_end = 2 + s.value.chars().count();
            fit(&plain, cols, &[(0, ""), (2, "\x1b[1m"), (2 + typed, "\x1b[0;36m"), (value_end, "\x1b[0;2m")])
        })
        .collect();
    if shown < suggestions.len() {
        rows.push(fit(&format!("  ... {} more", suggestions.len() - shown), cols, &[(0, "\x1b[2m")]));
    }
    rows
}

/// `plain` cut to `cols - 1` characters, with a style switched on at each
/// character offset in `styles`.
fn fit(plain: &str, cols: usize, styles: &[(usize, &str)]) -> String {
    let mut out = String::new();
    for (i, ch) in plain.chars().take(cols.saturating_sub(1)).enumerate() {
        for (_, style) in styles.iter().filter(|(at, _)| *at == i) {
            out.push_str(style);
        }
        out.push(ch);
    }
    out.push_str("\x1b[0m");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(row: &str) -> String {
        regex::Regex::new("\x1b\\[[0-9;]*m").unwrap().replace_all(row, "").into_owned()
    }

    fn config(toml_text: &str) -> Config {
        toml::from_str(toml_text).unwrap()
    }

    #[test]
    fn slash_lists_everything_and_typing_narrows_it() {
        assert_eq!(menu("/", 200, 50).len(), COMMANDS.len());
        let rows: Vec<String> = menu("/co", 200, 50).iter().map(|r| plain(r)).collect();
        assert_eq!(rows.len(), 2);
        assert!(
            rows[0].trim_start().starts_with("/compact [--smart|--standard] [focus]")
                && rows[1].trim_start().starts_with("/context")
        );
        assert!(plain(&menu("/zz", 200, 50)[0]).contains("no matching command"));
        assert!(menu("/model gpt", 200, 50).is_empty(), "arguments hide the command menu");
        assert!(menu("hello /", 200, 50).is_empty());
    }

    #[test]
    fn rows_fit_the_terminal() {
        for row in menu("/", 30, 50) {
            assert!(plain(&row).chars().count() <= 29, "{row:?}");
        }
        let rows = menu("/", 200, 4);
        assert_eq!(rows.len(), 4);
        assert!(plain(&rows[3]).contains(&format!("... {} more", COMMANDS.len() - 3)));
    }

    #[test]
    fn tab_completes_unique_commands_and_common_prefixes() {
        assert_eq!(complete("/he").as_deref(), Some("/help"));
        assert_eq!(complete("/comp").as_deref(), Some("/compact "));
        assert_eq!(complete("/c").as_deref(), Some("/co"));
        assert_eq!(complete("/co"), None, "already the common prefix");
        assert_eq!(complete("/x"), None);
    }

    #[test]
    fn compact_args_take_an_optional_mode_then_focus() {
        use crate::config::CompactionMode::*;
        assert_eq!(parse_compact_args(""), (None, None));
        assert_eq!(parse_compact_args(" the auth bug "), (None, Some("the auth bug")));
        assert_eq!(parse_compact_args("--smart"), (Some(Smart), None));
        assert_eq!(parse_compact_args("--standard  keep paths"), (Some(Standard), Some("keep paths")));
    }

    #[test]
    fn model_suggestions_hoist_current_recent_and_defaults() {
        let config = config(
            r#"
            model = "openai/gpt-4o"
            default_provider = "openai"
            [providers.work]
            kind = "openai"
            base_url = "http://merlin.local:8000/v1"
            default_model = "gpt-oss-120b"
        "#,
        );
        let recents = vec!["ollama/qwen3:8b".to_string(), "anthropic/claude-sonnet-4-5".to_string()];
        let found = model_suggestions(&config, &recents);
        let values: Vec<&str> = found.iter().map(|s| s.value.as_str()).collect();
        assert_eq!(values[0], "openai/gpt-4o", "current model first");
        assert_eq!(values[1], "ollama/qwen3:8b");
        assert_eq!(values[2], "anthropic/claude-sonnet-4-5");
        let work = values.iter().position(|v| *v == "work/gpt-oss-120b").unwrap();
        let bare_work = values.iter().position(|v| *v == "work").unwrap();
        assert!(work < bare_work, "provider defaults before bare providers: {values:?}");
        let mock = values.iter().position(|v| *v == "mock/mock").unwrap();
        assert!(work < mock, "configured providers before untouched presets: {values:?}");
        // No duplicates: a recent that is also a provider default appears once.
        let recents = vec!["work/gpt-oss-120b".to_string()];
        let found = model_suggestions(&config, &recents);
        let values: Vec<&str> = found.iter().map(|s| s.value.as_str()).collect();
        assert_eq!(values.iter().filter(|v| **v == "work/gpt-oss-120b").count(), 1);
    }

    #[test]
    fn suggestions_narrow_on_the_argument_prefix() {
        let config = config(r#"model = "openai/gpt-4o""#);
        let recents = vec!["ollama/qwen3:8b".to_string()];
        let values: Vec<String> = suggestions(&config, &recents, "/model ol").iter().map(|s| s.value.clone()).collect();
        assert_eq!(values, ["ollama/qwen3:8b", "ollama"], "recent first, then the bare provider");
        assert!(suggestions(&config, &recents, "/model zz").is_empty());
        assert!(suggestions(&config, &recents, "/model a b").is_empty(), "only the first argument completes");
        assert!(
            suggestions(&config, &recents, "/compact anything").is_empty(),
            "free-text arguments are not suggested"
        );
        assert!(suggestions(&config, &recents, "hello world").is_empty());
    }

    #[test]
    fn mode_and_verbosity_arguments_are_suggested() {
        let config = Config::default();
        let modes: Vec<String> = suggestions(&config, &[], "/mode ").iter().map(|s| s.value.clone()).collect();
        assert_eq!(modes, ["normal", "plan", "auto"]);
        let narrowed: Vec<String> = suggestions(&config, &[], "/mode p").iter().map(|s| s.value.clone()).collect();
        assert_eq!(narrowed, ["plan"]);
        let levels: Vec<String> = suggestions(&config, &[], "/verbosity v").iter().map(|s| s.value.clone()).collect();
        assert_eq!(levels, ["verbose"]);
    }

    #[test]
    fn complete_line_handles_arguments() {
        let config = config(
            r#"
            model = "openai/gpt-4o"
            [providers.work]
            kind = "openai"
            base_url = "http://merlin.local:8000/v1"
            default_model = "gpt-oss-120b"
        "#,
        );
        let recents = vec!["ollama/qwen3:8b".to_string()];
        // Several matches extend to the common prefix first...
        assert_eq!(complete_line(&config, &recents, "/model ol").as_deref(), Some("/model ollama"));
        // ...then Tab again descends to the top-ranked spec under the provider.
        assert_eq!(complete_line(&config, &recents, "/model ollama").as_deref(), Some("/model ollama/qwen3:8b"));
        // An exact provider name completes to its default model.
        assert_eq!(complete_line(&config, &recents, "/model work").as_deref(), Some("/model work/gpt-oss-120b"));
        // No common progress and the prefix is not a full provider segment: unchanged.
        assert_eq!(complete_line(&config, &recents, "/model o").as_deref(), None);
        assert_eq!(complete_line(&config, &recents, "/mode a").as_deref(), Some("/mode auto"));
        assert_eq!(complete_line(&config, &recents, "/mode ").as_deref(), None, "ambiguous: no progress");
        assert_eq!(complete_line(&config, &recents, "/model zz"), None);
        // Command names still complete through the same entry point.
        assert_eq!(complete_line(&config, &recents, "/comp").as_deref(), Some("/compact "));
        assert_eq!(complete_line(&config, &recents, "/he").as_deref(), Some("/help"));
    }

    #[test]
    fn suggestion_rows_fit_and_highlight_the_typed_part() {
        let config = config(r#"model = "openai/gpt-4o""#);
        let found = suggestions(&config, &[], "/model o");
        let rows = suggestion_menu(&found, "/model o", 30, 50);
        for row in &rows {
            assert!(plain(row).chars().count() <= 29, "{row:?}");
        }
        assert!(rows.iter().any(|r| r.contains("\x1b[1m")), "typed part bold: {rows:?}");
        let rows = suggestion_menu(&found, "/model o", 200, 2);
        assert_eq!(rows.len(), 2);
        assert!(plain(&rows[1]).contains("... "), "overflow counted");
        let none = suggestion_menu(&[], "/model zz", 200, 50);
        assert!(plain(&none[0]).contains("no match"));
    }

    #[test]
    fn help_lists_every_command() {
        let help = help_text();
        assert!(COMMANDS.iter().all(|c| help.contains(c.name)));
    }
}
