//! A status line pinned to the bottom row of the terminal: model, context
//! use, session tokens and what the agent is doing.
//!
//! The rows above it are made a scroll region (DECSTBM), so ordinary output
//! scrolls without disturbing the status line. The conversation is kept
//! bottom-anchored (directly above the status line, blank rows at the top) so
//! that shrinking the window drops blank rows rather than conversation.

use std::io::{self, IsTerminal, Write};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::context::{Activity, ContextStats, SharedStats, format_rate, format_tokens};

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
    with_term_lock(|| emit(bytes));
}

/// Write without taking the terminal lock; the caller must hold it.
fn emit(bytes: &str) {
    let mut out = io::stdout().lock();
    let _ = out.write_all(bytes.as_bytes());
    let _ = out.flush();
}

/// A cursor position report (`ESC [ row ; col R`) the line reader forwarded,
/// and whether one is being waited for. Reports arriving while nothing waits
/// are ignored: a modified F3 key sends the same shape.
static CURSOR_REPORT: (Mutex<(bool, Option<u16>)>, Condvar) = (Mutex::new((false, None)), Condvar::new());

/// How long to wait for the terminal to answer a cursor position query.
const CURSOR_REPORT_WAIT: Duration = Duration::from_millis(150);

/// Called by the line reader when it parses a cursor position report.
/// Returns whether the report was expected (and so consumed).
pub fn cursor_reported(row: u16) -> bool {
    let (lock, signal) = &CURSOR_REPORT;
    let mut report = lock.lock().unwrap_or_else(|e| e.into_inner());
    if !report.0 {
        return false;
    }
    report.1 = Some(row);
    signal.notify_all();
    true
}

/// Parse a cursor position report `ESC [ row ; col R` into `(row, col)`.
fn parse_cursor_report(bytes: &[u8]) -> Option<(u16, u16)> {
    let start = bytes.windows(2).rposition(|w| w == b"\x1b[")? + 2;
    let body = std::str::from_utf8(&bytes[start..]).ok()?.strip_suffix('R')?;
    let (row, col) = body.split_once(';')?;
    Some((row.parse().ok()?, col.parse().ok()?))
}

/// The row of a complete cursor position report, for the line reader.
pub fn cursor_report_row(seq: &[u8]) -> Option<u16> {
    parse_cursor_report(seq).map(|(row, _)| row)
}

/// Ask the terminal where the cursor is, reading the answer straight from
/// stdin. Only for use before the line reader starts (it would otherwise
/// race for the reply): echo and line buffering are turned off meanwhile so
/// the reply is never printed.
fn query_cursor_direct() -> Option<(u16, u16)> {
    let mut original: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut original) } != 0 {
        return None;
    }
    let mut raw = original;
    // Disable ISIG too: with ECHO/ICANON off, a Ctrl-C mid-query would
    // otherwise deliver SIGINT and terminate the process before termios is
    // restored below, stranding the terminal in non-echo/non-canonical mode.
    // Treat the interrupt byte as ordinary input for the brief query instead.
    raw.c_lflag &= !(libc::ICANON | libc::ECHO | libc::ISIG);
    raw.c_cc[libc::VMIN] = 0;
    raw.c_cc[libc::VTIME] = 0;
    if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) } != 0 {
        return None;
    }
    emit("\x1b[6n");
    let deadline = std::time::Instant::now() + CURSOR_REPORT_WAIT * 2;
    let mut reply = Vec::new();
    while !reply.ends_with(b"R") {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        if left.is_zero() {
            break;
        }
        let mut fd = libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
        if unsafe { libc::poll(&mut fd, 1, left.as_millis() as i32) } <= 0 {
            break;
        }
        let mut byte = 0u8;
        if unsafe { libc::read(libc::STDIN_FILENO, (&mut byte as *mut u8).cast(), 1) } != 1 {
            break;
        }
        reply.push(byte);
    }
    unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &original) };
    parse_cursor_report(&reply)
}

/// Bytes that scroll the scroll region's content down `gap` rows and move
/// the cursor down with it, so the conversation sits directly above the
/// status line. Blank lines are inserted at the top of the region (IL at row
/// 1, equivalent to SD but more widely emulated) and the region's bottom
/// `gap` rows — blank, below the cursor — drop off.
pub fn anchor_sequence(gap: u16) -> String {
    if gap == 0 {
        return String::new();
    }
    format!("\x1b7\x1b[1;1H\x1b[{gap}L\x1b8\x1b[{gap}B")
}

/// Bytes that pin the status row and bottom-anchor the conversation, given
/// where the cursor is (`None`: unknown). With the conversation directly
/// above the status line there are no blank rows between them, so when the
/// window shrinks the terminal drops blank rows from the top instead of
/// pushing the conversation up out of view: terminals only trim blank rows
/// at the very bottom, and the status line's row is never blank.
fn install_sequence(rows: u16, cursor: Option<(u16, u16)>) -> String {
    let bottom = scroll_region_bottom(rows);
    match cursor {
        Some((row, col)) if row < bottom => {
            format!("\x1b[1;{bottom}r\x1b[{row};{col}H{}", anchor_sequence(bottom - row))
        }
        // On (or below) the last region row, or unknown: make sure the cursor
        // is above the bottom row, then confine scrolling.
        _ => format!("\n\x1b[1A\x1b7\x1b[1;{bottom}r\x1b8"),
    }
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
        write_raw(&install_sequence(rows, query_cursor_direct()));
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
        let mut size = self.size.lock().unwrap();
        // When the size changed, prepend the resize cleanup so the whole draw —
        // region reset, erase-below and the fresh bar — is emitted as one
        // atomic write. Splitting it into separate writes lets output from
        // another thread interleave between them and tear the escape sequences.
        let prefix = match *size {
            None => return, // torn down
            Some((old_rows, old_cols)) if (old_rows, old_cols) != (rows, cols) => {
                *size = Some((rows, cols));
                resize_sequence(rows)
            }
            Some(_) => String::new(),
        };
        let line = match self.input.lock().unwrap().as_deref() {
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
    /// bar as one atomic write. Then re-anchor the conversation: a terminal
    /// that grew with too little scrollback to pull back pads blank rows at the
    /// bottom, opening a gap between the conversation and the status line.
    /// Call only from the SIGWINCH handler, never from the line reader thread
    /// (which must be free to read the cursor position reply).
    pub fn resize(&self) {
        self.draw();
        self.anchor();
    }

    /// Close any gap between the cursor and the status line by scrolling the
    /// conversation down into it. Asks the terminal for the cursor row, which
    /// only works while the line reader is in key mode (it forwards the reply;
    /// outside key mode the reply would be echoed). The terminal lock is held
    /// from the query to the scroll, so no output can move the cursor between
    /// them. Gives up after a short wait if no reply is forwarded.
    fn anchor(&self) {
        if !crate::lineedit::key_mode_active() {
            return;
        }
        let Some((rows, _)) = *self.size.lock().unwrap() else { return };
        with_term_lock(|| {
            let (lock, signal) = &CURSOR_REPORT;
            let mut report = lock.lock().unwrap_or_else(|e| e.into_inner());
            *report = (true, None);
            emit("\x1b[6n");
            let (mut report, _) = signal
                .wait_timeout_while(report, CURSOR_REPORT_WAIT, |r| r.1.is_none())
                .unwrap_or_else(|e| e.into_inner());
            let row = report.1.take();
            report.0 = false;
            drop(report);
            if let Some(row) = row {
                emit(&anchor_sequence(scroll_region_bottom(rows).saturating_sub(row)));
            }
        });
    }

    /// Clear the screen and scrollback for a fresh session, then re-establish
    /// the scroll region and redraw. A naive clear would fight the DECSTBM
    /// region, so it is reset and re-confined here.
    pub fn clear(&self) {
        {
            let size = self.size.lock().unwrap();
            let Some((rows, _cols)) = *size else { return };
            // Drop the region, home the cursor, wipe the screen + scrollback,
            // re-confine scrolling to every row but the pinned bottom one, and
            // start on the last region row so the new conversation is
            // bottom-anchored like the first.
            let bottom = scroll_region_bottom(rows);
            write_raw(&format!("\x1b[r\x1b[H\x1b[2J\x1b[3J\x1b[1;{bottom}r\x1b[{bottom};1H"));
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
            compactions: 1,
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
    fn marks_uncalibrated_estimates() {
        let line = visible(&render(&ContextStats { calibrated: false, ..stats() }, 140));
        assert!(line.contains("ctx ~96.5k"), "{line:?}");
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
    fn parses_cursor_position_reports() {
        assert_eq!(parse_cursor_report(b"\x1b[12;5R"), Some((12, 5)));
        assert_eq!(parse_cursor_report(b"typed\x1b[3;1R"), Some((3, 1)), "takes the report after typeahead");
        assert_eq!(parse_cursor_report(b"\x1b[12;5"), None, "incomplete");
        assert_eq!(parse_cursor_report(b"\x1b[A"), None, "an arrow key is not a report");
        assert_eq!(cursor_report_row(b"\x1b[7;40R"), Some(7));
    }

    #[test]
    fn anchor_scrolls_the_region_down_and_follows_with_the_cursor() {
        assert_eq!(anchor_sequence(0), "");
        // Insert blank lines at the top of the region (pushing the
        // conversation down), then move the restored cursor down with it.
        assert_eq!(anchor_sequence(3), "\x1b7\x1b[1;1H\x1b[3L\x1b8\x1b[3B");
    }

    #[test]
    fn install_bottom_anchors_the_conversation() {
        // Cursor on row 8 of 24: pin rows 1..=23, put the cursor back and
        // scroll the conversation down 15 rows so it sits on row 23.
        assert_eq!(install_sequence(24, Some((8, 1))), format!("\x1b[1;23r\x1b[8;1H{}", anchor_sequence(15)));
        // Already on the last region row, on the status row, or unknown: just
        // keep the cursor off the bottom row and pin the region.
        let plain = "\n\x1b[1A\x1b7\x1b[1;23r\x1b8";
        assert_eq!(install_sequence(24, Some((23, 1))), plain);
        assert_eq!(install_sequence(24, Some((24, 1))), plain);
        assert_eq!(install_sequence(24, None), plain);
    }

    #[test]
    fn scroll_region_never_underflows_on_tiny_terminals() {
        assert_eq!(scroll_region_bottom(1), 1);
        assert_eq!(scroll_region_bottom(2), 1);
        assert_eq!(scroll_region_bottom(24), 23);
    }
}
