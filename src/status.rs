//! The status bar: model, cwd, context use, session tokens and what the
//! agent is doing, rendered as one line for the frame renderer's last row.

use std::io::{self, IsTerminal};
use std::sync::{Arc, Mutex};

use crate::context::{Activity, ContextStats, SharedStats, format_rate, format_tokens};
use unicode_width::UnicodeWidthChar;

pub struct StatusLine {
    stats: SharedStats,
}

pub fn terminal_size() -> Option<(u16, u16)> {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0;
    (ok && size.ws_row > 0 && size.ws_col > 0).then_some((size.ws_row, size.ws_col))
}

/// Size of the terminal on **stderr**, where dialoguer pickers render. The
/// `--resume` picker is gated on stdin/stderr being terminals (stdout may be
/// redirected), so measuring stdout would fall back to a default even when
/// the stderr terminal is narrower and the supposedly fitted rows wrap.
pub fn stderr_terminal_size() -> Option<(u16, u16)> {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDERR_FILENO, libc::TIOCGWINSZ, &mut size) } == 0;
    (ok && size.ws_row > 0 && size.ws_col > 0).then_some((size.ws_row, size.ws_col))
}

/// A process-wide lock serialising multi-write units to stdout (a streamed
/// fragment and the deferred notes it releases), so output from another
/// thread cannot interleave with them. `std::io::Stdout`'s own lock only
/// makes a single `write_all` atomic; this lock spans a whole unit.
static TERM_LOCK: Mutex<()> = Mutex::new(());

/// Run `f` while holding the terminal write lock. The lock is not
/// reentrant: `f` must not call back into any terminal write helper.
pub fn with_term_lock<R>(f: impl FnOnce() -> R) -> R {
    let _guard = TERM_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    f()
}

impl StatusLine {
    /// The status bar, when stdin and stdout are a terminal and
    /// `AGENTIC_NO_STATUS` is unset. Writes nothing: the frame renderer draws
    /// it as the frame's last row.
    pub fn install(stats: SharedStats) -> Option<Arc<Self>> {
        if !io::stdout().is_terminal() || !io::stdin().is_terminal() || std::env::var_os("AGENTIC_NO_STATUS").is_some()
        {
            return None;
        }
        Some(Arc::new(Self { stats }))
    }

    /// The status bar as a plain string at `cols` columns.
    pub fn stats_line(&self, cols: usize) -> String {
        render(&self.stats.lock().unwrap().clone(), cols)
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

/// Index of the cwd in the status segments (after the model).
const CWD_SEGMENT: usize = 1;
/// The narrowest the cwd is elided to before whole segments are dropped.
const CWD_MIN_CELLS: usize = 16;

/// `path` for display, with the home directory shown as `~`. Only whole
/// leading components match: `/home/joshua` is not a prefix of
/// `/home/joshua2`.
pub fn tilde_path(path: &std::path::Path, home: Option<&std::path::Path>) -> String {
    let home = home.filter(|h| h.components().count() > 1);
    // The working directory is reported with symlinks resolved (on macOS
    // `/tmp` is `/private/tmp`), so also try the resolved home directory.
    // Apply the same root guard after canonicalization: a symlinked home that
    // resolves to `/` would otherwise strip the `/` prefix from every
    // absolute path and display it as `~/…`.
    let resolved = home.and_then(|h| h.canonicalize().ok()).filter(|h| h.components().count() > 1);
    let rest = home
        .and_then(|h| path.strip_prefix(h).ok())
        .or_else(|| resolved.as_deref().and_then(|h| path.strip_prefix(h).ok()));
    match rest {
        Some(rest) if rest.as_os_str().is_empty() => "~".to_string(),
        Some(rest) => format!("~/{}", rest.display()),
        None => path.display().to_string(),
    }
}

/// Shorten `path` to at most `budget` terminal cells by replacing middle
/// directories with `…`: keep the first component (`~`, or the first
/// directory under `/`) and as many trailing components as fit, e.g.
/// `~/workspace/nano/src/providers` -> `~/…/src/providers`. When even the
/// first and last components don't fit, keep the end of the last one
/// (`…providers`), since that is the directory the user is in.
fn elide_path(path: &str, budget: usize) -> String {
    if cell_width(path) <= budget {
        return path.to_string();
    }
    let parts: Vec<&str> = path.split('/').collect();
    // `/a/b/c` splits to ["", "a", "b", "c"]: keep "/a" as the head.
    let head_len = if parts.first() == Some(&"") { 2 } else { 1 };
    if parts.len() > head_len + 1 {
        let head = parts[..head_len].join("/");
        // Take trailing components while they fit, always leaving at least
        // one middle component to elide (or nothing would be gained).
        let mut keep = 0;
        while head_len + keep + 1 < parts.len() {
            let tail = parts[parts.len() - keep - 1..].join("/");
            if cell_width(&format!("{head}/…/{tail}")) > budget {
                break;
            }
            keep += 1;
        }
        if keep > 0 {
            return format!("{head}/…/{}", parts[parts.len() - keep..].join("/"));
        }
    }
    // Keep the end of the path, with `…` in front, within the budget.
    if budget == 0 {
        return String::new();
    }
    let mut kept: Vec<char> = Vec::new();
    let mut used = 1; // the leading `…`
    for c in path.chars().rev() {
        let w = UnicodeWidthChar::width(c).unwrap_or(0);
        if used + w > budget {
            break;
        }
        kept.push(c);
        used += w;
    }
    std::iter::once('…').chain(kept.into_iter().rev()).collect()
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
    let model =
        if stats.model.is_empty() { stats.provider.clone() } else { format!("{}/{}", stats.provider, stats.model) };

    let mut segments = vec![
        Segment { text: format!(" {model} "), color: Some("\x1b[1;38;5;255m"), priority: 9 },
        Segment { text: format!(" {} ", stats.cwd), color: None, priority: 6 },
        Segment {
            text: format!(
                " ctx {approx}{}/{} {percent:.0}% ",
                format_tokens(stats.tokens),
                format_tokens(stats.window)
            ),
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
    // The thinking level, when one is sent (none: the model decides).
    if let Some(level) = &stats.thinking {
        segments.push(Segment { text: format!(" think {level} "), color: Some("\x1b[38;5;147m"), priority: 4 });
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
    let label = if stats.smart_compact { "smart-compact" } else { "auto-compact" };
    let compact = match threshold {
        Some(t) => format!(" {label} {t:.0}%"),
        None => format!(" {label} off"),
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
        segments.iter().map(|s| cell_width(&s.text)).sum::<usize>() + segments.len().saturating_sub(1)
    };
    // Too wide: first shorten the cwd by eliding its middle directories, down
    // to CWD_MIN_CELLS, before any other segment is dropped.
    let overflow = width(&segments).saturating_sub(cols);
    if overflow > 0 {
        let cwd_width = cell_width(&stats.cwd);
        let budget = cwd_width.saturating_sub(overflow).max(CWD_MIN_CELLS.min(cwd_width));
        segments[CWD_SEGMENT].text = format!(" {} ", elide_path(&stats.cwd, budget));
    }
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
        let text = fit_cells(&segment.text, cols.saturating_sub(used));
        used += cell_width(&text);
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

/// Total terminal-cell width of `text`. The status segments are plain text
/// (colours are applied separately), so no ANSI stripping is needed. CJK and
/// wide emoji count as two cells so a status row never exceeds `cols` and gets
/// wrapped by the terminal, which would break the editor/status last-row
/// invariant.
fn cell_width(text: &str) -> usize {
    text.chars().map(|c| UnicodeWidthChar::width(c).unwrap_or(0)).sum()
}

/// Hard-truncate `text` to at most `budget` terminal cells, never splitting a
/// wide glyph across the boundary. Control characters are dropped rather than
/// emitted: values folded into a status segment (`cwd`, model/provider text, …)
/// can carry a newline, carriage return, tab or ESC. Those measure zero cells
/// via `cell_width`, so they'd slip past the width budget yet still add extra
/// rows or move/clear the cursor at draw time, breaking the frame's exact
/// last-row invariant.
fn fit_cells(text: &str, budget: usize) -> String {
    let mut out = String::new();
    let mut used = 0;
    for c in text.chars() {
        if c.is_control() {
            continue;
        }
        let w = UnicodeWidthChar::width(c).unwrap_or(0);
        if used + w > budget {
            break;
        }
        out.push(c);
        used += w;
    }
    out
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
            window_source: "known for the model name".into(),
            messages: 42,
            session_input_tokens: 310_000,
            session_output_tokens: 12_400,
            session_aic: None,
            compactions: 1,
            history_searches: 0,
            history_reads: 0,
            history_available: false,
            auto_compact: Some(0.8),
            smart_compact: false,
            activity: Activity::Tool("bash".into()),
            plan: Some((2, 5)),
            cwd: "/tmp/project".into(),
            tokens_per_sec: None,
            mode: crate::mode::AgentMode::Normal,
            thinking: None,
        }
    }

    #[test]
    fn shows_the_thinking_level_only_when_one_is_sent() {
        assert!(!visible(&render(&stats(), 160)).contains("think "));
        let line = visible(&render(&ContextStats { thinking: Some("high".into()), ..stats() }, 160));
        assert!(line.contains("think high"), "{line:?}");
        // Dropped before the model and context on a narrow terminal.
        let line = visible(&render(&ContextStats { thinking: Some("high".into()), ..stats() }, 50));
        assert!(!line.contains("think high") && line.contains("work/llama-b"), "{line:?}");
    }

    #[test]
    fn renders_all_segments_when_wide() {
        let line = visible(&render(&stats(), 140));
        assert_eq!(line.chars().count(), 140);
        for part in [
            "work/llama-b",
            "ctx 96.5k/128k 75%",
            "42 msgs",
            "↑310k ↓12.4k",
            "auto-compact 80% (1×)",
            "▶ bash",
            "plan 2/5",
        ] {
            assert!(line.contains(part), "{part} missing from {line:?}");
        }
    }

    #[test]
    fn names_smart_compaction() {
        let mut stats = stats();
        stats.smart_compact = true;
        let line = visible(&render(&stats, 140));
        assert!(line.contains("smart-compact 80% (1×)"), "{line:?}");
        assert!(!line.contains("auto-compact"), "{line:?}");
        stats.auto_compact = None;
        assert!(visible(&render(&stats, 140)).contains("smart-compact off"));
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
    fn strips_control_chars_from_segments() {
        // A cwd (or model/provider) carrying control bytes must never emit them
        // into the status row: a newline/CR/ESC would add rows or move the
        // cursor, breaking the frame's last-row invariant even though those
        // bytes measure zero cells and slip past the width budget.
        let evil = ContextStats { cwd: "/tmp/a\nb\r\x1b[2Jc\td".into(), ..stats() };
        let line = render(&evil, 140);
        assert!(!line.contains('\n'), "newline leaked: {line:?}");
        assert!(!line.contains('\r'), "carriage return leaked: {line:?}");
        assert!(!line.contains('\t'), "tab leaked: {line:?}");
        assert!(
            !line.contains('\x1b') || visible(&line).chars().all(|c| !c.is_control()),
            "control leaked into visible text: {:?}",
            visible(&line)
        );
        // The surrounding real path characters survive.
        assert!(visible(&line).contains("abcd") || visible(&line).contains("/tmp/a"), "{line:?}");
    }

    #[test]
    fn home_is_shown_as_tilde() {
        use std::path::Path;
        let home = Some(Path::new("/Users/joshua"));
        assert_eq!(tilde_path(Path::new("/Users/joshua"), home), "~");
        assert_eq!(tilde_path(Path::new("/Users/joshua/workspace/nano"), home), "~/workspace/nano");
        // Whole components only, and paths outside home are unchanged.
        assert_eq!(tilde_path(Path::new("/Users/joshua2/x"), home), "/Users/joshua2/x");
        assert_eq!(tilde_path(Path::new("/tmp/project"), home), "/tmp/project");
        assert_eq!(tilde_path(Path::new("/tmp"), None), "/tmp");
        // A home of `/` would turn every path into `~/…`: leave it alone.
        assert_eq!(tilde_path(Path::new("/tmp"), Some(Path::new("/"))), "/tmp");
        // A home reached through a symlink matches the resolved working dir.
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().canonicalize().unwrap().join("real-home");
        std::fs::create_dir_all(real.join("proj")).unwrap();
        let link = dir.path().join("link-home");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(tilde_path(&real.join("proj"), Some(&link)), "~/proj");
        // A symlinked home that resolves to `/` is still a root home: leave
        // absolute paths alone rather than stripping the resolved `/` prefix.
        let root_link = dir.path().join("root-home");
        std::os::unix::fs::symlink("/", &root_link).unwrap();
        assert_eq!(tilde_path(Path::new("/tmp"), Some(&root_link)), "/tmp");
        assert_eq!(tilde_path(Path::new("/any/where"), Some(&root_link)), "/any/where");
    }

    #[test]
    fn elide_path_drops_middle_directories_first() {
        let path = "~/workspace/rusty-harness/src/providers";
        assert_eq!(elide_path(path, 100), path, "fits: unchanged");
        assert_eq!(elide_path(path, 31), "~/…/rusty-harness/src/providers");
        assert_eq!(elide_path(path, 30), "~/…/src/providers");
        assert_eq!(elide_path(path, 20), "~/…/src/providers");
        assert_eq!(elide_path(path, 15), "~/…/providers");
        // Too narrow for head and last component: keep the end of the path.
        assert_eq!(elide_path(path, 8), "…oviders");
        assert_eq!(elide_path(path, 1), "…");
        assert_eq!(elide_path(path, 0), "");
        // Absolute paths keep their first directory.
        assert_eq!(elide_path("/var/lib/docker/volumes/data", 22), "/var/…/volumes/data");
        // Nothing in the middle to elide.
        assert_eq!(elide_path("/verylongdirectory/name", 10), "…tory/name");
        // Budgeted by terminal cells: CJK glyphs are two cells wide.
        let wide = elide_path("/项目/工作目录/深层/路径", 12);
        assert!(cell_width(&wide) <= 12, "{wide:?}");
        assert!(wide.ends_with("路径"), "{wide:?}");
    }

    #[test]
    fn a_long_cwd_is_elided_before_other_segments_are_dropped() {
        let long = ContextStats { cwd: "~/workspace/clients/acme/monorepo/services/billing/api".into(), ..stats() };
        let full = visible(&render(&long, 400));
        assert!(full.contains(&long.cwd), "wide: shown whole {full:?}");
        // Narrow enough that the whole cwd would push segments off, but wide
        // enough for all of them once the cwd is elided.
        let wide_enough = cell_width(visible(&render(&stats(), 400)).trim_end()) + 20;
        let line = visible(&render(&long, wide_enough));
        assert!(line.contains("~/…/"), "{line:?}");
        assert!(line.ends_with("api ") || line.contains("/api "), "the current directory stays: {line:?}");
        for part in ["work/llama-b", "ctx 96.5k/128k 75%", "42 msgs", "auto-compact 80% (1×)", "▶ bash", "plan 2/5"]
        {
            assert!(line.contains(part), "{part} dropped instead of eliding the cwd: {line:?}");
        }
        assert!(cell_width(&line) <= wide_enough);
    }

    #[test]
    fn status_row_never_exceeds_cols_with_wide_glyphs() {
        // A CJK cwd occupies two cells per glyph: the row must be budgeted and
        // truncated by terminal cells so it never overflows `cols` (which would
        // wrap and break the editor/status last-row invariant).
        let wide = ContextStats { cwd: "/项目/工作目录/深层/路径".into(), ..stats() };
        for cols in 10..=140 {
            let line = visible(&render(&wide, cols));
            assert!(
                cell_width(&line) <= cols,
                "row overflows at {cols} cols: cell_width={} {line:?}",
                cell_width(&line)
            );
        }
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
}
