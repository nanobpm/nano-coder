/// A small bash parser for permission checks (port of src/shell.rs).
///
/// It splits a command line into simple commands (on `;`, `&`, `&&`, `||`,
/// `|`, newlines and parentheses), unquotes words, records redirections and
/// here-document bodies, and parses command substitutions (`$(...)`,
/// backticks, `<(...)`) as further commands. It does not expand anything:
/// words that contain `$...` or command substitutions are marked dynamic, and
/// unquoted glob characters are recorded.
///
/// Anything it cannot parse (an unterminated quote, an unmatched `)`) throws
/// `ShellParseError`, so callers can fail closed.
module nano.shell;

@safe:

import std.algorithm : canFind, startsWith, any;
import std.array : split;
import std.format : format;
import std.conv : to;

class ShellParseError : Exception
{
    this(string msg) pure nothrow { super(msg); }
}

/// One word of a simple command, unquoted but not expanded.
struct Word
{
    /// Literal text; expansions are kept as written (`$HOME`, `${X:?}`, `$(...)`).
    string text;
    /// Contains a parameter expansion or command substitution.
    bool dynamic;
    /// Contains an unquoted `*`, `?` or `[`.
    bool glob;
    /// Some part of the word was quoted or escaped.
    bool quoted;
    /// The word may expand to other than exactly one argument (see shell.rs).
    bool splits;
    /// The word contains an expansion that can assign a shell variable.
    bool assigns;
}

struct Redirect
{
    string op;
    Word target;
}

/// A here-document body fed to a command.
struct Heredoc
{
    string body;
    /// The body is expanded unless the delimiter was quoted.
    bool expand;
}

/// A simple command: words, redirections and here-document bodies.
struct Simple
{
    Word[] words;
    Redirect[] redirects;
    Heredoc[] heredocs;
    /// Lifted out of a loop header or loop condition's command substitution.
    bool loopHeaderSub;
}

private bool isAlpha(dchar c) pure nothrow { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
private bool isDigit(dchar c) pure nothrow { return c >= '0' && c <= '9'; }
private bool isAlnum(dchar c) pure nothrow { return isAlpha(c) || isDigit(c); }
private bool isIdentStart(dchar c) pure nothrow { return c == '_' || isAlpha(c); }
private bool isIdent(dchar c) pure nothrow { return c == '_' || isAlnum(c); }

private int digitValue(dchar c, int radix) pure nothrow
{
    int v;
    if (isDigit(c)) v = c - '0';
    else if (c >= 'a' && c <= 'z') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'Z') v = c - 'A' + 10;
    else return -1;
    return v < radix ? v : -1;
}

/// Whether the words parsed so far open a loop whose header or condition runs
/// on the parent shell.
private bool opensLoopHeader(const Word[] words) pure nothrow
{
    foreach (w; words)
    {
        if (w.quoted) return false;
        switch (w.text)
        {
        case "for", "select", "while", "until": return true;
        case "!", "if", "then", "else", "elif", "do", "{", "}", "fi", "esac": continue;
        default: return false;
        }
    }
    return false;
}

/// Whether an arithmetic `$(( ... ))` body contains an assignment operator
/// (including `++`/`--`).
package bool arithmeticAssigns(string body) pure
{
    if (body.canFind("++") || body.canFind("--")) return true;
    auto chars = body.to!(dchar[]);
    foreach (i, c; chars)
    {
        if (c != '=') continue;
        dchar prev = i >= 1 ? chars[i - 1] : dchar.init;
        dchar next = i + 1 < chars.length ? chars[i + 1] : dchar.init;
        bool hasPrev = i >= 1;
        if (next == '=' && i + 1 < chars.length) continue;
        if (hasPrev && (prev == '=' || prev == '!')) continue;
        if (hasPrev && (prev == '<' || prev == '>'))
        {
            if (i >= 2 && chars[i - 2] == prev) return true; // `<<=` / `>>=`
            continue;
        }
        return true;
    }
    return false;
}

/// Index just past an identifier or digit run starting at `i`.
private size_t skipName(const dchar[] c, size_t i) pure nothrow
{
    if (i < c.length && isIdentStart(c[i]))
    {
        while (i < c.length && isIdent(c[i])) ++i;
    }
    else if (i < c.length && isDigit(c[i]))
    {
        while (i < c.length && isDigit(c[i])) ++i;
    }
    return i;
}

/// Whether a `${ ... }` parameter-expansion body assigns its variable.
private bool paramExpansionAssigns(string body) pure
{
    auto c = body.to!(dchar[]);
    size_t i = 0;
    if (c.length > 0 && c[0] == '#' && body.length > 1) ++i;
    if (i >= c.length) return false;
    auto ch = c[i];
    if (isIdentStart(ch) || isDigit(ch))
        i = skipName(c, i);
    else if (ch == '!')
    {
        ++i;
        if (i < c.length && (isIdentStart(c[i]) || isDigit(c[i])))
            i = skipName(c, i);
        else
            return false; // `${!prefix@}`, `${!prefix*}` or not a simple target
    }
    else if ("@*#?$-".canFind(ch))
        ++i;
    else
        return false;
    if (i < c.length && c[i] == '[')
    {
        ++i;
        dchar[] sub;
        while (i < c.length)
        {
            auto x = c[i++];
            if (x == ']') break;
            sub ~= x;
        }
        if (arithmeticAssigns(sub.to!string)) return true;
    }
    auto rest = c[i .. $].to!string;
    if (rest.startsWith("+=") || rest.startsWith("=") || rest.startsWith(":=") || rest.startsWith("::="))
        return true;
    if (rest.startsWith(":"))
    {
        auto sub = rest[1 .. $];
        if (!(sub.startsWith("-") || sub.startsWith("=") || sub.startsWith("+") || sub.startsWith("?")))
            if (sub.split(":").any!(f => arithmeticAssigns(f))) return true;
    }
    return nestedExpansionAssigns(body);
}

/// Index of the brace/paren closing the one opened at `start` (or length).
private size_t matchClose(const dchar[] c, size_t start, dchar open, dchar close) pure nothrow
{
    size_t depth = 0;
    size_t j = start;
    while (j < c.length)
    {
        if (c[j] == open) ++depth;
        else if (c[j] == close)
        {
            if (depth > 0) --depth;
            if (depth == 0) break;
        }
        ++j;
    }
    return j;
}

/// Whether any expansion nested in `body` yields one argument per element even
/// under the outer expansion's quotes.
private bool nestedListExpansion(string body) pure
{
    auto c = body.to!(dchar[]);
    size_t i = 0;
    while (i < c.length)
    {
        if (c[i] == '$' && i + 1 < c.length)
        {
            if (c[i + 1] == '@' || c[i + 1] == '*') return true;
            if (c[i + 1] == '{')
            {
                auto j = matchClose(c, i + 1, '{', '}');
                auto inner = c[i + 2 .. j].to!string;
                if (topLevelList(inner)) return true;
                if (!inner.startsWith("#") && nestedListExpansion(inner)) return true;
                i = j + 1;
                continue;
            }
        }
        ++i;
    }
    return false;
}

/// Whether a `${...}` body is itself a positional/array list expansion.
private bool topLevelList(string body) pure
{
    if (body.startsWith("#")) return false;
    if (body.startsWith("@") || body.startsWith("*")) return true;
    auto c = body.to!(dchar[]);
    if (c.length == 0 || !(isIdentStart(c[0]) || isDigit(c[0]))) return false;
    auto i = skipName(c, 0);
    return i + 2 < c.length && c[i] == '[' && (c[i + 1] == '@' || c[i + 1] == '*') && c[i + 2] == ']';
}

/// Whether any `$(( ... ))` or `${ ... }` nested in `body` assigns.
private bool nestedExpansionAssigns(string body) pure
{
    auto c = body.to!(dchar[]);
    size_t i = 0;
    while (i < c.length)
    {
        if (c[i] == '$' && i + 1 < c.length)
        {
            if (c[i + 1] == '(')
            {
                bool arith = i + 2 < c.length && c[i + 2] == '(';
                auto open = i + 1;
                auto j = matchClose(c, open, '(', ')');
                if (arith && arithmeticAssigns(c[open + 2 .. j].to!string)) return true;
                i = j + 1;
                continue;
            }
            if (c[i + 1] == '{')
            {
                auto j = matchClose(c, i + 1, '{', '}');
                if (paramExpansionAssigns(c[i + 2 .. j].to!string)) return true;
                i = j + 1;
                continue;
            }
        }
        ++i;
    }
    return false;
}

/// Whether the words parsed so far are inside an open `[[ ... ]]`.
private bool inConditional(const Word[] words) pure nothrow
{
    bool open, seenCommand;
    foreach (w; words)
    {
        if (w.quoted || w.dynamic)
        {
            seenCommand = true;
            continue;
        }
        if (w.text == "[[" && !seenCommand) { open = true; seenCommand = true; }
        else if (w.text == "]]" && open) open = false;
        else if (!seenCommand && ["!", "if", "then", "else", "elif", "do", "while", "until", "{", "}", "fi", "esac"].canFind(w.text)) {}
        else seenCommand = true;
    }
    return open;
}

enum maxDepth = 16;

/// Whether an expanding here-document body contains an expansion that assigns
/// a shell variable. Fails closed: a malformed expansion returns true.
bool heredocBodyAssigns(string body)
{
    auto p = Parser(body.to!(dchar[]), 0, 0);
    Word word;
    while (p.pos < p.chars.length)
    {
        auto c = p.chars[p.pos];
        try
        {
            if (c == '\\' && (p.peekAt(1) == '$' || p.peekAt(1) == '`' || p.peekAt(1) == '\\')) p.pos += 2;
            else if (c == '$') p.dollar(word, true);
            else if (c == '`') { p.pos += 1; p.backtick(); }
            else p.pos += 1;
        }
        catch (ShellParseError) return true;
        if (word.assigns) return true;
    }
    return word.assigns;
}

/// Parse a command line into its simple commands, including those inside
/// command substitutions.
Simple[] parse(string source) { return parseNested(source, 0); }

Simple[] parseNested(string source, size_t depth)
{
    if (depth > maxDepth) throw new ShellParseError("command nests too deeply to inspect");
    dchar[] chars;
    try chars = source.to!(dchar[]);
    catch (Exception) throw new ShellParseError("command is not valid UTF-8");
    auto p = Parser(chars, 0, depth);
    p.script(false);
    return p.out_;
}

private struct PendingHeredoc
{
    size_t command;
    string delimiter;
    bool stripTabs;
    bool expand;
}

private bool isOperator(dchar c) pure nothrow
{
    return c == ';' || c == '&' || c == '|' || c == '(' || c == ')' || c == '<' || c == '>' || c == '\n';
}

private enum dchar none = dchar.max; // sentinel for "no character"

private struct Parser
{
    dchar[] chars;
    size_t pos;
    size_t depth;
    Simple[] out_;
    size_t caseDepth;

    this(dchar[] chars, size_t pos, size_t depth) pure nothrow
    {
        this.chars = chars;
        this.pos = pos;
        this.depth = depth;
    }

    dchar peek() const pure nothrow { return pos < chars.length ? chars[pos] : none; }
    dchar peekAt(size_t off) const pure nothrow { return pos + off < chars.length ? chars[pos + off] : none; }
    bool atEnd() const pure nothrow { return pos >= chars.length; }

    bool eat(dchar c) pure nothrow
    {
        if (peek() == c) { ++pos; return true; }
        return false;
    }

    static void pushCode(ref Word w, uint val) pure
    {
        import std.utf : isValidDchar;
        auto d = cast(dchar) val;
        if (isValidDchar(d)) w.text ~= d;
        else w.dynamic = true;
    }

    /// Decode one ANSI-C (`$'...'`) backslash escape; pos just past the `\`.
    void ansiCEscape(ref Word word)
    {
        if (atEnd) throw new ShellParseError("unterminated $'...' string");
        auto next = chars[pos++];
        switch (next)
        {
        case 'a': word.text ~= '\x07'; break;
        case 'b': word.text ~= '\x08'; break;
        case 'e', 'E': word.text ~= '\x1b'; break;
        case 'f': word.text ~= '\x0c'; break;
        case 'n': word.text ~= '\n'; break;
        case 'r': word.text ~= '\r'; break;
        case 't': word.text ~= '\t'; break;
        case 'v': word.text ~= '\x0b'; break;
        case '\\': word.text ~= '\\'; break;
        case '\'': word.text ~= '\''; break;
        case '"': word.text ~= '"'; break;
        case '?': word.text ~= '?'; break;
        case 'x':
        case 'u', 'U':
        {
            auto width = next == 'x' ? 2 : next == 'u' ? 4 : 8;
            uint val = 0;
            int n = 0;
            while (n < width)
            {
                auto d = atEnd ? -1 : digitValue(peek(), 16);
                if (d < 0) break;
                val = val * 16 + d;
                ++pos;
                ++n;
            }
            if (n == 0) word.text ~= next;
            else pushCode(word, val);
            break;
        }
        case '0': .. case '7':
        {
            uint val = next - '0';
            int n = 1;
            while (n < 3)
            {
                auto d = atEnd ? -1 : digitValue(peek(), 8);
                if (d < 0) break;
                val = val * 8 + d;
                ++pos;
                ++n;
            }
            pushCode(word, val);
            break;
        }
        case 'c':
            if (atEnd) word.dynamic = true;
            else
            {
                auto c = chars[pos++];
                auto up = (c >= 'a' && c <= 'z') ? c - 32 : c;
                word.text ~= cast(char)((cast(ubyte) up) ^ 0x40);
            }
            break;
        default:
            word.text ~= next;
            word.dynamic = true;
        }
    }

    /// Parse commands until the end of input or, when `untilParen`, the `)`
    /// that closes a command substitution.
    void script(bool untilParen)
    {
        Simple current;
        size_t parens = 0;
        PendingHeredoc[] pending;
        for (;;)
        {
            skipBlanks();
            if (atEnd)
            {
                if (untilParen) throw new ShellParseError("unterminated command substitution");
                if (parens > 0) throw new ShellParseError("unmatched (");
                flush(current, pending);
                return;
            }
            auto c = peek();
            switch (c)
            {
            case '#':
                while (!atEnd && peek() != '\n') ++pos;
                break;
            case '\n':
                ++pos;
                flush(current, pending);
                foreach (h; pending)
                {
                    auto body = heredocBody(h.delimiter, h.stripTabs);
                    if (h.command < out_.length) out_[h.command].heredocs ~= Heredoc(body, h.expand);
                }
                pending = null;
                break;
            case ';', '&', '|':
                if (c == '&' && peekAt(1) == '>')
                {
                    redirect(current, pending);
                    continue;
                }
                bool doubled = peekAt(1) == c;
                if (doubled && c != ';' && inConditional(current.words))
                {
                    Word w;
                    w.text = format("%s%s", c, c);
                    current.words ~= w;
                    pos += 2;
                    continue;
                }
                ++pos;
                while (!atEnd && (peek() == '&' || peek() == '|' || peek() == ';')) ++pos;
                flush(current, pending);
                break;
            case '(':
                ++pos;
                ++parens;
                flush(current, pending);
                break;
            case ')':
                ++pos;
                if (parens > 0)
                {
                    --parens;
                    flush(current, pending);
                }
                else if (caseDepth > 0)
                    current = Simple.init; // a `case` pattern such as `a|b)`
                else if (untilParen)
                {
                    flush(current, pending);
                    if (pending.length) throw new ShellParseError("here-document inside a command substitution");
                    return;
                }
                else
                    throw new ShellParseError("unmatched )");
                break;
            case '<', '>':
                if (peekAt(1) == '(')
                {
                    pos += 2;
                    auto outStart = out_.length;
                    substitution();
                    if (opensLoopHeader(current.words)) markLoopHeaderSubs(outStart);
                    Word w;
                    w.text = "/dev/fd/63";
                    w.dynamic = true;
                    current.words ~= w;
                }
                else if (inConditional(current.words))
                {
                    Word w;
                    w.text = c == '<' ? "<" : ">";
                    current.words ~= w;
                    ++pos;
                }
                else
                    redirect(current, pending);
                break;
            default:
                if (isDigit(c) && isFdRedirect())
                {
                    while (!atEnd && isDigit(peek())) ++pos;
                    redirect(current, pending);
                    continue;
                }
                bool inLoopHead = opensLoopHeader(current.words);
                auto outStart = out_.length;
                auto w = word();
                if (inLoopHead) markLoopHeaderSubs(outStart);
                if (current.words.length == 0 && !w.quoted)
                {
                    if (w.text == "case") ++caseDepth;
                    else if (w.text == "esac" && caseDepth > 0) --caseDepth;
                }
                current.words ~= w;
            }
        }
    }

    bool isFdRedirect() const pure nothrow
    {
        size_t i = pos;
        while (i < chars.length && isDigit(chars[i])) ++i;
        return i < chars.length && (chars[i] == '<' || chars[i] == '>');
    }

    /// End the current simple command; here-documents it opened now know
    /// which command their body belongs to.
    void flush(ref Simple current, PendingHeredoc[] pending) pure nothrow
    {
        auto simple = current;
        current = Simple.init;
        bool caseHead = simple.words.length && !simple.words[0].quoted && simple.words[0].text == "case";
        if (!caseHead && (simple.words.length || simple.redirects.length))
        {
            out_ ~= simple;
            auto index = out_.length - 1;
            foreach (ref h; pending)
                if (h.command == size_t.max) h.command = index;
        }
    }

    void skipBlanks() pure nothrow
    {
        for (;;)
        {
            auto c = peek();
            if (c == ' ' || c == '\t' || c == '\r') ++pos;
            else if (c == '\\' && peekAt(1) == '\n') pos += 2;
            else return;
        }
    }

    void markLoopHeaderSubs(size_t outStart) pure nothrow
    {
        foreach (ref s; out_[outStart .. $]) s.loopHeaderSub = true;
    }

    void redirect(ref Simple current, ref PendingHeredoc[] pending)
    {
        auto start = pos;
        if (eat('&'))
        {
            eat('>');
            eat('>');
        }
        else if (eat('<'))
        {
            if (eat('<'))
            {
                if (!eat('<')) eat('-'); // `<<<` is a here-string
            }
            else if (!eat('&')) eat('>');
        }
        else if (eat('>'))
        {
            if (!eat('>') && !eat('|')) eat('&');
        }
        auto op = chars[start .. pos].to!string;
        skipBlanks();
        if (atEnd || (isOperator(peek()) && peek() != '<' && peek() != '>'))
            throw new ShellParseError(format("redirection %s has no target", op));
        auto outStart = out_.length;
        auto target = word();
        if (opensLoopHeader(current.words)) markLoopHeaderSubs(outStart);
        if (op == "<<" || op == "<<-")
            pending ~= PendingHeredoc(size_t.max, target.text, op == "<<-", !target.quoted);
        current.redirects ~= Redirect(op, target);
    }

    string heredocBody(string delimiter, bool stripTabs)
    {
        string body;
        while (pos < chars.length)
        {
            auto start = pos;
            while (!atEnd && peek() != '\n') ++pos;
            auto line = chars[start .. pos].to!string;
            eat('\n');
            auto candidate = line;
            if (stripTabs) while (candidate.length && candidate[0] == '\t') candidate = candidate[1 .. $];
            if (candidate == delimiter) break;
            body ~= line ~ "\n";
        }
        return body;
    }

    /// Parse a `$(...)` body (the opening `$(` already consumed) as commands.
    void substitution()
    {
        if (depth >= maxDepth) throw new ShellParseError("command nests too deeply to inspect");
        auto inner = Parser(chars, pos, depth + 1);
        scope (exit) pos = inner.pos;
        inner.script(true);
        out_ ~= inner.out_;
    }

    void backtick()
    {
        dchar[] inner;
        for (;;)
        {
            if (atEnd) throw new ShellParseError("unterminated backtick");
            auto c = peek();
            if (c == '`') { ++pos; break; }
            if (c == '\\' && (peekAt(1) == '`' || peekAt(1) == '\\' || peekAt(1) == '$'))
            {
                inner ~= chars[pos + 1];
                pos += 2;
            }
            else
            {
                inner ~= c;
                ++pos;
            }
        }
        out_ ~= parseNested(inner.to!string, depth + 1);
    }

    /// Skip a balanced `${...}` or `$((...))` body, returning its text, while
    /// still parsing command substitutions nested in it.
    string balanced(dchar open, dchar close)
    {
        auto start = pos;
        int level = 1;
        while (!atEnd)
        {
            auto c = peek();
            if (c == '\\') pos += 2;
            else if (c == '\'' && open == '{')
            {
                ++pos;
                while (!atEnd && peek() != '\'') ++pos;
                ++pos;
            }
            else if (c == '`') { ++pos; backtick(); }
            else if (c == '$' && peekAt(1) == '(' && peekAt(2) == '(')
            {
                pos += 3;
                balanced('(', ')');
                eat(')');
            }
            else if (c == '$' && peekAt(1) == '(')
            {
                pos += 2;
                substitution();
            }
            else if (c == open) { ++pos; ++level; }
            else if (c == close)
            {
                ++pos;
                if (--level == 0) return chars[start .. pos - 1].to!string;
            }
            else ++pos;
        }
        throw new ShellParseError(format("unterminated %s", open));
    }

    /// `$...` at the current position (the `$` not yet consumed).
    void dollar(ref Word word, bool quoted)
    {
        ++pos;
        auto c = peek();
        if (c == '(' && peekAt(1) == '(')
        {
            pos += 2;
            auto body = balanced('(', ')');
            eat(')');
            word.text ~= "$((" ~ body ~ "))";
            word.dynamic = true;
            if (!quoted) word.splits = true;
            if (arithmeticAssigns(body)) word.assigns = true;
        }
        else if (c == '(')
        {
            ++pos;
            substitution();
            word.text ~= "$(...)";
            word.dynamic = true;
            if (!quoted) word.splits = true;
        }
        else if (c == '{')
        {
            ++pos;
            auto body = balanced('{', '}');
            word.text ~= "${" ~ body ~ "}";
            word.dynamic = true;
            if (!quoted || topLevelList(body)) word.splits = true;
            if (quoted && nestedListExpansion(body)) word.splits = true;
            if (paramExpansionAssigns(body)) word.assigns = true;
        }
        else if (c != none && (isAlnum(c) || c == '_'))
        {
            word.text ~= '$';
            while (!atEnd && (isAlnum(peek()) || peek() == '_')) word.text ~= chars[pos++];
            word.dynamic = true;
            if (!quoted) word.splits = true;
        }
        else if (c != none && "@*#?$!-".canFind(c))
        {
            word.text ~= '$';
            word.text ~= c;
            ++pos;
            word.dynamic = true;
            if (!quoted || c == '@') word.splits = true;
        }
        else
            word.text ~= '$';
    }

    void singleQuote(ref Word word)
    {
        ++pos;
        word.quoted = true;
        for (;;)
        {
            if (atEnd) throw new ShellParseError("unterminated single quote");
            auto c = chars[pos++];
            if (c == '\'') return;
            word.text ~= c;
        }
    }

    void doubleQuote(ref Word word)
    {
        ++pos;
        word.quoted = true;
        for (;;)
        {
            if (atEnd) throw new ShellParseError("unterminated double quote");
            auto c = peek();
            if (c == '"') { ++pos; return; }
            auto n = peekAt(1);
            if (c == '\\' && (n == '"' || n == '\\' || n == '$' || n == '`' || n == '\n'))
            {
                if (n != '\n') word.text ~= n;
                pos += 2;
            }
            else if (c == '$') dollar(word, true);
            else if (c == '`')
            {
                ++pos;
                backtick();
                word.text ~= "$(...)";
                word.dynamic = true;
            }
            else
            {
                word.text ~= c;
                ++pos;
            }
        }
    }

    void ansiCString(ref Word word)
    {
        pos += 2;
        word.quoted = true;
        for (;;)
        {
            if (atEnd) throw new ShellParseError("unterminated $'...' string");
            auto c = chars[pos++];
            if (c == '\'') return;
            if (c == '\\') ansiCEscape(word);
            else word.text ~= c;
        }
    }

    /// A backslash outside quotes (pos at the `\`).
    void escape(ref Word word) pure
    {
        ++pos;
        auto n = peek();
        if (n == '\n') ++pos;
        else if (n != none)
        {
            word.text ~= n;
            word.quoted = true;
            ++pos;
        }
        else word.text ~= '\\';
    }

    Word word()
    {
        Word word;
        while (!atEnd)
        {
            auto c = peek();
            if (c == ' ' || c == '\t' || c == '\r' || isOperator(c)) break;
            switch (c)
            {
            case '\\': escape(word); break;
            case '\'': singleQuote(word); break;
            case '"': doubleQuote(word); break;
            case '$':
                if (peekAt(1) == '\'') ansiCString(word);
                else dollar(word, false);
                break;
            case '`':
                ++pos;
                backtick();
                word.text ~= "$(...)";
                word.dynamic = true;
                word.splits = true;
                break;
            case '*', '?', '[':
                word.glob = true;
                word.splits = true;
                word.text ~= c;
                ++pos;
                break;
            case '{':
                braceWord(word);
                break;
            default:
                word.text ~= c;
                ++pos;
            }
        }
        return word;
    }

    /// Unquoted brace expansion (`{a,b}`, `{1..9}`), parsed with the normal
    /// lexer handlers so quotes and substitutions inside keep their metadata.
    void braceWord(ref Word word)
    {
        word.text ~= '{';
        ++pos;
        size_t depth = 1;
        bool hasComma, hasRange;
        while (!atEnd)
        {
            auto c = peek();
            if (isOperator(c) || c == ' ' || c == '\t' || c == '\r') break;
            switch (c)
            {
            case '\\': escape(word); break;
            case '\'': singleQuote(word); break;
            case '"': doubleQuote(word); break;
            case '$':
                if (peekAt(1) == '\'') ansiCString(word);
                else dollar(word, false);
                break;
            case '`':
                ++pos;
                backtick();
                word.text ~= "$(...)";
                word.dynamic = true;
                word.splits = true;
                break;
            case '{':
                ++depth;
                word.text ~= c;
                ++pos;
                break;
            case '}':
                if (depth > 0) --depth;
                word.text ~= c;
                ++pos;
                if (depth == 0) goto done;
                break;
            case ',':
                hasComma = true;
                word.text ~= c;
                ++pos;
                break;
            case '.':
                if (peekAt(1) == '.')
                {
                    hasRange = true;
                    word.text ~= "..";
                    pos += 2;
                }
                else
                {
                    word.text ~= c;
                    ++pos;
                }
                break;
            case '*', '?', '[':
                word.glob = true;
                word.splits = true;
                word.text ~= c;
                ++pos;
                break;
            default:
                word.text ~= c;
                ++pos;
            }
        }
    done:
        if (hasComma || hasRange)
        {
            word.splits = true;
            word.dynamic = true;
        }
    }
}

// ---------------------------------------------------------------- tests

version (unittest)
{
    private string[][] words(string source)
    {
        string[][] r;
        foreach (s; parse(source))
        {
            string[] ws;
            foreach (w; s.words) ws ~= w.text;
            r ~= ws;
        }
        return r;
    }

    private Word wordAt(string source, size_t cmd, size_t idx) { return parse(source)[cmd].words[idx]; }

    private bool fails(string source)
    {
        try { parse(source); return false; }
        catch (ShellParseError) return true;
    }
}

unittest // splits_on_operators
{
    assert(words("ls -la && rm -rf / ; echo 'a b' | wc -l || true & sleep 1\ngit status") ==
        [["ls", "-la"], ["rm", "-rf", "/"], ["echo", "a b"], ["wc", "-l"], ["true"], ["sleep", "1"], ["git", "status"]]);
}

unittest // unquotes_and_marks_dynamic_and_glob
{
    auto w = parse(`rm -rf "$HOME"/x \* '*' * ${D:?}/y`)[0].words;
    assert(w[2].text == "$HOME/x");
    assert(w[2].dynamic && w[2].quoted);
    assert(!w[3].glob && w[3].text == "*");
    assert(!w[4].glob);
    assert(w[5].glob && !w[5].quoted);
    assert(w[6].text == "${D:?}/y");
}

unittest // parses_substitutions_as_commands
{
    assert(words(`echo "$(rm -rf / )" ` ~ "`mkfs /dev/sda`" ~ ` $(( 1 + 2 )) <(dd of=/dev/sda)`) ==
        [["rm", "-rf", "/"], ["mkfs", "/dev/sda"], ["dd", "of=/dev/sda"],
         ["echo", "$(...)", "$(...)", "$(( 1 + 2 ))", "/dev/fd/63"]]);
}

unittest // nested_command_substitutions_are_inspected
{
    assert(words(`echo $(( $(rm -rf /) ))`) == [["rm", "-rf", "/"], ["echo", "$(( $(rm -rf /) ))"]]);
    assert(words(`echo "${X:-$(rm -rf /)}"`) == [["rm", "-rf", "/"], ["echo", "${X:-$(rm -rf /)}"]]);
    assert(words("echo \"${X:-`mkfs /dev/sda`}\"") == [["mkfs", "/dev/sda"], ["echo", "${X:-`mkfs /dev/sda`}"]]);
}

unittest // records_redirects_and_heredocs
{
    auto p = parse("cat > /dev/sda 2>&1 <<EOF\nDROP DATABASE x;\nEOF\necho done");
    assert(p[0].redirects[0].op == ">");
    assert(p[0].redirects[0].target.text == "/dev/sda");
    assert(p[0].redirects[1].op == ">&");
    assert(p[0].heredocs == [Heredoc("DROP DATABASE x;\n", true)]);
    assert(p[1].words[0].text == "echo");
    p = parse("psql <<-'SQL' && echo ok\n\tDROP TABLE t;\n\tSQL\n");
    assert(p[0].heredocs == [Heredoc("\tDROP TABLE t;\n", false)]);
    assert(p[1].words[0].text == "echo");
}

unittest // handles_subshells_groups_and_case
{
    assert(words("(cd x && rm -rf y)") == [["cd", "x"], ["rm", "-rf", "y"]]);
    assert(words("{ rm a; }") == [["{", "rm", "a"], ["}"]]);
    assert(words("case $x in a|b) rm a ;; *) echo no ;; esac") == [["rm", "a"], ["echo", "no"], ["esac"]]);
}

unittest // fails_closed_on_malformed_input
{
    import std.array : replicate;
    foreach (bad; ["echo 'x", "echo \"x", "echo $(ls", "echo `ls", "ls )", "(ls", "echo ${x"])
        assert(fails(bad), bad);
    assert(fails("echo " ~ "$(".replicate(40) ~ ")".replicate(40)));
}

unittest // unquoted_brace_expansion_splits
{
    auto brace = wordAt("sort -T {/tmp,-oout} input", 0, 2);
    assert(brace.text == "{/tmp,-oout}");
    assert(brace.splits);
    assert(!wordAt("echo {a}", 0, 1).splits);
    assert(!wordAt("echo '{a,b}'", 0, 1).splits);
}

unittest // nested_and_substring_expansions_assign
{
    assert(wordAt(`echo "${x:-$((PATH=0))}"`, 0, 1).assigns);
    assert(wordAt(`echo "${missing:-${d:=/etc}}"`, 0, 1).assigns);
    assert(wordAt(`echo "${text:PATH=0:1}"`, 0, 1).assigns);
    assert(!wordAt(`echo "${x:-default}"`, 0, 1).assigns);
    assert(!wordAt(`echo "${text:0:1}"`, 0, 1).assigns);
}

unittest // logical_operators_stay_inside_conditional
{
    import std.algorithm : any;
    auto cmds = parse("while [[ -f marker && -r marker ]]; do cat marker; break; done");
    assert(cmds.any!(s => s.words.any!(w => w.text == "&&")));
    assert(!cmds.any!(s => s.words.length && s.words[0].text == "-r"));
    cmds = parse(`for f in a z; do [[ "$f" == a || "$f" == z ]]; done`);
    assert(cmds.any!(s => s.words.any!(w => w.text == "||")));
}

unittest // brace_expansion_preserves_inner_parsing
{
    import std.algorithm : any;
    assert(parse("echo {a,`mktemp`}").any!(s => s.words.length && s.words[0].text == "mktemp"));
    assert(wordAt("echo {x,${d:=/etc}}", 0, 1).assigns);
    assert(wordAt("echo {x,$((PATH=0))}", 0, 1).assigns);
    assert(wordAt(`echo {a,"b,c"}`, 0, 1).splits);
}

unittest // brace_expansion_marks_dynamic
{
    auto b = wordAt("sort {input,-oresult} input", 0, 1);
    assert(b.text == "{input,-oresult}" && b.splits && b.dynamic);
    assert(!wordAt("sort {input} input", 0, 1).dynamic);
}

unittest // substring_length_arithmetic_assigns
{
    assert(wordAt(`echo "${text:0:PATH=0}"`, 0, 1).assigns);
    assert(wordAt(`echo "${text:PATH=0:1}"`, 0, 1).assigns);
    assert(!wordAt(`echo "${text:0:1}"`, 0, 1).assigns);
}

unittest // backtick_inside_brace_splits
{
    import std.algorithm : find;
    auto cmds = parse("sort -T {`printf '/tmp -oresult'`} input");
    auto outer = cmds.find!(s => s.words.length && s.words[0].text == "sort");
    assert(outer.length);
    assert(outer[0].words[2].splits && outer[0].words[2].dynamic);
}

unittest // brace_range_marks_dynamic
{
    auto a = wordAt("printf -v{c..d} '%s' /etc", 0, 1);
    assert(a.text == "-v{c..d}" && a.splits && a.dynamic);
    auto n = wordAt("sort -T {1..9} input", 0, 2);
    assert(n.splits && n.dynamic);
    assert(!wordAt("sort {input} input", 0, 1).dynamic);
}

unittest // heredoc_body_assigns_detects_expansions
{
    assert(heredocBodyAssigns("${text:PATH=0:1}\n"));
    assert(heredocBodyAssigns("${text:0:PATH=0}\n"));
    assert(heredocBodyAssigns("${d:=/etc}\n"));
    assert(heredocBodyAssigns("$((PATH=0))\n"));
    assert(!heredocBodyAssigns("plain ${text} and ${d:-x}\n"));
    assert(!heredocBodyAssigns("no expansions here\n"));
    assert(!heredocBodyAssigns("\\${d:=/etc}\n"));
}

unittest // indirect_expansion_assigns
{
    assert(wordAt(`echo "${!ref:=/etc}"`, 0, 1).assigns);
    assert(wordAt(`echo "${!ref+=/etc}"`, 0, 1).assigns);
    assert(!wordAt(`echo "${!ref}"`, 0, 1).assigns);
    assert(!wordAt(`echo "${!prefix@}"`, 0, 1).assigns);
    assert(heredocBodyAssigns("${!ref:=/etc}\n"));
    assert(!heredocBodyAssigns("${!ref}\n"));
}

unittest // nested_brace_expansion_marks_dynamic
{
    auto c = wordAt("sort -T -o{{a,b}} input", 0, 2);
    assert(c.text == "-o{{a,b}}" && c.splits && c.dynamic);
    auto r = wordAt("sort -T {{1..3}} input", 0, 2);
    assert(r.splits && r.dynamic);
    assert(!wordAt("sort {{a}} input", 0, 1).dynamic);
}

unittest // quoted_default_nested_list_splits
{
    assert(wordAt(`sort -T "${missing:-"$@"}" input`, 0, 2).splits);
    assert(wordAt(`sort -T "${missing:-"${arr[@]}"}" input`, 0, 2).splits);
    assert(wordAt(`sort -T "${missing:-"$*"}" input`, 0, 2).splits);
    assert(!wordAt(`sort -T "${missing:-/tmp}" input`, 0, 2).splits);
    assert(!wordAt(`sort -T "${missing:-"$dir"}" input`, 0, 2).splits);
    assert(!wordAt(`sort -T "${missing:-"${#arr[@]}"}" input`, 0, 2).splits);
    assert(!wordAt(`sort -T "${#arr[@]}" input`, 0, 2).splits);
    assert(wordAt(`sort -T "${@}" input`, 0, 2).splits);
    assert(wordAt(`sort -T "${arr[@]}" input`, 0, 2).splits);
    assert(wordAt(`sort -T "${outer:-${inner:-"$@"}}" input`, 0, 2).splits);
    assert(wordAt(`sort -T "${a:-${b:-${c:-"$@"}}}" input`, 0, 2).splits);
    assert(wordAt(`sort -T "${outer:-${inner:-"${arr[@]}"}}" input`, 0, 2).splits);
    assert(!wordAt(`sort -T "${outer:-${inner:-"$dir"}}" input`, 0, 2).splits);
    assert(!wordAt(`sort -T "${outer:-${#arr[@]}}" input`, 0, 2).splits);
}

unittest // brace_wildcard_keeps_glob_metadata
{
    auto s = wordAt("sort -T -o{*} input", 0, 2);
    assert(s.text == "-o{*}" && s.glob && s.splits);
    auto q = wordAt("sort -T -o{a?b} input", 0, 2);
    assert(q.glob && q.splits);
    auto c = wordAt("sort -T -o{a[bc]} input", 0, 2);
    assert(c.glob && c.splits);
    auto p = wordAt("sort -T -o{ab} input", 0, 2);
    assert(!p.glob && !p.splits);
}

unittest // ANSI-C escapes decode to the real command
{
    auto w = parse(`bash -c $'\x72m -rf /'`)[0].words;
    assert(w[2].text == "rm -rf /" && w[2].quoted && !w[2].dynamic);
    assert(parse(`echo $'\q'`)[0].words[1].dynamic);
}
