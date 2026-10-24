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
ptrdiff_t writeFd(int fd, scope const(ubyte)[] data) @trusted
{
    import core.sys.posix.unistd : write;
    return write(fd, data.ptr, data.length);
}

/// `dup(2)`; the new fd or -1.
int dupFd(int fd) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : dup;
    return dup(fd);
}

/// `dup2(2)`; `to` or -1.
int dup2Fd(int from, int to) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : dup2;
    return dup2(from, to);
}

/// `close(2)`; 0 or -1.
int closeFd(int fd) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : close;
    return close(fd);
}

/// `pipe(2)` into `fds` (read end, write end); 0 or -1.
int pipeFds(ref int[2] fds) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : pipe;
    return pipe(fds);
}

import core.sys.posix.termios : termios;
/// `tcgetattr(3)` into `t`; false on error (not a terminal).
bool tcGet(int fd, out termios t) @trusted nothrow @nogc
{
    import core.sys.posix.termios : tcgetattr;
    return tcgetattr(fd, &t) == 0;
}

/// `tcsetattr(3)` with `TCSANOW`; false on error.
bool tcSet(int fd, const ref termios t) @trusted nothrow @nogc
{
    import core.sys.posix.termios : tcsetattr, TCSANOW;
    return tcsetattr(fd, TCSANOW, &t) == 0;
}

/// A C signal handler. It runs asynchronously, so it is @system and must
/// only touch atomics and async-signal-safe calls.
alias SignalHandler = extern (C) void function(int) nothrow @nogc @system;

/// Install `handler` for `sig` with `sigaction(2)` (empty mask, no flags).
void onSignal(int sig, SignalHandler handler) @trusted nothrow @nogc
{
    import core.sys.posix.signal : sigaction, sigaction_t, sigemptyset;
    sigaction_t sa;
    sa.sa_handler = handler;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, null);
}

/// An `atexit(3)` handler.
alias ExitHandler = extern (C) void function() nothrow @system;

/// `atexit(3)`.
void atExit(ExitHandler f) @trusted nothrow @nogc
{
    import core.stdc.stdlib : atexit;
    atexit(f);
}

/// A `__gshared` value of a plain struct, read and written through @safe
/// code as `name` (getter and setter) over the storage `name_`. A struct copy
/// is not atomic, so this is only for state touched by one thread (or set
/// before the others start); keep anything shared across threads atomic.
mixin template GsharedValue(T, string name)
{
    mixin("private __gshared T " ~ name ~ "_;");
    mixin("@property T " ~ name ~ "() @trusted nothrow @nogc { return " ~ name ~ "_; }");
    mixin("@property void " ~ name ~ "(T v) @trusted nothrow @nogc { " ~ name ~ "_ = v; }");
}

/// Line-buffer `stdout` (`setvbuf(_IOLBF)`), so a pipe gets whole lines.
void lineBufferStdout() @trusted
{
    import std.stdio : stdout;
    import core.stdc.stdio : _IOLBF;
    stdout.setvbuf(4096, _IOLBF);
}

/// `write(2)` all of `s`, retrying short writes; stops at the first error.
void writeAllFd(int fd, scope const(char)[] s) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : write;
    while (s.length)
    {
        auto n = write(fd, s.ptr, s.length);
        if (n <= 0) return;
        s = s[n .. $];
    }
}

/// `read(2)` into `buf`; returns the bytes read, 0 at EOF, or -1.
ptrdiff_t readFd(int fd, scope ubyte[] buf) @trusted
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
int pollFds(scope pollfd[] fds, int timeoutMs) @trusted
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


/// A `__gshared` class reference read and written through @safe code, as
/// `name` (getter and setter) over the storage `name_`. `@trusted` because a
/// reference load or store is atomic on every target we build for; the
/// referenced objects lock themselves, so only the reference is shared.
mixin template GsharedRef(T, string name)
{
    mixin("__gshared T " ~ name ~ "_;");
    mixin("@property T " ~ name ~ "() @trusted nothrow @nogc { return " ~ name ~ "_; }");
    mixin("@property void " ~ name ~ "(T v) @trusted nothrow @nogc { " ~ name ~ "_ = v; }");
}

/// Rows and columns of the terminal on `fd` (TIOCGWINSZ), or zeros when
/// unknown. `ioctl` only writes the local `winsize`.
size_t[2] terminalSize(int fd = 1) @trusted nothrow @nogc
{
    import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
    winsize ws;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0 && ws.ws_col > 0) return [ws.ws_row, ws.ws_col];
    return [0, 0];
}

/// C `strtod` (correctly rounded, unlike `std.conv.to!double`) on `text`;
/// `consumed` is how many characters it read. The string is copied to a
/// NUL-terminated buffer, and `end` only points into that copy.
double cStrtod(string text, out size_t consumed) @trusted
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;
    auto z = text.toStringz;
    immutable(char)* end;
    auto v = strtod(z, &end);
    consumed = end - z;
    return v;
}

/// ditto
double cStrtod(string text)
{
    size_t n;
    return cStrtod(text, n);
}

import std.json : JSONValue, JSONType;
/// `v[key]` when `v` is an object holding it, else null. Phobos marks
/// `JSONValue.object` @system because it returns the AA by reference; this
/// only looks a key up and returns a pointer into the GC-owned table.
const(JSONValue)* jsonGet(return scope const ref JSONValue v, string key) @trusted
{
    if (v.type != JSONType.object) return null;
    return key in v.object;
}

/// A deep, mutable copy of `v`, so a `const` tree can be merged into a
/// mutable one without casting `const` away (and without the two sharing
/// subtrees). Numbers are copied as stored, never re-parsed.
JSONValue jsonCopy(const JSONValue v)
{
    final switch (v.type)
    {
        case JSONType.null_: return JSONValue(null);
        case JSONType.string: return JSONValue(v.str);
        case JSONType.integer: return JSONValue(v.integer);
        case JSONType.uinteger: return JSONValue(v.uinteger);
        case JSONType.float_: return JSONValue(v.floating);
        case JSONType.true_: return JSONValue(true);
        case JSONType.false_: return JSONValue(false);
        case JSONType.array:
            JSONValue[] a;
            foreach (e; v.arrayNoRef) a ~= jsonCopy(e);
            return JSONValue(a);
        case JSONType.object:
            JSONValue[string] o;
            foreach (k, e; v.objectNoRef) o[k] = jsonCopy(e);
            return JSONValue(o);
    }
}

@safe unittest
{
    import std.json : parseJSON;
    auto src = parseJSON(`{"a":[1,2.5,"x",true,null,{"b":18446744073709551615}]}`);
    const c = src;
    auto d = jsonCopy(c);
    assert(d.toString == src.toString);
    d["a"][0] = 9;
    assert(src["a"][0].integer == 1);
}

@safe unittest
{
    import std.json : parseJSON;
    size_t n;
    assert(cStrtod("0.7") == 0.7);
    assert(cStrtod("1.5x", n) == 1.5 && n == 3);
    auto j = parseJSON(`{"a":1}`);
    assert(jsonGet(j, "a").integer == 1 && jsonGet(j, "b") is null);
    auto n1 = JSONValue(1);
    assert(jsonGet(n1, "a") is null);
}
