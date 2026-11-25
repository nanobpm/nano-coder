/// The frame renderer's terminal side (ui.rs frame mode): fd 1 and 2 point
/// at a pipe whose bytes become the transcript, the line editor draws
/// through `draw`/`commit`, and every change re-renders the frame (the
/// transcript, the editor rows, then the status line) on the saved tty.
module nano.frameui;

@safe:

import std.string : representation;
import nano.clock : monoNow;

import nano.option : NotNull;
import nano.frame;
import nano.lineedit : writeFd, ttyOut, terminalWidth, terminalHeight;
import nano.safeio : closeFd, dup2Fd, dupFd, lineBufferStdout, pipeFds, pollFds, readFd_ = readFd, setNonBlocking, stdErr, stdOut, Chan, Isolated, spawnDaemon;
import std.sumtype : SumType, match;

/// The status line at a width ("" for none). A plain function: the frame
/// thread calls it, so it may only read `shared` state.
alias StatusFn = string function(size_t width) @safe;

// Requests to the frame thread. The ones that change the transcript or the
// terminal wait for `done`, so output the caller writes afterwards can't
// overtake them.
private struct Draw { immutable(string)[] rows; }
private struct Commit { string line; Chan!bool done; }
private struct Redraw {}
private struct Clear { Chan!bool done; }
private struct Suspend { Chan!bool done; }
private struct Resume { Chan!bool done; }
private struct Close { Chan!(immutable(string)[]) lines; }
private struct Busy { bool on; }
private struct WorkPause { bool paused; }
private struct Toggle {}
private struct Verbose { bool on; }
private struct Hold { bool on; Chan!bool done; }
private struct Status { string bytes; }
private alias Request = SumType!(Draw, Commit, Redraw, Clear, Suspend, Resume, Close, Busy, WorkPause, Toggle, Verbose, Hold, Status);

/// The frame renderer, as seen from other threads: a sendable handle to the
/// thread that owns the transcript and the renderer (an actor). Copies
/// refer to the same frame; `FrameUi.init` is "no frame".
struct FrameUi
{
    private Chan!Request requests;
    private int tty = -1, writeEnd = -1, wake = -1;

    /// Whether this is a running frame.
    bool opCast(B : bool)() pure const { return !!requests; }

    /// Takes over the terminal: fd 1 and 2 now feed the transcript. Returns
    /// `FrameUi.init` if it can't.
    static FrameUi install(StatusFn status)
    {
        stdOut.flush();
        stdErr.flush();
        int[2] p, w;
        if (pipeFds(p) != 0) return FrameUi.init;
        if (pipeFds(w) != 0) { closeFd(p[0]); closeFd(p[1]); return FrameUi.init; }
        immutable tty = dupFd(1);
        auto f = new FrameState(new FrameRenderer((string s) { writeFd(tty, s); }));
        f.status = status;
        f.tty = tty;
        f.readFd = p[0];
        f.wakeFd = w[0];
        setNonBlocking(f.readFd);
        setNonBlocking(f.wakeFd);
        dup2Fd(p[1], 1);
        dup2Fd(p[1], 2);
        ttyOut = f.tty;
        // Line-buffered: a pipe would otherwise hold whole blocks back.
        lineBufferStdout();
        writeFd(f.tty, "\x1b[?25l");
        f.render();
        auto ui = FrameUi(Chan!Request.make, f.tty, p[1], w[1]);
        // Isolated: `f` was built just above, and only the frame thread keeps it.
        spawnDaemon(&frameThread, Isolated!FrameState.assumeIsolated(f), ui.requests);
        return ui;
    }

    private void send(Request r)
    {
        requests.put(r);
        writeFd(wake, "w");
    }

    private void sendWait(Request delegate(Chan!bool) @safe make)
    {
        auto done = Chan!bool.make;
        send(make(done));
        bool ok;
        done.take(ok);
    }

    /// Gives the terminal back (fd 1 and 2 to the tty) and returns the
    /// transcript's lines.
    string[] uninstall()
    {
        stdOut.flush();
        stdErr.flush();
        auto reply = Chan!(immutable(string)[]).make;
        send(Request(Close(reply)));
        immutable(string)[] lines;
        reply.take(lines);
        dup2Fd(tty, 1);
        dup2Fd(tty, 2);
        ttyOut = 1;
        closeFd(writeEnd);
        closeFd(wake);
        closeFd(tty);
        writeFd(1, "\x1b[?25h\r\n");
        return lines.dup;
    }

    /// Hands the real terminal to a child (a pager) until `resume`.
    void suspend()
    {
        stdOut.flush();
        stdErr.flush();
        sendWait((Chan!bool d) => Request(Suspend(d)));
        dup2Fd(tty, 1);
        dup2Fd(tty, 2);
        writeFd(tty, "\x1b[?25h");
    }

    void resume()
    {
        stdOut.flush();
        stdErr.flush();
        dup2Fd(writeEnd, 1);
        dup2Fd(writeEnd, 2);
        writeFd(tty, "\x1b[?25l");
        sendWait((Chan!bool d) => Request(Resume(d)));
    }

    /// The editor's rows (null hides them).
    void draw(const string[] rows) { send(Request(Draw(rows.idup))); }

    /// A line the editor leaves behind (a submitted prompt, a picker answer).
    void commit(string line)
    {
        stdOut.flush();
        sendWait((Chan!bool d) => Request(Commit(line, d)));
    }

    /// A turn starts (`true`: the prompt shows a spinner and the working
    /// time) or ends (back to `›` and the ready hint).
    void busy(bool on) { send(Request(Busy(on))); }

    /// Stops (or restarts) the working clock while a picker waits for the
    /// user; the spinner stays.
    void pauseWork(bool paused) { send(Request(WorkPause(paused))); }

    /// Re-renders (the status changed).
    void redraw() { send(Request(Redraw())); }

    /// Ctrl-O: expands the next batch of folds (`foldMark`) going up from
    /// the bottom, or collapses them all once every one is expanded.
    void toggleExpand() { send(Request(Toggle())); }

    /// Verbose on: expands the existing folds and every new one; off
    /// collapses them.
    void setVerbose(bool on) { send(Request(Verbose(on))); }
    /// Holds (`true`) or releases (`false`) rendering: while held, output
    /// still collects in the transcript but nothing reaches the terminal;
    /// the release reads what is waiting and renders it in one frame. A
    /// bulk write (the resume replay) then appears at once instead of
    /// visibly scrolling past frame by frame.
    void hold(bool on)
    {
        stdOut.flush();
        stdErr.flush();
        sendWait((Chan!bool d) => Request(Hold(on, d)));
    }

    /// Writes a terminal status report (`nano.progstatus`, OSC 7501) to the
    /// terminal between two renders, so it never lands inside another
    /// escape sequence. Dropped while a child (a pager) owns the terminal.
    void report(string bytes) { send(Request(Status(bytes))); }

    /// Empties the transcript (`/restart`).
    void clear()
    {
        stdOut.flush();
        sendWait((Chan!bool d) => Request(Clear(d)));
    }
}

/// The frame thread: owns `state`, serves `requests`, follows the pipe and
/// the terminal size until `Close`.
private void frameThread(Isolated!FrameState state, Chan!Request requests)
{
    import core.sys.posix.poll : pollfd, POLLIN;
    auto f = state.unwrap;
    bool pipeOpen = true;
    for (;;)
    {
        pollfd[2] ps = [pollfd(f.wakeFd, POLLIN, 0), pollfd(pipeOpen ? f.readFd : -1, POLLIN, 0)];
        pollFds(ps[], 50);
        if (ps[0].revents)
        {
            ubyte[64] buf;
            while (readFd_(f.wakeFd, buf[]) > 0) {}
        }
        if (serveRequests(f, requests))
        {
            closeFd(f.readFd);
            closeFd(f.wakeFd);
            return;
        }
        if (pipeOpen && ps[1].revents)
        {
            pipeOpen = f.drain();
            f.render();
        }
        f.tick();
    }
}

/// Serves every request waiting in `requests`; true once `Close` arrived.
/// Editor draws, redraws and busy changes only mark the frame dirty, and
/// the batch renders once at the end: key auto-repeat sends a draw per
/// key, faster than a long transcript renders, and rendering each one
/// queued them up, so the cursor kept moving after the key was released.
/// Requests that need their render before replying (commit, hold, clear,
/// resume, close) still render in place, which also clears `dirty`.
private bool serveRequests(FrameState f, Chan!Request requests)
{
    Request r;
    while (requests.tryTake(r))
    {
        bool closed = r.match!(
            (Draw d) { f.editorRows = d.rows; f.dirty = true; return false; },
            (Commit c) {
                f.drain();
                f.editorRows = null;
                import std.array : replace;
                // A committed prompt keeps the ready glyph, not a spinner frame.
                auto line = c.line.replace(glyphMark, promptGlyph(false, 0));
                f.transcript.feed((line ~ "\n").representation);
                f.render();
                c.done.put(true);
                return false;
            },
            (Redraw _) { f.dirty = true; return false; },
            (Status st) { if (!f.paused) writeFd(f.tty, st.bytes); return false; },
            (Hold h) {
                f.drain();
                f.held = h.on;
                if (!h.on) f.render();
                h.done.put(true);
                return false;
            },
            (Toggle _) {
                f.drain();
                if (f.transcript.toggle()) f.render();
                return false;
            },
            (Verbose v) {
                f.drain();
                if (f.transcript.setVerbose(v.on)) f.render();
                return false;
            },
            (Clear c) {
                f.drain();
                f.transcript.clear();
                f.renderer.invalidate();
                f.render();
                c.done.put(true);
                return false;
            },
            (Suspend c) { f.drain(); f.paused = true; c.done.put(true); return false; },
            (Resume c) {
                f.paused = false;
                f.renderer.invalidate();
                f.render();
                c.done.put(true);
                return false;
            },
            (Busy b) {
                f.busy = b.on;
                if (b.on) f.clock = WorkClock.started(FrameState.nowMs());
                f.dirty = true;
                return false;
            },
            (WorkPause p) {
                if (p.paused) f.clock.pause(FrameState.nowMs());
                else f.clock.resume(FrameState.nowMs());
                return false;
            },
            (Close c) {
                f.drain();
                f.render();
                f.paused = true;
                auto lines = f.transcript.lines.idup;
                if (f.transcript.cur.length) lines ~= f.transcript.cur.idup;
                c.lines.put(lines);
                return true;
            },
        );
        if (closed) return true;
    }
    if (f.dirty) f.render();
    return false;
}

/// The frame's state, owned by the frame thread.
private final class FrameState
{
    int tty = -1, readFd = -1, wakeFd = -1;
    Transcript transcript;
    immutable(string)[] editorRows;
    NotNull!FrameRenderer renderer;
    bool paused;
    /// Rendering held for a bulk write (`FrameUi.hold`).
    bool held;
    size_t lastW, lastH;
    Debouncer debounce = Debouncer(150);

    this(FrameRenderer renderer) pure nothrow { this.renderer = renderer; }
    StatusFn status;
    /// A turn is running: the prompt shows the spinner and `clock`.
    bool busy;
    WorkClock clock;
    long lastRenderMs;
    /// A render is due at the end of the current request batch
    /// (`serveRequests`).
    bool dirty;

    void render()
    {
        if (paused || held) return;
        dirty = false;
        auto w = terminalWidth(tty), h = terminalHeight(tty);
        lastW = w;
        lastH = h;
        debounce.clear();
        auto now = nowMs();
        lastRenderMs = now;
        auto lines = transcript.render(w);
        auto rows = decorate(editorRows, busy, clock.elapsed(now), w);
        renderer.render(compose(lines, rows, status is null ? "" : status(w)), w, h, lines.length);
    }

    /// Reads what's waiting in the pipe into the transcript; false at EOF.
    bool drain()
    {
        ubyte[8192] buf;
        for (;;)
        {
            auto n = readFd_(readFd, buf[]);
            // Fold texts go to the store, out of memory, after every read so
            // a long drain holds none of them.
            if (n > 0) { transcript.feed(buf[0 .. n]); transcript.settle(); continue; }
            return n != 0;
        }
    }

    static long nowMs()
    {
        import core.time : MonoTime;
        return monoNow.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    /// Watches the size; a burst of changes renders once, 150 ms after the last.
    void tick()
    {
        if (paused) return;
        auto w = terminalWidth(tty), h = terminalHeight(tty);
        if (w != lastW || h != lastH)
        {
            lastW = w;
            lastH = h;
            debounce.record(nowMs());
        }
        if (debounce.pending && debounce.ready(nowMs())) render();
        // Keep the spinner and the working time moving while a turn runs,
        // even when no output arrives.
        else if (busy && nowMs() - lastRenderMs >= spinnerIntervalMs) render();
    }
}

unittest
{
    // A held frame renders nothing; the release draws the collected output once.
    string[] outs;
    auto f = new FrameState(new FrameRenderer((string s) { outs ~= s; }));
    f.held = true;
    foreach (i; 0 .. 50)
    {
        f.transcript.feed("line\n".representation);
        f.render();
    }
    assert(outs.length == 0, "a held frame writes nothing to the terminal");
    f.held = false;
    f.render();
    assert(outs.length == 1, "the release renders once");
}

unittest
{
    // Key auto-repeat: a burst of editor draws queued while the frame thread
    // was busy renders once, with the newest rows, not once per key.
    string[] outs;
    auto f = new FrameState(new FrameRenderer((string s) { outs ~= s; }));
    auto requests = Chan!Request.make;
    foreach (i; 0 .. 100)
    {
        import std.conv : to;
        requests.put(Request(Draw(["> " ~ i.to!string])));
    }
    assert(!serveRequests(f, requests));
    assert(outs.length == 1, "a burst of draws renders once");
    assert(f.editorRows == ["> 99"], "the newest draw wins");
    assert(!f.dirty);

    // Nothing waiting: nothing rendered.
    assert(!serveRequests(f, requests));
    assert(outs.length == 1);
}
