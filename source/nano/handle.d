/// Session handles (issue #300, part of #264): a short, stable, user-chosen
/// name (`/name perf-matrix`, `--name perf-matrix`) that `session_send`, the
/// history tools, `sessions_list` and `--resume`/`/resume` accept in place of
/// the opaque session id.
///
/// A handle is lowercase letters, digits and `-`, at most 32 characters, and
/// can't look like a session id (`sess-…`). It is persisted in the session
/// log (a `name` record; the last one wins) and in the session index, so it
/// survives `/resume`, `/relaunch` and `/update`.
///
/// Uniqueness among running sessions uses the peers registry directory (the
/// one inter-session messages listen in): a running session that holds a
/// handle owns `<peers dir>/<handle>.name`, whose content is its session id.
/// "Running" is the session log's own flock (a live writer holds it), so a
/// stopped session's claim is stale and can be taken over.
module nano.handle;

@safe:

import std.algorithm : startsWith;
import std.format : format;
import std.string : strip;

/// The longest handle accepted.
enum size_t maxHandleLength = 32;

/// Why `handle` is not a valid handle, or null when it is.
string invalidHandle(string handle) pure nothrow
{
    if (!handle.length) return "a handle can't be empty";
    if (handle.length > maxHandleLength)
        return "a handle is at most 32 characters";
    foreach (char c; handle)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'))
            return "a handle is lowercase letters, digits and -";
    if (handle.startsWith("sess-") || handle == "sess")
        return "a handle can't look like a session id (sess-…)";
    if (handle == "last") return "`last` already means the newest session";
    return null;
}

unittest
{
    assert(invalidHandle("perf-matrix") is null);
    assert(invalidHandle("nano-engine2") is null);
    assert(invalidHandle("a") is null);
    assert(invalidHandle("") !is null);
    assert(invalidHandle("Perf") !is null);
    assert(invalidHandle("perf matrix") !is null);
    assert(invalidHandle("perf_matrix") !is null);
    assert(invalidHandle("sess-1234") !is null);
    assert(invalidHandle("last") !is null);
    assert(invalidHandle("abcdefghijklmnopqrstuvwxyz012345") is null);
    assert(invalidHandle("abcdefghijklmnopqrstuvwxyz0123456") !is null);
}

/// The registry file for `handle` in the peers directory `dir`.
string handlePath(string dir, string handle) pure
{
    import std.path : buildPath;
    return buildPath(dir, handle ~ ".name");
}

/// Whether session `id`'s log in `sessionDir` is held by a running writer.
bool sessionRunning(string sessionDir, string id)
{
    import std.file : exists;
    import std.path : buildPath;
    import nano.safeio : tryLockFile, LockResult;
    if (!plausibleId(id)) return false; // a corrupt registry entry names no session
    auto path = buildPath(sessionDir, id ~ ".jsonl");
    return path.exists && tryLockFile(path) == LockResult.contended;
}

/// Whether `id` could name a session log (1-128 of `[A-Za-z0-9._-]`, not
/// starting with `.`), checked without throwing.
bool plausibleId(string id) pure nothrow @nogc
{
    if (!id.length || id.length > 128 || id[0] == '.') return false;
    foreach (char c; id)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'))
            return false;
    return true;
}

unittest
{
    assert(plausibleId("sess-20261124T101010-1234abcd") && plausibleId("s.a_b"));
    assert(!plausibleId("") && !plausibleId(".x") && !plausibleId("../etc") && !plausibleId("a b"));
}

/// A registry entry: the holder's session id and the session directory its
/// log lives in (sessions with different `session_dir`s share the registry).
private struct Entry
{
    string id;
    string sessionDir; /// null in an entry written without one
}

/// The entry recorded for `handle` (`Entry.init` when none).
private Entry recordedEntry(string dir, string handle)
{
    import std.file : exists, readText, FileException;
    import std.string : lineSplitter;
    import std.array : array;
    auto p = handlePath(dir, handle);
    if (!p.exists) return Entry.init;
    import std.utf : UTFException;
    string text;
    try text = readText(p);
    catch (FileException) return Entry.init; // unreadable (or removed meanwhile): no holder
    catch (UTFException) return Entry.init; // not text: no holder
    auto lines = text.lineSplitter.array;
    if (!lines.length) return Entry.init;
    return Entry(lines[0].strip, lines.length > 1 ? lines[1].strip : null);
}

/// The session id recorded for `handle`, or null.
private string recorded(string dir, string handle)
{
    return recordedEntry(dir, handle).id;
}

/// Whether `e`'s session is running: checked in the directory it recorded,
/// else in `sessionDir`.
private bool entryRunning(const Entry e, string sessionDir)
{
    return e.id.length && sessionRunning(e.sessionDir.length ? e.sessionDir : sessionDir, e.id);
}

/// The id of the running session that holds `handle`, or null.
string runningHolder(string dir, string sessionDir, string handle)
{
    if (invalidHandle(handle) !is null) return null;
    auto e = recordedEntry(dir, handle);
    return entryRunning(e, sessionDir) ? e.id : null;
}

/// Claim `handle` for session `id`: null on success, else why it was
/// refused (another running session holds it; its id is in the message).
string claim(string dir, string sessionDir, string handle, string id)
{
    import std.file : write, rename, FileException;
    import std.process : thisProcessID;
    import nano.peers : ensureDir;
    import nano.safeio : lockExclusive;
    if (auto why = invalidHandle(handle)) return why;
    if (!ensureDir(dir)) return format("can't create the registry directory %s", dir);
    // Serialize check-then-write across processes: two sessions claiming the
    // same handle at once would otherwise both see no running holder. The
    // lock is released when `guard` closes (also if the process dies).
    auto guard = lockExclusive(handlePath(dir, handle) ~ ".lock");
    if (!guard.held) return format("can't lock the handle registry for %s", handle);
    auto holder = runningHolder(dir, sessionDir, handle);
    if (holder.length && holder != id)
        return format("the handle %s is held by running session %s", handle, holder);
    auto p = handlePath(dir, handle);
    auto tmp = format("%s.tmp-%s", p, thisProcessID);
    try
    {
        import std.path : absolutePath;
        write(tmp, id ~ "\n" ~ absolutePath(sessionDir) ~ "\n");
        rename(tmp, p);
    }
    catch (FileException e) return format("can't record the handle: %s", e.msg);
    return null;
}

/// Drop `id`'s claim on `handle` (a claim another session took over is left).
void release(string dir, string handle, string id)
{
    import std.file : remove, FileException;
    if (!handle.length || invalidHandle(handle) !is null) return;
    if (recorded(dir, handle) != id) return;
    try remove(handlePath(dir, handle));
    catch (FileException) {} // already gone (a concurrent release): nothing to drop
}

/// Every handle a running session holds in `dir`, by session id.
string[string] runningHandles(string dir, string sessionDir)
{
    import std.file : dirEntries, SpanMode, exists, FileException;
    import std.path : baseName, stripExtension;
    string[string] byId;
    if (!dir.exists) return byId;
    string[] files;
    try
        foreach (e; dirEntries(dir, "*.name", SpanMode.shallow)) files ~= e.name;
    catch (FileException) return byId; // unreadable registry: no handles known
    foreach (f; files)
    {
        auto handle = f.baseName.stripExtension;
        if (invalidHandle(handle) !is null) continue;
        auto e = recordedEntry(dir, handle);
        if (entryRunning(e, sessionDir)) byId[e.id] = handle;
    }
    return byId;
}

/// What `--resume` should be given to come back to session `id` named
/// `handle`: the handle when no other saved session in `sessionDir` had it
/// (so it can't resolve elsewhere), else the id.
string resumeArg(string sessionDir, string id, string handle)
{
    import nano.session_index : list;
    import std.file : FileException;
    if (!handle.length) return id;
    try
        foreach (s; list(sessionDir))
            if (s.id != id && s.name == handle) return id;
    catch (FileException) return id; // the sessions can't be read: the id always works
    return handle;
}

/// The `Session: …` line the banner, `/restart` and the exit print.
string sessionLine(string sessionDir, string id, string handle)
{
    return handle.length
        ? format("Session: %s · %s (resume with nano-coder --resume=%s)", handle, id, resumeArg(sessionDir, id, handle))
        : format("Session: %s (resume with nano-coder --resume=%s)", id, id);
}

/// The `/name` reply when showing the current handle.
string describe(string handle) pure
{
    return handle.length
        ? format("This session's handle is %s (other sessions reach it with session_send to \"%s\"; /name --clear removes it)",
            handle, handle)
        : "This session has no handle; set one with /name <handle>";
}

unittest
{
    import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists, readText;
    import std.path : buildPath;
    import std.process : thisProcessID;
    auto root = buildPath(tempDir, format("nano-handle-%s", thisProcessID));
    if (root.exists) rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    auto peers = buildPath(root, "peers"), sessions = buildPath(root, "sessions");
    mkdirRecurse(sessions);
    // A stopped session (log exists, no lock) holds nothing.
    import std.file : write;
    write(buildPath(sessions, "s-old.jsonl"), "{}\n");
    assert(claim(peers, sessions, "perf", "s-old") is null);
    assert(recorded(peers, "perf") == "s-old");
    import std.path : absolutePath;
    assert(recordedEntry(peers, "perf").sessionDir == absolutePath(sessions), "the holder's directory is recorded");
    assert(runningHolder(peers, sessions, "perf") is null, "a stopped holder is not running");
    // A stopped holder's handle is reusable by a running session (its open
    // log holds the writer's lock).
    import nano.session : SessionLog;
    auto live = new SessionLog(sessions, "mock/m", "/w", "s-live");
    scope (exit) live.close();
    assert(claim(peers, sessions, "perf", "s-live") is null);
    assert(runningHolder(peers, sessions, "perf") == "s-live");
    assert(runningHandles(peers, sessions) == ["s-live": "perf"]);
    // A running holder's handle is refused, naming the holder.
    auto refused = claim(peers, sessions, "perf", "s-other");
    import std.algorithm : canFind;
    assert(refused !is null && refused.canFind("s-live"), refused);
    // Re-claiming one's own handle is fine; release drops only one's own claim.
    assert(claim(peers, sessions, "perf", "s-live") is null);
    release(peers, "perf", "s-other");
    assert(handlePath(peers, "perf").exists);
    release(peers, "perf", "s-live");
    assert(!handlePath(peers, "perf").exists);
    assert(claim(peers, sessions, "Bad", "s-live") !is null);
    // The claim lock file is reusable once released, and the check under it still refuses.
    {
        import nano.safeio : lockExclusive;
        auto held = lockExclusive(handlePath(peers, "race") ~ ".lock");
        assert(held.held);
        held.release();
        assert(claim(peers, sessions, "race", "s-live") is null);
        assert(claim(peers, sessions, "race", "s-other") !is null, "the running holder wins");
    }
    assert(describe("perf").canFind("perf") && describe(null).canFind("/name"));
}
