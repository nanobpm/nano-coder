/// The `/settings` dialog driven by a scripted UI: the sub-agent and
/// inter-session message rows (issue #327) and their save output.
module nano.settings_dialog_test;
@safe:

version (unittest):

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.path : buildPath;
import nano.agent : Agent;
import nano.config : Config, ProviderConfig, ProviderKind, SubagentModel;
import nano.option : notNull;
import nano.permissions : Policy;
import nano.providers.mock : MockClient;
import nano.settings_dialog;
import nano.tools : ToolRegistry;

/// Answers prompts from a script: a select takes an index, an input the
/// text; "esc" is Esc. Every prompt and line is recorded.
private final class ScriptedUi : SettingsUi
{
    string[] script, said, prompts;
    this(string[] script) { this.script = script; }
    private string next(string prompt)
    {
        prompts ~= prompt;
        assert(script.length, "script ran out at: " ~ prompt);
        auto s = script[0];
        script = script[1 .. $];
        return s;
    }
    ptrdiff_t select(string prompt, const string[] labels, size_t initial)
    {
        auto s = next(prompt);
        if (s == "esc") return -1;
        auto i = s.to!ptrdiff_t;
        assert(i < labels.length, prompt);
        return i;
    }
    string input(string prompt, string initial)
    {
        auto s = next(prompt);
        return s == "esc" ? null : s;
    }
    string secret(string prompt) { return input(prompt, null); }
    void say(string line) { said ~= line; }
}

private string scratch(string name)
{
    auto d = buildPath(tempDir, "nano-d-settings-dialog-" ~ name);
    if (d.exists) rmdirRecurse(d);
    mkdirRecurse(d);
    return d;
}

/// A host over `cfg` whose command delegates record their arguments and
/// switch state as `/subagents` and `/messages` would.
private struct Fixture
{
    Config cfg;
    Agent agent;
    string[] subCalls, msgCalls;
    size_t reconfigured;
    bool msgOn, msgConfirm = true;
}

/// A host over `f.cfg` whose command delegates record their arguments.
private SettingsHost host(Fixture* f, string path)
{
    f.agent = new Agent(new MockClient(null), new ToolRegistry, Policy.init, "system");
    auto h = SettingsHost(&f.cfg, notNull(f.agent));
    h.configPath = path;
    h.recents = () => ["work/fast", "work/slow"];
    h.subagentsCommand = (string arg) {
        f.subCalls ~= arg;
        f.agent.subagentsOn = arg == "on";
        return "Sub-agents " ~ arg;
    };
    h.reconfigureSubagents = () { f.reconfigured++; };
    h.messagesCommand = (string arg) {
        f.msgCalls ~= arg;
        if (arg == "on") f.msgOn = true;
        else if (arg == "off") f.msgOn = false;
        else f.msgConfirm = arg == "confirm on";
        return "Messages " ~ arg;
    };
    h.messagesOn = () => f.msgOn;
    h.messagesConfirm = () => f.msgConfirm;
    return h;
}

unittest
{
    // Sub-agents on/off goes through the command; a refused switch is not saved.
    auto dir = scratch("toggle");
    auto path = buildPath(dir, "config.toml");
    auto f = new Fixture;
    auto h = host(f, path);
    f.agent.subagentsOn = false;
    // main: Sub-agents(9) → Enabled(0) → Yes(0) → Back(7) → Save(11) → Done(12)
    runSettings(new ScriptedUi(["9", "0", "0", "7", "11", "12"]), h);
    assert(f.subCalls == ["on"] && f.agent.subagentsOn && f.cfg.subagents);
    assert(readText(path).canFind("subagents = true"), readText(path));

    // A session where the switch fails: no change recorded, nothing to save.
    auto g = new Fixture;
    auto h2 = host(g, buildPath(dir, "other.toml"));
    h2.subagentsCommand = (string arg) { g.subCalls ~= arg; return "not available"; };
    g.agent.subagentsOn = false;
    runSettings(new ScriptedUi(["9", "0", "0", "7", "12"]), h2);
    assert(g.subCalls == ["on"] && g.cfg.subagents && !exists(buildPath(dir, "other.toml")));
    rmdirRecurse(dir);
}

unittest
{
    // Limits reject values below 1, then save and reconfigure.
    auto dir = scratch("limits");
    auto path = buildPath(dir, "config.toml");
    auto f = new Fixture;
    auto h = host(f, path);
    auto ui = new ScriptedUi(["9", "2", "0", "x", "3", "7", "11", "12"]);
    runSettings(ui, h);
    assert(ui.said.canFind("enter a whole number of at least 1"), ui.said.to!string);
    assert(f.cfg.subagentMaxConcurrency == 3 && f.reconfigured == 1);
    auto t = readText(path);
    assert(t.canFind("subagent_max_concurrency = 3") && t.canFind("subagent_max_tokens = "), t);
    auto c = Config.load(path);
    assert(c.subagentMaxConcurrency == 3, t);
    rmdirRecurse(dir);
}

unittest
{
    // Candidates: edit keeps the model, remove drops it; both reconfigure and save.
    auto dir = scratch("candidates");
    auto path = buildPath(dir, "config.toml");
    write(path, "[[subagent_models]]\nmodel = \"a/x\"\n\n[[subagent_models]]\nmodel = \"b/y\"\n");
    auto f = new Fixture;
    f.cfg.subagentModels = [SubagentModel("a/x", "", 0, 0, 0), SubagentModel("b/y", "", 0, 0, 0)];
    auto h = host(f, path);
    // Sub-agents → Candidates(6) → a/x(0) → Edit(0) → Keep(0) → use, 5, 0, 0
    // → b/y(1) → Remove(1) → Back(1) → Back(7) → Save → Done
    runSettings(new ScriptedUi(["9", "6", "0", "0", "0", "quick", "5", "0", "0", "1", "1", "2", "7", "11", "12"]), h);
    assert(f.reconfigured == 1 && f.cfg.subagentModels == [SubagentModel("a/x", "quick", 5, 0, 0)]);
    auto c = Config.load(path);
    assert(c.subagentModels == [SubagentModel("a/x", "quick", 5, 0, 0)], readText(path));
    rmdirRecurse(dir);
}

unittest
{
    // Messages: on and confirm go through the command; a refused switch is not saved.
    auto dir = scratch("messages");
    auto path = buildPath(dir, "config.toml");
    auto f = new Fixture;
    auto h = host(f, path);
    // Messages(10) → Enabled(0) → Yes → Confirm(1) → No(1) → Back(2) → Save → Done
    runSettings(new ScriptedUi(["10", "0", "0", "1", "1", "2", "11", "12"]), h);
    assert(f.msgCalls == ["on", "confirm off"] && f.cfg.sessionMessages && !f.cfg.sessionMessagesConfirm);
    auto t = readText(path);
    assert(t.canFind("session_messages = true") && t.canFind("session_messages_confirm = false"), t);

    auto g = new Fixture;
    auto h2 = host(g, buildPath(dir, "other.toml"));
    h2.messagesCommand = (string arg) { g.msgCalls ~= arg; return "refused"; };
    runSettings(new ScriptedUi(["10", "0", "0", "1", "1", "2", "12"]), h2);
    assert(g.msgCalls == ["on", "confirm off"] && !exists(buildPath(dir, "other.toml")));
    rmdirRecurse(dir);
}

unittest
{
    // Esc at each on/off prompt leaves the setting alone (it is not "No").
    auto f = new Fixture;
    auto h = host(f, buildPath(scratch("esc"), "config.toml"));
    f.agent.subagentsOn = true;
    f.msgOn = true;
    // Sub-agents → Enabled → Esc → Back; Messages → Enabled → Esc → Confirm → Esc → Back; Done
    runSettings(new ScriptedUi(["9", "0", "esc", "7", "10", "0", "esc", "1", "esc", "2", "12"]), h);
    assert(f.subCalls.length == 0 && f.msgCalls.length == 0, f.msgCalls.to!string);
    assert(f.agent.subagentsOn && f.msgOn && f.msgConfirm);
}

unittest
{
    // Header-like lines inside multi-line values are text, not tables, and
    // quoted `[["subagent_models"]]` headers are the same table.
    import nano.settings : replaceSubagentModels;
    auto doc = "system_prompt = \"\"\"\nhi\n[[subagent_models]]\n\"\"\"\n\n[[subagent_models]]\nmodel = \"a/x\"\n"
        ~ "use = '''\n[tests]\n'''\n\n[tests]\nfast = 1\n\n[[\"subagent_models\"]]\nmodel = \"b/y\"\n\n"
        ~ "[[ 'subagent_models' ]]\nmodel = \"c/z\"\n";
    auto res = replaceSubagentModels(doc, [SubagentModel("d/w", "", 0, 0, 0)]);
    assert(res == "system_prompt = \"\"\"\nhi\n[[subagent_models]]\n\"\"\"\n\n\n[tests]\nfast = 1\n\n"
        ~ "[[subagent_models]]\nmodel = \"d/w\"\n", res);
    import nano.toml : parseToml;
    import nano.result : unwrap;
    auto v = parseToml(res).unwrap("valid TOML");
    assert(v["subagent_models"].arrayNoRef.length == 1 && v["tests"]["fast"].integer == 1);
    assert(v["system_prompt"].str.canFind("[[subagent_models]]"));
}
