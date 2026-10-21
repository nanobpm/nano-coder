/// The interactive slash commands: one table for `/help`, the command menu
/// shown while a `/command` is typed, Tab completion and the "did you mean"
/// rejection of unknown commands (port of `commands.rs`, D's command set).
module nano.commands;

import nano.context : CompactionMode;

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
    Command("/compact", "[--smart|--standard] [focus]", "Summarize older messages to free context (optional mode and focus)"),
    Command("/context", "", "Show context-window use and token totals"),
    Command("/settings", "", "View/edit settings"),
    Command("/verbosity", "[quiet|normal|verbose|debug]", "Show or set output detail"),
    Command("/plan", "", "Show the agent's task plan with notes"),
    Command("/memory", "[forget ID]", "List cross-session memories (or forget one by id)"),
    Command("/hooks", "", "List loaded user hooks (.claude/settings.json and friends)"),
    Command("/queue", "[list|add text|remove N...|edit N text|clear]", "Show or edit the queued messages"),
    Command("/tools", "", "List available tools"),
    Command("/skills", "", "List skills the agent can load"),
    Command("/model", "[provider/model]", "Show the model and pick a new one (or switch directly)"),
    Command("/mode", "[normal|plan|auto]", "Show or set the agent mode (Shift+Tab cycles)"),
    Command("/thinking", "[level|default|off|reset]", "Show or set the thinking level for this session"),
    Command("/providers", "", "List configured providers"),
    Command("/session", "", "Show the session ID and log path"),
    Command("/trajectory", "[--json|--markdown]", "Show this session's turn-by-turn trajectory in your pager (or export it)"),
    Command("/resume", "[ID|last]", "Switch to a saved session: pick one, or give its ID"),
    Command("/restart", "", "Start a fresh session (clean context) without exiting"),
    Command("/exit", "", "Exit the agent"),
    Command("/quit", "", "Exit the agent (alias for /exit)"),
];

/// `/compact` arguments: an optional `--smart`/`--standard`, then a focus.
/// Returns whether a mode was given.
bool parseCompactArgs(string args, out CompactionMode mode, out string focus)
{
    import std.string : strip, indexOf;
    args = args.strip;
    auto sp = args.indexOf(' ');
    auto first = sp < 0 ? args : args[0 .. sp];
    bool has = true;
    if (first == "--smart") mode = CompactionMode.smart;
    else if (first == "--standard") mode = CompactionMode.standard;
    else has = false;
    focus = has ? (sp < 0 ? "" : args[sp + 1 .. $].strip) : args;
    return has;
}

unittest
{
    CompactionMode m;
    string f;
    assert(parseCompactArgs("--smart  the bug", m, f) && m == CompactionMode.smart && f == "the bug");
    assert(!parseCompactArgs("focus here", m, f) && f == "focus here");
    assert(parseCompactArgs("--standard", m, f) && m == CompactionMode.standard && f == "");
}

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
    out_ ~= "\nType / to list commands as you type; Tab completes commands and /model, /mode, /thinking arguments; Esc hides the list. Lines starting with / are never sent to the model: type // to send one that starts with /.";
    out_ ~= "\nKeys: Enter during a turn steers the running turn, Ctrl-Enter queues the message (/queue lists, edits, removes), Esc Esc or Ctrl-C cancels the turn, Esc Esc also clears the input at the prompt, Ctrl-O expands/collapses thinking, Shift+Tab cycles the mode (normal/plan/auto)";
    return out_;
}

/// One row of the argument type-ahead: the value Tab completes to and a note.
struct Suggestion
{
    string value, note;
}

/// The `/model` candidates (current, recents, provider defaults, providers);
/// set by the app, which has the config and the recents.
Suggestion[] delegate() @safe modelSuggestionSource;

/// The line as `command` + the start of its first argument; null past it.
string[2] splitCommand(string line, out bool ok)
{
    ok = false;
    size_t i;
    while (i < line.length && !isWhite(line[i])) i++;
    if (i == line.length) return typeof(return).init;
    auto rest = line[i + 1 .. $];
    while (rest.length && isWhite(rest[0])) rest = rest[1 .. $];
    if (rest.any!isWhite) return typeof(return).init;
    ok = true;
    return [line[0 .. i], rest];
}

/// Argument candidates for the line being typed, filtered by the typed prefix.
Suggestion[] suggestions(string line)
{
    import nano.mode : allModes, name, describe;
    import nano.thinking : ORDER;
    bool ok;
    auto parts = splitCommand(line, ok);
    if (!ok) return null;
    Suggestion[] all;
    switch (parts[0])
    {
        case "/model":
            if (modelSuggestionSource !is null) all = modelSuggestionSource();
            break;
        case "/mode":
            foreach (m; allModes) all ~= Suggestion(m.name, m.describe);
            break;
        case "/verbosity":
            {
                import nano.ui : allVerbosities, vname = name, vdescribe = describe;
                foreach (v; allVerbosities) all ~= Suggestion(v.vname, v.vdescribe);
                break;
            }
        case "/thinking":
            all = [Suggestion("default", "send no level; the model decides"),
                Suggestion("off", "turn thinking off, where the model allows it"),
                Suggestion("reset", "drop the session level; use the configured one")];
            foreach (l; ORDER) all ~= Suggestion(l, "");
            break;
        default: break;
    }
    return all.filter!(x => x.value.startsWith(parts[1])).array;
}

/// True past the name of a command with a known argument set (its type-ahead
/// is drawn even when nothing matches, to say so).
bool hasArgumentMenu(string line)
{
    bool ok;
    auto parts = splitCommand(line, ok);
    return ok && ["/model", "/mode", "/verbosity", "/thinking"].canFind(parts[0]);
}

/// What Tab turns the line into: a `/command` completes like `complete`; its
/// first argument completes against the suggestions (a unique match in full,
/// the common prefix, or a provider name to its top-ranked model).
string completeLine(string line)
{
    bool ok;
    auto parts = splitCommand(line, ok);
    if (!ok) return line.any!isWhite ? null : complete(line);
    auto found = suggestions(line);
    if (!found.length) return null;
    string done;
    if (found.length == 1) done = found[0].value;
    else
    {
        string common = found[0].value;
        foreach (x; found[1 .. $])
        {
            size_t n;
            while (n < common.length && n < x.value.length && common[n] == x.value[n]) ++n;
            common = common[0 .. n];
        }
        // Cut back to a whole character (Rust compares chars).
        while (common.length && (common[$ - 1] & 0xC0) == 0x80) common = common[0 .. $ - 1];
        if (common.length && (common[$ - 1] & 0x80)) common = common[0 .. $ - 1];
        if (common.length > parts[1].length) done = common;
        else
            foreach (x; found)
                if (x.value.startsWith(parts[1] ~ "/")) { done = x.value; break; }
    }
    return done.length ? parts[0] ~ " " ~ done : null;
}

/// Menu rows for an argument type-ahead: typed part bold, the rest of the value cyan, the note dim.
string[] suggestionMenu(const Suggestion[] found, string line, size_t cols, size_t maxRows)
{
    if (maxRows == 0) return null;
    bool ok;
    auto parts = splitCommand(line, ok);
    auto typed = ok ? parts[1].count : 0;
    if (!found.length) return [fit("  no match (any provider/model ID works)", cols, [Style(0, "\x1b[2m")])];
    size_t width;
    foreach (x; found) width = width < x.value.count ? x.value.count : width;
    auto shown = found.length > maxRows ? maxRows - 1 : found.length;
    string[] rows;
    foreach (x; found[0 .. shown])
    {
        auto plain = "  " ~ x.value ~ replicateStr(" ", width - x.value.count) ~ "  " ~ x.note;
        auto valueEnd = 2 + x.value.count;
        rows ~= fit(plain, cols, [Style(0, ""), Style(2, "\x1b[1m"), Style(2 + typed, "\x1b[0;36m"), Style(valueEnd, "\x1b[0;2m")]);
    }
    if (shown < found.length) rows ~= fit(format("  ... %s more", found.length - shown), cols, [Style(0, "\x1b[2m")]);
    return rows;
}

/// Menu rows for the line being typed: the command list while a `/command`
/// is typed, then its argument type-ahead. Each row fits in `cols` columns;
/// at most `maxRows`.
string[] menu(string line, size_t cols, size_t maxRows)
{
    if (hasArgumentMenu(line)) return suggestionMenu(suggestions(line), line, cols, maxRows);
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

/// Synopses longer than this overflow the name column instead of widening it.
enum nameColumn = 20;

size_t columnWidth()
{
    size_t w;
    foreach (c; commands)
    {
        auto n = synopsis(c).count;
        if (n <= nameColumn && n > w) w = n;
    }
    return w ? w : nameColumn;
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
    assert(complete("/mo") == "/mode"); // /mode and /model share it
    assert(complete("/mode") is null && complete("/model") == "/model ");
    assert(complete("/e") == "/exit");
    assert(complete("/s") == null); // /session, /skills: no longer prefix
    assert(complete("/zz") is null);
    assert(complete("/") is null);
}

unittest // menu rows
{
    auto rows = menu("/m", 80, 10);
    assert(rows.length == 3 && rows[0].canFind("\x1b[1m/m\x1b[0;36memory"), rows[0]);
    assert(menu("/help x", 80, 10) is null && menu("hi", 80, 10) is null && menu("/", 80, 0) is null);
    assert(menu("/zz", 80, 10)[0].canFind("no matching command"));
    auto few = menu("/", 80, 3);
    assert(few.length == 3 && few[2].canFind("more"));
    foreach (r; menu("/", 20, 20)) assert(r.count <= 19 + 30, r);
    assert(helpText().canFind("/memory [forget ID]"));
}

string replicateStr(string s, size_t n) pure { string r; foreach (_; 0 .. n) r ~= s; return r; }

unittest // argument type-ahead (Rust suggestions / complete_line / suggestion_menu)
{
    import std.algorithm : map, equal;
    auto saved = modelSuggestionSource;
    scope (exit) modelSuggestionSource = saved;
    modelSuggestionSource = () => [Suggestion("openai/gpt-4o", "current"), Suggestion("ollama/llama3", "recent"),
        Suggestion("ollama/qwen", "openai -> qwen"), Suggestion("ollama", "openai -> qwen")];
    assert(suggestions("/model oll").map!(x => x.value).equal(["ollama/llama3", "ollama/qwen", "ollama"]));
    assert(suggestions("/model") is null && suggestions("/model a b") is null && suggestions("/help x") is null);
    assert(hasArgumentMenu("/model ") && hasArgumentMenu("/mode x") && !hasArgumentMenu("/help ") && !hasArgumentMenu("/model"));
    // Unique match in full; common prefix; an exact provider descends to its top spec.
    assert(completeLine("/model op") == "/model openai/gpt-4o");
    assert(completeLine("/model o") is null || completeLine("/model o") == "/model o");
    assert(completeLine("/model oll") == "/model ollama");
    assert(completeLine("/model ollama") == "/model ollama/llama3");
    assert(completeLine("/model zz") is null);
    assert(completeLine("/mode p") == "/mode plan");
    assert(completeLine("/thinking xh") == "/thinking xhigh");
    assert(completeLine("/mo") == "/mode" && completeLine("/model a b") is null);
    auto rows = menu("/model zz", 80, 8);
    assert(rows.length == 1 && rows[0].canFind("no match (any provider/model ID works)"));
    rows = menu("/model oll", 80, 2);
    assert(rows.length == 2 && rows[1].canFind("... 2 more") && rows[0].canFind("llama3"));
}
