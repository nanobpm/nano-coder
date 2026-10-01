//! Choosing a session to resume: `--resume` without an ID, `--resume last`,
//! and `--list-sessions`.

use std::fmt;
use std::io::Write;
use std::path::Path;

use anyhow::{Context, Result, bail};
use chrono::{DateTime, FixedOffset, Local};
use dialoguer::theme::{ColorfulTheme, Theme};
use fuzzy_matcher::skim::SkimMatcherV2;
use unicode_width::UnicodeWidthStr;

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
/// Measured with `UnicodeWidthStr` (not a per-`char` sum): `unicode-width`
/// only resolves emoji presentation / variation-selector / ZWJ sequences at
/// the string level, so `"#\u{fe0f}"` is two cells as a string but its chars
/// sum to one — a per-`char` sum would undercount and let a row wrap.
fn cells(text: &str) -> usize {
    UnicodeWidthStr::width(text)
}

/// `text` fitted to at most `width` terminal cells, with an ellipsis when
/// truncated. Never splits a wide glyph across the boundary.
fn truncate(text: &str, width: usize) -> String {
    // A zero budget (the picker on a 1–4-column terminal, after
    // `saturating_sub(4)`) cannot hold even the one-cell ellipsis, so the
    // only string that fits is empty — honour the at-most-`width` contract.
    if width == 0 {
        return String::new();
    }
    if cells(text) <= width {
        return text.to_string();
    }
    let budget = width.saturating_sub(1);
    let mut out = String::new();
    for c in text.chars() {
        // Measure the whole candidate prefix with `UnicodeWidthStr`, not this
        // char's width in isolation: a variation selector or ZWJ joins with
        // the preceding scalar, so a per-scalar budget check would admit a
        // sequence that pushes the string past `budget` and make the final
        // ellipsis exceed `width`.
        out.push(c);
        if cells(&out) > budget {
            out.pop();
            break;
        }
    }
    out.push('…');
    out
}

/// A dialoguer theme that renders each picker row fitted to the terminal
/// width while fuzzy matching still sees the row's full text. `FuzzySelect`
/// matches against and renders the same item string, so passing the full
/// (untruncated) row lets a keyword anywhere in a long prompt find the
/// session — but dialoguer renders the item verbatim and would let a long row
/// wrap. This theme truncates only the rendered label, so matching stays
/// full-text while no drawn row exceeds the terminal.
///
/// Each item carries a hidden `\0<id>` disambiguator (see `pick`); it is
/// stripped here before rendering so the id never reaches the terminal.
struct FitTheme {
    inner: ColorfulTheme,
    width: usize,
}

impl Theme for FitTheme {
    fn format_fuzzy_select_prompt_item(
        &self,
        f: &mut dyn fmt::Write,
        text: &str,
        active: bool,
        highlight_matches: bool,
        matcher: &SkimMatcherV2,
        search_term: &str,
    ) -> fmt::Result {
        // Render the width-fitted label (the hidden id suffix removed); the
        // full `text` still reaches dialoguer's matcher for filtering.
        self.inner.format_fuzzy_select_prompt_item(
            f,
            &truncate(label_of(text), self.width),
            active,
            highlight_matches,
            matcher,
            search_term,
        )
    }
}

/// The separator between a picker item's visible label and its hidden,
/// uniquifying session-id suffix. `NUL` can never appear in a label: prompt,
/// project, and cwd text are all run through `sanitize_terminal_text`, which
/// drops control characters.
const ITEM_ID_SEP: char = '\u{0}';

/// The visible portion of a picker item string (everything before the hidden
/// `\0<id>` disambiguator added in `pick`).
fn label_of(item: &str) -> &str {
    item.split(ITEM_ID_SEP).next().unwrap_or(item)
}

/// A picker or list row, fitted to `width` columns: when last used, the
/// project, the prompt count, then the last prompt — the order the README and
/// `--list-sessions` document. The whole row (the fixed header included) is
/// truncated to `width`, so an item never exceeds the terminal, even one
/// narrower than that header.
pub fn row(summary: &Summary, now: DateTime<FixedOffset>, width: usize) -> String {
    let prompts = if summary.prompts == 1 { "1 prompt".to_string() } else { format!("{} prompts", summary.prompts) };
    let line = format!("{:<10}  {}  {}  {}", ago(summary.last_used, now), project(summary), prompts, topic(summary));
    truncate(&line, width)
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
    // The picker renders on stderr (dialoguer) and is gated on stdin/stderr
    // being terminals, so measure the stderr terminal — stdout may be
    // redirected, and its width would not reflect where the rows are drawn.
    let width = crate::status::stderr_terminal_size().map_or(100, |(_, cols)| cols as usize);
    // Use the actual available width (less the picker's own marker and
    // padding) so no row is wider than the terminal, even a narrow one.
    let width = width.saturating_sub(4);
    let theme = FitTheme { inner: ColorfulTheme::default(), width };
    // Start directory-scoped even when this directory has no sessions: the
    // documented behaviour (and the non-terminal list) is a directory-scoped
    // view whose "Show all sessions" entry is the explicit opt-in to every
    // directory. With no local rows that entry is the sole choice, so the
    // user still reaches all sessions — but only by asking for them, matching
    // `print_list` rather than bypassing the scoping outright.
    let mut show_all = false;
    loop {
        let shown: Vec<&Summary> = if show_all { sessions.iter().collect() } else { in_dir(&sessions, cwd) };
        // Give the picker the full row text so fuzzy matching can see a
        // keyword anywhere in a long prompt; the theme truncates only what is
        // rendered, so a row still never wraps the terminal. Append a hidden
        // `\0<id>` suffix so no two items are ever byte-identical: dialoguer
        // 0.11 maps the chosen row back to an index with
        // `items.iter().position(|i| i == selected)`, so two sessions that
        // render the same row (same relative time, project, count and topic)
        // would otherwise both resolve to the first one and resume the wrong
        // session. `FitTheme` strips the suffix before drawing, and ids are
        // unique, so each item is unique and `position` is exact.
        let mut items: Vec<String> =
            shown.iter().map(|s| format!("{}{ITEM_ID_SEP}{}", row(s, now, usize::MAX), s.id)).collect();
        let hidden = sessions.len() - shown.len();
        if hidden > 0 {
            items.push(format!("Show all sessions ({hidden} more in other directories)"));
        }
        let prompt = if show_all {
            "Resume which session? (type to filter, Esc to cancel)".to_string()
        } else {
            format!("Resume which session in {}? (type to filter, Esc to cancel)", crate::sanitize_terminal_text(cwd))
        };
        let choice = dialoguer::FuzzySelect::with_theme(&theme)
            .with_prompt(prompt)
            .items(&items)
            .default(0)
            .max_length(15)
            // Suppress dialoguer's post-selection confirmation: it re-renders
            // the chosen item through `format_input_prompt_selection` with the
            // full, untruncated row, bypassing `FitTheme`'s width-fitting, so a
            // long prompt would wrap past the terminal. The menu is cleared on
            // selection and the session resumes immediately, so the report adds
            // nothing but the wrap risk.
            .report(false)
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
    let mut out = std::io::stdout().lock();
    if json {
        // A closed pipe (`| head`) ends the listing quietly, but any other
        // write failure (EIO, ENOSPC mid-write) must surface: returning
        // success after one would hand scripts a truncated, invalid document.
        return match writeln!(out, "{}", serde_json::to_string_pretty(&shown)?) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
            Err(e) => Err(e).context("write session list"),
        };
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
        let line = writeln!(out, "{}  {}", crate::sanitize_terminal_text(&summary.id), row(summary, now, 100));
        match line {
            Ok(()) => {}
            // Only a closed pipe ends the listing quietly; other write errors
            // mean real output loss and must be returned, not swallowed.
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => break,
            Err(e) => return Err(e).context("write session list"),
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
        assert!(row.starts_with("just now    rusty-harness  3 prompts"), "{row}");
        assert!(row.contains("3 prompts  do it now  ← Fix the flaky deploy test"), "{row}");
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
    fn truncate_never_exceeds_width_even_zero() {
        // The at-most-`width` contract holds at the boundary: a zero budget
        // (a 1–4-column terminal) cannot hold even the ellipsis, so the only
        // fitting string is empty.
        assert_eq!(super::truncate("hello", 0), "");
        assert_eq!(super::truncate("", 0), "");
        // Width 1 fits just the ellipsis; width 2 fits one cell plus it.
        assert_eq!(super::cells(&super::truncate("hello", 1)), 1);
        let two = super::truncate("hello", 2);
        assert!(super::cells(&two) <= 2 && two.ends_with('…'), "{two}");
        // Untruncated text is returned as-is.
        assert_eq!(super::truncate("hi", 5), "hi");
    }

    #[test]
    fn truncate_counts_variation_selector_width_as_a_string() {
        // `"#\u{fe0f}"` is two terminal cells as a string (emoji
        // presentation), though its chars sum to one. `cells` must report the
        // string width, and `truncate` must not admit a sequence that pushes
        // the result past `width`.
        let emoji = "#\u{fe0f}x";
        assert_eq!(super::cells(emoji), 3);
        let fitted = super::truncate(emoji, 2);
        assert!(super::cells(&fitted) <= 2, "{fitted:?} exceeds width 2");
    }

    #[test]
    fn picker_items_are_unique_even_when_rows_render_identically() {
        // Two sessions that render the same row (same time/project/count/
        // topic) must still map back to distinct items: dialoguer resolves a
        // selection by `items.position(|i| i == chosen)`, so identical item
        // strings would both resolve to the first and resume the wrong id.
        let now = crate::session::now();
        let a = summary("sess-a", Some("/work/repo"), "same prompt", None);
        let b = summary("sess-b", Some("/work/repo"), "same prompt", None);
        let items: Vec<String> =
            [&a, &b].iter().map(|s| format!("{}{ITEM_ID_SEP}{}", row(s, now, usize::MAX), s.id)).collect();
        // The visible labels are identical...
        assert_eq!(label_of(&items[0]), label_of(&items[1]));
        // ...but the items themselves are not, so `position` is exact and the
        // hidden suffix never reaches the rendered label.
        assert_ne!(items[0], items[1]);
        assert_eq!(items.iter().position(|i| i == &items[1]), Some(1));
        assert!(!label_of(&items[1]).contains(ITEM_ID_SEP));
        assert!(!label_of(&items[1]).contains("sess-b"));
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
