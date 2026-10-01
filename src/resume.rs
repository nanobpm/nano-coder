//! Choosing a session to resume: `--resume` without an ID, `--resume last`,
//! and `--list-sessions`.

use std::fmt;
use std::io::Write;
use std::path::Path;

use anyhow::{Context, Result, bail};
use chrono::{DateTime, FixedOffset, Local};
use dialoguer::console::{Key, Term, truncate_str};
use dialoguer::theme::{ColorfulTheme, Theme};
use fuzzy_matcher::FuzzyMatcher;
use fuzzy_matcher::skim::SkimMatcherV2;
use unicode_width::UnicodeWidthStr;

use crate::session_index::{self, Summary};

/// Sessions that ran in `cwd`, plus those from older logs that don't say
/// where they ran.
pub fn in_dir<'a>(sessions: &'a [Summary], cwd: &str) -> Vec<&'a Summary> {
    sessions.iter().filter(|s| s.cwd.as_deref().is_none_or(|c| c == cwd)).collect()
}

/// The most recent session that ran in `cwd` (`--resume last`), other than
/// `exclude` (the session in use, for `/resume last`).
pub fn last(dir: &Path, cwd: &str, exclude: Option<&str>) -> Result<String> {
    let sessions = session_index::list(dir)?;
    match sessions.iter().find(|s| s.cwd.as_deref() == Some(cwd) && Some(s.id.as_str()) != exclude) {
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

/// Renders each picker row fitted to the terminal width while the selector's
/// fuzzy matcher still sees the row's full, untruncated text. Keeping the
/// searched text separate from the drawn text lets a keyword anywhere in a long
/// prompt find the session while no drawn row ever exceeds the terminal — and
/// it lets [`interactive_pick`] clear exactly the rows it drew. Delegating the
/// per-item formatting to `ColorfulTheme` preserves dialoguer's match
/// highlighting.
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
        // Fit the drawn label to the terminal; the selector matches the full
        // `text` itself, so filtering stays full-text while the row cannot wrap.
        self.inner.format_fuzzy_select_prompt_item(
            f,
            &truncate(text, self.width),
            active,
            highlight_matches,
            matcher,
            search_term,
        )
    }
}

/// Fuzzy-match every item's full text against `search`, returning the matching
/// items' indices (into `items`), best match first. An empty search keeps every
/// item; equal scores keep the input order (a stable sort), so the picker's
/// most-recent-first default survives until the user narrows it.
fn rank(matcher: &SkimMatcherV2, items: &[String], search: &str) -> Vec<usize> {
    let mut scored: Vec<(usize, i64)> =
        items.iter().enumerate().filter_map(|(i, t)| matcher.fuzzy_match(t, search).map(|s| (i, s))).collect();
    // A stable sort on the negated score keeps equal-score items in input order.
    scored.sort_by_key(|&(_, score)| std::cmp::Reverse(score));
    scored.into_iter().map(|(i, _)| i).collect()
}

/// The scroll offset (index of the first visible row) that keeps the selected
/// row inside a `max_visible`-row window, given the current offset.
fn scroll_top(top: usize, sel: usize, max_visible: usize) -> usize {
    if sel < top {
        sel
    } else if max_visible > 0 && sel >= top + max_visible {
        sel + 1 - max_visible
    } else {
        top
    }
}

/// How many terminal rows a written line occupies once the terminal wraps it at
/// `cols` columns. dialoguer's `FuzzySelect` ignores wrapping and clears by each
/// item's *byte* length instead, over-erasing the scrollback above a long row;
/// measuring the rendered width here is what makes `interactive_pick`'s clear
/// exact.
fn physical_rows(line: &str, cols: usize) -> usize {
    if cols == 0 {
        return 1;
    }
    dialoguer::console::measure_text_width(line).div_ceil(cols).max(1)
}

/// How many item rows fit beneath a `prompt_rows`-tall prompt in a `rows`-row
/// terminal, capped at `max_visible`. Zero when the prompt already fills the
/// screen: forcing a row there would make the frame (`prompt_rows + window`)
/// exceed `rows`, so `interactive_pick`'s `clear_last_lines(drawn)` would erase
/// scrollback above the picker.
fn item_window(rows: usize, prompt_rows: usize, max_visible: usize) -> usize {
    max_visible.min(rows.saturating_sub(prompt_rows))
}

/// Restores the terminal cursor on drop, so every early `?` return from
/// [`interactive_pick`] (clear/write/flush/read failures) still un-hides the
/// cursor instead of leaving the user's terminal with an invisible cursor.
struct CursorGuard<'a> {
    term: &'a Term,
}

impl Drop for CursorGuard<'_> {
    fn drop(&mut self) {
        let _ = self.term.show_cursor();
    }
}

/// Let the user fuzzy-filter `items` on the stderr terminal and pick one,
/// returning its index (or `None` on Esc / Ctrl-C). Unlike dialoguer's
/// `FuzzySelect`, the search runs over each item's full text while only a
/// terminal-fitted label is drawn, and the menu is cleared by its *rendered*
/// height — so a long row never corrupts the scrollback above the picker.
fn interactive_pick(
    prompt: &str,
    theme: &FitTheme,
    items: &[String],
    rows: usize,
    cols: usize,
    max_visible: usize,
) -> Result<Option<usize>> {
    let term = Term::stderr();
    let matcher = SkimMatcherV2::default();
    let mut search = String::new();
    let mut sel = 0usize; // index into the filtered list
    let mut top = 0usize; // first visible filtered row
    let mut drawn = 0usize; // physical rows drawn by the last frame

    term.hide_cursor()?;
    // Restore the cursor on *every* exit path, including an early `?` from any
    // clear/write/flush/read below, not only the normal return.
    let _cursor = CursorGuard { term: &term };
    let selected = loop {
        if drawn > 0 {
            term.clear_last_lines(drawn)?;
        }
        let filtered = rank(&matcher, items, &search);

        // Render the prompt first so its wrapped height is known, then reserve
        // those rows and show only as many items as still fit — keeping the
        // whole frame within the terminal so `clear_last_lines(drawn)` never
        // erases scrollback above the picker.
        let mut prompt_line = String::new();
        Theme::format_fuzzy_select_prompt(theme, &mut prompt_line, prompt, &search, search.len())?;
        // Cap the prompt to at most `rows` physical rows before measuring it:
        // it carries the full working directory and an unbounded search string,
        // so a long path or query can wrap past the terminal height on its own.
        // Left uncapped, that alone makes `drawn` exceed `rows` and the next
        // `clear_last_lines(drawn)` erase scrollback above the picker.
        // `truncate_str` is ANSI-aware, so it bounds the rendered width without
        // splitting the theme's colour escapes.
        let prompt_budget = rows.saturating_mul(cols);
        if prompt_budget > 0 && physical_rows(&prompt_line, cols) > rows {
            prompt_line = truncate_str(&prompt_line, prompt_budget, "…").into_owned();
        }
        let prompt_rows = physical_rows(&prompt_line, cols);
        // Reserve the prompt's rows and show only as many items as still fit,
        // allowing a *zero*-item window: when the prompt already fills the
        // terminal no item row fits, and forcing one (a trailing `.max(1)`)
        // would push the frame past `rows` and over-erase on the next clear.
        let window = item_window(rows, prompt_rows, max_visible);

        if filtered.is_empty() {
            sel = 0;
            top = 0;
        } else {
            sel = sel.min(filtered.len() - 1);
            top = scroll_top(top, sel, window);
        }

        let mut lines: Vec<String> = Vec::with_capacity(window + 1);
        lines.push(prompt_line);
        for (pos, &item) in filtered.iter().enumerate().skip(top).take(window) {
            let mut rendered = String::new();
            Theme::format_fuzzy_select_prompt_item(
                theme,
                &mut rendered,
                &items[item],
                pos == sel,
                true,
                &matcher,
                &search,
            )?;
            lines.push(rendered);
        }
        drawn = 0;
        for line in &lines {
            term.write_line(line)?;
            drawn += physical_rows(line, cols);
        }
        term.flush()?;

        match term.read_key()? {
            Key::Escape | Key::CtrlC => break None,
            Key::Enter if !filtered.is_empty() => break Some(filtered[sel]),
            Key::ArrowUp | Key::BackTab if !filtered.is_empty() => {
                sel = (sel + filtered.len() - 1) % filtered.len();
            }
            Key::ArrowDown | Key::Tab if !filtered.is_empty() => {
                sel = (sel + 1) % filtered.len();
            }
            Key::Backspace => {
                if search.pop().is_some() {
                    sel = 0;
                    top = 0;
                }
            }
            Key::Char(c) if !c.is_ascii_control() => {
                search.push(c);
                sel = 0;
                top = 0;
            }
            _ => {}
        }
    };
    // Clear the final frame so the menu leaves nothing behind, matching the old
    // `FuzzySelect::clear(true)` behaviour; `_cursor` then restores the cursor.
    if drawn > 0 {
        term.clear_last_lines(drawn)?;
    }
    Ok(selected)
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

/// A row prefixed with the session ID, for plain lists.
fn id_row(summary: &Summary, now: DateTime<FixedOffset>) -> String {
    // The id comes from a log header, which a crafted log can fill with
    // control characters; sanitize it for the terminal (JSON stays raw).
    format!("{}  {}", crate::sanitize_terminal_text(&summary.id), row(summary, now, 100))
}

/// Plain list rows (with IDs) of this directory's sessions, for `/resume`
/// without a terminal. `exclude` (the session in use) is left out, as in
/// `pick` and `last`.
pub fn list_rows(dir: &Path, cwd: &str, exclude: Option<&str>) -> Result<Vec<String>> {
    let sessions = session_index::list(dir)?;
    let now = crate::session::now();
    Ok(in_dir(&sessions, cwd).into_iter().filter(|s| Some(s.id.as_str()) != exclude).map(|s| id_row(s, now)).collect())
}

/// Let the user pick a session in the terminal: this directory's sessions
/// first, with an entry to show all. `exclude` (the session in use) is left
/// out. `None` when cancelled or there is nothing to resume.
pub fn pick(dir: &Path, cwd: &str, exclude: Option<&str>) -> Result<Option<String>> {
    Ok(match pick_outcome(dir, cwd, exclude)? {
        Pick::Selected(id) => Some(id),
        Pick::Cancelled | Pick::Empty => None,
    })
}

/// The picker result with the reason there is no selection: `Cancelled` is
/// Esc, `Empty` is "no saved sessions to resume" (nothing was ever shown).
/// Callers that repaint over the picker's stderr notice use this to keep the
/// two outcomes distinct.
pub enum Pick {
    Selected(String),
    Cancelled,
    Empty,
}

/// [`pick`], but reports *why* there is no selection.
pub fn pick_outcome(dir: &Path, cwd: &str, exclude: Option<&str>) -> Result<Pick> {
    let mut sessions = session_index::list(dir)?;
    sessions.retain(|s| Some(s.id.as_str()) != exclude);
    if sessions.is_empty() {
        eprintln!("No saved sessions to resume.");
        return Ok(Pick::Empty);
    }
    let now = crate::session::now();
    // The picker draws on stderr (console) and is gated on stdin/stderr being
    // terminals, so measure the stderr terminal — stdout may be redirected, and
    // its size would not reflect where the rows are drawn.
    let (rows, cols) = crate::status::stderr_terminal_size().map_or((24, 100), |(r, c)| (r as usize, c as usize));
    // Fit each row to the available width (less the picker's own marker and
    // padding) so none is wider than the terminal, even a narrow one.
    let width = cols.saturating_sub(4);
    // Leave two rows for the prompt line and cap the window like the old
    // `max_length(15)`, so a long list scrolls rather than filling the screen.
    let max_visible = rows.saturating_sub(2).clamp(1, 15);
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
        // Give the selector each row's full text so fuzzy matching can see a
        // keyword anywhere in a long prompt; `FitTheme` fits only what is drawn
        // and `interactive_pick` clears only the rows it drew, so a long row
        // neither wraps the terminal nor over-erases the scrollback above it.
        // Selection comes back by index, so two sessions that render an
        // identical row still map back to their own id — no disambiguator
        // suffix needed.
        let mut items: Vec<String> = shown.iter().map(|s| row(s, now, usize::MAX)).collect();
        let hidden = sessions.len() - shown.len();
        if hidden > 0 {
            items.push(format!("Show all sessions ({hidden} more in other directories)"));
        }
        let prompt = if show_all {
            "Resume which session? (type to filter, Esc to cancel)".to_string()
        } else {
            format!("Resume which session in {}? (type to filter, Esc to cancel)", crate::sanitize_terminal_text(cwd))
        };
        match interactive_pick(&prompt, &theme, &items, rows, cols, max_visible)? {
            None => return Ok(Pick::Cancelled),
            Some(i) if i == shown.len() => show_all = true,
            Some(i) => return Ok(Pick::Selected(shown[i].id.clone())),
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
        // id_row sanitizes the id, which comes from a log header a crafted log
        // can fill with control characters (JSON stays raw).
        let line = writeln!(out, "{}", id_row(summary, now));
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
    fn rank_keeps_recency_order_when_search_is_empty() {
        // An empty search must keep every item in input order (most-recent
        // first), so the picker opens on the same default as the list.
        let matcher = SkimMatcherV2::default();
        let items: Vec<String> = ["aaa", "bbb", "ccc"].iter().map(|s| s.to_string()).collect();
        assert_eq!(rank(&matcher, &items, ""), vec![0, 1, 2]);
    }

    #[test]
    fn rank_matches_full_row_text_and_drops_non_matches() {
        // Matching runs over each row's full text, so a keyword deep in a long
        // row still selects it; rows without the keyword are filtered out.
        let matcher = SkimMatcherV2::default();
        let items: Vec<String> =
            ["morning  acme  2 prompts  fix the parser bug", "evening  other  1 prompt  write docs"]
                .iter()
                .map(|s| s.to_string())
                .collect();
        assert_eq!(rank(&matcher, &items, "parser"), vec![0]);
        assert!(rank(&matcher, &items, "zzzzz").is_empty());
    }

    #[test]
    fn rank_returns_distinct_indices_for_identical_rows() {
        // Two sessions that render an identical row must still be addressable
        // by their own index: the selector returns the index, so the caller
        // maps it back to the right session id (no disambiguator suffix).
        let matcher = SkimMatcherV2::default();
        let items: Vec<String> = ["same row", "same row"].iter().map(|s| s.to_string()).collect();
        assert_eq!(rank(&matcher, &items, "same"), vec![0, 1]);
    }

    #[test]
    fn scroll_top_keeps_selection_in_the_window() {
        // Selecting above the window scrolls up to it; below scrolls down so
        // the selected row is the last visible one; inside leaves it put.
        assert_eq!(scroll_top(3, 1, 4), 1);
        assert_eq!(scroll_top(0, 6, 4), 3);
        assert_eq!(scroll_top(2, 3, 4), 2);
    }

    #[test]
    fn physical_rows_counts_terminal_wrapping() {
        // A line within the width is one row; one wider than the terminal
        // wraps to more — the accounting dialoguer's clear gets wrong.
        assert_eq!(physical_rows("short", 80), 1);
        assert_eq!(physical_rows(&"x".repeat(80), 80), 1);
        assert_eq!(physical_rows(&"x".repeat(81), 80), 2);
        assert_eq!(physical_rows("", 80), 1);
    }

    #[test]
    fn item_window_never_pushes_the_frame_past_the_terminal() {
        // Room to spare: the window is capped at `max_visible`.
        assert_eq!(item_window(24, 1, 15), 15);
        // The prompt leaves fewer rows than `max_visible`: shrink to the slack.
        assert_eq!(item_window(5, 2, 15), 3);
        // The prompt fills the terminal exactly, or wraps past it: zero items,
        // so `prompt_rows + window` can never exceed `rows` and the next clear
        // cannot erase scrollback above the picker.
        assert_eq!(item_window(3, 3, 15), 0);
        assert_eq!(item_window(3, 7, 15), 0);
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
        let err = last(dir.path(), "/work/evil\u{1b}[2J", None).unwrap_err().to_string();
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
        assert_eq!(last(dir.path(), "/a", None).unwrap(), "s");
        assert!(last(dir.path(), "/a", Some("s")).is_err(), "the session in use is skipped");
        assert!(last(dir.path(), "/b", None).unwrap_err().to_string().contains("no saved session for /b"));
    }

    #[test]
    fn list_rows_skips_the_session_in_use() {
        let dir = tempfile::tempdir().unwrap();
        for id in ["s", "t"] {
            let mut log = SessionLog::create_with(dir.path(), id, Some("/a".into()), None).unwrap();
            let input =
                Record::Input { id: "i".into(), text: "hello there".into(), recorded_at: crate::session::now() };
            log.append(&input).unwrap();
        }
        let rows = list_rows(dir.path(), "/a", None).unwrap();
        assert_eq!(rows.len(), 2, "{rows:?}");
        let rows = list_rows(dir.path(), "/a", Some("s")).unwrap();
        assert_eq!(rows.len(), 1, "the session in use is left out: {rows:?}");
        assert!(rows[0].starts_with("t  "), "{rows:?}");
    }

    #[test]
    fn pick_outcome_reports_empty_apart_from_cancelled() {
        let dir = tempfile::tempdir().unwrap();
        // Nothing saved at all: `Empty`, so the caller can say *why* instead
        // of the bare "Session unchanged" an Esc gets.
        assert!(matches!(pick_outcome(dir.path(), "/a", None).unwrap(), Pick::Empty));
        let mut log = SessionLog::create_with(dir.path(), "s", Some("/a".into()), None).unwrap();
        let input = Record::Input { id: "i".into(), text: "hello there".into(), recorded_at: crate::session::now() };
        log.append(&input).unwrap();
        // The only saved session is the one in use: still `Empty`.
        assert!(matches!(pick_outcome(dir.path(), "/a", Some("s")).unwrap(), Pick::Empty));
        // The Option-based wrapper keeps mapping both to `None`.
        assert_eq!(pick(dir.path(), "/a", Some("s")).unwrap(), None);
    }
}
