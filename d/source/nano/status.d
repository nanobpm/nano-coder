/// A status line pinned to the bottom row of the terminal: model, cwd,
/// context use, session tokens and what the agent is doing (status.rs).
///
/// The rows above it are made a scroll region (DECSTBM), so ordinary output
/// scrolls without disturbing it. The conversation is kept bottom-anchored
/// (directly above the status line) so shrinking the window drops blank rows
/// rather than conversation.
module nano.status;

@safe:

import std.format : format;
import std.conv : to;
import nano.context : formatTokens;
import nano.lineedit : charWidth, writeFd;
import nano.mode : AgentMode;

/// What the agent is doing.
enum Activity { idle, thinking, tool, compacting }

/// Everything the status line shows.
struct Stats
{
    string provider, model, cwd;
    size_t tokens, window, messages;
    bool calibrated;
    bool hasPlan;
    size_t planDone, planTotal;
    AgentMode mode;
    string thinking; /// the level sent (null: the model decides)
    ulong sessionInputTokens, sessionOutputTokens;
    bool hasAic;
    double aic = 0;
    size_t historySearches, historyReads;
    bool autoCompact;
    double threshold = 0; /// auto-compaction threshold as a fraction
    bool smartCompact;
    uint compactions;
    Activity activity;
    string tool; /// the running tool (activity == tool)
    double tokensPerSec = 0; /// live output rate (0: none)

    double percent() const { return window == 0 ? 0.0 : tokens * 100.0 / window; }
}

/// `12.3 tok/s` / `45 tok/s`.
string formatRate(double r)
{
    return r >= 10.0 ? format("%.0f tok/s", r) : format("%.1f tok/s", r);
}

private enum BG = "\x1b[0;48;5;236;38;5;250m";
private enum RESET = "\x1b[0m";

private struct Segment
{
    string text;
    string color; /// null: the background colour
    ubyte priority; /// lower is dropped first when too wide
}

/// Index of the cwd segment (after the model).
private enum cwdSegment = 1;
/// The narrowest the cwd is elided to before whole segments are dropped.
private enum cwdMinCells = 16;

/// Total terminal cells of `text`.
size_t cellWidth(string text)
{
    size_t w;
    foreach (dchar c; text) w += charWidth(c);
    return w;
}

/// `text` cut to at most `budget` cells, never splitting a wide glyph;
/// control characters are dropped (they would move the cursor).
string fitCells(string text, size_t budget)
{
    string out_;
    size_t used;
    foreach (dchar c; text)
    {
        if (c < 0x20 || (c >= 0x7f && c < 0xa0)) continue;
        auto w = charWidth(c);
        if (used + w > budget) break;
        out_ ~= c;
        used += w;
    }
    return out_;
}

/// `path` with the home directory shown as `~` (whole components only; the
/// symlink-resolved home matches too, as on macOS `/tmp` is `/private/tmp`).
string tildePath(string path, string home) @trusted
{
    import std.path : pathSplitter;
    import std.range : walkLength;
    import std.file : exists;
    static string rest(string p, string h)
    {
        if (h.length < 2) return null;
        while (h.length > 1 && h[$ - 1] == '/') h = h[0 .. $ - 1];
        if (p == h) return "";
        if (p.length > h.length && p[0 .. h.length] == h && p[h.length] == '/') return p[h.length + 1 .. $];
        return null;
    }
    if (home.length && home.pathSplitter.walkLength <= 1) home = null;
    string resolved;
    if (home.length && home.exists)
    {
        import core.sys.posix.stdlib : realpath;
        import core.stdc.stdlib : free;
        import std.string : toStringz, fromStringz;
        auto r = realpath(home.toStringz, null);
        if (r !is null)
        {
            resolved = r.fromStringz.idup;
            free(r);
            if (resolved.pathSplitter.walkLength <= 1) resolved = null;
        }
    }
    auto r = rest(path, home);
    if (r is null) r = rest(path, resolved);
    if (r is null) return path;
    return r.length ? "~/" ~ r : "~";
}

/// `path` shortened to `budget` cells by replacing middle directories with
/// `…` (`~/…/src/providers`), or, when even that won't fit, the end of the
/// last component (`…providers`).
string elidePath(string path, size_t budget)
{
    import std.array : split, join;
    if (cellWidth(path) <= budget) return path;
    auto parts = path.split("/");
    size_t headLen = parts.length && parts[0] == "" ? 2 : 1;
    if (parts.length > headLen + 1)
    {
        auto head = parts[0 .. headLen].join("/");
        size_t keep;
        while (headLen + keep + 1 < parts.length)
        {
            auto tail = parts[$ - keep - 1 .. $].join("/");
            if (cellWidth(head ~ "/…/" ~ tail) > budget) break;
            keep++;
        }
        if (keep > 0) return head ~ "/…/" ~ parts[$ - keep .. $].join("/");
    }
    if (budget == 0) return "";
    dchar[] kept;
    size_t used = 1;
    auto chars = path.to!(dchar[]);
    foreach_reverse (c; chars)
    {
        auto w = charWidth(c);
        if (used + w > budget) break;
        kept = c ~ kept;
        used += w;
    }
    return "…" ~ kept.to!string;
}

private string repeatStr(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n) r ~= s;
    return r;
}

/// The status bar at `cols` columns (no cursor positioning).
string render(const ref Stats stats, size_t cols)
{
    import std.math : round;
    auto percent = stats.percent;
    string barColor;
    if (stats.autoCompact && percent >= stats.threshold * 100.0) barColor = "\x1b[38;5;203m";
    else if (percent >= 90.0) barColor = "\x1b[38;5;203m";
    else if (percent >= 60.0) barColor = "\x1b[38;5;221m";
    else barColor = "\x1b[38;5;114m";
    auto filled = cast(size_t) round(percent / 10.0);
    if (filled > 10) filled = 10;
    auto bar = repeatStr("█", filled) ~ repeatStr("░", 10 - filled);
    auto approx = stats.calibrated ? "" : "~";
    auto model = stats.model.length ? stats.provider ~ "/" ~ stats.model : stats.provider;

    Segment[] segments = [
        Segment(" " ~ model ~ " ", "\x1b[1;38;5;255m", 9),
        Segment(" " ~ stats.cwd ~ " ", null, 6),
        Segment(format(" ctx %s%s/%s %.0f%% ", approx, formatTokens(stats.tokens), formatTokens(stats.window), percent), null, 8),
        Segment(bar, barColor, 5),
        Segment(format("  %s msgs ", stats.messages), null, 3),
    ];
    if (stats.hasPlan) segments ~= Segment(format(" plan %s/%s ", stats.planDone, stats.planTotal), null, 4);
    // The mode only gets a segment when it is not the default.
    if (stats.mode == AgentMode.plan) segments ~= Segment(" plan ", "\x1b[1;38;5;221m", 10);
    else if (stats.mode == AgentMode.auto_) segments ~= Segment(" auto ", "\x1b[1;38;5;114m", 10);
    if (stats.thinking.length) segments ~= Segment(" think " ~ stats.thinking ~ " ", "\x1b[38;5;147m", 4);
    if (stats.sessionInputTokens + stats.sessionOutputTokens > 0)
        segments ~= Segment(format(" ↑%s ↓%s ", formatTokens(cast(size_t) stats.sessionInputTokens),
            formatTokens(cast(size_t) stats.sessionOutputTokens)), null, 2);
    if (stats.hasAic) segments ~= Segment(format(" %.1f AIC ", stats.aic), "\x1b[38;5;222m", 2);
    if (stats.historySearches + stats.historyReads > 0)
        segments ~= Segment(format(" hist %ss %sr ", stats.historySearches, stats.historyReads), null, 1);
    auto label = stats.smartCompact ? "smart-compact" : "auto-compact";
    auto compact = stats.autoCompact ? format(" %s %.0f%%", label, stats.threshold * 100.0) : format(" %s off", label);
    auto compacted = stats.compactions > 0 ? format(" (%s×)", stats.compactions) : "";
    segments ~= Segment(compact ~ compacted ~ " ", null, 1);
    final switch (stats.activity)
    {
        case Activity.idle: break;
        case Activity.thinking: segments ~= Segment(" ● thinking… ", "\x1b[38;5;117m", 7); break;
        case Activity.tool: segments ~= Segment(" ▶ " ~ stats.tool ~ " ", "\x1b[38;5;180m", 7); break;
        case Activity.compacting: segments ~= Segment(" ⟳ compacting… ", "\x1b[38;5;221m", 7); break;
    }
    if (stats.activity == Activity.thinking && stats.tokensPerSec > 0)
        segments ~= Segment(" " ~ formatRate(stats.tokensPerSec) ~ " ", "\x1b[38;5;108m", 0);

    size_t width(const Segment[] segs)
    {
        size_t w;
        foreach (s; segs) w += cellWidth(s.text);
        return w + (segs.length ? segs.length - 1 : 0);
    }
    // Too wide: first elide the cwd's middle directories (down to cwdMinCells).
    auto total = width(segments);
    if (total > cols)
    {
        auto overflow = total - cols;
        auto cwdW = cellWidth(stats.cwd);
        auto floor_ = cwdMinCells < cwdW ? cwdMinCells : cwdW;
        auto budget = cwdW > overflow ? cwdW - overflow : 0;
        if (budget < floor_) budget = floor_;
        segments[cwdSegment].text = " " ~ elidePath(stats.cwd, budget) ~ " ";
    }
    while (width(segments) > cols && segments.length > 1)
    {
        size_t lowest;
        foreach (i, s; segments) if (s.priority < segments[lowest].priority) lowest = i;
        segments = segments[0 .. lowest] ~ segments[lowest + 1 .. $];
    }

    string line = BG;
    size_t used;
    foreach (i, s; segments)
    {
        if (i > 0 && used < cols)
        {
            line ~= "│";
            used++;
        }
        auto text = fitCells(s.text, cols > used ? cols - used : 0);
        used += cellWidth(text);
        if (s.color.length) line ~= s.color ~ text ~ BG;
        else line ~= text;
    }
    line ~= repeatStr(" ", cols > used ? cols - used : 0);
    return line ~ RESET;
}

/// The last scrollable row: the bottom row is the status line's.
ushort scrollRegionBottom(ushort rows) { return cast(ushort)((rows < 2 ? 2 : rows) - 1); }

/// Scroll the region's content down `gap` rows (blank lines inserted at the
/// top) and move the cursor with it, so the conversation sits on the status line.
string anchorSequence(ushort gap)
{
    return gap == 0 ? "" : format("\x1b7\x1b[1;1H\x1b[%sL\x1b8\x1b[%sB", gap, gap);
}

/// Pin the status row and bottom-anchor the conversation, given the cursor
/// position (rows 0: unknown).
string installSequence(ushort rows, ushort curRow, ushort curCol)
{
    auto bottom = scrollRegionBottom(rows);
    if (curRow > 0 && curRow < bottom)
        return format("\x1b[1;%sr\x1b[%s;%sH", bottom, curRow, curCol) ~ anchorSequence(cast(ushort)(bottom - curRow));
    return format("\n\x1b[1A\x1b7\x1b[1;%sr\x1b8", bottom);
}

/// After a resize: drop the region, erase below the cursor (a reflowed old
/// bar may sit there) and re-pin for the new height. DECSTBM homes the cursor,
/// so it is restored before the erase.
string resizeSequence(ushort rows)
{
    return format("\x1b7\x1b[r\x1b8\x1b[J\x1b7\x1b[1;%sr\x1b8", scrollRegionBottom(rows));
}

/// Parse a cursor position report `ESC [ row ; col R`.
bool parseCursorReport(const(ubyte)[] bytes, out ushort row, out ushort col)
{
    import std.string : lastIndexOf, indexOf;
    auto s = (() @trusted => cast(string) bytes.idup)();
    auto start = s.lastIndexOf("\x1b[");
    if (start < 0 || !s.length || s[$ - 1] != 'R') return false;
    auto body_ = s[start + 2 .. $ - 1];
    auto semi = body_.indexOf(';');
    if (semi < 0) return false;
    try
    {
        row = body_[0 .. semi].to!ushort;
        col = body_[semi + 1 .. $].to!ushort;
        return true;
    }
    catch (Exception) return false;
}

/// The terminal's rows and columns (0, 0 when fd 1 is not a terminal).
ushort[2] terminalSize() @trusted
{
    import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
    winsize ws;
    if (ioctl(1, TIOCGWINSZ, &ws) != 0 || ws.ws_row == 0 || ws.ws_col == 0) return [0, 0];
    return [ws.ws_row, ws.ws_col];
}

/// Ask the terminal where the cursor is, reading the reply straight from
/// stdin with echo, line buffering and signals off. Only before the line
/// reader runs (it would race for the reply).
private bool queryCursorDirect(out ushort row, out ushort col) @trusted
{
    import core.sys.posix.termios;
    import core.sys.posix.poll : poll, pollfd, POLLIN;
    import core.sys.posix.unistd : read;
    import core.time : MonoTime, msecs;
    termios original;
    if (tcgetattr(0, &original) != 0) return false;
    auto raw = original;
    raw.c_lflag &= ~(ICANON | ECHO | ISIG);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(0, TCSANOW, &raw) != 0) return false;
    scope (exit) tcsetattr(0, TCSANOW, &original);
    writeFd(1, "\x1b[6n");
    auto deadline = MonoTime.currTime + 300.msecs;
    ubyte[] reply;
    while (!reply.length || reply[$ - 1] != 'R')
    {
        auto left = (deadline - MonoTime.currTime).total!"msecs";
        if (left <= 0) break;
        auto fd = pollfd(0, POLLIN, 0);
        if (poll(&fd, 1, cast(int) left) <= 0) break;
        ubyte b;
        if (read(0, &b, 1) != 1) break;
        reply ~= b;
    }
    return parseCursorReport(reply, row, col);
}

/// The pinned status line. `stats` is read at each draw (on any thread).
final class StatusLine
{
    private Stats delegate() @safe stats;
    private ushort rows, cols;
    private bool live;

    private this(Stats delegate() @safe stats, ushort rows, ushort cols)
    {
        this.stats = stats;
        this.rows = rows;
        this.cols = cols;
        live = true;
    }

    /// Reserve the bottom row when stdin and stdout are terminals of at least
    /// five rows and `AGENTIC_NO_STATUS` is unset; null otherwise.
    static StatusLine install(Stats delegate() @safe stats) @trusted
    {
        import core.sys.posix.unistd : isatty;
        import std.process : environment;
        if (!isatty(0) || !isatty(1) || environment.get("AGENTIC_NO_STATUS") !is null) return null;
        auto size = terminalSize();
        if (size[0] < 5) return null;
        ushort row, col;
        bool known = queryCursorDirect(row, col);
        writeFd(1, installSequence(size[0], known ? row : 0, col));
        auto s = new StatusLine(stats, size[0], size[1]);
        s.draw();
        return s;
    }

    /// Redraw against the current terminal size; a changed size re-pins the
    /// region first, in the same write.
    void draw() @trusted
    {
        synchronized (this) writeFd(1, sequence());
    }

    /// The bytes that redraw the bar (re-pinning first after a resize), for
    /// writers that must emit them in the same write as their own output (the
    /// line editor's erase-to-end-of-screen wipes the bar's row).
    string sequence() @trusted
    {
        synchronized (this)
        {
            if (!live) return "";
            auto size = terminalSize();
            if (size[0] == 0) return "";
            string prefix;
            if (size[0] != rows || size[1] != cols)
            {
                rows = size[0];
                cols = size[1];
                prefix = resizeSequence(rows);
            }
            auto st = stats();
            return format("%s\x1b7\x1b[%s;1H\x1b[2K%s\x1b8", prefix, rows, render(st, cols));
        }
    }

    /// Clear the screen and scrollback for a fresh conversation and re-pin.
    void clear() @trusted
    {
        synchronized (this)
        {
            if (!live) return;
            auto bottom = scrollRegionBottom(rows);
            writeFd(1, format("\x1b[r\x1b[H\x1b[2J\x1b[3J\x1b[1;%sr\x1b[%s;1H", bottom, bottom));
        }
        draw();
    }

    /// Clear the status line and give the whole screen back.
    void teardown() @trusted
    {
        synchronized (this)
        {
            if (!live) return;
            live = false;
            writeFd(1, format("\x1b7\x1b[%s;1H\x1b[2K\x1b[r\x1b8", rows));
        }
    }
}

/// Live output rate: ceil(bytes / 4) tokens over the time since the first
/// delta, once deltas span 250 ms, at most every 250 ms (Rust's RateMeter).
struct RateMeter
{
    private long firstMs = -1, lastEmitMs = -1;
    private size_t bytes;

    void reset() { this = RateMeter.init; }

    /// Record `n` bytes at `nowMs`; the rate when one is due, else 0.
    double record(size_t n, long nowMs)
    {
        if (n == 0) return 0;
        if (firstMs < 0) firstMs = nowMs;
        bytes += n;
        auto elapsed = nowMs - firstMs;
        if (elapsed < 250) return 0;
        if (lastEmitMs >= 0 && nowMs - lastEmitMs < 250) return 0;
        lastEmitMs = nowMs;
        return ((bytes + 3) / 4) / (elapsed / 1000.0);
    }
}

unittest
{
    import std.algorithm : canFind;
    import std.regex : regex, replaceAll;
    string visible(string s) { return s.replaceAll(regex(`\x1b\[[0-9;]*m`), ""); }
    Stats s = {provider: "openai", model: "gpt-4o", cwd: "~/workspace/nano/src/providers", tokens: 12_345,
        window: 128_000, messages: 7, autoCompact: true, threshold: 0.8};
    auto line = visible(render(s, 200));
    assert(cellWidth(line) == 200);
    assert(line.canFind(" openai/gpt-4o │ ~/workspace/nano/src/providers │ ctx ~12.3k/128k 10% │█░░░░░░░░░│  7 msgs │ auto-compact 80% "));
    // Narrow: the cwd is elided first, then low-priority segments go.
    line = visible(render(s, 70));
    assert(cellWidth(line) == 70 && line.canFind("…") && line.canFind("openai/gpt-4o"));
    line = visible(render(s, 20));
    assert(cellWidth(line) == 20 && line.canFind("openai/gpt-4o"));
    s.mode = AgentMode.plan;
    s.activity = Activity.tool;
    s.tool = "bash";
    s.sessionInputTokens = 1500;
    s.sessionOutputTokens = 20;
    s.compactions = 2;
    line = visible(render(s, 300));
    assert(line.canFind("│ plan │") && line.canFind(" ▶ bash ") && line.canFind(" ↑1.5k ↓20 ") && line.canFind("(2×)"));
    s.activity = Activity.thinking;
    s.tokensPerSec = 42.4;
    assert(visible(render(s, 300)).canFind(" 42 tok/s "));
    assert(formatRate(3.25) == "3.2 tok/s" || formatRate(3.25) == "3.3 tok/s");

    assert(elidePath("~/workspace/nano/src/providers", 100) == "~/workspace/nano/src/providers");
    assert(elidePath("~/workspace/nano/src/providers", 20) == "~/…/src/providers");
    assert(elidePath("/usr/local/share/very/deep", 18) == "/usr/…/very/deep");
    assert(elidePath("~/averyveryverylongdirectory", 10) == "…directory");
    assert(fitCells("a\x1b[2Jb世c", 4) == "a[2J" && fitCells("ab世c", 3) == "ab");

    assert(tildePath("/home/joshua/x", "/home/joshua") == "~/x");
    assert(tildePath("/home/joshua", "/home/joshua") == "~");
    assert(tildePath("/home/joshua2", "/home/joshua") == "/home/joshua2");
    assert(tildePath("/x", "/") == "/x");

    ushort r, c;
    assert(parseCursorReport(cast(const(ubyte)[]) "\x1b[12;5R", r, c) && r == 12 && c == 5);
    assert(!parseCursorReport(cast(const(ubyte)[]) "\x1b[12R", r, c));
    assert(installSequence(24, 10, 1) == "\x1b[1;23r\x1b[10;1H\x1b7\x1b[1;1H\x1b[13L\x1b8\x1b[13B");
    assert(installSequence(24, 0, 0) == "\n\x1b[1A\x1b7\x1b[1;23r\x1b8");
    assert(resizeSequence(30) == "\x1b7\x1b[r\x1b8\x1b[J\x1b7\x1b[1;29r\x1b8");

    RateMeter m;
    assert(m.record(400, 0) == 0 && m.record(400, 100) == 0);
    auto rate = m.record(400, 300);
    assert(rate > 999 && rate < 1001); // 300 tokens over 0.3 s
    assert(m.record(4, 400) == 0); // throttled
}
