/// The frame renderer's terminal side (ui.rs frame mode): fd 1 and 2 point
/// at a pipe whose bytes become the transcript, the line editor draws
/// through `draw`/`commit`, and every change re-renders the frame (the
/// transcript, the editor rows, then the status line) on the saved tty.
module nano.frameui;

@safe:

import core.thread : Thread;
import nano.frame;
import nano.lineedit : writeFd, ttyOut, terminalWidth, terminalHeight;

final class FrameUi
{
    private int tty = -1, readFd = -1, writeEnd = -1;
    private Transcript transcript;
    private string[] editorRows;
    private FrameRenderer renderer;
    private bool paused, closed;
    private size_t lastW, lastH;
    private Debouncer debounce = Debouncer(150);
    /// The status line at a width ("" for none).
    string delegate(size_t width) @safe status;

    /// Takes over the terminal: fd 1 and 2 now feed the transcript.
    static FrameUi install(string delegate(size_t) @safe status) @trusted
    {
        import core.sys.posix.unistd : dup, dup2, pipe, close;
        import core.sys.posix.fcntl : fcntl, F_SETFL, F_GETFL, O_NONBLOCK;
        import std.stdio : stdout, stderr;
        auto f = new FrameUi;
        f.status = status;
        stdout.flush();
        stderr.flush();
        int[2] p;
        if (pipe(p) != 0) return null;
        f.tty = dup(1);
        f.readFd = p[0];
        f.writeEnd = p[1];
        fcntl(f.readFd, F_SETFL, fcntl(f.readFd, F_GETFL) | O_NONBLOCK);
        dup2(f.writeEnd, 1);
        dup2(f.writeEnd, 2);
        ttyOut = f.tty;
        // Line-buffered: a pipe would otherwise hold whole blocks back.
        import core.stdc.stdio : _IOLBF;
        stdout.setvbuf(4096, _IOLBF);
        f.renderer = new FrameRenderer((string s) @trusted { writeFd(f.tty, s); });
        writeFd(f.tty, "\x1b[?25l");
        auto reader = new Thread(&f.readLoop);
        reader.isDaemon = true;
        reader.start();
        auto ticker = new Thread(&f.tickLoop);
        ticker.isDaemon = true;
        ticker.start();
        f.redraw();
        return f;
    }

    /// Gives the terminal back (fd 1 and 2 to the tty) and returns the
    /// transcript's lines, for a legacy replay.
    string[] uninstall() @trusted
    {
        import core.sys.posix.unistd : dup2, close;
        import std.stdio : stdout, stderr;
        stdout.flush();
        stderr.flush();
        string[] lines;
        synchronized (this)
        {
            drain();
            render();
            closed = true;
            lines = transcript.lines.dup;
            if (transcript.cur.length) lines ~= transcript.cur;
        }
        dup2(tty, 1);
        dup2(tty, 2);
        ttyOut = 1;
        close(writeEnd);
        close(tty);
        writeFd(1, "\x1b[?25h\r\n");
        return lines;
    }

    /// Hands the real terminal to a child (a pager) until `resume`.
    void suspend() @trusted
    {
        import core.sys.posix.unistd : dup2;
        import std.stdio : stdout, stderr;
        stdout.flush();
        stderr.flush();
        synchronized (this) { drain(); paused = true; }
        dup2(tty, 1);
        dup2(tty, 2);
        writeFd(tty, "\x1b[?25h");
    }

    void resume() @trusted
    {
        import core.sys.posix.unistd : dup2;
        import std.stdio : stdout, stderr;
        stdout.flush();
        stderr.flush();
        dup2(writeEnd, 1);
        dup2(writeEnd, 2);
        writeFd(tty, "\x1b[?25l");
        synchronized (this)
        {
            paused = false;
            renderer.invalidate();
            render();
        }
    }

    /// The editor's rows (null hides it).
    void draw(string[] rows)
    {
        synchronized (this)
        {
            editorRows = rows;
            render();
        }
    }

    /// A line the editor leaves behind (a submitted prompt, a picker answer).
    void commit(string line) @trusted
    {
        import std.stdio : stdout, stderr;
        stdout.flush();
        synchronized (this)
        {
            drain();
            editorRows = null;
            transcript.feed(cast(const(ubyte)[]) (line ~ "\n"));
            render();
        }
    }

    /// Re-renders (the status changed).
    void redraw()
    {
        synchronized (this) render();
    }

    /// Empties the transcript (`/restart`).
    void clear() @trusted
    {
        import std.stdio : stdout;
        stdout.flush();
        synchronized (this)
        {
            drain();
            transcript.clear();
            renderer.invalidate();
            render();
        }
    }

    private void render()
    {
        if (paused || closed) return;
        auto w = terminalWidth(tty), h = terminalHeight(tty);
        lastW = w;
        lastH = h;
        debounce.clear();
        auto lines = transcript.render(w);
        renderer.render(compose(lines, editorRows, status is null ? "" : status(w)), w, h);
    }

    /// Reads what's waiting in the pipe into the transcript; false at EOF.
    private bool drain() @trusted
    {
        import core.sys.posix.unistd : read;
        ubyte[8192] buf;
        for (;;)
        {
            auto n = read(readFd, buf.ptr, buf.length);
            if (n > 0) { transcript.feed(buf[0 .. n]); continue; }
            return n != 0;
        }
    }

    private void readLoop() @trusted
    {
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        import core.sys.posix.unistd : close;
        for (;;)
        {
            pollfd p = pollfd(readFd, POLLIN, 0);
            if (poll(&p, 1, 200) < 0) continue;
            synchronized (this)
            {
                if (closed) break;
                if (!p.revents) continue;
                bool open = drain();
                render();
                if (!open) break;
            }
        }
    }

    private static long nowMs() @trusted
    {
        import core.time : MonoTime;
        return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    /// Watches the size; a burst of changes renders once, 150 ms after the last.
    private void tickLoop() @trusted
    {
        import core.time : msecs;
        for (;;)
        {
            Thread.sleep(50.msecs);
            synchronized (this)
            {
                if (closed) return;
                if (paused) continue;
                auto w = terminalWidth(tty), h = terminalHeight(tty);
                if (w != lastW || h != lastH)
                {
                    lastW = w;
                    lastH = h;
                    debounce.record(nowMs());
                }
                if (debounce.pending && debounce.ready(nowMs())) render();
            }
        }
    }
}
