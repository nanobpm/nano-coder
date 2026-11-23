/// Cross-session history (issue #271, part of #264): `sessions_list` and the
/// `session` argument of `history_search`/`history_read`, so an agent can read
/// another session's log instead of the user copying context between sessions
/// by hand.
///
/// Everything here is read-only and bounded: another session's log is streamed
/// through the same `history_search`/`history_read` machinery as the current
/// one (never loaded whole beyond what those already hold, and capped by the
/// same byte limits), and a live session's log is only read — never locked,
/// moved or rewritten. "Live" is probed with the session log's own flock: a
/// running nano-coder holds it exclusively for the life of its writer.
///
/// Permissions: a session whose working directory is the current workspace
/// (or below it) may be read outright. Reading one from another directory
/// goes through the permission policy as a read of that log (`Policy.checkIn`
/// with the log's absolute path), so a `Read(...)` deny rule still hides it
/// and an unverifiable read is blocked unless the sandbox confines it.
module nano.cross_session;

@safe:

import std.algorithm : canFind, startsWith, map;
import std.array : array, join;
import std.format : format;
import std.json;
import std.string : toLower, strip;
import std.conv : to;

import nano.paths : startsWithPath, normalize;
import nano.permissions : Policy;
import nano.safeio : jsonText;
import nano.session_history : HistoryError;
import nano.session_index : Summary, list;

/// One session as `sessions_list` reports it.
struct SessionInfo
{
    string id;
    /// Working directory the session started in (null for older logs).
    string cwd;
    /// The model's few-word title, else the first telling prompt, else the first prompt.
    string title;
    /// RFC 3339, as written in the log header.
    string createdAt;
    /// When the log was last written (RFC 3339).
    string lastUsed;
    /// The log file `history_search`/`history_read` stream.
    string path;
    /// A process currently has the log open (it holds the log's flock).
    bool live;
}

/// What `Summary` names a session by (title, else first telling prompt).
private string nameOf(const ref Summary s) pure @safe
{
    return s.title.length ? s.title
        : s.firstTellingPrompt.length ? s.firstTellingPrompt
        : s.firstPrompt;
}

private SessionInfo infoOf(Summary s, bool live) @safe
{
    import nano.session : stamp;
    SessionInfo i;
    i.id = s.id;
    i.cwd = s.cwd;
    i.title = nameOf(s);
    i.createdAt = s.createdAt;
    i.lastUsed = stamp(s.lastUsed);
    i.path = s.path;
    i.live = live;
    return i;
}

/// Whether a process currently holds `path`'s session lock. Probed by opening
/// the log read-only and attempting the same non-blocking exclusive flock a
/// writer takes: `contended` means a live writer holds it. The probe never
/// waits and closes at once, so a live session is never disturbed.
private bool isLive(string path) @safe
{
    import nano.safeio : tryLockFile, LockResult;
    import std.file : exists;
    if (!path.exists) return false;
    return tryLockFile(path) == LockResult.contended;
}

/// Every session in `dir` with at least one prompt, newest first, with the
/// live flag probed. `filter` keeps sessions whose id, title or working
/// directory contains it (case-insensitive). The current session is included
/// (marked live) so an id prefix can be checked against it too.
///
/// Discovery is permission-aware (issue #271): a session another workspace's
/// policy denies is omitted before its log is opened for summarizing and
/// before any cached metadata (title, first request) is returned, so
/// `sessions_list` can't leak a denied session's existence or contents. The
/// check reads only each log's header line for its recorded cwd.
SessionInfo[] listSessions(ref Policy policy, string dir, string cwd, string filter = null) @safe
{
    import nano.session : logHeaderCwd;
    SessionInfo[] out_;
    // Deny before the index opens or reports a log (issue #271): the header's
    // cwd decides whether the policy judges the log a foreign read.
    bool deniedPath(string path)
    {
        auto sessionCwd = logHeaderCwd(path);
        if (inWorkspace(sessionCwd, cwd)) return false;
        return policy.checkIn("read_file", JSONValue(["path": JSONValue(path)]), cwd) !is null;
    }
    foreach (s; list(dir, false, &deniedPath))
    {
        auto i = infoOf(s, isLive(s.path));
        if (!i.cwd.length) i.cwd = logHeaderCwd(s.path);
        if (filter.length)
        {
            auto f = filter.toLower;
            if (!i.id.toLower.canFind(f) && !i.title.toLower.canFind(f)
                && !(i.cwd.length && i.cwd.toLower.canFind(f))) continue;
        }
        out_ ~= i;
    }
    return out_;
}

/// One line of the `sessions_list` result.
private string lineOf(const ref SessionInfo i) @safe
{
    auto label = i.title.length ? i.title : "(no title)";
    auto out_ = format("%s  %s  %s  %s", i.id, label, i.cwd.length ? i.cwd : "(unknown cwd)",
        i.lastUsed.length >= 19 ? i.lastUsed[0 .. 19] : i.lastUsed);
    if (i.live) out_ ~= "  [live]";
    return out_;
}

/// The `sessions_list` tool result: one `#id title cwd last-activity [live]`
/// line per session, newest first, capped like other tool output (the
/// remainder is spilled to a file).
string listResult(ref Policy policy, string dir, string cwd, JSONValue args) @safe
{
    import nano.tools : truncateOutputBytes, defaultMaxOutput;
    string filter;
    if (args.type == JSONType.object)
        if (auto f = "filter" in args.objectNoRef)
            if (f.type == JSONType.string) filter = f.str;
    auto sessions = listSessions(policy, dir, cwd, filter);
    if (!sessions.length)
        return filter.length
            ? format("No sessions match %s.", JSONValue(filter).jsonText)
            : "No saved sessions.";
    return truncateOutputBytes(sessions.map!lineOf.array.join("\n"), defaultMaxOutput, "sessions-list");
}

/// `needle` as one session: an exact id, a unique id prefix, or a title match
/// (case-insensitive; every exact-title match beats any substring match, so
/// two sessions sharing a title report ambiguity instead of silently picking
/// one). An ambiguous match throws a HistoryError listing the candidates.
/// With `fallback`, an empty `needle` resolves to that session (the caller's
/// own log).
SessionInfo resolve(string needle, SessionInfo[] sessions, scope const(SessionInfo)* fallback = null) @safe
{
    if (!needle.length)
    {
        if (fallback !is null) return *fallback;
        throw new HistoryError("no current session to read; pass a session id, prefix or title");
    }
    SessionInfo[] candidates;
    foreach (i; sessions)
    {
        if (i.id == needle) return i;
        if (i.id.startsWith(needle) || (i.title.length && i.title.toLower.canFind(needle.toLower)))
            candidates ~= i;
    }
    // Case-insensitive exact titles beat the other substring matches; several
    // sessions may share one title (identical first-request fallbacks too).
    SessionInfo[] exact;
    foreach (ref c; candidates)
        if (c.title.toLower == needle.toLower) exact ~= c;
    if (exact.length) candidates = exact;
    if (candidates.length == 1) return candidates[0];
    if (!candidates.length)
        throw new HistoryError(format("no session matches %s; sessions_list shows the ids and titles",
            JSONValue(needle).jsonText));
    throw new HistoryError(format("session %s is ambiguous; candidates:\n%s",
        JSONValue(needle).jsonText, candidates.map!lineOf.array.join("\n")));
}

/// The `session` argument of a history call: absent (read the caller's own
/// log) or a non-empty string.
string sessionArg(JSONValue args) pure @safe
{
    if (args.type != JSONType.object) return null;
    auto v = "session" in args.objectNoRef;
    if (v is null || v.type == JSONType.null_) return null;
    if (v.type != JSONType.string || !v.str.strip.length)
        throw new HistoryError("session must be a non-empty string (an id, unique id prefix or title)");
    return v.str.strip;
}

/// Whether `sessionCwd` is the current workspace or below it: those sessions
/// may be read without a policy check.
/// Both paths are canonicalized first (symlinks resolved), so a recorded cwd
/// like `<workspace>/link` that points outside the workspace is foreign; a
/// relative or unresolvable path is never in the workspace (fail closed).
bool inWorkspace(string sessionCwd, string cwd) @safe
{
    import nano.paths : canonicalize;
    import std.path : isAbsolute;
    if (!sessionCwd.length || !cwd.length || !sessionCwd.isAbsolute || !cwd.isAbsolute) return false;
    auto s = canonicalize(sessionCwd), c = canonicalize(cwd);
    if (s is null || c is null) return false;
    return startsWithPath(normalize(s), normalize(c));
}

/// Null when the session's log may be read from `cwd`, else the message the
/// model sees. A session from another directory is judged as a read of its
/// log file, so `Read(...)` deny rules still cover it and an unverifiable
/// read is blocked unless the sandbox confines it.
string readDenied(ref Policy policy, const ref SessionInfo s, string cwd) @safe
{
    if (inWorkspace(s.cwd, cwd)) return null;
    return policy.checkIn("read_file", JSONValue(["path": JSONValue(s.path)]), cwd);
}

/// Whether reading `s` from `cwd` needs the user's confirmation first
/// (issue #271's default-ask): any session outside the current workspace
/// that the policy didn't already deny. In-workspace sessions never ask.
bool needsConfirmation(const ref SessionInfo s, string cwd) @safe
{
    return !inWorkspace(s.cwd, cwd);
}

/// The question a cross-workspace read asks before it proceeds.
string confirmQuestion(const ref SessionInfo s) @safe
{
    auto label = s.title.length ? s.title : "(no title)";
    return format("Read session %s (%s) from %s? It belongs to another workspace.", s.id, label,
        s.cwd.length ? s.cwd : "an unknown directory");
}

unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    import nano.session : SessionLog;
    import nano.llm : Message;

    auto dir = buildPath(tempDir, "nano-d-cross-session-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    import nano.paths : canonicalize;
    import std.string : toUpper;
    auto root = buildPath(canonicalize(tempDir), "nano-d-cross-session-ws");
    auto alpha = buildPath(root, "alpha"), beta = buildPath(root, "beta");
    mkdirRecurse(buildPath(alpha, "sub")); mkdirRecurse(beta);
    scope (exit) rmdirRecurse(root);
    auto liveLog = new SessionLog(dir, "m", alpha, "sess-live");
    {
        auto finished = new SessionLog(dir, "m", beta, "sess-done");
        finished.input("in-1", "finish the parser slice");
        finished.close();
    }
    liveLog.input("in-2", "keep working on the live one");

    Policy noRules;
    auto all = listSessions(noRules, dir, alpha);
    assert(all.length == 2, all.to!string);
    auto live = all[0].id == "sess-live" ? all[0] : all[1];
    auto done = all[0].id == "sess-done" ? all[0] : all[1];
    assert(live.live, "the open log is live");
    assert(!done.live, "a closed log is not live");
    assert(live.title == "keep working on the live one");
    assert(listSessions(noRules, dir, alpha, "done").length == 1);
    assert(listSessions(noRules, dir, alpha, alpha.toUpper).length == 1, "filter is case-insensitive");
    assert(!listSessions(noRules, dir, alpha, "nope").length);

    // A deny rule hides a foreign session from the listing entirely, cached
    // title and all; an in-workspace session stays.
    import nano.permissions : parseRule;
    Policy denying;
    denying.deny = [parseRule("Read(" ~ dir ~ "/sess-done.jsonl)")];
    auto visible = listSessions(denying, dir, alpha);
    assert(visible.length == 1 && visible[0].id == "sess-live", visible.to!string);

    // Resolve: exact id, unique prefix, title substring; ambiguity lists candidates.
    assert(resolve("sess-done", all).id == "sess-done");
    assert(resolve("sess-d", all).id == "sess-done");
    assert(resolve("parser", all).id == "sess-done");
    assert(resolve("", all, &live).id == live.id, "a blank needle falls back to the current session");
    bool threw;
    try resolve("sess", all);
    catch (HistoryError e)
    {
        threw = true;
        assert(e.msg.canFind("ambiguous") && e.msg.canFind("sess-live") && e.msg.canFind("sess-done"), e.msg);
    }
    assert(threw);
    threw = false;
    try resolve("zzz", all);
    catch (HistoryError e) { threw = true; assert(e.msg.canFind("no session matches"), e.msg); }
    assert(threw);

    // Two sessions titled alike (identical first-request fallbacks too) are
    // ambiguous by title, case-insensitively; one exact title still wins over
    // a substring of the other.
    SessionInfo a, b, c;
    a.id = "aaaa1111"; a.title = "Fix the parser"; a.path = "/x/a.jsonl"; a.cwd = alpha;
    b.id = "bbbb2222"; b.title = "fix the parser"; b.path = "/x/b.jsonl"; b.cwd = alpha;
    c.id = "cccc3333"; c.title = "Fix the parser tests"; c.path = "/x/c.jsonl"; c.cwd = alpha;
    auto titled = [a, b, c];
    threw = false;
    try resolve("FIX THE PARSER", titled);
    catch (HistoryError e)
    {
        threw = true;
        assert(e.msg.canFind("ambiguous") && e.msg.canFind("aaaa1111") && e.msg.canFind("bbbb2222")
            && !e.msg.canFind("cccc3333"), e.msg);
    }
    assert(threw, "duplicate titles are ambiguous, not first-wins");
    assert(resolve("fix the parser tests", titled).id == "cccc3333", "one exact title beats the substring matches");

    // Workspace check: same tree or below it is fine, a sibling is not.
    assert(inWorkspace(alpha, alpha));
    assert(inWorkspace(buildPath(alpha, "sub"), alpha));
    assert(!inWorkspace(beta, alpha));
    assert(!inWorkspace(null, alpha));
    assert(!inWorkspace("relative/alpha", alpha), "a relative cwd is never in the workspace");
    assert(!inWorkspace(buildPath(alpha, "missing"), alpha), "an unresolvable cwd fails closed");
    // A symlink inside the workspace that points at a sibling is foreign.
    {
        import std.file : symlink;
        auto link = buildPath(alpha, "linked");
        symlink(beta, link);
        assert(!inWorkspace(link, alpha), "a symlink to a sibling escapes the workspace");
        SessionInfo viaLink = done; viaLink.cwd = link;
        assert(needsConfirmation(viaLink, alpha), "a symlinked foreign cwd still asks");
    }

    Policy p;
    assert(readDenied(p, live, alpha) is null);
    assert(readDenied(p, done, alpha) is null, "no rules: another workspace is still allowed");
    p.deny = [parseRule("Read(" ~ dir ~ "/sess-done.jsonl)")];
    auto denied = readDenied(p, done, alpha);
    assert(denied !is null && denied.canFind("denies read_file"), denied is null ? done.path : denied);
    assert(readDenied(p, live, alpha) is null, "a session in the workspace skips the policy");

    // Default-ask: a foreign session needs confirmation, an in-workspace one doesn't.
    assert(needsConfirmation(done, alpha));
    assert(!needsConfirmation(live, alpha));
    assert(confirmQuestion(done).canFind("sess-done") && confirmQuestion(done).canFind(beta));

    liveLog.close();
}
