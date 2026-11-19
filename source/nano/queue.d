/// The interactive message queue: messages typed with Ctrl-Enter (or
/// `/queue add`) while a turn runs wait here and run as later prompts, one
/// per turn, in order. Port of `queue.rs`.
///
/// `/queue` lists, edits and removes entries while a turn runs; edits apply
/// at once, so a removed message is never sent. Ids are monotonic, so an id
/// read off `/queue` mid-turn still names the same message later.
///
/// Steers (plain Enter mid-turn) share the same id space and the same
/// `/queue` surface: until the agent reads a steer at its next step it is
/// listed as `steer`, and `remove`/`edit`/`clear` apply to it too, so a
/// steer the running turn has made stale can be withdrawn or rewritten. A
/// steer the agent has already read is gone from the list.
module nano.queue;

@safe:

import std.sumtype : SumType, match;
import std.format : format;
import std.string : strip, indexOf;
import std.conv : to, ConvException;
import std.array : join, split, replicate;
import nano.control : TurnControl;
import core.atomic : atomicLoad;

struct QueuedMessage
{
    size_t id;
    string text;
}

/// FIFO of messages waiting to run as prompts: a sendable handle (copies
/// share the queue), so the turn's key thread and the main loop both use it.
struct MessageQueue
{
    import nano.safeio : Shared;
    private static struct State
    {
        immutable(QueuedMessage)[] entries;
        size_t nextId;
    }
    private Shared!State state;

    /// A new, empty queue.
    static MessageQueue make() { return MessageQueue(Shared!State.make); }

    /// Add a message; returns its id.
    size_t push(string text)
    {
        return state.update!size_t((ref State s) {
            auto id = s.nextId++;
            s.entries ~= QueuedMessage(id, text);
            return id;
        });
    }

    /// Take an id without queueing anything (for a steer, so steers and
    /// queued messages never share an id).
    size_t reserveId() { return state.update!size_t((ref State s) => s.nextId++); }

    /// Queue a message under an id taken earlier with `reserveId` (a steer
    /// the turn ended before reading keeps its id).
    void pushWithId(size_t id, string text)
    {
        state.update((ref State s) { s.entries ~= QueuedMessage(id, text); });
    }

    /// The next message to run, if any.
    bool pop(out QueuedMessage m)
    {
        QueuedMessage got;
        bool ok = state.update!bool((ref State s) {
            if (!s.entries.length) return false;
            got = s.entries[0];
            s.entries = s.entries[1 .. $];
            return true;
        });
        m = got;
        return ok;
    }

    /// The waiting messages, oldest first.
    immutable(QueuedMessage)[] list() { return state.get.entries; }

    size_t length() { return state.get.entries.length; }

    bool empty() { return length == 0; }

    /// Drop the entries with these ids; returns how many were removed.
    size_t remove(const size_t[] ids)
    {
        import std.algorithm : canFind, filter;
        import std.array : array;
        return state.update!size_t((ref State s) {
            auto before = s.entries.length;
            s.entries = s.entries.filter!(e => !ids.canFind(e.id)).array;
            return before - s.entries.length;
        });
    }

    /// Replace one entry's text; false when no entry has that id.
    bool edit(size_t id, string text)
    {
        return state.update!bool((ref State s) {
            foreach (i, ref e; s.entries)
                if (e.id == id)
                {
                    s.entries = s.entries[0 .. i] ~ QueuedMessage(id, text) ~ s.entries[i + 1 .. $];
                    return true;
                }
            return false;
        });
    }

    /// Drop everything waiting; returns how many were removed.
    size_t clear()
    {
        return state.update!size_t((ref State s) {
            auto n = s.entries.length;
            s.entries = null;
            return n;
        });
    }
}

/// One queue edit, parsed from a `/queue ...` command line.
/// Each variant carries only its own fields, and `apply` must handle every
/// one (`match` is exhaustive).
struct ListOp {}
/// ditto
struct RemoveOp { size_t[] ids; }
/// ditto
struct EditOp { size_t id; string text; }
/// ditto
struct ClearOp {}
/// ditto
struct AddOp { string text; }
/// ditto
alias QueueOp = SumType!(ListOp, RemoveOp, EditOp, ClearOp, AddOp);

enum usage = "usage: /queue [list] | /queue add text | /queue remove N... | /queue edit N text | /queue clear";

class QueueUsage : Exception
{
    this(string msg) { super(msg); }
}

private size_t parseId(string word)
{
    import std.json : JSONValue;
    try
    {
        if (word.length && word[0] != '+' && word[0] != '-') return word.to!size_t;
    }
    catch (ConvException) {}
    throw new QueueUsage(format!"%s is not a queue id — %s"(JSONValue(word).toString, usage));
}

private string[] words(string s) pure
{
    import std.array : array;
    import std.algorithm : splitter, filter;
    import std.ascii : isWhite;
    return s.splitter!isWhite.filter!(w => w.length).array;
}

/// Split at the first whitespace.
private string[2] splitOnce(string s) pure
{
    import std.ascii : isWhite;
    foreach (i, char c; s)
        if (c.isWhite) return [s[0 .. i], s[i + 1 .. $]];
    return [s, ""];
}

/// Parse the arguments after `/queue` (empty means list); throws QueueUsage.
QueueOp parse(string args)
{
    args = args.strip;
    if (!args.length || args == "list" || args == "ls") return QueueOp(ListOp());
    auto parts = splitOnce(args);
    auto sub = parts[0], rest = parts[1].strip;
    switch (sub)
    {
        case "add":
            if (!rest.length) throw new QueueUsage(usage);
            return QueueOp(AddOp(rest));
        case "remove", "rm", "delete":
            size_t[] ids;
            foreach (w; words(rest)) ids ~= parseId(w);
            if (!ids.length) throw new QueueUsage(usage);
            return QueueOp(RemoveOp(ids));
        case "edit":
            auto p = splitOnce(rest);
            if (p[0] == rest) throw new QueueUsage(usage);
            auto id = parseId(p[0].strip);
            auto text = p[1].strip;
            if (!text.length) throw new QueueUsage(usage);
            return QueueOp(EditOp(id, text));
        case "clear":
            if (rest.length) throw new QueueUsage(usage);
            return QueueOp(ClearOp());
        default:
            throw new QueueUsage(usage);
    }
}

/// Apply an edit to the queue and any unread steers (`steers` is the
/// agent's turn controls; between turns it has none unread); says what happened.
string apply(MessageQueue queue, shared TurnControl steers, const QueueOp op)
{
    return op.match!(
        (const ListOp _) => describe(queue, atomicLoad(steers)),
        (const RemoveOp r) {
            auto withdrawn = steers.removeSteers(r.ids);
            auto removed = queue.remove(r.ids);
            auto sum = summary(queue, atomicLoad(steers));
            if (!withdrawn && !removed) return format!"No pending message with %s (%s)"(idsText(r.ids), sum);
            if (!withdrawn) return format!"Removed %s queued message%s (%s)"(removed, plural(removed), sum);
            if (!removed) return format!"Withdrew %s steer%s (%s)"(withdrawn, plural(withdrawn), sum);
            return format!"Withdrew %s steer%s and removed %s queued message%s (%s)"(withdrawn, plural(withdrawn),
                removed, plural(removed), sum);
        },
        (const EditOp e) {
            if (steers.editSteer(e.id, e.text))
                return format!"Steer #%s updated: %s"(e.id, preview(e.text, 60));
            if (queue.edit(e.id, e.text)) return format!"Queue #%s updated: %s"(e.id, preview(e.text, 60));
            return format!"No pending message with id %s (%s)"(e.id, summary(queue, atomicLoad(steers)));
        },
        (const AddOp a) {
            auto id = queue.push(a.text);
            return format!"↧ queued #%s (%s) — /queue remove %s to drop"(id, summary(queue, atomicLoad(steers)), id);
        },
        (const ClearOp _) {
            auto w = steers.clearSteers();
            auto n = queue.clear();
            return w == 0 ? format!"Cleared %s queued message%s"(n, plural(n))
                : format!"Cleared %s queued message%s and withdrew %s steer%s"(n, plural(n), w, plural(w));
        },
    );
}

enum emptyQueue = "Queue is empty. Enter while a turn runs steers it; Ctrl-Enter (or /queue add) queues a message for after it.";

/// One line per pending message: unread steers first (the agent reads them
/// at its next step), then queued messages, oldest first.
string describe(MessageQueue queue, shared TurnControl steers)
{
    auto entries = queue.list;
    auto pending = steers.pendingSteers;
    if (!entries.length && !pending.length) return emptyQueue;
    auto out_ = format!"Pending (%s):"(entries.length + pending.length);
    foreach (m; pending) out_ ~= format!"\n  %3s  steer   %s"(m.id, preview(m.text, 80));
    foreach (e; entries) out_ ~= format!"\n  %3s  queued  %s"(e.id, preview(e.text, 80));
    if (pending.length) out_ ~= "\nSteers go to the agent at its next step; /queue remove or edit them before then.";
    return out_;
}

/// "2 steers pending, 1 queued" / "queue is empty", for trailing summaries.
private string summary(MessageQueue queue, shared TurnControl steers)
{
    auto w = steers.pendingSteers.length;
    auto n = queue.length;
    if (!w) return n == 0 ? "queue is empty" : format!"%s queued"(n);
    return n == 0 ? format!"%s steer%s pending"(w, plural(w)) : format!"%s steer%s pending, %s queued"(w, plural(w), n);
}

private string plural(size_t n) pure { return n == 1 ? "" : "s"; }

private string idsText(const size_t[] ids) pure
{
    if (ids.length == 1) return format!"id %s"(ids[0]);
    string[] parts;
    foreach (i; ids) parts ~= i.to!string;
    return "ids " ~ parts.join(", ");
}

/// One line, at most `max` characters (an ellipsis marks a cut).
string preview(string text, size_t max) pure
{
    import std.utf : count;
    import std.range : take;
    auto line = words(text).join(" ");
    if (line.count <= max) return line;
    string cut;
    foreach (dchar c; line.take(max ? max - 1 : 0)) cut ~= c.to!string;
    return cut ~ "…";
}

// rust: queue.rs::push_assigns_monotonic_ids_that_survive_removal_and_clear
unittest // push assigns monotonic ids that survive removal and clear
{
    auto q = MessageQueue.make;
    assert(q.push("first") == 0 && q.push("second") == 1 && q.push("third") == 2);
    assert(q.remove([1]) == 1);
    auto l = q.list;
    assert(l.length == 2 && l[0].id == 0 && l[1].id == 2);
    assert(q.clear() == 2 && q.empty);
    assert(q.push("fourth") == 3);
}

// rust: queue.rs::pop_is_fifo_and_edit_rewrites_in_place
unittest // pop is FIFO and edit rewrites in place
{
    auto q = MessageQueue.make;
    q.push("one");
    q.push("two");
    assert(q.edit(1, "TWO") && !q.edit(9, "nope"));
    QueuedMessage m;
    assert(q.pop(m) && m.text == "one");
    assert(q.pop(m) && m.text == "TWO");
    assert(!q.pop(m));
}

// rust: queue.rs::add_queues_a_message
// rust: queue.rs::parse_covers_the_subcommands
unittest // parse covers the subcommands
{
    import std.exception : assertThrown;
    foreach (l; ["", "  ", "list", "ls"]) assert(parse(l) == QueueOp(ListOp()));
    assert(parse("remove 2") == QueueOp(RemoveOp([2])));
    assert(parse("rm 2 4") == QueueOp(RemoveOp([2, 4])));
    assert(parse("delete 3") == QueueOp(RemoveOp([3])));
    assert(parse("edit 2 try this instead") == QueueOp(EditOp(2, "try this instead")));
    assert(parse("clear") == QueueOp(ClearOp()));
    foreach (bad; ["clear keep-this", "remove", "remove x", "edit 2", "edit 2   ", "edit x hi", "frob", "add", "add   "])
        assertThrown!QueueUsage(parse(bad), bad);
    assert(parse("add fix the build") == QueueOp(AddOp("fix the build")));
}

// rust: queue.rs::apply_reports_what_happened
unittest // apply reports what happened
{
    import std.algorithm : canFind, startsWith;
    auto q = MessageQueue.make;
    auto idle = new shared TurnControl; // between turns: no unread steers
    q.push("alpha");
    q.push("beta");
    q.push("gamma");
    auto listed = apply(q, atomicLoad(idle), QueueOp(ListOp()));
    assert(listed.canFind("Pending (3):") && listed.canFind("  0  queued  alpha") && listed.canFind("  2  queued  gamma"),
        listed);
    auto removed = apply(q, atomicLoad(idle), QueueOp(RemoveOp([1, 9])));
    assert(removed.canFind("Removed 1 queued message") && removed.canFind("(2 queued)"), removed);
    assert(apply(q, atomicLoad(idle), QueueOp(EditOp(2, "GAMMA"))).canFind("#2"));
    assert(q.list[1].text == "GAMMA");
    assert(apply(q, atomicLoad(idle), QueueOp(RemoveOp([7]))).canFind("No pending message with id 7"));
    assert(apply(q, atomicLoad(idle), QueueOp(ClearOp())).canFind("Cleared 2"));
    assert(apply(q, atomicLoad(idle), QueueOp(ListOp())) == emptyQueue);
    auto note = apply(q, atomicLoad(idle), QueueOp(AddOp("later")));
    assert(note.startsWith("↧ queued #") && note.canFind("/queue remove") && q.length == 1, note);
}

// rust: queue.rs::edits_reach_unread_steers_and_share_ids_with_the_queue
unittest // edits reach unread steers and share ids with the queue (Rust edits_reach_unread_steers_and_share_ids_with_the_queue)
{
    import std.algorithm : canFind, startsWith;
    import std.json : JSONValue;
    import nano.control : Steer;
    auto control = new shared TurnControl;
    auto q = MessageQueue.make;
    auto s0 = q.reserveId();
    control.steerWithId("use the old api", s0);
    auto q1 = q.push("then write docs");
    auto s2 = q.reserveId();
    control.steerWithId("skip the tests", s2);
    control.steer(Steer("acp steer, not listed", JSONValue(7)));
    assert(s0 == 0 && q1 == 1 && s2 == 2);

    auto listed = apply(q, atomicLoad(control), QueueOp(ListOp()));
    assert(listed.startsWith("Pending (3):"), listed);
    assert(listed.canFind("  0  steer   use the old api") && listed.canFind("  1  queued  then write docs"), listed);
    assert(!listed.canFind("acp steer"), listed);

    auto edited = apply(q, atomicLoad(control), QueueOp(EditOp(0, "use the new api")));
    assert(edited.startsWith("Steer #0 updated"), edited);
    assert(control.pendingSteers[0].text == "use the new api");

    auto removed = apply(q, atomicLoad(control), QueueOp(RemoveOp([2, 1])));
    assert(removed.canFind("Withdrew 1 steer and removed 1 queued message") && removed.canFind("(1 steer pending)"), removed);

    // Once the agent reads a steer it is no longer editable.
    auto read = control.takePending;
    assert(read.length == 2 && read[0].text == "use the new api", "the edited steer and the untracked one are delivered");
    auto late = apply(q, atomicLoad(control), QueueOp(EditOp(0, "too late")));
    assert(late.startsWith("No pending message with id 0"), late);

    control.steerWithId("one more", q.reserveId());
    control.steer("untracked");
    auto cleared = apply(q, atomicLoad(control), QueueOp(ClearOp()));
    assert(cleared.canFind("withdrew 1 steer"), cleared);
    assert(control.takePending.length == 1, "clear leaves untracked (ACP) steers alone");

    // A steer left unread keeps its id in the queue.
    q.pushWithId(3, "kept");
    assert(q.list == [QueuedMessage(3, "kept")] && q.push("next") == 4);
}

// rust: queue.rs::preview_flattens_and_truncates
unittest // preview flattens and truncates
{
    import std.utf : count;
    assert(preview("hello\n  world", 80) == "hello world");
    auto shown = preview("x".replicate(100), 10);
    assert(shown.count == 10 && shown[$ - 3 .. $] == "…");
}
