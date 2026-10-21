/// The built-in destructive-command guard (port of `Guard` in
/// src/permissions.rs). It runs on every bash command regardless of the
/// user's rules and refuses operations whose damage would be catastrophic:
/// deleting `/`, home or system directories, writing raw devices, formatting
/// disks, force-pushing protected branches, dropping databases, and so on.
module nano.guard;

@safe:

import std.algorithm : canFind, any, startsWith, endsWith, all;
import std.array : join;
import std.format : format;
import std.regex : regex, matchFirst, ctRegex, replaceAll;
import std.string : strip, toLower, indexOf;
import std.uni : asLowerCase;
import nano.shell;
import nano.cmdexpand;
import nano.paths;

immutable string[] dbClients = ["psql", "pgcli", "mysql", "mariadb", "mycli", "sqlite3", "litecli", "duckdb", "sqlcmd",
    "mongosh", "mongo", "redis-cli", "valkey-cli", "cqlsh", "clickhouse-client", "clickhouse", "cockroach", "snowsql",
    "usql", "bq"];

/// Directories whose contents are the operating system.
immutable string[] systemDirs = ["/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share",
    "/etc", "/private/etc", "/System", "/boot", "/lib", "/lib32", "/lib64", "/proc", "/sys", "/dev", "/var/lib",
    "/private/var/lib", "/private/var/db"];

/// Exact `var` roots (descendants such as `/var/folders` are allowed).
immutable string[] varRoots = ["/var", "/private/var"];

private auto destructiveSql()
{
    static re = ctRegex!(`\b(drop\s+(database|schema|table|user|role|owned\s+by)\b|truncate\s+(table\s+)?[\w"` ~ "`"
        ~ `\[]|delete\s+from\s+[\w."` ~ "`" ~ `\[\]]+\s*($|;|'|"|\))|delete\s+from\s+[\w."` ~ "`"
        ~ `\[\]]+[^;]*\b(where|or)\s+(not\s+)?(true\b|\d+\s*=\s*\d+|'[^']*'\s*=\s*'[^']*'|"[^"]*"\s*=\s*"[^"]*")|alter\s+table\s+\S+\s+drop\s|dropDatabase\s*\(|flushall\b|flushdb\b)`,
        "i");
    return re;
}

private auto forkBomb()
{
    static re = ctRegex!(`:\s*\(\s*\)\s*\{[^}]*:\s*\|\s*:`);
    return re;
}

/// Refuse a redirection that writes directly to a raw device (`> /dev/sda`).
void deviceWriteAt(string target, string cwd)
{
    auto path = resolveTarget(target, cwd);
    bool dev = path.startsWith("/dev/") && !safeDevices.canFind(path) && !path.startsWith("/dev/fd/")
        && !path.startsWith("/dev/shm/") && !path.startsWith("/dev/pts/");
    if (dev) throw new Blocked(format("it writes directly to the device %s", target));
}

/// Split arguments into flags and operands (everything after `--` is an operand).
void splitFlags(const Word[] args, out string[] flags, out const(Word)[] operands)
{
    bool onlyOperands = false;
    foreach (arg; args)
    {
        if (!onlyOperands && arg.text == "--") onlyOperands = true;
        else if (!onlyOperands && arg.text.startsWith("-") && arg.text.length > 1) flags ~= arg.text;
        else operands ~= arg;
    }
}

/// The `mv`/`cp` destination given via `-t DIR`, `-tDIR` or `--target-directory[=]DIR`.
string mvTargetDir(const Word[] args) pure
{
    foreach (i, arg; args)
    {
        auto t = arg.text;
        if (t == "--") break;
        if (t.startsWith("--target-directory=")) return t["--target-directory=".length .. $];
        if (t == "--target-directory" || t == "-t") return i + 1 < args.length ? args[i + 1].text : null;
        if (t.length > 2 && t.startsWith("-t") && !t.startsWith("--")) return t[2 .. $];
    }
    return null;
}

/// The checked-out branch in `dir`, or null.
string currentBranch(string dir) @trusted
{
    import std.process : execute, Config;
    try
    {
        auto r = execute(["git", "symbolic-ref", "--short", "-q", "HEAD"], null, Config.stderrPassThrough & Config.none,
            size_t.max, dir);
        auto name = r.output.strip;
        return r.status == 0 && name.length ? name : null;
    }
    catch (Exception) return null;
}

/// A resolved path operand.
private struct Resolved
{
    string path;
    bool glob;
}

/// Result of `resolve`: undeterminable, empty (expands to nothing), or a path.
private enum Res { err, none, some }

struct Guard
{
    /// Working directory, symlink-resolved.
    string cwd;
    string home;
    const(string)[] protectedBranches;
    Known[string] assigned;
    bool[string] loopBound;
    /// Directory relative paths resolve against; null once unknown.
    string base;
    size_t depth;

    void check(string raw, const Simple[] commands)
    {
        if (!matchFirst(raw, forkBomb()).empty) throw new Blocked("this looks like a fork bomb");
        bool scanSql = false;
        foreach (cmd; commands)
        {
            foreach (r; cmd.redirects)
                if (isWriteRedirect(r.op)) deviceWrite(r.target.text);
            if (!cmd.words.length) continue;
            auto first = cmd.words[0];
            if (first.dynamic && !first.glob)
            {
                bool known;
                auto resolved = substitute(first.text, known).strip;
                if (!known) throw new Blocked(format("`%s` runs a command computed at run time", first.text));
                if (resolved != first.text)
                {
                    if (depth >= maxExpandDepth) throw new Blocked("commands nest too deeply to inspect");
                    auto line = resolved;
                    foreach (w; cmd.words[1 .. $]) line ~= " " ~ w.text;
                    Simple[] reparsed;
                    try reparsed = expandAll(parse(line));
                    catch (Exception e) throw new Blocked(format("could not inspect `%s` (%s)", line, e.msg));
                    ++depth;
                    scope (exit) --depth;
                    check(line, reparsed);
                    continue;
                }
            }
            auto program = basename(first.text);
            auto args = cmd.words[1 .. $];
            bool isInterp = interpreters.any!(p => program.startsWith(p));
            Word script;
            if (isInterp && interpreterInlineScript(args, script)) scriptText([script]);
            bool interpEval = isInterp && args.any!((a) {
                auto t = a.text;
                return ["-c", "-e", "-E", "-r", "--eval", "eval"].canFind(t)
                    || ((t.startsWith("-c") || t.startsWith("-e") || t.startsWith("-E") || t.startsWith("-r")) && t.length > 2)
                    || t.startsWith("--eval=");
            });
            scanSql |= cmd.words.any!(w => dbClients.canFind(basename(w.text))) || interpEval;
            switch (program)
            {
            case "cd", "pushd": changeDir(args); break;
            case "popd": base = null; break;
            default: command(program, args);
            }
        }
        if (scanSql)
        {
            auto m = matchFirst(raw, destructiveSql());
            if (!m.empty) throw new Blocked(format("it runs destructive database statements (`%s`)", m.hit.strip));
        }
    }

    void changeDir(const Word[] args)
    {
        ptrdiff_t ti = -1;
        foreach (i, a; args)
            if (!(a.text.startsWith("-") && a.text.length > 1 && !a.quoted)) { ti = i; break; }
        string next;
        if (ti < 0) next = home;
        else if (args[ti].text == "-") next = null;
        else next = resolveDir(args[ti]);
        base = (next !is null && !isDir(next)) ? null : next;
    }

    string resolveDir(const Word word)
    {
        bool known = true;
        string text = word.dynamic ? substitute(word.text, known) : word.text;
        if (!known || word.glob) return null;
        text = expandHome(text);
        if (text is null || base is null) return null;
        return resolveSymlinks(joinPath(base, text));
    }

    string expandHome(string text)
    {
        if (text == "~" || text.startsWith("~/"))
        {
            if (home is null) return null;
            return home ~ text[1 .. $];
        }
        return text;
    }

    void command(string program, const Word[] args)
    {
        bool has(string flag) { return args.any!(a => a.text == flag); }
        bool anyWord(const string[] names) { return args.any!(a => names.canFind(a.text)); }
        string[] flags;
        const(Word)[] targets;
        switch (program)
        {
        case "rm":
            splitFlags(args, flags, targets);
            bool recursive = flags.any!(f => f == "--recursive" || (!f.startsWith("--") && (f.canFind('r') || f.canFind('R'))));
            if (flags.canFind("--no-preserve-root"))
                throw new Blocked("`rm --no-preserve-root` can delete the whole filesystem");
            if (recursive) foreach (t; targets) protect(t, true, "rm -r");
            break;
        case "mv":
            splitFlags(args, flags, targets);
            auto dir = mvTargetDir(args);
            if (dir !is null)
            {
                foreach (s; targets) protect(s, true, "mv");
                Word dest;
                dest.text = dir;
                protect(followSymlink(dest), false, "mv");
            }
            else if (targets.length)
            {
                foreach (s; targets[0 .. $ - 1]) protect(s, true, "mv");
                protect(followSymlink(targets[$ - 1]), false, "mv");
            }
            break;
        case "chmod", "chown", "chgrp":
            splitFlags(args, flags, targets);
            bool recursive = flags.any!(f => f == "--recursive" || (!f.startsWith("--") && f.canFind('R')));
            if (recursive)
            {
                size_t skip = flags.any!(f => f.startsWith("--reference")) ? 0 : 1;
                foreach (i, t; targets)
                    if (i >= skip) protect(t, false, program);
            }
            break;
        case "find":
            if (has("-delete")) findDelete(args, anyWord(["-name", "-iname", "-path", "-ipath", "-regex", "-iregex",
                "-wholename"]));
            break;
        case "dd":
            foreach (a; args)
                if (a.text.startsWith("of=")) deviceWrite(a.text[3 .. $]);
            break;
        case "shred", "blkdiscard":
            splitFlags(args, flags, targets);
            foreach (t; targets) deviceWrite(t.text);
            break;
        case "mke2fs", "mkswap", "wipefs", "fdisk", "sfdisk", "gdisk", "sgdisk", "cfdisk", "parted":
            throw new Blocked(format("`%s` rewrites disk partitions or filesystems", program));
        case "diskutil":
            bool destructive = args.any!((a) {
                auto t = a.text.toLower;
                return t.startsWith("erase") || ["zerodisk", "randomdisk", "secureerase", "partitiondisk", "reformat",
                    "deletevolume", "deletecontainer", "splitpartition", "mergepartitions"].canFind(t);
            });
            if (destructive) throw new Blocked("`diskutil` would erase or repartition a disk");
            break;
        case "shutdown", "reboot", "halt", "poweroff":
            throw new Blocked(format("`%s` stops the machine", program));
        case "dropdb", "dropuser":
            throw new Blocked(format("`%s` deletes a database or role", program));
        case "git":
            git(args);
            break;
        default:
            if (program.startsWith("mkfs") || program.startsWith("newfs"))
                throw new Blocked(format("`%s` formats a disk", program));
            if (program == "mysqladmin" && has("drop")) throw new Blocked("`mysqladmin drop` deletes a database");
            if ((program == "terraform" || program == "tofu") && (has("destroy") || (has("apply") && has("-destroy"))))
                throw new Blocked("it destroys infrastructure");
            if (program == "pulumi" && has("destroy")) throw new Blocked("it destroys infrastructure");
            if ((program == "kubectl" || program == "oc") && has("delete")
                && (anyWord(["namespace", "namespaces", "ns", "--all", "--all-namespaces", "-A"])
                    || args.any!(a => a.text.startsWith("ns/") || a.text.startsWith("namespace/")
                        || a.text.startsWith("namespaces/"))))
                throw new Blocked("it deletes Kubernetes namespaces or every resource of a kind");
            if (program == "aws" && has("s3") && (has("rb") || (has("rm") && has("--recursive"))))
                throw new Blocked("it deletes S3 buckets or their contents");
            string[] words = [program];
            foreach (a; args) words ~= a.text;
            bool contains(string w) { return words.canFind(w); }
            bool migrateReset = false;
            foreach (i; 1 .. words.length)
                if (words[i - 1] == "migrate" && words[i] == "reset") migrateReset = true;
            bool prisma = contains("prisma") && (migrateReset || contains("--force-reset") || contains("--accept-data-loss"));
            bool rails = ["rails", "rake", "bundle", "npm", "pnpm", "yarn", "bun"].canFind(program)
                && (contains("db:drop") || contains("db:reset") || contains("db:purge"));
            bool django = words.any!(w => basename(w) == "manage.py") && (contains("flush") || contains("reset_db"));
            if (prisma || rails || django) throw new Blocked("it drops or resets a database");
        }
    }

    private void findDelete(const Word[] args, bool narrowed)
    {
        bool follow = false;
        size_t s = 0;
        while (s < args.length)
        {
            auto t = args[s].text;
            if (t == "-H" || t == "-L") { follow = true; ++s; }
            else if (t == "-P") { follow = false; ++s; }
            else if (t == "-D") s += 2;
            else if (t.startsWith("-O")) ++s;
            else break;
        }
        if (s > args.length) s = args.length;
        Word[] starts;
        foreach (a; args[s .. $])
        {
            if (a.text.startsWith("-") || a.text == "(" || a.text == "!") break;
            starts ~= follow ? followSymlink(a) : Word(a.text, a.dynamic, a.glob, a.quoted, a.splits, a.assigns);
        }
        Word implicit;
        implicit.text = ".";
        if (!starts.length) starts = [follow ? followSymlink(implicit) : implicit];
        Word[] kept;
        foreach (w; starts)
        {
            Resolved r;
            if (resolve(w, r) != Res.none) kept ~= w;
        }
        if (!kept.length) kept = [implicit];
        if (narrowed)
        {
            foreach (st; kept)
            {
                Resolved r;
                if (resolve(st, r) == Res.err)
                    throw new Blocked(format("`find -delete` start path `%s` expands a loop variable whose value cannot be "
                        ~ "determined; rewrite it as explicit commands", st.text));
            }
            foreach (st; kept)
            {
                Resolved r;
                if (resolve(st, r) == Res.some)
                {
                    auto what = catastrophicRoot(r.path);
                    if (what !is null)
                        throw new Blocked(format("`find -delete` under %s (%s) can remove protected files", what, r.path));
                }
            }
            if (findPredicateReachesGit(args))
                foreach (st; kept)
                {
                    Resolved r;
                    if (resolve(st, r) == Res.some && containsGitDir(r.path))
                        throw new Blocked(format("`find -delete` under %s can recurse into a git repository's .git directory",
                            r.path));
                }
        }
        else
            foreach (st; kept) protect(st, true, "find -delete");
    }

    void deviceWrite(string target)
    {
        if (target.canFind('`')) throw new Blocked("it redirects to a target computed at run time");
        bool known = true;
        auto t = target.canFind('$') ? substitute(target, known) : target;
        if (!known) throw new Blocked("it redirects to a target computed at run time");
        string b;
        if (expandTilde(t).isAbsolute) b = cwd;
        else
        {
            if (base is null)
                throw new Blocked("it redirects relative to a directory nano-coder can't determine; use an absolute path");
            b = base;
        }
        deviceWriteAt(t, b);
    }

    /// Refuse to delete, move or recursively re-permission a catastrophic path.
    void protect(const Word word, bool protectCwd, string action)
    {
        Resolved r;
        final switch (resolve(word, r))
        {
        case Res.none: return;
        case Res.err:
            if (word.dynamic && referencesVars(word.text, loopBound))
                throw new Blocked(format("`%s %s` depends on a loop variable whose value nano-coder cannot determine after "
                    ~ "the loop (the shell leaves it holding the last iterated value); rewrite it as explicit commands",
                    action, word.text));
            throw new Blocked(format("`%s %s` runs after a `cd` to a directory nano-coder can't determine; use an "
                ~ "absolute path", action, word.text));
        case Res.some:
            auto what = danger(r.path, protectCwd);
            if (what !is null)
                throw new Blocked(format("`%s %s` would affect %s (%s%s)", action, word.text, what, r.path, r.glob ? "/*" : ""));
        }
    }

    /// Why deleting/moving/re-permissioning `p` would be catastrophic, or null.
    string danger(string p, bool protectCwd)
    {
        if (samePath(p, "/")) return "the filesystem root";
        if (protectCwd && samePath(p, cwd)) return "the working directory";
        if (protectCwd && startsWithPath(cwd, p)) return "a parent of the working directory";
        if (home !is null)
        {
            if (startsWithPath(home, p)) return "your home directory";
            auto par = parent(p);
            if (par !is null && samePath(par, home))
            {
                auto name = fileName(p);
                if (name is null) return null;
                return format("a top-level folder of your home directory (~/%s)", name);
            }
        }
        bool rootWorkspace = samePath(cwd, "/");
        bool inWorkspace = !rootWorkspace && startsWithPath(p, cwd) && !samePath(p, cwd);
        if (!inWorkspace && componentCount(p) <= 2) return "a top-level system directory";
        if (!inWorkspace && systemDirs.any!(d => startsWithPath(p, d))) return "a system directory";
        if (!inWorkspace && varRoots.canFind(p)) return "a system directory";
        if (components(p).canFind(".git")) return "a git repository's .git directory";
        return null;
    }

    /// Like `danger`, but only catastrophic roots outside the workspace.
    string catastrophicRoot(string p)
    {
        if (components(p).canFind(".git")) return "a git repository's .git directory";
        if (!samePath(cwd, "/") && startsWithPath(p, cwd)) return null;
        if (samePath(p, "/")) return "the filesystem root";
        if (home !is null)
        {
            if (startsWithPath(home, p)) return "your home directory";
            auto par = parent(p);
            if (par !is null && samePath(par, home)) return "a top-level folder of your home directory";
        }
        if (componentCount(p) <= 1) return "a top-level system directory";
        if (systemDirs.any!(d => startsWithPath(p, d))) return "a system directory";
        if (varRoots.canFind(p)) return "a system directory";
        return null;
    }

    /// Follow a command-line symlink operand to its real path.
    Word followSymlink(const Word word)
    {
        Resolved r;
        if (resolve(word, r) == Res.some && !r.glob && isSymlink(r.path))
        {
            auto canon = canonicalize(r.path);
            if (canon !is null)
            {
                Word w;
                w.text = canon;
                return w;
            }
        }
        return Word(word.text, word.dynamic, word.glob, word.quoted, word.splits, word.assigns);
    }

    /// Resolve a path word: known variables and `~` substituted, unknown ones
    /// empty; a trailing all-wildcard component is a glob over its parent.
    private Res resolve(const Word word, out Resolved r)
    {
        if (word.dynamic && referencesVars(word.text, loopBound)) return Res.err;
        bool known = true;
        string text = word.dynamic ? substitute(word.text, known) : word.text;
        text = expandHome(text);
        if (text is null || !text.length) return Res.none;
        string b = base;
        if (b is null)
        {
            if (text.startsWith("/")) b = "/";
            else return Res.err;
        }
        auto raw = joinPath(b, text);
        auto path = text.endsWith("/") ? resolveSymlinks(raw) : resolveParent(raw);
        if (word.glob)
        {
            string[] prefix;
            foreach (part; components(text))
            {
                if (part.canFind('*') || part.canFind('?') || part.canFind('['))
                {
                    bool all_ = part.all!(c => c == '*' || c == '?' || c == '.');
                    auto par = resolveSymlinks(joinPath(b, fromComponents(prefix)));
                    r = all_ ? Resolved(par, true) : Resolved(path, false);
                    return Res.some;
                }
                prefix ~= part;
            }
        }
        r = Resolved(path, false);
        return Res.some;
    }

    /// Substitute variables; `known` is false when a value is not known
    /// (unset ones become empty, as the shell would make them).
    string substitute(string text, out bool known)
    {
        import std.process : environment;
        static re = ctRegex!(`\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[?\-=+][^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)|\$\([^)]*\)|\$\(\.\.\.\)`);
        bool k = true;
        string replace(Captures)(Captures caps)
        {
            string name = caps[1].length ? caps[1] : caps[3];
            if (!name.length)
            {
                k = false;
                return "";
            }
            string value;
            bool have = false;
            if (auto a = name in assigned)
            {
                if (a.known) { value = a.value; have = true; }
                else { k = false; value = "__" ~ name ~ "__"; have = true; }
            }
            else if (name == "PWD") { if (base !is null) { value = base; have = true; } }
            else if (name == "HOME") { if (home !is null) { value = home; have = true; } }
            else
            {
                value = envGet(name);
                have = value !is null;
            }
            if (have && !value.length) have = false;
            if (!have) k = false;
            string m = caps[2];
            string mm = m.startsWith(":") ? m[1 .. $] : m;
            if (have)
            {
                if (mm.startsWith("+")) return mm[1 .. $];
                return value;
            }
            if (mm.startsWith("?")) return "__" ~ name ~ "__";
            if (mm.startsWith("-") || mm.startsWith("=")) return mm[1 .. $];
            return "";
        }
        import std.regex : matchAll;
        string out_;
        size_t pos = 0;
        foreach (m; matchAll(text, re))
        {
            auto start = m.pre.length;
            out_ ~= text[pos .. start] ~ replace(m);
            pos = start + m.hit.length;
        }
        out_ ~= text[pos .. $];
        known = k;
        return out_;
    }

    void git(const Word[] args)
    {
        string dir = base !is null ? base : cwd;
        size_t i = 0;
        while (i < args.length)
        {
            auto t = args[i].text;
            if (t == "-C")
            {
                if (i + 1 < args.length) dir = joinPath(dir, args[i + 1].text);
                i += 2;
            }
            else if (t == "-c" || t == "--git-dir" || t == "--work-tree" || t == "--namespace") i += 2;
            else if (t.startsWith("-")) ++i;
            else break;
        }
        if (i >= args.length || args[i].text != "push") return;
        bool force, delete_, all_;
        string[] positional;
        auto j = i + 1;
        while (j < args.length)
        {
            auto t = args[j].text;
            if (t == "--mirror") throw new Blocked("`git push --mirror` overwrites every ref on the remote");
            else if (t == "--force" || t == "--force-if-includes") force = true;
            else if (t == "--delete") delete_ = true;
            else if (t == "--all" || t == "--branches") all_ = true;
            else if (["-o", "--push-option", "--repo", "--receive-pack", "--exec"].canFind(t)) ++j;
            else if (t.startsWith("--force-with-lease")) force = true;
            else if (t.startsWith("--")) {}
            else if (t.startsWith("-") && t.length > 1)
            {
                force |= t.canFind('f');
                delete_ |= t.canFind('d');
            }
            else positional ~= t;
            ++j;
        }
        static struct Target { string dst; bool plus; bool emptySrc; }
        Target[] targets;
        if (all_) foreach (b; protectedBranches) targets ~= Target(b, false, false);
        foreach (spec; positional.length > 1 ? positional[1 .. $] : [])
        {
            bool plus = spec.startsWith("+");
            while (spec.startsWith("+")) spec = spec[1 .. $];
            auto colon = spec.indexOf(':');
            string src = colon >= 0 ? spec[0 .. colon] : spec;
            string dst = colon >= 0 ? spec[colon + 1 .. $] : spec;
            if (!dst.length) dst = src;
            if (dst.canFind('*'))
            {
                foreach (b; protectedBranches) targets ~= Target(b, plus, !src.length);
                continue;
            }
            if (dst == "HEAD")
            {
                auto cur = currentBranch(dir);
                dst = cur is null ? "" : cur;
            }
            else
                while (dst.startsWith("refs/heads/")) dst = dst["refs/heads/".length .. $];
            targets ~= Target(dst, plus, !src.length);
        }
        if (!targets.length && (force || delete_))
        {
            auto cur = currentBranch(dir);
            if (cur is null)
                throw new Blocked("it force-pushes without naming a branch, and the current branch is unknown");
            targets ~= Target(cur, false, false);
        }
        foreach (t; targets)
        {
            if (!protectedBranches.canFind(t.dst)) continue;
            if (delete_ || t.emptySrc) throw new Blocked(format("it deletes the protected branch `%s` on the remote", t.dst));
            if (force || t.plus) throw new Blocked(format("it force-pushes the protected branch `%s`", t.dst));
        }
    }
}

private string envGet(string name) @trusted
{
    import std.process : environment;
    return environment.get(name);
}
