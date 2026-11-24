/// A task plan the agent keeps outside the conversation, so long-range work
/// survives compaction and resume (port of `plan.rs`). The agent edits it
/// with the `plan_*` tools; the harness records every change in the session
/// log and restates the plan after compaction.
module nano.plan;

import std.algorithm : canFind, map, filter, any, maxElement, count;
import std.array : array, join, replace;
import std.conv : to;
import std.format : format;
import std.json;
import std.string : strip, toLower, startsWith, stripLeft;
import std.uni : toUpper;

import nano.llm : ToolDefinition;
import nano.option : Option, match;
import nano.result : Result, unwrap, unwrapErr, match;

@safe:
pure:
import nano.safeio : jsonText, jsonPretty;

enum maxItems = 200;
enum maxTitleChars = 200;
enum maxNoteChars = 1_000;
enum maxGoalChars = 2_000;
/// Largest item id accepted from a client-supplied plan.
enum uint maxId = 1_000_000;
/// Budget for the plan restated after compaction.
enum contextChars = 8_000;
/// Most bytes of notes kept per item; older notes are dropped beyond it.
enum maxNotesBytes = 4_096;
/// Stands for the notes dropped to keep an item under `maxNotesBytes`.
enum droppedNotesMarker = "(older notes dropped)";

immutable string[] toolNames = ["plan_add", "plan_update", "plan_show"];

bool isPlanTool(string name) pure { return toolNames.canFind(name); }

/// A plan result: the error is the message for the model (Rust `bail!`).
alias PlanResult(T) = Result!(T, string);

enum Status { pending, inProgress, done, blocked, dropped }

string statusName(Status s) pure nothrow
{
    final switch (s)
    {
        case Status.pending: return "pending";
        case Status.inProgress: return "in_progress";
        case Status.done: return "done";
        case Status.blocked: return "blocked";
        case Status.dropped: return "dropped";
    }
}

PlanResult!Status parseStatus(string text) pure
{
    alias R = PlanResult!Status;
    auto t = text.strip.toLower.replace("-", "_").replace(" ", "_");
    switch (t)
    {
        case "pending", "todo": return R.ok(Status.pending);
        case "in_progress", "active", "doing", "started": return R.ok(Status.inProgress);
        case "done", "completed", "complete": return R.ok(Status.done);
        case "blocked": return R.ok(Status.blocked);
        case "dropped", "cancelled", "canceled", "skipped": return R.ok(Status.dropped);
        default:
            return R.err(format!"unknown status %s; use pending, in_progress, done, blocked or dropped"(
                    JSONValue(t).jsonText));
    }
}

private string mark(Status s) pure nothrow
{
    final switch (s)
    {
        case Status.pending: return "[ ]";
        case Status.inProgress: return "[>]";
        case Status.done: return "[x]";
        case Status.blocked: return "[!]";
        case Status.dropped: return "[-]";
    }
}

private bool closed(Status s) pure nothrow { return s == Status.done || s == Status.dropped; }

/// A rendered plan (`Plan.render`, or a plan tool's result) for the
/// terminal: each item's ASCII mark becomes a symbol, matching the ☐/☑ of
/// rendered markdown task lists. The model keeps seeing the ASCII form;
/// only item lines change (notes and other text are left alone).
string planSymbols(string text) pure
{
    import std.array : split;
    static immutable string[2][5] marks = [["[ ] ", "☐ "], ["[>] ", "◐ "], ["[x] ", "☑ "], ["[!] ", "⊘ "], ["[-] ", "☒ "]];
    auto lines = text.split("\n");
    foreach (ref l; lines)
        foreach (m; marks)
            if (l.startsWith(m[0]) && isItemId(l[4 .. $]))
            {
                l = m[1] ~ l[4 .. $];
                break;
            }
    return lines.join("\n");
}

/// `s` starts with an item id: one or more digits followed by `. `.
private bool isItemId(string s) pure nothrow @nogc
{
    import std.ascii : isDigit;
    size_t i;
    while (i < s.length && s[i].isDigit) i++;
    return i > 0 && i + 1 < s.length && s[i] == '.' && s[i + 1] == ' ';
}

unittest
{
    // Goal/title continuation lines that merely look like items stay as typed.
    assert(planSymbols("[x] 2026 release") == "[x] 2026 release");
    assert(planSymbols("[ ] 3.5 kg") == "[ ] 3.5 kg");
    assert(planSymbols("[ ] 12") == "[ ] 12");
    assert(planSymbols("[>] 12. x") == "◐ 12. x");
}

unittest
{
    auto text = "Plan (1/5 done):\n[ ] 1. a\n[>] 2. b\n[x] 3. c\n      - [x] note text\n[!] 4. d\n[-] 5. e\n[x] not an item";
    assert(planSymbols(text) == "Plan (1/5 done):\n☐ 1. a\n◐ 2. b\n☑ 3. c\n      - [x] note text\n⊘ 4. d\n☒ 5. e\n[x] not an item",
        planSymbols(text));
}

struct PlanItem
{
    uint id;
    string title;
    Status status;
    string[] notes; /// findings and decisions, oldest first
    uint[] after; /// items that must be done (or dropped) first

    PlanItem dup() pure const { return PlanItem(id, title, status, notes.dup, after.dup); }

    /// Serialized like an entry of `Plan.toJSON`'s `items` list.
    JSONValue toJSON() pure const
    {
        auto o = JSONValue(["id": JSONValue(id), "title": JSONValue(title), "status": JSONValue(statusName(status))]);
        if (notes.length) o["notes"] = JSONValue(notes.dup);
        if (after.length) o["after"] = JSONValue(after.map!(a => JSONValue(a)).array);
        return o;
    }
}

/// What a plan tool call did.
struct Outcome
{
    string text;
    bool changed;
    /// `plan_add` found the plan finished and started a new one: the
    /// caller archives the old plan and records the new one as a snapshot.
    bool restarted;
}

struct Plan
{
    string goal;
    PlanItem[] items;

    Plan dup() pure const
    {
        Plan p;
        p.goal = goal;
        foreach (ref i; items) p.items ~= i.dup;
        return p;
    }

    bool opEquals(const Plan o) pure const
    {
        if (goal != o.goal || items.length != o.items.length) return false;
        foreach (k, ref i; items)
        {
            auto j = &o.items[k];
            if (i.id != j.id || i.title != j.title || i.status != j.status || i.notes != j.notes || i.after != j.after)
                return false;
        }
        return true;
    }

    bool empty() pure const { return !goal.length && !items.length; }

    /// Every item is done or dropped (and there is at least one).
    bool finished() pure const { return items.length && !items.any!(i => !i.status.closed); }

    /// (done, total), not counting dropped items.
    size_t[2] progress() pure const
    {
        size_t done, total;
        foreach (ref i; items)
        {
            if (i.status == Status.dropped) continue;
            ++total;
            if (i.status == Status.done) ++done;
        }
        return [done, total];
    }

    private PlanResult!size_t item(uint id) pure const
    {
        alias R = PlanResult!size_t;
        foreach (k, ref i; items) if (i.id == id) return R.ok(k);
        if (!items.length) return R.err(format!"no item %s: the plan is empty; add items with plan_add"(id));
        return R.err(format!"no item %s; items are %s"(id, items.map!(i => i.id.to!string).join(", ")));
    }

    private bool isReady(const ref PlanItem it) pure const
    {
        if (it.status != Status.pending) return false;
        foreach (dep; it.after)
            foreach (ref o; items)
                if (o.id == dep && !o.status.closed) return false;
        return true;
    }

    /// Items to work on next: those in progress, else the first ready one.
    private const(PlanItem)[] next() pure const
    {
        const(PlanItem)[] active;
        foreach (ref i; items) if (i.status == Status.inProgress) active ~= i;
        if (active.length) return active;
        foreach (ref i; items) if (isReady(i)) return [i];
        return null;
    }

    /// Run a plan tool. On an error the plan is left unchanged.
    PlanResult!Outcome apply(string tool, const JSONValue args) pure
    {
        switch (tool)
        {
            case "plan_add": return add(args);
            case "plan_update": return update(args);
            case "plan_show": return PlanResult!Outcome.ok(Outcome(render(true, size_t.max), false));
            default: return PlanResult!Outcome.err("unknown plan tool " ~ tool);
        }
    }

    private PlanResult!Outcome add(JSONValue args) pure
    {
        alias R = PlanResult!Outcome;
        // A finished plan is history: new work starts a fresh plan (issue #346).
        bool restart = finished;
        auto plan = restart ? Plan.init : dup();
        string[] summary;
        if (auto g = field(args, "goal"))
            if (g.type == JSONType.string && g.str.strip.length)
            {
                plan.goal = clip(g.str.strip, maxGoalChars);
                summary ~= "set the goal";
            }
        JSONValue[] list;
        if (auto v = field(args, "items"))
        {
            auto dr = decoded(*v);
            if (dr.isErr) return R.err(dr.unwrapErr("isErr"));
            auto d = dr.unwrap("isOk");
            if (d.type == JSONType.array) list = d.arrayNoRef;
            else if (d.type != JSONType.null_) list = [d];
        }
        if (!list.length && !summary.length)
            return R.err("plan_add needs `items` (a list of step titles or {title, after} objects) or a `goal`");
        // Only real work restarts a finished plan; the notice is not work.
        if (restart) summary = format!"started a new plan (the previous one, %s items, is finished)"(items.length) ~ summary;
        uint firstId = (plan.items.length ? plan.items.map!(i => i.id).maxElement : 0) + 1;
        if (list.length > maxItems || plan.items.length + list.length > maxItems)
            return R.err(format!"a plan holds at most %s items; drop or merge some first"(maxItems));
        uint[] added;
        foreach (offset, it; list)
        {
            uint id = firstId + offset.to!uint;
            string title, note;
            uint[] after;
            if (it.type == JSONType.string) title = it.str;
            else if (it.type == JSONType.object)
            {
                if (auto t = field(it, "title")) if (t.type == JSONType.string) title = t.str;
                if (auto a = field(it, "after"))
                {
                    auto ids = idsOf(*a);
                    if (ids.isErr) return R.err(ids.unwrapErr("isErr"));
                    after = ids.unwrap("isOk");
                }
                if (auto n = field(it, "note")) if (n.type == JSONType.string) note = n.str;
            }
            else return R.err("each item must be a title string or an object with a `title`");
            title = title.strip;
            if (!title.length) return R.err(format!"item %s has an empty title"(offset + 1));
            foreach (dep; after)
                if (dep >= id || !plan.items.any!(i => i.id == dep))
                    return R.err(format!"item %s: `after` must name earlier items, not %s"(
                            JSONValue(title).jsonText, dep));
            PlanItem p = {id: id, title: clip(title, maxTitleChars), status: Status.pending, after: after};
            if (note.strip.length) p.notes = [clip(note.strip, maxNoteChars)];
            plan.items ~= p;
            added ~= id;
        }
        if (added.length == 1) summary ~= format!"added item %s"(added[0]);
        else if (added.length > 1) summary ~= format!"added items %s-%s"(added[0], added[$ - 1]);
        this = plan;
        auto o = outcome(summary.join(", "));
        o.restarted = restart;
        return R.ok(o);
    }

    private PlanResult!Outcome update(JSONValue args) pure
    {
        alias R = PlanResult!Outcome;
        JSONValue[] updates;
        auto u = field(args, "updates");
        if (u is null) updates = [args];
        else
        {
            auto dr = decoded(*u);
            if (dr.isErr) return R.err(dr.unwrapErr("isErr"));
            auto d = dr.unwrap("isOk");
            if (d.type == JSONType.array) updates = d.arrayNoRef;
            else if (d.type == JSONType.null_) updates = [args];
            else updates = [d];
        }
        auto plan = dup();
        string[] summary;
        foreach (up; updates)
        {
            auto idv = field(up, "id");
            uint id;
            if (idv is null || !idOf(*idv, id)) return R.err("plan_update needs the item `id`");
            auto at = plan.item(id);
            if (at.isErr) return R.err(at.unwrapErr("isErr"));
            auto it = &plan.items[at.unwrap("isOk")];
            string[] did;
            if (auto s = field(up, "status"))
                if (s.type == JSONType.string)
                {
                    auto st = parseStatus(s.str);
                    if (st.isErr) return R.err(st.unwrapErr("isErr"));
                    it.status = st.unwrap("isOk");
                    did ~= statusName(it.status);
                }
            if (auto t = field(up, "title"))
                if (t.type == JSONType.string && t.str.strip.length)
                {
                    it.title = clip(t.str.strip, maxTitleChars);
                    did ~= "renamed";
                }
            if (auto n = field(up, "note"))
                if (n.type == JSONType.string && n.str.strip.length)
                {
                    it.notes = capNotes(it.notes ~ clip(n.str.strip, maxNoteChars));
                    did ~= "noted";
                }
            if (!did.length) return R.err(format!"item %s: give a `status`, `note` or `title` to change"(id));
            summary ~= format!"%s %s"(id, did.join(" + "));
        }
        this = plan;
        return R.ok(outcome("updated " ~ summary.join(", ")));
    }

    private Outcome outcome(string summary) pure const
    {
        return Outcome(capitalize(summary) ~ ".\n" ~ render(false, size_t.max), true);
    }

    /// The plan as a checklist. `notes` includes each item's notes; output
    /// over `budget` characters drops the notes of finished items, then all notes.
    string render(bool notes, size_t budget, bool closedNotes = true) pure const
    {
        if (empty) return "The plan is empty.";
        bool[2][] modes = !notes ? [[false, false]]
            : closedNotes ? [[true, true], [true, false], [false, false]] : [[true, false], [false, false]];
        string text;
        foreach (m; modes)
        {
            text = renderWith(m[0], m[1]);
            if (text.length <= budget) break;
        }
        return text;
    }

    private string renderWith(bool openNotes, bool closedNotes) pure const
    {
        string out_;
        if (goal.length) out_ ~= "Goal: " ~ goal.replace("\n", "\n      ") ~ "\n";
        auto pr = progress();
        out_ ~= format!"Plan (%s/%s done):\n"(pr[0], pr[1]);
        foreach (ref it; items)
        {
            auto after = it.after.length ? " (after " ~ it.after.map!(a => a.to!string).join(", ") ~ ")" : "";
            out_ ~= format!"%s %s. %s%s\n"(it.status.mark, it.id, it.title.replace("\n", "\n      "), after);
            auto show = it.status.closed ? closedNotes : openNotes;
            if (show)
                foreach (n; it.notes) out_ ~= "      - " ~ n.replace("\n", "\n        ") ~ "\n";
            else if (it.notes.length)
                out_ ~= format!"      (%s note%s)\n"(it.notes.length, it.notes.length == 1 ? "" : "s");
        }
        auto nx = next();
        if (!nx.length)
            out_ ~= pr[1] > 0 && pr[0] == pr[1] ? "All items are done.\n"
                : "Nothing is ready: unblock or re-plan the remaining items.\n";
        else
        {
            auto label = nx[0].status == Status.inProgress ? "In progress" : "Next";
            out_ ~= label ~ ": " ~ nx.map!(i => format!"%s. %s"(i.id, i.title.replace("\n", "\n      "))).join("; ") ~ "\n";
        }
        return out_;
    }

    /// The plan restated for the model after its context was compacted.
    string contextNote() pure const
    {
        if (finished) return finishedNote;
        return "[Your plan, kept by the harness. Earlier conversation may be summarized, but the plan and its notes are "
            ~ "complete. Continue from it and keep it current with plan_update.]\n" ~ render(true, contextChars, false);
    }

    /// The plan handed to a new session that continues an earlier run.
    string carriedOverNote() pure const
    {
        if (finished) return finishedNote;
        return "[A plan carried over from an earlier, interrupted run of this task, kept by the harness. Work already "
            ~ "marked done may be committed or pushed: check the current state before redoing it. Continue from the "
            ~ "plan and keep it current with plan_update.]\n" ~ render(true, contextChars, false);
    }

    /// One line standing for a finished plan: restating it would only
    /// re-inject stale work into the context.
    private string finishedNote() pure const
    {
        auto g = goal.length ? " '" ~ clip(goal.replace("\n", " "), 200) ~ "'" : "";
        return format!"[Previous plan%s completed (%s items); details in the session log.]"(g, items.length);
    }

    /// ACP `plan` entries (dropped items omitted).
    JSONValue acpEntries() pure const
    {
        JSONValue[] list;
        foreach (ref i; items)
        {
            if (i.status == Status.dropped) continue;
            auto st = i.status == Status.done ? "completed" : i.status == Status.inProgress ? "in_progress" : "pending";
            list ~= JSONValue(["content": JSONValue(i.title), "priority": JSONValue("medium"), "status": JSONValue(st)]);
        }
        return JSONValue(list);
    }

    /// Serialized like Rust's serde form: {goal?, items: [{id, title, status, notes?, after?}]}.
    JSONValue toJSON() pure const
    {
        JSONValue[] list;
        foreach (ref i; items) list ~= i.toJSON;
        auto o = JSONValue(["items": JSONValue(list)]);
        if (goal.length) o["goal"] = JSONValue(goal);
        return o;
    }

    /// Accept a plan from a client or a session log: this harness's own shape
    /// (`{goal, items}`) or bare ACP entries.
    static PlanResult!Plan fromJSON(const JSONValue v) pure
    {
        alias R = PlanResult!Plan;
        enum shape = "plan must be {goal, items: [{id, title, status}]}";
        Plan plan;
        if (v.type == JSONType.object && "items" in v)
        {
            if (auto g = field(v, "goal")) if (g.type == JSONType.string) plan.goal = g.str;
            if (v["items"].type != JSONType.array) return R.err(shape);
            foreach (it; v["items"].arrayNoRef)
            {
                PlanItem p;
                auto idv = field(it, "id");
                auto t = field(it, "title");
                auto s = field(it, "status");
                if (idv is null || idv.type != JSONType.integer && idv.type != JSONType.uinteger || t is null
                        || t.type != JSONType.string || s is null || s.type != JSONType.string)
                    return R.err(shape);
                // Phobos tags any unsigned value `uinteger` (even
                // `JSONValue(1u)`, which `toJSON` produces for ids), so keep
                // the actual value; only one above `long.max` can't be a
                // valid id and takes the out-of-range path.
                auto raw = idv.type == JSONType.integer ? idv.integer
                    : idv.uinteger > ulong(long.max) ? long.max : long(idv.uinteger);
                if (raw <= 0 || raw > maxId) return R.err(format!"plan item id %s is out of range 1-%s"(raw, maxId));
                p.id = raw.to!uint; // in range: checked above
                p.title = t.str;
                auto st = parseStatus(s.str);
                if (st.isErr) return R.err(st.unwrapErr("isErr"));
                p.status = st.unwrap("isOk");
                if (auto n = field(it, "notes"))
                    if (n.type == JSONType.array)
                        foreach (x; n.arrayNoRef)
                        {
                            if (x.type != JSONType.string) return R.err(shape);
                            p.notes ~= x.str == droppedNotesMarker ? x.str : clip(x.str, maxNoteChars);
                        }
                // Logs written before the cap (or edited by hand) obey it too.
                p.notes = capNotes(p.notes);
                if (auto a = field(it, "after"))
                {
                    auto ids = idsOf(*a);
                    if (ids.isErr) return R.err(ids.unwrapErr("isErr"));
                    p.after = ids.unwrap("isOk");
                }
                plan.items ~= p;
            }
            return plan.invalidity.match!(e => R.err(e), () => R.ok(plan));
        }
        JSONValue entries = v;
        if (v.type == JSONType.object && "entries" in v) entries = v["entries"];
        if (entries.type != JSONType.array) return R.err("plan must be {goal, items} or a list of ACP plan entries");
        foreach (index, e; entries.arrayNoRef)
        {
            string title;
            if (auto c = field(e, "content")) { if (c.type == JSONType.string) title = c.str; }
            else if (auto c = field(e, "title")) if (c.type == JSONType.string) title = c.str;
            title = title.strip;
            if (!title.length) continue;
            auto st = Status.pending;
            if (auto s = field(e, "status"))
                if (s.type == JSONType.string)
                {
                    auto parsed = parseStatus(s.str);
                    if (parsed.isErr) return R.err(parsed.unwrapErr("isErr"));
                    st = parsed.unwrap("isOk");
                }
            plan.items ~= PlanItem((index + 1).to!uint, clip(title, maxTitleChars), st);
        }
        return R.ok(plan);
    }

    /// What is wrong with a plan from outside (ids unique and in range,
    /// dependencies known), if anything.
    private Option!string invalidity() pure const
    {
        import nano.option : some;
        if (items.length > maxItems) return some(format!"a plan holds at most %s items"(maxItems));
        bool[uint] seen;
        foreach (ref i; items)
        {
            if (i.id == 0 || i.id > maxId) return some(format!"plan item id %s is out of range 1-%s"(i.id, maxId));
            if (i.id in seen) return some(format!"plan item id %s is used twice"(i.id));
            seen[i.id] = true;
        }
        foreach (ref i; items)
            foreach (d; i.after)
                if (d !in seen) return some(format!"plan item %s is after unknown item %s"(i.id, d));
        return Option!string.init;
    }
}

import nano.safeio : jsonGet;
private alias field = jsonGet;

/// Models sometimes send a nested list as a JSON string; decode it.
private PlanResult!JSONValue decoded(const JSONValue v) pure
{
    alias R = PlanResult!JSONValue;
    if (v.type == JSONType.string)
    {
        auto t = v.str.stripLeft;
        if (t.startsWith("[") || t.startsWith("{"))
        {
            // std.json reports malformed input by throwing; turn it into a value here.
            try return R.ok(parseJSON(v.str));
            catch (Exception e)
                return R.err(format!"could not parse %s as JSON: %s; pass a list, not a string"(
                        JSONValue(v.str).jsonText, e.msg));
        }
    }
    return R.ok(JSONValue(v));
}

private bool idOf(const JSONValue v, out uint id) pure
{
    try
    {
        if (v.type == JSONType.integer && v.integer >= 0 && v.integer <= uint.max) { id = v.integer.to!uint; return true; }
        if (v.type == JSONType.uinteger && v.uinteger <= uint.max) { id = v.uinteger.to!uint; return true; }
        if (v.type == JSONType.string)
        {
            auto s = v.str.strip;
            while (s.startsWith("#")) s = s[1 .. $];
            id = s.to!uint;
            return true;
        }
    }
    catch (Exception) {} // a non-numeric or out-of-range id is not an id
    return false;
}

private PlanResult!(uint[]) idsOf(const JSONValue v) pure
{
    alias R = PlanResult!(uint[]);
    const(JSONValue)[] list;
    if (v.type == JSONType.array) list = v.arrayNoRef;
    else if (v.type != JSONType.null_) list = [v];
    uint[] out_;
    foreach (x; list)
    {
        uint id;
        if (!idOf(x, id)) return R.err("`after` must list item ids, got " ~ x.jsonText);
        out_ ~= id;
    }
    return R.ok(out_);
}

/// `notes` with the oldest dropped so they total at most `maxNotesBytes`
/// (the newest is always kept), led by `droppedNotesMarker` when any were.
private string[] capNotes(string[] notes) pure
{
    import std.algorithm : sum;
    if (notes.map!(n => n.length).sum <= maxNotesBytes) return notes;
    auto rest = notes.length && notes[0] == droppedNotesMarker ? notes[1 .. $] : notes;
    // The newest note always stays (each is at most `maxNoteChars` chars).
    size_t keep = rest.length - 1, total = droppedNotesMarker.length + rest[$ - 1].length;
    while (keep > 0 && total + rest[keep - 1].length <= maxNotesBytes) total += rest[--keep].length;
    return [droppedNotesMarker] ~ rest[keep .. $];
}

private string clip(string text, size_t max) pure
{
    import std.utf : count;
    import std.range : take;
    if (text.count <= max) return text;
    return text.take(max - 1).to!string ~ "…";
}

private string capitalize(string text) pure
{
    if (!text.length) return text;
    import std.utf : decode, stride;
    auto n = text.stride(0);
    return text[0 .. n].toUpper ~ text[n .. $];
}

ToolDefinition[] definitions() pure
{
    return [
        ToolDefinition("plan_add",
            "Add steps to your task plan (and optionally set its overall goal). For work with more than a few steps, "
            ~ "make a plan first. The plan is kept outside the conversation: it survives when older messages are "
            ~ "summarized away, so it is where you track progress on long tasks. Items get numeric ids.",
            parseJSON(`{"type":"object","properties":{"goal":{"type":"string","description":"The overall objective, in one or two sentences"},"items":{"type":"array","description":"Steps in order: title strings, or {title, after, note} objects","items":{"anyOf":[{"type":"string"},{"type":"object","properties":{"title":{"type":"string"},"after":{"type":"array","items":{"type":"integer"},"description":"Ids of items that must be done first"},"note":{"type":"string"}},"required":["title"]}]}}}}`)),
        ToolDefinition("plan_update",
            "Change a plan item: set its status (pending, in_progress, done, blocked, dropped), rename it, or add a "
            ~ "note. Mark an item in_progress when you start it and done when it is finished. Put findings you will "
            ~ "need later (file paths, decisions, commands, PR URLs) in a note: notes are kept even when the "
            ~ "conversation is summarized. Use `updates` to change several items at once.",
            parseJSON(`{"type":"object","properties":{"id":{"type":"integer"},"status":{"type":"string","enum":["pending","in_progress","done","blocked","dropped"]},"note":{"type":"string"},"title":{"type":"string"},"updates":{"type":"array","description":"Several updates, each {id, status?, note?, title?}","items":{"type":"object"}}}}`)),
        ToolDefinition("plan_show", "Show the whole plan with all notes.",
            parseJSON(`{"type":"object","properties":{}}`)),
    ];
}

// rust: plan.rs::adds_updates_and_tracks_what_is_next
unittest // adds_updates_and_tracks_what_is_next
{
    Plan plan;
    auto o = plan.apply("plan_add",
        parseJSON(`{"goal": "Ship it", "items": ["Read code", {"title": "Write fix", "after": [1]}, "Open PR"]}`)).unwrap("valid");
    assert(o.changed);
    assert(o.text.startsWith("Set the goal, added items 1-3.\n"), o.text);
    assert(o.text.canFind("[ ] 2. Write fix (after 1)"));
    assert(o.text.canFind("Next: 1. Read code"));

    o = plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done", "note": "bug in parser.rs:40"}, {"id": "2", "status": "in-progress"}]}`)).unwrap("valid");
    assert(o.text.startsWith("Updated 1 done + noted, 2 in_progress."), o.text);
    assert(o.text.canFind("[x] 1. Read code\n      (1 note)"));
    assert(o.text.canFind("In progress: 2. Write fix"));
    assert(plan.progress == [1, 3]);

    auto full = plan.apply("plan_show", parseJSON(`{}`)).unwrap("valid");
    assert(!full.changed && full.text.canFind("- bug in parser.rs:40"));
    plan.apply("plan_update", parseJSON(`{"id": 3, "status": "dropped"}`)).unwrap("valid");
    plan.apply("plan_update", parseJSON(`{"id": 2, "status": "done"}`)).unwrap("valid");
    import std.algorithm : endsWith;
    assert(plan.render(false, size_t.max).endsWith("All items are done.\n"));
}

// rust: plan.rs::rejects_bad_calls_without_changing_the_plan
unittest // rejects_bad_calls_without_changing_the_plan
{
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["a"]}`)).unwrap("valid");
    auto before = plan.dup;
    assert(plan.apply("plan_update", parseJSON(`{"id": 9, "status": "done"}`)).match!(v => "", e => e).canFind("items are 1"));
    assert(plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done"}, {"id": 1, "status": "nope"}]}`)).isErr);
    assert(plan.apply("plan_add", parseJSON(`{"items": [{"title": "b", "after": [5]}]}`)).isErr);
    assert(plan.apply("plan_add", parseJSON(`{}`)).isErr);
    assert(plan.apply("plan_add", parseJSON(`{"items": "[\"unclosed"}`)).isErr);
    assert(plan == before);

    plan.apply("plan_add", parseJSON(`{"items": "[\"b\", {\"title\": \"c\", \"after\": [2]}]"}`)).unwrap("valid");
    plan.apply("plan_update", parseJSON(`{"updates": "[{\"id\": 2, \"status\": \"done\"}]"}`)).unwrap("valid");
    assert(plan.items.map!(i => i.title).array == ["a", "b", "c"]);
    assert(plan.items[1].status == Status.done);

    assert(Plan.fromJSON(parseJSON(`{"items": [{"id": 4294967295, "title": "x", "status": "pending"}]}`)).isErr);
    assert(Plan.fromJSON(parseJSON(`{"items": [{"id": 1, "title": "x", "status": "pending"}, {"id": 1, "title": "y", "status": "done"}]}`)).isErr);
    assert(Plan.fromJSON(parseJSON(`{"items": [{"id": 1, "title": "x", "status": "pending", "after": [3]}]}`)).isErr);

    // `toJSON` builds ids from `uint`, which Phobos tags `uinteger`: a
    // nonempty plan must survive its own round-trip (the unsigned value is
    // kept, not read as "above long.max").
    Plan two;
    two.apply("plan_add", parseJSON(`{"items": ["a", "b"]}`)).unwrap("valid");
    auto back = Plan.fromJSON(two.toJSON).unwrap("a nonempty uinteger-id plan round-trips");
    assert(back == two);
    // An unsigned id above long.max is still out of range.
    assert(Plan.fromJSON(parseJSON(`{"items": [{"id": 18446744073709551615, "title": "x", "status": "pending"}]}`)).isErr);
}

// rust: plan.rs::context_note_drops_finished_notes_first_and_round_trips_through_acp
unittest // context_note_drops_finished_notes_first_and_round_trips_through_acp
{
    import std.array : replicate;
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["a", "b"]}`)).unwrap("valid");
    plan.apply("plan_update", JSONValue(["id": JSONValue(1), "status": JSONValue("done"), "note": JSONValue("x".replicate(900))])).unwrap("valid");
    plan.apply("plan_update", parseJSON(`{"id": 2, "note": "keep me"}`)).unwrap("valid");
    auto tight = plan.render(true, 300);
    assert(tight.canFind("- keep me") && tight.canFind("(1 note)"), tight);

    import nano.safeio : jsonText;
    assert(Plan.fromJSON(parseJSON(plan.toJSON.jsonText)).unwrap("valid") == plan);
    auto entries = plan.acpEntries;
    assert(entries[0]["status"].str == "completed");
    auto seeded = Plan.fromJSON(entries).unwrap("valid");
    assert(seeded.items[1].title == "b");
    assert(seeded.items[0].status == Status.done);
}

/// Plans longer than this show finished items as one line.
enum planLines = 12;

/// The plan as the terminal shows it after a change (Rust `ui::plan_checklist`).
string checklist(const ref Plan plan, size_t width, bool color) pure
{
    import nano.trajectory : terminalSafe;
    string c(string code) { return color ? code : ""; }
    auto green = c("\x1b[32m"), bold = c("\x1b[1m"), dim = c("\x1b[2m"), red = c("\x1b[31m"), reset = c("\x1b[0m");
    auto pr = plan.progress;
    import nano.frame : fit;
    // The header is fitted too, so a narrow terminal never wraps it.
    string out_ = fit(format!"%s●%s %sPlan%s %s%s/%s done%s"(green, reset, bold, reset, dim, pr[0], pr[1], reset), width) ~ "\n";
    const(PlanItem)[] live;
    foreach (ref i; plan.items) if (i.status != Status.dropped) live ~= i;
    bool collapse = live.length > planLines && pr[0] > 0;
    if (collapse) out_ ~= format!"  %s✔%s %s%s done%s\n"(green, reset, dim, pr[0], reset);
    const(PlanItem)[] visible;
    foreach (ref i; live) if (!(collapse && i.status == Status.done)) visible ~= i;
    foreach (shown, ref it; visible)
    {
        if (shown == planLines)
        {
            out_ ~= format!"  %s… +%s more%s\n"(dim, visible.length - shown, reset);
            break;
        }
        auto title = fitWidth(terminalSafe(it.title), width);
        string line;
        final switch (it.status)
        {
            case Status.done: line = green ~ "✔" ~ reset ~ " " ~ dim ~ title ~ reset; break;
            case Status.inProgress: line = bold ~ "◼ " ~ title ~ reset; break;
            case Status.blocked: line = red ~ "! " ~ title ~ reset; break;
            case Status.pending, Status.dropped: line = dim ~ "☐" ~ reset ~ " " ~ title; break;
        }
        out_ ~= "  " ~ line ~ "\n";
    }
    return out_;
}

private string fitWidth(string s, size_t width) pure
{
    import nano.lineedit : textWidth, charWidth;
    if (width < 2 || textWidth(s) <= width) return s;
    string out_;
    size_t w;
    foreach (dchar ch; s)
    {
        auto cw = charWidth(ch);
        if (w + cw > width - 1) break;
        out_ ~= ch.to!string;
        w += cw;
    }
    return out_ ~ "…";
}

unittest // multiline goal/title continuation lines are indented, so planSymbols leaves them alone
{
    Plan p;
    p.goal = "G\n[x] 9. fake";
    p.items ~= PlanItem(1, "Ship\n[x] 2. done already");
    auto t = planSymbols(p.render(true, size_t.max));
    assert(t.canFind("      [x] 2. done already"), t);
    assert(t.canFind("      [x] 9. fake"), t);
    assert(!t.canFind("\u2611"), t);
}

unittest // checklist
{
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["one", "two\u001b[2J", "three"]}`)).unwrap("valid");
    plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done"}, {"id": 2, "status": "in_progress"}]}`)).unwrap("valid");
    auto text = checklist(plan, 80, false);
    assert(text == "● Plan 1/3 done\n  ✔ one\n  ◼ two\n  ☐ three\n", text);
}

// rust: ui.rs::plan_checklist_sanitizes_model_controlled_titles
unittest
{
    import std.algorithm : canFind;
    Plan plan;
    plan.items ~= PlanItem(1, "\x1b[2Jwipe\x1b[H", Status.pending);
    auto r = checklist(plan, 80, true);
    assert(!r.canFind("\x1b[2J") && !r.canFind("\x1b[H") && r.canFind("wipe"), r);
}

unittest // issue #346: a finished plan is one line; plan_add starts afresh
{
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"goal": "Old", "items": ["a", "b"]}`)).unwrap("valid");
    plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done", "note": "n"}, {"id": 2, "status": "dropped"}]}`)).unwrap("valid");
    assert(plan.finished);
    assert(plan.contextNote == "[Previous plan 'Old' completed (2 items); details in the session log.]", plan.contextNote);
    assert(plan.carriedOverNote == plan.contextNote);
    auto o = plan.apply("plan_add", parseJSON(`{"goal": "New", "items": ["c"]}`)).unwrap("valid");
    assert(o.restarted && o.changed, o.text);
    assert(plan.goal == "New" && plan.items.length == 1 && plan.items[0].id == 1, plan.render(true, size_t.max));
    assert(!plan.finished && plan.contextNote.canFind("Continue from it"));
    auto again = plan.apply("plan_add", parseJSON(`{"items": ["d"]}`)).unwrap("valid");
    assert(!again.restarted && plan.items.length == 2);
}

unittest // issue #346: closed items' notes are hidden in contextNote, kept in plan_show
{
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["a", "b"]}`)).unwrap("valid");
    plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done", "note": "old finding"}, {"id": 2, "note": "live finding"}]}`)).unwrap("valid");
    auto c = plan.contextNote;
    assert(!c.canFind("old finding") && c.canFind("(1 note)") && c.canFind("- live finding"), c);
    assert(plan.apply("plan_show", parseJSON(`{}`)).unwrap("valid").text.canFind("old finding"));
}

unittest // issue #346: per-item notes are capped in bytes, newest kept
{
    import std.algorithm : sum;
    import std.array : replicate;
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["a"]}`)).unwrap("valid");
    foreach (i; 0 .. 20)
        plan.apply("plan_update", JSONValue(["id": JSONValue(1), "note": JSONValue(format!"%02d"(i) ~ "x".replicate(900))])).unwrap("valid");
    auto notes = plan.items[0].notes;
    assert(notes.map!(n => n.length).sum <= maxNotesBytes, notes.length.to!string);
    assert(notes[0] == droppedNotesMarker);
    assert(notes[$ - 1].startsWith("19") && notes.length > 2);
}

unittest // finished_plan_ignores_an_empty_add_and_caps_loaded_notes
{
    auto p = Plan.fromJSON(parseJSON(`{"items":[{"id":1,"title":"a","status":"done"}]}`)).unwrap("valid");
    assert(p.apply("plan_add", parseJSON(`{}`)).isErr);
    assert(p.apply("plan_add", parseJSON(`{"items":[]}`)).isErr);
    assert(p.items.length == 1, "an empty call keeps the finished plan");
    import std.array : replicate;
    import std.algorithm : sum;
    JSONValue[] notes;
    foreach (i; 0 .. 20) notes ~= JSONValue("n".replicate(900));
    notes ~= JSONValue("x".replicate(100_000));
    auto j = parseJSON(`{"items":[{"id":1,"title":"a","status":"pending"}]}`);
    j["items"][0]["notes"] = JSONValue(notes);
    auto q = Plan.fromJSON(j).unwrap("valid");
    assert(q.items[0].notes.map!(n => n.length).sum <= maxNotesBytes);
    assert(q.items[0].notes[0] == droppedNotesMarker);
}
