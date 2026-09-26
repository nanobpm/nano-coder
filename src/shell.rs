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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Redirect {
    pub op: String,
    pub target: Word,
}

/// A simple command: words, redirections and here-document bodies.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Simple {
    pub words: Vec<Word>,
    pub redirects: Vec<Redirect>,
    pub heredocs: Vec<String>,
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
                            command.heredocs.push(body);
                        }
                    }
                }
                ';' | '&' | '|' => {
                    if c == '&' && self.peek_at(1) == Some('>') {
                        self.redirect(&mut current, &mut pending)?;
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
                        self.substitution()?;
                        current.words.push(Word { text: "/dev/fd/63".into(), dynamic: true, ..Default::default() });
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
                    let word = self.word()?;
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
        let target = self.word()?;
        if op == "<<" || op == "<<-" {
            // The body belongs to the current command, which gets its index when flushed.
            pending.push(PendingHeredoc { command: usize::MAX, delimiter: target.text.clone(), strip_tabs: op == "<<-" });
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

    /// `$...` at the current position (the `$` not yet consumed).
    fn dollar(&mut self, word: &mut Word) -> Result<(), String> {
        self.pos += 1;
        match self.peek() {
            Some('(') if self.peek_at(1) == Some('(') => {
                self.pos += 2;
                let body = self.balanced('(', ')')?;
                self.eat(')');
                word.text.push_str(&format!("$(({body}))"));
                word.dynamic = true;
            }
            Some('(') => {
                self.pos += 1;
                self.substitution()?;
                word.text.push_str("$(...)");
                word.dynamic = true;
            }
            Some('{') => {
                self.pos += 1;
                let body = self.balanced('{', '}')?;
                word.text.push_str(&format!("${{{body}}}"));
                word.dynamic = true;
            }
            Some(c) if c.is_ascii_alphanumeric() || c == '_' => {
                word.text.push('$');
                while self.peek().is_some_and(|c| c.is_ascii_alphanumeric() || c == '_') {
                    word.text.push(self.chars[self.pos]);
                    self.pos += 1;
                }
                word.dynamic = true;
            }
            Some(c) if "@*#?$!-".contains(c) => {
                word.text.push('$');
                word.text.push(c);
                self.pos += 1;
                word.dynamic = true;
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
                            Some('$') => self.dollar(&mut word)?,
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
                                let next = self.peek_at(1).ok_or("unterminated $'...' string")?;
                                word.text.push(match next {
                                    'n' => '\n',
                                    't' => '\t',
                                    'r' => '\r',
                                    '0' => '\0',
                                    other => other,
                                });
                                self.pos += 2;
                            }
                            Some(c) => {
                                word.text.push(c);
                                self.pos += 1;
                            }
                        }
                    }
                }
                '$' => self.dollar(&mut word)?,
                '`' => {
                    self.pos += 1;
                    self.backtick()?;
                    word.text.push_str("$(...)");
                    word.dynamic = true;
                }
                '*' | '?' | '[' => {
                    word.glob = true;
                    word.text.push(c);
                    self.pos += 1;
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
        parse(source)
            .unwrap()
            .into_iter()
            .map(|s| s.words.into_iter().map(|w| w.text).collect())
            .collect()
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
        assert_eq!(parsed[0].heredocs, vec!["DROP DATABASE x;\n"]);
        assert_eq!(parsed[1].words[0].text, "echo");
        let parsed = parse("psql <<-'SQL' && echo ok\n\tDROP TABLE t;\n\tSQL\n").unwrap();
        assert_eq!(parsed[0].heredocs, vec!["\tDROP TABLE t;\n"]);
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
}
