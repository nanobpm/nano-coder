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

use std::io::{self, IsTerminal, Write};
use std::sync::{Arc, Mutex};

use crate::context::{Activity, ContextStats, SharedStats, format_rate, format_tokens};

pub struct StatusLine {
    stats: SharedStats,
    /// Terminal rows and columns the status line was last drawn for.
    size: Mutex<Option<(u16, u16)>>,
    /// Text being typed during a turn, shown instead of the stats.
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

    pub fn draw(&self) {
        // Target the real current terminal, never a stale cached size, so a
        // draw after a resize lands on the new bottom row. There is no scroll
        // region to re-pin: the status line is just painted at the bottom row
        // and the cursor restored, so the terminal stays free to reflow the
        // conversation above it.
        let Some((rows, cols)) = terminal_size() else { return };
        {
            let mut size = self.size.lock().unwrap();
            if size.is_none() {
                return; // torn down
            }
            *size = Some((rows, cols));
        }
        let line = match self.input.lock().unwrap().as_deref() {
            Some(text) => render_input(text, cols as usize),
            None => render(&self.stats.lock().unwrap().clone(), cols as usize),
        };
        write_raw(&draw_sequence(&line, rows));
    }

    /// Show `text` as a line being typed (None: back to the stats).
    pub fn set_input(&self, text: Option<&str>) {
        *self.input.lock().unwrap() = text.map(str::to_string);
        self.draw();
    }

    /// Redraw after the terminal was resized. With no scroll region, the
    /// terminal itself reflows the conversation; all that is needed is to
    /// paint the status line at the new bottom row.
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
    // AI Credits used (GitHub Copilot), when the provider reports them.
    if let Some(aic) = stats.session_aic {
        segments.push(Segment { text: format!(" {aic:.1} AIC "), color: Some("\x1b[38;5;222m"), priority: 2 });
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
    fn draw_sequence_paints_the_bottom_row_and_restores_the_cursor() {
        // The status line is drawn by absolute-positioning to the bottom row,
        // with the cursor saved and restored around the jump so output
        // continues uninterrupted. No DECSTBM scroll region is set: that is
        // what lets Ghostty/iTerm2 reflow the conversation on resize.
        let seq = draw_sequence("STATUS", 24);
        assert_eq!(seq, "\x1b7\x1b[24;1H\x1b[2KSTATUS\x1b8");
        assert!(!seq.contains('r'), "no scroll region may be set: {seq:?}");
    }
}
