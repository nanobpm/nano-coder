/// A resumed session's heap is bounded by its context, not by its log
/// (issue #263): the folded tool outputs a compacted session's log holds
/// twice (direct record and replace record) are not kept in memory after a
/// resume, and a transcript replay that reads them back does not keep them:
/// the heap left after `restore` + `loadRestored` + replay +
/// `releaseHeap` is the same small bound for a small and a large log.
module nano.session_resume_memory_test;
@safe:

version (unittest):

import std.array : appender, replicate;
import std.conv : text;
import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
import std.json : JSONValue;
import std.path : buildPath;
import nano.agent;
import nano.arith : saturatingSub;
import nano.llm;
import nano.option : ifSome, some;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : Restored, SessionLog, newSessionId, releaseHeap, restore;
import nano.tools : ToolRegistry;

private:

/// Write a nano-format log of about `bytes`: turns of four large tool results,
/// compacted every two turns by delta `replace` records restating the
/// folded turns (the shape of a long smart-compacted session). With
/// `heavyReplies` the tool outputs are short and the assistant replies carry
/// the bulk: long answers and reasoning (issue #301).
string writeLog(string dir, string id, size_t bytes, bool heavyReplies = false)
{
    auto o = appender!string;
    ulong line;
    ulong put(string type, JSONValue data)
    {
        o.put(JSONValue(["type": JSONValue(type), "data": data]).toString);
        o.put('\n');
        return ++line;
    }
    JSONValue msg(string role, string content)
    {
        JSONValue m = ["role": role, "content": content];
        m["log_line"] = line + 1;
        return m;
    }
    put("session", JSONValue(["version": JSONValue(1), "id": JSONValue(id), "created_at": JSONValue("x")]));
    put("message", msg("system", "sys"));
    JSONValue[] live;
    size_t stashN, pinsN;
    for (size_t i = 0; o.data.length < bytes; i++)
    {
        auto iid = text("in-", i);
        auto q = text("request ", i, ": fix module ", i % 97);
        put("input", JSONValue(["id": iid, "text": q]));
        auto u = msg("user", q);
        put("message", u);
        live ~= u;
        foreach (k; 0 .. 4)
        {
            auto cid = text("c", i, "_", k);
            auto a = msg("assistant", "");
            a["tool_calls"] = [JSONValue(["id": JSONValue(cid), "name": JSONValue("read"),
                "arguments": JSONValue(["path": "f"])])];
            put("message", a);
            live ~= a;
            auto t = msg("tool", heavyReplies ? "ok" : text("output of ", cid, " ").replicate(500));
            t["tool_call_id"] = cid;
            t["name"] = "read";
            put("message", t);
            live ~= t;
        }
        auto done = msg("assistant", heavyReplies ? text("answer ", i, " ").replicate(1000) : text("done ", i));
        if (heavyReplies) done["thinking"] = text("reasoning ", i, " ").replicate(1000);
        put("message", done);
        live ~= done;
        // The turn's response is kept per input id for redelivery; not what
        // this measures, so it stays short.
        put("turn_end", JSONValue(["input_id": iid, "response": text("done ", i)]));
        if (i % 2 == 1)
        {
            JSONValue[] pins;
            foreach (m; live) if (m["role"].str == "user") pins ~= m;
            JSONValue d = ["mode": "smart"];
            d["messages"] = [msg("system", "sys"), msg("user", text("summary ", i))];
            d["folded"] = live;
            d["folded_base"] = stashN;
            d["pinned_requests"] = pins;
            d["pinned_base"] = pinsN;
            d["summarized"] = [live[0]["log_line"], live[$ - 1]["log_line"]];
            put("replace", d);
            stashN += live.length;
            pinsN += pins.length;
            live = null;
        }
    }
    auto path = buildPath(dir, id ~ ".jsonl");
    write(path, o.data);
    return path;
}

/// GC bytes in use after a collection.
size_t usedAfterCollect() nothrow
{
    import core.memory : GC;
    releaseHeap();
    return GC.stats.usedSize;
}

/// The content bytes `agent`'s replay shows. A separate frame, so no
/// stale stack slot of the caller still points at the replayed messages
/// when it measures the heap.
pragma(inline, false)
size_t replayedBytes(Agent agent)
{
    size_t n;
    foreach (ref m; agent.replayMessages) n += m.content.length + m.thinking.length;
    return n;
}

/// Overwrite the stack below the caller's frame. The GC scans the stack
/// conservatively, so a dead slot of the replay that still points at its
/// rehydrated messages would otherwise keep them alive into the measurement
/// (seen: about 0.6 MB for the large log) and mask what the agent retains.
pragma(inline, false)
void clobberStack() nothrow
{
    ubyte[64 * 1024] junk = 1;
    foreach (ref b; junk) b ^= 1;
}

/// The GC heap a resumed agent keeps of the log at `path`.
/// It replays the transcript too (rehydrating the folded tool outputs from
/// the log), so a replay that retained what it read back would also fail;
/// `replayed` is the content bytes the replay produced.
size_t retainedByResume(string path, out size_t stash, out size_t replayed)
{
    size_t text_;
    return retainedByResume(path, stash, replayed, text_);
}

/// As above; `stashText` is the reply and tool-output text (content,
/// reasoning and thinking blocks) the resumed agent's replay stash still
/// holds: an exact count, the same on every platform, where the GC figure
/// also has allocator overhead that differs by platform (issue #388).
size_t retainedByResume(string path, out size_t stash, out size_t replayed, out size_t stashText)
{
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    immutable before = usedAfterCollect();
    {
        auto r = restore(path);
        agent.loadRestored(r, some(new SessionLog(path)));
        r = Restored.init;
    }
    replayed = replayedBytes(agent);
    clobberStack();
    immutable after = usedAfterCollect();
    stash = agent.replayStash.length;
    foreach (ref m; agent.replayStash)
    {
        stashText += m.content.length + m.thinking.length;
        foreach (ref b; m.thinkingBlocks) stashText += b.toString.length;
    }
    agent.log.ifSome((SessionLog l) { l.close(); });
    return saturatingSub(after, before);
}

unittest
{
    auto dir = buildPath(tempDir, "nano-d-resume-memory-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    size_t smallStash, largeStash, smallReplayed, largeReplayed;
    immutable small = retainedByResume(writeLog(dir, "small", 300_000), smallStash, smallReplayed);
    immutable large = retainedByResume(writeLog(dir, "large", 1_200_000), largeStash, largeReplayed);
    assert(largeStash > 3 * smallStash, "the large log folds more turns");
    // The replay really rehydrated the folded outputs (well over the bound),
    // yet none of it stays on the heap once the replayed messages are dropped.
    assert(largeReplayed > 500_000, text("replay rehydrated only ", largeReplayed, " B"));
    // The large log's folded tool outputs alone are ~0.6 MB: holding them
    // (the pre-#263 resume) fails this; the stash's per-entry metadata fits.
    enum bound = 300_000;
    assert(small < bound && large < bound, text("resume keeps ", small, " B of a 0.3 MB log and ", large,
        " B of a 1.2 MB log; the bound is ", bound));
}

// The same bound when the bulk is assistant replies (long answers and
// reasoning) rather than tool outputs: a folded reply keeps only its log
// reference too, and the replay reads it back (issue #301).
unittest
{
    auto dir = buildPath(tempDir, "nano-d-resume-memory-replies-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    size_t smallStash, largeStash, smallReplayed, largeReplayed, smallText, largeText;
    retainedByResume(writeLog(dir, "small", 300_000, true), smallStash, smallReplayed, smallText);
    retainedByResume(writeLog(dir, "large", 1_200_000, true), largeStash, largeReplayed, largeText);
    assert(largeStash > 3 * smallStash, "the large log folds more turns");
    assert(largeReplayed > 300_000, text("replay rehydrated only ", largeReplayed, " B"));
    // Each folded turn's reply holds ~20 KB of answer and reasoning: a stash
    // that kept them would hold about what the replay rehydrated. Counted
    // exactly from the stash, not from GC.stats: the heap figure also holds
    // allocator overhead and conservatively scanned garbage that differ by
    // platform and load (0.05 MB on macOS, 0.4 MB on linux-arm64 Release,
    // issue #388), so a bound on it can't separate the two.
    assert(smallText * 100 < smallReplayed && largeText * 100 < largeReplayed, text("the stash keeps ",
        smallText, " B of reply text of a 0.3 MB log and ", largeText, " B of a 1.2 MB log"));
}
