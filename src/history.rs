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

/// Appended once to a failed tool result after a smart compaction.
pub const FAILED_TOOL_HINT: &str = "[If you are looking for something from earlier in this session (an error, a command \
and its output, what the user asked for), it may only be in the conversation, not on disk: history_search finds the \
original messages that the summary folded away.]";

/// A tool call that failed, including a bash command that ran but reports a
/// failure in its (successful) result: a non-zero exit (`Exit code: N`), a
/// timeout, or a killing signal — `bash::run` returns all of these as `Ok`
/// text, not as an error.
pub fn looks_failed(tool: &str, ok: bool, result: &str) -> bool {
    if is_history_tool(tool) {
        return false;
    }
    if !ok {
        return true;
    }
    tool == "bash" && BASH_FAILURE_MARKERS.iter().any(|marker| line_starts_with(result, marker))
}

/// Line prefixes `bash::run` uses to report a command that ran but failed (see
/// `src/bash.rs`): a non-zero exit, a timeout, or termination by a signal.
const BASH_FAILURE_MARKERS: [&str; 3] = ["Exit code: ", "Error: command timed out ", "Terminated by signal "];

/// Whether `marker` begins `text` or begins any line within it.
fn line_starts_with(text: &str, marker: &str) -> bool {
    text.starts_with(marker) || text.contains(&format!("\n{marker}"))
}

/// Whether this message already consumed the one-time post-compaction history
/// hint: it is the failed tool result that carries the hint text, or it is a
/// history-tool call/result (which also clears the pending hint). Lets a resume
/// keep the hint one-time per compaction instead of re-arming it every
/// `--resume`. The checks are role-specific so user/assistant text that merely
/// quotes the hint literal (e.g. after compaction folds it into a summary)
/// cannot consume the one-time state: the hint is only ever appended to a tool
/// result, and `tool_calls`/`name` are only meaningful on assistant/tool roles.
pub fn consumes_hint(message: &Message) -> bool {
    match message.role {
        Role::Tool => {
            message.content.contains(FAILED_TOOL_HINT) || message.name.as_deref().is_some_and(is_history_tool)
        }
        Role::Assistant => message.tool_calls.iter().any(|call| is_history_tool(&call.name)),
        _ => false,
    }
}

const DEFAULT_LIMIT: usize = 20;
const MAX_LIMIT: usize = 100;
const SNIPPET_CHARS: usize = 240;
/// Matches shown per message; a broad pattern often matches boilerplate
/// first (e.g. `Compiling lease`), so later matches are shown too.
const SNIPPETS_PER_MESSAGE: usize = 3;

pub fn is_history_tool(name: &str) -> bool {
    name == SEARCH_TOOL || name == READ_TOOL
}

pub fn definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition::new(
            SEARCH_TOOL,
            "Search the original messages of this session, including those folded into a compaction summary. \
             Returns matching messages as `#N role: snippet` lines (up to 3 matches each), where #N is the ID the \
             summary cites; read one whole with history_read. Prefer distinctive patterns (an error code or \
             phrase, an identifier, a flag) over common words, and use order=oldest for things from early on. \
             An assistant message that follows tool output is often a paraphrase: read the output it names. \
             Results are history, not the current state of files.",
            json!({
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Regular expression (case-insensitive); plain text works too" },
                    "role": { "type": "string", "enum": ["user", "assistant", "tool"], "description": "Only messages with this role. Command output and errors are in tool messages; omit role to search everything" },
                    "before": { "type": "integer", "description": "Only messages with an ID below this" },
                    "after": { "type": "integer", "description": "Only messages with an ID above this" },
                    "order": { "type": "string", "enum": ["newest", "oldest"], "description": "Result order (default newest first)" },
                    "limit": { "type": "integer", "description": "Maximum messages returned (default 20, max 100)" }
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
            messages.push((index as u64 + 1, *message));
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
        Some(Value::String(s)) => {
            s.trim().trim_start_matches('#').parse().map(Some).map_err(|_| anyhow!("{key} must be a positive integer"))
        }
        Some(_) => bail!("{key} must be a positive integer"),
    }
}

fn snippet(text: &str, start: usize, end: usize) -> String {
    let lead = SNIPPET_CHARS / 3;
    let from = text[..start].char_indices().rev().nth(lead - 1).map_or(0, |(i, _)| i);
    let room = SNIPPET_CHARS.saturating_sub(text[from..start].chars().count());
    let to = text[end..]
        .char_indices()
        .nth(room.saturating_sub(text[start..end].chars().count()))
        .map_or(text.len(), |(i, _)| end + i);
    let mut out = text[from..to].split_whitespace().collect::<Vec<_>>().join(" ");
    if from > 0 {
        out.insert(0, '…');
    }
    if to < text.len() {
        out.push('…');
    }
    out
}

/// IDs of the tool results directly before message `index` (`#6` or
/// `#4–#6`), if any.
fn preceding_tool_outputs(messages: &[(u64, Message)], index: usize) -> Option<String> {
    let tools: Vec<u64> =
        messages[..index].iter().rev().take_while(|(_, m)| m.role == Role::Tool).map(|(id, _)| *id).collect();
    match (tools.last(), tools.first()) {
        (Some(first), Some(last)) if first == last => Some(format!("#{first}")),
        (Some(first), Some(last)) => Some(format!("#{first}–#{last}")),
        _ => None,
    }
}

/// `history_search`: matching messages, newest first.
pub fn search(path: &Path, args: &Value) -> Result<String> {
    let pattern = args
        .get("pattern")
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())
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
    let oldest_first = match args.get("order").and_then(Value::as_str) {
        None | Some("newest") => false,
        Some("oldest") => true,
        Some(other) => bail!("order must be \"newest\" or \"oldest\", not {other:?}"),
    };
    let messages = load(path)?;
    let ordered: Box<dyn Iterator<Item = &(u64, Message)>> =
        if oldest_first { Box::new(messages.iter()) } else { Box::new(messages.iter().rev()) };
    let position: std::collections::HashMap<u64, usize> =
        messages.iter().enumerate().map(|(i, (id, _))| (*id, i)).collect();
    let mut hits = Vec::new();
    let mut total = 0;
    let mut omitted = (u64::MAX, 0u64);
    // Matches the role filter hid, by role: models tend to search only their
    // own (assistant) messages and miss the tool output holding the detail.
    let mut hidden_by_role: std::collections::BTreeMap<&str, usize> = Default::default();
    for (id, message) in ordered {
        if message.role == Role::System || before.is_some_and(|b| *id >= b) || after.is_some_and(|a| *id <= a) {
            continue;
        }
        if role.is_some_and(|r| r != role_name(&message.role)) {
            if regex.is_match(&searchable(message)) {
                *hidden_by_role.entry(role_name(&message.role)).or_default() += 1;
            }
            continue;
        }
        let text = searchable(message);
        // Count every match but retain only the first SNIPPETS_PER_MESSAGE
        // distinct, non-overlapping regions, so a message with many matches
        // does not allocate one `Match` per occurrence.
        let mut match_count = 0usize;
        let mut snippets: Vec<(usize, usize)> = Vec::new();
        let mut shown_until = 0;
        for m in regex.find_iter(&text) {
            match_count += 1;
            if snippets.len() < SNIPPETS_PER_MESSAGE && m.start() >= shown_until {
                snippets.push((m.start(), m.end()));
                shown_until = m.end() + SNIPPET_CHARS;
            }
        }
        if match_count == 0 {
            continue;
        }
        total += 1;
        if hits.len() >= limit {
            omitted = (omitted.0.min(*id), omitted.1.max(*id));
            continue;
        }
        let mut line = label(*id, message);
        if match_count > 1 {
            line.push_str(&format!(" [{match_count} matches]"));
        }
        if message.role == Role::Assistant
            && let Some(sources) = preceding_tool_outputs(&messages, position[id])
        {
            // An assistant message often paraphrases the output it just saw;
            // point at the original so the paraphrase isn't taken as the source.
            line.push_str(&format!(" [after tool output {sources}]"));
        }
        line.push(':');
        for &(start, end) in &snippets {
            line.push(' ');
            line.push_str(&snippet(&text, start, end));
        }
        hits.push(line);
    }
    let hidden = (!hidden_by_role.is_empty()).then(|| {
        let counts: Vec<String> = hidden_by_role.iter().map(|(r, n)| format!("{n} {r}")).collect();
        format!(
            "[role={} hid {} matching message(s): {}. Tool messages hold command output and errors; \
             search without role to include them]",
            role.unwrap_or_default(),
            hidden_by_role.values().sum::<usize>(),
            counts.join(", ")
        )
    });
    if hits.is_empty() {
        let mut out = format!("No {}messages match {pattern:?}.", role.map(|r| format!("{r} ")).unwrap_or_default());
        if let Some(hidden) = hidden {
            out.push('\n');
            out.push_str(&hidden);
        }
        return Ok(out);
    }
    let mut out = hits.join("\n");
    if let Some(hidden) = &hidden {
        out.push('\n');
        out.push_str(hidden);
    }
    if total > hits.len() {
        let (which, bound) = if oldest_first { ("newer", "after") } else { ("older", "before") };
        let (first, last) = omitted;
        out.push_str(&format!(
            "\n[{} more {which} matching messages not shown (#{first}–#{last}); use a more distinctive pattern, \
             {bound}=, or order={}]",
            total - hits.len(),
            if oldest_first { "newest" } else { "oldest" },
        ));
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
    let mut emitted_thinking = false;
    for block in &message.thinking_blocks {
        if let Some(thought) = block.get("thinking").and_then(Value::as_str) {
            text.push_str(&format!("[thinking] {thought}\n"));
            emitted_thinking = true;
        }
    }
    // Other providers' reasoning is logged as plain text instead. Replay blocks
    // (OpenAI `reasoning_content`, Responses `reasoning`) carry no readable
    // `thinking`, so emit the logged text whenever no block produced one.
    if !emitted_thinking && !message.thinking.is_empty() {
        text.push_str(&format!("[thinking] {}\n", message.thinking));
    }
    text.push_str(&message.content);
    for call in &message.tool_calls {
        text.push_str(&format!("\n[called {} id={} {}]", call.name, call.id, call.arguments));
    }
    // An image attachment is shown as a placeholder with its source path, so
    // the model can `read_file` the path again to view it.
    for attachment in &message.attachments {
        text.push_str(&format!("\n{}", attachment.placeholder()));
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
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Message(Box::new(Message::user("fix the flaky test in auth.rs")))).unwrap();
        let call = crate::llm::ToolCall {
            id: "c1".into(),
            name: "bash".into(),
            arguments: json!({"command": "cargo test auth"}),
            item_id: None,
            malformed_arguments: None,
        };
        log.append(&Record::Message(Box::new(Message::assistant_with_tools("", vec![call])))).unwrap();
        let long = format!("{}error[E0308]: mismatched types at auth.rs:42{}", "a ".repeat(400), " b".repeat(400));
        log.append(&Record::Message(Box::new(Message::tool_error("c1", "bash", &long)))).unwrap();
        log.append(&Record::Message(Box::new(Message::assistant("fixed")))).unwrap();
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
    fn read_includes_logged_thinking_text() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "t").unwrap();
        let thought = Message { thinking: "check auth.rs first".into(), ..Message::assistant("on it") };
        log.append(&Record::Message(Box::new(thought))).unwrap();
        let out = read(log.path(), &json!({"id": 2}), dir.path()).unwrap();
        assert!(out.contains("[thinking] check auth.rs first\non it"), "{out}");
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
        let lines: Vec<&str> = out.lines().collect();
        assert!(lines.len() == 2 && lines[0].starts_with("#3 user") && lines[1].starts_with("[role=user hid"), "{out}");
        let out = search(&path, &json!({"pattern": "auth", "limit": 1})).unwrap();
        assert!(
            out.contains("[2 more older matching messages not shown (#3–#4)") && out.contains("order=oldest"),
            "{out}"
        );
        let out = search(&path, &json!({"pattern": "auth", "order": "oldest", "limit": 1})).unwrap();
        assert!(out.starts_with("#3 user") && out.contains("2 more newer") && out.contains("order=newest"), "{out}");
        assert!(search(&path, &json!({"pattern": "auth", "order": "sideways"})).is_err());
        let out = search(&path, &json!({"pattern": "auth", "before": 4})).unwrap();
        assert!(out.starts_with("#3 user") && out.lines().count() == 1, "{out}");
        // An invalid regex is searched as plain text.
        assert!(search(&path, &json!({"pattern": "E0308]"})).unwrap().starts_with("#5"));
        assert!(search(&path, &json!({"pattern": "nothing-like-this"})).unwrap().starts_with("No messages match"));
        assert!(search(&path, &json!({})).is_err());
    }

    #[test]
    fn search_shows_later_matches_in_a_message() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = crate::session::SessionLog::create(dir.path(), "s").unwrap();
        let noise = "x ".repeat(300);
        let text = format!(
            "Compiling lease {noise} Compiling lease {noise} error[E0599]: no method named `renew` in lease {noise}"
        );
        log.append(&Record::Message(Box::new(Message::tool_result("t1", "bash", &text)))).unwrap();
        let out = search(log.path(), &json!({"pattern": "lease"})).unwrap();
        assert!(out.contains("[3 matches]") && out.contains("no method named `renew`"), "{out}");
    }

    #[test]
    fn reports_matches_hidden_by_the_role_filter() {
        let dir = tempfile::tempdir().unwrap();
        let path = log(dir.path());
        // The error is only in the tool result (#5).
        let out = search(&path, &json!({"pattern": "E0308", "role": "assistant"})).unwrap();
        assert!(out.starts_with("No assistant messages match"), "{out}");
        assert!(out.contains("role=assistant hid 1 matching message(s): 1 tool"), "{out}");
        // Hits in the chosen role still show, plus the note.
        let out = search(&path, &json!({"pattern": "auth", "role": "user"})).unwrap();
        assert!(out.starts_with("#3 user") && out.contains("role=user hid"), "{out}");
        // No note without a role filter, or when nothing is hidden.
        assert!(!search(&path, &json!({"pattern": "E0308"})).unwrap().contains("hid"));
        assert!(!search(&path, &json!({"pattern": "E0308", "role": "tool"})).unwrap().contains("hid"));
    }

    #[test]
    fn assistant_hits_name_the_tool_output_they_follow() {
        let dir = tempfile::tempdir().unwrap();
        let path = log(dir.path());
        // #6 "fixed" follows the tool output #5; #4 follows a user message.
        let out = search(&path, &json!({"pattern": "fixed"})).unwrap();
        assert!(out.starts_with("#6 assistant") && out.contains("[after tool output #5]"), "{out}");
        let out = search(&path, &json!({"pattern": "cargo test auth", "role": "assistant"})).unwrap();
        assert!(out.starts_with("#4 assistant") && !out.contains("after tool output"), "{out}");

        let mut log = crate::session::SessionLog::create(dir.path(), "multi").unwrap();
        log.append(&Record::Message(Box::new(Message::user("go")))).unwrap();
        log.append(&Record::Message(Box::new(Message::tool_result("a", "bash", "one")))).unwrap();
        log.append(&Record::Message(Box::new(Message::tool_result("b", "bash", "two")))).unwrap();
        log.append(&Record::Message(Box::new(Message::assistant("both said something")))).unwrap();
        let out = search(log.path(), &json!({"pattern": "something"})).unwrap();
        assert!(out.contains("[after tool output #3–#4]"), "{out}");
    }

    #[test]
    fn failures_include_nonzero_bash_exits() {
        assert!(looks_failed("read_file", false, "no such file"));
        assert!(looks_failed("bash", true, "ls: /work: No such file\n\nExit code: 1"));
        assert!(looks_failed("bash", true, "Exit code: 2"));
        assert!(looks_failed("bash", true, "Error: command timed out after 600s and was killed"));
        assert!(looks_failed("bash", true, "partial output\nTerminated by signal 9"));
        assert!(!looks_failed("bash", true, "fine"));
        assert!(!looks_failed(SEARCH_TOOL, false, "bad pattern"));
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
        thinker.thinking_blocks =
            vec![json!({"type": "thinking", "thinking": "weigh the options", "signature": "sig"})];
        log.append(&Record::Message(Box::new(thinker))).unwrap();
        let out = read(log.path(), &json!({"id": 2}), dir.path()).unwrap();
        assert!(out.contains("[thinking] weigh the options"), "{out}");
    }

    #[test]
    fn read_includes_plain_thinking_alongside_replay_blocks() {
        // OpenAI/Responses replay blocks carry no readable `thinking`, so the
        // logged reasoning text must still be shown (the fallback must not be
        // gated on the block vector being empty).
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "t").unwrap();
        let mut thinker = Message { thinking: "check auth.rs first".into(), ..Message::assistant("on it") };
        thinker.thinking_blocks = vec![json!({"type": "reasoning_content", "text": "check auth.rs first"})];
        log.append(&Record::Message(Box::new(thinker))).unwrap();
        let out = read(log.path(), &json!({"id": 2}), dir.path()).unwrap();
        assert!(out.contains("[thinking] check auth.rs first\non it"), "{out}");
    }

    #[test]
    fn hint_is_consumed_only_by_tool_results_and_history_calls() {
        // The failed tool result that carries the hint consumes it.
        assert!(consumes_hint(&Message::tool_error("c1", "bash", FAILED_TOOL_HINT)));
        // User/assistant text that merely quotes the hint literal does not.
        assert!(!consumes_hint(&Message::user(FAILED_TOOL_HINT)));
        assert!(!consumes_hint(&Message::assistant(FAILED_TOOL_HINT)));
        // A history-tool call (assistant) and its result (tool) both consume it.
        let call = crate::llm::ToolCall {
            id: "h".into(),
            name: SEARCH_TOOL.into(),
            arguments: json!({}),
            item_id: None,
            malformed_arguments: None,
        };
        assert!(consumes_hint(&Message::assistant_with_tools("", vec![call])));
        assert!(consumes_hint(&Message::tool_result("h", READ_TOOL, "results")));
        // An assistant that only names a history tool in its text does not.
        assert!(!consumes_hint(&Message::assistant(SEARCH_TOOL)));
        // An ordinary tool result does not.
        assert!(!consumes_hint(&Message::tool_result("c2", "bash", "ok")));
    }
}
