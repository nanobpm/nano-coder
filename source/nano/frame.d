/// App-owned frame renderer (frame.rs). Each render turns the state into
/// lines at the current width: the transcript, the input editor, then the
/// status bar as the last line. The frame is diffed against the previous one
/// and only what changed is rewritten. A width change clears the screen and
/// scrollback and redraws everything, so history reflows.
///
/// Rust keeps a list of typed items. D keeps the transcript as the logical
/// lines the console printed (`Transcript`, fed the bytes it writes), which
/// reflow the same way; the layout helpers are ported as they are.
module nano.frame;

@safe:

import std.string : representation;
import nano.arith : saturatingSub;

import std.array : appender, replicate;
import std.format : format;
import std.utf : decode;
import nano.lineedit : charWidth;

enum syncStart = "\x1b[?2026h", syncEnd = "\x1b[?2026l";
private enum DIM = "\x1b[2m", BOLD = "\x1b[1m", RESET = "\x1b[0m";

/// The sentinel `editorLines` puts where the cursor has no character to
/// overlay (end of the text, on a newline), swapped for a reverse-video
/// blank after layout.
enum dchar cursorMark = '\0';

size_t cellWidth(dchar c) pure nothrow
{
    return c == cursorMark ? 1 : charWidth(c);
}

private bool isFinal(dchar c) pure nothrow { return c >= '@' && c <= '~'; }

/// Visible width in cells, ignoring CSI sequences.
size_t visibleWidth(string text) pure
{
    size_t n, i;
    while (i < text.length)
    {
        auto c = decode(text, i);
        if (c == '\x1b')
        {
            if (i < text.length && text[i] == '[')
            {
                i++;
                while (i < text.length) if (isFinal(decode(text, i))) break;
            }
            continue;
        }
        n += cellWidth(c);
    }
    return n;
}

private bool isControl(dchar c) pure nothrow { return c < 0x20 || (c >= 0x7f && c < 0xa0); }

/// Expands tabs (8-column stops) and drops every control and escape except
/// SGR styling, so content can't move the cursor out of its row.
string sanitize(string line) pure
{
    enum TAB = 8;
    auto out_ = appender!string;
    size_t col, i;
    while (i < line.length)
    {
        auto c = decode(line, i);
        if (c == '\x1b')
        {
            if (i < line.length && line[i] == '[')
            {
                auto start = i - 1;
                i++;
                dchar fin = 0;
                bool valid = true;
                while (i < line.length)
                {
                    auto n = decode(line, i);
                    if (isFinal(n)) { fin = n; break; }
                    if (!((n >= '0' && n <= '9') || n == ';' || n == ':')) valid = false;
                }
                if (valid && fin == 'm') out_ ~= line[start .. i];
            }
            continue;
        }
        if (c == '\t')
        {
            auto n = TAB - col % TAB;
            out_ ~= " ".replicate(n);
            col += n;
            continue;
        }
        if (c == cursorMark) { out_ ~= c; col++; continue; }
        if (isControl(c)) continue;
        out_ ~= c;
        col += cellWidth(c);
    }
    return out_[];
}

/// Truncates a (styled) string to `width` cells with an ellipsis and reset.
string fit(string text, size_t width) pure
{
    text = sanitize(text);
    if (visibleWidth(text) <= width) return text;
    auto keep = width > 0 ? width - 1 : 0;
    auto out_ = appender!string;
    size_t seen, i;
    while (i < text.length)
    {
        auto at = i;
        auto c = decode(text, i);
        if (c == '\x1b')
        {
            if (i < text.length && text[i] == '[')
            {
                i++;
                while (i < text.length) if (isFinal(decode(text, i))) break;
            }
            out_ ~= text[at .. i];
            continue;
        }
        auto w = cellWidth(c);
        if (seen + w > keep) break;
        out_ ~= c;
        seen += w;
    }
    out_ ~= "…" ~ RESET;
    return out_[];
}

/// Wraps one logical line to `width` cells, keeping escape sequences and
/// breaking at spaces where it can.
string[] wrapAnsi(string line, size_t width) pure
{
    import std.string : stripRight, stripLeft;
    if (width < 1) width = 1;
    line = sanitize(line);
    string[] out_;
    string cur;
    size_t vis;
    ptrdiff_t brk = -1;
    void breakLine()
    {
        if (brk >= 0)
        {
            auto rest = cur[brk .. $];
            out_ ~= cur[0 .. brk].stripRight(" ");
            cur = rest.stripLeft(" ");
            vis = visibleWidth(cur);
        }
        else
        {
            out_ ~= cur;
            cur = null;
            vis = 0;
        }
        brk = -1;
    }
    size_t i;
    while (i < line.length)
    {
        auto at = i;
        auto c = decode(line, i);
        if (c == '\x1b')
        {
            if (i < line.length && line[i] == '[')
            {
                i++;
                while (i < line.length) if (isFinal(decode(line, i))) break;
            }
            cur ~= line[at .. i];
            continue;
        }
        if (c == ' ')
        {
            if (vis >= width)
            {
                out_ ~= cur.stripRight(" ");
                cur = null;
                vis = 0;
                brk = -1;
                continue;
            }
            cur ~= ' ';
            vis++;
            brk = cur.length;
            continue;
        }
        if (vis >= width) breakLine();
        auto w = cellWidth(c);
        if (w > 1 && vis + w > width && cur.length) breakLine();
        cur ~= line[at .. i];
        vis += w;
    }
    out_ ~= cur;
    return out_;
}

/// Splits on newlines and wraps each line.
string[] wrapBlock(string text, size_t width) pure
{
    import std.algorithm : splitter;
    string[] out_;
    foreach (l; text.splitter('\n')) out_ ~= wrapAnsi(l, width);
    return out_;
}

/// The editor as wrapped rows, with a reverse-video block at `cursor` (an
/// index into `text`'s characters). The prompt may be styled.
string[] editorLines(string prompt, dstring text, size_t cursor, size_t width) pure
{
    import std.algorithm : splitter;
    import std.array : replace;
    import std.conv : to;
    if (width < 1) width = 1;
    if (cursor > text.length) cursor = text.length;
    // The block overlays the character after the insertion point in reverse
    // video (as a terminal's own block cursor does); inserting a blank cell
    // there instead shifted the rest of the line one cell right, reading as
    // an off-by-one against Backspace/Delete ("any" cursor-1-back rendered
    // "an y"). `sanitize` keeps well-formed SGR and `wrapAnsi` carries
    // escapes at no cell cost, so the character keeps exactly its own width.
    // The one-cell sentinel (a reverse-video blank) remains only where
    // there is no printable character to overlay.
    string marked;
    if (cursor < text.length && text[cursor] != '\n'
            && (text[cursor] == '\t' || !isControl(text[cursor])))
        marked = text[0 .. cursor].to!string ~ "\x1b[7m"
            ~ text[cursor .. cursor + 1].to!string ~ "\x1b[27m"
            ~ text[cursor + 1 .. $].to!string;
    else
        marked = (text[0 .. cursor] ~ cursorMark ~ text[cursor .. $]).to!string;
    auto pw = visibleWidth(prompt);
    auto inner = width > pw ? width - pw : 1;
    string[] lines;
    size_t n;
    foreach (logical; marked.splitter('\n'))
        lines ~= wrapAnsi(logical, n++ == 0 ? inner : width);
    if (!lines.length) lines = [""];
    lines[0] = BOLD ~ prompt ~ RESET ~ lines[0];
    foreach (ref l; lines) l = fit(l, width).replace("\0", "\x1b[7m \x1b[27m");
    return lines;
}

/// The whole frame: transcript, editor, then the status bar as the last line.
string[] compose(const string[] transcript, const string[] editor, string status) pure
{
    return transcript.dup ~ editor.dup ~ status;
}

/// The dim `⏸N queued` row under the editor (null when nothing is queued).
string queueIndicator(size_t queued, size_t width) pure
{
    return queued ? fit(format("%s⏸%s queued · /queue to edit%s", DIM, queued, RESET), width ? width : 1) : null;
}

/// A hint shown in place of the status bar (e.g. "Ctrl-C again to exit").
string transientStatus(string text, size_t width) pure
{
    return fit(DIM ~ text ~ RESET, width ? width : 1);
}

/// The first line that differs, or -1 when the frames are identical.
ptrdiff_t firstDiff(const string[] prev, const string[] next) pure nothrow
{
    auto common = prev.length < next.length ? prev.length : next.length;
    foreach (i; 0 .. common) if (prev[i] != next[i]) return i;
    return prev.length != next.length ? common : -1;
}

/// The terminal rows a composed line takes once written (wide glyphs that
/// would cross the edge move whole to the next row).
size_t linePhysicalRows(string line, size_t width) pure
{
    if (width < 1) width = 1;
    size_t rows = 1, col, i;
    while (i < line.length)
    {
        auto c = decode(line, i);
        if (c == '\x1b')
        {
            if (i < line.length && line[i] == '[')
            {
                i++;
                while (i < line.length) if (isFinal(decode(line, i))) break;
            }
            continue;
        }
        auto w = cellWidth(c);
        if (!w) continue;
        if (col + w > width && col > 0) { rows++; col = 0; }
        col += w;
    }
    return rows;
}

size_t physicalRows(const string[] frame, size_t width) pure
{
    size_t n;
    foreach (l; frame) n += linePhysicalRows(l, width);
    return n;
}

/// Owns the terminal and renders frames, diffing against the last one: a
/// size change (or the first frame) clears and redraws everything, anything
/// else rewrites from the first changed line. Writes are synchronized output.
final class FrameRenderer
{
    private void delegate(string) @safe out_;
    private string[] prev;
    private size_t width, height;
    private bool started;

    this(void delegate(string) @safe out_) pure { this.out_ = out_; }

    /// The next render is a full redraw (something else drew on the screen).
    void invalidate() pure { started = false; }

    void render(const string[] frame, size_t width, size_t height)
    {
        if (width < 1) width = 1;
        if (height < 1) height = 1;
        if (!started || width != this.width || height != this.height) fullRedraw(frame, width, height);
        else differential(frame, width, height);
        prev = frame.dup;
        this.width = width;
        this.height = height;
        started = true;
    }

    private void fullRedraw(const string[] frame, size_t width, size_t height)
    {
        auto buf = appender!string;
        // Drop any scroll region, then clear the screen and scrollback: the frame re-emits the whole transcript.
        buf ~= syncStart ~ "\x1b[r\x1b[H\x1b[2J\x1b[3J";
        auto physical = physicalRows(frame, width);
        buf ~= format("\x1b[%s;1H", physical < height ? height - physical + 1 : 1);
        foreach (i, l; frame)
        {
            if (i) buf ~= "\r\n";
            buf ~= l;
        }
        buf ~= syncEnd;
        out_(buf[]);
    }

    private void differential(const string[] frame, size_t width, size_t height)
    {
        auto diff = firstDiff(prev, frame);
        if (diff < 0) return;
        auto prevPhysical = physicalRows(prev, width), newPhysical = physicalRows(frame, width);
        auto prevTop = saturatingSub(prev.length, height);
        if (prevPhysical != newPhysical || diff < prevTop) return fullRedraw(frame, width, height);
        size_t before;
        foreach (l; frame[0 .. diff]) before += linePhysicalRows(l, width);
        auto row = newPhysical <= height ? height - newPhysical + before + 1 : before - (newPhysical - height) + 1;
        auto buf = appender!string;
        buf ~= syncStart ~ format("\x1b[%s;1H", row);
        foreach (i, l; frame[diff .. $])
        {
            if (i) buf ~= "\r\n";
            buf ~= "\x1b[2K" ~ l;
        }
        buf ~= syncEnd;
        out_(buf[]);
    }
}

/// Collapses a burst of resize events into one render after `quiet` ms.
struct Debouncer
{
    long quiet;
    private long last = long.min;

    void record(long nowMs) pure { last = nowMs; }
    bool ready(long nowMs) pure const { return last == long.min || nowMs - last >= quiet; }
    void clear() pure { last = long.min; }
    bool pending() pure const { return last != long.min; }
}

/// Untrusted text with every line kept and control characters dropped.
string sanitizeLines(string s) pure
{
    import nano.trajectory : terminalSafe;
    import std.algorithm : map;
    import std.array : join, split;
    return s.split('\n').map!(l => terminalSafe(l)).join("\n");
}

/// Expanded detail under a call or thought: sanitized lines, indented by four.
string expandedBody(string text, string style) pure
{
    import std.algorithm : splitter;
    import std.string : strip;
    string out_;
    auto clean = sanitizeLines(text.strip);
    if (!clean.length) return null;
    foreach (l; clean.splitter('\n'))
        out_ ~= "    " ~ (style.length ? style ~ l ~ "\x1b[0m" : l) ~ "\n";
    return out_;
}

/// A tool result with every line shown (`output` already sanitized).
string expandedResult(bool ok, string output, bool color = true) pure
{
    import std.array : replicate, split;
    import std.range : walkLength;
    import std.string : stripRight;
    string mark = ok ? "⎿" : "⎿ error:";
    string on = !color ? "" : ok ? "\x1b[2m" : "\x1b[38;5;203m", off = color ? "\x1b[0m" : "";
    auto body = output.stripRight;
    if (!body.length) return format("  %s%s (no output)%s\n", on, mark, off);
    auto pad = " ".replicate(mark.walkLength + 3);
    string text;
    foreach (i, l; body.split('\n'))
        text ~= (i == 0 ? format("  %s%s %s%s", on, mark, l.stripRight("\r"), off) : pad ~ on ~ l.stripRight("\r") ~ off) ~ "\n";
    return text;
}

// rust: frame.rs::expanded_content_is_sanitized
unittest
{
    assert(expandedResult(true, "a\nb", false) == "  ⎿ a\n    b\n");
    assert(expandedResult(false, "x\ny", false) == "  ⎿ error: x\n           y\n");
    assert(expandedResult(true, "", false) == "  ⎿ (no output)\n");
    import std.algorithm : canFind;
    auto b = expandedBody("{\n  \"a\": 1\n}\x1b]0;pwn\x07\x1b[2J", "");
    assert(b.canFind("    {\n      \"a\": 1\n") && !b.canFind("\x1b"), b);
}

/// The OSC number of a fold mark (`foldMark`).
enum foldOsc = "8770";

/// An in-band mark, written right after a collapsed block, that makes its
/// last `lines` lines a fold: Ctrl-O swaps them for `expanded` (and back).
/// Folds sharing a non-empty `id` (a tool call and its result) toggle
/// together. Only for the frame transcript: a terminal would show it.
string foldMark(string id, size_t lines, string expanded) pure
{
    import std.base64 : Base64;
    import std.conv : to;
    return "\x1b]" ~ foldOsc ~ ";" ~ Base64.encode(id.representation).idup ~ ";" ~ lines.to!string ~ ";"
        ~ Base64.encode(expanded.representation).idup ~ "\x07";
}

/// A block of transcript lines with an alternate (expanded or collapsed) form.
private struct Fold
{
    string id;
    size_t start, length;
    string[] other;
    bool expanded;
}

/// The transcript as the logical lines the console printed. `feed` takes
/// the raw bytes: `\n` ends a line, `\r` and `ESC[K`/`ESC[2K` restart the
/// current one (the live thinking line redraws that way), `ESC[2J` clears
/// everything, SGR styling is kept and other escapes are dropped.
struct Transcript
{
    string[] lines;
    string cur;
    /// Bounded: the oldest lines go once there are more than this.
    size_t cap = 20_000;
    private ubyte[] pending;
    private bool cr;
    private string[][] cache;
    private size_t cacheWidth;
    private Fold[] folds;

    void clear() pure
    {
        folds = null;
        lines = null;
        cur = null;
        cache = null;
        cr = false;
    }

    void feed(scope const(ubyte)[] bytes) pure
    {
        import std.string : indexOf;
        auto buf = pending ~ bytes;
        // Hold back an incomplete UTF-8 sequence for the next call.
        size_t end = buf.length, k = 0;
        while (k < 4 && k < buf.length && (buf[$ - 1 - k] & 0xC0) == 0x80) k++;
        if (k < buf.length)
        {
            auto lead = buf[$ - 1 - k];
            size_t need = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
            if (need > k + 1) end = buf.length - 1 - k;
        }
        pending = buf[end .. $].dup;
        import std.utf : validate, UTFException;
        auto s = cast(string) buf[0 .. end].idup;
        try validate(s);
        catch (UTFException) { import std.encoding : sanitize; s = sanitize(s); }
        size_t i;
        while (i < s.length)
        {
            auto at = i;
            auto c = decode(s, i);
            if (c == '\n') { endLine(); continue; }
            if (c == '\r') { cr = true; continue; }
            if (c == '\x1b')
            {
                if (i < s.length && s[i] == ']')
                {
                    // OSC: up to BEL or ST; an unfinished one waits for more.
                    auto rest = s[i + 1 .. $];
                    auto bel = rest.indexOf('\x07'), st = rest.indexOf("\x1b\\");
                    if (bel < 0 && st < 0)
                    {
                        pending = cast(ubyte[]) s[at .. $].dup ~ pending;
                        return;
                    }
                    auto end_ = bel >= 0 && (st < 0 || bel < st) ? bel : st;
                    osc(rest[0 .. end_]);
                    i += 1 + end_ + (end_ == bel ? 1 : 2);
                    continue;
                }
                if (i < s.length && s[i] == '[')
                {
                    i++;
                    auto ps = i;
                    dchar fin = 0;
                    while (i < s.length) { auto n = decode(s, i); if (isFinal(n)) { fin = n; break; } }
                    auto params = s[ps .. i > ps ? i - 1 : ps];
                    if (fin == 'm') cur ~= s[at .. i];
                    else if (fin == 'K') { cur = null; cr = false; }
                    else if (fin == 'J' && (params == "2" || params == "3")) clear();
                }
                continue;
            }
            if (cr) { cur = null; cr = false; }
            cur ~= s[at .. i];
        }
    }

    private void endLine() pure
    {
        lines ~= cur;
        cur = null;
        cr = false;
        if (lines.length > cap)
        {
            auto drop = lines.length - cap * 9 / 10;
            lines = lines[drop .. $];
            cache = cache.length > drop ? cache[drop .. $] : null;
            Fold[] kept;
            foreach (f; folds)
                if (f.start >= drop) { f.start -= drop; kept ~= f; }
            folds = kept;
        }
    }

    /// A fold mark (`foldMark`); anything else is dropped.
    private void osc(string body) pure
    {
        import std.algorithm : splitter;
        import std.array : array, split;
        import std.base64 : Base64;
        import std.conv : to;
        auto parts = body.split(";");
        if (parts.length != 4 || parts[0] != foldOsc) return;
        try
        {
            auto id = cast(string) Base64.decode(parts[1]).idup;
            auto n = parts[2].to!size_t;
            auto expanded = cast(string) Base64.decode(parts[3]).idup;
            import std.utf : validate;
            validate(id);
            validate(expanded);
            if (!n || n > lines.length) return;
            import std.string : stripRight;
            folds ~= Fold(id, lines.length - n, n, expanded.stripRight("\n").split("\n"));
            // A result arrives expanded when its call already is.
            if (id.length)
                foreach (f; folds[0 .. $ - 1])
                    if (f.id == id && f.expanded) { swap(folds.length - 1, true); break; }
        }
        catch (Exception) {} // a malformed OSC from the terminal is ignored, like any unknown escape
    }

    /// Ctrl-O: swap the latest fold (with the others sharing its id) between
    /// collapsed and expanded. False when there is none.
    bool toggleLatest() pure
    {
        if (!folds.length) return false;
        auto latest = folds[$ - 1];
        bool want = !latest.expanded;
        foreach_reverse (k; 0 .. folds.length)
            if (k == folds.length - 1 || (latest.id.length && folds[k].id == latest.id)) swap(k, want);
        return true;
    }

    /// Shows fold `k` expanded (`want`) or collapsed.
    private void swap(size_t k, bool want) pure
    {
        {
            auto f = &folds[k];
            if (f.expanded == want) return;
            auto shown = lines[f.start .. f.start + f.length].dup;
            lines = lines[0 .. f.start] ~ f.other ~ lines[f.start + f.length .. $];
            long delta = cast(long) f.other.length - cast(long) f.length;
            f.length = f.other.length;
            f.other = shown;
            f.expanded = want;
            foreach (ref g; folds)
                if (g.start > f.start) g.start = cast(size_t)(g.start + delta);
            if (cache.length > f.start) cache = cache[0 .. f.start];
        }
    }

    /// Every line wrapped to `width` (the unfinished line last, if any).
    string[] render(size_t width) pure
    {
        if (width != cacheWidth) { cache = null; cacheWidth = width; }
        while (cache.length < lines.length) cache ~= wrapAnsi(lines[cache.length], width);
        string[] out_;
        foreach (w; cache) out_ ~= w;
        if (cur.length) out_ ~= wrapAnsi(cur, width);
        return out_;
    }
}

// rust: frame.rs::wraps_words_at_the_width
unittest
{
    import std.algorithm : canFind;
    assert(visibleWidth("\x1b[1mab\x1b[0m中") == 4);
    assert(sanitize("a\tb\x1b[2Jc\x1b[31md\r") == "a       bc\x1b[31md");
    assert(sanitize("\x1b[\r31mx") == "x");
    assert(fit("hello world", 6) == "hello…\x1b[0m");
    assert(fit("short", 10) == "short");
    assert(wrapAnsi("the quick brown fox", 9) == ["the quick", "brown fox"]);
    assert(wrapAnsi("abcdefghij", 4) == ["abcd", "efgh", "ij"]);
    assert(wrapAnsi("ab中", 3) == ["ab", "中"]);
    assert(wrapAnsi("", 5) == [""]);
    assert(wrapBlock("a\nb", 5) == ["a", "b"]);
    auto ed = editorLines("› ", "hi"d, 2, 20);
    assert(ed == ["\x1b[1m› \x1b[0mhi\x1b[7m \x1b[27m"], ed[0]);
    // Mid-line the block overlays the character under it, adding no cell:
    // cursor one back over "any" must not render as "an y".
    ed = editorLines("› ", "any"d, 2, 20);
    assert(ed == ["\x1b[1m› \x1b[0man\x1b[7my\x1b[27m"], ed[0]);
    assert(visibleWidth(ed[0]) == 5);
    // On a newline the blank sits at the end of that row.
    ed = editorLines("› ", "ab\ncd"d, 2, 20);
    assert(ed.length == 2 && ed[0].canFind("ab\x1b[7m \x1b[27m"));
    ed = editorLines("› ", "abcdef"d, 0, 5);
    assert(ed.length == 2 && ed[0].canFind("\x1b[7ma\x1b[27m"));
    assert(compose(["t"], ["e"], "s") == ["t", "e", "s"]);
    assert(queueIndicator(0, 40) is null && queueIndicator(2, 40).canFind("⏸2 queued"));
    assert(firstDiff(["a", "b"], ["a", "b"]) == -1 && firstDiff(["a", "b"], ["a", "c"]) == 1 && firstDiff(["a"], ["a", "b"]) == 1);
    assert(linePhysicalRows("abcdef", 3) == 2 && linePhysicalRows("", 3) == 1 && linePhysicalRows("ab中", 3) == 2);
    assert(physicalRows(["abcd", "x"], 3) == 3);

    string screen;
    auto r = new FrameRenderer((string s) { screen ~= s; });
    r.render(["one", "two", "bar"], 10, 5);
    assert(screen.canFind("\x1b[3;1Hone\r\ntwo\r\nbar") && screen.canFind("\x1b[3J"));
    screen = null;
    r.render(["one", "TWO", "bar"], 10, 5);
    assert(screen == syncStart ~ "\x1b[4;1H\x1b[2KTWO\r\n\x1b[2Kbar" ~ syncEnd, screen);
    screen = null;
    r.render(["one", "TWO", "bar"], 10, 5);
    assert(!screen.length);
    r.render(["one", "TWO", "x", "bar"], 10, 5);
    assert(screen.canFind("\x1b[2J"));
    screen = null;
    r.render(["one", "TWO", "x", "bar"], 12, 5);
    assert(screen.canFind("\x1b[2J"));

    Debouncer d = Debouncer(150);
    assert(d.ready(0) && !d.pending);
    d.record(1000);
    assert(!d.ready(1100) && d.ready(1150) && d.pending);
    d.clear();
    assert(!d.pending);

    Transcript t;
    t.feed("hello\nwor".representation);
    assert(t.lines == ["hello"] && t.cur == "wor");
    t.feed("ld\n\x1b[2mdim\x1b[0m\n".representation);
    assert(t.lines == ["hello", "world", "\x1b[2mdim\x1b[0m"]);
    t.feed("∴ Thinking: a\r\x1b[2K∴ Thinking: ab\r\x1b[2K∴ Thought\n".representation);
    assert(t.lines[$ - 1] == "∴ Thought");
    auto bytes = "é\n".representation;
    t.feed(bytes[0 .. 1]);
    t.feed(bytes[1 .. $]);
    assert(t.lines[$ - 1] == "é");
    assert(t.render(3)[0 .. 2] == ["hel", "lo"]);
    t.feed("\x1b[H\x1b[2J\x1b[3Jfresh".representation);
    assert(!t.lines.length && t.render(10) == ["fresh"]);
    Transcript small;
    small.cap = 10;
    foreach (n; 0 .. 11) small.feed("x\n".representation);
    assert(small.lines.length == 9);
}

// ---- Whose turn it is: the prompt glyph and hint (ui.rs prompt_glyph/prompt_hint) ----

/// Placeholder for the prompt glyph in an editor prompt (one cell). The frame
/// thread swaps it for a cyan spinner while a turn runs, or a green `›`.
enum glyphMark = "\uE000";
/// Placeholder the editor puts after the cursor of an empty editor; the frame
/// thread swaps it for the dim hint saying whose turn it is.
enum hintMark = "\uE001";

/// Frames of the busy spinner drawn in place of the prompt glyph.
immutable dchar[10] spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
/// How long each spinner frame shows, in ms; the frame is redrawn this often.
enum long spinnerIntervalMs = 100;

/// The turn's working clock, in ms: when the current run began and the runs
/// already banked. The count shown is working time, not wall time: while a
/// picker (the `question` tool, the turn cap) waits for the user the clock is
/// paused, so the user's thinking time doesn't count as the agent's.
struct WorkClock
{
    long since = -1; /// start of the current run (-1: paused)
    long banked;     /// completed runs

    static WorkClock started(long now) pure nothrow { return WorkClock(now, 0); }

    long elapsed(long now) const pure nothrow
    {
        return banked + (since >= 0 ? saturatingSub(now, since) : 0);
    }

    /// Stop counting. Idempotent, so overlapping pauses never bank twice.
    void pause(long now) pure nothrow
    {
        if (since < 0) return;
        banked += saturatingSub(now, since);
        since = -1;
    }

    /// Count again from `now`, keeping what was banked. A resume without a
    /// pause leaves a running clock alone.
    void resume(long now) pure nothrow
    {
        if (since < 0) since = now;
    }
}

/// `4s`, `1m 05s`: whole seconds of the running turn.
string elapsedText(long ms) pure
{
    auto secs = ms / 1000;
    return secs < 60 ? format("%ss", secs) : format("%sm %02ds", secs / 60, secs % 60);
}

/// The prompt glyph: a cyan spinner while a turn runs (`busy`), a green `›`
/// while the harness waits for the user. A paused clock keeps its spinner.
string promptGlyph(bool busy, long elapsedMs) pure
{
    import std.conv : to;
    if (!busy) return "\x1b[38;5;114m›\x1b[39m";
    auto frame = spinnerFrames[cast(size_t)(elapsedMs / spinnerIntervalMs) % spinnerFrames.length];
    return "\x1b[38;5;117m" ~ frame.to!string ~ "\x1b[39m";
}

/// The dim hint after the cursor of an empty editor: whose turn it is.
string promptHint(bool busy, long elapsedMs) pure
{
    return busy ? "working " ~ elapsedText(elapsedMs) ~ " · Enter steers, Esc Esc cancels"
        : "ready · type a message, /help for commands";
}

/// The editor rows with the glyph and hint placeholders filled in.
string[] decorate(const string[] rows, bool busy, long elapsedMs, size_t width) pure
{
    import std.algorithm : endsWith;
    import std.array : replace;
    string[] out_;
    foreach (i, r; rows)
    {
        string row = r.replace(glyphMark, promptGlyph(busy, elapsedMs));
        if (row.endsWith(hintMark))
            row = fit(row[0 .. $ - hintMark.length] ~ " " ~ DIM ~ promptHint(busy, elapsedMs) ~ RESET, width);
        out_ ~= row;
    }
    return out_;
}

// rust: ui.rs::waiting_for_user_input_does_not_count_as_working_time
unittest // the working clock pauses and resumes
{
    auto c = WorkClock.started(0);
    assert(c.elapsed(3000) == 3000);
    c.pause(3000);
    assert(c.elapsed(63_000) == 3000);
    c.resume(63_000);
    assert(c.elapsed(65_000) == 5000, "working resumes from the banked 3s, not the wall clock");
    c.pause(65_000);
    assert(elapsedText(c.elapsed(300_000)) == "5s");
}

unittest // pausing_and_resuming_the_work_clock_is_idempotent
{
    auto c = WorkClock.started(0);
    c.pause(2000);
    c.pause(9000);
    assert(c.elapsed(10_000) == 2000);
    c.resume(10_000);
    c.resume(12_000);
    assert(c.elapsed(13_000) == 5000);
}

// rust: ui.rs::prompt_glyph_and_hint_say_whose_turn_it_is
unittest // elapsed text, glyph and hint
{
    import std.algorithm : canFind;
    assert(elapsedText(4999) == "4s" && elapsedText(65_000) == "1m 05s");
    assert(promptGlyph(false, 0).canFind("›"));
    assert(promptGlyph(true, 0).canFind("⠋") && promptGlyph(true, 150).canFind("⠙"));
    assert(promptHint(true, 12_000) == "working 12s · Enter steers, Esc Esc cancels");
    assert(promptHint(false, 0)[0 .. 5] == "ready");
    assert(cellWidth('\uE000') == 1 && cellWidth('\uE001') == 1);
}

unittest // decorate fills the placeholders and keeps the row within the width
{
    import std.algorithm : canFind;
    auto rows = decorate([glyphMark ~ " x" ~ hintMark, "more"], true, 2000, 80);
    assert(!rows[0].canFind(glyphMark) && rows[0].canFind("working 2s"));
    assert(rows[1] == "more");
    assert(visibleWidth(decorate([glyphMark ~ " " ~ hintMark], false, 0, 10)[0]) <= 10);
}

// rust: ui.rs::a_paused_work_clock_freezes_the_prompt_and_resumes, ui.rs::the_prompt_spins_during_a_turn_and_shows_ready_after
unittest
{
    import std.algorithm : canFind;
    auto c = WorkClock.started(0);
    c.pause(65_000);
    auto frozen = decorate([glyphMark ~ " " ~ hintMark], true, c.elapsed(90_000), 80)[0];
    assert(frozen == decorate([glyphMark ~ " " ~ hintMark], true, c.elapsed(95_000), 80)[0], "a paused clock banks no wait");
    assert(frozen.canFind("working 1m 05s"), "the prompt still shows the working turn");
    c.resume(95_000);
    assert(c.elapsed(96_000) > 65_000, "resuming counts working time again");
    assert(decorate([glyphMark], true, 0, 80)[0].canFind("⠋"), "a turn spins the glyph");
    assert(decorate([glyphMark], false, 0, 80)[0].canFind("›"), "ready after the turn");
}

// rust: ui.rs::pausing_and_resuming_the_work_clock_is_idempotent
unittest
{
    auto c = WorkClock.started(0);
    c.pause(2000);
    c.pause(9000);
    assert(c.banked == 2000, "a second pause banks nothing");
    c.resume(9000);
    c.resume(30_000);
    assert(c.since == 9000, "a second resume doesn't restart the clock");
    assert(c.elapsed(31_000) == 24_000);
}

// rust: frame.rs::sanitize_rejects_malformed_sgr_parameters, frame.rs::unsafe_terminal_controls_are_stripped_from_layout
// rust: frame.rs::width_counts_terminal_cells_not_scalars, frame.rs::wrapping_preserves_ansi_but_not_its_width
// rust: frame.rs::tabs_are_expanded_so_rows_never_overflow_the_width
// rust: frame.rs::physical_row_helpers_count_native_wraps
// rust: frame.rs::line_physical_rows_counts_wide_glyphs_that_cannot_start_in_the_last_column
// rust: frame.rs::diffs_frames_line_by_line, frame.rs::debouncer_waits_for_quiet
unittest
{
    import std.algorithm : all, canFind;
    import std.array : replicate;
    assert(sanitize("prefix\x1b[\r31mOVERWRITE") == "prefixOVERWRITE");
    assert(sanitize("a\x1b[31\x08mb") == "ab" && sanitize("a\x1b[31 mb") == "ab");
    assert(sanitize("\x1b[1;38:5:200mhi\x1b[0m") == "\x1b[1;38:5:200mhi\x1b[0m");
    foreach (s; ["a\x1b[2Jb", "a\x1b[Hb", "a\rb", "a\x08b", "a\x07b"]) assert(sanitize(s) == "ab", s);
    assert(wrapAnsi(sanitize("evil\x1b[2K\x1b[1;1Hclear"), 40).all!(l => !l.canFind("\x1b") && !l.canFind("\r")));
    assert(visibleWidth("你好") == 4 && visibleWidth("e\u0301") == 1);
    assert(wrapAnsi("你好世界你好世界", 5).all!(l => visibleWidth(l) <= 5));
    assert(visibleWidth(fit("你好世界", 5)) <= 5);
    auto w = wrapAnsi("\x1b[32mhello world again\x1b[0m", 11);
    assert(w.length == 2 && w[0].canFind("\x1b[32m") && visibleWidth(w[0]) == 11);
    assert(visibleWidth(sanitize("\tx\ty")) == 17);
    assert(linePhysicalRows("", 10) == 1 && linePhysicalRows("1234567890", 10) == 1);
    assert(linePhysicalRows("12345678901", 10) == 2 && linePhysicalRows("x".replicate(25), 10) == 3);
    assert(linePhysicalRows("\x1b[2m12345\x1b[0m", 10) == 1);
    assert(physicalRows(["abc", "x".replicate(21), ""], 10) == 5);
    auto line = "1\u4e16\u4e16\u4e16\u4e16\u4e162\u4e16\u4e16\u4e16\u4e16";
    assert(visibleWidth(line) == 20 && linePhysicalRows(line, 10) == 3);
    assert(linePhysicalRows("\x1b[2m" ~ line ~ "\x1b[0m", 10) == 3 && linePhysicalRows("\u4e16", 1) == 1);
    assert(firstDiff(["one", "two", "three"], ["one", "TWO", "three"]) == 1);
    assert(firstDiff(["one", "two"], ["one", "two"]) < 0);
    assert(firstDiff(["one", "two"], ["one", "two", "three"]) == 2);
    auto d = Debouncer(40);
    assert(d.ready(0));
    d.record(0);
    assert(!d.ready(10) && d.ready(40));
}

// rust: frame.rs::ctrl_o_toggles_the_latest_tool_call_and_result_in_place
// rust: frame.rs::ctrl_o_matches_the_call_by_id_not_adjacency
// rust: ui.rs::tool_result_inherits_expansion_from_its_call
unittest
{
    void put(ref Transcript t, string s) { t.feed(s.representation); }
    Transcript t;
    string rows;
    foreach (i; 1 .. 16) rows ~= format("row %s\n", i);
    put(t, "● bash ls\n" ~ foldMark("call_1", 1, "● bash ls\n    {\n      \"command\": \"ls\"\n    }\n"));
    put(t, "● read a.rs\n" ~ foldMark("call_2", 1, "● read a.rs\n    {\"path\": \"a.rs\"}\n"));
    put(t, "interleaved command output\n");
    put(t, "  ⎿ file-a (+1 lines)\n" ~ foldMark("call_1", 1, expandedResult(true, "file-a\nfile-b", false)));
    auto collapsed = t.lines.dup;
    assert(collapsed.length == 4, format("%s", collapsed));
    assert(t.toggleLatest());
    // call_1 and its result expand; call_2 and the output between are untouched.
    assert(t.lines == ["● bash ls", "    {", "      \"command\": \"ls\"", "    }", "● read a.rs",
        "interleaved command output", "  ⎿ file-a", "    file-b"], format("%s", t.lines));
    foreach (w; [12, 20, 80])
        foreach (l; t.render(w)) assert(visibleWidth(l) <= w);
    assert(t.toggleLatest());
    assert(t.lines == collapsed);
    // A result that arrives later expands with its already-expanded call.
    put(t, "● bash pwd\n" ~ foldMark("call_3", 1, "● bash pwd\n    {}\n"));
    assert(t.toggleLatest());
    put(t, "  ⎿ /x (+1 lines)\n" ~ foldMark("call_3", 1, "  ⎿ /x\n    /y\n"));
    assert(t.lines[$ - 4 .. $] == ["● bash pwd", "    {}", "  ⎿ /x", "    /y"], format("%s", t.lines));
    assert(t.toggleLatest()); // collapses the pair
    assert(t.lines[$ - 2 .. $] == ["● bash pwd", "  ⎿ /x (+1 lines)"]);
}

// rust: frame.rs::ctrl_o_toggles_the_latest_thinking_block
unittest
{
    Transcript t;
    assert(!t.toggleLatest());
    auto mark = foldMark("", 1, "∴ Thought for 1.5s\n    first idea\n    second\n");
    // A mark split across reads still applies.
    t.feed(("∴ Thought for 1.5s\n" ~ mark[0 .. 9]).representation);
    t.feed(mark[9 .. $].representation);
    t.feed("after\n".representation);
    assert(t.lines == ["∴ Thought for 1.5s", "after"]);
    assert(t.toggleLatest());
    assert(t.lines == ["∴ Thought for 1.5s", "    first idea", "    second", "after"]);
    // Other OSC sequences are dropped; a fold scrolled past the cap goes.
    t.feed("\x1b]0;title\x07x\n".representation);
    assert(t.lines[$ - 1] == "x");
    t.cap = 4;
    t.feed("a\nb\nc\n".representation);
    assert(!t.toggleLatest());
}
