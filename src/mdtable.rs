//! Terminal rendering of GitHub-flavoured markdown tables in assistant text.
//!
//! Models often answer with pipe tables, which are hard to read as raw
//! `| a | b |` rows. This finds table blocks (a header row, a delimiter row
//! such as `|---|:--:|`, then body rows) and lays them out as a box-drawn grid
//! sized to the terminal: cells wrap when the grid is too wide, and when even
//! wrapped columns can't fit, each row is shown as a stacked `Header: value`
//! record instead. Everything else in the text is left untouched, as are
//! tables inside code fences or indented code.
//!
//! Only the terminal display changes: callers keep the original markdown for
//! the session log, ACP, piped output and `-p`.
//!
//! [`render`] transforms a whole message (the frame renderer re-renders its
//! items on every change, so it simply re-runs this). [`TableStream`] is for
//! output that streams straight to the terminal and can't be retracted: it
//! passes text through as it arrives, except for lines that could belong to a
//! table, which it holds until the table ends and then emits laid out.

use unicode_width::UnicodeWidthChar;

const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const RESET: &str = "\x1b[0m";

/// Narrowest a column is squeezed to before switching to the stacked layout
/// (a column whose content is narrower keeps its natural width).
const MIN_COL: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Align {
    Left,
    Center,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Table {
    header: Vec<String>,
    aligns: Vec<Align>,
    rows: Vec<Vec<String>>,
}

// --- Parsing ----------------------------------------------------------------

/// Leading spaces, or `None` when the line is indented code (4+ spaces or a tab).
fn indent(line: &str) -> Option<usize> {
    let n = line.len() - line.trim_start_matches(' ').len();
    if n > 3 || line[n..].starts_with('\t') { None } else { Some(n) }
}

/// Split a table row into its cells, or `None` when the line is not a row (no
/// unescaped pipe outside a code span). Leading and trailing pipes are
/// optional; `\|` is a literal pipe, and pipes inside `` `code` `` don't split.
fn parse_row(line: &str) -> Option<Vec<String>> {
    let line = &line[indent(line)?..];
    let line = line.trim_end();
    if line.is_empty() {
        return None;
    }
    let mut cells = Vec::new();
    let mut cur = String::new();
    let mut pipes = 0;
    let mut chars = line.chars().peekable();
    // The length of the backtick run that opened the current code span.
    let mut code: Option<usize> = None;
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&'|') => {
                cur.push('|');
                chars.next();
            }
            '`' => {
                let mut run = 1;
                while chars.peek() == Some(&'`') {
                    chars.next();
                    run += 1;
                }
                match code {
                    None => code = Some(run),
                    Some(open) if open == run => code = None,
                    Some(_) => {}
                }
                cur.extend(std::iter::repeat_n('`', run));
            }
            '|' if code.is_none() => {
                pipes += 1;
                cells.push(std::mem::take(&mut cur));
            }
            _ => cur.push(c),
        }
    }
    cells.push(cur);
    if pipes == 0 {
        return None;
    }
    // A leading or trailing pipe delimits the row rather than an empty cell.
    if line.starts_with('|') {
        cells.remove(0);
    }
    if line.ends_with('|') && !line.ends_with("\\|") && cells.len() > 1 {
        cells.pop();
    }
    Some(cells.into_iter().map(|c| c.trim().to_string()).collect())
}

/// The column alignments of a delimiter row (`|---|:--:|--:|`), or `None`.
fn parse_delimiter(line: &str) -> Option<Vec<Align>> {
    let cells = parse_row(line)?;
    cells
        .iter()
        .map(|cell| {
            let left = cell.starts_with(':');
            let right = cell.ends_with(':') && cell.len() > 1;
            let dashes = cell.trim_start_matches(':').trim_end_matches(':');
            if dashes.is_empty() || !dashes.chars().all(|c| c == '-') {
                return None;
            }
            Some(match (left, right) {
                (true, true) => Align::Center,
                (false, true) => Align::Right,
                _ => Align::Left,
            })
        })
        .collect()
}

/// A table whose header and delimiter are `header` and `delimiter`, or `None`
/// when they don't form one (the cell counts must match, as in GFM).
fn start_table(header: &str, delimiter: &str) -> Option<Table> {
    let header = parse_row(header)?;
    let aligns = parse_delimiter(delimiter)?;
    (header.len() == aligns.len()).then(|| Table { header, aligns, rows: Vec::new() })
}

impl Table {
    /// Add a body row, padding or truncating it to the header's width.
    fn push(&mut self, mut row: Vec<String>) {
        row.resize(self.header.len(), String::new());
        self.rows.push(row);
    }
}

/// Whether `line` opens or closes a fenced code block.
fn fence(line: &str) -> Option<&'static str> {
    let t = &line[indent(line)?..];
    if t.starts_with("```") {
        Some("```")
    } else if t.starts_with("~~~") {
        Some("~~~")
    } else {
        None
    }
}

// --- Layout -----------------------------------------------------------------

fn char_width(c: char) -> usize {
    UnicodeWidthChar::width(c).unwrap_or(0)
}

fn width(s: &str) -> usize {
    s.chars().map(char_width).sum()
}

/// A cell's display text: emphasis and code markers removed, controls dropped
/// (cells are model text), so widths are measured on what is actually shown.
fn cell_text(raw: &str) -> String {
    let mut s = raw.replace("**", "").replace("__", "").replace("<br>", " ").replace("<br/>", " ");
    s = s.replace('`', "");
    s.chars().filter(|c| !c.is_control()).collect()
}

/// Word-wrap `text` to `w` cells, hard-breaking words that don't fit.
fn wrap(text: &str, w: usize) -> Vec<String> {
    let w = w.max(1);
    let mut lines = Vec::new();
    let mut cur = String::new();
    let mut cur_w = 0;
    for word in text.split_whitespace() {
        let ww = width(word);
        if cur_w > 0 && cur_w + 1 + ww <= w {
            cur.push(' ');
            cur.push_str(word);
            cur_w += 1 + ww;
            continue;
        }
        if cur_w > 0 {
            lines.push(std::mem::take(&mut cur));
            cur_w = 0;
        }
        if ww <= w {
            cur.push_str(word);
            cur_w = ww;
            continue;
        }
        for c in word.chars() {
            let cw = char_width(c);
            if cur_w + cw > w && cur_w > 0 {
                lines.push(std::mem::take(&mut cur));
                cur_w = 0;
            }
            cur.push(c);
            cur_w += cw;
        }
    }
    if cur_w > 0 || lines.is_empty() {
        lines.push(cur);
    }
    lines
}

fn pad(text: &str, w: usize, align: Align) -> String {
    let gap = w.saturating_sub(width(text));
    let (l, r) = match align {
        Align::Left => (0, gap),
        Align::Right => (gap, 0),
        Align::Center => (gap / 2, gap - gap / 2),
    };
    format!("{}{text}{}", " ".repeat(l), " ".repeat(r))
}

/// Column widths that fit `avail` cells of content, or `None` when even the
/// narrowest acceptable columns don't fit.
fn fit_columns(natural: &[usize], avail: usize) -> Option<Vec<usize>> {
    let floor: Vec<usize> = natural.iter().map(|&n| n.min(MIN_COL)).collect();
    if floor.iter().sum::<usize>() > avail {
        return None;
    }
    let mut widths = natural.to_vec();
    // Shrink the widest column one cell at a time, so wide columns give up
    // space before narrow ones.
    while widths.iter().sum::<usize>() > avail {
        let (i, _) = widths.iter().enumerate().filter(|(i, w)| **w > floor[*i]).max_by_key(|(_, w)| **w)?;
        widths[i] -= 1;
    }
    Some(widths)
}

fn border(widths: &[usize], left: char, mid: char, right: char) -> String {
    let segs: Vec<String> = widths.iter().map(|w| "─".repeat(w + 2)).collect();
    format!("{DIM}{left}{}{right}{RESET}", segs.join(&mid.to_string()))
}

fn grid_rows(cells: &[String], widths: &[usize], aligns: &[Align], bold: bool) -> Vec<String> {
    let wrapped: Vec<Vec<String>> = cells.iter().zip(widths).map(|(c, w)| wrap(c, *w)).collect();
    let height = wrapped.iter().map(Vec::len).max().unwrap_or(1);
    let bar = format!("{DIM}│{RESET}");
    (0..height)
        .map(|i| {
            let parts: Vec<String> = wrapped
                .iter()
                .zip(widths)
                .zip(aligns)
                .map(|((lines, w), a)| {
                    let text = pad(lines.get(i).map_or("", String::as_str), *w, *a);
                    if bold && !text.trim().is_empty() { format!("{BOLD}{text}{RESET}") } else { text }
                })
                .collect();
            format!("{bar} {} {bar}", parts.join(&format!(" {bar} ")))
        })
        .collect()
}

/// Lay a table out in at most `max_width` cells per line.
fn layout(table: &Table, max_width: usize) -> Vec<String> {
    let header: Vec<String> = table.header.iter().map(|c| cell_text(c)).collect();
    let rows: Vec<Vec<String>> = table.rows.iter().map(|r| r.iter().map(|c| cell_text(c)).collect()).collect();
    let n = header.len();
    let natural: Vec<usize> = (0..n)
        .map(|i| {
            std::iter::once(&header[i]).chain(rows.iter().map(|r| &r[i])).map(|c| width(c)).max().unwrap_or(0).max(1)
        })
        .collect();
    // `│ a │ b │`: two spaces and a bar per column, plus the closing bar.
    let chrome = 3 * n + 1;
    if let Some(widths) = max_width.checked_sub(chrome).and_then(|avail| fit_columns(&natural, avail)) {
        let mut out = vec![border(&widths, '┌', '┬', '┐')];
        out.extend(grid_rows(&header, &widths, &table.aligns, true));
        out.push(border(&widths, '├', '┼', '┤'));
        for row in &rows {
            out.extend(grid_rows(row, &widths, &table.aligns, false));
        }
        out.push(border(&widths, '└', '┴', '┘'));
        return out;
    }
    stacked(&header, &rows, max_width)
}

/// The narrow-terminal layout: each row as a block of `Header: value` lines,
/// values wrapped under themselves, blocks separated by a rule.
fn stacked(header: &[String], rows: &[Vec<String>], max_width: usize) -> Vec<String> {
    let label_w = header.iter().map(|h| width(h)).max().unwrap_or(0).min(max_width / 3);
    let value_w = max_width.saturating_sub(label_w + 2).max(1);
    let rule = format!("{DIM}{}{RESET}", "─".repeat(max_width.clamp(1, 40)));
    let mut out = Vec::new();
    for (r, row) in rows.iter().enumerate() {
        if r > 0 {
            out.push(rule.clone());
        }
        for (h, v) in header.iter().zip(row) {
            let labels = wrap(h, label_w.max(1));
            let values = wrap(v, value_w);
            for i in 0..labels.len().max(values.len()) {
                let label = pad(labels.get(i).map_or("", String::as_str), label_w, Align::Left);
                let value = values.get(i).map_or("", String::as_str);
                let colon = if i == 0 { ":" } else { " " };
                out.push(format!("{BOLD}{label}{RESET}{DIM}{colon}{RESET} {value}").trim_end().to_string());
            }
        }
    }
    if rows.is_empty() {
        out.push(format!("{BOLD}{}{RESET}", header.join(" · ")));
    }
    out
}

// --- Whole-text rendering ---------------------------------------------------

/// `text` with every markdown table laid out for a terminal `width` cells
/// wide. Text that contains no table is returned unchanged.
pub fn render(text: &str, width: usize) -> String {
    if !text.contains('|') {
        return text.to_string();
    }
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    let mut fenced: Option<&str> = None;
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if let Some(open) = fenced {
            if fence(line) == Some(open) {
                fenced = None;
            }
            out.push(line.to_string());
            i += 1;
            continue;
        }
        if let Some(f) = fence(line) {
            fenced = Some(f);
            out.push(line.to_string());
            i += 1;
            continue;
        }
        if let Some(mut table) = lines.get(i + 1).and_then(|next| start_table(line, next)) {
            let mut j = i + 2;
            while let Some(row) = lines.get(j).and_then(|l| parse_row(l)) {
                table.push(row);
                j += 1;
            }
            out.extend(layout(&table, width.max(10)));
            i = j;
            continue;
        }
        out.push(line.to_string());
        i += 1;
    }
    out.join("\n")
}

// --- Streaming --------------------------------------------------------------

/// Renders tables in text that arrives in fragments and is printed as it
/// arrives. Ordinary text passes straight through. A line that starts with a
/// pipe is held back, since it may be a table's header; it is released raw as
/// soon as the next line shows it isn't one, or kept with the rows that follow
/// until the table ends, then emitted laid out. (A table without a leading
/// pipe can't be recognised before its rows have already been printed, so
/// streamed output only lays out pipe-led tables, which is how models write
/// them; [`render`] handles both.)
#[derive(Default)]
pub struct TableStream {
    /// Complete lines held back (each without its newline).
    held: Vec<String>,
    /// The current, incomplete line while it is held or undecided.
    line: String,
    /// The current line is being passed through (it can't be a table row).
    passing: bool,
    /// Inside a fenced code block (`Some(fence)`): everything passes through.
    fenced: Option<&'static str>,
}

impl TableStream {
    /// Feed a fragment; returns the text that can be printed now.
    pub fn push(&mut self, text: &str, width: usize) -> String {
        let mut out = String::new();
        for c in text.chars() {
            if self.passing {
                out.push(c);
                if c == '\n' {
                    self.passing = false;
                }
                continue;
            }
            if c == '\n' {
                self.end_line(&mut out, width);
                continue;
            }
            self.line.push(c);
            if self.fenced.is_some() {
                continue; // decided at the end of the line
            }
            if c == ' ' && self.line.len() <= 3 {
                continue; // still undecided: leading spaces
            }
            if c == '|' && self.line.trim_start() == "|" {
                continue; // a candidate row: keep holding
            }
            if self.line.trim_start().starts_with('|') {
                continue; // the rest of a held row
            }
            // This line can't be a table row: the held table (if any) ends.
            self.release(&mut out, width);
            if self.line_could_open_fence() {
                continue; // decided at the end of the line
            }
            out.push_str(&std::mem::take(&mut self.line));
            self.passing = true;
        }
        out
    }

    /// The text still held at the end of the message, laid out if it is a
    /// table. Leaves the stream ready for the next message.
    pub fn finish(&mut self, width: usize) -> String {
        let mut out = String::new();
        let partial = std::mem::take(&mut self.line);
        if !partial.is_empty() && !self.passing {
            if parse_row(&partial).is_some() && !self.held.is_empty() {
                self.held.push(partial);
                self.release(&mut out, width);
                // The message ended without a newline; don't add one.
                if out.ends_with('\n') {
                    out.pop();
                }
            } else {
                self.release(&mut out, width);
                out.push_str(&partial);
            }
        } else {
            self.release(&mut out, width);
        }
        *self = Self::default();
        out
    }

    /// Whether anything is held back (e.g. a table still being collected).
    pub fn holding(&self) -> bool {
        !self.held.is_empty() || (!self.passing && !self.line.is_empty())
    }

    // A line that begins with a fence marker is decided at its end (so the
    // fence state is tracked), rather than passed through character by
    // character.
    fn line_could_open_fence(&self) -> bool {
        let t = self.line.trim_start();
        t.starts_with('`') || t.starts_with('~')
    }

    fn end_line(&mut self, out: &mut String, width: usize) {
        let line = std::mem::take(&mut self.line);
        if let Some(open) = self.fenced {
            if fence(&line) == Some(open) {
                self.fenced = None;
            }
            out.push_str(&line);
            out.push('\n');
            return;
        }
        if let Some(f) = fence(&line) {
            self.release(out, width);
            self.fenced = Some(f);
            out.push_str(&line);
            out.push('\n');
            return;
        }
        if !line.trim_start().starts_with('|') || parse_row(&line).is_none() {
            self.release(out, width);
            out.push_str(&line);
            out.push('\n');
            return;
        }
        self.held.push(line);
        // With a header and a second line, either it's a table, or the first
        // line was ordinary text: release it and treat the second line as a
        // possible header in turn.
        if self.held.len() == 2 && start_table(&self.held[0], &self.held[1]).is_none() {
            let first = self.held.remove(0);
            out.push_str(&first);
            out.push('\n');
        }
    }

    /// Emit the held lines: laid out if they form a table, else verbatim.
    fn release(&mut self, out: &mut String, width: usize) {
        let held = std::mem::take(&mut self.held);
        if held.is_empty() {
            return;
        }
        if held.len() >= 2
            && let Some(mut table) = start_table(&held[0], &held[1])
        {
            for row in &held[2..] {
                if let Some(cells) = parse_row(row) {
                    table.push(cells);
                }
            }
            for line in layout(&table, width.max(10)) {
                out.push_str(&line);
                out.push('\n');
            }
            return;
        }
        for line in held {
            out.push_str(&line);
            out.push('\n');
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for n in chars.by_ref() {
                    if n == 'm' {
                        break;
                    }
                }
                continue;
            }
            out.push(c);
        }
        out
    }

    const TABLE: &str = "| Name | Size |\n|---|--:|\n| alpha | 1 |\n| beta | 22 |";

    #[test]
    fn parses_rows_with_escapes_code_and_optional_pipes() {
        assert_eq!(parse_row("| a | b |").unwrap(), ["a", "b"]);
        assert_eq!(parse_row("a | b").unwrap(), ["a", "b"]);
        assert_eq!(parse_row("| a \\| b | c |").unwrap(), ["a | b", "c"]);
        assert_eq!(parse_row("| `x | y` | c |").unwrap(), ["`x | y`", "c"]);
        assert_eq!(parse_row("| only |").unwrap(), ["only"]);
        assert!(parse_row("no pipes here").is_none());
        assert!(parse_row("    | indented | code |").is_none());
        assert!(parse_row("").is_none());
    }

    #[test]
    fn parses_delimiter_alignment() {
        assert_eq!(
            parse_delimiter("|:--|:-:|--:|---|").unwrap(),
            [Align::Left, Align::Center, Align::Right, Align::Left]
        );
        assert!(parse_delimiter("| a | --- |").is_none());
        assert!(parse_delimiter("| :: |").is_none());
        assert!(start_table("| a | b |", "|---|").is_none(), "cell counts must match");
    }

    #[test]
    fn renders_a_grid_with_alignment() {
        let out = plain(&render(TABLE, 80));
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(
            lines,
            [
                "┌───────┬──────┐",
                "│ Name  │ Size │",
                "├───────┼──────┤",
                "│ alpha │    1 │",
                "│ beta  │   22 │",
                "└───────┴──────┘",
            ]
        );
    }

    #[test]
    fn surrounding_text_is_untouched() {
        let text = format!("Here:\n\n{TABLE}\n\nDone | maybe.");
        let out = plain(&render(&text, 80));
        assert!(out.starts_with("Here:\n\n┌"), "{out}");
        assert!(out.ends_with("┘\n\nDone | maybe."), "{out}");
        assert_eq!(render("no table", 80), "no table");
    }

    #[test]
    fn tables_in_code_fences_stay_raw() {
        let text = format!("```\n{TABLE}\n```");
        assert_eq!(render(&text, 80), text);
        let tilde = format!("~~~md\n{TABLE}\n~~~\n{TABLE}");
        let out = plain(&render(&tilde, 80));
        assert!(out.contains("| Name | Size |") && out.contains("┌"), "{out}");
    }

    #[test]
    fn ragged_rows_are_padded_and_trimmed() {
        let out = plain(&render("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |", 80));
        assert!(out.contains("│ 1 │   │"), "{out}");
        assert!(out.contains("│ 1 │ 2 │") && !out.contains('3'), "{out}");
    }

    #[test]
    fn markup_is_stripped_and_widths_are_cell_widths() {
        let out = plain(&render("| **k** | `v` |\n|---|---|\n| 日本 | é |", 80));
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[1], "│ k    │ v │");
        assert_eq!(lines[3], "│ 日本 │ é │");
        for l in &lines {
            assert_eq!(width(l), width(lines[0]), "{l}");
        }
    }

    #[test]
    fn wide_tables_wrap_cells_to_fit() {
        let long = "word ".repeat(30);
        let text = format!("| key | description |\n|---|---|\n| a | {long} |");
        let out = plain(&render(&text, 40));
        assert!(out.lines().count() > 6, "{out}");
        for l in out.lines() {
            assert!(width(l) <= 40, "{l} ({})", width(l));
        }
        assert!(out.contains("│ a   │ word word"), "{out}");
    }

    #[test]
    fn too_narrow_falls_back_to_stacked_records() {
        let text = "| one | two | three | four | five | six |\n|---|---|---|---|---|---|\n| aaaaaaa | bbbbbbb | c | d | e | f |\n| g | h | i | j | k | l |";
        let out = plain(&render(text, 30));
        assert!(!out.contains('┌'), "{out}");
        assert!(out.contains("one  : aaaaaaa"), "{out}");
        assert!(out.contains("six  : l"), "{out}");
        assert!(out.contains('─'), "records are separated: {out}");
        for l in out.lines() {
            assert!(width(l) <= 30, "{l}");
        }
    }

    #[test]
    fn grid_lines_never_exceed_width() {
        for w in [10, 20, 33, 50, 120] {
            let text = "| a | b | c |\n|---|---|---|\n| supercalifragilistic | x y z | 123456789012 |";
            for l in plain(&render(text, w)).lines() {
                assert!(width(l) <= w, "width {w}: {l}");
            }
        }
    }

    #[test]
    fn controls_in_cells_are_dropped() {
        let out = render("| a |\n|---|\n| x\x1b[2Jy |", 80);
        assert!(!out.contains("\x1b[2J"), "{out:?}");
    }

    fn stream(chunks: &[&str], width: usize) -> (String, Vec<String>) {
        let mut s = TableStream::default();
        let mut parts = Vec::new();
        for c in chunks {
            parts.push(s.push(c, width));
        }
        parts.push(s.finish(width));
        (parts.concat(), parts)
    }

    #[test]
    fn stream_passes_ordinary_text_through_immediately() {
        let (all, parts) = stream(&["Hello ", "wor", "ld\nnext line"], 80);
        assert_eq!(parts[0], "Hello ");
        assert_eq!(parts[1], "wor");
        assert_eq!(all, "Hello world\nnext line");
    }

    #[test]
    fn stream_holds_a_table_and_emits_it_laid_out() {
        let chunks = ["Intro\n", "| Name | Si", "ze |\n|---|--:|\n| alpha | 1 |\n", "| beta | 22 |\n", "\nAfter."];
        let (all, parts) = stream(&chunks, 80);
        assert_eq!(parts[0], "Intro\n");
        assert_eq!(parts[1], "", "a candidate header is held");
        assert_eq!(parts[2], "", "the table is held while rows arrive");
        assert_eq!(parts[3], "");
        assert_eq!(plain(&all), format!("Intro\n{}\n\nAfter.", plain(&render(TABLE, 80))));
    }

    #[test]
    fn stream_matches_whole_text_rendering_at_any_split() {
        let text = format!(
            "Before | not a table\n\n{TABLE}\ntext right after\n```\n{TABLE}\n```\n| x | y |\nnot a delimiter\n{TABLE}"
        );
        let whole = render(&text, 60);
        for size in [1, 2, 3, 7, 16] {
            let chars: Vec<char> = text.chars().collect();
            let chunks: Vec<String> = chars.chunks(size).map(|c| c.iter().collect()).collect();
            let refs: Vec<&str> = chunks.iter().map(String::as_str).collect();
            assert_eq!(stream(&refs, 60).0, whole, "chunk size {size}");
        }
    }

    #[test]
    fn stream_releases_a_pipe_line_that_is_not_a_table() {
        let (all, parts) = stream(&["| just a pipe line\n", "and more\n"], 80);
        assert_eq!(parts[0], "", "held until the next line decides");
        assert_eq!(parts[1], "| just a pipe line\nand more\n");
        assert_eq!(all, "| just a pipe line\nand more\n");
    }

    #[test]
    fn stream_finish_flushes_an_unfinished_table_or_header() {
        let (all, _) = stream(&["| a | b |\n|---|---|\n| 1 | 2 |"], 80);
        assert_eq!(plain(&all), plain(&render("| a | b |\n|---|---|\n| 1 | 2 |", 80)));
        let (all, _) = stream(&["| a | b"], 80);
        assert_eq!(all, "| a | b", "an incomplete header comes out raw");
        let mut s = TableStream::default();
        s.push("| a |\n", 80);
        assert!(s.holding());
        s.finish(80);
        assert!(!s.holding());
    }
}
