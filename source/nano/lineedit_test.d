/// Line-editor reads driven key by key (lineedit.rs EditView/LineReader tests).
module nano.lineedit_test;
@safe:

version (unittest):

import nano.lineedit;

private:

struct Fed
{
    string[] queue;
    LineEditor ed;
    size_t[] draws;
    string[] rows;
    long t;

    static Fed make()
    {
        import std.array : join;
        Fed f;
        auto q = new string[1];
        auto counts = new size_t[1];
        auto seen = new string[1];
        f.queue = q;
        f.draws = counts;
        f.rows = seen;
        ByteSource src = (int) {
            if (!q[0].length) return -1;
            auto b = q[0][0];
            q[0] = q[0][1 .. $];
            return b == 0xff ? -1 : cast(int) b;
        };
        import std.regex : regex, replaceAll;
        f.ed = new LineEditor(src, (string[] r) {
            if (r.length) { counts[0]++; seen[0] = r.join("\n").replaceAll(regex(`\x1b\[[0-9;]*m`), ""); }
        },
            (string) {}, () => 80);
        auto clock = new long[1];
        f.ed.nowMs = () => clock[0] += 100;
        return f;
    }

    /// Type `keys` into a read (a turn's when `turn`), which then stops.
    Result type(string keys, bool turn = false)
    {
        auto q = queue;
        q[0] = keys;
        return ed.readLine("> ", "> ", turn, () => q[0].length == 0);
    }

    string line() { return ed.state.text; }
}

// rust: lineedit.rs::a_new_read_starts_a_fresh_escape_pair
// rust: lineedit.rs::escape_clears_through_the_reader_and_only_when_there_is_text
// rust: lineedit.rs::clear_input_if_any_empties_a_non_empty_line
unittest
{
    auto f = Fed.make();
    f.type("draft\x1b");
    f.type("\x1b");
    assert(f.line == "draft", "Esc presses split across reads never pair");
    f.type("\x1b\x1b");
    assert(f.line == "", "two Esc in one read clear the input");
    f.type("one\ntwo\x1b\x1b");
    assert(f.line == "", "a multi-line input clears too");
    assert(!f.ed.state.clear(), "an empty line has nothing to clear");
}

// rust: lineedit.rs::clear_input_if_any_is_an_inert_no_op_on_an_empty_line
unittest
{
    auto f = Fed.make();
    f.ed.state.history.record("earlier");
    assert(f.ed.state.history.up("") == "earlier", "recall entered the browsing state");
    auto gen = f.ed.state.generation;
    assert(!f.ed.state.clear() && f.ed.state.generation == gen, "the empty path changes nothing");
    assert(f.ed.state.history.down() == "", "the browsing position was not reset by the no-op");
}

// rust: lineedit.rs::an_arm_does_not_survive_an_intervening_turn
// rust: lineedit.rs::escape_during_a_turn_does_not_arm_the_prompt_clear
// rust: lineedit.rs::escape_during_compaction_neither_clears_nor_arms
// rust: lineedit.rs::non_idle_phase_marks_turn_and_restores_prompt_on_drop
unittest
{
    auto f = Fed.make();
    f.type("draft\x1b"); // arms
    f.type("", true); // a turn (or compaction) runs
    f.type("\x1b");
    assert(f.line == "draft", "one Esc after the turn must not complete the pre-turn arm");
    f.type("\x1b", true);
    f.type("\x1b");
    assert(f.line == "draft", "a turn-time Esc does not count toward the idle pair");
    f.type("\x1b\x1b");
    assert(f.line == "", "two idle presses clear");
}

// rust: lineedit.rs::escape_does_not_clear_the_input_during_a_turn
unittest
{
    auto f = Fed.make();
    f.type("steer this", true);
    assert(f.type("\x1b\x1b", true).outcome == Outcome.cancel, "Esc Esc in a turn cancels the turn");
    assert(f.line == "steer this", "Esc during a turn keeps the next message");
}

// rust: lineedit.rs::frame_mutation_invokes_the_draw_hook_once
// rust: lineedit.rs::frame_history_recall_invokes_the_draw_hook_once
// rust: lineedit.rs::frame_menu_marks_menu_visible_so_esc_can_hide_it
unittest
{
    import std.algorithm : canFind;
    auto f = Fed.make();
    f.type("");
    auto base = f.draws[0];
    f.type("/");
    assert(f.draws[0] - base == 2, "the read's first draw, then the insert once");
    assert(f.rows[0].canFind('\n'), "a `/` line shows the menu");
    base = f.draws[0];
    f.type("\x1b");
    assert(!f.rows[0].canFind('\n') && f.line == "/", "Esc hides the menu and keeps the line");
    f.type("h");
    assert(f.line == "/h" && f.rows[0].canFind('\n'), "a mutation reopens the menu: " ~ f.rows[0]);
    base = f.draws[0];
    f.type("\x7f");
    assert(f.draws[0] - base == 2, "backspace draws once");
    f.ed.state.history.record("/model gpt");
    f.ed.state.clear();
    base = f.draws[0];
    f.type("\x1b[A");
    assert(f.line == "/model gpt" && f.draws[0] - base == 2, "history recall draws once");
}

// rust: lineedit.rs::frame_hook_receives_the_command_menu_at_the_prompt
unittest
{
    import std.algorithm : canFind, count;
    auto f = Fed.make();
    f.type("/");
    auto all = f.rows[0].count('\n');
    f.type("he");
    assert(f.rows[0].canFind("/help") && f.rows[0].count('\n') < all, "typing narrows the menu:\n" ~ f.rows[0]);
    f.ed.state.clear();
    f.type("hi");
    assert(!f.rows[0].canFind("/help") && !f.rows[0].canFind('\n'), "no menu for plain text");
    f.ed.state.clear();
    f.type("/he", true);
    assert(!f.rows[0].canFind('\n'), "no menu during a turn:\n" ~ f.rows[0]);
}

// rust: lineedit.rs::frame_mode_submission_records_history
unittest
{
    auto f = Fed.make();
    assert(f.type("first\r").text == "first" && f.type("second\r").text == "second");
    f.type("\x1b[A");
    assert(f.line == "second");
    f.type("\x1b[A");
    assert(f.line == "first");
}
