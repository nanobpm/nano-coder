/// Frame composition and rendering through a minimal terminal emulator
/// (frame.rs tests).
module nano.frame_test;
@safe:

version (unittest):

import std.algorithm : all, any, canFind, count, filter, startsWith;
import std.array : array, replicate;
import std.regex : regex, replaceAll;
import std.utf : decode;
import nano.frame;

private:

string strip(string s) { return s.replaceAll(regex(`\x1b\[[0-9;?]*[A-Za-z]`), ""); }

/// Just enough of a VT100 for FrameRenderer's output: CUP, EL 2, ED 2/3,
/// CR/LF with scrolling, autowrap with a pending wrap, wide glyphs; SGR,
/// DECSTBM reset and synchronized-output modes are ignored.
struct Emu
{
    size_t rows, cols;
    dchar[][] grid;
    size_t r, c;
    bool wrapPending;
    string[] sink;
    FrameRenderer renderer;

    this(size_t rows, size_t cols)
    {
        auto buf = new string[1];
        sink = buf;
        renderer = new FrameRenderer((string s) { buf[0] ~= s; });
        resize(rows, cols);
    }

    void resize(size_t rows, size_t cols)
    {
        auto old = grid;
        this.rows = rows;
        this.cols = cols;
        grid = new dchar[][](rows, cols);
        foreach (ref row; grid) row[] = ' ';
        foreach (i; 0 .. rows < old.length ? rows : old.length)
            foreach (j; 0 .. cols < old[i].length ? cols : old[i].length) grid[i][j] = old[i][j];
        if (r >= rows) r = rows - 1;
        if (c >= cols) c = cols - 1;
        wrapPending = false;
    }

    void render(const string[] frame)
    {
        renderer.render(frame, cols, rows);
        feed(sink[0]);
        sink[0] = null;
    }

    void lineFeed()
    {
        if (r + 1 < rows) { r++; return; }
        grid = grid[1 .. $] ~ new dchar[](cols);
        grid[$ - 1][] = ' ';
    }

    void feed(string s)
    {
        import std.conv : to;
        import std.string : split;
        size_t i;
        while (i < s.length)
        {
            auto ch = decode(s, i);
            if (ch == '\r') { c = 0; wrapPending = false; continue; }
            if (ch == '\n') { lineFeed(); wrapPending = false; continue; }
            if (ch == '\x1b')
            {
                assert(i < s.length && s[i] == '[', "unexpected escape");
                auto start = ++i;
                while (!(s[i] >= '@' && s[i] <= '~')) i++;
                auto params = s[start .. i];
                auto fin = s[i++];
                if (fin == 'H')
                {
                    auto p = params.length ? params.split(";") : ["1", "1"];
                    r = p[0].to!size_t - 1;
                    c = (p.length > 1 ? p[1].to!size_t : 1) - 1;
                    wrapPending = false;
                }
                else if (fin == 'K') grid[r][] = ' ';
                else if (fin == 'J' && params == "2") foreach (ref row; grid) row[] = ' ';
                continue;
            }
            auto w = cellWidth(ch);
            if (!w) continue;
            if (wrapPending || c + w > cols) { c = 0; lineFeed(); wrapPending = false; }
            grid[r][c] = ch;
            if (w == 2) grid[r][c + 1] = 0;
            c += w;
            if (c >= cols) { c = cols - 1; wrapPending = true; }
        }
    }

    string[] screen() const
    {
        import std.conv : to;
        import std.string : stripRight;
        string[] out_;
        foreach (row; grid) out_ ~= row.filter!(ch => ch != 0).array.to!string.stripRight;
        return out_;
    }
}

/// The transcript as the console printed it, wrapped to `width`.
string[] transcript(string printed, size_t width)
{
    Transcript t;
    t.feed(cast(const(ubyte)[]) printed);
    return t.render(width);
}

string[] sampleFrame(size_t width)
{
    auto t = transcript("› please summarise the plan\nhere is a fairly long answer that is meant to wrap onto "
        ~ "more than one row when the terminal is narrow\n", width);
    return compose(t, editorLines("› ", "my next question"d, 16, width), "MODEL  ctx 10% ");
}

/// A raw line wider than the terminal (the terminal wraps it), then an answer.
string[] wideRawFrame(size_t width, string marker)
{
    auto t = [`{"k":"` ~ "x".replicate(width * 3) ~ `"}`, "answer " ~ marker];
    return compose(t, editorLines("› ", "next"d, 4, width), "BAR");
}

// rust: frame.rs::bar_is_the_last_row_with_the_editor_above_and_no_duplicates
unittest
{
    auto emu = Emu(24, 80);
    emu.render(sampleFrame(80));
    auto screen = emu.screen;
    assert(screen[$ - 1] == "MODEL  ctx 10%", screen[$ - 1]);
    assert(screen[$ - 2].canFind("my next question"), screen[$ - 2]);
    assert(screen.count!(r => r.canFind("ctx 10%")) == 1);
}

// rust: frame.rs::a_width_change_reflows_history
unittest
{
    import std.range : walkLength;
    auto emu = Emu(24, 80);
    emu.render(sampleFrame(80));
    auto wide = emu.screen.count!(r => r.canFind("fairly long answer"));
    emu.resize(24, 30);
    emu.render(sampleFrame(30));
    auto narrow = emu.screen;
    assert(narrow[$ - 1] == "MODEL  ctx 10%" && narrow.count!(r => r.canFind("ctx 10%")) == 1);
    assert(narrow.all!(r => r.walkLength <= 30));
    auto rows = narrow.count!(r => r.canFind("fairly") || r.canFind("answer") || r.canFind("wrap"));
    assert(rows > wide, "history did not reflow");
}

// rust: frame.rs::a_resize_drag_ends_on_a_stable_correct_frame
unittest
{
    auto emu = Emu(24, 80);
    emu.render(sampleFrame(80));
    foreach (i; 0 .. 20)
    {
        auto cols = 40 + i % 40;
        emu.resize(24, cols);
        emu.render(sampleFrame(cols));
    }
    emu.resize(24, 64);
    emu.render(sampleFrame(64));
    auto first = emu.screen;
    emu.render(sampleFrame(64));
    auto second = emu.screen;
    assert(first == second, "frame not stable after the drag");
    assert(second[$ - 1] == "MODEL  ctx 10%" && second.count!(r => r.canFind("ctx 10%")) == 1);
    assert(second[$ - 2].canFind("my next question"));
}

// rust: frame.rs::a_wrapping_raw_line_keeps_the_bar_on_the_last_row
unittest
{
    auto emu = Emu(24, 40);
    emu.render(wideRawFrame(40, "a"));
    auto screen = emu.screen;
    assert(screen[$ - 1] == "BAR" && screen.count!(r => r.canFind("BAR")) == 1, screen[$ - 1]);
    assert(screen[$ - 2].canFind("next"), "editor not above the bar");
}

// rust: frame.rs::a_differential_render_after_a_wrapping_raw_line_addresses_real_rows
unittest
{
    auto emu = Emu(24, 40);
    emu.render(wideRawFrame(40, "a"));
    emu.render(wideRawFrame(40, "b"));
    auto screen = emu.screen;
    assert(screen[$ - 1] == "BAR" && screen.count!(r => r.canFind("BAR")) == 1, "bar duplicated");
    assert(screen.any!(r => r.canFind("answer b")), "update lost");
    assert(!screen.any!(r => r.canFind("answer a")), "stale row left behind");
}

// rust: frame.rs::composes_transcript_editor_then_status_last
unittest
{
    assert(compose(["a", "b"], ["› hi"], "STATUS") == ["a", "b", "› hi", "STATUS"]);
}

// rust: frame.rs::cursor_marker_reserves_a_cell_on_a_full_row
unittest
{
    import std.conv : to;
    auto text = "abcdefghijklmnopqrstuvwxyz"d;
    foreach (cursor; 0 .. text.length)
        foreach (line; editorLines("› ", text, cursor, 12))
            assert(visibleWidth(line) <= 12, line);
}

// rust: frame.rs::editor_marks_the_cursor_and_wraps
unittest
{
    auto lines = editorLines("› ", "hello"d, 5, 20);
    assert(lines.length == 1 && lines[0].canFind("\x1b[7m"));
    auto long_ = editorLines("› ", "x"d.replicate(50), 50, 10);
    assert(long_.length > 1 && long_.all!(l => visibleWidth(l) <= 10));
}

// rust: frame.rs::queue_indicator_shows_only_when_queued
unittest
{
    assert(queueIndicator(0, 40) is null);
    assert(strip(queueIndicator(2, 40)).canFind("⏸2 queued · /queue to edit"), queueIndicator(2, 40));
    assert(visibleWidth(queueIndicator(3, 6)) <= 6);
}

// rust: frame.rs::renders_items_within_the_width
// rust: frame.rs::message_stamp_is_shown_and_rows_stay_within_width
unittest
{
    enum stamp = "\x1b[2m12:34:56\x1b[0m ";
    auto printed = stamp ~ "a fairly long assistant answer that should wrap\n" ~ stamp
        ~ "● bash ls -la /some/very/long/path/that/overflows\n  ⎿ line1 (+2 lines)\n"
        ~ "a note that is also rather long and needs wrapping\n";
    assert(transcript(printed, 20).all!(l => visibleWidth(l) <= 20));
    auto user = stamp ~ "› a fairly long user question that wraps onto several rows\n";
    foreach (width; 4 .. 40)
        assert(transcript(user, width).all!(l => visibleWidth(l) <= width));
    assert(strip(transcript(user, 30)[0]).startsWith("12:34:56 › "));
    assert(strip(transcript("› hi\n", 30)[0]) == "› hi");
}

// rust: frame.rs::assistant_tables_are_laid_out_and_reflow_with_width
unittest
{
    import std.algorithm : map;
    import nano.markdown : renderLines;
    enum text = "Sizes:\n| Name | Notes |\n|---|---|\n| alpha | first entry in the list |";
    auto wide = renderLines(text, 80).map!strip.array;
    assert(wide[0] == "Sizes:" && wide[1] == "", wide[1]);
    assert(wide[2] == "┌───────┬─────────────────────────┐", wide[2]);
    assert(wide[5] == "│ alpha │ first entry in the list │", wide[5]);
    auto narrow = renderLines(text, 24).map!strip.array;
    assert(narrow.length > wide.length && narrow.all!(l => visibleWidth(l) <= 24));
}

// rust: frame.rs::plan_header_is_bounded_to_the_width
// rust: frame.rs::plan_item_wraps_and_marks_status
unittest
{
    import std.string : lineSplitter;
    import nano.plan : checklist, Plan, PlanItem, Status;
    Plan empty;
    foreach (width; 3 .. 20)
        foreach (line; checklist(empty, width, true).lineSplitter)
            assert(visibleWidth(line) <= width, line);
    auto plan = Plan(null, [PlanItem(1, "do the first thing", Status.done), PlanItem(2, "do the second thing", Status.inProgress)]);
    auto lines = checklist(plan, 30, true).lineSplitter.array;
    assert(strip(lines[0]).canFind("1/2 done") && lines.length >= 3, lines[0]);
}

/// A wide glyph one cell short of the edge wraps natively; no pad space is
/// emitted into the copied text. A separator the wrap consumed rides the
/// continuation row as a zero-cell mark and is emitted as a space, so copied
/// words stay apart.
unittest
{
    string outp;
    auto r = new FrameRenderer((string s) { outp ~= s; });
    r.render(["rm -r /ab", softWrapMark ~ "中/x"], 10, 5);
    assert(!outp.canFind("/ab 中"), outp);
    assert(outp.canFind("/ab中"), outp);
    auto emu = Emu(5, 10);
    emu.render(["rm -r /ab", softWrapMark ~ "中/x"]);
    assert(emu.screen()[$ - 2 .. $] == ["rm -r /ab", "中/x"], (){ import std.conv : to; return emu.screen().to!string; }());

    outp = null;
    auto s = new FrameRenderer((string s) { outp ~= s; });
    s.render(["cmd", softWrapMark ~ sepWrapMark ~ "中"], 4, 5);
    assert(outp.canFind("cmd 中"), outp);
    auto emu2 = Emu(5, 5);
    emu2.render(["cmdx", softWrapMark ~ sepWrapMark ~ "中"]);
    assert(emu2.screen()[$ - 2 .. $] == ["cmdx", "中"], (){ import std.conv : to; return emu2.screen().to!string; }());
}

/// A soft wrap that becomes a hard newline rewrites the row above, so its
/// terminal wrap flag is cleared.
unittest
{
    string outp;
    auto r = new FrameRenderer((string s) { outp ~= s; });
    r.render(["abcd", softWrapMark ~ "ef", "s"], 4, 5);
    outp = null;
    r.render(["abcd", "ef", "s"], 4, 5);
    assert(outp.canFind("abcd"), outp);
    assert(outp.canFind("abcd\r\n"), outp);
}

/// A join at the top of the screen that changes redraws everything: the row
/// above is scrollback and its wrap flag can't be rewritten in place.
unittest
{
    import std.algorithm : canFind;
    foreach (pair; [[["abcd", softWrapMark ~ "ef", "s"], ["abcd", "ef", "s"]],
                    [["abcd", "ef", "s"], ["abcd", softWrapMark ~ "ef", "s"]]])
    {
        string outp;
        auto r = new FrameRenderer((string s) { outp ~= s; });
        r.render(pair[0], 4, 2);
        outp = null;
        r.render(pair[1], 4, 2);
        assert(outp.canFind("\x1b[3J"), outp);
    }
    // An unchanged join at the top stays a bounded rewrite.
    string outp;
    auto r = new FrameRenderer((string s) { outp ~= s; });
    r.render(["abcd", softWrapMark ~ "ef", "s"], 4, 2);
    outp = null;
    r.render(["abcd", softWrapMark ~ "eg", "s"], 4, 2);
    assert(!outp.canFind("\x1b[3J"), outp);
}

unittest // an editor that shrinks while partly in scrollback keeps the scrollback
{
    string screen;
    auto r = new FrameRenderer((string s) { screen ~= s; });
    // Two transcript rows, a six-row editor and a status row on four rows.
    r.render(["t0", "t1", "e0", "e1", "e2", "e3", "e4", "e5", "st"], 10, 4, 2);
    screen = null;
    r.render(["t0", "t1", "e0", "st"], 10, 4, 2);
    assert(!screen.canFind("\x1b[3J") && !screen.canFind("\x1b[2J"), strip(screen));
    screen = null;
    r.render(["t0", "t1", "e0", "st"], 10, 4, 2);
    assert(!screen.canFind("\x1b[3J"), strip(screen));
}

unittest // a shrinking soft-wrapped draft opens its gap past the wrap, stably
{
    string screen;
    auto r = new FrameRenderer((string s) { screen ~= s; });
    r.render(["t0", "a1", softWrapMark ~ "a2", softWrapMark ~ "a3", softWrapMark ~ "a4", "b", "c", "st"], 10, 4);
    screen = null;
    r.render(["t0", "a1", softWrapMark ~ "a2", softWrapMark ~ "a3", softWrapMark ~ "a4", "st"], 10, 4);
    assert(!screen.canFind("\x1b[3J"), strip(screen));
    screen = null;
    r.render(["t0", "a1", softWrapMark ~ "a2", softWrapMark ~ "a3", softWrapMark ~ "a4", "st"], 10, 4);
    assert(!screen.canFind("\x1b[3J"), strip(screen));
}

unittest // output after a scrolled-off editor shrank fills the gap, keeping scrollback
{
    string screen;
    auto r = new FrameRenderer((string s) { screen ~= s; });
    r.render(["t0", "t1", "e0", "e1", "e2", "e3", "e4", "e5", "st"], 10, 4, 2);
    r.render(["t0", "t1", "e0", "st"], 10, 4, 2);
    screen = null;
    r.render(["t0", "t1", "new output", "e0", "st"], 10, 4, 3);
    assert(!screen.canFind("\x1b[3J") && !screen.canFind("\x1b[2J"), strip(screen));
    assert(screen.canFind("new output"), strip(screen));
    screen = null;
    r.render(["t0", "t1", "new output", "more", "e0", "st"], 10, 4, 4);
    assert(!screen.canFind("\x1b[3J"), strip(screen));
    assert(screen.canFind("more"), strip(screen));
    // A change inside the frozen transcript still redraws everything.
    screen = null;
    r.render(["t0", "T1", "new output", "more", "e0", "st"], 10, 4, 4);
    assert(screen.canFind("\x1b[3J"), strip(screen));
    assert(!screen.canFind("e5"), strip(screen));
}
