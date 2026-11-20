/// A small TOML reader covering what nano-coder's config.toml uses: tables
/// (`[a.b]`, quoted segments), dotted keys, basic/literal strings (single and
/// multi-line), integers, floats, booleans, arrays and inline tables.
/// Values are returned as a std.json tree. Dates are read as strings.
module nano.toml;

@safe:
pure:

import std.json;
import std.conv : to;
import std.array : appender;
import std.ascii : isDigit, isAlphaNum;
import std.format : format;
import std.string : strip;
import std.algorithm : canFind;

class TomlException : Exception
{
    this(string msg, size_t line) pure { super(format("config line %s: %s", line, msg)); }
}

JSONValue parseToml(string src) pure
{
    auto p = Parser(src);
    return p.document();
}

private struct Parser
{
    string s;
    size_t i;
    size_t line = 1;

    this(string src) pure { s = src; }

    noreturn fail(string msg) pure { throw new TomlException(msg, line); }

    bool eof() pure const { return i >= s.length; }
    char peek(size_t off = 0) pure const { return i + off < s.length ? s[i + off] : '\0'; }

    void skipWs() pure
    {
        while (!eof && (peek == ' ' || peek == '\t')) i++;
    }

    void skipComment() pure
    {
        if (peek == '#') while (!eof && peek != '\n') i++;
    }

    /// Skip whitespace, newlines and comments (inside arrays).
    void skipAll() pure
    {
        for (;;)
        {
            skipWs();
            skipComment();
            if (peek == '\n') { line++; i++; continue; }
            if (peek == '\r') { i++; continue; }
            break;
        }
    }

    void endOfLine() pure
    {
        skipWs();
        skipComment();
        if (eof) return;
        if (peek == '\r') i++;
        if (peek != '\n') fail("expected end of line");
        i++;
        line++;
    }

    JSONValue document() pure
    {
        JSONValue root = JSONValue(string[string].init);
        string[] current;
        for (;;)
        {
            skipAll();
            if (eof) break;
            if (peek == '[')
            {
                bool arrayTable = peek(1) == '[';
                i += arrayTable ? 2 : 1;
                skipWs();
                auto path = keyPath();
                skipWs();
                if (peek != ']') fail("expected ]");
                i++;
                if (arrayTable)
                {
                    if (peek != ']') fail("expected ]]");
                    i++;
                }
                endOfLine();
                if (arrayTable)
                {
                    auto k = path[$ - 1];
                    auto at = appendTable(tableAt(root, path[0 .. $ - 1]), k);
                    if (at < 0) fail("not an array of tables: " ~ k);
                    current = path ~ "\0" ~ at.to!string;
                }
                else
                {
                    tableAt(root, path);
                    current = path;
                }
                continue;
            }
            auto path = keyPath();
            skipWs();
            if (peek != '=') fail("expected =");
            i++;
            skipWs();
            auto v = value();
            if (!putNew(tableAt(root, current ~ path[0 .. $ - 1]), path[$ - 1], v)) fail("duplicate key " ~ path[$ - 1]);
            endOfLine();
        }
        return root;
    }

    // The tree under construction is walked by `ref` (JSONValue's @safe
    // `opIndex`), so the compiler checks that no reference outlives the table
    // it points into.

    /// Append an empty table to the array of tables `parent[k]` (created if
    /// missing); its index, or -1 when `parent[k]` is not an array.
    static ptrdiff_t appendTable(ref JSONValue parent, string k) pure
    {
        if (k !in parent) parent[k] = JSONValue(JSONValue[].init);
        if (parent[k].type != JSONType.array) return -1;
        auto tables = parent[k].arrayNoRef ~ JSONValue(string[string].init);
        parent[k] = JSONValue(tables);
        return tables.length - 1;
    }

    /// Set `t[k] = v` unless `k` is already there (false).
    static bool putNew(ref JSONValue t, string k, JSONValue v) pure
    {
        if (k in t) return false;
        t[k] = v;
        return true;
    }

    /// `t.a.b.c = v` for the dotted key `path` of an inline table, creating
    /// the intermediate tables.
    static void setDotted(ref JSONValue t, string[] path, JSONValue v) pure
    {
        if (path.length == 1) { t[path[0]] = v; return; }
        if (path[0] !in t) t[path[0]] = JSONValue(string[string].init);
        setDotted(t[path[0]], path[1 .. $], v);
    }

    /// The table at `path`, created on demand. A "\0" segment followed by an
    /// index selects an element of an array of tables.
    ref JSONValue tableAt(return ref JSONValue t, string[] path) pure
    {
        if (!path.length) return t;
        if (path[0] == "\0")
            return tableAt(t[path[1].to!size_t], path[2 .. $]);
        if (path.length > 1 && path[1] == "\0")
            return tableAt(t[path[0]], path[1 .. $]);
        auto key = path[0];
        if (key !in t) t[key] = JSONValue(string[string].init);
        const n = t[key].type == JSONType.array ? t[key].arrayNoRef.length : 0;
        if (n && t[key][n - 1].type == JSONType.object)
            return tableAt(t[key][n - 1], path[1 .. $]);
        if (t[key].type != JSONType.object)
            fail("not a table: " ~ key);
        return tableAt(t[key], path[1 .. $]);
    }

    string[] keyPath() pure
    {
        string[] parts;
        for (;;)
        {
            skipWs();
            parts ~= key();
            skipWs();
            if (peek != '.') break;
            i++;
        }
        return parts;
    }

    string key() pure
    {
        if (peek == '"') return basicString();
        if (peek == '\'') return literalString();
        size_t start = i;
        while (!eof && (isAlphaNum(peek) || peek == '_' || peek == '-')) i++;
        if (i == start) fail("expected a key");
        return s[start .. i];
    }

    JSONValue value() pure
    {
        char c = peek;
        if (c == '"') return JSONValue(peek(1) == '"' && peek(2) == '"' ? multiBasic() : basicString());
        if (c == '\'') return JSONValue(peek(1) == '\'' && peek(2) == '\'' ? multiLiteral() : literalString());
        if (c == '[') return array();
        if (c == '{') return inlineTable();
        if (s[i .. $].length >= 4 && s[i .. i + 4] == "true") { i += 4; return JSONValue(true); }
        if (s[i .. $].length >= 5 && s[i .. i + 5] == "false") { i += 5; return JSONValue(false); }
        return number();
    }

    JSONValue number() pure
    {
        size_t start = i;
        while (!eof && !" \t\r\n,]}#".canFind(peek)) i++;
        auto raw = s[start .. i];
        if (raw.length == 0) fail("expected a value");
        string clean;
        foreach (ch; raw) if (ch != '_') clean ~= ch;
        if (clean == "inf" || clean == "+inf") return JSONValue(double.infinity);
        if (clean == "-inf") return JSONValue(-double.infinity);
        if (clean == "nan" || clean == "+nan" || clean == "-nan") return JSONValue(double.nan);
        try
        {
            if (clean.length > 2 && clean[0] == '0' && (clean[1] == 'x' || clean[1] == 'o' || clean[1] == 'b'))
            {
                uint radix = clean[1] == 'x' ? 16 : clean[1] == 'o' ? 8 : 2;
                return JSONValue(clean[2 .. $].to!long(radix));
            }
            if (clean.canFind('.') || clean.canFind('e') || clean.canFind('E'))
                return JSONValue(parseDouble(clean));
            if (clean.length >= 10 && clean[4] == '-') return JSONValue(raw); // dates: keep as text
            return JSONValue(clean.to!long);
        }
        catch (Exception) // fail() rethrows it as a TOML error with the position
        {
            fail("invalid value: " ~ raw);
        }
    }

    JSONValue array() pure
    {
        i++;
        JSONValue[] items;
        for (;;)
        {
            skipAll();
            if (peek == ']') { i++; break; }
            items ~= value();
            skipAll();
            if (peek == ',') { i++; continue; }
            if (peek == ']') { i++; break; }
            fail("expected , or ] in array");
        }
        return JSONValue(items);
    }

    JSONValue inlineTable() pure
    {
        i++;
        JSONValue t = JSONValue(string[string].init);
        skipWs();
        if (peek == '}') { i++; return t; }
        for (;;)
        {
            skipWs();
            auto path = keyPath();
            skipWs();
            if (peek != '=') fail("expected = in inline table");
            i++;
            skipWs();
            auto v = value();
            setDotted(t, path, v);
            skipWs();
            if (peek == ',') { i++; continue; }
            if (peek == '}') { i++; break; }
            fail("expected , or } in inline table");
        }
        return t;
    }

    string literalString() pure
    {
        i++;
        size_t start = i;
        while (!eof && peek != '\'' && peek != '\n') i++;
        if (peek != '\'') fail("unterminated string");
        auto r = s[start .. i];
        i++;
        return r;
    }

    string multiLiteral() pure
    {
        i += 3;
        if (peek == '\n') { i++; line++; }
        size_t start = i;
        while (!eof && !(peek == '\'' && peek(1) == '\'' && peek(2) == '\''))
        {
            if (peek == '\n') line++;
            i++;
        }
        if (eof) fail("unterminated string");
        auto r = s[start .. i];
        i += 3;
        return r;
    }

    string basicString() pure
    {
        i++;
        auto out_ = appender!string;
        for (;;)
        {
            if (eof || peek == '\n') fail("unterminated string");
            char c = s[i++];
            if (c == '"') break;
            if (c == '\\') escape(out_);
            else out_.put(c);
        }
        return out_.data;
    }

    string multiBasic() pure
    {
        i += 3;
        if (peek == '\n') { i++; line++; }
        auto out_ = appender!string;
        for (;;)
        {
            if (eof) fail("unterminated string");
            if (peek == '"' && peek(1) == '"' && peek(2) == '"')
            {
                i += 3;
                // up to two extra quotes belong to the content
                while (peek == '"') { out_.put('"'); i++; }
                break;
            }
            char c = s[i++];
            if (c == '\n') line++;
            if (c == '\\')
            {
                // line-ending backslash trims following whitespace
                size_t j = i;
                while (j < s.length && (s[j] == ' ' || s[j] == '\t')) j++;
                if (j < s.length && (s[j] == '\n' || s[j] == '\r'))
                {
                    i = j;
                    while (!eof && (peek == ' ' || peek == '\t' || peek == '\n' || peek == '\r'))
                    {
                        if (peek == '\n') line++;
                        i++;
                    }
                    continue;
                }
                escape(out_);
            }
            else out_.put(c);
        }
        return out_.data;
    }

    void escape(A)(ref A out_) pure
    {
        if (eof) fail("bad escape");
        char e = s[i++];
        switch (e)
        {
            case 'n': out_.put('\n'); break;
            case 't': out_.put('\t'); break;
            case 'r': out_.put('\r'); break;
            case 'b': out_.put('\b'); break;
            case 'f': out_.put('\f'); break;
            case 'e': out_.put('\x1b'); break;
            case '"': out_.put('"'); break;
            case '\\': out_.put('\\'); break;
            case 'u':
            case 'U':
                size_t n = e == 'u' ? 4 : 8;
                if (i + n > s.length) fail("bad unicode escape");
                dchar cp = cast(dchar) s[i .. i + n].to!uint(16);
                i += n;
                import std.utf : encode;
                char[4] buf;
                auto len = encode(buf, cp);
                out_.put(buf[0 .. len]);
                break;
            default:
                fail("bad escape \\" ~ e);
        }
    }
}

unittest
{
    auto doc = parseToml(`
model = "github-copilot/claude"   # comment
auto_compact = true
threshold = 0.8
max_tokens = 16_384
tags = ["a", 'b', ]

[providers.macbook]
kind = "openai"
headers = { "X-Title" = "nano", y = 2 }

[providers."quoted.name"]
base_url = """
multi
line"""
`);
    assert(doc["model"].str == "github-copilot/claude");
    assert(doc["auto_compact"].boolean);
    assert(doc["threshold"].floating == 0.8);
    assert(doc["max_tokens"].integer == 16384);
    assert(doc["tags"].arrayNoRef.length == 2 && doc["tags"][1].str == "b");
    assert(doc["providers"]["macbook"]["kind"].str == "openai");
    assert(doc["providers"]["macbook"]["headers"]["X-Title"].str == "nano");
    assert(doc["providers"]["quoted.name"]["base_url"].str == "multi\nline");
}

unittest
{
    auto doc = parseToml("[[rules]]\nname = \"a\"\n[[rules]]\nname = \"b\"\n");
    assert(doc["rules"].arrayNoRef.length == 2 && doc["rules"][1]["name"].str == "b");
    bool threw;
    try parseToml("x = 1\nx = 2\n"); catch (TomlException) threw = true;
    assert(threw);
}

/// A correctly rounded double (`std.conv.to!double` is not: "0.7" came back
/// as 0.700000000000000067); throws on trailing junk.
private double parseDouble(string s) pure
{
    import nano.safeio : cStrtod;
    size_t used;
    auto v = cStrtod(s, used);
    if (used != s.length || !s.length) throw new Exception("bad number " ~ s);
    return v;
}

unittest
{
    assert(parseToml("t = 0.7")["t"].floating == 0.7);
    assert(parseToml("t = 1e-3")["t"].floating == 1e-3);
}
