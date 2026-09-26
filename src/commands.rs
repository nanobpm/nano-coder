//! The interactive slash commands: one table for `/help` and the command
//! menu shown while a `/command` is being typed.

pub struct Command {
    pub name: &'static str,
    /// Argument synopsis (empty when the command takes none).
    pub args: &'static str,
    pub description: &'static str,
}

pub const COMMANDS: &[Command] = &[
    Command { name: "/help", args: "", description: "Show this help" },
    Command { name: "/compact", args: "[focus]", description: "Summarize older messages to free context (optional focus)" },
    Command { name: "/context", args: "", description: "Show context-window use and token totals" },
    Command { name: "/settings", args: "", description: "View/edit settings" },
    Command { name: "/verbosity", args: "[quiet|normal|verbose|debug]", description: "Show or set output detail" },
    Command { name: "/plan", args: "", description: "Show the agent's task plan with notes" },
    Command { name: "/tools", args: "", description: "List available tools" },
    Command { name: "/skills", args: "", description: "List skills the agent can load" },
    Command { name: "/model", args: "[provider/model]", description: "Show or switch the model" },
    Command { name: "/providers", args: "", description: "List configured providers" },
    Command { name: "/session", args: "", description: "Show the session ID and log path" },
    Command { name: "/restart", args: "", description: "Start a fresh session (clean context) without exiting" },
    Command { name: "/exit", args: "", description: "Exit the agent" },
    Command { name: "/quit", args: "", description: "Exit the agent (alias for /exit)" },
];

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
    out.push_str("\nType / to list commands as you type; Tab completes, Esc hides the list.");
    out.push_str("\nKeys: Enter during a turn steers it, Esc Esc or Ctrl-C cancels it, Ctrl-O expands/collapses thinking");
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

    #[test]
    fn slash_lists_everything_and_typing_narrows_it() {
        assert_eq!(menu("/", 200, 50).len(), COMMANDS.len());
        let rows: Vec<String> = menu("/co", 200, 50).iter().map(|r| plain(r)).collect();
        assert_eq!(rows.len(), 2);
        assert!(rows[0].trim_start().starts_with("/compact [focus]") && rows[1].trim_start().starts_with("/context"));
        assert!(plain(&menu("/zz", 200, 50)[0]).contains("no matching command"));
        assert!(menu("/model gpt", 200, 50).is_empty(), "arguments hide the menu");
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
    fn help_lists_every_command() {
        let help = help_text();
        assert!(COMMANDS.iter().all(|c| help.contains(c.name)));
    }
}
