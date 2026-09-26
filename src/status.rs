//! A status line pinned to the bottom row of the terminal: model, context
//! use, session tokens and what the agent is doing.
//!
//! The rows above it are made a scroll region (DECSTBM), so ordinary output
//! scrolls without disturbing the status line.

use std::io::{self, IsTerminal, Write};
use std::sync::{Arc, Mutex};

use crate::context::{Activity, ContextStats, SharedStats, format_tokens};

pub struct StatusLine {
    stats: SharedStats,
    /// Terminal rows and columns the scroll region was set for.
    size: Mutex<Option<(u16, u16)>>,
    /// Text being typed during a turn (a steer), shown instead of the stats.
    input: Mutex<Option<String>>,
}

pub fn terminal_size() -> Option<(u16, u16)> {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0;
    (ok && size.ws_row > 0 && size.ws_col > 0).then_some((size.ws_row, size.ws_col))
}

fn write_raw(bytes: &str) {
    with_term_lock(|| {
        let mut out = io::stdout().lock();
        let _ = out.write_all(bytes.as_bytes());
        let _ = out.flush();
    });
}

/// A process-wide lock serialising every write to the terminal. Escape
/// sequences are emitted from more than one thread — the renderer and line
/// editor on the main task, the status line from the SIGWINCH handler — and a
/// multi-write logical unit (the region reset before a redraw, a streamed
/// fragment and its deferred notes) must not interleave with another thread's
/// sequence, or the cursor-save/restore and cursor-addressing tear and scatter
/// output across the screen. `std::io::Stdout`'s own lock only makes a single
/// `write_all` atomic; this lock spans a whole unit.
static TERM_LOCK: Mutex<()> = Mutex::new(());

/// Run `f` while holding the terminal write lock. Callers that emit escape
/// sequences directly hold it across the whole logical unit. The lock is not
/// reentrant: `f` must not call back into any terminal write helper.
pub fn with_term_lock<R>(f: impl FnOnce() -> R) -> R {
    let _guard = TERM_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    f()
}

/// The last scrollable row: the terminal's bottom row is reserved for the
/// status line, so the region is `1..=bottom-1`. Clamped to at least 1.
fn scroll_region_bottom(rows: u16) -> u16 {
    rows.max(2) - 1
}

/// Bytes that clean up after a resize to `rows`: save the cursor (it sits at
/// the conversation end), drop the scroll region, erase from the cursor to the
/// end of the display, re-pin the region for the new height and restore the
/// cursor. A terminal's resize reflows the whole grid and can relocate a
/// previously-drawn status bar to a mid-screen row the app never addresses;
/// erasing below the conversation cursor wipes any such stranded bar while
/// leaving the conversation above and the scrollback untouched. Runs
/// unconditionally for both grow and shrink; it addresses no absolute row, so
/// it is safe whether the terminal grew or shrank.
///
/// DECSTBM homes the cursor, so the cursor must be restored after resetting
/// the region and before erasing — otherwise `ESC[J` erases from row 1 and
/// wipes the whole visible conversation.
fn resize_sequence(rows: u16) -> String {
    format!("\x1b7\x1b[r\x1b8\x1b[J\x1b7\x1b[1;{}r\x1b8", scroll_region_bottom(rows))
}

impl StatusLine {
    /// Reserve the bottom row, when stdin and stdout are a terminal and
    /// `AGENTIC_NO_STATUS` is unset.
    pub fn install(stats: SharedStats) -> Option<Arc<Self>> {
        if !io::stdout().is_terminal() || !io::stdin().is_terminal() || std::env::var_os("AGENTIC_NO_STATUS").is_some() {
            return None;
        }
        let (rows, cols) = terminal_size().filter(|(rows, _)| *rows >= 5)?;
        // Make sure the cursor is above the bottom row, then confine scrolling.
        write_raw(&format!("\n\x1b[1A\x1b7\x1b[1;{}r\x1b8", rows - 1));
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            write_raw("\x1b7\x1b[r\x1b8");
            previous(info);
        }));
        let status = Arc::new(Self { stats, size: Mutex::new(Some((rows, cols))), input: Mutex::new(None) });
        status.draw();
        Some(status)
    }

    pub fn draw(&self) {
        // Target the real current terminal, never a stale cached size. A draw()
        // triggered by a Context event, the renderer or lineedit before the
        // SIGWINCH handler has run must not write the status line to a
        // mid-screen row — that is what scatters copies across the screen on
        // resize. When the size has changed, erase the old and new bottom rows
        // and re-pin the scroll region first, so the stale bar left at the old
        // bottom row is cleared even when the SIGWINCH resize() later no-ops.
        let Some((rows, cols)) = terminal_size() else { return };
        // Compute the resize cleanup under the `size` lock, then release that
        // lock before taking any other. draw() must never hold two of the
        // struct's mutexes at once: set_input() takes `input` and then calls
        // draw(), so if draw() held `size` while locking `input` the two paths
        // could deadlock on a lock-order inversion. Scoping each lock to a
        // single acquire removes that ordering entirely.
        //
        // When the size changed, prepend the resize cleanup so the whole draw —
        // region reset, erase-below and the fresh bar — is emitted as one
        // atomic write. Splitting it into separate writes lets output from
        // another thread interleave between them and tear the escape sequences.
        let prefix = {
            let mut size = self.size.lock().unwrap();
            match *size {
                None => return, // torn down
                Some((old_rows, old_cols)) if (old_rows, old_cols) != (rows, cols) => {
                    *size = Some((rows, cols));
                    resize_sequence(rows)
                }
                Some(_) => String::new(),
            }
        };
        // Snapshot the steer text and drop the `input` lock before touching
        // `stats`, so at most one of these locks is ever held at a time.
        let input = self.input.lock().unwrap().clone();
        let line = match input.as_deref() {
            Some(text) => render_input(text, cols as usize),
            None => render(&self.stats.lock().unwrap().clone(), cols as usize),
        };
        write_raw(&format!("{prefix}\x1b7\x1b[{rows};1H\x1b[2K{line}\x1b8"));
    }

    /// Show `text` as a line being typed (None: back to the stats).
    pub fn set_input(&self, text: Option<&str>) {
        *self.input.lock().unwrap() = text.map(str::to_string);
        self.draw();
    }

    /// Re-establish the region after the terminal was resized. `draw()` already
    /// detects a size change and emits the region reset, erase-below and fresh
    /// bar as one atomic write, so this simply delegates to it — keeping the
    /// SIGWINCH path a single, un-interleavable terminal write.
    pub fn resize(&self) {
        self.draw();
    }

    /// Clear the screen and scrollback for a fresh session, then re-establish
    /// the scroll region and redraw. A naive clear would fight the DECSTBM
    /// region, so it is reset and re-confined here.
    pub fn clear(&self) {
        {
            let size = self.size.lock().unwrap();
            let Some((rows, _cols)) = *size else { return };
            // Drop the region, home the cursor, wipe the screen + scrollback,
            // then re-confine scrolling to every row but the pinned bottom one.
            write_raw(&format!("\x1b[r\x1b[H\x1b[2J\x1b[3J\x1b[1;{}r", rows.max(2) - 1));
        }
        self.draw();
    }

    /// Clear the status line and give the whole screen back.
    pub fn teardown(&self) {
        let mut size = self.size.lock().unwrap();
        if let Some((rows, _)) = size.take() {
            write_raw(&format!("\x1b7\x1b[{rows};1H\x1b[2K\x1b[r\x1b8"));
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

fn render_input(text: &str, cols: usize) -> String {
    let prefix = " ✎ steer › ";
    let hint = "  Enter to send ";
    let room = cols.saturating_sub(prefix.chars().count() + hint.len() + 1);
    let count = text.chars().count();
    let shown: String = if count > room { text.chars().skip(count - room).collect() } else { text.to_string() };
    let used = prefix.chars().count() + shown.chars().count() + 1;
    let pad = cols.saturating_sub(used + hint.len());
    format!(
        "{BG}\x1b[1;38;5;117m{prefix}\x1b[0;48;5;236;38;5;255m{shown}█{}\x1b[38;5;244m{hint}{RESET}",
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
            compactions: 1,
            auto_compact: Some(0.8),
            activity: Activity::Tool("bash".into()),
            plan: Some((2, 5)),
            cwd: "/tmp/project".into(),
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
    fn marks_uncalibrated_estimates() {
        let line = visible(&render(&ContextStats { calibrated: false, ..stats() }, 140));
        assert!(line.contains("ctx ~96.5k"), "{line:?}");
    }

    #[test]
    fn resize_sequence_erases_below_cursor_and_repins() {
        // On resize the cursor sits at the conversation end (draws save/restore
        // it there). Reset the region, erase from the cursor to the end of the
        // display so any bar the terminal's resize reflow relocated below the
        // conversation is wiped, then re-pin for the new size. The conversation
        // above the cursor and the scrollback are left untouched.
        let seq = resize_sequence(40);
        assert!(seq.starts_with("\x1b7"), "cursor not saved first: {seq:?}");
        assert!(seq.contains("\x1b[r"), "region not reset to full screen: {seq:?}");
        // DECSTBM homes the cursor: it must be restored before erasing, or the
        // erase starts at row 1 and wipes the conversation.
        assert!(seq.contains("\x1b[r\x1b8\x1b[J"), "erase not from the restored cursor: {seq:?}");
        assert!(seq.ends_with("\x1b[1;39r\x1b8"), "region not re-pinned / cursor not restored: {seq:?}");
    }

    #[test]
    fn resize_sequence_addresses_no_absolute_row() {
        // Erase-below is cursor-relative, so the sequence must never move to an
        // absolute row — a row addressed after a shrink could be off-screen,
        // and one after a grow could clobber conversation content.
        for rows in [40, 24, 70, 110, 2, 1] {
            let seq = resize_sequence(rows);
            assert!(!seq.contains(";1H"), "addressed an absolute row for {rows} rows: {seq:?}");
        }
    }

    #[test]
    fn scroll_region_never_underflows_on_tiny_terminals() {
        assert_eq!(scroll_region_bottom(1), 1);
        assert_eq!(scroll_region_bottom(2), 1);
        assert_eq!(scroll_region_bottom(24), 23);
    }
}
