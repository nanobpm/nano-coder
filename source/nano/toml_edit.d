/// Minimal format-preserving TOML edits for `/settings` (the subset of
/// `toml_edit` that settings.rs uses): set or remove one `key = value` in
/// the root or a `[a.b."c"]` table, keeping every other line (comments,
/// order, other keys) as it was and an edited line's trailing comment.
module nano.toml_edit;

@safe:
pure:

import nano.arith : toSize;

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
                if (c < 0x20 || c == 0x7f) out_ ~= format("\\u%04X", uint(c));
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
string[] headerPath(string line) pure
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
            auto st = i;
            i++;
            while (i < t.length && t[i] != q)
                i += q == '"' && t[i] == '\\' && i + 1 < t.length ? 2 : 1;
            if (i >= t.length) return null;
            i++;
            // Decode with the loader's string rules (`\uXXXX`, `\n`, ...), so
            // the edit matches exactly the tables the loader sees.
            bool ok;
            seg = decodeQuoted(t[st .. i], ok);
            if (!ok) return null;
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

/// The dotted segments of an array-of-tables header like
/// `[["subagent_models"]]`, or null when `line` is not one.
string[] arrayHeaderPath(string line) pure
{
    auto t = line.strip;
    if (!t.startsWith("[[")) return null;
    auto segs = headerPath(t[1 .. $]);
    if (segs is null) return null;
    // The inner header must be closed by `]]`, not a lone `]`.
    size_t i = 2, depth;
    bool inStr;
    char q;
    for (; i < t.length; i++)
    {
        if (inStr) { if (q == '"' && t[i] == '\\') { i++; continue; } if (t[i] == q) inStr = false; continue; }
        if (t[i] == '"' || t[i] == '\'') { inStr = true; q = t[i]; continue; }
        if (t[i] == ']') break;
    }
    return i + 1 < t.length && t[i + 1] == ']' ? segs : null;
}

/// Decodes one quoted TOML key segment (quotes included) with the loader's
/// string rules, so edits match exactly the keys the loader sees; `ok` is
/// false when the segment is malformed.
private string decodeQuoted(string quoted, out bool ok) pure
{
    import nano.toml : parseToml;
    import std.json : JSONType;
    auto decoded = parseToml("k = " ~ quoted);
    if (decoded.isErr) return null;
    auto v = decoded.unwrap("checked isErr above")["k"];
    if (v.type != JSONType.string) return null;
    ok = true;
    return v.str;
}

/// For each of `lines`, whether it starts a TOML statement (a header, key,
/// comment or blank line) rather than continuing a multi-line string or
/// array begun above, where a `[header]`-looking line is just text.
bool[] statementRows(const string[] lines) pure
{
    auto res = new bool[lines.length];
    for (size_t i = 0; i < lines.length;)
    {
        res[i] = true;
        auto l = lines[i];
        if (lineKey(l) is null) { i++; continue; }
        size_t col = afterEq(l);
        while (col < l.length && (l[col] == ' ' || l[col] == '\t')) col++;
        if (col >= l.length) { i++; continue; }
        size_t endRow;
        valueEnd(lines, i, col, endRow);
        i = endRow + 1 > i ? endRow + 1 : i + 1;
    }
    return res;
}

/// The column of the `=` ending a `key = value` line's key, or -1 when the
/// line isn't one. Walks the dotted key segment by segment, so quoted segments
/// (`"a".b`, `a."x=y"`) neither hide the line nor fake its `=`.
private ptrdiff_t keyEq(string line, out string first, out bool dotted) pure
{
    size_t i;
    static size_t ws(string l, size_t i) { while (i < l.length && (l[i] == ' ' || l[i] == '\t')) i++; return i; }
    i = ws(line, 0);
    if (i >= line.length || line[i] == '#' || line[i] == '[') return -1;
    for (size_t seg = 0;; seg++)
    {
        string k;
        if (line[i] == '"' || line[i] == '\'')
        {
            auto q = line[i];
            auto j = i + 1;
            for (; j < line.length && line[j] != q; j++) if (q == '"' && line[j] == '\\') j++;
            if (j >= line.length) return -1;
            bool ok;
            k = decodeQuoted(line[i .. j + 1], ok);
            if (!ok) return -1;
            i = j + 1;
        }
        else
        {
            auto j = i;
            while (j < line.length && line[j] != ' ' && line[j] != '\t' && line[j] != '=' && line[j] != '.') j++;
            if (j == i) return -1;
            k = line[i .. j];
            i = j;
        }
        if (seg == 0) first = k;
        i = ws(line, i);
        if (i >= line.length) return -1;
        if (line[i] == '=') { dotted = seg > 0; return i; }
        if (line[i] != '.') return -1;
        i = ws(line, i + 1);
        if (i >= line.length) return -1;
    }
}

/// The first (decoded) segment of the key a `key = value` line sets, or
/// null when the line isn't one; lets callers find dotted keys like
/// `a.b = 1` that belong to table `a`.
string lineFirstKey(string line) pure
{
    string first;
    bool dotted;
    return keyEq(line, first, dotted) < 0 ? null : first;
}

/// The last row of the statement starting at key line `row`, following a
/// multi-line string or array value onto later rows.
size_t statementEnd(const string[] lines, size_t row) pure
{
    auto l = lines[row];
    if (lineKey(l) is null) return row;
    size_t col = afterEq(l);
    while (col < l.length && (l[col] == ' ' || l[col] == '\t')) col++;
    if (col >= l.length) return row;
    size_t endRow;
    valueEnd(lines, row, col, endRow);
    return endRow < row ? row : endRow;
}

/// The key a `key = value` line sets (unquoted), or null.
/// A dotted key reads as "\0" ~ its first segment.
private string lineKey(string line) pure
{
    string first;
    bool dotted;
    if (keyEq(line, first, dotted) < 0) return null;
    return dotted ? "\0" ~ first : first;
}

/// The column just past a key line's `=` (0 when the line isn't one).
private size_t afterEq(string line) pure
{
    string f;
    bool d;
    return keyEq(line, f, d) + 1;
}

/// Where a value starting at `v` ends (exclusive), counting multi-line
/// strings and arrays across `lines` from `row`; also the row it ends on.
private size_t valueEnd(const string[] lines, size_t row, size_t col, out size_t endRow) pure
{
    // One scanner for every depth: strings (basic, literal and their
    // triple-quoted forms) are recognised wherever they start, and basic
    // strings honour backslash escapes, as nano.toml's parser does.
    enum S { none, basic, literal, mlBasic, mlLiteral }
    S st;
    int depth;
    for (size_t r = row; r < lines.length; r++)
    {
        auto l = lines[r];
        for (size_t i = r == row ? col : 0; i < l.length; i++)
        {
            auto c = l[i];
            final switch (st)
            {
            case S.basic:
                if (c == '\\') i++;
                else if (c == '"') st = S.none;
                continue;
            case S.literal:
                if (c == '\'') st = S.none;
                continue;
            case S.mlBasic:
                if (c == '\\') { i++; continue; }
                goto case S.mlLiteral;
            case S.mlLiteral:
                auto q = st == S.mlBasic ? '"' : '\'';
                if (c == q && l[i .. $].startsWith([q, q, q]))
                {
                    // A closing run may hold up to two extra quotes.
                    i += 2;
                    while (i + 1 < l.length && l[i + 1] == q) i++;
                    st = S.none;
                }
                continue;
            case S.none:
                break;
            }
            if (c == '"' || c == '\'')
            {
                bool triple = l[i .. $].startsWith([c, c, c]);
                st = c == '"' ? (triple ? S.mlBasic : S.basic) : (triple ? S.mlLiteral : S.literal);
                if (triple) i += 2;
                continue;
            }
            if (c == '[' || c == '{') depth++;
            else if (c == ']' || c == '}') depth--;
            else if (c == '#')
            {
                // A comment runs to the end of the line at any depth: its
                // brackets and quotes are text, not structure.
                if (depth <= 0) { endRow = r; return i; }
                break;
            }
        }
        // A single-line string can't span rows; a malformed one ends here.
        if (st == S.basic || st == S.literal) st = S.none;
        if (depth <= 0 && st == S.none) { endRow = r; return l.length; }
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
    // Rows inside a multi-line string or array are text, never a header or key.
    auto stmt = statementRows(lines);
    foreach (i, l; lines)
    {
        if (!stmt[i]) continue;
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
                if (!stmt[i]) continue;
                auto k = lineKey(l);
                if (k is null) continue;
                auto h = tableAt(lines, stmt, i);
                if (!(h.length < path.length && equal(h, path[0 .. h.length]) && k == path[h.length])) continue;
                auto col = afterEq(l);
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
            if (!stmt[i]) continue;
            auto k = lineKey(l);
            if (k is null) continue;
            auto h = tableAt(lines, stmt, i);
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
    foreach (i; toSize(start) .. end)
    {
        if (!stmt[i]) continue;
        auto k = lineKey(lines[i]);
        if (k == "\0" ~ key)
            return R.err(format("%s is written as a dotted key; edit it by hand", key));
        if (k != key) continue;
        auto col = afterEq(lines[i]);
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
    foreach (i; toSize(start) .. end)
        if (stmt[i] && lineKey(lines[i]) !is null) { size_t er; valueEnd(lines, i, afterEq(lines[i]), er); at = er + 1; }
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
/// `stmt` is `statementRows(lines)`: rows inside a multi-line value are text.
private string[] tableAt(const string[] lines, const bool[] stmt, size_t row) pure
{
    string[] cur;
    foreach (i, l; lines[0 .. row])
        if (stmt[i])
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

// A multi-line value under a quoted dotted key is one statement: its
// header-looking lines are text, and `=` inside a quoted segment isn't the key's.
unittest
{
    assert(statementRows([`"x".y = '''`, "[providers.p]", "'''", "z = 1"]) == [true, false, false, true]);
    assert(statementRows([`a."k=v" = """`, "[t]", `"""`]) == [true, false, false]);
    assert(lineKey(`"a b".c = 1`) == "\0a b" && lineKey(`"q" = 1`) == "q" && lineKey(`a."x=y" = 1`) == "\0a");
    assert(lineKey(`"open = 1`) is null && lineKey("a. = 1") is null);
    auto doc = "\"x\".y = '''\n[providers.p]\n'''\nmodel = \"a\"\n";
    assert(tomlSet(doc, [], "model", `"b"`).unwrap("valid") == "\"x\".y = '''\n[providers.p]\n'''\nmodel = \"b\"\n");
}

// A root-key removal leaves a key-looking line inside a multi-line string alone.
unittest
{
    auto doc = "system_prompt = \"\"\"\nsubagent_models = [{ model = \"x\" }]\n\"\"\"\nsubagent_models = []\n";
    assert(tomlSet(doc, [], "subagent_models", null).unwrap("valid")
        == "system_prompt = \"\"\"\nsubagent_models = [{ model = \"x\" }]\n\"\"\"\n");
}

// A bracket in a comment inside a multi-line array doesn't swallow later headers.
unittest
{
    auto lines = ["files = [ # [", "  \"a\",", "]", "[[subagent_models]]", "model = \"m\""];
    assert(statementRows(lines) == [true, false, false, true, true]);
}

// A header-looking line inside a multi-line string doesn't move later root keys into that table.
unittest
{
    auto doc = "system_prompt = \"\"\"\n[notes]\n\"\"\"\nnotes = { k = 1 }\n";
    assert(tomlSet(doc, ["notes"], "k", "2").isErr);
}

// Triple-quoted strings nest anywhere: removing a key keeps the following table.
unittest
{
    auto doc = "subagent_models = [{ model = \"p/old\", use = '''For users' requests''' }]\n\n[providers.p]\nkind = \"openai\"\n";
    assert(tomlSet(doc, [], "subagent_models", null).unwrap("valid") == "\n[providers.p]\nkind = \"openai\"\n");
    auto ml = "a = [\"\"\"\n[x]\n\"\"\"]\n[y]\nk = 1";
    assert(statementRows(ml.split("\n")) == [true, false, false, true, true]);
}

// An escaped triple quote doesn't end a multi-line basic string.
unittest
{
    import std.array : replace;
    auto doc = "system_prompt = \"\"\"\nsay \\\"\"\" then\n[[subagent_models]]\n\"\"\"\nx = 1\n";
    assert(statementRows(doc.split("\n"))[0 .. 5] == [true, false, false, false, true]);
    assert(tomlSet(doc, [], "x", "2").unwrap("valid") == doc.replace("x = 1", "x = 2"));
    assert(tomlSet(doc, [], "system_prompt", `"s"`).unwrap("valid") == "system_prompt = \"s\"\nx = 1\n");
}

unittest
{
    // Quoted header segments decode TOML escapes like the loader does.
    assert(headerPath(`["subagent\u005Fmodels"]`) == ["subagent_models"]);
    assert(arrayHeaderPath(`[["subagent\u005Fmodels"]]`) == ["subagent_models"]);
    assert(headerPath(`["a\"b"]`) == [`a"b`]);
    assert(headerPath(`['raw\u005F']`) == [`raw\u005F`]);
    assert(headerPath(`["bad\uZZZZ"]`) is null);
}

unittest
{
    // Quoted key segments decode escapes like headers do, so an escaped
    // key is updated in place instead of duplicated.
    assert(lineKey(`"mod\u0065l" = "a"`) == "model");
    assert(lineKey(`"a\"b" = 1`) == `a"b`);
    assert(lineKey(`'raw\u0065' = 1`) == `raw\u0065`);
    assert(lineKey(`"bad\uZZZZ" = 1`) is null);
    assert(tomlSet("\"mod\\u0065l\" = \"a\"\n", [], "model", `"b"`).unwrap("editable")
        == "\"mod\\u0065l\" = \"b\"\n");
}
