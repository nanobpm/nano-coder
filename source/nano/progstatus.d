/// The Program Status Protocol (OSC 7501,
/// <https://www.superlogical.com/rex/docs/build/program-status>): tells the
/// terminal what the session is doing (idle, working, done, blocked, error),
/// so any terminal or multiplexer that adopts the protocol can show it, not
/// only Herdr.
///
/// The encoding, the tmux wrapping and the change detection are pure
/// (`encode`, `tmuxWrap`, `Emitter`); the process-wide reporter at the end
/// only decides where the bytes go. Callers hand it a sink that writes
/// through the frame renderer, so a report never splits another escape.
module nano.progstatus;

@safe:

import core.atomic : atomicLoad, atomicStore;
import nano.safeio : Locked;

/// A state as the protocol names it. `clear` removes the record (on exit).
enum PState { idle, working, done, blocked, error, clear }

/// What a `blocked` session waits for (`none`: unsaid).
enum Kind { none, permission, question, auth }

/// The value of `app` on every report.
enum appName = "nano-coder";

/// Decoded byte limits from the spec: a terminal discards a report over them.
enum maxMsgBytes = 2048, maxTitleBytes = 192;

/// One report: the root record's whole new content.
struct Report
{
    PState state;
    Kind kind;        /// sent only with `blocked`
    string msg;       /// one line; cleaned and capped by `encode`
    string title;     /// the session handle, when set
}

/// Whether `app` fits the spec's charset `[A-Za-z0-9_.+-]{1,32}`.
bool validApp(string app) pure nothrow @nogc
{
    if (app.length < 1 || app.length > 32) return false;
    foreach (c; app)
    {
        import std.ascii : isAlphaNum;
        if (!(isAlphaNum(c) || c == '_' || c == '.' || c == '+' || c == '-')) return false;
    }
    return true;
}

/// `text` as one line the spec accepts: invalid UTF-8 and control
/// characters (C0, DEL, C1, newlines and tabs included) become spaces, runs
/// of spaces collapse, the ends are trimmed, and the result is cut to at
/// most `maxBytes` bytes on a code point boundary.
string clean(string text, size_t maxBytes) pure nothrow
{
    import std.utf : decode, encode, UseReplacementDchar;
    import std.array : appender;
    auto o = appender!string;
    bool space = false;
    size_t i = 0;
    while (i < text.length)
    {
        // Invalid UTF-8 reads as U+FFFD, a lone surrogate too.
        dchar c = decode!(UseReplacementDchar.yes)(text, i);
        bool ctl = c < 0x20 || (c >= 0x7f && c <= 0x9f) || c == 0x2028 || c == 0x2029;
        if (ctl || c == ' ')
        {
            space = o.data.length > 0;
            continue;
        }
        char[4] buf;
        auto n = encode!(UseReplacementDchar.yes)(buf, c);
        if (o.data.length + (space ? 1 : 0) + n > maxBytes) break;
        if (space) o.put(' ');
        space = false;
        o.put(buf[0 .. n]);
    }
    return o.data;
}

///
unittest
{
    assert(clean("a\nb\tc\x1b[31m", 100) == "a b c [31m");
    assert(clean("  x  ", 100) == "x");
    assert(clean("é", 1) == "", "a code point is never split");
    assert(clean("aé", 2) == "a");
    import std.algorithm : endsWith, startsWith;
    auto bad = clean("\xff ok", 10);
    assert(bad.startsWith("\uFFFD") && bad.endsWith("ok"), "invalid UTF-8 reads as U+FFFD");
    assert(clean("a\u0085b", 10) == "a b", "C1 controls go");
}

/// The first non-blank line of `text` (an answer's summary for `done`).
string firstLine(string text) pure nothrow
{
    import std.string : lineSplitter, strip;
    foreach (l; text.lineSplitter)
        if (l.strip.length) return l.strip;
    return null;
}

///
unittest
{
    assert(firstLine("\n\n  Hello there  \nmore") == "Hello there");
    assert(firstLine("") is null);
}

/// The report's body (the `key=value` pairs), in a fixed key order:
/// state, kind, app, title, msg. `kind` only goes with `blocked`; `msg` and
/// `title` are cleaned, capped to the decoded limits and base64-encoded.
string encodeBody(const Report r, string app = appName) pure nothrow
{
    import std.base64 : Base64;
    import std.string : representation;
    string b = "state=" ~ stateName(r.state);
    if (r.state == PState.clear) return b;
    if (r.state == PState.blocked && r.kind != Kind.none) b ~= ":kind=" ~ kindName(r.kind);
    if (validApp(app)) b ~= ":app=" ~ app;
    if (auto t = clean(r.title, maxTitleBytes)) b ~= ":title=" ~ Base64.encode(t.representation).idup;
    if (auto m = clean(r.msg, maxMsgBytes)) b ~= ":msg=" ~ Base64.encode(m.representation).idup;
    return b;
}

/// The whole sequence: `ESC ] 7501 ; body ESC \`.
string encode(const Report r, string app = appName) pure nothrow
{
    return "\x1b]7501;" ~ encodeBody(r, app) ~ "\x1b\\";
}

private string stateName(PState s) pure nothrow @nogc
{
    final switch (s)
    {
        case PState.idle: return "idle";
        case PState.working: return "working";
        case PState.done: return "done";
        case PState.blocked: return "blocked";
        case PState.error: return "error";
        case PState.clear: return "clear";
    }
}

private string kindName(Kind k) pure nothrow @nogc
{
    final switch (k)
    {
        case Kind.none: return "";
        case Kind.permission: return "permission";
        case Kind.question: return "question";
        case Kind.auth: return "auth";
    }
}

unittest // the spec's terraform example
{
    auto r = Report(PState.blocked, Kind.permission, "Apply 3 to add, 1 to change, 0 to destroy?");
    assert(encode(r, "terraform") == "\x1b]7501;state=blocked:kind=permission:app=terraform:"
        ~ "msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/\x1b\\");
}

unittest // key order, app and title
{
    assert(encodeBody(Report(PState.working)) == "state=working:app=nano-coder");
    assert(encodeBody(Report(PState.idle, Kind.none, null, "fix-bug")) == "state=idle:app=nano-coder:title=Zml4LWJ1Zw==");
    assert(encodeBody(Report(PState.done, Kind.none, "hi", "t")) == "state=done:app=nano-coder:title=dA==:msg=aGk=");
    assert(encodeBody(Report(PState.working), "bad app") == "state=working", "an invalid app is left out");
    assert(encodeBody(Report(PState.clear, Kind.none, "x", "y")) == "state=clear");
}

unittest // kind only with blocked
{
    foreach (s; [PState.idle, PState.working, PState.done, PState.error])
    {
        import std.algorithm : canFind;
        assert(!encodeBody(Report(s, Kind.question)).canFind("kind="));
    }
    assert(encodeBody(Report(PState.blocked, Kind.auth)) == "state=blocked:kind=auth:app=nano-coder");
    assert(encodeBody(Report(PState.blocked)) == "state=blocked:app=nano-coder");
}

unittest // size limits: decoded msg ≤ 2048, title ≤ 192, sequence ≤ 4096
{
    import std.algorithm : findSplitAfter, findSplitBefore;
    import std.array : replicate;
    import std.base64 : Base64;
    import std.string : assumeUTF;
    auto r = Report(PState.done, Kind.none, "é".replicate(3000), "ü".replicate(500));
    auto s = encode(r);
    assert(s.length <= 4096);
    auto msg = assumeUTF(Base64.decode(s.findSplitAfter("msg=")[1].findSplitBefore("\x1b")[0]).idup);
    auto title = assumeUTF(Base64.decode(s.findSplitAfter("title=")[1].findSplitBefore(":")[0]).idup);
    assert(msg.length == 2048 && title.length == 192);
    import std.utf : validate;
    validate(msg);
    validate(title);
}

/// `seq` wrapped for tmux's passthrough (`ESC P tmux; … ESC \`, every ESC
/// inside doubled), which tmux forwards only with `allow-passthrough` on.
string tmuxWrap(string seq) pure nothrow
{
    import std.array : replace;
    return "\x1bPtmux;" ~ seq.replace("\x1b", "\x1b\x1b") ~ "\x1b\\";
}

unittest
{
    assert(tmuxWrap("\x1b]7501;state=idle\x1b\\") == "\x1bPtmux;\x1b\x1b]7501;state=idle\x1b\x1b\\\x1b\\");
}

/// How reports reach the terminal.
enum Route
{
    off,    /// not sent (turned off, or tmux would mangle them)
    direct, /// written as they are
    tmux,   /// wrapped for tmux passthrough
}

/// The route for an interactive session: `enabled` is the config key,
/// `inTmux` whether `$TMUX` is set, `passthrough` tmux's
/// `allow-passthrough` value (`on` or `all` let it through).
Route routeFor(bool enabled, bool inTmux, string passthrough) pure nothrow
{
    import std.string : strip;
    if (!enabled) return Route.off;
    if (!inTmux) return Route.direct;
    auto p = passthrough.strip;
    return p == "on" || p == "all" ? Route.tmux : Route.off;
}

unittest
{
    assert(routeFor(false, false, null) == Route.off);
    assert(routeFor(true, false, null) == Route.direct);
    assert(routeFor(true, true, "off\n") == Route.off);
    assert(routeFor(true, true, "") == Route.off);
    assert(routeFor(true, true, "on\n") == Route.tmux);
    assert(routeFor(true, true, "all") == Route.tmux);
}

/// Change detection: the bytes to write for `r`, or null when the last
/// report sent was the same. `resend` makes the next report go out anyway
/// (after `/relaunch` or a resume, the terminal's record may be stale).
struct Emitter
{
    Route route;
    string last;

    /// The bytes for `r` on this route, or null (unchanged, or off).
    string next(const Report r) pure nothrow
    {
        if (route == Route.off) return null;
        auto seq = encode(r);
        if (seq == last) return null;
        last = seq;
        return route == Route.tmux ? tmuxWrap(seq) : seq;
    }

    /// Forget the last report so the next one is sent.
    void resend() pure nothrow @nogc { last = null; }
}

unittest
{
    auto e = Emitter(Route.direct);
    assert(e.next(Report(PState.working)).length);
    assert(e.next(Report(PState.working)) is null, "unchanged: not sent");
    assert(e.next(Report(PState.blocked, Kind.question, "?")).length);
    assert(e.next(Report(PState.working)).length);
    e.resend();
    assert(e.next(Report(PState.working)).length, "resent after resend()");
    auto off = Emitter(Route.off);
    assert(off.next(Report(PState.idle)) is null);
    auto t = Emitter(Route.tmux);
    import std.algorithm : startsWith;
    assert(t.next(Report(PState.idle)).startsWith("\x1bPtmux;"));
}

/// What the session is doing, in nano-coder's terms (the state mapping).
struct Session
{
    bool turnRunning;       /// a turn (or background sub-agents) is running
    bool blocked;           /// waiting on the user (a question, an approval, a login)
    Kind blockedOn;         /// what for
    string question;        /// the question shown
    bool turnEnded;         /// back at the prompt after a turn, not yet typed at
    string turnError;       /// that turn failed: why (null: it didn't)
    string answer;          /// that turn's answer
    string activity;        /// what the running turn does (null: unsaid)
    string name;            /// the session handle
}

/// The report for `s`: blocked beats working; at the prompt a failed turn is
/// `error`, a finished one `done` (its answer's first line) until the user
/// types, then `idle`.
Report reportFor(const Session s) pure nothrow
{
    Report r;
    r.title = s.name;
    if (s.blocked)
    {
        r.state = PState.blocked;
        r.kind = s.blockedOn;
        r.msg = s.question;
    }
    else if (s.turnRunning)
    {
        r.state = PState.working;
        r.msg = s.activity;
    }
    else if (s.turnEnded && s.turnError !is null)
    {
        r.state = PState.error;
        r.msg = s.turnError.length ? s.turnError : "the turn failed";
    }
    else if (s.turnEnded)
    {
        r.state = PState.done;
        r.msg = firstLine(s.answer);
    }
    else r.state = PState.idle;
    return r;
}

unittest // the state mapping
{
    Session s;
    s.name = "h";
    assert(reportFor(s) == Report(PState.idle, Kind.none, null, "h"));
    s.turnRunning = true;
    s.activity = "thinking";
    assert(reportFor(s) == Report(PState.working, Kind.none, "thinking", "h"));
    s.blocked = true;
    s.blockedOn = Kind.permission;
    s.question = "Keep going?";
    assert(reportFor(s) == Report(PState.blocked, Kind.permission, "Keep going?", "h"));
    s = Session.init;
    s.turnEnded = true;
    s.answer = "\nAll tests pass.\nDetails…";
    assert(reportFor(s) == Report(PState.done, Kind.none, "All tests pass."));
    s.turnError = "provider error: 500";
    assert(reportFor(s) == Report(PState.error, Kind.none, "provider error: 500"));
    s.turnError = "";
    assert(reportFor(s).msg == "the turn failed");
}

/// Where report bytes go (the frame renderer in the CLI).
alias Sink = void function(string bytes) @safe;

private struct Reporter
{
    Emitter emitter;
    Session session;
}

// The process-wide reporter: the route, the session's state and the last
// report, behind a lock (questions are reported from the key reader, turns
// from the main loop).
private shared Locked!Reporter gReporter;
private shared Sink gSink;

/// Start reporting on `route` through `sink` (call once the frame renderer
/// owns the terminal: only interactive TTY sessions report). Off sends nothing.
void start(Route route, Sink sink)
{
    if (route == Route.off) return;
    atomicStore(gReporter, new shared Locked!Reporter(Reporter(Emitter(route))));
    atomicStore(gSink, sink);
}

/// Whether reports are being sent.
bool active() { return atomicLoad(gReporter) !is null; }

/// Change the session's state with `f` and report it if the report changed.
void update(scope void delegate(ref Session) @safe f)
{
    auto r = atomicLoad(gReporter);
    if (r is null) return;
    string bytes;
    r.update((ref Reporter v) {
        f(v.session);
        bytes = v.emitter.next(reportFor(v.session));
    });
    if (bytes.length) atomicLoad(gSink)(bytes);
}

/// Re-send the current state even if unchanged (after `/relaunch` or a
/// resume the terminal's record may be stale or gone).
void resend()
{
    if (auto r = atomicLoad(gReporter)) r.update((ref Reporter v) { v.emitter.resend(); });
    update((ref Session _) {});
}

/// Remove the record (on exit); nothing is sent afterwards.
void clear()
{
    auto r = atomicLoad(gReporter);
    if (r is null) return;
    string bytes;
    r.update((ref Reporter v) {
        bytes = v.emitter.next(Report(PState.clear));
        v.emitter.route = Route.off;
    });
    if (bytes.length) atomicLoad(gSink)(bytes);
}

/// The value in `tmux show -v` output: its last non-blank line, trimmed.
string lastValue(string output) pure
{
    import std.string : lineSplitter, strip;
    string v;
    foreach (l; output.lineSplitter) if (l.strip.length) v = l.strip;
    return v;
}

unittest
{
    assert(lastValue("on\n") == "on");
    assert(lastValue("off\n") == "off");
    assert(lastValue("") is null);
}

/// `allow-passthrough` of the tmux server this process runs in, or null
/// when it can't be read (then reports are skipped inside tmux).
string tmuxPassthrough()
{
    import std.process : execute, Config;
    try
    {
        import std.process : environment;
        // The pane's value, inherited from the window and global ones (-A).
        auto pane = environment.get("TMUX_PANE", "");
        auto r = execute(pane.length ? ["tmux", "show", "-Apv", "-t", pane, "allow-passthrough"]
            : ["tmux", "show", "-gpv", "allow-passthrough"], null, Config.none, 4096);
        return r.status == 0 ? lastValue(r.output) : null;
    }
    catch (Exception) return null; // no tmux binary: treat passthrough as off
}
