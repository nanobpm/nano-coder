//! Interactive output: verbosity levels and a renderer that turns agent
//! events into streamed text, collapsible thinking and inline tool calls.

use std::io::{self, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::AgentEvent;
use crate::frame::{self, FrameRenderer, Item, Role, StampedItem};
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
    if TIMESTAMPS.load(Ordering::Relaxed) {
        format!("{DIM}{}{RESET} ", chrono::Local::now().format("%H:%M:%S"))
    } else {
        String::new()
    }
}

/// Pair a frame transcript item with the current timestamp, so every item
/// (message, tool call/result, plan, thinking, note, output) is stamped
/// consistently — matching the legacy renderer, where `ui::stamp()` prefixes
/// every interactive item when `timestamps` is on (the default).
fn stamped(item: Item) -> StampedItem {
    StampedItem { stamp: stamp(), item }
}

const THINK: &str = "\x1b[38;5;245m";
const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const GREEN: &str = "\x1b[38;5;114m";
const RED: &str = "\x1b[38;5;203m";
const YELLOW: &str = "\x1b[38;5;179m";
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
    /// Raw payloads (e.g. `/trajectory --json`) held back until the streamed
    /// line they would interrupt ends. Kept separate from `deferred` because
    /// these are emitted verbatim — no stamp, no DIM — so the export stays
    /// byte-exact.
    deferred_raw: Vec<String>,
}

pub struct Renderer {
    state: Mutex<State>,
    status: Option<Arc<StatusLine>>,
    /// Stdout is a terminal (in-place redraws are possible).
    tty: bool,
    expanded: AtomicBool,
    /// Set when the turn's live answer stream may have been left incomplete by
    /// a mid-turn verbosity change. Only `quiet` suppresses streamed deltas, so
    /// a turn that is `quiet` for part of a streamed answer but ends at another
    /// level loses the suppressed deltas. The frame renderer reconciles the
    /// final `AssistantMessage` in place regardless; the legacy renderer, which
    /// streams straight to the terminal and can't retract, uses this flag to
    /// reprint the authoritative full response at turn end. Reset at
    /// `begin_turn`, then raised the moment a non-empty answer delta is
    /// actually suppressed while quiet (and by a mid-turn switch to `quiet`).
    touched_quiet: AtomicBool,
    /// The app-owned frame renderer, when `renderer = "frame"` and stdout is a
    /// terminal. When set, all output is composed into one frame (transcript,
    /// editor, status as the last line) and diff-rendered by a single writer,
    /// instead of streaming into the terminal's scrollback.
    frame: Option<Mutex<FrameState>>,
}

/// The mutable state behind the app-owned frame renderer.
struct FrameState {
    out: FrameRenderer<io::Stdout>,
    /// The transcript, oldest first. A width change re-renders every item.
    items: Vec<StampedItem>,
    /// The current input editor `(line, cursor)`.
    editor: (String, usize),
    /// Messages queued while a turn is in flight, shown as an indicator row
    /// under the editor (0 hides it).
    queued: usize,
    /// The command type-ahead rows drawn under the editor (empty: none).
    menu: Vec<String>,
    /// Index of the assistant message currently being streamed into, so text
    /// deltas append to one growing item rather than adding a line each.
    stream: Option<usize>,
    /// The reasoning block streaming in `(text, started)`, shown collapsed.
    think: Option<(String, Instant)>,
    /// True once reasoning has arrived as `ThinkingDelta`s this turn. It lets
    /// the trailing full `Thinking` event skip re-emitting a summary that a
    /// preceding `TextDelta` already finalized, which would otherwise duplicate
    /// the reasoning line. Reset at each turn/message boundary.
    think_streamed: bool,
    /// The timestamp shown on the editor prompt, captured when a fresh prompt
    /// starts and held stable while the user types. Regenerating it on every
    /// render (keystroke, live status tick) would make the prompt stamp — and
    /// its width — drift mid-line; the legacy editor stamps once at prompt draw
    /// and only restamps on submission, so mirror that by refreshing this only
    /// at a turn boundary.
    prompt_stamp: String,
    /// A transient hint shown on the status bar (e.g. "(Ctrl-C again to
    /// exit)") instead of as a transcript item. Transient notes are
    /// cursor-relevant feedback: as a transcript item they would trigger a
    /// full-screen clear and land above the editor row, so the user — watching
    /// the cursor — would never see them. Rendered in place of the stats, it
    /// persists across ordinary status refreshes (which only re-render it) and
    /// is cleared explicitly by `clear_transient`, `begin_turn`, or `end_turn`.
    transient: Option<String>,
}

impl Renderer {
    pub fn new(status: Option<Arc<StatusLine>>, mode: crate::frame::RendererMode) -> Arc<Self> {
        let tty = io::stdout().is_terminal();
        let frame = (mode == crate::frame::RendererMode::Frame && tty).then(|| {
            Mutex::new(FrameState {
                out: FrameRenderer::new(io::stdout()),
                items: Vec::new(),
                editor: (String::new(), 0),
                queued: 0,
                menu: Vec::new(),
                stream: None,
                think: None,
                think_streamed: false,
                prompt_stamp: stamp(),
                transient: None,
            })
        });
        Arc::new(Self {
            state: Mutex::new(State { at_line_start: true, ..Default::default() }),
            status,
            tty,
            expanded: AtomicBool::new(false),
            touched_quiet: AtomicBool::new(false),
            frame,
        })
    }

    /// Whether the app-owned frame renderer is active.
    pub fn is_frame(&self) -> bool {
        self.frame.is_some()
    }

    /// Update the editor row (called by the line editor's frame hook) and
    /// re-render the frame. `queued` is the number of messages waiting behind
    /// the current turn, shown as an indicator under the editor; `menu` is the
    /// command type-ahead, drawn under the editor.
    pub fn set_editor(&self, line: &str, cursor: usize, queued: usize, menu: &[String]) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.editor = (line.to_string(), cursor);
            fs.queued = queued;
            fs.menu = menu.to_vec();
            self.frame_render(&mut fs);
        }
    }

    /// Re-render after a resize (or after a foreground picker clobbered the
    /// screen): force a full redraw at the current size.
    pub fn frame_resize(&self) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.out.invalidate();
            self.frame_render(&mut fs);
        }
    }

    /// Compose the transcript, editor and status bar into one frame and render
    /// it at the current terminal size.
    fn frame_render(&self, fs: &mut FrameState) {
        let (rows, cols) = status::terminal_size().unwrap_or((24, 80));
        let width = (cols as usize).max(1);
        let height = (rows as usize).max(1);
        let transcript = frame::transcript_lines(&fs.items, width);
        // Prefix the editor prompt with the timestamp when timestamps are on,
        // matching the legacy prompt so switching renderers keeps the setting.
        // Use the stamp captured at prompt start (not `stamp()`), so it stays
        // fixed while the user types rather than ticking every render.
        let prompt = format!("{}› ", fs.prompt_stamp);
        let mut editor = frame::editor_lines(&prompt, &fs.editor.0, fs.editor.1, width);
        if let Some(indicator) = frame::queue_indicator(fs.queued, width) {
            editor.push(indicator);
        }
        editor.extend(fs.menu.iter().map(|row| frame::fit_line(row, width)));
        // A transient hint (e.g. "(Ctrl-C again to exit)") takes over the
        // status bar so it is seen where the cursor is; otherwise the stats.
        let status = match &fs.transient {
            Some(text) => frame::transient_status(text, width),
            None => self.status.as_ref().map(|s| s.stats_line(width)).unwrap_or_default(),
        };
        let composed = frame::compose(&transcript, &editor, &status);
        let _ = fs.out.render(&composed, width, height);
    }

    /// End any in-flight streamed message/thinking so the next item starts
    /// fresh.
    fn frame_finish_stream(&self, fs: &mut FrameState) {
        fs.stream = None;
        fs.think_streamed = false;
        if let Some((text, started)) = fs.think.take() {
            let text = text.trim();
            if !text.is_empty() {
                fs.items.push(stamped(Item::Thinking {
                    chars: text.chars().count(),
                    seconds: started.elapsed().as_secs_f64(),
                }));
            }
        }
    }

    /// Map an agent event onto the transcript and re-render (frame mode).
    fn frame_event(&self, fs: &mut FrameState, event: &AgentEvent) {
        match event {
            AgentEvent::ThinkingDelta { text } => {
                fs.think_streamed = true;
                fs.think.get_or_insert_with(|| (String::new(), Instant::now())).0.push_str(text);
            }
            AgentEvent::Thinking { text } => {
                match fs.think.take() {
                    // Reasoning streamed as deltas but was not yet finalized by
                    // a `TextDelta` (e.g. reasoning-only, or the answer is not
                    // streamed): emit its summary now.
                    Some((_, started)) => {
                        let chars = text.trim().chars().count();
                        if chars > 0 {
                            fs.items.push(stamped(Item::Thinking { chars, seconds: started.elapsed().as_secs_f64() }));
                        }
                    }
                    // No pending reasoning. If deltas streamed this turn, a
                    // preceding `TextDelta` already finalized the summary, so
                    // skip to avoid duplicating it. Otherwise this is a
                    // non-streamed block delivered whole — emit it.
                    None if !fs.think_streamed => {
                        let chars = text.trim().chars().count();
                        if chars > 0 {
                            fs.items.push(stamped(Item::Thinking { chars, seconds: 0.0 }));
                        }
                    }
                    None => {}
                }
                fs.think_streamed = false;
                // Do NOT reset `fs.stream` here: a streamed assistant message
                // may already be in flight (reasoning can arrive after the
                // answer starts). Only `AssistantMessage` finalizes the stream;
                // clearing it here would make that event see `None` and append
                // the full response again, duplicating the streamed answer.
            }
            AgentEvent::TextDelta { text } => {
                if text.is_empty() {
                    return;
                }
                // Finalize any streamed reasoning into a Thinking item *before*
                // the assistant message begins, so the summary is preserved and
                // ordered ahead of the answer rather than dropped (or appended
                // after it by the trailing `Thinking` event).
                if let Some((think, started)) = fs.think.take() {
                    let think = think.trim();
                    if !think.is_empty() {
                        fs.items.push(stamped(Item::Thinking {
                            chars: think.chars().count(),
                            seconds: started.elapsed().as_secs_f64(),
                        }));
                    }
                }
                match fs.stream {
                    Some(i) => {
                        if let Some(StampedItem { item: Item::Message { text: existing, .. }, .. }) =
                            fs.items.get_mut(i)
                        {
                            existing.push_str(text);
                        }
                    }
                    None => {
                        fs.items.push(stamped(Item::Message { role: Role::Assistant, text: (*text).to_string() }));
                        fs.stream = Some(fs.items.len() - 1);
                    }
                }
            }
            AgentEvent::AssistantMessage { text, .. } => {
                // Reconcile the streamed answer with the authoritative final
                // text. Normally the accumulated deltas already equal `text`,
                // so this is a no-op. But a mid-turn `/verbosity` change can
                // desync them: switching to quiet mid-stream drops the
                // remaining deltas (leaving a truncated prefix), and switching
                // away from quiet starts a fresh stream at a suffix (dropping
                // the earlier deltas). Overwriting in place — rather than
                // trusting accumulation — restores the full message in every
                // case without duplicating it or disturbing the item's order
                // (a mid-stream `/trajectory` export sits in a later item).
                match fs.stream {
                    Some(i) if !text.is_empty() => {
                        if let Some(StampedItem { item: Item::Message { text: existing, .. }, .. }) =
                            fs.items.get_mut(i)
                            && existing.as_str() != *text
                        {
                            *existing = (*text).to_string();
                        }
                    }
                    Some(_) => {}
                    None if !text.is_empty() => {
                        fs.items.push(stamped(Item::Message { role: Role::Assistant, text: (*text).to_string() }));
                    }
                    None => {}
                }
                self.frame_finish_stream(fs);
            }
            AgentEvent::Plan { plan } => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::Plan((*plan).clone())));
            }
            // Mirror the legacy renderer's user-facing filtering: plan_add /
            // plan_update are shown as the Plan checklist (the `Plan` event),
            // not as raw tool calls, and report_outcome's summary follows as
            // the answer, so only its status marker is shown.
            AgentEvent::ToolCall { call } if quiet_plan_tool(&call.name) => {
                self.frame_finish_stream(fs);
            }
            AgentEvent::ToolResult { call, ok: true, .. } if quiet_plan_tool(&call.name) => {}
            AgentEvent::ToolResult { call, ok: false, output } if quiet_plan_tool(&call.name) => {
                let _ = call;
                fs.items.push(stamped(Item::ToolResult {
                    ok: false,
                    output: (*output).to_string(),
                    verbose: verbosity() >= Verbosity::Verbose,
                }));
            }
            AgentEvent::ToolCall { call }
                if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose =>
            {
                self.frame_finish_stream(fs);
                // Derive the status from the parsed outcome so an invalid
                // `report_outcome` is not rendered as a success.
                let mark = match crate::goal::Status::from_args(&call.arguments) {
                    Some(crate::goal::Status::Blocked) => "■ blocked".to_string(),
                    Some(crate::goal::Status::NeedsInput) => "? needs input".to_string(),
                    Some(crate::goal::Status::Completed) => "✔ completed".to_string(),
                    None => {
                        let raw = crate::sanitize_terminal_text(
                            call.arguments.get("status").and_then(serde_json::Value::as_str).unwrap_or_default(),
                        );
                        if raw.is_empty() { "• unknown".to_string() } else { format!("• {raw}") }
                    }
                };
                fs.items.push(stamped(Item::Note(mark)));
            }
            AgentEvent::ToolResult { call, ok: true, .. }
                if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose => {}
            AgentEvent::ToolCall { call } => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::ToolCall { name: call.name.clone(), summary: tool_summary_text(call) }));
            }
            AgentEvent::ToolResult { ok, output, .. } => {
                fs.items.push(stamped(Item::ToolResult {
                    ok: *ok,
                    output: (*output).to_string(),
                    verbose: verbosity() >= Verbosity::Verbose,
                }));
            }
            AgentEvent::Compacted => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::Note("⟳ context compacted".to_string())));
            }
            // Steer/queued messages absorbed mid-turn arrive as `UserMessage`
            // events; render them in the transcript. Replaying a resumed
            // session also emits the loaded user turns through this arm so the
            // frame reconstructs the full history. (The primary interactive
            // prompt is recorded directly via `frame_user_message`, not here,
            // so there is no double entry.)
            AgentEvent::UserMessage { text } => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::Message { role: Role::User, text: (*text).to_string() }));
            }
            AgentEvent::Context => {}
        }
        self.frame_render(fs);
    }

    /// Record a submitted user message in the transcript (frame mode).
    pub fn frame_user_message(&self, text: &str) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.items.push(stamped(Item::Message { role: Role::User, text: text.to_string() }));
            self.frame_render(&mut fs);
        }
    }

    /// Emit command / informational output (e.g. slash-command replies). In
    /// frame mode it is captured as a transcript item so direct writes can't
    /// corrupt the owned frame; otherwise it prints inline as before.
    /// Output of a command run while a turn is streaming. The frame renderer
    /// adds it to the transcript as usual; the legacy renderer prints it as a
    /// note, which waits for a half-streamed line to end rather than landing
    /// in the middle of it (`print_block` there is a bare `println!`).
    pub fn turn_block(&self, text: &str) {
        if self.frame.is_some() {
            self.print_block(text);
        } else {
            self.note(text);
        }
    }

    /// Raw output of a command run while a turn is streaming (e.g.
    /// `/trajectory --json`). The frame renderer emits it verbatim via
    /// `print_raw`. The legacy renderer must not route it through `note` —
    /// that would prepend a timestamp and wrap it in DIM/reset escapes,
    /// corrupting JSON and Markdown — but it also can't print it straight away
    /// without landing in the middle of a half-streamed line. So it is held
    /// back (like a deferred note) and emitted verbatim once the streamed line
    /// ends at `end_turn`, keeping the payload byte-exact.
    pub fn turn_raw(&self, text: &str) {
        if self.frame.is_some() {
            self.print_raw(text);
            return;
        }
        let mut state = self.state.lock().unwrap();
        // Defer whenever the cursor is not at a line boundary, regardless of
        // whether that line is answer text or reasoning: a `thinking_delta`
        // leaves the cursor mid-line with `streamed_text` false, and printing
        // now would prefix the JSON/Markdown with the partial thinking line.
        if !state.at_line_start {
            state.deferred_raw.push(text.to_string());
            return;
        }
        // Write through `out` (not a bare `println!`) while retaining the state
        // lock: `out` holds the process-wide terminal lock, so a concurrent
        // status/SIGWINCH redraw cannot interleave its escape sequences with
        // the raw payload and corrupt it.
        self.out(&mut state, text);
        self.out(&mut state, "\n");
    }

    pub fn print_block(&self, text: &str) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.items.push(stamped(Item::Output(text.to_string())));
            self.frame_render(&mut fs);
            return;
        }
        println!("{text}");
    }

    /// Emit machine-readable output verbatim (e.g. `/trajectory --json`). The
    /// frame transcript wraps `Item::Output` to the terminal width and prefixes
    /// a timestamp, which hard-breaks long JSON string values and puts text
    /// before the opening `{`, so export modes bypass it. In frame mode the
    /// raw text is printed once into scrollback and then kept in the
    /// transcript as an `Item::Raw`, which renders byte-exact: the restore
    /// render's forced full redraw clears the screen AND scrollback, so an
    /// export that lives only in scrollback would be erased the moment the
    /// frame is restored. Keeping it as an item re-emits it inside the frame
    /// on every redraw — including resizes, which clear scrollback too. The
    /// frame lock is held across the direct write and the following render so
    /// a concurrent editor/resize/event render can't interleave its escape
    /// sequences with the raw bytes (`println!` takes no terminal lock, so the
    /// frame mutex is the only thing serializing them).
    ///
    /// Unlike the other transcript writes this does NOT finish an in-flight
    /// stream: typed mid-turn (the only way this runs while a response is
    /// streaming), clearing `fs.stream` would make the trailing
    /// `AssistantMessage` see no active stream and append the full response
    /// again, duplicating the answer. The pending `TextDelta`s still append
    /// to the streamed item above the export, and `AssistantMessage` closes
    /// the stream out as usual.
    pub fn print_raw(&self, text: &str) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            println!("{text}");
            fs.items.push(stamped(Item::Raw(text.to_string())));
            fs.out.invalidate();
            self.frame_render(&mut fs);
            return;
        }
        println!("{text}");
    }

    fn width(&self) -> usize {
        status::terminal_size().map(|(_, cols)| cols as usize).unwrap_or(80).max(20)
    }

    /// Wipe the screen and scrollback for a fresh session, re-pinning the
    /// status line's scroll region, and reset the renderer's line state.
    pub fn clear_screen(&self) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.items.clear();
            fs.stream = None;
            fs.think = None;
            fs.out.invalidate();
            self.frame_render(&mut fs);
            return;
        }
        match &self.status {
            Some(status) => status.clear(),
            None if self.tty => {
                crate::status::with_term_lock(|| {
                    let mut stdout = io::stdout().lock();
                    let _ = stdout.write_all(b"\x1b[H\x1b[2J\x1b[3J");
                    let _ = stdout.flush();
                });
            }
            None => {}
        }
        let mut state = self.state.lock().unwrap();
        *state = State { at_line_start: true, ..Default::default() };
    }

    fn out(&self, state: &mut State, text: &str) {
        if text.is_empty() {
            return;
        }
        crate::status::with_term_lock(|| {
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
        });
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
        // A turn starting supersedes any transient prompt-level hint.
        self.clear_transient();
        // Reset the truncation guard: it is raised only when a non-empty answer
        // delta is *actually* suppressed while quiet (see the quiet gate in
        // `event`), not merely because the turn starts quiet — a quiet turn
        // whose answer streams normally after a switch to a louder level must
        // not be reprinted.
        self.touched_quiet.store(false, Ordering::Relaxed);
        let mut state = self.state.lock().unwrap();
        state.in_turn = true;
        state.at_line_start = true;
    }

    /// Set the global verbosity in response to `/verbosity` typed mid-turn.
    /// Applying it immediately keeps the rest of the turn at the new level; the
    /// final-answer reconciliation (frame: in place; legacy: a turn-end reprint
    /// gated on [`Self::answer_may_be_truncated`]) is what prevents a switch
    /// across the `quiet` boundary from truncating the streamed answer.
    ///
    /// This does NOT raise the truncation guard itself: merely entering quiet
    /// has not dropped any answer text yet, so a `/verbosity quiet` followed by
    /// `/verbosity normal` before any delta arrives would otherwise reprint a
    /// fully streamed answer. Only the quiet `event` gate raises the guard,
    /// when it actually suppresses a non-empty `TextDelta`.
    pub fn set_verbosity_mid_turn(&self, level: Verbosity) {
        set_verbosity(level);
    }

    /// Whether the turn's live-streamed answer may be incomplete because the
    /// verbosity was `quiet` for part of it (so some streamed deltas were
    /// suppressed). The legacy renderer reprints the full response when this is
    /// true and the turn did not already reprint via its `quiet` end path.
    pub fn answer_may_be_truncated(&self) -> bool {
        self.touched_quiet.load(Ordering::Relaxed)
    }

    pub fn end_turn(&self) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            self.frame_finish_stream(&mut fs);
            // A fresh prompt starts now the turn is done: restamp it (matching
            // the legacy editor, which restamps on submission) so the next
            // prompt reflects the current time, then holds steady while typing.
            fs.prompt_stamp = stamp();
            // The turn is over; any transient hint no longer applies.
            fs.transient = None;
            self.frame_render(&mut fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        self.finish_thinking(&mut state);
        self.newline(&mut state);
        for note in std::mem::take(&mut state.deferred) {
            self.out(&mut state, &format!("{DIM}{note}{RESET}\n"));
        }
        // Raw exports queued mid-turn go out verbatim (no stamp/DIM), each on
        // its own line, so the payload stays byte-exact.
        for raw in std::mem::take(&mut state.deferred_raw) {
            self.out(&mut state, &raw);
            self.out(&mut state, "\n");
        }
        state.in_turn = false;
        state.streamed_text = false;
        state.streamed_thinking = false;
    }

    /// Print a short note on its own line (e.g. a queued steer). If an
    /// answer is streaming mid-line, the note waits for the line to end.
    pub fn note(&self, text: &str) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.items.push(stamped(Item::Note(text.to_string())));
            self.frame_render(&mut fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        if state.streamed_text && !state.at_line_start {
            state.deferred.push(format!("{}{DIM}{text}", stamp()));
            return;
        }
        self.note_now(&mut state, text);
    }

    /// Print a note on its own line straight away.
    pub fn urgent_note(&self, text: &str) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.items.push(stamped(Item::Note(text.to_string())));
            self.frame_render(&mut fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        self.note_now(&mut state, text);
    }

    /// Clear any transient status-bar hint (frame mode only; a no-op in legacy
    /// mode, where transients are ordinary printed lines).
    pub fn clear_transient(&self) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            if fs.transient.take().is_some() {
                self.frame_render(&mut fs);
            }
        }
    }

    /// Show a short transient hint where the user is looking, without adding
    /// it to the transcript. In frame mode it takes over the status bar (a
    /// transcript `Item::Note` would trigger a full-screen clear and land above
    /// the editor row, so the user watching the cursor never sees it); in
    /// legacy mode it prints inline like `note`. Use for cursor-relevant
    /// feedback such as "(Ctrl-C again to exit)".
    pub fn transient_note(&self, text: &str) {
        if let Some(frame) = &self.frame {
            let mut fs = frame.lock().unwrap();
            fs.transient = Some(text.to_string());
            self.frame_render(&mut fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        self.note_now(&mut state, text);
    }

    fn note_now(&self, state: &mut State, text: &str) {
        self.finish_thinking(state);
        self.newline(state);
        self.out(state, &format!("{}{DIM}{text}{RESET}\n", stamp()));
    }

    pub fn event(&self, event: &AgentEvent) {
        if let Some(frame) = &self.frame {
            // Hold the test verbosity lock across the quiet check and the event
            // application so the pair is atomic against a concurrent test that
            // changes the global level: without it a test that sets quiet
            // (e.g. the truncation-guard test) can flip the level between this
            // read and `frame_event`, making an unlocked renderer test drop its
            // events and fail nondeterministically. Production never mutates
            // verbosity on the event path, so the uncontended lock is free.
            #[cfg(test)]
            let _verbosity_guard = tests::verbosity_lock();
            if verbosity() == Verbosity::Quiet
                && !matches!(event, AgentEvent::AssistantMessage { .. } | AgentEvent::Context)
            {
                return;
            }
            let mut fs = frame.lock().unwrap();
            self.frame_event(&mut fs, event);
            return;
        }
        if matches!(event, AgentEvent::Context | AgentEvent::Compacted)
            && let Some(status) = &self.status
        {
            status.draw();
        }
        if verbosity() == Verbosity::Quiet {
            // Mark the truncation guard only when a non-empty answer delta is
            // actually suppressed here: those deltas never reach the terminal,
            // so if the turn later ends at a louder level the live stream is
            // incomplete and the legacy renderer reprints the full response.
            // Merely being quiet (with no delta suppressed yet) must not set
            // this — a turn that switches to a louder level before any delta
            // streams its answer normally, and reprinting would duplicate it.
            if let AgentEvent::TextDelta { text } = event
                && !text.is_empty()
            {
                self.touched_quiet.store(true, Ordering::Relaxed);
            }
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
                let text = stamp_block(&format!(
                    "{RED}●{RESET} {BOLD}{}{RESET}\n{}",
                    call.name,
                    self.tool_result(false, output)
                ));
                self.out(&mut state, &text);
            }
            // The outcome's summary follows as the answer; show just its status.
            AgentEvent::ToolCall { call }
                if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose =>
            {
                self.finish_thinking(&mut state);
                self.newline(&mut state);
                state.streamed_thinking = false;
                // Derive the status from the parsed outcome so string-encoded
                // arguments (a JSON string, which `Outcome::from_args` accepts)
                // and aliases render the correct marker, not a false success.
                let mark = match crate::goal::Status::from_args(&call.arguments) {
                    Some(crate::goal::Status::Blocked) => format!("{RED}■ blocked{RESET}"),
                    Some(crate::goal::Status::NeedsInput) => format!("{YELLOW}? needs input{RESET}"),
                    Some(crate::goal::Status::Completed) => format!("{GREEN}✔ completed{RESET}"),
                    None => {
                        // An unparseable/unknown/missing status is NOT a success;
                        // use a neutral marker so an invalid `report_outcome`
                        // (e.g. `{"status":"oops"}`) is not shown as a green ✔.
                        // `status` is model-controlled; strip control/escape
                        // characters so an invalid value cannot smuggle ANSI/OSC
                        // sequences into the terminal via this fallback.
                        let raw = crate::sanitize_terminal_text(
                            call.arguments.get("status").and_then(serde_json::Value::as_str).unwrap_or_default(),
                        );
                        if raw.is_empty() {
                            format!("{DIM}• unknown{RESET}")
                        } else {
                            format!("{DIM}• {raw}{RESET}")
                        }
                    }
                };
                self.out(&mut state, &format!("{}{mark}\n", stamp()));
            }
            AgentEvent::ToolResult { call, ok: true, .. }
                if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose => {}
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
            state.thinking =
                Some(ThinkBlock { text: String::new(), started: Instant::now(), stamp, expanded, last_draw: None });
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
        if self.frame.is_some() {
            // Reasoning is already shown collapsed in the transcript; there is
            // no in-place expand/collapse in frame mode yet.
            return false;
        }
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
    let text = tool_summary_text(call);
    format!("{DIM}{}{RESET}", fit(&text, width))
}

/// The raw one-line argument summary for a tool call (no colour, no fitting),
/// for the frame renderer's [`Item::ToolCall`](crate::frame::Item).
pub fn tool_summary_text(call: &ToolCall) -> String {
    let text = match &call.arguments {
        Value::Object(args) => ["command", "path", "file_path", "pattern", "url", "text"]
            .iter()
            .find_map(|key| args.get(*key).and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| if args.is_empty() { String::new() } else { call.arguments.to_string() }),
        Value::String(raw) => raw.clone(),
        other => other.to_string(),
    };
    text.split_whitespace().collect::<Vec<_>>().join(" ")
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

    /// Serializes tests that read or mutate the process-global verbosity
    /// (`LEVEL`): the test harness runs them on separate threads, so two tests
    /// setting different levels at once would race and flake. Acquired with
    /// `verbosity_lock()`, which ignores poisoning so one panicking test does
    /// not cascade a `PoisonError` failure into the others.
    ///
    /// The lock is *reentrant on the owning thread*: a test that holds it and
    /// then drives the renderer's `event` path re-acquires it in the frame
    /// quiet gate (which locks it so the verbosity check + event application is
    /// atomic against other tests). A plain `Mutex` would deadlock there, so
    /// recursion by the owning thread is allowed while other threads still
    /// block on the inner mutex.
    static VERBOSITY_LOCK: Mutex<()> = Mutex::new(());
    static VERBOSITY_OWNER: AtomicUsize = AtomicUsize::new(0);

    thread_local! {
        static VERBOSITY_DEPTH: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    }

    /// A reentrant guard for [`VERBOSITY_LOCK`]: the owning thread may hold
    /// several at once (each acquisition increments a thread-local depth); the
    /// inner mutex is released only when the last guard for that thread drops.
    pub(super) struct VerbosityGuard {
        inner: Option<std::sync::MutexGuard<'static, ()>>,
    }

    impl Drop for VerbosityGuard {
        fn drop(&mut self) {
            let remaining = VERBOSITY_DEPTH.with(|d| {
                let r = d.get().saturating_sub(1);
                d.set(r);
                r
            });
            if remaining == 0 {
                // Outermost guard for this thread. Clear the owner *while the
                // mutex is still held*, then release it: clearing after the
                // release opens a gap where another thread acquires the mutex
                // and publishes its id, which this store would then clobber
                // back to 0 — a recursive `event()` on that new owner would see
                // owner 0, re-lock its own non-reentrant mutex, and deadlock.
                VERBOSITY_OWNER.store(0, Ordering::SeqCst);
                self.inner.take();
            }
        }
    }

    pub(super) fn verbosity_lock() -> VerbosityGuard {
        let tid = current_thread_id();
        if VERBOSITY_OWNER.load(Ordering::SeqCst) == tid && tid != 0 {
            // Already owned by this thread: recurse without touching the mutex.
            VERBOSITY_DEPTH.with(|d| d.set(d.get() + 1));
            return VerbosityGuard { inner: None };
        }
        let inner = VERBOSITY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        VERBOSITY_OWNER.store(tid, Ordering::SeqCst);
        VERBOSITY_DEPTH.with(|d| d.set(1));
        VerbosityGuard { inner: Some(inner) }
    }

    #[test]
    fn verbosity_guard_owner_tracks_reentrancy_and_handoff() {
        let tid = current_thread_id();
        let outer = verbosity_lock();
        // Held by this thread: the owner is published while the mutex is held.
        assert_eq!(VERBOSITY_OWNER.load(Ordering::SeqCst), tid);
        {
            let _inner = verbosity_lock();
            // Reentrant acquire does not change the owner.
            assert_eq!(VERBOSITY_OWNER.load(Ordering::SeqCst), tid);
        }
        // Dropping an inner (non-outermost) guard keeps the lock owned.
        assert_eq!(VERBOSITY_OWNER.load(Ordering::SeqCst), tid);
        drop(outer);

        // A second thread can now take the lock cleanly: the outermost drop
        // cleared the owner *before* releasing the mutex, so this handoff never
        // sees the owner clobbered back to 0 under it (which would deadlock a
        // recursive acquire). It observes itself as the owner while it holds it.
        let handed = std::thread::spawn(|| {
            let other = current_thread_id();
            let g = verbosity_lock();
            assert_eq!(VERBOSITY_OWNER.load(Ordering::SeqCst), other);
            let _reentrant = verbosity_lock(); // must not deadlock
            assert_eq!(VERBOSITY_OWNER.load(Ordering::SeqCst), other);
            drop(_reentrant);
            drop(g);
        });
        handed.join().expect("second thread acquired the verbosity lock without deadlock");
    }

    /// A unique, nonzero per-thread id for identifying the lock owner.
    fn current_thread_id() -> usize {
        thread_local! {
            static ID: usize = NEXT_THREAD_ID.fetch_add(1, Ordering::Relaxed);
        }
        static NEXT_THREAD_ID: AtomicUsize = AtomicUsize::new(1);
        ID.with(|id| *id)
    }

    impl Renderer {
        /// Build a frame-mode renderer regardless of tty, for driving
        /// `frame_event` in tests. Rendering writes to stdout (captured by the
        /// test harness).
        fn frame_for_test() -> Arc<Self> {
            Arc::new(Self {
                state: Mutex::new(State { at_line_start: true, ..Default::default() }),
                status: None,
                tty: true,
                expanded: AtomicBool::new(false),
                touched_quiet: AtomicBool::new(false),
                frame: Some(Mutex::new(FrameState {
                    out: FrameRenderer::new(io::stdout()),
                    items: Vec::new(),
                    editor: (String::new(), 0),
                    queued: 0,
                    menu: Vec::new(),
                    stream: None,
                    think: None,
                    think_streamed: false,
                    prompt_stamp: stamp(),
                    transient: None,
                })),
            })
        }

        /// Build a legacy (non-frame) renderer for driving the legacy `event`
        /// path in tests. The truncation guard is a legacy-renderer concern:
        /// the frame renderer reconciles the final `AssistantMessage` in place
        /// and never consults `touched_quiet`.
        fn legacy_for_test() -> Arc<Self> {
            Arc::new(Self {
                state: Mutex::new(State { at_line_start: true, ..Default::default() }),
                status: None,
                tty: true,
                expanded: AtomicBool::new(false),
                touched_quiet: AtomicBool::new(false),
                frame: None,
            })
        }

        #[cfg(test)]
        fn frame_items(&self) -> Vec<StampedItem> {
            self.frame.as_ref().unwrap().lock().unwrap().items.clone()
        }

        #[cfg(test)]
        fn frame_transient(&self) -> Option<String> {
            self.frame.as_ref().unwrap().lock().unwrap().transient.clone()
        }
    }

    #[test]
    fn transient_note_stays_out_of_the_transcript_and_clears_on_turn_end() {
        let r = Renderer::frame_for_test();
        r.transient_note("(Ctrl-C again to exit)");
        // The hint is on the status bar, not a transcript item (a transcript
        // note would trigger a full-screen clear and land above the editor).
        assert_eq!(r.frame_transient().as_deref(), Some("(Ctrl-C again to exit)"));
        assert!(
            r.frame_items().iter().all(|i| !matches!(&i.item, Item::Note(t) if t.contains("Ctrl-C"))),
            "transient note leaked into the transcript: {:?}",
            r.frame_items()
        );
        // A turn boundary clears it so the hint does not stick.
        r.end_turn();
        assert_eq!(r.frame_transient(), None);
    }

    #[test]
    fn begin_turn_supersedes_a_transient_hint() {
        let r = Renderer::frame_for_test();
        r.transient_note("(Ctrl-C again to exit)");
        r.begin_turn();
        assert_eq!(r.frame_transient(), None);
    }

    #[test]
    fn truncation_guard_tracks_suppressed_deltas_not_quiet_start() {
        // A turn that merely *starts* quiet has not lost any answer yet: if the
        // user switches to a louder level before any delta arrives, the answer
        // streams in full and must NOT be reprinted. The guard is raised only
        // once a non-empty delta is actually suppressed while quiet.
        let _lock = verbosity_lock();
        let r = Renderer::legacy_for_test();

        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        // No delta suppressed yet — only the quiet start. Switching to normal
        // before any answer delta means the answer streams normally.
        set_verbosity(Verbosity::Normal);
        assert!(!r.answer_may_be_truncated(), "a quiet start with no suppressed delta must not flag truncation");

        // A fresh turn that genuinely suppresses a non-empty delta while quiet
        // IS flagged (the legacy renderer then reprints the full response).
        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "hello" });
        assert!(r.answer_may_be_truncated(), "a suppressed non-empty delta must flag truncation");
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn entering_quiet_alone_does_not_flag_truncation() {
        // `/verbosity quiet` then `/verbosity normal` before any answer delta
        // arrives must not flag truncation: nothing was suppressed, so the
        // answer streams in full and reprinting it would duplicate it. Only a
        // genuinely suppressed non-empty delta raises the guard.
        let _lock = verbosity_lock();
        let r = Renderer::legacy_for_test();
        set_verbosity(Verbosity::Normal);
        r.begin_turn();
        r.set_verbosity_mid_turn(Verbosity::Quiet);
        r.set_verbosity_mid_turn(Verbosity::Normal);
        assert!(
            !r.answer_may_be_truncated(),
            "entering quiet with no suppressed delta must not flag truncation"
        );
    }

    #[test]
    fn turn_raw_defers_while_reasoning_is_mid_line() {
        // A thinking delta leaves the cursor mid-line with `streamed_text`
        // false. A raw export then must still be deferred (not printed into the
        // middle of the reasoning line) and flushed verbatim at end_turn.
        let _lock = verbosity_lock();
        set_verbosity(Verbosity::Normal);
        let r = Renderer::legacy_for_test();
        r.begin_turn();
        r.event(&AgentEvent::ThinkingDelta { text: "pondering" });
        assert!(!r.state.lock().unwrap().at_line_start, "a thinking delta leaves the cursor mid-line");
        r.turn_raw("{\"k\":1}");
        assert_eq!(
            r.state.lock().unwrap().deferred_raw,
            vec!["{\"k\":1}".to_string()],
            "a raw export during mid-line reasoning must be deferred"
        );
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn turn_raw_defers_while_answer_text_is_mid_line() {
        let _lock = verbosity_lock();
        set_verbosity(Verbosity::Normal);
        let r = Renderer::legacy_for_test();
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "partial answer" });
        r.turn_raw("{\"k\":1}");
        assert_eq!(
            r.state.lock().unwrap().deferred_raw,
            vec!["{\"k\":1}".to_string()],
            "a raw export during a half-streamed answer must be deferred"
        );
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn turn_raw_at_a_line_boundary_prints_without_deferring() {
        // At a line boundary the export goes out immediately (through the
        // terminal-locked `out`), leaving nothing queued for end_turn.
        let _lock = verbosity_lock();
        set_verbosity(Verbosity::Normal);
        let r = Renderer::legacy_for_test();
        r.begin_turn();
        assert!(r.state.lock().unwrap().at_line_start);
        r.turn_raw("{\"k\":1}");
        assert!(
            r.state.lock().unwrap().deferred_raw.is_empty(),
            "a raw export at a line boundary must not be deferred"
        );
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn streamed_reasoning_then_text_emits_one_thinking_summary() {
        let r = Renderer::frame_for_test();
        // Reasoning streams as deltas, then the answer streams as text, then a
        // trailing full `Thinking` event repeats the reasoning: the summary
        // must appear exactly once, and the streamed answer exactly once.
        r.event(&AgentEvent::ThinkingDelta { text: "pondering the plan" });
        r.event(&AgentEvent::TextDelta { text: "Here " });
        r.event(&AgentEvent::TextDelta { text: "is the answer." });
        r.event(&AgentEvent::Thinking { text: "pondering the plan" });
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "Here is the answer." });
        let items = r.frame_items();
        let thinking = items.iter().filter(|i| matches!(i.item, Item::Thinking { .. })).count();
        let messages = items.iter().filter(|i| matches!(i.item, Item::Message { role: Role::Assistant, .. })).count();
        assert_eq!(thinking, 1, "reasoning summary duplicated: {items:?}");
        assert_eq!(messages, 1, "streamed answer duplicated: {items:?}");
    }

    #[test]
    fn non_streamed_thinking_event_still_emits_summary() {
        let r = Renderer::frame_for_test();
        // No ThinkingDelta: a whole `Thinking` block must still show once.
        r.event(&AgentEvent::Thinking { text: "quick thought" });
        let thinking = r.frame_items().iter().filter(|i| matches!(i.item, Item::Thinking { .. })).count();
        assert_eq!(thinking, 1);
    }

    #[test]
    fn user_message_event_is_recorded_in_frame_transcript() {
        // Reads the process-global verbosity (a concurrent test setting `quiet`
        // would make `event` drop the message), so serialize against those.
        let _lock = verbosity_lock();
        set_verbosity(Verbosity::Normal);
        let r = Renderer::frame_for_test();
        // Replaying a resumed session (and mid-turn steer messages) surface as
        // `UserMessage` events; they must land in the transcript.
        r.event(&AgentEvent::UserMessage { text: "resumed prompt" });
        let user = r
            .frame_items()
            .iter()
            .filter(|i| matches!(&i.item, Item::Message { role: Role::User, text, .. } if text == "resumed prompt"))
            .count();
        assert_eq!(user, 1);
    }

    #[test]
    fn raw_export_is_kept_in_the_frame_transcript() {
        let r = Renderer::frame_for_test();
        // A raw export (`/trajectory --json`) is printed to scrollback AND kept
        // as a transcript item: the restore render's full redraw clears the
        // screen and scrollback, so an export that lived only in scrollback
        // would be erased the moment the frame is restored.
        r.print_raw("{\"session_id\":\"s\"}");
        let raw =
            r.frame_items().iter().filter(|i| matches!(&i.item, Item::Raw(t) if t.contains("session_id"))).count();
        assert_eq!(raw, 1, "the export must survive the frame restore: {:?}", r.frame_items());
    }

    #[test]
    fn raw_export_mid_stream_does_not_duplicate_the_answer() {
        let r = Renderer::frame_for_test();
        // `/trajectory --json` typed while the answer streams: the export must
        // not close the stream out. If it did, the trailing `AssistantMessage`
        // would see no active stream and append the full response a second
        // time (and a delta split across the export would start a new item).
        r.event(&AgentEvent::TextDelta { text: "Here " });
        r.print_raw("{\"session_id\":\"s\"}");
        r.event(&AgentEvent::TextDelta { text: "is the answer." });
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "Here is the answer." });
        let items = r.frame_items();
        let messages: Vec<_> = items
            .iter()
            .filter_map(|i| match &i.item {
                Item::Message { role: Role::Assistant, text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(messages, ["Here is the answer."], "streamed answer duplicated or split: {items:?}");
        assert_eq!(
            items.iter().filter(|i| matches!(&i.item, Item::Raw(t) if t.contains("session_id"))).count(),
            1,
            "the export must still be kept: {items:?}"
        );
    }

    #[test]
    fn assistant_message_reconciles_a_partial_stream() {
        // A mid-turn `/verbosity` change can desync the streamed deltas from
        // the final answer: switching to quiet drops the remaining deltas
        // (leaving a truncated prefix), and switching away from quiet starts a
        // fresh stream at a suffix (dropping the earlier deltas). Either way the
        // open stream item holds only part of the answer when `AssistantMessage`
        // arrives. It must reconcile to the full authoritative text — in place,
        // without duplicating — rather than trusting the accumulated deltas.
        for partial in ["Here ", "answer."] {
            let r = Renderer::frame_for_test();
            r.event(&AgentEvent::TextDelta { text: partial });
            r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "Here is the answer." });
            let messages: Vec<_> = r
                .frame_items()
                .iter()
                .filter_map(|i| match &i.item {
                    Item::Message { role: Role::Assistant, text, .. } => Some(text.clone()),
                    _ => None,
                })
                .collect();
            assert_eq!(
                messages,
                ["Here is the answer."],
                "partial stream {partial:?} was not reconciled to the full answer"
            );
        }
    }

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
        let call = ToolCall {
            id: "1".into(),
            name: "bash".into(),
            arguments: json!({"command": "ls\n  -la"}),
            item_id: None,
            malformed_arguments: None,
        };
        assert!(tool_summary(&call, 40).contains("ls -la"));
        let call = ToolCall {
            id: "1".into(),
            name: "get_time".into(),
            arguments: json!({}),
            item_id: None,
            malformed_arguments: None,
        };
        assert_eq!(strip_ansi(&tool_summary(&call, 40)), "");
        assert_eq!(fit("abcdef", 4), "abc…");
        assert_eq!(strip_ansi("\x1b[2mhi\x1b[0m\r\n"), "hi\n");
    }
}
