//! A status line drawn on the bottom row of the terminal: model, context
//! use, session tokens and what the agent is doing.
//!
//! The status line is drawn by absolute-positioning to the bottom row (save
//! the cursor, jump to the last row, draw, restore), *without* confining the
//! conversation to a DECSTBM scroll region. Holding a scroll region would pin
//! the status line, but Ghostty and iTerm2 deliberately do not reflow text
//! inside a scroll-margin region on resize — so the whole conversation would
//! keep its old line breaks. Leaving the region unset lets those terminals
//! reflow the message history when the window is resized; the status line is
//! simply redrawn at the (new) bottom row whenever output lands there.
//!
//! Because no scroll region pins the bar, the bottom row is instead kept free
//! for it by reserving a row before output lands there (see
//! [`reserve_bottom_row`], and the line editor's `redraw`, which scrolls the
//! prompt block up so a wrapping prompt never reaches the reserved row).

use std::io::{self, IsTerminal, Write};
use std::sync::{Arc, Mutex};

use crate::context::{Activity, ContextStats, SharedStats, format_rate, format_tokens};

pub struct StatusLine {
    stats: SharedStats,
    /// Terminal rows and columns the status line was last drawn for.
    size: Mutex<Option<(u16, u16)>>,
    /// Text being typed during a turn, with the cursor's character index and
    /// the queued-message count, shown instead of the stats. Stored raw and
    /// rendered at draw time so the prefix, cursor, queue indicator and padding
    /// are applied exactly once.
    input: Mutex<Option<(String, usize, usize)>>,
}

pub fn terminal_size() -> Option<(u16, u16)> {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0;
    (ok && size.ws_row > 0 && size.ws_col > 0).then_some((size.ws_row, size.ws_col))
}

fn write_raw(bytes: &str) {
    with_term_lock(|| emit(bytes));
}

/// Write without taking the terminal lock; the caller must hold it.
fn emit(bytes: &str) {
    let mut out = io::stdout().lock();
    let _ = out.write_all(bytes.as_bytes());
    let _ = out.flush();
}

/// A process-wide lock serialising every write to the terminal. Escape
/// sequences are emitted from more than one thread — the renderer and line
/// editor on the main task, the status line from the SIGWINCH handler — and a
/// multi-write logical unit (a streamed fragment and its deferred notes, a
/// status redraw) must not interleave with another thread's sequence, or the
/// cursor-save/restore and cursor-addressing tear and scatter output across
/// the screen. `std::io::Stdout`'s own lock only makes a single `write_all`
/// atomic; this lock spans a whole unit.
static TERM_LOCK: Mutex<()> = Mutex::new(());

/// Run `f` while holding the terminal write lock. Callers that emit escape
/// sequences directly hold it across the whole logical unit. The lock is not
/// reentrant: `f` must not call back into any terminal write helper.
pub fn with_term_lock<R>(f: impl FnOnce() -> R) -> R {
    let _guard = TERM_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    f()
}

/// Bytes that draw `line` on the bottom row of a `rows`-row terminal and put
/// the cursor back where it was. No scroll region is set, so the terminal
/// stays free to reflow the conversation on resize. The cursor is saved and
/// restored around the jump, so output continues uninterrupted.
fn draw_sequence(line: &str, rows: u16) -> String {
    format!("\x1b7\x1b[{rows};1H\x1b[2K{line}\x1b8")
}

/// Bytes that erase a stale status bar left at `old_rows` after a resize, or
/// empty when there is nothing stale to clear. When the terminal grew
/// (`old_rows < new_rows`) the old, absolutely positioned bar sits above the
/// new bottom row and must be cleared before the bar is repainted lower down;
/// when it shrank (or is unchanged) the old row is below the new bottom (or is
/// the same row `draw` will clear anyway) so nothing need be erased. No scroll
/// region is set, so the terminal stays free to reflow the conversation.
fn resize_erase_sequence(old_rows: u16, new_rows: u16) -> String {
    if old_rows < new_rows { format!("\x1b7\x1b[{old_rows};1H\x1b[2K\x1b8") } else { String::new() }
}

/// Bytes that reserve the terminal's bottom row for the status line by keeping
/// whatever is written next one row higher.
///
/// With no DECSTBM scroll region to pin the bar, output and the prompt would
/// otherwise land on the same bottom row the status line owns and paint over
/// it. `\n` opens a blank row at the bottom — it scrolls the conversation up
/// only when the cursor is already on the last row, otherwise it just steps
/// down into an existing blank row — `\x1b[1A` steps the cursor back above that
/// row, and `\r\x1b[2K` clears the row the caller is about to write. Emitting
/// this before the prompt lands the prompt one row up and leaves the bottom row
/// free for the status line, without holding a scroll region (so the terminal
/// stays free to reflow the conversation on resize).
pub fn reserve_bottom_row() -> &'static str {
    "\n\x1b[1A\r\x1b[2K"
}

impl StatusLine {
    /// Draw the status line on the bottom row, when stdin and stdout are a
    /// terminal and `AGENTIC_NO_STATUS` is unset.
    pub fn install(stats: SharedStats) -> Option<Arc<Self>> {
        if !io::stdout().is_terminal() || !io::stdin().is_terminal() || std::env::var_os("AGENTIC_NO_STATUS").is_some() {
            return None;
        }
        let (rows, cols) = terminal_size().filter(|(rows, _)| *rows >= 5)?;
        let status = Arc::new(Self { stats, size: Mutex::new(Some((rows, cols))), input: Mutex::new(None) });
        status.draw();
        Some(status)
    }

    /// The bytes that redraw the status line at the current bottom row, or
    /// `None` when torn down. The caller emits them, so it can fold the redraw
    /// into a larger write it already holds the terminal lock for (the line
    /// editor appends this after a prompt redraw, whose clear-to-end-of-screen
    /// would otherwise wipe the bar). Updates the cached size as a side effect.
    pub(crate) fn draw_seq(&self) -> Option<String> {
        // Target the real current terminal, never a stale cached size, so a
        // draw after a resize lands on the new bottom row. There is no scroll
        // region to re-pin: the status line is just painted at the bottom row
        // and the cursor restored, so the terminal stays free to reflow the
        // conversation above it.
        let (rows, cols) = terminal_size()?;
        // Capture the previously drawn height and update the cache atomically,
        // then fold the stale-bar cleanup into this same sequence. When the
        // terminal grew, the bar last drawn at `old_rows` lingers above the new
        // bottom row and must be erased before repainting lower down. Doing the
        // erase here — the single place the cached size changes — means whichever
        // caller *first* observes the grown terminal does it, whether that is a
        // normal write/event or the SIGWINCH `resize()` handler. That closes the
        // race where a write's `draw_seq()` bumped the cache to the new height
        // before `resize()` ran, leaving `resize()` to see equal heights, skip
        // the cleanup, and strand a duplicate bar.
        let old_rows = {
            let mut size = self.size.lock().unwrap();
            let Some((old_rows, _)) = *size else {
                return None; // torn down
            };
            *size = Some((rows, cols));
            old_rows
        };
        let input = self.input.lock().unwrap().clone();
        let line = match input {
            Some((text, cursor, queued)) => render_input(&text, cursor, queued, cols as usize),
            None => render(&self.stats.lock().unwrap().clone(), cols as usize),
        };
        Some(format!("{}{}", resize_erase_sequence(old_rows, rows), draw_sequence(&line, rows)))
    }

    pub fn draw(&self) {
        if let Some(seq) = self.draw_seq() {
            write_raw(&seq);
        }
    }

    /// Show `text` as a line being typed, with the cursor `cursor` characters
    /// in and `queued` messages waiting (None: back to the stats). The text is
    /// stored raw and rendered at draw time. An empty line with a non-zero
    /// count still shows the queue indicator.
    pub fn set_input(&self, text: Option<(&str, usize)>, queued: usize) {
        *self.input.lock().unwrap() = text.map(|(t, c)| (t.to_string(), c, queued));
        self.draw();
    }

    /// Redraw after the terminal was resized. With no scroll region, the
    /// terminal itself reflows the conversation; `draw` (via `draw_seq`) erases
    /// any stale bar the resize left at the old bottom row before painting at
    /// the new bottom. The cleanup lives in `draw_seq` — not here — so it also
    /// fires when a write or event redraws first, after the terminal grew but
    /// before this handler runs, rather than being lost to that race.
    /// (Terminal-specific reflow of the old row makes the erase best-effort,
    /// per the module note, but it removes the common duplicate-bar case
    /// deterministically.)
    pub fn resize(&self) {
        self.draw();
    }

    /// Clear the screen and scrollback for a fresh session, then redraw.
    pub fn clear(&self) {
        write_raw("\x1b[H\x1b[2J\x1b[3J");
        self.draw();
    }

    /// Clear the status line and give the whole screen back.
    pub fn teardown(&self) {
        let mut size = self.size.lock().unwrap();
        if let Some((rows, _)) = size.take() {
            write_raw(&format!("\x1b7\x1b[{rows};1H\x1b[2K\x1b8"));
        }
    }
}

const BG: &str = "\x1b[0;48;5;236;38;5;250m";
const RESET: &str = "\x1b[0m";

/// One status-line segment: its visible text and optional colour.
struct Segment {
    text: String,
    color: Option<&'static str>,
    /// Lower priority segments are dropped first when the line is too wide.
    priority: u8,
}

/// The queue line with the cursor marked at `cursor` characters in, newlines
/// shown as `⏎` so multi-line input stays on one status row, and a count of the
/// messages already queued. The queue indicator yields its hint on narrow
/// terminals, then goes entirely, so the row never exceeds `cols`.
pub fn render_input(text: &str, cursor: usize, queued: usize, cols: usize) -> String {
    let prefix = " ✎ queue › ";
    let hint_text = "  Enter to queue ";
    // The queue indicator yields its hint on narrow terminals, then goes
    // entirely, so the row never exceeds `cols`.
    let full = (queued > 0).then(|| format!("⏸{queued} queued · /queue to edit"));
    let short = (queued > 0).then(|| format!("⏸{queued}"));
    let fits = |i: &Option<String>| {
        let extra = i.as_deref().map_or(0, |i| i.chars().count() + 3);
        prefix.chars().count() + text.chars().count().min(1) + 1 + hint_text.len() + extra <= cols
    };
    let indicator = match (full, short) {
        (Some(f), Some(_)) if fits(&Some(f.clone())) => Some(f),
        (Some(_), Some(s)) if fits(&Some(s.clone())) => Some(s),
        _ => None,
    };
    let extra = indicator.as_deref().map_or(0, |i| i.chars().count() + 3);
    // The hint is a fixed segment that `saturating_sub` can't shorten, so on a
    // terminal too narrow to hold the prefix, cursor, indicator, and hint drop
    // the hint entirely — otherwise the row would spill past `cols`.
    let hint = if prefix.chars().count() + 1 + hint_text.len() + extra <= cols { hint_text } else { "" };
    // Flatten to one row, marking where the cursor sits.
    let flat: String = text.chars().map(|c| if c == '\n' { '⏎' } else { c }).collect();
    let cursor = cursor.min(flat.chars().count());
    let room = cols.saturating_sub(prefix.chars().count() + hint.len() + extra + 1);
    // Keep the cursor visible: show the window of text around it.
    let start = if flat.chars().count() > room {
        cursor.saturating_sub(room / 2).min(flat.chars().count() - room)
    } else {
        0
    };
    let shown: String = flat.chars().skip(start).take(room).collect();
    let cursor_col = cursor - start;
    let before: String = shown.chars().take(cursor_col).collect();
    let under: String = shown.chars().skip(cursor_col).take(1).collect();
    let after: String = shown.chars().skip(cursor_col + 1).collect();
    let cursor_glyph = if under.is_empty() { "█".to_string() } else { format!("\x1b[7m{under}\x1b[27m") };
    let used = prefix.chars().count() + shown.chars().count() + 1;
    let pad = cols.saturating_sub(used + hint.len() + extra);
    let indicator = indicator
        .map(|i| format!("\x1b[38;5;222m · {i}\x1b[38;5;244m"))
        .unwrap_or_default();
    format!(
        "{BG}\x1b[1;38;5;117m{prefix}\x1b[0;48;5;236;38;5;255m{before}{cursor_glyph}{after}{}\x1b[38;5;244m{hint}{indicator}{RESET}",
        " ".repeat(pad)
    )
}

fn render(stats: &ContextStats, cols: usize) -> String {
    let percent = stats.percent();
    let threshold = stats.auto_compact.map(|t| t * 100.0);
    let bar_color = match threshold {
        Some(t) if percent >= t => "\x1b[38;5;203m",
        _ if percent >= 90.0 => "\x1b[38;5;203m",
        _ if percent >= 60.0 => "\x1b[38;5;221m",
        _ => "\x1b[38;5;114m",
    };
    let filled = ((percent / 10.0).round() as usize).min(10);
    let bar = format!("{}{}", "█".repeat(filled), "░".repeat(10 - filled));
    let approx = if stats.calibrated { "" } else { "~" };
    let model = if stats.model.is_empty() { stats.provider.clone() } else { format!("{}/{}", stats.provider, stats.model) };

    let mut segments = vec![
        Segment { text: format!(" {model} "), color: Some("\x1b[1;38;5;255m"), priority: 9 },
        Segment {
            text: format!(" {} ", stats.cwd),
            color: None,
            priority: 6,
        },
        Segment {
            text: format!(" ctx {approx}{}/{} {percent:.0}% ", format_tokens(stats.tokens), format_tokens(stats.window)),
            color: None,
            priority: 8,
        },
        Segment { text: bar, color: Some(bar_color), priority: 5 },
        Segment { text: format!("  {} msgs ", stats.messages), color: None, priority: 3 },
    ];
    if let Some((done, total)) = stats.plan {
        segments.push(Segment { text: format!(" plan {done}/{total} "), color: None, priority: 4 });
    }
    // The mode is only worth a segment when it is not the default; normal is
    // the expected state and the space is better spent on context stats.
    let mode_segment = match stats.mode {
        crate::mode::AgentMode::Normal => None,
        crate::mode::AgentMode::Plan => Some((" plan ", "\x1b[1;38;5;221m")),
        crate::mode::AgentMode::Auto => Some((" auto ", "\x1b[1;38;5;114m")),
    };
    if let Some((text, color)) = mode_segment {
        segments.push(Segment { text: text.to_string(), color: Some(color), priority: 10 });
    }
    if stats.session_input_tokens + stats.session_output_tokens > 0 {
        segments.push(Segment {
            text: format!(
                " ↑{} ↓{} ",
                format_tokens(stats.session_input_tokens as usize),
                format_tokens(stats.session_output_tokens as usize)
            ),
            color: None,
            priority: 2,
        });
    }
    // AI Credits used (GitHub Copilot), when the provider reports them.
    if let Some(aic) = stats.session_aic {
        segments.push(Segment { text: format!(" {aic:.1} AIC "), color: Some("\x1b[38;5;222m"), priority: 2 });
    }
    // History-tool usage this session (smart compaction), shown once used.
    if stats.history_searches + stats.history_reads > 0 {
        segments.push(Segment {
            text: format!(" hist {}s {}r ", stats.history_searches, stats.history_reads),
            color: None,
            priority: 1,
        });
    }
    let compact = match threshold {
        Some(t) => format!(" auto-compact {t:.0}%"),
        None => " auto-compact off".to_string(),
    };
    let compacted = if stats.compactions > 0 { format!(" ({}×)", stats.compactions) } else { String::new() };
    segments.push(Segment { text: format!("{compact}{compacted} "), color: None, priority: 1 });
    let activity = match &stats.activity {
        Activity::Idle => None,
        Activity::Thinking => Some(("● thinking…".to_string(), "\x1b[38;5;117m")),
        Activity::Tool(name) => Some((format!("▶ {name}"), "\x1b[38;5;180m")),
        Activity::Compacting => Some(("⟳ compacting…".to_string(), "\x1b[38;5;221m")),
    };
    if let Some((text, color)) = activity {
        segments.push(Segment { text: format!(" {text} "), color: Some(color), priority: 7 });
    }
    // Live output rate while the model is generating; lowest priority so it is
    // shed first on narrow terminals, and hidden unless a rate is available.
    if matches!(stats.activity, Activity::Thinking)
        && let Some(rate) = stats.tokens_per_sec
    {
        segments.push(Segment { text: format!(" {} ", format_rate(rate)), color: Some("\x1b[38;5;108m"), priority: 0 });
    }

    let width = |segments: &[Segment]| -> usize {
        segments.iter().map(|s| s.text.chars().count()).sum::<usize>() + segments.len().saturating_sub(1)
    };
    while width(&segments) > cols && segments.len() > 1 {
        let lowest = segments.iter().enumerate().min_by_key(|(_, s)| s.priority).map(|(i, _)| i).unwrap();
        segments.remove(lowest);
    }

    let mut line = String::from(BG);
    let mut used = 0;
    for (i, segment) in segments.iter().enumerate() {
        if i > 0 && used < cols {
            line.push('│');
            used += 1;
        }
        let text: String = segment.text.chars().take(cols.saturating_sub(used)).collect();
        used += text.chars().count();
        match segment.color {
            Some(color) => {
                line.push_str(color);
                line.push_str(&text);
                line.push_str(BG);
            }
            None => line.push_str(&text),
        }
    }
    line.push_str(&" ".repeat(cols.saturating_sub(used)));
    line.push_str(RESET);
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    fn visible(line: &str) -> String {
        regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap().replace_all(line, "").to_string()
    }

    fn stats() -> ContextStats {
        ContextStats {
            provider: "work".into(),
            model: "llama-b".into(),
            tokens: 96_500,
            calibrated: true,
            window: 128_000,
            messages: 42,
            session_input_tokens: 310_000,
            session_output_tokens: 12_400,
            session_aic: None,
            compactions: 1,
            history_searches: 0,
            history_reads: 0,
            auto_compact: Some(0.8),
            activity: Activity::Tool("bash".into()),
            plan: Some((2, 5)),
            cwd: "/tmp/project".into(),
            tokens_per_sec: None,
            mode: crate::mode::AgentMode::Normal,
        }
    }

    #[test]
    fn renders_all_segments_when_wide() {
        let line = visible(&render(&stats(), 140));
        assert_eq!(line.chars().count(), 140);
        for part in ["work/llama-b", "ctx 96.5k/128k 75%", "42 msgs", "↑310k ↓12.4k", "auto-compact 80% (1×)", "▶ bash", "plan 2/5"] {
            assert!(line.contains(part), "{part} missing from {line:?}");
        }
    }

    #[test]
    fn drops_low_priority_segments_when_narrow() {
        let line = visible(&render(&stats(), 50));
        assert_eq!(line.chars().count(), 50);
        assert!(line.contains("work/llama-b"), "{line:?}");
        assert!(line.contains("ctx 96.5k/128k"), "{line:?}");
        assert!(!line.contains("auto-compact"), "{line:?}");
    }

    #[test]
    fn shows_aic_only_when_reported() {
        // No credits by default.
        assert!(!visible(&render(&stats(), 140)).contains("AIC"));
        // Credits appear once the provider reports them.
        let with_aic = ContextStats { session_aic: Some(0.0541), ..stats() };
        let line = visible(&render(&with_aic, 140));
        assert!(line.contains("0.1 AIC"), "{line:?}");
    }

    #[test]
    fn shows_history_usage_only_when_used() {
        // No history segment before the tools are used.
        assert!(!visible(&render(&stats(), 140)).contains("hist "));
        // It appears once a smart-compaction history tool has been called.
        let used = ContextStats { history_searches: 3, history_reads: 1, ..stats() };
        assert!(visible(&render(&used, 200)).contains("hist 3s 1r"), "{used:?}");
    }

    #[test]
    fn marks_uncalibrated_estimates() {
        let line = visible(&render(&ContextStats { calibrated: false, ..stats() }, 140));
        assert!(line.contains("ctx ~96.5k"), "{line:?}");
    }

    #[test]
    fn input_row_shows_the_queue_count() {
        // Typing mid-turn: the row invites queueing and shows what waits.
        let line = visible(&render_input("fix the typo", 12, 2, 100));
        assert!(line.contains("✎ queue › fix the typo"), "{line:?}");
        assert!(line.contains("⏸2 queued · /queue to edit"), "{line:?}");
        assert_eq!(line.chars().count(), 100, "fills the width: {line:?}");

        // Nothing queued: just the line being typed, no indicator.
        let line = visible(&render_input("fix the typo", 12, 0, 100));
        assert!(line.contains("✎ queue › fix the typo"), "{line:?}");
        assert!(!line.contains("queued"), "{line:?}");

        // An empty line with a waiting queue still shows the indicator.
        let line = visible(&render_input("", 0, 1, 100));
        assert!(line.contains("⏸1 queued"), "{line:?}");

        // Narrow terminal: the indicator collapses to the bare count and the
        // line is truncated, but the row still fits.
        let line = visible(&render_input("a very long line being typed here", 33, 3, 40));
        assert_eq!(line.chars().count(), 40, "{line:?}");
        assert!(line.contains("⏸3"), "{line:?}");

        // Very narrow terminal: the hint is dropped so the row never overflows.
        for cols in 20..=30 {
            let line = visible(&render_input("typing here", 11, 0, cols));
            assert!(line.chars().count() <= cols, "row overflows at {cols} cols: {line:?}");
        }
    }

    #[test]
    fn input_row_marks_the_cursor_in_a_multiline_queued_line() {
        // A multi-line message with the cursor in the middle: newlines collapse
        // to `⏎`, the character under the cursor stays visible (reverse video is
        // stripped here), and the queue indicator still shows the count.
        let line = visible(&render_input("first line\nsecond line", 4, 2, 100));
        assert!(line.contains("✎ queue › firs"), "{line:?}");
        assert!(line.contains("⏎"), "newline shown as a glyph: {line:?}");
        assert!(line.contains("⏸2 queued · /queue to edit"), "{line:?}");
        assert!(line.chars().count() <= 100, "never overflows the width: {line:?}");
    }

    #[test]
    fn shows_output_rate_only_while_generating() {
        let generating = ContextStats { activity: Activity::Thinking, tokens_per_sec: Some(2.0), ..stats() };
        assert!(visible(&render(&generating, 160)).contains("2.0 tok/s"), "rate should show while thinking");

        let fast = ContextStats { activity: Activity::Thinking, tokens_per_sec: Some(12.4), ..stats() };
        assert!(visible(&render(&fast, 160)).contains("12 tok/s"), "fast rate rounds to integer");

        // A rate is only shown while thinking, never during a tool call or idle.
        let tooling = ContextStats { tokens_per_sec: Some(2.0), ..stats() };
        assert!(!visible(&render(&tooling, 160)).contains("tok/s"), "rate hidden outside generation");
        let idle = ContextStats { activity: Activity::Idle, tokens_per_sec: None, ..stats() };
        assert!(!visible(&render(&idle, 160)).contains("tok/s"), "rate hidden when idle");
    }

    #[test]
    fn drops_output_rate_first_on_narrow_widths() {
        let generating = ContextStats { activity: Activity::Thinking, tokens_per_sec: Some(2.0), ..stats() };
        // Wide enough to shed the rate but keep the model name.
        let line = visible(&render(&generating, 50));
        assert_eq!(line.chars().count(), 50);
        assert!(line.contains("work/llama-b"), "{line:?}");
        assert!(!line.contains("tok/s"), "rate should be dropped first: {line:?}");
    }

    #[test]
    fn draw_sequence_paints_the_bottom_row_and_restores_the_cursor() {
        // The status line is drawn by absolute-positioning to the bottom row,
        // with the cursor saved and restored around the jump so output
        // continues uninterrupted. No DECSTBM scroll region is set: that is
        // what lets Ghostty/iTerm2 reflow the conversation on resize.
        let seq = draw_sequence("STATUS", 24);
        assert_eq!(seq, "\x1b7\x1b[24;1H\x1b[2KSTATUS\x1b8");
        assert!(!seq.contains('r'), "no scroll region may be set: {seq:?}");
    }

    #[test]
    fn resize_erases_a_stale_bar_only_when_the_terminal_grew() {
        // Grew: the old bar sits above the new bottom row and would linger as a
        // duplicate, so its former row is cleared before the bar is repainted.
        assert_eq!(resize_erase_sequence(24, 30), "\x1b7\x1b[24;1H\x1b[2K\x1b8");
        // Shrank: the old row is below the new bottom and already gone.
        assert_eq!(resize_erase_sequence(30, 24), "");
        // Unchanged height: `draw` clears and repaints that row anyway.
        assert_eq!(resize_erase_sequence(24, 24), "");
        // No DECSTBM scroll region (which ends in a literal 'r') is set.
        assert!(!resize_erase_sequence(24, 30).contains('r'), "no scroll region may be set");
    }

    #[test]
    fn draw_seq_folds_the_stale_bar_cleanup_before_the_repaint() {
        // `draw_seq` composes the erase and the repaint into one sequence (the
        // erase lives with the size-changing draw, not in `resize`, so whichever
        // caller first observes the grown terminal clears the stale bar and the
        // resize race cannot strand it). When the terminal grew from 24 to 30
        // rows the old row (24) must be erased *before* the bar is painted at
        // the new bottom (30).
        let seq = format!("{}{}", resize_erase_sequence(24, 30), draw_sequence("STATUS", 30));
        let erase_at = seq.find("\x1b[24;1H\x1b[2K").expect("old row erased");
        let draw_at = seq.find("\x1b[30;1H").expect("bar painted at the new bottom");
        assert!(erase_at < draw_at, "stale bar must be erased before the repaint: {seq:?}");
        // Unchanged/shrunk height folds in no erase, only the repaint.
        assert_eq!(
            format!("{}{}", resize_erase_sequence(24, 24), draw_sequence("STATUS", 24)),
            draw_sequence("STATUS", 24)
        );
    }

    #[test]
    fn reserve_bottom_row_keeps_the_prompt_one_row_up() {
        // A blank bottom row is opened with `\n` (which only scrolls the
        // conversation up when the cursor is already on the last row), the
        // cursor steps back above it, and the row it lands on is cleared — so
        // the prompt written next sits one row above the status line and the
        // bottom row is left free for the bar. No DECSTBM region (which ends in
        // 'r') is set, so the terminal stays free to reflow on resize.
        let seq = reserve_bottom_row();
        assert_eq!(seq, "\n\x1b[1A\r\x1b[2K");
        assert!(!seq.contains('r'), "no scroll region may be set: {seq:?}");
    }
}
