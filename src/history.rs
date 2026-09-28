//! Smart compaction's history tools: search and read the original messages
//! of the current session log after compaction folded them into a summary.
//!
//! A message's ID is the 1-based line of its `message` record in the session
//! JSONL (`#N`). `replace` records repeat kept messages, so they are skipped:
//! every message appears once, at the line where it was first recorded.

use std::path::Path;

use anyhow::{Context, Result, anyhow, bail};
use regex::RegexBuilder;
use serde_json::{Value, json};

use crate::llm::{Message, Role};
use crate::session::Record;
use crate::tools::ToolDefinition;

pub const SEARCH_TOOL: &str = "history_search";
pub const READ_TOOL: &str = "history_read";

const DEFAULT_LIMIT: usize = 20;
const MAX_LIMIT: usize = 100;
const SNIPPET_CHARS: usize = 240;

pub fn is_history_tool(name: &str) -> bool {
    name == SEARCH_TOOL || name == READ_TOOL
}

pub fn definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition::new(
            SEARCH_TOOL,
            "Search the original messages of this session, including those folded into a compaction summary. \
             Returns matching messages as `#N role: snippet` lines, where #N is the ID the summary cites; read one \
             whole with history_read. Results are history, not the current state of files.",
            json!({
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Regular expression (case-insensitive); plain text works too" },
                    "role": { "type": "string", "enum": ["user", "assistant", "tool"], "description": "Only messages with this role" },
                    "before": { "type": "integer", "description": "Only messages with an ID below this" },
                    "after": { "type": "integer", "description": "Only messages with an ID above this" },
                    "limit": { "type": "integer", "description": "Maximum results, newest first (default 20, max 100)" }
                },
                "required": ["pattern"]
            }),
        ),
        ToolDefinition::new(
            READ_TOOL,
            "Read one original message of this session in full by its ID (#N from a summary or history_search).",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "integer", "description": "Message ID (the N in #N)" },
                    "max_output_length": { "type": "integer", "description": "Maximum characters to return (default 40000)" }
                },
                "required": ["id"]
            }),
        ),
    ]
}

/// Messages of the log with their IDs, each once.
pub fn load(path: &Path) -> Result<Vec<(u64, Message)>> {
    let bytes = std::fs::read(path).with_context(|| format!("read session log {}", path.display()))?;
    let mut messages = Vec::new();
    for (index, line) in bytes.split(|&b| b == b'\n').enumerate() {
        if line.is_empty() {
            continue;
        }
        // A torn or unknown record is skipped rather than failing the search.
        if let Ok(Record::Message(message)) = serde_json::from_slice::<Record>(line) {
            messages.push((index as u64 + 1, message));
        }
    }
    Ok(messages)
}

fn role_name(role: &Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
        Role::Tool => "tool",
    }
}

/// `#N role [name] (time)` label.
fn label(id: u64, message: &Message) -> String {
    let mut label = format!("#{id} {}", role_name(&message.role));
    if let Some(name) = &message.name {
        label.push_str(&format!(" {name}"));
    }
    if message.is_error {
        label.push_str(" (failed)");
    }
    if let Some(time) = message.timestamp {
        label.push_str(&format!(" ({})", time.format("%Y-%m-%d %H:%M:%S")));
    }
    label
}

/// Everything searchable in a message: its text and any tool calls, leaving
/// out earlier history lookups so a search does not find itself.
fn searchable(message: &Message) -> String {
    if message.name.as_deref().is_some_and(is_history_tool) {
        return String::new();
    }
    let mut text = message.content.clone();
    for call in message.tool_calls.iter().filter(|c| !is_history_tool(&c.name)) {
        text.push_str(&format!("\n[called {}({})]", call.name, call.arguments));
    }
    text
}

fn id_arg(args: &Value, key: &str) -> Result<Option<u64>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(n)) => n.as_u64().map(Some).ok_or_else(|| anyhow!("{key} must be a positive integer")),
        Some(Value::String(s)) => s
            .trim()
            .trim_start_matches('#')
            .parse()
            .map(Some)
            .map_err(|_| anyhow!("{key} must be a positive integer")),
        Some(_) => bail!("{key} must be a positive integer"),
    }
}

fn snippet(text: &str, start: usize, end: usize) -> String {
    let lead = SNIPPET_CHARS / 3;
    let from = text[..start].char_indices().rev().nth(lead - 1).map_or(0, |(i, _)| i);
    let room = SNIPPET_CHARS.saturating_sub(text[from..start].chars().count());
    let to = text[end..].char_indices().nth(room.saturating_sub(text[start..end].chars().count())).map_or(text.len(), |(i, _)| end + i);
    let mut out = text[from..to].split_whitespace().collect::<Vec<_>>().join(" ");
    if from > 0 {
        out.insert(0, '…');
    }
    if to < text.len() {
        out.push('…');
    }
    out
}

/// `history_search`: matching messages, newest first.
pub fn search(path: &Path, args: &Value) -> Result<String> {
    let pattern = args.get("pattern").and_then(Value::as_str).filter(|p| !p.is_empty())
        .ok_or_else(|| anyhow!("pattern must be a non-empty string"))?;
    let regex = RegexBuilder::new(pattern)
        .case_insensitive(true)
        .build()
        .or_else(|_| RegexBuilder::new(&regex::escape(pattern)).case_insensitive(true).build())?;
    let role = args.get("role").and_then(Value::as_str);
    let before = id_arg(args, "before")?;
    let after = id_arg(args, "after")?;
    let limit = match args.get("limit").and_then(Value::as_u64) {
        Some(0) | None => DEFAULT_LIMIT,
        Some(n) => (n as usize).min(MAX_LIMIT),
    };
    let messages = load(path)?;
    let mut hits = Vec::new();
    let mut total = 0;
    for (id, message) in messages.iter().rev() {
        if message.role == Role::System
            || role.is_some_and(|r| r != role_name(&message.role))
            || before.is_some_and(|b| *id >= b)
            || after.is_some_and(|a| *id <= a)
        {
            continue;
        }
        let text = searchable(message);
        let Some(found) = regex.find(&text) else { continue };
        total += 1;
        if hits.len() < limit {
            hits.push(format!("{}: {}", label(*id, message), snippet(&text, found.start(), found.end())));
        }
    }
    if hits.is_empty() {
        return Ok(format!("No messages match {pattern:?}."));
    }
    let mut out = hits.join("\n");
    if total > hits.len() {
        out.push_str(&format!("\n[{} more matches; narrow the pattern or use before/after]", total - hits.len()));
    }
    Ok(out)
}

/// `history_read`: one message in full (bounded, with the whole spilled).
pub fn read(path: &Path, args: &Value, spill_dir: &Path) -> Result<String> {
    let id = id_arg(args, "id")?.ok_or_else(|| anyhow!("id is required"))?;
    let limit = crate::output::parse_max_output_length(args.get("max_output_length")).map_err(|e| anyhow!(e))?;
    let messages = load(path)?;
    let Some((_, message)) = messages.iter().find(|(line, _)| *line == id) else {
        let last = messages.last().map_or(0, |(line, _)| *line);
        bail!("no message #{id} in this session (IDs are log lines; the latest is #{last})");
    };
    // Keep the read surface consistent with `search`, which excludes system
    // messages: never expose the session's system prompt or project
    // instructions through a guessed ID.
    if message.role == Role::System {
        bail!("message #{id} is a system message and cannot be read");
    }
    let mut text = format!("{}\n", label(id, message));
    // Reasoning-model assistant messages may carry their content only in
    // thinking blocks, so include them to keep the "read in full" contract.
    for block in &message.thinking_blocks {
        if let Some(thought) = block.get("thinking").and_then(Value::as_str) {
            text.push_str(&format!("[thinking] {thought}\n"));
        }
    }
    text.push_str(&message.content);
    for call in &message.tool_calls {
        text.push_str(&format!("\n[called {} id={} {}]", call.name, call.id, call.arguments));
    }
    Ok(crate::output::bound_and_spill(&text, limit, spill_dir, &format!("history-{id}.txt")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{SessionLog, now};

    /// A log with a compaction: lines 2-6 are messages, 7 a replace.
    fn log(dir: &Path) -> std::path::PathBuf {
        let mut log = SessionLog::create(dir, "h").unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap();
        log.append(&Record::Message(Message::user("fix the flaky test in auth.rs"))).unwrap();
        let call = crate::llm::ToolCall { id: "c1".into(), name: "bash".into(), arguments: json!({"command": "cargo test auth"}), item_id: None };
        log.append(&Record::Message(Message::assistant_with_tools("", vec![call]))).unwrap();
        let long = format!("{}error[E0308]: mismatched types at auth.rs:42{}", "a ".repeat(400), " b".repeat(400));
        log.append(&Record::Message(Message::tool_error("c1", "bash", &long))).unwrap();
        log.append(&Record::Message(Message::assistant("fixed"))).unwrap();
        let replace = Record::Replace {
            messages: vec![Message::system("sys"), Message::user("summary"), Message::assistant("fixed")],
            pending_position: None,
            summarized: Some((3, 5)),
            mode: Some(crate::config::CompactionMode::Smart),
            model: None,
            recorded_at: now(),
        };
        log.append(&replace).unwrap();
        log.path().to_path_buf()
    }

    #[test]
    fn ids_are_log_lines_and_replace_records_are_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let ids: Vec<u64> = load(&log(dir.path())).unwrap().into_iter().map(|(id, _)| id).collect();
        assert_eq!(ids, vec![2, 3, 4, 5, 6]);
    }

    #[test]
    fn search_finds_text_and_tool_calls_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        let path = log(dir.path());
        let out = search(&path, &json!({"pattern": "auth"})).unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 3, "{out}");
        assert!(lines[0].starts_with("#5 tool bash (failed)") && lines[0].contains("error[E0308]"), "{out}");
        assert!(lines[0].contains('…') && lines[0].chars().count() < 400, "snippets are short: {out}");
        assert!(lines[1].starts_with("#4 assistant") && lines[1].contains("cargo test auth"), "{out}");
        assert!(lines[2].starts_with("#3 user"), "{out}");

        let out = search(&path, &json!({"pattern": "auth", "role": "user"})).unwrap();
        assert_eq!(out.lines().count(), 1);
        let out = search(&path, &json!({"pattern": "auth", "limit": 1})).unwrap();
        assert!(out.contains("[2 more matches"), "{out}");
        let out = search(&path, &json!({"pattern": "auth", "before": 4})).unwrap();
        assert!(out.starts_with("#3 user") && out.lines().count() == 1, "{out}");
        // An invalid regex is searched as plain text.
        assert!(search(&path, &json!({"pattern": "E0308]"})).unwrap().starts_with("#5"));
        assert!(search(&path, &json!({"pattern": "nothing-like-this"})).unwrap().starts_with("No messages match"));
        assert!(search(&path, &json!({})).is_err());
    }

    #[test]
    fn read_returns_one_message_whole_or_bounded() {
        let dir = tempfile::tempdir().unwrap();
        let path = log(dir.path());
        let out = read(&path, &json!({"id": 5}), dir.path()).unwrap();
        assert!(out.starts_with("#5 tool bash (failed)") && out.contains("auth.rs:42") && out.ends_with(" b"), "{out}");
        let out = read(&path, &json!({"id": "#4"}), dir.path()).unwrap();
        assert!(out.contains("[called bash id=c1 {\"command\":\"cargo test auth\"}]"), "{out}");
        let out = read(&path, &json!({"id": 5, "max_output_length": 100}), dir.path()).unwrap();
        assert!(out.contains("complete output in"), "{out}");
        let err = read(&path, &json!({"id": 99}), dir.path()).unwrap_err();
        assert!(err.to_string().contains("latest is #6"), "{err}");
        // System messages are not readable, matching search's exclusion.
        let err = read(&path, &json!({"id": 2}), dir.path()).unwrap_err();
        assert!(err.to_string().contains("system message"), "{err}");
    }

    #[test]
    fn read_includes_thinking_blocks() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "t").unwrap();
        let mut thinker = Message::assistant("");
        thinker.thinking_blocks = vec![json!({"type": "thinking", "thinking": "weigh the options", "signature": "sig"})];
        log.append(&Record::Message(thinker)).unwrap();
        let out = read(log.path(), &json!({"id": 2}), dir.path()).unwrap();
        assert!(out.contains("[thinking] weigh the options"), "{out}");
    }
}
