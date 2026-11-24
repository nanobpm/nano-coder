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
