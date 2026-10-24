/// The frame renderer's terminal side (ui.rs frame mode): fd 1 and 2 point
/// at a pipe whose bytes become the transcript, the line editor draws
/// through `draw`/`commit`, and every change re-renders the frame (the
/// transcript, the editor rows, then the status line) on the saved tty.
module nano.frameui;

@safe:

import core.thread : Thread;
import nano.frame;
import nano.lineedit : writeFd, ttyOut, terminalWidth, terminalHeight;
import nano.safeio : closeFd, dup2Fd, dupFd, lineBufferStdout, pipeFds, pollFds, readFd_ = readFd, setNonBlocking, startThread, stdErr, stdOut;

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
    static FrameUi install(string delegate(size_t) @safe status)
    {
        auto f = new FrameUi;
        f.status = status;
        stdOut.flush();
        stdErr.flush();
        int[2] p;
        if (pipeFds(p) != 0) return null;
        f.tty = dupFd(1);
        f.readFd = p[0];
        f.writeEnd = p[1];
        setNonBlocking(f.readFd);
        dup2Fd(f.writeEnd, 1);
        dup2Fd(f.writeEnd, 2);
        ttyOut = f.tty;
        // Line-buffered: a pipe would otherwise hold whole blocks back.
        lineBufferStdout();
        f.renderer = new FrameRenderer((string s) { writeFd(f.tty, s); });
        writeFd(f.tty, "\x1b[?25l");
        auto reader = new Thread(&f.readLoop);
        reader.isDaemon = true;
        startThread(reader);
        auto ticker = new Thread(&f.tickLoop);
        ticker.isDaemon = true;
        startThread(ticker);
        f.redraw();
        return f;
    }

    /// Gives the terminal back (fd 1 and 2 to the tty) and returns the
    /// transcript's lines, for a legacy replay.
    string[] uninstall()
    {
        stdOut.flush();
        stdErr.flush();
        string[] lines;
        synchronized (this)
        {
            drain();
            render();
            closed = true;
            lines = transcript.lines.dup;
            if (transcript.cur.length) lines ~= transcript.cur;
        }
        dup2Fd(tty, 1);
        dup2Fd(tty, 2);
        ttyOut = 1;
        closeFd(writeEnd);
        closeFd(tty);
        writeFd(1, "\x1b[?25h\r\n");
        return lines;
    }

    /// Hands the real terminal to a child (a pager) until `resume`.
    void suspend()
    {
        stdOut.flush();
        stdErr.flush();
        synchronized (this) { drain(); paused = true; }
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
    void commit(string line)
    {
        stdOut.flush();
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
    void clear()
    {
        stdOut.flush();
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
    private bool drain()
    {
        ubyte[8192] buf;
        for (;;)
        {
            auto n = readFd_(readFd, buf[]);
            if (n > 0) { transcript.feed(buf[0 .. n]); continue; }
            return n != 0;
        }
    }

    private void readLoop()
    {
        import core.sys.posix.poll : pollfd, POLLIN;
        for (;;)
        {
            pollfd[1] ps = [pollfd(readFd, POLLIN, 0)];
            if (pollFds(ps[], 200) < 0) continue;
            auto p = ps[0];
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

    private static long nowMs()
    {
        import core.time : MonoTime;
        return MonoTime.currTime.ticks / (MonoTime.ticksPerSecond / 1000);
    }

    /// Watches the size; a burst of changes renders once, 150 ms after the last.
    private void tickLoop()
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
