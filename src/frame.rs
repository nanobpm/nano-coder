//! App-owned frame renderer (approach (a) from #46).
//!
//! Instead of writing output into the terminal's scrollback and pinning the
//! status bar with a scroll region, this renderer *owns* the screen: every
//! render turns the current state into a `Vec<String>` of lines at the current
//! width (the transcript, then the input editor, then the status bar as the
//! last line), diffs it against the previous frame and rewrites only what
//! changed. A width change clears the screen and scrollback and redraws every
//! line at the new width — this is what makes history "reflow" while keeping the
//! bar and editor stable, without relying on the terminal's own reflow.
//!
//! The "items → lines at a width" layer ([`Item`], [`render_item`],
//! [`transcript_lines`], [`editor_lines`], [`compose`]) is deliberately
//! independent of the screen mode, so an alternate-screen mode (approach (b))
//! could reuse it later. Only [`FrameRenderer`] knows about escape sequences.

use std::io::Write;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use unicode_width::UnicodeWidthChar;

use crate::plan::{Plan, Status};

/// Which renderer the interactive CLI drives.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RendererMode {
    /// The scroll-region renderer: the terminal owns scrollback and reflow.
    #[default]
    Legacy,
    /// The app-owned frame renderer: nano-coder re-renders on a width change.
    Frame,
}

impl RendererMode {
    pub const ALL: [RendererMode; 2] = [RendererMode::Legacy, RendererMode::Frame];

    pub fn describe(self) -> &'static str {
        match self {
            RendererMode::Legacy => "terminal owns scrollback and reflow (scroll region)",
            RendererMode::Frame => "app re-renders the frame on a width change",
        }
    }
}

impl std::fmt::Display for RendererMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            RendererMode::Legacy => "legacy",
            RendererMode::Frame => "frame",
        })
    }
}

impl std::str::FromStr for RendererMode {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        RendererMode::ALL
            .into_iter()
            .find(|m| m.to_string() == s.trim().to_lowercase())
            .ok_or_else(|| format!("unknown renderer {s:?} (legacy, frame)"))
    }
}

// Synchronized output: the terminal buffers everything between these and paints
// it in one go, so a half-drawn frame is never visible. Terminals that don't
// support the mode ignore it.
const SYNC_START: &str = "\x1b[?2026h";
const SYNC_END: &str = "\x1b[?2026l";

const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const THINK: &str = "\x1b[38;5;245m";
const GREEN: &str = "\x1b[38;5;114m";
const RED: &str = "\x1b[38;5;203m";
const RESET: &str = "\x1b[0m";

/// Result-preview lines shown per tool result (matches the legacy renderer).
const PREVIEW_LINES: usize = 10;

// --- The transcript model: items → lines at a width -----------------------

/// Who produced a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

/// One entry in the transcript. Rendering an item to lines is a pure function
/// of the item and the width, so a width change just re-renders every item.
#[derive(Debug, Clone)]
pub enum Item {
    /// A user or assistant message (plain text, wrapped to width).
    Message { role: Role, text: String },
    /// A finished reasoning block, shown collapsed as a one-line summary.
    Thinking { chars: usize, seconds: f64 },
    /// A tool invocation: the tool name and a one-line argument summary.
    ToolCall { name: String, summary: String },
    /// A tool result: its first line plus a "+N lines" count (or a preview
    /// when `verbose`).
    ToolResult {
        ok: bool,
        output: String,
        verbose: bool,
    },
    /// The current plan checklist.
    Plan(Plan),
    /// A short diagnostic / lifecycle note.
    Note(String),
    /// Verbatim command / informational output (e.g. `/help`, `/context`),
    /// captured into the transcript so it can't corrupt the owned frame.
    Output(String),
}

/// Render one transcript item to lines at `width`.
pub fn render_item(item: &Item, width: usize) -> Vec<String> {
    let width = width.max(1);
    match item {
        Item::Message { role, text } => {
            let prefix = match role {
                Role::User => "› ",
                Role::Assistant => "",
            };
            let body = wrap_block(text, width.saturating_sub(prefix.chars().count()).max(1));
            body.into_iter()
                .enumerate()
                .map(|(i, line)| {
                    if i == 0 && !prefix.is_empty() {
                        format!("{DIM}{prefix}{RESET}{line}")
                    } else {
                        line
                    }
                })
                .collect()
        }
        Item::Thinking { chars, seconds } => {
            vec![fit(
                &format!("{THINK}∴ Thought for {seconds:.1}s{RESET}{DIM} · {chars} chars{RESET}"),
                width,
            )]
        }
        Item::ToolCall { name, summary } => {
            let used = name.chars().count() + 4;
            let summary = fit(summary, width.saturating_sub(used));
            vec![fit(
                &format!("{GREEN}●{RESET} {BOLD}{name}{RESET} {DIM}{summary}{RESET}"),
                width,
            )]
        }
        Item::ToolResult {
            ok,
            output,
            verbose,
        } => tool_result_lines(*ok, output, *verbose, width),
        Item::Plan(plan) => plan_lines(plan, width),
        Item::Note(text) => wrap_block(text, width)
            .into_iter()
            .map(|line| format!("{DIM}{line}{RESET}"))
            .collect(),
        Item::Output(text) => wrap_block(text, width),
    }
}

fn tool_result_lines(ok: bool, output: &str, verbose: bool, width: usize) -> Vec<String> {
    let lines: Vec<&str> = output.trim_end().lines().collect();
    let (mark, color) = if ok {
        ("⎿", DIM)
    } else {
        ("⎿ error:", RED)
    };
    // The prefix is two leading spaces, the marker, and one space; reserve its
    // real width so the longer `⎿ error:` marker can't overflow `width` and
    // wrap onto extra rows. Both result formats below use the same `body`.
    let body = width.saturating_sub(mark.chars().count() + 3).max(1);
    if lines.is_empty() {
        return vec![fit(&format!("  {color}{mark} (no output){RESET}"), width)];
    }
    if verbose {
        let mut out = Vec::new();
        for (i, line) in lines.iter().take(PREVIEW_LINES).enumerate() {
            let lead = if i == 0 { mark } else { " " };
            out.push(format!("  {color}{lead} {}{RESET}", fit(line, body)));
        }
        if lines.len() > PREVIEW_LINES {
            out.push(format!(
                "  {DIM}  … +{} lines{RESET}",
                lines.len() - PREVIEW_LINES
            ));
        }
        return out;
    }
    let more = if lines.len() > 1 {
        format!(" (+{} lines)", lines.len() - 1)
    } else {
        String::new()
    };
    vec![format!(
        "  {color}{mark} {}{more}{RESET}",
        fit(lines[0], body.saturating_sub(more.len()))
    )]
}

/// Plans longer than this show finished items as one summary line.
const PLAN_LINES: usize = 12;

fn plan_lines(plan: &Plan, width: usize) -> Vec<String> {
    let body = width.saturating_sub(4).max(1);
    let (done, total) = plan.progress();
    let mut out = vec![fit(
        &format!("{GREEN}●{RESET} {BOLD}Plan{RESET} {DIM}{done}/{total} done{RESET}"),
        width,
    )];
    let live: Vec<&crate::plan::PlanItem> = plan
        .items
        .iter()
        .filter(|i| i.status != Status::Dropped)
        .collect();
    let collapse = live.len() > PLAN_LINES && done > 0;
    if collapse {
        out.push(fit(&format!("  {GREEN}✔{RESET} {DIM}{done} done{RESET}"), width));
    }
    let visible: Vec<&&crate::plan::PlanItem> = live
        .iter()
        .filter(|i| !(collapse && i.status == Status::Done))
        .collect();
    for (shown, item) in visible.iter().enumerate() {
        if shown == PLAN_LINES {
            out.push(fit(&format!("  {DIM}… +{} more{RESET}", visible.len() - shown), width));
            break;
        }
        let title = fit(&item.title, body);
        let line = match item.status {
            Status::Done => format!("{GREEN}✔{RESET} {DIM}{title}{RESET}"),
            Status::InProgress => format!("{BOLD}◼ {title}{RESET}"),
            Status::Blocked => format!("{RED}! {title}{RESET}"),
            _ => format!("{DIM}☐{RESET} {title}"),
        };
        out.push(format!("  {line}"));
    }
    out
}

/// Every transcript item's lines, in order, at `width`.
pub fn transcript_lines(items: &[Item], width: usize) -> Vec<String> {
    items
        .iter()
        .flat_map(|item| render_item(item, width))
        .collect()
}

/// The input editor as wrapped lines with a reverse-video cursor marker at
/// `cursor` (a character index into `text`). Newlines in `text` become their
/// own wrapped rows.
pub fn editor_lines(prompt: &str, text: &str, cursor: usize, width: usize) -> Vec<String> {
    let width = width.max(1);
    let cursor = cursor.min(text.chars().count());
    // Mark the cursor with a sentinel that survives wrapping, then swap it for a
    // reverse-video block once the lines are laid out. `cell_width` reserves one
    // cell for it so a full row leaves room for the block.
    const MARK: char = CURSOR_MARK;
    let mut marked = String::new();
    for (i, c) in text.chars().enumerate() {
        if i == cursor {
            marked.push(MARK);
        }
        marked.push(c);
    }
    if cursor >= text.chars().count() {
        marked.push(MARK);
    }
    let inner = width.saturating_sub(prompt.chars().count()).max(1);
    let mut lines: Vec<String> = Vec::new();
    for (i, logical) in marked.split('\n').enumerate() {
        let wrapped = if i == 0 {
            wrap_ansi(logical, inner)
        } else {
            wrap_ansi(logical, width)
        };
        for line in wrapped {
            lines.push(line);
        }
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines[0] = format!("{BOLD}{prompt}{RESET}{}", lines[0]);
    lines
        .into_iter()
        .map(|line| line.replace(MARK, "\x1b[7m \x1b[27m"))
        .collect()
}

/// Compose the whole frame: the transcript, then the editor, then the status
/// bar as the **last** line. The bar isn't absolutely positioned and there is
/// no scroll region — it is simply the final line of the frame.
pub fn compose(transcript: &[String], editor: &[String], status: &str) -> Vec<String> {
    let mut frame = Vec::with_capacity(transcript.len() + editor.len() + 1);
    frame.extend(transcript.iter().cloned());
    frame.extend(editor.iter().cloned());
    frame.push(status.to_string());
    frame
}

/// The dim queue indicator row shown under the editor in frame mode, mirroring
/// the legacy status line's `⏸N queued · /queue to edit` hint. Returns `None`
/// when nothing is queued.
pub fn queue_indicator(queued: usize, width: usize) -> Option<String> {
    (queued > 0).then(|| {
        fit(
            &format!("{DIM}⏸{queued} queued · /queue to edit{RESET}"),
            width.max(1),
        )
    })
}

/// The index of the first line that differs between two frames, or `None` when
/// they are identical. A shorter/longer frame differs at its first extra or
/// missing line.
pub fn first_diff(prev: &[String], next: &[String]) -> Option<usize> {
    let common = prev.len().min(next.len());
    for i in 0..common {
        if prev[i] != next[i] {
            return Some(i);
        }
    }
    (prev.len() != next.len()).then_some(common)
}

// --- Width-aware wrapping --------------------------------------------------

/// The zero-width sentinel `editor_lines` injects at the cursor position; it is
/// swapped for a one-cell reverse-video block after wrapping.
const CURSOR_MARK: char = '\u{0}';

/// A single character's terminal-cell width, treating the editor cursor
/// sentinel as one cell. `CURSOR_MARK` is a control character (nominally zero
/// width) but is replaced by a one-cell reverse-video block after layout, so
/// reserving a cell for it here keeps a full editor row from spilling past the
/// frame width and pushing the status bar down.
fn cell_width(c: char) -> usize {
    if c == CURSOR_MARK {
        1
    } else {
        UnicodeWidthChar::width(c).unwrap_or(0)
    }
}

/// Visible width in terminal cells, ignoring ANSI escape sequences. CJK
/// characters and many emoji occupy two columns and combining marks zero, so
/// this uses Unicode cell width rather than a raw scalar-value count.
fn visible_width(text: &str) -> usize {
    let mut count = 0;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for n in chars.by_ref() {
                    if ('@'..='~').contains(&n) {
                        break;
                    }
                }
            }
            continue;
        }
        count += cell_width(c);
    }
    count
}

/// Truncate a (possibly ANSI-coloured) string to `width` terminal cells,
/// appending an ellipsis and a reset when it overflows.
fn fit(text: &str, width: usize) -> String {
    if visible_width(text) <= width {
        return text.to_string();
    }
    let keep = width.saturating_sub(1);
    let mut out = String::new();
    let mut seen = 0;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            out.push(c);
            if chars.peek() == Some(&'[') {
                out.push(chars.next().unwrap());
                while let Some(&n) = chars.peek() {
                    out.push(chars.next().unwrap());
                    if ('@'..='~').contains(&n) {
                        break;
                    }
                }
            }
            continue;
        }
        let w = cell_width(c);
        if seen + w > keep {
            break;
        }
        out.push(c);
        seen += w;
    }
    out.push('…');
    out.push_str(RESET);
    out
}

/// Wrap plain (uncoloured) text to `width`, splitting on whitespace and hard
/// breaking words longer than the width. Existing newlines start new lines.
fn wrap_block(text: &str, width: usize) -> Vec<String> {
    text.split('\n')
        .flat_map(|line| wrap_ansi(line, width))
        .collect()
}

/// Wrap one logical line to `width` visible columns, preserving ANSI escape
/// sequences (they take no columns) and breaking on spaces where possible.
fn wrap_ansi(line: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut vis = 0usize;
    // Byte offset in `cur` just after the most recent space, and the visible
    // width at that point — the preferred break for an overlong word.
    let mut brk: Option<usize> = None;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            cur.push(c);
            if chars.peek() == Some(&'[') {
                cur.push(chars.next().unwrap());
                while let Some(&n) = chars.peek() {
                    cur.push(chars.next().unwrap());
                    if ('@'..='~').contains(&n) {
                        break;
                    }
                }
            }
            continue;
        }
        if c == ' ' {
            if vis >= width {
                // The line is full: end it here and drop the space.
                out.push(cur.trim_end().to_string());
                cur = String::new();
                vis = 0;
                brk = None;
                continue;
            }
            cur.push(' ');
            vis += 1;
            brk = Some(cur.len());
            continue;
        }
        if vis >= width {
            match brk {
                Some(byte) => {
                    let rest = cur.split_off(byte);
                    out.push(std::mem::take(&mut cur).trim_end().to_string());
                    cur = rest.trim_start_matches(' ').to_string();
                    vis = visible_width(&cur);
                }
                None => {
                    out.push(std::mem::take(&mut cur));
                    vis = 0;
                }
            }
            brk = None;
        }
        let w = cell_width(c);
        // A wide (2-cell) glyph that would spill past `width` starts a new row
        // even when the running width has not yet reached `width`.
        if w > 1 && vis + w > width && !cur.is_empty() {
            match brk {
                Some(byte) => {
                    let rest = cur.split_off(byte);
                    out.push(std::mem::take(&mut cur).trim_end().to_string());
                    cur = rest.trim_start_matches(' ').to_string();
                    vis = visible_width(&cur);
                }
                None => {
                    out.push(std::mem::take(&mut cur));
                    vis = 0;
                }
            }
            brk = None;
        }
        cur.push(c);
        vis += w;
    }
    out.push(cur);
    out
}

// --- The single writer -----------------------------------------------------

/// Owns the terminal and renders frames, diffing against the previous one. On a
/// width or height change it clears and redraws every line at the new size;
/// otherwise it rewrites only from the first changed line to the end. Every
/// write is wrapped in synchronized output.
pub struct FrameRenderer<W: Write> {
    out: W,
    prev: Vec<String>,
    width: usize,
    height: usize,
    started: bool,
}

impl<W: Write> FrameRenderer<W> {
    pub fn new(out: W) -> Self {
        Self {
            out,
            prev: Vec::new(),
            width: 0,
            height: 0,
            started: false,
        }
    }

    /// Force the next [`render`](Self::render) to be a full redraw — used after
    /// a foreground picker (dialoguer) has written over the screen.
    pub fn invalidate(&mut self) {
        self.started = false;
    }

    /// Render `frame` (already composed to lines at `width`) at a terminal of
    /// `width` × `height`.
    pub fn render(&mut self, frame: &[String], width: usize, height: usize) -> std::io::Result<()> {
        let width = width.max(1);
        let height = height.max(1);
        if !self.started || width != self.width || height != self.height {
            // First frame, or a width/height change: re-emit every line at the
            // new size. A full redraw always clears scrollback — the frame holds
            // the entire transcript, so anything already in scrollback is a copy
            // of what is about to be written; keeping it would leave a duplicate
            // (stale) frame behind the fresh one.
            self.full_redraw(frame, height)?;
        } else {
            self.differential(frame, height)?;
        }
        self.prev = frame.to_vec();
        self.width = width;
        self.height = height;
        self.started = true;
        Ok(())
    }

    fn full_redraw(&mut self, frame: &[String], height: usize) -> std::io::Result<()> {
        let mut buf = String::from(SYNC_START);
        // Drop any scroll region a prior renderer (e.g. `StatusLine::install`,
        // which pins DECSTBM to rows 1..rows-1) left set: this renderer owns
        // the whole screen, so `CRLF` scrolling must span every row or the
        // bottom status line can be pushed out of place.
        buf.push_str("\x1b[r");
        // Clear the screen AND scrollback: a full redraw re-emits the whole
        // transcript, so any surplus that scrolls off must not sit behind a
        // stale copy of the previous frame.
        buf.push_str("\x1b[H\x1b[2J\x1b[3J");
        // Bottom-anchor: when the frame is shorter than the screen, leave blank
        // rows at the top so the bar lands on the last row; when it is taller,
        // write from the top and let the surplus scroll into scrollback.
        let start_row = if frame.len() < height {
            height - frame.len() + 1
        } else {
            1
        };
        buf.push_str(&format!("\x1b[{start_row};1H"));
        for (i, line) in frame.iter().enumerate() {
            if i > 0 {
                buf.push_str("\r\n");
            }
            buf.push_str(line);
        }
        buf.push_str(SYNC_END);
        self.out.write_all(buf.as_bytes())?;
        self.out.flush()
    }

    fn differential(&mut self, frame: &[String], height: usize) -> std::io::Result<()> {
        let Some(diff) = first_diff(&self.prev, frame) else {
            return Ok(());
        };
        let plen = self.prev.len();
        // The first on-screen line index of the previous frame; anything before
        // it has scrolled into scrollback and can't be rewritten in place.
        let prev_top = plen.saturating_sub(height);
        if plen != frame.len() || diff < prev_top {
            // Line count changed, or the change is already in scrollback: fall
            // back to a full redraw. It clears scrollback so re-emitting the
            // whole transcript can't stack a duplicate copy behind the frame.
            return self.full_redraw(frame, height);
        }
        let row = if plen <= height {
            (height - plen) + diff + 1
        } else {
            diff - prev_top + 1
        };
        let mut buf = String::from(SYNC_START);
        buf.push_str(&format!("\x1b[{row};1H"));
        for (i, line) in frame[diff..].iter().enumerate() {
            if i > 0 {
                buf.push_str("\r\n");
            }
            buf.push_str("\x1b[2K");
            buf.push_str(line);
        }
        buf.push_str(SYNC_END);
        self.out.write_all(buf.as_bytes())?;
        self.out.flush()
    }
}

// --- Resize debounce -------------------------------------------------------

/// Collapses a burst of resize events (a window drag) into a single render at
/// the final size: after the last event, wait for `quiet` of no further events
/// before rendering.
pub struct Debouncer {
    last: Option<Instant>,
    quiet: Duration,
}

impl Debouncer {
    pub fn new(quiet: Duration) -> Self {
        Self { last: None, quiet }
    }

    /// Record that a resize happened at `now`.
    pub fn record(&mut self, now: Instant) {
        self.last = Some(now);
    }

    /// Whether enough quiet time has passed since the last resize to render.
    pub fn ready(&self, now: Instant) -> bool {
        self.last
            .is_none_or(|last| now.duration_since(last) >= self.quiet)
    }

    /// Consume the pending resize once rendered.
    pub fn clear(&mut self) {
        self.last = None;
    }

    /// Whether a resize is waiting to be rendered.
    pub fn pending(&self) -> bool {
        self.last.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::PlanItem;

    fn strip(text: &str) -> String {
        let mut out = String::new();
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                if chars.peek() == Some(&'[') {
                    chars.next();
                    for n in chars.by_ref() {
                        if ('@'..='~').contains(&n) {
                            break;
                        }
                    }
                }
                continue;
            }
            out.push(c);
        }
        out
    }

    #[test]
    fn parses_and_displays_renderer_mode() {
        assert_eq!("frame".parse::<RendererMode>(), Ok(RendererMode::Frame));
        assert_eq!("Legacy".parse::<RendererMode>(), Ok(RendererMode::Legacy));
        assert!("fancy".parse::<RendererMode>().is_err());
        assert_eq!(RendererMode::default(), RendererMode::Legacy);
        assert_eq!(RendererMode::Frame.to_string(), "frame");
    }

    #[test]
    fn wraps_words_at_the_width() {
        assert_eq!(
            wrap_ansi("the quick brown fox", 9),
            vec!["the quick", "brown fox"]
        );
        // A word longer than the width is hard-broken.
        assert_eq!(wrap_ansi("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
        // Every wrapped line stays within the width.
        for line in wrap_ansi("one two three four five six seven", 7) {
            assert!(visible_width(&line) <= 7, "{line:?}");
        }
    }

    #[test]
    fn width_counts_terminal_cells_not_scalars() {
        // CJK glyphs take two cells; combining marks take none.
        assert_eq!(visible_width("你好"), 4);
        assert_eq!(visible_width("e\u{0301}"), 1);
        // Wrapping a run of wide glyphs never overflows the column budget.
        for line in wrap_ansi("你好世界你好世界", 5) {
            assert!(visible_width(&line) <= 5, "{line:?}");
        }
        // `fit` truncates on cells, so a wide-glyph string can't exceed width.
        assert!(visible_width(&fit("你好世界", 5)) <= 5);
    }

    #[test]
    fn cursor_marker_reserves_a_cell_on_a_full_row() {
        // A line exactly filling the inner width with the cursor mid-row: the
        // sentinel is replaced by a one-cell reverse-video block, so the row
        // must be laid out reserving a cell for it and never exceed the width.
        let width = 12;
        let text: String = "abcdefghijklmnopqrstuvwxyz".chars().take(40).collect();
        for cursor in 0..text.chars().count() {
            for line in editor_lines("› ", &text, cursor, width) {
                assert!(
                    visible_width(&line) <= width,
                    "row overflows at cursor {cursor}: {line:?} (w={})",
                    visible_width(&line)
                );
            }
        }
    }

    #[test]
    fn plan_header_is_bounded_to_the_width() {
        let plan = Plan::default();
        // Even at a pathologically narrow width the header row never exceeds it,
        // so native terminal wrapping can't push the editor/status rows down.
        for width in 3..20 {
            for line in plan_lines(&plan, width) {
                assert!(visible_width(&line) <= width, "row overflows at {width}: {line:?}");
            }
        }
    }

    #[test]
    fn queue_indicator_shows_only_when_queued() {
        assert_eq!(queue_indicator(0, 40), None);
        let line = queue_indicator(2, 40).unwrap();
        assert!(strip(&line).contains("⏸2 queued · /queue to edit"), "{line:?}");
        // The indicator is fit to the width like every other frame row.
        assert!(visible_width(&queue_indicator(3, 6).unwrap()) <= 6);
    }

    #[test]
    fn wrapping_preserves_ansi_but_not_its_width() {
        let coloured = format!("{GREEN}hello world again{RESET}");
        let lines = wrap_ansi(&coloured, 11);
        assert_eq!(
            lines.iter().map(|l| strip(l)).collect::<Vec<_>>(),
            vec!["hello world", "again"]
        );
        // The colour codes survived even though they cost no columns.
        assert!(lines[0].contains(GREEN));
    }

    #[test]
    fn composes_transcript_editor_then_status_last() {
        let transcript = vec!["a".to_string(), "b".to_string()];
        let editor = vec!["› hi".to_string()];
        let frame = compose(&transcript, &editor, "STATUS");
        assert_eq!(frame, vec!["a", "b", "› hi", "STATUS"]);
        assert_eq!(
            frame.last().unwrap(),
            "STATUS",
            "the bar must be the last line"
        );
    }

    #[test]
    fn diffs_frames_line_by_line() {
        let a = vec!["one".into(), "two".into(), "three".into()];
        let b = vec!["one".into(), "TWO".into(), "three".into()];
        assert_eq!(first_diff(&a, &b), Some(1));
        assert_eq!(first_diff(&a, &a), None);
        // A grown frame differs at the first extra line.
        let c = vec!["one".into(), "two".into(), "three".into(), "four".into()];
        assert_eq!(first_diff(&a, &c), Some(3));
    }

    #[test]
    fn renders_items_within_the_width() {
        let items = vec![
            Item::Message {
                role: Role::Assistant,
                text: "a fairly long assistant answer that should wrap".into(),
            },
            Item::ToolCall {
                name: "bash".into(),
                summary: "ls -la /some/very/long/path/that/overflows".into(),
            },
            Item::ToolResult {
                ok: true,
                output: "line1\nline2\nline3".into(),
                verbose: false,
            },
            Item::Note("a note that is also rather long and needs wrapping".into()),
        ];
        for line in transcript_lines(&items, 20) {
            assert!(
                visible_width(&line) <= 20,
                "{line:?} ({} cols)",
                visible_width(&line)
            );
        }
        // The single-line tool result summarises the extra lines.
        let result = render_item(
            &Item::ToolResult {
                ok: true,
                output: "a\nb\nc".into(),
                verbose: false,
            },
            40,
        );
        assert_eq!(result.len(), 1);
        assert!(strip(&result[0]).contains("(+2 lines)"));
    }

    #[test]
    fn editor_marks_the_cursor_and_wraps() {
        let lines = editor_lines("› ", "hello", 5, 20);
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("\x1b[7m"), "cursor marker present");
        // A long line wraps under the width.
        let long = editor_lines("› ", &"x".repeat(50), 50, 10);
        assert!(long.len() > 1);
        for line in &long {
            assert!(visible_width(line) <= 10, "{line:?}");
        }
    }

    #[test]
    fn plan_item_wraps_and_marks_status() {
        let plan = Plan {
            goal: String::new(),
            items: vec![
                PlanItem {
                    id: 1,
                    title: "do the first thing".into(),
                    status: Status::Done,
                    notes: vec![],
                    after: vec![],
                },
                PlanItem {
                    id: 2,
                    title: "do the second thing".into(),
                    status: Status::InProgress,
                    notes: vec![],
                    after: vec![],
                },
            ],
        };
        let lines = plan_lines(&plan, 30);
        assert!(strip(&lines[0]).contains("1/2 done"));
        assert!(lines.len() >= 3);
    }

    #[test]
    fn debouncer_waits_for_quiet() {
        let mut d = Debouncer::new(Duration::from_millis(40));
        let t0 = Instant::now();
        d.record(t0);
        assert!(d.pending());
        assert!(!d.ready(t0 + Duration::from_millis(10)));
        assert!(d.ready(t0 + Duration::from_millis(40)));
        d.clear();
        assert!(!d.pending());
        assert!(d.ready(t0));
    }
}

/// Emulator tests: feed the renderer's bytes to a `vt100` terminal, resize it
/// and assert the whole screen — the bar is on the last row, the editor sits
/// directly above it, there are no duplicate bars, and history reflows to the
/// new width.
#[cfg(test)]
mod emulator {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    /// A `Write` that appends to a shared buffer, so a test can drain the bytes
    /// the renderer produced and feed them to the emulator.
    #[derive(Clone)]
    struct Shared(Rc<RefCell<Vec<u8>>>);

    impl Write for Shared {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.borrow_mut().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// A renderer wired to a `vt100` terminal of the given size.
    struct Emu {
        buf: Shared,
        renderer: FrameRenderer<Shared>,
        parser: vt100::Parser,
        rows: u16,
        cols: u16,
    }

    impl Emu {
        fn new(rows: u16, cols: u16) -> Self {
            let buf = Shared(Rc::new(RefCell::new(Vec::new())));
            Self {
                renderer: FrameRenderer::new(buf.clone()),
                parser: vt100::Parser::new(rows, cols, 0),
                buf,
                rows,
                cols,
            }
        }

        /// Resize the emulated terminal (as a real terminal would on a drag).
        fn resize(&mut self, rows: u16, cols: u16) {
            self.rows = rows;
            self.cols = cols;
            self.parser.set_size(rows, cols);
        }

        /// Render a frame and feed the produced bytes to the emulator.
        fn render(&mut self, frame: &[String]) {
            self.renderer
                .render(frame, self.cols as usize, self.rows as usize)
                .unwrap();
            let bytes: Vec<u8> = self.buf.0.borrow_mut().drain(..).collect();
            self.parser.process(&bytes);
        }

        /// The visible screen, one trimmed string per row.
        fn screen(&self) -> Vec<String> {
            self.parser
                .screen()
                .rows(0, self.cols)
                .map(|row| row.trim_end().to_string())
                .collect()
        }
    }

    fn sample_frame(width: usize) -> Vec<String> {
        let transcript = transcript_lines(
            &[
                Item::Message { role: Role::User, text: "please summarise the plan".into() },
                Item::Message {
                    role: Role::Assistant,
                    text: "here is a fairly long answer that is meant to wrap onto more than one row when the terminal is narrow".into(),
                },
            ],
            width,
        );
        let editor = editor_lines("› ", "my next question", 16, width);
        compose(&transcript, &editor, "MODEL  ctx 10% ")
    }

    #[test]
    fn bar_is_the_last_row_with_the_editor_above_and_no_duplicates() {
        let mut emu = Emu::new(24, 80);
        emu.render(&sample_frame(80));
        let screen = emu.screen();
        assert_eq!(
            screen.last().unwrap(),
            "MODEL  ctx 10%",
            "bar on the last row"
        );
        // The editor row sits directly above the bar.
        let editor_row = &screen[screen.len() - 2];
        assert!(
            editor_row.contains("my next question"),
            "editor above the bar: {editor_row:?}"
        );
        // Exactly one bar on screen.
        let bars = screen.iter().filter(|r| r.contains("ctx 10%")).count();
        assert_eq!(bars, 1, "no duplicate bars: {screen:?}");
    }

    #[test]
    fn a_width_change_reflows_history() {
        let mut emu = Emu::new(24, 80);
        emu.render(&sample_frame(80));
        // The long answer fits few rows when wide.
        let wide_answer_rows = emu
            .screen()
            .iter()
            .filter(|r| r.contains("fairly long answer"))
            .count();

        // Shrink: the terminal (and renderer) both go narrow.
        emu.resize(24, 30);
        emu.render(&sample_frame(30));
        let narrow = emu.screen();
        // The bar is still the single last row.
        assert_eq!(narrow.last().unwrap(), "MODEL  ctx 10%");
        assert_eq!(narrow.iter().filter(|r| r.contains("ctx 10%")).count(), 1);
        // Every visible row now fits the new width.
        for row in &narrow {
            assert!(row.chars().count() <= 30, "row wider than 30: {row:?}");
        }
        // History reflowed: the long answer occupies more rows at the smaller
        // width than it did when wide.
        let narrow_answer_rows = narrow
            .iter()
            .filter(|r| r.contains("fairly") || r.contains("answer") || r.contains("wrap"))
            .count();
        assert!(
            narrow_answer_rows > wide_answer_rows,
            "history did not reflow ({wide_answer_rows} -> {narrow_answer_rows})"
        );
    }

    #[test]
    fn a_resize_drag_ends_on_a_stable_correct_frame() {
        let mut emu = Emu::new(24, 80);
        emu.render(&sample_frame(80));
        // 20 resizes in a row, as during a window drag.
        for i in 0..20 {
            let cols = 40 + (i % 40) as u16;
            emu.resize(24, cols);
            emu.render(&sample_frame(cols as usize));
        }
        // Settle at a final size and render the final frame twice: the second
        // render must be a no-op that leaves an identical, correct screen.
        emu.resize(24, 64);
        emu.render(&sample_frame(64));
        let first = emu.screen();
        emu.render(&sample_frame(64));
        let second = emu.screen();
        assert_eq!(first, second, "frame not stable after the drag");
        assert_eq!(second.last().unwrap(), "MODEL  ctx 10%");
        assert_eq!(second.iter().filter(|r| r.contains("ctx 10%")).count(), 1);
        assert!(second[second.len() - 2].contains("my next question"));
    }
}
