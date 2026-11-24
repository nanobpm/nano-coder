/// @safe access to the process's standard streams and other small escapes
/// from Phobos/POSIX calls that are not marked @safe. Each one is `@trusted`
/// on its own, with the reason it is memory safe next to it, so the rest of
/// the code base can be `@safe:` throughout (enforced by
/// `scripts/check-safe.sh`).
module nano.safeio;

@safe:

import std.stdio : File;

/// druntime GC options, read once before `main`. The GC returns memory to
/// the OS only a whole pool at a time (`GC.minimize`), and by default pools
/// grow to 64 MB. After a resume parses a long session log, the survivors are
/// spread over those large pools, so almost none of the freed heap goes back
/// (a 59 MB log kept ~330 MB resident with 38 MB live). Small fixed-size pools
/// let far more of them empty out and be released: 336 -> 237 MB there.
/// `heapSizeFactor` (default 2) is how far the heap may outgrow the live
/// set before a collection: a resume's replay decodes thousands of folded
/// messages of short-lived garbage, and at 2 the heap doubled into pools the
/// few survivors then pinned. Resuming an 82 MB log settled at 139 MB at the
/// default, 91 MB at 1.25 (1.1: 82 MB, for ~8% more CPU on the resume).
extern (C) __gshared string[] rt_options = ["gcopt=maxPoolSize:4 incPoolSize:0 initReserve:0 heapSizeFactor:1.25"];

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

/// A file's bytes, reading at most `cap + 1`; null when it holds more than
/// `cap` (checked while reading, so a growing file can't slip past).
ubyte[] readCapped(string path, ulong cap) @safe
{
    import std.algorithm : min;
    import std.stdio : File;
    auto f = File(path, "rb");
    auto size = f.size; // a hint only: the file may grow while read
    auto buf = new ubyte[cast(size_t) min(cap + 1, size == ulong.max ? 64 * 1024 : size + 1)];
    size_t got;
    for (;;)
    {
        if (got == buf.length)
        {
            if (buf.length > cap) break;
            buf.length = cast(size_t) min(buf.length * 2, cap + 1);
        }
        auto r = f.rawRead(buf[got .. $]);
        if (!r.length) break;
        got += r.length;
    }
    if (got > cap) return null;
    return got ? buf[0 .. got] : [];
}

/// Replaces this process with `path` run with `args` (argv[0] included).
/// Returns only on failure, with the reason. `@trusted`: the strings are
/// copied into NUL-terminated buffers that outlive the call, and the array
/// ends in null as execv requires.
string execProgram(string path, const string[] args) @trusted
{
    import core.stdc.errno : errno;
    import core.stdc.string : strerror;
    import core.sys.posix.unistd : execv;
    import std.string : toStringz, fromStringz;
    const(char)*[] argv;
    foreach (a; args) argv ~= a.toStringz;
    argv ~= null;
    execv(path.toStringz, argv.ptr);
    return strerror(errno).fromStringz.idup;
}

/// `std.file.read` as immutable bytes: the buffer is freshly allocated and
/// only this result refers to it.
immutable(ubyte)[] readImmutableBytes(string path) @trusted
{
    import std.file : read;
    return cast(immutable(ubyte)[]) read(path);
}

/// `std.file.read` as (possibly invalid) UTF-8 text, without validating it.
string readRawText(string path) @trusted
{
    import std.file : read;
    return cast(string) read(path);
}

/// The bytes of `path` from byte `offset` to the end (`File.seek` and
/// `byChunk`; each chunk is copied before the buffer is reused).
ubyte[] readFrom(string path, ulong offset) @trusted
{
    import std.stdio : File;
    auto f = File(path, "rb");
    f.seek(offset);
    return readToEnd(f);
}

import std.stdio : File;
/// Everything left in `f` (a pipe or file), copied out of `byChunk`'s reused
/// buffer.
ubyte[] readToEnd(File f) @trusted
{
    ubyte[] r;
    foreach (chunk; f.byChunk(64 * 1024)) r ~= chunk;
    return r;
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
int openPath(string path, int flags, uint mode = 0) @trusted nothrow
{
    import core.sys.posix.fcntl : open;
    import std.string : toStringz;
    import core.sys.posix.sys.types : mode_t;
    return open(path.toStringz, flags, cast(mode_t) mode);
}

/// `chmod(2)`; returns 0 or -1.
int chmodPath(string path, uint mode) @trusted nothrow
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

/// `mkdir(2)` with an explicit mode (subject to the umask); returns 0 or -1
/// (errno set). Used where the mode is part of the contract — the peer
/// registry's 0700 directory (issue #272) — since `std.file.mkdir` always
/// passes 0777.
int mkdirMode(string path, uint mode) @trusted nothrow
{
    import core.sys.posix.sys.stat : mkdir;
    import std.string : toStringz;
    import core.sys.posix.sys.types : mode_t;
    return mkdir(path.toStringz, cast(mode_t) mode);
}

version (Posix)
{
    private import core.sys.posix.sys.socket : socklen_t, SOL_SOCKET;
    private import core.sys.posix.sys.types : uid_t, gid_t;
    private import std.socket : socket_t;
}

/// Duplicate a socket fd (`dup(2)`), returning `socket_t.init` on error.
/// Used so a background thread can wrap its own `std.socket.Socket` without
/// sharing the fd with another `Socket` whose GC finalizer would close it.
socket_t dupSocket(socket_t fd) nothrow @nogc
{
    auto n = dupFd(fd);
    return n < 0 ? socket_t.init : cast(socket_t) n;
}

/// The uid on the other end of a connected Unix-domain socket, or -1 when
/// the platform can't say. The peer registry (issue #272) drops a peer whose
/// uid is not the process's own, so a socket planted by another user is
/// never served (an unknown uid fails closed).
long socketPeerUid(socket_t fd) @trusted nothrow @nogc
{
    version (linux)
    {
        // SO_PEERCRED fills a ucred: the call writes only within `c` (its
        // size handed over through `n`).
        UCred c;
        socklen_t n = UCred.sizeof;
        if (getsockopt(fd, SOL_SOCKET, socPeercred, &c, &n) != 0) return -1;
        return c.uid;
    }
    else version (OSX)
    {
        uid_t uid;
        gid_t gid;
        if (getpeereid(fd, &uid, &gid) != 0) return -1;
        return uid;
    }
    else return -1; // unsupported platform: fail closed
}

version (linux)
{
    private enum socPeercred = 17; // SO_PEERCRED on Linux
    private struct UCred { int pid; uint uid; uint gid; }
    // getsockopt writes at most *optlen bytes at optval; here exactly the
    // UCred the length says.
    private extern (C) int getsockopt(socket_t, int, int, void*, socklen_t*) nothrow @nogc @system;
}
else version (OSX)
{
    private extern (C) int getpeereid(socket_t, uid_t*, gid_t*) nothrow @nogc @system;
}

/// How a non-blocking lock attempt ended.
enum LockResult { acquired, contended, unsupported }

/// Open `path` read-only and try the same exclusive non-blocking flock a
/// session writer holds for its life (issue #271: a `contended` answer means
/// a live process has the log open). The fd is closed before returning, so
/// the probe never holds the lock itself. `unsupported` is any other failure
/// (a missing file, ENOLCK, ...): the caller treats it as "not live".
/// EINTR is retried: an interrupted attempt says nothing about the lock.
LockResult tryLockFile(string path) @trusted nothrow
{
    import core.sys.posix.fcntl : O_RDONLY;
    import core.sys.posix.unistd : close;
    import core.stdc.errno : errno, EWOULDBLOCK, EAGAIN, EINTR;
    auto fd = openPath(path, O_RDONLY);
    if (fd < 0) return LockResult.unsupported;
    scope (exit) close(fd);
    for (;;)
    {
        if (flockFd(fd, flockEx | flockNb) == 0) return LockResult.acquired;
        immutable err = errno;
        if (err == EINTR) continue;
        return err == EWOULDBLOCK || err == EAGAIN ? LockResult.contended : LockResult.unsupported;
    }
}

// flock(2) takes an fd and flags, touching no memory.
private extern (C) pragma(mangle, "flock") int flockFd(int, int) nothrow @nogc @system;
private enum flockEx = 2, flockNb = 4;

/// An incremental gzip inflate stream (issue #271: history and the session
/// index stream a compressed log instead of inflating it whole). The zlib
/// state is heap-allocated C data owned between `open` and `close`; every
/// method writes only within the caller's buffers (sizes tracked in
/// avail_in/avail_out), so the struct is memory safe to drive from @safe
/// code through these small @trusted wrappers.
struct InflateStream
{
    private void* zs; // etc.c.zlib z_stream

    /// How one `inflateInto` ended.
    enum Rc { ok, streamEnd, error }

    private ubyte[] input; // owned copy of the bytes zlib is reading

    /// Whether the stream was never opened (or closed already).
    bool isNone() const pure @safe nothrow { return zs is null; }

    /// A gzip inflate stream; throws when zlib can't start.
    static InflateStream open(string path)
    {
        import etc.c.zlib : z_stream, inflateInit2;
        // zlib's C API writes only within the caller's buffers; the stream
        // struct is plain C data, heap-allocated so the caller holds a
        // pointer, not the raw struct.
        auto p = () @trusted {
            auto z = new z_stream;
            if (inflateInit2(z, 15 + 16) != 0 /* Z_OK */)
                throw new Exception("inflate init failed for " ~ path);
            return cast(void*) z;
        }();
        return InflateStream(p);
    }

    /// End the zlib stream (idempotent).
    void close()
    {
        import etc.c.zlib : z_stream, inflateEnd;
        if (zs is null) return;
        // inflateEnd touches only the stream struct.
        () @trusted { inflateEnd(cast(z_stream*) zs); }();
        zs = null;
    }

    /// Compressed bytes still waiting to be consumed.
    uint availIn()
    {
        import etc.c.zlib : z_stream;
        if (zs is null) return 0;
        // Reads one field of the C struct (zs checked non-null above).
        return (() @trusted => (cast(z_stream*) zs).avail_in)();
    }

    /// Room left in the last output buffer.
    uint availOut()
    {
        import etc.c.zlib : z_stream;
        if (zs is null) return 0;
        // Reads one field of the C struct (zs checked non-null above).
        return (() @trusted => (cast(z_stream*) zs).avail_out)();
    }

    /// Point the stream at the next compressed bytes. They are copied into
    /// a buffer the stream owns, so zlib never keeps a pointer into the
    /// caller's (possibly short-lived) memory between calls. At most
    /// `uint.max` bytes are taken; throws on an unopened stream.
    void feed(scope const(ubyte)[] data)
    {
        import etc.c.zlib : z_stream;
        if (zs is null) throw new Exception("inflate: stream not open");
        immutable n = data.length > uint.max ? uint.max : cast(uint) data.length;
        if (input.length < n) input = new ubyte[](n);
        input[0 .. n] = data[0 .. n];
        // next_in points at the stream's own GC buffer, which lives as long
        // as this struct (and is only replaced by a later feed that resets
        // next_in); avail_in never exceeds its length.
        () @trusted {
            auto z = cast(z_stream*) zs;
            z.next_in = input.ptr;
            z.avail_in = n;
        }();
    }

    /// Inflate into `buf` (at most `uint.max` bytes of it); the filled size
    /// is `min(buf.length, uint.max) - availOut`. Throws on an unopened
    /// stream.
    Rc inflateInto(scope ubyte[] buf)
    {
        import etc.c.zlib : z_stream, inflate, Z_NO_FLUSH, Z_STREAM_END, Z_OK, Z_BUF_ERROR;
        if (zs is null) throw new Exception("inflate: stream not open");
        immutable n = buf.length > uint.max ? uint.max : cast(uint) buf.length;
        // zlib writes only within buf[0 .. n], n <= buf.length; next_out is
        // cleared before returning so no pointer into buf outlives the call.
        auto rc = () @trusted {
            auto z = cast(z_stream*) zs;
            z.next_out = buf.ptr;
            z.avail_out = n;
            auto r = inflate(z, Z_NO_FLUSH);
            z.next_out = null;
            return r;
        }();
        if (rc == Z_STREAM_END) return Rc.streamEnd;
        if (rc == Z_OK || rc == Z_BUF_ERROR) return Rc.ok;
        return Rc.error;
    }

    /// zlib's error text after `Rc.error`.
    string errorMessage()
    {
        import etc.c.zlib : z_stream;
        import core.stdc.string : strlen;
        if (zs is null) return "stream not open";
        // msg is a NUL-terminated C string owned by zlib; copied here.
        auto msg = (() @trusted => (cast(z_stream*) zs).msg)();
        if (msg is null) return "corrupt stream";
        // strlen counts the NUL terminator zlib guarantees.
        return (() @trusted => msg[0 .. strlen(msg)].idup)();
    }
}

/// The mode `open(2)` gives a new file created with 0666: 0666 less the
/// process umask, read once at startup (reading it means setting it, which
/// is only safe before other threads exist).
immutable uint newFileMode;

// Safe: umask(2) takes and returns a plain mode, touching no memory.
shared static this() @trusted
{
    import core.sys.posix.sys.stat : umask;
    import std.conv : octal;
    auto old = umask(0);
    umask(old);
    newFileMode = octal!666 & ~uint(old);
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
    // `@trusted`: plain loads and stores of the storage above (see the doc).
    mixin("@property T " ~ name ~ "() @trusted nothrow @nogc { return " ~ name ~ "_; }");
    // `@trusted`: the matching store.
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

import std.file : DirEntry, SpanMode;
/// `std.file.dirEntries` collected into an array. Phobos marks the iterator
/// @system only for its reference-counted handle; the entries themselves are
/// plain values. Throws `FileException` as `dirEntries` does.
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

/// `t.isRunning`.
bool threadRunning(Thread t) @trusted { return t.isRunning; }

/// Run `dg` with SIGPIPE ignored, restoring the previous handler after (so a
/// child that exits early, like a pager, can't kill the process).
T withSigpipeIgnored(T)(scope T delegate() @safe dg) @trusted
{
    import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN;
    auto old = signal(SIGPIPE, SIG_IGN);
    scope (exit) signal(SIGPIPE, old);
    return dg();
}

import std.process : Pid;
/// `std.process.kill(pid)`. It is @system only because of the `Pid` class
/// handle; the signal goes to the pid it holds.
void killProcess(Pid pid) @trusted
{
    import std.process : kill;
    kill(pid);
}

/// `fsync(2)`.
int fsyncFd(int fd) @trusted nothrow @nogc
{
    import core.sys.posix.unistd : fsync;
    return fsync(fd);
}

/// `c.notify()`.
void signalOne(Condition c) @trusted { c.notify(); }
/// `c.notifyAll()`.
void signalAll(Condition c) @trusted { c.notifyAll(); }
/// `c.wait()` (the caller holds `c`'s mutex).
void waitOn(Condition c) @trusted { c.wait(); }
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


/// A value shared between threads that is only reachable under its lock.
/// Declare it `shared` (`shared Locked!T x = new shared Locked!T;`): the
/// compiler then rejects any access that bypasses `get`/`update`. `T` may
/// not hold unshared mutable references, so neither a copy out of `get` nor
/// anything `update` stores can alias the locked value from another thread.
import std.traits : hasUnsharedAliasing;
import core.time : Duration;
final class Locked(T) if (!hasUnsharedAliasing!T)
{
    import core.sync.mutex : Mutex;
    private T value;
    private Mutex mutex;
    private Condition changed;

    /// `@trusted`: casts away `shared` only on a freshly built object.
    this(T v = T.init) shared @trusted
    {
        auto self = cast() this;
        self.value = v;
        self.mutex = new Mutex;
        self.changed = new Condition(self.mutex);
    }

    /// A copy of the value.
    /// `@trusted`: the unshared view of `value` is used only under the lock.
    T get() shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        return self.value;
    }

    /// Run `f` on the value under the lock, and wake `await`ers. `f` is
    /// `scope`: it can't keep the reference.
    /// `@trusted`: as for `get`; the `ref` can't outlive `f` (DIP1000).
    R update(R = void)(scope R delegate(ref T) @safe f) shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        scope (exit) self.changed.notifyAll();
        return f(self.value);
    }

    /// Block until `ready(value)` holds, then run `f` under the same lock.
    /// `@trusted`: as for `update`.
    R await(R = void)(scope bool delegate(ref const T) @safe ready, scope R delegate(ref T) @safe f) shared @trusted
    {
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        while (!ready(self.value)) self.changed.wait();
        scope (exit) self.changed.notifyAll();
        return f(self.value);
    }

    /// `await` with a bound: false when `timeout` lapses before `ready`
    /// holds (nothing run); true after running `f` under the lock.
    /// `@trusted`: as for `update`.
    bool await(R = void)(scope bool delegate(ref const T) @safe ready, scope R delegate(ref T) @safe f,
        Duration timeout) shared @trusted
    {
        import core.time : MonoTime;
        auto self = cast() this;
        self.mutex.lock();
        scope (exit) self.mutex.unlock();
        auto deadline = MonoTime.currTime + timeout;
        while (!ready(self.value))
        {
            auto left = deadline - MonoTime.currTime;
            if (left <= Duration.zero) return false;
            self.changed.wait(left);
        }
        scope (exit) self.changed.notifyAll();
        f(self.value);
        return true;
    }
}

/// A copyable, sendable handle to a `shared Locked!T` (like Rust's
/// `Arc<Mutex<T>>`), so holders needn't spell `shared` or `atomicLoad`.
struct Shared(T)
{
    import core.atomic : atomicLoad;
    private shared Locked!T impl;
    /// A new cell holding `v`.
    static Shared make(T v = T.init) { return Shared(new shared Locked!T(v)); }
    /// Whether this handle refers to a cell.
    bool opCast(B : bool)() pure const { return atomicLoad(impl) !is null; }
    /// See `Locked`.
    T get() { return atomicLoad(impl).get(); }
    /// ditto
    R update(R = void)(scope R delegate(ref T) @safe f) { return atomicLoad(impl).update!R(f); }
    /// ditto
    R await(R = void)(scope bool delegate(ref const T) @safe ready, scope R delegate(ref T) @safe f)
    {
        return atomicLoad(impl).await!R(ready, f);
    }
    /// ditto
    bool await(R = void)(scope bool delegate(ref const T) @safe ready, scope R delegate(ref T) @safe f,
        Duration timeout)
    {
        return atomicLoad(impl).await!R(ready, f, timeout);
    }
}

@safe unittest
{
    static struct S { int n; string s; }
    shared Locked!S l = new shared Locked!S(S(1, "a"));
    l.update((ref S v) { v.n++; });
    assert(l.get == S(2, "a"));
    static assert(!__traits(compiles, new shared Locked!(int[])));
}

// ---- Sendable-only threads ----------------------------------------------
//
// The "E profile": threads start only through `spawn`, which takes a plain
// `function` (no hidden closure context) and arguments that are sendable,
// and threads talk through `Channel`s of sendable values or `Locked` state.
// check-safe.sh bans `new Thread` outside this module (bar a shrinking
// budget), so data shared between threads is visible in the types.

/// Whether a value of type `T` may be handed to another thread: it holds no
/// unshared mutable references (immutable, `shared` or plain data, function
/// pointers), or it is an `Isolated` whose holder gives it up. Delegates are
/// not sendable: their context can reach anything.
enum bool isSendable(T) = !hasUnsharedAliasing!T || is(T : Isolated!U, U);

/// A value with exactly one owner: nothing outside it refers to it or to
/// anything it reaches, so it may move to another thread. It can't be
/// copied, only moved (`std.algorithm.move`) or taken with `unwrap`.
struct Isolated(T)
{
    private T payload;
    @disable this(this);

    /// Claim that nothing else refers to `value` (e.g. it was just built).
    /// The compiler can't check this; check-safe.sh counts every call
    /// against scripts/isolation-budget, so each claim gets reviewed.
    static Isolated assumeIsolated(T value) pure
    {
        Isolated r;
        r.payload = value;
        return r;
    }

    /// Take the value out (the holder is left empty).
    T unwrap() pure
    {
        auto v = payload;
        payload = T.init;
        return v;
    }

    /// Make it immutable: sound because nothing else can still change it.
    /// `@trusted`: the cast is what isolation licenses (`assumeUnique`).
    immutable(T) freeze() pure @trusted
    {
        auto v = unwrap();
        return cast(immutable) v;
    }
}

/// A started thread, to wait for or poll; `join` returns what its function
/// returned (an `R`, which must be sendable).
struct Join(R)
{
    private Thread thread;
    static if (!is(R == void)) private ResultBox!R box;

    /// Wait for the thread to finish (rethrows what killed it).
    R join()
    {
        joinThread(thread);
        static if (!is(R == void)) return takeResult(box);
    }

    /// Whether the thread is still running.
    bool running() { return threadRunning(thread); }
}

/// A thread whose function returns nothing.
alias JoinHandle = Join!void;

private final class ResultBox(R) { Unqual!R value; }

/// `@trusted`: the thread wrote `box.value` before it ended, and `join`
/// waited for that (a happens-before edge), so nothing else touches it now.
private R takeResult(R)(ResultBox!R box) pure @trusted
{
    import core.lifetime : move;
    return cast(R) move(box.value);
}

/// Run `fn(args)` on a new thread. `fn` is a plain function, so it can only
/// reach what it is given (and `shared` or thread-local globals), and every
/// argument, and the result, must be sendable.
Join!R spawn(R, Args...)(R function(Args) @safe fn, auto ref Args args)
    if (allSatisfy!(isSendable, Args) && (is(R == void) || isSendable!R))
{
    return startSpawned(fn, args, false);
}

/// `spawn` for a daemon thread, which doesn't keep the process alive.
Join!R spawnDaemon(R, Args...)(R function(Args) @safe fn, auto ref Args args)
    if (allSatisfy!(isSendable, Args) && (is(R == void) || isSendable!R))
{
    return startSpawned(fn, args, true);
}

import std.meta : allSatisfy, staticMap;
import std.traits : Unqual;
// `= void`: an argument type may have no default (`@disable this()`, as
// NotNull does); each slot is filled by `moveEmplace` before any read.
private final class SpawnBox(Args...) { staticMap!(Unqual, Args) args = void; }

/// `@trusted`: the arguments (checked sendable by `spawn`) are moved into a
/// box only the new thread can reach; `shared` is stripped for the move and
/// restored for the call. `fn` is a context-free function. The result goes
/// into a box read only after `join`.
private Join!R startSpawned(R, Args...)(R function(Args) @safe fn, ref Args args, bool daemon) @trusted
{
    import core.lifetime : move, moveEmplace;
    auto box = new SpawnBox!Args;
    static foreach (i; 0 .. Args.length)
        moveEmplace(*cast(Unqual!(Args[i])*) &args[i], box.args[i]);
    Join!R h;
    static if (is(R == void))
        auto t = new Thread({ mixin("fn(" ~ callArgs!(Args.length) ~ ");"); });
    else
    {
        auto rb = h.box = new ResultBox!R;
        auto t = new Thread({ mixin("rb.value = cast(Unqual!R) fn(" ~ callArgs!(Args.length) ~ ");"); });
    }
    t.isDaemon = daemon;
    h.thread = t.start();
    return h;
}

private template callArgs(size_t n)
{
    import std.conv : to;
    enum callArgs = () {
        string r;
        foreach (i; 0 .. n) r ~= (i ? ", " : "") ~ "cast(Args[" ~ i.to!string ~ "]) move(box.args[" ~ i.to!string ~ "])";
        return r;
    }();
}

/// A handle to a `Channel`: copyable and sendable, so each thread holds its
/// own (like Rust's `Arc<Channel>`). `Chan!T.make` creates one.
struct Chan(T)
{
    import core.atomic : atomicLoad;
    private shared Channel!T impl;

    /// A new, open channel.
    static Chan make() { return Chan(new shared Channel!T); }
    /// Whether this handle refers to a channel.
    bool opCast(B : bool)() pure const { return atomicLoad(impl) !is null; }
    /// See `Channel`.
    void put(T v, bool front = false) { atomicLoad(impl).put(v, front); }
    /// ditto
    void close() { atomicLoad(impl).close(); }
    /// ditto
    bool take(out T v) { return atomicLoad(impl).take(v); }
    /// ditto
    bool tryTake(out T v) { return atomicLoad(impl).tryTake(v); }
    /// ditto
    void edit(scope void delegate(ref T[]) @safe f) { atomicLoad(impl).edit(f); }
}

/// A blocking queue of sendable values between threads, closable. Use it
/// through `Chan`.
final class Channel(T) if (!hasUnsharedAliasing!T)
{
    import core.sync.mutex : Mutex;
    private Mutex lock;
    private Condition ready;
    private T[] items;
    private bool closed;

    /// `@trusted`: initialises the fresh object's own lock.
    this() shared @trusted
    {
        auto self = cast() this;
        self.lock = new Mutex;
        self.ready = new Condition(self.lock);
    }

    /// Append `v` (or put it first); wakes one taker.
    /// `@trusted`: the unshared view is used only while holding `lock`.
    void put(T v, bool front = false) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        self.items = front ? v ~ self.items : self.items ~ v;
        self.ready.notify();
    }

    /// No more values: takers drain what is left, then get false.
    /// `@trusted`: as for `put`.
    void close() shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        self.closed = true;
        self.ready.notifyAll();
    }

    /// Wait for the next value; false once closed and empty.
    /// `@trusted`: as for `put`.
    bool take(out T v) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        while (!self.items.length && !self.closed) self.ready.wait();
        if (!self.items.length) return false;
        v = self.items[0];
        self.items = self.items[1 .. $];
        return true;
    }

    /// The next value if one is waiting (doesn't block).
    /// `@trusted`: as for `put`.
    bool tryTake(out T v) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        if (!self.items.length) return false;
        v = self.items[0];
        self.items = self.items[1 .. $];
        return true;
    }

    /// Run `f` on the queued values under the lock (e.g. to reorder them).
    /// `@trusted`: as for `put`; `f` can't keep the reference (`scope`).
    void edit(scope void delegate(ref T[]) @safe f) shared @trusted
    {
        auto self = cast() this;
        self.lock.lock();
        scope (exit) self.lock.unlock();
        f(self.items);
    }
}

@safe unittest // spawn moves an Isolated, Channel carries results back
{
    static void worker(Isolated!(int[]) xs, Chan!int ch)
    {
        auto a = xs.unwrap;
        foreach (x; a) ch.put(x * 2);
        ch.close();
    }
    import core.lifetime : move;
    auto ch = Chan!int.make;
    auto xs = Isolated!(int[]).assumeIsolated([1, 2, 3]);
    auto h = spawn(&worker, move(xs), ch);
    int v, sum;
    while (ch.take(v)) sum += v;
    h.join();
    assert(sum == 12);
    static assert(isSendable!(immutable(int)[]) && isSendable!string && isSendable!(Chan!int));
    static assert(!isSendable!(int[]) && !isSendable!(void delegate()) && !isSendable!Object);
    static int add(int a, int b) { return a + b; }
    assert(spawn(&add, 2, 3).join() == 5);
    static void bad(int[] a) {}
    static assert(!__traits(compiles, spawn(&bad, [1])));
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
/// NUL-terminated buffer, and `end` only points into that copy. Pure: strtod
/// reads only its input and the C locale, which stays "C" (check-safe bans
/// setlocale); the errno it may set on overflow is never read.
double cStrtod(string text, out size_t consumed) pure @trusted
{
    import core.stdc.stdlib : strtod;
    import std.string : toStringz;
    alias Strtod = double function(scope const(char)*, scope char**) pure nothrow @nogc;
    auto z = text.toStringz;
    char* end;
    auto v = (cast(Strtod) &strtod)(z, &end);
    consumed = end - z;
    return v;
}

/// ditto
double cStrtod(string text) pure
{
    size_t n;
    return cStrtod(text, n);
}

import std.json : JSONValue, JSONType;
/// `v[key]` when `v` is an object holding it, else null. Phobos marks
/// `JSONValue.object` @system because it returns the AA by reference; this
/// only looks a key up and returns a pointer into the GC-owned table.
const(JSONValue)* jsonGet(return scope const ref JSONValue v, string key) pure @trusted
{
    if (v.type != JSONType.object) return null;
    return key in v.object;
}

/// A deep, mutable copy of `v`, so a `const` tree can be merged into a
/// mutable one without casting `const` away (and without the two sharing
/// subtrees). Numbers are copied as stored, never re-parsed.
JSONValue jsonCopy(const JSONValue v) pure
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

/// A mutable deep copy of a `const` value: arrays and maps are rebuilt,
/// JSON is copied with `jsonCopy`, structs field by field. Data that is
/// already immutable (strings) is shared. This replaces `cast()` copies out
/// of `const`, which would let the copy write into the original.
U deepCopy(U)(const U v) pure
{
    import std.traits : hasIndirections, isAssociativeArray, KeyType, ValueType;
    import std.typecons : Nullable;
    static if (!hasIndirections!U) return v;
    else static if (is(U == JSONValue)) return jsonCopy(v);
    else static if (is(U == E[], E))
    {
        static if (is(E == immutable)) return v;
        else
        {
            U r;
            r.reserve(v.length);
            foreach (ref e; v) r ~= deepCopy!E(e);
            return r;
        }
    }
    else static if (isAssociativeArray!U)
    {
        U r;
        foreach (k, ref e; v) r[deepCopy!(KeyType!U)(k)] = deepCopy!(ValueType!U)(e);
        return r;
    }
    else static if (is(U == Nullable!X, X))
    {
        U r;
        if (!v.isNull) r = deepCopy!X(v.get);
        return r;
    }
    else static if (is(U == struct))
    {
        U r;
        static foreach (i; 0 .. U.tupleof.length)
            r.tupleof[i] = deepCopy!(typeof(U.tupleof[i]))(v.tupleof[i]);
        return r;
    }
    else static assert(0, "deepCopy: unsupported type " ~ U.stringof);
}

@safe unittest
{
    static struct In { int[] xs; string s; }
    static struct Out { In[] ins; string[string] m; int n; }
    const Out o = Out([In([1, 2], "a")], ["k": "v"], 3);
    auto c = deepCopy(o);
    c.ins[0].xs[0] = 9;
    assert(o.ins[0].xs[0] == 1 && c.m["k"] == "v" && c.n == 3 && c.ins[0].s == "a");
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

// --- JSON text, pure -------------------------------------------------------

import std.json : JSONOptions, JSONValue;

private string jsonTextImpl(const JSONValue v, JSONOptions options, bool pretty)
{
    return pretty ? v.toPrettyString(options) : v.toString(options);
}

/// `v.toString(options)`, but `pure`, so code that serializes JSON can be.
// why: std.json's toJSON recurses through a nested function, for which D
// infers no attributes, so it isn't marked pure; it only writes to its own
// appender (floats through std.format's pure formatter) and reads no globals.
string jsonText(const JSONValue v, JSONOptions options = JSONOptions.none) pure @trusted
{
    alias Impure = string function(const JSONValue, JSONOptions, bool) @safe;
    alias Pure = string function(const JSONValue, JSONOptions, bool) pure @safe;
    return (cast(Pure) cast(Impure) &jsonTextImpl)(v, options, false);
}

/// `v.toPrettyString(options)`, pure; see `jsonText`.
// why: as for jsonText.
string jsonPretty(const JSONValue v, JSONOptions options = JSONOptions.none) pure @trusted
{
    alias Impure = string function(const JSONValue, JSONOptions, bool) @safe;
    alias Pure = string function(const JSONValue, JSONOptions, bool) pure @safe;
    return (cast(Pure) cast(Impure) &jsonTextImpl)(v, options, true);
}

/// Through a pointer, as `p.toString` reads (UFCS doesn't dereference).
string jsonText(const(JSONValue)* v, JSONOptions options = JSONOptions.none) pure
{
    return jsonText(*v, options);
}

/// ditto
string jsonPretty(const(JSONValue)* v, JSONOptions options = JSONOptions.none) pure
{
    return jsonPretty(*v, options);
}

unittest
{
    import std.json : parseJSON;
    auto v = parseJSON(`{"a":[1,2.5,"x/y"],"b":null}`);
    assert(jsonText(v) == v.toString);
    assert(jsonText(v, JSONOptions.doNotEscapeSlashes) == v.toString(JSONOptions.doNotEscapeSlashes));
    assert(jsonPretty(v) == v.toPrettyString);
}

// Bytes to text. Viewing bytes as `char` skips UTF-8 validation, so bad
// input would become a `string` that throws wherever it is next decoded.
// These are the casts between the two; the rest of the code goes through
// them (text to bytes is `std.string.representation`, which needs no cast).

/// `b` as text, checked: throws `UTFException` at the first invalid byte.
/// The result aliases `b`.
inout(char)[] utf8View(return scope inout(ubyte)[] b) pure
{
    import std.utf : validate;
    auto s = cast(inout(char)[]) b;
    validate(s);
    return s;
}

/// `b` copied into a `string`, checked like `utf8View`.
string utf8Text(scope const(ubyte)[] b) pure
{
    return utf8View(b).idup;
}

/// `b` copied into a `string`, each invalid byte replaced with U+FFFD.
string lossyText(scope const(ubyte)[] b) pure
{
    import std.utf : decode, UTFException;
    import std.array : appender;
    auto s = cast(const(char)[]) b;
    auto o = appender!string;
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] < 0x80) { o.put(s[i]); ++i; continue; }
        size_t j = i;
        try { decode(s, j); o.put(s[i .. j]); i = j; }
        catch (UTFException) { o.put("\uFFFD"); ++i; }
    }
    return o[];
}

/// `b` as `char`s without validation, for byte-level scanning (searching
/// for ASCII delimiters) whose pieces are validated or treated as bytes
/// afterwards. Never let the result escape as a `string`.
inout(char)[] asChars(return scope inout(ubyte)[] b) pure nothrow @nogc
{
    return cast(inout(char)[]) b;
}

/// `s` as bytes owned by the caller: a mutable copy.
ubyte[] bytesOf(scope const(char)[] s) pure nothrow
{
    import std.string : representation;
    return s.representation.dup;
}

unittest
{
    import std.exception : assertThrown;
    import std.utf : UTFException;
    import std.string : representation;
    assert(utf8Text("héllo".representation) == "héllo");
    assertThrown!UTFException(utf8Text([0x61, 0xff, 0x62]));
    assert(lossyText([0x61, 0xff, 0x62]) == "a\uFFFDb");
    assert(lossyText("€".representation) == "€");
    ubyte[] m = [0x68, 0x69];
    char[] v = utf8View(m);
    assert(v == "hi");
    assert(bytesOf("hi") == [0x68, 0x69]);
}

/// Reads a whole JSON number that may be tagged either `integer` or
/// `uinteger` (std.json uses the latter for values > long.max and for
/// `JSONValue(1u)`). Reading `.integer` on a `uinteger` throws, so every
/// site that accepts both tags must go through here. Returns false for
/// non-integral types and for negative values.
bool jsonUnsigned(const JSONValue v, out ulong r) pure @safe
{
    if (v.type == JSONType.uinteger) { r = v.uinteger; return true; }
    if (v.type == JSONType.integer && v.integer >= 0) { r = cast(ulong) v.integer; return true; }
    return false;
}

/// Reads a whole JSON number of either tag as a `long`; false for
/// non-integral types and for a `uinteger` above `long.max`.
bool jsonSigned(const JSONValue v, out long r) pure @safe
{
    if (v.type == JSONType.integer) { r = v.integer; return true; }
    if (v.type == JSONType.uinteger && v.uinteger <= long.max) { r = cast(long) v.uinteger; return true; }
    return false;
}

/// A whole JSON number (either tag) as a double; NaN for other types.
double jsonWholeAsDouble(const JSONValue v) pure @safe
{
    if (v.type == JSONType.uinteger) return double(v.uinteger);
    if (v.type == JSONType.integer) return double(v.integer);
    return double.nan;
}

unittest
{
    ulong r;
    assert(jsonUnsigned(JSONValue(1u), r) && r == 1);
    assert(jsonUnsigned(JSONValue(ulong.max), r) && r == ulong.max);
    assert(jsonUnsigned(JSONValue(7), r) && r == 7);
    assert(!jsonUnsigned(JSONValue(-1), r));
    assert(!jsonUnsigned(JSONValue("1"), r));
    long l;
    assert(jsonSigned(JSONValue(1u), l) && l == 1);
    assert(jsonSigned(JSONValue(-4), l) && l == -4);
    assert(!jsonSigned(JSONValue(ulong.max), l));
    assert(!jsonSigned(JSONValue(1.5), l));
    assert(jsonWholeAsDouble(JSONValue(3u)) == 3.0);
    assert(jsonWholeAsDouble(JSONValue(-3)) == -3.0);
}

/// Create a fresh temp file beside `base` in `dir` holding `content`, opened
/// exclusively (`O_CREAT | O_EXCL`, which never follows a symlink) under an
/// unpredictable name, retrying on a collision. Returns its path. The file is
/// private (0600) while being written, then given `mode` (the replaced
/// file's permissions, or `newFileMode` for a fresh one) in a single step, so
/// it is never wider than that final mode. The name is bounded so a
/// long `base` can't push it past the filesystem's component limit.
string writeTemp(string dir, string base, const(ubyte)[] content, uint mode) @trusted
{
    import core.sys.posix.fcntl : open, O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW;
    import core.sys.posix.unistd : posixWrite = write, close;
    import core.stdc.errno : errno, EEXIST, EINTR;
    import std.process : thisProcessID;
    import std.file : FileException, remove;
    import std.format : format;
    import std.path : buildPath;
    import std.conv : octal;
    import std.random : uniform;
    import std.string : toStringz;
    // A 255-byte component limit is common; the suffix needs a dot, the PID
    // and 16 hex digits, so cap the basename to keep the whole name under it.
    enum maxBase = 240 - 20 - 10;
    if (base.length > maxBase) base = base[$ - maxBase .. $];
    foreach (_; 0 .. 100)
    {
        auto tmp = buildPath(dir, format(".%s.tmp-%s-%016x", base, thisProcessID, uniform!ulong));
        auto fd = open(tmp.toStringz, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, octal!600);
        if (fd < 0)
        {
            if (errno == EEXIST) continue;
            throw new FileException(tmp, errno);
        }
        scope (exit) close(fd);
        scope (failure) { try remove(tmp); catch (FileException) {} } // best effort; the write error propagates
        auto rest = content;
        while (rest.length)
        {
            auto n = posixWrite(fd, rest.ptr, rest.length);
            if (n < 0)
            {
                if (errno == EINTR) continue;
                throw new FileException(tmp, errno);
            }
            rest = rest[n .. $];
        }
        // Apply the final mode once: never widen past it, even briefly.
        if (fchmodFd(fd, mode & octal!7777) != 0) throw new FileException(tmp, errno);
        return tmp;
    }
    throw new FileException(dir, "could not create a unique temporary file");
}

unittest // writeTemp applies the caller's final mode directly; a 0600 target's replacement is never widened
{
    import std.conv : octal;
    import std.file : getAttributes, remove, tempDir, readText;
    auto t = writeTemp(tempDir, "wt-mode-private", cast(const(ubyte)[]) "s\n", octal!600);
    scope (exit) remove(t);
    assert((getAttributes(t) & octal!7777) == octal!600);
    assert(readText(t) == "s\n");
    auto u = writeTemp(tempDir, "wt-mode-default", cast(const(ubyte)[]) "d\n", newFileMode);
    scope (exit) remove(u);
    assert((getAttributes(u) & octal!7777) == newFileMode);
}

// Issue #271 review: an unopened inflate stream is rejected rather than
// handed to zlib, and `feed` copies its input (no borrowed pointer kept).
unittest
{
    import std.exception : assertThrown;
    InflateStream z;
    auto buf = new ubyte[](8);
    assertThrown(z.inflateInto(buf));
    assertThrown(z.feed(buf));
    assert(z.availIn == 0 && z.availOut == 0);
}
