/// Input history for the prompt's line editor: submitted lines, newest last,
/// with shell-style Up/Down recall (port of `input_history.rs`). Session-scoped:
/// nothing is written to disk of its own; a resumed session is seeded from the
/// prompts in its log (`RecentInputs`, `InputHistory.seed`).
module nano.history;

import std.string : strip;
import nano.arith : saturatingSub;

@safe:
pure:

struct InputHistory
{
    /// Most entries kept; the oldest drop off the front.
    enum maxEntries = 200;
    /// Byte cap across all stored entries, so large pasted prompts cannot pin
    /// megabytes in session history (issue #310).
    enum size_t maxBytes = 512 * 1024;

    string[] lines;
    /// Running byte total of `lines` (text + slice header per entry).
    private size_t heldBytes;
    /// While browsing: the entry shown (-1 = the draft at the bottom).
    private ptrdiff_t position = -1;
    /// The line before the first Up, restored by Down past the newest.
    private string draft;

    private static size_t entryCost(string l) pure nothrow @nogc { return l.length + string.sizeof; }

    /// Record a submitted line; blanks and repeats of the previous line aren't kept.
    void record(string line) pure
    {
        if (!line.strip.length || (lines.length && lines[$ - 1] == line)) return;
        // An entry over the whole budget is not kept at all: otherwise a huge
        // paste would stay resident as the sole entry, unbounded.
        if (entryCost(line) > maxBytes) return;
        lines ~= line;
        heldBytes += entryCost(line);
        size_t drop;
        while (lines.length - drop > maxEntries || (lines.length - drop > 1 && heldBytes > maxBytes))
        {
            auto c = entryCost(lines[drop++]);
            heldBytes = saturatingSub(heldBytes, c);
        }
        // Copy, not slice: a suffix slice pins dropped backing-array entries
        // under D's conservative GC.
        if (drop) lines = lines[drop .. $].dup;
    }

    /// Replace the history with `older` (oldest first), as if each had been
    /// submitted in order: a resumed session recalls its earlier prompts.
    void seed(const string[] older) pure
    {
        this = InputHistory.init;
        foreach (l; older) record(l);
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

/// The newest prompts of a long sequence, kept within `InputHistory`'s
/// caps while it streams past: restoring a session log of 40k prompts holds
/// at most about twice the history's budget, never the whole run.
struct RecentInputs
{
    private string[] buf;
    private size_t bytes;

    /// Add the next prompt (newest last). Blank ones and any over the whole
    /// byte budget are skipped, as `InputHistory.record` would.
    void put(string line) pure
    {
        if (!line.strip.length || line.length + string.sizeof > InputHistory.maxBytes) return;
        buf ~= line;
        bytes += line.length + string.sizeof;
        if (buf.length >= 2 * InputHistory.maxEntries || bytes > 2 * InputHistory.maxBytes) trim();
    }

    /// The kept prompts, oldest first, at most the history's caps.
    string[] lines() pure
    {
        trim();
        return buf;
    }

    /// Drop the oldest beyond the history's entry and byte caps (a copy, so
    /// the dropped entries are not pinned by the backing array).
    private void trim() pure
    {
        size_t keep, kept;
        while (keep < buf.length && keep < InputHistory.maxEntries)
        {
            immutable c = buf[$ - 1 - keep].length + string.sizeof;
            if (keep && kept + c > InputHistory.maxBytes) break;
            kept += c;
            ++keep;
        }
        if (keep == buf.length) return;
        buf = buf[$ - keep .. $].dup;
        bytes = kept;
    }
}

unittest // a resumed session's prompts seed Up/Down recall, newest first
{
    RecentInputs r;
    foreach (i; 0 .. 1000) r.put(i % 2 ? "even" : "odd");
    r.put("  ");
    r.put("last");
    auto kept = r.lines;
    assert(kept.length == InputHistory.maxEntries && kept[$ - 1] == "last", "newest kept within the entry cap");
    InputHistory h;
    h.record("from the old process");
    h.seed(["first", "second", "second"]);
    assert(h.lines == ["first", "second"], "seed replaces and dedupes like record");
    assert(h.up("") == "second" && h.up("second") == "first");
}

unittest // the byte cap bounds the kept prompts, not just their count
{
    import std.array : replicate;
    RecentInputs r;
    auto big = "x".replicate(100 * 1024);
    foreach (i; 0 .. 50) r.put(big);
    r.put("x".replicate(InputHistory.maxBytes)); // over the whole budget: skipped
    size_t total;
    foreach (l; r.lines) total += l.length + string.sizeof;
    assert(total <= InputHistory.maxBytes && r.lines.length == 5, "within maxBytes");
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

    // Byte cap evicts oldest large entries while keeping at least the newest.
    import std.array : replicate;
    InputHistory big;
    string chunk = "x".replicate(200 * 1024);
    big.record(chunk ~ "1");
    big.record(chunk ~ "2");
    big.record(chunk ~ "3");
    assert(big.lines.length == 2, "3 x 200 KiB exceeds 512 KiB cap; oldest evicted");
    assert(big.lines[0][$ - 1] == '2' && big.lines[1][$ - 1] == '3');
    // A single entry larger than maxBytes is not kept; earlier entries stay.
    auto keptBefore = big.lines.dup;
    string huge = "y".replicate(InputHistory.maxBytes + 1024);
    big.record(huge);
    assert(big.lines == keptBefore);
    InputHistory solo;
    solo.record(huge);
    assert(solo.lines.length == 0);
}
