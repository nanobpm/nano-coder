/// Session handles at the agent level (issue #300): `/name`'s validation,
/// persistence across a resume and `--clear`; uniqueness among running
/// sessions; `session_send` and the history tools resolving a handle (a
/// handle beats a colliding title); and the resume hint naming the handle.
module nano.agent_name_test;
@safe:

version (unittest):

import std.algorithm : canFind;
import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists;
import std.path : buildPath;
import nano.agent;
import nano.handle : handlePath, sessionLine, resumeArg;
import nano.llm;
import nano.option : ifSome, some;
import nano.peers;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : SessionLog, restore;
import nano.tools : ToolRegistry;
static import cross = nano.cross_session;

private:

/// A sessions dir and a peers dir under a fresh root; NANO_CODER_PEERS
/// points at the latter for the test's life.
struct Dirs
{
    string root, sessions, peers;

    static Dirs make(string name)
    {
        import std.process : environment;
        Dirs d;
        d.root = buildPath(tempDir, name);
        if (d.root.exists) rmdirRecurse(d.root);
        d.sessions = buildPath(d.root, "sessions");
        d.peers = buildPath(d.root, "peers");
        mkdirRecurse(d.sessions);
        mkdirRecurse(d.peers);
        environment["NANO_CODER_PEERS"] = d.peers;
        return d;
    }

    void cleanup()
    {
        import std.process : environment;
        environment.remove("NANO_CODER_PEERS");
        rmdirRecurse(root);
    }

    /// An agent recording to a new log `id` (with one prompt, so the index lists it).
    Agent agent(string id, MockClient mock = null)
    {
        auto a = new Agent(mock is null ? new MockClient([]) : mock, new ToolRegistry, Policy.init, "sys");
        auto log = new SessionLog(sessions, "mock/m", root, id);
        log.input("in-" ~ id, "the first prompt of " ~ id);
        a.log = some(log);
        return a;
    }
}

void closeLog(Agent a)
{
    import nano.option : ifSome;
    a.log.ifSome((SessionLog l) { l.close(); });
}

// `/name`: validation, the registry claim, persistence across a resume, and
// `--clear` (a cleared handle stays cleared after a resume).
unittest
{
    auto d = Dirs.make("nd-name-persist");
    scope (exit) d.cleanup();
    auto a = d.agent("s-a");
    assert(a.setName("Perf Matrix") !is null, "an invalid handle is refused");
    assert(a.setName("sess-123") !is null, "a handle can't look like a session id");
    assert(a.setName("sess-20261124T000000-abcdef12") !is null, "a full session id is refused as a handle");
    assert(a.name is null);
    assert(a.setName("perf") is null);
    assert(a.name == "perf" && handlePath(d.peers, "perf").exists);
    auto path = buildPath(d.sessions, "s-a.jsonl");
    a.releaseName();
    closeLog(a);
    assert(!handlePath(d.peers, "perf").exists, "releasing drops the claim");

    // A resume restores the handle (and claims it again).
    auto r = restore(path);
    assert(r.name == "perf");
    auto b = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    b.loadRestored(r, some(new SessionLog(path)));
    assert(b.name == "perf" && handlePath(d.peers, "perf").exists);

    // `--clear` survives a resume too.
    assert(b.setName(null) is null && b.name is null);
    assert(!handlePath(d.peers, "perf").exists);
    closeLog(b);
    assert(restore(path).name is null);
}

// Uniqueness: a running session's handle is refused (naming the holder); a
// stopped session's handle is reusable; resolution prefers the running one.
unittest
{
    auto d = Dirs.make("nd-name-unique");
    scope (exit) d.cleanup();
    auto a = d.agent("s-a");
    auto b = d.agent("s-b");
    assert(a.setName("perf") is null);
    auto refused = b.setName("perf");
    assert(refused !is null && refused.canFind("s-a"), refused);
    assert(b.name is null);
    // `a` stops (its log closes without releasing): its claim is stale.
    closeLog(a);
    assert(b.setName("perf") is null, "a stopped session's handle is reusable");
    // Both logs say "perf" now; the running one wins, then the newest.
    auto sessions = cross.listSessions(b.policy, d.sessions, d.root);
    assert(cross.resolve("perf", sessions).id == "s-b");
    // The resume hint falls back to the id: the handle isn't unique on disk.
    assert(resumeArg(d.sessions, "s-b", "perf") == "s-b");
    assert(sessionLine(d.sessions, "s-b", "perf").canFind("perf · s-b"));
    closeLog(b);
}

// The resume hint names the handle when it is unique on disk, and `--resume`
// resolves it (handle first, then id, prefix, title).
unittest
{
    auto d = Dirs.make("nd-name-resume");
    scope (exit) d.cleanup();
    auto a = d.agent("s-only");
    assert(a.setName("nano-engine") is null);
    closeLog(a);
    assert(sessionLine(d.sessions, "s-only", "nano-engine").canFind("--resume=nano-engine"),
        sessionLine(d.sessions, "s-only", "nano-engine"));
    assert(sessionLine(d.sessions, "s-only", null).canFind("--resume=s-only"));
    assert(cross.resolveResumeId(d.sessions, "nano-engine") == "s-only");
    assert(cross.resolveResumeId(d.sessions, "s-on") == "s-only", "a unique id prefix");
    assert(cross.resolveResumeId(d.sessions, "s-only") == "s-only");
    import std.exception : assertThrown;
    assertThrown(cross.resolveResumeId(d.sessions, "nobody"));
}

// `session_send` resolves a handle — beating a session whose title is the
// same word — and the delivered label names the sender by its handle.
unittest
{
    import core.atomic : atomicLoad;
    import nano.control : TurnControl;
    import nano.handle : claim;
    auto d = Dirs.make("nd-ns");
    scope (exit) d.cleanup();
    // A session titled "nano-engine" (its first prompt), stopped.
    {
        auto decoy = new SessionLog(d.sessions, "mock/m", d.root, "sess-decoy");
        decoy.input("in-1", "nano-engine");
        decoy.close();
    }
    // The target: running (its log open), listening, holding the handle.
    auto targetLog = new SessionLog(d.sessions, "mock/m", d.root, "sess-target");
    targetLog.input("in-1", "work on the engine scheduler");
    scope (exit) targetLog.close();
    assert(claim(d.peers, d.sessions, "nano-engine", "sess-target") is null);
    auto control = new shared TurnControl;
    auto router = PeerRouter.make(atomicLoad(control));
    auto listener = PeerListener.listen(d.peers, "sess-target", router.requests);
    scope (exit) listener.close();
    auto pump = TestPump.start(router);
    scope (exit) pump.stop();

    auto mock = new MockClient([
        LLMResponse("", "", [ToolCall.fromRaw("s1", sendTool, `{"to":"nano-engine","text":"here is the diagnostic"}`)]),
        LLMResponse("sent")]);
    auto sender = d.agent("sess-sender", mock);
    scope (exit) closeLog(sender);
    sender.messagesOn = true;
    assert(sender.setName("perf-matrix") is null);
    sender.run("hand this to nano-engine", new NullEvents);
    string result;
    foreach_reverse (m; mock.seen[$ - 1])
        if (m.role == Role.tool) { result = m.content; break; }
    assert(result.canFind("delivered") || result.canFind("awaiting confirmation"), result);
    Inbound inbound;
    assert(router.takeWaiting(inbound), "the handle's holder got it, not the title match");
    assert(inbound.labelled.canFind("[from perf-matrix"), inbound.labelled);
    settle(inbound, true);

    // The history tools' `session` argument resolves the handle the same way.
    auto sessions = cross.listSessions(sender.policy, d.sessions, d.root);
    assert(cross.resolve("nano-engine", sessions).id == "sess-target");
    // sessions_list shows it.
    import std.json : parseJSON;
    assert(cross.listResult(sender.policy, d.sessions, d.root, parseJSON(`{}`)).canFind("[name: nano-engine]"));
    assert(cross.listResult(sender.policy, d.sessions, d.root, parseJSON(`{"filter":"nano-engine"}`))
        .canFind("sess-target"));
}

// Without a session log a handle can be neither claimed nor resumed: refused.
unittest
{
    auto d = Dirs.make("nd-name-nolog");
    scope (exit) d.cleanup();
    auto a = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    assert(a.setName("perf") !is null, "no log: refused");
    assert(!a.name.length);
    assert(a.setName(null) is null, "clearing nothing is fine");
}

// A holder whose log lives in another session directory still blocks the
// claim: the registry records the holder's directory.
unittest
{
    import nano.handle : claim;
    auto d = Dirs.make("nd-name-otherdir");
    scope (exit) d.cleanup();
    auto a = d.agent("s-a");
    assert(a.setName("perf") is null);
    auto other = buildPath(d.root, "other");
    mkdirRecurse(other);
    assert(claim(d.peers, other, "perf", "s-b") !is null, "held by s-a in another dir");
}

// A running holder without a prompt yet (so unlisted) resumes by handle,
// matched case-insensitively.
unittest
{
    auto d = Dirs.make("nd-name-promptless");
    scope (exit) d.cleanup();
    auto a = new Agent(new MockClient([]), new ToolRegistry, Policy.init, "sys");
    a.log = some(new SessionLog(d.sessions, "mock/m", d.root, "s-bare"));
    assert(a.setName("perf") is null);
    assert(cross.resolveResumeId(d.sessions, "PERF") == "s-bare");
    closeLog(a);
}

// A failed log write on rename (set or clear) is reported, not thrown: the
// session goes on, the name is unchanged and the new claim is rolled back.
unittest
{
    import nano.handle : runningHolder;
    auto d = Dirs.make("nd-name-writefail");
    scope (exit) d.cleanup();
    auto a = d.agent("s-wf");
    scope (exit) closeLog(a);
    assert(a.setName("first") is null);
    a.log.ifSome((SessionLog l) { l.failNextWrite = true; });
    auto why = a.setName("second");
    assert(why !is null && why.canFind("can't record the handle"), why);
    assert(a.name == "first");
    assert(runningHolder(d.peers, d.sessions, "second") is null, "the new claim is rolled back");
    assert(runningHolder(d.peers, d.sessions, "first") == "s-wf", "the old claim is kept");
    a.log.ifSome((SessionLog l) { l.failNextWrite = true; });
    why = a.setName(null);
    assert(why !is null && why.canFind("can't record the handle"), why);
    assert(a.name == "first" && runningHolder(d.peers, d.sessions, "first") == "s-wf");
    assert(a.setName("second") is null && a.name == "second", "a retry really retries");
}

// One corrupt, unrelated log in the sessions dir doesn't block a resume by
// exact id or by handle.
unittest
{
    import std.file : write;
    auto d = Dirs.make("nd-name-corrupt");
    scope (exit) d.cleanup();
    auto a = d.agent("sess-good");
    assert(a.setName("keeper") is null);
    closeLog(a);
    write(buildPath(d.sessions, "sess-broken.jsonl.gz"), "not gzip at all");
    assert(cross.resolveResumeId(d.sessions, "sess-good") == "sess-good");
    assert(cross.resolveResumeId(d.sessions, "keeper") == "sess-good");
}

// A legacy handle shaped like another session's id (claimed before such
// handles were refused): resume and the history tools both pick the session
// with that exact id.
unittest
{
    import std.file : write;
    auto d = Dirs.make("nd-name-idshaped");
    scope (exit) d.cleanup();
    auto target = d.agent("sess-target");
    target.setName("tgt");
    closeLog(target);
    auto other = d.agent("sess-other");
    // Forge the legacy claim directly: setName now refuses it.
    import nano.handle : handlePath;
    write(handlePath(d.peers, "sess-target"), "sess-other");
    assert(cross.resolveResumeId(d.sessions, "sess-target") == "sess-target");
    cross.SessionInfo t, o;
    t.id = "sess-target";
    o.id = "sess-other";
    o.name = "sess-target";
    o.live = true;
    auto infos = [o, t];
    assert(cross.resolve("sess-target", infos).id == "sess-target");
    closeLog(other);
}

// A recovery that moves the log to `<id>.recovered-N` moves the handle's
// claim with it: the handle still resolves to the running session and no
// other session can take it.
unittest
{
    import std.file : write;
    import nano.handle : runningHolder;
    import nano.llm : Message;
    auto d = Dirs.make("nd-name-recovered");
    scope (exit) d.cleanup();
    auto a = d.agent("s-a");
    assert(a.setName("perf") is null);
    string warned;
    a.log.ifSome((SessionLog l) {
        l.warn = (string m) { warned ~= m; };
        // A different (non-prefix) file at the path forces a recovery log.
        import std.file : remove;
        remove(l.path);
        write(l.path, "{\"type\":\"session\",\"data\":{\"id\":\"other\"}}\n");
        auto m = Message.user("after");
        l.append(m);
        assert(l.id == "s-a.recovered-1", l.id);
    });
    assert(a.name == "perf");
    assert(runningHolder(d.peers, d.sessions, "perf") == "s-a.recovered-1");
    auto b = d.agent("s-b");
    assert(b.setName("perf") !is null, "the recovered session still holds the handle");
    closeLog(a);
    closeLog(b);
}

// The write of the name record itself recovers the log to a new id: the
// claim moves to that id and the old id holds nothing.
unittest
{
    import std.file : write, remove;
    import nano.handle : runningHolder, handlePath;
    import std.file : readText;
    import std.algorithm : startsWith;
    auto d = Dirs.make("nd-name-recover-on-set");
    scope (exit) d.cleanup();
    auto a = d.agent("s-a");
    a.log.ifSome((SessionLog l) {
        l.warn = (string m) {};
        remove(l.path);
        write(l.path, "{\"type\":\"session\",\"data\":{\"id\":\"other\"}}\n");
    });
    assert(a.setName("perf") is null);
    string id;
    a.log.ifSome((SessionLog l) { id = l.id; });
    assert(id == "s-a.recovered-1", id);
    assert(readText(handlePath(d.peers, "perf")).startsWith(id ~ "\n"), "the claim names the recovered id");
    assert(runningHolder(d.peers, d.sessions, "perf") == id);
    closeLog(a);
}

// `--clear` with no live name (a handle refused on restore) still writes
// the clearing record, so a resume doesn't bring the handle back.
unittest
{
    auto d = Dirs.make("nd-name-clear-refused");
    scope (exit) d.cleanup();
    auto a = d.agent("s-a");
    auto path = buildPath(d.sessions, "s-a.jsonl");
    a.log.ifSome((SessionLog l) { l.name("perf"); });
    assert(a.name is null);
    assert(a.setName(null) is null);
    closeLog(a);
    assert(restore(path).name is null, "the clearing record wins on resume");
}
