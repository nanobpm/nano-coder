/// Input history for the prompt's line editor: submitted lines, newest last,
/// with shell-style Up/Down recall (port of `input_history.rs`). Session-scoped:
/// nothing is written to disk.
module nano.history;

import std.string : strip;

@safe:

struct InputHistory
{
    /// Most entries kept; the oldest drop off the front.
    enum maxEntries = 200;

    string[] lines;
    /// While browsing: the entry shown (-1 = the draft at the bottom).
    private ptrdiff_t position = -1;
    /// The line before the first Up, restored by Down past the newest.
    private string draft;

    /// Record a submitted line; blanks and repeats of the previous line aren't kept.
    void record(string line) pure
    {
        if (!line.strip.length || (lines.length && lines[$ - 1] == line)) return;
        lines ~= line;
        if (lines.length > maxEntries) lines = lines[1 .. $];
    }

    /// The entry one older than shown, or null at the oldest. The first call
    /// saves `current` as the draft.
    string up(string current) pure
    {
        if (position < 0)
        {
            if (!lines.length) return null;
            draft = current;
            position = lines.length - 1;
        }
        else
        {
            if (position == 0) return null;
            --position;
        }
        return lines[position];
    }

    /// The entry one newer; past the newest, the saved draft. null when not browsing.
    string down() pure
    {
        if (position < 0) return null;
        if (position + 1 < lines.length) return lines[++position];
        position = -1;
        return draft is null ? "" : draft;
    }

    /// The line changed by other means: the next Up starts from the newest.
    void edited() pure { position = -1; }

    /// Take the browsing state (position and saved draft), leaving history
    /// not browsing, for a parked editor line (`restoreBrowsing` puts it back).
    HistoryBrowsing parkBrowsing() pure
    {
        auto b = HistoryBrowsing(position, draft);
        position = -1;
        draft = null;
        return b;
    }

    /// ditto
    void restoreBrowsing(HistoryBrowsing b) pure
    {
        position = b.position;
        draft = b.draft;
    }
}

/// The browsing state set aside with a parked draft.
struct HistoryBrowsing
{
    private ptrdiff_t position = -1;
    private string draft;
}

// rust: input_history.rs::parking_round_trips_the_browsing_state
unittest
{
    InputHistory h;
    h.record("first");
    h.record("second");
    assert(h.up("typed so far") == "second");
    auto b = h.parkBrowsing();
    assert(h.down() is null, "parked history is not browsing");
    assert(h.up("") == "second", "a fresh Up starts from the newest again");
    h.edited();
    h.restoreBrowsing(b);
    assert(h.down() == "typed so far", "Down reaches the pre-Up draft again");
    assert(h.down() is null, "past the draft: no longer browsing");
}

unittest // ports input_history.rs tests
{
    InputHistory h;
    assert(h.up("draft") is null && h.down() is null);
    h.record("one");
    h.record("two");
    h.record("two");
    h.record("  ");
    assert(h.lines == ["one", "two"]);
    assert(h.up("draft") == "two");
    assert(h.up("two") == "one");
    assert(h.up("one") is null);
    assert(h.down() == "two");
    assert(h.down() == "draft");
    assert(h.down() is null);
    // Editing a recalled entry restarts from the newest; the edit is the draft.
    assert(h.up("") == "two");
    h.edited();
    assert(h.up("two!") == "two");
    assert(h.down() == "two!");
    foreach (i; 0 .. 250)
    {
        import std.conv : to;
        h.record(i.to!string);
    }
    assert(h.lines.length == InputHistory.maxEntries && h.lines[$ - 1] == "249");
}

// rust: input_history.rs::an_edit_resets_browsing_to_the_newest
// rust: input_history.rs::down_returns_to_the_draft
// rust: input_history.rs::skips_blanks_and_immediate_repeats_and_bounds_the_list
// rust: input_history.rs::up_walks_back_then_stops_at_the_oldest
unittest
{
    import std.format : format;
    InputHistory h;
    assert(h.up("") is null, "empty history");
    h.record("first");
    h.record("second");
    assert(h.up("") == "second");
    h.edited();
    assert(h.up("") == "second");
    assert(h.down() == "" && h.down() is null);

    assert(h.up("typed so far") == "second" && h.up("second") == "first");
    assert(h.up("") is null, "at the oldest: stay");
    assert(h.down() == "second" && h.down() == "typed so far" && h.down() is null);

    InputHistory b;
    foreach (l; ["  ", "one", "one", " one "]) b.record(l);
    assert(b.lines == ["one", " one "], "whitespace variants are kept verbatim");
    foreach (i; 0 .. InputHistory.maxEntries + 10) b.record(format("line %s", i));
    assert(b.lines.length == InputHistory.maxEntries && b.lines[0] == "line 10");
}
