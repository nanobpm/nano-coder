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
/// Directory depth searched under a rules directory.
const MAX_RULES_DEPTH: usize = 8;

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
    text: String,
    patterns: Vec<Regex>,
    attached: bool,
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
    Some(format!("{}\n\n[... truncated: {} of {} bytes shown]", &text[..end], end, text.len()))
}

/// The opening fence (``` or ~~~) of a Markdown code block on this line.
fn fence(line: &str) -> Option<&'static str> {
    let t = line.trim_start();
    if t.starts_with("```") {
        Some("```")
    } else if t.starts_with("~~~") {
        Some("~~~")
    } else {
        None
    }
}

/// Remove block-level `<!-- ... -->` comments (outside code blocks), as
/// Claude Code does before a CLAUDE.md reaches the model.
fn strip_html_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_fence: Option<&str> = None;
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
            if line.trim_start().starts_with(open) {
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
    let mut in_fence: Option<&str> = None;
    for line in text.lines() {
        if let Some(open) = in_fence {
            if line.trim_start().starts_with(open) {
                in_fence = None;
            }
            continue;
        }
        if let Some(open) = fence(line) {
            in_fence = Some(open);
            continue;
        }
        let chars: Vec<char> = line.chars().collect();
        let mut i = 0;
        let mut in_span = false;
        while i < chars.len() {
            let c = chars[i];
            if c == '`' {
                in_span = !in_span;
                i += 1;
                continue;
            }
            let starts = i == 0 || chars[i - 1].is_whitespace() || chars[i - 1] == '(';
            if in_span || c != '@' || !starts {
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
        paths = Some(inner.split(',').map(unquote).collect());
    }
    let paths = paths.map(|p| p.into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>()).filter(|p| !p.is_empty());
    (paths, &text[offset.min(text.len())..])
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
    fn walk(dir: &Path, depth: usize, visited: &mut HashSet<PathBuf>, out: &mut Vec<PathBuf>) {
        let Ok(real) = dir.canonicalize() else { return };
        if depth > MAX_RULES_DEPTH || !visited.insert(real) {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        let mut paths: Vec<PathBuf> = entries.filter_map(|e| e.ok().map(|e| e.path())).collect();
        paths.sort();
        for path in paths {
            if path.is_dir() {
                walk(&path, depth + 1, visited, out);
            } else if path.extension().is_some_and(|e| e == "md") && path.is_file() {
                out.push(path);
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, 0, &mut HashSet::new(), &mut out);
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
        self.load_at(path, kind, user, 0);
    }

    fn load_at(&mut self, path: PathBuf, kind: Kind, user: bool, depth: usize) {
        let Some(text) = read_capped(&path) else { return };
        let real = path.canonicalize().unwrap_or_else(|_| path.clone());
        if !self.seen.insert(real) {
            return;
        }
        let refs = if expands_imports(&path, &kind) { import_refs(&text) } else { Vec::new() };
        self.loaded.push(InstructionFile { path: path.clone(), text, kind, user });
        if depth >= MAX_IMPORT_DEPTH {
            return;
        }
        for reference in refs {
            if let Some(target) = self.resolve_import(&path, &reference, user) {
                self.load_at(target, Kind::Import(path.clone()), user, depth + 1);
            }
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
                    self.scoped.push(ScopedRule { path, text: body.to_string(), patterns: compiled, attached: false });
                }
                (None, body) => {
                    let body = body.trim();
                    if body.is_empty() {
                        continue;
                    }
                    // Front matter without `paths` is dropped, as Claude Code does.
                    let start = self.loaded.len();
                    self.load(path, Kind::Rule, user);
                    if let Some(file) = self.loaded.get_mut(start) {
                        file.text = body.to_string();
                    }
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
        let mut out = String::new();
        let mut budget = MAX_TOTAL_BYTES;
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
        for (user, header) in groups {
            let files: Vec<&InstructionFile> = self.loaded.iter().filter(|f| f.user == user).collect();
            if files.is_empty() {
                continue;
            }
            out.push_str(header);
            for file in files {
                let section = format!("\n\n## {}\n\n{}", self.heading(file), file.text);
                if section.len() > budget {
                    out.push_str(&format!(
                        "\n\n## {}\n\n[omitted: instruction size limit reached; read it with read_file]",
                        self.heading(file)
                    ));
                    continue;
                }
                budget -= section.len();
                out.push_str(&section);
            }
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
        let mut out = String::new();
        for d in &dirs {
            let range = self.search(d);
            let files = self.loaded.drain(range).collect::<Vec<_>>();
            for file in files {
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
                out.push_str(&format!("\n\n{note}\n{}", file.text));
            }
        }
        if let Ok(rel) = absolute.strip_prefix(&self.root) {
            let rel = rel.to_string_lossy().replace('\\', "/");
            let mut matched = Vec::new();
            for rule in self.scoped.iter_mut().filter(|r| !r.attached) {
                if rule.patterns.iter().any(|re| re.is_match(&rel)) {
                    rule.attached = true;
                    matched.push((rule.path.clone(), rule.text.clone()));
                }
            }
            for (rule_path, text) in matched {
                out.push_str(&format!(
                    "\n\n[Rule {} applies to {rel}. Follow it for changes to matching files:]\n{text}",
                    self.display(&rule_path)
                ));
            }
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
}
