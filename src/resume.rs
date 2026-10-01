//! Choosing a session to resume: `--resume` without an ID, `--resume last`,
//! and `--list-sessions`.

use std::io::Write;
use std::path::Path;

use anyhow::{Result, bail};
use chrono::{DateTime, FixedOffset, Local};
use unicode_width::UnicodeWidthChar;

use crate::session_index::{self, Summary};

/// Sessions that ran in `cwd`, plus those from older logs that don't say
/// where they ran.
pub fn in_dir<'a>(sessions: &'a [Summary], cwd: &str) -> Vec<&'a Summary> {
    sessions.iter().filter(|s| s.cwd.as_deref().is_none_or(|c| c == cwd)).collect()
}

/// The most recent session that ran in `cwd` (`--resume last`).
pub fn last(dir: &Path, cwd: &str) -> Result<String> {
    let sessions = session_index::list(dir)?;
    match sessions.iter().find(|s| s.cwd.as_deref() == Some(cwd)) {
        Some(session) => Ok(session.id.clone()),
        None => bail!("no saved session for {}; run with --resume to pick one", crate::sanitize_terminal_text(cwd)),
    }
}

/// How long ago `then` was, briefly.
pub fn ago(then: DateTime<FixedOffset>, now: DateTime<FixedOffset>) -> String {
    let minutes = (now - then).num_minutes();
    match minutes {
        ..1 => "just now".into(),
        1..60 => format!("{minutes}m ago"),
        60..1440 => format!("{}h ago", minutes / 60),
        1440..2880 => "yesterday".into(),
        2880..10080 => format!("{}d ago", minutes / 1440),
        _ => then.with_timezone(&Local).format("%b %-d").to_string(),
    }
}

/// The last component of the session's directory, or `?` when unknown.
/// Control characters are dropped: the path is persisted or current
/// filesystem text, and a crafted directory name could otherwise inject
/// terminal escape sequences into the picker and listing.
pub fn project(summary: &Summary) -> String {
    summary
        .cwd
        .as_deref()
        .map(|cwd| crate::sanitize_terminal_text(Path::new(cwd).file_name().map_or(cwd, |n| n.to_str().unwrap_or(cwd))))
        .unwrap_or_else(|| "?".into())
}

/// One line of prompt text: whitespace (including newlines) collapsed, and
/// control characters dropped, since prompt text is echoed back into the
/// terminal by the picker and listing.
fn one_line(text: &str) -> String {
    crate::sanitize_terminal_text(&text.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// What the session was last about: the last prompt, and when that says
/// little, the more telling one before it.
pub fn topic(summary: &Summary) -> String {
    let last = one_line(summary.last_prompt.as_deref().unwrap_or_default());
    match &summary.context_prompt {
        Some(context) => format!("{last}  ← {}", one_line(context)),
        None => last,
    }
}

/// Terminal-cell width of `text` (CJK and wide emoji count as two cells), so
/// rows are fitted the way the terminal renders them, not by char count.
fn cells(text: &str) -> usize {
    text.chars().map(|c| UnicodeWidthChar::width(c).unwrap_or(0)).sum()
}

/// `text` fitted to at most `width` terminal cells, with an ellipsis when
/// truncated. Never splits a wide glyph across the boundary.
fn truncate(text: &str, width: usize) -> String {
    if cells(text) <= width {
        return text.to_string();
    }
    let budget = width.saturating_sub(1);
    let mut out = String::new();
    let mut used = 0;
    for c in text.chars() {
        let w = UnicodeWidthChar::width(c).unwrap_or(0);
        if used + w > budget {
            break;
        }
        out.push(c);
        used += w;
    }
    out.push('…');
    out
}

/// A picker or list row, fitted to `width` columns.
pub fn row(summary: &Summary, now: DateTime<FixedOffset>, width: usize) -> String {
    let prompts = if summary.prompts == 1 { "1 prompt".to_string() } else { format!("{} prompts", summary.prompts) };
    let head = format!("{:<10} {:>11}  ", ago(summary.last_used, now), prompts);
    let text = format!("{}  {}", project(summary), topic(summary));
    fit_row(head, &text, width)
}

/// `head` plus `text` truncated so the whole row fits `width` cells.
fn fit_row(head: String, text: &str, width: usize) -> String {
    let room = width.saturating_sub(cells(&head));
    format!("{head}{}", truncate(text, room))
}

/// Let the user pick a session in the terminal: this directory's sessions
/// first, with an entry to show all. `None` when cancelled or there is
/// nothing to resume.
pub fn pick(dir: &Path, cwd: &str) -> Result<Option<String>> {
    let sessions = session_index::list(dir)?;
    if sessions.is_empty() {
        eprintln!("No saved sessions to resume.");
        return Ok(None);
    }
    let now = crate::session::now();
    let width = crate::status::terminal_size().map_or(100, |(_, cols)| cols as usize);
    // Room for the picker's own marker and padding.
    let width = width.saturating_sub(4).max(40);
    let mut show_all = in_dir(&sessions, cwd).is_empty();
    loop {
        let shown: Vec<&Summary> = if show_all { sessions.iter().collect() } else { in_dir(&sessions, cwd) };
        let mut items: Vec<String> = shown.iter().map(|s| row(s, now, width)).collect();
        let hidden = sessions.len() - shown.len();
        if hidden > 0 {
            items.push(format!("Show all sessions ({hidden} more in other directories)"));
        }
        let prompt = if show_all {
            "Resume which session? (type to filter, Esc to cancel)".to_string()
        } else {
            format!("Resume which session in {}? (type to filter, Esc to cancel)", crate::sanitize_terminal_text(cwd))
        };
        let choice = dialoguer::FuzzySelect::with_theme(&dialoguer::theme::ColorfulTheme::default())
            .with_prompt(prompt)
            .items(&items)
            .default(0)
            .max_length(15)
            .interact_opt()?;
        match choice {
            None => return Ok(None),
            Some(i) if i == shown.len() => show_all = true,
            Some(i) => return Ok(Some(shown[i].id.clone())),
        }
    }
}

/// `--list-sessions` and `--resume` without a terminal: one row per session
/// (this directory's unless `all`), or JSON summaries.
pub fn print_list(dir: &Path, cwd: &str, all: bool, json: bool) -> Result<()> {
    let sessions = session_index::list(dir)?;
    let shown: Vec<&Summary> = if all { sessions.iter().collect() } else { in_dir(&sessions, cwd) };
    // Write errors (a closed pipe, as with `| head`) just end the listing.
    let mut out = std::io::stdout().lock();
    if json {
        let _ = writeln!(out, "{}", serde_json::to_string_pretty(&shown)?);
        return Ok(());
    }
    if shown.is_empty() {
        let scope = if all {
            String::new()
        } else {
            format!(" for {} (--all lists every directory)", crate::sanitize_terminal_text(cwd))
        };
        eprintln!("No saved sessions{scope}.");
        return Ok(());
    }
    let now = crate::session::now();
    for summary in shown {
        // The id comes from a log header, which a crafted log can fill with
        // control characters; sanitize it for the terminal (JSON stays raw).
        if writeln!(out, "{}  {}", crate::sanitize_terminal_text(&summary.id), row(summary, now, 100)).is_err() {
            break;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Record, SessionLog};
    use chrono::Duration;

    fn summary(id: &str, cwd: Option<&str>, last: &str, context: Option<&str>) -> Summary {
        Summary {
            id: id.into(),
            cwd: cwd.map(Into::into),
            model: None,
            created_at: None,
            last_used: crate::session::now(),
            prompts: 3,
            first_prompt: None,
            last_prompt: Some(last.into()),
            context_prompt: context.map(Into::into),
            log_bytes: 0,
        }
    }

    #[test]
    fn ago_is_brief() {
        let now = crate::session::now();
        assert_eq!(ago(now, now), "just now");
        assert_eq!(ago(now - Duration::minutes(5), now), "5m ago");
        assert_eq!(ago(now - Duration::hours(3), now), "3h ago");
        assert_eq!(ago(now - Duration::hours(30), now), "yesterday");
        assert_eq!(ago(now - Duration::days(4), now), "4d ago");
        let old = now - Duration::days(40);
        assert_eq!(ago(old, now), old.with_timezone(&Local).format("%b %-d").to_string());
    }

    #[test]
    fn row_shows_project_count_and_topic() {
        let s = summary("s", Some("/work/rusty-harness"), "do it\nnow", Some("Fix the flaky\n deploy test"));
        let row = row(&s, crate::session::now(), 200);
        assert!(row.starts_with("just now     3 prompts  rusty-harness"), "{row}");
        assert!(row.contains("rusty-harness  do it now  ← Fix the flaky deploy test"), "{row}");
        let narrow = super::row(&s, crate::session::now(), 70);
        assert!(narrow.ends_with('…') && super::cells(&narrow) <= 70, "{narrow}");
        assert_eq!(project(&summary("s", None, "x", None)), "?");
    }

    #[test]
    fn row_fits_narrow_and_wide_text() {
        let s = summary("s", Some("/w"), "Fix the flaky deploy test in CI", None);
        // A narrow terminal truncates rather than wrapping or overflowing.
        let narrow = row(&s, crate::session::now(), 30);
        assert!(super::cells(&narrow) <= 30, "{narrow}");
        // CJK text measures two cells per glyph, so the row still fits.
        let wide = summary("s", Some("/work/プロジェクト"), "修正テストを直す", None);
        let row = row(&wide, crate::session::now(), 40);
        assert!(super::cells(&row) <= 40, "{row}");
    }

    #[test]
    fn project_and_topic_drop_control_characters() {
        let s = summary("s", Some("/work/evil\u{1b}[2J"), "hi\u{1b}]8;;x\u{7}", None);
        assert_eq!(project(&s), "evil[2J");
        assert_eq!(topic(&s), "hi]8;;x");
    }

    #[test]
    fn errors_and_plain_ids_drop_control_characters() {
        // `--resume last` from a crafted directory name cannot inject escapes.
        let dir = tempfile::tempdir().unwrap();
        let err = last(dir.path(), "/work/evil\u{1b}[2J").unwrap_err().to_string();
        assert!(err.contains("no saved session for /work/evil[2J"), "{err}");
        assert!(!err.contains('\u{1b}'), "{err}");
        // A crafted session id is sanitized by the same helper for plain output.
        assert_eq!(crate::sanitize_terminal_text("s\u{1b}[2J"), "s[2J");
    }

    #[test]
    fn directory_view_includes_unknown_cwd() {
        let sessions = [
            summary("here", Some("/a"), "x", None),
            summary("there", Some("/b"), "x", None),
            summary("old", None, "x", None),
        ];
        let ids: Vec<&str> = in_dir(&sessions, "/a").iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, ["here", "old"]);
    }

    #[test]
    fn last_requires_a_session_from_this_directory() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create_with(dir.path(), "s", Some("/a".into()), None).unwrap();
        let input = Record::Input { id: "i".into(), text: "hello there".into(), recorded_at: crate::session::now() };
        log.append(&input).unwrap();
        assert_eq!(last(dir.path(), "/a").unwrap(), "s");
        assert!(last(dir.path(), "/b").unwrap_err().to_string().contains("no saved session for /b"));
    }
}
