/// Permission checks run before every tool call (config `[permissions]`).
/// Port of src/permissions.rs.
///
/// Order: user `deny` rules, then user `allow` rules, then the built-in
/// guards against destructive commands. Deny always wins; an allow rule
/// approves a shell command only when every command in it matches an allow
/// rule. Plan mode (an agent-level gate) blocks every mutating tool.
///
/// These checks catch mistakes, not adversaries: a model can still write a
/// script and run it. The Rust build also holds file writes to the OS
/// sandbox's writable roots; the D port has no sandbox yet (PORTING.md).
///
/// Shell commands are parsed by nano.shell, normalized by nano.cmdexpand
/// (wrappers stripped, nested scripts and loops inspected) and judged by
/// nano.guard. Errors keep the Rust wording.
module nano.permissions;

@safe:

import std.json;
import std.format : format;
import std.regex : regex, matchFirst, Regex;
import std.string : strip, indexOf, toLower;
import std.algorithm : canFind, any, all, startsWith, endsWith, filter;
import std.array : array;
import nano.shell : parse, Simple;
import nano.cmdexpand;
import nano.guard;
import nano.paths;

enum string blockAdvice = "Do not try to get around this with a different command or a script. "
    ~ "If the action is really needed, stop and tell the user what you want to run and why, so they can run it "
    ~ "themselves or add an allow rule.";

enum Mode { normal, plan, auto_ }

/// A malformed permission rule.
class RuleError : Exception
{
    this(string msg) pure nothrow { super(msg); }
}

enum Subject
{
    /// `Bash(...)`: matched against each command and the whole command line.
    command,
    /// `Read(...)` / `Edit(...)`: matched against the path argument.
    path,
    /// Any other tool name: matched against its JSON arguments.
    arguments,
}

struct Rule
{
    string source;
    string[] tools;
    Subject subject;
    /// null: every call to the tool.
    string patternSource;
    Regex!char pattern;

    bool appliesTo(string tool) const { return tools.canFind(tool); }

    bool matches(string text) const @trusted
    {
        return patternSource is null || !matchFirst(text, cast() pattern).empty;
    }
}

private string quoted(string s) { return JSONValue(s).toString; }

/// Parse a rule like `Bash(git push *)`, `Read(**/.env)` or `write_file`.
Rule parseRule(string src)
{
    auto source = src.strip;
    string name, pattern;
    bool hasPattern = false;
    auto open = source.indexOf('(');
    if (open >= 0)
    {
        if (!source.endsWith(")"))
            throw new RuleError(format("permission rule %s is missing its closing )", quoted(source)));
        name = source[0 .. open];
        pattern = source[open + 1 .. $ - 1];
        hasPattern = true;
    }
    else name = source;
    name = name.strip;
    if (!name.length) throw new RuleError(format("permission rule %s has no tool name", quoted(source)));
    Rule r;
    r.source = source;
    switch (name.toLower)
    {
    case "bash", "shell": r.tools = ["bash"]; r.subject = Subject.command; break;
    case "read", "read_file": r.tools = ["read_file", "grep", "glob"]; r.subject = Subject.path; break;
    case "grep": r.tools = ["grep"]; r.subject = Subject.arguments; break;
    case "glob": r.tools = ["glob"]; r.subject = Subject.arguments; break;
    case "edit", "write", "edit_file", "write_file": r.tools = ["write_file", "edit_file"]; r.subject = Subject.path; break;
    default: r.tools = [name]; r.subject = Subject.arguments;
    }
    auto p = pattern.strip;
    if (hasPattern && p.length && p != "*" && p != "**")
    {
        r.patternSource = r.subject == Subject.path ? pathGlob(p) : commandGlob(p);
        try r.pattern = regex(r.patternSource, "s");
        catch (Exception e) throw new RuleError(format("bad pattern %s: %s", quoted(p), e.msg));
    }
    return r;
}

private string escapeChar(dchar c)
{
    import std.conv : to;
    if (`\.+*?()|[]{}^$`.canFind(c)) return "\\" ~ c.to!string;
    return c.to!string;
}

/// `*` matches anything (including spaces and `/`); a trailing `:*` matches
/// the prefix alone or followed by arguments (`npm run test:*`).
string commandGlob(string pattern)
{
    bool prefix = pattern.endsWith(":*");
    auto body = prefix ? pattern[0 .. $ - 2] : pattern;
    string re = "^";
    foreach (dchar c; body)
        re ~= c == '*' ? ".*" : c == '?' ? "." : escapeChar(c);
    if (prefix) re ~= "(?: .*)?";
    return re ~ "$";
}

/// `**` crosses directories, `*` and `?` do not. `~/` is the home directory.
string pathGlob(string pattern)
{
    import std.conv : to;
    auto home = homeDir();
    if (pattern.startsWith("~/") && home !is null) pattern = home ~ "/" ~ pattern[2 .. $];
    auto chars = pattern.to!(dchar[]);
    string re = "^";
    size_t i = 0;
    while (i < chars.length)
    {
        if (chars[i] == '*' && i + 1 < chars.length && chars[i + 1] == '*')
        {
            if (i + 2 < chars.length && chars[i + 2] == '/') { re ~= "(?:.*/)?"; i += 3; }
            else { re ~= ".*"; i += 2; }
            continue;
        }
        re ~= chars[i] == '*' ? "[^/]*" : chars[i] == '?' ? "[^/]" : escapeChar(chars[i]);
        ++i;
    }
    return re ~ "$";
}

private bool pathRuleMatches(const Rule rule, string absolute, string cwd)
{
    if (rule.patternSource is null) return true;
    if (rule.matches(absolute)) return true;
    if (startsWithPath(absolute, cwd))
    {
        auto rel = fromComponents(components(absolute)[components(cwd).length .. $]);
        return rule.matches(rel);
    }
    return false;
}

/// Whether a permission-style rule string matches a tool call (hook `if`
/// filters). False when the rule fails to parse or does not apply.
bool ruleMatches(string ruleSrc, string tool, JSONValue args)
{
    Rule rule;
    try rule = parseRule(ruleSrc);
    catch (RuleError) return false;
    if (!rule.appliesTo(tool)) return false;
    auto cwd = currentDir();
    final switch (rule.subject)
    {
    case Subject.command:
        auto c = stringArg(args, "command");
        if (c is null) return false;
        if (rule.matches(c.strip)) return true;
        try
        {
            foreach (cmd; expandAll(parse(c)))
                if (rule.matches(commandText(cmd))) return true;
        }
        catch (Exception) {}
        return false;
    case Subject.path:
        auto path = stringArg(args, "path");
        if (path is null)
        {
            if (tool == "grep" || tool == "glob") path = ".";
            else return false;
        }
        auto joined = joinPath(cwd, expandTilde(path));
        return pathRuleMatches(rule, normalize(joined), cwd) || pathRuleMatches(rule, resolveSymlinks(joined), cwd);
    case Subject.arguments:
        return rule.matches(args.toString);
    }
}

/// The parse error of a malformed rule, or null.
string validateRule(string ruleSrc)
{
    try parseRule(ruleSrc);
    catch (RuleError e) return e.msg;
    return null;
}

private string stringArg(JSONValue args, string key) @trusted
{
    if (args.type != JSONType.object) return null;
    auto v = key in args;
    return v !is null && v.type == JSONType.string ? v.str : null;
}

private string currentDir() @trusted
{
    import std.file : getcwd;
    try return getcwd();
    catch (Exception) return "/";
}

bool isMutating(string tool)
{
    return tool == "bash" || tool == "write_file" || tool == "edit_file";
}

/// Checks tool calls against rules and the built-in guards.
struct Policy
{
    Rule[] allow;
    Rule[] deny;
    bool builtinRules = true;
    string[] protectedBranches = ["main", "master", "trunk", "develop"];
    Mode mode = Mode.normal;

    /// Build from the `[permissions]` table; throws RuleError on a bad rule.
    static Policy fromConfig(JSONValue section) @trusted
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

    /// null when the call may run, else the reason it is blocked.
    string check(string tool, JSONValue args)
    {
        if (mode == Mode.plan && isMutating(tool))
            return format("%s is not available in plan mode (read-only). Present the plan instead.", tool);
        auto reason = checkIn(tool, args, currentDir());
        if (reason is null) return null;
        return format("Blocked by nano-coder permissions: %s. %s", reason, blockAdvice);
    }

    /// The bare reason a call is blocked (no advice), or null.
    string checkIn(string tool, JSONValue args, string cwd)
    {
        try
        {
            switch (tool)
            {
            case "bash":
                auto c = stringArg(args, "command");
                if (c !is null) checkCommand(c, cwd);
                return null;
            case "read_file", "write_file", "edit_file":
                auto path = stringArg(args, "path");
                if (path is null) return null;
                auto joined = joinPath(cwd, expandTilde(path));
                auto absolute = normalize(joined);
                auto resolved = resolveSymlinks(joined);
                foreach (rule; deny)
                    if (rule.appliesTo(tool)
                        && (pathRuleMatches(rule, absolute, cwd) || pathRuleMatches(rule, resolved, cwd)))
                        return format("rule `%s` denies %s on %s", rule.source, tool, absolute);
                return null;
            case "grep", "glob":
                auto root = stringArg(args, "path");
                if (root is null) root = ".";
                if (auto rule = readDenyRule(expandTilde(root), cwd))
                    return format("rule `%s` denies %s on %s", rule, tool, root);
                auto text = args.toString;
                foreach (rule; deny)
                    if (rule.subject == Subject.arguments && rule.appliesTo(tool) && rule.matches(text))
                        return format("rule `%s` denies %s", rule.source, tool);
                return null;
            default:
                auto text = args.toString;
                foreach (rule; deny)
                    if (rule.appliesTo(tool) && rule.matches(text))
                        return format("rule `%s` denies %s", rule.source, tool);
                return null;
            }
        }
        catch (Blocked b) return b.msg;
    }

    /// Whether a `Read(...)` deny rule covers `path` or any ancestor of it.
    /// The search tools call this for every discovered file.
    bool readDenied(string path, string cwd) { return readDenyRule(path, cwd) !is null; }

    /// The source of the `Read(...)` deny rule covering `path`, or null.
    private string readDenyRule(string path, string cwd)
    {
        bool any_ = false;
        foreach (ref r; deny)
            if (r.subject == Subject.path && r.appliesTo("read_file")) { any_ = true; break; }
        if (!any_) return null;
        auto joined = joinPath(cwd, path);
        auto absolute = normalize(joined);
        auto resolved = resolveSymlinks(joined);
        foreach (ref r; deny)
        {
            if (!(r.subject == Subject.path && r.appliesTo("read_file"))) continue;
            for (string c = absolute; c !is null; c = parent(c))
                if (pathRuleMatches(r, c, cwd)) return r.source;
            for (string c = resolved; c !is null; c = parent(c))
                if (pathRuleMatches(r, c, cwd)) return r.source;
        }
        return null;
    }

    /// Throws Blocked with the reason a shell command is refused.
    void checkCommand(string command, string cwd)
    {
        auto denyRules = deny.filter!(r => r.subject == Subject.command).array;
        foreach (r; denyRules)
            if (r.matches(command.strip)) throw new Blocked(format("rule `%s` denies this command", r.source));
        Simple[] commands;
        try commands = expandAll(parse(command));
        catch (Exception e) throw new Blocked(format("could not inspect this command (%s); simplify it", e.msg));
        foreach (cmd; commands)
        {
            auto text = commandText(cmd);
            foreach (r; denyRules)
                if (r.matches(text)) throw new Blocked(format("rule `%s` denies `%s`", r.source, text));
        }
        Guard guard;
        if (builtinRules)
        {
            auto realCwd = resolveSymlinks(cwd);
            auto withAssignments = commandsWithAssignments(command);
            auto loopBound = loopBoundVars(withAssignments);
            auto assigned = assignments(withAssignments);
            foreach (name, _; loopBound) assigned[name] = Known(false, null);
            guard = Guard(realCwd, homeDir(), protectedBranches, assigned, loopBound, realCwd, 0);
            foreach (cmd; commands)
                foreach (r; cmd.redirects)
                    if (isWriteRedirect(r.op)) guard.deviceWrite(r.target.text);
        }
        auto allowRules = allow.filter!(r => r.subject == Subject.command).array;
        if (allowRules.length && commands.all!((cmd) {
                auto text = commandText(cmd);
                return (!cmd.words.length && !cmd.redirects.length) || allowRules.any!(r => r.matches(text));
            }))
            return;
        if (builtinRules) guard.check(command, commands);
    }
}

unittest
{
    Policy p;
    JSONValue cmd(string c) { return JSONValue(["command": c]); }
    assert(p.check("bash", cmd("ls -la")) is null);
    assert(p.check("bash", cmd("cd /tmp && rm -rf /")) !is null);
    assert(p.check("bash", cmd("rm -rf build")) is null);
    assert(p.check("bash", cmd("git push --force origin main")) !is null);
    assert(p.check("bash", cmd("git push origin feature/x")) is null);
    p.deny = [parseRule("Bash(git push:*)"), parseRule("Edit(**/.env)")];
    assert(p.check("bash", cmd("echo hi; git push origin main")) !is null);
    assert(p.check("edit_file", JSONValue(["path": "/x/y/.env"])) !is null);
    assert(p.check("edit_file", JSONValue(["path": "/x/y/env.d"])) is null);
    p.mode = Mode.plan;
    assert(p.check("write_file", JSONValue(["path": "a"])) !is null);
    assert(p.check("read_file", JSONValue(["path": "a"])) is null);
}
