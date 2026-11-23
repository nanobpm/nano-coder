/// A resumed session's heap is bounded by its context, not by its log
/// (issue #263): the folded tool outputs a compacted session's log holds
/// twice (direct record and replace record) are not kept in memory after a
/// resume, so the heap left after `restore` + `loadRestored` +
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
/// folded turns (the shape of a long smart-compacted session).
string writeLog(string dir, string id, size_t bytes)
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
            auto t = msg("tool", text("output of ", cid, " ").replicate(500));
            t["tool_call_id"] = cid;
            t["name"] = "read";
            put("message", t);
            live ~= t;
        }
        auto done = msg("assistant", text("done ", i));
        put("message", done);
        live ~= done;
        put("turn_end", JSONValue(["input_id": iid, "response": done["content"].str]));
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

/// The GC heap a resumed agent keeps of the log at `path`.
size_t retainedByResume(string path, out size_t stash)
{
    auto agent = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    immutable before = usedAfterCollect();
    {
        auto r = restore(path);
        agent.loadRestored(r, some(new SessionLog(path)));
        r = Restored.init;
    }
    immutable after = usedAfterCollect();
    stash = agent.replayStash.length;
    agent.log.ifSome((SessionLog l) { l.close(); });
    return saturatingSub(after, before);
}

unittest
{
    auto dir = buildPath(tempDir, "nano-d-resume-memory-" ~ newSessionId);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    size_t smallStash, largeStash;
    immutable small = retainedByResume(writeLog(dir, "small", 300_000), smallStash);
    immutable large = retainedByResume(writeLog(dir, "large", 1_200_000), largeStash);
    assert(largeStash > 3 * smallStash, "the large log folds more turns");
    // The large log's folded tool outputs alone are ~0.6 MB: holding them
    // (the pre-#263 resume) fails this; the stash's per-entry metadata fits.
    enum bound = 300_000;
    assert(small < bound && large < bound, text("resume keeps ", small, " B of a 0.3 MB log and ", large,
        " B of a 1.2 MB log; the bound is ", bound));
}
