//! Terminal rendering of the markdown in assistant answers.
//!
//! `pulldown-cmark` parses the text (CommonMark plus GFM tables,
//! strikethrough and task lists) into a small block tree, which is drawn for
//! a terminal of a given width:
//! - headings in bold (level 1 also underlined);
//! - emphasis, strong, strikethrough and inline code styled, with markers
//!   removed;
//! - links as their text followed by the dimmed URL;
//! - fenced code verbatim between dimmed fence lines, so it copies cleanly;
//! - lists with bullets, numbers or task boxes, nested, with hanging indent;
//! - block quotes behind a dimmed bar, rules as a dimmed line;
//! - tables via [`crate::mdtable::layout`].
//!
//! Everything wraps to the width, measured in terminal cells. Control
//! characters in the model's text are dropped, so the only escape sequences
//! in the output are the styling added here.
//!
//! This only changes what the terminal shows: session logs, transcripts, ACP
//! and piped output keep the original markdown.
//!
//! [`render`] draws a whole message. The frame renderer redraws its items on
//! every change, so it just calls this again.

use crate::mdtable::{self, Align, Table};
use pulldown_cmark::{Alignment, CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use unicode_width::UnicodeWidthChar;

const DIM: &str = "\x1b[2m";
const RESET: &str = "\x1b[0m";

// Inline style bits.
const BOLD: u8 = 1;
const ITALIC: u8 = 2;
const CODE: u8 = 4;
const STRIKE: u8 = 8;
const UNDERLINE: u8 = 16;
const FAINT: u8 = 32;

fn sgr(style: u8) -> String {
    let mut codes = Vec::new();
    if style & BOLD != 0 {
        codes.push("1");
    }
    if style & FAINT != 0 {
        codes.push("2");
    }
    if style & ITALIC != 0 {
        codes.push("3");
    }
    if style & UNDERLINE != 0 {
        codes.push("4");
    }
    if style & STRIKE != 0 {
        codes.push("9");
    }
    if style & CODE != 0 {
        codes.push("36");
    }
    format!("\x1b[{}m", codes.join(";"))
}

fn styled(text: &str, style: u8) -> String {
    if style == 0 || text.is_empty() { text.to_string() } else { format!("{}{text}{RESET}", sgr(style)) }
}

fn options() -> Options {
    Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS
}

/// Model text with control characters removed; tabs become spaces.
fn clean(text: &str) -> String {
    text.chars().map(|c| if c == '\t' { ' ' } else { c }).filter(|c| *c == '\n' || !c.is_control()).collect()
}

fn char_width(c: char) -> usize {
    UnicodeWidthChar::width(c).unwrap_or(0)
}

// --- Block tree -------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
struct Span {
    text: String,
    style: u8,
}

#[derive(Debug, Clone, PartialEq)]
enum Block {
    Para(Vec<Span>),
    Heading(u8, Vec<Span>),
    Code { info: Option<String>, text: String },
    Quote(Vec<Block>),
    List { start: Option<u64>, items: Vec<Item>, tight: bool },
    Rule,
    Table(Table),
    Html(String),
}

#[derive(Debug, Clone, PartialEq)]
struct Item {
    task: Option<bool>,
    blocks: Vec<Block>,
}

/// An open container while the event stream is folded into blocks.
enum Node {
    Root(Vec<Block>),
    Quote(Vec<Block>),
    List { start: Option<u64>, items: Vec<Item>, loose: bool },
    Item { task: Option<bool>, blocks: Vec<Block>, inline: Vec<Span> },
    Para(Vec<Span>),
    Heading(u8, Vec<Span>),
    Code { info: Option<String>, text: String },
    Html(String),
    Table { table: Table, row: Vec<String>, cell: String },
}

struct Builder {
    stack: Vec<Node>,
    styles: Vec<u8>,
    /// Open links: the destination and the text seen so far.
    links: Vec<(String, String)>,
}

impl Builder {
    fn style(&self) -> u8 {
        self.styles.last().copied().unwrap_or(0)
    }

    fn push_style(&mut self, bits: u8) {
        let s = self.style() | bits;
        self.styles.push(s);
    }

    fn span(&mut self, text: &str, style: u8) {
        let text = clean(text);
        if text.is_empty() {
            return;
        }
        for (_, seen) in &mut self.links {
            seen.push_str(&text);
        }
        match self.stack.last_mut() {
            Some(Node::Para(spans)) | Some(Node::Heading(_, spans)) | Some(Node::Item { inline: spans, .. }) => {
                spans.push(Span { text, style })
            }
            Some(Node::Table { cell, .. }) => cell.push_str(&text),
            Some(Node::Code { text: code, .. }) => code.push_str(&text),
            Some(Node::Html(html)) => html.push_str(&text),
            // Text directly in a container (from a construct we don't model).
            _ => self.add_block(Block::Para(vec![Span { text, style }])),
        }
    }

    /// Move an item's loose inline text into a paragraph block, keeping order.
    fn flush_item_inline(&mut self) {
        if let Some(Node::Item { blocks, inline, .. }) = self.stack.last_mut()
            && !inline.is_empty()
        {
            blocks.push(Block::Para(std::mem::take(inline)));
        }
    }

    fn add_block(&mut self, block: Block) {
        self.flush_item_inline();
        match self.stack.last_mut() {
            Some(Node::Root(blocks)) | Some(Node::Quote(blocks)) | Some(Node::Item { blocks, .. }) => {
                blocks.push(block)
            }
            _ => {}
        }
    }

    fn start_block(&mut self, node: Node) {
        self.flush_item_inline();
        self.stack.push(node);
    }

    fn start(&mut self, tag: Tag) {
        match tag {
            Tag::Paragraph => {
                // A paragraph tag inside an item means the list is loose.
                if matches!(self.stack.last(), Some(Node::Item { .. }))
                    && let Some(Node::List { loose, .. }) = self.stack.iter_mut().rev().nth(1)
                {
                    *loose = true;
                }
                self.start_block(Node::Para(Vec::new()));
            }
            Tag::Heading { level, .. } => self.start_block(Node::Heading(level as u8, Vec::new())),
            Tag::BlockQuote(_) => self.start_block(Node::Quote(Vec::new())),
            Tag::CodeBlock(kind) => {
                let info = match kind {
                    CodeBlockKind::Fenced(info) => Some(clean(&info).trim().to_string()),
                    CodeBlockKind::Indented => None,
                };
                self.start_block(Node::Code { info, text: String::new() });
            }
            Tag::HtmlBlock => self.start_block(Node::Html(String::new())),
            Tag::List(start) => self.start_block(Node::List { start, items: Vec::new(), loose: false }),
            Tag::Item => self.stack.push(Node::Item { task: None, blocks: Vec::new(), inline: Vec::new() }),
            Tag::Table(aligns) => {
                let aligns = aligns
                    .iter()
                    .map(|a| match a {
                        Alignment::Center => Align::Center,
                        Alignment::Right => Align::Right,
                        _ => Align::Left,
                    })
                    .collect();
                self.start_block(Node::Table {
                    table: Table { aligns, ..Default::default() },
                    row: Vec::new(),
                    cell: String::new(),
                });
            }
            Tag::TableCell => {
                if let Some(Node::Table { cell, .. }) = self.stack.last_mut() {
                    cell.clear();
                }
            }
            Tag::Emphasis => self.push_style(ITALIC),
            Tag::Strong => self.push_style(BOLD),
            Tag::Strikethrough => self.push_style(STRIKE),
            Tag::Link { dest_url, .. } => {
                self.links.push((dest_url.to_string(), String::new()));
                self.push_style(UNDERLINE);
            }
            Tag::Image { .. } => {
                let s = self.style();
                self.span("[image: ", s | FAINT);
                self.push_style(FAINT);
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph
            | TagEnd::Heading(_)
            | TagEnd::BlockQuote(_)
            | TagEnd::CodeBlock
            | TagEnd::HtmlBlock
            | TagEnd::List(_)
            | TagEnd::Table => {
                self.flush_item_inline();
                let block = match self.stack.pop() {
                    Some(Node::Para(spans)) => Block::Para(spans),
                    Some(Node::Heading(level, spans)) => Block::Heading(level, spans),
                    Some(Node::Quote(blocks)) => Block::Quote(blocks),
                    Some(Node::Code { info, text }) => Block::Code { info, text },
                    Some(Node::Html(html)) => Block::Html(html),
                    Some(Node::List { start, items, loose }) => Block::List { start, items, tight: !loose },
                    Some(Node::Table { table, .. }) => Block::Table(table),
                    Some(other) => {
                        self.stack.push(other);
                        return;
                    }
                    None => return,
                };
                self.add_block(block);
            }
            TagEnd::Item => {
                self.flush_item_inline();
                if let Some(Node::Item { task, blocks, .. }) = self.stack.pop()
                    && let Some(Node::List { items, .. }) = self.stack.last_mut()
                {
                    items.push(Item { task, blocks });
                }
            }
            TagEnd::TableCell => {
                if let Some(Node::Table { row, cell, .. }) = self.stack.last_mut() {
                    row.push(cell.trim().to_string());
                }
            }
            TagEnd::TableHead | TagEnd::TableRow => {
                if let Some(Node::Table { table, row, .. }) = self.stack.last_mut() {
                    let row = std::mem::take(row);
                    if tag == TagEnd::TableHead { table.header = row } else { table.rows.push(row) }
                }
            }
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough => {
                self.styles.pop();
            }
            TagEnd::Link => {
                self.styles.pop();
                if let Some((url, text)) = self.links.pop() {
                    let bare = url.strip_prefix("mailto:").unwrap_or(&url);
                    if !url.is_empty() && text.trim() != url && text.trim() != bare {
                        let s = self.style();
                        self.span(&format!(" ({url})"), (s & !UNDERLINE) | FAINT);
                    }
                }
            }
            TagEnd::Image => {
                self.styles.pop();
                let s = self.style();
                self.span("]", s | FAINT);
            }
            _ => {}
        }
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(t) | Event::InlineMath(t) | Event::DisplayMath(t) => {
                let s = self.style();
                self.span(&t, s);
            }
            Event::Code(t) => {
                let s = self.style();
                self.span(&t, s | CODE);
            }
            Event::Html(t) | Event::InlineHtml(t) => {
                let tag = t.trim().to_ascii_lowercase();
                if matches!(tag.as_str(), "<br>" | "<br/>" | "<br />") {
                    self.span("\n", 0);
                } else {
                    let s = self.style();
                    self.span(&t, s);
                }
            }
            Event::SoftBreak => {
                let s = self.style();
                self.span(" ", s);
            }
            Event::HardBreak => self.span("\n", 0),
            Event::Rule => self.add_block(Block::Rule),
            Event::TaskListMarker(done) => {
                if let Some(Node::Item { task, .. }) = self.stack.last_mut() {
                    *task = Some(done);
                }
            }
            Event::FootnoteReference(label) => {
                let s = self.style();
                self.span(&format!("[^{label}]"), s);
            }
        }
    }
}

/// Whether `line` looks like a table delimiter row (`|---|:--:|`).
fn is_delimiter_row(line: &str) -> bool {
    let t = line.trim();
    t.contains('-') && t.contains('|') && t.chars().all(|c| matches!(c, '|' | '-' | ':' | ' '))
}

/// GitHub lets a table start right after a paragraph line ("Results:" then
/// the header row); CommonMark parsers, pulldown-cmark included, treat those
/// rows as paragraph text. Insert the blank line GitHub implies, outside
/// fenced code. Idempotent.
fn separate_tables(text: &str) -> std::borrow::Cow<'_, str> {
    if !text.contains('|') {
        return text.into();
    }
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out: Vec<&str> = Vec::with_capacity(lines.len() + 2);
    let mut fence: Option<String> = None;
    let mut changed = false;
    for (i, line) in lines.iter().enumerate() {
        let t = line.trim_start();
        if let Some(f) = &fence {
            if closes_fence(line, f) {
                fence = None;
            }
        } else if t.starts_with("```") || t.starts_with("~~~") {
            fence = Some(fence_run(line));
        } else if i > 0
            && line.contains('|')
            && !is_delimiter_row(line)
            && lines.get(i + 1).is_some_and(|next| is_delimiter_row(next))
        {
            let prev = lines[i - 1].trim();
            if !prev.is_empty() && !prev.contains('|') {
                out.push("");
                changed = true;
            }
        }
        out.push(line);
    }
    if changed { out.join("\n").into() } else { text.into() }
}

fn parse(text: &str) -> Vec<Block> {
    let mut b = Builder { stack: vec![Node::Root(Vec::new())], styles: Vec::new(), links: Vec::new() };
    for event in Parser::new_ext(&separate_tables(text), options()) {
        b.event(event);
    }
    // Close anything left open, innermost first.
    while b.stack.len() > 1 {
        match b.stack.last() {
            Some(Node::Item { .. }) => b.end(TagEnd::Item),
            Some(Node::List { .. }) => b.end(TagEnd::List(false)),
            _ => b.end(TagEnd::Paragraph),
        }
    }
    match b.stack.pop() {
        Some(Node::Root(blocks)) => blocks,
        _ => Vec::new(),
    }
}

// --- Rendering --------------------------------------------------------------

/// Lines being filled with styled words, wrapped at `width` cells.
struct Lines {
    width: usize,
    lines: Vec<String>,
    cur: String,
    cur_w: usize,
}

impl Lines {
    fn new(width: usize) -> Self {
        Self { width: width.max(1), lines: Vec::new(), cur: String::new(), cur_w: 0 }
    }

    fn newline(&mut self) {
        self.lines.push(std::mem::take(&mut self.cur));
        self.cur_w = 0;
    }

    /// Place one word (styled pieces, no whitespace), preceded by a space
    /// unless it starts a line. A word wider than the line is broken.
    fn word(&mut self, pieces: &[(String, u8)], space: bool) {
        let w: usize = pieces.iter().map(|(t, _)| t.chars().map(char_width).sum::<usize>()).sum();
        if w == 0 {
            return;
        }
        let gap = usize::from(space && self.cur_w > 0);
        if self.cur_w > 0 && self.cur_w + gap + w > self.width {
            self.newline();
        } else if gap == 1 {
            self.cur.push(' ');
            self.cur_w += 1;
        }
        for (text, style) in pieces {
            let mut run = String::new();
            for c in text.chars() {
                let cw = char_width(c);
                if self.cur_w + cw > self.width && self.cur_w > 0 {
                    self.cur.push_str(&styled(&std::mem::take(&mut run), *style));
                    self.newline();
                }
                run.push(c);
                self.cur_w += cw;
            }
            self.cur.push_str(&styled(&run, *style));
        }
    }

    fn finish(mut self) -> Vec<String> {
        if self.cur_w > 0 || self.lines.is_empty() {
            self.newline();
        }
        self.lines
    }
}

/// Word-wrap styled spans to `width`; `extra` style bits apply to every span.
fn wrap_spans(spans: &[Span], width: usize, extra: u8) -> Vec<String> {
    let mut lines = Lines::new(width);
    let mut word: Vec<(String, u8)> = Vec::new();
    let mut space = false;
    let flush = |lines: &mut Lines, word: &mut Vec<(String, u8)>, space: &mut bool| {
        if !word.is_empty() {
            lines.word(word, *space);
            word.clear();
            *space = false;
        }
    };
    for span in spans {
        let style = span.style | extra;
        let mut piece = String::new();
        for c in span.text.chars() {
            if c == '\n' {
                if !piece.is_empty() {
                    word.push((std::mem::take(&mut piece), style));
                }
                flush(&mut lines, &mut word, &mut space);
                lines.newline();
                space = false;
            } else if c.is_whitespace() {
                if !piece.is_empty() {
                    word.push((std::mem::take(&mut piece), style));
                }
                flush(&mut lines, &mut word, &mut space);
                space = true;
            } else {
                piece.push(c);
            }
        }
        if !piece.is_empty() {
            word.push((piece, style));
        }
    }
    flush(&mut lines, &mut word, &mut space);
    lines.finish()
}

/// A verbatim line (code, HTML), broken at `width` cells rather than wrapped.
fn hard_lines(line: &str, width: usize, style: u8) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut w = 0;
    for c in line.chars() {
        let cw = char_width(c);
        if w + cw > width && w > 0 {
            out.push(styled(&std::mem::take(&mut cur), style));
            w = 0;
        }
        cur.push(c);
        w += cw;
    }
    out.push(styled(&cur, style));
    out
}

fn fence_open(info: &str) -> String {
    format!("{DIM}```{info}{RESET}")
}

fn fence_close() -> String {
    format!("{DIM}```{RESET}")
}

fn code_lines(text: &str, width: usize) -> Vec<String> {
    let text = text.strip_suffix('\n').unwrap_or(text);
    if text.is_empty() {
        return Vec::new();
    }
    text.split('\n').flat_map(|l| hard_lines(l, width, 0)).collect()
}

fn prefix_lines(lines: Vec<String>, first: &str, rest: &str) -> Vec<String> {
    lines
        .into_iter()
        .enumerate()
        .map(|(i, l)| {
            let p = if i == 0 { first } else { rest };
            if l.is_empty() && i > 0 { String::new() } else { format!("{p}{l}") }
        })
        .collect()
}

const BULLETS: [&str; 3] = ["•", "◦", "▪"];

fn render_blocks(blocks: &[Block], width: usize, depth: usize, separate: bool) -> Vec<String> {
    let mut out = Vec::new();
    for (i, block) in blocks.iter().enumerate() {
        if i > 0 && separate {
            out.push(String::new());
        }
        out.extend(render_block(block, width, depth));
    }
    out
}

fn render_block(block: &Block, width: usize, depth: usize) -> Vec<String> {
    let width = width.max(1);
    match block {
        Block::Para(spans) => wrap_spans(spans, width, 0),
        Block::Heading(level, spans) => wrap_spans(spans, width, if *level == 1 { BOLD | UNDERLINE } else { BOLD }),
        Block::Code { info: Some(info), text } => {
            let mut out = vec![fence_open(info)];
            out.extend(code_lines(text, width));
            out.push(fence_close());
            out
        }
        Block::Code { info: None, text } => {
            code_lines(text, width.saturating_sub(4).max(1)).into_iter().map(|l| format!("    {l}")).collect()
        }
        Block::Quote(blocks) => {
            let bar = format!("{DIM}│{RESET} ");
            let inner = render_blocks(blocks, width.saturating_sub(2).max(1), depth, true);
            inner.into_iter().map(|l| format!("{bar}{l}")).collect()
        }
        Block::List { start, items, tight } => {
            let mut out = Vec::new();
            for (i, item) in items.iter().enumerate() {
                if i > 0 && !tight {
                    out.push(String::new());
                }
                let box_ = item.task.map(|done| if done { "☑" } else { "☐" });
                let marker = match (start, box_) {
                    (Some(n), Some(b)) => format!("{}. {b}", n + i as u64),
                    (Some(n), None) => format!("{}.", n + i as u64),
                    (None, Some(b)) => b.to_string(),
                    (None, None) => BULLETS[depth % BULLETS.len()].to_string(),
                };
                let marker_w = mdtable::width(&marker) + 1;
                let marker = if start.is_none() && box_.is_none() { format!("{DIM}{marker}{RESET}") } else { marker };
                let mut body = render_blocks(&item.blocks, width.saturating_sub(marker_w).max(1), depth + 1, !tight);
                if body.is_empty() {
                    body.push(String::new());
                }
                out.extend(prefix_lines(body, &format!("{marker} "), &" ".repeat(marker_w)));
            }
            out
        }
        Block::Rule => vec![format!("{DIM}{}{RESET}", "─".repeat(width))],
        Block::Table(table) => {
            if table.header.is_empty() {
                Vec::new()
            } else {
                mdtable::layout(table, width)
            }
        }
        Block::Html(html) => html.trim_end().split('\n').flat_map(|l| hard_lines(l, width, FAINT)).collect(),
    }
}

/// The lines of `text` drawn for a terminal `width` cells wide.
fn render_lines(text: &str, width: usize) -> Vec<String> {
    render_blocks(&parse(text), width.max(10), 0, true)
}

/// `text` rendered for a terminal `width` cells wide (no trailing newline).
pub fn render(text: &str, width: usize) -> String {
    render_lines(text, width).join("\n")
}

/// [`render`], memoised: the frame renderer redraws the whole transcript on
/// every streamed delta, and re-parsing each settled message every time adds
/// up in long sessions. Keyed by the text's hash and the width; the cache is
/// dropped wholesale when it grows large (a width change re-renders everything
/// anyway).
pub fn render_cached(text: &str, width: usize) -> String {
    use std::collections::HashMap;
    use std::hash::{Hash, Hasher};
    thread_local! {
        static CACHE: std::cell::RefCell<HashMap<(u64, usize, usize), String>> = Default::default();
    }
    let mut h = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut h);
    let key = (h.finish(), text.len(), width);
    if let Some(hit) = CACHE.with(|c| c.borrow().get(&key).cloned()) {
        return hit;
    }
    let out = render(text, width);
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.len() >= 1024 {
            c.clear();
        }
        c.insert(key, out.clone());
    });
    out
}

/// The run of backticks or tildes that opens a fence line.
fn fence_run(line: &str) -> String {
    let t = line.trim_start();
    let Some(c) = t.chars().next() else { return String::new() };
    t.chars().take_while(|x| *x == c).collect()
}

fn closes_fence(line: &str, fence: &str) -> bool {
    let t = line.trim();
    let c = fence.chars().next().unwrap_or('`');
    t.len() >= fence.len() && t.chars().all(|x| x == c)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars();
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

    fn show(text: &str, width: usize) -> Vec<String> {
        render_lines(text, width).iter().map(|l| plain(l)).collect()
    }

    fn w(s: &str) -> usize {
        mdtable::width(&plain(s))
    }

    #[test]
    fn cached_rendering_matches_and_tracks_width() {
        let text = "Some **bold** text that wraps";
        assert_eq!(render_cached(text, 12), render(text, 12));
        assert_eq!(render_cached(text, 12), render(text, 12));
        assert_eq!(render_cached(text, 40), render(text, 40));
    }

    #[test]
    fn inline_markup_is_styled_and_markers_removed() {
        let out = render("Some **bold**, *italic*, ~~gone~~ and `code`.", 80);
        assert_eq!(plain(&out), "Some bold, italic, gone and code.");
        assert!(out.contains("\x1b[1mbold\x1b[0m"), "{out:?}");
        assert!(out.contains("\x1b[3mitalic\x1b[0m"), "{out:?}");
        assert!(out.contains("\x1b[9mgone\x1b[0m"), "{out:?}");
        assert!(out.contains("\x1b[36mcode\x1b[0m"), "{out:?}");
        assert!(out.contains("\x1b[1;3mboth\x1b[0m") || render("***both***", 80).contains("\x1b[1;3mboth"), "nested");
    }

    #[test]
    fn headings_paragraphs_and_rules() {
        assert_eq!(
            show("# Title\n\nText here.\n\n---\n\n## Sub", 20),
            ["Title", "", "Text here.", "", &"─".repeat(20), "", "Sub"]
        );
        assert!(render("# T", 80).contains("\x1b[1;4mT"), "h1 bold+underline");
        assert!(render("### T", 80).contains("\x1b[1mT"));
    }

    #[test]
    fn paragraphs_wrap_and_soft_breaks_reflow() {
        let out = show("one two three\nfour five six seven", 12);
        assert_eq!(out, ["one two", "three four", "five six", "seven"]);
        assert_eq!(show("a  \nb", 80), ["a", "b"], "hard break");
        assert_eq!(show("x<br>y", 80), ["x", "y"]);
        for l in show(&"supercalifragilisticexpialidocious ".repeat(3), 10) {
            assert!(w(&l) <= 10, "{l}");
        }
    }

    #[test]
    fn links_show_their_url_unless_it_is_the_text() {
        assert_eq!(show("see [docs](https://x.dev/d) now", 80), ["see docs (https://x.dev/d) now"]);
        assert_eq!(show("<https://x.dev>", 80), ["https://x.dev"]);
        assert_eq!(show("![logo](a.png)", 80), ["[image: logo]"]);
    }

    #[test]
    fn lists_nest_with_bullets_numbers_and_tasks() {
        let text = "- one\n- two\n  - inner\n    - deep\n- three\n\n3. c\n4. d\n\n- [ ] todo\n- [x] done";
        assert_eq!(
            show(text, 80),
            ["• one", "• two", "  ◦ inner", "    ▪ deep", "• three", "", "3. c", "4. d", "", "☐ todo", "☑ done"]
        );
    }

    #[test]
    fn list_items_wrap_with_a_hanging_indent() {
        assert_eq!(show("- alpha beta gamma delta", 14), ["• alpha beta", "  gamma delta"]);
        assert_eq!(show("10. alpha beta gamma", 13), ["10. alpha", "    beta", "    gamma"]);
    }

    #[test]
    fn loose_lists_keep_blank_lines() {
        assert_eq!(show("- a\n\n- b\n\n  more", 80), ["• a", "", "• b", "", "  more"]);
    }

    #[test]
    fn code_blocks_are_verbatim_between_dim_fences() {
        let out = show("```rust\nfn main() {\n    **not bold**\n}\n```\nafter", 80);
        assert_eq!(out, ["```rust", "fn main() {", "    **not bold**", "}", "```", "", "after"]);
        assert_eq!(show("    indented\n    code", 80), ["    indented", "    code"]);
        let long = format!("```\n{}\n```", "x".repeat(25));
        assert_eq!(show(&long, 10)[1..4], ["xxxxxxxxxx", "xxxxxxxxxx", "xxxxx"]);
    }

    #[test]
    fn block_quotes_get_a_bar() {
        assert_eq!(show("> quoted **text**\n> more\n\n> - item", 80), ["│ quoted text more", "", "│ • item"]);
    }

    #[test]
    fn controls_in_model_text_are_dropped() {
        let out = render("evil \x1b[2J text\x07 and `co\x1bde`", 80);
        assert!(!out.contains("\x1b[2J") && !out.contains('\x07'), "{out:?}");
        assert!(!render("```\n\x1b]0;title\x07\n```", 80).contains("\x1b]"));
    }

    // Tables (the layout itself is in `mdtable`).

    const TABLE: &str = "| Name | Size |\n|---|--:|\n| alpha | 1 |\n| beta | 22 |";

    #[test]
    fn tables_render_as_grids_with_alignment() {
        assert_eq!(
            show(TABLE, 80),
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
    fn table_cells_handle_escapes_code_markup_and_wide_chars() {
        // GFM: a pipe inside a code span must still be escaped.
        let out = show("| **k** | `a\\|b` | c \\| d |\n|---|---|---|\n| 日本 | é | x |", 80);
        assert_eq!(out[1], "│ k    │ a|b │ c | d │");
        assert_eq!(out[3], "│ 日本 │ é   │ x     │");
        assert!(out.iter().all(|l| w(l) == w(&out[0])), "{out:?}");
    }

    #[test]
    fn ragged_table_rows_are_padded_and_trimmed() {
        let out = show("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |", 80);
        assert!(out.contains(&"│ 1 │   │".to_string()), "{out:?}");
        assert!(out.contains(&"│ 1 │ 2 │".to_string()) && !out.concat().contains('3'), "{out:?}");
    }

    #[test]
    fn wide_tables_wrap_then_stack() {
        let long = "word ".repeat(30);
        let out = show(&format!("| key | description |\n|---|---|\n| a | {long} |"), 40);
        assert!(out.len() > 6 && out.iter().all(|l| w(l) <= 40), "{out:?}");
        assert!(out[3].starts_with("│ a   │ word word"), "{out:?}");
        let text = "| one | two | three | four | five | six |\n|---|---|---|---|---|---|\n| aaaaaaa | bbbbbbb | c | d | e | f |";
        let out = show(text, 30);
        assert!(!out.concat().contains('┌') && out.contains(&"one  : aaaaaaa".to_string()), "{out:?}");
    }

    #[test]
    fn a_table_may_follow_a_paragraph_line_directly() {
        let out = show("Results:\n| a | b |\n|---|---|\n| 1 | 2 |", 80);
        assert_eq!(out[..3], ["Results:", "", "┌───┬───┐"]);
        // Not inside code, and only before a real header + delimiter pair.
        assert_eq!(show("```\nx\n| a |\n|---|\n```", 80)[2], "| a |");
        assert_eq!(show("a | b\nc | d", 80), ["a | b c | d"]);
    }

    #[test]
    fn tables_in_code_and_lists() {
        assert_eq!(show(&format!("```\n{TABLE}\n```"), 80)[1], "| Name | Size |");
        let out = show(&format!("- item\n\n  {}", TABLE.replace('\n', "\n  ")), 80);
        assert!(out.iter().any(|l| l == "  ┌───────┬──────┐"), "{out:?}");
    }

    #[test]
    fn every_line_fits_the_width() {
        let text = format!(
            "# A heading that is fairly long\n\n> quote with words {}\n\n- list {}\n  1. nested {}\n\n{TABLE}\n\n```\n{}\n```",
            "w ".repeat(40),
            "x ".repeat(40),
            "y ".repeat(40),
            "z".repeat(90)
        );
        for width in [10, 17, 30, 80] {
            for l in render_lines(&text, width) {
                assert!(w(&l) <= width, "width {width}: {l:?}");
            }
        }
    }
}
