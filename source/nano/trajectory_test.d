/// Trajectory ledger built from session records (trajectory.rs tests).
module nano.trajectory_test;
@safe:

version (unittest):

import std.algorithm : canFind, count, filter;
import std.array : array;
import std.json;
import nano.trajectory;

private:

enum ts = `"timestamp":"2026-01-02T03:04:06+13:00"`;
enum metrics = `"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120},"duration_ms":1500,` ~ ts;
enum header = `{"type":"session","data":{"version":1,"id":"s","created_at":"2026-01-02T03:04:05+13:00"}}`;

/// The shared fixture: one turn with a read_file call, its result and the answer.
string[] records()
{
    return [
        `{"type":"session","data":{"version":1,"id":"sess-x","created_at":"2026-01-02T03:04:05+13:00"}}`,
        `{"type":"message","data":{"role":"system","content":"sys",` ~ ts ~ `}}`,
        `{"type":"input","data":{"id":"in-1","text":"add a feature"}}`,
        `{"type":"message","data":{"role":"user","content":"add a feature",` ~ ts ~ `}}`,
        `{"type":"message","data":{"role":"assistant","content":"","thinking":"let me look","tool_calls":[{"id":"c1","name":"read_file","arguments":{"path":"a.rs"}}],` ~ metrics ~ `}}`,
        `{"type":"message","data":{"role":"tool","content":"ok","tool_call_id":"c1","name":"read_file",` ~ ts ~ `}}`,
        `{"type":"message","data":{"role":"assistant","content":"feature added",` ~ metrics ~ `}}`,
        `{"type":"turn_end","data":{"input_id":"in-1","response":"feature added","outcome":{"status":"completed","summary":"done"}}}`,
    ];
}

Trajectory traj(string[] lines)
{
    JSONValue[] recs;
    ulong[] nums;
    foreach (i, l; lines)
    {
        try recs ~= parseJSON(l);
        catch (JSONException e) assert(false, l);
        nums ~= i + 1;
    }
    return Trajectory.fromRecords(recs, nums);
}

/// A turn `go` whose messages are `messages`, then `tail` records.
string[] turn(string[] messages, string[] tail = null)
{
    return [header, `{"type":"input","data":{"id":"i","text":"go"}}`] ~ messages ~ tail;
}

enum userGo = `{"type":"message","data":{"role":"user","content":"go",` ~ ts ~ `}}`;

// rust: trajectory.rs::error_tool_is_marked
unittest
{
    auto recs = records();
    recs = recs[0 .. 6] ~ (`{"type":"message","data":{"role":"tool","content":"boom","tool_call_id":"c2","name":"bash","is_error":true,` ~ ts ~ `}}`)
        ~ recs[6 .. $];
    auto tool = traj(recs).turns[0].rows.filter!(r => r.kind == Kind.tool && r.name == "bash").array;
    assert(tool.length == 1 && !tool[0].ok && tool[0].label.canFind("error"), tool[0].label);
}

// rust: trajectory.rs::legacy_assistant_rows_without_metrics_still_count_as_calls
unittest
{
    auto t = traj(turn([userGo,
        `{"type":"message","data":{"role":"assistant","content":"working on it",` ~ ts ~ `}}`,
        `{"type":"message","data":{"role":"assistant","content":"done",` ~ ts ~ `}}`],
        [`{"type":"turn_end","data":{"input_id":"i","response":"done","outcome":{"status":"completed","summary":"done"}}}`]));
    auto s = t.turns[0].summary;
    assert(s.canFind("1 call") && !s.canFind("no activity"), s);
}

// rust: trajectory.rs::markdown_sanitizes_untrusted_content
unittest
{
    auto md = traj([header,
        `{"type":"input","data":{"id":"in-1","text":"ask\u001b[2Jwiped\nsecond"}}`,
        `{"type":"message","data":{"role":"user","content":"ask\u001b[2Jwiped\nsecond",` ~ ts ~ `}}`,
        `{"type":"message","data":{"role":"assistant","content":"resp\u001b]8;;http://evil\u0007x",` ~ metrics ~ `}}`,
        `{"type":"turn_end","data":{"input_id":"in-1","response":"final\u001b[31mred"}}`]).toMarkdown;
    assert(!md.canFind('\x1b'), "no ESC byte survives in the export");
    assert(md.canFind("ask[2Jwiped") && md.canFind("> second") && md.canFind("final[31mred"), md);
}

// rust: trajectory.rs::metrics_free_thinking_message_is_one_call_not_two
unittest
{
    auto t = traj(turn([userGo,
        `{"type":"message","data":{"role":"assistant","content":"thought through","thinking":"let me think",` ~ ts ~ `}}`],
        [`{"type":"turn_end","data":{"input_id":"i","response":"thought through"}}`]));
    assert(t.turns[0].rows.canFind!(r => r.kind == Kind.think));
    auto s = t.turns[0].summary;
    assert(s.canFind("1 call") && !s.canFind("2 calls"), s);
}

// rust: trajectory.rs::needs_pager_counts_wide_glyphs_that_cannot_start_in_the_last_column
unittest
{
    assert(wrappedRows("a界界界界界a界界界界", 10) == 3);
    assert(wrappedRows("界界界界界界界界", 5) == 4);
    assert(wrappedRows("界界", 4) == 1);
    assert(wrappedRows("界", 1) == 1);
}

// rust: trajectory.rs::opening_input_is_kept_as_a_user_row
// rust: trajectory.rs::ordinary_turn_does_not_duplicate_the_opening_user_row
unittest
{
    auto users = traj(records()).turns[0].rows.filter!(r => r.kind == Kind.user).array;
    assert(users.length == 1 && users[0].text == "add a feature");
}

// rust: trajectory.rs::orphaned_tool_result_without_a_call_row_still_counts_once
unittest
{
    auto s = traj(records()).turns[0].summary;
    assert(s.canFind("1 tool"), s);
}

// rust: trajectory.rs::outcome_free_turn_counts_its_real_final_response
unittest
{
    auto t = traj(turn([userGo, `{"type":"message","data":{"role":"assistant","content":"done",` ~ ts ~ `}}`],
        [`{"type":"turn_end","data":{"input_id":"i","response":"done"}}`]));
    auto s = t.turns[0].summary;
    assert(s.canFind("1 call") && !s.canFind("no activity"), s);
}

// rust: trajectory.rs::plain_render_emits_a_persisted_response_with_no_assistant_row
unittest
{
    auto plain = traj(turn([userGo], [`{"type":"turn_end","data":{"input_id":"i","response":"[turn cancelled]"}}`])).toPlain;
    assert(plain.canFind("RESPONSE") && plain.canFind("[turn cancelled]"), plain);
    plain = traj(records()).toPlain;
    assert(plain.count("feature added") == 1, plain);
}

// rust: trajectory.rs::thinking_blocks_supply_the_think_row_when_the_plain_field_is_empty
unittest
{
    auto t = traj(turn([`{"type":"message","data":{"role":"assistant","content":"the answer","thinking_blocks":[`
        ~ `{"type":"thinking","thinking":"reasoning in a block","signature":"sig"},{"type":"redacted_thinking","data":"..."}],`
        ~ metrics ~ `}}`]));
    auto rows = t.turns[0].rows;
    auto think = rows.filter!(r => r.kind == Kind.think).array;
    assert(think.length == 1 && think[0].text == "reasoning in a block");
    assert(think[0].durationMs == 1500, "the request metrics live on the THINK row");
    auto answer = rows.filter!(r => r.kind == Kind.assistant).array;
    assert(answer.length == 1 && !answer[0].hasUsage, "not double-counted on the paired ASSISTANT row");
    assert(t.turns[0].summary.canFind("1 call"), t.turns[0].summary);
}

// rust: trajectory.rs::tool_call_only_assistant_still_records_metrics
unittest
{
    auto rows = traj(turn([`{"type":"message","data":{"role":"assistant","content":"",`
        ~ `"tool_calls":[{"id":"c1","name":"grep","arguments":{"pattern":"foo"}}],` ~ metrics ~ `}}`])).turns[0].rows;
    assert(rows[0].kind == Kind.user && rows[0].text == "go");
    auto a = rows.filter!(r => r.kind == Kind.assistant).array;
    assert(a.length == 1 && a[0].durationMs == 1500 && a[0].text.canFind("grep"), a[0].text);
    auto call = rows.filter!(r => r.kind == Kind.toolCall).array;
    assert(call.length == 1 && call[0].callId == "c1" && call[0].name == "grep" && call[0].arguments.canFind("foo"));
    assert(call[0].label == "CALL grep");
}
