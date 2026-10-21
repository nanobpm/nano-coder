/// The prompt's line editor (port of the core of `lineedit.rs`): a key-mode
/// terminal reader with UTF-8 and wide-character aware editing, multi-line
/// input, history, bracketed paste, Tab completion and the slash-command menu.
///
/// The editing model, key decoding and layout are pure and unit-tested; the
/// `LineEditor` class wires them to a terminal.
module nano.lineedit;

import std.algorithm : min, max, canFind, startsWith;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.string : indexOf;
import std.uni : isWhite, isAlphaNum;

import nano.history : InputHistory;
import commands = nano.commands;

@safe:

// ---------------------------------------------------------------------------
// Keys

enum K
{
    none, insert, submit, newline, left, right, home, end, wordLeft, wordRight, up, down,
    backspace, delete_, killEnd, clearLine, eraseWord, tab, escape, interrupt, eof, paste, ignored, closed,
}

struct Key
{
    K kind;
    string text; /// insert / paste
}

/// Reads one byte, waiting at most `timeoutMs` (-1 = forever): the byte, or
/// -1 on timeout, -2 at end of input.
alias ByteSource = int delegate(int timeoutMs) @safe;

/// How long to wait after Esc for the rest of an escape sequence.
enum escapeWaitMs = 30;

/// Decode the next key from `next`. Returns K.none on timeout.
Key decode(ByteSource next, int timeoutMs, ref ubyte[] utf8)
{
    auto b = next(timeoutMs);
    if (b == -1) return Key(K.none);
    if (b == -2) return Key(K.closed);
    switch (b)
    {
        case '\r': return Key(K.submit);
        case '\n': return Key(K.newline); // Ctrl-J
        case 0x01: return Key(K.home);
        case 0x02: return Key(K.left);
        case 0x03: return Key(K.interrupt);
        case 0x04: return Key(K.eof); // Ctrl-D: EOF on an empty line, else delete
        case 0x05: return Key(K.end);
        case 0x06: return Key(K.right);
        case 0x08, 0x7f: return Key(K.backspace);
        case 0x09: return Key(K.tab);
        case 0x0b: return Key(K.killEnd);
        case 0x0e: return Key(K.down);
        case 0x10: return Key(K.up);
        case 0x15: return Key(K.clearLine);
        case 0x17: return Key(K.eraseWord);
        case 0x1b: return decodeEscape(next);
        default:
            if (b < 0x20) return Key(K.ignored);
            utf8 ~= cast(ubyte) b;
            auto need = utf8Length(utf8[0]);
            if (need == 0) { utf8 = null; return Key(K.ignored); }
            while (utf8.length < need)
            {
                auto c = next(escapeWaitMs);
                if (c < 0 || (c & 0xC0) != 0x80) { utf8 = null; return Key(K.ignored); }
                utf8 ~= cast(ubyte) c;
            }
            auto s = (() @trusted => cast(string) utf8.idup)();
            utf8 = null;
            import std.utf : validate;
            try validate(s); catch (Exception) return Key(K.ignored);
            return Key(K.insert, s);
    }
}

private size_t utf8Length(ubyte lead) pure nothrow
{
    if (lead < 0x80) return 1;
    if ((lead & 0xE0) == 0xC0) return 2;
    if ((lead & 0xF0) == 0xE0) return 3;
    if ((lead & 0xF8) == 0xF0) return 4;
    return 0;
}

private Key decodeEscape(ByteSource next)
{
    auto intro = next(escapeWaitMs);
    if (intro < 0) return Key(K.escape);
    if (intro == '[' || intro == 'O')
    {
        ubyte[] seq = [0x1b, cast(ubyte) intro];
        for (;;)
        {
            auto c = next(escapeWaitMs);
            if (c < 0) break;
            seq ~= cast(ubyte) c;
            if (c >= 0x40 && c <= 0x7e) break;
        }
        auto s = (() @trusted => cast(string) seq.idup)();
        if (s == "\x1b[200~") return Key(K.paste, readPaste(next));
        if (s == "\x1b[M") // legacy mouse report: drop its three coordinate bytes
            foreach (_; 0 .. 3) if (next(0) < 0) break;
        return parseEscape(s);
    }
    if (intro == '\r') return Key(K.newline); // Alt-Enter
    if (intro == 'b') return Key(K.wordLeft);
    if (intro == 'f') return Key(K.wordRight);
    if (intro == 0x7f) return Key(K.eraseWord); // Alt-Backspace
    if (intro == 0x1b) return Key(K.escape, "\x1b"); // the caller re-reads the second Esc as its own key
    return Key(K.ignored);
}

/// Interpret a complete escape sequence (CSI `ESC [ …` or SS3 `ESC O x`).
Key parseEscape(string seq)
{
    switch (seq)
    {
        case "\x1bOD": return Key(K.left);
        case "\x1bOC": return Key(K.right);
        case "\x1bOA": return Key(K.up);
        case "\x1bOB": return Key(K.down);
        case "\x1bOH": return Key(K.home);
        case "\x1bOF": return Key(K.end);
        default: break;
    }
    if (seq.length < 3 || !seq.startsWith("\x1b[")) return Key(K.ignored);
    auto body_ = seq[2 .. $ - 1];
    auto fin = seq[$ - 1];
    if (body_.startsWith("<")) return Key(K.ignored); // SGR mouse
    if (fin == '~')
    {
        switch (body_)
        {
            case "3": return Key(K.delete_);
            case "1", "7": return Key(K.home);
            case "4", "8": return Key(K.end);
            default: break;
        }
        // modifyOtherKeys: CSI 27 ; modifier ; key ~
        if (body_.startsWith("27;"))
        {
            auto parts = splitNums(body_[3 .. $]);
            if (parts.length >= 2) return modifiedKey(parts[1], parts[0]);
        }
        return Key(K.ignored);
    }
    if (fin == 'u') // kitty: CSI key[:alt] ; modifier[:event] u
    {
        auto parts = splitNums(body_);
        if (!parts.length) return Key(K.ignored);
        return modifiedKey(parts[0], parts.length > 1 ? parts[1] : 1);
    }
    if ("ABCDHF".canFind(fin))
    {
        // xterm modifier: 1 + (shift=1, alt=2, ctrl=4); Alt or Ctrl jumps by word.
        auto nums = splitNums(body_);
        auto bits = (nums.length ? nums[$ - 1] : 1) - 1;
        bool word = (bits & 6) != 0;
        switch (fin)
        {
            case 'C': return Key(word ? K.wordRight : K.right);
            case 'D': return Key(word ? K.wordLeft : K.left);
            case 'A': return Key(K.up);
            case 'B': return Key(K.down);
            case 'H': return Key(K.home);
            default: return Key(K.end);
        }
    }
    return Key(K.ignored); // includes Shift-Tab (CSI Z) and focus reports
}

/// `key` with an xterm/kitty `modifier` (lock bits masked off).
private Key modifiedKey(uint key, uint modifier)
{
    enum shift = 1, alt = 2, ctrl = 4, super_ = 8;
    auto bits = (modifier ? modifier - 1 : 0) & ~(64u | 128u);
    if (key == 13 && (bits & (ctrl | super_ | alt | shift))) return Key(K.newline);
    if (key == 13 && bits == 0) return Key(K.submit);
    if (key == 27 && (bits & ~shift) == 0) return Key(K.escape);
    if (((key >= 0x41 && key <= 0x5a) || (key >= 0x61 && key <= 0x7a)) && (bits & ~shift) == ctrl)
    {
        ubyte[] one = [cast(ubyte)(key & 0x1f)];
        ubyte[] none;
        auto i = 0;
        return decode((int) => i++ == 0 ? one[0] : -1, 0, none);
    }
    if (key == 'b' && bits == alt) return Key(K.wordLeft);
    if (key == 'f' && bits == alt) return Key(K.wordRight);
    return Key(K.ignored);
}

private uint[] splitNums(string s)
{
    uint[] out_;
    import std.algorithm : splitter;
    foreach (part; s.splitter(';'))
    {
        auto p = part;
        auto colon = p.indexOf(':');
        if (colon >= 0) p = p[0 .. colon];
        try out_ ~= p.length ? p.to!uint : 1;
        catch (Exception) out_ ~= 1;
    }
    return out_;
}

/// A bracketed paste body, up to `ESC [ 201 ~`. CR LF and lone CR become LF;
/// tabs become four spaces; other control bytes are dropped.
string readPaste(ByteSource next)
{
    enum end = "\x1b[201~";
    ubyte[] buf;
    for (;;)
    {
        auto c = next(1000);
        if (c < 0) break;
        buf ~= cast(ubyte) c;
        if (buf.length >= end.length && buf[$ - end.length .. $] == cast(const(ubyte)[]) end)
        {
            buf = buf[0 .. $ - end.length];
            break;
        }
    }
    import std.utf : byDchar;
    auto raw = (() @trusted => cast(string) buf.idup)();
    string out_;
    bool cr;
    foreach (dchar ch; raw.byDchar)
    {
        if (ch == '\r') { out_ ~= '\n'; cr = true; continue; }
        if (ch == '\n' && cr) { cr = false; continue; }
        cr = false;
        if (ch == '\t') out_ ~= "    ";
        else if (ch == '\n' || ch >= 0x20 && ch != 0x7f && ch != 0xfffd) out_ ~= ch.to!string;
    }
    return out_;
}

// ---------------------------------------------------------------------------
// Editing model

/// Terminal columns `ch` occupies: 0 for combining marks and zero-width
/// characters, 2 for East Asian wide/fullwidth characters and emoji.
size_t charWidth(dchar ch) pure nothrow
{
    if (ch == 0x200B || ch == 0x200C || ch == 0x200D || ch == 0xFE0F || ch == 0xFE0E) return 0;
    if ((ch >= 0x300 && ch <= 0x36F) || (ch >= 0x1AB0 && ch <= 0x1AFF) || (ch >= 0x20D0 && ch <= 0x20FF)
        || (ch >= 0xFE20 && ch <= 0xFE2F)) return 0;
    if ((ch >= 0x1100 && ch <= 0x115F) || (ch >= 0x2E80 && ch <= 0x303E) || (ch >= 0x3041 && ch <= 0x33FF)
        || (ch >= 0x3400 && ch <= 0x4DBF) || (ch >= 0x4E00 && ch <= 0x9FFF) || (ch >= 0xA000 && ch <= 0xA4CF)
        || (ch >= 0xAC00 && ch <= 0xD7A3) || (ch >= 0xF900 && ch <= 0xFAFF) || (ch >= 0xFE30 && ch <= 0xFE4F)
        || (ch >= 0xFF00 && ch <= 0xFF60) || (ch >= 0xFFE0 && ch <= 0xFFE6) || (ch >= 0x1F300 && ch <= 0x1F64F)
        || (ch >= 0x1F900 && ch <= 0x1F9FF) || (ch >= 0x20000 && ch <= 0x3FFFD)) return 2;
    return 1;
}

size_t textWidth(string s) pure
{
    size_t w;
    foreach (dchar c; s) w += charWidth(c);
    return w;
}

struct Pos { size_t row, col; }

/// Where each position lands when `buf` is drawn after a prompt `promptW`
/// columns wide in a terminal `width` columns wide. Continuation lines (after
/// a newline) are indented by `promptW`. Returns the cursor and end positions.
void layout(const dchar[] buf, size_t promptW, size_t width, size_t cursor, out Pos cur, out Pos end) pure
{
    width = max(width, 2);
    auto indent = promptW < width ? promptW : 0;
    size_t row, col = promptW % width;
    row = promptW / width;
    Pos norm() { return col >= width ? Pos(row + 1, 0) : Pos(row, col); }
    foreach (i, ch; buf)
    {
        auto w = ch == '\n' ? 0 : charWidth(ch);
        // Wrap first, so a cursor before a wrapping character sits where it's drawn.
        if (ch != '\n' && (col >= width || col + w > width)) { ++row; col = 0; }
        if (i == cursor) cur = norm();
        if (ch == '\n') { ++row; col = indent; continue; }
        col += w;
    }
    end = norm();
    if (cursor >= buf.length) cur = end;
}

/// The editable line: text as code points, a cursor, history.
struct EditState
{
    dchar[] buf;
    size_t cursor;
    InputHistory history;
    bool menuHidden; /// Esc hid the command menu for this line

    string text() const { return buf.to!string; }

    void set(string s)
    {
        buf = s.to!(dchar[]);
        cursor = buf.length;
    }

    /// Take the line and reset (recording it in the history).
    string take()
    {
        auto t = text;
        history.record(t);
        history.edited();
        buf = null;
        cursor = 0;
        menuHidden = false;
        return t;
    }

    private void changed() { history.edited(); menuHidden = false; }

    void insert(string s)
    {
        auto d = s.to!(dchar[]);
        buf = buf[0 .. cursor] ~ d ~ buf[cursor .. $];
        cursor += d.length;
        changed();
    }

    void backspace()
    {
        if (!cursor) return;
        // Remove a base character with any combining marks after it as one.
        auto start = cursor - 1;
        while (start > 0 && charWidth(buf[start]) == 0) --start;
        buf = buf[0 .. start] ~ buf[cursor .. $];
        cursor = start;
        changed();
    }

    void delete_()
    {
        if (cursor >= buf.length) return;
        auto stop = cursor + 1;
        while (stop < buf.length && charWidth(buf[stop]) == 0) ++stop;
        buf = buf[0 .. cursor] ~ buf[stop .. $];
        changed();
    }

    void left() { while (cursor > 0) { --cursor; if (charWidth(buf[cursor]) != 0) break; } }
    void right() { if (cursor < buf.length) ++cursor; while (cursor < buf.length && charWidth(buf[cursor]) == 0) ++cursor; }

    /// Home/End move within the current line of a multi-line input.
    void home() { while (cursor > 0 && buf[cursor - 1] != '\n') --cursor; }
    void end() { while (cursor < buf.length && buf[cursor] != '\n') ++cursor; }

    private static bool wordChar(dchar c) { return isAlphaNum(c) || c == '_'; }

    void wordLeft()
    {
        while (cursor > 0 && !wordChar(buf[cursor - 1])) --cursor;
        while (cursor > 0 && wordChar(buf[cursor - 1])) --cursor;
    }

    void wordRight()
    {
        while (cursor < buf.length && !wordChar(buf[cursor])) ++cursor;
        while (cursor < buf.length && wordChar(buf[cursor])) ++cursor;
    }

    /// Ctrl-W: delete the whitespace-delimited word before the cursor.
    void eraseWord()
    {
        auto start = cursor;
        while (start > 0 && isWhite(buf[start - 1])) --start;
        while (start > 0 && !isWhite(buf[start - 1])) --start;
        if (start == cursor) return;
        buf = buf[0 .. start] ~ buf[cursor .. $];
        cursor = start;
        changed();
    }

    void killEnd()
    {
        auto stop = cursor;
        while (stop < buf.length && buf[stop] != '\n') ++stop;
        if (stop == cursor && stop < buf.length) ++stop; // at a line end: join the next line
        buf = buf[0 .. cursor] ~ buf[stop .. $];
        changed();
    }

    /// Clear the whole input; false when it was already empty.
    bool clear()
    {
        if (!buf.length) return false;
        buf = null;
        cursor = 0;
        changed();
        return true;
    }

    /// Up: in a multi-line input, the line above; else the previous history entry.
    void up()
    {
        if (moveLine(-1)) return;
        auto e = history.up(text);
        if (e !is null) set(e);
    }

    void down()
    {
        if (moveLine(1)) return;
        auto e = history.down();
        if (e !is null) set(e);
    }

    /// Move the cursor to the same column one line up/down within the input.
    private bool moveLine(int dir)
    {
        size_t lineStart = cursor;
        while (lineStart > 0 && buf[lineStart - 1] != '\n') --lineStart;
        auto col = cursor - lineStart;
        if (dir < 0)
        {
            if (lineStart == 0) return false;
            size_t prevStart = lineStart - 1;
            while (prevStart > 0 && buf[prevStart - 1] != '\n') --prevStart;
            cursor = min(prevStart + col, lineStart - 1);
            return true;
        }
        size_t lineEnd = cursor;
        while (lineEnd < buf.length && buf[lineEnd] != '\n') ++lineEnd;
        if (lineEnd >= buf.length) return false;
        size_t nextEnd = lineEnd + 1;
        while (nextEnd < buf.length && buf[nextEnd] != '\n') ++nextEnd;
        cursor = min(lineEnd + 1 + col, nextEnd);
        return true;
    }

    /// Tab: complete a `/command` typed so far (the whole line, no spaces yet).
    void tab()
    {
        auto t = text;
        if (cursor != buf.length || !t.startsWith("/") || t.canFind(' ')) return;
        if (auto c = commands.complete(t)) set(c);
        changed();
    }

    /// Menu rows for the current line.
    string[] menu(size_t cols, size_t maxRows)
    {
        if (menuHidden || cursor != buf.length) return null;
        return commands.menu(text, cols, maxRows);
    }
}

// ---------------------------------------------------------------------------
// Terminal reader

enum Outcome { line, eof, interrupt, stopped, cancel }

struct Result
{
    Outcome outcome;
    string text;
}

/// Max rows of the command menu.
enum menuRows = 8;

final class LineEditor
{
    EditState state;
    private ByteSource src;
    private void delegate(string) @safe out_;
    private size_t delegate() @safe width;
    private size_t drawnRow;
    private bool drawn;
    private string prompt, styledPrompt, notice;
    private size_t promptW;
    private ubyte[] utf8;
    private int pushback = -1;
    private long lastEscMs = long.min / 2;
    long delegate() @safe nowMs;

    this(ByteSource src, void delegate(string) @safe out_, size_t delegate() @safe width)
    {
        this.src = (int t) {
            if (pushback >= 0) { auto b = pushback; pushback = -1; return b; }
            return src(t);
        };
        this.out_ = out_;
        this.width = width;
        nowMs = () @trusted {
            import core.time : MonoTime;
            return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
        };
    }

    /// Read a line. `turn` = a turn is running: Esc Esc and Ctrl-C return
    /// `cancel`. `stop` (polled every 100 ms) ends the read with `stopped`,
    /// keeping the typed text for the next call.
    Result readLine(string prompt, string styledPrompt, bool turn = false, bool delegate() @safe stop = null)
    {
        this.prompt = prompt;
        this.styledPrompt = styledPrompt;
        promptW = textWidth(prompt);
        notice = null;
        if (!turn || state.buf.length) render();
        for (;;)
        {
            auto key = decode(src, stop is null ? -1 : 100, utf8);
            if (key.kind == K.none)
            {
                if (stop !is null && stop()) { erase(); return Result(Outcome.stopped); }
                continue;
            }
            notice = null;
            final switch (key.kind)
            {
                case K.none, K.ignored: break;
                case K.submit:
                    if (auto note = commands.rejection(state.text))
                    {
                        notice = "\x1b[2m" ~ note ~ "\x1b[0m";
                        break;
                    }
                    if (turn) erase(); else finish();
                    return Result(Outcome.line, state.take());
                case K.newline: state.insert("\n"); break;
                case K.insert, K.paste: state.insert(key.text); break;
                case K.left: state.left(); break;
                case K.right: state.right(); break;
                case K.home: state.home(); break;
                case K.end: state.end(); break;
                case K.wordLeft: state.wordLeft(); break;
                case K.wordRight: state.wordRight(); break;
                case K.up: state.up(); break;
                case K.down: state.down(); break;
                case K.backspace: state.backspace(); break;
                case K.delete_: state.delete_(); break;
                case K.killEnd: state.killEnd(); break;
                case K.clearLine: state.clear(); break;
                case K.eraseWord: state.eraseWord(); break;
                case K.tab: state.tab(); break;
                case K.interrupt:
                    state.clear();
                    erase();
                    return Result(turn ? Outcome.cancel : Outcome.interrupt);
                case K.closed:
                    finish();
                    return Result(Outcome.eof);
                case K.eof:
                    if (state.buf.length) { state.delete_(); break; }
                    finish();
                    return Result(Outcome.eof);
                case K.escape:
                    if (key.text.length) pushback = 0x1b;
                    auto now = nowMs();
                    bool second = now - lastEscMs <= 500;
                    lastEscMs = second ? long.min / 2 : now;
                    if (state.menu(80, menuRows).length) { state.menuHidden = true; break; }
                    if (!second) break;
                    if (turn) { erase(); return Result(Outcome.cancel); }
                    state.clear();
                    break;
            }
            render();
        }
    }

    /// Remove what the editor drew (the cursor ends at its first row).
    void erase()
    {
        if (!drawn) return;
        out_((drawnRow ? format("\x1b[%sA", drawnRow) : "") ~ "\r\x1b[J");
        drawn = false;
        drawnRow = 0;
    }

    private void finish()
    {
        state.cursor = state.buf.length;
        render(false);
        out_("\n");
        drawn = false;
        drawnRow = 0;
    }

    private void render(bool extras = true)
    {
        auto w = max(width(), 2);
        Pos cur, end;
        layout(state.buf, promptW, w, state.cursor, cur, end);
        string s = drawn && drawnRow ? format("\x1b[%sA", drawnRow) : "";
        s ~= "\r\x1b[J" ~ styledPrompt;
        auto indent = promptW < w ? promptW : 0;
        foreach (ch; state.buf)
        {
            if (ch == '\n') s ~= "\r\n" ~ spaces(indent);
            else s ~= ch.to!string;
        }
        // At exactly the right margin the terminal defers the wrap: force it.
        if (end.col == 0 && end.row > 0 && (state.buf.length ? state.buf[$ - 1] != '\n' : true)) s ~= " \r\x1b[K";
        string[] rows;
        if (extras)
        {
            if (notice.length) rows = [notice];
            else rows = state.menu(w, menuRows);
        }
        foreach (r; rows) s ~= "\r\n" ~ r;
        auto up = end.row + rows.length - cur.row;
        if (up) s ~= format("\x1b[%sA", up);
        s ~= "\r";
        if (cur.col) s ~= format("\x1b[%sC", cur.col);
        out_(s);
        drawn = true;
        drawnRow = cur.row;
    }

    private static string spaces(size_t n) pure { string r; foreach (_; 0 .. n) r ~= ' '; return r; }
}

// ---------------------------------------------------------------------------
// Terminal plumbing

version (Posix)
{
    import core.sys.posix.termios;

    private __gshared termios saved;
    private __gshared bool keyMode;

    /// Key mode: no canonical input, echo or signals (Ctrl-C arrives as a
    /// byte), and bracketed paste. Output processing stays on.
    bool enterKeyMode(int fd) @trusted
    {
        if (keyMode) return true;
        if (tcgetattr(fd, &saved) != 0) return false;
        auto t = saved;
        t.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
        t.c_iflag &= ~(IXON | ICRNL | INLCR);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        if (tcsetattr(fd, TCSANOW, &t) != 0) return false;
        keyMode = true;
        writeFd(1, "\x1b[?2004h");
        import core.stdc.stdlib : atexit;
        static bool registered;
        if (!registered) { registered = true; atexit(&restoreAtExit); }
        return true;
    }

    void leaveKeyMode(int fd = 0) @trusted nothrow
    {
        if (!keyMode) return;
        tcsetattr(fd, TCSANOW, &saved);
        keyMode = false;
        writeFd(1, "\x1b[?2004l");
    }

    private extern (C) void restoreAtExit() nothrow { leaveKeyMode(0); }

    void writeFd(int fd, string s) @trusted nothrow
    {
        import core.sys.posix.unistd : write;
        while (s.length)
        {
            auto n = write(fd, s.ptr, s.length);
            if (n <= 0) return;
            s = s[n .. $];
        }
    }

    /// Terminal width of `fd` (80 when unknown).
    size_t terminalWidth(int fd = 1) @trusted
    {
        import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
        winsize ws;
        if (ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) return ws.ws_col;
        return 80;
    }

    /// A ByteSource reading `fd` with poll.
    ByteSource fdSource(int fd) @trusted
    {
        import core.sys.posix.poll : pollfd, poll, POLLIN;
        import core.sys.posix.unistd : read;
        ubyte[] pending;
        return (int timeoutMs) @trusted {
            if (pending.length)
            {
                auto b = pending[0];
                pending = pending[1 .. $];
                return cast(int) b;
            }
            pollfd p = pollfd(fd, POLLIN, 0);
            auto r = poll(&p, 1, timeoutMs);
            if (r == 0) return -1;
            if (r < 0) return -1; // EINTR: treat as a timeout, the caller loops
            ubyte[256] buf;
            auto n = read(fd, buf.ptr, buf.length);
            if (n <= 0) return -2;
            pending = buf[1 .. n].dup;
            return cast(int) buf[0];
        };
    }
}

// ---------------------------------------------------------------------------
// Tests

version (unittest)
{
    /// Scripted input: the bytes of `keys`, then end of input.
    ByteSource script(string keys)
    {
        size_t i;
        // `\xff` stands for a pause: the read times out.
        return (int) {
            if (i >= keys.length) return -2;
            auto b = keys[i++];
            return b == 0xff ? -1 : cast(int) b;
        };
    }

    LineEditor editor(string keys, ref string screen, size_t w = 40)
    {
        auto e = new LineEditor(script(keys), (string s) { screen ~= s; }, () => w);
        return e;
    }
}

unittest // editing keys
{
    string screen;
    auto e = editor("helo\x02l\x01X\x05!\r", screen);
    assert(e.readLine("› ", "› ") == Result(Outcome.line, "Xhello!"));
    e = editor("one two three\x17\x17four\r", screen);
    assert(e.readLine("> ", "> ").text == "one four");
    e = editor("abc\x1b[D\x1b[D\x0b\r", screen);
    assert(e.readLine("> ", "> ").text == "a");
    e = editor("abc\x1b[D\x1b[3~\r", screen); // Delete
    assert(e.readLine("> ", "> ").text == "ab");
    e = editor("foo bar\x1bb\x1bbX\x1b[1;5CY\r", screen); // Alt-b twice, Ctrl-Right
    assert(e.readLine("> ", "> ").text == "XfooY bar");
    e = editor("x\x15y\r", screen); // Ctrl-U
    assert(e.readLine("> ", "> ").text == "y");
}

unittest // UTF-8, wide characters and combining marks
{
    string screen;
    auto e = editor("h\xc3\xa9llo \xe4\xb8\x96\x7f\x7f\r", screen);
    assert(e.readLine("> ", "> ").text == "héllo");
    e = editor("e\xcc\x81x\x1b[D\x7f\r", screen); // e + combining acute: one backspace removes both
    assert(e.readLine("> ", "> ").text == "x");
    assert(charWidth('世') == 2 && charWidth('\u0301') == 0 && textWidth("a世") == 3);
}

unittest // multi-line input: Ctrl-J, Alt-Enter, kitty/modifyOtherKeys Ctrl-Enter, paste
{
    string screen;
    auto e = editor("a\nb\x1b\rc\x1b[13;5ud\x1b[27;5;13~e\r", screen);
    assert(e.readLine("> ", "> ").text == "a\nb\nc\nd\ne");
    e = editor("x\x1b[200~line1\r\nline2\tz\x1b[201~\r", screen);
    assert(e.readLine("> ", "> ").text == "xline1\nline2    z");
    // Up/Down move between lines of the input before recalling history.
    e = editor("abc\ndef\x1b[A\x1b[DX\r", screen);
    assert(e.readLine("> ", "> ").text == "abXc\ndef");
}

unittest // history recall; Ctrl-D; Ctrl-C
{
    string screen;
    auto e = editor("first\rsecond\r\x1b[A\x1b[A\rdraft\x1b[A\x1b[B\r", screen);
    assert(e.readLine("> ", "> ").text == "first");
    assert(e.readLine("> ", "> ").text == "second");
    assert(e.readLine("> ", "> ").text == "first");
    assert(e.readLine("> ", "> ").text == "draft");
    e = editor("ab\x01\x04\r\x04", screen);
    assert(e.readLine("> ", "> ").text == "b");
    assert(e.readLine("> ", "> ").outcome == Outcome.eof);
    e = editor("junk\x03ok\r", screen);
    assert(e.readLine("> ", "> ").outcome == Outcome.interrupt);
    assert(e.readLine("> ", "> ").text == "ok");
    e = editor("x\x03", screen);
    assert(e.readLine("", "", true).outcome == Outcome.cancel);
}

unittest // slash commands: Tab, menu, rejection, Esc
{
    string screen;
    auto e = editor("/mo\t gpt\r", screen);
    assert(e.readLine("> ", "> ").text == "/model  gpt");
    screen = null;
    e = editor("/he", screen);
    e.readLine("> ", "> ");
    assert(screen.canFind("Show this"), "menu drawn while typing");
    screen = null;
    e = editor("/exin\r\x7f\x7fit\r", screen);
    assert(e.readLine("> ", "> ").text == "/exit");
    assert(screen.canFind("Did you mean /exit?"));
    // Esc hides the menu; Esc Esc clears at the prompt and cancels in a turn.
    long t;
    e = editor("/h\x1b\x1b\xffok\r", screen);
    e.nowMs = () => t += 100;
    assert(e.readLine("> ", "> ").text == "ok");
    e = editor("abc\x1b\x1b", screen);
    e.nowMs = () => t += 100;
    assert(e.readLine("", "", true).outcome == Outcome.cancel);
}

unittest // stop keeps the typed text
{
    string screen;
    bool stopNow;
    size_t i;
    auto keys = "dra";
    auto e = new LineEditor((int) => i < keys.length ? cast(int) keys[i++] : -1, (string s) { screen ~= s; }, () => 40);
    assert(e.readLine("", "", true, () { stopNow = i >= keys.length; return stopNow; }).outcome == Outcome.stopped);
    assert(e.state.text == "dra");
}

unittest // layout: wrapping, wide chars, newlines, exact margin
{
    Pos c, e;
    layout("abcdef"d.dup, 2, 4, 6, c, e);
    assert(e == Pos(2, 0) && c == e);
    layout("ab世"d.dup, 2, 5, 2, c, e); // 世 doesn't fit at col 4: wraps
    assert(c == Pos(1, 0) && e == Pos(1, 2));
    layout("ab\ncd"d.dup, 2, 40, 3, c, e);
    assert(c == Pos(1, 2) && e == Pos(1, 4));
}

unittest // escape parsing
{
    assert(parseEscape("\x1b[1;3D").kind == K.wordLeft && parseEscape("\x1bOH").kind == K.home);
    assert(parseEscape("\x1b[<0;1;1M").kind == K.ignored && parseEscape("\x1b[Z").kind == K.ignored);
    assert(parseEscape("\x1b[119;5u").kind == K.eraseWord); // kitty Ctrl-W
    assert(parseEscape("\x1b[27;6;87~").kind == K.eraseWord); // Ctrl-Shift-W
}
