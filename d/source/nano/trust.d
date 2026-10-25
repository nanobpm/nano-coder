/// Per-repository trust: what a cloned repository can inject into the agent
/// (its skills, its skill lock and its `.claude/settings*.json` hooks) loads
/// only once the user has trusted that repository. `--yolo` and `--acp` trust
/// without asking; an interactive start asks once and remembers a yes.
module nano.trust;

@safe:

import std.algorithm : canFind, any;
import std.array : array;
import std.file : exists, isDir, readText, append, mkdirRecurse, dirEntries, SpanMode;
import std.path : buildPath, dirName, expandTilde;
import std.process : environment;
import std.string : splitLines, strip, toLower;

/// Where trusted repository roots are kept, one canonical path per line.
string trustFile()
{
    if (auto x = environment.get("NANO_CODER_TRUST_FILE")) return x;
    if (auto x = environment.get("XDG_CONFIG_HOME")) return buildPath(x, "nano-coder", "trusted-projects");
    return buildPath(expandTilde("~"), ".config", "nano-coder", "trusted-projects");
}

/// The directory trust is granted for: the repository root (or `cwd` itself).
string trustRoot(string cwd)
{
    import nano.skills : canonical, gitRoot;
    auto c = canonical(cwd);
    if (c is null) c = cwd;
    auto r = gitRoot(c);
    return r !is null ? (canonical(r) is null ? r : canonical(r)) : c;
}

bool isTrusted(string root, string file)
{
    if (!exists(file)) return false;
    try return readText(file).splitLines.canFind!(l => l.strip == root);
    catch (Exception) return false;
}

void remember(string root, string file)
{
    if (isTrusted(root, file)) return;
    mkdirRecurse(dirName(file));
    append(file, root ~ "\n");
}

/// Whether the repository carries anything trust gates: hooks in
/// `.claude/settings{,.local}.json`, a skill lock, or a skill under one of
/// the configured workspace skill directories.
string[] projectResources(string root, const string[] skillDirs)
{
    string[] found;
    foreach (f; [".claude/settings.json", ".claude/settings.local.json", "ai.lock"])
        if (exists(buildPath(root, f))) found ~= f;
    foreach (d; skillDirs)
    {
        auto p = buildPath(root, d);
        try
            if (exists(p) && isDir(p) && dirEntries(p, "SKILL.md", SpanMode.depth).any)
                found ~= d;
        catch (Exception) {}
    }
    return found;
}

/// How a start decides trust.
enum TrustMode { ask, yolo, deny }

/// Decide trust for `root`. `ask` prompts via `prompt` (which returns the
/// user's answer line, or null at EOF) only when the repository has
/// something to gate and isn't trusted yet; a yes is remembered.
bool decideTrust(string root, const string[] resources, TrustMode mode, string file,
    string delegate(string question) @safe prompt)
{
    if (mode == TrustMode.yolo || !resources.length || isTrusted(root, file)) return true;
    if (mode == TrustMode.deny || prompt is null) return false;
    import std.array : join;
    auto answer = prompt("Trust this repo? " ~ root ~ " has " ~ resources.join(", ")
        ~ " that can run commands or steer the agent.\nLoad its skills and hooks? [y/N] ");
    if (answer is null || !["y", "yes"].canFind(answer.strip.toLower)) return false;
    try remember(root, file);
    catch (Exception) {}
    return true;
}

unittest
{
    import std.file : tempDir, write, rmdirRecurse, remove;
    auto root = buildPath(tempDir, "nano-d-trust");
    if (root.exists) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, ".agents/skills/x"));
    scope (exit) rmdirRecurse(root);
    auto file = buildPath(root, "trusted");
    assert(projectResources(root, [".agents/skills"]) is null, "an empty skills dir needs no trust");
    write(buildPath(root, ".agents/skills/x/SKILL.md"), "---\nname: x\n---\n");
    mkdirRecurse(buildPath(root, ".claude"));
    write(buildPath(root, ".claude/settings.json"), "{}");
    auto res = projectResources(root, [".agents/skills"]);
    assert(res == [".claude/settings.json", ".agents/skills"], res[0]);

    int asked;
    string delegate(string) @safe say(string a) { return (string q) { asked++; assert(q.canFind("Trust this repo?")); return a; }; }
    assert(decideTrust(root, null, TrustMode.ask, file, say("n")) && asked == 0, "nothing to gate: no question");
    assert(decideTrust(root, res, TrustMode.yolo, file, say("n")) && asked == 0);
    assert(!decideTrust(root, res, TrustMode.deny, file, say("y")) && asked == 0);
    assert(!decideTrust(root, res, TrustMode.ask, file, null), "no terminal: untrusted");
    assert(!decideTrust(root, res, TrustMode.ask, file, say("")) && asked == 1, "the default is no");
    assert(!decideTrust(root, res, TrustMode.ask, file, delegate string(string q) => null), "EOF is no");
    assert(!isTrusted(root, file));
    assert(decideTrust(root, res, TrustMode.ask, file, say(" Yes\n")) && asked == 2);
    assert(isTrusted(root, file), "a yes is remembered");
    assert(decideTrust(root, res, TrustMode.ask, file, say("n")) && asked == 2, "remembered: no question");
    assert(decideTrust(root, res, TrustMode.deny, file, null), "remembered trust holds without a terminal");
    remember(root, file);
    assert(readText(file) == root ~ "\n", "remembered once");
}
