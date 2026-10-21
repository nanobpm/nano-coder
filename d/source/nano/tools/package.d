/// Tool registry, shared argument helpers and output truncation.
module nano.tools;

import std.json;
import std.format : format;
import std.algorithm : sort;
import nano.llm : ToolDefinition;

/// A tool failure the model should see as an error result.
class ToolError : Exception
{
    this(string msg) { super(msg); }
}

/// Decodes bytes as UTF-8, replacing each invalid sequence with U+FFFD
/// (like Rust's `String::from_utf8_lossy`), so tool output is never lost
/// to an encoding error.
string lossyUtf8(const(ubyte)[] data) @safe pure
{
    import std.utf : decode, UTFException;
    import std.array : appender;
    auto s = cast(const(char)[]) data;
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

    void register(ToolDefinition def, ToolHandler handler)
    {
        defs[def.name] = def;
        handlers[def.name] = handler;
    }

    bool has(string name) const { return (name in defs) !is null; }

    /// Sorted by name so requests are stable across turns (prompt caching).
    ToolDefinition[] definitions()
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

// ---------------------------------------------------------------------------
// Argument helpers
// ---------------------------------------------------------------------------

string requireString(JSONValue args, string name, string tool)
{
    auto v = name in args;
    if (v is null) throw new ToolError(format(`%s argument "%s" must be set`, tool, name));
    if (v.type != JSONType.string) throw new ToolError(format(`%s argument "%s" must be a string`, tool, name));
    return v.str;
}

string optString(JSONValue args, string name, string def = null)
{
    auto v = name in args;
    if (v is null || v.type == JSONType.null_) return def;
    if (v.type != JSONType.string) throw new ToolError(format(`argument "%s" must be a string`, name));
    return v.str;
}

long optInt(JSONValue args, string name, long def)
{
    auto v = name in args;
    if (v is null || v.type == JSONType.null_) return def;
    if (v.type == JSONType.integer) return v.integer;
    if (v.type == JSONType.uinteger) return cast(long) v.uinteger;
    if (v.type == JSONType.float_ && v.floating == cast(long) v.floating) return cast(long) v.floating;
    if (v.type == JSONType.string)
    {
        import std.conv : to;
        try return v.str.to!long;
        catch (Exception) {}
    }
    throw new ToolError(format(`argument "%s" must be an integer`, name));
}

bool optBool(JSONValue args, string name, bool def)
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
    return format("%s\n\n[... %s characters omitted; full output saved to %s ...]\n\n%s",
            chars[0 .. head].toUTF8, chars.length - limit, spill, chars[$ - tail .. $].toUTF8);
}

private string spillFile(string text, string label)
{
    import std.file : write, mkdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.datetime.systime : Clock;
    static size_t counter;
    auto dir = buildPath(tempDir, "nano-coder-d");
    mkdirRecurse(dir);
    auto path = buildPath(dir, format("%s-%s-%s-%s.txt", label, thisProcessID, Clock.currStdTime, ++counter));
    write(path, text);
    return path;
}

unittest
{
    auto big = new char[1000];
    big[] = 'x';
    auto t = truncateOutput(cast(string) big, 100, "test");
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
