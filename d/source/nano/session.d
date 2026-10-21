/// Session logs (JSONL: a header line, then one message per line) and
/// project instructions (AGENTS.md and friends).
module nano.session;

import std.json;
import std.format : format;
import std.file;
import std.path;
import std.stdio : File;
import std.string : strip, lineSplitter;
import std.datetime.systime : Clock;
import std.process : environment;
import std.algorithm : sort, filter, map;
import std.array : array;
import nano.llm;

string sessionDir()
{
    if (auto x = environment.get("NANO_CODER_D_SESSIONS")) return x;
    version (OSX)
        return buildPath(expandTilde("~"), "Library", "Application Support", "nano-coder-d", "sessions");
    else
        return buildPath(environment.get("XDG_DATA_HOME", buildPath(expandTilde("~"), ".local", "share")), "nano-coder-d", "sessions");
}

class SessionLog
{
    string id;
    string path;
    private File f;

    this(string dir, string model, string cwd)
    {
        mkdirRecurse(dir);
        auto now = Clock.currTime;
        id = format("%04d%02d%02d-%02d%02d%02d-%04x", now.year, cast(int) now.month, now.day, now.hour, now.minute,
                now.second, (cast(uint) Clock.currStdTime) & 0xffff);
        path = buildPath(dir, id ~ ".jsonl");
        f = File(path, "a");
        JSONValue h = ["type": "session", "id": id, "model": model, "cwd": cwd, "started": now.toISOExtString];
        f.writeln(h.toString);
        f.flush();
    }

    /// Continue an existing log.
    this(string existingPath)
    {
        path = existingPath;
        id = existingPath.baseName.stripExtension;
        f = File(path, "a");
    }

    void append(const ref Message m)
    {
        JSONValue line = ["type": "message"];
        line["message"] = m.toJson;
        f.writeln(line.toString);
        f.flush();
    }
}

/// Messages recorded in a session log.
Message[] loadSession(string path)
{
    Message[] out_;
    foreach (line; readText(path).lineSplitter)
    {
        if (!line.strip.length) continue;
        auto j = parseJSON(line);
        if (j["type"].str == "message") out_ ~= Message.fromJson(j["message"]);
    }
    return out_;
}

/// Find a session by id, or "last" for the newest.
string findSession(string dir, string which)
{
    if (!dir.exists) throw new Exception("no sessions yet in " ~ dir);
    auto logs = dirEntries(dir, "*.jsonl", SpanMode.shallow).map!(e => e.name).array;
    if (!logs.length) throw new Exception("no sessions yet in " ~ dir);
    logs.sort!((a, b) => timeLastModified(a) < timeLastModified(b));
    if (which == "last" || !which.length) return logs[$ - 1];
    foreach (l; logs)
        if (l.baseName.stripExtension == which) return l;
    throw new Exception("no session " ~ which ~ " in " ~ dir);
}

/// Project instruction files from the git root down to `cwd` (first name
/// found per directory), plus the user's own `~/.config/nano-coder/AGENTS.md`.
string projectInstructions(string cwd, const string[] names = ["AGENTS.md", "CLAUDE.md"])
{
    string[] dirs;
    auto d = cwd;
    for (;;)
    {
        dirs = d ~ dirs;
        if (buildPath(d, ".git").exists) break;
        auto up = d.dirName;
        if (up == d) { dirs = [cwd]; break; } // not a repo: only cwd
        d = up;
    }
    string out_;
    auto user = buildPath(expandTilde("~"), ".config", "nano-coder", "AGENTS.md");
    if (user.exists) out_ ~= format("\n\n# User instructions (%s)\n\n%s", user, readText(user).strip);
    foreach (dir; dirs)
        foreach (n; names)
        {
            auto p = buildPath(dir, n);
            if (p.exists && p.isFile)
            {
                out_ ~= format("\n\n# Project instructions (%s)\n\n%s", p, readText(p).strip);
                break;
            }
        }
    return out_;
}

unittest
{
    auto dir = buildPath(tempDir, "nano-coder-d-session-test");
    if (dir.exists) rmdirRecurse(dir);
    auto log = new SessionLog(dir, "mock", "/x");
    auto m1 = Message.user("hello");
    auto m2 = Message.assistant("", [ToolCall.fromRaw("c", "bash", `{"command":"ls"}`)]);
    log.append(m1);
    log.append(m2);
    auto back = loadSession(findSession(dir, "last"));
    assert(back.length == 2 && back[0].content == "hello" && back[1].toolCalls[0].name == "bash");
    assert(findSession(dir, log.id) == log.path);
}

unittest
{
    auto root = buildPath(tempDir, "nano-coder-d-instr-test");
    if (root.exists) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, ".git"));
    mkdirRecurse(buildPath(root, "sub"));
    write(buildPath(root, "AGENTS.md"), "root rules");
    write(buildPath(root, "sub", "CLAUDE.md"), "sub rules");
    import std.string : indexOf;
    auto s = projectInstructions(buildPath(root, "sub"));
    assert(s.indexOf("root rules") >= 0 && s.indexOf("sub rules") > s.indexOf("root rules"));
}
