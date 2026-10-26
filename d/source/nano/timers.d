/// Timers the agent sets for itself: "come back to this later" within a
/// session. The harness owns the clock. A due timer reaches the agent as a
/// system note, at its next step mid-turn or as a new turn at an idle
/// prompt. Timers are kept in the session log, so they survive compaction
/// and `--resume`, and one that came due while nano-coder was closed fires
/// (as overdue) on resume. A timer only reminds; whatever the agent does
/// next goes through the normal permission checks.
module nano.timers;

@safe:

import std.algorithm : canFind, sort, filter, map, any;
import std.array : array, join;
import std.conv : to, ConvException;
import std.format : format;
import std.json;
import std.string : strip, toLower, indexOf;

import nano.llm : ToolDefinition;

/// Most timers active at once.
enum maxActive = 10;
/// Shortest delay: timers are for coming back later, not for polling.
enum long minDelaySecs = 60;
/// Longest delay: a session-scoped reminder, not a scheduler.
enum long maxDelaySecs = 24 * 3600;
enum maxNoteChars = 1_000;

immutable string[] toolNames = ["timer_set", "timer_list", "timer_cancel"];

bool isTimerTool(string name) { return toolNames.canFind(name); }

/// A rejected timer call.
class TimerError : Exception
{
    this(string msg) { super(msg); }
}

struct Timer
{
    uint id;
    long setAt, dueAt; /// unix seconds
    string note;
}

/// What a timer tool call did.
struct Outcome
{
    string text;
    bool changed;
}

struct Timers
{
    Timer[] items; /// active, in due order
    uint lastId;

    bool empty() const { return items.length == 0; }

    /// The earliest due time, or 0 with no timers.
    long nextDue() const { return items.length ? items[0].dueAt : 0; }

    bool anyDue(long now) const { return items.length && items[0].dueAt <= now; }

    /// Remove and return the timers due at `now`.
    Timer[] takeDue(long now)
    {
        size_t n;
        while (n < items.length && items[n].dueAt <= now) n++;
        auto due = items[0 .. n].dup;
        items = items[n .. $].dup;
        return due;
    }

    Outcome apply(string tool, JSONValue args, long now)
    {
        switch (tool)
        {
            case "timer_set": return set(args, now);
            case "timer_list": return Outcome(list(now), false);
            case "timer_cancel": return cancel(args, now);
            default: throw new TimerError("unknown timer tool " ~ tool);
        }
    }

    private Outcome set(JSONValue args, long now)
    {
        if (args.type != JSONType.object) throw new TimerError("timer_set takes {after | at, note}");
        auto note = str(args, "note").strip;
        if (!note.length) throw new TimerError("timer_set needs a `note`: what to do when it fires, written for your future self");
        if (note.length > maxNoteChars) note = note[0 .. maxNoteChars] ~ "…";
        auto after = str(args, "after").strip, at = str(args, "at").strip;
        if (after.length && at.length) throw new TimerError("give `after` or `at`, not both");
        if (!after.length && !at.length) throw new TimerError("timer_set needs `after` (e.g. \"30m\") or `at` (e.g. \"14:30\")");
        long due = after.length ? now + parseDelay(after) : parseAt(at, now);
        auto delay = due - now;
        if (delay < minDelaySecs)
            throw new TimerError(format("%s is too soon: the shortest delay is %s. Timers are for coming back later; "
                ~ "to wait for something now, run a command that waits for it.", at.length ? at : after, describe(minDelaySecs)));
        if (delay > maxDelaySecs)
            throw new TimerError(format("%s is too far ahead: timers last at most %s, within this session. For longer "
                ~ "waits, hand the work to something durable (e.g. a workflow engine or cron).", at.length ? at : after,
                describe(maxDelaySecs)));
        if (items.length >= maxActive)
            throw new TimerError(format("%s timers are already set (the limit); cancel one with timer_cancel first", maxActive));
        auto t = Timer(++lastId, now, due, note);
        items ~= t;
        items.sort!((a, b) => a.dueAt < b.dueAt || (a.dueAt == b.dueAt && a.id < b.id));
        return Outcome(format("Timer %s set for %s (in %s). When it fires you'll get its note back as a message.",
            t.id, clock(due), describe(delay)), true);
    }

    private Outcome cancel(JSONValue args, long now)
    {
        if (args.type != JSONType.object || "id" !in args.objectNoRef) throw new TimerError("timer_cancel takes {id}");
        auto v = args["id"];
        long id;
        try id = v.type == JSONType.string ? v.str.strip.to!long : v.integer;
        catch (Exception) throw new TimerError("timer_cancel: `id` must be a timer number");
        foreach (i, t; items)
            if (t.id == id)
            {
                items = items[0 .. i] ~ items[i + 1 .. $];
                return Outcome(format("Cancelled timer %s (%s).", id, t.note.oneLine(60)), true);
            }
        throw new TimerError(format("no active timer %s%s", id,
            items.length ? "; active: " ~ items.map!(t => t.id.to!string).join(", ") : ""));
    }

    /// The active timers, one per line.
    string list(long now) const
    {
        if (!items.length) return "No timers set.";
        string s;
        foreach (t; items)
            s ~= format("%s. %s (in %s): %s\n", t.id, clock(t.dueAt), describe(t.dueAt > now ? t.dueAt - now : 0),
                t.note.oneLine(200));
        return s;
    }

    JSONValue toJSON() const
    {
        JSONValue[] list;
        foreach (t; items)
            list ~= JSONValue(["id": JSONValue(t.id), "set_at": JSONValue(t.setAt), "due_at": JSONValue(t.dueAt),
                "note": JSONValue(t.note)]);
        return JSONValue(["last_id": JSONValue(lastId), "items": JSONValue(list)]);
    }

    static Timers fromJSON(const JSONValue v)
    {
        Timers r;
        if (v.type != JSONType.object) return r;
        if (auto l = "last_id" in v.objectNoRef) r.lastId = cast(uint) l.integer;
        if (auto list = "items" in v.objectNoRef)
            foreach (j; list.arrayNoRef)
            {
                auto t = Timer(cast(uint) j["id"].integer, j["set_at"].integer, j["due_at"].integer, j["note"].str);
                if (t.id > r.lastId) r.lastId = t.id;
                r.items ~= t;
            }
        r.items.sort!((a, b) => a.dueAt < b.dueAt);
        return r;
    }
}

/// The message a fired timer sends the agent.
string firedMessage(const Timer[] due, long now)
{
    string s;
    foreach (t; due)
    {
        auto late = now - t.dueAt;
        s ~= format("Timer %s, set at %s, fired%s: %s\n", t.id, clock(t.setAt),
            late >= 120 ? format(" (overdue by %s: nano-coder wasn't running when it came due)", describe(late)) : "",
            t.note);
    }
    return s ~ "Act on it now, as the note says.";
}

/// A one-line notice for the user.
string firedNotice(const Timer[] due)
{
    return due.map!(t => format("⏰ timer %s: %s", t.id, t.note.oneLine(100))).join("\n");
}

/// `30s`, `5m`, `1h30m`, `2h`, `90` (seconds), `1.5h`.
long parseDelay(string s)
{
    auto t = s.strip.toLower;
    if (!t.length) throw new TimerError("empty delay");
    long total;
    size_t i;
    while (i < t.length)
    {
        size_t j = i;
        while (j < t.length && ((t[j] >= '0' && t[j] <= '9') || t[j] == '.')) j++;
        if (j == i) throw new TimerError(format("can't read the delay %s; use e.g. \"90s\", \"30m\", \"1h30m\"", s));
        double n;
        try n = t[i .. j].strip.to!double;
        catch (ConvException) throw new TimerError(format("can't read the delay %s", s));
        while (j < t.length && t[j] == ' ') j++;
        size_t k = j;
        while (k < t.length && t[k] >= 'a' && t[k] <= 'z') k++;
        auto unit = t[j .. k];
        long mult;
        switch (unit)
        {
            case "", "s", "sec", "secs", "second", "seconds": mult = 1; break;
            case "m", "min", "mins", "minute", "minutes": mult = 60; break;
            case "h", "hr", "hrs", "hour", "hours": mult = 3600; break;
            default: throw new TimerError(format("unknown unit %s in %s; use s, m or h", unit, s));
        }
        total += cast(long)(n * mult);
        i = k;
        while (i < t.length && t[i] == ' ') i++;
    }
    return total;
}

/// `14:30` (the next one, local time) or an ISO date-time
/// (`2026-10-25T14:30`, with optional seconds and `Z`/offset; local if none).
long parseAt(string s, long now)
{
    import std.datetime.systime : SysTime;
    import std.datetime.date : DateTime, TimeOfDay;
    import std.datetime.timezone : LocalTime;
    auto t = s.strip;
    try
    {
        if (t.length <= 5 && t.indexOf(':') > 0)
        {
            auto colon = t.indexOf(':');
            auto tod = TimeOfDay(t[0 .. colon].to!int, t[colon + 1 .. $].to!int);
            auto today = SysTime.fromUnixTime(now, LocalTime());
            auto at = SysTime(DateTime(today.year, today.month, today.day, tod.hour, tod.minute, 0), LocalTime());
            auto u = at.toUnixTime;
            if (u <= now) u = (at + imported!"core.time".days(1)).toUnixTime;
            return u;
        }
        auto iso = t.length == 16 ? t ~ ":00" : t;
        return SysTime.fromISOExtString(iso, LocalTime()).toUnixTime;
    }
    catch (Exception)
        throw new TimerError(format("can't read the time %s; use \"14:30\" or \"2026-10-25T14:30\"", s));
}

/// Local `HH:MM`, with the date when it isn't today.
string clock(long unix)
{
    import std.datetime.systime : SysTime, Clock;
    import std.datetime.timezone : LocalTime;
    auto t = SysTime.fromUnixTime(unix, LocalTime());
    auto now = Clock.currTime(LocalTime());
    auto hm = format("%02d:%02d", t.hour, t.minute);
    return t.year == now.year && t.dayOfYear == now.dayOfYear ? hm : format("%04d-%02d-%02d %s", t.year, t.month, t.day, hm);
}

/// `45s`, `5m`, `1h30m`.
string describe(long secs)
{
    if (secs < 60) return format("%ss", secs);
    if (secs < 3600) return secs % 60 ? format("%sm%02ss", secs / 60, secs % 60) : format("%sm", secs / 60);
    auto m = secs % 3600 / 60;
    return m ? format("%sh%02sm", secs / 3600, m) : format("%sh", secs / 3600);
}

private string str(JSONValue o, string key)
{
    auto v = key in o.objectNoRef;
    if (v is null) return null;
    if (v.type == JSONType.string) return v.str;
    if (v.type == JSONType.integer) return v.integer.to!string;
    return null;
}

private string oneLine(string s, size_t max)
{
    import std.array : replace;
    import std.utf : count;
    auto l = s.replace("\n", " ").strip;
    if (l.count <= max) return l;
    size_t n, i;
    foreach (j, dchar c; l) { if (n++ == max) { i = j; break; } }
    return l[0 .. i] ~ "…";
}

ToolDefinition[] definitions()
{
    return [
        ToolDefinition("timer_set",
            "Set a timer to come back to something later in this session, such as a CI run, a deploy or a review you "
            ~ "are waiting on. When it fires, the harness sends you its note as a message (a new turn if the user is "
            ~ "idle). Write the note for your future self: what to check and what to do next. Delays run from "
            ~ describe(minDelaySecs) ~ " to " ~ describe(maxDelaySecs) ~ "; at most " ~ maxActive.to!string
            ~ " timers at once. Don't use it to wait during a turn: run a command that waits instead.",
            parseJSON(`{"type":"object","properties":{"after":{"type":"string","description":"Delay, e.g. \"10m\", \"1h30m\""},"at":{"type":"string","description":"Local time \"14:30\" (the next one) or \"2026-10-25T14:30\""},"note":{"type":"string","description":"What to do when it fires"}},"required":["note"]}`)),
        ToolDefinition("timer_list", "List the active timers.", parseJSON(`{"type":"object","properties":{}}`)),
        ToolDefinition("timer_cancel", "Cancel a timer by its id.",
            parseJSON(`{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}`)),
    ];
}

unittest
{
    assert(parseDelay("90s") == 90 && parseDelay("30m") == 1800 && parseDelay("1h30m") == 5400);
    assert(parseDelay("1.5h") == 5400 && parseDelay("120") == 120 && parseDelay("2 hours") == 7200);
    import std.exception : assertThrown;
    assertThrown!TimerError(parseDelay("soon"));
    assertThrown!TimerError(parseDelay("5d"));
    assert(describe(45) == "45s" && describe(300) == "5m" && describe(5400) == "1h30m" && describe(7200) == "2h");
}

unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm : startsWith;
    Timers t;
    enum now = 1_000_000L;
    auto o = t.apply("timer_set", parseJSON(`{"after": "30m", "note": "check CI on PR 12"}`), now);
    assert(o.changed && o.text.startsWith("Timer 1 set for ") && o.text.canFind("(in 30m)"), o.text);
    t.apply("timer_set", parseJSON(`{"after": "10m", "note": "second"}`), now);
    assert(t.items[0].id == 2 && t.nextDue == now + 600);
    assert(t.apply("timer_list", parseJSON(`{}`), now).text.canFind("2. "));
    // Limits.
    assert(collectExceptionMsg(t.apply("timer_set", parseJSON(`{"after": "10s", "note": "x"}`), now)).canFind("too soon"));
    assert(collectExceptionMsg(t.apply("timer_set", parseJSON(`{"after": "25h", "note": "x"}`), now)).canFind("too far"));
    assert(collectExceptionMsg(t.apply("timer_set", parseJSON(`{"after": "5m"}`), now)).canFind("needs a `note`"));
    assert(collectExceptionMsg(t.apply("timer_set", parseJSON(`{"after": "5m", "at": "14:00", "note": "x"}`), now)).canFind("not both"));
    foreach (i; 0 .. maxActive - 2) t.apply("timer_set", parseJSON(`{"after": "1h", "note": "fill"}`), now);
    assert(collectExceptionMsg(t.apply("timer_set", parseJSON(`{"after": "1h", "note": "x"}`), now)).canFind("limit"));
    // Cancel.
    assert(t.apply("timer_cancel", parseJSON(`{"id": "3"}`), now).text.startsWith("Cancelled timer 3"));
    assert(collectExceptionMsg(t.apply("timer_cancel", parseJSON(`{"id": 99}`), now)).canFind("no active timer 99"));
    // Firing.
    assert(!t.anyDue(now + 599) && t.anyDue(now + 600));
    auto due = t.takeDue(now + 1800);
    assert(due.length == 2 && due[0].id == 2 && due[1].id == 1);
    assert(firedMessage(due, now + 1800).canFind("Timer 1, set at"));
    assert(firedMessage(due, now + 1800).canFind("overdue by 20m"));
    // Round trip; ids keep counting.
    auto back = Timers.fromJSON(parseJSON(t.toJSON.toString));
    assert(back == t);
    back.apply("timer_set", parseJSON(`{"after": "2m", "note": "next"}`), now);
    assert(back.items[0].id == t.lastId + 1);
}

unittest
{
    import std.datetime.systime : SysTime;
    import std.datetime.date : DateTime;
    import std.datetime.timezone : LocalTime;
    auto at1000 = SysTime(DateTime(2026, 10, 25, 10, 0, 0), LocalTime()).toUnixTime;
    // 14:30 later today; 09:00 is tomorrow.
    assert(parseAt("14:30", at1000) - at1000 == 4 * 3600 + 1800);
    assert(parseAt("09:00", at1000) - at1000 == 23 * 3600);
    assert(parseAt("2026-10-25T11:15", at1000) - at1000 == 4500);
    import std.exception : assertThrown;
    assertThrown!TimerError(parseAt("noon", at1000));
}
