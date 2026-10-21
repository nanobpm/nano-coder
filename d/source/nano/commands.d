/// The interactive slash commands: one table for `/help`, the command menu
/// shown while a `/command` is typed, Tab completion and the "did you mean"
/// rejection of unknown commands (port of `commands.rs`, D's command set).
module nano.commands;

import std.algorithm : filter, map, maxElement, min, startsWith, canFind, any;
import std.array : array;
import std.format : format;
import std.string : strip, indexOf;
import std.uni : isWhite;
import std.utf : count;

@safe:

struct Command
{
    string name;
    /// Argument synopsis (empty when the command takes none).
    string args;
    string description;
}

immutable Command[] commands = [
    Command("/help", "", "Show this help"),
    Command("/usage", "", "Show token totals for this session"),
    Command("/plan", "", "Switch to plan mode (read-only tools)"),
    Command("/normal", "", "Leave plan mode"),
    Command("/memory", "[forget ID]", "List cross-session memories (or forget one by id)"),
    Command("/hooks", "", "List loaded user hooks (.claude/settings.json and friends)"),
    Command("/tools", "", "List available tools"),
    Command("/skills", "", "List skills the agent can load"),
    Command("/model", "[provider/model]", "Show the model or switch to another"),
    Command("/session", "", "Show the session ID and log path"),
    Command("/clear", "", "Start a fresh conversation (clean context) without exiting"),
    Command("/exit", "", "Exit the agent"),
    Command("/quit", "", "Exit the agent (alias for /exit)"),
];

/// Why a submitted `/…` line can't be sent: its first word isn't a command.
/// null for anything else (not a `/` line, a known command, or a `//` escape).
/// Such a line is never sent to the model.
string rejection(string line)
{
    auto word = firstWord(line.strip);
    if (!word.length || !word.startsWith("/") || word.startsWith("//") || commands.any!(c => c.name == word))
        return null;
    auto note = "Unknown command " ~ word;
    if (auto close = closest(word)) note ~= ". Did you mean " ~ close ~ "?";
    if (word[1 .. $].canFind('/')) note ~= " To send a message starting with a path, type //" ~ word[1 .. $];
    else note ~= " (/help lists commands)";
    return note;
}

/// A `//…` line is a prompt that starts with `/`: the text with one `/`
/// removed. null for other lines.
string unescapePrompt(string line)
{
    import std.string : stripLeft;
    auto t = line.stripLeft;
    return t.startsWith("//") ? t[1 .. $] : null;
}

const(Command)[] matching(string prefix)
{
    return commands.filter!(c => c.name.startsWith(prefix)).array;
}

/// What Tab turns `prefix` into: the command (plus a space when it takes
/// arguments) if only one matches, else the longest common prefix (null when
/// that adds nothing).
string complete(string prefix)
{
    auto found = matching(prefix);
    if (!found.length) return null;
    if (found.length == 1) return found[0].name ~ (found[0].args.length ? " " : "");
    string common = found[0].name;
    foreach (c; found[1 .. $])
    {
        size_t n;
        while (n < common.length && n < c.name.length && common[n] == c.name[n]) ++n;
        common = common[0 .. n];
    }
    return common.length > prefix.length ? common : null;
}

/// The `/help` text.
string helpText()
{
    auto width = columnWidth();
    auto out_ = "Commands:";
    foreach (c; commands) out_ ~= format("\n  %-*s  %s", width, synopsis(c), c.description);
    out_ ~= "\nType / to list commands as you type; Tab completes them; Esc hides the list. Lines starting with / are never sent to the model: type // to send one that starts with /.";
    out_ ~= "\nKeys: Enter during a turn steers it; Ctrl-C or Esc Esc cancels the turn; Esc Esc also clears the input at the prompt; Ctrl-J, Alt-Enter or Ctrl-Enter inserts a newline; Up/Down recall earlier input.";
    return out_;
}

/// Menu rows for the line being typed: empty unless it is a `/command`
/// without arguments yet. Each row fits in `cols` columns; at most `maxRows`.
string[] menu(string line, size_t cols, size_t maxRows)
{
    if (!line.startsWith("/") || line.any!isWhite || maxRows == 0) return null;
    auto found = matching(line);
    if (!found.length) return [fit("  no matching command (/help lists them)", cols, [Style(0, "\x1b[2m")])];
    auto width = columnWidth();
    auto shown = found.length > maxRows ? maxRows - 1 : found.length;
    auto typed = line.count;
    string[] rows;
    foreach (c; found[0 .. shown])
    {
        auto plain = format("  %-*s  %s", width, synopsis(c), c.description);
        auto nameEnd = 2 + c.name.count;
        // Typed part bold, the rest of the name cyan, the rest dim.
        rows ~= fit(plain, cols, [Style(0, ""), Style(2, "\x1b[1m"), Style(2 + typed, "\x1b[0;36m"), Style(nameEnd, "\x1b[0;2m")]);
    }
    if (shown < found.length) rows ~= fit(format("  ... %s more", found.length - shown), cols, [Style(0, "\x1b[2m")]);
    return rows;
}

private:

struct Style { size_t at; string sgr; }

string firstWord(string s)
{
    foreach (i, dchar c; s)
        if (isWhite(c)) return s[0 .. i];
    return s;
}

string synopsis(const Command c)
{
    return c.args.length ? c.name ~ " " ~ c.args : c.name;
}

size_t columnWidth()
{
    size_t w;
    foreach (c; commands) w = w < synopsis(c).count ? synopsis(c).count : w;
    return w;
}

/// The command closest to a mistyped `word`: the only one it is a prefix of,
/// else the nearest within two edits (ties go to the same length).
string closest(string word)
{
    auto m = matching(word);
    if (m.length == 1) return m[0].name;
    auto len = word.count;
    string best;
    size_t bestD = size_t.max, bestDiff = size_t.max;
    foreach (c; commands)
    {
        auto n = c.name.count;
        auto diff = len > n ? len - n : n - len;
        // Lengths more than two apart can't be within two edits; skip the
        // O(word x name) matrix for long pastes.
        if (diff > 2) continue;
        auto d = editDistance(word, c.name);
        if (d > 2) continue;
        if (d < bestD || (d == bestD && diff < bestDiff))
        {
            best = c.name;
            bestD = d;
            bestDiff = diff;
        }
    }
    return best;
}

/// Optimal string alignment distance (adjacent swaps count as one edit).
size_t editDistance(string as, string bs)
{
    import std.conv : to;
    auto a = as.to!dstring, b = bs.to!dstring;
    auto d = new size_t[][](a.length + 1, b.length + 1);
    foreach (i; 0 .. a.length + 1) d[i][0] = i;
    foreach (j; 0 .. b.length + 1) d[0][j] = j;
    foreach (i; 1 .. a.length + 1)
        foreach (j; 1 .. b.length + 1)
        {
            size_t cost = a[i - 1] != b[j - 1];
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
            if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1])
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1);
        }
    return d[a.length][b.length];
}

/// `plain` cut to `cols - 1` characters, with a style switched on at each
/// character offset in `styles`.
string fit(string plain, size_t cols, const Style[] styles)
{
    string out_;
    size_t i;
    foreach (dchar ch; plain)
    {
        if (i + 1 >= cols) break;
        foreach (s; styles)
            if (s.at == i) out_ ~= s.sgr;
        import std.utf : encode;
        char[4] buf;
        out_ ~= buf[0 .. encode(buf, ch)].idup;
        ++i;
    }
    return out_ ~ "\x1b[0m";
}

unittest // rejection with did-you-mean, path hint and // escape
{
    assert(rejection("/help") is null && rejection("hello") is null && rejection("//etc/hosts") is null);
    assert(rejection("/model gpt") is null);
    auto r = rejection("/exin");
    assert(r.canFind("Unknown command /exin") && r.canFind("Did you mean /exit?") && r.canFind("/help lists"), r);
    assert(rejection("/modle").canFind("Did you mean /model?"));
    auto p = rejection("/etc/hosts is odd");
    assert(p.canFind("type //etc/hosts") && !p.canFind("Did you mean"), p);
    assert(unescapePrompt("//etc/hosts x") == "/etc/hosts x" && unescapePrompt("/help") is null);
    assert(rejection("/" ~ "x".replicateStr(5000)).canFind("Unknown"));
}

unittest // Tab completion
{
    assert(complete("/he") == "/help");
    assert(complete("/mo") == "/model ");
    assert(complete("/e") == "/exit");
    assert(complete("/s") == null); // /session, /skills: no longer prefix
    assert(complete("/zz") is null);
    assert(complete("/") is null);
}

unittest // menu rows
{
    auto rows = menu("/m", 80, 10);
    assert(rows.length == 2 && rows[0].canFind("\x1b[1m/m\x1b[0;36memory"), rows[0]);
    assert(menu("/model x", 80, 10) is null && menu("hi", 80, 10) is null && menu("/", 80, 0) is null);
    assert(menu("/zz", 80, 10)[0].canFind("no matching command"));
    auto few = menu("/", 80, 3);
    assert(few.length == 3 && few[2].canFind("more"));
    foreach (r; menu("/", 20, 20)) assert(r.count <= 19 + 30, r);
    assert(helpText().canFind("/memory [forget ID]"));
}

string replicateStr(string s, size_t n) pure { string r; foreach (_; 0 .. n) r ~= s; return r; }
