/// Choosing a session to resume: `--resume` without an ID, `--resume last`,
/// `/resume` and `--list-sessions` (Rust `resume.rs`).
module nano.resume;

import std.format : format;
import std.array : join, split, array;
import std.algorithm : filter, map, sort, min, max;
import std.range : walkLength;
import std.conv : to;
import std.path : baseName;
import std.datetime.systime : SysTime, Clock;
import nano.session_index : Summary, list;
import nano.lineedit : Key, K, ByteSource, decode;

/// Sessions that ran in `cwd`, plus those from older logs that don't say where they ran.
const(Summary)[] inDir(const Summary[] sessions, string cwd)
{
    return sessions.filter!(s => s.cwd is null || s.cwd == cwd).array;
}

/// The most recent session that ran in `cwd` (`--resume last`), other than
/// `exclude` (the session in use, for `/resume last`).
string last(string dir, string cwd, string exclude = null)
{
    foreach (s; list(dir))
        if (s.cwd == cwd && s.id != exclude) return s.id;
    throw new Exception(format("no saved session for %s; run with --resume to pick one", sanitize(cwd)));
}

/// `text` without control characters (C0, DEL and C1): persisted or
/// filesystem text must not inject terminal escape sequences.
string sanitize(string text)
{
    import std.uni : isControl;
    string o;
    foreach (dchar c; text) if (!isControl(c)) o ~= c;
    return o;
}

/// How long ago `then` was, briefly.
string ago(SysTime then, SysTime now)
{
    auto minutes = (now - then).total!"minutes";
    if (minutes < 1) return "just now";
    if (minutes < 60) return format("%sm ago", minutes);
    if (minutes < 1440) return format("%sh ago", minutes / 60);
    if (minutes < 2880) return "yesterday";
    if (minutes < 10080) return format("%sd ago", minutes / 1440);
    static immutable months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    auto local = then.toLocalTime;
    return format("%s %s", months[local.month - 1], local.day);
}

/// The last component of the session's directory, or `?` when unknown.
string project(const ref Summary s)
{
    if (s.cwd is null) return "?";
    auto name = s.cwd.baseName;
    return sanitize(name.length ? name : s.cwd);
}

/// One line of prompt text: whitespace collapsed, control characters dropped.
string oneLine(string text)
{
    return sanitize(text.split.join(" "));
}

/// What the session was last about: the title (when there is one) and the
/// last prompt, else the last prompt and, when that says little, the more
/// telling one before it.
string topic(const ref Summary s)
{
    auto lastP = oneLine(s.lastPrompt);
    if (s.title !is null) return oneLine(s.title) ~ " · " ~ lastP;
    if (s.contextPrompt !is null) return lastP ~ "  ← " ~ oneLine(s.contextPrompt);
    return lastP;
}

// ---------------------------------------------------------------------------
// Terminal-cell widths (unicode-width, simplified)

/// Whether `c` takes no cell of its own: combining marks, zero-width
/// joiners/spaces and variation selectors join the preceding character.
private bool zeroWidth(dchar c)
{
    import std.uni : combiningClass, unicode;
    if (c == 0x200B || c == 0x200C || c == 0x200D || c == 0x2060 || c == 0xFEFF) return true;
    if (c >= 0xFE00 && c <= 0xFE0F) return true;
    if (c >= 0xE0100 && c <= 0xE01EF) return true;
    static immutable marks = unicode.Mn | unicode.Me;
    return marks[c];
}

/// Whether `c` is East Asian wide/fullwidth or a wide emoji (two cells).
private bool wide(dchar c)
{
    return (c >= 0x1100 && c <= 0x115F) || (c >= 0x231A && c <= 0x231B) || (c >= 0x2329 && c <= 0x232A)
        || (c >= 0x23E9 && c <= 0x23EC) || c == 0x23F0 || c == 0x23F3 || (c >= 0x25FD && c <= 0x25FE)
        || (c >= 0x2614 && c <= 0x2615) || (c >= 0x2648 && c <= 0x2653) || c == 0x267F || c == 0x2693
        || c == 0x26A1 || (c >= 0x26AA && c <= 0x26AB) || (c >= 0x26BD && c <= 0x26BE) || (c >= 0x26C4 && c <= 0x26C5)
        || c == 0x26CE || c == 0x26D4 || c == 0x26EA || (c >= 0x26F2 && c <= 0x26F3) || c == 0x26F5 || c == 0x26FA
        || c == 0x26FD || c == 0x2705 || (c >= 0x270A && c <= 0x270B) || c == 0x2728 || c == 0x274C || c == 0x274E
        || (c >= 0x2753 && c <= 0x2755) || c == 0x2757 || (c >= 0x2795 && c <= 0x2797) || c == 0x27B0 || c == 0x27BF
        || (c >= 0x2B1B && c <= 0x2B1C) || c == 0x2B50 || c == 0x2B55
        || (c >= 0x2E80 && c <= 0x303E) || (c >= 0x3041 && c <= 0x33FF) || (c >= 0x3400 && c <= 0x4DBF)
        || (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0xA000 && c <= 0xA4CF) || (c >= 0xA960 && c <= 0xA97F)
        || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFE10 && c <= 0xFE19)
        || (c >= 0xFE30 && c <= 0xFE6F) || (c >= 0xFF00 && c <= 0xFF60) || (c >= 0xFFE0 && c <= 0xFFE6)
        || (c >= 0x16FE0 && c <= 0x18CFF) || (c >= 0x1B000 && c <= 0x1B2FF) || c == 0x1F004 || c == 0x1F0CF
        || c == 0x1F18E || (c >= 0x1F191 && c <= 0x1F19A) || (c >= 0x1F200 && c <= 0x1F251)
        || (c >= 0x1F300 && c <= 0x1F64F && !(c >= 0x1F321 && c <= 0x1F32C) && !(c >= 0x1F336 && c <= 0x1F336)
            && !(c >= 0x1F37D && c <= 0x1F37D) && !(c >= 0x1F394 && c <= 0x1F39F) && !(c >= 0x1F3CB && c <= 0x1F3CE)
            && !(c >= 0x1F3D4 && c <= 0x1F3DF) && !(c >= 0x1F3F1 && c <= 0x1F3F3) && !(c >= 0x1F3F5 && c <= 0x1F3F7)
            && c != 0x1F43F && c != 0x1F441 && !(c >= 0x1F4FD && c <= 0x1F4FE) && !(c >= 0x1F53E && c <= 0x1F54A)
            && c != 0x1F54F && !(c >= 0x1F568 && c <= 0x1F579) && !(c >= 0x1F57B && c <= 0x1F594)
            && !(c >= 0x1F597 && c <= 0x1F5A3) && !(c >= 0x1F5A5 && c <= 0x1F5FA))
        || (c >= 0x1F680 && c <= 0x1F6C5) || c == 0x1F6CC || (c >= 0x1F6D0 && c <= 0x1F6D2)
        || (c >= 0x1F6D5 && c <= 0x1F6D7) || (c >= 0x1F6DC && c <= 0x1F6DF) || (c >= 0x1F6EB && c <= 0x1F6EC)
        || (c >= 0x1F6F4 && c <= 0x1F6FC) || (c >= 0x1F7E0 && c <= 0x1F7EB) || c == 0x1F7F0
        || (c >= 0x1F90C && c <= 0x1F93A) || (c >= 0x1F93C && c <= 0x1F945) || (c >= 0x1F947 && c <= 0x1F9FF)
        || (c >= 0x1FA70 && c <= 0x1FAFF) || (c >= 0x20000 && c <= 0x3FFFD);
}

/// Terminal cells `text` occupies. Measured over the string, not per
/// character: an emoji-presentation selector (U+FE0F) widens the narrow
/// character before it to two cells, as terminals render `#️`.
size_t cells(string text)
{
    import std.uni : isControl;
    size_t n;
    bool prevNarrow;
    foreach (dchar c; text)
    {
        if (c == 0xFE0F && prevNarrow)
        {
            n++;
            prevNarrow = false;
            continue;
        }
        if (zeroWidth(c)) continue;
        if (isControl(c)) { prevNarrow = false; continue; }
        if (wide(c)) { n += 2; prevNarrow = false; }
        else { n += 1; prevNarrow = true; }
    }
    return n;
}

/// `text` fitted to at most `width` cells, with an ellipsis when truncated.
/// Never splits a wide glyph or a joining sequence across the boundary.
string truncate(string text, size_t width)
{
    if (width == 0) return "";
    if (cells(text) <= width) return text;
    auto budget = width - 1;
    string out_;
    foreach (dchar c; text)
    {
        auto next = out_ ~ c.to!string;
        if (cells(next) > budget) break;
        out_ = next;
    }
    return out_ ~ "…";
}

/// Width of `line` with ANSI CSI sequences skipped.
private size_t visibleCells(string line)
{
    string plain;
    for (size_t i = 0; i < line.length; i++)
    {
        if (line[i] == '\x1b' && i + 1 < line.length && line[i + 1] == '[')
        {
            i += 2;
            while (i < line.length && !(line[i] >= 0x40 && line[i] <= 0x7e)) i++;
            continue;
        }
        plain ~= line[i];
    }
    return cells(plain);
}

/// Terminal rows a written line occupies once wrapped at `cols`.
size_t physicalRows(string line, size_t cols)
{
    if (cols == 0) return 1;
    return max(1, (visibleCells(line) + cols - 1) / cols);
}

/// Item rows that fit beneath a `promptRows`-tall prompt, capped at
/// `maxVisible`; zero when the prompt already fills the screen.
size_t itemWindow(size_t rows, size_t promptRows, size_t maxVisible)
{
    return min(maxVisible, rows > promptRows ? rows - promptRows : 0);
}

/// The scroll offset that keeps `sel` inside a `maxVisible`-row window.
size_t scrollTop(size_t top, size_t sel, size_t maxVisible)
{
    if (sel < top) return sel;
    if (maxVisible > 0 && sel >= top + maxVisible) return sel + 1 - maxVisible;
    return top;
}

// ---------------------------------------------------------------------------
// Fuzzy matching (a skim-style subsequence scorer)

/// Score `pattern` as a subsequence of `text` (smart case: case-sensitive
/// only when the pattern has an uppercase letter), filling `positions` with
/// the matched character indices. Null when there is no match. Consecutive
/// runs, word starts and early matches score higher; gaps cost a little.
long fuzzyMatch(string text, string pattern, out size_t[] positions)
{
    import std.uni : toLower, isUpper, isAlphaNum;
    import std.algorithm : any;
    auto t = text.to!dstring;
    auto p = pattern.to!dstring;
    if (!p.length) return 0;
    bool sensitive = p.any!(c => isUpper(c));
    dchar fold(dchar c) { return sensitive ? c : toLower(c); }
    // Every start position of the first character is tried; the best wins.
    long best = long.min;
    foreach (start; 0 .. t.length)
    {
        if (fold(t[start]) != fold(p[0])) continue;
        size_t[] pos;
        size_t ti = start;
        foreach (pc; p)
        {
            while (ti < t.length && fold(t[ti]) != fold(pc)) ti++;
            if (ti == t.length) { pos = null; break; }
            pos ~= ti++;
        }
        if (pos is null) break; // later starts can't match either
        long score;
        foreach (i, at; pos)
        {
            score += 16;
            bool wordStart = at == 0 || !isAlphaNum(t[at - 1]);
            if (wordStart) score += 8;
            if (i && pos[i - 1] + 1 == at) score += 12;
            else if (i) score -= min(at - pos[i - 1] - 1, 8);
        }
        score -= min(pos[0], 16) / 2;
        if (score > best)
        {
            best = score;
            positions = pos;
        }
    }
    return best == long.min ? long.min : best;
}

/// Indices of `items` matching `search`, best first; equal scores keep input
/// order, so the newest-first default survives until the user narrows it.
size_t[] rank(const string[] items, string search)
{
    struct Hit { size_t i; long score; }
    Hit[] hits;
    foreach (i, t; items)
    {
        size_t[] pos;
        auto s = fuzzyMatch(t, search, pos);
        if (s != long.min) hits ~= Hit(i, s);
    }
    import std.algorithm : SwapStrategy;
    hits.sort!((a, b) => a.score > b.score, SwapStrategy.stable);
    return hits.map!(h => h.i).array;
}

// ---------------------------------------------------------------------------
// The picker

/// A list row fitted to `width` cells: when last used, the project, the
/// prompt count, then the topic.
string row(const ref Summary s, SysTime now, size_t width)
{
    auto prompts = s.prompts == 1 ? "1 prompt" : format("%s prompts", s.prompts);
    auto line = format("%-10s  %s  %s  %s", ago(s.lastUsed, now), project(s), prompts, topic(s));
    return truncate(line, width);
}

/// A row prefixed with the (sanitized) session ID, for plain lists.
string idRow(const ref Summary s, SysTime now)
{
    return sanitize(s.id) ~ "  " ~ row(s, now, 100);
}

/// Plain list rows (with IDs) of this directory's sessions, for `/resume`
/// without a terminal; `exclude` (the session in use) is left out.
string[] listRows(string dir, string cwd, string exclude = null)
{
    auto now = Clock.currTime;
    auto all = list(dir);
    return inDir(all, cwd).filter!(s => s.id != exclude).map!(s => idRow(s, now)).array;
}

/// The interactive picker's state: a search over items' full text, with the
/// drawn rows fitted to the terminal and the frame kept within its height.
struct Picker
{
    string prompt;
    const(string)[] items;
    size_t width; /// cells for an item's label
    bool color;
    string search;
    size_t sel, top;

    /// The frame's lines for a `rows`×`cols` terminal.
    string[] frame(size_t rows, size_t cols, size_t maxVisible)
    {
        auto filtered = rank(items, search);
        auto promptLine = (color ? "\x1b[32m?\x1b[0m \x1b[1m" : "? ") ~ prompt ~ (color ? "\x1b[0m" : "") ~ " › " ~ search;
        // A long cwd or search must not wrap past the terminal on its own.
        if (rows * cols > 0 && physicalRows(promptLine, cols) > rows)
            promptLine = truncate(sanitize(stripAnsi(promptLine)), rows * cols);
        auto window = itemWindow(rows, physicalRows(promptLine, cols), maxVisible);
        if (!filtered.length) sel = top = 0;
        else
        {
            sel = min(sel, filtered.length - 1);
            top = scrollTop(top, sel, window);
        }
        string[] lines = [promptLine];
        foreach (pos; top .. min(top + window, filtered.length))
            lines ~= renderItem(items[filtered[pos]], pos == sel);
        return lines;
    }

    private string renderItem(string text, bool active)
    {
        auto label = truncate(text, width);
        size_t[] matched;
        if (search.length) fuzzyMatch(label, search, matched);
        string o = active ? (color ? "\x1b[36m❯\x1b[0m " : "❯ ") : "  ";
        size_t i, m;
        foreach (dchar c; label)
        {
            bool hit = m < matched.length && matched[m] == i;
            if (hit) m++;
            if (hit && color) o ~= "\x1b[1m" ~ c.to!string ~ "\x1b[22m";
            else o ~= c;
            i++;
        }
        return o;
    }

    /// Apply a key. Returns -1 to keep going, -2 when cancelled, or the
    /// chosen item's index.
    long handle(Key k)
    {
        auto filtered = rank(items, search);
        switch (k.kind)
        {
            case K.escape, K.interrupt, K.eof, K.closed: return -2;
            case K.submit:
                return filtered.length ? cast(long) filtered[sel] : -1;
            case K.up:
                if (filtered.length) sel = (sel + filtered.length - 1) % filtered.length;
                return -1;
            case K.down, K.tab:
                if (filtered.length) sel = (sel + 1) % filtered.length;
                return -1;
            case K.backspace:
                if (search.length)
                {
                    import std.utf : strideBack;
                    search = search[0 .. $ - strideBack(search, search.length)];
                    sel = top = 0;
                }
                return -1;
            case K.insert, K.paste:
                foreach (dchar c; k.text) if (c >= 0x20 && c != 0x7f) search ~= c;
                sel = top = 0;
                return -1;
            default: return -1;
        }
    }
}

private string stripAnsi(string line)
{
    string plain;
    for (size_t i = 0; i < line.length; i++)
    {
        if (line[i] == '\x1b' && i + 1 < line.length && line[i + 1] == '[')
        {
            i += 2;
            while (i < line.length && !(line[i] >= 0x40 && line[i] <= 0x7e)) i++;
            continue;
        }
        plain ~= line[i];
    }
    return plain;
}

/// Run `p` on the terminal: draw on `out_`, read keys from `src`, clear the
/// frame by its rendered height after each key and at the end. The chosen
/// index, or -1 when cancelled.
long runPicker(ref Picker p, ByteSource src, void delegate(string) out_, size_t rows, size_t cols, size_t maxVisible)
{
    size_t drawn;
    ubyte[] utf8;
    out_("\x1b[?25l");
    scope (exit) out_("\x1b[?25h");
    void clear()
    {
        if (drawn) out_(format("\x1b[%sA\r\x1b[J", drawn));
        drawn = 0;
    }
    for (;;)
    {
        clear();
        string buf;
        foreach (line; p.frame(rows, cols, maxVisible))
        {
            buf ~= line ~ "\r\n";
            drawn += physicalRows(line, cols);
        }
        out_(buf);
        Key k;
        do k = decode(src, -1, utf8);
        while (k.kind == K.none);
        auto r = p.handle(k);
        if (r == -1) continue;
        clear();
        return r == -2 ? -1 : r;
    }
}

/// Why the picker returned no session.
enum Pick { selected, cancelled, empty }

/// Pick a session in the terminal (stdin keys, drawn on stderr): this
/// directory's sessions first, with an entry to show all. `exclude` (the
/// session in use) is left out.
Pick pickOutcome(string dir, string cwd, string exclude, out string id)
{
    import std.stdio : stderr;
    import nano.lineedit : enterKeyMode, leaveKeyMode, inKeyMode, fdSource, writeFd, terminalWidth, terminalHeight;
    auto sessions = list(dir).filter!(s => s.id != exclude).array;
    if (!sessions.length)
    {
        stderr.writeln("No saved sessions to resume.");
        return Pick.empty;
    }
    auto now = Clock.currTime;
    auto cols = terminalWidth(2), rows = terminalHeight(2);
    auto maxVisible = rows > 2 ? min(max(rows - 2, 1), 15) : 1;
    bool wasRaw = inKeyMode;
    if (!wasRaw) enterKeyMode(0);
    scope (exit) if (!wasRaw) leaveKeyMode(0);
    auto src = fdSource(0);
    bool showAll;
    for (;;)
    {
        auto shown = showAll ? sessions : inDir(sessions, cwd);
        string[] items = shown.map!(s => row(s, now, size_t.max)).array;
        auto hidden = sessions.length - shown.length;
        if (hidden) items ~= format("Show all sessions (%s more in other directories)", hidden);
        auto prompt = showAll ? "Resume which session? (type to filter, Esc to cancel)"
            : format("Resume which session in %s? (type to filter, Esc to cancel)", sanitize(cwd));
        auto p = Picker(prompt, items, cols > 4 ? cols - 4 : 0, true);
        auto r = runPicker(p, src, (string s) { writeFd(2, s); }, rows, cols, maxVisible);
        if (r < 0) return Pick.cancelled;
        if (r == shown.length) { showAll = true; continue; }
        id = shown[r].id;
        return Pick.selected;
    }
}

/// `--list-sessions` and `--resume` without a terminal: one row per session
/// (this directory's unless `all`), or Rust's pretty JSON summaries.
void printList(string dir, string cwd, bool all, bool json)
{
    import std.stdio : stdout, stderr;
    auto sessions = list(dir);
    auto shown = all ? sessions : inDir(sessions, cwd);
    if (json)
    {
        if (!shown.length) { stdout.writeln("[]"); return; }
        string o = "[\n";
        foreach (i, ref s; shown) o ~= "  " ~ s.toPrettyJson(2) ~ (i + 1 < shown.length ? ",\n" : "\n");
        stdout.writeln(o ~ "]");
        return;
    }
    if (!shown.length)
    {
        stderr.writefln("No saved sessions%s.", all ? "" : " for " ~ sanitize(cwd) ~ " (--all lists every directory)");
        return;
    }
    auto now = Clock.currTime;
    foreach (ref s; shown) stdout.writeln(idRow(s, now));
}

unittest
{
    assert(cells("abc") == 3 && cells("日本") == 4 && cells("e\u0301") == 1 && cells("#\uFE0F") == 2);
    assert(cells("👨\u200D👩") == 4 && cells("\x1b") == 0);
    assert(truncate("hello world", 8) == "hello w…" && truncate("hi", 8) == "hi" && truncate("abc", 0) == "");
    assert(truncate("日本語テキスト", 6) == "日本…"); // never splits a wide glyph
    assert(cells(truncate("#\uFE0F#\uFE0F#\uFE0F", 4)) <= 4);
    assert(physicalRows("x", 0) == 1 && physicalRows("", 10) == 1 && physicalRows("abcdefghijk", 10) == 2);
    assert(physicalRows("\x1b[1mabc\x1b[0m", 3) == 1);
    assert(itemWindow(24, 1, 15) == 15 && itemWindow(3, 1, 15) == 2 && itemWindow(2, 3, 15) == 0);
    assert(scrollTop(5, 2, 3) == 2 && scrollTop(0, 7, 3) == 5 && scrollTop(4, 5, 3) == 4);
}

unittest
{
    size_t[] pos;
    assert(fuzzyMatch("deploy pipeline", "dpl", pos) != long.min && pos == [0, 2, 3]);
    assert(fuzzyMatch("abc", "abd", pos) == long.min);
    assert(fuzzyMatch("Deploy", "deploy", pos) != long.min); // smart case: lower matches any
    assert(fuzzyMatch("deploy", "Deploy", pos) == long.min); // upper is exact
    // A contiguous match and a word start beat a scattered one.
    assert(rank(["d e p l o y x", "the deploy test", "deploy"], "deploy") == [2, 1, 0]);
    // Empty search keeps order; equal scores stay stable.
    assert(rank(["b", "a", "c"], "") == [0, 1, 2]);
    // Matches anywhere in the full text, even past what a narrow row shows.
    assert(rank(["5m ago  w8  2 prompts  first thing then the keyword zebra", "other"], "zebra") == [0]);
}

unittest
{
    import nano.lineedit : script;
    auto p = Picker("Resume which session?", ["alpha one", "beta two", "gamma three"], 40, false);
    auto lines = p.frame(24, 80, 15);
    assert(lines.length == 4 && lines[0] == "? Resume which session? › " && lines[1] == "❯ alpha one" && lines[2] == "  beta two");
    // Typing filters, arrows move, Enter picks the original index.
    string drawn;
    auto r = runPicker(p, script("gam\r"), (string s) { drawn ~= s; }, 24, 80, 15);
    assert(r == 2);
    p.search = null;
    assert(runPicker(p, script("\x1b[B\x1b[B\x1b[B\r"), (string s) {}, 24, 80, 15) == 0); // wraps around
    p.search = null;
    assert(runPicker(p, script("\x1b"), (string s) {}, 24, 80, 15) == -1);
    p.search = null;
    // No match: Enter does nothing; backspace widens again.
    assert(runPicker(p, script("zz\r\x7f\x7f\x1b[B\r"), (string s) {}, 24, 80, 15) == 1);
    // The frame never exceeds the terminal: a 3-row terminal shows 2 items.
    p.search = null;
    p.sel = p.top = 0;
    assert(p.frame(3, 80, 15).length == 3);
    // Scrolling keeps the selection visible.
    p.sel = 2;
    auto f = p.frame(3, 80, 15);
    assert(f[$ - 1] == "❯ gamma three", f[$ - 1]);
    // Rows are fitted to the width while search sees the full text.
    auto q = Picker("x", ["a very long row whose keyword is at the very end: needle"], 20, false);
    q.search = "needle";
    auto g = q.frame(24, 80, 15);
    assert(g.length == 2 && cells(g[1]) <= 22);
}

@trusted unittest
{
    import std.file : tempDir, exists, rmdirRecurse, mkdirRecurse, readText;
    import std.path : buildPath;
    import nano.session : SessionLog;
    import core.time : minutes, days;
    auto dir = buildPath(tempDir, "nano-d-resume");
    if (dir.exists) rmdirRecurse(dir);
    auto a = new SessionLog(dir, "p/m", "/proj/a", "a");
    a.input("1", "Fix the \x1b[31mflaky\x1b[0m deploy test now");
    auto b = new SessionLog(dir, "p/m", "/proj/b", "b");
    b.input("1", "elsewhere");
    assert(last(dir, "/proj/a") == "a");
    import std.exception : assertThrown, collectExceptionMsg;
    import std.algorithm : canFind;
    assert(collectExceptionMsg(last(dir, "/proj/a", "a")).canFind("no saved session for /proj/a"));
    auto rows = listRows(dir, "/proj/a");
    assert(rows.length == 1 && rows[0].canFind("a  just now") && rows[0].canFind("Fix the [31mflaky[0m deploy"));
    assert(listRows(dir, "/proj/a", "a").length == 0);
    auto now = Clock.currTime;
    assert(ago(now - 90.minutes, now) == "1h ago" && ago(now - 1.days - 2.minutes, now) == "yesterday");
    Summary s;
    s.title = "Deploy\nfix";
    s.lastPrompt = "do it";
    s.contextPrompt = "older telling prompt";
    assert(topic(s) == "Deploy fix · do it");
    s.title = null;
    assert(topic(s) == "do it  ← older telling prompt");
    assert(project(s) == "?");
}
