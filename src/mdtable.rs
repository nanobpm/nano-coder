//! Terminal layout of markdown tables.
//!
//! [`crate::markdown`] parses a table into a [`Table`] of plain-text cells;
//! [`layout`] draws it as a box-drawn grid sized to the terminal. Cells wrap
//! when the grid is too wide (the widest columns shrink first), and when even
//! wrapped columns can't fit, each row is shown as a stacked `Header: value`
//! record instead.

use unicode_width::UnicodeWidthChar;

const DIM: &str = "\x1b[2m";
const BOLD: &str = "\x1b[1m";
const RESET: &str = "\x1b[0m";

/// Narrowest a column is squeezed to before switching to the stacked layout
/// (a column whose content is narrower keeps its natural width).
const MIN_COL: usize = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Align {
    Left,
    Center,
    Right,
}

/// A table of plain-text cells. Body rows may be ragged; [`layout`] pads them.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Table {
    pub header: Vec<String>,
    pub aligns: Vec<Align>,
    pub rows: Vec<Vec<String>>,
}

// --- Layout -----------------------------------------------------------------

fn char_width(c: char) -> usize {
    UnicodeWidthChar::width(c).unwrap_or(0)
}

pub fn width(s: &str) -> usize {
    s.chars().map(char_width).sum()
}

/// A cell's display text: controls dropped (cells are model text), so widths
/// are measured on what is actually shown.
fn cell_text(raw: &str) -> String {
    raw.chars().map(|c| if c == '\n' || c == '\t' { ' ' } else { c }).filter(|c| !c.is_control()).collect()
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
pub fn layout(table: &Table, max_width: usize) -> Vec<String> {
    let header: Vec<String> = table.header.iter().map(|c| cell_text(c)).collect();
    let n = header.len();
    let rows: Vec<Vec<String>> = table
        .rows
        .iter()
        .map(|r| {
            let mut row: Vec<String> = r.iter().take(n).map(|c| cell_text(c)).collect();
            row.resize(n, String::new());
            row
        })
        .collect();
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
