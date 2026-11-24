/// The system prompt: the base text, then the environment, project
/// instructions, the skills index, the memory index and the plan-mode note.
module nano.system_prompt;
@safe:

import std.format : format;
import nano.config : Config;
import nano.mode : planPromptNote;
import nano.skills : Skills;

/// The prompt for `cwd` on the date `today` (YYYY-MM-DD); `instructions` and
/// `memoryIndex` are pre-rendered.
string buildSystemPrompt(const ref Config c, string cwd, string today, bool plan, const Skills skills,
    string memoryIndex = null, string instructions = null, string handle = null) pure
{
    auto base = c.systemPrompt.length ? c.systemPrompt : "You are a helpful assistant with access to tools.";
    version (OSX) enum os = "macOS";
    else version (linux) enum os = "Linux";
    else enum os = "unknown";
    auto s = format("%s\n\nWorking directory: %s\nPlatform: %s\nToday's date: %s", base, cwd, os, today);
    // The session's own handle (issue #300), so the agent can introduce
    // itself and other sessions can be told how to reach it.
    if (handle.length)
        s ~= format("\nSession handle: %s (other sessions reach this one with session_send to \"%s\")", handle, handle);
    s ~= instructions;
    s ~= skills.renderIndex;
    s ~= memoryIndex;
    if (plan) s ~= planPromptNote;
    return s;
}

unittest // the session's handle (issue #300) is in the prompt when set
{
    import std.algorithm : canFind;
    import nano.config : Config;
    import nano.skills : Skills;
    Config c;
    auto named = buildSystemPrompt(c, "/w", "2026-01-02", false, new Skills, null, null, "perf-matrix");
    assert(named.canFind("Session handle: perf-matrix"), named);
    assert(!buildSystemPrompt(c, "/w", "2026-01-02", false, new Skills).canFind("Session handle"));
}

// rust: agent.rs::indexes_skills_in_the_system_prompt_and_loads_them_on_request
unittest
{
    import std.algorithm : canFind;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.json : parseJSON;
    import std.path : buildPath;
    import nano.skills : Locations, SkillsConfig;
    auto repo = buildPath(tempDir, "nano-sysprompt-skills");
    if (exists(repo)) rmdirRecurse(repo);
    scope (exit) rmdirRecurse(repo);
    mkdirRecurse(buildPath(repo, ".git"));
    mkdirRecurse(buildPath(repo, ".agents/skills/release"));
    write(buildPath(repo, ".agents/skills/release/SKILL.md"),
        "---\nname: release\ndescription: Cut a release.\n---\nBump the version, then tag it.\n");
    Config c;
    c.systemPrompt = "base";
    SkillsConfig sc;
    auto skills = Skills.discoverIn(repo, sc, Locations.init);
    auto s = buildSystemPrompt(c, repo, "2026-01-02", false, skills);
    assert(s.canFind("- `release`: Cut a release.") && !s.canFind("Bump the version"), s);
    auto loaded = skills.load(parseJSON(`{"name": "release"}`));
    assert(loaded.canFind("Skill: release") && loaded.canFind("Bump the version, then tag it."), loaded);
}

// Root instructions join the prompt; a nested file attaches to the first
// file-tool result under it, once.
// rust: agent.rs::adds_project_instructions_to_the_system_prompt_and_nested_ones_to_file_results
unittest
{
    import std.algorithm : canFind, startsWith;
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.json : JSONValue, parseJSON;
    import std.path : buildPath;
    import nano.agent : Agent, NullEvents;
    import nano.instructions : ProjectInstructions, Options;
    import nano.llm;
    import nano.option : some;
    import nano.permissions : Policy;
    import nano.providers.mock : MockClient;
    import nano.tools : ToolRegistry;
    auto repo = buildPath(tempDir, "nano-sysprompt-instr");
    if (exists(repo)) rmdirRecurse(repo);
    scope (exit) rmdirRecurse(repo);
    mkdirRecurse(buildPath(repo, ".git"));
    mkdirRecurse(buildPath(repo, "pkg"));
    write(buildPath(repo, "AGENTS.md"), "Run make test before committing.");
    write(buildPath(repo, "pkg/AGENTS.md"), "Never edit generated files.");
    Options o;
    o.names = ["AGENTS.md"];
    auto pi = ProjectInstructions.discover(repo, o);
    Config c;
    c.systemPrompt = "base";
    auto sys = buildSystemPrompt(c, repo, "2026-01-02", false, new Skills, null, pi.render);
    assert(sys.startsWith("base") && sys.canFind("Run make test") && !sys.canFind("Never edit"), sys);

    auto file = buildPath(repo, "pkg/lib.rs");
    auto read = (string id) => LLMResponse("", "", [ToolCall.fromRaw(id, "read_file", JSONValue(["path": file]).toString)]);
    auto mock = new MockClient([read("r1"), read("r2"), LLMResponse("done")]);
    auto reg = new ToolRegistry;
    reg.register(ToolDefinition("read_file", "read", parseJSON(`{"type":"object"}`)), (JSONValue a) => "fn main() {}");
    auto agent = new Agent(mock, reg, Policy.init, sys);
    agent.instructions = some(pi);
    agent.run("look", new NullEvents);
    auto last = mock.seen[$ - 1];
    assert(last[3].content.startsWith("fn main() {}") && last[3].content.canFind("Never edit generated files."));
    assert(last[5].content == "fn main() {}", last[5].content);
}
