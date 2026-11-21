/// Terminal rendering of the markdown in assistant answers (markdown.rs).
///
/// The text (CommonMark plus GFM tables, strikethrough and task lists) is
/// parsed into a small block tree (`nano.mdblock`, `nano.mdinline`), which is
/// drawn for a terminal of a given width:
/// - headings in bold (level 1 also underlined);
/// - emphasis, strong, strikethrough and inline code styled, with markers
///   removed;
/// - links as their text followed by the dimmed URL;
/// - fenced code verbatim between dimmed fence lines, so it copies cleanly;
/// - lists with bullets, numbers or task boxes, nested, with hanging indent;
/// - block quotes behind a dimmed bar, rules as a dimmed line;
/// - tables via `nano.mdtable.layout`.
///
/// Everything wraps to the width, measured in terminal cells. Control
/// characters in the model's text are dropped, so the only escape sequences
/// in the output are the styling added here.
///
/// This only changes what the terminal shows: session logs, transcripts, ACP
/// and piped output keep the original markdown. Rust's frame renderer keeps
/// typed items and re-renders whole messages; D's transcript is the printed
/// lines, so the console streams answers through `MarkdownStream` (the path
/// Rust used for its retired legacy renderer).
module nano.markdown;

@safe:
pure:

import std.array : appender, join, replicate, split;
import std.format : format;
import std.string : indexOf, lastIndexOf, strip, stripLeft;
import std.uni : isWhite;
import nano.lineedit : charWidth;
import nano.frame : softWrapMark, verbatimMark, sepWrapMark;
import nano.mdblock;
import nano.mdinline;
import nano.mdtable : layout, textWidth = width;

private enum DIM = "\x1b[2m", RESET = "\x1b[0m";

private string sgr(ubyte style) pure nothrow
{
    string[] codes;
    if (style & BOLD) codes ~= "1";
    if (style & FAINT) codes ~= "2";
    if (style & ITALIC) codes ~= "3";
    if (style & UNDERLINE) codes ~= "4";
    if (style & STRIKE) codes ~= "9";
    if (style & CODE) codes ~= "36";
    return "\x1b[" ~ codes.join(";") ~ "m";
}

private string styled(string text, ubyte style) pure
{
    return style == 0 || !text.length ? text : sgr(style) ~ text ~ RESET;
}

/// GitHub lets a table start right after a paragraph line ("Results:" then
/// the header row); CommonMark treats those rows as paragraph text. Insert
/// the blank line GitHub implies, outside fenced code. Idempotent.
string separateTables(string text) pure
{
    if (text.indexOf('|') < 0) return text;
    auto lines = text.split("\n");
    string[] out_;
    string fence;
    bool changed;
    foreach (i, line; lines)
    {
        auto t = line.stripLeft;
        if (fence.length) { if (closesFence(line, fence)) fence = null; }
        else if (t.length >= 3 && (t[0 .. 3] == "```" || t[0 .. 3] == "~~~")) fence = fenceRun(line);
        else if (i > 0 && line.indexOf('|') >= 0 && !isDelimiterRow(line) && i + 1 < lines.length && isDelimiterRow(lines[i + 1]))
        {
            auto prev = lines[i - 1].strip;
            if (prev.length && prev.indexOf('|') < 0) { out_ ~= ""; changed = true; }
        }
        out_ ~= line;
    }
    return changed ? out_.join("\n") : text;
}

private string[] sourceLines(string text) pure
{
    string[] lines;
    foreach (l; text.split("\n")) lines ~= expandIndent(l);
    return lines;
}

private Block[] parse(string text) pure
{
    Block[] blocks;
    foreach (p; parseLines(sourceLines(separateTables(text)))) blocks ~= p.block;
    return blocks;
}

// --- Rendering ---------------------------------------------------------------

private struct Piece { string text; ubyte style; }

/// Lines being filled with styled words, wrapped at `width` cells.
private struct Lines
{
    size_t width;
    string[] lines;
    string cur;
    size_t curW;

    /// Ends the line; `soft` marks the next one as its continuation (a wrap,
    /// not a break in the text), so the frame joins them for copying.
    void newline(bool soft = false) pure { lines ~= cur; cur = soft ? softWrapMark : null; curW = 0; }

    /// Whether the first visible glyph of `pieces` is double-width.
    static bool firstWide(const Piece[] pieces) pure
    {
        foreach (p; pieces) foreach (dchar c; p.text) if (charWidth(c)) return charWidth(c) > 1;
        return false;
    }

    /// Place one word (styled pieces, no whitespace), preceded by a space
    /// unless it starts a line. A word wider than the line is broken,
    /// except inline code: it starts its own row and is left whole, so the
    /// frame breaks it at the full terminal width as one soft-wrapped row and
    /// no alignment padding lands inside a copied path or identifier.
    void word(const Piece[] pieces, bool space) pure
    {
        size_t w;
        foreach (p; pieces) foreach (dchar c; p.text) w += charWidth(c);
        if (!w) return;
        bool hasCode;
        foreach (p; pieces) if (p.style & CODE) hasCode = true;
        size_t gap = space && curW > 0 ? 1 : 0;
        if (curW > 0 && curW + gap + w > width)
        {
            // A separator on the edge starts the next row, so a copy across
            // the wrap keeps it (a shorter row is padded with spaces anyway).
            auto full = curW >= width;
            // One cell short of the edge before a wide glyph, the separator
            // fits nowhere (the frame pads nothing there): it rides the next
            // row as a zero-cell mark the frame emits as a space.
            auto sep = gap && curW + 1 == width && firstWide(pieces);
            newline(true);
            if (sep) cur ~= sepWrapMark;
            else if (gap && full) { cur ~= ' '; curW = 1; }
        }
        else if (gap) { cur ~= ' '; curW++; }
        // A word with inline code that doesn't fit the rest of its row
        // (which it starts) is never broken here: the row is marked verbatim
        // so the frame breaks it by character at the full terminal width,
        // and no newline or alignment padding lands inside the token.
        immutable whole = hasCode && curW + w > width;
        if (whole) cur ~= verbatimMark;
        foreach (p; pieces)
        {
            string run;
            foreach (dchar c; p.text)
            {
                auto cw = charWidth(c);
                if (!whole && curW + cw > width && curW > 0)
                {
                    cur ~= styled(run, p.style);
                    run = null;
                    newline(true);
                }
                run ~= c;
                curW += cw;
            }
            cur ~= styled(run, p.style);
        }
    }

    string[] finish() pure
    {
        if (curW > 0 || !lines.length) newline();
        return lines;
    }
}

/// Word-wrap styled spans to `width`; `extra` style bits apply to every span.
private string[] wrapSpans(const Span[] spans, size_t width, ubyte extra) pure
{
    auto lines = Lines(width < 1 ? 1 : width);
    Piece[] word;
    bool space;
    void flush()
    {
        if (word.length)
        {
            lines.word(word, space);
            word = null;
            space = false;
        }
    }
    foreach (span; spans)
    {
        auto style = cast(ubyte)(span.style | extra);
        string piece;
        foreach (dchar c; span.text)
        {
            if (c == '\n')
            {
                if (piece.length) { word ~= Piece(piece, style); piece = null; }
                flush();
                lines.newline();
                space = false;
            }
            else if (isWhite(c))
            {
                if (piece.length) { word ~= Piece(piece, style); piece = null; }
                flush();
                space = true;
            }
            else piece ~= c;
        }
        if (piece.length) word ~= Piece(piece, style);
    }
    flush();
    return lines.finish();
}

/// A verbatim line (code, HTML). It isn't broken here: the frame breaks it
/// by character at the terminal's full width (`verbatimMark`), so the rows
/// after the first carry no indent or quote prefix and a copy is exact.
string[] hardLines(string line, size_t width, ubyte style) pure
{
    return [verbatimMark ~ styled(line, style)];
}

string fenceOpen(string info) pure nothrow { return DIM ~ "```" ~ info ~ RESET; }
string fenceClose() pure { return DIM ~ "```" ~ RESET; }

private string[] codeLines(string text, size_t width) pure
{
    if (text.length && text[$ - 1] == '\n') text = text[0 .. $ - 1];
    if (!text.length) return null;
    string[] out_;
    foreach (l; text.split("\n")) out_ ~= hardLines(l, width, 0);
    return out_;
}

private string[] prefixLines(string[] lines, string first, string rest) pure
{
    foreach (i, ref l; lines) l = !l.length && i > 0 ? "" : (i == 0 ? first : rest) ~ l;
    return lines;
}

private immutable string[] BULLETS = ["•", "◦", "▪"];

private string[] renderBlocks(const Block[] blocks, size_t width, size_t depth, bool separate) pure
{
    string[] out_;
    foreach (i, b; blocks)
    {
        if (i > 0 && separate) out_ ~= "";
        out_ ~= renderBlock(b, width, depth);
    }
    return out_;
}

private string[] renderBlock(const Block block, size_t width, size_t depth) pure
{
    if (width < 1) width = 1;
    final switch (block.kind)
    {
        case BK.para: return wrapSpans(block.spans, width, 0);
        case BK.heading: return wrapSpans(block.spans, width, block.level == 1 ? BOLD | UNDERLINE : BOLD);
        case BK.code:
            if (block.fenced) return [fenceOpen(block.info)] ~ codeLines(block.text, width) ~ fenceClose();
            string[] out_;
            // Verbatim like fenced code: the frame breaks each line by
            // character at the full width, so the indent stays on the first
            // row only and a copy is exact (wrapping at width-4 repeated the
            // indent on every continuation row).
            foreach (l; codeLines(block.text, width)) out_ ~= "    " ~ l;
            return out_;
        case BK.quote:
            string[] out_;
            foreach (l; renderBlocks(block.blocks, width > 3 ? width - 2 : 1, depth, true)) out_ ~= DIM ~ "│" ~ RESET ~ " " ~ l;
            return out_;
        case BK.list:
            string[] out_;
            foreach (i, item; block.items)
            {
                if (i > 0 && !block.tight) out_ ~= "";
                string box = item.task < 0 ? null : item.task ? "☑" : "☐";
                string marker = block.ordered ? format("%s.", block.start + i) ~ (box.length ? " " ~ box : "")
                    : box.length ? box : BULLETS[depth % BULLETS.length];
                auto markerW = textWidth(marker) + 1;
                if (!block.ordered && !box.length) marker = DIM ~ marker ~ RESET;
                auto body = renderBlocks(item.blocks, width > markerW + 1 ? width - markerW : 1, depth + 1, !block.tight);
                if (!body.length) body = [""];
                out_ ~= prefixLines(body, marker ~ " ", " ".replicate(markerW));
            }
            return out_;
        case BK.rule: return [DIM ~ "─".replicate(width) ~ RESET];
        case BK.table: return block.table.header.length ? layout(block.table, width) : null;
        case BK.html:
            string t = block.text;
            while (t.length && isWhite(t[$ - 1])) t = t[0 .. $ - 1];
            string[] out_;
            foreach (l; t.split("\n")) out_ ~= hardLines(l, width, FAINT);
            return out_;
    }
}

/// The lines of `text` drawn for a terminal `width` cells wide.
string[] renderLines(string text, size_t width) pure
{
    return renderBlocks(parse(text), width < 10 ? 10 : width, 0, true);
}

/// `text` rendered for a terminal `width` cells wide (no trailing newline).
string render(string text, size_t width) pure
{
    return renderLines(text, width).join("\n");
}

// --- Streaming ---------------------------------------------------------------

private enum Kind { list, fenced, single, other }

private struct TopBlock
{
    size_t start; // byte offset
    Kind kind;
    size_t[] items; // byte offsets of a list's items
}

/// The top-level blocks of `src`, in order, with where each starts.
private TopBlock[] topBlocks(string src) pure
{
    auto raw = src.split("\n");
    auto offsets = new size_t[raw.length];
    size_t at;
    foreach (i, l; raw) { offsets[i] = at; at += l.length + 1; }
    TopBlock[] out_;
    foreach (p; parseLines(sourceLines(src)))
    {
        auto k = p.block.kind;
        auto tb = TopBlock(offsets[p.start], k == BK.list ? Kind.list : k == BK.code && p.block.fenced ? Kind.fenced
            : k == BK.heading || k == BK.rule ? Kind.single : Kind.other);
        foreach (it; p.items) tb.items ~= offsets[it];
        out_ ~= tb;
    }
    return out_;
}

/// Renders markdown that arrives in fragments and is printed as it arrives,
/// for a terminal that can't take printed text back. Each top-level block is
/// emitted once a later block has started (a heading or rule as soon as its
/// line ends), list items as each one completes, fenced code a line at a
/// time, and whatever is left when the message ends.
struct MarkdownStream
{
    /// Source received but not yet emitted.
    private string src;
    /// Something has been emitted, so the next block is preceded by a blank line.
    private bool started;
    /// The last emission was the first items of a list whose remaining items
    /// come next, with no blank line between.
    private bool listCont;
    /// Inside a fenced code block: its opening fence run.
    private string code;

    /// Feed a fragment; returns the text that can be printed now.
    string push(string text, size_t width) pure
    {
        src ~= text;
        auto out_ = appender!string;
        if (text.indexOf('\n') >= 0) drain(out_, width < 10 ? 10 : width, false);
        return out_[];
    }

    /// Everything still held, rendered, at the end of a message. Leaves the
    /// stream ready for the next message.
    string finish(size_t width) pure
    {
        auto out_ = appender!string;
        drain(out_, width < 10 ? 10 : width, true);
        this = MarkdownStream.init;
        return out_[];
    }

    /// Whether anything is held back.
    bool holding() pure const { return src.length || code.length; }

    private void emit(ref Appender!string out_, string chunk, size_t width, bool partialList) pure
    {
        auto lines = renderLines(chunk, width);
        if (!lines.length) return;
        if (started && !listCont) out_ ~= "\n";
        foreach (l; lines) out_ ~= l ~ "\n";
        started = true;
        listCont = partialList;
    }

    private void drain(ref Appender!string out_, size_t width, bool last) pure
    {
        for (;;)
        {
            if (code.length)
            {
                auto fence = code;
                for (auto nl = src.indexOf('\n'); nl >= 0; nl = src.indexOf('\n'))
                {
                    auto line = src[0 .. nl];
                    src = src[nl + 1 .. $];
                    if (closesFence(line, fence)) { code = null; break; }
                    foreach (l; hardLines(clean(expandIndent(line)), width, 0)) out_ ~= l ~ "\n";
                }
                if (code.length)
                {
                    if (last)
                    {
                        auto rest = src;
                        src = null;
                        if (rest.length && !closesFence(rest, fence))
                            foreach (l; hardLines(clean(expandIndent(rest)), width, 0)) out_ ~= l ~ "\n";
                        out_ ~= fenceClose() ~ "\n";
                        code = null;
                    }
                    return;
                }
                out_ ~= fenceClose() ~ "\n";
                continue;
            }

            src = separateTables(src);
            size_t end;
            if (last) end = src.length;
            else
            {
                auto nl = src.lastIndexOf('\n');
                if (nl < 0) return;
                end = nl + 1;
            }
            auto complete = src[0 .. end];
            auto blocks = topBlocks(complete);
            if (!blocks.length)
            {
                if (last) src = null;
                return;
            }
            foreach (k; 1 .. blocks.length) emit(out_, complete[blocks[k - 1].start .. blocks[k].start], width, false);
            auto fin = blocks[$ - 1];
            auto tail = complete[fin.start .. $];
            size_t consumed = fin.start;
            if (last)
            {
                emit(out_, tail, width, false);
                src = null;
                return;
            }
            final switch (fin.kind)
            {
                case Kind.single:
                    emit(out_, tail, width, false);
                    consumed = end;
                    break;
                case Kind.fenced:
                    auto nl = tail.indexOf('\n');
                    auto first = nl >= 0 ? tail[0 .. nl] : tail;
                    auto fence = fenceRun(first);
                    auto t = tail;
                    while (t.length && t[$ - 1] == '\n') t = t[0 .. $ - 1];
                    auto body = t.split("\n");
                    if (body.length >= 2 && closesFence(body[$ - 1], fence))
                    {
                        emit(out_, tail, width, false);
                        consumed = end;
                        break;
                    }
                    // Open: print the fence, then stream the code a line at a time.
                    auto info = clean(first.stripLeft[fence.length .. $].strip);
                    if (started && !listCont) out_ ~= "\n";
                    out_ ~= fenceOpen(info) ~ "\n";
                    started = true;
                    listCont = false;
                    code = fence;
                    src = src[fin.start + first.length + 1 .. $];
                    continue;
                case Kind.list:
                    if (fin.items.length >= 2)
                    {
                        auto cut = fin.items[$ - 1];
                        emit(out_, complete[fin.start .. cut], width, true);
                        consumed = cut;
                    }
                    break;
                case Kind.other:
                    break;
            }
            src = src[consumed .. $];
            return;
        }
    }
}

import std.array : Appender;

version (unittest)
{
    private string plain(string s) pure
    {
        auto o = appender!string;
        for (size_t i; i < s.length; i++)
        {
            if (s[i] == '\x1b') { while (i < s.length && s[i] != 'm') i++; continue; }
            o ~= s[i];
        }
        return o[];
    }

    private string[] show(string text, size_t width) pure
    {
        string[] out_;
        import nano.frame : dropSoftWraps;
        foreach (l; renderLines(text, width)) out_ ~= dropSoftWraps(plain(l));
        return out_;
    }

    private size_t w(string s) pure
    {
        import nano.frame : dropSoftWraps;
        return textWidth(dropSoftWraps(plain(s)));
    }

    private string stream(string[] chunks, size_t width) pure
    {
        MarkdownStream s;
        string all;
        foreach (c; chunks) all ~= s.push(c, width);
        return all ~ s.finish(width);
    }

    private string[] chunked(string text, size_t size) pure
    {
        import std.conv : to;
        auto d = text.to!dstring;
        string[] out_;
        for (size_t i; i < d.length; i += size) out_ ~= d[i .. i + size > d.length ? d.length : i + size].to!string;
        return out_;
    }

    private enum TABLE = "| Name | Size |\n|---|--:|\n| alpha | 1 |\n| beta | 22 |";
    private enum DOC = "# Title\n\nSee:\n| k | v |\n|---|---|\n| x | y |\n\nIntro with **bold** and a [link](https://x.dev).\nSecond line.\n\n- one\n- two\n  - nested\n- three\n\n1. first\n2. second\n\n> quoted\n\n```sh\necho hi\n\n| not | table |\n```\n\n| Name | Size |\n|---|--:|\n| alpha | 1 |\n\n---\n\nThe end.";
}

// rust: markdown.rs::inline_markup_is_styled_and_markers_removed
unittest // inline markup is styled and markers removed
{
    import std.algorithm : canFind;
    auto out_ = render("Some **bold**, *italic*, ~~gone~~ and `code`.", 80);
    assert(plain(out_) == "Some bold, italic, gone and code.", out_);
    assert(out_.canFind("\x1b[1mbold\x1b[0m") && out_.canFind("\x1b[3mitalic\x1b[0m"), out_);
    assert(out_.canFind("\x1b[9mgone\x1b[0m") && out_.canFind("\x1b[36mcode\x1b[0m"), out_);
    assert(render("***both***", 80).canFind("\x1b[1;3mboth"));
}

// rust: markdown.rs::headings_paragraphs_and_rules
unittest // headings, paragraphs and rules
{
    import std.algorithm : canFind;
    assert(show("# Title\n\nText here.\n\n---\n\n## Sub", 20) == ["Title", "", "Text here.", "", "─".replicate(20), "", "Sub"]);
    assert(render("# T", 80).canFind("\x1b[1;4mT"));
    assert(render("### T", 80).canFind("\x1b[1mT"));
}

// rust: markdown.rs::paragraphs_wrap_and_soft_breaks_reflow
unittest // paragraphs wrap and soft breaks reflow
{
    assert(show("one two three\nfour five six seven", 12) == ["one two", "three four", "five six", "seven"]);
    assert(show("a  \nb", 80) == ["a", "b"]);
    assert(show("x<br>y", 80) == ["x", "y"]);
    foreach (l; show("supercalifragilisticexpialidocious ".replicate(3), 10)) assert(w(l) <= 10, l);
}

// rust: markdown.rs::links_show_their_url_unless_it_is_the_text
unittest // links show their URL unless it is the text
{
    assert(show("see [docs](https://x.dev/d) now", 80) == ["see docs (https://x.dev/d) now"]);
    assert(show("<https://x.dev>", 80) == ["https://x.dev"]);
    assert(show("![logo](a.png)", 80) == ["[image: logo]"]);
}

// rust: markdown.rs::list_items_wrap_with_a_hanging_indent
// rust: markdown.rs::lists_nest_with_bullets_numbers_and_tasks
// rust: markdown.rs::loose_lists_keep_blank_lines
unittest // lists nest with bullets, numbers and tasks; hanging indent; loose lists
{
    auto text = "- one\n- two\n  - inner\n    - deep\n- three\n\n3. c\n4. d\n\n- [ ] todo\n- [x] done";
    assert(show(text, 80) == ["• one", "• two", "  ◦ inner", "    ▪ deep", "• three", "", "3. c", "4. d", "", "☐ todo", "☑ done"], show(text, 80).join("|"));
    assert(show("- alpha beta gamma delta", 14) == ["• alpha beta", "  gamma delta"]);
    assert(show("10. alpha beta gamma", 13) == ["10. alpha", "    beta", "    gamma"]);
    assert(show("- a\n\n- b\n\n  more", 80) == ["• a", "", "• b", "", "  more"]);
}

// rust: markdown.rs::code_blocks_are_verbatim_between_dim_fences
unittest // code blocks are verbatim between dim fences
{
    assert(show("```rust\nfn main() {\n    **not bold**\n}\n```\nafter", 80) == ["```rust", "fn main() {", "    **not bold**", "}", "```", "", "after"]);
    assert(show("    indented\n    code", 80) == ["    indented", "    code"]);
    // A long code line stays whole here; the frame breaks it by character
    // at the terminal's width, so copying it back gives exactly the line.
    assert(show("```\n" ~ "x".replicate(25) ~ "\n```", 10)[1] == "x".replicate(25));
    import nano.frame : wrapAnsi, dropSoftWraps;
    import std.algorithm : map;
    import std.array : array;
    auto rows = wrapAnsi(renderLines("```\n" ~ "x".replicate(25) ~ "\n```", 10)[1], 10).map!(r => dropSoftWraps(plain(r))).array;
    assert(rows == ["xxxxxxxxxx", "xxxxxxxxxx", "xxxxx"], rows[0]);
}

// rust: markdown.rs::block_quotes_get_a_bar
// rust: markdown.rs::controls_in_model_text_are_dropped
unittest // block quotes get a bar; controls are dropped
{
    import std.algorithm : canFind;
    assert(show("> quoted **text**\n> more\n\n> - item", 80) == ["│ quoted text more", "", "│ • item"]);
    auto out_ = render("evil \x1b[2J text\x07 and `co\x1bde`", 80);
    assert(!out_.canFind("\x1b[2J") && !out_.canFind('\x07'), out_);
    assert(!render("```\n\x1b]0;title\x07\n```", 80).canFind("\x1b]"));
}

// rust: markdown.rs::a_table_may_follow_a_paragraph_line_directly
// rust: markdown.rs::ragged_table_rows_are_padded_and_trimmed
// rust: markdown.rs::table_cells_handle_escapes_code_markup_and_wide_chars
// rust: markdown.rs::tables_in_code_and_lists
// rust: markdown.rs::tables_render_as_grids_with_alignment
// rust: markdown.rs::wide_tables_wrap_then_stack
unittest // tables
{
    import std.algorithm : canFind, all;
    assert(show(TABLE, 80) == ["┌───────┬──────┐", "│ Name  │ Size │", "├───────┼──────┤", "│ alpha │    1 │", "│ beta  │   22 │", "└───────┴──────┘"]);
    auto o = show("| **k** | `a\\|b` | c \\| d |\n|---|---|---|\n| 日本 | é | x |", 80);
    assert(o[1] == "│ k    │ a|b │ c | d │" && o[3] == "│ 日本 │ é   │ x     │", o.join("\n"));
    o = show("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |", 80);
    assert(o.canFind("│ 1 │   │") && o.canFind("│ 1 │ 2 │") && !o.join.canFind('3'));
    o = show("| key | description |\n|---|---|\n| a | " ~ "word ".replicate(30) ~ " |", 40);
    assert(o.length > 6 && o.all!(l => w(l) <= 40) && o[3][0 .. "│ a   │ word word".length] == "│ a   │ word word", o.join("\n"));
    o = show("| one | two | three | four | five | six |\n|---|---|---|---|---|---|\n| aaaaaaa | bbbbbbb | c | d | e | f |", 30);
    assert(!o.join.canFind("┌") && o.canFind("one  : aaaaaaa"), o.join("\n"));
    assert(show("Results:\n| a | b |\n|---|---|\n| 1 | 2 |", 80)[0 .. 3] == ["Results:", "", "┌───┬───┐"]);
    assert(show("```\nx\n| a |\n|---|\n```", 80)[2] == "| a |");
    assert(show("a | b\nc | d", 80) == ["a | b c | d"]);
    assert(show("```\n" ~ TABLE ~ "\n```", 80)[1] == "| Name | Size |");
    import std.array : replace;
    assert(show("- item\n\n  " ~ TABLE.replace("\n", "\n  "), 80).canFind("  ┌───────┬──────┐"));
}

// rust: markdown.rs::every_line_fits_the_width
unittest // every line fits the width
{
    auto text = format("# A heading that is fairly long\n\n> quote with words %s\n\n- list %s\n  1. nested %s\n\n%s\n\n```\n%s\n```",
        "w ".replicate(40), "x ".replicate(40), "y ".replicate(40), TABLE, "z".replicate(90));
    foreach (width; [10, 17, 30, 80])
        foreach (l; renderLines(text, width))
        {
            // Code is left whole for the frame to break by character.
            import std.string : indexOf;
            if (l.indexOf(verbatimMark) < 0) assert(w(l) <= width, l);
        }
}

unittest // stream matches whole-text rendering at any split
{
    auto whole = render(DOC, 60) ~ "\n";
    foreach (size; [1, 2, 3, 5, 7, 16, 64, DOC.length])
        assert(stream(chunked(DOC, size), 60) == whole, format("chunk size %s:\n%s\n---\n%s", size, plain(stream(chunked(DOC, size), 60)), plain(whole)));
}

unittest // stream emits blocks as soon as they complete
{
    import nano.frame : dropSoftWraps;
    MarkdownStream s;
    assert(plain(s.push("# Title\n", 80)) == "Title\n");
    assert(s.push("Para", 80) == "");
    assert(s.push("graph text\n", 80) == "");
    assert(plain(s.push("\n- a\n", 80)) == "\nParagraph text\n");
    assert(plain(s.push("- b\n", 80)) == "\n• a\n");
    assert(plain(s.push("- c\n", 80)) == "• b\n");
    assert(dropSoftWraps(plain(s.push("```py\nx = 1\n", 80))) == "• c\n\n```py\nx = 1\n");
    assert(dropSoftWraps(plain(s.push("y = 2\n```\n", 80))) == "y = 2\n```\n");
    assert(plain(s.push("bye", 80)) == "");
    assert(plain(s.finish(80)) == "\nbye\n");
    assert(!s.holding);
}

unittest // finish closes an unterminated code block; plain text is unchanged
{
    auto all = stream(["text\n\n```\ncode", " more"], 80);
    import nano.frame : dropSoftWraps;
    assert(dropSoftWraps(plain(all)) == "text\n\n```\ncode more\n```\n", all);
    assert(plain(all) == plain(render("text\n\n```\ncode more", 80) ~ "\n"));
    assert(stream(["just ", "some words\n", "on lines"], 80) == "just some words on lines\n");
}

// rust: markdown.rs::emoji_shortcodes
unittest // GitHub-style emoji shortcodes in prose; code stays verbatim
{
    import std.algorithm : canFind;
    import std.array : join;
    auto r = (string md) => show(md, 80).join("\n");
    assert(r("Grow :seedling: now").canFind("Grow 🌱 now"));
    assert(r(":+1: and :tada:").canFind("👍 and 🎉"));
    assert(r(":sweat_smile:").canFind("😅"), r(":sweat_smile:"));
    assert(r("keep :not_an_emoji_xyz: as is").canFind(":not_an_emoji_xyz:"));
    assert(r("at 12:30:45 in a::b").canFind("12:30:45 in a::b"));
    assert(r("v1:zz:seedling:").canFind("v1:zz🌱"));
    assert(r("`:seedling:`").canFind(":seedling:"));
    assert(r("```\n:seedling:\n```").canFind(":seedling:"));
}

unittest // a separator one cell short of the edge survives a wide-glyph wrap
{
    import std.conv : to;
    import std.string : indexOf;
    // The consumed separator rides the continuation as a zero-cell mark the
    // frame emits as a space, so a copy keeps the words apart (a plain view
    // drops the mark; the emit half is covered in nano.frame).
    auto rows = renderLines("cmd abcdef 中", 11);
    assert(rows.length == 2 && rows[1].indexOf(sepWrapMark) >= 0, rows[1]);
    assert(show("cmd abcdef 中", 11) == ["cmd abcdef", "中"], show("cmd abcdef 中", 11).to!string);
    assert(show("cmd abcdefg中", 11) == ["cmd", "abcdefg中"], show("cmd abcdefg中", 11).to!string);
}

unittest // indented code is verbatim: the frame breaks it, the indent stays on the first row
{
    import std.conv : to;
    import std.algorithm : map;
    import std.array : array;
    import nano.frame : wrapAnsi, dropSoftWraps;
    auto rows = renderLines("    rm -r /a b", 6);
    assert(rows.length == 1 && rows[0].indexOf(verbatimMark) >= 0, rows[0]);
    assert(wrapAnsi(rows[0], 6).map!dropSoftWraps.array == ["    rm", " -r /a", " b"]);
    assert(show("    short", 20) == ["    short"]);
}

unittest // inline code wider than the line stays whole for the frame to wrap
{
    import std.conv : to;
    import std.algorithm : canFind;
    // Breaking it here would put a newline (and the caller's alignment pad)
    // inside the token, corrupting a copied path. Plain words still break.
    foreach (c; [["`/abcdefghijklmnopqrstuv`", "/abcdefghijklmnopqrstuv"],
                 ["see `/abcdefghijklmnopqrstuv`", "/abcdefghijklmnopqrstuv"],
                 ["x `/abcd` `/klmnopqrstuvwx`", "/klmnopqrstuvwx"]])
    {
        auto rows = show(c[0], 10);
        assert(rows.canFind!(r => r.canFind(c[1])), rows.to!string);
    }
    foreach (l; show("/abcdefghijklmnopqrstuv", 10)) assert(w(l) <= 10, l);
}

unittest // a word with inline code is whole and verbatim whenever it would break
{
    import std.conv : to;
    import std.algorithm : canFind, count;
    // Oversized: the row is verbatim, so the frame wraps by character.
    auto rows = renderLines("see `/abcdefghijklmnopqrstuv`", 20);
    assert(rows.count!(r => r.indexOf(verbatimMark) >= 0) == 1, rows.to!string);
    // Adjacent punctuation: the code word stays whole.
    auto p = show("see `/abcdefghijklmnopqrstuv`,", 10);
    assert(p.canFind!(r => r.canFind("/abcdefghijklmnopqrstuv,")), p.to!string);
    // Exactly the width after an edge separator: kept whole, not split.
    auto e = show("abcdefghij `/klmnopqrs`", 10);
    assert(e.canFind!(r => r.canFind("/klmnopqrs")), e.to!string);
    // A fitting code word is not marked.
    assert(renderLines("see `/ab`", 20)[0].indexOf(verbatimMark) < 0);
}
