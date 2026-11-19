/// System reminders: short notes appended to tool results so the model sees
/// harness state at the moment it matters (port of `reminders.rs`). Covers the
/// stale-plan / suggest-plan / suggest-memory nudges and the loop detector
/// (issue #65): a repeated identical call is warned twice, then hard-stopped.
module nano.reminders;

@safe:

import std.algorithm : canFind, startsWith, all;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.json;
import std.string : strip;
import nano.plan : Plan, Status;

/// Remind about a stale plan after this many tool calls without a plan change.
enum size_t planStaleAfter = 12;
/// Suggest a plan after this many tool calls in one turn without one.
enum size_t suggestPlanAfter = 10;
/// Suggest saving a memory after this many tool calls without a save.
enum size_t suggestMemoryAfter = 30;
/// Warn after this many consecutive repeats of the same tool call.
enum size_t repeatWarnAfter = 3;
/// How often the repeat warning may fire in one turn before the hard stop.
enum size_t repeatMaxWarnings = 2;
/// Consecutive repeats of the current key needed for a hard stop once the
/// turn's warning budget is spent, so a fresh streak is never stopped before
/// it has ignored warnings of its own.
enum size_t repeatHardStopAfter = repeatWarnAfter + repeatMaxWarnings;

/// Tools where repeating a call is legitimate (waiting on a person).
immutable string[] repeatExemptTools = ["question"];

/// Wrap reminder text in `<system-reminder>` tags.
string wrap(string text)
{
    return "<system-reminder>\n" ~ text ~ "\n</system-reminder>";
}

/// What the loop detector decided about the call just recorded.
struct RepeatVerdict
{
    enum Kind { none, warning, hardStop }
    Kind kind;
    string text; /// the warning, or the hard-stop reason

    bool none() const { return kind == Kind.none; }
    bool warning() const { return kind == Kind.warning; }
    bool hardStop() const { return kind == Kind.hardStop; }
}

/// Tool-call counters behind the reminders.
struct Reminders
{
    private size_t sincePlanChange, thisTurn, sinceMemorySave;
    private bool suggestedPlan, suggestedMemory;
    private size_t repeatCount;
    private string repeatKey_; /// null when there is no streak
    private string repeatCmd; /// the raw bash command of the last counted call
    private size_t repeatWarnings;
    /// Whether `report_outcome` is offered, so the warning only names it then.
    bool outcomeTool;

    this(bool outcomeTool) { this.outcomeTool = outcomeTool; }

    void startTurn()
    {
        thisTurn = 0;
        resetRepeat();
        repeatWarnings = 0;
    }

    void planChanged() { sincePlanChange = 0; }

    void memorySaved()
    {
        sinceMemorySave = 0;
        suggestedMemory = true;
    }

    /// Break the current streak without counting a call (plan/outcome calls).
    void resetRepeat()
    {
        repeatCount = 0;
        repeatKey_ = null;
        repeatCmd = null;
    }

    /// Count a (non-plan) tool call and return any reminders for its result.
    string[] afterToolCall(const ref Plan plan, bool memoryWritable)
    {
        ++sincePlanChange;
        ++thisTurn;
        ++sinceMemorySave;
        string[] notes;
        if (memoryWritable && !suggestedMemory && sinceMemorySave >= suggestMemoryAfter)
        {
            suggestedMemory = true;
            notes ~= format("%s tool calls without a memory save. If this work taught you something durable that a future "
                    ~ "session would have to rediscover (a correction from the user, a preference, a decision, costly "
                    ~ "setup), save it with memory_save. If not, carry on.", sinceMemorySave);
        }
        if (plan.empty)
        {
            if (!suggestedPlan && thisTurn >= suggestPlanAfter)
            {
                suggestedPlan = true;
                notes ~= format("This task has taken %s tool calls so far. If several steps remain, record them with plan_add: "
                        ~ "the plan survives when older messages are summarized away.", thisTurn);
            }
        }
        else if (sincePlanChange % planStaleAfter == 0)
        {
            string focus;
            ptrdiff_t active = -1, next = -1;
            foreach (n, ref i; plan.items)
            {
                if (active < 0 && i.status == Status.inProgress) active = n;
                if (next < 0 && i.status == Status.pending) next = n;
            }
            if (active >= 0) focus = format(`#%s "%s" is still in progress`, plan.items[active].id, plan.items[active].title);
            else if (next >= 0) focus = format(`no item is in progress; next is #%s "%s"`, plan.items[next].id, plan.items[next].title);
            if (focus.length)
                notes ~= format("Your plan has not changed in %s tool calls and %s. Use plan_update to mark finished "
                        ~ "items done and to note findings you will need later.", sincePlanChange, focus);
        }
        return notes;
    }

    /// Loop detector: record one call and its result. `rawArgs` (non-null for
    /// a call whose argument JSON never decoded) replaces the decoded `args`
    /// in the fingerprint; `attachments` are image content hashes.
    RepeatVerdict afterRepeatCall(string tool, JSONValue args, string rawArgs, bool ok, string result,
            const string[] attachments = null)
    {
        if (repeatExemptTools.canFind(tool))
        {
            resetRepeat();
            return RepeatVerdict.init;
        }
        auto key = fingerprint(tool, args, rawArgs, ok, result, attachments);
        string cmd;
        if (tool == "bash" && args.type == JSONType.object)
            if (auto c = "command" in args.objectNoRef)
                if (c.type == JSONType.string) cmd = c.str;
        bool sameCmd = (repeatCmd is null && cmd is null)
            || (repeatCmd !is null && cmd !is null && isDiagnosticExtension(repeatCmd, cmd));
        bool isRepeat = repeatKey_ !is null && repeatKey_ == key && sameCmd;
        repeatCount = isRepeat ? repeatCount + 1 : 1;
        repeatKey_ = key;
        repeatCmd = cmd;
        if (repeatCount < repeatWarnAfter) return RepeatVerdict.init;
        auto outcome = ok ? "the same result" : "the same error";
        if (repeatWarnings < repeatMaxWarnings)
        {
            ++repeatWarnings;
            auto escape = outcomeTool ? `, or call report_outcome with status "blocked" and say what you tried` : "";
            return RepeatVerdict(RepeatVerdict.Kind.warning, format("You have now made this same `%s` call %s times in a row "
                    ~ "with %s. Repeating it will not change anything. Change approach: try something different%s.",
                    tool, repeatCount, outcome, escape));
        }
        if (repeatCount >= repeatHardStopAfter)
            return RepeatVerdict(RepeatVerdict.Kind.hardStop, format("the model repeated the same `%s` call %s times in a row "
                    ~ "with %s, and kept repeating it after %s warnings already issued this turn to change approach",
                    tool, repeatCount, outcome, repeatMaxWarnings));
        return RepeatVerdict.init;
    }
}

/// Fingerprint one call: tool, normalised arguments, error flag, result hash.
private string fingerprint(string tool, JSONValue args, string rawArgs, bool ok, string result,
        const string[] attachments)
{
    import std.digest.sha : SHA256, toHexString;
    auto a = rawArgs !is null ? rawArgs : normalisedArgs(tool, args);
    SHA256 h;
    h.start();
    h.put(cast(const(ubyte)[]) normaliseSpillPaths(result));
    foreach (sha; attachments)
    {
        h.put(cast(const(ubyte)[]) "\x00img:");
        h.put(cast(const(ubyte)[]) sha);
    }
    auto digest = h.finish();
    return format("%s|%s|err=%s|out=%s", tool, a, ok, toHexString(digest[0 .. 8]).idup);
}

/// Collapse the per-call path in D's truncation marker
/// (`[... N characters omitted (sha256:D); full output saved to PATH ...]`),
/// so two identical large outputs still match. Only the path of a file this
/// session spilled is rewritten; the digest, count, head and tail stay in the
/// hash.
private string normaliseSpillPaths(string result)
{
    import std.regex : regex, replaceAll, Captures;
    import nano.tools : isSpill;
    static re = regex(`(characters omitted \(sha256:[0-9a-f]{16}\); full output saved to )([^\n]*?) \.\.\.\]`);
    // Only a marker for a file this session spilled is rewritten; its digest
    // stays, so different outputs with the same head and tail stay apart.
    return replaceAll!((Captures!string m) => isSpill(m[2]) ? m[1] ~ "<spill> ...]" : m.hit)(result, re);
}

/// Read-only filters a retry loop commonly appends to the same base command.
immutable string[] diagnosticStages = ["wc", "head", "tail", "cat", "tac", "sort", "uniq", "nl", "cut", "tr", "rev",
    "fold", "column", "less", "more", "grep", "egrep", "fgrep"];

/// The argument text a repeat match is based on: for bash, the command with
/// its trailing read-only diagnostic stages stripped plus the other arguments.
string normalisedArgs(string tool, JSONValue args)
{
    if (tool == "bash" && args.type == JSONType.object)
        if (auto c = "command" in args.objectNoRef)
            if (c.type == JSONType.string)
            {
                JSONValue[string] rest;
                foreach (k, v; args.objectNoRef) if (k != "command") rest[k] = v;
                return pipelineKey(c.str) ~ "|" ~ JSONValue(rest).toString;
            }
    return args.toString;
}

/// Strip the trailing run of read-only diagnostic stages from a command.
string pipelineKey(string command)
{
    auto stages = splitPipeline(command);
    if (stages is null || stages.length <= 1) return command.strip;
    auto end = stages.length;
    while (end > 1 && isDiagnosticStage(stages[end - 1])) --end;
    if (end == stages.length) return command.strip;
    string[] kept;
    foreach (s; stages[0 .. end]) kept ~= s.strip;
    return kept.join(" | ");
}

/// Whether `b` is `a` with only read-only diagnostic stages appended (or the
/// reverse): shared stages identical, every extra stage diagnostic.
bool isDiagnosticExtension(string a, string b)
{
    auto sa = splitPipeline(a), sb = splitPipeline(b);
    if (sa is null || sb is null) return a.strip == b.strip;
    auto s = sa.length <= sb.length ? sa : sb;
    auto l = sa.length <= sb.length ? sb : sa;
    foreach (i, x; s) if (x.strip != l[i].strip) return false;
    return l[s.length .. $].all!isDiagnosticStage;
}

/// A stage that only reads stdin and writes stdout. Conservative: anything
/// unrecognised or with shell control/redirection/substitution is not.
bool isDiagnosticStage(string stage)
{
    import std.array : split;
    stage = stage.strip;
    if (!stage.length) return false;
    foreach (ch; stage)
        if (ch == '>' || ch == '<' || ch == ';' || ch == '&' || ch == '`' || ch == '\n') return false;
    if (stage.canFind("$(") || stage.canFind("${")) return false;
    // Tokenise shell-style (quotes stripped, escapes honoured); a shape we
    // don't model (unterminated quote, glob/brace/expansion) fails closed.
    string[] words;
    if (!shellWords(stage, words) || !words.length || !diagnosticStages.canFind(words[0])) return false;
    return !stageHasSideEffect(words[0], words[1 .. $]);
}

/// Option grammar of one diagnostic command, enough to tell a writer option
/// from an option's value (`sort -k2o` is `-k` with value `2o`, not `-o`).
private struct OptionSpec
{
    string shortWithArg;     // consume the rest of the cluster or the next word
    string shortNumericArg;  // consume following digits (`less -x4`, `-#1`)
    string shortWriters;     // write a file
    immutable(string)[] longWithArg, longWriters;
    long maxReadPositionals = -1; // more positionals than this write (uniq OUT)
}

private bool optionSpec(string cmd, out OptionSpec spec)
{
    switch (cmd)
    {
        case "sort":
            spec = OptionSpec("kotST", "", "o",
                ["--key", "--field-separator", "--buffer-size", "--temporary-directory", "--parallel",
                 "--batch-size", "--files0-from", "--sort", "--random-source"],
                ["--output", "--compress-program"]);
            return true;
        case "less":
            spec = OptionSpec("bhjkoOpPtT", "xz#", "oO", [], ["--log-file", "--LOG-FILE"]);
            return true;
        case "uniq":
            spec = OptionSpec("fsw", "", "", ["--skip-fields", "--skip-chars", "--check-chars"], [], 1);
            return true;
        default:
            return false;
    }
}

/// Whether a diagnostic command writes a file or runs a helper via an option
/// or an extra positional. Long options match by unambiguous prefix (`--out`).
private bool stageHasSideEffect(string cmd, string[] args)
{
    import std.algorithm.searching : startsWith, findSplit;
    import std.ascii : isDigit;
    OptionSpec spec;
    if (!optionSpec(cmd, spec)) return false;
    size_t positionals, i;
    bool optionsDone;
    while (i < args.length)
    {
        auto a = args[i++];
        if (optionsDone || a == "-" || !a.startsWith("-")) { ++positionals; continue; }
        if (a == "--") { optionsDone = true; continue; }
        if (a.startsWith("--"))
        {
            auto parts = a.findSplit("=");
            auto name = parts[0];
            bool hasValue = parts[1].length > 0;
            foreach (w; spec.longWriters) if (w.startsWith(name)) return true;
            if (!hasValue) foreach (w; spec.longWithArg) if (w.startsWith(name)) { ++i; break; }
            continue;
        }
        auto cluster = a[1 .. $];
        size_t pos;
        while (pos < cluster.length)
        {
            auto c = cluster[pos];
            if (spec.shortWriters.canFind(c)) return true;
            if (spec.shortNumericArg.canFind(c))
            {
                ++pos;
                while (pos < cluster.length && cluster[pos].isDigit) ++pos;
                continue;
            }
            if (spec.shortWithArg.canFind(c))
            {
                if (pos + 1 == cluster.length) ++i;
                break;
            }
            ++pos;
        }
    }
    return spec.maxReadPositionals >= 0 && positionals > spec.maxReadPositionals;
}

/// Shell-style words of a stage: quotes stripped, escapes honoured. False for
/// shapes not modelled (expansions, globs, redirections, unterminated quotes).
private bool shellWords(string stage, out string[] words) nothrow
{
    string cur;
    bool inWord;
    size_t i;
    bool next(out char c) { if (i >= stage.length) return false; c = stage[i++]; return true; }
    char c;
    while (next(c))
    {
        switch (c)
        {
            case ' ', '\t', '\n':
                if (inWord) { words ~= cur; cur = null; inWord = false; }
                break;
            case '\\':
                char n;
                if (!next(n)) return false;
                cur ~= n; inWord = true;
                break;
            case '\'':
                inWord = true;
                for (;;)
                {
                    char q;
                    if (!next(q)) return false;
                    if (q == '\'') break;
                    cur ~= q;
                }
                break;
            case '"':
                inWord = true;
                for (;;)
                {
                    char q;
                    if (!next(q)) return false;
                    if (q == '"') break;
                    if (q == '$' || q == '`') return false;
                    if (q == '\\')
                    {
                        char n;
                        if (!next(n)) return false;
                        if (n != '"' && n != '\\' && n != '$' && n != '`') cur ~= '\\';
                        cur ~= n;
                    }
                    else cur ~= q;
                }
                break;
            case '$', '`', '*', '?', '[', '{', '(', ')', '~', '!', '<', '>', ';', '&', '|':
                return false;
            default:
                cur ~= c; inWord = true;
        }
    }
    if (inWord) words ~= cur;
    return true;
}

/// Split into top-level pipeline stages, quote- and escape-aware. Returns null
/// for shapes not modelled: `||`, `|&`, substitutions, here-docs, newlines and
/// unterminated quotes.
string[] splitPipeline(string command) nothrow
{
    string[] stages;
    size_t start, i;
    bool single, dbl;
    while (i < command.length)
    {
        auto c = command[i];
        if (c == '\\' && !single) { i += 2; continue; }
        if (c == '\'' && !dbl) single = !single;
        else if (c == '"' && !single) dbl = !dbl;
        // Command substitution, here-docs and newlines can hide a `|` or
        // carry further commands: shapes not modelled, so refuse to split.
        else if (c == '`' && !single) return null;
        else if (c == '$' && !single && i + 1 < command.length && command[i + 1] == '(') return null;
        else if (c == '<' && !single && !dbl && i + 1 < command.length && command[i + 1] == '<') return null;
        else if (c == '\n' && !single && !dbl) return null;
        else if (c == '|' && !single && !dbl)
        {
            // `||` is logical OR and `|&` also pipes stderr.
            if (i + 1 < command.length && (command[i + 1] == '|' || command[i + 1] == '&')) return null;
            stages ~= command[start .. i];
            start = i + 1;
        }
        ++i;
    }
    if (single || dbl) return null;
    stages ~= command[start .. $];
    return stages;
}

// ---------------------------------------------------------------------------
// Tests (ported from reminders.rs)
// ---------------------------------------------------------------------------

version (unittest)
{
    private RepeatVerdict call(ref Reminders r, string cmd, bool ok, string result, string extra = "")
    {
        return r.afterRepeatCall("bash", parseJSON(`{"command": ` ~ JSONValue(cmd).toString ~ extra ~ `}`), null, ok, result);
    }

    private RepeatVerdict[] repeats(ref Reminders r, size_t n)
    {
        RepeatVerdict[] v;
        foreach (_; 0 .. n) v ~= call(r, "make test", false, "exit 1");
        return v;
    }
}

// rust: reminders.rs::suggests_saving_a_memory_once_unless_one_was_saved
// rust: reminders.rs::suggests_a_plan_once_per_session
unittest // suggests a plan once per session; memory once unless saved
{
    Plan plan;
    Reminders r;
    string[] notes;
    foreach (_; 0 .. suggestPlanAfter) notes ~= r.afterToolCall(plan, false);
    assert(notes.length == 1 && notes[0].canFind("plan_add"));
    r.startTurn();
    foreach (_; 0 .. suggestPlanAfter * 2) assert(!r.afterToolCall(plan, false).length);

    size_t memoryNotes(ref Reminders m, bool writable)
    {
        size_t n;
        foreach (_; 0 .. suggestMemoryAfter * 2)
            foreach (note; m.afterToolCall(plan, writable)) if (note.canFind("memory_save")) ++n;
        return n;
    }
    Reminders a, b, c;
    assert(memoryNotes(a, true) == 1);
    assert(memoryNotes(b, false) == 0);
    c.memorySaved();
    assert(memoryNotes(c, true) == 0);
}

// rust: reminders.rs::nudges_a_stale_plan_until_it_changes
unittest // nudges a stale plan until it changes
{
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["read", "fix"]}`));
    plan.apply("plan_update", parseJSON(`{"id": 1, "status": "in_progress"}`));
    Reminders r;
    size_t[] fired;
    foreach (i; 1 .. planStaleAfter * 2 + 1) if (r.afterToolCall(plan, false).length) fired ~= i;
    assert(fired == [planStaleAfter, planStaleAfter * 2], fired.to!string);
    r.planChanged();
    plan.apply("plan_update", parseJSON(`{"id": 1, "status": "done"}`));
    string note;
    foreach (_; 0 .. planStaleAfter) foreach (n; r.afterToolCall(plan, false)) note = n;
    assert(note.canFind(`next is #2 "fix"`), note);
    plan.apply("plan_update", parseJSON(`{"id": 2, "status": "done"}`));
    foreach (_; 0 .. planStaleAfter * 2) assert(!r.afterToolCall(plan, false).length);
}

// rust: reminders.rs::caps_the_warning_then_hard_stops
// rust: reminders.rs::warns_on_the_third_identical_call_not_before
unittest // warns on the third identical call, caps warnings, then hard-stops
{
    Reminders r;
    auto v = repeats(r, repeatWarnAfter * 2);
    foreach (x; v[0 .. repeatWarnAfter - 1]) assert(x.none);
    assert(v[repeatWarnAfter - 1].warning);

    Reminders s;
    v = repeats(s, repeatWarnAfter + repeatMaxWarnings + 2);
    size_t warnings;
    foreach (x; v) if (x.warning) ++warnings;
    assert(warnings == repeatMaxWarnings);
    assert(v[$ - 1].hardStop && repeats(s, 1)[0].hardStop);
}

// rust: reminders.rs::repeat_warning_only_names_report_outcome_when_it_is_offered
unittest // the warning names report_outcome only when it is offered
{
    auto on = Reminders(true), off = Reminders(false);
    auto a = repeats(on, repeatWarnAfter)[$ - 1].text, b = repeats(off, repeatWarnAfter)[$ - 1].text;
    assert(a.canFind("report_outcome") && a.canFind("try something different"));
    assert(!b.canFind("report_outcome") && b.canFind("try something different"));
}

// rust: reminders.rs::a_one_time_hint_on_the_first_failure_keeps_it_out_of_the_identical_streak
unittest // a hint on the first failure keeps it out of the identical streak
{
    Reminders r;
    RepeatVerdict[] v = [call(r, "make test", false, "exit 1\n\nhint")];
    foreach (_; 0 .. repeatWarnAfter) v ~= call(r, "make test", false, "exit 1");
    foreach (x; v[0 .. repeatWarnAfter]) assert(x.none);
    assert(v[repeatWarnAfter].warning);
}

// rust: reminders.rs::different_arguments_or_results_do_not_repeat
unittest // different arguments or results do not repeat
{
    Reminders r, s;
    foreach (i; 0 .. repeatWarnAfter * 2)
    {
        assert(call(r, format("make test %s", i), false, "x").none);
        assert(call(s, "make test", false, format("exit %s", i)).none);
    }
}

// rust: reminders.rs::a_fresh_streak_does_not_hard_stop_before_its_own_warnings
unittest // a fresh streak does not hard-stop before its own warnings
{
    Reminders r;
    RepeatVerdict last;
    foreach (_; 0 .. repeatWarnAfter) last = call(r, "cmd a", false, "exit 1");
    assert(last.warning);
    foreach (_; 0 .. repeatWarnAfter) last = call(r, "cmd b", false, "exit 1");
    assert(last.warning);
    foreach (_; 0 .. repeatHardStopAfter - 1) assert(call(r, "cmd c", false, "exit 1").none);
    assert(call(r, "cmd c", false, "exit 1").hardStop);
}

// rust: reminders.rs::a_bash_loop_that_appends_pipeline_stages_still_counts
// rust: reminders.rs::changing_a_diagnostic_stages_query_is_not_a_repeat
// rust: reminders.rs::an_appended_diagnostic_suffix_loop_is_detected
unittest // appended diagnostic stages still count; changed queries do not
{
    Reminders r;
    RepeatVerdict last;
    foreach (i; 1 .. repeatWarnAfter + 1)
    {
        string suffix;
        foreach (_; 1 .. i) suffix ~= " | wc -l";
        last = call(r, "gh pr diff 1" ~ suffix, true, "1");
    }
    assert(last.warning);
    Reminders s;
    foreach (q; ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta"])
        assert(call(s, "cat log | grep " ~ q, true, "").none, q);
}

// rust: reminders.rs::changing_execution_arguments_is_not_a_repeat
unittest // changing execution arguments is not a repeat; the same ones are
{
    Reminders r, s, t;
    foreach (n; [10, 20, 40, 80, 160, 320, 640])
    {
        assert(call(r, "make test", true, "ok", format(`, "timeout_seconds": %s`, n)).none);
        assert(call(s, "make test", true, "ok", format(`, "max_output_length": %s`, n * 100)).none);
    }
    RepeatVerdict last;
    foreach (_; 0 .. repeatWarnAfter) last = call(t, "make test", true, "ok", `, "timeout_seconds": 30`);
    assert(last.warning);
}

// rust: reminders.rs::disabled_plan_tool_repeats_are_still_detected
// rust: reminders.rs::reset_repeat_breaks_a_building_streak
// rust: reminders.rs::changing_image_attachment_does_not_repeat
// rust: reminders.rs::an_interleaved_exempt_call_breaks_the_streak
// rust: reminders.rs::exempt_tools_and_start_turn_reset_the_detector
// rust: reminders.rs::distinct_malformed_payloads_sharing_a_prefix_are_not_a_repeat
unittest // distinct malformed payloads, exempt tools, reset, images
{
    Reminders r;
    auto empty = parseJSON(`{}`);
    auto prefix = format("%-400s", "x");
    foreach (i; 0 .. 7)
        assert(r.afterRepeatCall("edit_file", empty, prefix ~ i.to!string, false, "bad args").none);
    Reminders q;
    foreach (_; 0 .. 10) assert(q.afterRepeatCall("question", empty, null, true, "yes").none);
    // An interleaved exempt call breaks a streak.
    Reminders s;
    foreach (_; 0 .. 5)
    {
        assert(call(s, "make", true, "same").none);
        s.afterRepeatCall("question", empty, null, true, "ok");
    }
    Reminders t;
    call(t, "make", true, "same");
    call(t, "make", true, "same");
    t.resetRepeat();
    assert(call(t, "make", true, "same").none);
    t.startTurn();
    // A changing image with identical metadata text is not a repeat.
    Reminders u;
    foreach (i; 0 .. 7)
        assert(u.afterRepeatCall("read_file", parseJSON(`{"path": "a.png"}`), null, true, "image a.png",
                [format("sha%s", i)]).none);
    // Disabled plan tools (not found errors) are still detected.
    Reminders w;
    RepeatVerdict last;
    foreach (_; 0 .. repeatWarnAfter) last = w.afterRepeatCall("plan_add", empty, null, false, "Tool 'plan_add' not found");
    assert(last.warning);
}

// rust: reminders.rs::identical_large_output_with_per_call_spill_paths_still_counts
// rust: reminders.rs::spill_normalisation_only_touches_the_marker_not_arbitrary_output
// rust: reminders.rs::spill_normalisation_handles_paths_with_spaces
// rust: reminders.rs::spill_path_normalisation_collapses_per_call_names
unittest // identical large output with per-call spill paths still counts
{
    import std.file : remove;
    import nano.tools : truncateOutput, contentDigest;
    string[] made;
    scope (exit) foreach (f; made) remove(f);
    string big(string middle)
    {
        import std.regex : matchFirst;
        auto t = truncateOutput("head " ~ middle ~ " tail", 10, "bash-stdout");
        made ~= t.matchFirst(`saved to (.*\.txt) \.\.\.\]`)[1];
        return t;
    }
    Reminders r;
    RepeatVerdict last;
    foreach (i; 0 .. repeatWarnAfter) last = call(r, "cat big", true, big("the same long middle"));
    assert(last.warning, "identical spilled output repeats despite per-call paths");
    // ...but a lookalike in ordinary output is left alone.
    assert(normaliseSpillPaths("saved to a.txt") == "saved to a.txt");

    // rust: reminders.rs::a_known_spill_marker_is_normalised_without_its_digest
    auto a = big("x"), b = big("x");
    assert(a != b && normaliseSpillPaths(a) == normaliseSpillPaths(b) && normaliseSpillPaths(a).canFind("<spill>"));

    // rust: reminders.rs::an_embedded_marker_cannot_hide_the_outer_spill_digest
    // Same head and tail, different middles: the digest keeps them apart.
    Reminders r2;
    RepeatVerdict v;
    foreach (i; 0 .. repeatWarnAfter + 1)
    {
        v = call(r2, "cat big", true, big(format("middle number %s of many", i)));
        assert(v.none, "different outputs conflated");
    }

    // rust: reminders.rs::a_known_spill_rewrite_leaves_an_untracked_lookalike_marker_intact
    auto lookalike = format("[... 3 characters omitted (sha256:%s); full output saved to /tmp/nano-coder-9/tool-aaa-1-2.txt ...]",
        contentDigest("x"));
    assert(normaliseSpillPaths(a ~ "\nStderr:\nnote " ~ lookalike).canFind("tool-aaa-1-2.txt"),
        "a marker for a file this session didn't write is kept verbatim");
}

// rust: reminders.rs::less_logfile_option_is_not_diagnostic
// rust: reminders.rs::pipeline_key_only_collapses_read_only_diagnostic_stages
// rust: reminders.rs::pipeline_key_keeps_stages_that_write_through_options_or_shell_control
// rust: reminders.rs::a_quoted_pipe_is_not_a_pipeline_boundary
unittest // pipeline parsing
{
    assert(splitPipeline(`echo "a|b" | wc -l`).length == 2);
    assert(splitPipeline(`echo a\|b`).length == 1);
    assert(splitPipeline("a || b") is null);
    assert(pipelineKey("make | sed s/a/b/ | grep a | wc -l") == "make | sed s/a/b/");
    assert(pipelineKey("make | tee a") == "make | tee a");
    assert(pipelineKey("make | sort -o /tmp/a") == "make | sort -o /tmp/a");
    assert(pipelineKey("make | sort -ro/tmp/a") == "make | sort -ro/tmp/a");
    assert(pipelineKey("make | sort --compress-program=x") == "make | sort --compress-program=x");
    assert(pipelineKey("make | uniq in out") == "make | uniq in out");
    assert(pipelineKey("make | uniq - out") == "make | uniq - out");
    assert(pipelineKey("make | less -No/tmp/a") == "make | less -No/tmp/a");
    assert(pipelineKey("make | less --log-file=x") == "make | less --log-file=x");
    assert(pipelineKey("make | grep a > f") == "make | grep a > f");
    assert(pipelineKey("make | grep $(id)") == "make | grep $(id)");
    assert(pipelineKey("make | uniq | sort") == "make");
    assert(isDiagnosticExtension("make", "make | wc -l | head"));
    assert(!isDiagnosticExtension("make | grep a", "make | grep b"));
    assert(!isDiagnosticExtension("make", "make | tee x"));
}

// rust: reminders.rs::distinct_side_effecting_pipelines_do_not_hard_stop
unittest // distinct side-effecting pipelines do not hard-stop
{
    Reminders r;
    foreach (i; 0 .. 8) assert(call(r, format("make | tee /tmp/out%s", i), true, "ok").none);
}

// rust: reminders.rs::option_values_are_not_misread_as_writer_flags
unittest
{
    assert(pipelineKey("cat f | sort -k2o") == "cat f");
    assert(pipelineKey("cat f | sort -t o") == "cat f");
    assert(pipelineKey("cat f | sort -k 2 -o /tmp/a") == "cat f | sort -k 2 -o /tmp/a");
    assert(pipelineKey("cat f | sort -rk2 -o/tmp/a") != pipelineKey("cat f | sort -rk2 -o/tmp/b"));
    assert(pipelineKey("cat f | sort --out=/tmp/a") == "cat f | sort --out=/tmp/a");
    assert(pipelineKey("cat f | less --log=/tmp/a") == "cat f | less --log=/tmp/a");
    assert(pipelineKey("cat f | uniq -f 2") == "cat f");
    assert(pipelineKey("cat f | uniq -f 2 - /tmp/out") == "cat f | uniq -f 2 - /tmp/out");
    assert(pipelineKey("cat f | uniq -- -in -out") == "cat f | uniq -- -in -out");
    assert(pipelineKey("cat f | uniq --group - /tmp/out") == "cat f | uniq --group - /tmp/out");
    assert(pipelineKey("cat f | uniq --all-repeated - /tmp/out") == "cat f | uniq --all-repeated - /tmp/out");
    assert(pipelineKey("cat f | uniq --group=prepend") == "cat f");
    assert(pipelineKey("cat f | uniq --all-repeated=separate") == "cat f");
    foreach (sep; ["\v", "\r", "\f"])
        assert(pipelineKey("cat f | sort -t" ~ sep ~ " -o /tmp/out") == "cat f | sort -t" ~ sep ~ " -o /tmp/out");
    assert(pipelineKey("cat f | sort '-o' /tmp/a") == "cat f | sort '-o' /tmp/a");
    assert(pipelineKey("cat f | 'tee' /tmp/a") == "cat f | 'tee' /tmp/a");
}

// rust: reminders.rs::less_numeric_option_prefix_does_not_hide_a_writer_flag
unittest
{
    foreach (o; ["-x4o", "-x4O", "-z4o", "-#1o", "-x4No"])
        assert(pipelineKey("printf x | less " ~ o ~ "/tmp/a") != pipelineKey("printf x | less " ~ o ~ "/tmp/b"), o);
    foreach (o; ["-x4", "-x 4", "-#1", "-x4N", "-pfoo", "-p foo"])
        assert(pipelineKey("printf x | less " ~ o) == "printf x", o);
}

// rust: reminders.rs::unmodelled_shell_shapes_fail_closed
unittest
{
    foreach (c; ["echo $(cat a | wc -l)", "echo `cat a | wc -l`", "make |& tee log", "cat <<EOF | wc\nx\nEOF",
                 "cmd | grep 'x", "cmd | sort $OPT", "cmd | sort -*"])
        assert(pipelineKey(c) == c, c);
    foreach (w; ["tee -a /tmp/a", "cp a b", "mv a b", "rsync a b", "xargs rm"])
        assert(pipelineKey("cmd | " ~ w) == "cmd | " ~ w);
    assert(pipelineKey("cmd | grep 'a b' | head -n 3") == "cmd");
}
