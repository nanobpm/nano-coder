/// Minimal format-preserving TOML edits for `/settings` (the subset of
/// `toml_edit` that settings.rs uses): set or remove one `key = value` in
/// the root or a `[a.b."c"]` table, keeping every other line (comments,
/// order, other keys) as it was and an edited line's trailing comment.
module nano.toml_edit;

@safe:
pure:

import nano.result : Result, unwrap;
import std.array : join, split;
import std.format : format;
import std.string : indexOf, strip, stripLeft, startsWith;

/// A TOML basic string.
string tomlString(string s) pure
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
string tomlFloat(double v) pure
{
    auto s = format("%.15g", v);
    if (s.indexOf('.') < 0 && s.indexOf('e') < 0 && s.indexOf("inf") < 0 && s.indexOf("nan") < 0) s ~= ".0";
    return s;
}

/// A key as written in TOML: bare when it can be, quoted otherwise.
string tomlKey(string k) pure
{
    import std.ascii : isAlphaNum;
    bool bare = k.length > 0;
    foreach (c; k) if (!(c.isAlphaNum || c == '_' || c == '-')) bare = false;
    return bare ? k : tomlString(k);
}

/// The dotted segments of a header like `[providers."my x".models]`, or null
/// when `line` is not a plain table header (`[[array]]` tables too are null).
string[] headerPath(string line) pure nothrow
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
private string lineKey(string line) pure
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
private size_t valueEnd(const string[] lines, size_t row, size_t col, out size_t endRow) pure
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
/// appended. An error when the key is set some way a line edit can't
/// follow (a dotted key or an inline table).
Result!(string, string) tomlSet(string doc, const string[] path, string key, string value) pure
{
    alias R = Result!(string, string);
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
        if (value is null)
        {
            // The table may be an inline value on some line: remove the key
            // inside it, keeping the rest of the line.
            foreach (i, l; lines)
            {
                auto k = lineKey(l);
                if (k is null) continue;
                auto h = tableAt(lines, i);
                if (!(h.length < path.length && equal(h, path[0 .. h.length]) && k == path[h.length])) continue;
                auto col = l.indexOf('=') + 1;
                while (col < l.length && l[col] == ' ') col++;
                if (col >= l.length || l[col] != '{') continue;
                bool found;
                auto edited = inlineRemove(l[col .. $], path[h.length + 1 .. $], key, found);
                if (!found) return R.ok(doc);
                lines[i] = l[0 .. col] ~ edited;
                return R.ok(lines.join("\n") ~ (trailingNl ? "\n" : ""));
            }
            return R.ok(doc);
        }
        // A dotted or inline definition elsewhere would make a new header a
        // redefinition: refuse rather than corrupt the file.
        foreach (i, l; lines)
        {
            auto k = lineKey(l);
            if (k is null) continue;
            auto h = tableAt(lines, i);
            if (h.length < path.length && equal(h, path[0 .. h.length]) && (k == path[h.length] || k == "\0" ~ path[h.length]))
                return R.err(format("%s is written as an inline or dotted table; edit it by hand", path.join(".")));
        }
        string[] tail;
        if (lines.length && lines[$ - 1].strip.length) tail ~= "";
        string[] keys;
        foreach (p; path) keys ~= tomlKey(p);
        tail ~= "[" ~ keys.join(".") ~ "]";
        tail ~= tomlKey(key) ~ " = " ~ value;
        return R.ok((lines ~ tail).join("\n") ~ "\n");
    }
    foreach (i; cast(size_t) start .. end)
    {
        auto k = lineKey(lines[i]);
        if (k == "\0" ~ key)
            return R.err(format("%s is written as a dotted key; edit it by hand", key));
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
        return R.ok(res.join("\n") ~ (trailingNl || !doc.length || res.length ? "\n" : ""));
    }
    if (value is null) return R.ok(doc);
    // Insert after the table's last key line (before trailing blanks/comments).
    size_t at = start;
    foreach (i; cast(size_t) start .. end)
        if (lineKey(lines[i]) !is null) { size_t er; valueEnd(lines, i, lines[i].indexOf('=') + 1, er); at = er + 1; }
    auto res = lines[0 .. at] ~ [tomlKey(key) ~ " = " ~ value] ~ lines[at .. $];
    return R.ok(res.join("\n") ~ "\n");
}

/// `text` (starting at an inline table's `{`) with `key` under the nested
/// inline tables `path` removed, entry and separating comma; `found` says
/// whether it was there. Everything after the table is kept as it was.
private string inlineRemove(string text, const string[] path, string key, out bool found) pure
{
    // Where the value starting at `i` ends (exclusive).
    static size_t valueStop(string t, size_t i)
    {
        int depth;
        for (; i < t.length; i++)
        {
            auto c = t[i];
            if (c == '"' || c == '\'')
            {
                for (i++; i < t.length && t[i] != c; i++) if (c == '"' && t[i] == '\\') i++;
                if (depth == 0) return i + 1;
                continue;
            }
            if (c == '{' || c == '[') depth++;
            else if (c == '}' || c == ']') { if (depth == 0) return i; if (--depth == 0) return i + 1; }
            else if (depth == 0 && (c == ',' || c == ' ' || c == '#')) return i;
        }
        return i;
    }
    static size_t skipWs(string t, size_t i) { while (i < t.length && (t[i] == ' ' || t[i] == '\t')) i++; return i; }
    size_t i = 1; // past `{`
    size_t prevEnd = 0; // end of the previous entry's value (0: none yet)
    for (;;)
    {
        i = skipWs(text, i);
        if (i >= text.length || text[i] == '}') return text;
        auto entryStart = i;
        string k;
        if (text[i] == '"' || text[i] == '\'')
        {
            auto q = text[i];
            auto j = i + 1;
            while (j < text.length && text[j] != q) j++;
            k = text[i + 1 .. j];
            i = j + 1;
        }
        else
        {
            auto j = i;
            while (j < text.length && text[j] != ' ' && text[j] != '=' && text[j] != '.') j++;
            k = text[i .. j];
            i = j;
        }
        i = skipWs(text, i);
        if (i >= text.length || text[i] != '=') return text; // dotted keys: left alone
        auto vStart = skipWs(text, i + 1);
        auto vEnd = valueStop(text, vStart);
        auto next = skipWs(text, vEnd);
        bool comma = next < text.length && text[next] == ',';
        if (path.length && k == path[0] && vStart < text.length && text[vStart] == '{')
        {
            auto inner = inlineRemove(text[vStart .. $], path[1 .. $], key, found);
            return text[0 .. vStart] ~ inner;
        }
        if (!path.length && k == key)
        {
            found = true;
            if (comma) return text[0 .. entryStart] ~ text[skipWs(text, next + 1) .. $];
            // The last entry: drop the comma before it instead.
            if (prevEnd) return text[0 .. prevEnd] ~ " " ~ text[next .. $];
            return text[0 .. entryStart] ~ text[next .. $];
        }
        prevEnd = vEnd;
        i = comma ? next + 1 : next;
    }
}

unittest
{
    bool f;
    assert(inlineRemove(`{ "k3" = { temperature = 0.5 } }`, ["k3"], "temperature", f) == `{ "k3" = { } }` && f);
    assert(inlineRemove(`{ k3 = { temperature = 0.7, thinking = "low" } } # x`, ["k3"], "temperature", f)
        == `{ k3 = { thinking = "low" } } # x`);
    assert(inlineRemove(`{ k3 = { thinking = "a,}", temperature = 0.7 } }`, ["k3"], "temperature", f)
        == `{ k3 = { thinking = "a,}" } }`);
    assert(inlineRemove(`{ k3 = { thinking = "low" } }`, ["k3"], "temperature", f) == `{ k3 = { thinking = "low" } }` && !f);
}

/// The header path in force at line `row`.
private string[] tableAt(const string[] lines, size_t row) pure nothrow
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
    assert(tomlSet(doc, [], "model", `"c/d"`).unwrap("editable") == "# top\nmodel = \"c/d\" # mine\n\n[providers.x]\nkind = \"openai\"\n\n# end\n");
    assert(tomlSet(doc, [], "max_tokens", "5").unwrap("editable") == "# top\nmodel = \"a/b\" # mine\nmax_tokens = 5\n\n[providers.x]\nkind = \"openai\"\n\n# end\n");
    assert(tomlSet(doc, ["providers", "x"], "base_url", `"u"`).unwrap("editable")
        == "# top\nmodel = \"a/b\" # mine\n\n[providers.x]\nkind = \"openai\"\nbase_url = \"u\"\n\n# end\n");
    assert(tomlSet(doc, ["providers", "x"], "kind", null).unwrap("editable") == "# top\nmodel = \"a/b\" # mine\n\n[providers.x]\n\n# end\n");
    assert(tomlSet(doc, ["providers", "y", "models", "m:1"], "temperature", "0.5").unwrap("editable")
        == doc ~ "\n[providers.y.models.\"m:1\"]\ntemperature = 0.5\n");
    assert(tomlSet("", [], "verbosity", `"quiet"`).unwrap("editable") == "verbosity = \"quiet\"\n");
    // Multi-line values are replaced whole.
    assert(tomlSet("system_prompt = \"\"\"\nhi\nthere\"\"\"\nx = 1\n", [], "system_prompt", `"new"`).unwrap("editable") == "system_prompt = \"new\"\nx = 1\n");
    assert(tomlSet("a = [1,\n 2] # c\nb = 2\n", [], "a", "[3]").unwrap("editable") == "a = [3] # c\nb = 2\n");
    // A hash inside a string is not a comment.
    assert(tomlSet("a = \"x#y\" # c\n", [], "a", "1").unwrap("editable") == "a = 1 # c\n");
    assert(tomlSet("providers.x.kind = \"openai\"\n", ["providers", "x"], "kind", `"anthropic"`).isErr);
    assert(tomlSet("providers = { x = { kind = \"openai\" } }\n", ["providers", "x"], "kind", `"a"`).isErr);
    assert(tomlSet("a.b = 1\n", ["c"], "k", "1").unwrap("editable") == "a.b = 1\n\n[c]\nk = 1\n");
    assert(tomlSet("[providers]\nx = { kind = \"openai\" }\n", ["providers", "x"], "kind", `"a"`).isErr);
    assert(tomlSet("[providers]\n", ["providers", "x"], "kind", `"a"`).unwrap("editable") == "[providers]\n\n[providers.x]\nkind = \"a\"\n");
}
