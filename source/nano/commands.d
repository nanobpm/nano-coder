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
    Command("/compact", "[--smart|--standard|--extract] [focus]", "Summarize older messages to free context (optional mode and focus)"),
    Command("/context", "", "Show context-window use and token totals"),
    Command("/settings", "", "View/edit settings"),
    Command("/verbosity", "[quiet|normal|verbose|debug]", "Show or set output detail"),
    Command("/plan", "", "Show the agent's task plan with notes"),
    Command("/timers", "", "List the timers the agent set for itself"),
    Command("/memory", "[forget ID]", "List cross-session memories (or forget one by id)"),
    Command("/hooks", "", "List loaded user hooks (.claude/settings.json and friends)"),
    Command("/queue", "[list|add text|remove N...|edit N text|clear]", "Show or edit the queued messages"),
    Command("/tools", "", "List available tools"),
    Command("/skills", "", "List skills the agent can load"),
    Command("/subagents", "[on|off] [--save]", "Show sub-agent models, or switch the agent tool on/off"),
    Command("/model", "[provider/model]", "Show the model and pick a new one (or switch directly)"),
    Command("/mode", "[normal|plan|auto]", "Show or set the agent mode (Shift+Tab cycles)"),
    Command("/thinking", "[level|default|off|reset]", "Show or set the thinking level for this session"),
    Command("/providers", "", "List configured providers"),
    Command("/session", "", "Show the session ID and log path"),
    Command("/version", "", "Show the nano-coder version"),
    Command("/changes", "[version]", "Show what changed since the previous release (or since version)"),
    Command("/trajectory", "[--json|--markdown]", "Show this session's turn-by-turn trajectory in your pager (or export it)"),
    Command("/resume", "[ID|last]", "Switch to a saved session: pick one, or give its ID"),
    Command("/restart", "", "Start a fresh session (clean context) without exiting"),
    Command("/update", "", "Install the latest release through the channel nano-coder was installed from"),
    Command("/relaunch", "", "Restart the binary, resuming this session (picks up a just-installed update)"),
    Command("/exit", "", "Exit the agent"),
    Command("/quit", "", "Exit the agent (alias for /exit)"),
];

/// `/compact` arguments: an optional `--smart`/`--standard`/`--extract`, then a focus.
/// Returns whether a mode was given.
bool parseCompactArgs(string args, out CompactionMode mode, out string focus) pure
{
    import std.string : strip, indexOf;
    args = args.strip;
    auto sp = args.indexOf(' ');
    auto first = sp < 0 ? args : args[0 .. sp];
    bool has = true;
    if (first == "--smart") mode = CompactionMode.smart;
    else if (first == "--standard") mode = CompactionMode.standard;
    else if (first == "--extract") mode = CompactionMode.extract;
    else has = false;
    focus = has ? (sp < 0 ? "" : args[sp + 1 .. $].strip) : args;
    return has;
}

// rust: commands.rs::compact_args_take_an_optional_mode_then_focus
unittest
{
    CompactionMode m;
    string f;
    assert(parseCompactArgs("--smart  the bug", m, f) && m == CompactionMode.smart && f == "the bug");
    assert(!parseCompactArgs("focus here", m, f) && f == "focus here");
    assert(parseCompactArgs("--standard", m, f) && m == CompactionMode.standard && f == "");
    assert(parseCompactArgs("--extract x", m, f) && m == CompactionMode.extract && f == "x");
}

/// Why a submitted `/…` line can't be sent: its first word isn't a command.
/// null for anything else (not a `/` line, a known command, or a `//` escape).
/// Such a line is never sent to the model.
string rejection(string line) pure
{
    auto word = firstWord(line.strip);
    if (!isCommand(line) || commands.any!(c => c.name == word))
        return null;
    auto note = "Unknown command " ~ word;
    if (auto close = closest(word)) note ~= ". Did you mean " ~ close ~ "?";
    note ~= " (/help lists commands)";
    return note;
}

/// Whether a submitted line is a slash command rather than a prompt. A
/// known command (`/help`, `/model x/y`) always is; an unknown `/word` is
/// only when it is a single line whose first word doesn't look like a path,
/// so a prompt such as `/workspace is shared.\n...` or `/tmp/foo is empty,
/// why?` reaches the model instead of being swallowed (Rust #173). A `//…`
/// line is an escaped prompt, never a command.
bool isCommand(string line) pure
{
    auto t = line.strip;
    auto word = firstWord(t);
    if (!word.length || !word.startsWith("/") || word.startsWith("//")) return false;
    if (commands.any!(c => c.name == word)) return true;
    return !word[1 .. $].canFind('/') && !t.canFind('\n');
}

/// A `//…` line is a prompt that starts with `/`: the text with one `/`
/// removed. null for other lines.
string unescapePrompt(string line) pure
{
    import std.string : stripLeft;
    auto t = line.stripLeft;
    return t.startsWith("//") ? t[1 .. $] : null;
}

const(Command)[] matching(string prefix) pure
{
    return commands.filter!(c => c.name.startsWith(prefix)).array;
}

/// What Tab turns `prefix` into: the command (plus a space when it takes
/// arguments) if only one matches, else the longest common prefix (null when
/// that adds nothing).
string complete(string prefix) pure
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
string helpText() pure
{
    auto width = columnWidth();
    auto out_ = "Commands:";
    foreach (c; commands) out_ ~= format("\n  %-*s  %s", width, synopsis(c), c.description);
    out_ ~= "\nType / to list commands as you type; Tab completes commands and /model, /mode, /thinking arguments; Esc hides the list. Lines starting with / are never sent to the model: type // to send one that starts with /.";
    out_ ~= "\nKeys: Enter during a turn steers the running turn, Ctrl-Enter queues the message (/queue lists, edits, removes), Esc Esc or Ctrl-C cancels the turn, Esc Esc also clears the input at the prompt, Shift+Tab cycles the mode (normal/plan/auto), Ctrl-O expands tool calls/results and thinking blocks a batch at a time going up from the bottom (press again to reach further back; once all are expanded it collapses them)";
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
string[2] splitCommand(string line, out bool ok) pure
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

/// The `/model` candidates: the current model, then recents, then each
/// enabled provider's default model, curated models, and bare provider
/// names (configured providers first). Hidden providers aren't offered, and
/// each value appears once.
Suggestion[] modelSuggestions(const ref imported!"nano.config".Config cfg, string current, const string[] recents) pure
{
    import nano.config : specVisible, enabledProviderNames, ProviderKind;
    import std.algorithm : sort;
    Suggestion[] out_;
    void push(string value, string note)
    {
        if (value.length && !out_.canFind!(x => x.value == value)) out_ ~= Suggestion(value, note);
    }
    // A current or recent model on a hidden provider stays usable but isn't offered.
    if (specVisible(current, cfg.providers, cfg.defaultProvider)) push(current, "current");
    foreach (r; recents)
        if (specVisible(r, cfg.providers, cfg.defaultProvider)) push(r, "recent");
    bool configured(string n) { return cfg.userProviders.canFind(n) || n == cfg.defaultProvider; }
    auto names = enabledProviderNames(cfg.providers);
    names.sort!((a, b) => configured(a) != configured(b) ? configured(a) : a < b);
    string kindOf(string n)
    {
        auto p = cfg.providers[n];
        if (!p.hasKind) return "provider";
        final switch (p.kind)
        {
            case ProviderKind.openai: return "openai";
            case ProviderKind.anthropic: return "anthropic";
            case ProviderKind.githubCopilot: return "githubcopilot";
            case ProviderKind.mock: return "mock";
        }
    }
    string providerNote(string n)
    {
        auto m = cfg.providers[n].defaultModel;
        return kindOf(n) ~ (m.length ? " -> " ~ m : "") ~ (n == cfg.defaultProvider ? ", default provider" : "");
    }
    foreach (n; names)
        if (auto m = cfg.providers[n].defaultModel)
            push(n ~ "/" ~ m, n == cfg.defaultProvider ? "default provider" : providerNote(n));
    // A curated list (`list_models = "configured"`) offers each of its models.
    foreach (n; names)
        foreach (m; cfg.providers[n].configuredModels) push(n ~ "/" ~ m[0], m[1]);
    foreach (n; names) push(n, providerNote(n));
    return out_;
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
bool hasArgumentMenu(string line) pure
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
string[] suggestionMenu(const Suggestion[] found, string line, size_t cols, size_t maxRows) pure
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

string firstWord(string s) pure
{
    foreach (i, dchar c; s)
        if (isWhite(c)) return s[0 .. i];
    return s;
}

string synopsis(const Command c) pure nothrow
{
    return c.args.length ? c.name ~ " " ~ c.args : c.name;
}

/// Synopses longer than this overflow the name column instead of widening it.
enum nameColumn = 20;

size_t columnWidth() pure
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
string closest(string word) pure
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
size_t editDistance(string as, string bs) pure
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
string fit(string plain, size_t cols, const Style[] styles) pure
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

// rust: commands.rs::closest_skips_the_matrix_for_oversized_input
// rust: commands.rs::oversized_words_skip_edit_distance_and_suggest_nothing
// rust: commands.rs::slash_slash_escapes_a_prompt
// rust: commands.rs::unknown_commands_are_rejected_with_a_suggestion
unittest // rejection with did-you-mean and // escape; path-leading prompts pass
{
    assert(rejection("/help") is null && rejection("hello") is null && rejection("//etc/hosts") is null);
    assert(rejection("/model gpt") is null);
    auto r = rejection("/exin");
    assert(r.canFind("Unknown command /exin") && r.canFind("Did you mean /exit?") && r.canFind("/help lists"), r);
    assert(rejection("/modle").canFind("Did you mean /model?"));
    foreach (ok; ["/exit", "/model gpt-4o", "/compact --smart focus", "//usr/lib", "hello /exin", "", "   ",
            "/usr/lib is 4 GB, why?", "/tmp/foo is empty, why?",
            "\n/workspace is the only path you share with the user.\n\nWrite a FEEL expression"])
        assert(rejection(ok) is null, ok);
    assert(unescapePrompt("//etc/hosts x") == "/etc/hosts x" && unescapePrompt("/help") is null);
    assert(rejection("/" ~ "x".replicateStr(5000)).canFind("Unknown"));
}

// rust: commands.rs::only_known_or_plausible_commands_are_commands
unittest // a known command or a single-line, non-path /word is a command
{
    foreach (cmd; ["/help", "/compact", "/compact --smart keep tests", "/model openai/gpt-4o", " /exit \n"])
        assert(isCommand(cmd), cmd);
    assert(isCommand("/exin") && isCommand("/frobnicate now"));
    foreach (prompt; ["\n/workspace is the only path you share with the user.\n\nWrite a FEEL expression to /workspace/answer.feel",
            "/tmp/foo is empty, why?", "/workspace\nis shared", "//escaped", "plain", ""])
        assert(!isCommand(prompt), prompt);
}

// rust: commands.rs::tab_completes_unique_commands_and_common_prefixes
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

// rust: commands.rs::help_lists_every_command
// rust: commands.rs::suggestion_rows_fit_and_highlight_the_typed_part
// rust: commands.rs::rows_fit_the_terminal
// rust: commands.rs::slash_lists_everything_and_typing_narrows_it
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
    assert(helpText().canFind("/version")); // rust: commands.rs::help_lists_version
}

string replicateStr(string s, size_t n) pure nothrow { string r; foreach (_; 0 .. n) r ~= s; return r; }

// rust: commands.rs::suggestions_narrow_on_the_argument_prefix
// rust: commands.rs::complete_line_handles_arguments
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
    // rust: lineedit.rs::tab_completes_model_arguments_from_context
    assert(completeLine("/mode a") == "/mode auto");
    assert(completeLine("/model zz") is null, "no match: unchanged");
    assert(completeLine("/model  ol") == "/model ollama", "irregular spacing canonicalizes");
    assert(completeLine("/model zz") is null);
    assert(completeLine("/mode p") == "/mode plan");
    assert(completeLine("/thinking xh") == "/thinking xhigh");
    assert(completeLine("/mo") == "/mode" && completeLine("/model a b") is null);
    auto rows = menu("/model zz", 80, 8);
    assert(rows.length == 1 && rows[0].canFind("no match (any provider/model ID works)"));
    rows = menu("/model oll", 80, 2);
    assert(rows.length == 2 && rows[1].canFind("... 2 more") && rows[0].canFind("llama3"));
}

// rust: commands.rs::edit_distance_counts_edits
// rust: commands.rs::mode_and_verbosity_arguments_are_suggested
// rust: commands.rs::model_suggestions_hoist_current_recent_and_defaults
unittest
{
    import nano.config : Config;
    import std.file : tempDir, write, remove;
    import std.path : buildPath;
    assert(editDistance("/exin", "/exit") == 1);
    assert(editDistance("/modle", "/model") == 1, "a swap is one edit");
    assert(editDistance("/modle", "/mode") == 1);
    assert(editDistance("", "abc") == 3 && editDistance("same", "same") == 0);

    string[] values(Suggestion[] xs) { return xs.map!(x => x.value).array; }
    assert(values(suggestions("/mode ")) == ["normal", "plan", "auto"]);
    assert(values(suggestions("/mode p")) == ["plan"]);
    assert(values(suggestions("/verbosity v")) == ["verbose"]);

    auto path = buildPath(tempDir, "nano-d-model-suggestions.toml");
    write(path, "model = \"openai/gpt-4o\"\ndefault_provider = \"openai\"\n[providers.work]\nkind = \"openai\"\n"
        ~ "base_url = \"http://merlin.local:8000/v1\"\ndefault_model = \"gpt-oss-120b\"\n");
    scope (exit) remove(path);
    auto cfg = Config.load(path);
    auto found = values(modelSuggestions(cfg, "openai/gpt-4o", ["ollama/qwen3:8b", "anthropic/claude-sonnet-4-5"]));
    assert(found[0 .. 3] == ["openai/gpt-4o", "ollama/qwen3:8b", "anthropic/claude-sonnet-4-5"], found[0]);
    import std.algorithm : countUntil;
    assert(found.countUntil("work/gpt-oss-120b") < found.countUntil("work") && found.countUntil("work") > 0, found[3]);
    assert(!found.canFind("mock/mock") && !found.canFind("mock"), "hidden mock not offered");
    found = values(modelSuggestions(cfg, "openai/gpt-4o", ["work/gpt-oss-120b"]));
    assert(found.filter!(v => v == "work/gpt-oss-120b").array.length == 1);
}

// rust: commands.rs::model_suggestions_offer_configured_models_and_skip_disabled_providers
unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    import std.algorithm : find, any, startsWith;
    import nano.config : Config;
    auto path = buildPath(tempDir, "nano-d-model-suggestions-2.toml");
    write(path, `model = "openrouter-regional/moonshotai/kimi-k3"
[providers.openrouter]
disabled = true
[providers.openrouter-regional]
kind = "openai"
base_url = "https://us.openrouter.ai/api/v1"
list_models = "configured"
[providers.openrouter-regional.models."amazon/nova-lite-v1"]
name = "Nova Lite 1.0"
base_url = "https://eu.openrouter.ai/api/v1"
`);
    scope (exit) remove(path);
    auto cfg = Config.load(path);
    auto found = modelSuggestions(cfg, null, null);
    auto nova = found.find!(s => s.value == "openrouter-regional/amazon/nova-lite-v1");
    assert(nova.length, "configured model offered");
    assert(nova[0].note == "Nova Lite 1.0", nova[0].note);
    assert(!found.any!(s => s.value == "openrouter" || s.value.startsWith("openrouter/")), "disabled hidden");
}
