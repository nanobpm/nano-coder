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
    void record(string line)
    {
        if (!line.strip.length || (lines.length && lines[$ - 1] == line)) return;
        lines ~= line;
        if (lines.length > maxEntries) lines = lines[1 .. $];
    }

    /// The entry one older than shown, or null at the oldest. The first call
    /// saves `current` as the draft.
    string up(string current)
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
    string down()
    {
        if (position < 0) return null;
        if (position + 1 < lines.length) return lines[++position];
        position = -1;
        return draft is null ? "" : draft;
    }

    /// The line changed by other means: the next Up starts from the newest.
    void edited() { position = -1; }
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
