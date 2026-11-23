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

/// What a worker thread hands back for one concurrent call. Sendable: plain
/// strings and immutable bytes only.
struct JobResult
{
    /// The result text, or the error message the model sees.
    string text;
    bool error;
    /// Failed with an unexpected exception: `text` is its message, which the
    /// agent prefixes with the tool name (as for a sequential call).
    bool crashed;
    /// Tool-specific facts for `Concurrency.settle` (e.g. a read's digest).
    immutable(ubyte)[] receipt;
}

/// A read-only call packaged for a worker thread (issue #222): a
/// context-free function and sendable inputs, so `nano.safeio.spawn` can
/// run it. It must not touch the agent's (or any thread-local) state; it
/// reads the filesystem and its own inputs only.
struct Job
{
    JobResult function(string argsJson, immutable(string)[] context) @safe run;
    /// The call's arguments, as JSON text (a `JSONValue` isn't sendable).
    string argsJson;
    /// Whatever else the tool needs, resolved on the agent's thread.
    immutable(string)[] context;
}

/// Run a job's function, turning its exceptions into the error text the
/// agent's sequential path produces for the same failure.
JobResult runJob(Job j)
{
    try return j.run(j.argsJson, j.context);
    catch (ToolError e) return JobResult(e.msg, true);
    catch (Exception e) return JobResult(e.msg, true, true);
}

/// How a tool may run alongside the other calls of one reply (issue #222).
/// The default (not read-only) makes each call a barrier that runs alone.
struct Concurrency
{
    /// Read-only by construction and never prompts: a run of consecutive
    /// read-only calls executes concurrently.
    bool readOnly;
    /// Packages a call for a worker thread; runs on the agent's thread.
    /// Without it a read-only call runs on the agent's thread while the
    /// workers run (cheap, in-memory tools).
    Job delegate(JSONValue args) @safe offload;
    /// Applies a worker's result to the tool's own state, on the agent's
    /// thread, in call order (e.g. read_file records what was read).
    void delegate(const ref JobResult) @safe settle;
}

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
    private Concurrency[string] modes;

    void register(ToolDefinition def, ToolHandler handler, Concurrency mode = Concurrency.init) pure
    {
        defs[def.name] = def;
        handlers[def.name] = handler;
        if (mode.readOnly) modes[def.name] = mode;
        else modes.remove(def.name);
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

    /// Whether calls to `name` may run concurrently with other read-only calls.
    bool readOnly(string name) pure const { return (name in modes) !is null; }

    /// The tool's concurrency (the default for a sequential tool).
    Concurrency concurrency(string name) pure
    {
        auto m = name in modes;
        return m is null ? Concurrency.init : *m;
    }

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
    if (text.length <= limit) return text;
    // Walk code points in place without allocating a 4x UTF-32 copy.
    auto headTarget = limit * 2 / 3;
    auto tailTarget = limit - headTarget;
    size_t count;
    size_t headByte;
    bool headFound;
    for (size_t i = 0; i < text.length;)
    {
        if (!headFound && count == headTarget)
        {
            headByte = i;
            headFound = true;
        }
        ubyte b = text[i];
        size_t step = (b & 0x80) == 0 ? 1
            : (b & 0xE0) == 0xC0 ? 2
            : (b & 0xF0) == 0xE0 ? 3
            : (b & 0xF8) == 0xF0 ? 4 : 1;
        i += step <= text.length - i ? step : text.length - i;
        count++;
    }
    if (count <= limit) return text;
    size_t tailByte = text.length;
    size_t tailCount;
    while (tailByte > 0 && tailCount < tailTarget)
    {
        tailByte--;
        if ((text[tailByte] & 0xC0) != 0x80) tailCount++;
    }
    auto spill = spillFile(text, label);
    return format("%s\n\n[... %s characters omitted (sha256:%s); full output saved to %s ...]\n\n%s",
            text[0 .. headByte], count - limit, contentDigest(text), spill, text[tailByte .. $]);
}

/// Stream-truncate a file on disk (raw bytes, lossy UTF-8 decoded on the fly)
/// to `limit` characters without loading the whole file into memory. When the
/// file exceeds `limit` characters, its UTF-8-sanitized full text is streamed
/// to a spill file and the head/tail marker is returned. Also sets `denied` if
/// `checkDenied` is true and any denial phrase appears in the output.
string truncateFile(string path, size_t limit, string label, out bool denied, bool checkDenied = false)
{
    import std.file : getSize;
    import std.stdio : File;
    import std.digest.sha : SHA256, toHexString;
    import std.ascii : LetterCase;
    import std.array : Appender;
    import std.string : representation;
    import nano.safeio : asChars;
    import nano.sandbox : looksDenied;
    import nano.arith : saturatingSub;

    denied = false;
    auto rawSize = getSize(path);
    if (rawSize == 0) return null;
    // Fast path for small files: at most `limit` bytes can never exceed `limit`
    // UTF-8 code points (even if every byte is invalid -> 1 U+FFFD each).
    if (rawSize <= limit)
    {
        // Cap at the sampled size: a background child may still be appending.
        auto buf = new ubyte[rawSize];
        auto text = lossyUtf8(File(path, "rb").rawRead(buf));
        if (checkDenied) denied = looksDenied(text);
        return text;
    }

    auto headTarget = limit * 2 / 3;
    auto tailTarget = limit - headTarget;

    // Stream the file in 64 KiB chunks, lossy-decoding UTF-8 across chunk
    // boundaries, hashing the decoded UTF-8, capturing head + rolling tail,
    // and writing the sanitized full output to a spill file once we know it
    // exceeds `limit` characters.
    // Allocated only when spilling actually starts: a file over `limit` bytes
    // may still fit `limit` characters and then needs no spill directory.
    string spillPath;
    File spillF;
    bool spilling;
    scope (failure)
    {
        if (spilling)
        {
            import std.file : exists, remove;
            spillF.close();
            if (spillPath.length && spillPath.exists) remove(spillPath);
        }
    }

    Appender!(char[]) headBuf;
    // Rolling double-buffer of decoded UTF-8 bytes for the tail. Reused via
    // `.clear()` so streaming a multi-MB file does zero per-chunk heap copies.
    Appender!(char[]) smallBuf; // holds decoded text while totalChars <= limit
    Appender!(char[]) tailPrev;
    Appender!(char[]) tailCur;
    size_t tailCurChars;
    size_t headChars;
    size_t totalChars;
    SHA256 sha;
    sha.start();

    // Small overlap for sandbox denial phrase matching across chunk boundaries
    // (longest phrase in looksDenied is 23 bytes).
    enum size_t deniedOverlap = 32;
    char[deniedOverlap * 2] deniedJoin; // carry + piece prefix, fixed: no per-chunk GC copy
    size_t deniedCarryLen;

    static const(char)[] lastNChars(const(char)[] s, size_t n) pure nothrow @nogc
    {
        size_t pos = s.length;
        size_t seen;
        while (pos > 0 && seen < n)
        {
            pos--;
            if ((s[pos] & 0xC0) != 0x80) seen++;
        }
        return s[pos .. $];
    }

    auto startSpilling = () {
        if (spilling) return;
        spillPath = nextSpillPath(label);
        spillF = File(spillPath, "wb");
        spilling = true;
        if (smallBuf.data.length) spillF.rawWrite(smallBuf.data);
        // Seed rolling tail from what we already decoded.
        if (tailTarget > 0)
        {
            auto seed = totalChars > tailTarget ? lastNChars(smallBuf.data, tailTarget) : smallBuf.data;
            tailCur.put(seed);
            tailCurChars = totalChars > tailTarget ? tailTarget : totalChars;
        }
        smallBuf.clear();
    };

    auto pushDecoded = (const(char)[] piece, size_t nChars) {
        if (!piece.length) return;
        sha.put(piece.representation);
        if (checkDenied && !denied)
        {
            // Scan the piece in place, plus a fixed-size join of the carried
            // tail and the piece's head for phrases straddling the boundary.
            auto pre = piece.length > deniedOverlap ? piece[0 .. deniedOverlap] : piece;
            deniedJoin[deniedCarryLen .. deniedCarryLen + pre.length] = pre[];
            auto joined = deniedJoin[0 .. deniedCarryLen + pre.length];
            if (looksDenied(piece) || looksDenied(joined)) denied = true;
            else
            {
                const(char)[] keep = piece.length >= deniedOverlap
                    ? piece[$ - deniedOverlap .. $]
                    : joined[saturatingSub(joined.length, deniedOverlap) .. $];
                char[deniedOverlap] tmp;
                tmp[0 .. keep.length] = keep[];
                deniedJoin[0 .. keep.length] = tmp[0 .. keep.length];
                deniedCarryLen = keep.length;
            }
        }
        if (headChars < headTarget)
        {
            auto need = headTarget - headChars;
            if (nChars <= need)
            {
                headBuf.put(piece);
                headChars += nChars;
            }
            else
            {
                size_t cut;
                size_t taken;
                while (cut < piece.length && taken < need)
                {
                    ubyte b = piece[cut];
                    size_t step = (b & 0x80) == 0 ? 1
                        : (b & 0xE0) == 0xC0 ? 2
                        : (b & 0xF0) == 0xE0 ? 3
                        : (b & 0xF8) == 0xF0 ? 4 : 1;
                    cut += step <= piece.length - cut ? step : piece.length - cut;
                    taken++;
                }
                headBuf.put(piece[0 .. cut]);
                headChars += taken;
            }
        }
        totalChars += nChars;
        if (!spilling)
        {
            smallBuf.put(piece);
            if (totalChars > limit) startSpilling();
        }
        else
        {
            spillF.rawWrite(piece);
            if (tailTarget > 0)
            {
                if (nChars >= tailTarget)
                {
                    // This chunk alone has enough trailing characters: keep
                    // only its last `tailTarget` chars and drop older tail.
                    tailPrev.clear();
                    tailCur.clear();
                    tailCur.put(lastNChars(piece, tailTarget));
                    tailCurChars = tailTarget;
                }
                else
                {
                    tailCur.put(piece);
                    tailCurChars += nChars;
                    if (tailCurChars >= tailTarget)
                    {
                        import std.algorithm.mutation : swap;
                        swap(tailPrev, tailCur);
                        tailCur.clear();
                        tailCurChars = 0;
                    }
                }
            }
        }
    };

    auto src = File(path, "rb");
    ubyte[64 * 1024] chunkBuf;
    ubyte[4] carry;
    size_t carryLen;
    Appender!(char[]) decoded;

    // Read only the `rawSize` bytes sampled above: background children left by
    // the command may keep appending, and a live EOF could then never come.
    ulong remaining = rawSize;
    for (;;)
    {
        if (remaining == 0) break;
        auto want = remaining < chunkBuf.length ? remaining : chunkBuf.length;
        auto got = src.rawRead(chunkBuf[0 .. want]);
        if (!got.length) break;
        remaining -= got.length;

        // Decode `carry[0 .. carryLen]` + `got`, leaving an incomplete
        // trailing multi-byte UTF-8 sequence (at most 3 bytes) in `carry` for
        // the next chunk.
        decoded.clear();
        size_t chars;

        // Combine small carry with the start of `got` so boundary sequences
        // decode seamlessly.
        ubyte[64 * 1024 + 4] combined;
        const(ubyte)[] data;
        if (carryLen)
        {
            combined[0 .. carryLen] = carry[0 .. carryLen];
            combined[carryLen .. carryLen + got.length] = got[];
            data = combined[0 .. carryLen + got.length];
            carryLen = 0;
        }
        else data = got;

        size_t i;
        while (i < data.length)
        {
            auto b = data[i];
            if (b < 0x80)
            {
                // Fast ASCII run.
                size_t j = i + 1;
                while (j < data.length && data[j] < 0x80) j++;
                decoded.put(asChars(data[i .. j]));
                chars += j - i;
                i = j;
                continue;
            }
            size_t need = (b & 0xE0) == 0xC0 ? 2
                : (b & 0xF0) == 0xE0 ? 3
                : (b & 0xF8) == 0xF0 ? 4 : 0;
            if (need == 0)
            {
                decoded.put("\uFFFD");
                chars++;
                i++;
                continue;
            }
            if (data.length - i < need)
            {
                // Could be a valid sequence split across chunks; hold it.
                carryLen = data.length - i;
                carry[0 .. carryLen] = data[i .. $];
                break;
            }
            if (validUtf8Seq(data[i .. i + need]))
            {
                decoded.put(asChars(data[i .. i + need]));
                chars++;
                i += need;
            }
            else
            {
                decoded.put("\uFFFD");
                chars++;
                i++;
            }
        }
        pushDecoded(decoded.data, chars);
    }
    if (carryLen)
    {
        // Any bytes left in `carry` at EOF are an incomplete UTF-8 sequence:
        // lossyUtf8 replaces each invalid byte with U+FFFD.
        auto tail = lossyUtf8(carry[0 .. carryLen].dup);
        size_t chars;
        for (size_t i = 0; i < tail.length;)
        {
            ubyte b = tail[i];
            size_t step = (b & 0x80) == 0 ? 1
                : (b & 0xE0) == 0xC0 ? 2
                : (b & 0xF0) == 0xE0 ? 3
                : (b & 0xF8) == 0xF0 ? 4 : 1;
            i += step <= tail.length - i ? step : tail.length - i;
            chars++;
        }
        pushDecoded(tail, chars);
    }

    if (!spilling) return smallBuf.data.idup;

    spillF.close();
    recordSpill(spillPath);

    // Extract exact `tailTarget` trailing code points from `tailPrev ~ tailCur`.
    string tailStr;
    if (tailTarget > 0)
    {
        auto joined = tailPrev.data.length ? (tailPrev.data ~ tailCur.data) : tailCur.data;
        tailStr = lastNChars(joined, tailTarget).idup;
    }

    auto digest = toHexString!(LetterCase.lower)(sha.finish()[0 .. 8]).idup;
    return format("%s\n\n[... %s characters omitted (sha256:%s); full output saved to %s ...]\n\n%s",
            headBuf.data, totalChars - limit, digest, spillPath, tailStr);
}

private bool validUtf8Seq(const(ubyte)[] seq) pure nothrow @nogc
{
    if (seq.length == 2)
        return seq[0] >= 0xC2 && seq[0] <= 0xDF && (seq[1] & 0xC0) == 0x80;
    if (seq.length == 3)
    {
        auto b0 = seq[0], b1 = seq[1], b2 = seq[2];
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) return false;
        if (b0 == 0xE0 && b1 < 0xA0) return false; // overlong
        if (b0 == 0xED && b1 >= 0xA0) return false; // UTF-16 surrogate
        return true;
    }
    if (seq.length == 4)
    {
        auto b0 = seq[0], b1 = seq[1], b2 = seq[2], b3 = seq[3];
        if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80) return false;
        if (b0 == 0xF0 && b1 < 0x90) return false; // overlong
        if (b0 == 0xF4 && b1 >= 0x90) return false; // > U+10FFFF
        if (b0 > 0xF4) return false;
        return true;
    }
    return false;
}

/// Keep the head and tail of `text` within `limit` UTF-8 bytes, marker
/// included, cutting only on code-point boundaries. Use it where the cap is
/// advertised in bytes (a listing of multi-byte titles must not exceed it).
/// When cut, the full text is spilled and its path noted. A `limit` smaller
/// than the marker itself yields the marker alone, which is then over `limit`:
/// the spill path must never be dropped.
string truncateOutputBytes(string text, size_t limit, string label)
{
    if (text.length <= limit) return text;
    auto spill = spillFile(text, label);
    auto digest = contentDigest(text);
    enum fmt = "\n\n[... %s bytes omitted (sha256:%s); full output saved to %s ...]\n\n";
    // Size the budget with text.length as the count: the real omitted count
    // is no larger, so its marker is no longer and the result still fits.
    import nano.arith : saturatingSub;
    auto budget = saturatingSub(limit, format(fmt, text.length, digest, spill).length);
    size_t head = budget * 2 / 3;
    while (head > 0 && (text[head] & 0xC0) == 0x80) head--;
    size_t tailStart = text.length - (budget - head);
    while (tailStart < text.length && (text[tailStart] & 0xC0) == 0x80) tailStart++;
    auto marker = format(fmt, tailStart - head, digest, spill);
    return text[0 .. head] ~ marker ~ text[tailStart .. $];
}

unittest
{
    import std.algorithm : canFind;
    import std.array : replicate;
    import std.file : remove;
    import std.regex : matchFirst;
    import std.utf : validate;
    auto text = "\U0001F600".replicate(30_000); // 120 KB of 4-byte characters
    auto t = truncateOutputBytes(text, 40_000, "test-bytes");
    assert(t.length <= 40_000, "the cap counts bytes");
    validate(t);
    auto m = t.matchFirst(`full output saved to (.*\.txt) \.\.\.\]`);
    assert(!m.empty);
    remove(m[1]);
    // The marker counts the bytes actually cut, not the whole text.
    import std.conv : to;
    auto mk = t.matchFirst(`\n\n\[\.\.\. (\d+) bytes omitted.*\.\.\.\]\n\n`);
    assert(!mk.empty && mk[1].to!size_t == text.length - (t.length - mk.hit.length), mk.hit);
    assert(truncateOutputBytes("short", 100, "x") == "short");
    // A limit below the marker's size keeps the marker (and spill path) alone.
    auto tiny = truncateOutputBytes("x".replicate(500), 10, "test-tiny");
    auto tm = tiny.matchFirst(`full output saved to (.*\.txt) \.\.\.\]`);
    assert(!tm.empty && tiny.canFind("[... 500 bytes omitted"), tiny);
    remove(tm[1]);
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

private string nextSpillPath(string label)
{
    import std.file : mkdirRecurse, tempDir, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    static size_t counter;
    auto dir = spillDir_.length ? spillDir_ : buildPath(tempDir, format("nano-coder-%s", thisProcessID));
    mkdirRecurse(dir);
    // Never overwrite: a recorded path must keep pointing at its output.
    auto stem = buildPath(dir, format("%s-%s-%s", label, stdTimeNow, ++counter));
    auto path = stem ~ ".txt";
    for (size_t n = 2; path.exists; n++) path = format("%s-%s.txt", stem, n);
    return path;
}

private void recordSpill(string path)
{
    if (spilled_.length > 10_000) spilled_ = null; // bounded: the oldest calls are long out of the repeat window
    spilled_[path] = true;
}

private string spillFile(string text, string label)
{
    import std.file : write;
    auto path = nextSpillPath(label);
    write(path, text);
    recordSpill(path);
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

// Stream truncation of a large file matches `truncateOutput` byte-for-byte
// (head, tail, omitted count, sha256 digest, spill contents, and denial check)
// while keeping GC heap bounded well below the file size (issue #307).
unittest
{
    import core.memory : GC;
    import std.algorithm : canFind, startsWith, endsWith;
    import std.file : tempDir, write, remove, exists, readText;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.regex : matchFirst;
    import std.stdio : File;

    // 1. Equivalence on multi-byte + invalid UTF-8 crossing chunk boundaries,
    //    plus sandbox denial phrase straddling a 64 KiB boundary.
    {
        auto p = buildPath(tempDir, format("nano-d-trunc-eq-%s.bin", thisProcessID));
        scope (exit) if (p.exists) remove(p);
        ubyte[] raw;
        raw.length = 64 * 1024 - 1;
        raw[] = 'a';
        raw ~= [0xE2, 0x82, 0xAC]; // '€' split across 64 KiB chunk boundary
        raw ~= [0xFF, 0xFE];       // invalid bytes -> U+FFFD each
        raw ~= cast(const(ubyte)[]) "Operation not permitted";
        foreach (_; 0 .. 100) raw ~= cast(const(ubyte)[]) "héllo😀";
        write(p, raw);

        auto expectedText = lossyUtf8(raw);
        auto expected = truncateOutput(expectedText, 50, "eq-ref");
        auto refPath = expected.matchFirst(`full output saved to (.*\.txt) \.\.\.\]`);
        scope (exit) if (refPath && refPath[1].exists) remove(refPath[1]);

        bool denied;
        auto got = truncateFile(p, 50, "eq-stream", denied, true);
        auto gotPath = got.matchFirst(`full output saved to (.*\.txt) \.\.\.\]`);
        scope (exit) if (gotPath && gotPath[1].exists) remove(gotPath[1]);

        assert(denied, "expected denial phrase to be detected while streaming");
        assert(gotPath && isSpill(gotPath[1]));
        assert(readText(gotPath[1]) == expectedText, "spill content mismatch");
        // Compare markers ignoring only the spill file path.
        assert(got.startsWith(expected[0 .. 33]), "head mismatch");
        assert(got.canFind("(sha256:" ~ contentDigest(expectedText) ~ ")"), "digest mismatch: " ~ got);
        assert(got.endsWith(expected[$ - 20 .. $]), "tail mismatch");
    }

    // 1b. Complete-result equivalence (spill paths normalised only): a denial
    //     phrase straddling a chunk boundary, and tails longer than one 64 KiB
    //     chunk so the rolling-tail buffers rotate, ending both exactly on a
    //     chunk boundary and with a partially filled current buffer.
    {
        import std.regex : replaceAll, regex;
        auto spillRe = regex(`full output saved to (.*\.txt) \.\.\.\]`);
        string norm(string s) { return s.replaceAll(spillRe, "full output saved to SPILL ...]"); }
        void check(const(ubyte)[] raw, size_t limit, bool wantDenied, string label)
        {
            auto p = buildPath(tempDir, format("nano-d-trunc-full-%s.bin", thisProcessID));
            scope (exit) if (p.exists) remove(p);
            write(p, raw);
            auto expected = truncateOutput(lossyUtf8(raw), limit, "full-ref");
            auto em = expected.matchFirst(spillRe);
            scope (exit) if (em && em[1].exists) remove(em[1]);
            bool denied;
            auto got = truncateFile(p, limit, "full-stream", denied, true);
            auto gm = got.matchFirst(spillRe);
            scope (exit) if (gm && gm[1].exists) remove(gm[1]);
            assert(norm(got) == norm(expected), label ~ ": output mismatch");
            assert(denied == wantDenied, label ~ ": denial mismatch");
        }
        enum chunk = 64 * 1024;
        enum phrase = "Operation not permitted";
        // Phrase split across the first chunk boundary.
        {
            ubyte[] raw;
            raw.length = chunk - 10;
            raw[] = 'a';
            raw ~= cast(const(ubyte)[]) phrase;
            raw ~= new ubyte[](chunk)[] = 'b';
            check(raw, 50, true, "denial across boundary");
        }
        // Without the phrase, no denial (guards against a fail-open matcher).
        {
            auto raw = new ubyte[](3 * chunk);
            raw[] = 'c';
            check(raw, 50, false, "no denial");
        }
        // Tail larger than a chunk; file ends on a chunk boundary and mid-chunk.
        foreach (extra; [0, 12_345])
        {
            auto raw = new ubyte[](8 * chunk + extra);
            foreach (i, ref b; raw) b = cast(ubyte)('a' + (i * 7 + i / 977) % 26);
            raw[5 * chunk + 3 .. 5 * chunk + 5] = [0xC3, 0xA9]; // multi-byte in tail
            check(raw, 3 * chunk, false, format("rotation extra=%s", extra));
            check(raw, 2 * chunk + 1, false, format("rotation odd extra=%s", extra));
        }
    }

    // 2. Memory bound: streaming a 16 MiB file must not grow GC heap by ~16 MiB.
    {
        auto p = buildPath(tempDir, format("nano-d-trunc-mem-%s.bin", thisProcessID));
        scope (exit) if (p.exists) remove(p);
        {
            auto f = File(p, "wb");
            ubyte[64 * 1024] block;
            block[] = 'z';
            block[0] = 'H';
            block[$ - 1] = '\n';
            foreach (_; 0 .. 256) f.rawWrite(block[]); // 16 MiB
        }
        // Both with and without sandbox-denial scanning (the sandboxed-failure path).
        foreach (checkDenied; [false, true])
        {
            GC.collect();
            auto before = GC.stats.allocatedInCurrentThread;
            bool denied;
            auto got = truncateFile(p, 1000, "mem-stream", denied, checkDenied);
            auto allocated = GC.stats.allocatedInCurrentThread - before;
            auto m = got.matchFirst(`full output saved to (.*\.txt) \.\.\.\]`);
            scope (exit) if (m && m[1].exists) remove(m[1]);
            assert(m && got.startsWith("H") && got.endsWith("z\n"));
            assert(got.canFind("16776216 characters omitted"), got);
            assert(!denied);
            // Streaming 16 MiB should allocate well under 4 MiB total on the GC heap
            // (old path allocated > 96 MiB: readBytes + lossyUtf8 + 4x toUTF32).
            assert(allocated < 4 * 1024 * 1024, format("expected < 4 MiB allocated (checkDenied=%s), got %s bytes",
                checkDenied, allocated));
        }
    }

    // 3. Over `limit` bytes but within `limit` characters: no spill is needed,
    //    so an unusable spill directory must not matter.
    {
        auto p = buildPath(tempDir, format("nano-d-trunc-nospill-%s.bin", thisProcessID));
        auto blocker = buildPath(tempDir, format("nano-d-trunc-blocker-%s", thisProcessID));
        scope (exit) { if (p.exists) remove(p); if (blocker.exists) remove(blocker); }
        string text;
        foreach (_; 0 .. 30_000) text ~= "é";
        write(p, text);
        write(blocker, "not a dir");
        auto saved = spillDir_;
        setSpillDir(buildPath(blocker, "sub"));
        scope (exit) setSpillDir(saved);
        bool denied;
        assert(truncateFile(p, 40_000, "nospill", denied) == text);
    }
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
