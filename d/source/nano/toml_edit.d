/// Minimal format-preserving TOML edits for `/settings` (the subset of
/// `toml_edit` that settings.rs uses): set or remove one `key = value` in
/// the root or a `[a.b."c"]` table, keeping every other line (comments,
/// order, other keys) as it was and an edited line's trailing comment.
module nano.toml_edit;

@safe:

import std.array : join, split;
import std.format : format;
import std.string : indexOf, strip, stripLeft, startsWith;

/// A TOML basic string.
string tomlString(string s)
{
    string out_ = "\"";
    foreach (dchar c; s)
    {
        switch (c)
        {
            case '"': out_ ~= `\"`; break;
            case '\\': out_ ~= `\\`; break;
            case '\n': out_ ~= `\n`; break;
            case '\r': out_ ~= `\r`; break;
            case '\t': out_ ~= `\t`; break;
            default:
                if (c < 0x20 || c == 0x7f) out_ ~= format("\\u%04X", cast(uint) c);
                else
                {
                    import std.conv : to;
                    out_ ~= c.to!string;
                }
        }
    }
    return out_ ~ "\"";
}

/// A TOML float (always with a fraction or exponent).
string tomlFloat(double v)
{
    auto s = format("%.15g", v);
    if (s.indexOf('.') < 0 && s.indexOf('e') < 0 && s.indexOf("inf") < 0 && s.indexOf("nan") < 0) s ~= ".0";
    return s;
}

/// A key as written in TOML: bare when it can be, quoted otherwise.
string tomlKey(string k)
{
    import std.ascii : isAlphaNum;
    bool bare = k.length > 0;
    foreach (c; k) if (!(c.isAlphaNum || c == '_' || c == '-')) bare = false;
    return bare ? k : tomlString(k);
}

/// The dotted segments of a header like `[providers."my x".models]`, or null
/// when `line` is not a plain table header (`[[array]]` tables too are null).
string[] headerPath(string line)
{
    auto t = line.strip;
    if (!t.startsWith("[") || t.startsWith("[[")) return null;
    string[] segs;
    size_t i = 1;
    for (;;)
    {
        while (i < t.length && (t[i] == ' ' || t[i] == '\t')) i++;
        if (i >= t.length) return null;
        string seg;
        if (t[i] == '"' || t[i] == '\'')
        {
            auto q = t[i];
            i++;
            while (i < t.length && t[i] != q)
            {
                if (q == '"' && t[i] == '\\' && i + 1 < t.length) { seg ~= t[i + 1]; i += 2; continue; }
                seg ~= t[i++];
            }
            if (i >= t.length) return null;
            i++;
        }
        else
        {
            auto st = i;
            while (i < t.length && t[i] != '.' && t[i] != ']' && t[i] != ' ' && t[i] != '\t') i++;
            seg = t[st .. i];
            if (!seg.length) return null;
        }
        segs ~= seg;
        while (i < t.length && (t[i] == ' ' || t[i] == '\t')) i++;
        if (i >= t.length) return null;
        if (t[i] == ']') return segs;
        if (t[i] != '.') return null;
        i++;
    }
}

/// The key a `key = value` line sets (unquoted), or null.
private string lineKey(string line)
{
    auto t = line.stripLeft;
    if (!t.length || t[0] == '#' || t[0] == '[') return null;
    if (t[0] == '"' || t[0] == '\'')
    {
        auto q = t[0];
        auto end = t[1 .. $].indexOf(q);
        if (end < 0) return null;
        auto rest = t[end + 2 .. $].stripLeft;
        return rest.startsWith("=") ? t[1 .. end + 1] : null;
    }
    auto eq = t.indexOf('=');
    if (eq <= 0) return null;
    auto k = t[0 .. eq].strip;
    // A dotted key reads as "\0" ~ its first segment.
    return k.indexOf('.') >= 0 ? "\0" ~ k[0 .. k.indexOf('.')].strip : k;
}

/// Where a value starting at `v` ends (exclusive), counting multi-line
/// strings and arrays across `lines` from `row`; also the row it ends on.
private size_t valueEnd(const string[] lines, size_t row, size_t col, out size_t endRow)
{
    endRow = row;
    auto line = lines[row];
    auto v = line[col .. $];
    foreach (q; [`"""`, `'''`])
        if (v.startsWith(q))
        {
            auto close = v[3 .. $].indexOf(q);
            if (close >= 0) return col + 3 + close + 3;
            foreach (r; row + 1 .. lines.length)
            {
                auto c = lines[r].indexOf(q);
                if (c >= 0) { endRow = r; return c + 3; }
            }
            endRow = lines.length - 1;
            return lines[$ - 1].length;
        }
    int depth;
    bool inStr;
    char quote;
    for (size_t r = row; r < lines.length; r++)
    {
        auto l = lines[r];
        for (size_t i = r == row ? col : 0; i < l.length; i++)
        {
            auto c = l[i];
            if (inStr)
            {
                if (quote == '"' && c == '\\') { i++; continue; }
                if (c == quote) inStr = false;
                continue;
            }
            if (c == '"' || c == '\'') { inStr = true; quote = c; continue; }
            if (c == '[' || c == '{') depth++;
            else if (c == ']' || c == '}') depth--;
            else if (c == '#' && depth == 0) { endRow = r; return i; }
            if (depth == 0 && i + 1 == l.length) { endRow = r; return l.length; }
        }
        if (depth <= 0) { endRow = r; return l.length; }
    }
    endRow = lines.length - 1;
    return lines[$ - 1].length;
}

/// `doc` with `key` in table `path` (empty: the root) set to the TOML
/// literal `value`, or removed when `value` is null. A missing table is
/// appended. Throws when the key is set some way a line edit can't follow
/// (a dotted key or an inline table).
string tomlSet(string doc, const string[] path, string key, string value)
{
    import std.algorithm : equal;
    auto lines = doc.length ? doc.split("\n") : [];
    bool trailingNl = doc.length && doc[$ - 1] == '\n';
    if (trailingNl) lines = lines[0 .. $ - 1];
    // The table's line range [start, end).
    ptrdiff_t start = path.length ? -1 : 0;
    size_t end = lines.length;
    string[] current;
    bool inside = !path.length;
    foreach (i, l; lines)
    {
        auto h = headerPath(l);
        if (h is null && !l.strip.startsWith("[[")) continue;
        if (inside) { end = i; break; }
        if (h !is null && equal(h, path)) { start = i + 1; inside = true; }
    }
    if (start < 0)
    {
        if (value is null) return doc;
        // A dotted or inline definition elsewhere would make a new header a
        // redefinition: refuse rather than corrupt the file.
        foreach (i, l; lines)
        {
            auto k = lineKey(l);
            if (k is null) continue;
            auto h = tableAt(lines, i);
            if (h.length < path.length && equal(h, path[0 .. h.length]) && (k == path[h.length] || k == "\0" ~ path[h.length]))
                throw new Exception(format("%s is written as an inline or dotted table; edit it by hand", path.join(".")));
        }
        string[] tail;
        if (lines.length && lines[$ - 1].strip.length) tail ~= "";
        string[] keys;
        foreach (p; path) keys ~= tomlKey(p);
        tail ~= "[" ~ keys.join(".") ~ "]";
        tail ~= tomlKey(key) ~ " = " ~ value;
        return (lines ~ tail).join("\n") ~ "\n";
    }
    foreach (i; cast(size_t) start .. end)
    {
        auto k = lineKey(lines[i]);
        if (k == "\0" ~ key)
            throw new Exception(format("%s is written as a dotted key; edit it by hand", key));
        if (k != key) continue;
        auto eq = lines[i].indexOf('=');
        auto col = eq + 1;
        while (col < lines[i].length && lines[i][col] == ' ') col++;
        size_t endRow;
        auto stop = valueEnd(lines, i, col, endRow);
        auto comment = lines[endRow][stop .. $];
        string[] replaced;
        if (value !is null)
        {
            import std.string : stripRight;
            auto c = comment.strip;
            replaced = [lines[i][0 .. col] ~ value ~ (c.length ? " " ~ c : "")];
        }
        auto res = lines[0 .. i] ~ replaced ~ lines[endRow + 1 .. $];
        return res.join("\n") ~ (trailingNl || !doc.length || res.length ? "\n" : "");
    }
    if (value is null) return doc;
    // Insert after the table's last key line (before trailing blanks/comments).
    size_t at = start;
    foreach (i; cast(size_t) start .. end)
        if (lineKey(lines[i]) !is null) { size_t er; valueEnd(lines, i, lines[i].indexOf('=') + 1, er); at = er + 1; }
    auto res = lines[0 .. at] ~ [tomlKey(key) ~ " = " ~ value] ~ lines[at .. $];
    return res.join("\n") ~ "\n";
}

/// The header path in force at line `row`.
private string[] tableAt(const string[] lines, size_t row)
{
    string[] cur;
    foreach (l; lines[0 .. row])
        if (auto h = headerPath(l)) cur = h;
    return cur;
}

unittest
{
    assert(headerPath(`[providers."my x".models]`) == ["providers", "my x", "models"]);
    assert(headerPath("[ a . b ]") == ["a", "b"]);
    assert(headerPath("[[x]]") is null && headerPath("a = 1") is null);
    assert(tomlString("a\"b\\\n") == `"a\"b\\\n"`);
    assert(tomlFloat(1) == "1.0" && tomlFloat(0.25) == "0.25");

    auto doc = "# top\nmodel = \"a/b\" # mine\n\n[providers.x]\nkind = \"openai\"\n\n# end\n";
    assert(tomlSet(doc, [], "model", `"c/d"`) == "# top\nmodel = \"c/d\" # mine\n\n[providers.x]\nkind = \"openai\"\n\n# end\n");
    assert(tomlSet(doc, [], "max_tokens", "5") == "# top\nmodel = \"a/b\" # mine\nmax_tokens = 5\n\n[providers.x]\nkind = \"openai\"\n\n# end\n");
    assert(tomlSet(doc, ["providers", "x"], "base_url", `"u"`)
        == "# top\nmodel = \"a/b\" # mine\n\n[providers.x]\nkind = \"openai\"\nbase_url = \"u\"\n\n# end\n");
    assert(tomlSet(doc, ["providers", "x"], "kind", null) == "# top\nmodel = \"a/b\" # mine\n\n[providers.x]\n\n# end\n");
    assert(tomlSet(doc, ["providers", "y", "models", "m:1"], "temperature", "0.5")
        == doc ~ "\n[providers.y.models.\"m:1\"]\ntemperature = 0.5\n");
    assert(tomlSet("", [], "verbosity", `"quiet"`) == "verbosity = \"quiet\"\n");
    // Multi-line values are replaced whole.
    assert(tomlSet("system_prompt = \"\"\"\nhi\nthere\"\"\"\nx = 1\n", [], "system_prompt", `"new"`) == "system_prompt = \"new\"\nx = 1\n");
    assert(tomlSet("a = [1,\n 2] # c\nb = 2\n", [], "a", "[3]") == "a = [3] # c\nb = 2\n");
    // A hash inside a string is not a comment.
    assert(tomlSet("a = \"x#y\" # c\n", [], "a", "1") == "a = 1 # c\n");
    import std.exception : assertThrown;
    assertThrown(tomlSet("providers.x.kind = \"openai\"\n", ["providers", "x"], "kind", `"anthropic"`));
    assertThrown(tomlSet("providers = { x = { kind = \"openai\" } }\n", ["providers", "x"], "kind", `"a"`));
    assert(tomlSet("a.b = 1\n", ["c"], "k", "1") == "a.b = 1\n\n[c]\nk = 1\n");
    assertThrown(tomlSet("[providers]\nx = { kind = \"openai\" }\n", ["providers", "x"], "kind", `"a"`));
    assert(tomlSet("[providers]\n", ["providers", "x"], "kind", `"a"`) == "[providers]\n\n[providers.x]\nkind = \"a\"\n");
}
