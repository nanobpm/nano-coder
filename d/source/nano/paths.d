/// Filesystem path helpers with Rust `std::path::Path` semantics, used by the
/// permission guard (port of the path helpers in src/permissions.rs).
///
/// Paths are plain strings. `components` mirrors `Path::components`: a leading
/// `/` is the root, empty and interior `.` segments are dropped, and `..` is
/// kept. `startsWith` is component-wise, like `Path::starts_with`.
module nano.paths;

@safe:

import std.algorithm : startsWith;
import std.array : join;
import std.string : split;

/// `Path::components`, as strings (`"/"` for the root).
string[] components(string path) pure
{
    string[] out_;
    if (path.startsWith("/")) out_ ~= "/";
    foreach (i, seg; path.split("/"))
    {
        if (!seg.length) continue;
        if (seg == "." && !(i == 0 && !path.startsWith("/"))) continue;
        out_ ~= seg;
    }
    return out_;
}

/// Rebuild a path from components.
string fromComponents(const string[] comps) pure
{
    if (!comps.length) return "";
    if (comps[0] == "/") return "/" ~ comps[1 .. $].join("/");
    return comps.join("/");
}

/// `Path::parent`: null for the root or an empty path.
string parent(string path) pure
{
    auto c = components(path);
    if (!c.length || (c.length == 1 && c[0] == "/")) return null;
    if (c.length == 1) return "";
    return fromComponents(c[0 .. $ - 1]);
}

/// `Path::file_name`: null when the last component is the root, `.` or `..`.
string fileName(string path) pure
{
    auto c = components(path);
    if (!c.length) return null;
    auto last = c[$ - 1];
    return (last == "/" || last == "." || last == "..") ? null : last;
}

bool isAbsolute(string path) pure { return path.startsWith("/"); }

/// `Path::join`: an absolute `rel` replaces `base`.
string joinPath(string base, string rel) pure
{
    if (rel.isAbsolute || !base.length) return rel;
    if (!rel.length) return base.length && base[$ - 1] == '/' ? base : base ~ "/";
    return base[$ - 1] == '/' ? base ~ rel : base ~ "/" ~ rel;
}

/// Component-wise prefix test (`Path::starts_with`).
bool startsWithPath(string path, string prefix) pure
{
    auto p = components(path), q = components(prefix);
    if (q.length > p.length) return false;
    return p[0 .. q.length] == q;
}

/// Path equality by components (`/a/b/` == `/a/b`).
bool samePath(string a, string b) pure { return components(a) == components(b); }

size_t componentCount(string path) pure { return components(path).length; }

/// Collapse `.` and `..` without touching the filesystem; always absolute.
string normalize(string path) pure
{
    string[] out_;
    foreach (c; components(path))
    {
        if (c == "..") { if (out_.length) out_ = out_[0 .. $ - 1]; }
        else if (c != "/" && c != ".") out_ ~= c;
    }
    return "/" ~ out_.join("/");
}

/// `realpath(3)`, or null when the path does not exist.
string canonicalize(string path) @trusted
{
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.string : toStringz, fromStringz;
    if (!path.length) return null;
    auto p = realpath(path.toStringz, null);
    if (p is null) return null;
    scope (exit) free(p);
    return fromStringz(p).idup;
}

/// The target of a symlink, or null when `path` is not one.
string readLink(string path) @trusted
{
    import std.file : readLink_ = readLink;
    try return readLink_(path);
    catch (Exception) return null;
}

bool isSymlink(string path) @trusted
{
    import std.file : isSymlink_ = isSymlink;
    try return isSymlink_(path);
    catch (Exception) return false;
}

bool isDir(string path) @trusted
{
    import std.file : exists, isDir_ = isDir;
    try return exists(path) && isDir_(path);
    catch (Exception) return false;
}

/// The user's home directory, or null.
string homeDir() @trusted
{
    import std.process : environment;
    auto h = environment.get("HOME");
    return h.length ? h : null;
}

string expandTilde(string path)
{
    auto home = homeDir();
    if (home is null) return path;
    if (path == "~") return home;
    if (path.startsWith("~/")) return joinPath(home, path[2 .. $]);
    return path;
}

/// Resolve through symlinks by canonicalizing the deepest existing ancestor
/// and re-appending the not-yet-existing tail.
string resolveSymlinks(string path)
{
    string existing = path;
    string[] rest;
    while (true)
    {
        auto real_ = canonicalize(existing);
        if (real_ !is null)
        {
            auto p = real_;
            foreach_reverse (part; rest) p = joinPath(p, part);
            return normalize(p);
        }
        auto par = parent(existing), name = fileName(existing);
        if (par is null || name is null) return normalize(path);
        rest ~= name;
        existing = par;
    }
}

/// Resolve `..` and intermediate symlinks, leaving the final component as is.
string resolveParent(string path)
{
    auto par = parent(path), name = fileName(path);
    if (par !is null && name !is null) return normalize(joinPath(resolveSymlinks(par), name));
    return resolveSymlinks(path);
}

/// Resolve a redirection/`dd` target against `cwd`, following symlinks
/// (including dangling ones).
string resolveTarget(string target, string cwd)
{
    auto expanded = expandTilde(target);
    auto joined = expanded.isAbsolute ? expanded : joinPath(cwd, expanded);
    return followDanglingSymlink(resolveSymlinks(joined));
}

string followDanglingSymlink(string path)
{
    auto current = path;
    foreach (_; 0 .. 40)
    {
        auto target = readLink(current);
        if (target is null) return current;
        string next;
        if (target.isAbsolute) next = target;
        else
        {
            auto par = parent(current);
            next = par is null ? target : joinPath(par, target);
        }
        current = resolveSymlinks(next);
    }
    return current;
}

unittest
{
    assert(components("/a//./b/") == ["/", "a", "b"]);
    assert(components("./a") == [".", "a"]);
    assert(parent("/a/b") == "/a");
    assert(parent("/") is null);
    assert(parent("a") == "");
    assert(fileName("/a/..") is null);
    assert(startsWithPath("/etc/passwd", "/etc"));
    assert(!startsWithPath("/etcetera", "/etc"));
    assert(normalize("/a/b/../c/./d") == "/a/c/d");
    assert(normalize("/..") == "/");
    assert(componentCount("/etc") == 2);
    assert(joinPath("/w", "x/") == "/w/x/");
    assert(joinPath("/w", "/abs") == "/abs");
}

/// A string quoted like Rust's `{:?}`: only `"`, `\\` and control characters are escaped.
string debugQuote(string s) pure @safe
{
    import std.format : format;
    string out_ = "\"";
    foreach (dchar c; s)
    {
        switch (c)
        {
        case '"': out_ ~= `\"`; break;
        case '\\': out_ ~= `\\`; break;
        case '\n': out_ ~= `\n`; break;
        case '\t': out_ ~= `\t`; break;
        case '\r': out_ ~= `\r`; break;
        default:
            if (c < 0x20) out_ ~= format(`\u{%x}`, cast(uint) c);
            else out_ ~= c;
        }
    }
    return out_ ~ "\"";
}

unittest
{
    assert(debugQuote(`a/"b"`) == `"a/\"b\""`);
}
