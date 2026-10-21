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
    catch (Exception) return true;
}

/// Whether a `.git` directory exists at or below `root` (symlinks not
/// followed; a tree larger than the budget is treated as containing one).
bool containsGitDir(string root) @trusted
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
        catch (Exception) continue;
    }
    return false;
}

// ---- sequences and loops -------------------------------------------------------

Simple[] expandAll(const Simple[] parsed)
{
    Simple[] out_;
    expandSequence(parsed, 0, out_);
    return out_;
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
    expandSequenceWith(parsed, depth, out_, false);
}

/// Expand a parsed command sequence, classifying shell loops by effect: once
/// a `for`/`select`/`while`/`until` opens, every condition and body command
/// until the matching `done` must be provably read-only. `readonly` is set
/// when the sequence is itself a loop header/condition substitution.
void expandSequenceWith(const Simple[] parsed, size_t depth, ref Simple[] out_, bool readonly)
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
                expandSequenceWith(cleared, depth, out_, true);
            }
            else
                foreach (cmd; run)
                {
                    checkReadonlyLoopCommand(cmd, "loop", "header or condition substitution");
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
                checkReadonlyLoopCommand(withWords(simple, simple.words[offset .. $]), "loop",
                    "header or condition substitution");
            expand(simple, depth, out_);
            continue;
        }
        if (loops.length && simple.words[0 .. offset].any!(w => w.text == "do"))
            loops[$ - 1].inBody = true;

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
                checkReadonlyLoopCommand(condition, kind, "condition");
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
        checkReadonlyLoopCommand(effective, frame.kind, phase);
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

void checkReadonlyLoopCommand(const Simple cmd, string kind, string phase)
{
    checkLoopSideEffects(cmd, kind, phase);
    auto rendered = commandText(cmd);
    string fail(string what) { return format("cannot allow `%s` loop: %s command `%s` %s", kind, phase, rendered, what); }
    size_t i = 0;
    while (i < cmd.words.length && isAssignment(cmd.words[i].text))
    {
        auto text = cmd.words[i].text;
        auto name = text[0 .. (text.indexOf('=') < 0 ? text.length : text.indexOf('='))];
        while (name.endsWith("+")) name = name[0 .. $ - 1];
        if (name.indexOf('[') >= 0) name = name[0 .. name.indexOf('[')];
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
        if (dangerousLoopAssignments.canFind(name))
            throw new Blocked(fail(format("assigns `%s`, which can change what the loop's commands run; rewrite it as "
                ~ "explicit commands", name)));
        ++i;
    }
    if (i >= cmd.words.length) return;
    auto programIndex = i;
    auto first = cmd.words[i].text;
    if (first == "builtin") programIndex = i + 1;
    else if (first == "command")
    {
        auto j = i + 1;
        while (j < cmd.words.length && cmd.words[j].text == "-p") ++j;
        if (j < cmd.words.length && (cmd.words[j].text == "-v" || cmd.words[j].text == "-V")) return;
        if (j < cmd.words.length && cmd.words[j].text == "--") ++j;
        else if (j < cmd.words.length && cmd.words[j].text.startsWith("-") && cmd.words[j].text.length > 1)
            throw new Blocked(fail("uses unsupported `command` options; rewrite it as explicit commands"));
        programIndex = j;
    }
    if (programIndex >= cmd.words.length) throw new Blocked(fail("does not name a command to inspect"));
    auto programWord = cmd.words[programIndex];
    if (programWord.dynamic)
        throw new Blocked(fail("runs a command computed at run time; rewrite it as explicit commands"));
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
    if (!readonlyLoopCommands.canFind(program))
        throw new Blocked(fail("is not a known read-only command; keep the loop body to read-only commands like "
            ~ "`echo`, `grep`, `cat` and `wc`, or rewrite it as explicit commands"));
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
        if (i >= words.length) { push(i); return; }
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

/// Parsed commands with their assignment words intact, including commands
/// nested inside inspectable scripts. Never fails.
Simple[] commandsWithAssignments(string command)
{
    Simple[] out_;
    Simple[] parsed;
    try parsed = parse(command);
    catch (Exception) return out_;
    foreach (s; parsed) collectWithAssignments(s, 0, out_);
    return out_;
}

void collectWithAssignments(const Simple simple, size_t depth, ref Simple[] out_)
{
    out_ ~= withWords(simple, simple.words);
    if (depth >= maxExpandDepth) return;
    foreach (script; nestedScripts(simple))
    {
        Simple[] inner;
        try inner = parseNested(script, depth);
        catch (Exception) continue;
        foreach (c; inner) collectWithAssignments(c, depth + 1, out_);
    }
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

Known[string] assignments(const Simple[] commands)
{
    Known[string] out_;
    foreach (cmd; commands)
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
    return out_;
}

/// Names whose value cannot be trusted to a pre-loop literal.
bool[string] loopBoundVars(const Simple[] commands)
{
    bool[string] out_;
    size_t depth = 0;
    foreach (cmd; commands)
    {
        auto offset = loopCommandOffset(cmd.words);
        string head = offset < cmd.words.length && isLoopKeyword(cmd.words[offset]) ? cmd.words[offset].text : null;
        bool startsLoop = head !is null && ["for", "select", "while", "until"].canFind(head);
        bool closesLoop = head == "done" && depth > 0;
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
            ++depth;
            continue;
        }
        if (closesLoop) { --depth; continue; }
        if (depth > 0) collectLoopBodyWrites(cmd.words[offset .. $], out_);
        foreach (w; cmd.words)
            if (w.assigns)
            {
                auto name = expansionAssignedName(w.text);
                if (name !is null && isShellIdentifier(name)) out_[name] = true;
            }
    }
    return out_;
}

void collectLoopBodyWrites(const Word[] words, ref bool[string] out_)
{
    foreach (w; words)
        if (w.assigns)
        {
            auto name = expansionAssignedName(w.text);
            if (name !is null) insertVarName(name, out_);
        }
    size_t i = 0;
    if (words.length && declBuiltins.canFind(words[0].text)) ++i;
    while (i < words.length && isAssignment(words[i].text))
    {
        auto t = words[i].text;
        auto name = t[0 .. t.indexOf('=')];
        while (name.endsWith("+")) name = name[0 .. $ - 1];
        if (name.indexOf('[') >= 0) name = name[0 .. name.indexOf('[')];
        if (name.length) out_[name] = true;
        ++i;
    }
    if (i >= words.length) return;
    auto programIndex = i;
    if (words[i].text == "builtin") programIndex = i + 1;
    else if (words[i].text == "command")
    {
        auto j = i + 1;
        while (j < words.length && words[j].text == "-p") ++j;
        if (j < words.length && (words[j].text == "-v" || words[j].text == "-V")) return;
        if (j < words.length && words[j].text == "--") ++j;
        programIndex = j;
    }
    if (programIndex >= words.length) return;
    auto args = words[programIndex + 1 .. $];
    switch (basename(words[programIndex].text))
    {
    case "read": collectReadDestinations(args, out_); break;
    case "printf": collectPrintfDestination(args, out_); break;
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
