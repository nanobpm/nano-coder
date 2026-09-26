//! Spike: a portable, bottom-pinned status line built on `ratatui`'s inline
//! viewport instead of the hand-rolled DECSTBM + SIGWINCH machinery in
//! `src/status.rs`.
//!
//! Why this exists
//! ---------------
//! The production status line pins itself to the bottom row by installing a
//! DECSTBM scroll region and repainting on every `SIGWINCH`. That approach is
//! fragile: on resize (and under concurrent stdout writes) stale copies of the
//! bar scatter across the screen in Ghostty/iTerm2. This prototype demonstrates
//! the durable alternative:
//!
//!   * `Viewport::Inline(height)` reserves the bottom `height` rows for a live
//!     widget and keeps everything above it as ordinary scrollback.
//!   * `Terminal::insert_before` pushes log/assistant output *above* the pinned
//!     area — it scrolls normally and never fights the status bar.
//!   * Resize is handled by ratatui itself: no DECSTBM, no `TIOCGWINSZ`, no
//!     SIGWINCH handler, no manual erase-the-old-row bookkeeping.
//!
//! Known caveat: ratatui issue #2666 — the inline viewport can still leave a
//! copy of the live line in *scrollback history* on some terminals. That is
//! off-screen history, not the on-screen diagonal scatter we see today, and it
//! is being tracked upstream.
//!
//! Run it:
//!
//! ```sh
//! cargo run --example inline_status
//! ```
//!
//! Type to see steers echoed into the bar, resize the window freely, and press
//! `q` or `Ctrl-C` to quit.

use std::io::{self, stdout};
use std::time::{Duration, Instant};

use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::event::{self, Event, KeyCode, KeyModifiers};
use ratatui::crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use ratatui::layout::Alignment;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Paragraph, Widget};
use ratatui::{Terminal, TerminalOptions, Viewport};

/// A trimmed-down mirror of `crate::context::ContextStats`, enough to render a
/// representative status bar for the spike.
struct DemoStats {
    provider: String,
    model: String,
    cwd: String,
    tokens: usize,
    window: usize,
    messages: usize,
    auto_compact: Option<f64>,
    activity: Activity,
    steer: Option<String>,
}

enum Activity {
    Thinking,
    Tool(String),
}

impl DemoStats {
    fn percent(&self) -> f64 {
        if self.window == 0 {
            0.0
        } else {
            (self.tokens as f64 / self.window as f64) * 100.0
        }
    }
}

/// Same colour thresholds as `src/status.rs::render`.
fn bar_style(percent: f64, threshold: Option<f64>) -> Style {
    let color = match threshold {
        Some(t) if percent >= t => Color::Indexed(203),
        _ if percent >= 90.0 => Color::Indexed(203),
        _ if percent >= 60.0 => Color::Indexed(221),
        _ => Color::Indexed(114),
    };
    Style::default().fg(color)
}

fn format_tokens(n: usize) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

/// Build the status line as styled ratatui spans. When a steer is being typed
/// we show that instead, mirroring the production behaviour.
fn status_line(stats: &DemoStats) -> Line<'static> {
    let bg = Style::default()
        .bg(Color::Indexed(236))
        .fg(Color::Indexed(250));

    if let Some(text) = &stats.steer {
        return Line::from(vec![Span::styled(
            format!(" › {text}"),
            bg.fg(Color::Indexed(255)),
        )])
        .style(bg);
    }

    let percent = stats.percent();
    let threshold = stats.auto_compact.map(|t| t * 100.0);
    let filled = ((percent / 10.0).round() as usize).min(10);
    let bar = format!("{}{}", "█".repeat(filled), "░".repeat(10 - filled));
    let model = if stats.model.is_empty() {
        stats.provider.clone()
    } else {
        format!("{}/{}", stats.provider, stats.model)
    };
    let compact = match threshold {
        Some(t) => format!(" auto-compact {t:.0}% "),
        None => " auto-compact off ".to_string(),
    };
    let activity = match &stats.activity {
        Activity::Thinking => (" ● thinking… ".to_string(), Color::Indexed(117)),
        Activity::Tool(name) => (format!(" ▶ {name} "), Color::Indexed(180)),
    };

    let sep = Span::styled("│", bg);
    let spans = vec![
        Span::styled(
            format!(" {model} "),
            bg.fg(Color::Indexed(255)).add_modifier(Modifier::BOLD),
        ),
        sep.clone(),
        Span::styled(format!(" {} ", stats.cwd), bg),
        sep.clone(),
        Span::styled(
            format!(
                " ctx {}/{} {percent:.0}% ",
                format_tokens(stats.tokens),
                format_tokens(stats.window)
            ),
            bg,
        ),
        sep.clone(),
        Span::styled(bar, bar_style(percent, threshold)),
        sep.clone(),
        Span::styled(format!(" {} msgs ", stats.messages), bg),
        sep.clone(),
        Span::styled(compact, bg),
        sep,
        Span::styled(activity.0, bg.fg(activity.1)),
    ];

    Line::from(spans).style(bg)
}

fn main() -> io::Result<()> {
    enable_raw_mode()?;
    let backend = CrosstermBackend::new(stdout());
    let mut terminal = Terminal::with_options(
        backend,
        TerminalOptions {
            viewport: Viewport::Inline(1),
        },
    )?;

    let mut stats = DemoStats {
        provider: "macbook".to_string(),
        model: "qwen3.8-neo-coder".to_string(),
        cwd: "~/workspace/rusty-harness".to_string(),
        tokens: 1_300,
        window: 262_000,
        messages: 1,
        auto_compact: Some(0.85),
        activity: Activity::Thinking,
        steer: None,
    };

    let start = Instant::now();
    let mut last_line = Instant::now();
    let mut chunk = 0usize;

    loop {
        terminal.draw(|frame| {
            frame.render_widget(Paragraph::new(status_line(&stats)), frame.area());
        })?;

        // Simulate a slow (~2 tok/s) assistant stream scrolling above the bar.
        if last_line.elapsed() >= Duration::from_millis(450) {
            last_line = Instant::now();
            chunk += 1;
            stats.tokens += 37;
            stats.messages = 1 + chunk / 8;
            stats.activity = if chunk.is_multiple_of(6) {
                Activity::Tool("read_file".to_string())
            } else {
                Activity::Thinking
            };
            let line = Line::from(format!(
                "assistant › streamed token chunk #{chunk} — resize the window; the bar stays pinned and clean"
            ))
            .alignment(Alignment::Left);
            terminal.insert_before(1, |buf| {
                Paragraph::new(line).render(buf.area, buf);
            })?;
        }

        if event::poll(Duration::from_millis(30))? {
            match event::read()? {
                Event::Key(k) => {
                    let ctrl_c = k.modifiers.contains(KeyModifiers::CONTROL)
                        && matches!(k.code, KeyCode::Char('c'));
                    if ctrl_c {
                        break;
                    }
                    match k.code {
                        KeyCode::Char('q') if stats.steer.is_none() => break,
                        KeyCode::Char(c) => {
                            stats.steer.get_or_insert_with(String::new).push(c);
                        }
                        KeyCode::Backspace => {
                            if let Some(s) = stats.steer.as_mut() {
                                s.pop();
                                if s.is_empty() {
                                    stats.steer = None;
                                }
                            }
                        }
                        KeyCode::Enter | KeyCode::Esc => stats.steer = None,
                        _ => {}
                    }
                }
                // Resize needs no handling: ratatui re-lays the inline viewport.
                Event::Resize(_, _) => {}
                _ => {}
            }
        }

        if start.elapsed() > Duration::from_secs(180) {
            break;
        }
    }

    disable_raw_mode()?;
    terminal.clear()?;
    println!();
    Ok(())
}
