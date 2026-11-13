/// The prompt's line editor (port of the core of `lineedit.rs`): a key-mode
/// terminal reader with UTF-8 and wide-character aware editing, multi-line
/// input, history, bracketed paste, Tab completion and the slash-command menu.
///
/// The editing model and key decoding are pure and unit-tested; the
/// `LineEditor` class wires them to a terminal and draws only through the
/// frame renderer (`nano.frame`).
module nano.lineedit;

import std.algorithm : min, max, canFind, startsWith;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.string : indexOf;
import std.uni : isWhite, isAlphaNum;

import nano.history : HistoryBrowsing, InputHistory;
import core.time : Duration, MonoTime, seconds;

/// How long a half-typed line holds back a due timer. After this long with
/// no keystrokes the draft counts as abandoned: the timer fires, and the
/// draft is parked for the automatic turn and restored after it (Rust #178).
enum Duration draftHold = 60.seconds;

/// A draft set aside while a timer turn runs (`EditState.parkDraft`).
struct ParkedDraft
{
    private dchar[] buf;
    private size_t cursor;
    private MonoTime lastEdit;
    private ulong generation;
    private HistoryBrowsing browsing;
}
import commands = nano.commands;

@safe:

// ---------------------------------------------------------------------------
// Keys

enum K
{
    none, insert, submit, newline, left, right, home, end, wordLeft, wordRight, up, down,
    backspace, delete_, killEnd, clearLine, eraseWord, tab, escape, interrupt, eof, paste, ignored, closed,
    /// Shift-Tab (CSI Z): cycle the agent mode.
    cycleMode,
    /// Ctrl-O: expand or collapse the latest tool call/result or thought.
    toggleExpand,
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
        case 0x0f: return Key(K.toggleExpand);
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
            auto s = (() => cast(string) utf8.idup)();
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
        auto s = (() => cast(string) seq.idup)();
        if (s == "\x1b[200~") return Key(K.paste, readPaste(next));
        if (s == "\x1b[Z") return Key(K.cycleMode); // Shift-Tab (backtab)
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
    return Key(K.ignored); // includes focus reports
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
    auto raw = (() => cast(string) buf.idup)();
    string out_;
    bool cr;
    foreach (dchar ch; raw.byDchar)
    {
        if (ch == '\r') { out_ ~= '\n'; cr = true; continue; }
        if (ch == '\n' && cr) { cr = false; continue; }
        cr = false;
        if (ch == '\t') out_ ~= "    ";
        else if (ch == '\n' || (ch >= 0x20 && ch != 0x7f && ch != 0xfffd)) out_ ~= ch.to!string;
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
    if (isWideEmoji(ch)) return 2;
    return 1;
}

/// Emoji with East Asian Width "W" outside the CJK blocks (Unicode 15), e.g.
/// U+23F0 ⏰ in the timers status segment: terminals draw these two cells wide.
private bool isWideEmoji(dchar ch) pure nothrow @nogc
{
    static immutable uint[2][] ranges = [
        [0x231A, 0x231B], [0x2329, 0x232A], [0x23E9, 0x23EC], [0x23F0, 0x23F0], [0x23F3, 0x23F3],
        [0x25FD, 0x25FE], [0x2614, 0x2615], [0x2648, 0x2653], [0x267F, 0x267F], [0x2693, 0x2693],
        [0x26A1, 0x26A1], [0x26AA, 0x26AB], [0x26BD, 0x26BE], [0x26C4, 0x26C5], [0x26CE, 0x26CE],
        [0x26D4, 0x26D4], [0x26EA, 0x26EA], [0x26F2, 0x26F3], [0x26F5, 0x26F5], [0x26FA, 0x26FA],
        [0x26FD, 0x26FD], [0x2705, 0x2705], [0x270A, 0x270B], [0x2728, 0x2728], [0x274C, 0x274C],
        [0x274E, 0x274E], [0x2753, 0x2755], [0x2757, 0x2757], [0x2795, 0x2797], [0x27B0, 0x27B0],
        [0x27BF, 0x27BF], [0x2B1B, 0x2B1C], [0x2B50, 0x2B50], [0x2B55, 0x2B55], [0x1F004, 0x1F004],
        [0x1F0CF, 0x1F0CF], [0x1F18E, 0x1F18E], [0x1F191, 0x1F19A], [0x1F200, 0x1F202], [0x1F210, 0x1F23B],
        [0x1F240, 0x1F248], [0x1F250, 0x1F251], [0x1F260, 0x1F265], [0x1F680, 0x1F6C5], [0x1F6CC, 0x1F6CC],
        [0x1F6D0, 0x1F6D2], [0x1F6D5, 0x1F6D7], [0x1F6DC, 0x1F6DF], [0x1F6EB, 0x1F6EC], [0x1F6F4, 0x1F6FC],
        [0x1F7E0, 0x1F7EB], [0x1F7F0, 0x1F7F0], [0x1FA70, 0x1FAFF],
    ];
    foreach (r; ranges) if (ch >= r[0] && ch <= r[1]) return true;
    return false;
}

unittest
{
    assert(charWidth('\u23F0') == 2); // ⏰ timers status segment
    assert(charWidth('\u2705') == 2 && charWidth('\U0001F680') == 2 && charWidth('\u2B50') == 2);
    assert(charWidth('\u2713') == 1 && charWidth('\u2026') == 1 && charWidth('\u25B6') == 1);
}

size_t textWidth(string s) pure
{
    size_t w;
    foreach (dchar c; s) w += charWidth(c);
    return w;
}

/// The editable line: text as code points, a cursor, history.
struct EditState
{
    dchar[] buf;
    size_t cursor;
    InputHistory history;
    bool menuHidden; /// Esc hid the command menu for this line
    /// The last keystroke that edited or moved in the line (zero: none since
    /// the last submission). A draft idle for `draftHold` is stale.
    MonoTime lastEdit;
    /// Bumped by every text change, so a parked draft knows whether the user
    /// typed (or sent) something newer meanwhile.
    ulong generation;

    string text() const { return buf.to!string; }

    /// A fresh half-typed line holds back a due timer; an empty or stale one doesn't.
    bool holdsTimer(MonoTime now) const { return buf.length && !draftIsStale(now); }

    /// The draft has been idle for `draftHold` (or was never touched by a key).
    bool draftIsStale(MonoTime now) const
    {
        return buf.length && (lastEdit == MonoTime.init || now - lastEdit >= draftHold);
    }

    /// Clear the line for a timer turn, returning it to put back afterwards;
    /// false (nothing parked) when the line is empty.
    bool parkDraft(out ParkedDraft parked)
    {
        if (!buf.length) return false;
        parked = ParkedDraft(buf, cursor, lastEdit, generation, history.parkBrowsing());
        buf = null;
        cursor = 0;
        menuHidden = false;
        lastEdit = MonoTime.init;
        return true;
    }

    /// Put a parked draft back, unless the user typed, cleared or sent
    /// something since it was parked. Its age is kept, so a stale draft
    /// doesn't hold the next timer.
    void restoreDraft(ParkedDraft parked)
    {
        if (buf.length || generation != parked.generation) return;
        buf = parked.buf;
        cursor = min(parked.cursor, buf.length);
        menuHidden = false;
        lastEdit = parked.lastEdit;
        history.restoreBrowsing(parked.browsing);
    }

    private void active() { lastEdit = MonoTime.currTime; }

    /// Run a cursor move; moving counts as activity, a no-op doesn't.
    private void move(scope void delegate() @safe f)
    {
        auto before = cursor;
        f();
        if (cursor != before) active();
    }

    void set(string s)
    {
        buf = s.to!(dchar[]);
        cursor = buf.length;
    }

    /// Take the line and reset (recording it in the history). A blank
    /// Enter changes nothing else, so a parked draft and history browsing
    /// survive it.
    string take()
    {
        auto t = text;
        lastEdit = MonoTime.init;
        if (t.length)
        {
            history.record(t);
            history.edited();
            ++generation;
        }
        buf = null;
        cursor = 0;
        menuHidden = false;
        return t;
    }

    private void changed() { history.edited(); menuHidden = false; ++generation; active(); }

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

    void left() { move({ while (cursor > 0) { --cursor; if (charWidth(buf[cursor]) != 0) break; } }); }
    void right() { move({ if (cursor < buf.length) ++cursor; while (cursor < buf.length && charWidth(buf[cursor]) == 0) ++cursor; }); }

    /// Home/End move within the current line of a multi-line input.
    void home() { move({ while (cursor > 0 && buf[cursor - 1] != '\n') --cursor; }); }
    void end() { move({ while (cursor < buf.length && buf[cursor] != '\n') ++cursor; }); }

    private static bool wordChar(dchar c) { return isAlphaNum(c) || c == '_'; }

    void wordLeft()
    {
        move({
            while (cursor > 0 && !wordChar(buf[cursor - 1])) --cursor;
            while (cursor > 0 && wordChar(buf[cursor - 1])) --cursor;
        });
    }

    void wordRight()
    {
        move({
            while (cursor < buf.length && !wordChar(buf[cursor])) ++cursor;
            while (cursor < buf.length && wordChar(buf[cursor])) ++cursor;
        });
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
        if (moveLine(-1)) { active(); return; }
        auto e = history.up(text);
        if (e !is null) { set(e); ++generation; active(); }
    }

    void down()
    {
        if (moveLine(1)) { active(); return; }
        auto e = history.down();
        if (e !is null) { set(e); ++generation; active(); }
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

    /// Tab: complete a `/command` typed so far, or its first argument.
    void tab()
    {
        import std.algorithm : canFind;
        import std.ascii : isWhite;
        auto t = text;
        // Tab is a space outside a command, and past a command name with
        // nothing to complete (a bare ambiguous `/s` and the argument menus
        // stay put).
        if (!t.startsWith("/")) return insert(" ");
        if (cursor != buf.length) return;
        if (auto c = commands.completeLine(t)) set(c);
        else if (t.canFind!isWhite && !commands.hasArgumentMenu(t)) return insert(" ");
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

/// `queue`: Ctrl/Cmd-Enter during a turn (queue the line for a later turn).
enum Outcome { line, eof, interrupt, stopped, cancel, queue }

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
    private size_t delegate() @safe width;
    /// Terminal rows (for `select`'s window); null means 24.
    size_t delegate() @safe rows;
    private size_t height() { return rows is null ? 24 : rows(); }
    private bool drawn;
    private string prompt, styledPrompt, notice;
    /// A dim hint shown under the next prompt until a key is pressed
    /// (e.g. "(Ctrl-C again to exit)"); consumed by the next read.
    string hint;
    private ubyte[] utf8;
    private int pushback = -1;
    private long lastEscMs = long.min / 2;
    long delegate() @safe nowMs;
    /// Shift-Tab: run with the input erased, then the input is redrawn.
    void delegate(K) @safe onAction;
    /// Ctrl-O, at the prompt or mid-turn; the editor is left as it is.
    void delegate() @safe onToggle;
    /// On submit, the styled prompt to redraw the line with (Rust's
    /// `restamp_prompt`: the timestamp becomes the submission time). It must
    /// keep the prompt's visible width.
    string delegate() @safe restyle;

    /// The editor draws only through the frame renderer (`nano.frame`):
    /// `frameDraw` gets the editor rows (cursor marked) whenever they change
    /// (null to clear them), and `frameCommit` the line a finished prompt or
    /// picker leaves behind.
    this(ByteSource src, void delegate(string[] rows) @safe frameDraw, void delegate(string line) @safe frameCommit,
        size_t delegate() @safe width)
    {
        this.frameDraw = frameDraw;
        this.frameCommit = frameCommit;
        this.src = (int t) {
            if (pushback >= 0) { auto b = pushback; pushback = -1; return b; }
            return src(t);
        };
        this.width = width;
        nowMs = () {
            import core.time : MonoTime;
            return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
        };
    }

    /// Read a line. `turn` = a turn is running: Esc Esc and Ctrl-C return
    /// `cancel`. `stop` (polled every 100 ms) ends the read with `stopped`,
    /// keeping the typed text for the next call.
    Result readLine(string prompt, string styledPrompt, bool turn = false, bool delegate() @safe stop = null)
    {
        plain = masked = false;
        return read(prompt, styledPrompt, turn, stop);
    }

    /// A value prompt (`/settings`): no slash menu or command checks, the
    /// buffer starts as `initial`, and `masked` shows `*` for each character.
    /// Esc (twice, or once on an empty line) and Ctrl-C cancel.
    Result readValue(string prompt, string styledPrompt, string initial, bool masked = false)
    {
        import std.conv : to;
        plain = true;
        this.masked = masked;
        state.buf = initial.to!(dchar[]);
        state.cursor = state.buf.length;
        scope (exit) plain = this.masked = false;
        return read(prompt, styledPrompt, false, null);
    }

    private bool plain, masked;

    private void delegate(string[] rows) @safe frameDraw;
    private void delegate(string line) @safe frameCommit;

    private void drawFrame(string[] menuRows)
    {
        import nano.frame : editorLines, fit;
        import std.conv : to;
        auto w = max(width(), 2);
        auto text = masked ? replicateD('*', state.buf.length) : state.buf.idup;
        auto rows = editorLines(styledPrompt, text, state.cursor, w);
        // An empty editor with a placeholder glyph says whose turn it is
        // after the cursor (filled in by the frame thread).
        import std.algorithm : canFind;
        import nano.frame : glyphMark, hintMark;
        if (!text.length && styledPrompt.canFind(glyphMark)) rows[0] ~= hintMark;
        foreach (r; menuRows) rows ~= fit(r, w);
        frameDraw(rows);
    }

    private static dstring replicateD(dchar c, size_t n) pure { dstring r; foreach (_; 0 .. n) r ~= c; return r; }

    /// Text is typed but not yet sent.
    bool hasDraft() const { return state.buf.length > 0; }

    /// A fresh draft holds back a due timer (see `EditState.holdsTimer`).
    bool holdsTimer(MonoTime now) const { return state.holdsTimer(now); }

    /// Park the draft for a timer turn (see `EditState.parkDraft`).
    bool parkDraft(out ParkedDraft parked) { return state.parkDraft(parked); }

    /// Put a parked draft back after the turn (see `EditState.restoreDraft`).
    void restoreDraft(ParkedDraft parked) { state.restoreDraft(parked); }

    private Result read(string prompt, string styledPrompt, bool turn, bool delegate() @safe stop)
    {
        this.prompt = prompt;
        this.styledPrompt = styledPrompt;
        notice = hint;
        hint = null;
        render();
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
                    if (plain) { auto t = state.text; finish(); state.clear(); return Result(Outcome.line, t); }
                    if (auto note = commands.rejection(state.text))
                    {
                        notice = "\x1b[2m" ~ note ~ "\x1b[0m";
                        break;
                    }
                    if (turn) erase(); else finish();
                    return Result(Outcome.line, state.take());
                case K.newline:
                    if (!turn)
                    {
                        state.insert("\n");
                        break;
                    }
                    if (auto note = commands.rejection(state.text))
                    {
                        notice = "\x1b[2m" ~ note ~ "\x1b[0m";
                        break;
                    }
                    erase();
                    return Result(Outcome.queue, state.take());
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
                case K.cycleMode:
                    if (onAction is null) break;
                    erase();
                    onAction(key.kind);
                    if (turn && !state.buf.length) continue; // no empty prompt amid the output
                    break;
                case K.toggleExpand:
                    if (onToggle !is null) onToggle();
                    break;
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
                    if (plain) { state.clear(); erase(); return Result(Outcome.cancel); }
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

    /// Pick one of `labels` with Up/Down (or its number) and Enter; Esc or
    /// Ctrl-C dismisses (-1). Leaves the prompt and the choice on screen.
    /// When `stop` turns true (polled) the picker is removed and -2 returned.
    ptrdiff_t select(string prompt, const string[] labels, size_t initial = 0, bool delegate() @safe stop = null,
        const string[] body_ = null)
    {
        size_t at = initial < labels.length ? initial : 0;
        size_t top;
        // Rows drawn above the prompt (a rendered question); kept to half the
        // screen so the options stay visible, and committed with the answer.
        string[] above;
        {
            auto h = height();
            auto room = h > 8 ? (h - 3) / 2 : 1;
            above = body_.length > room ? body_[0 .. room - 1].dup ~ "…" : body_.dup;
        }
        // At most `visible` rows show; the window scrolls to keep `at` in it.
        size_t visible = labels.length;
        {
            auto h = height();
            auto cap = h > 4 + above.length ? h - 3 - above.length : 1;
            if (cap > 15) cap = 15;
            if (visible > cap) visible = cap;
        }
        void draw(bool final_)
        {
            auto fw = max(width(), 2);
            if (final_)
            {
                frameDraw(null);
                import std.array : join;
                auto answer = "\x1b[32m?\x1b[0m " ~ prompt ~ " \x1b[36m" ~ fitCols(labels[at], fw / 2) ~ "\x1b[0m";
                frameCommit(body_.length ? (cast(const(string)[]) body_).join("\n") ~ "\n" ~ answer : answer);
                return;
            }
            if (at < top) top = at;
            if (at >= top + visible) top = at + 1 - visible;
            string[] rows = above ~ ["\x1b[32m?\x1b[0m \x1b[1m" ~ fitCols(prompt, fw - 3) ~ "\x1b[0m"];
            foreach (k; top .. top + visible)
                rows ~= k == at ? "\x1b[36m❯ " ~ fitCols(labels[k], fw - 3) ~ "\x1b[0m" : "  " ~ fitCols(labels[k], fw - 3);
            frameDraw(rows);
        }
        draw(false);
        for (;;)
        {
            auto key = decode(src, stop is null ? -1 : 100, utf8);
            if (key.kind == K.none && stop !is null && stop())
            {
                frameDraw(null);
                return -2;
            }
            switch (key.kind)
            {
                case K.up: at = at ? at - 1 : labels.length - 1; break;
                case K.down, K.tab: at = (at + 1) % labels.length; break;
                case K.submit:
                    draw(true);
                    return at;
                case K.escape, K.interrupt, K.eof, K.closed:
                    if (key.kind == K.escape && key.text.length) pushback = 0x1b;
                    frameDraw(null);
                    return -1;
                case K.insert:
                    import std.ascii : isDigit;
                    if (key.text.length == 1 && key.text[0].isDigit && key.text[0] != '0'
                            && key.text[0] - '1' < labels.length) at = key.text[0] - '1';
                    break;
                default: break;
            }
            draw(false);
        }
    }

    private static string fitCols(string s, size_t w)
    {
        if (textWidth(s) <= w) return s;
        string r;
        size_t used;
        foreach (dchar c; s)
        {
            auto cw = charWidth(c);
            if (used + cw + 1 > w) break;
            r ~= c.to!string;
            used += cw;
        }
        return r ~ "…";
    }

    /// Remove what the editor drew.
    void erase()
    {
        if (!drawn) return;
        frameDraw(null);
        drawn = false;
    }

    private void finish()
    {
        import std.conv : to;
        if (restyle !is null) styledPrompt = restyle();
        auto text = masked ? replicateD('*', state.buf.length).to!string : state.text;
        frameCommit(styledPrompt ~ text);
        drawn = false;
    }

    private void render()
    {
        string[] extra;
        if (notice.length) extra = [notice];
        else if (!plain) extra = state.menu(max(width(), 2), menuRows);
        drawFrame(extra);
        drawn = true;
    }
}

// ---------------------------------------------------------------------------
// Terminal plumbing

version (Posix)
{
    import core.sys.posix.termios;

    import core.atomic : atomicLoad, atomicStore;
    import nano.safeio : GsharedValue, atExit, tcGet, tcSet;
    // The terminal settings key mode replaced; only the main thread (and its
    // atexit handler) enters and leaves key mode.
    mixin GsharedValue!(termios, "saved");
    private shared bool keyMode_;

    /// Key mode: no canonical input, echo or signals (Ctrl-C arrives as a
    /// byte), and bracketed paste. Output processing stays on.
    bool enterKeyMode(int fd)
    {
        if (atomicLoad(keyMode_)) return true;
        termios orig;
        if (!tcGet(fd, orig)) return false;
        saved = orig;
        auto t = orig;
        t.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
        t.c_iflag &= ~(IXON | ICRNL | INLCR);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        if (!tcSet(fd, t)) return false;
        atomicStore(keyMode_, true);
        writeFd(1, "\x1b[?2004h");
        static bool registered;
        if (!registered) { registered = true; atExit(&restoreAtExit); }
        return true;
    }

    void leaveKeyMode(int fd = 0) nothrow
    {
        if (!atomicLoad(keyMode_)) return;
        auto t = saved;
        tcSet(fd, t);
        atomicStore(keyMode_, false);
        writeFd(1, "\x1b[?2004l");
    }

    private extern (C) void restoreAtExit() nothrow { leaveKeyMode(0); }

    void writeFd(int fd, string s) nothrow
    {
        import nano.safeio : writeAllFd;
        writeAllFd(fd, s);
    }

    /// Whether key mode is on (so a nested user can leave it as it was).
    bool inKeyMode() nothrow { return atomicLoad(keyMode_); }

    /// The terminal's output fd: 1, or the saved one while the frame
    /// renderer has fd 1 pointing at its pipe.
    shared int ttyOut_ = 1;
    /// ditto
    @property int ttyOut() nothrow @nogc { import core.atomic : atomicLoad; return atomicLoad(ttyOut_); }
    /// ditto
    @property void ttyOut(int fd) nothrow @nogc { import core.atomic : atomicStore; atomicStore(ttyOut_, fd); }

    /// Terminal height of `fd` (24 when unknown).
    size_t terminalHeight(int fd = 1)
    {
        import safeio = nano.safeio;
        if (fd == 1) fd = ttyOut;
        auto n = safeio.terminalSize(fd)[0];
        return n ? n : 24;
    }

    /// Terminal width of `fd` (80 when unknown).
    size_t terminalWidth(int fd = 1)
    {
        import safeio = nano.safeio;
        if (fd == 1) fd = ttyOut;
        auto n = safeio.terminalSize(fd)[1];
        return n ? n : 80;
    }

    /// A ByteSource reading `fd` with poll.
    ByteSource fdSource(int fd)
    {
        import core.sys.posix.poll : pollfd, POLLIN;
        import nano.safeio : pollFds, readFd;
        ubyte[] pending;
        return (int timeoutMs) {
            if (pending.length)
            {
                auto b = pending[0];
                pending = pending[1 .. $];
                return cast(int) b;
            }
            pollfd[1] p = [pollfd(fd, POLLIN, 0)];
            auto r = pollFds(p[], timeoutMs);
            if (r == 0) return -1;
            if (r < 0) return -1; // EINTR: treat as a timeout, the caller loops
            ubyte[256] buf;
            auto n = readFd(fd, buf[]);
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

    /// What the editor sent the frame: drawn rows (joined), `<ERASE>` for a
    /// clear and `<COMMIT …>` for a committed line. Heap-allocated so the
    /// editor's delegates can outlive the test frame (DIP1000).
    final class Screen { string text; }

    LineEditor editor(string keys, Screen screen, size_t w = 40)
    {
        import std.array : join;
        return new LineEditor(script(keys), (string[] rows) { screen.text ~= rows is null ? "<ERASE>" : rows.join("\n"); },
            (string line) { screen.text ~= "<COMMIT " ~ line ~ ">"; }, () => w);
    }
}

// rust: lineedit.rs::erase_word_from_the_middle_keeps_the_tail
// rust: lineedit.rs::word_jumps_skip_whitespace
// rust: lineedit.rs::inserts_and_deletes_at_the_cursor
unittest // editing keys
{
    auto screen = new Screen;
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
    e = editor("foo bar baz\x1b[D\x1b[D\x1b[D\x17\r", screen); // Ctrl-W mid-line keeps the tail
    assert(e.readLine("> ", "> ").text == "foo baz");
    e = editor("fix it\t\r", screen); // Tab outside a command is a space
    assert(e.readLine("> ", "> ").text == "fix it ");
    e = editor("/compact focus\tx\r", screen);
    assert(e.readLine("> ", "> ").text == "/compact focus x");
}

unittest // Shift-Tab runs the action with the input erased, keeping the text; Ctrl-O toggles
{
    auto screen = new Screen;
    K[] seen;
    int toggles;
    auto e = editor("ab\x1b[Zc\x0f\x1b[111;5u\r", screen);
    e.onAction = (K k) { seen ~= k; screen.text ~= "<ACT>"; };
    e.onToggle = () { toggles++; };
    assert(e.readLine("> ", "> ").text == "abc");
    assert(seen == [K.cycleMode] && toggles == 2);
    // Erased right before the action; the line is committed at the end.
    assert(screen.text.canFind("<ERASE><ACT>"));
    assert(screen.text.canFind("<COMMIT > abc>"));
    // Without a handler it does nothing.
    e = editor("a\x1b[Zb\x0f\r", screen);
    assert(e.readLine("> ", "> ").text == "ab");
}

unittest // UTF-8, wide characters and combining marks
{
    auto screen = new Screen;
    auto e = editor("h\xc3\xa9llo \xe4\xb8\x96\x7f\x7f\r", screen);
    assert(e.readLine("> ", "> ").text == "héllo");
    e = editor("e\xcc\x81x\x1b[D\x7f\r", screen); // e + combining acute: one backspace removes both
    assert(e.readLine("> ", "> ").text == "x");
    assert(charWidth('世') == 2 && charWidth('\u0301') == 0 && textWidth("a世") == 3);
}

// rust: lineedit.rs::parses_ctrl_and_cmd_enter_as_a_newline
// rust: lineedit.rs::take_returns_the_multiline_input
// rust: lineedit.rs::paste_normalizes_line_endings
unittest // multi-line input: Ctrl-J, Alt-Enter, kitty/modifyOtherKeys Ctrl-Enter, paste
{
    auto screen = new Screen;
    auto e = editor("a\nb\x1b\rc\x1b[13;5ud\x1b[27;5;13~e\r", screen);
    assert(e.readLine("> ", "> ").text == "a\nb\nc\nd\ne");
    e = editor("x\x1b[200~line1\r\nline2\tz\x1b[201~\r", screen);
    assert(e.readLine("> ", "> ").text == "xline1\nline2    z");
    // Up/Down move between lines of the input before recalling history.
    e = editor("abc\ndef\x1b[A\x1b[DX\r", screen);
    assert(e.readLine("> ", "> ").text == "abXc\ndef");
}

// rust: lineedit.rs::up_down_recalls_submitted_lines_and_the_draft
unittest // history recall; Ctrl-D; Ctrl-C
{
    auto screen = new Screen;
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

// rust: lineedit.rs::double_escape_clears_a_command_menu_line_in_two_presses
// rust: lineedit.rs::double_escape_press_clears_a_non_empty_idle_input
// rust: lineedit.rs::enter_on_an_unknown_command_keeps_the_line_unsent
// rust: lineedit.rs::tab_completes_commands_and_is_a_space_elsewhere
unittest // slash commands: Tab, menu, rejection, Esc
{
    auto screen = new Screen;
    auto e = editor("/mod\tl\t gpt\r", screen);
    assert(e.readLine("> ", "> ").text == "/model  gpt");
    screen.text = null;
    e = editor("/he", screen);
    e.readLine("> ", "> ");
    assert(screen.text.canFind("Show this"), "menu drawn while typing");
    screen.text = null;
    e = editor("/exin\r\x7f\x7fit\r", screen);
    assert(e.readLine("> ", "> ").text == "/exit");
    assert(screen.text.canFind("Unknown command /exin"));
    // Esc hides the menu; Esc Esc clears at the prompt and cancels in a turn.
    long t;
    e = editor("/h\x1b\x1b\xffok\r", screen);
    e.nowMs = () => t += 100;
    assert(e.readLine("> ", "> ").text == "ok");
    e = editor("abc\x1b\x1b", screen);
    e.nowMs = () => t += 100;
    assert(e.readLine("", "", true).outcome == Outcome.cancel);
}

unittest // select
{
    auto screen = new Screen;
    auto e = editor("\x1b[B\x1b[B\x1b[A\r", screen);
    assert(e.select("Pick", ["a", "b", "c"]) == 1);
    e = editor("3\r", screen);
    assert(e.select("Pick", ["a", "b", "c"]) == 2);
    e = editor("\x1b\xff", screen);
    assert(e.select("Pick", ["a"]) == -1);
}

unittest // select draws a question body above the prompt and keeps it with the answer
{
    import std.algorithm : canFind;
    import std.string : indexOf;
    auto screen = new Screen;
    auto e = editor("\r", screen);
    e.rows = () => 24;
    assert(e.select("Your answer", ["yes", "no"], 0, null, ["Two options:", "- **A**", "- B"]) == 0);
    auto drawn = screen.text;
    assert(drawn.indexOf("Two options:\n- **A**\n- B\n") >= 0 && drawn.indexOf("- B") < drawn.indexOf("Your answer"), drawn);
    assert(drawn.canFind("<COMMIT Two options:\n- **A**\n- B\n"), "committed with the answer: " ~ drawn);
}

// rust: lineedit.rs::enter_steers_and_ctrl_enter_queues_during_a_turn
unittest // Enter steers and Ctrl-Enter queues during a turn (Rust enter_steers_and_ctrl_enter_queues_during_a_turn)
{
    auto screen = new Screen;
    auto r = editor("go left\r", screen).readLine("", "", true);
    assert(r.outcome == Outcome.line && r.text == "go left");
    foreach (seq; ["\x1b[27;5;13~", "\x1b[13;5u", "\x1b[27;9;13~"])
    {
        r = editor("later" ~ seq, screen).readLine("", "", true);
        assert(r.outcome == Outcome.queue && r.text == "later", seq);
        // At the prompt the same keys insert a newline.
        r = editor("a" ~ seq ~ "b\r", screen).readLine("", "");
        assert(r.outcome == Outcome.line && r.text == "a\nb", seq);
    }
}

unittest // stop keeps the typed text
{
    string screen;
    bool stopNow;
    size_t i;
    auto keys = "dra";
    auto e = new LineEditor((int) => i < keys.length ? cast(int) keys[i++] : -1, (string[] rows) { screen ~= "."; },
        (string line) { screen ~= line; }, () => 40);
    assert(e.readLine("", "", true, () { stopNow = i >= keys.length; return stopNow; }).outcome == Outcome.stopped);
    assert(e.state.text == "dra");
}

// rust: lineedit.rs::kitty_encoded_control_keys_act_like_legacy_bytes
// rust: lineedit.rs::parses_kitty_and_modify_other_keys_control_keys
// rust: lineedit.rs::ignores_sgr_mouse_reports
// rust: lineedit.rs::parses_modified_cursor_keys
unittest // escape parsing
{
    assert(parseEscape("\x1b[1;3D").kind == K.wordLeft && parseEscape("\x1bOH").kind == K.home);
    assert(parseEscape("\x1b[<0;1;1M").kind == K.ignored && parseEscape("\x1b[Z").kind == K.ignored);
    assert(parseEscape("\x1b[119;5u").kind == K.eraseWord); // kitty Ctrl-W
    assert(parseEscape("\x1b[27;6;87~").kind == K.eraseWord); // Ctrl-Shift-W
}

// rust: lineedit.rs::parses_cursor_and_function_keys, lineedit.rs::kitty_lock_state_bits_are_ignored
unittest
{
    K k(string s) { return parseEscape(s).kind; }
    assert(k("\x1b[D") == K.left && k("\x1b[C") == K.right && k("\x1b[H") == K.home && k("\x1b[F") == K.end);
    assert(k("\x1bOD") == K.left && k("\x1bOC") == K.right && k("\x1bOH") == K.home && k("\x1bOF") == K.end);
    assert(k("\x1b[3~") == K.delete_ && k("\x1b[1~") == K.home && k("\x1b[4~") == K.end);
    assert(k("\x1b[A") == K.up && k("\x1b[B") == K.down && k("\x1bOA") == K.up && k("\x1bOB") == K.down);
    // Caps Lock (64) and Num Lock (128) bits don't defeat the modifiers.
    assert(k("\x1b[27;65u") == K.escape && k("\x1b[27;129u") == K.escape);
    assert(k("\x1b[13;65u") == K.submit && k("\x1b[13;193u") == K.submit);
    assert(k("\x1b[99;69u") == K.interrupt && k("\x1b[99;197u") == K.interrupt);
    assert(k("\x1b[13;69u") == K.newline && k("\x1b[98;131u") == K.wordLeft);
}

// rust: lineedit.rs::movement_clamps_at_the_ends, lineedit.rs::erase_word_handles_multibyte_spaces
// rust: lineedit.rs::take_skips_repeats_but_history_up_still_works
// rust: lineedit.rs::editing_a_recalled_line_restarts_browsing_from_the_newest
unittest
{
    auto screen = new Screen;
    auto e = editor("ab\x1b[D\x1b[D\x1b[DX\x1b[C\x1b[C\x1b[CY\r", screen);
    assert(e.readLine("> ", "> ").text == "XabY");
    e = editor("run a\u00a0b\u00e9  \x17\r", screen);
    assert(e.readLine("> ", "> ").text == "run a\u00a0");
    e = editor("run a\u00a0b\u00e9  \x17\x17\r", screen);
    assert(e.readLine("> ", "> ").text == "run ");
    e = editor("same\rsame\r\x1b[A\x1b[A\r", screen);
    e.readLine("> ", "> ");
    e.readLine("> ", "> ");
    assert(e.readLine("> ", "> ").text == "same");
    e = editor("first\rsecond\r\x1b[A!\x1b[A\x1b[B\r", screen);
    e.readLine("> ", "> ");
    e.readLine("> ", "> ");
    assert(e.readLine("> ", "> ").text == "second!");
}

// Rust #178: a stale draft stops holding due timers, and parks for the turn.
// rust: lineedit.rs::a_fresh_draft_holds_a_timer_and_a_stale_one_does_not
// rust: lineedit.rs::park_and_restore_round_trip_the_draft
// rust: lineedit.rs::cursor_navigation_keeps_the_draft_fresh
// rust: lineedit.rs::a_steer_submitted_during_the_turn_supersedes_the_parked_draft
// rust: lineedit.rs::a_blank_enter_during_the_turn_keeps_the_parked_draft
// rust: lineedit.rs::a_noop_ctrl_w_during_the_turn_keeps_the_parked_draft
// rust: lineedit.rs::a_whitespace_only_ctrl_w_still_erases_and_supersedes_the_draft
// rust: lineedit.rs::parking_and_restoring_keeps_the_history_browsing_state
// rust: lineedit.rs::a_blank_enter_on_an_empty_buffer_keeps_the_history_state
// rust: lineedit.rs::a_restored_draft_keeps_its_age_and_stays_stale
unittest
{
    ParkedDraft parked;
    // Fresh vs stale.
    {
        EditState e;
        auto t0 = MonoTime.currTime;
        assert(!e.holdsTimer(t0) && !e.draftIsStale(t0), "an empty buffer never holds a timer");
        e.insert("half-typed");
        auto now = MonoTime.currTime;
        assert(e.holdsTimer(now) && !e.draftIsStale(now), "a just-typed draft holds the timer");
        e.lastEdit = now - draftHold;
        assert(e.draftIsStale(now) && !e.holdsTimer(now), "a stale draft no longer holds the timer");
        e.lastEdit = MonoTime.init;
        assert(e.draftIsStale(now) && !e.holdsTimer(now));
    }
    // Park and restore round-trip; a newer draft is not overwritten.
    {
        EditState e;
        e.insert("half-typed note");
        e.left();
        e.left();
        auto cursor = e.cursor;
        assert(e.parkDraft(parked));
        assert(e.text == "", "park clears the editor so a timer turn cannot steer it");
        ParkedDraft none;
        assert(!e.parkDraft(none), "an empty buffer parks nothing");
        e.restoreDraft(parked);
        assert(e.text == "half-typed note" && e.cursor == cursor);
        e.clear();
        e.insert("typed during the turn");
        assert(e.parkDraft(parked));
        e.insert("newer still");
        e.restoreDraft(parked);
        assert(e.text == "newer still", "a live draft is not overwritten");
    }
    // Cursor navigation is activity; a no-op move isn't.
    {
        EditState e;
        e.insert("a long draft being reviewed");
        auto now = MonoTime.currTime;
        e.lastEdit = now - draftHold;
        assert(e.draftIsStale(now));
        e.left();
        assert(!e.draftIsStale(now) && e.holdsTimer(now), "a cursor move is activity");
        e.lastEdit = now - draftHold;
        e.home();
        assert(e.holdsTimer(now), "Home is activity");
        e.lastEdit = now - draftHold;
        e.end();
        assert(e.holdsTimer(now), "End is activity");
        e.lastEdit = now - draftHold;
        e.wordLeft();
        assert(e.holdsTimer(now), "a word jump is activity");
        e.home();
        e.lastEdit = now - draftHold;
        e.home();
        assert(e.draftIsStale(now), "a no-op move changes nothing");
    }
    // A steer sent (or text typed then cleared) during the turn supersedes the draft.
    {
        EditState e;
        e.insert("abandoned draft");
        assert(e.parkDraft(parked));
        e.insert("steer while the timer runs");
        e.take();
        e.restoreDraft(parked);
        assert(e.text == "", "a submitted steer supersedes the parked draft");
        e.insert("abandoned draft");
        assert(e.parkDraft(parked));
        e.insert("typed then cleared");
        e.clear();
        e.restoreDraft(parked);
        assert(e.text == "", "text typed then cleared supersedes the parked draft");
    }
    // A blank Enter keeps the parked draft; a real submission still supersedes it.
    {
        EditState e;
        e.insert("abandoned draft");
        assert(e.parkDraft(parked));
        assert(e.take() == "", "a blank Enter submits nothing");
        e.restoreDraft(parked);
        assert(e.text == "abandoned draft", "a no-op Enter does not discard the parked draft");
        assert(e.parkDraft(parked));
        e.insert("steer while the timer runs");
        e.take();
        e.restoreDraft(parked);
        assert(e.text == "");
    }
    // A no-op Ctrl-W keeps the parked draft; a real erase supersedes it.
    {
        EditState e;
        e.insert("abandoned draft");
        assert(e.parkDraft(parked));
        e.eraseWord();
        e.restoreDraft(parked);
        assert(e.text == "abandoned draft", "a no-op Ctrl-W does not discard the parked draft");
        assert(e.parkDraft(parked));
        e.insert("more words");
        e.eraseWord();
        e.restoreDraft(parked);
        assert(e.text == "more ", "a real erase supersedes the parked draft");
    }
    // A whitespace-only Ctrl-W still erases, and so supersedes.
    {
        EditState e;
        e.insert("abandoned draft");
        assert(e.parkDraft(parked));
        e.insert("   ");
        e.eraseWord();
        assert(e.text == "", "a whitespace-only prefix is still erased");
        e.restoreDraft(parked);
        assert(e.text == "", "erasing the spaces superseded the parked draft");
    }
    // Parking keeps the history browsing state.
    {
        EditState e;
        e.history.record("older entry");
        e.insert("my unsent draft");
        e.up();
        assert(e.text == "older entry");
        assert(e.parkDraft(parked));
        assert(e.text == "", "park clears the editor");
        assert(e.take() == "");
        e.restoreDraft(parked);
        assert(e.text == "older entry", "the recalled entry is restored");
        e.down();
        assert(e.text == "my unsent draft", "Down still recovers the unsent draft");
        assert(e.history.down() is null, "past the draft: no longer browsing");
    }
    // A blank Enter on an empty buffer keeps the history state.
    {
        EditState e;
        e.history.record("first entry");
        e.up();
        assert(e.text == "first entry");
        e.clear();
        assert(e.take() == "");
        e.up();
        assert(e.text == "first entry");
    }
    // A restored draft keeps its age.
    {
        EditState e;
        e.insert("abandoned draft");
        auto t0 = MonoTime.currTime;
        e.lastEdit = t0 - draftHold;
        assert(e.parkDraft(parked));
        e.restoreDraft(parked);
        assert(e.text == "abandoned draft" && e.draftIsStale(t0) && !e.holdsTimer(t0), "a restored AFK draft stays stale");
        EditState f;
        f.insert("fresh draft");
        auto t1 = MonoTime.currTime;
        assert(f.parkDraft(parked));
        f.restoreDraft(parked);
        assert(f.holdsTimer(t1), "a restored fresh draft stays fresh");
    }
}
