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

import std.array : appender, replicate;
import std.format : format;
import std.utf : decode;
import nano.lineedit : charWidth;

enum syncStart = "\x1b[?2026h", syncEnd = "\x1b[?2026l";
private enum DIM = "\x1b[2m", BOLD = "\x1b[1m", RESET = "\x1b[0m";

/// The sentinel `editorLines` puts at the cursor (one cell wide), swapped
/// for a reverse-video block after layout.
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
    auto marked = (text[0 .. cursor] ~ cursorMark ~ text[cursor .. $]).to!string;
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

    this(void delegate(string) @safe out_) { this.out_ = out_; }

    /// The next render is a full redraw (something else drew on the screen).
    void invalidate() { started = false; }

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
        // Drop a scroll region a status line left, then clear the screen
        // and scrollback: the frame re-emits the whole transcript.
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
        auto prevTop = prev.length > height ? prev.length - height : 0;
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

    void record(long nowMs) { last = nowMs; }
    bool ready(long nowMs) const { return last == long.min || nowMs - last >= quiet; }
    void clear() { last = long.min; }
    bool pending() const { return last != long.min; }
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

    void clear()
    {
        lines = null;
        cur = null;
        cache = null;
        cr = false;
    }

    void feed(const(ubyte)[] bytes) @trusted
    {
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

    private void endLine()
    {
        lines ~= cur;
        cur = null;
        cr = false;
        if (lines.length > cap)
        {
            auto drop = lines.length - cap * 9 / 10;
            lines = lines[drop .. $];
            cache = cache.length > drop ? cache[drop .. $] : null;
        }
    }

    /// Every line wrapped to `width` (the unfinished line last, if any).
    string[] render(size_t width)
    {
        if (width != cacheWidth) { cache = null; cacheWidth = width; }
        while (cache.length < lines.length) cache ~= wrapAnsi(lines[cache.length], width);
        string[] out_;
        foreach (w; cache) out_ ~= w;
        if (cur.length) out_ ~= wrapAnsi(cur, width);
        return out_;
    }
}

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
    ed = editorLines("› ", "abcdef"d, 0, 5);
    assert(ed.length == 3 && ed[0].canFind("\x1b[7m \x1b[27m"));
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
    t.feed(cast(const(ubyte)[]) "hello\nwor");
    assert(t.lines == ["hello"] && t.cur == "wor");
    t.feed(cast(const(ubyte)[]) "ld\n\x1b[2mdim\x1b[0m\n");
    assert(t.lines == ["hello", "world", "\x1b[2mdim\x1b[0m"]);
    t.feed(cast(const(ubyte)[]) "∴ Thinking: a\r\x1b[2K∴ Thinking: ab\r\x1b[2K∴ Thought\n");
    assert(t.lines[$ - 1] == "∴ Thought");
    auto bytes = cast(const(ubyte)[]) "é\n";
    t.feed(bytes[0 .. 1]);
    t.feed(bytes[1 .. $]);
    assert(t.lines[$ - 1] == "é");
    assert(t.render(3)[0 .. 2] == ["hel", "lo"]);
    t.feed(cast(const(ubyte)[]) "\x1b[H\x1b[2J\x1b[3Jfresh");
    assert(!t.lines.length && t.render(10) == ["fresh"]);
    Transcript small;
    small.cap = 10;
    foreach (n; 0 .. 11) small.feed(cast(const(ubyte)[]) "x\n");
    assert(small.lines.length == 9);
}
