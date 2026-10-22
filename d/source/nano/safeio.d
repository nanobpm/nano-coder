/// @safe access to the process's standard streams and other small escapes
/// from Phobos/POSIX calls that are not marked @safe. Each one is `@trusted`
/// on its own, with the reason it is memory safe next to it, so the rest of
/// the code base can be `@safe:` throughout (enforced by
/// `scripts/check-safe.sh`).
module nano.safeio;

@safe:

import std.stdio : File;

/// `std.stdio.stdout`. Phobos marks it @system only because the `File` is a
/// `__gshared` global; every `File` operation locks the stream itself.
@property ref File stdOut() @trusted
{
    import std.stdio : stdout;
    return stdout;
}

/// `std.stdio.stderr`; see `stdOut`.
@property ref File stdErr() @trusted
{
    import std.stdio : stderr;
    return stderr;
}

/// `std.file.read` as bytes. The `void[]` it returns is freshly allocated
/// and untyped, so viewing it as `ubyte[]` aliases nothing else.
ubyte[] readBytes(string path) @trusted
{
    import std.file : read;
    return cast(ubyte[]) read(path);
}

/// A byte buffer nothing else references, viewed as (possibly invalid) UTF-8
/// text. The caller must hand over the only reference: the bytes become
/// immutable, so a later write through another alias would break that.
string ownText(ubyte[] unique) @trusted pure nothrow
{
    return cast(string) unique;
}

/// `ownText` for a `char[]` buffer.
string ownText(char[] unique) @trusted pure nothrow
{
    return cast(string) unique;
}

// POSIX calls taking D strings and slices. Each passes a NUL-terminated copy
// (`toStringz`) or a slice's own pointer and length, so the C side never reads
// or writes past memory the caller owns.

/// `open(2)`; returns the fd or -1 (errno set).
int openPath(string path, int flags, uint mode = 0) @trusted
{
    import core.sys.posix.fcntl : open;
    import std.string : toStringz;
    import core.sys.posix.sys.types : mode_t;
    return open(path.toStringz, flags, cast(mode_t) mode);
}

/// `chmod(2)`; returns 0 or -1.
int chmodPath(string path, uint mode) @trusted
{
    import core.sys.posix.sys.stat : chmod;
    import std.string : toStringz;
    import core.sys.posix.sys.types : mode_t;
    return chmod(path.toStringz, cast(mode_t) mode);
}

/// `fchmod(2)`; returns 0 or -1.
int fchmodFd(int fd, uint mode) @trusted
{
    import core.sys.posix.sys.stat : fchmod;
    import core.sys.posix.sys.types : mode_t;
    return fchmod(fd, cast(mode_t) mode);
}

/// `stat(2)`'s `st_mode` for `path`; false when the path can't be stat'ed.
bool statMode(string path, out uint mode) @trusted
{
    import core.sys.posix.sys.stat : stat, stat_t;
    import std.string : toStringz;
    stat_t st;
    if (stat(path.toStringz, &st) != 0) return false;
    mode = st.st_mode;
    return true;
}

/// `write(2)` of (a prefix of) `data`; returns the bytes written or -1.
ptrdiff_t writeFd(int fd, const(ubyte)[] data) @trusted
{
    import core.sys.posix.unistd : write;
    return write(fd, data.ptr, data.length);
}

/// `read(2)` into `buf`; returns the bytes read, 0 at EOF, or -1.
ptrdiff_t readFd(int fd, ubyte[] buf) @trusted
{
    import core.sys.posix.unistd : read;
    return read(fd, buf.ptr, buf.length);
}

/// `kill(2)` (a negative `pid` signals the process group).
int killPid(int pid, int sig) @trusted
{
    import core.sys.posix.signal : kill;
    return kill(pid, sig);
}

/// `killpg(2)`.
int killGroup(int pgrp, int sig) @trusted
{
    import core.sys.posix.signal : killpg;
    return killpg(pgrp, sig);
}

/// `realpath(3)`: the canonical absolute path, or null when it can't be resolved.
string realPath(string path) @trusted
{
    import core.sys.posix.stdlib : realpath;
    import core.stdc.stdlib : free;
    import std.string : fromStringz, toStringz;
    auto p = realpath(path.toStringz, null);
    if (p is null) return null;
    scope (exit) free(p);
    return p.fromStringz.idup;
}

/// `std.file.dirEntries` collected into an array. Phobos marks the iterator
/// @system only for its reference-counted handle; the entries themselves are
/// plain values. Throws `FileException` as `dirEntries` does.
import std.file : DirEntry, SpanMode;
DirEntry[] listDir(string dir, SpanMode mode, bool followSymlink = false) @trusted
{
    import std.file : dirEntries;
    DirEntry[] r;
    foreach (DirEntry e; dirEntries(dir, mode, followSymlink)) r ~= e;
    return r;
}

/// Make `fd` non-blocking (`fcntl(F_SETFL, … | O_NONBLOCK)`).
void setNonBlocking(int fd) @trusted
{
    import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

/// Ignore SIGPIPE, so a child that closes its stdin can't kill the process.
void ignoreSigpipe() @trusted
{
    import core.stdc.signal : signal, SIG_IGN;
    import core.sys.posix.signal : SIGPIPE;
    signal(SIGPIPE, SIG_IGN);
}

import core.sys.posix.poll : pollfd;
/// `poll(2)` on `fds`; returns the ready count, 0 on timeout, or -1.
int pollFds(pollfd[] fds, int timeoutMs) @trusted
{
    import core.sys.posix.poll : poll, nfds_t;
    return poll(fds.ptr, cast(nfds_t) fds.length, timeoutMs);
}

// druntime's Condition and Thread methods carry no attributes, so they are
// @system; they only take the object's own lock and state.
import core.sync.condition : Condition;
import core.thread : Thread;

/// `c.notify()`.
void signalOne(Condition c) @trusted { c.notify(); }
/// `c.notifyAll()`.
void signalAll(Condition c) @trusted { c.notifyAll(); }
/// `c.wait()` (the caller holds `c`'s mutex).
void waitOn(Condition c) @trusted { c.wait(); }
/// `t.start()`.
Thread startThread(Thread t) @trusted { return t.start(); }
/// `t.join()`; rethrows what the thread threw.
void joinThread(Thread t) @trusted { t.join(); }

/// `exit(3)`: run C atexit handlers and end the process.
noreturn exitProcess(int status) @trusted
{
    import core.stdc.stdlib : exit;
    exit(status);
}

/// `std.stdio.readln` on stdin (@system only for the `__gshared` stdin).
string stdinLine() @trusted
{
    import std.stdio : readln;
    return readln();
}

unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    auto p = buildPath(tempDir, "nano-safeio-test");
    write(p, "hi");
    scope (exit) remove(p);
    assert(readBytes(p) == cast(const(ubyte)[]) "hi");
    assert(ownText(readBytes(p)) == "hi");
    assert(stdOut.isOpen && stdErr.isOpen);
}
