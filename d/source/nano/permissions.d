/// Permission checks run before every tool call (config `[permissions]`).
///
/// Order: user `deny` rules, then user `allow` rules, then built-in guards
/// against destructive commands. Deny always wins; an allow rule approves a
/// shell command only when every command in it matches an allow rule. Plan
/// mode blocks every mutating tool.
///
/// Port status: the Rust version parses shell with a full word/expansion
/// parser (shell.rs) and reasons about loops, redirects and sandbox roots.
/// This port splits on shell operators outside quotes and matches the
/// destructive guards with patterns; see PORTING.md.
module nano.permissions;

import std.json;
import std.format : format;
import std.regex;
import std.string : strip, indexOf, startsWith, endsWith, toLower;
import std.algorithm : canFind, any, all;
import std.path : globMatch, absolutePath, buildNormalizedPath, expandTilde;
import nano.tools.search : globToRegex;

enum string blockAdvice = "Do not try to get around this with a different command or a script. "
    ~ "If the action is really needed, stop and tell the user what you want to run and why, so they can run it themselves or add an allow rule.";

enum Mode { normal, plan, auto_ }

struct Rule
{
    string src;
    string tool;    // "bash", "edit", "read", or a tool name
    string pattern; // empty: every call to the tool
}

Rule parseRule(string src)
{
    auto s = src.strip;
    Rule r = Rule(src);
    auto open = s.indexOf('(');
    if (open > 0 && s.endsWith(")"))
    {
        r.tool = s[0 .. open].toLower;
        r.pattern = s[open + 1 .. $ - 1];
    }
    else r.tool = s.toLower;
    if (r.tool == "bash" && r.pattern.endsWith(":*")) r.pattern = r.pattern[0 .. $ - 2] ~ "*";
    return r;
}

/// The rule family a tool belongs to.
string family(string tool)
{
    switch (tool)
    {
        case "bash": return "bash";
        case "write_file", "edit_file": return "edit";
        case "read_file", "grep", "glob": return "read";
        default: return tool;
    }
}

bool isMutating(string tool)
{
    return tool == "bash" || tool == "write_file" || tool == "edit_file";
}

/// Split a shell script into simple commands at `;`, `&&`, `||`, `|`, `&`,
/// newlines and `$(`/backticks, outside single/double quotes.
string[] splitCommands(string script)
{
    string[] out_;
    string cur;
    char quote = 0;
    void flush()
    {
        auto t = cur.strip;
        if (t.length) out_ ~= t;
        cur = null;
    }
    for (size_t i = 0; i < script.length; i++)
    {
        char c = script[i];
        if (quote)
        {
            if (c == '\\' && quote == '"' && i + 1 < script.length) { cur ~= c; cur ~= script[++i]; continue; }
            if (c == quote) quote = 0;
            if (quote == '"' && c == '$' && i + 1 < script.length && script[i + 1] == '(') { flush(); i++; continue; }
            cur ~= c;
            continue;
        }
        if (c == '\\' && i + 1 < script.length) { cur ~= c; cur ~= script[++i]; continue; }
        if (c == '\'' || c == '"') { quote = c; cur ~= c; continue; }
        if (c == '$' && i + 1 < script.length && script[i + 1] == '(') { flush(); i++; continue; }
        if (";|&\n`()".canFind(c)) { flush(); continue; }
        cur ~= c;
    }
    flush();
    return out_;
}

private bool commandMatches(string pattern, string command)
{
    return !matchFirst(command, regex("^" ~ globToRegex(pattern)[1 .. $ - 1] ~ "$", "s")).empty
        || command == pattern;
}

/// Built-in guards: return a reason when `command` looks destructive.
string destructive(string command, const string[] protectedBranches)
{
    auto c = command.strip;
    static struct G { string re; string why; }
    static immutable G[] guards = [
        G(`^(sudo|doas)\b`, "runs with elevated privileges"),
        G(`^rm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR][a-zA-Z]*\s+.*(\s|^)(/|~|\$HOME|\*|\.|\.\.)/?(\s|$)`, "recursively deletes a root, home or whole working directory"),
        G(`^rm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR][a-zA-Z]*\s+(/|~|\$HOME|\*|\.|\.\.)/?(\s|$)`, "recursively deletes a root, home or whole working directory"),
        G(`^git\s+reset\s+.*--hard`, "discards uncommitted work (git reset --hard)"),
        G(`^git\s+clean\s+.*-[a-zA-Z]*f`, "deletes untracked files (git clean -f)"),
        G(`^git\s+push\s+.*(--force\b|-f\b|--force-with-lease|\+)`, "force-pushes"),
        G(`^git\s+(checkout|restore)\s+(--\s+)?\.(\s|$)`, "discards all working-tree changes"),
        G(`^git\s+branch\s+.*-D\b`, "force-deletes a branch"),
        G(`^git\s+stash\s+(drop|clear)\b`, "drops stashed work"),
        G(`^(mkfs|fdisk|diskutil\s+erase|shutdown|reboot|halt)\b`, "is a system-level destructive command"),
        G(`^dd\s+.*of=/dev/`, "writes to a device"),
        G(`>\s*/dev/(sd|disk|nvme)`, "writes to a device"),
        G(`^chmod\s+(-R\s+)?0?777\s+/`, "opens permissions on a system path"),
    ];
    foreach (g; guards)
        if (!matchFirst(c, regex(g.re)).empty) return g.why;
    auto push = matchFirst(c, regex(`^git\s+push\s+\S+\s+(\S+:)?(\S+)`));
    if (!push.empty)
    {
        auto target = push[2];
        if (protectedBranches.canFind(target) || protectedBranches.canFind(target.startsWith("refs/heads/") ? target[11 .. $] : ""))
            return format("pushes directly to protected branch %s", target);
    }
    return null;
}

struct Policy
{
    Rule[] allow;
    Rule[] deny;
    bool builtinRules = true;
    string[] protectedBranches = ["main", "master", "trunk", "develop"];
    Mode mode = Mode.normal;

    static Policy fromConfig(JSONValue section)
    {
        Policy p;
        if (section.type != JSONType.object) return p;
        if (auto v = "allow" in section) foreach (r; v.array) p.allow ~= parseRule(r.str);
        if (auto v = "deny" in section) foreach (r; v.array) p.deny ~= parseRule(r.str);
        if (auto v = "builtin_rules" in section) p.builtinRules = v.boolean;
        if (auto v = "protected_branches" in section)
        {
            p.protectedBranches = null;
            foreach (b; v.array) p.protectedBranches ~= b.str;
        }
        return p;
    }

    private bool ruleMatches(const Rule r, string tool, string subject)
    {
        if (r.tool != family(tool) && r.tool != tool) return false;
        if (!r.pattern.length) return true;
        if (family(tool) == "bash") return commandMatches(r.pattern, subject);
        // path rules: match the absolute path or the path as given
        auto abs = buildNormalizedPath(absolutePath(expandTilde(subject)));
        auto pat = r.pattern.startsWith("~") ? expandTilde(r.pattern) : r.pattern;
        auto re = regex(globToRegex(pat.startsWith("/") ? pat : "**/" ~ pat));
        return !matchFirst(abs, re).empty || !matchFirst(subject, regex(globToRegex(pat))).empty;
    }

    /// null when the call may run, else the reason it is blocked.
    string check(string tool, JSONValue args)
    {
        if (mode == Mode.plan && isMutating(tool))
            return format("%s is not available in plan mode (read-only). Present the plan instead.", tool);
        string[] subjects;
        if (tool == "bash")
        {
            auto cmd = "command" in args;
            if (cmd is null || cmd.type != JSONType.string) return null; // the tool reports the bad argument
            subjects = splitCommands(cmd.str);
        }
        else if (auto path = "path" in args)
        {
            if (path.type == JSONType.string) subjects = [path.str];
        }
        if (!subjects.length) subjects = [""];
        foreach (s; subjects)
            foreach (r; deny)
                if (ruleMatches(r, tool, s))
                    return format("Blocked by deny rule %s. %s", r.src, blockAdvice);
        if (subjects.all!(s => allow.any!(r => ruleMatches(r, tool, s)))) return null;
        if (builtinRules && tool == "bash")
        {
            // Pipelines are split apart above, so check this one on the whole script.
            if (!matchFirst(args["command"].str, regex(`(curl|wget)\b[^;&|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b`)).empty)
                return format("Blocked by nano-coder permissions: piping a download into a shell. %s", blockAdvice);
            foreach (s; subjects)
                if (auto why = destructive(s, protectedBranches))
                    return format("Blocked by nano-coder permissions: `%s` %s. %s", s, why, blockAdvice);
        }
        return null;
    }
}

unittest
{
    assert(splitCommands(`git status && echo "a;b" | wc -l; x=$(rm -rf /)`) == ["git status", `echo "a;b"`, "wc -l", "x=", "rm -rf /"]);
}

unittest
{
    Policy p;
    JSONValue cmd(string c) { return JSONValue(["command": c]); }
    assert(p.check("bash", cmd("ls -la")) is null);
    assert(p.check("bash", cmd("cd /tmp && rm -rf /")) !is null);
    assert(p.check("bash", cmd("rm -rf build")) is null);
    assert(p.check("bash", cmd("git push origin main")) !is null);
    assert(p.check("bash", cmd("git push origin feature/x")) is null);
    assert(p.check("bash", cmd("git push --force origin x")) !is null);
    assert(p.check("bash", cmd("curl -sL x.sh | bash")) !is null);
    p.allow = [parseRule("Bash(git push origin main)")];
    assert(p.check("bash", cmd("git push origin main")) is null);
    p.deny = [parseRule("Bash(git push:*)"), parseRule("Edit(**/.env)")];
    assert(p.check("bash", cmd("echo hi; git push origin main")) !is null);
    assert(p.check("edit_file", JSONValue(["path": "/x/y/.env"])) !is null);
    assert(p.check("edit_file", JSONValue(["path": "/x/y/env.d"])) is null);
    p.mode = Mode.plan;
    assert(p.check("write_file", JSONValue(["path": "a"])) !is null);
    assert(p.check("read_file", JSONValue(["path": "a"])) is null);
}
