/// Inter-session messages at the agent level (issue #272): the `session_send`
/// tool (offered only with `session_messages` on), the loop guard (a
/// peer-started turn can't send unapproved), and delivery into a second
/// in-process session's router.
module nano.agent_peers_test;
@safe:

version (unittest):

import std.algorithm : any, canFind;
import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.control : TurnControl;
import nano.llm;
import nano.option : some, none;
import nano.peers;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.queue : MessageQueue;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;

private:

LLMResponse call(string id, string name, string args) { return LLMResponse("", "", [ToolCall.fromRaw(id, name, args)]); }

string lastToolResult(MockClient mock)
{
    foreach_reverse (m; mock.seen[$ - 1])
        if (m.role == Role.tool) return m.content;
    return null;
}

/// Two sessions in one sessions dir: the agent's own (live) and a target
/// with a listening router. The peers dir is a sibling.
struct TwoSessions
{
    string root, peers;
    Agent agent;
    SessionLog ownLog;
    PeerRouter targetRouter;
    PeerListener targetListener;
    MessageQueue targetQueue;
    TestPump pump;

    static TwoSessions make(string name, MockClient mock)
    {
        import std.process : environment;
        auto t = TwoSessions("", "", null, null, PeerRouter.init, PeerListener.init, MessageQueue.init, TestPump.init);
        t.root = buildPath(tempDir, name);
        mkdirRecurse(buildPath(t.root, "sessions"));
        t.peers = buildPath(t.root, "peers");
        mkdirRecurse(t.peers);
        environment["NANO_CODER_PEERS"] = t.peers;
        auto reg = new ToolRegistry;
        t.agent = new Agent(mock, reg, Policy.init, "sys");
        t.ownLog = new SessionLog(buildPath(t.root, "sessions"), "mock/m", t.root, "sess-sender");
        t.agent.log = some(t.ownLog);
        t.agent.messagesOn = true;
        // The target session, listening.
        auto targetLog = new SessionLog(buildPath(t.root, "sessions"), "mock/m", t.root, "sess-target");
        targetLog.input("in-1", "the target session's first prompt");
        targetLog.close();
        import core.atomic : atomicLoad;
        auto control = new shared TurnControl;
        t.targetRouter = PeerRouter.make(atomicLoad(control));
        t.targetQueue = MessageQueue.make;
        t.targetListener = PeerListener.listen(t.peers, "sess-target", t.targetRouter.requests);
        // The prompt loop's routing pass, so a send is answered while the
        // test thread is blocked in agent.run.
        t.pump = TestPump.start(t.targetRouter);
        return t;
    }

    void cleanup()
    {
        import std.process : environment;
        pump.stop();
        targetListener.close();
        ownLog.close();
        environment.remove("NANO_CODER_PEERS");
        rmdirRecurse(root);
    }
}

// `session_send` delivers to a listening session; the result names the
// outcome; the tool is offered only with `session_messages` on.
unittest
{
    auto mock = new MockClient([
        call("s1", sendTool, `{"to":"sess-target","text":"hello from the sender"}`), LLMResponse("sent")]);
    auto t = TwoSessions.make("nd-ap", mock);
    scope (exit) t.cleanup();
    assert(t.agent.offeredTools.any!(d => d.name == sendTool), "the tool is offered with messages on");
    // Targets are discoverable before local history is: sessions_list rides with messaging.
    assert(t.agent.offeredTools.any!(d => d.name == "sessions_list"), "sessions_list is offered with messages on");

    t.agent.run("send it", new NullEvents);
    auto result = lastToolResult(mock);
    assert(result.canFind("delivered") || result.canFind("awaiting confirmation"), result);

    // The target's router has the message, labelled with the sender.
    Inbound inbound;
    assert(t.targetRouter.takeWaiting(inbound), "the target received it");
    assert(inbound.labelled.canFind("[from session s-sender"), inbound.labelled);
    assert(inbound.labelled.canFind("hello from the sender"), inbound.labelled);
    settle(inbound, true);

    // Setting off: no tool, and a direct call reports the setting.
    t.agent.messagesOn = false;
    assert(!t.agent.offeredTools.any!(d => d.name == sendTool), "no session_send with the setting off");
}

// The loop guard: a turn started by a peer message can't send without
// `confirm: true`; with it, the send goes through (marked for approval).
unittest
{
    auto mock = new MockClient([
        call("s1", sendTool, `{"to":"sess-target","text":"ping-pong?"}`),
        call("s2", sendTool, `{"to":"sess-target","text":"ping-pong?","confirm":true}`),
        LLMResponse("done")]);
    auto t = TwoSessions.make("nd-ap-guard", mock);
    scope (exit) t.cleanup();

    // A peer-started turn (fromPeer: the prompt loop's flag).
    t.agent.run("[from session abcd1234] talk to the target", new NullEvents, true, null, true, "abcd1234-full-id");
    {
        import std.algorithm.searching : any;
        assert(t.agent.messages.any!(m => m.role == Role.user && m.fromSession == "abcd1234-full-id"),
            "a peer input keeps its full sender id");
    }
    // The final request carries both tool results: the refused plain send
    // and the confirm-marked one that went through.
    string[] toolTexts;
    foreach (m; mock.seen[$ - 1])
        if (m.role == Role.tool) toolTexts ~= m.content;
    assert(toolTexts.length == 2, mock.seen[$ - 1].length.stringof);
    assert(toolTexts[0].canFind("loop guard") || toolTexts[0].canFind("started by a peer message"), toolTexts[0]);
    // With confirm the send is allowed; the wire asks the target to confirm.
    assert(toolTexts[1].canFind("delivered") || toolTexts[1].canFind("awaiting confirmation"), toolTexts[1]);
    Inbound inbound;
    assert(t.targetRouter.takeWaiting(inbound), "the confirm-marked message arrived");
    assert(inbound.needsConfirm, "the target's user is asked even with their confirm off");

    // The next plain turn lifts the guard.
    auto mock2 = new MockClient([call("s3", sendTool, `{"to":"sess-target","text":"free to send"}`), LLMResponse("ok")]);
    t.agent.client = mock2;
    t.agent.run("a normal turn", new NullEvents);
    assert(lastToolResult(mock2).canFind("delivered") || lastToolResult(mock2).canFind("awaiting confirmation"),
        lastToolResult(mock2));
}

// A target with messages off (no listener) reports `not running`; an unknown
// session is an error listing how to find ids.
unittest
{
    auto both = LLMResponse("", "", [
        ToolCall.fromRaw("s1", sendTool, `{"to":"sess-target","text":"hi"}`),
        ToolCall.fromRaw("s2", sendTool, `{"to":"sess-nope","text":"hi"}`)]);
    auto mock = new MockClient([both, LLMResponse("done")]);
    auto t = TwoSessions.make("nd-ap-off", mock);
    scope (exit) t.cleanup();
    t.targetListener.close(); // the target turned messages off

    t.agent.run("send both", new NullEvents);
    auto results = mock.seen[$ - 1];
    string[] toolTexts;
    foreach (m; results)
        if (m.role == Role.tool) toolTexts ~= m.content;
    assert(toolTexts.length == 2, mock.seen[$ - 1].length.stringof);
    assert(toolTexts[0].canFind("not running"), toolTexts[0]);
    assert(toolTexts[1].canFind("no session matches"), toolTexts[1]);
}

import std.conv : to;
