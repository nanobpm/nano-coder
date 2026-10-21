/// Agent skills: folders with a `SKILL.md` that describe how to do one kind
/// of task. Port of src/skills.rs.
///
/// Only each skill's name and description go into the system prompt. The
/// model calls `load_skill` to read a skill when a task matches it, so an
/// unused skill costs one line of context.
///
/// Skills are found, in order of precedence:
/// 1. in the repository: `.agents/skills`, `.github/skills` and `.claude/skills`
///    under the git root (any depth);
/// 2. in `ai.lock` (written by spm): each locked skill, and the skills bundled
///    in each locked plugin. The pinned commit is read from the spm store
///    (`~/.spm/store`) when present, or else fetched into the nano-coder cache.
///    `spm install` is never run, because it edits the workspace;
/// 3. in the user's `~/.agents/skills`.
///
/// A later skill with the same name as an earlier one is ignored.
module nano.skills;

import std.algorithm : all, any, canFind, sort, startsWith, endsWith, filter, map, countUntil;
import std.array : array, join, split;
import std.conv : to;
import std.file;
import std.format : format;
import std.json;
import std.path;
import std.process : environment;
import std.string : strip, stripLeft, stripRight, indexOf, lineSplitter, toLower, chompPrefix, KeepTerminator;
import std.uni : isWhite;
import nano.llm : ToolDefinition;
import nano.tools : ToolError, lossyUtf8;

enum toolName = "load_skill";
private enum skillFile = "SKILL.md";
private enum lockFile = "ai.lock";
private enum manifestFile = "ai.json";
/// Cap on the `SKILL.md` text returned by `load_skill`.
private enum maxSkillBytes = 32 * 1024;
/// Cap on the skill index in the system prompt.
private enum maxIndexBytes = 8 * 1024;
private enum maxDescriptionChars = 400;
private enum maxListedFiles = 50;
/// How deep below a skills directory to look for `SKILL.md`.
private enum maxScanDepth = 4;
private enum fetchTimeoutSecs = 120;

/// `[skills]` in config.toml.
struct SkillsConfig
{
    bool enabled = true;
    /// Skill directories relative to the git root.
    string[] dirs = [".agents/skills", ".github/skills", ".claude/skills"];
    /// User skill directories (`~/` is expanded).
    string[] userDirs = ["~/.agents/skills"];
    /// Load skills pinned in the repository's `ai.lock`.
    bool aiLock = true;
    /// Fetch `ai.lock` commits that are not in the spm store or the cache.
    bool fetch = true;
    /// Git hosts `ai.lock` entries may be fetched from (`*`: any; `file`: file:// URLs).
    string[] allowedHosts = ["github.com"];

    /// Read the `[skills]` table (absent keys keep their defaults).
    static SkillsConfig fromToml(JSONValue t)
    {
        SkillsConfig c;
        if (t.type != JSONType.object) return c;
        string[] strs(JSONValue v) { return v.array.map!(x => x.str).array; }
        if (auto v = "enabled" in t) c.enabled = v.boolean;
        if (auto v = "dirs" in t) c.dirs = strs(*v);
        if (auto v = "user_dirs" in t) c.userDirs = strs(*v);
        if (auto v = "ai_lock" in t) c.aiLock = v.boolean;
        if (auto v = "fetch" in t) c.fetch = v.boolean;
        if (auto v = "allowed_hosts" in t) c.allowedHosts = strs(*v);
        return c;
    }
}

/// Where a skill came from.
struct Source
{
    enum Kind { workspace, user, lock }
    Kind kind;
    string git, commit;

    string label() const
    {
        final switch (kind)
        {
        case Kind.workspace: return "repository";
        case Kind.user: return "user";
        case Kind.lock: return format("ai.lock: %s @ %s", git, commit[0 .. commit.length < 8 ? $ : 8]);
        }
    }
}

struct Skill
{
    string name;
    string description;
    /// The skill's folder (contains `SKILL.md`), canonical.
    string dir;
    Source source;
}

/// Where to look outside the repository (injectable for tests).
struct Locations
{
    string home;
    /// spm's content store (`$SPM_HOME/store`, default `~/.spm/store`).
    string spmStore;
    /// nano-coder's own checkout cache for `ai.lock` commits.
    string cache;

    static Locations fromEnv()
    {
        Locations l;
        l.home = environment.get("HOME", null);
        auto spmHome = environment.get("SPM_HOME", l.home.length ? buildPath(l.home, ".spm") : null);
        if (spmHome.length) l.spmStore = buildPath(spmHome, "store");
        version (OSX)
            auto cacheBase = l.home.length ? buildPath(l.home, "Library", "Caches") : null;
        else
            auto cacheBase = environment.get("XDG_CACHE_HOME", l.home.length ? buildPath(l.home, ".cache") : null);
        if (cacheBase.length) l.cache = buildPath(cacheBase, "nano-coder", "skills");
        return l;
    }
}

final class Skills
{
    Skill[] skills;
    /// Problems found while loading (bad lock entries, failed fetches...).
    string[] warnings;
    private bool[string] seen;

    static Skills discover(string cwd, const ref SkillsConfig config)
    {
        return discoverIn(cwd, config, Locations.fromEnv);
    }

    static Skills discoverIn(string cwd, const ref SkillsConfig config, Locations locations)
    {
        auto s = new Skills;
        auto c = canonical(cwd);
        if (c is null) c = cwd;
        auto root = gitRoot(c);
        if (root is null) root = c;
        // Confine workspace skill discovery to the repository root: a configured
        // directory that canonicalizes outside it (a symlinked `.agents/skills`)
        // is rejected.
        auto confine = canonical(root);
        foreach (dir; config.dirs) s.addDir(buildPath(root, dir), Source(Source.Kind.workspace), confine);
        if (config.aiLock) s.addLock(root, config, locations);
        foreach (dir; config.userDirs)
        {
            string path;
            if (dir.startsWith("~/"))
            {
                if (!locations.home.length) continue;
                path = buildPath(locations.home, dir[2 .. $]);
            }
            else path = dir;
            s.addDir(path, Source(Source.Kind.user), null);
        }
        return s;
    }

    private void addDir(string dir, Source source, string confine)
    {
        // Canonicalize the configured directory and keep discovery inside it, so
        // a symlinked `SKILL.md` or skill folder can't pull in an outside file.
        auto root = canonical(dir);
        if (root is null) return;
        if (confine !is null && !startsWithPath(root, confine)) return;
        string[] found;
        scan(root, root, 0, found);
        foreach (skillDir; found)
        {
            Skill sk;
            if (readSkill(skillDir, null, source, sk)) push(sk);
        }
    }

    private void push(Skill sk)
    {
        if (sk.name in seen) return;
        seen[sk.name] = true;
        skills ~= sk;
    }

    private void addLock(string root, const ref SkillsConfig config, Locations locations)
    {
        auto lockPath = buildPath(root, lockFile);
        if (!lockPath.exists || !lockPath.isFile)
        {
            auto manifest = buildPath(root, manifestFile);
            if (manifest.exists && manifest.isFile)
                warnings ~= format("%s has no %s next to it, so its skills are not loaded (run spm to pin them)",
                    manifestFile, lockFile);
            return;
        }
        JSONValue lock;
        try lock = parseJSON(readText(lockPath));
        catch (Exception e) { warnings ~= format("%s: %s", lockFile, e.msg); return; }
        foreach (kind; ["skills", "plugins"])
        {
            if (lock.type != JSONType.object || kind !in lock) continue;
            auto table = lock[kind];
            if (table.type != JSONType.object) { warnings ~= format("%s: `%s` must be a table", lockFile, kind); continue; }
            // BTreeMap order, as in Rust.
            auto names = table.object.keys.sort.array;
            foreach (name; names)
            {
                try loadLocked(name, table[name], kind == "plugins", config, locations);
                catch (Exception e)
                    warnings ~= format("%s %s `%s`: %s", lockFile, kind == "plugins" ? "plugin" : "skill", name, e.msg);
            }
        }
    }

    private void loadLocked(string name, JSONValue entry, bool isPlugin, const ref SkillsConfig config,
            Locations locations)
    {
        auto locked = Locked.parse(entry);
        locked.validate(name);
        auto checkout = canonical(checkoutFor(locked, config, locations));
        if (checkout is null) throw new Exception("checkout is missing");
        auto rel = locked.path.length ? locked.path : ".";
        auto content = within(checkout, buildPath(checkout, rel));
        if (content is null) throw new Exception(format("path `%s` is missing or outside the checkout", rel));
        auto source = Source(Source.Kind.lock, locked.git, locked.commit);
        if (!isPlugin)
        {
            if (within(checkout, buildPath(content, skillFile)) is null)
                throw new Exception(format("no %s inside the checkout at the locked path", skillFile));
            Skill sk;
            if (!readSkill(content, name, source, sk)) throw new Exception(format("no %s in the locked path", skillFile));
            push(sk);
            return;
        }
        auto skillsRel = pluginSkillsDir(content);
        auto skillsDir = within(checkout, buildPath(content, skillsRel));
        if (skillsDir is null || !skillsDir.isDir) return;
        auto dirs = dirEntries(skillsDir, SpanMode.shallow, false).map!(e => e.name).array.sort.array;
        foreach (d; dirs)
        {
            auto rp = within(checkout, d);
            if (rp is null || within(checkout, buildPath(rp, skillFile)) is null) continue;
            Skill sk;
            if (readSkill(rp, null, source, sk)) push(sk);
        }
    }

    bool empty() const { return skills.length == 0; }

    string[] names() const { return skills.map!(s => s.name.idup).array; }

    /// The skill index appended to the system prompt (empty without skills).
    string renderIndex() const
    {
        if (!skills.length) return "";
        string out_ = "\n\n# Skills\n\nSkills are instructions for specific kinds of task. When a task matches a skill below, "
            ~ "call `" ~ toolName ~ "` with its name and follow what it says before you start. Load only the skills that apply.\n";
        long budget = cast(long) maxIndexBytes - cast(long) out_.length;
        string[] omitted;
        foreach (s; skills)
        {
            auto line = format("\n- `%s`: %s", s.name, s.description);
            if (cast(long) line.length > budget) { omitted ~= "`" ~ s.name ~ "`"; continue; }
            budget -= line.length;
            out_ ~= line;
        }
        if (omitted.length) out_ ~= "\n- Also (descriptions omitted for space): " ~ omitted.join(", ");
        if (out_.length > maxIndexBytes) out_ = truncateUtf8(out_, maxIndexBytes);
        return out_;
    }

    /// Run the `load_skill` tool.
    string load(JSONValue args) const
    {
        if (args.type == JSONType.string)
        {
            try args = parseJSON(args.str);
            catch (Exception) args = JSONValue(null);
        }
        if (args.type != JSONType.object || "name" !in args || args["name"].type != JSONType.string)
            throw new ToolError(toolName ~ " needs `name`");
        auto name = args["name"].str.strip;
        auto i = skills.countUntil!(s => s.name == name);
        if (i < 0)
            throw new ToolError(format("no skill named %s; available: %s", JSONValue(name).toString, names.join(", ")));
        auto skill = skills[i];
        // Re-check containment at read time: SKILL.md may since have been
        // swapped for a symlink escaping the directory.
        auto file = within(skill.dir, buildPath(skill.dir, skillFile));
        if (file is null || !file.isFile)
            throw new ToolError(format("%s is not a regular file inside the skill directory", buildPath(skill.dir, skillFile)));
        auto text = lossyUtf8(cast(ubyte[]) read(file));
        string[2][] fields;
        auto body_ = frontMatter(text, fields);
        auto out_ = format("Skill: %s\nSource: %s\nDirectory: %s\n\n%s", skill.name, skill.source.label, skill.dir,
            cap(body_.strip, maxSkillBytes));
        string[] files;
        listFiles(skill.dir, skill.dir, 0, files);
        files = files.filter!(f => f != skillFile).array;
        if (files.length)
        {
            out_ ~= "\n\nOther files in this skill (absolute paths; read them with read_file when the skill refers to them):";
            foreach (f; files[0 .. files.length < maxListedFiles ? $ : maxListedFiles])
                out_ ~= "\n- " ~ buildPath(skill.dir, f);
            if (files.length > maxListedFiles) out_ ~= format("\n- ... and %s more", files.length - maxListedFiles);
        }
        return out_;
    }
}

ToolDefinition definition()
{
    return ToolDefinition(toolName,
        "Load a skill: step-by-step instructions for a kind of task, listed under \"Skills\" in the system prompt. "
        ~ "Call it before starting a task that matches a skill's description, then follow the instructions.",
        parseJSON(`{"type":"object","properties":{"name":{"type":"string","description":"The skill's name, exactly as listed."}},"required":["name"]}`));
}

// ---- helpers ----

/// The rp path of `p` (symlinks resolved), or null if it doesn't exist.
string canonical(string p) @trusted
{
    import core.sys.posix.stdlib : realpath;
    import core.stdc.stdlib : free;
    import std.string : toStringz, fromStringz;
    auto r = realpath(p.toStringz, null);
    if (r is null) return null;
    scope (exit) free(r);
    return r.fromStringz.idup;
}

private bool startsWithPath(string path, string root)
{
    return path == root || path.startsWith(root.endsWith("/") ? root : root ~ "/");
}

/// `path` canonicalized, if it exists and stays inside `root` (already canonical) and outside `.git`.
private string within(string root, string path)
{
    auto rp = canonical(path);
    if (rp is null || !startsWithPath(rp, root)) return null;
    if (rp.pathSplitter.canFind(".git")) return null;
    return rp;
}

/// The nearest directory at or above `dir` holding `.git`.
string gitRoot(string dir)
{
    for (auto d = dir;;)
    {
        if (buildPath(d, ".git").exists) return d;
        auto up = d.dirName;
        if (up == d) return null;
        d = up;
    }
}

/// Folders containing `SKILL.md` under `dir`; a skill's own subfolders are not searched.
private void scan(string root, string dir, size_t depth, ref string[] out_)
{
    auto sf = within(root, buildPath(dir, skillFile));
    if (sf !is null && sf.isFile) { out_ ~= dir; return; }
    if (depth >= maxScanDepth) return;
    string[] dirs;
    try
        foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
        {
            if (e.name.baseName.startsWith(".")) continue;
            auto rp = within(root, e.name);
            if (rp !is null && rp.isDir) dirs ~= rp;
        }
    catch (FileException) return;
    dirs.sort();
    foreach (sub; dirs) scan(root, sub, depth + 1, out_);
}

private bool readSkill(string dir, string nameOverride, Source source, out Skill sk)
{
    string text;
    try text = lossyUtf8(cast(ubyte[]) read(buildPath(dir, skillFile)));
    catch (Exception) return false;
    string[2][] fields;
    auto body_ = frontMatter(text, fields);
    string field(string key)
    {
        foreach (f; fields) if (f[0] == key && f[1].length) return f[1];
        return null;
    }
    auto name = nameOverride.length ? nameOverride : field("name");
    if (!name.length) name = dir.baseName;
    name = name.strip;
    if (!name.length || name.any!(c => c == '/' || c == '\\' || c == '`')) return false;
    auto description = field("description");
    if (!description.length)
        foreach (l; body_.lineSplitter)
        {
            auto t = l.strip;
            if (t.length && !t.startsWith("#")) { description = t; break; }
        }
    if (!description.length) description = "(no description)";
    description = description.split.join(" ");
    if (description.to!dstring.length > maxDescriptionChars)
        description = description.to!dstring[0 .. maxDescriptionChars].to!string ~ "...";
    auto c = canonical(dir);
    sk = Skill(name, description, c !is null ? c : dir, source);
    return true;
}

/// Split YAML front matter (`---` … `---`) into top-level `key: value` pairs
/// and the body. Handles quoted values and `>` / `|` blocks.
string frontMatter(string text, out string[2][] fields)
{
    text = text.chompPrefix("\uFEFF");
    auto lines = text.lineSplitter!(KeepTerminator.yes).array;
    if (!lines.length || lines[0].stripRight != "---") return text;
    size_t offset = lines[0].length;
    string[] yaml;
    bool closed;
    foreach (line; lines[1 .. $])
    {
        offset += line.length;
        if (line.stripRight == "---") { closed = true; break; }
        yaml ~= line.stripRight("\r\n");
    }
    if (!closed) return text;
    string blockKey;
    bool literal, inBlock;
    foreach (line; yaml)
    {
        bool indented = line.length && (line[0] == ' ' || line[0] == '\t');
        if (indented)
        {
            if (inBlock)
                foreach (ref f; fields)
                    if (f[0] == blockKey)
                    {
                        if (f[1].length) f[1] ~= literal ? "\n" : " ";
                        f[1] ~= line.strip;
                        break;
                    }
            continue;
        }
        inBlock = false;
        auto colon = line.indexOf(':');
        if (colon < 0) continue;
        auto key = line[0 .. colon].strip;
        auto value = line[colon + 1 .. $].strip;
        if (["", ">", ">-", ">+", "|", "|-", "|+"].canFind(value))
        {
            inBlock = true;
            blockKey = key;
            literal = value.startsWith("|");
            fields ~= [key, ""];
            continue;
        }
        if (value.length >= 2 && ((value[0] == '"' && value[$ - 1] == '"') || (value[0] == '\'' && value[$ - 1] == '\'')))
            value = value[1 .. $ - 1];
        fields ~= [key, value];
    }
    return text[offset < text.length ? offset : $ .. $];
}

private string truncateUtf8(string s, size_t max)
{
    if (s.length <= max) return s;
    auto end = max;
    while (end > 0 && (s[end] & 0xC0) == 0x80) end--;
    return s[0 .. end];
}

private string cap(string text, size_t max)
{
    if (text.length <= max) return text;
    auto total = text.length;
    for (auto end = max;; end--)
    {
        while (end > 0 && (text[end] & 0xC0) == 0x80) end--;
        auto out_ = format("%s\n\n[... truncated: %s of %s bytes shown; read the rest with read_file]", text[0 .. end], end, total);
        if (out_.length <= max || end == 0) return out_;
    }
}

private void listFiles(string root, string dir, size_t depth, ref string[] out_)
{
    if (depth > maxScanDepth || out_.length > maxListedFiles * 4) return;
    string[] paths;
    try
        foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
            if (!e.name.baseName.startsWith(".")) paths ~= e.name;
    catch (FileException) return;
    paths.sort();
    foreach (p; paths)
    {
        // Only entries whose rp target stays inside the skill directory.
        auto rp = within(root, p);
        if (rp is null) continue;
        if (rp.isDir) listFiles(root, rp, depth + 1, out_);
        else out_ ~= rp[root.length + 1 .. $];
    }
}

private bool relativeInside(string path)
{
    if (!path.length || path.isAbsolute) return false;
    return path.pathSplitter.all!(c => c != ".." && c != "/");
}

/// spm's store key: `<repo-name hint>-<FNV-1a 64 of the URL>@<sha>`.
string storeKey(string url, string sha)
{
    ulong h = 0xcbf2_9ce4_8422_2325UL;
    foreach (ubyte b; cast(const(ubyte)[]) url)
    {
        h ^= b;
        h *= 0x0000_0100_0000_01b3UL;
    }
    auto u = url;
    while (u.endsWith("/")) u = u[0 .. $ - 1];
    auto cut = u.length;
    foreach_reverse (i, c; u) if (c == '/' || c == ':') { cut = i; break; }
    auto last = cut < u.length ? u[cut + 1 .. $] : u;
    while (last.endsWith(".git")) last = last[0 .. $ - 4];
    string hint;
    foreach (c; last)
    {
        import std.ascii : isAlphaNum;
        if (c.isAlphaNum && hint.length < 32) hint ~= c;
    }
    return format("%s-%016x@%s", hint, h, sha);
}

private struct Locked
{
    string git, commit, path, store;

    static Locked parse(JSONValue e)
    {
        if (e.type != JSONType.object) throw new Exception("entry must be a table");
        string req(string k)
        {
            if (k !in e || e[k].type != JSONType.string) throw new Exception(format("missing field `%s`", k));
            return e[k].str;
        }
        Locked l;
        l.git = req("git");
        l.commit = req("commit");
        l.store = req("store");
        if ("path" in e && e["path"].type == JSONType.string) l.path = e["path"].str;
        return l;
    }

    /// `ai.lock` is committed to the repository, so it is untrusted input.
    void validate(string name) const
    {
        if (!name.length || name == "." || name == ".." || name.any!(c => c == '/' || c == '\\' || c == '\0'))
            throw new Exception("invalid name");
        if (commit.length != 40 || !commit.all!(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            throw new Exception(format("commit `%s` is not a full 40-character lowercase SHA", commit));
        auto expected = storeKey(git, commit);
        if (store != expected)
            throw new Exception(format("store key `%s` does not match `%s` derived from git+commit", store, expected));
        if (path.length && !relativeInside(path))
            throw new Exception(format("path `%s` must be relative and stay inside the repository", path));
    }
}

/// The skills folder a plugin declares in `.claude-plugin/plugin.json` (default `skills`).
private string pluginSkillsDir(string plugin)
{
    auto p = buildPath(plugin, ".claude-plugin", "plugin.json");
    string rel = "skills";
    if (p.exists)
    {
        JSONValue meta;
        try meta = parseJSON(readText(p));
        catch (Exception e) throw new Exception(format("parsing %s: %s", p, e.msg));
        if (meta.type == JSONType.object && "skills" in meta && meta["skills"].type == JSONType.string)
            rel = meta["skills"].str;
    }
    rel = rel.chompPrefix("./");
    while (rel.endsWith("/")) rel = rel[0 .. $ - 1];
    if (!rel.length) rel = "skills";
    if (!relativeInside(rel)) throw new Exception(format("plugin skills dir `%s` must stay inside the plugin", rel));
    return rel;
}

private bool headIs(string dir, string commit)
{
    try return readText(buildPath(dir, ".git", "HEAD")).strip == commit;
    catch (Exception) return false;
}

/// A checkout of the locked commit: the spm store's if it has one, else the
/// cache's, fetching into the cache when allowed.
private string checkoutFor(const ref Locked locked, const ref SkillsConfig config, Locations locations)
{
    foreach (base; [locations.spmStore, locations.cache])
        if (base.length && headIs(buildPath(base, locked.store), locked.commit)) return buildPath(base, locked.store);
    if (!config.fetch) throw new Exception("commit is not in the spm store and fetching is off (skills.fetch = false)");
    auto host = gitHost(locked.git);
    if (!config.allowedHosts.any!(h => h == "*" || h.toLower == host))
        throw new Exception(format("host %s is not in skills.allowed_hosts, so %s was not fetched",
            JSONValue(host).toString, locked.git));
    if (!locations.cache.length) throw new Exception("no cache directory");
    import std.process : thisProcessID;
    mkdirRecurse(locations.cache);
    auto dest = buildPath(locations.cache, locked.store);
    auto tmp = buildPath(locations.cache, format(".tmp-%s-%s", thisProcessID, locked.store));
    void rm(string d) { try if (d.exists) rmdirRecurse(d); catch (Exception) {} }
    rm(tmp);
    try fetchCommit(locked.git, locked.commit, tmp);
    catch (Exception e)
    {
        rm(tmp);
        throw new Exception(format("fetching %s @ %s: %s", locked.git, locked.commit[0 .. 8], e.msg));
    }
    rm(dest);
    try rename(tmp, dest);
    catch (Exception) rm(tmp); // another process may have fetched it at the same time
    if (!headIs(dest, locked.commit))
        throw new Exception(format("checkout of %s @ %s is not at the locked commit", locked.git, locked.commit[0 .. 8]));
    return dest;
}

/// Host of a git URL (`https://host/...`, `ssh://user@host:port/...`, `user@host:path`), or `file`.
string gitHost(string url)
{
    if (url.startsWith("file://")) return "file";
    string authority;
    auto sep = url.indexOf("://");
    if (sep >= 0)
    {
        auto rest = url[sep + 3 .. $];
        auto slash = rest.indexOf('/');
        authority = slash >= 0 ? rest[0 .. slash] : rest;
    }
    else
    {
        auto colon = url.indexOf(':');
        if (colon < 0) return null;
        authority = url[0 .. colon];
    }
    auto at = authority.length;
    foreach_reverse (i, c; authority) if (c == '@') { at = i; break; }
    auto host = at < authority.length ? authority[at + 1 .. $] : authority;
    auto colon = host.indexOf(':');
    if (colon >= 0) host = host[0 .. colon];
    return host.length ? host.toLower : null;
}

private void fetchCommit(string url, string sha, string dest)
{
    mkdirRecurse(dest);
    git(dest, ["init", "-q"]);
    git(dest, ["remote", "add", "origin", url]);
    try git(dest, ["fetch", "-q", "--depth", "1", "origin", sha]);
    catch (Exception) git(dest, ["fetch", "-q", "origin"]);
    git(dest, ["-c", "advice.detachedHead=false", "checkout", "-q", "--detach", sha]);
}

private void git(string dir, string[] args)
{
    import std.process : pipeProcess, Redirect, tryWait, kill, wait, Config;
    import core.thread : Thread;
    import core.time : msecs, seconds, MonoTime;
    import std.stdio : File;
    import std.exception : collectException;
    auto env = ["GIT_TERMINAL_PROMPT": "0"];
    auto devnull = File("/dev/null", "r");
    auto errPath = buildPath(tempDir, format("nano-d-git-%s.err", MonoTime.currTime.ticks));
    auto errF = File(errPath, "w");
    scope (exit) collectException(remove(errPath));
    import std.process : spawnProcess;
    auto pid = spawnProcess(["git"] ~ args, devnull, File("/dev/null", "w"), errF, env, Config.none, dir);
    auto deadline = MonoTime.currTime + fetchTimeoutSecs.seconds;
    for (;;)
    {
        auto r = tryWait(pid);
        if (r.terminated)
        {
            if (r.status == 0) return;
            errF.close();
            throw new Exception(format("git %s: %s", args.join(" "), readText(errPath).strip));
        }
        if (MonoTime.currTime > deadline)
        {
            kill(pid);
            wait(pid);
            throw new Exception(format("git %s timed out", args.join(" ")));
        }
        Thread.sleep(50.msecs);
    }
}

// ---- tests (ported from skills.rs) ----

version (unittest)
{
    private string tmpRoot(string name)
    {
        auto d = buildPath(tempDir, "nano-d-skills-" ~ name);
        if (d.exists) rmdirRecurse(d);
        mkdirRecurse(d);
        return canonical(d);
    }

    private void put(string path, string text)
    {
        mkdirRecurse(path.dirName);
        std.file.write(path, text);
    }

    private string skillMd(string name, string description)
    {
        return format("---\nname: %s\ndescription: %s\n---\n\n# %s\n\nDo the %s thing.\n", name, description, name, name);
    }

    private Locations locs(string base)
    {
        return Locations(buildPath(base, "home"), buildPath(base, "spm/store"), buildPath(base, "cache"));
    }

    private SkillsConfig cfg()
    {
        SkillsConfig c;
        c.allowedHosts = ["file"];
        return c;
    }

    private string runGit(string dir, string[] args)
    {
        import std.process : execute, Config;
        auto r = execute(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ~ args,
            null, Config.none, size_t.max, dir);
        assert(r.status == 0, "git " ~ args.join(" ") ~ ": " ~ r.output);
        return r.output.strip;
    }
}

unittest // cap_keeps_truncated_body_within_max
{
    import std.array : replicate;
    auto out_ = cap("x".replicate(1024), 256);
    assert(out_.length <= 256 && out_.canFind("truncated"));
}

unittest // parses_front_matter_blocks_and_quotes
{
    string[2][] f;
    auto body_ = frontMatter("---\nname: \"pdf\"\ndescription: >\n  Fill PDF forms\n  and merge files.\nlicense: MIT\n---\nBody\n", f);
    assert(f[0] == ["name", "pdf"] && f[1] == ["description", "Fill PDF forms and merge files."] && f[2] == ["license", "MIT"]);
    assert(body_ == "Body\n");
    body_ = frontMatter("# No front matter\n", f);
    assert(!f.length && body_ == "# No front matter\n");
}

unittest // discovers_repository_and_user_skills_with_precedence
{
    auto dir = tmpRoot("discover");
    auto repo = buildPath(dir, "repo");
    put(buildPath(repo, ".agents/skills/review/SKILL.md"), skillMd("review", "Review a PR."));
    put(buildPath(repo, ".claude/skills/group/deploy/SKILL.md"), skillMd("deploy", "Deploy it."));
    put(buildPath(repo, ".agents/skills/review/scripts/check.sh"), "echo ok");
    mkdirRecurse(buildPath(repo, ".git"));
    mkdirRecurse(buildPath(repo, "sub"));
    auto home = buildPath(dir, "home");
    put(buildPath(home, ".agents/skills/review/SKILL.md"), skillMd("review", "User review (shadowed)."));
    put(buildPath(home, ".agents/skills/notes/SKILL.md"), "# Notes\n\nKeep notes tidy.\n");

    auto c = cfg();
    auto s = Skills.discoverIn(buildPath(repo, "sub"), c, locs(dir));
    assert(s.names == ["review", "deploy", "notes"], s.names.join(","));
    assert(s.skills[0].source.kind == Source.Kind.workspace && s.skills[2].source.kind == Source.Kind.user);
    assert(s.skills[2].description == "Keep notes tidy.");
    assert(!s.warnings.length);
    auto index = s.renderIndex;
    assert(index.canFind("# Skills") && index.canFind("- `review`: Review a PR.") && !index.canFind("shadowed"));
    auto loaded = s.load(parseJSON(`{"name":"review"}`));
    assert(loaded.canFind("Do the review thing.") && !loaded.canFind("description:"));
    auto script = buildPath(s.skills[0].dir, "scripts/check.sh");
    assert(loaded.canFind("- " ~ script) && script.isAbsolute, loaded);
    try { s.load(parseJSON(`{"name":"nope"}`)); assert(0); }
    catch (ToolError e) assert(e.msg.canFind("available: review, deploy, notes"));
}

unittest // no_skills_means_no_index
{
    auto dir = tmpRoot("none");
    auto c = cfg();
    auto s = Skills.discoverIn(dir, c, locs(dir));
    assert(s.empty && s.renderIndex == "");
}

unittest // loads_ai_lock_skills_and_plugin_skills_by_fetching_into_the_cache
{
    auto dir = tmpRoot("lock");
    auto src = buildPath(dir, "src");
    put(buildPath(src, "skills/lint/SKILL.md"), skillMd("lint-upstream-name", "Lint the code."));
    put(buildPath(src, "plugin/.claude-plugin/plugin.json"), `{"name":"p","skills":"./bundled"}`);
    put(buildPath(src, "plugin/bundled/triage/SKILL.md"), skillMd("triage", "Triage issues."));
    runGit(src, ["init", "-q"]);
    runGit(src, ["add", "-A"]);
    runGit(src, ["commit", "-qm", "init"]);
    auto sha = runGit(src, ["rev-parse", "HEAD"]);
    auto url = "file://" ~ src;
    auto repo = buildPath(dir, "repo");
    mkdirRecurse(buildPath(repo, ".git"));
    JSONValue entry(string path)
    {
        return JSONValue(["git": url, "reference": "branch:main", "commit": sha, "path": path, "store": storeKey(url, sha)]);
    }
    JSONValue lock = ["skills": JSONValue(["lint": entry("skills/lint")]), "plugins": JSONValue(["p": entry("plugin")])];
    put(buildPath(repo, "ai.lock"), lock.toString);

    auto c = cfg();
    auto s = Skills.discoverIn(repo, c, locs(dir));
    assert(!s.warnings.length, s.warnings.join("\n"));
    assert(s.names == ["lint", "triage"], s.names.join(","));
    assert(s.skills[0].source.kind == Source.Kind.lock && s.skills[0].source.commit == sha);
    assert(headIs(buildPath(dir, "cache", storeKey(url, sha)), sha));
    // The workspace is left alone.
    assert(dirEntries(repo, SpanMode.shallow).array.length == 2);
    // Second run reads the cache; fetching is not needed.
    c.fetch = false;
    assert(Skills.discoverIn(repo, c, locs(dir)).names == ["lint", "triage"]);
}

unittest // prefers_the_spm_store_and_guards_untrusted_lock_entries
{
    import std.array : replicate;
    auto dir = tmpRoot("guard");
    auto url = "https://github.com/acme/skills.git";
    auto sha = "a".replicate(40);
    auto store = buildPath(dir, "spm/store", storeKey(url, sha));
    put(buildPath(store, ".git/HEAD"), sha ~ "\n");
    put(buildPath(store, "fmt/SKILL.md"), skillMd("fmt", "Format files."));
    auto repo = buildPath(dir, "repo");
    mkdirRecurse(buildPath(repo, ".git"));
    JSONValue e(string git, string commit, string path, string st)
    {
        JSONValue j = ["git": git, "reference": "tag:v1", "commit": commit, "store": st];
        if (path !is null) j["path"] = path;
        return j;
    }
    put(buildPath(dir, "secret/SKILL.md"), "---\nname: secret\ndescription: TOP SECRET\n---\n");
    mkdirRecurse(buildPath(store, "leak"));
    symlink(buildPath(dir, "secret/SKILL.md"), buildPath(store, "leak/SKILL.md"));
    auto b40 = "b".replicate(40);
    JSONValue skills = [
        "fmt": e(url, sha, "fmt", storeKey(url, sha)),
        "escape": e(url, sha, "../../etc", storeKey(url, sha)),
        "forged": e(url, sha, "fmt", "other@x"),
        "leak": e(url, sha, "leak", storeKey(url, sha)),
        "short": e(url, "abc", null, "x"),
        "other": e("https://evil.example/x.git", b40, null, storeKey("https://evil.example/x.git", b40)),
    ];
    put(buildPath(repo, "ai.lock"), JSONValue(["skills": skills]).toString);
    SkillsConfig c;
    auto s = Skills.discoverIn(repo, c, locs(dir));
    assert(s.names == ["fmt"], s.names.join(","));
    auto w = s.warnings.join("\n");
    assert(w.canFind("`escape`: path `../../etc` must be relative"), w);
    assert(w.canFind("`forged`: store key"), w);
    assert(w.canFind("`short`: commit"), w);
    assert(w.canFind("`leak`: no SKILL.md inside the checkout"), w);
    assert(w.canFind("`other`: host \"evil.example\" is not in skills.allowed_hosts"), w);
}

unittest // warns_about_ai_json_without_a_lock
{
    auto dir = tmpRoot("manifest");
    mkdirRecurse(buildPath(dir, ".git"));
    put(buildPath(dir, "ai.json"), "{}");
    auto c = cfg();
    assert(Skills.discoverIn(dir, c, locs(dir)).warnings[0].canFind("ai.json has no ai.lock"));
}

unittest // parses_git_hosts, store_key_matches_spm
{
    import std.array : replicate;
    assert(gitHost("https://github.com/a/b.git") == "github.com");
    assert(gitHost("ssh://git@GitHub.com:22/a/b") == "github.com");
    assert(gitHost("git@github.com:a/b.git") == "github.com");
    assert(gitHost("file:///tmp/x") == "file");
    auto z = "0".replicate(40);
    assert(storeKey("https://github.com/camunda/skills.git", z) == "skills-f3b38a5efdfe31f3@" ~ z);
}
