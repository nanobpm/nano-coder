/// Command normalization and loop classification for permission checks
/// (port of the "command normalization" half of src/permissions.rs).
///
/// `expandAll` turns parsed simple commands into the commands that actually
/// run: wrappers (`sudo`, `env`, `timeout`, `xargs`, ...) are stripped and
/// nested scripts (`bash -c`, `eval`, `ssh host CMD`, `find -exec`,
/// here-documents fed to a shell) are parsed and inspected. Shell loops must
/// be provably read-only. Anything that cannot be inspected throws `Blocked`
/// (Rust: `Err(String)`), with the same wording as the Rust implementation.
module nano.cmdexpand;

@safe:

import std.algorithm : canFind, any, all, startsWith, endsWith, map, filter;
import std.array : join, split, array;
import std.format : format;
import std.regex : regex, matchFirst, ctRegex;
import std.string : indexOf, lastIndexOf, stripLeft;
import nano.shell;

/// A reason a command is blocked or cannot be inspected.
class Blocked : Exception
{
    this(string msg) pure { super(msg); }
}

enum maxExpandDepth = 8;

immutable string[] safeDevices = ["/dev/null", "/dev/zero", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty"];
immutable string[] interpreters = ["python", "python3", "node", "ruby", "perl", "php", "deno", "bun"];

string commandText(const Simple cmd) pure
{
    return cmd.words.map!(w => w.text).join(" ");
}

/// A redirection operator that writes to its target.
bool isWriteRedirect(string op) pure
{
    return [">", ">>", ">|", "&>", "&>>", "<>", ">&"].canFind(op);
}

string basename(string text) pure
{
    auto i = text.lastIndexOf('/');
    return i < 0 ? text : text[i + 1 .. $];
}

bool isAssignment(string text)
{
    static re = ctRegex!(`^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=`);
    return !matchFirst(text, re).empty;
}

bool isShellIdentifier(string text) pure
{
    if (!text.length) return false;
    auto c = text[0];
    if (!(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
    foreach (ch; text[1 .. $])
        if (!(ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))) return false;
    return true;
}

bool allDigits(string s) pure
{
    foreach (c; s) if (c < '0' || c > '9') return false;
    return true;
}

/// `s` with its words replaced (redirects, heredocs and flags kept).
Simple withWords(const Simple s, const(Word)[] words) pure
{
    Simple r;
    r.words = words.dup;
    r.redirects = s.redirects.dup;
    r.heredocs = s.heredocs.dup;
    r.loopHeaderSub = s.loopHeaderSub;
    return r;
}

/// A command with only words (Rust: `Simple { words, ..Default::default() }`).
Simple bare(const(Word)[] words) pure
{
    Simple r;
    r.words = words.dup;
    return r;
}

// ---- find / glob helpers ---------------------------------------------------

/// True when a `find` narrowing predicate could match a `.git` path.
bool findPredicateReachesGit(const Word[] args)
{
    static immutable gitPaths = [".git", "./.git", "a/.git", "a/.git/HEAD", "a/b/.git"];
    foreach (i, arg; args)
    {
        if (i + 1 >= args.length) break;
        auto v = args[i + 1].text;
        switch (arg.text)
        {
        case "-name", "-iname": if (globReaches(v, [".git"])) return true; break;
        case "-path", "-ipath", "-wholename", "-iwholename": if (globReaches(v, gitPaths)) return true; break;
        case "-regex", "-iregex": if (regexReaches(v, gitPaths)) return true; break;
        default:
        }
    }
    return false;
}

private string escapeRegexChar(dchar c) pure
{
    import std.conv : to;
    if (`\.+*?()|[]{}^$`.canFind(c)) return "\\" ~ c.to!string;
    return c.to!string;
}

/// Whether a shell glob matches any target (fail closed on a bad pattern).
bool globReaches(string pattern, const string[] targets)
{
    string re = "^";
    foreach (dchar c; pattern)
        re ~= c == '*' ? ".*" : c == '?' ? "." : escapeRegexChar(c);
    re ~= "$";
    return regexReaches(re, targets);
}

/// Whether a regex matches any target (fail closed on a bad pattern).
bool regexReaches(string pattern, const string[] targets)
{
    try
    {
        auto r = regex(pattern);
        foreach (t; targets)
            if (!matchFirst(t, r).empty) return true;
        return false;
    }
    catch (Exception) return true; // an unparsable pattern might reach anything: answer yes, the safe side
}

/// Whether a `.git` directory exists at or below `root` (symlinks not
/// followed; a tree larger than the budget is treated as containing one).
bool containsGitDir(string root)
{
    import std.file : dirEntries, SpanMode, DirEntry;
    import std.path : baseName;
    string[] stack = [root];
    size_t budget = 20_000;
    while (stack.length)
    {
        auto dir = stack[$ - 1];
        stack = stack[0 .. $ - 1];
        if (budget == 0) return true;
        --budget;
        try
        {
            foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
            {
                if (e.isSymlink || !e.isDir) continue;
                if (baseName(e.name) == ".git") return true;
                stack ~= e.name;
            }
        }
        catch (Exception) continue; // an unreadable directory can't hold a .git we could reach; skip it
    }
    return false;
}

// ---- sequences and loops -------------------------------------------------------

Simple[] expandAll(const Simple[] parsed)
{
    return expandAllChecked(parsed).commands;
}

/// A loop command whose program is static but not a known read-only utility,
/// so the loop could not be verified automatically. An interactive session asks
/// the user about the whole loop; anywhere else it is blocked with `reason`.
struct Unverified
{
    Simple command;
    string reason;
}

/// The expansion of a parsed command line: the commands to check, plus the
/// loop fallout the caller must account for.
struct Expansion
{
    /// Every command the line runs, with loops classified by effect.
    Simple[] commands;
    /// Loop commands that could not be verified as read-only.
    Unverified[] unverified;
    /// Variables of loops that were unrolled away: the loop still ran, so the
    /// name stays loop-bound for the destructive-path guard.
    string[] bound;
    /// The original parsed commands (loop headers and assignments intact) the
    /// guard's dataflow is built from; the executable `commands` lose
    /// bindings to the unroll.
    Simple[] guardSource;
}

/// Most iterations a literal word list is unrolled into (issue #164).
enum maxLoopUnroll = 64;
/// Most body commands all unrolled loops of one command line may produce.
enum maxUnrolledCommands = 1024;

struct ExpandCtx
{
    Unverified[] unverified;
    /// Whether literal-list `for` loops may be unrolled; off while running the
    /// hard-block pre-check over a loop's original form.
    bool unroll = true;
    /// Remaining unrolled-command budget.
    size_t budget = maxUnrolledCommands;
    /// Variables of loops that were unrolled away.
    string[] bound;

    void note(string verdict, const Simple command)
    {
        if (verdict !is null) unverified ~= Unverified(withWords(command, command.words), verdict);
    }
}

/// Expand a parsed command line. Hard blocks throw `Blocked`.
Expansion expandAllChecked(const Simple[] parsed)
{
    Expansion e;
    ExpandCtx ctx;
    expandSequenceWith(parsed, 0, e.commands, false, ctx);
    e.unverified = ctx.unverified;
    e.bound = ctx.bound;
    foreach (s; parsed) e.guardSource ~= withWords(s, s.words);
    return e;
}

void parseInner(string script, size_t depth, ref Simple[] out_)
{
    if (depth >= maxExpandDepth) throw new Blocked("commands nest too deeply");
    Simple[] parsed;
    try parsed = parseNested(script, depth);
    catch (ShellParseError e) throw new Blocked(e.msg);
    expandSequence(parsed, depth + 1, out_);
}

/// Text of a script argument (`bash -c SCRIPT`, `eval ...`); throws when it is
/// computed at run time and so cannot be inspected.
string scriptText(const Word[] words)
{
    auto text = words.map!(w => w.text).join(" ");
    bool opaque = words.any!(w => w.text.canFind("$(...)"))
        || (words.length == 1 && words[0].dynamic && words[0].text.stripLeft.startsWith("$"));
    if (opaque) throw new Blocked(format("the script `%s` is computed at run time", text));
    return text;
}

private struct LoopFrame
{
    string kind;
    bool inBody;
}

void expandSequence(const Simple[] parsed, size_t depth, ref Simple[] out_)
{
    // A nested script (`bash -c '...'`, `eval`, `ssh host ...`) has no approval
    // path of its own: an unverifiable loop inside it stays a hard block.
    ExpandCtx ctx;
    expandSequenceWith(parsed, depth, out_, false, ctx);
    if (ctx.unverified.length) throw new Blocked(ctx.unverified[0].reason);
}

/// Expand a parsed command sequence, classifying shell loops by effect: once
/// a `for`/`select`/`while`/`until` opens, every condition and body command
/// until the matching `done` must be provably read-only. `readonly` is set
/// when the sequence is itself a loop header/condition substitution.
void expandSequenceWith(const Simple[] parsed, size_t depth, ref Simple[] out_, bool readonly, ref ExpandCtx ctx)
{
    LoopFrame[] loops;
    size_t index = 0;
    while (index < parsed.length)
    {
        auto simple = parsed[index];
        if (simple.loopHeaderSub)
        {
            auto start = index;
            while (index < parsed.length && parsed[index].loopHeaderSub) ++index;
            auto run = parsed[start .. index];
            if (run.any!(s => startsReadonlyLoopKeyword(s)))
            {
                Simple[] cleared;
                foreach (s; run)
                {
                    auto c = withWords(s, s.words);
                    c.loopHeaderSub = false;
                    cleared ~= c;
                }
                // A header/condition substitution's values are produced at run
                // time, so a literal-looking list inside it is not a literal the
                // unroll can substitute: keep the inner loop's classification.
                immutable saved = ctx.unroll;
                ctx.unroll = false;
                scope (exit) ctx.unroll = saved;
                expandSequenceWith(cleared, depth, out_, true, ctx);
            }
            else
                foreach (cmd; run)
                {
                    ctx.note(checkReadonlyLoopCommand(cmd, "loop", "header or condition substitution"), cmd);
                    expand(cmd, depth, out_);
                }
            continue;
        }
        ++index;
        auto offset = loopCommandOffset(simple.words);
        string head = offset < simple.words.length && isLoopKeyword(simple.words[offset]) ? simple.words[offset].text : null;
        bool startsLoop = head !is null && ["for", "select", "while", "until"].canFind(head);
        bool closesLoop = head == "done" && loops.length > 0;
        if (!loops.length && !startsLoop)
        {
            if (readonly)
            {
                auto effective = withWords(simple, simple.words[offset .. $]);
                ctx.note(checkReadonlyLoopCommand(effective, "loop", "header or condition substitution"), effective);
            }
            expand(simple, depth, out_);
            continue;
        }
        if (loops.length && simple.words[0 .. offset].any!(w => w.text == "do"))
            loops[$ - 1].inBody = true;

        // Issue #164: a `for` loop over a literal list is exactly the commands
        // it unrolls to. Not while an enclosing loop frame is active (the
        // unrolled body would drop the outer loop's read-only requirement).
        if (startsLoop && ctx.unroll && head == "for" && !loops.length)
        {
            auto end = matchingDone(parsed, index - 1);
            if (end >= 0)
            {
                // Classify the loop as written first, without unrolling: this
                // keeps every hard block and yields the fallback expansion.
                auto region = parsed[index - 1 .. end + 1];
                ExpandCtx scratch;
                scratch.unroll = false;
                scratch.budget = 0;
                Simple[] scratchOut;
                expandSequenceWith(region, depth, scratchOut, readonly, scratch);
                // Attempt the unroll even when the loop already classifies
                // read-only, so the caller's deny scan sees the values.
                Simple[] unrolled;
                if (unrollLiteralLoop(region, offset, ctx.budget, parsed[0 .. index - 1], unrolled))
                {
                    // The loop still ran: keep its variable loop-bound.
                    if (offset + 1 < region[0].words.length) ctx.bound ~= region[0].words[offset + 1].text;
                    // Re-raise hard blocks a substitution introduced; a merely
                    // unverifiable verdict is not re-recorded (the commands are
                    // the explicit equivalents the caller judges).
                    foreach (cmd; unrolled)
                    {
                        checkReadonlyLoopCommand(cmd, "for", "body");
                        expand(cmd, depth, out_);
                    }
                }
                else
                {
                    out_ ~= scratchOut;
                    ctx.unverified ~= scratch.unverified;
                }
                index = end + 1;
                continue;
            }
        }

        if (startsLoop)
        {
            auto kind = head;
            auto phase = (kind == "while" || kind == "until") ? "condition" : "header";
            checkLoopSideEffects(simple, kind, phase);
            if (kind == "for" || kind == "select") validateLoopHeader(simple, offset, kind);
            loops ~= LoopFrame(kind, false);
            if ((kind == "while" || kind == "until") && offset + 1 < simple.words.length)
            {
                auto condWords = simple.words[offset + 1 .. $];
                auto condOffset = loopCommandOffset(condWords);
                auto condition = withWords(simple, condWords[condOffset .. $]);
                ctx.note(checkReadonlyLoopCommand(condition, kind, "condition"), condition);
                expand(condition, depth, out_);
            }
            continue;
        }
        auto frame = loops[$ - 1];
        if (closesLoop)
        {
            checkLoopSideEffects(simple, frame.kind, "closing");
            if (offset + 1 < simple.words.length)
                throw new Blocked(format("cannot inspect words after `done` in `%s`; rewrite the loop as explicit commands",
                    commandText(simple)));
            loops = loops[0 .. $ - 1];
            continue;
        }
        auto phase = frame.inBody ? "body" : "condition";
        auto effective = withWords(simple, simple.words[offset .. $]);
        ctx.note(checkReadonlyLoopCommand(effective, frame.kind, phase), effective);
        expand(effective, depth, out_);
    }
    if (loops.length)
        throw new Blocked(format("unterminated `%s` loop cannot be inspected; rewrite the loop as explicit commands",
            loops[$ - 1].kind));
}

/// Offset of the first word that is not a leading control-flow keyword.
size_t loopCommandOffset(const Word[] words) pure
{
    size_t offset = 0;
    while (offset < words.length)
    {
        auto w = words[offset];
        if (!isLoopKeyword(w) || !["!", "if", "then", "else", "elif", "do", "{", "}", "fi", "esac"].canFind(w.text)) break;
        ++offset;
    }
    return offset;
}

bool isLoopKeyword(const Word w) pure { return !w.dynamic && !w.quoted; }

/// A mutable deep copy of `w`.
Word copyWord(const Word w) pure
{
    Word r;
    r.text = w.text;
    r.dynamic = w.dynamic;
    r.glob = w.glob;
    r.quoted = w.quoted;
    r.splits = w.splits;
    r.assigns = w.assigns;
    r.literalDollars = w.literalDollars;
    r.expansionDollars = w.expansionDollars;
    r.expansionSpans = w.expansionSpans;
    return r;
}

/// Index of the `done` closing the loop whose header is `parsed[start]`, or -1.
ptrdiff_t matchingDone(const Simple[] parsed, size_t start) pure
{
    size_t depth = 0;
    foreach (index; start .. parsed.length)
    {
        auto words = parsed[index].words;
        auto offset = loopCommandOffset(words);
        if (offset >= words.length || !isLoopKeyword(words[offset])) continue;
        auto head = words[offset].text;
        if (head == "for" || head == "select" || head == "while" || head == "until") ++depth;
        else if (head == "done" && depth > 0)
        {
            --depth;
            if (depth == 0) return cast(ptrdiff_t) index;
        }
    }
    return -1;
}

private bool isIdentChar(char c) pure
{
    return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

/// Unroll a `for NAME in WORDS; do BODY; done` loop whose word list is literal
/// (plain words, quoted strings, brace expansion) into its body repeated once
/// per value with the loop variable substituted, so each command is judged
/// exactly as the explicit command it becomes. False when the loop cannot be
/// unrolled exactly (Rust `unroll_literal_loop` returning `None`).
bool unrollLiteralLoop(const Simple[] region, size_t offset, ref size_t budget, const Simple[] prior,
    out Simple[] result)
{
    if (region.length < 2) return false;
    auto header = region[0];
    auto done = region[$ - 1];
    auto body = region[1 .. $ - 1];
    // The effective IFS: the last literal `IFS=...` assignment-position word
    // before the loop on this line (`echo IFS=x` is an argument, not a binding).
    string ifs = null;
    foreach (cmd; prior)
    {
        auto words = cmd.words[loopCommandOffset(cmd.words) .. $];
        if (words.length && !words[0].dynamic && declBuiltins.canFind(words[0].text)) words = words[1 .. $];
        bool here = false, programFollows = false;
        string value;
        foreach (w; words)
        {
            if (w.dynamic || w.glob || !isAssignment(w.text)) { programFollows = true; break; }
            if (w.text.startsWith("IFS=")) { here = true; value = w.text[4 .. $]; }
        }
        if (here)
        {
            // `IFS=x true` binds IFS for that one command only (or not,
            // depending on the program): decline rather than guess.
            if (programFollows) return false;
            ifs = value is null ? "" : value;
        }
    }
    if (header.redirects.length || header.heredocs.length || done.heredocs.length) return false;
    if (offset + 2 >= header.words.length) return false;
    auto variable = header.words[offset + 1];
    if (variable.dynamic || variable.quoted || !isShellIdentifier(variable.text)) return false;
    // `_` is rebound to the last argument of every simple command.
    if (variable.text == "_") return false;
    // A prior declaration can give the variable transforming attributes.
    if (priorDeclares(prior, variable.text)) return false;
    auto keyword = header.words[offset + 2];
    if (keyword.text != "in" || !isLoopKeyword(keyword)) return false;
    string[] values;
    foreach (word; header.words[offset + 3 .. $])
    {
        if (word.glob || word.assigns || word.text.canFind('$') || word.text.canFind('`') || word.text.canFind('\\'))
            return false;
        if (word.text.canFind('{') || word.text.canFind('}'))
        {
            // The lexer marks an unquoted brace list/range dynamic; an unmarked
            // brace word is literal text (`{x}`, `{}`).
            if (word.dynamic)
            {
                if (word.quoted) return false;
                string[] expanded;
                if (!braceExpand(word.text, expanded)) return false;
                values ~= expanded;
            }
            else values ~= word.text;
        }
        else
        {
            if (word.dynamic) return false;
            values ~= word.text;
        }
        if (values.length > maxLoopUnroll) return false;
    }
    // Tilde expansion runs before the binding and is unmarked by the lexer.
    if (values.any!(v => v.startsWith("~"))) return false;
    auto total = values.length * body.length;
    if (total > budget) return false;
    // A body that rebinds the variable, writes IFS, or holds a nested loop
    // cannot be replayed flat.
    bool[string] rebinds;
    foreach (simple; body) collectLoopBodyWrites(simple.words[loopCommandOffset(simple.words) .. $], rebinds);
    if (variable.text in rebinds || "IFS" in rebinds) return false;
    foreach (simple; body)
        if (simple.words[loopCommandOffset(simple.words) .. $].any!(w => isLoopKeyword(w)
                && ["for", "select", "while", "until", "done"].canFind(w.text)))
            return false;
    auto name = variable.text;
    Simple[] unrolled;
    foreach (value; values)
        foreach (simple; body)
        {
            if (simple.heredocs.any!(h => h.expand && h.body.canFind('$'))) return false;
            Word[] words;
            foreach (w; simple.words)
            {
                Word sub;
                if (!substituteWord(w, name, value, ifs, sub)) return false;
                // Only a plain `$VAR` may stay dynamic: a command substitution,
                // brace or assigning expansion re-runs per iteration.
                if (sub.assigns || (sub.dynamic && (sub.text.canFind('`') || sub.text.canFind('{')
                        || sub.text.canFind('}') || sub.text.canFind("$("))))
                    return false;
                words ~= sub;
            }
            Redirect[] redirects;
            foreach (r; simple.redirects.dup ~ done.redirects.dup)
            {
                Word target;
                if (!substituteWord(r.target, name, value, ifs, target)) return false;
                if (target.assigns || (target.dynamic && (target.text.canFind('`') || target.text.canFind('{')
                        || target.text.canFind('}'))))
                    return false;
                redirects ~= Redirect(r.op, target);
            }
            // Strip leading control keywords (`do`, `then`) so the unrolled
            // command is the plain command it stands for.
            auto c = withWords(simple, words[loopCommandOffset(words) .. $]);
            c.redirects = redirects;
            unrolled ~= c;
        }
    budget -= total;
    result = unrolled;
    return true;
}

/// Whether any command in `prior` runs a declaration builtin whose arguments
/// name `name` or are computed (wrappers seen through by scanning every word).
bool priorDeclares(const Simple[] prior, string name)
{
    foreach (cmd; prior)
    {
        auto words = cmd.words;
        foreach (k, w; words)
        {
            if (w.dynamic || !declBuiltins.canFind(basename(w.text))) continue;
            foreach (arg; words[k + 1 .. $])
            {
                if (arg.dynamic) return true;
                string head = arg.text;
                foreach (i, ch; head)
                    if (ch == '=' || ch == '[') { head = head[0 .. i]; break; }
                while (head.endsWith("+")) head = head[0 .. $ - 1];
                if (head == name) return true;
            }
        }
    }
    return false;
}

/// Replace `$name` / `${name}` in `word` with `value`. False when the word uses
/// the variable another way (`${name:-x}`, `${#name}`), mixes a literal
/// (quoted/escaped) `$name` with real expansions, or when word splitting,
/// pathname or brace expansion would turn `value` into something other than
/// one literal argument. `ifs` null means the default IFS.
bool substituteWord(const Word word, string name, string value, string ifs, out Word result)
{
    if (!word.dynamic)
    {
        result = copyWord(word);
        return true;
    }
    auto text = word.text;
    string out_;
    bool replaced = false;
    size_t i = 0;
    while (i < text.length)
    {
        if (text[i] != '$') { out_ ~= text[i]; ++i; continue; }
        auto rest = text[i + 1 .. $];
        if (rest.startsWith("$")) { out_ ~= "$$"; i += 2; continue; }
        // Trust the lexer's real span over the flat text (`"$d"etc` is `$d`).
        bool spanIsName = word.expansionSpans.any!(sp => sp[0] == i && sp[1] == i + 1 + name.length);
        bool spanKnown = word.expansionSpans.any!(sp => sp[0] == i);
        if (rest.startsWith(name))
        {
            auto after = rest[name.length .. $];
            if (spanIsName || (!spanKnown && !(after.length && isIdentChar(after[0]))))
            {
                // A literal `$name` (single-quoted, escaped) stays in place.
                if (word.literalDollars.canFind(i)) out_ ~= "$" ~ name;
                else { out_ ~= value; replaced = true; }
                i += 1 + name.length;
                continue;
            }
        }
        if (rest.startsWith("{"))
        {
            auto inner = rest[1 .. $];
            if (inner.startsWith(name) && inner[name.length .. $].startsWith("}"))
            {
                if (word.literalDollars.canFind(i)) out_ ~= "${" ~ name ~ "}";
                else { out_ ~= value; replaced = true; }
                i += 3 + name.length;
                continue;
            }
            // Any other braced form mentioning the variable is not plain.
            auto close = inner.indexOf('}');
            auto bodyText = close < 0 ? inner : inner[0 .. close];
            size_t s = 0;
            foreach (k; 0 .. bodyText.length + 1)
                if (k == bodyText.length || !isIdentChar(bodyText[k]))
                {
                    if (bodyText[s .. k] == name) return false;
                    s = k + 1;
                }
        }
        out_ ~= '$';
        ++i;
    }
    // A preserved literal `$name` alongside real expansions is ambiguous: the
    // checked operand would not be the executed one.
    foreach (lit; word.literalDollars)
    {
        if (lit + 1 > text.length) continue;
        auto after = text[lit + 1 .. $];
        if ((after.startsWith(name) && !(after.length > name.length && isIdentChar(after[name.length])))
            || (after.startsWith("{") && after[1 .. $].startsWith(name) && after[1 + name.length .. $].startsWith("}")))
            return false;
    }
    if (!replaced)
    {
        result = copyWord(word);
        return true;
    }
    if (word.splits)
    {
        // An unquoted substitution word-splits on the effective IFS and is
        // then pathname-expanded.
        auto split = ifs is null ? " \t\n" : ifs;
        if (!value.length || value.any!(c => split.canFind(c) || "*?[".canFind(c))) return false;
    }
    // A brace surviving substitution is brace-expanded by the shell.
    if (out_.canFind('{') || out_.canFind('}')) return false;
    result = copyWord(word);
    result.text = out_;
    result.dynamic = out_.canFind('$') || out_.canFind('`');
    result.splits = result.dynamic ? word.splits : word.glob;
    return true;
}

/// Bash brace expansion of an unquoted literal word: comma lists and integer
/// or single-letter ranges (with an optional step), with any prefix and
/// suffix. False on nested or unbalanced braces; a non-expanding brace group
/// (`{}`, `{x}`) is kept literally.
bool braceExpand(string text, out string[] result)
{
    import core.checkedint : adds, subs;
    import std.conv : to, ConvException;
    import std.ascii : isAlpha;
    auto open = text.indexOf('{');
    if (open < 0)
    {
        if (text.canFind('}')) return false;
        result = [text];
        return true;
    }
    auto closeRel = text[open .. $].indexOf('}');
    if (closeRel < 0) return false;
    auto close = open + closeRel;
    auto inner = text[open + 1 .. close];
    if (inner.canFind('{')) return false;
    auto prefix = text[0 .. open], suffix = text[close + 1 .. $];
    if (prefix.canFind('}')) return false;
    string[] items;
    static bool parseLong(string s, out long v)
    {
        try { v = s.to!long; return true; }
        catch (ConvException) return false;
    }
    if (inner.canFind(','))
        items = inner.split(",");
    else if (inner.indexOf("..") >= 0)
    {
        auto dd = inner.indexOf("..");
        auto from = inner[0 .. dd], rest = inner[dd + 2 .. $];
        string to_ = rest;
        ulong step = 1;
        auto dd2 = rest.indexOf("..");
        if (dd2 >= 0)
        {
            to_ = rest[0 .. dd2];
            auto stepText = rest[dd2 + 2 .. $];
            if (!stepText.length || !allDigits(stepText)) return false;
            try step = stepText.to!ulong;
            catch (ConvException) return false;
            if (step == 0) step = 1;
        }
        long a, b;
        if (parseLong(from, a) && parseLong(to_, b))
        {
            immutable ulong diff = a <= b ? cast(ulong) b - cast(ulong) a : cast(ulong) a - cast(ulong) b;
            if (diff >= maxLoopUnroll) return false;
            // Bash pads only when an endpoint has an explicit leading zero.
            bool padded = (from.length > 1 && from.startsWith("0")) || from.startsWith("-0")
                || (to_.length > 1 && to_.startsWith("0")) || to_.startsWith("-0");
            auto width = from.length > to_.length ? from.length : to_.length;
            if (step > long.max) step = long.max;
            immutable long st = cast(long) step;
            long n = a;
            for (;;)
            {
                items ~= padded ? format("%0*d", width, n) : n.to!string;
                if (n == b) break;
                bool overflow = false;
                auto next = a <= b ? adds(n, st, overflow) : subs(n, st, overflow);
                if (overflow) break;
                n = next;
                if ((a <= b && n > b) || (a > b && n < b)) break;
                if (items.length > maxLoopUnroll) return false;
            }
        }
        else if (from.length == 1 && to_.length == 1 && isAlpha(from[0]) && isAlpha(to_[0]))
        {
            long ca = from[0], cb = to_[0];
            if ((ca <= cb ? cb - ca : ca - cb) >= maxLoopUnroll) return false;
            immutable long st = step > long.max ? long.max : cast(long) step;
            long c = ca;
            for (;;)
            {
                items ~= [cast(char) c].idup;
                if (c == cb) break;
                bool overflow = false;
                auto next = ca <= cb ? adds(c, st, overflow) : subs(c, st, overflow);
                if (overflow) break;
                c = next;
                if ((ca <= cb && c > cb) || (ca > cb && c < cb)) break;
                if (items.length > maxLoopUnroll) return false;
            }
        }
        else return false;
    }
    else
    {
        // Not an expansion: the braces are literal; expand the rest.
        string[] tail;
        if (!braceExpand(suffix, tail)) return false;
        foreach (t; tail) result ~= prefix ~ "{" ~ inner ~ "}" ~ t;
        return true;
    }
    string[] tails;
    if (!braceExpand(suffix, tails)) return false;
    foreach (item; items)
        foreach (t; tails)
        {
            result ~= prefix ~ item ~ t;
            if (result.length > maxLoopUnroll) return false;
        }
    return true;
}

bool startsReadonlyLoopKeyword(const Simple s) pure
{
    return s.words.length && isLoopKeyword(s.words[0]) && ["if", "for", "select", "while", "until", "case", "!", "{",
        "do", "then", "else", "elif", "fi", "done", "esac", "}"].canFind(s.words[0].text);
}

void validateLoopHeader(const Simple simple, size_t offset, string kind)
{
    auto bad = format("cannot inspect `%s` loop header `%s`; only `for NAME [in WORDS]` loops are supported "
        ~ "(arithmetic `for ((...))` loops are not)", kind, commandText(simple));
    if (offset + 1 >= simple.words.length) throw new Blocked(bad);
    auto variable = simple.words[offset + 1];
    if (variable.dynamic || variable.quoted || !isShellIdentifier(variable.text)) throw new Blocked(bad);
    if (dangerousLoopAssignments.canFind(variable.text))
        throw new Blocked(format("cannot allow `%s` loop: header `%s` binds `%s`, which can change what the loop's "
            ~ "commands run; rewrite it as explicit commands", kind, commandText(simple), variable.text));
}

void checkLoopSideEffects(const Simple cmd, string kind, string phase)
{
    auto rendered = commandText(cmd);
    foreach (r; cmd.redirects)
        if (isWriteRedirect(r.op) && !isSafeLoopRedirect(r))
            throw new Blocked(format("cannot allow `%s` loop: %s command `%s` writes via redirection `%s %s`; keep the "
                ~ "loop free of file-writing redirections or rewrite it as explicit commands", kind, phase, rendered,
                r.op, r.target.text));
    foreach (h; cmd.heredocs)
    {
        if (h.expand && (h.body.canFind("$(") || h.body.canFind('`')))
            throw new Blocked(format("cannot allow `%s` loop: %s command `%s` uses a command substitution in an "
                ~ "expanding here-document; move that work out of the loop or rewrite it as explicit commands",
                kind, phase, rendered));
        if (h.expand && heredocBodyAssigns(h.body))
            throw new Blocked(format("cannot allow `%s` loop: %s command `%s` assigns a shell variable via an "
                ~ "expansion in an expanding here-document; move that assignment out of the loop or rewrite it as "
                ~ "explicit commands", kind, phase, rendered));
    }
    foreach (w; cmd.words.dup ~ cmd.redirects.map!(r => r.target).array)
        if (w.assigns)
            throw new Blocked(format("cannot allow `%s` loop: %s command `%s` assigns a shell variable via expansion "
                ~ "`%s`; move that assignment out of the loop or rewrite it as explicit commands", kind, phase,
                rendered, w.text));
}

bool isSafeLoopRedirect(const Redirect r) pure
{
    if (r.target.dynamic) return false;
    auto t = r.target.text;
    return safeDevices.canFind(t) || (r.op == ">&" && (t == "-" || (t.length && allDigits(t))));
}

immutable string[] readonlyLoopCommands = ["echo", "printf", "grep", "egrep", "fgrep", "wc", "cat", "head", "tail",
    "ls", "stat", "file", "basename", "dirname", "read", "test", "[", "[[", "true", "false", ":", "pwd", "break",
    "continue", "sort"];

immutable string[] dangerousLoopAssignments = ["PATH", "LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH",
    "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "GREP_OPTIONS"];

immutable string[] loopExecCommands = ["bash", "sh", "zsh", "dash", "ksh", "ash", "mksh", "fish", "eval", "exec",
    "source", ".", "ssh", "xargs"];

immutable string[] arithTestOps = ["-eq", "-ne", "-lt", "-le", "-gt", "-ge"];

/// Classify one loop command. Throws `Blocked` for a hard block (a dynamic
/// program, an interpreter, a dangerous assignment, a write, ...); returns the
/// reason when the program is static but not a known read-only utility, so the
/// loop cannot be verified automatically (an interactive session may ask);
/// null when the command is provably read-only.
string checkReadonlyLoopCommand(const Simple cmd, string kind, string phase)
{
    checkLoopSideEffects(cmd, kind, phase);
    auto rendered = commandText(cmd);
    string fail(string what) { return format("cannot allow `%s` loop: %s command `%s` %s", kind, phase, rendered, what); }
    auto unknown = fail("is not a known read-only command; keep the loop body to read-only commands like "
        ~ "`echo`, `grep`, `cat` and `wc`, or rewrite it as explicit commands");
    string assignmentName(string text)
    {
        auto name = text[0 .. (text.indexOf('=') < 0 ? text.length : text.indexOf('='))];
        while (name.endsWith("+")) name = name[0 .. $ - 1];
        if (name.indexOf('[') >= 0) name = name[0 .. name.indexOf('[')];
        return name;
    }
    void checkArithSubscript(string text)
    {
        size_t idLen = 0;
        while (idLen < text.length && (text[idLen] == '_' || (text[idLen] >= 'a' && text[idLen] <= 'z')
                || (text[idLen] >= 'A' && text[idLen] <= 'Z') || (text[idLen] >= '0' && text[idLen] <= '9')))
            ++idLen;
        if (idLen < text.length && text[idLen] == '[')
        {
            auto close = text[idLen + 1 .. $].indexOf(']');
            if (close >= 0 && arithmeticAssigns(text[idLen + 1 .. idLen + 1 + close]))
                throw new Blocked(fail(format("assigns a shell variable through the arithmetic array subscript of `%s`; "
                    ~ "rewrite it as explicit commands", text)));
        }
    }
    void checkDangerous(string name)
    {
        if (dangerousLoopAssignments.canFind(name))
            throw new Blocked(fail(format("assigns `%s`, which can change what the loop's commands run; rewrite it as "
                ~ "explicit commands", name)));
    }
    size_t i = 0;
    while (i < cmd.words.length && isAssignment(cmd.words[i].text))
    {
        checkArithSubscript(cmd.words[i].text);
        checkDangerous(assignmentName(cmd.words[i].text));
        ++i;
    }
    if (i >= cmd.words.length) return null;
    // Validate the original program word before dispatching on its basename:
    // `$CMD`, a glob (`s?`) or `/tmp/env` is not a known wrapper whatever its
    // basename spells.
    auto first = cmd.words[i];
    if (first.dynamic) throw new Blocked(fail("runs a command computed at run time; rewrite it as explicit commands"));
    enum globProgram = "runs a program name the shell expands as a glob at run time; rewrite it as explicit commands";
    static bool globText(string t) pure
    {
        return t != "[" && t != "[[" && (t.canFind('*') || t.canFind('?') || t.canFind('['));
    }
    if (globText(first.text)) throw new Blocked(fail(globProgram));
    if (first.text.canFind('/'))
    {
        auto parent = first.text[0 .. first.text.lastIndexOf('/')];
        if (parent != "/bin" && parent != "/usr/bin")
            throw new Blocked(fail(format("runs path-qualified program `%s`, which cannot be verified as a read-only "
                ~ "utility", first.text)));
    }
    auto programIndex = i;
    bool qualified = first.text.canFind('/');
    switch (basename(first.text))
    {
    case "builtin":
        if (!qualified) programIndex = i + 1;
        break;
    case "command":
        if (qualified) break;
        auto j = i + 1;
        while (j < cmd.words.length && cmd.words[j].text == "-p") ++j;
        if (j < cmd.words.length && (cmd.words[j].text == "-v" || cmd.words[j].text == "-V")) return null;
        if (j < cmd.words.length && cmd.words[j].text == "--") ++j;
        else if (j < cmd.words.length && cmd.words[j].text.startsWith("-") && cmd.words[j].text.length > 1)
            throw new Blocked(fail("uses unsupported `command` options; rewrite it as explicit commands"));
        programIndex = j;
        break;
    case "export", "local", "declare", "typeset", "readonly":
        // A declaration builtin's arguments are assignments: validate each
        // exactly as a leading one before the unverifiable verdict.
        foreach (w; cmd.words[i + 1 .. $])
        {
            if (!isAssignment(w.text)) continue;
            checkArithSubscript(w.text);
            checkDangerous(assignmentName(w.text));
        }
        return unknown;
    case "env":
        // `env` applies `NAME=value` words then runs its argument; `--` ends
        // option processing, not the assignments.
        auto j = i + 1;
        bool optionsDone = false;
        while (j < cmd.words.length)
        {
            auto t = cmd.words[j].text;
            if (!optionsDone && t == "--") { optionsDone = true; ++j; continue; }
            if (!optionsDone)
            {
                if (t == "-u" || t == "-C" || t == "--unset" || t == "--chdir") { j += 2; continue; }
                // Every other option is unmodeled (an attached `-S'...'` would
                // hide a command): reject rather than skip.
                if (t.startsWith("-") && t.length > 1)
                    throw new Blocked(fail("uses an `env` option that cannot be inspected; rewrite it as explicit commands"));
            }
            if (isAssignment(t))
            {
                checkDangerous(assignmentName(t));
                ++j;
                continue;
            }
            break;
        }
        programIndex = j;
        break;
    // Command transformers run their argument as a program: resolve them as
    // `expand()` does so the effective command faces the loop checks.
    case "timeout": programIndex = skipOptions(cmd.words, i + 1, "sk", timeoutLongWithValue) + 1; break;
    case "nice": programIndex = skipOptions(cmd.words, i + 1, "n", []); break;
    case "sudo", "doas": programIndex = skipOptions(cmd.words, i + 1, "ugCDhprtUTR", sudoLongWithValue); break;
    case "stdbuf": programIndex = skipOptions(cmd.words, i + 1, "ioe", []); break;
    case "setsid", "caffeinate", "nohup", "unbuffer", "busybox":
        programIndex = skipOptions(cmd.words, i + 1, "", []);
        break;
    case "coproc": throw new Blocked(fail("starts a coprocess that cannot be inspected"));
    case "ionice": programIndex = skipOptions(cmd.words, i + 1, "cnpt", []); break;
    case "chrt":
        auto j = skipOptions(cmd.words, i + 1, "", []);
        if (j < cmd.words.length && allDigits(cmd.words[j].text)) ++j;
        programIndex = j;
        break;
    default:
    }
    if (programIndex >= cmd.words.length) throw new Blocked(fail("does not name a command to inspect"));
    // A wrapper only selects how the effective command is found: classify the
    // unwrapped remainder recursively (each step consumes at least one word).
    if (programIndex > i) return checkReadonlyLoopCommand(withWords(cmd, cmd.words[programIndex .. $]), kind, phase);
    auto programWord = cmd.words[programIndex];
    if (programWord.dynamic)
        throw new Blocked(fail("runs a command computed at run time; rewrite it as explicit commands"));
    if (globText(programWord.text)) throw new Blocked(fail(globProgram));
    auto programText = programWord.text;
    auto program = basename(programText);
    if (programText.canFind('/'))
    {
        auto parent = programText[0 .. programText.lastIndexOf('/')];
        if (parent != "/bin" && parent != "/usr/bin")
            throw new Blocked(fail(format("runs path-qualified program `%s`, which cannot be verified as a read-only "
                ~ "utility", programText)));
    }
    if (loopExecCommands.canFind(program) || interpreters.any!(p => program.startsWith(p)))
        throw new Blocked(fail("runs an interpreter, shell, or other dynamic command; rewrite it as explicit commands"));
    if (!readonlyLoopCommands.canFind(program)) return unknown;
    auto args = cmd.words[programIndex + 1 .. $];
    if ((program == "[[" || program == "[" || program == "test") && args.any!(w => arithTestOps.canFind(w.text)))
        foreach (w; args)
            if (arithmeticAssigns(w.text))
                throw new Blocked(fail(format("runs an arithmetic test whose operand `%s` assigns a shell variable; "
                    ~ "rewrite it as explicit commands", w.text)));
    enum abbrevValue = "abbreviates a `%s` option that takes a value; GNU resolves the prefix, but its value cannot "
        ~ "be told from the `--` terminator — spell the option in full or rewrite the loop as explicit commands";
    switch (program)
    {
    case "sort":
        if (hasShortOption(args, 'o', sortShortWithValue, sortLongWithValue)
            || hasLongOption(args, "--output", sortShortWithValue, sortLongWithValue)
            || hasLongOption(args, "--compress-program", sortShortWithValue, sortLongWithValue)
            || hasAbbreviatedLongOption(args, ["output", "compress-program"], sortShortWithValue, sortLongWithValue))
            throw new Blocked(fail("uses a `sort` option that writes a file or runs another program"));
        if (hasAbbreviatedValueOption(args, sortLongWithValue)) throw new Blocked(fail(format(abbrevValue, "sort")));
        checkLoopDynamicOptionPosition(args, cmd, kind, phase, program);
        break;
    case "file":
        if (hasShortOption(args, 'C', fileShortWithValue, fileLongWithValue)
            || hasLongOption(args, "--compile", fileShortWithValue, fileLongWithValue)
            || hasAbbreviatedLongOption(args, ["compile"], fileShortWithValue, fileLongWithValue))
            throw new Blocked(fail("uses a `file` option that writes a compiled magic file"));
        if (hasAbbreviatedValueOption(args, fileLongWithValue)) throw new Blocked(fail(format(abbrevValue, "file")));
        checkLoopDynamicOptionPosition(args, cmd, kind, phase, program);
        break;
    case "read": checkLoopReadDestinations(args, kind, phase, rendered); break;
    case "printf": checkLoopPrintfDestination(args, kind, phase, rendered); break;
    default:
    }
    return null;
}

void rejectDangerousLoopDestination(const Word name, string kind, string phase, string rendered, string builtin)
{
    if (name.dynamic || name.quoted || name.glob)
        throw new Blocked(format("cannot allow `%s` loop: %s command `%s` writes a shell variable with `%s` whose name "
            ~ "is computed at run time or produced by filename expansion; rewrite it as explicit commands",
            kind, phase, rendered, builtin));
    auto base = name.text.indexOf('[') >= 0 ? name.text[0 .. name.text.indexOf('[')] : name.text;
    if (dangerousLoopAssignments.canFind(base))
        throw new Blocked(format("cannot allow `%s` loop: %s command `%s` writes `%s` with `%s`, which can change what "
            ~ "the loop's commands run; rewrite it as explicit commands", kind, phase, rendered, base, builtin));
}

private bool readOptionTakesValue(dchar c) pure { return "adinNptu".canFind(c); }

void checkLoopReadDestinations(const Word[] args, string kind, string phase, string rendered)
{
    auto uninspectable = format("cannot allow `%s` loop: %s command `%s` uses a `read` option that cannot be "
        ~ "inspected; rewrite it as explicit commands", kind, phase, rendered);
    size_t i = 0;
    while (i < args.length)
    {
        auto arg = args[i];
        auto text = arg.text;
        if (text == "--") { ++i; break; }
        if (!(text.startsWith("-") && text.length > 1)) break;
        if (arg.dynamic || arg.glob) throw new Blocked(uninspectable);
        import std.conv : to;
        auto letters = text[1 .. $].to!(dchar[]);
        size_t k = 0;
        while (k < letters.length)
        {
            auto letter = letters[k];
            if (letter == 'a')
            {
                if (k + 1 < letters.length)
                {
                    Word n;
                    n.text = letters[k + 1 .. $].to!string;
                    rejectDangerousLoopDestination(n, kind, phase, rendered, "read");
                }
                else
                {
                    ++i;
                    if (i >= args.length) throw new Blocked(uninspectable);
                    rejectDangerousLoopDestination(args[i], kind, phase, rendered, "read");
                }
                k = letters.length;
            }
            else if (readOptionTakesValue(letter))
            {
                if (k + 1 >= letters.length)
                {
                    ++i;
                    if (i >= args.length || args[i].splits) throw new Blocked(uninspectable);
                }
                k = letters.length;
            }
            else if (letter == 'r' || letter == 's' || letter == 'e') ++k;
            else throw new Blocked(uninspectable);
        }
        ++i;
    }
    foreach (name; args[(i < args.length ? i : args.length) .. $])
        rejectDangerousLoopDestination(name, kind, phase, rendered, "read");
}

void checkLoopPrintfDestination(const Word[] args, string kind, string phase, string rendered)
{
    string fail(string what) { return format("cannot allow `%s` loop: %s command `%s` %s", kind, phase, rendered, what); }
    size_t i = 0;
    while (i < args.length)
    {
        auto arg = args[i];
        auto text = arg.text;
        if (text == "--") { ++i; break; }
        if (!text.startsWith("-")) break;
        if (arg.dynamic || arg.glob)
            throw new Blocked(fail("passes a computed or glob argument to `printf` where it could be read as an option; "
                ~ "rewrite it as explicit commands"));
        if (text == "-v")
        {
            if (i + 1 >= args.length)
                throw new Blocked(fail("uses `printf -v` without a destination; rewrite it as explicit commands"));
            rejectDangerousLoopDestination(args[i + 1], kind, phase, rendered, "printf");
            i += 2;
            continue;
        }
        if (text.startsWith("-v"))
        {
            Word n;
            n.text = text[2 .. $];
            n.dynamic = arg.dynamic;
            n.glob = arg.glob;
            rejectDangerousLoopDestination(n, kind, phase, rendered, "printf");
            ++i;
            continue;
        }
        if (text.length > 1) { ++i; continue; }
        break;
    }
    if (i < args.length)
    {
        auto fmt = args[i];
        if (fmt.glob)
            throw new Blocked(fail("runs `printf` with a format produced by filename expansion, which could write shell "
                ~ "variables; rewrite it as explicit commands"));
        if (fmt.dynamic)
            throw new Blocked(fail("runs `printf` with a format computed at run time, which could write shell variables; "
                ~ "rewrite it as explicit commands"));
        if (printfFormatWrites(fmt.text))
            throw new Blocked(fail("uses a `printf` `%n` conversion that writes a shell variable; rewrite it as explicit "
                ~ "commands"));
    }
}

/// Whether a `printf` format contains a `%n` conversion (`%%` is literal).
bool printfFormatWrites(string fmt) pure
{
    size_t i = 0;
    while (i < fmt.length)
    {
        if (fmt[i] != '%') { ++i; continue; }
        ++i;
        if (i >= fmt.length) break;
        if (fmt[i] == '%') { ++i; continue; }
        while (i < fmt.length && ("-+ #'.*".canFind(fmt[i]) || (fmt[i] >= '0' && fmt[i] <= '9'))) ++i;
        while (i < fmt.length && "lhLjztq".canFind(fmt[i])) ++i;
        if (i < fmt.length && fmt[i] == 'n') return true;
    }
    return false;
}

// ---- option scanning ----------------------------------------------------------

enum sortShortWithValue = "kotTS";
immutable string[] sortLongWithValue = ["--batch-size", "--buffer-size", "--compress-program", "--files0-from", "--key",
    "--output", "--random-source", "--separator", "--temporary-directory"];
enum fileShortWithValue = "mMfFe";
immutable string[] fileLongWithValue = ["--magic-file", "--exclude", "--exclude-quiet", "--separator"];

/// Whether a value-taking short option is the last letter of its bundle.
bool shortConsumesNext(string text, string shortWithValue) pure
{
    import std.utf : count;
    auto opts = text[1 .. $];
    size_t pos = 0;
    foreach (dchar c; opts)
    {
        if (shortWithValue.canFind(c)) return pos + 1 == opts.count;
        ++pos;
    }
    return false;
}

private bool consumesNext(string text, string shortWithValue, const string[] longWithValue) pure
{
    if (text.startsWith("--")) return !text[2 .. $].canFind('=') && longWithValue.canFind(text);
    return shortConsumesNext(text, shortWithValue);
}

/// The option-position words of a `sort`/`file` invocation.
const(Word)[] optionPositionWords(const Word[] args, string shortWithValue, const string[] longWithValue) pure
{
    const(Word)[] out_;
    size_t i = 0;
    while (i < args.length)
    {
        auto arg = args[i];
        auto text = arg.text;
        if (text == "--") break;
        if (arg.dynamic || arg.glob) { out_ ~= arg; ++i; continue; }
        if (!text.startsWith("-") || text == "-") { ++i; continue; }
        out_ ~= arg;
        i += consumesNext(text, shortWithValue, longWithValue) ? 2 : 1;
    }
    return out_;
}

const(Word)[] optionWords(const Word[] args, string shortWithValue, const string[] longWithValue) pure
{
    return optionPositionWords(args, shortWithValue, longWithValue).filter!(a => !a.dynamic && !a.glob).array;
}

void checkLoopDynamicOptionPosition(const Word[] args, const Simple cmd, string kind, string phase, string program)
{
    string short_ = program == "sort" ? sortShortWithValue : program == "file" ? fileShortWithValue : "";
    const string[] long_ = program == "sort" ? sortLongWithValue : program == "file" ? fileLongWithValue : [];
    auto err = format("cannot allow `%s` loop: %s command `%s` passes a computed or glob argument to `%s` where it "
        ~ "could be read as an option; put `--` before it or rewrite the loop as explicit commands",
        kind, phase, commandText(cmd), program);
    if (hasAbbreviatedValueOption(args, long_)) throw new Blocked(err);
    size_t i = 0;
    while (i < args.length)
    {
        auto arg = args[i];
        auto text = arg.text;
        if (text == "--") break;
        if (arg.dynamic || arg.glob) throw new Blocked(err);
        if (!text.startsWith("-") || text == "-") { ++i; continue; }
        if (consumesNext(text, short_, long_))
        {
            if (i + 1 < args.length && args[i + 1].splits) throw new Blocked(err);
            i += 2;
        }
        else ++i;
    }
}

bool hasShortOption(const Word[] args, dchar letter, string shortWithValue, const string[] longWithValue) pure
{
    foreach (arg; optionWords(args, shortWithValue, longWithValue))
    {
        if (!arg.text.startsWith("-") || arg.text.startsWith("--") || arg.text.length < 2) continue;
        foreach (dchar c; arg.text[1 .. $])
        {
            if (c == letter) return true;
            if (shortWithValue.canFind(c)) break;
        }
    }
    return false;
}

bool hasLongOption(const Word[] args, string name, string shortWithValue, const string[] longWithValue) pure
{
    return optionWords(args, shortWithValue, longWithValue).any!(a => a.text == name || a.text.startsWith(name ~ "="));
}

private string longName(string text) pure
{
    auto body = text[2 .. $];
    auto eq = body.indexOf('=');
    return eq < 0 ? body : body[0 .. eq];
}

bool hasAbbreviatedLongOption(const Word[] args, const string[] dangerous, string shortWithValue,
    const string[] longWithValue) pure
{
    foreach (arg; optionWords(args, shortWithValue, longWithValue))
    {
        if (!arg.text.startsWith("--")) continue;
        auto name = longName(arg.text);
        if (name.length && dangerous.any!(full => full.startsWith(name))) return true;
    }
    return false;
}

bool hasAbbreviatedValueOption(const Word[] args, const string[] longWithValue) pure
{
    foreach (arg; optionWords(args, "", longWithValue))
    {
        if (!arg.text.startsWith("--")) continue;
        auto name = longName(arg.text);
        if (name.length && longWithValue.any!(f => f.startsWith("--") && f.length - 2 > name.length
                && f[2 .. $].startsWith(name)))
            return true;
    }
    return false;
}

/// The inline script an interpreter runs via `-c`/`-e`/`--eval`, if any.
bool interpreterInlineScript(const Word[] args, out Word script) pure
{
    foreach (i, arg; args)
    {
        auto t = arg.text;
        if (["-c", "-e", "-E", "-r", "--eval", "eval"].canFind(t))
        {
            if (i + 1 >= args.length) return false;
            script = args[i + 1];
            return true;
        }
        if ((t.startsWith("-c") || t.startsWith("-e") || t.startsWith("-E") || t.startsWith("-r")) && t.length > 2)
        {
            script.text = t[2 .. $];
            script.dynamic = arg.dynamic;
            return true;
        }
        if (t.startsWith("--eval="))
        {
            script.text = t[7 .. $];
            script.dynamic = arg.dynamic;
            return true;
        }
    }
    return false;
}

// ---- wrappers and containers --------------------------------------------------

immutable string[] sudoLongWithValue = ["--user", "--group", "--chdir", "--role", "--type", "--prompt", "--host",
    "--close-from", "--command-timeout"];
immutable string[] xargsLongWithValue = ["--max-args", "--max-chars", "--max-lines", "--max-procs", "--delimiter",
    "--arg-file", "--process-slot-var"];
immutable string[] timeoutLongWithValue = ["--kill-after", "--signal"];
immutable string[] dockerLongWithValue = ["--env", "--user", "--workdir", "--volume", "--publish", "--name",
    "--network", "--net", "--hostname", "--entrypoint", "--env-file", "--label", "--label-file", "--mount",
    "--add-host", "--device", "--dns", "--expose", "--link", "--log-driver", "--restart", "--memory", "--cpus",
    "--platform", "--detach-keys", "--volumes-from", "--tmpfs", "--ulimit", "--sysctl", "--cap-add", "--cap-drop",
    "--security-opt", "--pid", "--ipc", "--uts", "--group-add", "--health-cmd", "--stop-signal", "--stop-timeout",
    "--pull", "--attach", "--cidfile"];

/// Index of the command `docker|podman [container] exec|run ... CMD` runs.
bool containerCommandStart(const Word[] words, size_t from, out size_t start) pure
{
    if (from < words.length && words[from].text == "container") ++from;
    if (!(from < words.length && (words[from].text == "exec" || words[from].text == "run"))) return false;
    ++from;
    start = skipOptions(words, from, "eupvwmhl", dockerLongWithValue) + 1;
    return start < words.length;
}

/// A `-v`/`--volume`/`--mount` spec that bind-mounts a host path.
bool mountBindsHost(string spec) pure
{
    static bool pathLike(string s) pure { return s.startsWith("/") || s.startsWith(".") || s.startsWith("~"); }
    if (spec.canFind("type=bind")) return true;
    if (spec.canFind("source=") || spec.canFind("src="))
    {
        foreach (kv; spec.split(","))
        {
            if (kv.startsWith("source=") && pathLike(kv[7 .. $])) return true;
            if (kv.startsWith("src=") && pathLike(kv[4 .. $])) return true;
        }
        return false;
    }
    auto colon = spec.indexOf(':');
    return colon >= 0 && pathLike(spec[0 .. colon]);
}

/// Why a container invocation escapes the sandbox, or null.
string containerEscape(const Word[] words, size_t from) pure
{
    if (from < words.length && words[from].text == "container") ++from;
    if (!(from < words.length && (words[from].text == "exec" || words[from].text == "run"))) return null;
    ++from;
    auto i = from;
    while (i < words.length)
    {
        auto text = words[i].text;
        if (text == "--" || !text.startsWith("-") || text == "-") break;
        auto eq = text.indexOf('=');
        string name = eq >= 0 ? text[0 .. eq] : text;
        bool hasInline = eq >= 0;
        bool hasValue = hasInline || i + 1 < words.length;
        string value = hasInline ? text[eq + 1 .. $] : (i + 1 < words.length ? words[i + 1].text : null);
        if (name == "--privileged") return "--privileged";
        if (name == "--device" || name == "--cap-add" || name == "--security-opt") return name;
        if ((name == "-v" || name == "--volume" || name == "--mount") && hasValue && mountBindsHost(value))
            return format("host bind mount `%s`", value);
        if (["--pid", "--ipc", "--uts", "--userns", "--cgroupns", "--network", "--net"].canFind(name) && hasValue
            && (value == "host" || value.endsWith(":host") || value.endsWith("=host")))
            return format("%s host namespace", name);
        bool consumes = !hasInline && (name.startsWith("--")
            ? dockerLongWithValue.canFind(name)
            : shortConsumesNext(name, "eupvwmhl"));
        i += consumes ? 2 : 1;
    }
    return null;
}

size_t skipOptions(const Word[] words, size_t i, string withValue, const string[] longWithValue) pure
{
    while (i < words.length)
    {
        auto text = words[i].text;
        if (text == "--") return i + 1;
        if (!text.startsWith("-") || text == "-") break;
        bool consume = text.startsWith("--")
            ? !text.canFind('=') && longWithValue.canFind(text)
            : shortConsumesNext(text, withValue);
        i += consume ? 2 : 1;
    }
    return i;
}


/// Strip assignments, keywords and wrappers (`sudo`, `env`, `timeout`,
/// `xargs`, ...), and look inside `bash -c`, `eval`, `ssh host CMD`,
/// `find -exec` and here-documents fed to a shell, so guards and rules see
/// the commands that actually run.
void expand(const Simple simple, size_t depth, ref Simple[] out_)
{
    auto words = simple.words;
    inspectHeredocs(simple, depth, out_);
    size_t i = 0;
    void push(size_t from) { out_ ~= withWords(simple, words[(from < words.length ? from : words.length) .. $]); }
    const(Word)[] rest(size_t from) { return from < words.length ? words[from .. $] : []; }
    while (true)
    {
        if (i >= words.length)
        {
            // An assignment-only command keeps its static binding for the
            // guard's dataflow; a dynamic/glob value is dropped (the name is
            // marked assigned-at-run-time instead).
            push(words.all!(w => !w.dynamic && !w.glob) ? 0 : i);
            return;
        }
        auto text = words[i].text;
        if (isAssignment(text)) { ++i; continue; }
        switch (basename(text))
        {
        case "!", "if", "then", "else", "elif", "do", "while", "until", "{", "}", "fi", "done", "esac", "coproc",
            "nohup", "builtin", "unbuffer", "busybox":
            ++i;
            break;
        case "[[":
            push(i);
            return;
        case "for", "select":
            throw new Blocked(format("cannot analyze `%s` loop variables safely; rewrite the loop as explicit commands", text));
        case "function": i += 2; break;
        case "time": i = skipOptions(words, i + 1, "", []); break;
        case "command":
            if (i + 1 < words.length && (words[i + 1].text == "-v" || words[i + 1].text == "-V")) return;
            i = skipOptions(words, i + 1, "", []);
            break;
        case "exec": i = skipOptions(words, i + 1, "a", []); break;
        case "sudo", "doas": i = skipOptions(words, i + 1, "ugCDhprtUTR", sudoLongWithValue); break;
        case "nice": i = skipOptions(words, i + 1, "n", []); break;
        case "ionice": i = skipOptions(words, i + 1, "cnpt", []); break;
        case "stdbuf": i = skipOptions(words, i + 1, "ioe", []); break;
        case "setsid": i = skipOptions(words, i + 1, "", []); break;
        case "caffeinate": i = skipOptions(words, i + 1, "tw", []); break;
        case "xargs": i = skipOptions(words, i + 1, "InPLdEsa", xargsLongWithValue); break;
        case "chrt":
            i = skipOptions(words, i + 1, "", []);
            if (i < words.length && allDigits(words[i].text)) ++i;
            break;
        case "timeout":
            i = skipOptions(words, i + 1, "sk", timeoutLongWithValue);
            ++i; // duration
            break;
        case "env":
            auto j = i + 1;
            envLoop: while (j < words.length)
            {
                auto t = words[j].text;
                switch (t)
                {
                case "--": ++j; break envLoop;
                case "-u", "-C", "--unset", "--chdir": j += 2; break;
                case "-S", "--split-string":
                    parseInner(scriptText(rest(j + 1)), depth, out_);
                    return;
                default:
                    // An attached or `=`-joined split-string carries its
                    // script in this same word.
                    if (t.startsWith("-S") && t.length > 2)
                    {
                        parseInner(t[2 .. $], depth, out_);
                        return;
                    }
                    if (t.startsWith("--split-string="))
                    {
                        parseInner(t["--split-string=".length .. $], depth, out_);
                        return;
                    }
                    if (t.startsWith("-") || isAssignment(t)) ++j;
                    else break envLoop;
                }
            }
            i = j;
            break;
        case "watch":
            auto j = skipOptions(words, i + 1, "nq", []);
            if (!rest(j).length) return;
            parseInner(scriptText(rest(j)), depth, out_);
            return;
        case "eval":
            parseInner(scriptText(rest(i + 1)), depth, out_);
            return;
        case "ssh":
            auto j = skipOptions(words, i + 1, "bcDEeFIiJLlmOoPpQRSWw", []) + 1; // host
            push(i);
            if (!rest(j).length) return;
            parseInner(scriptText(rest(j)), depth, out_);
            return;
        case "bash", "sh", "zsh", "dash", "ksh", "ash", "mksh", "fish":
            expandShell(simple, i, depth, out_);
            return;
        case "docker", "podman":
            push(i);
            auto reason = containerEscape(words, i + 1);
            if (reason !is null)
                throw new Blocked(format("container invocation escapes the sandbox via %s: the container runtime performs "
                    ~ "this write as a separate, unsandboxed process — remove host bind mounts, privileged/host-namespace, "
                    ~ "device and capability options", reason));
            if (depth >= maxExpandDepth) return;
            size_t start;
            if (containerCommandStart(words, i + 1, start)) expand(bare(words[start .. $]), depth + 1, out_);
            return;
        case "find":
            push(i);
            auto j = i + 1;
            while (j < words.length)
            {
                if (["-exec", "-execdir", "-ok", "-okdir"].canFind(words[j].text))
                {
                    auto start = j + 1;
                    auto end = start;
                    while (end < words.length && words[end].text != ";" && words[end].text != "+") ++end;
                    expand(bare(words[start .. end]), depth + 1, out_);
                    j = end;
                }
                ++j;
            }
            return;
        default:
            push(i);
            return;
        }
    }
}

/// `bash [options] [-c SCRIPT | FILE | <<HEREDOC]`
void expandShell(const Simple simple, size_t at, size_t depth, ref Simple[] out_)
{
    auto words = simple.words;
    out_ ~= withWords(simple, words[at .. $]);
    auto j = at + 1;
    while (j < words.length)
    {
        auto word = words[j];
        auto text = word.text;
        if (text == "--" || text == "-") { ++j; break; }
        if (!(text.startsWith("-") || text.startsWith("+"))) break;
        if (text.startsWith("--"))
        {
            j += (text == "--rcfile" || text == "--init-file") ? 2 : 1;
            continue;
        }
        auto pos = text[1 .. $].indexOf('c');
        if (pos >= 0)
        {
            auto attached = text[1 + pos + 1 .. $];
            if (!attached.length)
            {
                if (j + 1 < words.length) parseInner(scriptText(words[j + 1 .. j + 2]), depth, out_);
            }
            else
            {
                Word script;
                script.text = attached;
                script.dynamic = word.dynamic;
                parseInner(scriptText([script]), depth, out_);
            }
            return;
        }
        j += (text.endsWith("o") || text.endsWith("O")) ? 2 : 1;
    }
    if (j >= words.length)
    {
        bool inspectedStdin = false;
        foreach (h; simple.heredocs)
        {
            parseInner(h.body, depth, out_);
            inspectedStdin = true;
        }
        foreach (r; simple.redirects)
            if (r.op == "<<<")
            {
                parseInner(scriptText([r.target]), depth, out_);
                inspectedStdin = true;
            }
        bool fromFile = simple.redirects.any!(r => r.op == "<" || r.op == "0<");
        if (fromFile || !inspectedStdin)
            throw new Blocked(format("`%s` reads its script from standard input (a pipe or file redirect) that cannot be "
                ~ "inspected; pass the script via `-c` or a here-document so it can be checked", words[at].text));
    }
}

/// Inspect expanding here-document bodies for command substitutions the
/// parent shell runs before the command starts.
void inspectHeredocs(const Simple simple, size_t depth, ref Simple[] out_)
{
    foreach (h; simple.heredocs)
        if (h.expand && (h.body.canFind("$(") || h.body.canFind('`')))
            parseInner(h.body, depth, out_);
}

// ---- assignment / loop-binding collection (used by the guard) -------------------

/// A variable's value as far as static analysis knows it.
struct Known
{
    bool known;
    string value;
}

/// Script texts nested inside `simple` that the shell runs (deliberately
/// permissive; used only to collect assignments).
string[] nestedScripts(const Simple simple)
{
    auto words = simple.words;
    string[] scripts;
    foreach (h; simple.heredocs) scripts ~= h.body;
    size_t i = 0;
    while (i < words.length)
    {
        auto b = basename(words[i].text);
        if (b == "eval")
        {
            try scripts ~= scriptText(i + 1 < words.length ? words[i + 1 .. $] : []);
            catch (Blocked) {}
            break;
        }
        if (["bash", "sh", "zsh", "dash", "ksh", "ash", "mksh", "fish"].canFind(b))
        {
            auto j = i + 1;
            while (j < words.length)
            {
                auto t = words[j].text;
                if (!(t.startsWith("-") || t.startsWith("+")) || t == "--" || t == "-") break;
                auto pos = t[1 .. $].indexOf('c');
                if (pos >= 0)
                {
                    auto attached = t[1 + pos + 1 .. $];
                    Word script;
                    bool have = true;
                    if (!attached.length)
                    {
                        if (j + 1 < words.length) script = words[j + 1];
                        else have = false;
                    }
                    else
                    {
                        script.text = attached;
                        script.dynamic = words[j].dynamic;
                    }
                    if (have)
                    {
                        try scripts ~= scriptText([script]);
                        catch (Blocked) {}
                    }
                    break;
                }
                ++j;
            }
            break;
        }
        ++i;
    }
    return scripts;
}

private immutable string[] declBuiltins = ["export", "local", "declare", "typeset", "readonly"];

/// The assignment dataflow of `commands` (the guard's original source, loop
/// headers and assignment words intact), recursing into nested scripts
/// (`bash -c`, `eval`, shell-fed here-docs) whose assignments stay in scope.
Known[string] assignments(const Simple[] commands)
{
    Known[string] out_;
    collectAssignments(commands, 0, out_);
    return out_;
}

void collectAssignments(const Simple[] commands, size_t depth, ref Known[string] out_)
{
    foreach (cmd; commands)
    {
        collectCommandAssignments(cmd, out_);
        if (depth >= maxExpandDepth) continue;
        foreach (script; nestedScripts(cmd))
        {
            Simple[] inner;
            try inner = parseNested(script, depth);
            catch (Exception) continue; // an unparsable nested script contributes no assignments
            collectAssignments(inner, depth + 1, out_);
        }
    }
}

void collectCommandAssignments(const Simple cmd, ref Known[string] out_)
{
    auto offset = loopCommandOffset(cmd.words);
    auto words = cmd.words[offset .. $];
    if (words.length && declBuiltins.canFind(words[0].text)) words = words[1 .. $];
    foreach (w; cmd.words)
        if (w.assigns)
        {
            auto name = expansionAssignedName(w.text);
            if (name !is null) out_[name] = Known(false, null);
        }
    foreach (w; words)
    {
        if (!isAssignment(w.text))
        {
            if (w.text.startsWith("-")) continue;
            break;
        }
        auto eq = w.text.indexOf('=');
        auto name = w.text[0 .. eq];
        auto value = w.text[eq + 1 .. $];
        bool append = name.endsWith("+");
        while (name.endsWith("+")) name = name[0 .. $ - 1];
        bool literal = !w.dynamic && !w.glob && !append;
        out_[name] = (name in out_ || !literal) ? Known(false, null) : Known(true, value);
    }
}

/// Names whose value cannot be trusted to a pre-loop literal, recursing into
/// nested scripts as `assignments` does.
bool[string] loopBoundVars(const Simple[] commands)
{
    bool[string] out_;
    collectLoopBoundVars(commands, 0, out_);
    return out_;
}

void collectLoopBoundVars(const Simple[] commands, size_t depth, ref bool[string] out_)
{
    size_t loopDepth = 0;
    foreach (cmd; commands)
    {
        auto offset = loopCommandOffset(cmd.words);
        string head = offset < cmd.words.length && isLoopKeyword(cmd.words[offset]) ? cmd.words[offset].text : null;
        bool startsLoop = head !is null && ["for", "select", "while", "until"].canFind(head);
        bool closesLoop = head == "done" && loopDepth > 0;
        if (startsLoop)
        {
            if ((head == "for" || head == "select") && offset + 1 < cmd.words.length)
            {
                auto v = cmd.words[offset + 1];
                if (!v.dynamic && !v.quoted && isShellIdentifier(v.text)) out_[v.text] = true;
            }
            if (head == "select") out_["REPLY"] = true;
            if (head == "while" || head == "until")
            {
                auto cond = cmd.words[offset + 1 .. $];
                auto co = loopCommandOffset(cond);
                collectLoopBodyWrites(cond[(co < cond.length ? co : cond.length) .. $], out_);
            }
            ++loopDepth;
            continue;
        }
        if (closesLoop) { --loopDepth; continue; }
        if (loopDepth > 0) collectLoopBodyWrites(cmd.words[offset .. $], out_);
        foreach (w; cmd.words)
            if (w.assigns)
            {
                auto name = expansionAssignedName(w.text);
                if (name !is null && isShellIdentifier(name)) out_[name] = true;
            }
        // A loop inside a nested script rebinds its variable for the
        // script's later commands.
        if (depth < maxExpandDepth)
            foreach (script; nestedScripts(cmd))
            {
                Simple[] inner;
                try inner = parseNested(script, depth);
                catch (Exception) continue; // an unparsable nested script binds no loop variables
                collectLoopBoundVars(inner, depth + 1, out_);
            }
    }
}

private string assignedName(string text) pure
{
    auto name = text[0 .. (text.indexOf('=') < 0 ? text.length : text.indexOf('='))];
    while (name.endsWith("+")) name = name[0 .. $ - 1];
    if (name.indexOf('[') >= 0) name = name[0 .. name.indexOf('[')];
    return name;
}

private void insertReferenced(const Word w, ref bool[string] out_)
{
    foreach (n; referencedVarNames(w.text)) insertVarName(n, out_);
}

/// Record every variable a loop-body command writes: assignments (including a
/// declaration builtin's arguments), nested loop headers, `read`/`printf -v`/
/// `mapfile`/`unset`/`getopts`/`env` destinations, implicit `PWD` writes, and
/// assigning expansions, seeing through `builtin`/`command` wrappers.
void collectLoopBodyWrites(const Word[] words, ref bool[string] out_)
{
    foreach (w; words)
        if (w.assigns)
        {
            auto name = expansionAssignedName(w.text);
            if (name !is null) insertVarName(name, out_);
        }
    size_t i = 0;
    if (i < words.length && isLoopKeyword(words[i]) && (words[i].text == "for" || words[i].text == "select"))
    {
        if (i + 1 < words.length && !words[i + 1].dynamic && !words[i + 1].quoted && isShellIdentifier(words[i + 1].text))
            out_[words[i + 1].text] = true;
        if (words[i].text == "select") out_["REPLY"] = true;
        return;
    }
    if (i < words.length && isLoopKeyword(words[i]) && (words[i].text == "while" || words[i].text == "until"))
    {
        auto cond = words[i + 1 .. $];
        auto co = loopCommandOffset(cond);
        collectLoopBodyWrites(cond[(co < cond.length ? co : cond.length) .. $], out_);
        return;
    }
    if (i < words.length && words[i].text == "builtin")
    {
        collectLoopBodyWrites(words[i + 1 .. $], out_);
        return;
    }
    if (i < words.length && words[i].text == "command")
    {
        auto j = i + 1;
        while (j < words.length && words[j].text == "-p") ++j;
        if (j < words.length && (words[j].text == "-v" || words[j].text == "-V")) return;
        if (j < words.length && words[j].text == "--") ++j;
        collectLoopBodyWrites(words[(j < words.length ? j : words.length) .. $], out_);
        return;
    }
    if (i < words.length && declBuiltins.canFind(words[i].text))
    {
        ++i;
        foreach (w; words[i .. $])
        {
            if (w.text == "--") continue;
            if (isAssignment(w.text))
            {
                auto name = assignedName(w.text);
                if (name.length) out_[name] = true;
            }
            else if (w.dynamic) insertReferenced(w, out_);
        }
    }
    while (i < words.length && isAssignment(words[i].text))
    {
        auto name = assignedName(words[i].text);
        if (name.length) out_[name] = true;
        ++i;
    }
    if (i >= words.length) return;
    auto args = words[i + 1 .. $];
    switch (basename(words[i].text))
    {
    case "read": collectReadDestinations(args, out_); break;
    case "printf": collectPrintfDestination(args, out_); break;
    case "mapfile", "readarray":
        static immutable valueOpts = ["-n", "-O", "-s", "-u", "-d", "-C", "-c", "--array-origin", "--line-count", "--skip"];
        size_t j = 0;
        while (j < args.length)
        {
            auto t = args[j].text;
            if (t == "--") { ++j; break; }
            if (t.startsWith("-") && t.length > 1) { j += valueOpts.canFind(t) ? 2 : 1; continue; }
            break;
        }
        if (j < args.length)
        {
            if (args[j].dynamic) insertReferenced(args[j], out_);
            else insertVarName(args[j].text, out_);
        }
        else out_["MAPFILE"] = true;
        break;
    case "unset":
        foreach (a; args)
        {
            if (a.text == "--" || (a.text.startsWith("-") && a.text.length > 1)) continue;
            if (a.dynamic) insertReferenced(a, out_);
            else insertVarName(a.text, out_);
        }
        break;
    case "cd", "pushd", "popd":
        out_["PWD"] = true;
        out_["OLDPWD"] = true;
        break;
    case "getopts":
        out_["OPTARG"] = true;
        out_["OPTIND"] = true;
        if (args.length > 1)
        {
            if (args[1].dynamic) insertReferenced(args[1], out_);
            else insertVarName(args[1].text, out_);
        }
        break;
    case "env":
        size_t j = 0;
        bool optionsDone = false;
        while (j < args.length)
        {
            auto t = args[j].text;
            if (!optionsDone && t == "--") { optionsDone = true; ++j; continue; }
            if (!optionsDone && (t == "-u" || t == "--unset"))
            {
                if (j + 1 < args.length) insertVarName(args[j + 1].text, out_);
                j += 2;
                continue;
            }
            if (!optionsDone && t.startsWith("-") && t.length > 1) { ++j; continue; }
            if (isAssignment(t))
            {
                auto name = assignedName(t);
                if (name.length) out_[name] = true;
                ++j;
                continue;
            }
            break;
        }
        break;
    default:
    }
}

void collectReadDestinations(const Word[] args, ref bool[string] out_)
{
    import std.conv : to;
    size_t i = 0;
    bool sawArray = false;
    while (i < args.length)
    {
        auto text = args[i].text;
        if (text == "--") { ++i; break; }
        if (!(text.startsWith("-") && text.length > 1)) break;
        auto letters = text[1 .. $].to!(dchar[]);
        size_t k = 0;
        while (k < letters.length)
        {
            auto letter = letters[k];
            if (letter == 'a')
            {
                sawArray = true;
                if (k + 1 < letters.length) insertVarName(letters[k + 1 .. $].to!string, out_);
                else
                {
                    ++i;
                    if (i < args.length) insertVarName(args[i].text, out_);
                }
                k = letters.length;
            }
            else if (readOptionTakesValue(letter))
            {
                if (k + 1 >= letters.length) ++i;
                k = letters.length;
            }
            else ++k;
        }
        ++i;
    }
    auto destinations = args[(i < args.length ? i : args.length) .. $];
    foreach (n; destinations) insertVarName(n.text, out_);
    if (!destinations.length && !sawArray) out_["REPLY"] = true;
}

void collectPrintfDestination(const Word[] args, ref bool[string] out_)
{
    size_t i = 0;
    while (i < args.length)
    {
        auto text = args[i].text;
        if (text == "--") break;
        if (text == "-v")
        {
            if (i + 1 < args.length) insertVarName(args[i + 1].text, out_);
            i += 2;
            continue;
        }
        if (text.startsWith("-v")) { insertVarName(text[2 .. $], out_); ++i; continue; }
        if (text.startsWith("-") && text.length > 1) { ++i; continue; }
        break;
    }
}

void insertVarName(string text, ref bool[string] out_)
{
    auto b = text.indexOf('[') >= 0 ? text[0 .. text.indexOf('[')] : text;
    if (isShellIdentifier(b)) out_[b] = true;
}

/// The variable name an assignment-capable expansion writes (first only).
string expansionAssignedName(string text) pure
{
    static string ident(string body) pure
    {
        size_t n = 0;
        while (n < body.length && (body[n] == '_' || (body[n] >= 'a' && body[n] <= 'z') || (body[n] >= 'A' && body[n] <= 'Z')
                || (body[n] >= '0' && body[n] <= '9')))
            ++n;
        auto name = body[0 .. n];
        return isShellIdentifier(name) ? name : null;
    }
    auto s = text.indexOf("$((");
    if (s >= 0) return ident(text[s + 3 .. $].stripLeft);
    s = text.indexOf("${");
    if (s >= 0) return ident(text[s + 2 .. $]);
    return null;
}

/// Every variable name `text` expands (`$d`, `${d}`, `${d:-x}`), used to
/// fail closed on a computed write destination (`declare "$d=/etc"`).
string[] referencedVarNames(string text)
{
    import std.regex : matchAll;
    static re = ctRegex!(`\$\{?([A-Za-z_][A-Za-z0-9_]*)`);
    string[] names;
    foreach (m; matchAll(text, re)) names ~= m[1];
    return names;
}

/// Whether `text` expands any of `names` (`$d`, `${d}`, `${d:-x}`).
bool referencesVars(string text, const bool[string] names)
{
    import std.regex : matchAll;
    if (!names.length) return false;
    static re = ctRegex!(`\$\{?([A-Za-z_][A-Za-z0-9_]*)`);
    foreach (m; matchAll(text, re))
        if (m[1] in names) return true;
    return false;
}
