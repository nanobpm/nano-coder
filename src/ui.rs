//! Interactive output: verbosity levels and a renderer that turns agent
//! events into streamed text, collapsible thinking and inline tool calls.

use std::io::{self, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::AgentEvent;
use crate::llm::ToolCall;
use crate::plan::{Plan, PlanItem, Status};
use crate::status::{self, StatusLine};

/// How much the CLI prints.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verbosity {
    /// Only final answers.
    Quiet,
    /// Streamed answers, collapsed thinking, one line per tool call.
    #[default]
    Normal,
    /// Also tool output previews.
    Verbose,
    /// Also lifecycle hook events.
    Debug,
}

impl Verbosity {
    pub const ALL: [Verbosity; 4] = [Verbosity::Quiet, Verbosity::Normal, Verbosity::Verbose, Verbosity::Debug];

    pub fn describe(self) -> &'static str {
        match self {
            Verbosity::Quiet => "final answers only",
            Verbosity::Normal => "streamed answers, collapsed thinking, tool calls",
            Verbosity::Verbose => "normal + tool output previews",
            Verbosity::Debug => "verbose + lifecycle hook events",
        }
    }
}

impl std::fmt::Display for Verbosity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Verbosity::Quiet => "quiet",
            Verbosity::Normal => "normal",
            Verbosity::Verbose => "verbose",
            Verbosity::Debug => "debug",
        })
    }
}

impl std::str::FromStr for Verbosity {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Verbosity::ALL
            .into_iter()
            .find(|v| v.to_string() == s.trim().to_lowercase())
            .ok_or_else(|| format!("unknown verbosity {s:?} (quiet, normal, verbose, debug)"))
    }
}

static RENDERER: std::sync::OnceLock<Arc<Renderer>> = std::sync::OnceLock::new();

/// Route `log` lines through `renderer` (interactive mode).
pub fn install(renderer: Arc<Renderer>) {
    let _ = RENDERER.set(renderer);
}

/// A diagnostic line: on its own line in the interactive CLI, else stderr.
pub fn log(text: &str) {
    match RENDERER.get() {
        Some(renderer) => renderer.urgent_note(text),
        None => eprintln!("{text}"),
    }
}

static LEVEL: AtomicU8 = AtomicU8::new(Verbosity::Normal as u8);

pub fn verbosity() -> Verbosity {
    Verbosity::ALL[LEVEL.load(Ordering::Relaxed) as usize]
}

pub fn set_verbosity(level: Verbosity) {
    LEVEL.store(level as u8, Ordering::Relaxed);
}

static TIMESTAMPS: AtomicBool = AtomicBool::new(true);

pub fn set_timestamps(on: bool) {
    TIMESTAMPS.store(on, Ordering::Relaxed);
}

/// `text` (one or more lines) with `stamp()` on its first line and the
/// other lines indented to match.
pub fn stamp_block(text: &str) -> String {
    stamp_block_with(&stamp(), text)
}

/// Like [`stamp_block`] but with a caller-supplied `stamp` (e.g. the stamp
/// captured when a block first started streaming).
fn stamp_block_with(stamp: &str, text: &str) -> String {
    if stamp.is_empty() {
        return text.to_string();
    }
    let pad = " ".repeat(strip_ansi(stamp).chars().count());
    let mut out = String::new();
    for (i, line) in text.split_inclusive('\n').enumerate() {
        out.push_str(if i == 0 { stamp } else { &pad });
        out.push_str(line);
    }
    out
}

/// Width of `text` on screen, ignoring colour codes.
pub fn visible_width(text: &str) -> usize {
    strip_ansi(text).chars().count()
}

/// Local time (`HH:MM:SS`) in dim text plus a space, to start a message
/// line; empty when timestamps are off.
pub fn stamp() -> String {
    if TIMESTAMPS.load(Ordering::Relaxed) { format!("{DIM}{}{RESET} ", chrono::Local::now().format("%H:%M:%S")) } else { String::new() }
}

const THINK: &str = "\x1b[38;5;245m";
const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const GREEN: &str = "\x1b[38;5;114m";
const RED: &str = "\x1b[38;5;203m";
const RESET: &str = "\x1b[0m";
const REDRAW_EVERY: Duration = Duration::from_millis(50);
const PREVIEW_LINES: usize = 10;

/// A reasoning block that is streaming in.
struct ThinkBlock {
    text: String,
    started: Instant,
    /// `stamp()` from when the block started.
    stamp: String,
    /// Printed in full (otherwise shown as one updating line).
    expanded: bool,
    last_draw: Option<Instant>,
}

#[derive(Default)]
struct State {
    thinking: Option<ThinkBlock>,
    /// The most recent complete reasoning, for Ctrl-O at the prompt.
    last_thinking: String,
    streamed_text: bool,
    streamed_thinking: bool,
    /// The cursor is at the start of a line.
    at_line_start: bool,
    in_turn: bool,
    /// Width of the current streamed answer's stamp, so continuation lines
    /// can be indented to align under it.
    stream_pad: usize,
    /// Notes held back until the streamed line they would interrupt ends.
    deferred: Vec<String>,
}

pub struct Renderer {
    state: Mutex<State>,
    status: Option<Arc<StatusLine>>,
    /// Stdout is a terminal (in-place redraws are possible).
    tty: bool,
    expanded: AtomicBool,
}

impl Renderer {
    pub fn new(status: Option<Arc<StatusLine>>) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State { at_line_start: true, ..Default::default() }),
            status,
            tty: io::stdout().is_terminal(),
            expanded: AtomicBool::new(false),
        })
    }

    fn width(&self) -> usize {
        status::terminal_size().map(|(_, cols)| cols as usize).unwrap_or(80).max(20)
    }

    fn out(&self, state: &mut State, text: &str) {
        if text.is_empty() {
            return;
        }
        let mut stdout = io::stdout().lock();
        let _ = stdout.write_all(text.as_bytes());
        let _ = stdout.flush();
        let visible = strip_ansi(text);
        if let Some(last) = visible.chars().last() {
            state.at_line_start = last == '\n';
        }
        if state.at_line_start && !state.deferred.is_empty() && state.thinking.is_none() {
            let notes: String = state.deferred.drain(..).map(|n| format!("{DIM}{n}{RESET}\n")).collect();
            let _ = stdout.write_all(notes.as_bytes());
            let _ = stdout.flush();
        }
    }

    fn newline(&self, state: &mut State) {
        if !state.at_line_start {
            self.out(state, "\n");
        }
    }

    /// Write a streamed fragment, indenting any line that begins after a
    /// newline by `pad` spaces so continuation lines align under the stamp.
    fn out_aligned(&self, state: &mut State, text: &str, pad: usize) {
        if pad == 0 {
            self.out(state, text);
            return;
        }
        let indent = " ".repeat(pad);
        for seg in text.split_inclusive('\n') {
            if state.at_line_start {
                self.out(state, &indent);
            }
            self.out(state, seg);
        }
    }

    pub fn begin_turn(&self) {
        let mut state = self.state.lock().unwrap();
        state.in_turn = true;
        state.at_line_start = true;
    }

    pub fn end_turn(&self) {
        let mut state = self.state.lock().unwrap();
        self.finish_thinking(&mut state);
        self.newline(&mut state);
        for note in std::mem::take(&mut state.deferred) {
            self.out(&mut state, &format!("{DIM}{note}{RESET}\n"));
        }
        state.in_turn = false;
        state.streamed_text = false;
        state.streamed_thinking = false;
    }

    /// Print a short note on its own line (e.g. a queued steer). If an
    /// answer is streaming mid-line, the note waits for the line to end.
    pub fn note(&self, text: &str) {
        let mut state = self.state.lock().unwrap();
        if state.streamed_text && !state.at_line_start {
            state.deferred.push(format!("{}{DIM}{text}", stamp()));
            return;
        }
        self.note_now(&mut state, text);
    }

    /// Print a note on its own line straight away.
    pub fn urgent_note(&self, text: &str) {
        let mut state = self.state.lock().unwrap();
        self.note_now(&mut state, text);
    }

    fn note_now(&self, state: &mut State, text: &str) {
        self.finish_thinking(state);
        self.newline(state);
        self.out(state, &format!("{}{DIM}{text}{RESET}\n", stamp()));
    }

    pub fn event(&self, event: &AgentEvent) {
        if matches!(event, AgentEvent::Context | AgentEvent::Compacted)
            && let Some(status) = &self.status
        {
            status.draw();
        }
        if verbosity() == Verbosity::Quiet {
            return;
        }
        let mut state = self.state.lock().unwrap();
        match event {
            AgentEvent::ThinkingDelta { text } => {
                state.streamed_thinking = true;
                self.thinking_delta(&mut state, text);
            }
            AgentEvent::Thinking { text } => {
                if state.thinking.is_some() {
                    self.finish_thinking(&mut state);
                } else if !state.streamed_thinking {
                    // Not streamed: show it now, like a block that just ended.
                    self.thinking_delta(&mut state, text);
                    self.finish_thinking(&mut state);
                }
                state.streamed_thinking = false;
            }
            AgentEvent::TextDelta { text } => {
                self.finish_thinking(&mut state);
                if !text.is_empty() {
                    if !state.streamed_text {
                        self.newline(&mut state);
                        let stamp = stamp();
                        state.stream_pad = visible_width(&stamp);
                        self.out(&mut state, &stamp);
                    }
                    state.streamed_text = true;
                    let pad = state.stream_pad;
                    self.out_aligned(&mut state, text, pad);
                }
            }
            AgentEvent::AssistantMessage { text, .. } => {
                self.finish_thinking(&mut state);
                if !state.streamed_text && !text.is_empty() {
                    self.newline(&mut state);
                    self.out(&mut state, &stamp_block(text));
                }
                self.newline(&mut state);
                state.streamed_text = false;
                state.streamed_thinking = false;
            }
            // In normal mode a plan change is shown as the checklist (the
            // `Plan` event) rather than as a tool call and its result.
            AgentEvent::ToolCall { call } if quiet_plan_tool(&call.name) => {
                self.finish_thinking(&mut state);
                state.streamed_thinking = false;
            }
            AgentEvent::ToolResult { call, ok: true, .. } if quiet_plan_tool(&call.name) => {}
            AgentEvent::ToolResult { call, ok: false, output } if quiet_plan_tool(&call.name) => {
                self.newline(&mut state);
                let text = stamp_block(&format!("{RED}●{RESET} {BOLD}{}{RESET}\n{}", call.name, self.tool_result(false, output)));
                self.out(&mut state, &text);
            }
            // The outcome's summary follows as the answer; show just its status.
            AgentEvent::ToolCall { call } if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose => {
                self.finish_thinking(&mut state);
                self.newline(&mut state);
                state.streamed_thinking = false;
                let status = call.arguments.get("status").and_then(serde_json::Value::as_str).unwrap_or_default();
                let mark = if status == "blocked" { format!("{RED}■ blocked{RESET}") } else { format!("{GREEN}✔ {status}{RESET}") };
                self.out(&mut state, &format!("{}{mark}\n", stamp()));
            }
            AgentEvent::ToolResult { call, ok: true, .. } if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose => {}
            AgentEvent::Plan { plan } => {
                self.finish_thinking(&mut state);
                self.newline(&mut state);
                let stamp = stamp();
                let width = self.width().saturating_sub(4 + visible_width(&stamp));
                let text = plan_checklist(plan, width);
                self.out(&mut state, &stamp_block_with(&stamp, &text));
            }
            AgentEvent::ToolCall { call } => {
                self.finish_thinking(&mut state);
                self.newline(&mut state);
                state.streamed_thinking = false;
                let stamp = stamp();
                let used = strip_ansi(&stamp).chars().count() + call.name.len() + 4;
                let summary = tool_summary(call, self.width().saturating_sub(used));
                self.out(&mut state, &format!("{stamp}{GREEN}●{RESET} {BOLD}{}{RESET} {summary}\n", call.name));
            }
            AgentEvent::ToolResult { ok, output, .. } => {
                self.newline(&mut state);
                let text = stamp_block(&self.tool_result(*ok, output));
                self.out(&mut state, &text);
            }
            AgentEvent::Compacted if state.in_turn => {
                self.finish_thinking(&mut state);
                self.newline(&mut state);
                self.out(&mut state, &format!("{}{DIM}⟳ context compacted{RESET}\n", stamp()));
            }
            AgentEvent::UserMessage { .. } | AgentEvent::Context | AgentEvent::Compacted => {}
        }
    }

    fn tool_result(&self, ok: bool, output: &str) -> String {
        let width = self.width().saturating_sub(8 + strip_ansi(&stamp()).chars().count());
        let lines: Vec<&str> = output.trim_end().lines().collect();
        let (mark, color) = if ok { ("⎿", DIM) } else { ("⎿ error:", RED) };
        if lines.is_empty() {
            return format!("  {color}{mark} (no output){RESET}\n");
        }
        if verbosity() >= Verbosity::Verbose {
            let mut text = String::new();
            for (i, line) in lines.iter().take(PREVIEW_LINES).enumerate() {
                let lead = if i == 0 { mark } else { " " };
                text.push_str(&format!("  {color}{lead} {}{RESET}\n", fit(line, width)));
            }
            if lines.len() > PREVIEW_LINES {
                text.push_str(&format!("  {DIM}  … +{} lines{RESET}\n", lines.len() - PREVIEW_LINES));
            }
            return text;
        }
        let more = if lines.len() > 1 { format!(" (+{} lines)", lines.len() - 1) } else { String::new() };
        format!("  {color}{mark} {}{more}{RESET}\n", fit(lines[0], width.saturating_sub(more.len())))
    }

    fn thinking_delta(&self, state: &mut State, text: &str) {
        if state.thinking.is_none() {
            self.newline(state);
            let expanded = self.expanded.load(Ordering::Relaxed);
            let stamp = stamp();
            if expanded {
                self.out(state, &format!("{stamp}{THINK}∴ Thinking {DIM}(ctrl+o to collapse){RESET}\n"));
            }
            state.thinking = Some(ThinkBlock { text: String::new(), started: Instant::now(), stamp, expanded, last_draw: None });
        }
        let print = {
            let block = state.thinking.as_mut().unwrap();
            let first = block.text.is_empty();
            block.text.push_str(text);
            if block.expanded {
                let pad = strip_ansi(&block.stamp).chars().count();
                Some((format!("{THINK}{}{RESET}", if first { text.trim_start() } else { text }), pad))
            } else if self.tty && block.last_draw.is_none_or(|t| t.elapsed() >= REDRAW_EVERY) {
                block.last_draw = Some(Instant::now());
                Some((self.collapsed_line(block), 0))
            } else {
                None
            }
        };
        if let Some((print, pad)) = print {
            self.out_aligned(state, &print, pad);
        }
    }

    /// The one-line view of a streaming block, redrawn in place.
    fn collapsed_line(&self, block: &ThinkBlock) -> String {
        let prefix = "∴ Thinking: ";
        let suffix = "  (ctrl+o to expand)";
        let stamp_width = strip_ansi(&block.stamp).chars().count();
        let room = self.width().saturating_sub(stamp_width + prefix.chars().count() + suffix.len() + 1);
        let flat: String = block.text.split_whitespace().collect::<Vec<_>>().join(" ");
        let count = flat.chars().count();
        let tail: String = if count > room {
            let skip = count - room + 1;
            format!("…{}", flat.chars().skip(skip).collect::<String>())
        } else {
            flat
        };
        format!("\r\x1b[2K{}{THINK}{prefix}{DIM}{tail}{suffix}{RESET}", block.stamp)
    }

    fn finish_thinking(&self, state: &mut State) {
        let Some(block) = state.thinking.take() else { return };
        if block.expanded {
            self.newline(state);
        } else {
            let seconds = block.started.elapsed().as_secs_f64();
            let clear = if self.tty { "\r\x1b[2K" } else { "" };
            let line = format!(
                "{clear}{}{THINK}∴ Thought for {seconds:.1}s{RESET}{DIM} · {} chars (ctrl+o to expand){RESET}\n",
                block.stamp,
                block.text.trim().chars().count()
            );
            self.out(state, &line);
        }
        state.last_thinking = block.text.trim().to_string();
    }

    /// Ctrl-O: toggle between collapsed and expanded thinking. Returns true
    /// when it printed something at the prompt (the prompt must be redrawn).
    pub fn toggle_thinking(&self) -> bool {
        let expanded = !self.expanded.fetch_xor(true, Ordering::Relaxed);
        let mut state = self.state.lock().unwrap();
        if let Some(block) = state.thinking.as_mut() {
            block.expanded = expanded;
            if expanded {
                let body = format!(
                    "{THINK}∴ Thinking {DIM}(ctrl+o to collapse){RESET}\n{THINK}{}{RESET}",
                    block.text.trim_start()
                );
                let stamp = block.stamp.clone();
                let text = format!("{}{}", if self.tty { "\r\x1b[2K" } else { "\n" }, stamp_block_with(&stamp, &body));
                self.out(&mut state, &text);
            } else {
                self.newline(&mut state);
                let line = self.collapsed_line(state.thinking.as_ref().unwrap());
                self.out(&mut state, &line);
            }
            return false;
        }
        if state.in_turn {
            return false;
        }
        let note = if !expanded {
            format!("{DIM}thinking will be collapsed{RESET}\n")
        } else if state.last_thinking.is_empty() {
            format!("{DIM}thinking will be shown in full (no thinking yet){RESET}\n")
        } else {
            format!(
                "{THINK}∴ Last thinking {DIM}(shown in full from now on; ctrl+o to collapse){RESET}\n{THINK}{}{RESET}\n",
                state.last_thinking
            )
        };
        self.out(&mut state, "\r\x1b[2K");
        self.out(&mut state, &stamp_block(&note));
        true
    }
}

/// One-line description of a tool call's arguments.
fn quiet_plan_tool(name: &str) -> bool {
    matches!(name, "plan_add" | "plan_update") && verbosity() < Verbosity::Verbose
}

/// Plans longer than this show finished items as one line.
const PLAN_LINES: usize = 12;

fn plan_checklist(plan: &Plan, width: usize) -> String {
    let (done, total) = plan.progress();
    let mut out = format!("{GREEN}●{RESET} {BOLD}Plan{RESET} {DIM}{done}/{total} done{RESET}\n");
    let live: Vec<&PlanItem> = plan.items.iter().filter(|i| i.status != Status::Dropped).collect();
    let collapse = live.len() > PLAN_LINES && done > 0;
    if collapse {
        out.push_str(&format!("  {GREEN}✔{RESET} {DIM}{done} done{RESET}\n"));
    }
    let visible: Vec<&&PlanItem> = live.iter().filter(|i| !(collapse && i.status == Status::Done)).collect();
    for (shown, item) in visible.iter().enumerate() {
        if shown == PLAN_LINES {
            out.push_str(&format!("  {DIM}… +{} more{RESET}\n", visible.len() - shown));
            break;
        }
        let title = fit(&item.title, width);
        let line = match item.status {
            Status::Done => format!("{GREEN}✔{RESET} {DIM}{title}{RESET}"),
            Status::InProgress => format!("{BOLD}◼ {title}{RESET}"),
            Status::Blocked => format!("{RED}! {title}{RESET}"),
            _ => format!("{DIM}☐{RESET} {title}"),
        };
        out.push_str(&format!("  {line}\n"));
    }
    out
}

fn tool_summary(call: &ToolCall, width: usize) -> String {
    let text = match &call.arguments {
        Value::Object(args) => ["command", "path", "file_path", "pattern", "url", "text"]
            .iter()
            .find_map(|key| args.get(*key).and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| if args.is_empty() { String::new() } else { call.arguments.to_string() }),
        Value::String(raw) => raw.clone(),
        other => other.to_string(),
    };
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    format!("{DIM}{}{RESET}", fit(&text, width))
}

/// Truncate to `width` characters with an ellipsis.
fn fit(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }
    let mut out: String = text.chars().take(width.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            continue;
        }
        if c != '\r' {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn stamps_the_first_line_and_aligns_the_rest() {
        let block = strip_ansi(&stamp_block("● Plan\n  ☐ one\n"));
        let time = &block[..8];
        assert!(chrono::NaiveTime::parse_from_str(time, "%H:%M:%S").is_ok(), "{block:?}");
        assert_eq!(&block[8..], " ● Plan\n           ☐ one\n");
    }

    #[test]
    fn parses_and_orders_verbosity() {
        assert_eq!("Verbose".parse::<Verbosity>(), Ok(Verbosity::Verbose));
        assert!("loud".parse::<Verbosity>().is_err());
        assert!(Verbosity::Debug > Verbosity::Normal);
        assert_eq!(Verbosity::default(), Verbosity::Normal);
    }

    #[test]
    fn summarizes_tool_calls() {
        let call = ToolCall { id: "1".into(), name: "bash".into(), arguments: json!({"command": "ls\n  -la"}) };
        assert!(tool_summary(&call, 40).contains("ls -la"));
        let call = ToolCall { id: "1".into(), name: "get_time".into(), arguments: json!({}) };
        assert_eq!(strip_ansi(&tool_summary(&call, 40)), "");
        assert_eq!(fit("abcdef", 4), "abc…");
        assert_eq!(strip_ansi("\x1b[2mhi\x1b[0m\r\n"), "hi\n");
    }
}
