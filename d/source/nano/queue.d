/// The interactive message queue: messages typed with Ctrl-Enter (or
/// `/queue add`) while a turn runs wait here and run as later prompts, one
/// per turn, in order. Port of `queue.rs`.
///
/// `/queue` lists, edits and removes entries while a turn runs; edits apply
/// at once, so a removed message is never sent. Ids are monotonic, so an id
/// read off `/queue` mid-turn still names the same message later.
module nano.queue;

@safe:

import std.sumtype : SumType, match;
import std.format : format;
import std.string : strip, indexOf;
import std.conv : to, ConvException;
import std.array : join, split, replicate;

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

private string[] words(string s)
{
    import std.array : array;
    import std.algorithm : splitter, filter;
    import std.ascii : isWhite;
    return s.splitter!isWhite.filter!(w => w.length).array;
}

/// Split at the first whitespace.
private string[2] splitOnce(string s)
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

/// Apply an edit and say what happened.
string apply(MessageQueue queue, const QueueOp op)
{
    return op.match!(
        (const ListOp _) => describe(queue),
        (const RemoveOp r) {
            auto removed = queue.remove(r.ids);
            return removed == 0
                ? format!"No queued message with %s (%s)"(idsText(r.ids), summary(queue))
                : format!"Removed %s queued message%s (%s)"(removed, plural(removed), summary(queue));
        },
        (const EditOp e) => queue.edit(e.id, e.text)
            ? format!"Queue #%s updated: %s"(e.id, preview(e.text, 60))
            : format!"No queued message with id %s (%s)"(e.id, summary(queue)),
        (const AddOp a) {
            auto id = queue.push(a.text);
            return format!"↧ queued #%s (%s) — /queue remove %s to drop"(id, summary(queue), id);
        },
        (const ClearOp _) {
            auto n = queue.clear();
            return format!"Cleared %s queued message%s"(n, plural(n));
        },
    );
}

string describe(MessageQueue queue)
{
    auto entries = queue.list;
    if (!entries.length)
        return "Queue is empty. Ctrl-Enter (or /queue add) while a turn runs queues a message; plain Enter steers.";
    auto out_ = format!"Queued (%s):"(entries.length);
    foreach (e; entries) out_ ~= format!"\n  %3s  %s"(e.id, preview(e.text, 80));
    return out_;
}

private string summary(MessageQueue queue)
{
    auto n = queue.length;
    return n == 0 ? "queue is empty" : format!"%s queued"(n);
}

private string plural(size_t n) { return n == 1 ? "" : "s"; }

private string idsText(const size_t[] ids)
{
    if (ids.length == 1) return format!"id %s"(ids[0]);
    string[] parts;
    foreach (i; ids) parts ~= i.to!string;
    return "ids " ~ parts.join(", ");
}

/// One line, at most `max` characters (an ellipsis marks a cut).
string preview(string text, size_t max)
{
    import std.utf : count;
    import std.range : take;
    auto line = words(text).join(" ");
    if (line.count <= max) return line;
    string cut;
    foreach (dchar c; line.take(max ? max - 1 : 0)) cut ~= c.to!string;
    return cut ~ "…";
}

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

unittest // apply reports what happened
{
    import std.algorithm : canFind, startsWith;
    auto q = MessageQueue.make;
    q.push("alpha");
    q.push("beta");
    q.push("gamma");
    auto listed = apply(q, QueueOp(ListOp()));
    assert(listed.canFind("Queued (3):") && listed.canFind("  0  alpha") && listed.canFind("  2  gamma"), listed);
    auto removed = apply(q, QueueOp(RemoveOp([1, 9])));
    assert(removed.canFind("Removed 1 queued message") && removed.canFind("(2 queued)"), removed);
    assert(apply(q, QueueOp(EditOp(2, "GAMMA"))).canFind("#2"));
    assert(q.list[1].text == "GAMMA");
    assert(apply(q, QueueOp(RemoveOp([7]))).canFind("No queued message with id 7"));
    assert(apply(q, QueueOp(ClearOp())).canFind("Cleared 2"));
    assert(apply(q, QueueOp(ListOp()))
        == "Queue is empty. Ctrl-Enter (or /queue add) while a turn runs queues a message; plain Enter steers.");
    auto note = apply(q, QueueOp(AddOp("later")));
    assert(note.startsWith("↧ queued #") && note.canFind("/queue remove") && q.length == 1, note);
}

unittest // preview flattens and truncates
{
    import std.utf : count;
    assert(preview("hello\n  world", 80) == "hello world");
    auto shown = preview("x".replicate(100), 10);
    assert(shown.count == 10 && shown[$ - 3 .. $] == "…");
}
