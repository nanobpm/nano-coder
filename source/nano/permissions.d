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
import nano.safeio : jsonText, jsonPretty;

import std.json;
import std.format : format;
import std.regex : regex, matchFirst, Regex;
import std.string : strip, indexOf, toLower;
import std.algorithm : canFind, any, all, startsWith, endsWith, filter;
import std.array : array, join, replace;
import std.algorithm : map;
import std.sumtype : SumType, match;
import nano.shell : parse, Simple;
import nano.result : orThrow, toOption;
import nano.cmdexpand;
import nano.guard;
import nano.paths;
import nano.sandbox : SandboxConfig, modeName;

enum string blockAdvice = "Do not try to get around this with a different command or a script. "
    ~ "If the action is really needed, stop and tell the user what you want to run and why, so they can run it "
    ~ "themselves or add an allow rule.";


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

    bool appliesTo(string tool) pure const { return tools.canFind(tool); }

    bool matches(string text) const
    {
        if (patternSource is null) return true;
        // A `const` Regex can't be matched with, and copying one out of
        // `const` needs a cast; reuse a per-thread compiled copy instead.
        static Regex!char[string] compiled;
        auto re = patternSource in compiled;
        if (re is null) { compiled[patternSource] = regex(patternSource, "s"); re = patternSource in compiled; }
        return !matchFirst(text, *re).empty;
    }
}

private string quoted(string s) pure { return debugQuote(s); }

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

private string escapeChar(dchar c) pure
{
    import std.conv : to;
    if (`\.+*?()|[]{}^$`.canFind(c)) return "\\" ~ c.to!string;
    return c.to!string;
}

/// `*` matches anything (including spaces and `/`); a trailing `:*` matches
/// the prefix alone or followed by arguments (`npm run test:*`).
string commandGlob(string pattern) pure
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
        // Unparsable: only the whole-command match above applies (as in Rust).
        foreach (parsed; parse(c).toOption)
        {
            try
            {
                foreach (cmd; expandAll(parsed))
                    if (rule.matches(commandText(cmd))) return true;
            }
            catch (Exception) {} // unexpandable: likewise only the whole-command match applies
        }
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
        return rule.matches(args.jsonText);
    }
}

/// The parse error of a malformed rule, or null.
string validateRule(string ruleSrc)
{
    try parseRule(ruleSrc);
    catch (RuleError e) return e.msg;
    return null;
}

private string stringArg(JSONValue args, string key) pure
{
    if (args.type != JSONType.object) return null;
    auto v = key in args;
    return v !is null && v.type == JSONType.string ? v.str : null;
}

private string currentDir() nothrow
{
    import std.file : getcwd;
    try return getcwd();
    catch (Exception) return "/"; // a deleted cwd: resolve relative paths from /, which no allow rule covers
}

/// Checks tool calls against rules and the built-in guards.
struct Policy
{
    Rule[] allow;
    Rule[] deny;
    bool builtinRules = true;
    string[] protectedBranches = ["main", "master", "trunk", "develop"];
    /// File-tool writes stay inside the sandbox's writable roots.
    SandboxConfig sandbox;

    /// Build from the `[permissions]` table; throws RuleError on a bad rule.
    static Policy fromConfig(JSONValue section)
    {
        Policy p;
        if (section.type != JSONType.object) return p;
        if (auto v = "allow" in section) foreach (r; v.arrayNoRef) p.allow ~= parseRule(r.str);
        if (auto v = "deny" in section) foreach (r; v.arrayNoRef) p.deny ~= parseRule(r.str);
        if (auto v = "builtin_rules" in section) p.builtinRules = v.boolean;
        if (auto v = "protected_branches" in section)
        {
            p.protectedBranches = null;
            foreach (b; v.arrayNoRef) p.protectedBranches ~= b.str;
        }
        return p;
    }

    /// Allow or deny. A call the static checks cannot verify (a shell loop
    /// whose commands are not provably safe) never prompts: with the OS
    /// sandbox active it is allowed (the sandbox confines what it can write),
    /// and without one it is blocked with the usual guidance (Rust #171).
    /// Hard blocks are denied either way. `PermDeny` carries the full message
    /// for the model.
    PermissionDecision decide(string tool, JSONValue args) { return decideIn(tool, args, currentDir()); }

    /// ditto, at `cwd`.
    PermissionDecision decideIn(string tool, JSONValue args, string cwd)
    {
        return verdictIn(tool, args, cwd).match!(
            (PermAllow a) => PermissionDecision(a),
            (PermAsk a) => sandbox.active ? PermissionDecision(PermAllow()) : PermissionDecision(PermDeny(blockedMessage(a.reason))),
            (PermDeny d) => PermissionDecision(d),
        );
    }

    /// The checks' own verdict, before `decide` resolves an unverifiable call
    /// (`PermAsk`) by whether the OS sandbox is active.
    PermissionVerdict verdictIn(string tool, JSONValue args, string cwd)
    {
        string ask;
        auto reason = reasonIn(tool, args, cwd, ask);
        if (reason !is null) return PermissionVerdict(PermDeny(blockedMessage(reason)));
        if (ask !is null) return PermissionVerdict(PermAsk(ask));
        return PermissionVerdict(PermAllow());
    }

    /// Null when the call may run, else the message the model sees.
    string check(string tool, JSONValue args)
    {
        return decide(tool, args).match!(
            (PermAllow _) => string.init,
            (PermDeny d) => d.message,
        );
    }

    /// The bare reason a call is blocked (no advice), or null. An unverifiable
    /// call runs under the sandbox and is blocked with the full guidance
    /// message without it.
    string checkIn(string tool, JSONValue args, string cwd)
    {
        string ask;
        auto reason = reasonIn(tool, args, cwd, ask);
        if (reason !is null) return reason;
        return ask is null || sandbox.active ? null : blockedMessage(ask);
    }

    /// The bare deny reason, or null; `ask` is set when a bash command can't
    /// be verified.
    private string reasonIn(string tool, JSONValue args, string cwd, out string ask)
    {
        try
        {
            switch (tool)
            {
            case "bash":
                auto c = stringArg(args, "command");
                if (c !is null) ask = checkCommand(c, cwd);
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
                // Check the symlink-resolved target too: `link/../etc/hosts`
                // (link -> /) is lexically inside but writes /etc/hosts.
                if (tool != "read_file" && sandbox.active)
                    foreach (p; [absolute, resolved])
                        if (!sandbox.allowsWrite(p, cwd))
                            return format("%s is outside the %s sandbox's writable directories", p, sandbox.mode.modeName);
                return null;
            case "apply_patch":
                // Every path the patch touches (both ends of a move) passes
                // the same checks as a direct edit of it. A patch that doesn't
                // parse touches nothing; the tool reports the parse error.
                // A tool-level rule (`deny = ["apply_patch"]`) applies first.
                foreach (rule; deny)
                    if (rule.appliesTo(tool) && rule.matches(args.jsonText))
                        return format("rule `%s` denies %s", rule.source, tool);
                auto patch = stringArg(args, "patch");
                if (patch is null) return null;
                import nano.tools : ToolError;
                import nano.tools.files : parsePatch, PatchKind, FilePatch;
                FilePatch[] files;
                try files = parsePatch(patch);
                catch (ToolError) return null; // unparseable: the tool rejects it before touching any path
                foreach (fp; files)
                {
                    // Delete/Update read the existing file (its text lands in
                    // the diff, even on a dry run), so it must be readable too.
                    if (fp.kind != PatchKind.add)
                        if (auto r = reasonIn("read_file", JSONValue(["path": fp.path]), cwd, ask))
                            return r.replace("denies read_file on", "denies apply_patch on");
                    foreach (p; fp.moveTo is null ? [fp.path] : [fp.path, fp.moveTo])
                        if (auto r = reasonIn("edit_file", JSONValue(["path": p]), cwd, ask))
                            return r.replace("denies edit_file on", "denies apply_patch on");
                }
                return null;
            case "grep", "glob":
                auto root = stringArg(args, "path");
                if (root is null) root = ".";
                if (auto rule = readDenyRule(expandTilde(root), cwd))
                    return format("rule `%s` denies %s on %s", rule, tool, root);
                auto text = args.jsonText;
                foreach (rule; deny)
                    if (rule.subject == Subject.arguments && rule.appliesTo(tool) && rule.matches(text))
                        return format("rule `%s` denies %s", rule.source, tool);
                return null;
            default:
                auto text = args.jsonText;
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

    /// The Read-deny rules and resolved working directory, computed once for
    /// a search walk so each entry is judged lexically, with no per-entry
    /// symlink resolution (Rust `read_deny_scan`, #160). False when no
    /// Read-deny rule exists: nothing is hidden and no work is needed.
    bool readDenyScan(string cwd, out ReadDenyScan scan) const
    {
        foreach (ref r; deny)
            if (r.subject == Subject.path && r.appliesTo("read_file")) scan.rules ~= r;
        if (!scan.rules.length) return false;
        scan.cwdNormalized = scan.rootNormalized = normalize(cwd);
        scan.cwdResolved = scan.rootResolved = resolveSymlinks(cwd);
        return true;
    }

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

    /// Throws Blocked with the reason a shell command is refused; returns the
    /// reason it can't be verified (an unverifiable loop), or null.
    string checkCommand(string command, string cwd)
    {
        auto denyRules = deny.filter!(r => r.subject == Subject.command).array;
        foreach (r; denyRules)
            if (r.matches(command.strip)) throw new Blocked(format("rule `%s` denies this command", r.source));
        Expansion e;
        try e = expandAllChecked(parse(command).orThrow!(m => new Exception(m)));
        catch (Exception ex) throw new Blocked(format("could not inspect this command (%s); simplify it", ex.msg));
        auto commands = e.commands;
        foreach (cmd; commands)
        {
            auto text = commandText(cmd);
            foreach (r; denyRules)
                if (r.matches(text)) throw new Blocked(format("rule `%s` denies `%s`", r.source, text));
        }
        // An unverified loop command carries run-time arguments: a deny rule
        // that could match it for some value denies the loop (a dynamic or
        // glob word can take any value); an allow rule approves it only when
        // the command has no run-time-dependent word and the rule matches.
        auto allowRules = allow.filter!(r => r.subject == Subject.command).array;
        static bool runtime(const Simple cmd) { return cmd.words.any!(w => w.dynamic || w.glob); }
        foreach (item; e.unverified)
        {
            auto text = commandText(item.command);
            foreach (r; denyRules)
                if (r.matches(text))
                    throw new Blocked(format("rule `%s` may deny `%s` depending on the loop's values", r.source, text));
            if (runtime(item.command) && denyRules.length)
                throw new Blocked(format("rule `%s` may deny `%s` depending on the loop's values", denyRules[0].source,
                    text));
        }
        string ask;
        foreach (item; e.unverified)
            if (runtime(item.command) || !allowRules.any!(r => r.matches(commandText(item.command))))
            {
                ask = item.reason;
                break;
            }
        Guard guard;
        if (builtinRules)
        {
            auto realCwd = resolveSymlinks(cwd);
            // The dataflow comes from the original parsed commands (loop
            // headers and assignments intact), never the executable ones.
            auto loopBound = loopBoundVars(e.guardSource);
            // A loop unrolled away still ran: its variable stays loop-bound.
            foreach (name; e.bound) loopBound[name] = true;
            auto assigned = assignments(e.guardSource);
            foreach (name, _; loopBound) assigned[name] = Known(false, null);
            guard = Guard(realCwd, homeDir(), protectedBranches, assigned, loopBound, realCwd, 0);
            foreach (cmd; commands)
                foreach (r; cmd.redirects)
                    if (isWriteRedirect(r.op)) guard.deviceWrite(r.target.text);
        }
        if (allowRules.length && commands.all!((cmd) {
                auto text = commandText(cmd);
                // An assignment-only command has no program an allow rule
                // must cover.
                return ((!cmd.words.length || cmd.words.all!(w => isAssignment(w.text))) && !cmd.redirects.length)
                    || allowRules.any!(r => r.matches(text));
            }))
            return ask;
        if (builtinRules)
        {
            // Scan the substituted commands as well as the raw text, so an
            // unrolled loop cannot hide `DROP TABLE` behind its variable.
            auto scan = command ~ "\n" ~ commands.map!(c => commandText(c)).join("\n");
            guard.check(scan, commands);
        }
        return ask;
    }
}

/// The message a blocked call returns to the model.
string blockedMessage(string reason) pure
{
    return format("Blocked by nano-coder permissions: %s. %s", reason, blockAdvice);
}

/// Outcome of `Policy.decide`.
struct PermAllow {}
/// The checks could not verify the call; the reason why (`Policy.verdictIn`).
struct PermAsk { string reason; }
/// Blocked; the full message for the model.
struct PermDeny { string message; }
/// ditto
alias PermissionDecision = SumType!(PermAllow, PermDeny);
/// The checks' verdict, with unverifiable calls still unresolved.
alias PermissionVerdict = SumType!(PermAllow, PermAsk, PermDeny);

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
    // A tool-level deny of apply_patch blocks it outright, not only per path.
    auto patch = JSONValue(["patch": "*** Begin Patch\n*** Add File: /x/ok.txt\n+a\n*** End Patch\n"]);
    assert(p.check("apply_patch", patch) is null);
    p.deny ~= parseRule("apply_patch");
    assert(p.check("apply_patch", patch) !is null);
}

unittest
{
    // A path read_file may not show can't be read through apply_patch either
    // (a dry-run Delete/Update would put its text in the diff), but a
    // read-denied path may still be created by Add File.
    Policy p;
    p.deny = [parseRule("Read(**/.env)")];
    JSONValue pt(string body_) { return JSONValue(["patch": "*** Begin Patch\n" ~ body_ ~ "*** End Patch\n"]); }
    assert(p.check("apply_patch", pt("*** Delete File: /x/.env\n")) !is null);
    assert(p.check("apply_patch", pt("*** Update File: /x/.env\n@@\n-a\n+b\n")) !is null);
    assert(p.check("apply_patch", pt("*** Move File: /x/.env -> /x/b\n")) !is null);
    assert(p.check("apply_patch", pt("*** Add File: /x/.env\n+a\n")) is null);
    assert(p.check("apply_patch", pt("*** Delete File: /x/ok\n")) is null);
}

/// Read-deny rules prepared for judging many walked paths (`Policy.readDenyScan`).
/// Walked paths never pass through a symlink (the walker doesn't follow
/// them), so only the search root and working directory need resolving: a
/// path under a symlinked root is also judged at its resolved location.
struct ReadDenyScan
{
    private const(Rule)[] rules;
    private string cwdNormalized, cwdResolved, rootNormalized, rootResolved;

    /// The scan for a walk under `root` (which may be a symlink).
    ReadDenyScan forRoot(string root) const
    {
        ReadDenyScan s;
        s.rules = rules;
        s.cwdNormalized = cwdNormalized;
        s.cwdResolved = cwdResolved;
        s.rootNormalized = normalize(joinPath(cwdNormalized, root));
        s.rootResolved = resolveSymlinks(joinPath(cwdNormalized, root));
        return s;
    }

    /// Whether a Read-deny rule hides `path` (absolute or cwd-relative).
    bool denied(string path) const
    {
        auto absolute = normalize(joinPath(cwdNormalized, path));
        string[] candidates = [absolute];
        if (rootResolved != rootNormalized && startsWithPath(absolute, rootNormalized))
        {
            auto rest = fromComponents(components(absolute)[components(rootNormalized).length .. $]);
            candidates ~= normalize(joinPath(rootResolved, rest));
        }
        bool matches(const ref Rule r, string c)
        {
            if (r.matches(c)) return true;
            if (startsWithPath(c, cwdNormalized)
                && r.matches(fromComponents(components(c)[components(cwdNormalized).length .. $])))
                return true;
            return cwdResolved != cwdNormalized && startsWithPath(c, cwdResolved)
                && r.matches(fromComponents(components(c)[components(cwdResolved).length .. $]));
        }
        foreach (ref r; rules)
        {
            if (r.patternSource is null) return true;
            foreach (base; candidates)
                for (string c = base; c !is null; c = parent(c))
                    if (matches(r, c)) return true;
        }
        return false;
    }
}
