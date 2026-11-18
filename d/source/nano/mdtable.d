/// Terminal layout of markdown tables (mdtable.rs).
///
/// `nano.markdown` parses a table into a `Table` of plain-text cells;
/// `layout` draws it as a box-drawn grid sized to the terminal. Cells wrap
/// when the grid is too wide (the widest columns shrink first), and when even
/// wrapped columns can't fit, each row is shown as a stacked `Header: value`
/// record instead.
module nano.mdtable;

@safe:
import nano.arith : saturatingSub;

import std.array : appender, join, replicate;
import std.string : strip, stripRight;
import nano.lineedit : charWidth;

private enum DIM = "\x1b[2m", BOLD = "\x1b[1m", RESET = "\x1b[0m";

/// Narrowest a column is squeezed to before switching to the stacked layout
/// (a column whose content is narrower keeps its natural width).
private enum size_t MIN_COL = 6;

enum Align { left, center, right }

/// A table of plain-text cells. Body rows may be ragged; `layout` pads them.
struct Table
{
    string[] header;
    Align[] aligns;
    string[][] rows;
}

/// Display width in terminal cells (no escape sequences expected).
size_t width(string s) pure
{
    size_t w;
    foreach (dchar c; s) w += charWidth(c);
    return w;
}

private bool isControl(dchar c) pure nothrow { return c < 0x20 || (c >= 0x7f && c < 0xa0); }

/// A cell's display text: controls dropped (cells are model text), so widths
/// are measured on what is actually shown.
private string cellText(string raw) pure
{
    auto o = appender!string;
    foreach (dchar c; raw)
    {
        if (c == '\n' || c == '\t') o ~= ' ';
        else if (!isControl(c)) o ~= c;
    }
    return o[];
}

/// Word-wrap `text` to `w` cells, hard-breaking words that don't fit.
private string[] wrap(string text, size_t w) pure
{
    import std.array : split;
    if (w < 1) w = 1;
    string[] lines;
    string cur;
    size_t curW;
    foreach (word; text.split)
    {
        auto ww = width(word);
        if (curW > 0 && curW + 1 + ww <= w)
        {
            cur ~= " " ~ word;
            curW += 1 + ww;
            continue;
        }
        if (curW > 0)
        {
            lines ~= cur;
            cur = null;
            curW = 0;
        }
        if (ww <= w)
        {
            cur = word;
            curW = ww;
            continue;
        }
        foreach (dchar c; word)
        {
            auto cw = charWidth(c);
            if (curW + cw > w && curW > 0)
            {
                lines ~= cur;
                cur = null;
                curW = 0;
            }
            cur ~= c;
            curW += cw;
        }
    }
    if (curW > 0 || !lines.length) lines ~= cur;
    return lines;
}

private string pad(string text, size_t w, Align a) pure
{
    auto tw = width(text);
    auto gap = saturatingSub(w, tw);
    size_t l, r;
    final switch (a)
    {
        case Align.left: r = gap; break;
        case Align.right: l = gap; break;
        case Align.center: l = gap / 2; r = gap - gap / 2; break;
    }
    return " ".replicate(l) ~ text ~ " ".replicate(r);
}

private size_t sum(const size_t[] xs) pure nothrow
{
    size_t n;
    foreach (x; xs) n += x;
    return n;
}

/// Column widths that fit `avail` cells of content, or null when even the
/// narrowest acceptable columns don't fit.
private size_t[] fitColumns(const size_t[] natural, size_t avail) pure
{
    auto floor = new size_t[natural.length];
    foreach (i, n; natural) floor[i] = n < MIN_COL ? n : MIN_COL;
    if (sum(floor) > avail) return null;
    auto widths = natural.dup;
    // Shrink the widest column one cell at a time, so wide columns give up
    // space before narrow ones (the last of equals, as Rust's max_by_key).
    while (sum(widths) > avail)
    {
        ptrdiff_t best = -1;
        foreach (i, w; widths)
            if (w > floor[i] && (best < 0 || w >= widths[best])) best = i;
        if (best < 0) return null;
        widths[best]--;
    }
    return widths;
}

private string border(const size_t[] widths, string left, string mid, string right) pure
{
    string[] segs;
    foreach (w; widths) segs ~= "─".replicate(w + 2);
    return DIM ~ left ~ segs.join(mid) ~ right ~ RESET;
}

private string[] gridRows(const string[] cells, const size_t[] widths, const Align[] aligns, bool bold) pure
{
    string[][] wrapped;
    size_t height = 1;
    foreach (i, c; cells)
    {
        wrapped ~= wrap(c, widths[i]);
        if (wrapped[$ - 1].length > height) height = wrapped[$ - 1].length;
    }
    enum bar = DIM ~ "│" ~ RESET;
    string[] out_;
    foreach (row; 0 .. height)
    {
        string[] parts;
        foreach (i, lines; wrapped)
        {
            auto a = i < aligns.length ? aligns[i] : Align.left;
            auto text = pad(row < lines.length ? lines[row] : "", widths[i], a);
            parts ~= bold && text.strip.length ? BOLD ~ text ~ RESET : text;
        }
        out_ ~= bar ~ " " ~ parts.join(" " ~ bar ~ " ") ~ " " ~ bar;
    }
    return out_;
}

/// Lay a table out in at most `maxWidth` cells per line.
string[] layout(const ref Table table, size_t maxWidth) pure
{
    string[] header;
    foreach (c; table.header) header ~= cellText(c);
    auto n = header.length;
    string[][] rows;
    foreach (r; table.rows)
    {
        auto row = new string[n];
        foreach (i, c; r)
            if (i < n) row[i] = cellText(c);
        rows ~= row;
    }
    auto natural = new size_t[n];
    foreach (i; 0 .. n)
    {
        size_t m = width(header[i]);
        foreach (r; rows) if (width(r[i]) > m) m = width(r[i]);
        natural[i] = m < 1 ? 1 : m;
    }
    // `│ a │ b │`: two spaces and a bar per column, plus the closing bar.
    auto chrome = 3 * n + 1;
    if (maxWidth >= chrome)
    {
        auto widths = fitColumns(natural, maxWidth - chrome);
        if (widths !is null)
        {
            string[] out_ = [border(widths, "┌", "┬", "┐")];
            out_ ~= gridRows(header, widths, table.aligns, true);
            out_ ~= border(widths, "├", "┼", "┤");
            foreach (row; rows) out_ ~= gridRows(row, widths, table.aligns, false);
            out_ ~= border(widths, "└", "┴", "┘");
            return out_;
        }
    }
    return stacked(header, rows, maxWidth);
}

/// The narrow-terminal layout: each row as a block of `Header: value` lines,
/// values wrapped under themselves, blocks separated by a rule.
private string[] stacked(const string[] header, const string[][] rows, size_t maxWidth) pure
{
    size_t labelW;
    foreach (h; header) if (width(h) > labelW) labelW = width(h);
    if (labelW > maxWidth / 3) labelW = maxWidth / 3;
    auto valueW = maxWidth > labelW + 2 ? maxWidth - labelW - 2 : 1;
    auto ruleW = maxWidth < 1 ? 1 : maxWidth > 40 ? 40 : maxWidth;
    auto rule = DIM ~ "─".replicate(ruleW) ~ RESET;
    string[] out_;
    foreach (r, row; rows)
    {
        if (r > 0) out_ ~= rule;
        foreach (i, h; header)
        {
            if (i >= row.length) break;
            auto labels = wrap(h, labelW < 1 ? 1 : labelW);
            auto values = wrap(row[i], valueW);
            auto count = labels.length > values.length ? labels.length : values.length;
            foreach (k; 0 .. count)
            {
                auto label = pad(k < labels.length ? labels[k] : "", labelW, Align.left);
                auto value = k < values.length ? values[k] : "";
                auto colon = k == 0 ? ":" : " ";
                out_ ~= (BOLD ~ label ~ RESET ~ DIM ~ colon ~ RESET ~ " " ~ value).stripRight;
            }
        }
    }
    if (!rows.length) out_ ~= BOLD ~ header.join(" · ") ~ RESET;
    return out_;
}
