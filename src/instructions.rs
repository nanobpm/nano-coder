//! Instruction files: the user's own (`~/.claude/CLAUDE.md`, `~/.agents/AGENTS.md`,
//! `~/.claude/rules/`) and the repository's (AGENTS.md and friends,
//! `CLAUDE.local.md`, `.claude/rules/`), with Claude Code's `@path` imports.
//!
//! At session start the user's files come first, then the files from the git
//! root down to the working directory, outermost first, so the model has them
//! before it makes any change. Files in deeper directories, and rules scoped
//! with `paths:` front matter, are attached to the first file-tool result that
//! touches a matching path.
//!
//! Imports in project files may not leave the repository unless
//! `instruction_imports_outside_project` is set: a committed `CLAUDE.md` must
//! not be able to send `~/.ssh/...` to the model provider.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use regex::Regex;

/// Per-file cap; longer files are truncated with a note.
const MAX_FILE_BYTES: usize = 32 * 1024;
/// Cap on everything added to the system prompt.
const MAX_TOTAL_BYTES: usize = 64 * 1024;
/// Imports nest at most this deep (Claude Code: four hops).
const MAX_IMPORT_DEPTH: usize = 4;
/// Patterns one rule's `paths` may expand to (brace expansion).
const MAX_RULE_PATTERNS: usize = 1_000;

pub const DEFAULT_FILES: [&str; 4] = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".github/copilot-instructions.md"];
/// Personal per-directory files, loaded after the main file (not committed).
pub const LOCAL_FILES: [&str; 1] = ["CLAUDE.local.md"];
pub const DEFAULT_USER_FILES: [&str; 2] = ["~/.claude/CLAUDE.md", "~/.agents/AGENTS.md"];
pub const DEFAULT_USER_RULES_DIRS: [&str; 1] = ["~/.claude/rules"];
/// Project rules directory, relative to the git root.
const PROJECT_RULES_DIR: &str = ".claude/rules";

/// Where a loaded file came from.
#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    User,
    Project,
    Local,
    Rule,
    /// Imported with `@path` by the file at this path.
    Import(PathBuf),
}

#[derive(Debug, Clone, PartialEq)]
pub struct InstructionFile {
    pub path: PathBuf,
    pub text: String,
    pub kind: Kind,
    /// From the user's own configuration rather than the repository.
    pub user: bool,
}

/// What to load besides the per-directory project files.
#[derive(Debug, Clone, Default)]
pub struct Options {
    /// File names tried in each directory; the first that exists is used.
    pub names: Vec<String>,
    /// User instruction files (absolute, `~` already expanded); all that exist load.
    pub user_files: Vec<PathBuf>,
    /// User rules directories (absolute).
    pub user_rules_dirs: Vec<PathBuf>,
    /// Let imports in project files resolve outside the repository.
    pub imports_outside_project: bool,
}

impl Options {
    /// Project files only, as before user files existed (tests, embedders).
    #[cfg(test)]
    pub fn project(names: &[String]) -> Self {
        Self { names: names.to_vec(), ..Default::default() }
    }
}

/// A rule with `paths:` front matter, attached when a matching file is touched.
#[derive(Debug, Clone)]
struct ScopedRule {
    path: PathBuf,
    /// The body alone; `@path` imports resolve when the rule attaches, so an
    /// import of a rule that never matches cannot suppress the same import in
    /// a file that is actually rendered.
    body: String,
    patterns: Vec<Regex>,
    attached: bool,
    /// From the user's own configuration rather than the repository.
    user: bool,
}

#[derive(Debug, Default)]
pub struct ProjectInstructions {
    /// Git root (or the working directory outside a repository).
    root: PathBuf,
    options: Options,
    /// Files in the system prompt, in order.
    pub loaded: Vec<InstructionFile>,
    /// Files skipped, with the reason (imports outside the repository, ...).
    pub warnings: Vec<String>,
    /// Directories already searched (root..=cwd, plus nested ones seen).
    searched: HashSet<PathBuf>,
    /// Directories searched at session start (kept across compaction).
    initial: HashSet<PathBuf>,
    /// Files already loaded or attached (canonical), so each appears once.
    seen: HashSet<PathBuf>,
    /// `seen` at session start (kept across compaction).
    initial_seen: HashSet<PathBuf>,
    scoped: Vec<ScopedRule>,
}

pub(crate) fn git_root(start: &Path) -> Option<PathBuf> {
    start.ancestors().find(|dir| dir.join(".git").exists()).map(Path::to_path_buf)
}

/// Expand a leading `~` to the home directory.
pub fn expand_home(path: &str) -> PathBuf {
    match (path, dirs::home_dir()) {
        ("~", Some(home)) => home,
        (p, Some(home)) if p.starts_with("~/") => home.join(&p[2..]),
        (p, _) => PathBuf::from(p),
    }
}

fn read_capped(path: &Path) -> Option<String> {
    if !path.is_file() {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    let text = strip_html_comments(&String::from_utf8_lossy(&bytes));
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if text.len() <= MAX_FILE_BYTES {
        return Some(text.to_string());
    }
    let mut end = MAX_FILE_BYTES;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    Some(format!(
        "{}\n\n[... truncated: {} of {} bytes shown; read the full file with read_file]",
        &text[..end],
        end,
        text.len()
    ))
}

/// Leading spaces before a fence marker. CommonMark allows 0–3 spaces of
/// indentation; a tab or 4+ leading spaces makes the line an indented code
/// block, not a fence.
fn fence_indent(line: &str) -> Option<usize> {
    let spaces = line.bytes().take_while(|&b| b == b' ').count();
    if spaces > 3 || line[spaces..].starts_with('\t') {
        return None;
    }
    Some(spaces)
}

/// The opening fence of a Markdown code block on this line: its character
/// and the length of its backtick/tilde run. CommonMark closes a fence only
/// on a run of the same character at least as long, so the length matters.
fn fence(line: &str) -> Option<(char, usize)> {
    let indent = fence_indent(line)?;
    let t = &line[indent..];
    let ch = match t.chars().next() {
        Some(c @ ('`' | '~')) => c,
        _ => return None,
    };
    let run = t.chars().take_while(|&c| c == ch).count();
    if run < 3 {
        return None;
    }
    // A backtick fence's info string may not contain a backtick (CommonMark),
    // so a line like ``` ```rust ``` opens but ``` ``` ` ``` does not.
    if ch == '`' && t[run..].contains('`') {
        return None;
    }
    Some((ch, run))
}

/// Whether this line closes a fence opened as `open`: 0–3 spaces of indent, a
/// run of the same character at least as long as the opening run, and only
/// whitespace after it. A closing fence may not carry an info string, so a line
/// like ``` ```not-a-close ``` inside the block does **not** close it.
fn closes_fence(line: &str, open: (char, usize)) -> bool {
    let Some(indent) = fence_indent(line) else { return false };
    let t = &line[indent..];
    let run = t.chars().take_while(|&c| c == open.0).count();
    run >= open.1 && t[run..].trim().is_empty()
}

/// Whether this line is an indented code block (4+ spaces, or a leading tab):
/// its content is code, not Markdown, so HTML comments are not stripped from
/// it and `@path` imports are not expanded out of it — mirroring how fenced
/// code content is preserved.
fn is_indented_code(line: &str) -> bool {
    let mut spaces = 0usize;
    for b in line.bytes() {
        match b {
            b' ' => {
                spaces += 1;
                if spaces >= 4 {
                    return true;
                }
            }
            b'\t' => return true,
            _ => return false,
        }
    }
    false
}

/// Remove block-level `<!-- ... -->` comments (outside code blocks), as
/// Claude Code does before a CLAUDE.md reaches the model.
fn strip_html_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_fence: Option<(char, usize)> = None;
    let mut in_comment = false;
    for line in text.split_inclusive('\n') {
        if in_comment {
            if let Some(end) = line.find("-->") {
                in_comment = false;
                let rest = &line[end + 3..];
                if !rest.trim().is_empty() {
                    out.push_str(rest);
                }
            }
            continue;
        }
        if let Some(open) = in_fence {
            if closes_fence(line, open) {
                in_fence = None;
            }
            out.push_str(line);
            continue;
        }
        if let Some(open) = fence(line) {
            in_fence = Some(open);
            out.push_str(line);
            continue;
        }
        if is_indented_code(line) {
            out.push_str(line);
            continue;
        }
        if let Some(body) = line.trim_start().strip_prefix("<!--") {
            match body.find("-->") {
                Some(end) => {
                    let rest = &body[end + 3..];
                    if !rest.trim().is_empty() {
                        out.push_str(rest);
                    }
                }
                None => in_comment = true,
            }
            continue;
        }
        out.push_str(line);
    }
    out
}

/// `@path` references outside code spans and fenced blocks, in order. A
/// reference starts at the beginning of a line or after whitespace or `(`,
/// so e-mail addresses don't count; `\ ` continues a path past a space.
fn import_refs(text: &str) -> Vec<String> {
    let mut refs = Vec::new();
    let mut in_fence: Option<(char, usize)> = None;
    // A code span opens with a run of N backticks and closes only on a run of
    // exactly N (CommonMark). The state lives across lines: a span may span a
    // line break, so resetting per line would parse the continuation as prose
    // and import a `@path` that is still inside the span.
    let mut span_ticks: Option<usize> = None;
    for line in text.lines() {
        if let Some(open) = in_fence {
            if closes_fence(line, open) {
                in_fence = None;
            }
            continue;
        }
        if let Some(open) = fence(line) {
            in_fence = Some(open);
            continue;
        }
        if is_indented_code(line) {
            continue;
        }
        let chars: Vec<char> = line.chars().collect();
        let mut i = 0;
        // A line that opens with a backtick/tilde run of three or more is a
        // fence candidate. When `fence()` rejects it (a backtick in the info
        // string, so it is prose per CommonMark) AND no code span is open,
        // that leading run is fence syntax, not a code-span opener: skip the
        // run, so it is not misread as opening or closing a multiline span.
        // But when a span IS open (carried across a line break), the line is
        // span content, not fence syntax: leave `span_ticks` alone and parse
        // the line normally, so the run can only close the span if its length
        // matches. Resetting an open span here would leak a `@path` that is
        // still inside it.
        let t = line.trim_start();
        if span_ticks.is_none() && (t.starts_with("```") || t.starts_with("~~~")) {
            let fc = t.chars().next().unwrap();
            i = line.chars().take_while(|&c| c == ' ').count() + t.chars().take_while(|&c| c == fc).count();
        }
        while i < chars.len() {
            let c = chars[i];
            if c == '`' {
                let start = i;
                while i < chars.len() && chars[i] == '`' {
                    i += 1;
                }
                let run = i - start;
                match span_ticks {
                    None => span_ticks = Some(run),
                    Some(open) if open == run => span_ticks = None,
                    Some(_) => {}
                }
                continue;
            }
            let starts = i == 0 || chars[i - 1].is_whitespace() || chars[i - 1] == '(';
            if span_ticks.is_some() || c != '@' || !starts {
                i += 1;
                continue;
            }
            let mut path = String::new();
            let mut j = i + 1;
            while j < chars.len() {
                match chars[j] {
                    '\\' if chars.get(j + 1) == Some(&' ') => {
                        path.push(' ');
                        j += 2;
                    }
                    ch if ch.is_whitespace() || ch == '`' => break,
                    ch => {
                        path.push(ch);
                        j += 1;
                    }
                }
            }
            if !path.is_empty() && !path.starts_with(['"', '\'']) {
                refs.push(path);
            }
            i = j;
        }
    }
    refs
}

/// Whether `@path` imports in this file are expanded: Claude-format files
/// only. `AGENTS.md` has no import syntax, and an `@name` there is a mention.
fn expands_imports(path: &Path, kind: &Kind) -> bool {
    matches!(kind, Kind::Rule | Kind::Import(_))
        || matches!(path.file_name().and_then(|n| n.to_str()), Some("CLAUDE.md" | "CLAUDE.local.md"))
}

/// Split a rule's front matter into its `paths` patterns (None: applies
/// everywhere) and the body. Accepts a YAML list, `[a, b]` or `a, b`.
fn rule_front_matter(text: &str) -> (Option<Vec<String>>, &str) {
    let mut lines = text.split_inclusive('\n');
    let Some(first) = lines.next() else { return (None, text) };
    if first.trim_end() != "---" {
        return (None, text);
    }
    let mut offset = first.len();
    let mut yaml = Vec::new();
    let mut closed = false;
    for line in lines {
        offset += line.len();
        if line.trim_end() == "---" {
            closed = true;
            break;
        }
        yaml.push(line.trim_end());
    }
    if !closed {
        return (None, text);
    }
    let unquote = |s: &str| -> String {
        let s = s.trim();
        let quoted =
            s.len() >= 2 && ((s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')));
        if quoted { s[1..s.len() - 1].to_string() } else { s.to_string() }
    };
    let mut paths: Option<Vec<String>> = None;
    let mut in_list = false;
    for line in yaml {
        if in_list {
            if let Some(item) = line.trim_start().strip_prefix('-').filter(|_| line.starts_with([' ', '\t', '-'])) {
                paths.get_or_insert_with(Vec::new).push(unquote(item));
                continue;
            }
            in_list = false;
        }
        let Some(value) = line.strip_prefix("paths:") else { continue };
        let value = value.trim();
        if value.is_empty() {
            in_list = true;
            paths.get_or_insert_with(Vec::new);
            continue;
        }
        let inner = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')).unwrap_or(value);
        paths = Some(split_top_level(inner).into_iter().map(unquote).collect());
    }
    let paths = paths.map(|p| p.into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>()).filter(|p| !p.is_empty());
    (paths, &text[offset.min(text.len())..])
}

/// Split a front-matter value on top-level commas only: commas inside a `{a,b}`
/// brace group or inside quotes belong to a single pattern, not a list boundary.
fn split_top_level(value: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut quote: Option<char> = None;
    let mut start = 0usize;
    for (i, c) in value.char_indices() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                }
            }
            None => match c {
                '"' | '\'' => quote = Some(c),
                '{' => depth += 1,
                '}' => depth = depth.saturating_sub(1),
                ',' if depth == 0 => {
                    out.push(&value[start..i]);
                    start = i + 1;
                }
                _ => {}
            },
        }
    }
    out.push(&value[start..]);
    out
}

/// Expand `{a,b}` groups; past `budget` patterns, keep the rest unexpanded.
fn expand_braces(pattern: &str, budget: &mut usize) -> Vec<String> {
    let Some(open) = pattern.find('{') else { return vec![pattern.to_string()] };
    let Some(close) = pattern[open..].find('}').map(|c| open + c) else { return vec![pattern.to_string()] };
    let alternatives: Vec<&str> = pattern[open + 1..close].split(',').collect();
    if alternatives.len() < 2 || *budget < alternatives.len() {
        return vec![pattern.to_string()];
    }
    *budget -= alternatives.len();
    let (head, tail) = (&pattern[..open], &pattern[close + 1..]);
    alternatives.iter().flat_map(|alt| expand_braces(&format!("{head}{alt}{tail}"), budget)).collect()
}

fn compile_patterns(patterns: &[String]) -> Vec<Regex> {
    let mut budget = MAX_RULE_PATTERNS;
    patterns
        .iter()
        .flat_map(|p| expand_braces(p.trim_start_matches("./"), &mut budget))
        .filter_map(|p| crate::permissions::path_glob(&p).ok())
        .collect()
}

/// `.md` files under `dir`, sorted, following symlinks without looping.
fn markdown_files(dir: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, visited: &mut HashSet<PathBuf>, out: &mut Vec<PathBuf>) {
        let Ok(real) = dir.canonicalize() else { return };
        // The canonical path is the loop guard: a directory already visited
        // (directly or through a symlink) is not entered again, so recursion
        // terminates even with symlink cycles. There is no depth cap — the
        // `**` lookup is advertised as recursive and must not silently drop
        // rules nested deeper than an arbitrary limit.
        if !visited.insert(real) {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
        paths.sort();
        for path in paths {
            if path.is_dir() {
                walk(&path, visited, out);
            } else if path.extension().is_some_and(|e| e == "md") && path.is_file() {
                out.push(path);
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, &mut HashSet::new(), &mut out);
    out
}

impl ProjectInstructions {
    /// Find the project instruction files that apply to `cwd` (no user files).
    #[cfg(test)]
    pub fn discover(cwd: &Path, names: &[String]) -> Self {
        Self::discover_with(cwd, Options::project(names))
    }

    /// Find the user's and the project's instruction files for `cwd`.
    pub fn discover_with(cwd: &Path, options: Options) -> Self {
        let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
        let root = git_root(&cwd).unwrap_or_else(|| cwd.clone());
        let mut this = Self { root, options, ..Default::default() };
        for path in this.options.user_files.clone() {
            this.load(path, Kind::User, true);
        }
        for dir in this.options.user_rules_dirs.clone() {
            this.load_rules(&dir, true);
        }
        let mut dirs: Vec<PathBuf> =
            cwd.ancestors().take_while(|d| d.starts_with(&this.root)).map(Path::to_path_buf).collect();
        dirs.reverse();
        for (i, dir) in dirs.iter().enumerate() {
            this.search(dir);
            if i == 0 {
                this.load_rules(&this.root.join(PROJECT_RULES_DIR), false);
            }
        }
        this.initial = this.searched.clone();
        this.initial_seen = this.seen.clone();
        this
    }

    /// Load the files for one directory: the first of `names`, then the
    /// local files. Returns what was added to `loaded`.
    fn search(&mut self, dir: &Path) -> std::ops::Range<usize> {
        let start = self.loaded.len();
        if !self.searched.insert(dir.to_path_buf()) {
            return start..start;
        }
        let names = self.options.names.clone();
        if let Some(path) = names.iter().map(|name| dir.join(name)).find(|p| read_capped(p).is_some()) {
            self.load(path, Kind::Project, false);
        }
        for name in LOCAL_FILES {
            self.load(dir.join(name), Kind::Local, false);
        }
        start..self.loaded.len()
    }

    /// Load one file (if it exists and is new) and, for Claude-format files,
    /// its imports after it.
    fn load(&mut self, path: PathBuf, kind: Kind, user: bool) {
        self.load_at(path, kind, user, 0, None);
    }

    /// Load one file (if it exists and is new) and, for Claude-format files,
    /// its imports. `body`, when given, replaces the file's on-disk text for
    /// both the stored content and import scanning — used when front matter is
    /// dropped, so `@path` references in that front matter are not expanded.
    fn load_at(&mut self, path: PathBuf, kind: Kind, user: bool, depth: usize, body: Option<String>) {
        let Some(disk) = read_capped(&path) else { return };
        // A committed file may itself be a symlink out of the repository
        // (`.claude/CLAUDE.md -> ~/.ssh/...`), so apply the same canonical
        // containment check rules get before its contents reach the prompt.
        // Done only after the file is known to exist, so a missing optional
        // file (whose `canonicalize` fails) is not mistaken for an escape.
        if !user && !self.options.imports_outside_project {
            let inside = path.canonicalize().is_ok_and(|real| {
                let root = self.root.canonicalize().unwrap_or_else(|_| self.root.clone());
                real.starts_with(&root)
            });
            if !inside {
                self.warnings.push(format!(
                    "skipped {}: links outside the repository (set instruction_imports_outside_project = true to allow)",
                    self.display(&path)
                ));
                return;
            }
        }
        let real = path.canonicalize().unwrap_or_else(|_| path.clone());
        if !self.seen.insert(real) {
            return;
        }
        let text = body.unwrap_or(disk);
        let refs = if expands_imports(&path, &kind) { import_refs(&text) } else { Vec::new() };
        self.loaded.push(InstructionFile { path: path.clone(), text, kind, user });
        if depth >= MAX_IMPORT_DEPTH {
            return;
        }
        for reference in refs {
            if let Some(target) = self.resolve_import(&path, &reference, user) {
                self.load_at(target, Kind::Import(path.clone()), user, depth + 1, None);
            }
        }
    }

    /// Resolve a scoped rule's body together with its `@path` imports into one
    /// block, at attachment time. Scoped rules are Claude-format, so their
    /// imports must be expanded rather than emitted literally; doing it on
    /// attachment (not at discovery) keeps a dormant rule's imports out of the
    /// shared canonical `seen` set, so they cannot suppress imports in files
    /// that are actually rendered. Resolution still shares the `seen` dedup,
    /// import depth, and outside-repository safety checks used for every other
    /// instruction file.
    fn resolve_scoped_rule(&mut self, path: &Path, body: &str, user: bool) -> Option<String> {
        let real = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        // Canonical "each file once": if this rule's file was already rendered
        // (an explicit @import, or an earlier matching rule), skip re-emitting
        // its body. `forget_nested` resets `seen`, so it attaches again later.
        if !self.seen.insert(real) {
            return None;
        }
        let mut out = body.to_string();
        self.append_rule_imports(path, body, user, 0, &mut out);
        Some(out)
    }

    fn append_rule_imports(&mut self, from: &Path, text: &str, user: bool, depth: usize, out: &mut String) {
        if depth >= MAX_IMPORT_DEPTH {
            return;
        }
        for reference in import_refs(text) {
            let Some(target) = self.resolve_import(from, &reference, user) else { continue };
            let real = target.canonicalize().unwrap_or_else(|_| target.clone());
            if !self.seen.insert(real) {
                continue;
            }
            let Some(imported) = read_capped(&target) else { continue };
            out.push_str(&format!(
                "\n\n## {} (imported by {})\n\n{}",
                self.display(&target),
                self.display(from),
                imported
            ));
            self.append_rule_imports(&target, &imported, user, depth + 1, out);
        }
    }

    /// Resolve `@reference` in `from`. Missing files are mentions, not
    /// imports, and are ignored; project imports outside the repository are
    /// skipped with a warning unless allowed.
    fn resolve_import(&mut self, from: &Path, reference: &str, user: bool) -> Option<PathBuf> {
        let candidates = [reference, reference.trim_end_matches(['.', ',', ';', ':', ')', '!', '?'])];
        let target = candidates.iter().find_map(|r| {
            let path = if r.starts_with('~') {
                expand_home(r)
            } else if Path::new(r).is_absolute() {
                PathBuf::from(r)
            } else {
                from.parent()?.join(r)
            };
            path.is_file().then_some(path)
        })?;
        if !user && !self.options.imports_outside_project {
            let real = target.canonicalize().ok()?;
            let root = self.root.canonicalize().unwrap_or_else(|_| self.root.clone());
            if !real.starts_with(&root) {
                self.warnings.push(format!(
                    "skipped import @{reference} in {}: outside the repository (set instruction_imports_outside_project = true to allow)",
                    self.display(from)
                ));
                return None;
            }
        }
        Some(target)
    }

    /// Rules under `dir`: unscoped ones load now, `paths:` ones on demand.
    fn load_rules(&mut self, dir: &Path, user: bool) {
        let root = self.root.canonicalize().unwrap_or_else(|_| self.root.clone());
        for path in markdown_files(dir) {
            if !user && !self.options.imports_outside_project {
                let inside = path.canonicalize().is_ok_and(|real| real.starts_with(&root));
                if !inside {
                    self.warnings.push(format!(
                        "skipped rule {}: links outside the repository (set instruction_imports_outside_project = true to allow)",
                        self.display(&path)
                    ));
                    continue;
                }
            }
            let Some(text) = read_capped(&path) else { continue };
            match rule_front_matter(&text) {
                (Some(patterns), body) => {
                    let body = body.trim();
                    if body.is_empty() {
                        continue;
                    }
                    let compiled = compile_patterns(&patterns);
                    if compiled.is_empty() {
                        self.warnings.push(format!("rule {} has no usable paths patterns", self.display(&path)));
                        continue;
                    }
                    self.scoped.push(ScopedRule { path, body: body.to_string(), patterns: compiled, attached: false, user });
                }
                (None, body) => {
                    let body = body.trim();
                    if body.is_empty() {
                        continue;
                    }
                    // Front matter without `paths` is dropped, as Claude Code
                    // does. Expand imports from the parsed body only, so an
                    // `@path` in the dropped front matter is not pulled in.
                    self.load_at(path, Kind::Rule, user, 0, Some(body.to_string()));
                }
            }
        }
    }

    fn display(&self, path: &Path) -> String {
        if let Ok(rel) = path.strip_prefix(&self.root) {
            return rel.display().to_string();
        }
        if let Some(home) = dirs::home_dir()
            && let Ok(rel) = path.strip_prefix(&home)
        {
            return format!("~/{}", rel.display());
        }
        path.display().to_string()
    }

    fn heading(&self, file: &InstructionFile) -> String {
        match &file.kind {
            Kind::Import(by) => format!("{} (imported by {})", self.display(&file.path), self.display(by)),
            Kind::Rule => format!("{} (rule)", self.display(&file.path)),
            Kind::Local => format!("{} (personal, not committed)", self.display(&file.path)),
            Kind::User | Kind::Project => self.display(&file.path),
        }
    }

    /// Text appended to the system prompt (empty when nothing was found).
    pub fn render(&self) -> String {
        // One bounded marker is reserved up front so the total never exceeds
        // `MAX_TOTAL_BYTES`, however many files are omitted. Group headers and
        // the marker are charged against the budget too, so a rules directory
        // with many files cannot grow the prompt past the cap.
        const MARKER: &str = "\n\n[omitted: instruction size limit reached; read the remaining files with read_file]";
        let mut out = String::new();
        let mut budget = MAX_TOTAL_BYTES.saturating_sub(MARKER.len());
        let mut truncated = false;
        let groups = [
            (
                true,
                "\n\n# Your instructions\n\nThese instruction files are the user's own, for every project. \
                 Follow them.",
            ),
            (
                false,
                "\n\n# Repository instructions\n\nThese instruction files come from the repository you are \
                 working in. Read and follow them before and while making changes. Files in deeper directories \
                 refine the ones above them.",
            ),
        ];
        'groups: for (user, header) in groups {
            let files: Vec<&InstructionFile> = self.loaded.iter().filter(|f| f.user == user).collect();
            if files.is_empty() {
                continue;
            }
            if header.len() > budget {
                truncated = true;
                break;
            }
            budget -= header.len();
            out.push_str(header);
            for file in files {
                let section = format!("\n\n## {}\n\n{}", self.heading(file), file.text);
                if section.len() > budget {
                    truncated = true;
                    break 'groups;
                }
                budget -= section.len();
                out.push_str(&section);
            }
        }
        if truncated {
            out.push_str(MARKER);
        }
        out
    }

    /// Instructions that apply to `path` and have not been shown yet: files
    /// in directories between it and the root (outermost first), then rules
    /// whose `paths` match it. Rendered for a tool result.
    pub fn nested_for(&mut self, path: &Path) -> Option<String> {
        let absolute = if path.is_absolute() { path.to_path_buf() } else { std::env::current_dir().ok()?.join(path) };
        let absolute = canonicalize_existing(&absolute);
        let dir = if absolute.is_dir() { absolute.as_path() } else { absolute.parent()? };
        let mut dirs: Vec<PathBuf> =
            dir.ancestors().take_while(|d| d.starts_with(&self.root)).map(Path::to_path_buf).collect();
        if dirs.is_empty() {
            return None;
        }
        dirs.reverse();
        // This text lands in a tool result (read_file skips its own bound for
        // it), so bound it here: one reserved marker keeps the total within
        // `MAX_TOTAL_BYTES` however many files or rules match.
        const MARKER: &str = "\n\n[omitted: instruction size limit reached; read the remaining files with read_file]";
        let mut out = String::new();
        let mut budget = MAX_TOTAL_BYTES.saturating_sub(MARKER.len());
        let mut truncated = false;
        'outer: for d in &dirs {
            // Render this directory's files atomically: if any section overflows
            // the budget, roll the whole directory back — output, budget, and the
            // searched/seen state `search` just committed — so its files stay
            // pending and a later call (e.g. after compaction frees budget) can
            // render them, rather than dropping them from `loaded` permanently.
            let out_checkpoint = out.len();
            let budget_checkpoint = budget;
            let seen_checkpoint = self.seen.clone();
            let range = self.search(d);
            let files = self.loaded.drain(range).collect::<Vec<_>>();
            let mut overflow = false;
            for file in &files {
                let note = match &file.kind {
                    Kind::Import(by) => {
                        format!("[{} (imported by {}) applies with it:]", self.display(&file.path), self.display(by))
                    }
                    _ => {
                        let scope = file.path.parent().map(|p| self.display(p)).unwrap_or_default();
                        let scope = scope.trim_end_matches("/.claude").trim_end_matches(".claude").to_string();
                        format!(
                            "[Instructions from {} apply to files under {}/. Follow them for changes there:]",
                            self.display(&file.path),
                            if scope.is_empty() { "." } else { &scope }
                        )
                    }
                };
                let section = format!("\n\n{note}\n{}", file.text);
                if section.len() > budget {
                    overflow = true;
                    break;
                }
                budget -= section.len();
                out.push_str(&section);
            }
            if overflow {
                out.truncate(out_checkpoint);
                budget = budget_checkpoint;
                self.seen = seen_checkpoint;
                self.searched.remove(d);
                truncated = true;
                break 'outer;
            }
        }
        if !truncated
            && let Ok(rel) = absolute.strip_prefix(&self.root)
        {
            let rel = rel.to_string_lossy().replace('\\', "/");
            let matched: Vec<usize> = self
                .scoped
                .iter()
                .enumerate()
                .filter(|(_, r)| !r.attached && r.patterns.iter().any(|re| re.is_match(&rel)))
                .map(|(i, _)| i)
                .collect();
            for i in matched {
                let (rule_path, body, user) = {
                    let r = &self.scoped[i];
                    (r.path.clone(), r.body.clone(), r.user)
                };
                // Commit `attached`/`seen` only once the rule's whole section
                // fits: an overflow rule (and every later match) must stay
                // pending so a later call can still attach it, instead of being
                // marked attached yet never rendered.
                let seen_checkpoint = self.seen.clone();
                let Some(text) = self.resolve_scoped_rule(&rule_path, &body, user) else {
                    // Produced nothing (its file was already rendered elsewhere);
                    // it is handled, so mark it attached and move on.
                    self.scoped[i].attached = true;
                    continue;
                };
                let section = format!(
                    "\n\n[Rule {} applies to {rel}. Follow it for changes to matching files:]\n{text}",
                    self.display(&rule_path)
                );
                if section.len() > budget {
                    self.seen = seen_checkpoint;
                    truncated = true;
                    break;
                }
                budget -= section.len();
                out.push_str(&section);
                self.scoped[i].attached = true;
            }
        }
        if truncated {
            out.push_str(MARKER);
        }
        (!out.is_empty()).then_some(out)
    }

    /// After compaction, nested instructions attached to old tool results may
    /// be gone: let them be attached again.
    pub fn forget_nested(&mut self) {
        self.searched = self.initial.clone();
        self.seen = self.initial_seen.clone();
        for rule in &mut self.scoped {
            rule.attached = false;
        }
    }

    /// Files in the system prompt, for the banner, `/context` and ACP.
    pub fn loaded_paths(&self) -> Vec<String> {
        self.loaded.iter().map(|f| f.path.display().to_string()).collect()
    }

    /// Rules attached only when a matching file is touched.
    pub fn on_demand_paths(&self) -> Vec<String> {
        self.scoped.iter().map(|r| r.path.display().to_string()).collect()
    }
}

/// Canonicalize the longest existing prefix of `path`, so files that do not
/// exist yet (about to be written) still resolve symlinked roots.
fn canonicalize_existing(path: &Path) -> PathBuf {
    for base in path.ancestors() {
        if let Ok(real) = base.canonicalize() {
            return match path.strip_prefix(base) {
                Ok(rest) if !rest.as_os_str().is_empty() => real.join(rest),
                _ => real,
            };
        }
    }
    path.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names() -> Vec<String> {
        DEFAULT_FILES.iter().map(|s| s.to_string()).collect()
    }

    fn repo() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap().join("repo");
        std::fs::create_dir_all(root.join(".git")).unwrap();
        (dir, root)
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn loads_root_to_leaf_with_fallbacks_and_nested_files_once() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();
        std::fs::create_dir_all(root.join("app/web/src")).unwrap();
        std::fs::create_dir_all(root.join("lib/core")).unwrap();
        std::fs::create_dir_all(root.join(".github")).unwrap();
        std::fs::write(root.join(".github/copilot-instructions.md"), "root copilot").unwrap();
        std::fs::write(root.join("app/CLAUDE.md"), "app claude").unwrap();
        std::fs::write(root.join("app/AGENTS.md"), "app agents").unwrap();
        std::fs::write(root.join("lib/AGENTS.md"), "lib rules").unwrap();
        std::fs::write(root.join("lib/core/AGENTS.md"), "   ").unwrap();

        let mut instructions = ProjectInstructions::discover(&root.join("app/web"), &names());
        let texts: Vec<&str> = instructions.loaded.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts, ["root copilot", "app agents"]);
        let rendered = instructions.render();
        assert!(rendered.find("root copilot").unwrap() < rendered.find("app agents").unwrap());
        assert!(rendered.contains("## app/AGENTS.md"));
        assert!(!rendered.contains("# Your instructions"));

        assert_eq!(instructions.nested_for(&root.join("app/web/src/main.rs")), None);
        let nested = instructions.nested_for(&root.join("lib/core/x.rs")).unwrap();
        assert!(nested.contains("lib/AGENTS.md apply to files under lib/") && nested.contains("lib rules"));
        assert_eq!(instructions.nested_for(&root.join("lib/y.rs")), None);
        instructions.forget_nested();
        assert!(instructions.nested_for(&root.join("lib/y.rs")).is_some());
        assert_eq!(instructions.nested_for(Path::new("/elsewhere/file")), None);
    }

    #[test]
    fn outside_a_repository_only_the_working_directory_counts() {
        let dir = tempfile::tempdir().unwrap();
        let cwd = dir.path().join("work");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::write(dir.path().join("AGENTS.md"), "parent").unwrap();
        std::fs::write(cwd.join("AGENTS.md"), "x".repeat(MAX_FILE_BYTES + 10)).unwrap();
        let instructions = ProjectInstructions::discover(&cwd, &names());
        assert_eq!(instructions.loaded.len(), 1);
        assert!(instructions.loaded[0].text.contains("[... truncated"));
    }

    #[test]
    fn user_files_come_first_and_local_files_follow_the_main_file() {
        let (dir, root) = repo();
        let home = dir.path().canonicalize().unwrap().join("home");
        write(&home.join(".claude/CLAUDE.md"), "user claude");
        write(&home.join(".claude/rules/style.md"), "user rule");
        write(&root.join("AGENTS.md"), "root agents");
        write(&root.join("CLAUDE.md"), "root claude (AGENTS.md wins)");
        write(&root.join("CLAUDE.local.md"), "root local");
        write(&root.join("sub/.claude/CLAUDE.md"), "sub dot-claude");
        let options = Options {
            names: names(),
            user_files: vec![home.join(".claude/CLAUDE.md"), home.join(".agents/AGENTS.md")],
            user_rules_dirs: vec![home.join(".claude/rules")],
            imports_outside_project: false,
        };
        let instructions = ProjectInstructions::discover_with(&root.join("sub"), options);
        let got: Vec<(&str, bool)> = instructions.loaded.iter().map(|f| (f.text.as_str(), f.user)).collect();
        assert_eq!(
            got,
            [
                ("user claude", true),
                ("user rule", true),
                ("root agents", false),
                ("root local", false),
                ("sub dot-claude", false)
            ]
        );
        let rendered = instructions.render();
        let (user_at, repo_at) =
            (rendered.find("# Your instructions").unwrap(), rendered.find("# Repository instructions").unwrap());
        assert!(user_at < rendered.find("user rule").unwrap() && rendered.find("user rule").unwrap() < repo_at);
        assert!(rendered.contains("## CLAUDE.local.md (personal, not committed)"));
        assert!(rendered.contains("style.md (rule)"));
    }

    #[test]
    fn multi_backtick_code_spans_skip_their_contents() {
        // A double-backtick span must stay open across inner single backticks,
        // so the reference inside it is not imported.
        assert_eq!(import_refs("See `` @a.md `` and @b.md"), vec!["b.md".to_string()]);
        assert!(import_refs("`` @secret.md ``").is_empty());
        // A single-backtick span still skips its one reference.
        assert!(import_refs("`@secret.md`").is_empty());
        // An unterminated span keeps the rest of the line protected.
        assert!(import_refs("`` @secret.md").is_empty());
        // Outside any span, references are imported as before.
        assert_eq!(import_refs("@a.md and `code` @b.md"), vec!["a.md".to_string(), "b.md".to_string()]);
    }

    #[test]
    fn code_span_state_is_preserved_across_line_breaks() {
        // A code span may cross a line break, so the open backtick-run state
        // must persist across lines. Resetting it per line parses the second
        // line as prose and imports a `@path` that is still inside the span.
        assert!(import_refs("See ``code\n@secret.md`` done").is_empty());
        assert!(import_refs("`code\n@secret.md`").is_empty());
        // The closing run must match the opening run length even across lines:
        // a single backtick does not close a double-backtick span.
        assert!(import_refs("``code\n` @secret.md\n``").is_empty());
        // Once the span closes, later references import as before.
        assert_eq!(import_refs("``code\n@secret.md``\n@real.md"), vec!["real.md".to_string()]);
        // A line that opens with a fence-length run rejected as a fence (a
        // backtick in its info string) does not open a multiline span: its
        // leading ``` run is skipped, so the next line's reference is imported.
        assert_eq!(import_refs("``` `code`\n@live.md"), vec!["live.md".to_string()]);
    }

    #[test]
    fn rejected_fence_candidate_does_not_break_an_open_span() {
        // A rejected fence candidate (a backtick in its info string) must not
        // reset a code span that is still open across a line break: the line
        // is span content, not fence syntax, so a `@path` after it stays
        // suppressed. Resetting the open span here would leak the import.
        assert!(import_refs("``open\n``` `x`\n@secret.md").is_empty());
        assert!(import_refs("`open\n``` `x`\n@secret.md").is_empty());
        // A tilde candidate never closes a backtick span either.
        assert!(import_refs("``open\n~~~ `x`\n@secret.md").is_empty());
        // But a fence run matching the open span's length still closes it.
        assert_eq!(import_refs("``open\n`` `x`\n@after.md"), vec!["after.md".to_string()]);
    }

    #[test]
    fn scoped_rule_imports_are_expanded_and_deduplicated() {
        let (_dir, root) = repo();
        // The import target lives outside the rules dir, so it is reachable
        // only through the rule's `@import`, not as a standalone rule.
        write(&root.join(".claude/rules/api.md"), "---\npaths:\n  - \"src/**\"\n---\nrule body, see @../shared.md");
        write(&root.join(".claude/shared.md"), "shared detail");
        let mut instructions = ProjectInstructions::discover(&root, &names());
        let out = instructions.nested_for(&root.join("src/x.rs")).unwrap();
        assert!(out.contains("rule body, see @../shared.md"), "{out}");
        // The import is expanded inline, not emitted literally.
        assert!(out.contains("shared detail"), "{out}");
        assert!(out.contains("imported by"), "{out}");
    }

    #[test]
    fn scoped_rule_import_shared_with_loaded_file_is_not_duplicated() {
        let (_dir, root) = repo();
        // The main file imports shared.md; a scoped rule also references it.
        write(&root.join("CLAUDE.md"), "root, see @shared.md");
        write(&root.join("shared.md"), "shared once");
        write(&root.join(".claude/rules/api.md"), "---\npaths:\n  - \"src/**\"\n---\nrule, see @shared.md");
        let mut instructions = ProjectInstructions::discover(&root, &names());
        let out = instructions.nested_for(&root.join("src/x.rs")).unwrap();
        // Already loaded via CLAUDE.md, so the rule does not re-expand it.
        assert!(!out.contains("shared once"), "{out}");
    }

    #[test]
    fn a_dormant_scoped_rules_import_does_not_suppress_a_rendered_file() {
        let (_dir, root) = repo();
        // Reachable only via import, never auto-loaded as a standalone rule.
        write(&root.join(".claude/shared-detail.md"), "shared detail");
        // Sorts first; scoped, so it is never attached at startup. It imports
        // the shared file but must not mark it seen while dormant.
        write(&root.join(".claude/rules/a-scoped.md"), "---\npaths:\n  - \"src/**\"\n---\nscoped, see @../shared-detail.md");
        // Sorts later; a plain rule rendered at startup that imports the same file.
        write(&root.join(".claude/rules/b-plain.md"), "plain rule, see @../shared-detail.md");
        let instructions = ProjectInstructions::discover(&root, &names());
        let rendered = instructions.render();
        // Deferred resolution keeps the dormant rule from suppressing the import.
        assert!(rendered.contains("shared detail"), "{rendered}");
    }

    #[test]
    fn on_demand_scoped_rules_are_bounded_with_a_single_marker() {
        let (_dir, root) = repo();
        // Several near-cap scoped rules all match src/**, together far past the
        // total cap; the tool result this feeds skips its own post-bounding.
        let big = "x".repeat(MAX_FILE_BYTES - 64);
        for i in 0..8 {
            write(
                &root.join(format!(".claude/rules/r{i}.md")),
                &format!("---\npaths:\n  - \"src/**\"\n---\n{big} rule{i}"),
            );
        }
        let mut instructions = ProjectInstructions::discover(&root, &names());
        let out = instructions.nested_for(&root.join("src/x.rs")).unwrap();
        assert!(out.len() <= MAX_TOTAL_BYTES, "on-demand output {} > cap", out.len());
        // Exactly one omission marker, however many rules were dropped.
        assert_eq!(out.matches("[omitted: instruction size limit reached").count(), 1);
    }

    #[test]
    #[cfg(unix)]
    fn a_committed_instruction_file_symlinked_outside_the_repo_is_skipped() {
        let (dir, root) = repo();
        let outside = dir.path().canonicalize().unwrap().join("id_ed25519");
        write(&outside, "SECRET KEY");
        std::fs::create_dir_all(root.join(".claude")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join(".claude/CLAUDE.md")).unwrap();

        let blocked = ProjectInstructions::discover(&root, &names());
        assert!(!blocked.render().contains("SECRET KEY"));
        assert_eq!(blocked.warnings.len(), 1);
        assert!(blocked.warnings[0].contains("outside the repository"));

        let allowed = ProjectInstructions::discover_with(
            &root,
            Options { names: names(), imports_outside_project: true, ..Default::default() },
        );
        assert!(allowed.render().contains("SECRET KEY"));
    }

    #[test]
    fn longer_fences_are_not_closed_by_shorter_inner_runs() {
        // A four-backtick fence stays open across an inner ``` line, so an
        // @import and an HTML comment inside it are left untouched.
        let text = "````\n@secret.md\n```\nstill inside\n<!-- keep -->\n````\n@after.md";
        assert_eq!(import_refs(text), vec!["after.md".to_string()]);
        assert!(strip_html_comments(text).contains("<!-- keep -->"));
        // A tilde fence is independent of a backtick run of any length.
        assert_eq!(import_refs("~~~\n@a.md\n```\n@b.md\n~~~\n@c.md"), vec!["c.md".to_string()]);
    }

    #[test]
    fn fence_close_requires_a_bare_marker_and_small_indent() {
        // A run with trailing non-whitespace is NOT a closing fence, so an
        // @import on the next line stays inside the code block.
        let text = "```\n@secret.md\n```not-a-close\n@still.md\n```\n@after.md";
        assert_eq!(import_refs(text), vec!["after.md".to_string()]);
        assert!(strip_html_comments("```\n<!-- a -->\n```x\n<!-- b -->\n```").contains("<!-- a -->"));
        // A 4-space-indented run is indented code, not a fence marker, so it
        // does not CLOSE an open fence: the @import after it stays inside until
        // a bare marker closes the block.
        assert_eq!(import_refs("```\n@secret.md\n    ```\n@still.md\n```\n@after.md"), vec!["after.md".to_string()]);
        // Up to 3 spaces of indent is still a valid fence.
        assert_eq!(import_refs("   ```\n@in.md\n   ```\n@out.md"), vec!["out.md".to_string()]);
        // A backtick fence's info string may not contain a backtick, so this
        // line is not an opening fence; its leading ``` run is skipped as a
        // rejected fence candidate rather than parsed as a code-span opener,
        // so the inline `code` span on the same line still closes and the
        // @import on the next line is extracted.
        assert_eq!(import_refs("``` `code`\n@live.md"), vec!["live.md".to_string()]);
    }

    #[test]
    fn render_cap_bounds_total_with_header_and_single_marker() {
        let (_dir, root) = repo();
        // Many nested files, each near the per-file cap, well past the total cap.
        let big = "x".repeat(MAX_FILE_BYTES - 16);
        let mut dir = root.clone();
        for i in 0..8 {
            dir = dir.join(format!("d{i}"));
            write(&dir.join("AGENTS.md"), &format!("{big} file{i}"));
        }
        let instructions = ProjectInstructions::discover(&dir, &names());
        let rendered = instructions.render();
        assert!(rendered.len() <= MAX_TOTAL_BYTES, "rendered {} > cap", rendered.len());
        // Exactly one omission marker, however many files were dropped.
        assert_eq!(rendered.matches("[omitted: instruction size limit reached").count(), 1);
    }

    #[test]
    fn imports_expand_in_claude_files_once_and_stay_inside_the_repository() {
        let (dir, root) = repo();
        let outside = dir.path().canonicalize().unwrap().join("secret.txt");
        write(&outside, "SECRET");
        write(
            &root.join("CLAUDE.md"),
            &format!(
                "See @docs/a.md and @docs/a.md again.\nNot `@docs/b.md`, not user@docs, not @missing.md.\n\
                 ```\n@docs/b.md\n```\nOutside: @{}\nSpaces: @docs/with\\ space.md.",
                outside.display()
            ),
        );
        write(&root.join("docs/a.md"), "doc a, see @b.md");
        write(&root.join("docs/b.md"), "doc b, back to @a.md");
        write(&root.join("docs/with space.md"), "spaced");
        let instructions = ProjectInstructions::discover(&root, &names());
        let texts: Vec<&str> = instructions.loaded.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts.len(), 4, "{texts:?}");
        assert_eq!(&texts[1..], ["doc a, see @b.md", "doc b, back to @a.md", "spaced"]);
        assert!(!instructions.render().contains("SECRET"));
        assert!(instructions.render().contains("## docs/b.md (imported by docs/a.md)"));
        assert_eq!(instructions.warnings.len(), 1);
        assert!(instructions.warnings[0].contains("outside the repository"));

        let allowed = ProjectInstructions::discover_with(
            &root,
            Options { names: names(), imports_outside_project: true, ..Default::default() },
        );
        assert!(allowed.render().contains("SECRET"));
    }

    #[test]
    fn agents_md_mentions_are_not_imports() {
        let (_dir, root) = repo();
        write(&root.join("AGENTS.md"), "Ask @docs/a.md");
        write(&root.join("docs/a.md"), "doc a");
        let instructions = ProjectInstructions::discover(&root, &names());
        assert_eq!(instructions.loaded.len(), 1);
    }

    #[test]
    fn imports_stop_after_four_levels() {
        let (_dir, root) = repo();
        write(&root.join("CLAUDE.md"), "@l1.md");
        for i in 1..=6 {
            write(&root.join(format!("l{i}.md")), &format!("level {i} @l{}.md", i + 1));
        }
        let instructions = ProjectInstructions::discover(&root, &names());
        assert_eq!(instructions.loaded.len(), 1 + MAX_IMPORT_DEPTH);
    }

    #[test]
    fn scoped_rules_attach_to_matching_files_once_per_compaction() {
        let (_dir, root) = repo();
        write(&root.join(".claude/rules/always.md"), "---\ndescription: x\n---\nalways rule");
        write(&root.join(".claude/rules/api/ts.md"), "---\npaths:\n  - \"src/api/**/*.{ts,tsx}\"\n---\nts rule");
        write(&root.join(".claude/rules/docs.md"), "---\npaths: \"*.md\", docs/**\n---\ndocs rule");
        let mut instructions = ProjectInstructions::discover(&root, &names());
        let texts: Vec<&str> = instructions.loaded.iter().map(|f| f.text.as_str()).collect();
        assert_eq!(texts, ["always rule"]);
        assert_eq!(instructions.on_demand_paths().len(), 2);

        assert_eq!(instructions.nested_for(&root.join("src/api/x.rs")), None);
        let ts = instructions.nested_for(&root.join("src/api/v1/x.tsx")).unwrap();
        assert!(ts.contains("Rule .claude/rules/api/ts.md applies to src/api/v1/x.tsx") && ts.contains("ts rule"));
        assert_eq!(instructions.nested_for(&root.join("src/api/y.ts")), None);
        assert!(instructions.nested_for(&root.join("README.md")).unwrap().contains("docs rule"));
        assert_eq!(instructions.nested_for(&root.join("sub/README.md")), None);
        instructions.forget_nested();
        assert!(instructions.nested_for(&root.join("src/api/y.ts")).is_some());
    }

    #[test]
    fn rules_nested_deeper_than_eight_directories_are_still_loaded() {
        let (_dir, root) = repo();
        // The `.claude/rules/**/*.md` lookup is advertised as recursive with no
        // documented depth limit, so a rule nested well past the old eight-level
        // cap must still be discovered (the canonical visited-set guards loops).
        let deep = root.join(".claude/rules/a/b/c/d/e/f/g/h/i/j/k");
        write(&deep.join("deep.md"), "---\npaths:\n  - \"src/**\"\n---\ndeep rule");
        let mut instructions = ProjectInstructions::discover(&root, &names());
        let out = instructions.nested_for(&root.join("src/x.rs")).unwrap();
        assert!(out.contains("deep rule"), "{out}");
    }

    #[test]
    fn a_symlink_cycle_in_rules_does_not_loop_forever() {
        let (_dir, root) = repo();
        // With no depth cap, the canonical visited-set is the only guard against
        // a symlink cycle: a directory linked back into the tree must be entered
        // once, then skipped on the cyclic revisit, so discovery terminates.
        let rules = root.join(".claude/rules");
        write(&rules.join("top.md"), "top rule");
        std::fs::create_dir_all(rules.join("sub")).unwrap();
        std::os::unix::fs::symlink(&rules, rules.join("sub/loop")).unwrap();
        let files = markdown_files(&rules);
        // Terminates, and each canonical file appears once despite the cycle.
        assert_eq!(files.iter().filter(|p| p.ends_with("top.md")).count(), 1, "{files:?}");
    }

    #[test]
    fn a_scoped_rule_already_imported_is_not_re_emitted() {
        let (_dir, root) = repo();
        // dup.md is both explicitly imported by CLAUDE.md and a path-scoped rule.
        write(&root.join(".claude/rules/dup.md"), "---\npaths: docs/**\n---\ndup body");
        write(&root.join("CLAUDE.md"), "@.claude/rules/dup.md");
        let mut instructions = ProjectInstructions::discover(&root, &names());
        // Imported once at the top level.
        assert_eq!(instructions.render().matches("dup body").count(), 1);
        // Matching a docs file must not attach the rule body again (already seen).
        assert_eq!(instructions.nested_for(&root.join("docs/x.md")), None);
    }

    #[test]
    fn html_comments_are_stripped_outside_code_blocks() {
        let text = "keep\n<!-- one line -->\n<!-- multi\nline -->\nafter\n```\n<!-- in code -->\n```\n";
        assert_eq!(strip_html_comments(text), "keep\nafter\n```\n<!-- in code -->\n```\n");
    }

    #[test]
    fn front_matter_forms() {
        assert_eq!(rule_front_matter("---\npaths: [a, \"b\"]\n---\nx").0, Some(vec!["a".into(), "b".into()]));
        assert_eq!(
            rule_front_matter("---\npaths:\n- a\n- 'b'\nother: 1\n---\nx").0,
            Some(vec!["a".into(), "b".into()])
        );
        assert_eq!(rule_front_matter("---\nname: y\n---\nx"), (None, "x"));
        assert_eq!(rule_front_matter("no front matter").0, None);
        let mut budget = MAX_RULE_PATTERNS;
        assert_eq!(expand_braces("{a,b}/*.{c,d}", &mut budget).len(), 4);
    }

    #[test]
    fn inline_paths_keep_brace_groups() {
        // A comma inside a `{a,b}` brace group (or inside quotes) is not a list
        // separator: the inline form must split only on top-level commas.
        assert_eq!(
            rule_front_matter("---\npaths: \"src/**/*.{ts,tsx}\"\n---\nx").0,
            Some(vec!["src/**/*.{ts,tsx}".into()])
        );
        assert_eq!(
            rule_front_matter("---\npaths: [src/**/*.{ts,tsx}, \"docs/*.md\"]\n---\nx").0,
            Some(vec!["src/**/*.{ts,tsx}".into(), "docs/*.md".into()])
        );
        assert_eq!(rule_front_matter("---\npaths: \"a,b\", c\n---\nx").0, Some(vec!["a,b".into(), "c".into()]));
    }

    #[test]
    fn inline_paths_with_braces_match() {
        // Regression: the inline `paths:` form used to split on every comma, so a
        // brace group was shattered and the compiled rule matched nothing.
        let (paths, _) = rule_front_matter("---\npaths: \"src/**/*.{ts,tsx}\"\n---\nx");
        let compiled = compile_patterns(&paths.unwrap());
        assert!(compiled.iter().any(|r| r.is_match("src/a/b.ts")));
        assert!(compiled.iter().any(|r| r.is_match("src/a/b.tsx")));
        assert!(!compiled.iter().any(|r| r.is_match("src/a/b.js")));
    }

    #[test]
    fn split_top_level_adversarial() {
        // No panics on unbalanced braces/quotes; nested braces and empty entries behave.
        for v in ["}", "{", "a}", "{a", "\"a,b", "a,\"b", "'x,y',z", "{a,{b,c}},d", "a,,b", "", ","] {
            let _ = split_top_level(v);
        }
        assert_eq!(split_top_level("{a,{b,c}},d"), vec!["{a,{b,c}}", "d"]);
        assert_eq!(split_top_level("a,,b"), vec!["a", "", "b"]); // empty filtered later
        assert_eq!(split_top_level(""), vec![""]);
    }

    #[test]
    fn overflow_directory_stays_pending_for_a_later_call() {
        let (_dir, root) = repo();
        // Two near-cap files in nested dirs: together past the 64 KiB budget.
        let big = "x".repeat(MAX_FILE_BYTES - 16);
        write(&root.join("AGENTS.md"), "root file");
        write(&root.join("a/AGENTS.md"), &format!("{big} file_a"));
        write(&root.join("a/b/AGENTS.md"), &format!("{big} file_b"));
        let mut instructions = ProjectInstructions::discover(&root, &names());
        // First call renders a/ but a/b overflows the budget and is rolled back.
        let first = instructions.nested_for(&root.join("a/b/x.rs")).unwrap();
        assert!(first.contains("file_a"));
        assert!(!first.contains("file_b"));
        assert!(first.contains("[omitted: instruction size limit reached"));
        // The overflowed directory stayed pending (searched/seen rolled back),
        // so a later call still renders it instead of dropping it permanently.
        let second = instructions.nested_for(&root.join("a/b/y.rs")).unwrap();
        assert!(second.contains("file_b"));
    }

    #[test]
    fn overflow_scoped_rule_stays_pending_for_a_later_call() {
        let (_dir, root) = repo();
        // Two near-cap rules both matching src/**: together past the budget.
        let big = "x".repeat(MAX_FILE_BYTES - 64);
        write(&root.join(".claude/rules/a.md"), &format!("---\npaths:\n  - \"src/**\"\n---\n{big} rule_a"));
        write(&root.join(".claude/rules/b.md"), &format!("---\npaths:\n  - \"src/**\"\n---\n{big} rule_b"));
        let mut instructions = ProjectInstructions::discover(&root, &names());
        let first = instructions.nested_for(&root.join("src/x.rs")).unwrap();
        assert!(first.contains("[omitted: instruction size limit reached"));
        let a_first = first.contains("rule_a");
        let b_first = first.contains("rule_b");
        assert!(a_first ^ b_first, "exactly one rule should fit the budget");
        // The overflowed rule was NOT marked attached, so a later call attaches
        // it (previously it was marked attached yet never rendered).
        let second = instructions.nested_for(&root.join("src/y.rs")).unwrap();
        assert!(second.contains(if a_first { "rule_b" } else { "rule_a" }));
    }

    #[test]
    fn indented_code_blocks_preserve_comments_and_imports() {
        // A 4-space-indented line is an indented code block: its HTML comment is
        // not stripped and its `@import` is not expanded (it is code, not Markdown).
        assert!(strip_html_comments("text\n\n    <!-- example -->\n").contains("<!-- example -->"));
        assert_eq!(import_refs("text\n\n    @code.md\n@live.md"), vec!["live.md".to_string()]);
        // A leading tab counts as indented code as well.
        assert!(strip_html_comments("text\n\n\t<!-- tabbed -->\n").contains("<!-- tabbed -->"));
        // Up to 3 spaces is still prose: a shallow-indented comment is stripped.
        assert_eq!(strip_html_comments("   <!-- shallow -->\nkeep\n"), "keep\n");
    }

    #[test]
    fn front_matter_imports_are_not_expanded_when_front_matter_is_dropped() {
        let (_dir, root) = repo();
        write(&root.join("secret.md"), "SECRET BODY");
        // A rule with front matter but no `paths`: the front matter is dropped,
        // so its `@secret.md` reference must NOT be imported — only the body shows.
        write(&root.join(".claude/rules/x.md"), "---\ndescription: see @secret.md\n---\nrule body");
        let instructions = ProjectInstructions::discover(&root, &names());
        let rendered = instructions.render();
        assert!(rendered.contains("rule body"));
        assert!(!rendered.contains("SECRET BODY"));
    }

    #[test]
    fn per_file_truncation_marker_mentions_read_file() {
        let (_dir, root) = repo();
        write(&root.join("AGENTS.md"), &"x".repeat(MAX_FILE_BYTES + 10));
        let instructions = ProjectInstructions::discover(&root, &names());
        let text = &instructions.loaded[0].text;
        assert!(text.contains("[... truncated"));
        assert!(text.contains("read_file"), "per-file marker should direct to read_file");
    }
}
