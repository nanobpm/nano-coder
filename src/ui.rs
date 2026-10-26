//! Interactive output: verbosity levels and a renderer that turns agent
//! events into streamed text, collapsible thinking and inline tool calls.

use std::io::{self, IsTerminal, Write};

/// Frames of the busy spinner drawn in place of the prompt glyph.
const SPINNER: [char; 10] = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
/// How long each spinner frame shows; the frame is redrawn this often.
pub const SPINNER_INTERVAL: std::time::Duration = std::time::Duration::from_millis(100);

/// The turn's working clock: when the turn started, and how much of it was
/// spent waiting for the user.
///
/// The count shown on the prompt is working time, not wall time: while the
/// turn is blocked waiting for a picker (the `question` tool, the turn cap)
/// the clock is paused, so a question the user takes minutes to answer does
/// not inflate the time the agent was said to be working. [`Clock::pause`]
/// banks the run since the start and [`Clock::resume`] restarts from now,
/// which keeps the interruption out of the total while it stays visible on
/// the screen (a frozen spinner and a frozen `working 12s`) instead of the
/// prompt flipping to `ready`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Clock {
    /// When the current working run began (`None`: paused).
    since: Option<Instant>,
    /// Whole spans already completed by earlier runs of this turn.
    banked: Duration,
}

impl Clock {
    /// Start the clock at `now`.
    fn started(now: Instant) -> Self {
        Self { since: Some(now), banked: Duration::ZERO }
    }

    /// Working time so far at `now`: the banked spans plus the running one.
    fn elapsed(&self, now: Instant) -> Duration {
        match self.since {
            Some(since) => self.banked + now.saturating_duration_since(since),
            None => self.banked,
        }
    }

    /// Stop counting: bank the run since the start. Idempotent, so overlapping
    /// pauses (a nested picker) never bank the same span twice.
    fn pause(&mut self, now: Instant) {
        if let Some(since) = self.since.take() {
            self.banked += now.saturating_duration_since(since);
        }
    }

    /// Resume counting from `now`, keeping the banked spans.
    fn resume(&mut self, now: Instant) {
        if self.since.is_none() {
            self.since = Some(now);
        }
    }
}

/// The prompt glyph: a cyan spinner while a turn runs, a green `›` when the
/// harness is waiting for the user. A paused clock keeps its spinner: the turn
/// still owns the prompt, it is just not accruing working time.
fn prompt_glyph(busy: Option<(&Clock, Instant)>) -> String {
    match busy {
        Some((clock, now)) => {
            let frame = (clock.elapsed(now).as_millis() / SPINNER_INTERVAL.as_millis()) as usize % SPINNER.len();
            format!("\x1b[38;5;117m{}\x1b[39m", SPINNER[frame])
        }
        None => "\x1b[38;5;114m›\x1b[39m".to_string(),
    }
}

/// The dim hint after the cursor of an empty editor: whose turn it is.
fn prompt_hint(busy: Option<(&Clock, Instant)>) -> String {
    match busy {
        Some((clock, now)) => format!("working {} · Enter steers, Esc Esc cancels", elapsed_text(clock.elapsed(now))),
        None => "ready · type a message, /help for commands".to_string(),
    }
}

/// `4s`, `1m 05s`: whole seconds of the running turn.
fn elapsed_text(elapsed: std::time::Duration) -> String {
    let secs = elapsed.as_secs();
    if secs < 60 { format!("{secs}s") } else { format!("{}m {:02}s", secs / 60, secs % 60) }
}

#[cfg(test)]
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
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
/// consistently — matching plain output, where `ui::stamp()` prefixes
/// every item when `timestamps` is on (the default).
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
const PREVIEW_LINES: usize = 10;

/// A reasoning block that is streaming in.
struct ThinkBlock {
    text: String,
    started: Instant,
    /// `stamp()` from when the block started.
    stamp: String,
}

#[derive(Default)]
struct State {
    thinking: Option<ThinkBlock>,
    streamed_text: bool,
    streamed_thinking: bool,
    /// The cursor is at the start of a line.
    at_line_start: bool,
    in_turn: bool,
    /// Width of the current streamed answer's stamp, so continuation lines
    /// can be indented to align under it.
    stream_pad: usize,
    /// Output held back until the streamed line it would interrupt ends, in
    /// submission order. Notes are stamped and dimmed; raw payloads (e.g.
    /// `/trajectory --json`) go out verbatim — no stamp, no DIM — so the
    /// export stays byte-exact. One ordered queue keeps a raw export queued
    /// between two notes from leapfrogging them at `end_turn`.
    deferred: Vec<Deferred>,
}

/// A held-back line of output: a dimmed note, or a verbatim raw payload.
enum Deferred {
    Note(String),
    Raw(String),
}

pub struct Renderer {
    state: Mutex<State>,
    /// The context stats shown on the frame's status bar (none off a tty).
    status: Option<Arc<StatusLine>>,
    /// Set when the turn's live answer stream may have been left incomplete by
    /// a mid-turn verbosity change. Only `quiet` suppresses streamed deltas, so
    /// a turn that is `quiet` for part of a streamed answer but ends at another
    /// level loses the suppressed deltas. The frame renderer reconciles the
    /// final `AssistantMessage` in place regardless; plain output, which
    /// streams straight to the terminal and can't retract, uses this flag to
    /// reprint the authoritative full response at turn end. Reset at
    /// `begin_turn`, then raised the moment a non-empty answer delta is
    /// actually suppressed while quiet.
    touched_quiet: AtomicBool,
    /// Set when an assistant message has closed since the last answer delta, so
    /// the next non-empty answer delta begins a *new* message segment. The
    /// turn-end reprint (gated on [`Self::answer_may_be_truncated`]) reprints
    /// only `outcome.response` — the turn's *final* assistant message — so the
    /// truncation guard must reflect whether that final answer's live stream is
    /// incomplete, not whether any earlier (already-finalized, never-reprinted)
    /// message was suppressed while quiet. On each new answer segment the guard
    /// is cleared, so a quiet intermediate/tool-call response followed by a
    /// normally-streamed final answer no longer spuriously reprints it. Reset
    /// at `begin_turn`.
    answer_segment_closed: AtomicBool,
    /// The app-owned frame renderer, whenever stdout is a terminal: all output
    /// is composed into one frame (transcript, editor, status as the last
    /// line) and diff-rendered by a single writer. `None` off a terminal
    /// (piped/headless runs), where output is printed as plain lines.
    frame: Mutex<Option<FrameState>>,
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
    /// its width — drift mid-line, so it is refreshed only at a turn boundary.
    prompt_stamp: String,
    /// The running turn's working clock; `None` while the prompt waits for the
    /// user. Drives the busy spinner in place of the `›` prompt glyph, and
    /// pauses while the turn is blocked waiting for a picker (see [`Clock`]).
    busy: Option<Clock>,
    /// A transient hint shown on the status bar (e.g. "(Ctrl-C again to
    /// exit)") instead of as a transcript item. Transient notes are
    /// cursor-relevant feedback: as a transcript item they would trigger a
    /// full-screen clear and land above the editor row, so the user — watching
    /// the cursor — would never see them. Rendered in place of the stats, it
    /// persists across ordinary status refreshes (which only re-render it) and
    /// is cleared explicitly by `clear_transient`, `begin_turn`, or `end_turn`.
    transient: Option<String>,
    /// While set, `frame_event` updates the transcript WITHOUT rendering after
    /// each event: a history replay emits one event per conversation/tool
    /// entry, and rendering each one redoes the whole transcript layout
    /// (O(events²) work and a terminal write per event on a long session).
    /// The caller renders once when the batch is complete.
    batch: bool,
    /// Monotonic counter bumped on EVERY transcript mutation (`push`, `extend`,
    /// `clear`, and the in-place streamed edits to the last item). Keys
    /// `transcript_cache` so a stale wrapped-lines entry is never reused after
    /// the items changed — a length-only key would miss an in-place edit that
    /// keeps the item count (e.g. a `TextDelta` growing the streamed message).
    transcript_version: u64,
    /// Cache of the wrapped transcript lines: the `transcript_version` and wrap
    /// width the lines were built at, plus the lines. The 100 ms spinner `tick`
    /// re-renders the frame without touching the transcript, and the frame
    /// renderer already diffs composed lines (rewriting only from the first
    /// changed row), so re-wrapping every item on each tick would make an idle
    /// model/tool wait cost O(transcript) ten times a second for no visible
    /// change. A width change also re-wraps (the key includes the width).
    transcript_cache: Option<(u64, usize, Vec<String>)>,
}

impl FrameState {
    /// Record a transcript mutation: bump the version so the next
    /// `frame_render` re-wraps rather than reusing now-stale cached lines.
    /// Call after ANY change to `items` — a push/extend/clear AND the in-place
    /// streamed edits to the last item (which keep the item count, so a
    /// length-keyed cache would miss them).
    fn touch_transcript(&mut self) {
        self.transcript_version += 1;
    }
}

impl Renderer {
    /// A fresh frame transcript state: an empty transcript, a new prompt stamp,
    /// and a frame renderer bound to stdout.
    fn fresh_frame() -> FrameState {
        FrameState {
            out: FrameRenderer::new(io::stdout()),
            items: Vec::new(),
            editor: (String::new(), 0),
            queued: 0,
            menu: Vec::new(),
            stream: None,
            think: None,
            think_streamed: false,
            prompt_stamp: stamp(),
            busy: None,
            transient: None,
            batch: false,
            transcript_version: 0,
            transcript_cache: None,
        }
    }

    pub fn new(status: Option<Arc<StatusLine>>) -> Arc<Self> {
        let frame = Mutex::new(io::stdout().is_terminal().then(Self::fresh_frame));
        Arc::new(Self {
            state: Mutex::new(State { at_line_start: true, ..Default::default() }),
            status,
            touched_quiet: AtomicBool::new(false),
            answer_segment_closed: AtomicBool::new(false),
            frame,
        })
    }

    /// Whether the app-owned frame renderer is active.
    pub fn is_frame(&self) -> bool {
        self.frame.lock().unwrap().is_some()
    }

    /// Update the editor row (called by the line editor's frame hook) and
    /// re-render the frame. `queued` is the number of messages waiting behind
    /// the current turn, shown as an indicator under the editor; `menu` is the
    /// command type-ahead, drawn under the editor.
    pub fn set_editor(&self, line: &str, cursor: usize, queued: usize, menu: &[String]) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.editor = (line.to_string(), cursor);
            fs.queued = queued;
            fs.menu = menu.to_vec();
            self.frame_render(fs);
        }
    }

    /// Re-render after a resize (or after a foreground picker clobbered the
    /// screen): force a full redraw at the current size.
    pub fn frame_resize(&self) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.out.invalidate();
            self.frame_render(fs);
        }
    }

    /// Compose the transcript, editor and status bar into one frame and render
    /// it at the current terminal size.
    fn frame_render(&self, fs: &mut FrameState) {
        let (rows, cols) = status::terminal_size().unwrap_or((24, 80));
        let width = (cols as usize).max(1);
        let height = (rows as usize).max(1);
        // Re-wrap the transcript only when it actually changed (see the
        // `transcript_cache` field docs): a spinner tick during a quiet
        // model/tool wait would otherwise redo O(transcript) layout work ten
        // times a second for a frame the line differ then finds unchanged
        // above the editor row.
        let transcript = match &fs.transcript_cache {
            Some((version, w, lines)) if *version == fs.transcript_version && *w == width => lines.clone(),
            _ => {
                let lines = frame::transcript_lines(&fs.items, width);
                fs.transcript_cache = Some((fs.transcript_version, width, lines.clone()));
                lines
            }
        };
        // One `now` for the whole frame, so the glyph and the hint cannot
        // disagree about the elapsed second around a boundary.
        let now = Instant::now();
        // Prefix the editor prompt with the timestamp when timestamps are on,
        // as plain output's prompt line is.
        // Use the stamp captured at prompt start (not `stamp()`), so it stays
        // fixed while the user types rather than ticking every render.
        let prompt = format!("{}{} ", fs.prompt_stamp, prompt_glyph(fs.busy.as_ref().map(|c| (c, now))));
        let mut editor = frame::editor_lines(&prompt, &fs.editor.0, fs.editor.1, width);
        // An empty editor says whose turn it is, after the cursor.
        if fs.editor.0.is_empty() {
            let hint = prompt_hint(fs.busy.as_ref().map(|c| (c, now)));
            editor[0] = frame::fit_line(&format!("{} {DIM}{hint}{RESET}", editor[0]), width);
        }
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
                fs.touch_transcript();
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
                            fs.touch_transcript();
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
                            fs.touch_transcript();
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
                        fs.touch_transcript();
                    }
                }
                match fs.stream {
                    Some(i) => {
                        if let Some(StampedItem { item: Item::Message { text: existing, .. }, .. }) =
                            fs.items.get_mut(i)
                        {
                            existing.push_str(text);
                            fs.touch_transcript();
                        }
                    }
                    None => {
                        fs.items.push(stamped(Item::Message { role: Role::Assistant, text: (*text).to_string() }));
                        fs.touch_transcript();
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
                            fs.touch_transcript();
                        }
                    }
                    Some(_) => {}
                    None if !text.is_empty() => {
                        fs.items.push(stamped(Item::Message { role: Role::Assistant, text: (*text).to_string() }));
                        fs.touch_transcript();
                    }
                    None => {}
                }
                self.frame_finish_stream(fs);
            }
            AgentEvent::Plan { plan } => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::Plan((*plan).clone())));
                fs.touch_transcript();
            }
            // Mirror plain output's user-facing filtering: plan_add /
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
                fs.touch_transcript();
            }
            AgentEvent::ToolCall { call }
                if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose =>
            {
                self.frame_finish_stream(fs);
                // Derive the status from the parsed outcome so an invalid
                // `report_outcome` is not rendered as a success. Record it as
                // an `OutcomeMark` rather than a renderer-only `Note` to mark
                // it conversation-derived (it comes from the tool call).

                let mark = match crate::goal::Status::from_args(&call.arguments) {
                    Some(crate::goal::Status::Blocked) => "■ blocked".to_string(),
                    Some(crate::goal::Status::NeedsInput) => "? needs input".to_string(),
                    Some(crate::goal::Status::Completed) => "✔ completed".to_string(),
                    None => {
                        // This marker is a single status row, so a model-supplied
                        // `\n` (e.g. `{"status":"oops\nINJECT"}`) would inject an
                        // unprefixed extra row; use the single-line sanitizer.
                        let raw = crate::sanitize_terminal_line(
                            call.arguments.get("status").and_then(serde_json::Value::as_str).unwrap_or_default(),
                        );
                        if raw.is_empty() { "• unknown".to_string() } else { format!("• {raw}") }
                    }
                };
                fs.items.push(stamped(Item::OutcomeMark(mark)));
                fs.touch_transcript();
            }
            AgentEvent::ToolResult { call, ok: true, .. }
                if call.name == crate::goal::TOOL_NAME && verbosity() < Verbosity::Verbose => {}
            AgentEvent::ToolCall { call } => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::ToolCall { name: call.name.clone(), summary: tool_summary_text(call) }));
                fs.touch_transcript();
            }
            AgentEvent::ToolResult { ok, output, .. } => {
                fs.items.push(stamped(Item::ToolResult {
                    ok: *ok,
                    output: (*output).to_string(),
                    verbose: verbosity() >= Verbosity::Verbose,
                }));
                fs.touch_transcript();
            }
            AgentEvent::Compacted => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::Note("⟳ context compacted".to_string())));
                fs.touch_transcript();
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
                fs.touch_transcript();
            }
            // A mid-turn timer firing is a note, not a user turn. Sanitize the
            // model-controlled note: it can carry control/escape bytes that a
            // terminal would otherwise interpret (issue #150).
            AgentEvent::TimerFired { id, note } => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::Note(format!(
                    "⏰ timer {}: {}",
                    id,
                    crate::sanitize_terminal_line(note)
                ))));
                fs.touch_transcript();
            }
            // The mid-turn `/model <spec>` note is printed when the command is
            // typed; the event exists so the sink records the recents MRU.
            AgentEvent::ModelSwitched { .. } | AgentEvent::Context => {}
            // A mid-turn `/model <spec>` that could not be applied: surface the
            // error in the transcript so the failed switch is never silent.
            AgentEvent::ModelSwitchFailed { spec, error } => {
                self.frame_finish_stream(fs);
                fs.items.push(stamped(Item::Note(format!("⚠ model switch to {spec} failed: {error}"))));
                fs.touch_transcript();
            }
        }
        // Batched (a history replay): the caller renders once at the end —
        // rendering here would redo the whole transcript layout per event.
        if !fs.batch {
            self.frame_render(fs);
        }
    }

    /// Batch a run of frame events (a history replay) into ONE render: set the
    /// batch flag, run `feed` (which emits the events), then clear the flag and
    /// render the completed frame a single time. Without this each replayed
    /// event triggers a full transcript layout, so resuming a session does
    /// O(events²) work and one terminal write per event.
    /// With plain output it just runs `feed`.
    pub fn frame_batch(&self, feed: impl FnOnce()) {
        let mut frame = self.frame.lock().unwrap();
        let Some(fs) = frame.as_mut() else {
            drop(frame);
            feed();
            return;
        };
        fs.batch = true;
        drop(frame);
        feed();
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.batch = false;
            self.frame_render(fs);
        }
    }

    /// Record a submitted user message in the transcript (frame mode).
    pub fn frame_user_message(&self, text: &str) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Message { role: Role::User, text: text.to_string() }));
            fs.touch_transcript();
            self.frame_render(fs);
        }
    }

    /// Emit command / informational output (e.g. slash-command replies). In
    /// frame mode it is captured as a transcript item so direct writes can't
    /// corrupt the owned frame; otherwise it prints inline as before.
    /// Output of a command run while a turn is streaming. The frame renderer
    /// adds it to the transcript as usual; plain output prints it as a
    /// note, which waits for a half-streamed line to end rather than landing
    /// in the middle of it (`print_block` there is a bare `println!`).
    pub fn turn_block(&self, text: &str) {
        if self.is_frame() {
            self.print_block(text);
        } else {
            self.note(text);
        }
    }

    /// Raw output of a command run while a turn is streaming (e.g.
    /// `/trajectory --json`). The frame renderer emits it verbatim via
    /// `print_raw`. Plain output must not route it through `note` —
    /// that would prepend a timestamp and wrap it in DIM/reset escapes,
    /// corrupting JSON and Markdown — but it also can't print it straight away
    /// without landing in the middle of a half-streamed line. So it is held
    /// back (like a deferred note) and emitted verbatim once the streamed line
    /// ends at `end_turn`, keeping the payload byte-exact.
    pub fn turn_raw(&self, text: &str) {
        if self.is_frame() {
            self.print_raw(text);
            return;
        }
        let mut state = self.state.lock().unwrap();
        // Defer whenever the cursor is not at a line boundary, regardless of
        // whether that line is answer text or reasoning: a `thinking_delta`
        // leaves the cursor mid-line with `streamed_text` false, and printing
        // now would prefix the JSON/Markdown with the partial thinking line.
        if !state.at_line_start {
            state.deferred.push(Deferred::Raw(text.to_string()));
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
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Output(text.to_string())));
            fs.touch_transcript();
            self.frame_render(fs);
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
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            println!("{text}");
            fs.items.push(stamped(Item::Raw(text.to_string())));
            fs.touch_transcript();
            fs.out.invalidate();
            self.frame_render(fs);
            return;
        }
        println!("{text}");
    }

    fn width(&self) -> usize {
        status::terminal_size().map(|(_, cols)| cols as usize).unwrap_or(80).max(20)
    }

    /// Start a fresh session: wipe the frame's transcript (and so the screen
    /// and scrollback), or reset the plain printer's line state.
    pub fn clear_screen(&self) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.clear();
            fs.touch_transcript();
            fs.stream = None;
            fs.think = None;
            fs.out.invalidate();
            self.frame_render(fs);
            return;
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
                let notes: String = state
                    .deferred
                    .drain(..)
                    .map(|d| match d {
                        Deferred::Note(n) => format!("{DIM}{n}{RESET}\n"),
                        Deferred::Raw(r) => format!("{r}\n"),
                    })
                    .collect();
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
        if let Some(fs) = self.frame.lock().unwrap().as_mut() {
            fs.busy = Some(Clock::started(Instant::now()));
            self.frame_render(fs);
        }
        // Reset the truncation guard: it is raised only when a non-empty answer
        // delta is *actually* suppressed while quiet (see the quiet gate in
        // `event`), not merely because the turn starts quiet — a quiet turn
        // whose answer streams normally after a switch to a louder level must
        // not be reprinted.
        self.touched_quiet.store(false, Ordering::Relaxed);
        // The first answer streamed this turn is a fresh segment.
        self.answer_segment_closed.store(false, Ordering::Relaxed);
        let mut state = self.state.lock().unwrap();
        state.in_turn = true;
        state.at_line_start = true;
    }

    /// Set the global verbosity in response to `/verbosity` typed mid-turn.
    /// Applying it immediately keeps the rest of the turn at the new level; the
    /// final-answer reconciliation (frame: in place; plain: a turn-end reprint
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
    /// suppressed). Plain output reprints the full response when this is
    /// true and the turn did not already reprint via its `quiet` end path.
    pub fn answer_may_be_truncated(&self) -> bool {
        self.touched_quiet.load(Ordering::Relaxed)
    }

    /// Redraw the frame while a turn runs, so the busy spinner and elapsed
    /// time move even when no output arrives (a long tool call or a model
    /// still reading the prompt). A no-op at the prompt and with plain output.
    pub fn tick(&self) {
        if let Some(fs) = self.frame.lock().unwrap().as_mut()
            && fs.busy.is_some()
        {
            self.frame_render(fs);
        }
    }

    /// Stop counting working time: the turn is now blocked waiting for a
    /// picker (the `question` tool, the turn cap), and the time it takes the
    /// user to answer is not the agent working. The turn still owns the
    /// prompt — the spinner and `working 12s` stay on screen, held at their
    /// last drawn values — so this paints nothing: the caller is about to
    /// hand the terminal to another writer (`dialoguer`), which must stay
    /// the only one. A no-op at the prompt and with plain output.
    pub fn pause_work(&self) {
        let Some(mut frame) = self.frame.lock().ok() else { return };
        if let Some(fs) = frame.as_mut()
            && let Some(busy) = fs.busy.as_mut()
        {
            busy.pause(Instant::now());
        }
    }

    /// Count working time again after [`Self::pause_work`], when the picker has
    /// returned the terminal. Idempotent, so a resume with no matching pause
    /// leaves a running clock alone.
    pub fn resume_work(&self) {
        let Some(mut frame) = self.frame.lock().ok() else { return };
        if let Some(fs) = frame.as_mut()
            && let Some(busy) = fs.busy.as_mut()
        {
            busy.resume(Instant::now());
        }
    }

    pub fn end_turn(&self) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            self.frame_finish_stream(fs);
            // A fresh prompt starts now the turn is done: restamp it so the next
            // prompt reflects the current time, then holds steady while typing.
            fs.prompt_stamp = stamp();
            // Back to the user: the prompt glyph stops spinning.
            fs.busy = None;
            // The turn is over; any transient hint no longer applies.
            fs.transient = None;
            self.frame_render(fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        self.finish_thinking(&mut state);
        self.newline(&mut state);
        // Everything queued mid-turn goes out in submission order: notes
        // stamped and dimmed, raw exports verbatim (no stamp/DIM), each on its
        // own line, so payloads stay byte-exact without reordering.
        for item in std::mem::take(&mut state.deferred) {
            match item {
                Deferred::Note(note) => self.out(&mut state, &format!("{DIM}{note}{RESET}\n")),
                Deferred::Raw(raw) => {
                    self.out(&mut state, &raw);
                    self.out(&mut state, "\n");
                }
            }
        }
        state.in_turn = false;
        state.streamed_text = false;
        state.streamed_thinking = false;
    }

    /// Print a short note on its own line (e.g. a queued steer). If an
    /// answer is streaming mid-line, the note waits for the line to end.
    pub fn note(&self, text: &str) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Note(text.to_string())));
            fs.touch_transcript();
            self.frame_render(fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        if state.streamed_text && !state.at_line_start {
            state.deferred.push(Deferred::Note(format!("{}{DIM}{text}", stamp())));
            return;
        }
        self.note_now(&mut state, text);
    }

    /// Print a note on its own line straight away.
    pub fn urgent_note(&self, text: &str) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Note(text.to_string())));
            fs.touch_transcript();
            self.frame_render(fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        self.note_now(&mut state, text);
    }

    /// Clear any transient status-bar hint (frame mode only; a no-op with plain
    /// output, where transients are ordinary printed lines).
    pub fn clear_transient(&self) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut()
            && fs.transient.take().is_some()
        {
            self.frame_render(fs);
        }
    }

    /// Show a short transient hint where the user is looking, without adding
    /// it to the transcript. In frame mode it takes over the status bar (a
    /// transcript `Item::Note` would trigger a full-screen clear and land above
    /// the editor row, so the user watching the cursor never sees it); with
    /// plain output it prints inline like `note`. Use for cursor-relevant
    /// feedback such as "(Ctrl-C again to exit)".
    pub fn transient_note(&self, text: &str) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.transient = Some(text.to_string());
            self.frame_render(fs);
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
        let mut guard = self.frame.lock().unwrap();
        if let Some(fs) = guard.as_mut() {
            // Hold the test verbosity lock across the quiet check and the event
            // application so the pair is atomic against a concurrent test that
            // changes the global level: without it a test that sets quiet
            // (e.g. the truncation-guard test) can flip the level between this
            // read and `frame_event`, making an unlocked renderer test drop its
            // events and fail nondeterministically. Production never mutates
            // verbosity on the event path, so the uncontended lock is free.
            #[cfg(test)]
            let _verbosity_guard = tests::verbosity_lock();
            // Quiet mode suppresses live steer/user chatter, but a history
            // replay (`fs.batch`) must keep its recorded user prompts — else
            // switching a quiet session to frame clears scrollback and rebuilds
            // only assistant replies, losing every earlier user message.
            if verbosity() == Verbosity::Quiet
                && !matches!(
                    event,
                    AgentEvent::AssistantMessage { .. }
                        | AgentEvent::Context
                        | AgentEvent::ModelSwitchFailed { .. }
                        // A timer firing is a harness notification, not model
                        // chatter: show it even in quiet mode.
                        | AgentEvent::TimerFired { .. }
                )
                && !(fs.batch && matches!(event, AgentEvent::UserMessage { .. }))
            {
                return;
            }
            self.frame_event(fs, event);
            return;
        }
        if verbosity() == Verbosity::Quiet {
            // A failed mid-turn `/model` switch is user-facing in every
            // verbosity — quiet suppresses streamed output, not warnings.
            if let AgentEvent::ModelSwitchFailed { spec, error } = event {
                let mut state = self.state.lock().unwrap();
                self.newline(&mut state);
                self.out(&mut state, &format!("{}{RED}⚠ model switch to {spec} failed: {error}{RESET}\n", stamp()));
                return;
            }
            // A timer firing mid-turn is a harness notification, not model
            // chatter: show it even in quiet mode (the user asked for the
            // timer). Sanitize the model-controlled note (issue #150).
            if let AgentEvent::TimerFired { id, note } = event {
                let mut state = self.state.lock().unwrap();
                self.note_now(&mut state, &format!("⏰ timer {}: {}", id, crate::sanitize_terminal_line(note)));
                return;
            }
            // Mark the truncation guard only when a non-empty answer delta is
            // actually suppressed here: those deltas never reach the terminal,
            // so if the turn later ends at a louder level the live stream is
            // incomplete and plain output reprints the full response.
            // Merely being quiet (with no delta suppressed yet) must not set
            // this — a turn that switches to a louder level before any delta
            // streams its answer normally, and reprinting would duplicate it.
            match event {
                AgentEvent::TextDelta { text } if !text.is_empty() => {
                    // A new answer segment: clear any truncation signal left by
                    // an earlier, already-finalized message (the turn-end
                    // reprint only reprints the final answer), then flag this
                    // segment's suppression.
                    if self.answer_segment_closed.swap(false, Ordering::Relaxed) {
                        self.touched_quiet.store(false, Ordering::Relaxed);
                    }
                    self.touched_quiet.store(true, Ordering::Relaxed);
                }
                // An assistant message closed while quiet: the next answer
                // delta begins a fresh segment (see `answer_segment_closed`).
                AgentEvent::AssistantMessage { .. } => {
                    self.answer_segment_closed.store(true, Ordering::Relaxed);
                    // Close plain output's open stream. A message can
                    // begin streaming at a louder level and have only its
                    // terminating `AssistantMessage` arrive after a switch to
                    // quiet; this arm then returns without finalizing the open
                    // stream, leaving `streamed_text == true` with no trailing
                    // newline. The next louder segment's `TextDelta` would see
                    // that flag, skip its own stamp/newline, and append to this
                    // message's truncated prefix — merging two assistant
                    // messages on one line — and the new-segment guard reset
                    // means the turn-end reprint can't repair it. Finalizing
                    // the stream here ends the segment cleanly, exactly as the
                    // normal-verbosity `AssistantMessage` arm does.
                    let mut state = self.state.lock().unwrap();
                    self.finish_thinking(&mut state);
                    if state.streamed_text {
                        self.newline(&mut state);
                    }
                    state.streamed_text = false;
                    state.streamed_thinking = false;
                }
                _ => {}
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
                    // A new answer segment is streaming normally: drop any
                    // truncation signal from an earlier, already-finalized
                    // message so only this (potentially final) answer's own
                    // quiet suppression can request a turn-end reprint.
                    if self.answer_segment_closed.swap(false, Ordering::Relaxed) {
                        self.touched_quiet.store(false, Ordering::Relaxed);
                    }
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
                    // This non-streamed message is the full, authoritative
                    // answer and is printed here in its entirety. Drop any
                    // truncation signal left by an earlier suppressed segment
                    // (or by this answer's own quiet-suppressed deltas, which
                    // never set `streamed_text`) so turn-end reconciliation does
                    // not reprint — and thus duplicate — what we just printed.
                    // When the answer instead streamed live (`streamed_text`),
                    // that live stream may be incomplete, so the guard is left
                    // set for the reprint.
                    self.touched_quiet.store(false, Ordering::Relaxed);
                    self.newline(&mut state);
                    self.out(&mut state, &stamp_block(text));
                }
                self.newline(&mut state);
                state.streamed_text = false;
                state.streamed_thinking = false;
                // This message is final; the next answer delta starts a fresh
                // segment (see `answer_segment_closed`).
                self.answer_segment_closed.store(true, Ordering::Relaxed);
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
                    self.tool_result(false, output, verbosity() >= Verbosity::Verbose)
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
                        // sequences into the terminal via this fallback. This is a
                        // single status row, so also drop `\n` (the single-line
                        // sanitizer): an embedded line feed would inject an
                        // unprefixed extra row, not multi-line content to keep.
                        let raw = crate::sanitize_terminal_line(
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
                let text = stamp_block(&self.tool_result(*ok, output, verbosity() >= Verbosity::Verbose));
                self.out(&mut state, &text);
            }
            AgentEvent::Compacted if state.in_turn => {
                self.finish_thinking(&mut state);
                self.newline(&mut state);
                self.out(&mut state, &format!("{}{DIM}⟳ context compacted{RESET}\n", stamp()));
            }
            AgentEvent::UserMessage { .. } | AgentEvent::Context | AgentEvent::Compacted => {}
            // A timer firing mid-turn is a harness notification, not the
            // steer/replay chatter `UserMessage` carries: plain output shows it
            // (the user asked for the timer), including a redirected/headless
            // `--wait-timers` run. Sanitize the model-controlled note so its
            // control/escape bytes never reach the terminal (issue #150).
            AgentEvent::TimerFired { id, note } => {
                self.note_now(&mut state, &format!("⏰ timer {}: {}", id, crate::sanitize_terminal_line(note)));
            }
            // The mid-turn `/model <spec>` note is printed when the command
            // is typed; the event exists so the sink records the recents MRU.
            AgentEvent::ModelSwitched { .. } => {}
            // A mid-turn `/model <spec>` that could not be applied: surface the
            // error inline so the failed switch is never silent.
            AgentEvent::ModelSwitchFailed { spec, error } => {
                self.newline(&mut state);
                self.out(&mut state, &format!("{}{RED}⚠ model switch to {spec} failed: {error}{RESET}\n", stamp()));
            }
        }
    }

    fn tool_result(&self, ok: bool, output: &str, verbose: bool) -> String {
        let width = self.width().saturating_sub(8 + strip_ansi(&stamp()).chars().count());
        // Tool output is model-/tool-controlled (e.g. `timer_list` and
        // `timer_cancel` echo back model-authored notes): strip control and
        // escape bytes so a result preview can never drive the terminal (clear
        // the screen, set the title/clipboard, …). Only the displayed preview is
        // sanitized — the model-facing `output` is handed on untouched (#150).
        let lines: Vec<String> = output.trim_end().lines().map(crate::sanitize_terminal_line).collect();
        let (mark, color) = if ok { ("⎿", DIM) } else { ("⎿ error:", RED) };
        if lines.is_empty() {
            return format!("  {color}{mark} (no output){RESET}\n");
        }
        if verbose {
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
        format!("  {color}{mark} {}{more}{RESET}\n", fit(&lines[0], width.saturating_sub(more.len())))
    }

    /// Accumulate streamed reasoning. Plain output shows only the one-line
    /// summary once the block ends (see [`Self::finish_thinking`]).
    fn thinking_delta(&self, state: &mut State, text: &str) {
        if state.thinking.is_none() {
            self.newline(state);
            state.thinking = Some(ThinkBlock { text: String::new(), started: Instant::now(), stamp: stamp() });
        }
        state.thinking.as_mut().unwrap().text.push_str(text);
    }

    fn finish_thinking(&self, state: &mut State) {
        let Some(block) = state.thinking.take() else { return };
        let seconds = block.started.elapsed().as_secs_f64();
        let line = format!(
            "{}{THINK}∴ Thought for {seconds:.1}s{RESET}{DIM} · {} chars{RESET}\n",
            block.stamp,
            block.text.trim().chars().count()
        );
        self.out(state, &line);
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
        // A plan title is model-controlled (`plan_add` / `plan_update`), so it
        // may embed cursor/erase escapes. This plain `fit` does NOT sanitize
        // (unlike the frame's), so strip them before formatting to keep e.g.
        // `\x1b[2J` from clearing the terminal in plain output.
        // Use the single-line sanitizer: a title is one checklist row, so an
        // embedded `\n` must be dropped too (the frame's `fit` also strips it),
        // else it would spill an unprefixed extra terminal row here.
        let title = fit(&crate::sanitize_terminal_line(&item.title), width);
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
pub(crate) mod tests {
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
    pub(crate) struct VerbosityGuard {
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

    pub(crate) fn verbosity_lock() -> VerbosityGuard {
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
        pub(crate) fn frame_for_test() -> Arc<Self> {
            Arc::new(Self {
                state: Mutex::new(State { at_line_start: true, ..Default::default() }),
                status: None,
                touched_quiet: AtomicBool::new(false),
                answer_segment_closed: AtomicBool::new(false),
                frame: Mutex::new(Some(Self::fresh_frame())),
            })
        }

        /// Whether a frame-mode renderer's working clock is paused by a picker
        /// (`Some(true)`), running (`Some(false)`) or absent because no turn is
        /// up (`None`). Test hook for the picker guard.
        #[cfg(test)]
        pub(crate) fn work_paused_for_test(&self) -> Option<bool> {
            self.frame.lock().unwrap().as_ref().and_then(|fs| fs.busy.map(|clock| clock.since.is_none()))
        }

        /// Build a plain (non-frame, as for piped stdout) renderer for driving
        /// the plain `event` path in tests. The truncation guard is a
        /// plain-output concern: the frame renderer reconciles the final
        /// `AssistantMessage` in place and never consults `touched_quiet`.
        pub(crate) fn plain_for_test() -> Arc<Self> {
            Arc::new(Self {
                state: Mutex::new(State { at_line_start: true, ..Default::default() }),
                status: None,
                touched_quiet: AtomicBool::new(false),
                answer_segment_closed: AtomicBool::new(false),
                frame: Mutex::new(None),
            })
        }

        #[cfg(test)]
        fn frame_items(&self) -> Vec<StampedItem> {
            self.frame.lock().unwrap().as_ref().unwrap().items.clone()
        }

        #[cfg(test)]
        fn frame_transient(&self) -> Option<String> {
            self.frame.lock().unwrap().as_ref().unwrap().transient.clone()
        }

        #[cfg(test)]
        fn frame_batching(&self) -> bool {
            self.frame.lock().unwrap().as_ref().unwrap().batch
        }
    }

    #[test]
    fn frame_batch_defers_rendering_until_the_batch_ends() {
        // A history replay emits one event per conversation entry; rendering
        // each one would redo the whole transcript layout per event. The batch
        // flag holds renders back while events stream in and the closing
        // render draws the completed frame once.
        let r = Renderer::frame_for_test();
        assert!(!r.frame_batching());
        r.frame_batch(|| {
            assert!(r.frame_batching(), "batch flag set while events stream in");
            r.event(&AgentEvent::UserMessage { text: "one" });
            r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "two" });
            r.event(&AgentEvent::UserMessage { text: "three" });
        });
        assert!(!r.frame_batching(), "batch flag cleared at the end");
        let texts: Vec<String> = r
            .frame_items()
            .iter()
            .filter_map(|i| match &i.item {
                Item::Message { text, .. } => Some(text.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(texts, ["one", "two", "three"], "every batched event still landed");
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
    fn clear_transient_drops_a_hint_before_the_turn_ends() {
        // An accepted submission clears a refusal hint mid-turn: it must not
        // wait for `end_turn`.
        let r = Renderer::frame_for_test();
        r.transient_note("Unknown command /exin (/help lists commands)");
        r.clear_transient();
        assert_eq!(r.frame_transient(), None);
        // Clearing with no hint armed is a no-op (no redraw, no panic).
        r.clear_transient();
        assert_eq!(r.frame_transient(), None);
    }

    #[test]
    fn the_prompt_spins_during_a_turn_and_shows_ready_after() {
        let r = Renderer::frame_for_test();
        let busy = |r: &Renderer| r.frame.lock().unwrap().as_ref().unwrap().busy;
        assert_eq!(busy(&r), None);
        r.begin_turn();
        assert!(busy(&r).is_some(), "a turn marks the prompt busy");
        r.tick();
        r.end_turn();
        assert_eq!(busy(&r), None, "the prompt is back to the user");
    }

    #[test]
    fn waiting_for_user_input_does_not_count_as_working_time() {
        // A turn that asks a question: the time between `pause_work` (the
        // picker taking the terminal) and `resume_work` (the answer arriving)
        // is the user's, not the agent's, so it stays out of the count while
        // the turn keeps the prompt.
        let t0 = Instant::now();
        let mut clock = Clock::started(t0);
        assert_eq!(clock.elapsed(t0 + Duration::from_secs(3)), Duration::from_secs(3));
        clock.pause(t0 + Duration::from_secs(3));
        // The user deliberates for a minute; the frozen count does not move.
        assert_eq!(clock.elapsed(t0 + Duration::from_secs(63)), Duration::from_secs(3));
        clock.resume(t0 + Duration::from_secs(63));
        // Working resumes from the banked 3s, not from the wall clock.
        assert_eq!(clock.elapsed(t0 + Duration::from_secs(65)), Duration::from_secs(5));
        clock.pause(t0 + Duration::from_secs(65));
        // The visible text is the working time too, not wall time.
        assert_eq!(elapsed_text(clock.elapsed(t0 + Duration::from_secs(300))), "5s");
    }

    #[test]
    fn pausing_and_resuming_the_work_clock_is_idempotent() {
        // Overlapping pickers must not bank the same span twice, and a resume
        // with no pause must not restart a running clock.
        let t0 = Instant::now();
        let mut clock = Clock::started(t0);
        clock.pause(t0 + Duration::from_secs(2));
        clock.pause(t0 + Duration::from_secs(9));
        assert_eq!(clock.banked, Duration::from_secs(2), "a second pause must not bank the same span twice");
        clock.resume(t0 + Duration::from_secs(9));
        clock.resume(t0 + Duration::from_secs(30));
        assert_eq!(clock.since, Some(t0 + Duration::from_secs(9)), "a second resume must not restart the clock");
        assert_eq!(clock.elapsed(t0 + Duration::from_secs(31)), Duration::from_secs(24));
    }

    #[test]
    fn a_paused_work_clock_freezes_the_prompt_and_resumes() {
        let r = Renderer::frame_for_test();
        r.begin_turn();
        let elapsed = |r: &Renderer| {
            let frame = r.frame.lock().unwrap();
            frame.as_ref().unwrap().busy.unwrap().elapsed(Instant::now())
        };
        // A pause stops the count: the frozen value stays exactly what was
        // banked at the pause, however long the picker keeps the terminal, and
        // the prompt keeps its spinner (the turn is still up). Compare against
        // the value captured right after pausing rather than a wall-clock
        // bound: `begin_turn` renders before the pause, so a slow or preempted
        // CI worker can legitimately bank more than any fixed threshold.
        r.pause_work();
        let frozen = elapsed(&r);
        std::thread::sleep(Duration::from_millis(15));
        assert_eq!(elapsed(&r), frozen, "a paused clock banks no wait");
        assert!(r.frame.lock().unwrap().as_ref().unwrap().busy.is_some(), "the prompt still shows the working turn");
        r.resume_work();
        std::thread::sleep(Duration::from_millis(15));
        assert!(elapsed(&r) > frozen, "resuming counts working time again");
    }

    #[test]
    fn a_spinner_tick_reuses_the_wrapped_transcript() {
        // The 100 ms spinner tick only animates the prompt glyph/elapsed hint,
        // so it must not re-wrap the whole transcript on every frame: the
        // wrapped lines are cached and reused while the items are unchanged.
        // A re-wrap would still produce the SAME lines for unchanged items, so
        // this asserts on the cache entry the tick consults: a hit keeps the
        // exact entry (version key and lines), proving the tick took the cache
        // path rather than re-wrapping.
        let cache = |r: &Renderer| r.frame.lock().unwrap().as_ref().unwrap().transcript_cache.clone();
        let r = Renderer::frame_for_test();
        r.event(&AgentEvent::UserMessage { text: "hello" });
        r.begin_turn();
        let cached = cache(&r).expect("a render populates the transcript cache");
        r.tick();
        let after = cache(&r).expect("the cache survives a tick");
        assert_eq!(cached, after, "a tick with an unchanged transcript reuses the cached entry");
    }

    #[test]
    fn the_transcript_cache_invalidates_when_items_change() {
        let cache = |r: &Renderer| r.frame.lock().unwrap().as_ref().unwrap().transcript_cache.clone();
        let r = Renderer::frame_for_test();
        r.begin_turn();
        // Streamed deltas grow the LAST item in place, keeping the item count;
        // the version key must still invalidate, or a tick would redraw a stale
        // transcript.
        r.event(&AgentEvent::TextDelta { text: "one" });
        let first = cache(&r).expect("a render populates the transcript cache");
        r.event(&AgentEvent::TextDelta { text: " two" });
        let second = cache(&r).unwrap();
        assert_ne!(first.0, second.0, "an in-place streamed edit bumps the transcript version");
        assert_ne!(first.2, second.2, "an in-place edit re-wraps the transcript");
        // Appending an item also bumps the version and re-wraps.
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "one two" });
        let third = cache(&r).unwrap();
        r.end_turn();
        r.event(&AgentEvent::UserMessage { text: "next" });
        let fourth = cache(&r).unwrap();
        assert_ne!(third.0, fourth.0, "appending an item bumps the transcript version");
        assert_ne!(third.2, fourth.2, "appending an item re-wraps the transcript");
    }

    #[test]
    fn prompt_glyph_and_hint_say_whose_turn_it_is() {
        assert_eq!(visible_width_text(&prompt_glyph(None)), "›");
        assert!(prompt_hint(None).starts_with("ready"));
        // The spinner frame follows the WORKING time, so a paused clock holds
        // its frame instead of spinning on while the user reads the question.
        let now = Instant::now();
        let clock = Clock::started(now - SPINNER_INTERVAL * 3);
        assert_eq!(visible_width_text(&prompt_glyph(Some((&clock, now)))), SPINNER[3].to_string());
        let mut paused = Clock::started(now - Duration::from_secs(65));
        paused.pause(now);
        assert_eq!(visible_width_text(&prompt_glyph(Some((&paused, now)))), SPINNER[0].to_string());
        assert!(
            prompt_hint(Some((&paused, now))).starts_with("working 1m 05s · Enter steers"),
            "{}",
            prompt_hint(Some((&paused, now)))
        );
        assert_eq!(elapsed_text(Duration::from_secs(4)), "4s");
    }

    /// `text` without its ANSI colour codes.
    fn visible_width_text(text: &str) -> String {
        let mut out = String::new();
        let mut chars = text.chars();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for c in chars.by_ref() {
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
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
        let r = Renderer::plain_for_test();

        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        // No delta suppressed yet — only the quiet start. Switching to normal
        // before any answer delta means the answer streams normally.
        set_verbosity(Verbosity::Normal);
        assert!(!r.answer_may_be_truncated(), "a quiet start with no suppressed delta must not flag truncation");

        // A fresh turn that genuinely suppresses a non-empty delta while quiet
        // IS flagged (plain output then reprints the full response).
        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "hello" });
        assert!(r.answer_may_be_truncated(), "a suppressed non-empty delta must flag truncation");
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn plain_tool_result_strips_terminal_escapes() {
        // A model/tool-controlled result (e.g. a `timer_list`/`timer_cancel`
        // note) rendered through the plain `ToolResult` branch must not carry
        // live escape/control bytes to the terminal, while keeping its text
        // (#150). Verbose shows every line; the one-line form shows the first.
        let _lock = verbosity_lock();
        let r = Renderer::plain_for_test();
        let hostile = "note \x1b]0;pwned\x07\nsecond \x1b[2J line";
        for verbose in [true, false] {
            let content = strip_ansi(&r.tool_result(true, hostile, verbose));
            assert!(!content.contains('\x1b'), "ESC survived (verbose={verbose}): {content:?}");
            assert!(!content.contains('\x07'), "BEL survived (verbose={verbose}): {content:?}");
            assert!(content.contains("note"), "visible text dropped (verbose={verbose}): {content:?}");
        }
    }

    #[test]
    fn entering_quiet_alone_does_not_flag_truncation() {
        // `/verbosity quiet` then `/verbosity normal` before any answer delta
        // arrives must not flag truncation: nothing was suppressed, so the
        // answer streams in full and reprinting it would duplicate it. Only a
        // genuinely suppressed non-empty delta raises the guard.
        let _lock = verbosity_lock();
        let r = Renderer::plain_for_test();
        set_verbosity(Verbosity::Normal);
        r.begin_turn();
        r.set_verbosity_mid_turn(Verbosity::Quiet);
        r.set_verbosity_mid_turn(Verbosity::Normal);
        assert!(!r.answer_may_be_truncated(), "entering quiet with no suppressed delta must not flag truncation");
    }

    #[test]
    fn truncation_guard_resets_per_answer_segment() {
        // A multi-message turn: an intermediate/tool-call response is suppressed
        // while quiet, then the user switches to normal and the FINAL answer
        // streams in full. The turn-end reprint only reprints the final answer,
        // so the guard must be clear — otherwise the fully-streamed final answer
        // is duplicated. The guard tracks the final segment, not any earlier one.
        let _lock = verbosity_lock();
        let r = Renderer::plain_for_test();

        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        // Intermediate response suppressed while quiet, then it closes.
        r.event(&AgentEvent::TextDelta { text: "intermediate" });
        assert!(r.answer_may_be_truncated(), "the suppressed intermediate delta flags truncation");
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "intermediate" });

        // Switch to normal; the final answer streams in full.
        set_verbosity(Verbosity::Normal);
        r.event(&AgentEvent::TextDelta { text: "final answer" });
        assert!(
            !r.answer_may_be_truncated(),
            "a final answer streamed normally after an earlier quiet segment must not be reprinted"
        );
        r.event(&AgentEvent::AssistantMessage { message_id: "m2", text: "final answer" });
        assert!(!r.answer_may_be_truncated(), "the final segment was never suppressed");

        // But if the FINAL answer itself is quiet-prefixed before switching
        // louder, its live stream IS incomplete and must be reprinted.
        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "A" }); // suppressed intermediate
        r.event(&AgentEvent::AssistantMessage { message_id: "m3", text: "A" });
        set_verbosity(Verbosity::Quiet);
        r.event(&AgentEvent::TextDelta { text: "final prefix" }); // final answer starts quiet
        set_verbosity(Verbosity::Normal);
        r.event(&AgentEvent::TextDelta { text: " suffix" });
        assert!(
            r.answer_may_be_truncated(),
            "a final answer whose own prefix was suppressed while quiet must be reprinted"
        );
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn non_streamed_final_message_clears_an_earlier_suppressed_segments_guard() {
        // `report_outcome` synthesizes the final answer and emits only an
        // `AssistantMessage` (no preceding `TextDelta`). If an earlier tool-loop
        // response was suppressed while quiet, that non-streamed final message is
        // printed in full by the louder `AssistantMessage` arm — so the stale
        // guard from the earlier segment must be cleared, or turn-end
        // reconciliation reprints (duplicates) the just-printed answer.
        let _lock = verbosity_lock();
        let r = Renderer::plain_for_test();

        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        // Earlier tool-loop response suppressed while quiet, then it closes.
        r.event(&AgentEvent::TextDelta { text: "intermediate" });
        assert!(r.answer_may_be_truncated(), "the suppressed intermediate delta flags truncation");
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "intermediate" });

        // Switch louder; the final answer arrives as a non-streamed message.
        set_verbosity(Verbosity::Normal);
        r.event(&AgentEvent::AssistantMessage { message_id: "m2", text: "final answer" });
        assert!(!r.answer_may_be_truncated(), "a non-streamed final message printed in full must not be reprinted");
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn fully_quiet_final_answer_closed_by_a_louder_message_is_not_reprinted() {
        // The whole final answer streams while quiet (every delta suppressed, so
        // `streamed_text` stays false), then the user switches louder and the
        // terminating `AssistantMessage` arrives. The louder arm prints the full
        // text in place, so the guard must be cleared — reprinting would
        // duplicate the answer just printed.
        let _lock = verbosity_lock();
        let r = Renderer::plain_for_test();

        set_verbosity(Verbosity::Quiet);
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "final answer" }); // suppressed while quiet
        assert!(r.answer_may_be_truncated(), "the suppressed final delta flags truncation");
        set_verbosity(Verbosity::Normal);
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "final answer" });
        assert!(
            !r.answer_may_be_truncated(),
            "a non-streamed message that printed the full answer must not be reprinted"
        );
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn quiet_assistant_message_closes_the_plain_stream() {
        // A message streams at normal, then verbosity switches to quiet before
        // its terminating `AssistantMessage` arrives. The quiet gate must close
        // plain output's open stream (reset `streamed_text`, end the
        // line) so a later normal `TextDelta` begins a fresh segment instead of
        // appending to this message's prefix and merging two messages.
        let _lock = verbosity_lock();
        let r = Renderer::plain_for_test();

        set_verbosity(Verbosity::Normal);
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "first" });
        assert!(r.state.lock().unwrap().streamed_text, "the first message is streaming");

        // Switch to quiet; the message's closing `AssistantMessage` arrives here.
        set_verbosity(Verbosity::Quiet);
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "first" });
        {
            let state = r.state.lock().unwrap();
            assert!(!state.streamed_text, "the closed segment must reset the plain stream");
            assert!(state.at_line_start, "the closed segment must end the line");
        }

        // Back to normal: the next message must start a fresh, un-merged stream.
        set_verbosity(Verbosity::Normal);
        r.event(&AgentEvent::TextDelta { text: "second" });
        assert!(
            r.state.lock().unwrap().streamed_text,
            "a new message after a quiet-closed segment streams on its own line"
        );
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn turn_raw_defers_while_answer_text_is_mid_line() {
        let _lock = verbosity_lock();
        set_verbosity(Verbosity::Normal);
        let r = Renderer::plain_for_test();
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "partial answer" });
        r.turn_raw("{\"k\":1}");
        assert!(
            matches!(
                r.state.lock().unwrap().deferred.as_slice(),
                [Deferred::Raw(payload)] if payload == "{\"k\":1}"
            ),
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
        let r = Renderer::plain_for_test();
        r.begin_turn();
        assert!(r.state.lock().unwrap().at_line_start);
        r.turn_raw("{\"k\":1}");
        assert!(r.state.lock().unwrap().deferred.is_empty(), "a raw export at a line boundary must not be deferred");
        set_verbosity(Verbosity::Normal);
    }

    #[test]
    fn deferred_notes_and_raw_exports_keep_submission_order() {
        // A raw export queued between two notes must not leapfrog them at
        // end_turn: one ordered queue drains note, raw, note.
        let _lock = verbosity_lock();
        set_verbosity(Verbosity::Normal);
        let r = Renderer::plain_for_test();
        r.begin_turn();
        r.event(&AgentEvent::TextDelta { text: "partial answer" });
        r.note("first");
        r.turn_raw("{\"k\":1}");
        r.note("second");
        let deferred = std::mem::take(&mut r.state.lock().unwrap().deferred);
        let kinds: Vec<&str> = deferred
            .iter()
            .map(|d| match d {
                Deferred::Note(_) => "note",
                Deferred::Raw(_) => "raw",
            })
            .collect();
        assert_eq!(kinds, ["note", "raw", "note"], "deferred output keeps submission order");
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
    fn frame_quiet_preserves_a_model_switch_failure() {
        // A failed mid-turn `/model` switch is user-facing in every verbosity.
        // In frame mode the quiet gate returns before `frame_event` for all but
        // a few events; `ModelSwitchFailed` must be exempt so the warning still
        // lands in the transcript instead of being silently dropped — exactly
        // the mode where plain output explicitly preserves it.
        let _lock = verbosity_lock();
        set_verbosity(Verbosity::Quiet);
        let r = Renderer::frame_for_test();
        r.event(&AgentEvent::ModelSwitchFailed { spec: "broken/x", error: "no base_url" });
        set_verbosity(Verbosity::Normal);
        let note = r
            .frame_items()
            .iter()
            .filter(|i| matches!(&i.item, Item::Note(t) if t.contains("broken/x") && t.contains("no base_url")))
            .count();
        assert_eq!(note, 1, "the switch failure must survive the frame quiet gate: {:?}", r.frame_items());
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

    #[test]
    fn plan_checklist_sanitizes_model_controlled_titles() {
        // A plan title comes from a model's `plan_add` / `plan_update`, so the
        // plain checklist
        // must strip cursor/erase escapes before printing — otherwise a title
        // like `\x1b[2J` would clear the terminal.
        let plan = Plan {
            goal: String::new(),
            items: vec![PlanItem {
                id: 1,
                title: "\x1b[2Jwipe\x1b[H".to_string(),
                status: Status::Pending,
                notes: Vec::new(),
                after: Vec::new(),
            }],
        };
        let rendered = plan_checklist(&plan, 80);
        assert!(!rendered.contains("\x1b[2J"), "erase escape leaked: {rendered:?}");
        assert!(!rendered.contains("\x1b[H"), "cursor escape leaked: {rendered:?}");
        assert!(rendered.contains("wipe"), "title text dropped: {rendered:?}");
    }
}
