/// Tool registry, shared argument helpers and output truncation.
module nano.tools;

@safe:

import std.math : trunc;

import std.conv : to;
import nano.clock : stdTimeNow;

import nano.safeio : ownText;

import std.json;
import std.format : format;
import std.algorithm : sort;
import nano.llm : ToolDefinition;

/// A tool failure the model should see as an error result.
class ToolError : Exception
{
    this(string msg) pure { super(msg); }
}

/// Decodes bytes as UTF-8, replacing each invalid sequence with U+FFFD
/// (like Rust's `String::from_utf8_lossy`), so tool output is never lost
/// to an encoding error.
string lossyUtf8(const(ubyte)[] data) @safe pure
{
    import nano.safeio : lossyText;
    return lossyText(data);
}

unittest
{
    ubyte[] bad = [0x61, 0xff, 0x62, 0xe2, 0x82, 0xac];
    assert(lossyUtf8(bad) == "a\uFFFDb€");
}

alias ToolHandler = string delegate(JSONValue args);

class ToolRegistry
{
    private ToolDefinition[string] defs;
    private ToolHandler[string] handlers;
    private Object[string] richHandlers;

    private static final class RichHandler(T)
    {
        T handler;
        this(T h) pure { handler = h; }
    }

    void register(ToolDefinition def, ToolHandler handler) pure
    {
        defs[def.name] = def;
        handlers[def.name] = handler;
    }

    /// Register an additional, richer-shaped handler for `name` (e.g.
    /// apply_patch's PatchHandler), retrievable via `handlerAs`. It is kept
    /// in its own map, so the plain ToolHandler used by `execute` is never
    /// replaced or reinterpreted.
    void registerHandler(T)(string name, T handler) pure
    {
        richHandlers[name] = new RichHandler!T(handler);
    }

    /// The richer handler registered for `name` with exactly the shape `T`,
    /// or null when none was (a type-checked downcast, never a reinterpret).
    T handlerAs(T)(string name)
    {
        auto h = name in richHandlers;
        if (h is null) return null;
        auto boxed = cast(RichHandler!T) *h;
        return boxed is null ? null : boxed.handler;
    }

    bool has(string name) pure const { return (name in defs) !is null; }

    /// Sorted by name so requests are stable across turns (prompt caching).
    ToolDefinition[] definitions() pure
    {
        auto all = defs.values;
        all.sort!((a, b) => a.name < b.name);
        return all;
    }

    string execute(string name, JSONValue args)
    {
        auto h = name in handlers;
        if (h is null) throw new ToolError(format("Tool '%s' not found", name));
        return (*h)(args);
    }
}

unittest
{
    alias Rich = string delegate(JSONValue, int) @safe;
    auto r = new ToolRegistry;
    r.register(ToolDefinition("t", "d", JSONValue.init), (JSONValue a) => "plain");
    assert(r.handlerAs!Rich("t") is null);
    r.registerHandler!Rich("t", delegate(JSONValue a, int n) @safe => "rich");
    assert(r.execute("t", JSONValue.init) == "plain"); // execute keeps the plain shape
    assert(r.handlerAs!Rich("t")(JSONValue.init, 1) == "rich");
    assert(r.handlerAs!(string delegate(JSONValue, string))("t") is null); // wrong shape
}

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

string requireString(JSONValue args, string name, string tool) pure
{
    auto v = name in args;
    if (v is null) throw new ToolError(format(`%s: missing required argument "%s"`, tool, name));
    if (v.type == JSONType.null_) throw new ToolError(format(`%s: argument "%s" is null; provide a string value`, tool, name));
    if (v.type != JSONType.string)
        throw new ToolError(format(`%s: argument "%s" must be a string, got %s`, tool, name, jsonTypeName(*v)));
    return v.str;
}

/// "a number", "an array", ...: what a wrongly typed argument was.
string jsonTypeName(const JSONValue v) pure nothrow
{
    final switch (v.type)
    {
        case JSONType.null_: return "null";
        case JSONType.true_, JSONType.false_: return "a boolean";
        case JSONType.integer, JSONType.uinteger, JSONType.float_: return "a number";
        case JSONType.string: return "a string";
        case JSONType.array: return "an array";
        case JSONType.object: return "an object";
    }
}

string optString(JSONValue args, string name, string def = null) pure
{
    auto v = name in args;
    if (v is null || v.type == JSONType.null_) return def;
    if (v.type != JSONType.string) throw new ToolError(format(`argument "%s" must be a string`, name));
    return v.str;
}

long optInt(JSONValue args, string name, long def) pure
{
    auto v = name in args;
    if (v is null || v.type == JSONType.null_) return def;
    if (v.type == JSONType.integer) return v.integer;
    if (v.type == JSONType.uinteger) return v.uinteger.to!long;
    // An integral float converts only below 2^63: `long.max` rounds to 2^63
    // as a double, so Phobos's `value > T.max` check misses
    // 9223372036854775808.0 and the cast would be out of range instead of
    // reporting invalid input. (Below -2^63 the cast itself throws, so only
    // the upper boundary needs the explicit gate.)
    if (v.type == JSONType.float_ && v.floating == trunc(v.floating) && v.floating < 0x1p63)
        return v.floating.to!long;
    if (v.type == JSONType.string)
    {
        import std.conv : to;
        try return v.str.to!long;
        catch (Exception) {} // not numeric: reported as a tool error just below
    }
    throw new ToolError(format(`argument "%s" must be an integer`, name));
}

bool optBool(JSONValue args, string name, bool def) pure
{
    auto v = name in args;
    if (v is null || v.type == JSONType.null_) return def;
    if (v.type == JSONType.true_) return true;
    if (v.type == JSONType.false_) return false;
    if (v.type == JSONType.string && (v.str == "true" || v.str == "false")) return v.str == "true";
    throw new ToolError(format(`argument "%s" must be a boolean`, name));
}

// ---------------------------------------------------------------------------
// Output truncation
// ---------------------------------------------------------------------------

enum size_t defaultMaxOutput = 40_000;
enum size_t maxOutputLimit = 1_000_000;

/// Keep the head and tail of `text` within `limit` characters. When cut, the
/// full text is saved and its path noted, so nothing is lost.
string truncateOutput(string text, size_t limit, string label)
{
    import std.utf : toUTF32, toUTF8;
    if (text.length <= limit) return text;
    auto chars = text.toUTF32;
    if (chars.length <= limit) return text;
    auto spill = spillFile(text, label);
    auto head = limit * 2 / 3;
    auto tail = limit - head;
    return format("%s\n\n[... %s characters omitted (sha256:%s); full output saved to %s ...]\n\n%s",
            chars[0 .. head].toUTF8, chars.length - limit, contentDigest(text), spill, chars[$ - tail .. $].toUTF8);
}

/// The first 16 hex digits of the text's SHA-256: the spill marker's
/// identity, which the repeat detector keys on instead of the per-call path.
string contentDigest(scope const(char)[] text) pure
{
    import std.digest.sha : sha256Of, toHexString;
    import std.ascii : LetterCase;
    auto d = sha256Of(text);
    return toHexString!(LetterCase.lower)(d[0 .. 8]).idup;
}

/// The spill files this thread wrote (the agent's: tools run on it). The
/// repeat detector rewrites only these markers' paths, so a look-alike
/// marker in ordinary output stays as it is (Rust's out-of-band spills).
private bool[string] spilled_;

/// Whether `path` is a spill file this thread wrote.
bool isSpill(string path) { return (path in spilled_) !is null; }

// rust: output.rs::is_utf8_safe_and_mentions_path
unittest
{
    import std.algorithm : canFind, startsWith, endsWith;
    import std.array : replicate;
    import std.file : remove;
    import std.regex : matchFirst;
    auto text = "é".replicate(10);
    auto t = truncateOutput(text, 3, "test");
    auto m = t.matchFirst(`full output saved to (.*\.txt) \.\.\.\]`);
    scope (exit) remove(m[1]);
    assert(t.startsWith("éé\n") && t.endsWith("\né"), "cut on character boundaries: " ~ t);
    assert(t.canFind("[... 7 characters omitted (sha256:" ~ contentDigest(text) ~ "); full output saved to "), t);
    assert(isSpill(m[1]) && !isSpill("/tmp/elsewhere.txt"));
}

/// Where cut outputs are saved: the session's `<id>.spill` directory when
/// the session is persisted, so the paths in the log stay valid on resume;
/// null for a per-process temporary directory. Per thread: the agent's.
private string spillDir_;

/// Set (or clear, with null) the directory cut outputs are saved in.
void setSpillDir(string dir) { spillDir_ = dir; }

/// The spill directory of the session logged at `logPath` (`<id>.spill`
/// beside `<id>.jsonl`, as Rust's `session::spill_dir_for`).
string spillDirFor(string logPath) pure
{
    import std.path : stripExtension;
    return logPath.stripExtension ~ ".spill";
}

private string spillFile(string text, string label)
{
    import std.file : write, mkdirRecurse, tempDir, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.datetime.systime : Clock;
    static size_t counter;
    auto dir = spillDir_.length ? spillDir_ : buildPath(tempDir, format("nano-coder-%s", thisProcessID));
    mkdirRecurse(dir);
    // Never overwrite: a recorded path must keep pointing at its output.
    auto stem = buildPath(dir, format("%s-%s-%s", label, stdTimeNow, ++counter));
    auto path = stem ~ ".txt";
    for (size_t n = 2; path.exists; n++) path = format("%s-%s.txt", stem, n);
    write(path, text);
    if (spilled_.length > 10_000) spilled_ = null; // bounded: the oldest calls are long out of the repeat window
    spilled_[path] = true;
    return path;
}

// Spills go to the session directory when one is set.
unittest
{
    import std.file : tempDir, rmdirRecurse, exists, readText;
    import std.path : buildPath, dirName;
    import std.process : thisProcessID;
    auto dir = buildPath(tempDir, format("nano-d-spill-test-%s", thisProcessID));
    scope (exit) { setSpillDir(null); if (dir.exists) rmdirRecurse(dir); }
    assert(spillDirFor("/s/sess-1.jsonl") == "/s/sess-1.spill");
    setSpillDir(dir);
    auto big = new char[300];
    big[] = 'y';
    auto t = truncateOutput(ownText(big), 100, "tool-c1-grep");
    import std.regex : matchFirst;
    auto m = t.matchFirst(`saved to (.*\.txt) \.\.\.\]`);
    assert(m && m[1].dirName == dir && readText(m[1]).length == 300);
}

// rust: output.rs::spills_long_output_to_a_file
// rust: output.rs::leaves_short_output_alone
// rust: output.rs::keeps_head_and_tail
unittest
{
    auto big = new char[1000];
    big[] = 'x';
    auto t = truncateOutput(ownText(big), 100, "test");
    import std.string : indexOf;
    assert(t.indexOf("900 characters omitted") > 0);
    assert(truncateOutput("short", 100, "test") == "short");
}

unittest
{
    auto args = parseJSON(`{"a":"x","n":"5","b":true}`);
    assert(optInt(args, "n", 0) == 5 && optBool(args, "b", false) && optString(args, "a") == "x");
    bool threw;
    try requireString(args, "missing", "t"); catch (ToolError) threw = true;
    assert(threw);
}

// rust: output.rs::spill_never_overwrites_an_existing_file
unittest
{
    import std.file : tempDir, rmdirRecurse, exists, dirEntries, SpanMode, readText;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.array : array;
    import std.algorithm : map, sort;
    auto dir = buildPath(tempDir, format("nano-d-spill-twice-%s", thisProcessID));
    scope (exit) { setSpillDir(null); if (dir.exists) rmdirRecurse(dir); }
    setSpillDir(dir);
    truncateOutput("abcdefghij", 4, "tool-x");
    truncateOutput("klmnopqrst", 4, "tool-x");
    auto texts = dirEntries(dir, SpanMode.shallow).array.map!(e => readText(e.name)).array.sort.array;
    assert(texts == ["abcdefghij", "klmnopqrst"]);
}

unittest
{
    // A number past `long.max` is reported where it is read, not wrapped
    // to a negative value.
    import std.conv : ConvException;
    import std.exception : assertThrown;
    import std.json : parseJSON;
    assert(optInt(parseJSON(`{"n":7.0}`), "n", 0) == 7);
    assertThrown!ConvException(optInt(parseJSON(`{"n":18446744073709551615}`), "n", 0));
    // 1e300 is past 2^63: invalid input, a tool error rather than a bad cast.
    assertThrown!ToolError(optInt(parseJSON(`{"n":1e300}`), "n", 0));
}

unittest // optInt rejects integral floats at and above 2^63
{
    import std.exception : assertThrown;
    // `long.max` rounds to 2^63 as a double, so 9223372036854775808.0 slips
    // past Phobos's `value > T.max` check; the explicit 2^63 gate rejects it
    // as invalid input instead of an out-of-range cast.
    assertThrown!ToolError(optInt(parseJSON(`{"n": 9223372036854775808.0}`), "n", 0));
    assertThrown!ToolError(optInt(parseJSON(`{"n": 1.5}`), "n", 0)); // non-integral
    // The largest double below 2^63 and -2^63 itself still convert.
    assert(optInt(parseJSON(`{"n": 9223372036854774784.0}`), "n", 0) == 9223372036854774784L);
    assert(optInt(parseJSON(`{"n": -9223372036854775808.0}`), "n", 0) == long.min);
    assert(optInt(parseJSON(`{"n": 4096.0}`), "n", 0) == 4096);
}
