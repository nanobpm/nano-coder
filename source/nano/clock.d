/// The one place nano reads the clock or sleeps. check-safe bans
/// `Clock.currTime`, `MonoTime.currTime`, `Clock.currStdTime`, `StopWatch` and
/// `Thread.sleep` everywhere else, so every time-dependent path can be run
/// against a `FakeClock` in tests.
///
/// A fake clock is per thread (module variables are thread-local in D): it
/// covers the test's own thread, so tests running in parallel don't see each
/// other's fake time, and threads the code under test spawns use the real
/// clock. With a fake clock installed, `sleepFor` advances fake time instead of
/// sleeping, so a retry loop or a deadline is exercised instantly.
module nano.clock;
@safe:

import core.time : Duration, MonoTime;
import std.datetime.systime : SysTime;
import std.datetime.timezone : LocalTime, TimeZone;

/// Wall-clock time, in `tz` (local by default).
SysTime wallNow(immutable TimeZone tz = LocalTime())
{
    if (fake !is null) return fake.wall.toOtherTZ(tz);
    import std.datetime.systime : Clock;
    return Clock.currTime(tz);
}

/// Wall-clock time in hnsecs since 1 Jan 1 AD UTC (`Clock.currStdTime`).
long stdTimeNow()
{
    if (fake !is null) return fake.wall.stdTime;
    import std.datetime.systime : Clock;
    return Clock.currStdTime;
}

/// Monotonic time, for deadlines and elapsed times.
MonoTime monoNow() nothrow @nogc
{
    if (fake !is null) return fake.mono;
    return MonoTime.currTime;
}

/// Time elapsed since `start` (a `monoNow` reading).
Duration since(MonoTime start) nothrow @nogc
{
    return monoNow - start;
}

/// Sleep the calling thread (advance fake time under a `FakeClock`).
void sleepFor(Duration d)
{
    if (fake !is null)
    {
        fake.advance(d);
        return;
    }
    if (d <= Duration.zero) return;
    import core.thread : Thread;
    Thread.sleep(d);
}

/// Fake time for the current thread, installed by `FakeClock.install` and
/// removed when the returned handle goes out of scope.
struct FakeTime
{
    SysTime wall;
    MonoTime mono;

    /// Move both clocks forward.
    void advance(Duration d) pure nothrow
    {
        if (d <= Duration.zero) return;
        wall += d;
        mono += d;
    }
}

private FakeTime* fake; // thread-local

/// RAII handle: `auto clock = FakeClock.install(start);` then
/// `clock.advance(5.seconds)`; the real clock is back when it is destroyed.
struct FakeClock
{
    private FakeTime* time, saved;

    @disable this(this);

    /// Fake the current thread's clock, starting at `start` (wall) and at the
    /// real monotonic time (so deadlines computed before install still order).
    static FakeClock install(SysTime start)
    {
        FakeClock c;
        c.saved = fake;
        c.time = new FakeTime;
        c.time.wall = start;
        c.time.mono = MonoTime.currTime;
        fake = c.time;
        return c;
    }

    ~this()
    {
        if (time !is null && fake is time) fake = saved;
    }

    void advance(Duration d) pure { time.advance(d); }
    SysTime wall() pure const { return time.wall; }
    MonoTime mono() pure const { return time.mono; }
}

unittest // a fake clock reads, advances and pauses without sleeping, then restores the real one
{
    import core.time : seconds, hours, msecs;
    import std.datetime.date : DateTime;
    import std.datetime.timezone : UTC;
    auto start = SysTime(DateTime(2026, 1, 2, 3, 4, 5), UTC());
    auto realBefore = MonoTime.currTime;
    {
        auto c = FakeClock.install(start);
        assert(wallNow(UTC()) == start);
        assert(stdTimeNow == start.stdTime);
        auto m0 = monoNow;
        sleepFor(3.hours); // instant
        assert(wallNow(UTC()) == start + 3.hours && monoNow - m0 == 3.hours);
        c.advance(2.seconds);
        assert(since(m0) == 3.hours + 2.seconds);
        sleepFor(-(1.seconds)); // never backwards
        assert(monoNow - m0 == 3.hours + 2.seconds);
    }
    assert(MonoTime.currTime - realBefore < 1.seconds, "no real sleep happened");
    assert(wallNow(UTC()).year >= 2026 && wallNow(UTC()) != start + 3.hours + 2.seconds);
    auto r0 = monoNow;
    sleepFor(5.msecs);
    assert(monoNow - r0 >= 5.msecs, "real pause sleeps");
}

unittest // fake time is per thread
{
    import core.time : hours;
    import std.datetime.date : DateTime;
    import std.datetime.timezone : UTC;
    import nano.safeio : spawn;
    auto start = SysTime(DateTime(2000, 1, 1), UTC());
    auto c = FakeClock.install(start);
    static void other() { assert(wallNow(UTC()).year >= 2026, "another thread keeps the real clock"); }
    spawn(&other).join();
    assert(wallNow(UTC()) == start);
}
