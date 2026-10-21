/// A small TOML reader covering what nano-coder's config.toml uses: tables
/// (`[a.b]`, quoted segments), dotted keys, basic/literal strings (single and
/// multi-line), integers, floats, booleans, arrays and inline tables.
/// Values are returned as a std.json tree. Dates are read as strings.
module nano.toml;

import std.json;
import std.conv : to;
import std.array : appender;
import std.ascii : isDigit, isAlphaNum;
import std.format : format;
import std.string : strip;
import std.algorithm : canFind;

class TomlException : Exception
{
    this(string msg, size_t line) { super(format("config line %s: %s", line, msg)); }
}

JSONValue parseToml(string src)
{
    auto p = Parser(src);
    return p.document();
}

private struct Parser
{
    string s;
    size_t i;
    size_t line = 1;

    this(string src) { s = src; }

    noreturn fail(string msg) { throw new TomlException(msg, line); }

    bool eof() const { return i >= s.length; }
    char peek(size_t off = 0) const { return i + off < s.length ? s[i + off] : '\0'; }

    void skipWs()
    {
        while (!eof && (peek == ' ' || peek == '\t')) i++;
    }

    void skipComment()
    {
        if (peek == '#') while (!eof && peek != '\n') i++;
    }

    /// Skip whitespace, newlines and comments (inside arrays).
    void skipAll()
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

    void endOfLine()
    {
        skipWs();
        skipComment();
        if (eof) return;
        if (peek == '\r') i++;
        if (peek != '\n') fail("expected end of line");
        i++;
        line++;
    }

    JSONValue document()
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
                    auto parent = tableAt(root, path[0 .. $ - 1]);
                    auto k = path[$ - 1];
                    if (k !in parent.object) parent.object[k] = JSONValue(JSONValue[].init);
                    if (parent.object[k].type != JSONType.array) fail("not an array of tables: " ~ k);
                    parent.object[k].array ~= JSONValue(string[string].init);
                    current = path ~ "\0" ~ (parent.object[k].array.length - 1).to!string;
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
            auto t = tableAt(root, current ~ path[0 .. $ - 1]);
            if (path[$ - 1] in t.object) fail("duplicate key " ~ path[$ - 1]);
            t.object[path[$ - 1]] = v;
            endOfLine();
        }
        return root;
    }

    /// The table at `path`, created on demand. A "\0" segment followed by an
    /// index selects an element of an array of tables.
    JSONValue* tableAt(ref JSONValue root, string[] path)
    {
        JSONValue* t = &root;
        for (size_t k = 0; k < path.length; k++)
        {
            if (path[k] == "\0")
            {
                t = &t.array[path[k + 1].to!size_t];
                k++;
                continue;
            }
            if (k + 1 < path.length && path[k + 1] == "\0")
            {
                t = &t.object[path[k]];
                continue;
            }
            auto key = path[k];
            if (key !in t.object) t.object[key] = JSONValue(string[string].init);
            t = &t.object[key];
            if (t.type == JSONType.array && t.array.length && t.array[$ - 1].type == JSONType.object)
                t = &t.array[$ - 1];
            else if (t.type != JSONType.object)
                fail("not a table: " ~ key);
        }
        return t;
    }

    string[] keyPath()
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

    string key()
    {
        if (peek == '"') return basicString();
        if (peek == '\'') return literalString();
        size_t start = i;
        while (!eof && (isAlphaNum(peek) || peek == '_' || peek == '-')) i++;
        if (i == start) fail("expected a key");
        return s[start .. i];
    }

    JSONValue value()
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

    JSONValue number()
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
                return JSONValue(clean.to!double);
            if (clean.length >= 10 && clean[4] == '-') return JSONValue(raw); // dates: keep as text
            return JSONValue(clean.to!long);
        }
        catch (Exception)
        {
            fail("invalid value: " ~ raw);
        }
    }

    JSONValue array()
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

    JSONValue inlineTable()
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
            JSONValue* cur = &t;
            foreach (k; path[0 .. $ - 1])
            {
                if (k !in cur.object) cur.object[k] = JSONValue(string[string].init);
                cur = &cur.object[k];
            }
            cur.object[path[$ - 1]] = v;
            skipWs();
            if (peek == ',') { i++; continue; }
            if (peek == '}') { i++; break; }
            fail("expected , or } in inline table");
        }
        return t;
    }

    string literalString()
    {
        i++;
        size_t start = i;
        while (!eof && peek != '\'' && peek != '\n') i++;
        if (peek != '\'') fail("unterminated string");
        auto r = s[start .. i];
        i++;
        return r;
    }

    string multiLiteral()
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

    string basicString()
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

    string multiBasic()
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

    void escape(A)(ref A out_)
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
    assert(doc["tags"].array.length == 2 && doc["tags"][1].str == "b");
    assert(doc["providers"]["macbook"]["kind"].str == "openai");
    assert(doc["providers"]["macbook"]["headers"]["X-Title"].str == "nano");
    assert(doc["providers"]["quoted.name"]["base_url"].str == "multi\nline");
}

unittest
{
    auto doc = parseToml("[[rules]]\nname = \"a\"\n[[rules]]\nname = \"b\"\n");
    assert(doc["rules"].array.length == 2 && doc["rules"][1]["name"].str == "b");
    bool threw;
    try parseToml("x = 1\nx = 2\n"); catch (TomlException) threw = true;
    assert(threw);
}
