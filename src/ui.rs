//! Interactive output: verbosity levels and a renderer that turns agent
//! events into streamed text, collapsible thinking and inline tool calls.

use std::io::{self, IsTerminal, Write};
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
    /// The dropped frame's full transcript, in original on-screen order,
    /// captured by `set_mode(Legacy)` for `replay_transcript` to reprint after
    /// the post-switch screen+scrollback clear. Replaying THIS — not the
    /// (possibly compacted) conversation — keeps frame-only items, turns and
    /// plan updates in their shown order and restores the real pre-compaction
    /// turns instead of the synthetic summary. Byte-exact `Raw` exports ride
    /// along in order; they are printed after the clear, so they survive it.
    transcript: Vec<crate::frame::StampedItem>,
}

pub struct Renderer {
    state: Mutex<State>,
    status: Option<Arc<StatusLine>>,
    /// Stdout is a terminal (in-place redraws are possible).
    tty: bool,
    expanded: AtomicBool,
    /// The app-owned frame renderer, when `renderer = "frame"` and stdout is a
    /// terminal. When set, all output is composed into one frame (transcript,
    /// editor, status as the last line) and diff-rendered by a single writer,
    /// instead of streaming into the terminal's scrollback. Wrapped in a
    /// `Mutex<Option<..>>` (rather than `Option<Mutex<..>>`) so the frame can
    /// be enabled or dropped at runtime — a live `renderer` switch in
    /// `/settings` — behind the shared `Arc<Renderer>`; the `Mutex` supplies
    /// the interior mutability, so the field itself stays shared-borrowed.
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
    /// While set, `frame_event` updates the transcript WITHOUT rendering after
    /// each event: a history replay emits one event per conversation/tool
    /// entry, and rendering each one redoes the whole transcript layout
    /// (O(events²) work and a terminal write per event on a long session).
    /// The caller renders once when the batch is complete.
    batch: bool,
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
            transient: None,
            batch: false,
        }
    }

    pub fn new(status: Option<Arc<StatusLine>>, mode: crate::frame::RendererMode) -> Arc<Self> {
        let tty = io::stdout().is_terminal();
        let frame =
            Mutex::new(if mode == crate::frame::RendererMode::Frame && tty { Some(Self::fresh_frame()) } else { None });
        Arc::new(Self {
            state: Mutex::new(State { at_line_start: true, ..Default::default() }),
            status,
            tty,
            expanded: AtomicBool::new(false),
            frame,
        })
    }

    /// Whether the app-owned frame renderer is active.
    pub fn is_frame(&self) -> bool {
        self.frame.lock().unwrap().is_some()
    }

    /// Turn the app-owned frame renderer on or off at runtime (a live
    /// `renderer` switch in `/settings`). On a tty the frame is created or
    /// dropped in place; off a tty it is always off. The transcript and
    /// in-flight stream state are preserved across the switch, and the
    /// caller is expected to re-render (a resize / replay) afterwards.
    ///
    /// Switching OFF captures the WHOLE frame transcript (`fs.items`, in
    /// on-screen order) so `replay_transcript` can reprint it once legacy owns
    /// the screen again. The frame holds the visible history exactly as shown
    /// — frame-only output (the startup banner, `/help` or `/tools` text,
    /// renderer notes) lives ONLY in `FrameState.items`, and frame redraws have
    /// already cleared the old scrollback, so dropping the frame would lose it.
    /// Conversation items (messages, tool calls/results, the plan) and the
    /// conversation-derived `report_outcome` markers (`Item::OutcomeMark`) are
    /// captured and replayed too: the caller does NOT re-derive the visible
    /// history from `Agent::conversation` on this path, so nothing is printed
    /// twice and nothing is dropped. Replaying the captured transcript — rather
    /// than the conversation — is what keeps the switch lossless: it restores
    /// the real pre-compaction turns (compaction only appends a note; it never
    /// rewrites `fs.items`) where the compacted conversation would print the
    /// synthetic summary as a user turn and lose the compacted-away turns, and
    /// the current plan prints exactly once (it is simply the last
    /// `Item::Plan`). `Item::Raw` holds verbatim machine-readable output
    /// (`/trajectory --json`); it is replayed byte-exact (never routed through
    /// the deferred-note queue, which would trim trailing newlines and add DIM
    /// styling, corrupting the export). Nothing prints here: the caller clears
    /// the screen+scrollback AFTER `set_mode` returns, so `replay_transcript`
    /// does the printing.
    pub fn set_mode(&self, mode: crate::frame::RendererMode) {
        let on = mode == crate::frame::RendererMode::Frame && self.tty;
        let mut frame = self.frame.lock().unwrap();
        if on {
            if frame.is_none() {
                *frame = Some(Self::fresh_frame());
            }
        } else if let Some(fs) = frame.take() {
            // Capture the WHOLE transcript in on-screen order. The frame holds
            // the visible history exactly as shown — including the real
            // pre-compaction turns (compaction only appends a note; it never
            // rewrites `fs.items`) — so replaying it restores what the user
            // saw, in order, where re-deriving from `Agent::conversation`
            // would print the synthetic summary as a user turn and lose the
            // compacted-away turns. Nothing prints here: the caller clears the
            // screen+scrollback AFTER `set_mode` returns, so `replay_transcript`
            // does the printing.
            self.state.lock().unwrap().transcript = fs.items;
        }
    }

    /// Reprint the dropped frame's transcript, in original on-screen order,
    /// now that legacy owns the screen again. The caller runs this AFTER the
    /// post-switch screen+scrollback clear (`repin_scroll_region` /
    /// `clear_display`), so everything printed here survives the transition.
    ///
    /// Replaying the captured transcript — rather than re-deriving the visible
    /// history from `Agent::conversation` — is what keeps a frame → legacy
    /// switch lossless:
    /// * ORDER: frame-only items (`/help`, banner, notes), turns and plan
    ///   updates are reprinted where they were shown, not grouped ahead of or
    ///   behind the conversation (the old `flush_pending` /
    ///   `replay_plan_snapshots` split reordered them).
    /// * COMPACTION: the frame kept the real pre-compaction turns, so they are
    ///   restored instead of the synthetic summary the compacted conversation
    ///   would print as a user turn — and the summary is never exposed.
    /// * The CURRENT plan is simply the last `Item::Plan` in the transcript,
    ///   so it prints exactly once with no special-casing.
    ///
    /// No-op in frame mode or when nothing was captured. Goes through `out()`
    /// so a partial streamed line is ended first.
    pub fn replay_transcript(&self) {
        let mut state = self.state.lock().unwrap();
        if self.frame.lock().unwrap().is_some() || state.transcript.is_empty() {
            return;
        }
        // Replay even in quiet mode. Leaving the frame clears the screen AND
        // scrollback, and in quiet mode the frame only ever recorded what it
        // displayed — final assistant replies and `print_raw` exports (both
        // printed regardless of verbosity). Dropping the transcript here would
        // erase those already-visible lines; replaying restores exactly them.
        let items = std::mem::take(&mut state.transcript);
        for si in &items {
            self.replay_item(&mut state, si);
        }
    }

    /// Print one captured transcript item through the legacy path, mirroring
    /// what [`Self::event`] emits for the equivalent live event so the
    /// transition looks seamless. `si.stamp` is reused (not a fresh `stamp()`)
    /// so each line keeps the timestamp it was originally shown with.
    ///
    /// The frame layout strips cursor/erase escapes from model/tool text before
    /// displaying it, so the captured fields are still RAW — replaying them
    /// straight into legacy `out()` would emit those controls now (a tool
    /// result holding `\x1b[2J` is safe in the frame yet clears the terminal
    /// here). Run every model/tool-controlled field through
    /// [`crate::sanitize_terminal_text`] first — the same filter live output
    /// applies — leaving the intentional styling (colours, bold) and the
    /// byte-exact `Raw` export untouched.
    fn replay_item(&self, state: &mut State, si: &crate::frame::StampedItem) {
        use crate::frame::Item;
        let stamp = &si.stamp;
        match &si.item {
            Item::Message { role, text } => {
                let text = crate::sanitize_terminal_text(text);
                let text = text.trim_end();
                if text.trim().is_empty() {
                    return;
                }
                self.newline(state);
                match role {
                    crate::frame::Role::User => self.out(state, &format!("{stamp}> {text}\n")),
                    crate::frame::Role::Assistant => self.out(state, &stamp_block_with(stamp, &format!("{text}\n"))),
                }
            }
            Item::Thinking { chars, seconds } => {
                self.newline(state);
                self.out(state, &format!("{stamp}{DIM}∴ Thought for {seconds:.1}s · {chars} chars{RESET}\n"));
            }
            Item::ToolCall { name, summary } => {
                self.newline(state);
                // Name and summary share one status row, so a `\n` would inject
                // an unprefixed extra line (the frame layout drops it); use the
                // single-line sanitizer to match what live output shows.
                let name = crate::sanitize_terminal_line(name);
                let summary = crate::sanitize_terminal_line(summary);
                // Fit the summary to the row's remaining width: the frame
                // truncated it to one row (and live legacy output fits it too),
                // so replaying the raw captured value would wrap across rows and
                // the frame → legacy replay would not preserve the transcript.
                let used = strip_ansi(stamp).chars().count() + name.chars().count() + 4;
                let summary = fit(&summary, self.width().saturating_sub(used));
                self.out(state, &format!("{stamp}{GREEN}●{RESET} {BOLD}{name}{RESET} {DIM}{summary}{RESET}\n"));
            }
            Item::ToolResult { ok, output, verbose } => {
                self.newline(state);
                let output = crate::sanitize_terminal_text(output);
                // Format from the verbosity captured WITH the result, not the
                // current global: if the user changed verbosity and renderer in
                // the same settings visit, replaying with today's verbosity would
                // show more (or fewer) lines than the frame ever did, so the
                // captured transcript would not be lossless.
                let text = stamp_block_with(stamp, &self.tool_result(*ok, &output, *verbose));
                self.out(state, &text);
            }
            Item::Plan(plan) => {
                self.newline(state);
                let width = self.width().saturating_sub(4 + visible_width(stamp));
                let text = plan_checklist(plan, width);
                self.out(state, &stamp_block_with(stamp, &text));
            }
            Item::Note(text) | Item::OutcomeMark(text) => {
                self.newline(state);
                let text = crate::sanitize_terminal_text(text);
                self.out(state, &format!("{stamp}{DIM}{}{RESET}\n", text.trim_end()));
            }
            Item::Output(text) => {
                self.newline(state);
                let text = crate::sanitize_terminal_text(text);
                self.out(state, &format!("{}\n", text.trim_end()));
            }
            // Byte-exact, unstyled, untrimmed, UNSANITIZED: the export must
            // survive intact for whatever pipeline reads it. `print_raw`
            // originally emitted it with `println!`, which ALWAYS appends one
            // newline after the text — so write that suffix newline
            // unconditionally (`newline()` would skip it when the raw text
            // already ends in `\n`, dropping the blank line `println!` added).
            Item::Raw(text) => {
                self.newline(state);
                self.out(state, text);
                self.out(state, "\n");
            }
        }
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
                if fs.stream.is_none() && !text.is_empty() {
                    fs.items.push(stamped(Item::Message { role: Role::Assistant, text: (*text).to_string() }));
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
                // `report_outcome` is not rendered as a success. Record it as
                // an `OutcomeMark` rather than a renderer-only `Note` to mark
                // it conversation-derived (it comes from the tool call). Both
                // are captured in `fs.items` and, on a frame → legacy switch,
                // replayed directly and in place exactly once, so the choice is
                // semantic — the marker is neither dropped nor reprinted.
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
        // Batched (a history replay): the caller renders once at the end —
        // rendering here would redo the whole transcript layout per event.
        if !fs.batch {
            self.frame_render(fs);
        }
    }

    /// Batch a run of frame events (a history replay) into ONE render: set the
    /// batch flag, run `feed` (which emits the events), then clear the flag and
    /// render the completed frame a single time. Without this each replayed
    /// event triggers a full transcript layout, so switching to frame mode (or
    /// resuming into it) does O(events²) work and one terminal write per event.
    /// No-op in legacy mode: `feed` then emits nothing frame-bound.
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

    /// Hand legacy-mode output that exists only in renderer state (not yet in
    /// scrollback) to the frame transcript, so the frame's first full redraw —
    /// which clears scrollback — cannot erase it: notes deferred behind an
    /// in-progress streamed line, and the collapsed reasoning Ctrl-O would
    /// reprint. Returns the drained items; the caller pushes them into the
    /// frame before replaying history so they land ahead of the conversation.
    /// Empty in frame mode (everything is already in the transcript).
    pub fn drain_pending(&self) -> Vec<Item> {
        if self.frame.lock().unwrap().is_some() {
            return Vec::new();
        }
        let mut state = self.state.lock().unwrap();
        let mut items: Vec<Item> = std::mem::take(&mut state.deferred).into_iter().map(Item::Note).collect();
        let thinking = std::mem::take(&mut state.last_thinking);
        if !thinking.trim().is_empty() {
            items.push(Item::Thinking { chars: thinking.trim().chars().count(), seconds: 0.0 });
        }
        items
    }

    /// Record a submitted user message in the transcript (frame mode).
    pub fn frame_user_message(&self, text: &str) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Message { role: Role::User, text: text.to_string() }));
            self.frame_render(fs);
        }
    }

    /// Append drained legacy output (see `drain_pending`) to the frame
    /// transcript without rendering: called just before a batched history
    /// replay, whose closing render draws these items too. No-op in legacy
    /// mode (no frame to hold them).
    pub fn push_items(&self, items: Vec<Item>) {
        if items.is_empty() {
            return;
        }
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.extend(items.into_iter().map(stamped));
        }
    }

    /// Emit command / informational output (e.g. slash-command replies). In
    /// frame mode it is captured as a transcript item so direct writes can't
    /// corrupt the owned frame; otherwise it prints inline as before.
    pub fn print_block(&self, text: &str) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Output(text.to_string())));
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
    pub fn print_raw(&self, text: &str) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            self.frame_finish_stream(fs);
            println!("{text}");
            fs.items.push(stamped(Item::Raw(text.to_string())));
            fs.out.invalidate();
            self.frame_render(fs);
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
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.clear();
            fs.stream = None;
            fs.think = None;
            fs.out.invalidate();
            self.frame_render(fs);
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
        let mut state = self.state.lock().unwrap();
        state.in_turn = true;
        state.at_line_start = true;
    }

    pub fn end_turn(&self) {
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            self.frame_finish_stream(fs);
            // A fresh prompt starts now the turn is done: restamp it (matching
            // the legacy editor, which restamps on submission) so the next
            // prompt reflects the current time, then holds steady while typing.
            fs.prompt_stamp = stamp();
            // The turn is over; any transient hint no longer applies.
            fs.transient = None;
            self.frame_render(fs);
            // `begin_turn` sets the legacy `in_turn` flag even in frame mode;
            // clear it here too, or switching back to legacy leaves Ctrl-O at
            // the prompt behaving as though a turn is still active.
            let mut state = self.state.lock().unwrap();
            state.in_turn = false;
            state.streamed_text = false;
            state.streamed_thinking = false;
            return;
        }
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
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Note(text.to_string())));
            self.frame_render(fs);
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
        let mut frame = self.frame.lock().unwrap();
        if let Some(fs) = frame.as_mut() {
            fs.items.push(stamped(Item::Note(text.to_string())));
            self.frame_render(fs);
            return;
        }
        let mut state = self.state.lock().unwrap();
        self.note_now(&mut state, text);
    }

    /// Clear any transient status-bar hint (frame mode only; a no-op in legacy
    /// mode, where transients are ordinary printed lines).
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
    /// the editor row, so the user watching the cursor never sees it); in
    /// legacy mode it prints inline like `note`. Use for cursor-relevant
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
            // Quiet mode suppresses live steer/user chatter, but a history
            // replay (`fs.batch`) must keep its recorded user prompts — else
            // switching a quiet session to frame clears scrollback and rebuilds
            // only assistant replies, losing every earlier user message.
            if verbosity() == Verbosity::Quiet
                && !matches!(event, AgentEvent::AssistantMessage { .. } | AgentEvent::Context)
                && !(fs.batch && matches!(event, AgentEvent::UserMessage { .. }))
            {
                return;
            }
            self.frame_event(fs, event);
            return;
        }
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
        }
    }

    fn tool_result(&self, ok: bool, output: &str, verbose: bool) -> String {
        let width = self.width().saturating_sub(8 + strip_ansi(&stamp()).chars().count());
        let lines: Vec<&str> = output.trim_end().lines().collect();
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
        if self.frame.lock().unwrap().is_some() {
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
        // A plan title is model-controlled (`plan_add` / `plan_update`), so it
        // may embed cursor/erase escapes. This legacy `fit` does NOT sanitize
        // (unlike the frame's), so strip them before formatting to keep e.g.
        // `\x1b[2J` from clearing the terminal on replay or live legacy output.
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
mod tests {
    use super::*;
    use serde_json::json;

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
                frame: Mutex::new(Some(Self::fresh_frame())),
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

        #[cfg(test)]
        fn pending_transcript(&self) -> Vec<StampedItem> {
            self.state.lock().unwrap().transcript.clone()
        }

        #[cfg(test)]
        fn in_turn(&self) -> bool {
            self.state.lock().unwrap().in_turn
        }
    }

    #[test]
    fn leaving_frame_mode_captures_the_full_transcript_in_order() {
        // The whole frame transcript — frame-only output AND conversation
        // turns — is captured in on-screen order for `replay_transcript`.
        // Replaying this (not the conversation) is what keeps the switch
        // lossless: nothing is grouped ahead of or behind the turns.
        let r = Renderer::frame_for_test();
        r.print_block("nano-coder v0.0.0\nType /help for commands");
        r.note("a renderer note");
        r.event(&AgentEvent::UserMessage { text: "hi" });
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "hello" });
        r.set_mode(crate::frame::RendererMode::Legacy);
        assert!(r.frame.lock().unwrap().is_none(), "frame dropped");
        let binding = r.pending_transcript();
        let items: Vec<&Item> = binding.iter().map(|si| &si.item).collect();
        // Banner + note + user turn + assistant turn, in the order shown.
        assert!(
            matches!(
                items.as_slice(),
                [
                    Item::Output(_),
                    Item::Note(_),
                    Item::Message { role: Role::User, .. },
                    Item::Message { role: Role::Assistant, .. }
                ]
            ),
            "full transcript captured in order: {items:?}"
        );
        assert!(items.iter().any(|i| matches!(i, Item::Output(t) if t.contains("nano-coder v0.0.0"))), "banner kept");
        assert!(items.iter().any(|i| matches!(i, Item::Note(t) if t.contains("a renderer note"))), "note kept");
        assert!(items.iter().any(|i| matches!(i, Item::Message { text, .. } if text == "hi")), "user turn kept");
        assert!(
            items.iter().any(|i| matches!(i, Item::Message { text, .. } if text == "hello")),
            "assistant turn kept"
        );
    }

    #[test]
    fn replay_transcript_consumes_the_queue_and_is_idempotent() {
        // After a frame → legacy switch the captured transcript must be
        // reprinted during the transition: a fresh session has no history
        // events to trigger `out()`'s deferred flush, and the next prompt is
        // drawn by `EditView`, so the transcript would otherwise stay
        // invisible until the first turn's output. The replay empties the
        // queue; a second call (or the next `out()`) reprints nothing.
        let r = Renderer::frame_for_test();
        r.print_block("nano-coder v0.0.0");
        r.event(&AgentEvent::UserMessage { text: "hi" });
        r.set_mode(crate::frame::RendererMode::Legacy);
        assert!(!r.pending_transcript().is_empty(), "transcript captured");
        r.replay_transcript();
        assert!(r.pending_transcript().is_empty(), "replayed during the transition");
        r.replay_transcript();
        assert!(r.pending_transcript().is_empty(), "idempotent");
    }

    #[test]
    fn leaving_frame_mode_keeps_raw_exports_byte_exact_in_the_transcript() {
        // `Item::Raw` holds verbatim machine-readable output (`/trajectory
        // --json`). It rides along in the captured transcript (byte-exact,
        // never trimmed or DIM-styled like a note) and is printed by
        // `replay_transcript`, which the caller runs after the clear.
        let r = Renderer::frame_for_test();
        r.print_raw("{\"session_id\":\"abc\"}");
        r.set_mode(crate::frame::RendererMode::Legacy);
        let items = r.pending_transcript();
        assert!(
            items.iter().any(|si| matches!(&si.item, Item::Raw(t) if t == "{\"session_id\":\"abc\"}")),
            "raw export kept byte-exact in the transcript: {items:?}"
        );
        assert!(
            !items.iter().any(|si| matches!(&si.item, Item::Note(t) if t.contains("session_id"))),
            "raw output is never restyled as a note: {items:?}"
        );
        r.replay_transcript();
        assert!(r.pending_transcript().is_empty(), "replayed after the clear");
    }

    #[test]
    fn leaving_frame_mode_preserves_plan_snapshots_in_order() {
        // The frame appends an `Item::Plan` per `Plan` event. Capturing the
        // transcript keeps every snapshot in original order, so the earlier
        // checklist states survive a frame → legacy switch alongside the turns
        // they belonged to — and the current plan (the last snapshot) prints
        // exactly once, with no separate trailing reprint to skip.
        let r = Renderer::frame_for_test();
        let first = Plan {
            goal: String::new(),
            items: vec![
                PlanItem { id: 1, title: "one".into(), status: Status::InProgress, notes: vec![], after: vec![] },
                PlanItem { id: 2, title: "two".into(), status: Status::Pending, notes: vec![], after: vec![] },
            ],
        };
        let second = Plan {
            goal: String::new(),
            items: vec![
                PlanItem { id: 1, title: "one".into(), status: Status::Done, notes: vec![], after: vec![] },
                PlanItem { id: 2, title: "two".into(), status: Status::InProgress, notes: vec![], after: vec![] },
            ],
        };
        r.event(&AgentEvent::UserMessage { text: "do it" });
        r.event(&AgentEvent::Plan { plan: &first });
        r.event(&AgentEvent::Plan { plan: &second });
        r.set_mode(crate::frame::RendererMode::Legacy);
        let binding = r.pending_transcript();
        let plans: Vec<&Plan> = binding
            .iter()
            .filter_map(|si| match &si.item {
                Item::Plan(p) => Some(p),
                _ => None,
            })
            .collect();
        assert_eq!(plans, vec![&first, &second], "plan snapshots kept in original order");
    }

    #[test]
    fn leaving_frame_mode_restores_pre_compaction_turns_not_the_summary() {
        // After compaction `Agent::conversation` holds a synthetic user-role
        // summary in place of the folded turns, but the frame still holds the
        // REAL turns (compaction only appends a note; it never rewrites the
        // transcript). Replaying the captured transcript therefore restores
        // the actual displayed history and never exposes the summary.
        let r = Renderer::frame_for_test();
        r.event(&AgentEvent::UserMessage { text: "earlier question" });
        r.event(&AgentEvent::AssistantMessage { message_id: "m1", text: "earlier answer" });
        r.event(&AgentEvent::Compacted);
        r.event(&AgentEvent::UserMessage { text: "later question" });
        r.set_mode(crate::frame::RendererMode::Legacy);
        let items = r.pending_transcript();
        assert!(
            items.iter().any(|si| matches!(&si.item, Item::Message { text, .. } if text == "earlier question")),
            "real pre-compaction user turn preserved: {items:?}"
        );
        assert!(
            items.iter().any(|si| matches!(&si.item, Item::Message { text, .. } if text == "earlier answer")),
            "real pre-compaction assistant turn preserved: {items:?}"
        );
        assert!(
            items.iter().any(|si| matches!(&si.item, Item::Note(t) if t.contains("compacted"))),
            "the compaction marker is shown as a note: {items:?}"
        );
        assert!(
            !items.iter().any(|si| matches!(&si.item, Item::Message { text, .. } if text.starts_with("[Summary of the earlier conversation"))),
            "no synthetic summary is replayed as a user turn: {items:?}"
        );
    }

    #[test]
    fn leaving_frame_mode_preserves_the_outcome_marker() {
        // The `report_outcome` status marker is conversation-derived, but the
        // transcript replay (not `Agent::conversation`) is now the source on a
        // frame → legacy switch, so the frame's `OutcomeMark` must be kept —
        // dropping it would lose the marker entirely.
        let r = Renderer::frame_for_test();
        let call = ToolCall {
            id: "call_1".into(),
            name: crate::goal::TOOL_NAME.into(),
            arguments: json!({"status": "completed", "summary": "done"}),
            ..Default::default()
        };
        r.event(&AgentEvent::ToolCall { call: &call });
        r.set_mode(crate::frame::RendererMode::Legacy);
        let items = r.pending_transcript();
        assert!(
            items.iter().any(|si| matches!(&si.item, Item::OutcomeMark(t) if t.contains("completed"))),
            "the outcome marker is preserved for the transcript replay: {items:?}"
        );
    }

    #[test]
    fn frame_mode_end_turn_clears_the_legacy_turn_flag() {
        // `begin_turn` sets `in_turn` even in frame mode; if the frame branch
        // of `end_turn` did not clear it, switching back to legacy would leave
        // Ctrl-O at the prompt behaving as though a turn were still active.
        let r = Renderer::frame_for_test();
        r.begin_turn();
        assert!(r.in_turn());
        r.end_turn();
        assert!(!r.in_turn(), "frame-mode end_turn must clear the legacy flag");
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
    fn begin_turn_supersedes_a_transient_hint() {
        let r = Renderer::frame_for_test();
        r.transient_note("(Ctrl-C again to exit)");
        r.begin_turn();
        assert_eq!(r.frame_transient(), None);
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
        // legacy checklist (used on frame→legacy replay and live legacy output)
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
