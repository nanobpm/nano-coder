//! A small bash parser for permission checks.
//!
//! It splits a command line into simple commands (on `;`, `&`, `&&`, `||`,
//! `|`, newlines and parentheses), unquotes words, records redirections and
//! here-document bodies, and parses command substitutions (`$(...)`,
//! backticks, `<(...)`) as further commands. It does not expand anything:
//! words that contain `$...` or command substitutions are marked dynamic, and
//! unquoted glob characters are recorded.
//!
//! Anything it cannot parse (an unterminated quote, an unmatched `)`) is an
//! error, so callers can fail closed.

/// One word of a simple command, unquoted but not expanded.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Word {
    /// Literal text; expansions are kept as written (`$HOME`, `${X:?}`, `$(...)`).
    pub text: String,
    /// Contains a parameter expansion or command substitution.
    pub dynamic: bool,
    /// Contains an unquoted `*`, `?` or `[`.
    pub glob: bool,
    /// Some part of the word was quoted or escaped.
    pub quoted: bool,
    /// The word may expand to other than exactly one argument: it contains an
    /// unquoted expansion or glob (word-splitting / pathname expansion), or a
    /// `$@` / `${arr[@]}` expansion that yields multiple arguments even when
    /// quoted. `quoted` alone does not prove single-argument — `""$x` is quoted
    /// yet `$x` still splits — so callers that need a provably single argument
    /// (e.g. an option value that must not smuggle extra options) check this.
    pub splits: bool,
    /// The word contains an expansion that can assign a shell variable when the
    /// shell evaluates it: arithmetic `$((x = ...))` (assignment operators are
    /// full arithmetic inside `$(( ))`) or a parameter expansion with an
    /// assignment-capable operator (`${x:=y}`, `${x+=y}`, `${x::=y}`). Such an
    /// expansion runs before the command it sits in, so a guard that inspects
    /// the command's own words never sees the write.
    pub assigns: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Redirect {
    pub op: String,
    pub target: Word,
}

/// A here-document body fed to a command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Heredoc {
    /// The raw body text between the operator line and the delimiter.
    pub body: String,
    /// The parent shell expands the body (so command substitutions and
    /// parameter expansions in it run) unless the delimiter was quoted
    /// (`<<'EOF'` / `<<"EOF"` / `<<\EOF`).
    pub expand: bool,
}

/// A simple command: words, redirections and here-document bodies.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Simple {
    pub words: Vec<Word>,
    pub redirects: Vec<Redirect>,
    pub heredocs: Vec<Heredoc>,
    /// Set when this command was lifted out of a loop header or loop
    /// condition's command substitution (`for f in "$(cmd)"`,
    /// `while cmd "$(sub)"; do ...`). The parser flattens substitutions ahead
    /// of their containing command, so such a command reaches the effect
    /// classifier before any loop frame exists; this flag lets the classifier
    /// still apply the loop's read-only rules to it.
    pub loop_header_sub: bool,
}

/// Whether the words parsed so far open a loop whose header or condition runs
/// on the parent shell. `for`/`select`/`while`/`until` begin such a loop, and a
/// command substitution in that header/condition is subject to the loop's
/// read-only rules even though the parser emits it first. The loop keyword can
/// sit behind leading control-flow keywords (`if true; then for f in "$(cmd)"`,
/// `! while ...`), so skip those first — mirroring
/// `permissions::loop_command_offset` — rather than only inspecting the first
/// word, or a header substitution after a control prefix slips through
/// unflagged before the loop frame exists.
fn opens_loop_header(words: &[Word]) -> bool {
    for word in words {
        if word.quoted {
            return false;
        }
        match word.text.as_str() {
            "for" | "select" | "while" | "until" => return true,
            "!" | "if" | "then" | "else" | "elif" | "do" | "{" | "}" | "fi" | "esac" => continue,
            _ => return false,
        }
    }
    false
}

/// Whether an arithmetic `$(( ... ))` body contains an assignment operator,
/// which writes a shell variable when the expansion runs. Inside arithmetic,
/// `=` and the compound forms (`+=`, `-=`, `*=`, `/=`, `%=`, `<<=`, `>>=`,
/// `&=`, `|=`, `^=`) assign; a bare `=` is not a comparison operator there
/// (equality is `==`), so any `=` that is not part of `==`, `<=`, `>=`, `!=`
/// assigns. A `<<=` / `>>=` is an assignment, not the comparison `<=` / `>=`
/// it ends with, so a `=` preceded by `<` / `>` only escapes classification as
/// an assignment when that predecessor is not itself a shift. Nested
/// `$( ( ... ) )` bodies arrive with their inner parens intact, so a nested
/// assignment (`$(( (x = 1) + 2 ))`) is still seen. The prefix/postfix
/// increment and decrement operators (`x++`, `--x`) also write their operand,
/// so any `++` / `--` counts as an assignment too.
pub(crate) fn arithmetic_assigns(body: &str) -> bool {
    // `++` / `--` increment or decrement (and thus write) their operand.
    // Arithmetic never needs two adjacent `+`/`-` for anything else (a double
    // negation is written `- -x` with a space), so treating the bare digraph
    // as an assignment is both correct and fail-closed.
    if body.contains("++") || body.contains("--") {
        return true;
    }
    let chars: Vec<char> = body.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        if c != '=' {
            continue;
        }
        let prev = i.checked_sub(1).and_then(|p| chars.get(p)).copied();
        let next = chars.get(i + 1).copied();
        if next == Some('=') {
            continue; // `==` (and the `=` of `<=`/`>=`/`!=` handled below)
        }
        match prev {
            Some('=') | Some('!') => continue,
            // `<=` / `>=` compare, but `<<=` / `>>=` assign.
            Some('<') | Some('>') => {
                let before = i.checked_sub(2).and_then(|p| chars.get(p)).copied();
                if before == prev {
                    return true; // `<<=` / `>>=`
                }
                continue;
            }
            _ => return true,
        }
    }
    false
}

/// Whether a `${ ... }` parameter-expansion body assigns its variable when the
/// expansion runs: the assignment-capable operators `:=`, `::=`, `+=` (and
/// `=`, which assigns only when the variable is unset — still a write) after a
/// plain variable name or positional parameter. Test operators (`:-`, `:?`,
/// `:+`, `-`, `?`, `+`), substring/length forms and pattern edits never
/// assign. An array subscript (`${a[i=1]}`, `${a[0]:=x}`) is itself an
/// arithmetic context, so a subscript that assigns — or any element
/// assignment — writes a variable and must be flagged too.
///
/// The *value* of any operator and the offset/length of a substring expansion
/// are evaluated too, so a nested expansion there runs its own writes:
/// `${x:-$((PATH=0))}` and `${missing:-${d:=/etc}}` assign through the default,
/// and `${text:PATH=0:1}` assigns through its arithmetic offset. Scan the whole
/// body for a nested `$(( ... ))` / `${ ... }` that assigns, and for a
/// substring offset/length that is an arithmetic assignment.
fn param_expansion_assigns(body: &str) -> bool {
    let mut chars = body.chars().peekable();
    // `$#` is a length prefix, not the parameter name.
    if chars.peek() == Some(&'#') && body.len() > 1 {
        chars.next();
    }
    // The parameter name: a plain identifier, a positional digit, or a special
    // parameter. Anything else (subscript, indirection) is not a simple
    // variable assignment this check needs to model.
    match chars.peek().copied() {
        Some(c) if c == '_' || c.is_ascii_alphabetic() => {
            while chars.peek().is_some_and(|&c| c == '_' || c.is_ascii_alphanumeric()) {
                chars.next();
            }
        }
        Some(c) if c.is_ascii_digit() => {
            while chars.peek().is_some_and(|&c| c.is_ascii_digit()) {
                chars.next();
            }
        }
        Some(c) if "@*#?$!-".contains(c) => {
            chars.next();
        }
        _ => return false,
    }
    // A subscript is an arithmetic context: `${a[i=1]}` sets `i` even when the
    // outer expansion only reads it. Fail closed on any assigning subscript.
    if chars.peek() == Some(&'[') {
        chars.next();
        let mut subscript = String::new();
        for c in chars.by_ref() {
            if c == ']' {
                break;
            }
            subscript.push(c);
        }
        if arithmetic_assigns(&subscript) {
            return true;
        }
    }
    let rest: String = chars.collect();
    if rest.starts_with("+=") || rest.starts_with('=') || rest.starts_with(":=") || rest.starts_with("::=") {
        return true;
    }
    // A substring expansion `${name:offset[:length]}` evaluates offset and
    // length as arithmetic; either can assign (`${text:PATH=0:1}`). The first
    // `:` after the name opens the offset (but `:-`, `:=`, `:+`, `:?`, `::=`
    // are operators, not substrings). Fail closed on an assigning offset.
    if let Some(offset) = rest.strip_prefix(':')
        && !offset.starts_with(['-', '=', '+', '?'])
    {
        // The offset runs to the next top-level `:` (the length) or the end.
        let offset = offset.split(':').next().unwrap_or("");
        if arithmetic_assigns(offset) {
            return true;
        }
    }
    // A nested expansion anywhere in the body runs when the outer one does, so
    // propagate its writes: `$(( ... ))` arithmetic and `${ ... }` parameter
    // expansions can both assign even when the outer operator only reads.
    nested_expansion_assigns(body)
}

/// Whether any `$(( ... ))` or `${ ... }` nested in `body` assigns a shell
/// variable. Only the innermost expansions matter — an outer arithmetic body is
/// already scanned by `arithmetic_assigns` — so this walks the text, and on
/// each nested expansion checks the assignment class for that form.
fn nested_expansion_assigns(body: &str) -> bool {
    let chars: Vec<char> = body.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '$' && i + 1 < chars.len() {
            if chars[i + 1] == '(' {
                // `$((` arithmetic, or `$(` command substitution (whose inner
                // commands the parser already models separately). Only the
                // arithmetic form is an assignment context here.
                let arith = i + 2 < chars.len() && chars[i + 2] == '(';
                let open = i + 1;
                let mut depth = 0usize;
                let mut j = open;
                while j < chars.len() {
                    match chars[j] {
                        '(' => depth += 1,
                        ')' => {
                            depth = depth.saturating_sub(1);
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    j += 1;
                }
                if arith {
                    let inner: String = chars[open + 2..j].iter().collect();
                    if arithmetic_assigns(&inner) {
                        return true;
                    }
                }
                i = j + 1;
                continue;
            } else if chars[i + 1] == '{' {
                let mut depth = 0usize;
                let mut j = i + 1;
                while j < chars.len() {
                    match chars[j] {
                        '{' => depth += 1,
                        '}' => {
                            depth = depth.saturating_sub(1);
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    j += 1;
                }
                let inner: String = chars[i + 2..j].iter().collect();
                if param_expansion_assigns(&inner) {
                    return true;
                }
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }
    false
}

/// Whether the words parsed so far are inside an open `[[ ... ]]` conditional,
/// where `<` and `>` are string-comparison operators rather than redirections.
/// `[[` only has that meaning in command position — possibly behind leading
/// control-flow keywords (`do [[ $a > $b ]]`, `! [[ ... ]]`, `if [[ ... ]]`,
/// `while [[ ... ]]`, `until [[ ... ]]`, mirroring
/// `permissions::loop_command_offset`). An `[[` that is an *operand*
/// (`echo [[ > out`) is ordinary text, so its `>` is a real redirection and
/// must not be treated as a comparison.
fn in_conditional(words: &[Word]) -> bool {
    let mut open = false;
    let mut seen_command = false;
    for w in words {
        if w.quoted || w.dynamic {
            // A quoted or computed word is never conditional syntax, and it
            // occupies command position if none was taken yet.
            if !seen_command {
                seen_command = true;
            }
            continue;
        }
        match w.text.as_str() {
            "[[" if !seen_command => {
                open = true;
                seen_command = true;
            }
            "]]" if open => open = false,
            "!" | "if" | "then" | "else" | "elif" | "do" | "while" | "until" | "{" | "}" | "fi" | "esac"
                if !seen_command => {}
            _ => seen_command = true,
        }
    }
    open
}

const MAX_DEPTH: usize = 16;
/// Parse a command line into its simple commands, including those inside
/// command substitutions.
pub fn parse(source: &str) -> Result<Vec<Simple>, String> {
    parse_nested(source, 0)
}

pub fn parse_nested(source: &str, depth: usize) -> Result<Vec<Simple>, String> {
    if depth > MAX_DEPTH {
        return Err("command nests too deeply to inspect".into());
    }
    let mut parser = Parser { chars: source.chars().collect(), pos: 0, depth, out: Vec::new(), case_depth: 0 };
    parser.script(false)?;
    Ok(parser.out)
}

struct PendingHeredoc {
    command: usize,
    delimiter: String,
    strip_tabs: bool,
    expand: bool,
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
    depth: usize,
    out: Vec<Simple>,
    case_depth: usize,
}

fn is_operator(c: char) -> bool {
    matches!(c, ';' | '&' | '|' | '(' | ')' | '<' | '>' | '\n')
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn peek_at(&self, offset: usize) -> Option<char> {
        self.chars.get(self.pos + offset).copied()
    }

    /// Decode one ANSI-C (`$'...'`) backslash escape, `self.pos` positioned just
    /// past the backslash. Bash interprets these escapes, so `\x72` means `r`:
    /// leaving it as the literal text `x72` would make the guard inspect the
    /// wrong command (`bash -c $'\x72m -rf /'` would look like the harmless
    /// `x72m`, hiding the real `rm`). Decode every well-defined escape so the
    /// true bytes are inspected, and fail closed on anything unrecognized by
    /// marking the word dynamic (untrusted) instead of trusting it as a literal.
    fn ansi_c_escape(&mut self, word: &mut Word) -> Result<(), String> {
        let next = self.peek().ok_or("unterminated $'...' string")?;
        self.pos += 1;
        let push_code = |word: &mut Word, val: u32| match char::from_u32(val) {
            Some(c) => word.text.push(c),
            None => word.dynamic = true,
        };
        match next {
            'a' => word.text.push('\u{07}'),
            'b' => word.text.push('\u{08}'),
            'e' | 'E' => word.text.push('\u{1b}'),
            'f' => word.text.push('\u{0c}'),
            'n' => word.text.push('\n'),
            'r' => word.text.push('\r'),
            't' => word.text.push('\t'),
            'v' => word.text.push('\u{0b}'),
            '\\' => word.text.push('\\'),
            '\'' => word.text.push('\''),
            '"' => word.text.push('"'),
            '?' => word.text.push('?'),
            'x' => {
                // `\xHH` — one or two hex digits.
                let mut val = 0u32;
                let mut n = 0;
                while n < 2 {
                    match self.peek().and_then(|c| c.to_digit(16)) {
                        Some(d) => {
                            val = val * 16 + d;
                            self.pos += 1;
                            n += 1;
                        }
                        None => break,
                    }
                }
                if n == 0 { word.text.push('x') } else { push_code(word, val) }
            }
            '0'..='7' => {
                // `\NNN` — up to three octal digits (the first already consumed).
                let mut val = next.to_digit(8).unwrap_or(0);
                let mut n = 1;
                while n < 3 {
                    match self.peek().and_then(|c| c.to_digit(8)) {
                        Some(d) => {
                            val = val * 8 + d;
                            self.pos += 1;
                            n += 1;
                        }
                        None => break,
                    }
                }
                push_code(word, val)
            }
            'u' | 'U' => {
                // `\uHHHH` / `\UHHHHHHHH` — up to 4 / 8 hex digits.
                let width = if next == 'u' { 4 } else { 8 };
                let mut val = 0u32;
                let mut n = 0;
                while n < width {
                    match self.peek().and_then(|c| c.to_digit(16)) {
                        Some(d) => {
                            val = val * 16 + d;
                            self.pos += 1;
                            n += 1;
                        }
                        None => break,
                    }
                }
                if n == 0 { word.text.push(next) } else { push_code(word, val) }
            }
            'c' => {
                // `\cX` — control character.
                match self.peek() {
                    Some(c) => {
                        self.pos += 1;
                        word.text.push(((c.to_ascii_uppercase() as u8) ^ 0x40) as char);
                    }
                    None => word.dynamic = true,
                }
            }
            other => {
                // Unrecognized escape: distrust the token so an unmodelled
                // encoding cannot masquerade as a benign literal.
                word.text.push(other);
                word.dynamic = true;
            }
        }
        Ok(())
    }

    fn eat(&mut self, c: char) -> bool {
        if self.peek() == Some(c) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    /// Parse commands until the end of input or, when `until_paren`, the
    /// `)` that closes a command substitution.
    fn script(&mut self, until_paren: bool) -> Result<(), String> {
        let mut current = Simple::default();
        let mut parens = 0usize;
        let mut pending: Vec<PendingHeredoc> = Vec::new();
        loop {
            self.skip_blanks();
            let Some(c) = self.peek() else {
                if until_paren {
                    return Err("unterminated command substitution".into());
                }
                if parens > 0 {
                    return Err("unmatched (".into());
                }
                self.flush(&mut current, &mut pending);
                return Ok(());
            };
            match c {
                '#' => {
                    while self.peek().is_some_and(|c| c != '\n') {
                        self.pos += 1;
                    }
                }
                '\n' => {
                    self.pos += 1;
                    self.flush(&mut current, &mut pending);
                    for heredoc in pending.drain(..) {
                        let body = self.heredoc_body(&heredoc.delimiter, heredoc.strip_tabs);
                        if let Some(command) = self.out.get_mut(heredoc.command) {
                            command.heredocs.push(Heredoc { body, expand: heredoc.expand });
                        }
                    }
                }
                ';' | '&' | '|' => {
                    if c == '&' && self.peek_at(1) == Some('>') {
                        self.redirect(&mut current, &mut pending)?;
                        continue;
                    }
                    // Inside `[[ ... ]]`, `&&` and `||` are conditional
                    // conjunctions/disjunctions, not command separators
                    // (`[[ -f m && -r m ]]` is one test). Keep them as plain
                    // words so the conditional stays a single command until
                    // `]]`; a single `&`/`|`/`;` still separates commands.
                    let doubled = self.peek_at(1) == Some(c);
                    if doubled && c != ';' && in_conditional(&current.words) {
                        current.words.push(Word { text: format!("{c}{c}"), ..Default::default() });
                        self.pos += 2;
                        continue;
                    }
                    self.pos += 1;
                    // `&&`, `||`, `|&`, `;;`, `;&`, `;;&`
                    while self.peek().is_some_and(|n| matches!(n, '&' | '|' | ';')) {
                        self.pos += 1;
                    }
                    self.flush(&mut current, &mut pending);
                }
                '(' => {
                    self.pos += 1;
                    parens += 1;
                    self.flush(&mut current, &mut pending);
                }
                ')' => {
                    self.pos += 1;
                    if parens > 0 {
                        parens -= 1;
                        self.flush(&mut current, &mut pending);
                    } else if self.case_depth > 0 {
                        // A `case` pattern such as `a|b)`.
                        current = Simple::default();
                    } else if until_paren {
                        self.flush(&mut current, &mut pending);
                        if !pending.is_empty() {
                            return Err("here-document inside a command substitution".into());
                        }
                        return Ok(());
                    } else {
                        return Err("unmatched )".into());
                    }
                }
                '<' | '>' => {
                    if self.peek_at(1) == Some('(') {
                        // Process substitution <(...) / >(...).
                        self.pos += 2;
                        let out_start = self.out.len();
                        self.substitution()?;
                        if opens_loop_header(&current.words) {
                            self.mark_loop_header_subs(out_start);
                        }
                        current.words.push(Word { text: "/dev/fd/63".into(), dynamic: true, ..Default::default() });
                    } else if in_conditional(&current.words) {
                        // Inside `[[ ... ]]`, `<` and `>` are string-comparison
                        // operators, not redirections (`[[ $a > $b ]]` compares,
                        // it does not write a file named `$b`). Record the
                        // operator as a plain word; a real redirect after `]]`
                        // still parses normally because `]]` ends the conditional.
                        current.words.push(Word { text: c.to_string(), ..Default::default() });
                        self.pos += 1;
                    } else {
                        self.redirect(&mut current, &mut pending)?;
                    }
                }
                _ => {
                    if c.is_ascii_digit() && self.is_fd_redirect() {
                        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                            self.pos += 1;
                        }
                        self.redirect(&mut current, &mut pending)?;
                        continue;
                    }
                    let in_loop_head = opens_loop_header(&current.words);
                    let out_start = self.out.len();
                    let word = self.word()?;
                    if in_loop_head {
                        self.mark_loop_header_subs(out_start);
                    }
                    if current.words.is_empty() && !word.quoted {
                        match word.text.as_str() {
                            "case" => self.case_depth += 1,
                            "esac" => self.case_depth = self.case_depth.saturating_sub(1),
                            _ => {}
                        }
                    }
                    current.words.push(word);
                }
            }
        }
    }

    fn is_fd_redirect(&self) -> bool {
        let mut i = self.pos;
        while self.chars.get(i).is_some_and(|c| c.is_ascii_digit()) {
            i += 1;
        }
        matches!(self.chars.get(i), Some('<' | '>'))
    }

    /// End the current simple command; here-documents it opened now know
    /// which command their body belongs to.
    fn flush(&mut self, current: &mut Simple, pending: &mut [PendingHeredoc]) {
        let simple = std::mem::take(current);
        // The pattern list of `case WORD in PATTERN|...` is not a command.
        let case_head = simple.words.first().is_some_and(|w| !w.quoted && w.text == "case");
        if !case_head && (!simple.words.is_empty() || !simple.redirects.is_empty()) {
            self.out.push(simple);
            let index = self.out.len() - 1;
            for heredoc in pending.iter_mut().filter(|h| h.command == usize::MAX) {
                heredoc.command = index;
            }
        }
    }

    fn skip_blanks(&mut self) {
        loop {
            match self.peek() {
                Some(' ' | '\t' | '\r') => self.pos += 1,
                Some('\\') if self.peek_at(1) == Some('\n') => self.pos += 2,
                _ => return,
            }
        }
    }

    /// Flag every command emitted since `out_start` as a loop header/condition
    /// substitution. The parser appends a substitution's inner commands to
    /// `out` before flushing their containing command, so these are the
    /// commands lifted out of the loop header or condition currently being
    /// parsed; the effect classifier must hold them to the loop's read-only
    /// rules even though no loop frame exists when it reaches them.
    fn mark_loop_header_subs(&mut self, out_start: usize) {
        for simple in self.out[out_start..].iter_mut() {
            simple.loop_header_sub = true;
        }
    }

    fn redirect(&mut self, current: &mut Simple, pending: &mut Vec<PendingHeredoc>) -> Result<(), String> {
        let start = self.pos;
        if self.eat('&') {
            self.eat('>');
            self.eat('>');
        } else if self.eat('<') {
            if self.eat('<') {
                if self.eat('<') {
                    // here-string
                } else {
                    self.eat('-');
                }
            } else {
                let _ = self.eat('&') || self.eat('>');
            }
        } else if self.eat('>') {
            let _ = self.eat('>') || self.eat('|') || self.eat('&');
        }
        let op: String = self.chars[start..self.pos].iter().collect();
        self.skip_blanks();
        if self.peek().is_none_or(|c| is_operator(c) && c != '<' && c != '>') {
            return Err(format!("redirection {op} has no target"));
        }
        // A command substitution in a redirect target of a loop header or
        // condition (`while read x < "$(touch out)"; do ...`) runs on the parent
        // shell, but the target is parsed here via `word()` rather than the main
        // loop, so mark its substitutions as header substitutions too.
        let out_start = self.out.len();
        let target = self.word()?;
        if opens_loop_header(&current.words) {
            self.mark_loop_header_subs(out_start);
        }
        if op == "<<" || op == "<<-" {
            // The body belongs to the current command, which gets its index when flushed.
            // A quoted delimiter (`<<'EOF'`) disables expansion of the body.
            pending.push(PendingHeredoc {
                command: usize::MAX,
                delimiter: target.text.clone(),
                strip_tabs: op == "<<-",
                expand: !target.quoted,
            });
        }
        current.redirects.push(Redirect { op, target });
        Ok(())
    }

    fn heredoc_body(&mut self, delimiter: &str, strip_tabs: bool) -> String {
        let mut body = String::new();
        while self.pos < self.chars.len() {
            let start = self.pos;
            while self.peek().is_some_and(|c| c != '\n') {
                self.pos += 1;
            }
            let line: String = self.chars[start..self.pos].iter().collect();
            self.eat('\n');
            let candidate = if strip_tabs { line.trim_start_matches('\t') } else { line.as_str() };
            if candidate == delimiter {
                break;
            }
            body.push_str(&line);
            body.push('\n');
        }
        body
    }

    /// Parse a `$(...)` body (the opening `$(` already consumed) as commands.
    fn substitution(&mut self) -> Result<(), String> {
        if self.depth >= MAX_DEPTH {
            return Err("command nests too deeply to inspect".into());
        }
        let mut inner = Parser {
            chars: std::mem::take(&mut self.chars),
            pos: self.pos,
            depth: self.depth + 1,
            out: Vec::new(),
            case_depth: 0,
        };
        let result = inner.script(true);
        self.chars = std::mem::take(&mut inner.chars);
        self.pos = inner.pos;
        result?;
        self.out.extend(inner.out);
        Ok(())
    }

    fn backtick(&mut self) -> Result<(), String> {
        let mut inner = String::new();
        loop {
            match self.peek() {
                None => return Err("unterminated backtick".into()),
                Some('`') => {
                    self.pos += 1;
                    break;
                }
                Some('\\') if matches!(self.peek_at(1), Some('`' | '\\' | '$')) => {
                    inner.push(self.chars[self.pos + 1]);
                    self.pos += 2;
                }
                Some(c) => {
                    inner.push(c);
                    self.pos += 1;
                }
            }
        }
        let commands = parse_nested(&inner, self.depth + 1)?;
        self.out.extend(commands);
        Ok(())
    }

    /// Skip a balanced `${...}` or `$((...))` body, returning its text. Command
    /// substitutions (`$(...)`, backticks) nested in the body are still parsed,
    /// since bash evaluates them; otherwise a destructive command hidden inside
    /// an expansion (`${X:-$(rm -rf /)}`, `$(( $(rm -rf /) ))`) would go unseen.
    fn balanced(&mut self, open: char, close: char) -> Result<String, String> {
        let start = self.pos;
        let mut level = 1;
        while let Some(c) = self.peek() {
            match c {
                '\\' => self.pos += 2,
                '\'' if open == '{' => {
                    self.pos += 1;
                    while self.peek().is_some_and(|c| c != '\'') {
                        self.pos += 1;
                    }
                    self.pos += 1;
                }
                '`' => {
                    self.pos += 1;
                    self.backtick()?;
                }
                '$' if self.peek_at(1) == Some('(') && self.peek_at(2) == Some('(') => {
                    self.pos += 3;
                    self.balanced('(', ')')?;
                    self.eat(')');
                }
                '$' if self.peek_at(1) == Some('(') => {
                    self.pos += 2;
                    self.substitution()?;
                }
                c if c == open => {
                    self.pos += 1;
                    level += 1;
                }
                c if c == close => {
                    self.pos += 1;
                    level -= 1;
                    if level == 0 {
                        return Ok(self.chars[start..self.pos - 1].iter().collect());
                    }
                }
                _ => self.pos += 1,
            }
        }
        Err(format!("unterminated {open}"))
    }

    /// `$...` at the current position (the `$` not yet consumed). `quoted` is
    /// true when the expansion sits inside double quotes, where most expansions
    /// stay a single argument; an unquoted expansion (and a quoted `$@` /
    /// `${arr[@]}`) can produce multiple arguments, which sets `word.splits`.
    fn dollar(&mut self, word: &mut Word, quoted: bool) -> Result<(), String> {
        self.pos += 1;
        match self.peek() {
            Some('(') if self.peek_at(1) == Some('(') => {
                self.pos += 2;
                let body = self.balanced('(', ')')?;
                self.eat(')');
                word.text.push_str(&format!("$(({body}))"));
                word.dynamic = true;
                if !quoted {
                    word.splits = true;
                }
                // Arithmetic assignment operators (`$((x = 1))`, `$((x += 1))`)
                // write a shell variable when the expansion runs.
                if arithmetic_assigns(&body) {
                    word.assigns = true;
                }
            }
            Some('(') => {
                self.pos += 1;
                self.substitution()?;
                word.text.push_str("$(...)");
                word.dynamic = true;
                if !quoted {
                    word.splits = true;
                }
            }
            Some('{') => {
                self.pos += 1;
                let body = self.balanced('{', '}')?;
                word.text.push_str(&format!("${{{body}}}"));
                word.dynamic = true;
                // `${arr[@]}` and the positional list `${@}` (plain or sliced,
                // `${@:1}`) yield one argument per element even when quoted;
                // any unquoted expansion word-splits.
                if !quoted || body.contains("[@]") || body.starts_with('@') {
                    word.splits = true;
                }
                // `${x:=y}`, `${x+=y}` and friends assign the variable when the
                // expansion runs.
                if param_expansion_assigns(&body) {
                    word.assigns = true;
                }
            }
            Some(c) if c.is_ascii_alphanumeric() || c == '_' => {
                word.text.push('$');
                while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || c == '_') {
                    word.text.push(self.chars[self.pos]);
                    self.pos += 1;
                }
                word.dynamic = true;
                if !quoted {
                    word.splits = true;
                }
            }
            Some(c) if "@*#?$!-".contains(c) => {
                word.text.push('$');
                word.text.push(c);
                self.pos += 1;
                word.dynamic = true;
                // `$@` expands to multiple arguments even inside quotes; the
                // other special parameters are single, but any unquoted
                // expansion still word-splits.
                if !quoted || c == '@' {
                    word.splits = true;
                }
            }
            _ => word.text.push('$'),
        }
        Ok(())
    }

    fn word(&mut self) -> Result<Word, String> {
        let mut word = Word::default();
        while let Some(c) = self.peek() {
            match c {
                ' ' | '\t' | '\r' => break,
                c if is_operator(c) => break,
                '\\' => {
                    self.pos += 1;
                    match self.peek() {
                        Some('\n') => self.pos += 1,
                        Some(next) => {
                            word.text.push(next);
                            word.quoted = true;
                            self.pos += 1;
                        }
                        None => word.text.push('\\'),
                    }
                }
                '\'' => {
                    self.pos += 1;
                    word.quoted = true;
                    loop {
                        match self.peek() {
                            None => return Err("unterminated single quote".into()),
                            Some('\'') => {
                                self.pos += 1;
                                break;
                            }
                            Some(c) => {
                                word.text.push(c);
                                self.pos += 1;
                            }
                        }
                    }
                }
                '"' => {
                    self.pos += 1;
                    word.quoted = true;
                    loop {
                        match self.peek() {
                            None => return Err("unterminated double quote".into()),
                            Some('"') => {
                                self.pos += 1;
                                break;
                            }
                            Some('\\') if matches!(self.peek_at(1), Some('"' | '\\' | '$' | '`' | '\n')) => {
                                let next = self.chars[self.pos + 1];
                                if next != '\n' {
                                    word.text.push(next);
                                }
                                self.pos += 2;
                            }
                            Some('$') => self.dollar(&mut word, true)?,
                            Some('`') => {
                                self.pos += 1;
                                self.backtick()?;
                                word.text.push_str("$(...)");
                                word.dynamic = true;
                            }
                            Some(c) => {
                                word.text.push(c);
                                self.pos += 1;
                            }
                        }
                    }
                }
                '$' if self.peek_at(1) == Some('\'') => {
                    self.pos += 2;
                    word.quoted = true;
                    loop {
                        match self.peek() {
                            None => return Err("unterminated $'...' string".into()),
                            Some('\'') => {
                                self.pos += 1;
                                break;
                            }
                            Some('\\') => {
                                self.pos += 1;
                                self.ansi_c_escape(&mut word)?;
                            }
                            Some(c) => {
                                word.text.push(c);
                                self.pos += 1;
                            }
                        }
                    }
                }
                '$' => self.dollar(&mut word, false)?,
                '`' => {
                    self.pos += 1;
                    self.backtick()?;
                    word.text.push_str("$(...)");
                    word.dynamic = true;
                    word.splits = true;
                }
                '*' | '?' | '[' => {
                    word.glob = true;
                    word.splits = true;
                    word.text.push(c);
                    self.pos += 1;
                }
                '{' => {
                    // Unquoted brace expansion (`{a,b}`) yields one argument
                    // per alternative, so the word can split into several
                    // (e.g. `sort -T {/tmp,-oout}` supplies `-T /tmp -oout`).
                    // Quoted/escaped braces are literal and handled above.
                    word.text.push(c);
                    self.pos += 1;
                    let mut depth = 1usize;
                    let mut has_comma = false;
                    while let Some(c) = self.peek() {
                        if is_operator(c) || matches!(c, ' ' | '\t' | '\r') {
                            break;
                        }
                        match c {
                            '{' => depth += 1,
                            '}' => {
                                depth = depth.saturating_sub(1);
                                if depth == 0 {
                                    word.text.push(c);
                                    self.pos += 1;
                                    break;
                                }
                            }
                            ',' if depth == 1 => has_comma = true,
                            _ => {}
                        }
                        word.text.push(c);
                        self.pos += 1;
                    }
                    if has_comma {
                        word.splits = true;
                    }
                }
                _ => {
                    word.text.push(c);
                    self.pos += 1;
                }
            }
        }
        Ok(word)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(source: &str) -> Vec<Vec<String>> {
        parse(source).unwrap().into_iter().map(|s| s.words.into_iter().map(|w| w.text).collect()).collect()
    }

    #[test]
    fn splits_on_operators() {
        assert_eq!(
            words("ls -la && rm -rf / ; echo 'a b' | wc -l || true & sleep 1\ngit status"),
            vec![
                vec!["ls", "-la"],
                vec!["rm", "-rf", "/"],
                vec!["echo", "a b"],
                vec!["wc", "-l"],
                vec!["true"],
                vec!["sleep", "1"],
                vec!["git", "status"],
            ]
        );
    }

    #[test]
    fn unquotes_and_marks_dynamic_and_glob() {
        let parsed = parse(r#"rm -rf "$HOME"/x \* '*' * ${D:?}/y"#).unwrap();
        let w = &parsed[0].words;
        assert_eq!(w[2].text, "$HOME/x");
        assert!(w[2].dynamic && w[2].quoted);
        assert!(!w[3].glob && w[3].text == "*");
        assert!(!w[4].glob);
        assert!(w[5].glob && !w[5].quoted);
        assert_eq!(w[6].text, "${D:?}/y");
    }

    #[test]
    fn parses_substitutions_as_commands() {
        assert_eq!(
            words(r#"echo "$(rm -rf / )" `mkfs /dev/sda` $(( 1 + 2 )) <(dd of=/dev/sda)"#),
            vec![
                vec!["rm", "-rf", "/"],
                vec!["mkfs", "/dev/sda"],
                vec!["dd", "of=/dev/sda"],
                vec!["echo", "$(...)", "$(...)", "$(( 1 + 2 ))", "/dev/fd/63"],
            ]
        );
    }

    #[test]
    fn nested_command_substitutions_are_inspected() {
        // Command substitutions hidden inside arithmetic or parameter expansions
        // are parsed, so the destructive command is seen rather than skipped.
        assert_eq!(
            words(r#"echo $(( $(rm -rf /) ))"#),
            vec![vec!["rm", "-rf", "/"], vec!["echo", "$(( $(rm -rf /) ))"]]
        );
        assert_eq!(
            words(r#"echo "${X:-$(rm -rf /)}""#),
            vec![vec!["rm", "-rf", "/"], vec!["echo", "${X:-$(rm -rf /)}"]]
        );
        assert_eq!(
            words(r#"echo "${X:-`mkfs /dev/sda`}""#),
            vec![vec!["mkfs", "/dev/sda"], vec!["echo", "${X:-`mkfs /dev/sda`}"]]
        );
    }

    #[test]
    fn records_redirects_and_heredocs() {
        let parsed = parse("cat > /dev/sda 2>&1 <<EOF\nDROP DATABASE x;\nEOF\necho done").unwrap();
        assert_eq!(parsed[0].redirects[0].op, ">");
        assert_eq!(parsed[0].redirects[0].target.text, "/dev/sda");
        assert_eq!(parsed[0].redirects[1].op, ">&");
        assert_eq!(parsed[0].heredocs, vec![Heredoc { body: "DROP DATABASE x;\n".into(), expand: true }]);
        assert_eq!(parsed[1].words[0].text, "echo");
        let parsed = parse("psql <<-'SQL' && echo ok\n\tDROP TABLE t;\n\tSQL\n").unwrap();
        assert_eq!(parsed[0].heredocs, vec![Heredoc { body: "\tDROP TABLE t;\n".into(), expand: false }]);
        assert_eq!(parsed[1].words[0].text, "echo");
    }

    #[test]
    fn handles_subshells_groups_and_case() {
        assert_eq!(words("(cd x && rm -rf y)"), vec![vec!["cd", "x"], vec!["rm", "-rf", "y"]]);
        assert_eq!(words("{ rm a; }"), vec![vec!["{", "rm", "a"], vec!["}"]]);
        assert_eq!(
            words("case $x in a|b) rm a ;; *) echo no ;; esac"),
            vec![vec!["rm", "a"], vec!["echo", "no"], vec!["esac"]]
        );
    }

    #[test]
    fn fails_closed_on_malformed_input() {
        for bad in ["echo 'x", "echo \"x", "echo $(ls", "echo `ls", "ls )", "(ls", "echo ${x"] {
            assert!(parse(bad).is_err(), "{bad}");
        }
        let deep = "$(".repeat(40) + &")".repeat(40);
        assert!(parse(&format!("echo {deep}")).is_err());
    }

    /// Round-9 advisory: unquoted `{a,b}` expands to one argument per
    /// alternative, so it must set `splits` (the option-value consumers rely on
    /// it to reject smuggled extra options).
    #[test]
    fn unquoted_brace_expansion_splits() {
        let brace = parse("sort -T {/tmp,-oout} input").unwrap().remove(0).words.remove(2);
        assert_eq!(brace.text, "{/tmp,-oout}");
        assert!(brace.splits, "brace expansion must split");
        // A brace without a comma (`{a}`, a `{ ...; }` group word) does not
        // expand to multiple arguments.
        let plain = parse("echo {a}").unwrap().remove(0).words.remove(1);
        assert!(!plain.splits, "single brace word stays one argument");
        // Quoted braces are literal, not expansion.
        let quoted = parse("echo '{a,b}'").unwrap().remove(0).words.remove(1);
        assert!(!quoted.splits, "quoted braces are literal");
    }

    /// Round-9 advisory: nested expansions and substring offsets are evaluated
    /// when the outer expansion runs, so their writes must flag `assigns`.
    #[test]
    fn nested_and_substring_expansions_assign() {
        let nested_arith = parse("echo \"${x:-$((PATH=0))}\"").unwrap().remove(0).words.remove(1);
        assert!(nested_arith.assigns, "${{x:-$((PATH=0))}} assigns PATH");
        let nested_param = parse("echo \"${missing:-${d:=/etc}}\"").unwrap().remove(0).words.remove(1);
        assert!(nested_param.assigns, "${{missing:-${{d:=/etc}}}} assigns d");
        let substring = parse("echo \"${text:PATH=0:1}\"").unwrap().remove(0).words.remove(1);
        assert!(substring.assigns, "${{text:PATH=0:1}} assigns PATH via offset");
        // Read-only forms stay clean.
        let read = parse("echo \"${x:-default}\"").unwrap().remove(0).words.remove(1);
        assert!(!read.assigns, "${{x:-default}} only reads");
        let sub = parse("echo \"${text:0:1}\"").unwrap().remove(0).words.remove(1);
        assert!(!sub.assigns, "${{text:0:1}} has a constant offset");
    }

    /// Round-9 advisory: `&&` / `||` inside `[[ ... ]]` are conditional
    /// logic, not command separators, so the conditional stays one command.
    #[test]
    fn logical_operators_stay_inside_conditional() {
        // The whole `[[ ... && ... ]]` is a single command; nothing splits off.
        let cmds = parse("while [[ -f marker && -r marker ]]; do cat marker; break; done").unwrap();
        assert!(
            cmds.iter().any(|s| s.words.iter().any(|w| w.text == "&&")),
            "the && should be a word inside the conditional, got {cmds:?}"
        );
        assert!(
            !cmds.iter().any(|s| s.words.first().is_some_and(|w| w.text == "-r")),
            "no command should start at -r, got {cmds:?}"
        );
        let cmds = parse("for f in a z; do [[ \"$f\" == a || \"$f\" == z ]]; done").unwrap();
        assert!(
            cmds.iter().any(|s| s.words.iter().any(|w| w.text == "||")),
            "the || should be a word inside the conditional, got {cmds:?}"
        );
    }
}
