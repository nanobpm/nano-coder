/// Inline markdown (CommonMark plus GFM strikethrough) parsed into styled
/// spans for `nano.markdown`: emphasis, strong, strikethrough, code spans,
/// links, autolinks, images, escapes, entities, hard and soft breaks, and
/// inline HTML (`<br>` becomes a line break, other tags stay as text).
///
/// The Rust port uses pulldown-cmark; this is a small hand-written parser
/// following the CommonMark delimiter algorithm, producing the same spans
/// the Rust event builder does.
module nano.mdinline;

@safe:
pure:

import std.array : appender;
import std.string : strip, toLower;
import std.utf : decode, decodeFront;

// Inline style bits (markdown.rs).
enum ubyte BOLD = 1, ITALIC = 2, CODE = 4, STRIKE = 8, UNDERLINE = 16, FAINT = 32;

struct Span
{
    string text;
    ubyte style;
}

private bool isControl(dchar c) pure nothrow { return c < 0x20 || (c >= 0x7f && c < 0xa0); }

/// Model text with control characters removed; tabs become spaces. The
/// frame's private-use wrap marks (U+E002-U+E004) are metadata, never text:
/// a literal one would be read as a wrap, verbatim or separator mark, so it
/// is replaced by U+FFFD (as `terminalSafe` does).
string clean(string text) pure
{
    bool plain = true;
    foreach (dchar c; text)
        if ((c < 0x20 && c != '\n') || (c >= 0x7f && c < 0xa0) || (c >= 0xE002 && c <= 0xE004)) { plain = false; break; }
    if (plain) return text;
    auto o = appender!string;
    foreach (dchar c; text)
    {
        if (c == '\t') o ~= ' ';
        else if (c == '\n' || !isControl(c)) o ~= c >= 0xE002 && c <= 0xE004 ? '\uFFFD' : c;
    }
    return o[];
}

private enum K { text, code, emph, strong, strike, link, image, hard, soft, html, delim }

private final class Inl
{
    K k;
    string text, url;
    Inl[] kids;
    char dc;
    size_t count;
    bool canOpen, canClose, active = true, isImage;

    this(K k, string text = null) pure { this.k = k; this.text = text; }
}

private bool isPunct(dchar c) pure nothrow
{
    import std.uni : isPunctuation, isSymbol;
    if (c < 0x80) return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~');
    return isPunctuation(c) || isSymbol(c);
}

private bool isSpace(dchar c) pure nothrow
{
    import std.uni : isWhite;
    return isWhite(c);
}

private dchar charBefore(string s, size_t i) pure
{
    if (i == 0) return '\n';
    size_t j = i - 1;
    while (j > 0 && (s[j] & 0xC0) == 0x80) j--;
    return decode(s, j);
}

private dchar charAt(string s, size_t i) pure
{
    return i < s.length ? decode(s, i) : '\n';
}

private size_t runLength(string s, size_t i, char c) pure nothrow
{
    size_t j = i;
    while (j < s.length && s[j] == c) j++;
    return j - i;
}

/// `(dest "title")` after a link's `]` at `i`; the URL and the index after `)`.
private bool linkTail(string s, size_t i, out string url, out size_t next) pure
{
    if (i >= s.length || s[i] != '(') return false;
    i++;
    void ws() { while (i < s.length && (s[i] == ' ' || s[i] == '\n')) i++; }
    ws();
    auto u = appender!string;
    if (i < s.length && s[i] == '<')
    {
        i++;
        while (i < s.length && s[i] != '>' && s[i] != '\n')
        {
            if (s[i] == '\\' && i + 1 < s.length && isPunct(s[i + 1])) i++;
            u ~= s[i++];
        }
        if (i >= s.length || s[i] != '>') return false;
        i++;
    }
    else
    {
        int depth;
        while (i < s.length && s[i] > ' ')
        {
            if (s[i] == '(') depth++;
            else if (s[i] == ')') { if (depth == 0) break; depth--; }
            if (s[i] == '\\' && i + 1 < s.length && isPunct(s[i + 1])) i++;
            u ~= s[i++];
        }
        if (depth) return false;
    }
    auto before = i;
    ws();
    if (i < s.length && (s[i] == '"' || s[i] == '\'' || s[i] == '(') && i > before)
    {
        char close = s[i] == '(' ? ')' : s[i];
        i++;
        while (i < s.length && s[i] != close)
        {
            if (s[i] == '\\') i++;
            i++;
        }
        if (i >= s.length) return false;
        i++;
        ws();
    }
    if (i >= s.length || s[i] != ')') return false;
    url = u[];
    next = i + 1;
    return true;
}

private bool isAlpha(char c) pure nothrow { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
private bool isDigit(char c) pure nothrow { return c >= '0' && c <= '9'; }

/// An autolink `<scheme:...>` or `<a@b.c>` at `i`: its text, URL and end.
private bool autolink(string s, size_t i, out string text, out string url, out size_t next) pure
{
    size_t j = i + 1;
    if (j < s.length && isAlpha(s[j]))
    {
        auto k = j;
        while (k < s.length && (isAlpha(s[k]) || isDigit(s[k]) || s[k] == '+' || s[k] == '.' || s[k] == '-')) k++;
        if (k - j >= 2 && k - j <= 32 && k < s.length && s[k] == ':')
        {
            while (k < s.length && s[k] > ' ' && s[k] != '<' && s[k] != '>') k++;
            if (k < s.length && s[k] == '>')
            {
                text = url = s[j .. k];
                next = k + 1;
                return true;
            }
        }
    }
    auto k = j;
    bool at;
    while (k < s.length && s[k] > ' ' && s[k] != '<' && s[k] != '>') { if (s[k] == '@') at = true; k++; }
    if (at && k < s.length && s[k] == '>' && s[j] != '@' && s[k - 1] != '@')
    {
        text = s[j .. k];
        url = "mailto:" ~ text;
        next = k + 1;
        return true;
    }
    return false;
}

/// An inline HTML tag or comment at `i`; the index after it.
size_t htmlTag(string s, size_t i) pure nothrow
{
    if (i + 1 >= s.length || s[i] != '<') return 0;
    if (s.length - i >= 4 && s[i .. i + 4] == "<!--")
    {
        foreach (k; i + 4 .. s.length - 2 > i + 4 ? s.length - 2 : i + 4)
            if (s[k .. k + 3] == "-->") return k + 3;
        return 0;
    }
    size_t j = i + 1;
    if (s[j] == '/') j++;
    if (j >= s.length || !isAlpha(s[j])) return 0;
    while (j < s.length && (isAlpha(s[j]) || isDigit(s[j]) || s[j] == '-')) j++;
    if (j >= s.length) return 0;
    if (s[j] != '>' && s[j] != '/' && s[j] != ' ' && s[j] != '\n') return 0;
    char quote = 0;
    while (j < s.length)
    {
        auto c = s[j];
        if (quote) { if (c == quote) quote = 0; }
        else if (c == '"' || c == '\'') quote = c;
        else if (c == '<') return 0;
        else if (c == '>') return j + 1;
        j++;
    }
    return 0;
}

private bool entity(string s, size_t i, out string text, out size_t next) pure
{
    import std.conv : to, ConvException;
    import std.utf : encode, isValidDchar;
    static immutable string[2][] named = [["amp", "&"], ["lt", "<"], ["gt", ">"], ["quot", "\""], ["apos", "'"],
        ["nbsp", "\u00a0"], ["copy", "©"], ["mdash", "—"], ["ndash", "–"], ["hellip", "…"], ["rarr", "→"], ["larr", "←"]];
    auto semi = i + 1;
    while (semi < s.length && semi - i < 33 && s[semi] != ';') semi++;
    if (semi >= s.length || s[semi] != ';') return false;
    auto name = s[i + 1 .. semi];
    next = semi + 1;
    if (name.length >= 2 && name[0] == '#')
    {
        try
        {
            auto v = name[1] == 'x' || name[1] == 'X' ? name[2 .. $].to!uint(16) : name[1 .. $].to!uint;
            dchar c = v == 0 || !isValidDchar(v) ? '\uFFFD' : cast(dchar) v;
            char[4] buf;
            text = buf[0 .. encode(buf, c)].idup;
            return true;
        }
        catch (ConvException) return false;
    }
    foreach (e; named) if (e[0] == name) { text = e[1]; return true; }
    return false;
}

/// Parses inline markdown into a node list (delimiters resolved).
private Inl[] parse(string s) pure
{
    Inl[] seq;
    size_t[] brackets;
    auto buf = appender!string;
    void flush()
    {
        if (buf[].length) seq ~= new Inl(K.text, buf[]);
        buf = appender!string;
    }
    size_t i;
    while (i < s.length)
    {
        char c = s[i];
        switch (c)
        {
            case '\\':
                if (i + 1 < s.length && s[i + 1] == '\n')
                {
                    flush();
                    seq ~= new Inl(K.hard);
                    i += 2;
                    while (i < s.length && s[i] == ' ') i++;
                }
                else if (i + 1 < s.length && s[i + 1] < 0x80 && isPunct(s[i + 1]))
                {
                    buf ~= s[i + 1];
                    i += 2;
                }
                else { buf ~= c; i++; }
                break;
            case '`':
                auto n = runLength(s, i, '`');
                size_t j = i + n, close = 0;
                while (j < s.length)
                {
                    if (s[j] == '`')
                    {
                        auto m = runLength(s, j, '`');
                        if (m == n) { close = j; break; }
                        j += m;
                    }
                    else j++;
                }
                if (!close) { buf ~= s[i .. i + n]; i += n; break; }
                auto code = s[i + n .. close].dup;
                foreach (ref ch; code) if (ch == '\n') ch = ' ';
                if (code.length >= 2 && code[0] == ' ' && code[$ - 1] == ' ' && code.strip.length) code = code[1 .. $ - 1];
                flush();
                seq ~= new Inl(K.code, code.idup);
                i = close + n;
                break;
            case '*': case '_': case '~':
                auto n = runLength(s, i, c);
                auto before = charBefore(s, i), after = charAt(s, i + n);
                bool left = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before));
                bool right = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after));
                flush();
                auto d = new Inl(K.delim, s[i .. i + n]);
                d.dc = c;
                d.count = n;
                if (c == '_')
                {
                    d.canOpen = left && (!right || isPunct(before));
                    d.canClose = right && (!left || isPunct(after));
                }
                else
                {
                    d.canOpen = left;
                    d.canClose = right;
                }
                if (c == '~' && n > 2) d.canOpen = d.canClose = false;
                seq ~= d;
                i += n;
                break;
            case '!':
                if (i + 1 < s.length && s[i + 1] == '[')
                {
                    flush();
                    auto b = new Inl(K.text, "![");
                    b.isImage = true;
                    brackets ~= seq.length;
                    seq ~= b;
                    i += 2;
                }
                else { buf ~= c; i++; }
                break;
            case '[':
                flush();
                brackets ~= seq.length;
                seq ~= new Inl(K.text, "[");
                i++;
                break;
            case ']':
                string url;
                size_t next;
                if (!brackets.length) { buf ~= c; i++; break; }
                auto b = brackets[$ - 1];
                brackets = brackets[0 .. $ - 1];
                if (!seq[b].active || !linkTail(s, i + 1, url, next)) { buf ~= c; i++; break; }
                flush();
                auto node = new Inl(seq[b].isImage ? K.image : K.link);
                node.url = url;
                node.kids = resolve(seq[b + 1 .. $].dup);
                seq = seq[0 .. b] ~ node;
                if (node.k == K.link) foreach (o; brackets) seq[o].active = false;
                i = next;
                break;
            case '<':
                string text, url;
                size_t next;
                if (autolink(s, i, text, url, next))
                {
                    flush();
                    auto node = new Inl(K.link);
                    node.url = url;
                    node.kids = [new Inl(K.text, text)];
                    seq ~= node;
                    i = next;
                }
                else if (auto end = htmlTag(s, i))
                {
                    flush();
                    seq ~= new Inl(K.html, s[i .. end]);
                    i = end;
                }
                else { buf ~= c; i++; }
                break;
            case '&':
                string text;
                size_t next;
                if (entity(s, i, text, next)) { buf ~= text; i = next; }
                else { buf ~= c; i++; }
                break;
            case '\n':
                auto t = buf[];
                size_t sp;
                while (sp < t.length && t[$ - 1 - sp] == ' ') sp++;
                buf = appender!string;
                buf ~= t[0 .. $ - sp];
                flush();
                seq ~= new Inl(sp >= 2 ? K.hard : K.soft);
                i++;
                while (i < s.length && s[i] == ' ') i++;
                break;
            default:
                buf ~= c;
                i++;
        }
    }
    flush();
    return resolve(seq);
}

/// The CommonMark "process emphasis" step over `seq`.
private Inl[] resolve(Inl[] seq) pure
{
    size_t ci;
    for (;;)
    {
        ptrdiff_t c = -1;
        foreach (k; ci .. seq.length)
            if (seq[k].k == K.delim && seq[k].canClose && seq[k].count) { c = k; break; }
        if (c < 0) break;
        auto cl = seq[c];
        ptrdiff_t o = -1;
        for (ptrdiff_t j = c - 1; j >= 0; j--)
        {
            auto op = seq[j];
            if (op.k != K.delim || !op.canOpen || !op.count || op.dc != cl.dc) continue;
            if (cl.dc == '~') { if (op.count != cl.count) continue; }
            else if ((op.canClose || cl.canOpen) && (op.count + cl.count) % 3 == 0 && !(op.count % 3 == 0 && cl.count % 3 == 0))
                continue;
            o = j;
            break;
        }
        if (o < 0)
        {
            cl.canClose = false;
            ci = c + 1;
            continue;
        }
        auto op = seq[o];
        size_t use = cl.dc == '~' ? cl.count : op.count >= 2 && cl.count >= 2 ? 2 : 1;
        auto node = new Inl(cl.dc == '~' ? K.strike : use == 2 ? K.strong : K.emph);
        node.kids = seq[o + 1 .. c].dup;
        op.count -= use;
        cl.count -= use;
        Inl[] next = seq[0 .. o];
        if (op.count) next ~= op;
        next ~= node;
        ci = next.length;
        if (cl.count) next ~= cl;
        next ~= seq[c + 1 .. $];
        seq = next;
    }
    return seq;
}

private struct Flatten
{
    Span[] spans;
    string[] links;

    void emit(string text, ubyte style) pure
    {
        text = clean(text);
        if (!text.length) return;
        foreach (ref l; links) l ~= text;
        if (spans.length && spans[$ - 1].style == style && text != "\n" && spans[$ - 1].text != "\n")
            spans[$ - 1].text ~= text;
        else spans ~= Span(text, style);
    }

    void walk(Inl[] xs, ubyte style) pure
    {
        foreach (x; xs) final switch (x.k)
        {
            case K.text: emit(x.text, style); break;
            case K.delim: { import std.array : replicate; emit([x.dc].replicate(x.count).idup, style); } break;
            case K.code: emit(x.text, style | CODE); break;
            case K.soft: emit(" ", style); break;
            case K.hard: emit("\n", 0); break;
            case K.html:
                auto tag = x.text.strip.toLower;
                if (tag == "<br>" || tag == "<br/>" || tag == "<br />") emit("\n", 0);
                else emit(x.text, style);
                break;
            case K.emph: walk(x.kids, style | ITALIC); break;
            case K.strong: walk(x.kids, style | BOLD); break;
            case K.strike: walk(x.kids, style | STRIKE); break;
            case K.link:
                links ~= "";
                walk(x.kids, style | UNDERLINE);
                auto seen = links[$ - 1].strip;
                links = links[0 .. $ - 1];
                auto bare = x.url.length > 7 && x.url[0 .. 7] == "mailto:" ? x.url[7 .. $] : x.url;
                if (x.url.length && seen != x.url && seen != bare)
                    emit(" (" ~ x.url ~ ")", cast(ubyte)((style & ~UNDERLINE) | FAINT));
                break;
            case K.image:
                emit("[image: ", style | FAINT);
                walk(x.kids, style | FAINT);
                emit("]", style | FAINT);
                break;
        }
    }
}

/// Inline markdown as styled spans (markers removed, controls dropped).
Span[] inlineSpans(string text) pure
{
    Flatten f;
    f.walk(parse(text), 0);
    // Prose gets GitHub-style `:shortcode:` emoji; code stays verbatim (Rust
    // #181). Expanded after merging, as `_` in a name splits the text runs.
    import nano.emoji : expandShortcodes;
    foreach (ref sp; f.spans)
        if (!(sp.style & CODE)) sp.text = expandShortcodes(sp.text);
    return f.spans;
}

/// Inline markdown as plain text (table cells).
string inlinePlain(string text) pure
{
    auto o = appender!string;
    foreach (s; inlineSpans(text)) o ~= s.text;
    return o[];
}

unittest
{
    assert(inlineSpans("a **b** c") == [Span("a ", 0), Span("b", BOLD), Span(" c", 0)]);
    assert(inlineSpans("***x***") == [Span("x", BOLD | ITALIC)]);
    assert(inlineSpans("snake_case_name") == [Span("snake_case_name", 0)]);
    assert(inlineSpans("2 * 3 * 4") == [Span("2 * 3 * 4", 0)]);
    assert(inlineSpans("`a``b`") == [Span("a``b", CODE)]);
    assert(inlinePlain("[a](u) and \\*x\\* &amp; &#65;") == "a (u) and *x* & A");
    assert(inlinePlain("[unclosed and [x](y)") == "[unclosed and x (y)");
    assert(inlinePlain("<a@b.co>") == "a@b.co");
    assert(inlinePlain("x ~~y~~ ~z~") == "x y z");
    // A literal wrap mark is text, never metadata: it becomes U+FFFD.
    assert(clean("/tmp/a\uE003b\uE002c\uE004d") == "/tmp/a\uFFFDb\uFFFDc\uFFFDd");
    assert(clean("plain") is "plain");
}
