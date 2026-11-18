/// Memory as a session offers it (agent.rs tests): which tools each mode
/// offers, read-only and plan-mode refusals, and a save carried into the
/// next session's index.
module nano.agent_memory_test;
@safe:

version (unittest):

import std.algorithm : any, canFind, map;
import std.array : array;
import std.file : exists, mkdirRecurse, read, readText, rmdirRecurse, tempDir;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import nano.agent;
import nano.llm;
import nano.memory;
import nano.mode : AgentMode;
import nano.option : some, unwrap;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.session : SessionLog;
import nano.tools : ToolRegistry;

private:

string freshDir(string name)
{
    auto dir = buildPath(tempDir, "nano-d-agent-memory-" ~ name);
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

/// An agent whose memory tools are wired as the REPL wires them, for a
/// session where memory is `mode`.
Agent memoryAgent(MemoryMode mode, LLMResponse[] script, string dir, out Store store)
{
    auto reg = new ToolRegistry;
    Agent agent;
    if (mode != MemoryMode.off)
    {
        store = new Store(buildPath(dir, "memory"), "proj", 0);
        foreach (t; sessionTools(store, mode == MemoryMode.on, () => agent.control.mode == AgentMode.plan,
                () => "session-1"))
            reg.register(t.definition, t.handler);
        agent = new Agent(new MockClient(script), reg, Policy.init, "system");
        agent.memory = some(store);
    }
    else agent = new Agent(new MockClient(script), reg, Policy.init, "system");
    return agent;
}

LLMResponse call(string name, string args)
{
    return LLMResponse("", "", [ToolCall.fromRaw("m1", name, args)]);
}

string[] names(Agent agent) { return agent.offeredTools.map!(d => d.name).array; }

bool stored(Store store) { return store.path(Scope.user).exists && readText(store.path(Scope.user)).length > 0; }

// rust: agent.rs::read_only_memory_refuses_a_save
unittest
{
    auto dir = freshDir("ro-save");
    scope (exit) rmdirRecurse(dir);
    Store store;
    auto agent = memoryAgent(MemoryMode.readOnly,
        [call(saveTool, `{"scope":"user","text":"should not persist"}`), LLMResponse("ok")], dir, store);
    agent.run("try to save", new NullEvents);
    assert(!stored(store), "read-only did not persist the save");
}

// rust: agent.rs::configured_read_only_memory_search_does_not_mutate_the_store
unittest
{
    auto dir = freshDir("ro-search");
    scope (exit) rmdirRecurse(dir);
    Store store;
    auto agent = memoryAgent(MemoryMode.readOnly, [], dir, store);
    store.saveWith(Scope.user, "the deploy command is make ship", null, null, null, null, false);
    auto before = read(store.path(Scope.user));
    auto out_ = agent.tools.execute(searchTool, parseJSON(`{"pattern":"deploy"}`));
    assert(out_.canFind("make ship"), out_);
    assert(read(store.path(Scope.user)) == before, "a read-only search leaves the store byte-for-byte unchanged");
}

// rust: agent.rs::memory_save_persists_and_surfaces_in_the_prompt
unittest
{
    auto dir = freshDir("save");
    scope (exit) rmdirRecurse(dir);
    Store store;
    auto agent = memoryAgent(MemoryMode.on,
        [call(saveTool, `{"scope":"user","text":"python comes from uv"}`), LLMResponse("done")], dir, store);
    agent.log = some(new SessionLog(buildPath(dir, "sessions"), "mock/m", "/w"));
    assert(agent.run("remember that", new NullEvents) == "done");
    assert(readText(agent.log.unwrap("set above").path).canFind("remembered (user"), "the transcript records the save");
    Store later;
    memoryAgent(MemoryMode.on, [], dir, later);
    assert(later.index(true).canFind("python comes from uv"), "the index carries into the next session");
}

// rust: agent.rs::memory_tools_track_the_configured_mode
unittest
{
    auto dir = freshDir("modes");
    scope (exit) rmdirRecurse(dir);
    Store store;
    auto on = names(memoryAgent(MemoryMode.on, [], dir, store));
    foreach (t; [saveTool, searchTool, forgetTool]) assert(on.canFind(t), t);
    auto ro = names(memoryAgent(MemoryMode.readOnly, [], dir, store));
    assert(ro.canFind(searchTool) && !ro.canFind(saveTool) && !ro.canFind(forgetTool), "read-only hides save");
    Store none;
    auto off = memoryAgent(MemoryMode.off, [], dir, none);
    assert(!names(off).any!(n => isMemoryTool(n)), "off offers no memory tools");
    assert(off.memory.isNone);
}

// rust: agent.rs::plan_mode_blocks_a_memory_mutation_that_reached_the_handler
unittest
{
    auto dir = freshDir("plan-handler");
    scope (exit) rmdirRecurse(dir);
    Store store;
    auto agent = memoryAgent(MemoryMode.on, [], dir, store);
    agent.control.mode = AgentMode.plan;
    scope (exit) agent.control.mode = AgentMode.normal;
    string err;
    try agent.tools.execute(saveTool, parseJSON(`{"scope":"user","text":"should not persist"}`));
    catch (Exception e) err = e.msg;
    assert(err.canFind("plan mode"), err);
    assert(!stored(store), "plan mode did not persist the save");
    agent.tools.execute(searchTool, parseJSON(`{"pattern":"anything"}`));
}

// Plan mode hides save from the tools and from the index guidance (the
// REPL renders the index with `writable && !plan`).
// rust: agent.rs::plan_mode_drops_save_from_tools_and_index_guidance
unittest
{
    auto dir = freshDir("plan-index");
    scope (exit) rmdirRecurse(dir);
    Store store;
    auto agent = memoryAgent(MemoryMode.on, [], dir, store);
    store.saveWith(Scope.user, "a durable fact", null, null, null, null, false);
    assert(store.index(true).canFind(saveTool) && names(agent).canFind(saveTool));
    agent.control.mode = AgentMode.plan;
    scope (exit) agent.control.mode = AgentMode.normal;
    auto planIndex = store.index(false);
    assert(!planIndex.canFind(saveTool) && planIndex.canFind(searchTool), planIndex);
    assert(!names(agent).canFind(saveTool), "plan mode hides the save tool");
}
