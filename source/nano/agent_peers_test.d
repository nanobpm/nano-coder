/// Inter-session messages at the agent level (issue #272): the `session_send`
/// tool (offered only with `session_messages` on), the loop guard (hop
/// limit and per-pair rate cap, issue #350), and delivery into a second
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

// The loop guard (issue #350): a peer-started turn's plain reply to a
// confirm-off target is delivered as hop 2; a confirm-on target still asks
// its user; `confirm: true` still asks whatever the target's setting.
unittest
{
    auto mock = new MockClient([
        call("s1", sendTool, `{"to":"sess-target","text":"the answer"}`),
        call("s2", sendTool, `{"to":"sess-target","text":"are you sure?","confirm":true}`),
        LLMResponse("done")]);
    auto t = TwoSessions.make("nd-ap-guard", mock);
    scope (exit) t.cleanup();
    t.targetRouter.confirm(false);

    // A peer-started turn (fromPeer: the prompt loop's flag), hop 1.
    t.agent.run("[from session abcd1234] talk to the target", new NullEvents, true, null, true,
        "abcd1234-full-id", 1, "abcd1234-full-id/msg-1");
    {
        import std.algorithm.searching : any;
        assert(t.agent.messages.any!(m => m.role == Role.user && m.fromSession == "abcd1234-full-id"),
            "a peer input keeps its full sender id");
    }
    string[] toolTexts;
    foreach (m; mock.seen[$ - 1])
        if (m.role == Role.tool) toolTexts ~= m.content;
    assert(toolTexts.length == 2, mock.seen[$ - 1].length.stringof);
    assert(toolTexts[0].canFind("delivered"), toolTexts[0]);
    assert(toolTexts[1].canFind("delivered") || toolTexts[1].canFind("awaiting confirmation"), toolTexts[1]);
    Inbound plain, asked;
    assert(t.targetRouter.takeWaiting(plain), "the plain reply arrived");
    assert(!plain.needsConfirm && plain.pm.hop == 2, "a reply is hop 2, unconfirmed");
    assert(plain.pm.thread == "abcd1234-full-id/msg-1", plain.pm.thread);
    assert(t.targetRouter.takeWaiting(asked), "the confirm-marked message arrived");
    assert(asked.needsConfirm, "the target's user is asked even with their confirm off");
    settle(plain, true);
    settle(asked, true);

    // A confirm-on target still asks its user for a peer turn's reply.
    t.targetRouter.confirm(true);
    auto mock2 = new MockClient([call("s3", sendTool, `{"to":"sess-target","text":"again"}`), LLMResponse("ok")]);
    t.agent.client = mock2;
    t.agent.run("[from session abcd1234] more", new NullEvents, true, null, true, "abcd1234-full-id", 1);
    assert(lastToolResult(mock2).canFind("awaiting confirmation"), lastToolResult(mock2));
    Inbound third;
    assert(t.targetRouter.takeWaiting(third) && third.needsConfirm);
    settle(third, false);

    // A user-started turn sends hop 1 and opens its own thread.
    t.targetRouter.confirm(false);
    auto mock3 = new MockClient([call("s4", sendTool, `{"to":"sess-target","text":"fresh"}`), LLMResponse("ok")]);
    t.agent.client = mock3;
    t.agent.run("a normal turn", new NullEvents);
    assert(lastToolResult(mock3).canFind("delivered"), lastToolResult(mock3));
    Inbound fresh;
    assert(t.targetRouter.takeWaiting(fresh) && fresh.pm.hop == 1 && fresh.pm.thread.canFind("sess-sender/"),
        fresh.pm.thread);
    settle(fresh, true);
}

// The hop limit (issue #350): a turn started by a hop-4 message can't send
// hop 5 (default limit 4); nothing reaches the target.
unittest
{
    auto mock = new MockClient([call("s1", sendTool, `{"to":"sess-target","text":"hop five"}`), LLMResponse("done")]);
    auto t = TwoSessions.make("nd-ap-hops", mock);
    scope (exit) t.cleanup();
    t.targetRouter.confirm(false);
    t.agent.run("[from session abcd1234] reply", new NullEvents, true, null, true, "abcd1234-full-id", 4, "th");
    auto result = lastToolResult(mock);
    assert(result.canFind("thread hop limit reached") && result.canFind("ask your user"), result);
    Inbound none_;
    assert(!t.targetRouter.takeWaiting(none_), "a refused send never reaches the target");
}

// The per-pair rate cap (issue #350): the 11th send to one target within an
// hour is refused; an hour later it goes through. Times are fake stdTime.
unittest
{
    enum long minute = 60L * 10_000_000L;
    long[][string] sent;
    long now = 1_000_000 * minute;
    foreach (i; 0 .. 10)
    {
        assert(Agent.rateRefusal(sent, "b", now, 10) is null);
        sent["b"] ~= now;
        now += minute;
    }
    auto why = Agent.rateRefusal(sent, "b", now, 10);
    assert(why.canFind("rate limit reached") && why.canFind("10 messages"), why);
    // Another target is capped separately; 0 means no cap.
    assert(Agent.rateRefusal(sent, "c", now, 10) is null);
    assert(Agent.rateRefusal(sent, "b", now, 0) is null);
    // An hour after the first send, its slot frees.
    now = 1_000_000 * minute + 60 * minute;
    assert(Agent.rateRefusal(sent, "b", now, 10) is null);
    assert(sent["b"].length == 9);
    // Stale targets are pruned: the map stays bounded.
    assert(Agent.rateRefusal(sent, "z", now + 120 * minute, 10) is null);
    assert(sent.length == 0);
    // Hops: user turns send hop 1; a peer turn one more than its input
    // (an older sender's message without a hop counts as hop 1).
    assert(Agent.sendHop(false, 0) == 1 && Agent.sendHop(true, 1) == 2 && Agent.sendHop(true, 0) == 2);
    assert(Agent.hopRefusal(4, 4) is null && Agent.hopRefusal(5, 4) !is null);
}

// The rate cap in the tool: with a cap of 1 the second send to the same
// target is refused.
unittest
{
    auto both = LLMResponse("", "", [
        ToolCall.fromRaw("s1", sendTool, `{"to":"sess-target","text":"one"}`),
        ToolCall.fromRaw("s2", sendTool, `{"to":"sess-target","text":"two"}`)]);
    auto mock = new MockClient([both, LLMResponse("done")]);
    auto t = TwoSessions.make("nd-ap-rate", mock);
    scope (exit) t.cleanup();
    t.targetRouter.confirm(false);
    t.agent.maxSendsPerHour = 1;
    t.agent.run("send twice", new NullEvents);
    string[] toolTexts;
    foreach (m; mock.seen[$ - 1])
        if (m.role == Role.tool) toolTexts ~= m.content;
    assert(toolTexts.length == 2);
    assert(toolTexts[0].canFind("delivered"), toolTexts[0]);
    assert(toolTexts[1].canFind("rate limit reached"), toolTexts[1]);
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

// Resuming an interrupted peer-input turn (its id redelivered with no
// sender) re-arms the loop guard and restores the full sender id from the
// persisted message; the hop isn't persisted, so its reply is hop 2.
unittest
{
    import nano.session : PendingInput;
    auto mock = new MockClient([call("s1", sendTool, `{"to":"sess-target","text":"pong"}`), LLMResponse("done")]);
    auto t = TwoSessions.make("nd-ap-resume", mock);
    scope (exit) t.cleanup();
    auto um = Message.user("[from session abcd1234] talk to the target");
    um.fromSession = "abcd1234-full-id";
    t.agent.messages ~= um;
    t.agent.hasPending = true;
    t.agent.pending = PendingInput("in-peer", um.content, t.agent.messages.length - 1);

    t.agent.run(um.content, new NullEvents, true, "in-peer");
    assert(t.agent.peerTurn, "the resumed peer turn keeps the loop guard");
    assert(t.agent.inputSender == "abcd1234-full-id", t.agent.inputSender);
    auto result = lastToolResult(mock);
    assert(result.canFind("delivered") || result.canFind("awaiting confirmation"), result);
    Inbound inbound;
    assert(t.targetRouter.takeWaiting(inbound) && inbound.pm.hop == 2);
    settle(inbound, true);
}
