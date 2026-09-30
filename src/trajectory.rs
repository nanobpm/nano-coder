//! A turn-grouped trajectory ledger built from a session log, shown in the
//! user's pager (`$PAGER`, default `less`) and exported as JSON / Markdown.
//!
//! DeepSeek Harness ships a Trajectory tab: a turn-grouped ledger of every
//! User, Assistant (thinking + text), Tool and compaction record, with an
//! inspector for tokens, duration, input and output. This is the terminal
//! equivalent — for the live session (`/trajectory`) and for any saved session
//! (`nano-coder --trajectory <id>`, `--json` / `--markdown` for external
//! viewers such as nano-workforce).
//!
//! Everything is rebuilt offline from the JSONL log (`session.rs`): `Input`,
//! `Message` (thinking, tool calls, tool results with `is_error`, per-request
//! `usage`/`duration_ms`, timestamps), `TurnEnd` (response, outcome) and
//! `Replace` (compaction). Timing mixes two sources: an assistant (or thinking)
//! row reports the request's persisted wall-clock `duration_ms`, while a tool
//! row's duration is only approximate — the gap between the tool result and the
//! message before it, inferred from their timestamps.

use std::collections::HashSet;

use chrono::{DateTime, FixedOffset};
use serde::Serialize;

use crate::config::CompactionMode;
use crate::goal::Outcome;
use crate::llm::{Message, Role, TokenUsage};
use crate::session::Record;

/// One assistant/user/tool/compaction entry in a turn.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RowKind {
    /// A user prompt (the input that opened the turn, or a mid-turn steer).
    User,
    /// The model's reasoning text for a request.
    Think,
    /// The model's answer text for a request.
    Assistant,
    /// A tool result: the tool the model called, whether it succeeded, and how
    /// long it took (approximate — the gap to the preceding message).
    Tool {
        name: String,
        ok: bool,
        /// The `id` of the `ToolCall` row this answers, when the call was
        /// recorded; used to count each invocation once even when both sides
        /// of the call are present.
        #[serde(skip_serializing_if = "Option::is_none")]
        call_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        duration_ms: Option<u64>,
    },
    /// A tool call the model requested: its name and arguments, paired with the
    /// later result by `id`. Emitted even when no result was recorded (a crash
    /// or a cancelled call), so the ledger is a complete record of tool inputs.
    ToolCall { id: String, name: String, arguments: String },
    /// A conversation replacement (compaction / system-prompt reset).
    Compact {
        #[serde(skip_serializing_if = "Option::is_none")]
        mode: Option<CompactionMode>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },
}

/// A single ledger row: its kind, full text, and any per-request metrics.
#[derive(Debug, Clone, Serialize)]
pub struct Row {
    /// The message's line in the session log: the `#N` that `history_read`
    /// and smart-compaction summaries cite. `None` for compaction rows and
    /// rows rebuilt from a crashed input.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(flatten)]
    pub kind: RowKind,
    pub text: String,
    /// Token usage the provider reported for the request that produced this row
    /// (assistant/think rows only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<TokenUsage>,
    /// Wall-clock time of the request that produced this row, in milliseconds
    /// (assistant/think rows only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<DateTime<FixedOffset>>,
}

impl Row {
    fn new(kind: RowKind, text: String) -> Self {
        Self { id: None, kind, text, usage: None, duration_ms: None, timestamp: None }
    }

    /// [`Row::label`] prefixed with the row's `#N` log ID, when it has one.
    pub fn cited_label(&self) -> String {
        match self.id {
            Some(id) => format!("#{id} {}", self.label()),
            None => self.label(),
        }
    }

    /// The short label shown at the head of a collapsed row.
    pub fn label(&self) -> String {
        match &self.kind {
            RowKind::User => "USER".to_string(),
            RowKind::Think => "THINK".to_string(),
            RowKind::Assistant => "ASSISTANT".to_string(),
            RowKind::Tool { name, ok, duration_ms, .. } => {
                let status = if *ok { "ok" } else { "error" };
                match duration_ms {
                    Some(ms) => format!("TOOL {name} ({}, {status})", format_duration(*ms)),
                    None => format!("TOOL {name} ({status})"),
                }
            }
            RowKind::ToolCall { name, .. } => format!("CALL {name}"),
            RowKind::Compact { mode, .. } => match mode {
                Some(mode) => format!("COMPACT ({})", mode.as_str()),
                None => "COMPACT".to_string(),
            },
        }
    }

    /// The per-request metric suffix (`1.2k tok, 3.4s`), when known.
    fn metric(&self) -> Option<String> {
        let mut bits: Vec<String> = Vec::new();
        if let Some(usage) = &self.usage
            && usage.total_tokens > 0
        {
            bits.push(format!("{} tok", format_tokens(usage.total_tokens)));
        }
        if let RowKind::Tool { .. } = self.kind {
            // The tool duration is already in the label.
        } else if let Some(ms) = self.duration_ms {
            bits.push(format_duration(ms));
        }
        (!bits.is_empty()).then(|| bits.join(", "))
    }
}

/// One turn: the user input that opened it, its rows and the reported outcome.
#[derive(Debug, Clone, Serialize)]
pub struct Turn {
    /// 1-based turn number; `0` is the pre-input preamble (system prompt).
    pub number: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub outcome: Option<Outcome>,
    pub rows: Vec<Row>,
}

impl Turn {
    fn new(number: usize, input: Option<String>) -> Self {
        Self { number, input, response: None, outcome: None, rows: vec![] }
    }

    /// A compact per-turn summary: tool count, model calls, output tokens and
    /// total request time.
    pub fn summary(&self) -> String {
        // One tool invocation per CALL row. A finished invocation also yields a
        // Tool result row, so counting both would report two tools per call. The
        // CALL row is the invocation count — it is emitted even when no result
        // ever arrived (a crash or a cancelled call). A Tool result whose call
        // row is absent from the records (e.g. folded away by compaction) still
        // counts once, so an orphaned result is not dropped from the tally.
        let call_rows = self.rows.iter().filter(|r| matches!(r.kind, RowKind::ToolCall { .. })).count();
        // Collect the call IDs once so orphan detection stays O(rows): for every
        // tool result we then test membership in O(1) rather than rescanning
        // every row, which made `summary()` quadratic (and it is recomputed on
        // each pager keypress via `flatten`).
        let call_ids: HashSet<&str> = self
            .rows
            .iter()
            .filter_map(|r| match &r.kind {
                RowKind::ToolCall { id, .. } => Some(id.as_str()),
                _ => None,
            })
            .collect();
        let orphaned_results = self
            .rows
            .iter()
            .filter(|r| {
                matches!(&r.kind, RowKind::Tool { call_id, .. }
                    if !call_id.as_ref().is_some_and(|id| call_ids.contains(id.as_str())))
            })
            .count();
        let tools = call_rows + orphaned_results;
        // One model call per assistant request. A THINK row is the same
        // request's reasoning, so the ASSISTANT row paired with one is not
        // counted again — the pairing is positional (a THINK row is always
        // emitted immediately before its request's ASSISTANT row) and does NOT
        // depend on usage/duration being present: those fields are optional
        // for backward compatibility, so a metrics-free thinking message is
        // still one request, not two. The one row that is NOT a request is the
        // final-answer row the agent itself appends after `report_outcome`
        // (`Message::assistant(&response)` in agent.rs): it is the turn's LAST
        // assistant row, carries no usage/duration, its text is the persisted
        // `TurnEnd.response` verbatim, AND the turn has a recorded outcome —
        // `report_outcome` always records one, so without it the matching last
        // row is an ordinary final response (`TurnEnd.response` is the turn's
        // real response for every completed turn, outcome or not). Logs
        // written before per-request metrics existed have no usage/duration on
        // ANY row; there every assistant/think row is a real request, so only
        // that specifically identifiable synthetic row is excluded —
        // otherwise a completed legacy turn would summarize as
        // `(no activity)`.
        let last_assistant = self.rows.iter().rposition(|r| matches!(r.kind, RowKind::Assistant));
        let mut seen_think = false;
        let mut calls = 0usize;
        for (i, r) in self.rows.iter().enumerate() {
            match r.kind {
                RowKind::Think => {
                    seen_think = true;
                    calls += 1;
                }
                RowKind::Assistant => {
                    let synthetic_answer = Some(i) == last_assistant
                        && self.response.is_some()
                        && self.outcome.is_some()
                        && r.usage.is_none()
                        && r.duration_ms.is_none()
                        && self.response.as_deref() == Some(r.text.as_str());
                    if synthetic_answer {
                        continue;
                    }
                    // The ASSISTANT row paired with a THINK row is the same
                    // request's answer (any usage/duration live on the THINK
                    // row) — already counted, metrics or not.
                    if seen_think {
                        seen_think = false;
                        continue;
                    }
                    calls += 1;
                }
                _ => {}
            }
        }
        let out: i64 =
            self.rows.iter().filter_map(|r| r.usage.as_ref()).map(|u| u.completion_tokens).filter(|&t| t > 0).sum();
        let duration: u64 = self.rows.iter().filter_map(|r| r.duration_ms).sum();
        let mut bits: Vec<String> = Vec::new();
        if calls > 0 {
            bits.push(format!("{calls} call{}", plural(calls)));
        }
        if tools > 0 {
            bits.push(format!("{tools} tool{}", plural(tools)));
        }
        if out > 0 {
            bits.push(format!("{} out", format_tokens(out)));
        }
        if duration > 0 {
            bits.push(format_duration(duration));
        }
        if let Some(outcome) = &self.outcome {
            bits.push(outcome.status.as_str().to_string());
        }
        if bits.is_empty() { "(no activity)".to_string() } else { bits.join(" · ") }
    }
}

/// A whole session's ledger.
#[derive(Debug, Clone, Serialize)]
pub struct Trajectory {
    pub session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<DateTime<FixedOffset>>,
    pub turns: Vec<Turn>,
}

impl Trajectory {
    /// Rebuild the ledger from a session log's ordered records.
    pub fn from_records(records: &[Record]) -> Self {
        let mut session_id = String::new();
        let mut created_at = None;
        let mut turns: Vec<Turn> = Vec::new();
        // The turn currently accepting rows; a preamble turn (number 0) holds
        // anything before the first `Input`.
        let mut current = Turn::new(0, None);
        let mut next_number = 1;
        // Timestamp of the previous message, for approximate tool durations.
        let mut prev_ts: Option<DateTime<FixedOffset>> = None;

        let flush = |turns: &mut Vec<Turn>, mut turn: Turn| {
            // A committed `Input` can be the final record if the process crashed
            // before the opening user `Message` was appended, leaving an
            // input-bearing turn with no navigable/searchable `USER` row.
            // Materialize the opening user row from the input in that case;
            // ordinary turns already carry it from the matching user message, so
            // only add one when the turn has no leading user row (this coalesces
            // the normal case and avoids a duplicate).
            if let Some(input) = &turn.input
                && !matches!(turn.rows.first().map(|r| &r.kind), Some(RowKind::User))
            {
                turn.rows.insert(0, Row::new(RowKind::User, input.clone()));
            }
            // Keep every input-bearing turn; drop an empty preamble.
            if turn.input.is_some() || !turn.rows.is_empty() {
                turns.push(turn);
            }
        };

        for record in records {
            match record {
                Record::Session { id, created_at: at, .. } => {
                    session_id = id.clone();
                    created_at = Some(*at);
                }
                Record::Input { text, .. } => {
                    flush(&mut turns, std::mem::replace(&mut current, Turn::new(next_number, Some(text.clone()))));
                    next_number += 1;
                    prev_ts = None;
                }
                Record::Message(message) => {
                    append_message_rows(&mut current, message, &mut prev_ts);
                }
                Record::TurnEnd { response, outcome, .. } => {
                    current.response = Some(response.clone());
                    current.outcome = outcome.clone();
                }
                Record::Replace { mode, model, .. } => {
                    current
                        .rows
                        .push(Row::new(RowKind::Compact { mode: *mode, model: model.clone() }, compact_text(record)));
                    prev_ts = None;
                }
                // The plan is surfaced by `/plan`; it is not a ledger row.
                Record::Plan { .. } => {}
            }
        }
        flush(&mut turns, current);
        Self { session_id, created_at, turns }
    }

    /// Render the whole ledger as plain text (the `/trajectory` fallback when
    /// no terminal is attached). Unlike the interactive pager's collapsed rows,
    /// this emits each row's full sanitized text so a piped
    /// `nano-coder --trajectory <id>` loses no prompt, reasoning, tool
    /// argument/result or answer content.
    pub fn to_plain(&self) -> String {
        let mut out: Vec<String> = Vec::new();
        out.push(format!("Trajectory — session {}", self.session_id));
        if let Some(at) = self.created_at {
            out.push(format!("Started {}", at.format("%Y-%m-%d %H:%M:%S")));
        }
        if self.turns.is_empty() {
            out.push(String::new());
            out.push("(no activity)".to_string());
        }
        for turn in &self.turns {
            out.push(String::new());
            out.push(sanitize_terminal(&turn_header(turn)));
            for row in &turn.rows {
                // Header line: bullet + label + any per-request metric.
                let mut head = format!("  {} {}", bullet(row), row.cited_label());
                if let Some(metric) = row.metric() {
                    head.push_str("  ");
                    head.push_str(&metric);
                }
                out.push(sanitize_terminal(&head));
                // Full body: every line of the row, indented, so nothing is
                // truncated to a 200-char preview in the non-interactive output.
                for text_line in row.text.split('\n') {
                    out.push(sanitize_terminal(&format!("      {text_line}")));
                }
            }
            // The persisted turn response lives only on `TurnEnd`; an ordinary
            // completed turn's final ASSISTANT row already carries the same
            // text, but a cancelled or max-requests turn has no such row, so
            // emit the response here or `/trajectory` would omit the
            // `[turn cancelled]` / stop explanation that JSON/Markdown keep.
            if let Some(response) = &turn.response {
                let response = response.trim();
                if !response.is_empty()
                    && !matches!(
                        turn.rows.iter().rev().find(|r| matches!(r.kind, RowKind::Assistant)),
                        Some(last) if last.text.trim() == response
                    )
                {
                    out.push(sanitize_terminal("  ● RESPONSE"));
                    for text_line in response.split('\n') {
                        out.push(sanitize_terminal(&format!("      {text_line}")));
                    }
                }
            }
            out.push(sanitize_terminal(&format!("  ↳ {}", turn.summary())));
        }
        out.join("\n")
    }

    /// The ledger as pretty JSON, for external viewers.
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".to_string())
    }

    /// The ledger as Markdown, for external viewers / nano-workforce.
    pub fn to_markdown(&self) -> String {
        let mut out: Vec<String> = Vec::new();
        out.push(format!("# Trajectory — session `{}`", self.session_id));
        if let Some(at) = self.created_at {
            out.push(String::new());
            out.push(format!("_Started {}_", at.format("%Y-%m-%d %H:%M:%S %:z")));
        }
        for turn in &self.turns {
            out.push(String::new());
            out.push(format!("## {}", turn_title(turn)));
            if let Some(input) = &turn.input {
                out.push(String::new());
                out.push(format!("> {}", sanitize_markdown(input).replace('\n', "\n> ")));
            }
            out.push(String::new());
            out.push(format!("_{}_", turn.summary()));
            for row in &turn.rows {
                out.push(String::new());
                out.push(format!("### {}", sanitize_markdown(&row.cited_label())));
                if let Some(metric) = row.metric() {
                    out.push(format!("_{metric}_"));
                }
                let text = row.text.trim();
                if !text.is_empty() {
                    out.push(String::new());
                    out.push(fence(&row.kind, &sanitize_markdown(text)));
                }
            }
            if let Some(response) = &turn.response {
                let response = response.trim();
                if !response.is_empty() {
                    out.push(String::new());
                    out.push("**Response**".to_string());
                    out.push(String::new());
                    out.push(format!("> {}", sanitize_markdown(response).replace('\n', "\n> ")));
                }
            }
        }
        out.push(String::new());
        out.join("\n")
    }
}

/// Turn an assistant/user/tool message into its ledger rows.
fn append_message_rows(turn: &mut Turn, message: &Message, prev_ts: &mut Option<DateTime<FixedOffset>>) {
    let first_new = turn.rows.len();
    match message.role {
        Role::System => {}
        Role::User => {
            // Record every user message as a row, including the turn's opening
            // input: exports then carry a `user` row for ordinary turns and the
            // pager can search for the opening prompt. The turn header
            // still summarises it via `Turn::input`.
            let mut row = Row::new(RowKind::User, message.content.clone());
            row.timestamp = message.timestamp;
            turn.rows.push(row);
        }
        Role::Assistant => {
            // Older Anthropic logs can carry readable reasoning only in
            // `thinking_blocks` (as `history_read` handles at
            // src/history.rs:345-359); replay blocks (OpenAI
            // `reasoning_content`, Responses `reasoning`) have no readable
            // `thinking`, so only blocks with a string `thinking` member
            // contribute. The effective thinking decides both the THINK row
            // and the metric placement below.
            let thinking = if message.thinking.is_empty() {
                message
                    .thinking_blocks
                    .iter()
                    .filter_map(|block| block.get("thinking").and_then(serde_json::Value::as_str))
                    .collect::<Vec<&str>>()
                    .join("\n\n")
            } else {
                message.thinking.clone()
            };
            let has_think_row = !thinking.is_empty();
            if has_think_row {
                let mut row = Row::new(RowKind::Think, thinking);
                row.usage = message.usage.clone();
                row.duration_ms = message.duration_ms;
                row.timestamp = message.timestamp;
                turn.rows.push(row);
            }
            // Always record the assistant turn, even when its text is empty and
            // it only carried tool calls — the request metrics live here.
            let text = if message.content.is_empty() && !message.tool_calls.is_empty() {
                let names: Vec<&str> = message.tool_calls.iter().map(|c| c.name.as_str()).collect();
                format!("(calling {})", names.join(", "))
            } else {
                message.content.clone()
            };
            let mut row = Row::new(RowKind::Assistant, text);
            // When there is a separate think row, the usage/duration belong to
            // it; avoid double-counting the request in the turn summary.
            if !has_think_row {
                row.usage = message.usage.clone();
                row.duration_ms = message.duration_ms;
            }
            row.timestamp = message.timestamp;
            turn.rows.push(row);
            // Record each requested tool call with its arguments, so the ledger
            // keeps tool inputs (not just results) and a call with no result —
            // a crash or cancellation — is still represented.
            for call in &message.tool_calls {
                let arguments = call
                    .malformed_arguments
                    .clone()
                    .unwrap_or_else(|| serde_json::to_string(&call.arguments).unwrap_or_else(|_| "{}".to_string()));
                let mut row = Row::new(
                    RowKind::ToolCall { id: call.id.clone(), name: call.name.clone(), arguments: arguments.clone() },
                    arguments,
                );
                row.timestamp = message.timestamp;
                turn.rows.push(row);
            }
        }
        Role::Tool => {
            let name = message.name.clone().unwrap_or_else(|| "tool".to_string());
            let duration_ms = match (prev_ts.as_ref(), message.timestamp) {
                (Some(prev), Some(now)) => u64::try_from((now - *prev).num_milliseconds()).ok(),
                _ => None,
            };
            let mut row = Row::new(
                RowKind::Tool { name, ok: !message.is_error, call_id: message.tool_call_id.clone(), duration_ms },
                message.content.clone(),
            );
            row.timestamp = message.timestamp;
            turn.rows.push(row);
        }
    }
    for row in &mut turn.rows[first_new..] {
        row.id = message.log_line;
    }
    if let Some(ts) = message.timestamp {
        *prev_ts = Some(ts);
    }
}

fn compact_text(record: &Record) -> String {
    let Record::Replace { messages, summarized, mode, model, .. } = record else {
        return String::new();
    };
    let mut parts: Vec<String> = Vec::new();
    if let Some(mode) = mode {
        parts.push(format!("mode: {}", mode.as_str()));
    }
    if let Some(model) = model {
        parts.push(format!("model: {model}"));
    }
    if let Some((first, last)) = summarized {
        parts.push(format!("folded log lines {first}–{last}"));
    }
    parts.push(format!("{} message(s) retained", messages.len()));
    parts.join(", ")
}

fn turn_header(turn: &Turn) -> String {
    let title = turn_title(turn);
    match &turn.input {
        Some(input) => format!("── {title} ──  {}", one_line(input, 60)),
        None => format!("── {title} ──"),
    }
}

fn turn_title(turn: &Turn) -> String {
    if turn.number == 0 { "Preamble".to_string() } else { format!("Turn {}", turn.number) }
}

fn bullet(row: &Row) -> char {
    match &row.kind {
        RowKind::Tool { ok: false, .. } => '✗',
        RowKind::Tool { .. } => '•',
        RowKind::ToolCall { .. } => '→',
        RowKind::Think => '·',
        RowKind::Compact { .. } => '↺',
        _ => '▸',
    }
}

fn fence(kind: &RowKind, text: &str) -> String {
    let lang = match kind {
        RowKind::Think => "",
        _ => "",
    };
    // Never let embedded fences break out of the block.
    let ticks = longest_fence(text).max(3);
    let bar = "`".repeat(ticks);
    format!("{bar}{lang}\n{text}\n{bar}")
}

fn longest_fence(text: &str) -> usize {
    text.lines()
        .filter(|l| l.trim_start().starts_with("```"))
        .map(|l| l.trim_start().chars().take_while(|&c| c == '`').count())
        .max()
        .map_or(0, |n| n + 1)
}

fn one_line(text: &str, max: usize) -> String {
    let collapsed: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate(&collapsed, max)
}

pub(crate) fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let kept: String = text.chars().take(max.saturating_sub(1)).collect();
    format!("{kept}…")
}

fn plural(n: usize) -> &'static str {
    if n == 1 { "" } else { "s" }
}

pub(crate) fn format_tokens(tokens: i64) -> String {
    if tokens >= 1000 { format!("{:.1}k", tokens as f64 / 1000.0) } else { tokens.to_string() }
}

pub(crate) fn format_duration(ms: u64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else if ms < 60_000 {
        format!("{:.1}s", ms as f64 / 1000.0)
    } else {
        format!("{}m{:02}s", ms / 60_000, (ms % 60_000) / 1000)
    }
}

use unicode_width::UnicodeWidthStr;

/// Strip terminal control sequences (ESC/OSC/CSI and C0/C1 controls) from
/// untrusted persisted text and expand tabs to 8-column stops. A prompt or tool
/// result containing escape sequences could otherwise move the cursor, clear the
/// screen, or modify the clipboard; a literal tab has no `UnicodeWidthStr` width
/// but the terminal advances it to the next tab stop, so leaving it in lets a
/// row exceed the declared width, auto-wrap, and displace the pager's status row
/// (the frame renderer keeps the same invariant, see `src/frame.rs`). Every
/// control character is dropped and tabs become spaces; the caller must sanitize
/// *before* width calculation, then add back only its own SGR styling.
/// Strip terminal control/escape sequences from untrusted text while keeping
/// Markdown line breaks. Each line is run through `sanitize_terminal` (which
/// drops C0/C1 controls and expands tabs); the `\n` separators are preserved so
/// the Markdown structure survives. Persisted prompts, row text, labels and
/// responses are otherwise copied verbatim into the export, so a logged ESC/OSC
/// sequence could clear the screen or drive the clipboard when the file is
/// printed to a TTY.
fn sanitize_markdown(text: &str) -> String {
    text.split('\n').map(sanitize_terminal).collect::<Vec<_>>().join("\n")
}

fn sanitize_terminal(text: &str) -> String {
    const TAB: usize = 8;
    let mut out = String::new();
    let mut col = 0usize;
    for c in text.chars() {
        if c == '\t' {
            let spaces = TAB - (col % TAB);
            out.extend(std::iter::repeat_n(' ', spaces));
            col += spaces;
            continue;
        }
        if c.is_control() {
            continue;
        }
        out.push(c);
        col += UnicodeWidthStr::width(c.to_string().as_str());
    }
    out
}

/// Show `text` in the user's pager (`$PAGER`, default `less`), run through
/// `sh -c` like git does. Returns `false` when no pager could be started (the
/// caller prints the text instead), including when the shell could not find
/// or run it (exit status 127 / 126). The pager reads the text on stdin and the
/// keyboard from the terminal; it owns the screen until it exits.
pub fn page(text: &str) -> bool {
    use std::io::Write;
    use std::process::{Command, Stdio};
    let pager = std::env::var("PAGER").ok().filter(|p| !p.trim().is_empty()).unwrap_or_else(|| "less".to_string());
    let mut command = Command::new("sh");
    command.arg("-c").arg(&pager).stdin(Stdio::piped());
    if std::env::var_os("LESS").is_none() {
        // Pass colour and other SGR sequences through raw (the text is
        // sanitized, so there are none today) instead of showing them as `^[`.
        command.env("LESS", "-R");
    }
    let Ok(mut child) = command.spawn() else { return false };
    if let Some(mut stdin) = child.stdin.take() {
        // A pager quit before reading everything closes the pipe: not an error.
        let _ = stdin.write_all(text.as_bytes());
    }
    child.wait().is_ok_and(|status| pager_ran(status.code()))
}

/// Whether a pager that exited with `code` actually ran. `sh -c` exits 127
/// when the command is not found and 126 when it cannot be executed; any other
/// status (including a non-zero one, or death by a signal) means the pager
/// started and showed the text, so printing it again would only duplicate it.
fn pager_ran(code: Option<i32>) -> bool {
    !matches!(code, Some(126 | 127))
}

/// Whether `text` is worth paging on a `rows` x `cols` terminal: once long
/// lines wrap (counted in display cells), it would not fit on one screen with
/// room for the prompt.
pub fn needs_pager(text: &str, rows: usize, cols: usize) -> bool {
    let cols = cols.max(1);
    let limit = rows.saturating_sub(2);
    let mut used = 0usize;
    for line in text.lines() {
        used += UnicodeWidthStr::width(line).div_ceil(cols).max(1);
        if used > limit {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::ToolCall;
    use crate::session::now;
    use serde_json::json;

    fn assistant(content: &str, thinking: &str) -> Message {
        Message {
            thinking: thinking.to_string(),
            usage: Some(TokenUsage { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120, aic: None }),
            duration_ms: Some(1500),
            timestamp: Some(now()),
            ..Message::assistant(content)
        }
    }

    fn records() -> Vec<Record> {
        let mut first = assistant("", "let me look");
        first.tool_calls = vec![ToolCall {
            id: "c1".into(),
            name: "read_file".into(),
            arguments: json!({"path": "a.rs"}),
            ..Default::default()
        }];
        vec![
            Record::Session { version: 1, id: "sess-x".into(), created_at: now() },
            Record::Message(Message { timestamp: Some(now()), ..Message::system("sys") }),
            Record::Input { id: "in-1".into(), text: "add a feature".into(), recorded_at: now() },
            Record::Message(Message { timestamp: Some(now()), ..Message::user("add a feature") }),
            Record::Message(first),
            Record::Message(Message { timestamp: Some(now()), ..Message::tool_result("c1", "read_file", "ok") }),
            Record::Message(assistant("feature added", "")),
            Record::TurnEnd {
                input_id: "in-1".into(),
                response: "feature added".into(),
                outcome: Some(Outcome { status: crate::goal::Status::Completed, summary: "done".into() }),
                history_calls: 0,
                recorded_at: now(),
            },
        ]
    }

    #[test]
    fn rows_cite_their_session_log_line() {
        // Written as a real log and read back, each message row carries its
        // 1-based line number: the `#N` that history_read and smart summaries
        // use. Lines: 1 session, 2 system, 3 input, 4 user, 5 assistant.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sess-x.jsonl");
        let log: String = records().iter().map(|r| serde_json::to_string(r).unwrap() + "\n").collect();
        std::fs::write(&path, log).unwrap();
        let traj = Trajectory::from_records(&crate::session::read_records_at(&path, Some("sess-x")).unwrap());
        let rows = &traj.turns[0].rows;
        let ids: Vec<(String, Option<u64>)> = rows.iter().map(|r| (r.label(), r.id)).collect();
        assert_eq!(ids[0], ("USER".to_string(), Some(4)));
        assert_eq!(ids[1], ("THINK".to_string(), Some(5)), "{ids:?}");
        assert_eq!(ids[2], ("ASSISTANT".to_string(), Some(5)), "thinking and answer share their message's line");
        assert!(traj.to_plain().contains("#4 USER"), "{}", traj.to_plain());
        assert!(traj.to_markdown().contains("### #5 ASSISTANT"));
        assert!(traj.to_json().contains("\"id\": 4"));
        // Records built in memory (no log) have no IDs and no `#` prefix.
        let traj = Trajectory::from_records(&records());
        assert!(traj.turns[0].rows.iter().all(|r| r.id.is_none()));
        assert!(!traj.to_plain().contains(" #"), "{}", traj.to_plain());
    }

    #[test]
    fn needs_pager_counts_wrapped_rows() {
        // Ten 300-column lines are 3 lines short of a 24-row screen by count,
        // but 40 rows once wrapped at 80 columns.
        let long = vec!["x".repeat(300); 10].join("\n");
        assert!(needs_pager(&long, 24, 80));
        assert!(!needs_pager(&long, 24, 400));
        // Wide characters take two cells each.
        let wide = vec!["界".repeat(100); 10].join("\n");
        assert!(needs_pager(&wide, 24, 80));
        // Short text and empty lines fit.
        assert!(!needs_pager("a\n\nb", 24, 80));
        assert!(needs_pager(&"a\n".repeat(23), 24, 80));
    }

    #[test]
    fn a_pager_that_could_not_start_falls_back() {
        assert!(!pager_ran(Some(127)), "command not found");
        assert!(!pager_ran(Some(126)), "not executable");
        assert!(pager_ran(Some(0)));
        assert!(pager_ran(Some(1)), "ran, then failed: the text was shown");
        assert!(pager_ran(None), "killed by a signal after starting");
    }

    #[test]
    fn groups_records_into_turns_and_rows() {
        let traj = Trajectory::from_records(&records());
        assert_eq!(traj.session_id, "sess-x");
        // The system-only preamble is dropped; one real turn remains.
        assert_eq!(traj.turns.len(), 1);
        let turn = &traj.turns[0];
        assert_eq!(turn.number, 1);
        assert_eq!(turn.input.as_deref(), Some("add a feature"));
        // user(opening), think, assistant(tool-call), CALL, tool, assistant(final).
        let labels: Vec<String> = turn.rows.iter().map(|r| r.label()).collect();
        assert_eq!(labels[0], "USER");
        assert_eq!(labels[1], "THINK");
        assert!(labels[2].starts_with("ASSISTANT"));
        assert_eq!(labels[3], "CALL read_file");
        assert!(labels[4].starts_with("TOOL read_file"), "{:?}", labels[4]);
        assert!(labels[4].contains("ok"));
        assert_eq!(labels[5], "ASSISTANT");
        assert_eq!(turn.response.as_deref(), Some("feature added"));
        assert!(turn.summary().contains("tool"));
        // Two assistant requests (one with reasoning, one final), not three:
        // the THINK row is the same request as its ASSISTANT row.
        assert!(turn.summary().contains("2 calls"), "{}", turn.summary());
    }

    #[test]
    fn synthetic_final_answer_is_not_a_model_call() {
        // A turn the model completed with `report_outcome`: the agent appends
        // the answer as `Message::assistant(&response)` without another LLM
        // request, so the row carries no usage/duration and must not count as
        // a second call.
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message({
                let mut msg = assistant("", "");
                msg.tool_calls = vec![ToolCall {
                    id: "c1".into(),
                    name: "report_outcome".into(),
                    arguments: json!({"status": "completed", "summary": "done"}),
                    ..Default::default()
                }];
                msg
            }),
            Record::Message(Message { timestamp: Some(now()), ..Message::tool_result("c1", "report_outcome", "ok") }),
            // The synthetic final answer: no usage, no duration_ms.
            Record::Message(Message { timestamp: Some(now()), ..Message::assistant("done") }),
            Record::TurnEnd {
                input_id: "i".into(),
                response: "done".into(),
                outcome: Some(Outcome { status: crate::goal::Status::Completed, summary: "done".into() }),
                history_calls: 0,
                recorded_at: now(),
            },
        ];
        let traj = Trajectory::from_records(&recs);
        let turn = &traj.turns[0];
        // Both assistant rows are still in the ledger…
        assert_eq!(turn.rows.iter().filter(|r| matches!(r.kind, RowKind::Assistant)).count(), 2);
        // …but only the real request is counted as a model call.
        assert!(turn.summary().contains("1 call"), "{}", turn.summary());
        assert!(!turn.summary().contains("2 calls"), "{}", turn.summary());
    }

    #[test]
    fn legacy_assistant_rows_without_metrics_still_count_as_calls() {
        // Logs written before per-request metrics existed carry no usage and no
        // duration_ms on any row. Their assistant messages are real requests and
        // must still be counted; only the specifically identifiable synthetic
        // final-answer row (its text matches the persisted turn response) is
        // excluded.
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message(Message { timestamp: Some(now()), ..Message::user("go") }),
            // A real legacy request: no usage, no duration_ms.
            Record::Message(Message { timestamp: Some(now()), ..Message::assistant("working on it") }),
            // The synthetic final answer appended after `report_outcome`.
            Record::Message(Message { timestamp: Some(now()), ..Message::assistant("done") }),
            Record::TurnEnd {
                input_id: "i".into(),
                response: "done".into(),
                outcome: Some(Outcome { status: crate::goal::Status::Completed, summary: "done".into() }),
                history_calls: 0,
                recorded_at: now(),
            },
        ];
        let traj = Trajectory::from_records(&recs);
        let turn = &traj.turns[0];
        assert!(turn.summary().contains("1 call"), "{}", turn.summary());
        assert!(!turn.summary().contains("no activity"), "{}", turn.summary());
    }

    #[test]
    fn outcome_free_turn_counts_its_real_final_response() {
        // Every completed turn copies its real assistant response into
        // `TurnEnd.response`, outcome or not — so the response-text match alone
        // must NOT mark the last assistant row synthetic. A legacy (metrics-free)
        // one-call turn with no recorded outcome is one real request, not
        // `(no activity)`.
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message(Message { timestamp: Some(now()), ..Message::user("go") }),
            // The one real request: no usage, no duration_ms (legacy log).
            Record::Message(Message { timestamp: Some(now()), ..Message::assistant("done") }),
            Record::TurnEnd {
                input_id: "i".into(),
                response: "done".into(),
                outcome: None,
                history_calls: 0,
                recorded_at: now(),
            },
        ];
        let traj = Trajectory::from_records(&recs);
        let turn = &traj.turns[0];
        assert!(turn.summary().contains("1 call"), "{}", turn.summary());
        assert!(!turn.summary().contains("no activity"), "{}", turn.summary());
    }

    #[test]
    fn metrics_free_thinking_message_is_one_call_not_two() {
        // A legacy (metrics-free) assistant message with reasoning produces a
        // THINK row AND an ASSISTANT row for the SAME request: one call, even
        // though no usage/duration exists anywhere to pair them by.
        let mut thinking_request = Message { timestamp: Some(now()), ..Message::assistant("thought through") };
        thinking_request.thinking = "let me think".into();
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message(Message { timestamp: Some(now()), ..Message::user("go") }),
            Record::Message(thinking_request),
            Record::TurnEnd {
                input_id: "i".into(),
                response: "thought through".into(),
                outcome: None,
                history_calls: 0,
                recorded_at: now(),
            },
        ];
        let traj = Trajectory::from_records(&recs);
        let turn = &traj.turns[0];
        assert!(turn.rows.iter().any(|r| matches!(r.kind, RowKind::Think)));
        assert!(turn.summary().contains("1 call"), "{}", turn.summary());
        assert!(!turn.summary().contains("2 calls"), "{}", turn.summary());
    }

    #[test]
    fn thinking_blocks_supply_the_think_row_when_the_plain_field_is_empty() {
        // Older Anthropic logs carry readable reasoning only in
        // `thinking_blocks`; `history_read` already replays it, and the
        // trajectory must not silently drop it. The request metrics sit on the
        // THINK row, exactly as for a message with the plain `thinking` field.
        let mut msg = Message {
            usage: Some(TokenUsage { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120, aic: None }),
            duration_ms: Some(1500),
            timestamp: Some(now()),
            ..Message::assistant("the answer")
        };
        msg.thinking_blocks = vec![
            json!({"type": "thinking", "thinking": "reasoning in a block", "signature": "sig"}),
            json!({"type": "redacted_thinking", "data": "..."}),
        ];
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message(msg),
        ];
        let traj = Trajectory::from_records(&recs);
        let rows = &traj.turns[0].rows;
        let think = rows.iter().find(|r| matches!(r.kind, RowKind::Think)).expect("a THINK row from the blocks");
        assert_eq!(think.text, "reasoning in a block");
        assert_eq!(think.duration_ms, Some(1500), "the request metrics live on the THINK row");
        let answer = rows.iter().find(|r| matches!(r.kind, RowKind::Assistant)).expect("an ASSISTANT row");
        assert_eq!(answer.usage, None, "not double-counted on the paired ASSISTANT row");
        assert!(traj.turns[0].summary().contains("1 call"), "{}", traj.turns[0].summary());
    }

    #[test]
    fn plain_render_emits_a_persisted_response_with_no_assistant_row() {
        // A cancelled turn's final text exists only as `TurnEnd.response`
        // (src/agent.rs): the plain/pager rendering must still show it, as the
        // JSON/Markdown exports do.
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message(Message { timestamp: Some(now()), ..Message::user("go") }),
            Record::TurnEnd {
                input_id: "i".into(),
                response: "[turn cancelled]".into(),
                outcome: None,
                history_calls: 0,
                recorded_at: now(),
            },
        ];
        let plain = Trajectory::from_records(&recs).to_plain();
        assert!(plain.contains("RESPONSE"), "{plain}");
        assert!(plain.contains("[turn cancelled]"), "{plain}");
        // An ordinary completed turn's final ASSISTANT row already carries the
        // response text, so it is not repeated.
        let plain = Trajectory::from_records(&records()).to_plain();
        assert_eq!(plain.matches("feature added").count(), 1, "{plain}");
    }

    #[test]
    fn opening_input_is_kept_as_a_user_row() {
        let traj = Trajectory::from_records(&records());
        let users: Vec<&Row> = traj.turns[0].rows.iter().filter(|r| matches!(r.kind, RowKind::User)).collect();
        assert_eq!(users.len(), 1, "the opening input is preserved as a USER row");
        assert_eq!(users[0].text, "add a feature");
    }

    #[test]
    fn error_tool_is_marked() {
        let mut recs = records();
        recs.insert(
            6,
            Record::Message(Message { timestamp: Some(now()), ..Message::tool_error("c2", "bash", "boom") }),
        );
        let traj = Trajectory::from_records(&recs);
        let tool = traj.turns[0].rows.iter().find(|r| matches!(&r.kind, RowKind::Tool { name, .. } if name == "bash"));
        assert!(matches!(tool.unwrap().kind, RowKind::Tool { ok: false, .. }));
        assert!(tool.unwrap().label().contains("error"));
    }

    #[test]
    fn compaction_becomes_a_row() {
        let mut recs = records();
        recs.push(Record::Replace {
            messages: vec![Message::system("new")],
            pending_position: None,
            summarized: Some((2, 6)),
            mode: Some(CompactionMode::Smart),
            model: Some("copilot/gpt".into()),
            recorded_at: now(),
        });
        let traj = Trajectory::from_records(&recs);
        let last = traj.turns.last().unwrap().rows.last().unwrap();
        assert!(matches!(last.kind, RowKind::Compact { .. }));
        assert!(last.label().contains("smart"));
        assert!(last.text.contains("folded log lines 2–6"));
    }

    #[test]
    fn tool_call_only_assistant_still_records_metrics() {
        let mut msg = assistant("", "");
        msg.tool_calls = vec![ToolCall {
            id: "c1".into(),
            name: "grep".into(),
            arguments: serde_json::json!({"pattern": "foo"}),
            ..Default::default()
        }];
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message(msg),
        ];
        let traj = Trajectory::from_records(&recs);
        let rows = &traj.turns[0].rows;
        // The opening user row is materialized from the input even though no user
        // message was recorded, so the prompt stays navigable/searchable.
        assert!(matches!(rows[0].kind, RowKind::User));
        assert_eq!(rows[0].text, "go");
        // The assistant row carries the request metrics and the synthetic text.
        let assistant = rows.iter().find(|r| matches!(r.kind, RowKind::Assistant)).expect("an ASSISTANT row");
        assert_eq!(assistant.duration_ms, Some(1500));
        assert!(assistant.text.contains("grep"));
        // A CALL row preserves the call's id, name and arguments even though no
        // result was recorded.
        let call = rows.iter().find(|r| matches!(r.kind, RowKind::ToolCall { .. })).expect("a CALL row");
        match &call.kind {
            RowKind::ToolCall { id, name, arguments } => {
                assert_eq!(id, "c1");
                assert_eq!(name, "grep");
                assert!(arguments.contains("foo"), "{arguments}");
            }
            _ => unreachable!(),
        }
        assert_eq!(call.label(), "CALL grep");
    }

    #[test]
    fn tool_invocation_is_counted_once_for_call_and_result() {
        // An assistant request that calls a tool, then the matching result: one
        // invocation, even though it produces both a CALL row and a TOOL row.
        let mut msg = assistant("", "");
        msg.tool_calls = vec![ToolCall {
            id: "c1".into(),
            name: "read_file".into(),
            arguments: serde_json::json!({"path": "a.rs"}),
            ..Default::default()
        }];
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "go".into(), recorded_at: now() },
            Record::Message(msg),
            Record::Message(Message { timestamp: Some(now()), ..Message::tool_result("c1", "read_file", "ok") }),
        ];
        let traj = Trajectory::from_records(&recs);
        let turn = &traj.turns[0];
        // Both sides of the call are in the ledger...
        assert!(turn.rows.iter().any(|r| matches!(r.kind, RowKind::ToolCall { .. })));
        assert!(turn.rows.iter().any(|r| matches!(r.kind, RowKind::Tool { .. })));
        // ...but the summary counts the invocation once, not twice.
        assert!(turn.summary().contains("1 tool"), "{}", turn.summary());
        assert!(!turn.summary().contains("2 tool"), "{}", turn.summary());
    }

    #[test]
    fn orphaned_tool_result_without_a_call_row_still_counts_once() {
        // A tool result whose call message is absent from the records (e.g.
        // folded away by compaction) is still one invocation.
        let traj = Trajectory::from_records(&records());
        assert!(traj.turns[0].summary().contains("1 tool"), "{}", traj.turns[0].summary());
    }

    #[test]
    fn json_and_markdown_round_trip() {
        let traj = Trajectory::from_records(&records());
        let value: serde_json::Value = serde_json::from_str(&traj.to_json()).unwrap();
        assert_eq!(value["session_id"], json!("sess-x"));
        // Row 0 is the opening USER row; the THINK row follows it.
        assert_eq!(value["turns"][0]["rows"][0]["kind"], json!("user"));
        assert_eq!(value["turns"][0]["rows"][1]["kind"], json!("think"));
        let md = traj.to_markdown();
        assert!(md.contains("# Trajectory — session `sess-x`"));
        assert!(md.contains("## Turn 1"));
        assert!(md.contains("### TOOL read_file"));
    }

    #[test]
    fn sanitize_terminal_strips_control_sequences() {
        // ESC/OSC/CSI and other C0 controls are removed; printable text and
        // spaces survive, and tabs are expanded to 8-column stops.
        assert_eq!(sanitize_terminal("plain text"), "plain text");
        assert_eq!(sanitize_terminal("a\x1b[2Jcleared"), "a[2Jcleared");
        assert_eq!(sanitize_terminal("x\x1b]8;;http://evil\x07link\x1b]8;;\x07y"), "x]8;;http://evillink]8;;y");
        assert_eq!(sanitize_terminal("keep\ttabs"), "keep    tabs");
        assert_eq!(sanitize_terminal("bell\x07ring"), "bellring");
    }

    #[test]
    fn plain_render_sanitizes_untrusted_input() {
        // A malicious prompt carrying an escape sequence and a tab must not
        // survive into the non-interactive fallback rendering: the escape's
        // control byte is stripped and the tab is expanded, so neither can
        // move the cursor, clear the screen, or overflow the row width.
        let recs = vec![
            Record::Input { id: "in-1".into(), text: "hi\x1b[2Jwiped\tafter".into(), recorded_at: now() },
            Record::Message(assistant("ok", "")),
        ];
        let plain = Trajectory::from_records(&recs).to_plain();
        assert!(!plain.contains('\x1b'), "no ESC byte survives");
        assert!(!plain.contains('\t'), "tabs are expanded");
        assert!(plain.contains("hi[2Jwiped"), "printable text is preserved");
    }

    #[test]
    fn markdown_sanitizes_untrusted_content() {
        // Prompts, row text and responses are copied into the export; a
        // persisted ESC/OSC sequence must be stripped so printing the file to a
        // TTY cannot clear the screen or drive the clipboard, while the Markdown
        // line breaks in the quoted prompt/response survive.
        let recs = vec![
            Record::Input { id: "in-1".into(), text: "ask\x1b[2Jwiped\nsecond".into(), recorded_at: now() },
            Record::Message(Message { timestamp: Some(now()), ..Message::user("ask\x1b[2Jwiped\nsecond") }),
            Record::Message(assistant("resp\x1b]8;;http://evil\x07x", "")),
            Record::TurnEnd {
                input_id: "in-1".into(),
                response: "final\x1b[31mred".into(),
                outcome: None,
                history_calls: 0,
                recorded_at: now(),
            },
        ];
        let md = Trajectory::from_records(&recs).to_markdown();
        assert!(!md.contains('\x1b'), "no ESC byte survives in the export");
        assert!(md.contains("ask[2Jwiped"), "printable prompt text preserved");
        assert!(md.contains("> second"), "Markdown line breaks in the prompt survive");
        assert!(md.contains("final[31mred"), "printable response text preserved");
    }

    #[test]
    fn crashed_input_materializes_opening_user_row() {
        // The process crashed right after the prompt was committed: the `Input`
        // is the final record with no following user `Message`. The opening user
        // row is still materialized from the input so the pager can
        // navigate/search to the prompt.
        let recs = vec![
            Record::Session { version: 1, id: "s".into(), created_at: now() },
            Record::Input { id: "i".into(), text: "unanswered prompt".into(), recorded_at: now() },
        ];
        let traj = Trajectory::from_records(&recs);
        let rows = &traj.turns[0].rows;
        assert_eq!(rows.len(), 1);
        assert!(matches!(rows[0].kind, RowKind::User));
        assert_eq!(rows[0].text, "unanswered prompt");
    }

    #[test]
    fn ordinary_turn_does_not_duplicate_the_opening_user_row() {
        // When the user message is present the opening row comes from it; the
        // materialization must coalesce and not add a second USER row.
        let traj = Trajectory::from_records(&records());
        let user_rows = traj.turns[0].rows.iter().filter(|r| matches!(r.kind, RowKind::User)).count();
        assert_eq!(user_rows, 1);
    }

    #[test]
    fn plain_render_lists_turns_and_summaries() {
        let plain = Trajectory::from_records(&records()).to_plain();
        assert!(plain.contains("── Turn 1 ──"));
        assert!(plain.contains("THINK"));
        assert!(plain.contains("↳"));
    }

    #[test]
    fn durations_and_tokens_format_readably() {
        assert_eq!(format_duration(500), "500ms");
        assert_eq!(format_duration(1500), "1.5s");
        assert_eq!(format_duration(65_000), "1m05s");
        assert_eq!(format_tokens(120), "120");
        assert_eq!(format_tokens(1500), "1.5k");
    }

    #[test]
    fn markdown_fences_survive_embedded_backticks() {
        let mut recs = records();
        recs.insert(
            6,
            Record::Message(Message { timestamp: Some(now()), ..Message::tool_result("c", "bash", "```\ncode\n```") }),
        );
        let md = Trajectory::from_records(&recs).to_markdown();
        // The outer fence must be longer than the embedded one so it is not
        // broken out of.
        assert!(md.contains("````"));
    }
}
