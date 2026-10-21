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

@safe:

enum maxItems = 200;
enum maxTitleChars = 200;
enum maxNoteChars = 1_000;
enum maxGoalChars = 2_000;
/// Largest item id accepted from a client-supplied plan.
enum uint maxId = 1_000_000;
/// Budget for the plan restated after compaction.
enum contextChars = 8_000;

immutable string[] toolNames = ["plan_add", "plan_update", "plan_show"];

bool isPlanTool(string name) { return toolNames.canFind(name); }

/// A rejected plan call (Rust `bail!`).
class PlanError : Exception
{
    this(string msg) { super(msg); }
}

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

Status parseStatus(string text)
{
    auto t = text.strip.toLower.replace("-", "_").replace(" ", "_");
    switch (t)
    {
        case "pending", "todo": return Status.pending;
        case "in_progress", "active", "doing", "started": return Status.inProgress;
        case "done", "completed", "complete": return Status.done;
        case "blocked": return Status.blocked;
        case "dropped", "cancelled", "canceled", "skipped": return Status.dropped;
        default:
            throw new PlanError(format!"unknown status %s; use pending, in_progress, done, blocked or dropped"(
                    JSONValue(t).toString));
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

struct PlanItem
{
    uint id;
    string title;
    Status status;
    string[] notes; /// findings and decisions, oldest first
    uint[] after; /// items that must be done (or dropped) first

    PlanItem dup() const { return PlanItem(id, title, status, notes.dup, after.dup); }
}

/// What a plan tool call did.
struct Outcome
{
    string text;
    bool changed;
}

struct Plan
{
    string goal;
    PlanItem[] items;

    Plan dup() const
    {
        Plan p;
        p.goal = goal;
        foreach (ref i; items) p.items ~= i.dup;
        return p;
    }

    bool opEquals(const Plan o) const
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

    bool empty() const { return !goal.length && !items.length; }

    /// (done, total), not counting dropped items.
    size_t[2] progress() const
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

    private size_t item(uint id)
    {
        foreach (k, ref i; items) if (i.id == id) return k;
        if (!items.length) throw new PlanError(format!"no item %s: the plan is empty; add items with plan_add"(id));
        throw new PlanError(format!"no item %s; items are %s"(id, items.map!(i => i.id.to!string).join(", ")));
    }

    private bool isReady(const ref PlanItem it) const
    {
        if (it.status != Status.pending) return false;
        foreach (dep; it.after)
            foreach (ref o; items)
                if (o.id == dep && !o.status.closed) return false;
        return true;
    }

    /// Items to work on next: those in progress, else the first ready one.
    private const(PlanItem)[] next() const
    {
        const(PlanItem)[] active;
        foreach (ref i; items) if (i.status == Status.inProgress) active ~= i;
        if (active.length) return active;
        foreach (ref i; items) if (isReady(i)) return [i];
        return null;
    }

    /// Run a plan tool. Throws PlanError (the plan is left unchanged).
    Outcome apply(string tool, JSONValue args)
    {
        switch (tool)
        {
            case "plan_add": return add(args);
            case "plan_update": return update(args);
            case "plan_show": return Outcome(render(true, size_t.max), false);
            default: throw new PlanError("unknown plan tool " ~ tool);
        }
    }

    private Outcome add(JSONValue args) @trusted
    {
        auto plan = dup();
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
            auto d = decoded(*v);
            if (d.type == JSONType.array) list = d.array;
            else if (d.type != JSONType.null_) list = [d];
        }
        if (!list.length && !summary.length)
            throw new PlanError("plan_add needs `items` (a list of step titles or {title, after} objects) or a `goal`");
        uint firstId = (plan.items.length ? plan.items.map!(i => i.id).maxElement : 0) + 1;
        if (list.length > maxItems || plan.items.length + list.length > maxItems)
            throw new PlanError(format!"a plan holds at most %s items; drop or merge some first"(maxItems));
        uint[] added;
        foreach (offset, it; list)
        {
            uint id = firstId + cast(uint) offset;
            string title, note;
            uint[] after;
            if (it.type == JSONType.string) title = it.str;
            else if (it.type == JSONType.object)
            {
                if (auto t = field(it, "title")) if (t.type == JSONType.string) title = t.str;
                if (auto a = field(it, "after")) after = idsOf(*a);
                if (auto n = field(it, "note")) if (n.type == JSONType.string) note = n.str;
            }
            else throw new PlanError("each item must be a title string or an object with a `title`");
            title = title.strip;
            if (!title.length) throw new PlanError(format!"item %s has an empty title"(offset + 1));
            foreach (dep; after)
                if (dep >= id || !plan.items.any!(i => i.id == dep))
                    throw new PlanError(format!"item %s: `after` must name earlier items, not %s"(
                            JSONValue(title).toString, dep));
            PlanItem p = {id: id, title: clip(title, maxTitleChars), status: Status.pending, after: after};
            if (note.strip.length) p.notes = [clip(note.strip, maxNoteChars)];
            plan.items ~= p;
            added ~= id;
        }
        if (added.length == 1) summary ~= format!"added item %s"(added[0]);
        else if (added.length > 1) summary ~= format!"added items %s-%s"(added[0], added[$ - 1]);
        this = plan;
        return outcome(summary.join(", "));
    }

    private Outcome update(JSONValue args) @trusted
    {
        JSONValue[] updates;
        auto u = field(args, "updates");
        if (u is null) updates = [args];
        else
        {
            auto d = decoded(*u);
            if (d.type == JSONType.array) updates = d.array;
            else if (d.type == JSONType.null_) updates = [args];
            else updates = [d];
        }
        auto plan = dup();
        string[] summary;
        foreach (up; updates)
        {
            auto idv = field(up, "id");
            uint id;
            if (idv is null || !idOf(*idv, id)) throw new PlanError("plan_update needs the item `id`");
            auto it = &plan.items[plan.item(id)];
            string[] did;
            if (auto s = field(up, "status"))
                if (s.type == JSONType.string)
                {
                    it.status = parseStatus(s.str);
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
                    it.notes ~= clip(n.str.strip, maxNoteChars);
                    did ~= "noted";
                }
            if (!did.length) throw new PlanError(format!"item %s: give a `status`, `note` or `title` to change"(id));
            summary ~= format!"%s %s"(id, did.join(" + "));
        }
        this = plan;
        return outcome("updated " ~ summary.join(", "));
    }

    private Outcome outcome(string summary) const
    {
        return Outcome(capitalize(summary) ~ ".\n" ~ render(false, size_t.max), true);
    }

    /// The plan as a checklist. `notes` includes each item's notes; output
    /// over `budget` characters drops the notes of finished items, then all notes.
    string render(bool notes, size_t budget) const
    {
        if (empty) return "The plan is empty.";
        bool[2][] modes = notes ? [[true, true], [true, false], [false, false]] : [[false, false]];
        string text;
        foreach (m; modes)
        {
            text = renderWith(m[0], m[1]);
            if (text.length <= budget) break;
        }
        return text;
    }

    private string renderWith(bool openNotes, bool closedNotes) const
    {
        string out_;
        if (goal.length) out_ ~= "Goal: " ~ goal ~ "\n";
        auto pr = progress();
        out_ ~= format!"Plan (%s/%s done):\n"(pr[0], pr[1]);
        foreach (ref it; items)
        {
            auto after = it.after.length ? " (after " ~ it.after.map!(a => a.to!string).join(", ") ~ ")" : "";
            out_ ~= format!"%s %s. %s%s\n"(it.status.mark, it.id, it.title, after);
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
            out_ ~= label ~ ": " ~ nx.map!(i => format!"%s. %s"(i.id, i.title)).join("; ") ~ "\n";
        }
        return out_;
    }

    /// The plan restated for the model after its context was compacted.
    string contextNote() const
    {
        return "[Your plan, kept by the harness. Earlier conversation may be summarized, but the plan and its notes are "
            ~ "complete. Continue from it and keep it current with plan_update.]\n" ~ render(true, contextChars);
    }

    /// The plan handed to a new session that continues an earlier run.
    string carriedOverNote() const
    {
        return "[A plan carried over from an earlier, interrupted run of this task, kept by the harness. Work already "
            ~ "marked done may be committed or pushed: check the current state before redoing it. Continue from the "
            ~ "plan and keep it current with plan_update.]\n" ~ render(true, contextChars);
    }

    /// ACP `plan` entries (dropped items omitted).
    JSONValue acpEntries() const
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
    JSONValue toJSON() const
    {
        JSONValue[] list;
        foreach (ref i; items)
        {
            auto o = JSONValue(["id": JSONValue(i.id), "title": JSONValue(i.title), "status": JSONValue(statusName(i.status))]);
            if (i.notes.length) o["notes"] = JSONValue(i.notes.dup);
            if (i.after.length) o["after"] = JSONValue(i.after.map!(a => JSONValue(a)).array);
            list ~= o;
        }
        auto o = JSONValue(["items": JSONValue(list)]);
        if (goal.length) o["goal"] = JSONValue(goal);
        return o;
    }

    /// Accept a plan from a client or a session log: this harness's own shape
    /// (`{goal, items}`) or bare ACP entries.
    static Plan fromJSON(JSONValue v) @trusted
    {
        Plan plan;
        if (v.type == JSONType.object && "items" in v)
        {
            if (auto g = field(v, "goal")) if (g.type == JSONType.string) plan.goal = g.str;
            if (v["items"].type != JSONType.array) throw new PlanError("plan must be {goal, items: [{id, title, status}]}");
            foreach (it; v["items"].array)
            {
                PlanItem p;
                auto idv = field(it, "id");
                auto t = field(it, "title");
                auto s = field(it, "status");
                if (idv is null || idv.type != JSONType.integer && idv.type != JSONType.uinteger || t is null
                        || t.type != JSONType.string || s is null || s.type != JSONType.string)
                    throw new PlanError("plan must be {goal, items: [{id, title, status}]}");
                auto raw = idv.type == JSONType.integer ? idv.integer : cast(long) idv.uinteger;
                if (raw <= 0 || raw > maxId) throw new PlanError(format!"plan item id %s is out of range 1-%s"(raw, maxId));
                p.id = cast(uint) raw;
                p.title = t.str;
                p.status = parseStatus(s.str);
                if (auto n = field(it, "notes")) if (n.type == JSONType.array) foreach (x; n.array) p.notes ~= x.str;
                if (auto a = field(it, "after")) p.after = idsOf(*a);
                plan.items ~= p;
            }
            plan.validate();
            return plan;
        }
        JSONValue entries = v;
        if (v.type == JSONType.object && "entries" in v) entries = v["entries"];
        if (entries.type != JSONType.array) throw new PlanError("plan must be {goal, items} or a list of ACP plan entries");
        foreach (index, e; entries.array)
        {
            string title;
            if (auto c = field(e, "content")) { if (c.type == JSONType.string) title = c.str; }
            else if (auto c = field(e, "title")) if (c.type == JSONType.string) title = c.str;
            title = title.strip;
            if (!title.length) continue;
            auto st = Status.pending;
            if (auto s = field(e, "status")) if (s.type == JSONType.string) st = parseStatus(s.str);
            plan.items ~= PlanItem(cast(uint) index + 1, clip(title, maxTitleChars), st);
        }
        return plan;
    }

    /// Check a plan from outside (ids unique and in range, dependencies known).
    private void validate() const
    {
        if (items.length > maxItems) throw new PlanError(format!"a plan holds at most %s items"(maxItems));
        bool[uint] seen;
        foreach (ref i; items)
        {
            if (i.id == 0 || i.id > maxId) throw new PlanError(format!"plan item id %s is out of range 1-%s"(i.id, maxId));
            if (i.id in seen) throw new PlanError(format!"plan item id %s is used twice"(i.id));
            seen[i.id] = true;
        }
        foreach (ref i; items)
            foreach (d; i.after)
                if (d !in seen) throw new PlanError(format!"plan item %s is after unknown item %s"(i.id, d));
    }
}

private const(JSONValue)* field(const ref JSONValue v, string key) @trusted
{
    if (v.type != JSONType.object) return null;
    return key in v.object;
}

/// Models sometimes send a nested list as a JSON string; decode it.
private JSONValue decoded(const JSONValue v) @trusted
{
    if (v.type == JSONType.string)
    {
        auto t = v.str.stripLeft;
        if (t.startsWith("[") || t.startsWith("{"))
        {
            try return parseJSON(v.str);
            catch (Exception e)
                throw new PlanError(format!"could not parse %s as JSON: %s; pass a list, not a string"(
                        JSONValue(v.str).toString, e.msg));
        }
    }
    return cast(JSONValue) v;
}

private bool idOf(const JSONValue v, out uint id) @trusted
{
    try
    {
        if (v.type == JSONType.integer && v.integer >= 0 && v.integer <= uint.max) { id = cast(uint) v.integer; return true; }
        if (v.type == JSONType.uinteger && v.uinteger <= uint.max) { id = cast(uint) v.uinteger; return true; }
        if (v.type == JSONType.string)
        {
            auto s = v.str.strip;
            while (s.startsWith("#")) s = s[1 .. $];
            id = s.to!uint;
            return true;
        }
    }
    catch (Exception) {}
    return false;
}

private uint[] idsOf(const JSONValue v) @trusted
{
    const(JSONValue)[] list;
    if (v.type == JSONType.array) list = v.array;
    else if (v.type != JSONType.null_) list = [v];
    uint[] out_;
    foreach (x; list)
    {
        uint id;
        if (!idOf(x, id)) throw new PlanError("`after` must list item ids, got " ~ x.toString);
        out_ ~= id;
    }
    return out_;
}

private string clip(string text, size_t max)
{
    import std.utf : count;
    import std.range : take;
    if (text.count <= max) return text;
    return text.take(max - 1).to!string ~ "…";
}

private string capitalize(string text)
{
    if (!text.length) return text;
    import std.utf : decode, stride;
    auto n = text.stride(0);
    return text[0 .. n].toUpper ~ text[n .. $];
}

ToolDefinition[] definitions() @trusted
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

@trusted unittest // adds_updates_and_tracks_what_is_next
{
    Plan plan;
    auto o = plan.apply("plan_add",
        parseJSON(`{"goal": "Ship it", "items": ["Read code", {"title": "Write fix", "after": [1]}, "Open PR"]}`));
    assert(o.changed);
    assert(o.text.startsWith("Set the goal, added items 1-3.\n"), o.text);
    assert(o.text.canFind("[ ] 2. Write fix (after 1)"));
    assert(o.text.canFind("Next: 1. Read code"));

    o = plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done", "note": "bug in parser.rs:40"}, {"id": "2", "status": "in-progress"}]}`));
    assert(o.text.startsWith("Updated 1 done + noted, 2 in_progress."), o.text);
    assert(o.text.canFind("[x] 1. Read code\n      (1 note)"));
    assert(o.text.canFind("In progress: 2. Write fix"));
    assert(plan.progress == [1, 3]);

    auto full = plan.apply("plan_show", parseJSON(`{}`));
    assert(!full.changed && full.text.canFind("- bug in parser.rs:40"));
    plan.apply("plan_update", parseJSON(`{"id": 3, "status": "dropped"}`));
    plan.apply("plan_update", parseJSON(`{"id": 2, "status": "done"}`));
    import std.algorithm : endsWith;
    assert(plan.render(false, size_t.max).endsWith("All items are done.\n"));
}

@trusted unittest // rejects_bad_calls_without_changing_the_plan
{
    import std.exception : collectExceptionMsg, assertThrown;
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["a"]}`));
    auto before = plan.dup;
    assert(collectExceptionMsg(plan.apply("plan_update", parseJSON(`{"id": 9, "status": "done"}`))).canFind("items are 1"));
    assertThrown(plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done"}, {"id": 1, "status": "nope"}]}`)));
    assertThrown(plan.apply("plan_add", parseJSON(`{"items": [{"title": "b", "after": [5]}]}`)));
    assertThrown(plan.apply("plan_add", parseJSON(`{}`)));
    assertThrown(plan.apply("plan_add", parseJSON(`{"items": "[\"unclosed"}`)));
    assert(plan == before);

    plan.apply("plan_add", parseJSON(`{"items": "[\"b\", {\"title\": \"c\", \"after\": [2]}]"}`));
    plan.apply("plan_update", parseJSON(`{"updates": "[{\"id\": 2, \"status\": \"done\"}]"}`));
    assert(plan.items.map!(i => i.title).array == ["a", "b", "c"]);
    assert(plan.items[1].status == Status.done);

    assertThrown(Plan.fromJSON(parseJSON(`{"items": [{"id": 4294967295, "title": "x", "status": "pending"}]}`)));
    assertThrown(Plan.fromJSON(parseJSON(`{"items": [{"id": 1, "title": "x", "status": "pending"}, {"id": 1, "title": "y", "status": "done"}]}`)));
    assertThrown(Plan.fromJSON(parseJSON(`{"items": [{"id": 1, "title": "x", "status": "pending", "after": [3]}]}`)));
}

@trusted unittest // context_note_drops_finished_notes_first_and_round_trips_through_acp
{
    import std.array : replicate;
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["a", "b"]}`));
    plan.apply("plan_update", JSONValue(["id": JSONValue(1), "status": JSONValue("done"), "note": JSONValue("x".replicate(900))]));
    plan.apply("plan_update", parseJSON(`{"id": 2, "note": "keep me"}`));
    auto tight = plan.render(true, 300);
    assert(tight.canFind("- keep me") && tight.canFind("(1 note)"), tight);

    assert(Plan.fromJSON(parseJSON(plan.toJSON.toString)) == plan);
    auto entries = plan.acpEntries;
    assert(entries[0]["status"].str == "completed");
    auto seeded = Plan.fromJSON(entries);
    assert(seeded.items[1].title == "b");
    assert(seeded.items[0].status == Status.done);
}

/// Plans longer than this show finished items as one line.
enum planLines = 12;

/// The plan as the terminal shows it after a change (Rust `ui::plan_checklist`).
string checklist(const ref Plan plan, size_t width, bool color)
{
    import nano.question : sanitizeLine;
    string c(string code) { return color ? code : ""; }
    auto green = c("\x1b[32m"), bold = c("\x1b[1m"), dim = c("\x1b[2m"), red = c("\x1b[31m"), reset = c("\x1b[0m");
    auto pr = plan.progress;
    string out_ = format!"%s●%s %sPlan%s %s%s/%s done%s\n"(green, reset, bold, reset, dim, pr[0], pr[1], reset);
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
        auto title = fitWidth(sanitizeLine(it.title), width);
        string line;
        switch (it.status)
        {
            case Status.done: line = green ~ "✔" ~ reset ~ " " ~ dim ~ title ~ reset; break;
            case Status.inProgress: line = bold ~ "◼ " ~ title ~ reset; break;
            case Status.blocked: line = red ~ "! " ~ title ~ reset; break;
            default: line = dim ~ "☐" ~ reset ~ " " ~ title; break;
        }
        out_ ~= "  " ~ line ~ "\n";
    }
    return out_;
}

private string fitWidth(string s, size_t width)
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

@trusted unittest // checklist
{
    Plan plan;
    plan.apply("plan_add", parseJSON(`{"items": ["one", "two\u001b[2J", "three"]}`));
    plan.apply("plan_update", parseJSON(`{"updates": [{"id": 1, "status": "done"}, {"id": 2, "status": "in_progress"}]}`));
    auto text = checklist(plan, 80, false);
    assert(text == "● Plan 1/3 done\n  ✔ one\n  ◼ two[2J\n  ☐ three\n", text);
}
