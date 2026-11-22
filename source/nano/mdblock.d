/// Block-level markdown parsing for `nano.markdown`: CommonMark blocks
/// (paragraphs, ATX and setext headings, fenced and indented code, block
/// quotes, nested lists, rules, HTML blocks) plus GFM tables and task
/// lists, into a small block tree. Each top-level block keeps the line it
/// starts on, so a stream can emit blocks as they complete.
module nano.mdblock;

@safe:
pure:

import std.conv : to;

import nano.option : NotNull, notNull;
import std.array : appender, join;
import std.string : strip, stripLeft, stripRight, indexOf;
import nano.mdinline;
import nano.mdtable : Table, Align;

enum BK { para, heading, code, quote, list, rule, table, html }

final class Block
{
    BK kind;
    Span[] spans;       // para, heading
    int level;          // heading
    bool fenced;        // code: fenced (has an info string, maybe empty)
    string info, text;  // code, html
    Block[] blocks;     // quote
    Item[] items;       // list
    bool ordered, tight;
    ulong start;
    Table table;

    this(BK kind) pure { this.kind = kind; }
}

struct Item
{
    int task = -1; // -1 none, 0 open, 1 done
    Block[] blocks;
}

/// A parsed block with its source lines `[start, end)` (trailing blank
/// lines excluded) and, for a list, the line each item starts on.
struct Parsed
{
    NotNull!Block block;
    size_t start, end;
    size_t[] items;
}

// --- Line classification -----------------------------------------------------

bool isBlank(string l) pure { return l.strip.length == 0; }

size_t indentOf(string l) pure nothrow
{
    size_t n;
    while (n < l.length && l[n] == ' ') n++;
    return n;
}

/// `l` with up to `n` leading spaces removed.
string dedent(string l, size_t n) pure nothrow
{
    size_t k;
    while (k < n && k < l.length && l[k] == ' ') k++;
    return l[k .. $];
}

/// Leading tabs become spaces (4-column stops), so indentation is counted in spaces.
string expandIndent(string l) pure
{
    size_t i, col;
    while (i < l.length && (l[i] == ' ' || l[i] == '\t')) { col = l[i] == '\t' ? (col / 4 + 1) * 4 : col + 1; i++; }
    if (l[0 .. i].indexOf('\t') < 0) return l;
    import std.array : replicate;
    return " ".replicate(col) ~ l[i .. $];
}

private bool atx(string t, out int level, out string content) pure
{
    size_t n;
    while (n < t.length && t[n] == '#') n++;
    if (n < 1 || n > 6 || (n < t.length && t[n] != ' ' && t[n] != '\t')) return false;
    level = n.to!int; // at most 6: checked above
    auto c = t[n .. $].strip;
    // An optional closing run of #s, preceded by a space.
    size_t k = c.length;
    while (k > 0 && c[k - 1] == '#') k--;
    if (k == 0) c = null;
    else if (k < c.length && (c[k - 1] == ' ' || c[k - 1] == '\t')) c = c[0 .. k].stripRight;
    content = c;
    return true;
}

private bool isRuleLine(string t) pure nothrow
{
    char m = 0;
    size_t n;
    foreach (c; t)
    {
        if (c == ' ' || c == '\t') continue;
        if (c != '-' && c != '*' && c != '_') return false;
        if (m && c != m) return false;
        m = c;
        n++;
    }
    return n >= 3;
}

/// The run of backticks or tildes that opens a fence line.
string fenceRun(string line) pure nothrow
{
    auto t = line;
    while (t.length && t[0] == ' ') t = t[1 .. $];
    if (!t.length) return null;
    size_t n;
    while (n < t.length && t[n] == t[0]) n++;
    return t[0 .. n];
}

bool closesFence(string line, string fence) pure
{
    auto t = line.strip;
    char c = fence.length ? fence[0] : '`';
    if (t.length < fence.length) return false;
    foreach (x; t) if (x != c) return false;
    return true;
}

private bool isFenceOpen(string t) pure nothrow
{
    if (t.length < 3 || (t[0] != '`' && t[0] != '~')) return false;
    auto run = fenceRun(t);
    if (run.length < 3) return false;
    if (t[0] == '`') foreach (c; t[run.length .. $]) if (c == '`') return false;
    return true;
}

private struct Marker
{
    bool ok, ordered, empty;
    char ch; // bullet char or ordered delimiter
    ulong num;
    size_t width; // content indent
    string rest;
}

private Marker listMarker(string l) pure
{
    Marker m;
    auto ind = indentOf(l);
    if (ind > 3) return m;
    auto t = l[ind .. $];
    size_t k;
    if (t.length && (t[0] == '-' || t[0] == '+' || t[0] == '*'))
    {
        m.ch = t[0];
        k = 1;
    }
    else
    {
        while (k < t.length && k < 9 && t[k] >= '0' && t[k] <= '9') k++;
        if (k == 0 || k >= t.length || (t[k] != '.' && t[k] != ')')) return m;
        import std.conv : to;
        m.num = t[0 .. k].to!ulong;
        m.ordered = true;
        m.ch = t[k];
        k++;
    }
    if (k < t.length && t[k] != ' ') return m;
    size_t sp;
    while (k + sp < t.length && t[k + sp] == ' ') sp++;
    m.empty = k + sp >= t.length;
    if (m.empty || sp > 4) sp = 1;
    m.width = ind + k + sp;
    m.rest = k + sp <= t.length ? t[k + sp .. $] : "";
    if (m.empty) m.rest = "";
    m.ok = true;
    return m;
}

private immutable string[] blockTags = ["address", "article", "aside", "blockquote", "body", "center", "details",
    "dialog", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4",
    "h5", "h6", "header", "hr", "html", "iframe", "li", "main", "menu", "nav", "ol", "p", "pre", "script", "section",
    "style", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"];

/// Whether `t` starts an HTML block, and whether that block may interrupt a paragraph.
private bool htmlStart(string t, out bool interrupts) pure
{
    import std.string : toLower;
    if (t.length < 2 || t[0] != '<') return false;
    if (t.length >= 4 && t[0 .. 4] == "<!--") { interrupts = true; return true; }
    size_t j = t[1] == '/' ? 2 : 1, k = j;
    while (k < t.length && (((t[k] | 0x20) >= 'a' && (t[k] | 0x20) <= 'z') || (k > j && t[k] >= '0' && t[k] <= '9'))) k++;
    if (k == j) return false;
    auto name = t[j .. k].toLower;
    bool known;
    foreach (b; blockTags) if (b == name) { known = true; break; }
    if (known && (k == t.length || t[k] == ' ' || t[k] == '>' || (t[k] == '/' && k + 1 < t.length && t[k + 1] == '>')))
    {
        interrupts = true;
        return true;
    }
    // Any other complete tag alone on its line (it can't interrupt a paragraph).
    auto end = htmlTag(t, 0);
    return end && t[end .. $].strip.length == 0;
}

/// A table delimiter row (`|---|:--:|`), as markdown.rs checks it.
bool isDelimiterRow(string line) pure
{
    auto t = line.strip;
    if (t.indexOf('-') < 0 || t.indexOf('|') < 0) return false;
    foreach (c; t) if (c != '|' && c != '-' && c != ':' && c != ' ') return false;
    return true;
}

/// A table row's cells, with escaped pipes unescaped.
private string[] splitRow(string line) pure
{
    import std.array : replace;
    auto t = line.strip;
    if (t.length && t[0] == '|') t = t[1 .. $];
    if (t.length && t[$ - 1] == '|' && !(t.length >= 2 && t[$ - 2] == '\\')) t = t[0 .. $ - 1];
    string[] cells;
    size_t from;
    foreach (i, c; t)
        if (c == '|' && !(i > 0 && t[i - 1] == '\\'))
        {
            cells ~= t[from .. i].strip.replace("\\|", "|");
            from = i + 1;
        }
    cells ~= t[from .. $].strip.replace("\\|", "|");
    return cells;
}

/// Whether line `l` (outside any container) starts a block that ends a paragraph.
private bool interrupts(string l) pure
{
    if (isBlank(l)) return true;
    auto ind = indentOf(l);
    if (ind > 3) return false;
    auto t = l[ind .. $];
    int level;
    string content;
    bool html;
    if (atx(t, level, content) || isFenceOpen(t) || t[0] == '>' || isRuleLine(t)) return true;
    if (htmlStart(t, html) && html) return true;
    auto m = listMarker(l);
    return m.ok && !m.empty && (!m.ordered || m.num == 1);
}

// --- Block parsing -----------------------------------------------------------

/// Blocks of `lines` (already tab-expanded).
Parsed[] parseLines(const string[] lines) pure
{
    Parsed[] out_;
    size_t i;
    auto n = lines.length;
    while (i < n)
    {
        auto line = lines[i];
        if (isBlank(line)) { i++; continue; }
        auto ind = indentOf(line);
        auto start = i;
        void add(Block b, size_t end, size_t[] items = null) { out_ ~= Parsed(notNull(b), start, end, items); }

        if (ind >= 4)
        {
            size_t j = i, last = i;
            string[] body;
            while (j < n && (isBlank(lines[j]) || indentOf(lines[j]) >= 4))
            {
                if (!isBlank(lines[j])) last = j;
                j++;
            }
            foreach (l; lines[i .. last + 1]) body ~= dedent(l, 4) ~ "\n";
            auto b = new Block(BK.code);
            b.text = clean(body.join);
            add(b, last + 1);
            i = last + 1;
            continue;
        }
        auto t = line[ind .. $];
        int level;
        string content;
        bool htmlInterrupts;

        if (isFenceOpen(t))
        {
            auto fence = fenceRun(t);
            auto b = new Block(BK.code);
            b.fenced = true;
            b.info = clean(t[fence.length .. $]).strip;
            auto body = appender!string;
            size_t j = i + 1;
            while (j < n && !(indentOf(lines[j]) < 4 && closesFence(lines[j], fence)))
                body ~= dedent(lines[j++], ind) ~ "\n";
            b.text = clean(body[]);
            if (j < n) j++;
            add(b, j);
            i = j;
            continue;
        }
        if (atx(t, level, content))
        {
            auto b = new Block(BK.heading);
            b.level = level;
            b.spans = inlineSpans(content);
            add(b, i + 1);
            i++;
            continue;
        }
        if (isRuleLine(t))
        {
            add(new Block(BK.rule), i + 1);
            i++;
            continue;
        }
        if (t[0] == '>')
        {
            string[] inner;
            size_t j = i;
            bool prevText;
            while (j < n)
            {
                auto l = lines[j];
                auto li = indentOf(l);
                if (li < 4 && li < l.length && l[li] == '>')
                {
                    auto rest = l[li + 1 .. $];
                    if (rest.length && rest[0] == ' ') rest = rest[1 .. $];
                    inner ~= rest;
                    prevText = !isBlank(rest);
                }
                else if (prevText && !interrupts(l) && !listMarker(l).ok) inner ~= l.stripLeft;
                else break;
                j++;
            }
            auto b = new Block(BK.quote);
            foreach (p; parseLines(inner)) b.blocks ~= p.block;
            add(b, j);
            i = j;
            continue;
        }
        auto m = listMarker(line);
        if (m.ok)
        {
            size_t end;
            size_t[] items;
            add(parseList(lines, i, end, items), end, items);
            i = end;
            continue;
        }
        if (htmlStart(t, htmlInterrupts))
        {
            size_t j = i;
            string[] body;
            while (j < n && !isBlank(lines[j])) body ~= lines[j++];
            auto b = new Block(BK.html);
            b.text = clean(body.join("\n") ~ "\n");
            add(b, j);
            i = j;
            continue;
        }
        if (t.indexOf('|') >= 0 && i + 1 < n && isDelimiterRow(lines[i + 1]))
        {
            auto header = splitRow(t), delims = splitRow(lines[i + 1]);
            bool valid = header.length == delims.length;
            foreach (d; delims) if (!d.length || d.strip(":").length == 0) valid = false;
            if (valid)
            {
                auto b = new Block(BK.table);
                foreach (h; header) b.table.header ~= inlinePlain(h).strip;
                foreach (d; delims)
                    b.table.aligns ~= d[$ - 1] == ':' ? (d[0] == ':' ? Align.center : Align.right) : Align.left;
                size_t j = i + 2;
                while (j < n && !isBlank(lines[j]) && !(interrupts(lines[j]) || listMarker(lines[j]).ok))
                {
                    string[] row;
                    foreach (c; splitRow(lines[j])) row ~= inlinePlain(c).strip;
                    b.table.rows ~= row;
                    j++;
                }
                add(b, j);
                i = j;
                continue;
            }
        }
        // A paragraph, perhaps underlined into a setext heading.
        size_t j = i + 1;
        int setext;
        while (j < n)
        {
            auto l = lines[j];
            if (indentOf(l) < 4)
            {
                auto u = l.strip;
                bool eq = u.length > 0, dash = u.length > 0;
                foreach (c; u) { if (c != '=') eq = false; if (c != '-') dash = false; }
                if (eq || dash) { setext = eq ? 1 : 2; break; }
            }
            if (interrupts(l)) break;
            j++;
        }
        string[] text;
        foreach (l; lines[i .. j]) text ~= l.stripLeft;
        auto b = new Block(setext ? BK.heading : BK.para);
        b.level = setext;
        b.spans = inlineSpans(text.join("\n").stripRight);
        if (setext) j++;
        add(b, j);
        i = j;
    }
    return out_;
}

/// The list starting at `lines[i]`; sets `end` to the line after it and
/// `items` to each item's first line.
private Block parseList(const string[] lines, size_t i, out size_t end, out size_t[] items) pure
{
    auto first = listMarker(lines[i]);
    auto b = new Block(BK.list);
    b.ordered = first.ordered;
    b.start = first.num;
    bool loose;
    size_t j = i;
    auto n = lines.length;
    for (;;)
    {
        auto m = listMarker(lines[j]);
        items ~= j;
        string[] content = [m.rest];
        size_t s = j;
        j++;
        bool lastText = !m.empty;
        while (j < n)
        {
            auto l = lines[j];
            if (isBlank(l))
            {
                // An item that starts empty can only begin with one blank line.
                if (m.empty && content.length == 1) break;
                content ~= "";
                lastText = false;
            }
            else if (indentOf(l) >= m.width) { content ~= dedent(l, m.width); lastText = true; }
            else if (lastText && !interrupts(l) && !listMarker(l).ok) content ~= l.stripLeft;
            else break;
            j++;
        }
        // Trailing blank lines belong between items, not to this one.
        size_t trailing;
        while (content.length > 1 && isBlank(content[$ - 1])) { content = content[0 .. $ - 1]; trailing++; }
        Item item;
        auto c0 = content[0];
        if (c0.length >= 3 && c0[0] == '[' && c0[2] == ']' && (c0[1] == ' ' || c0[1] == 'x' || c0[1] == 'X')
            && (c0.length == 3 || c0[3] == ' '))
        {
            item.task = c0[1] != ' ';
            content[0] = c0.length > 3 ? c0[4 .. $] : "";
        }
        auto parsed = parseLines(content);
        foreach (k, p; parsed)
        {
            item.blocks ~= p.block;
            if (k > 0)
                foreach (l; content[parsed[k - 1].end .. p.start]) if (isBlank(l)) loose = true;
        }
        b.items ~= item;
        end = j - trailing;
        if (j >= n) break;
        auto next = listMarker(lines[j]);
        if (!next.ok || next.ordered != first.ordered || next.ch != first.ch || isRuleLine(lines[j].strip)) break;
        if (trailing) loose = true;
    }
    b.tight = !loose;
    return b;
}

unittest
{
    auto ps = parseLines(["# T", "", "para", "more", "", "- a", "- b", "", "```", "x", "```"]);
    assert(ps.length == 4);
    assert(ps[0].block.kind == BK.heading && ps[1].block.kind == BK.para && ps[1].start == 2 && ps[1].end == 4);
    assert(ps[2].block.kind == BK.list && ps[2].items == [5, 6] && ps[2].block.tight);
    assert(ps[3].block.kind == BK.code && ps[3].block.text == "x\n");
    assert(parseLines(["Title", "==="])[0].block.level == 1);
    assert(parseLines(["- [x] done"])[0].block.items[0].task == 1);
}
