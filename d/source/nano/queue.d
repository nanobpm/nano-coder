/// The interactive message queue: messages typed with Ctrl-Enter (or
/// `/queue add`) while a turn runs wait here and run as later prompts, one
/// per turn, in order. Port of `queue.rs`.
///
/// `/queue` lists, edits and removes entries while a turn runs; edits apply
/// at once, so a removed message is never sent. Ids are monotonic, so an id
/// read off `/queue` mid-turn still names the same message later.
module nano.queue;

@safe:

import std.format : format;
import std.string : strip, indexOf;
import std.conv : to, ConvException;
import std.array : join, split, replicate;
import core.sync.mutex : Mutex;

struct QueuedMessage
{
    size_t id;
    string text;
}

/// FIFO of messages waiting to run as prompts; safe to share between the
/// turn's key thread and the main loop.
final class MessageQueue
{
    private QueuedMessage[] entries;
    private size_t nextId;
    private Mutex lock;

    this() @trusted { lock = new Mutex; }

    /// Add a message; returns its id.
    size_t push(string text) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        auto id = nextId++;
        entries ~= QueuedMessage(id, text);
        return id;
    }

    /// The next message to run, if any.
    bool pop(out QueuedMessage m) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        if (!entries.length) return false;
        m = entries[0];
        entries = entries[1 .. $];
        return true;
    }

    /// The waiting messages, oldest first.
    QueuedMessage[] list() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        return entries.dup;
    }

    size_t length() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        return entries.length;
    }

    bool empty() { return length == 0; }

    /// Drop the entries with these ids; returns how many were removed.
    size_t remove(const size_t[] ids) @trusted
    {
        import std.algorithm : canFind, filter;
        import std.array : array;
        lock.lock();
        scope (exit) lock.unlock();
        auto before = entries.length;
        entries = entries.filter!(e => !ids.canFind(e.id)).array;
        return before - entries.length;
    }

    /// Replace one entry's text; false when no entry has that id.
    bool edit(size_t id, string text) @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        foreach (ref e; entries)
            if (e.id == id)
            {
                e.text = text;
                return true;
            }
        return false;
    }

    /// Drop everything waiting; returns how many were removed.
    size_t clear() @trusted
    {
        lock.lock();
        scope (exit) lock.unlock();
        auto n = entries.length;
        entries = null;
        return n;
    }
}

/// One queue edit, parsed from a `/queue ...` command line.
struct QueueOp
{
    enum Kind { list, remove, edit, clear, add }
    Kind kind;
    size_t[] ids; /// remove; edit uses ids[0]
    string text;  /// edit, add
}

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
    if (!args.length || args == "list" || args == "ls") return QueueOp(QueueOp.Kind.list);
    auto parts = splitOnce(args);
    auto sub = parts[0], rest = parts[1].strip;
    switch (sub)
    {
        case "add":
            if (!rest.length) throw new QueueUsage(usage);
            return QueueOp(QueueOp.Kind.add, null, rest);
        case "remove", "rm", "delete":
            size_t[] ids;
            foreach (w; words(rest)) ids ~= parseId(w);
            if (!ids.length) throw new QueueUsage(usage);
            return QueueOp(QueueOp.Kind.remove, ids);
        case "edit":
            auto p = splitOnce(rest);
            if (p[0] == rest) throw new QueueUsage(usage);
            auto id = parseId(p[0].strip);
            auto text = p[1].strip;
            if (!text.length) throw new QueueUsage(usage);
            return QueueOp(QueueOp.Kind.edit, [id], text);
        case "clear":
            if (rest.length) throw new QueueUsage(usage);
            return QueueOp(QueueOp.Kind.clear);
        default:
            throw new QueueUsage(usage);
    }
}

/// Apply an edit and say what happened.
string apply(MessageQueue queue, const QueueOp op)
{
    final switch (op.kind)
    {
        case QueueOp.Kind.list: return describe(queue);
        case QueueOp.Kind.remove:
            auto removed = queue.remove(op.ids);
            return removed == 0
                ? format!"No queued message with %s (%s)"(idsText(op.ids), summary(queue))
                : format!"Removed %s queued message%s (%s)"(removed, plural(removed), summary(queue));
        case QueueOp.Kind.edit:
            return queue.edit(op.ids[0], op.text)
                ? format!"Queue #%s updated: %s"(op.ids[0], preview(op.text, 60))
                : format!"No queued message with id %s (%s)"(op.ids[0], summary(queue));
        case QueueOp.Kind.add:
            auto id = queue.push(op.text);
            return format!"↧ queued #%s (%s) — /queue remove %s to drop"(id, summary(queue), id);
        case QueueOp.Kind.clear:
            auto n = queue.clear();
            return format!"Cleared %s queued message%s"(n, plural(n));
    }
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
    auto q = new MessageQueue;
    assert(q.push("first") == 0 && q.push("second") == 1 && q.push("third") == 2);
    assert(q.remove([1]) == 1);
    auto l = q.list;
    assert(l.length == 2 && l[0].id == 0 && l[1].id == 2);
    assert(q.clear() == 2 && q.empty);
    assert(q.push("fourth") == 3);
}

unittest // pop is FIFO and edit rewrites in place
{
    auto q = new MessageQueue;
    q.push("one");
    q.push("two");
    assert(q.edit(1, "TWO") && !q.edit(9, "nope"));
    QueuedMessage m;
    assert(q.pop(m) && m.text == "one");
    assert(q.pop(m) && m.text == "TWO");
    assert(!q.pop(m));
}

@trusted unittest // parse covers the subcommands
{
    import std.exception : assertThrown;
    assert(parse("").kind == QueueOp.Kind.list && parse("  ").kind == QueueOp.Kind.list);
    assert(parse("list").kind == QueueOp.Kind.list && parse("ls").kind == QueueOp.Kind.list);
    assert(parse("remove 2") == QueueOp(QueueOp.Kind.remove, [2]));
    assert(parse("rm 2 4") == QueueOp(QueueOp.Kind.remove, [2, 4]));
    assert(parse("delete 3") == QueueOp(QueueOp.Kind.remove, [3]));
    assert(parse("edit 2 try this instead") == QueueOp(QueueOp.Kind.edit, [2], "try this instead"));
    assert(parse("clear").kind == QueueOp.Kind.clear);
    foreach (bad; ["clear keep-this", "remove", "remove x", "edit 2", "edit 2   ", "edit x hi", "frob", "add", "add   "])
        assertThrown!QueueUsage(parse(bad), bad);
    assert(parse("add fix the build") == QueueOp(QueueOp.Kind.add, null, "fix the build"));
}

unittest // apply reports what happened
{
    import std.algorithm : canFind, startsWith;
    auto q = new MessageQueue;
    q.push("alpha");
    q.push("beta");
    q.push("gamma");
    auto listed = apply(q, QueueOp(QueueOp.Kind.list));
    assert(listed.canFind("Queued (3):") && listed.canFind("  0  alpha") && listed.canFind("  2  gamma"), listed);
    auto removed = apply(q, QueueOp(QueueOp.Kind.remove, [1, 9]));
    assert(removed.canFind("Removed 1 queued message") && removed.canFind("(2 queued)"), removed);
    assert(apply(q, QueueOp(QueueOp.Kind.edit, [2], "GAMMA")).canFind("#2"));
    assert(q.list[1].text == "GAMMA");
    assert(apply(q, QueueOp(QueueOp.Kind.remove, [7])).canFind("No queued message with id 7"));
    assert(apply(q, QueueOp(QueueOp.Kind.clear)).canFind("Cleared 2"));
    assert(apply(q, QueueOp(QueueOp.Kind.list))
        == "Queue is empty. Ctrl-Enter (or /queue add) while a turn runs queues a message; plain Enter steers.");
    auto note = apply(q, QueueOp(QueueOp.Kind.add, null, "later"));
    assert(note.startsWith("↧ queued #") && note.canFind("/queue remove") && q.length == 1, note);
}

unittest // preview flattens and truncates
{
    import std.utf : count;
    assert(preview("hello\n  world", 80) == "hello world");
    auto shown = preview("x".replicate(100), 10);
    assert(shown.count == 10 && shown[$ - 3 .. $] == "…");
}
