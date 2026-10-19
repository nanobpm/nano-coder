//! Structured, read-only workspace search for the `grep` and `glob` tools.
//!
//! These tools replace shelling out to grep/find/rg through `bash`, where the
//! permission guard cannot tell a read-only search from a write: as tools
//! they are policy-checkable, plan-mode safe, and sandbox-independent.
//!
//! The walker is hand-rolled to keep the dependency surface (and binary
//! size) unchanged. Behavior:
//! * `.git` directories and symlinked entries are never followed, so a walk
//!   cannot loop or escape the search root through a link. A search root
//!   named explicitly is used as given.
//! * `.gitignore` files from the search root downward are honored with a
//!   documented subset of gitignore syntax: comments, `!` negation,
//!   trailing-`/` directory patterns, patterns with a `/` anchored to the
//!   .gitignore's directory, and `*`/`?`/`**` wildcards. (`\` escapes and
//!   character classes are not supported; a negation cannot re-include a
//!   file under a directory that an earlier rule pruned, matching git.)
//! * Files covered by a `Read(...)` deny rule are filtered out of the
//!   results (contents and names alike) via [`Policy::read_denied`].
//! * Binary files (NUL in the first 8 KiB, the `read_file` test) and files
//!   over 16 MiB are skipped by `grep`; results are sorted by path and
//!   capped, with an explicit truncation note rather than silent loss.

use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use regex::Regex;
use serde_json::{Value, json};

use crate::permissions::{self, Policy};
use crate::tools::{ToolDefinition, ToolRegistry};

const DEFAULT_LIMIT: usize = 250;
const MAX_LIMIT: usize = 5_000;
const MAX_LINE_CHARS: usize = 2_000;
const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;
const BINARY_SNIFF_BYTES: usize = 8_192;
const NO_MATCHES: &str = "(no matches)";

pub fn register(tools: &ToolRegistry, policy: Policy) {
    let grep_policy = policy.clone();
    tools.register(
        ToolDefinition::new(
            "grep",
            "Search file contents under a path for a regular expression. Read-only. Respects .gitignore, \
             skips .git, symlinks and binary files, and omits files covered by Read deny rules. Output \
             defaults to matching lines as `path:line:text`; use output_mode `files` for just the paths \
             or `count` for per-file match counts. Results are sorted by path and capped by `limit` \
             (matching lines in content mode, files otherwise); hitting the cap is reported.",
            json!({
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Regular expression to search for" },
                    "path": { "type": "string", "description": "File or directory to search (default: working directory)" },
                    "glob": { "type": "string", "description": "Only search files matching this glob, e.g. \"*.rs\" (any depth) or \"src/**/*.rs\"" },
                    "output_mode": { "type": "string", "enum": ["content", "files", "count"], "description": "Default content" },
                    "limit": { "type": "integer", "description": "Max results to return (default 250, max 5000)" }
                },
                "required": ["pattern"]
            }),
        ),
        Box::new(move |args| grep(&args, &grep_policy)),
    );
    tools.register(
        ToolDefinition::new(
            "glob",
            "List files under a path whose name matches a glob pattern. Read-only. A pattern without `/` \
             matches the file name at any depth (\"*.rs\"); a pattern with `/` matches the path relative \
             to the search root, where `*` stays within one directory and `**` crosses directories \
             (\"src/**/*.rs\"). Respects .gitignore, skips .git and symlinks, and omits files covered by \
             Read deny rules. Results are sorted by path and capped by `limit`.",
            json!({
                "type": "object",
                "properties": {
                    "pattern": { "type": "string", "description": "Glob pattern, e.g. \"*.toml\" or \"src/**/*.rs\"" },
                    "path": { "type": "string", "description": "Directory to list from (default: working directory)" },
                    "limit": { "type": "integer", "description": "Max paths to return (default 250, max 5000)" }
                },
                "required": ["pattern"]
            }),
        ),
        Box::new(move |args| glob(&args, &policy)),
    );
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

fn required_string(args: &Value, name: &str) -> Result<String> {
    match args.get(name) {
        Some(Value::String(s)) if !s.is_empty() => Ok(s.clone()),
        Some(Value::String(_)) => bail!("{name} must not be empty"),
        Some(_) => bail!("{name} must be a string"),
        None => bail!("missing {name}"),
    }
}

fn optional_string(args: &Value, name: &str) -> Result<Option<String>> {
    match args.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.is_empty() => Ok(Some(s.clone())),
        Some(Value::String(_)) => bail!("{name} must not be empty"),
        Some(_) => bail!("{name} must be a string"),
    }
}

fn limit_arg(args: &Value) -> Result<usize> {
    match args.get("limit") {
        None | Some(Value::Null) => Ok(DEFAULT_LIMIT),
        Some(v) => match v.as_u64() {
            Some(0) => bail!("limit must be at least 1"),
            Some(n) => Ok((n as usize).min(MAX_LIMIT)),
            None => bail!("limit must be a positive integer"),
        },
    }
}

fn root_arg(args: &Value) -> Result<String> {
    Ok(optional_string(args, "path")?.unwrap_or_else(|| ".".to_string()))
}

// ---------------------------------------------------------------------------
// grep
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum OutputMode {
    Content,
    Files,
    Count,
}

pub fn grep(args: &Value, policy: &Policy) -> Result<Value> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    grep_in(args, policy, &cwd)
}

fn grep_in(args: &Value, policy: &Policy, cwd: &Path) -> Result<Value> {
    let pattern = required_string(args, "pattern")?;
    let regex = Regex::new(&pattern).map_err(|e| anyhow::anyhow!("invalid regex pattern {pattern:?}: {e}"))?;
    let mode = match optional_string(args, "output_mode")?.as_deref() {
        None | Some("content") => OutputMode::Content,
        Some("files") | Some("files_with_matches") => OutputMode::Files,
        Some("count") => OutputMode::Count,
        Some(other) => bail!("output_mode must be content, files or count, got {other:?}"),
    };
    let limit = limit_arg(args)?;
    let filter = optional_string(args, "glob")?.map(|g| GlobFilter::compile(&g)).transpose()?;
    let root = root_arg(args)?;

    let mut files = collect_files(&root, cwd, policy)?;
    if let Some(filter) = &filter {
        files.retain(|f| filter.matches(f));
    }

    let mut out: Vec<String> = Vec::new();
    let mut truncated = false;
    for file in &files {
        match mode {
            OutputMode::Content => {
                let remaining = limit - out.len();
                // Collect one line past the cap so truncation is detected
                // (and reported) instead of silently looking exhaustive.
                let found = search_file(&file.fs_path, &regex, remaining + 1, false);
                if found.count > remaining {
                    out.extend(
                        found.lines.into_iter().take(remaining).map(|(n, text)| format!("{}:{n}:{text}", file.display)),
                    );
                    truncated = true;
                    break;
                }
                out.extend(found.lines.into_iter().map(|(n, text)| format!("{}:{n}:{text}", file.display)));
            }
            OutputMode::Files => {
                if search_file(&file.fs_path, &regex, 0, true).count > 0 {
                    if out.len() >= limit {
                        truncated = true;
                        break;
                    }
                    out.push(file.display.clone());
                }
            }
            OutputMode::Count => {
                let found = search_file(&file.fs_path, &regex, 0, false);
                if found.count > 0 {
                    if out.len() >= limit {
                        truncated = true;
                        break;
                    }
                    out.push(format!("{}:{}", file.display, found.count));
                }
            }
        }
    }

    if out.is_empty() {
        return Ok(Value::String(NO_MATCHES.to_string()));
    }
    if truncated {
        out.push(format!(
            "[limit {limit} reached; more matches exist — narrow the pattern, path or glob, or raise the limit]"
        ));
    }
    Ok(Value::String(out.join("\n")))
}

#[derive(Default)]
struct FileMatches {
    count: usize,
    lines: Vec<(usize, String)>,
}

/// Search one file line by line. `collect_up_to` caps how many matching
/// lines are kept (0 keeps none); `first_only` stops at the first match.
/// Unreadable, oversized and binary files yield no matches: one bad file
/// should not fail a whole search.
fn search_file(path: &Path, regex: &Regex, collect_up_to: usize, first_only: bool) -> FileMatches {
    let mut found = FileMatches::default();
    let Ok(file) = File::open(path) else { return found };
    if file.metadata().is_ok_and(|m| m.len() > MAX_FILE_BYTES) {
        return found;
    }
    let mut reader = BufReader::new(file);
    let mut raw: Vec<u8> = Vec::new();
    let mut sniffed = 0usize;
    let mut line_no = 0usize;
    loop {
        raw.clear();
        match reader.read_until(b'\n', &mut raw) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        line_no += 1;
        if sniffed < BINARY_SNIFF_BYTES {
            let take = (BINARY_SNIFF_BYTES - sniffed).min(raw.len());
            if raw[..take].contains(&0) {
                return FileMatches::default();
            }
            sniffed += take;
        }
        let text = String::from_utf8_lossy(&raw);
        let line = text.strip_suffix('\n').unwrap_or(&text);
        let line = line.strip_suffix('\r').unwrap_or(line);
        if regex.is_match(line) {
            found.count += 1;
            if first_only {
                return found;
            }
            if found.lines.len() < collect_up_to {
                found.lines.push((line_no, clip_line(line)));
            } else if collect_up_to > 0 {
                // Past what the caller can use; `count` already proves it.
                return found;
            }
        }
    }
    found
}

fn clip_line(line: &str) -> String {
    if line.chars().count() <= MAX_LINE_CHARS {
        return line.to_string();
    }
    let mut clipped: String = line.chars().take(MAX_LINE_CHARS).collect();
    clipped.push_str("... [line truncated]");
    clipped
}

// ---------------------------------------------------------------------------
// glob
// ---------------------------------------------------------------------------

pub fn glob(args: &Value, policy: &Policy) -> Result<Value> {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/"));
    glob_in(args, policy, &cwd)
}

fn glob_in(args: &Value, policy: &Policy, cwd: &Path) -> Result<Value> {
    let pattern = required_string(args, "pattern")?;
    let filter = GlobFilter::compile(&pattern)?;
    let limit = limit_arg(args)?;
    let root = root_arg(args)?;

    let files = collect_files(&root, cwd, policy)?;
    let matched: Vec<&FoundFile> = files.iter().filter(|f| filter.matches(f)).collect();
    if matched.is_empty() {
        return Ok(Value::String(NO_MATCHES.to_string()));
    }
    let mut out: Vec<String> = matched.iter().take(limit).map(|f| f.display.clone()).collect();
    if matched.len() > limit {
        out.push(format!(
            "[showing first {limit} of {} matches; narrow the pattern or raise the limit]",
            matched.len()
        ));
    }
    Ok(Value::String(out.join("\n")))
}

/// A compiled glob. A pattern without `/` matches the file name at any
/// depth; otherwise it matches the path relative to the search root (and,
/// for an explicitly named file root, the path as given).
struct GlobFilter {
    regex: Regex,
    by_name: bool,
}

impl GlobFilter {
    fn compile(pattern: &str) -> Result<Self> {
        let cleaned = pattern.trim().strip_prefix("./").unwrap_or(pattern.trim()).trim_start_matches('/');
        if cleaned.is_empty() {
            bail!("glob pattern must not be empty");
        }
        let regex = permissions::path_glob(cleaned).map_err(anyhow::Error::msg)?;
        Ok(Self { regex, by_name: !cleaned.contains('/') })
    }

    fn matches(&self, file: &FoundFile) -> bool {
        if self.by_name {
            let name = file.rel.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
            return self.regex.is_match(&name);
        }
        self.regex.is_match(&slash(&file.rel)) || self.regex.is_match(file.display.trim_start_matches("./"))
    }
}

// ---------------------------------------------------------------------------
// The walker
// ---------------------------------------------------------------------------

struct FoundFile {
    /// Path to open.
    fs_path: PathBuf,
    /// Path as reported to the model (usable with `read_file` from cwd).
    display: String,
    /// Path relative to the search root (the file name for a file root).
    rel: PathBuf,
}

fn collect_files(root: &str, cwd: &Path, policy: &Policy) -> Result<Vec<FoundFile>> {
    let root_path = Path::new(root);
    let fs_root = if root_path.is_absolute() { root_path.to_path_buf() } else { cwd.join(root_path) };
    let metadata = std::fs::metadata(&fs_root)
        .with_context(|| format!("search path {} does not exist or is not readable", root))?;

    if metadata.is_file() {
        // An explicitly named file is searched even if a .gitignore rule or
        // the include glob would skip it in a walk; deny rules still apply.
        if policy.read_denied(&fs_root, cwd) {
            return Ok(Vec::new());
        }
        let rel = root_path.file_name().map(PathBuf::from).unwrap_or_else(|| root_path.to_path_buf());
        return Ok(vec![FoundFile { fs_path: fs_root, display: root.trim_start_matches("./").to_string(), rel }]);
    }
    if !metadata.is_dir() {
        bail!("search path {root} is neither a file nor a directory");
    }

    let mut out = Vec::new();
    walk_dir(&fs_root, &PathBuf::new(), root, cwd, policy, &[], &mut out, true)?;
    out.sort_by(|a, b| a.display.cmp(&b.display));
    Ok(out)
}

#[allow(clippy::too_many_arguments)]
fn walk_dir(
    dir: &Path,
    rel_dir: &Path,
    root: &str,
    cwd: &Path,
    policy: &Policy,
    inherited: &[IgnoreRule],
    out: &mut Vec<FoundFile>,
    is_root: bool,
) -> Result<()> {
    let mut rules: Vec<IgnoreRule> = inherited.to_vec();
    rules.extend(load_gitignore(dir, rel_dir));

    let read_dir = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if is_root => return Err(e).with_context(|| format!("cannot read search directory {root}")),
        // An unreadable nested directory is skipped, not fatal.
        Err(_) => return Ok(()),
    };
    let mut entries: Vec<_> = read_dir.filter_map(|e| e.ok()).collect();
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let Ok(file_type) = entry.file_type() else { continue };
        // Symlinked entries are never followed: no loops, no escaping the root.
        if file_type.is_symlink() {
            continue;
        }
        let name = entry.file_name();
        if file_type.is_dir() && name == ".git" {
            continue;
        }
        let rel = rel_dir.join(&name);
        if is_ignored(&rules, &rel, file_type.is_dir()) {
            continue;
        }
        let fs_path = entry.path();
        if policy.read_denied(&fs_path, cwd) {
            continue;
        }
        if file_type.is_dir() {
            walk_dir(&fs_path, &rel, root, cwd, policy, &rules, out, false)?;
        } else if file_type.is_file() {
            out.push(FoundFile { display: display_path(root, &rel), fs_path, rel });
        }
    }
    Ok(())
}

fn display_path(root: &str, rel: &Path) -> String {
    let rel = slash(rel);
    let root = root.trim_end_matches('/');
    if root.is_empty() || root == "." { rel } else { format!("{}/{rel}", root.trim_start_matches("./")) }
}

fn slash(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

// ---------------------------------------------------------------------------
// .gitignore (documented subset — see the module docs)
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct IgnoreRule {
    /// Directory containing the .gitignore, relative to the search root.
    base: PathBuf,
    regex: Regex,
    negated: bool,
    dir_only: bool,
    anchored: bool,
}

fn load_gitignore(dir: &Path, rel_dir: &Path) -> Vec<IgnoreRule> {
    let Ok(text) = std::fs::read_to_string(dir.join(".gitignore")) else { return Vec::new() };
    text.lines().filter_map(|line| parse_ignore_line(line, rel_dir)).collect()
}

fn parse_ignore_line(line: &str, base: &Path) -> Option<IgnoreRule> {
    let line = line.trim_end();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let (negated, line) = match line.strip_prefix('!') {
        Some(rest) => (true, rest),
        None => (false, line),
    };
    let (dir_only, line) = match line.strip_suffix('/') {
        Some(rest) => (true, rest),
        None => (false, line),
    };
    if line.is_empty() {
        return None;
    }
    let anchored = line.contains('/');
    let pattern = line.trim_start_matches('/');
    if pattern.is_empty() {
        return None;
    }
    let regex = permissions::path_glob(pattern).ok()?;
    Some(IgnoreRule { base: base.to_path_buf(), regex, negated, dir_only, anchored })
}

fn is_ignored(rules: &[IgnoreRule], rel: &Path, is_dir: bool) -> bool {
    let mut ignored = false;
    for rule in rules {
        if rule.dir_only && !is_dir {
            continue;
        }
        let Ok(under) = rel.strip_prefix(&rule.base) else { continue };
        if under.as_os_str().is_empty() {
            continue;
        }
        let candidate;
        let subject: &str = if rule.anchored {
            candidate = slash(under);
            &candidate
        } else {
            match under.file_name() {
                Some(name) => {
                    candidate = name.to_string_lossy().into_owned();
                    &candidate
                }
                None => continue,
            }
        };
        if rule.regex.is_match(subject) {
            ignored = !rule.negated;
        }
    }
    ignored
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::permissions::PermissionsConfig;
    use crate::sandbox::SandboxConfig;

    fn policy_with_deny(deny: &[&str]) -> Policy {
        let config = PermissionsConfig { deny: deny.iter().map(|s| s.to_string()).collect(), ..Default::default() };
        Policy::new(&config, &SandboxConfig::default())
    }

    fn text_out(value: Value) -> String {
        match value {
            Value::String(s) => s,
            other => panic!("expected text result, got {other}"),
        }
    }

    /// A small tree:
    ///   src/main.rs        "fn main() {}\n// needle line\n"
    ///   src/lib.rs         "needle\nneedle again\n"
    ///   src/generated.rs   "needle but gitignored\n"  (via /src/generated.rs)
    ///   target/junk.rs     "needle but gitignored\n"  (via target/)
    ///   target/keep.rs     "needle kept\n"            (NOT un-ignored: parent pruned)
    ///   docs/notes.txt     "a needle in prose\n"
    ///   .env               "SECRET=needle\n"
    ///   .git/objects/x     "needle in git internals\n"
    ///   binary.bin         NUL bytes + "needle"
    ///   .gitignore         "target/\n/src/generated.rs\n"
    fn fixture() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let write = |rel: &str, content: &str| {
            let path = root.join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, content).unwrap();
        };
        write("src/main.rs", "fn main() {}\n// needle line\n");
        write("src/lib.rs", "needle\nneedle again\n");
        write("src/generated.rs", "needle but gitignored\n");
        write("target/junk.rs", "needle but gitignored\n");
        write("target/keep.rs", "needle kept\n");
        write("docs/notes.txt", "a needle in prose\n");
        write(".env", "SECRET=needle\n");
        write(".git/objects/x", "needle in git internals\n");
        std::fs::write(root.join("binary.bin"), b"\x00\x01needle\x00").unwrap();
        write(".gitignore", "target/\n/src/generated.rs\n");
        dir
    }

    #[test]
    fn grep_content_is_sorted_with_line_numbers_and_no_ignored_files() {
        let dir = fixture();
        let out = text_out(grep_in(&json!({"pattern": "needle"}), &Policy::default(), dir.path()).unwrap());
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(
            lines,
            vec![
                ".env:1:SECRET=needle",
                "docs/notes.txt:1:a needle in prose",
                "src/lib.rs:1:needle",
                "src/lib.rs:2:needle again",
                "src/main.rs:2:// needle line",
            ],
            "{out}"
        );
    }

    #[test]
    fn grep_files_and_count_modes() {
        let dir = fixture();
        let files = text_out(
            grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), dir.path()).unwrap(),
        );
        assert_eq!(files, ".env\ndocs/notes.txt\nsrc/lib.rs\nsrc/main.rs");
        let counts = text_out(
            grep_in(&json!({"pattern": "needle", "output_mode": "count"}), &Policy::default(), dir.path()).unwrap(),
        );
        assert_eq!(counts, ".env:1\ndocs/notes.txt:1\nsrc/lib.rs:2\nsrc/main.rs:1");
    }

    #[test]
    fn grep_glob_filter_limits_by_file_name_and_path() {
        let dir = fixture();
        let by_name =
            text_out(grep_in(&json!({"pattern": "needle", "glob": "*.rs"}), &Policy::default(), dir.path()).unwrap());
        assert!(by_name.contains("src/lib.rs:1:needle"), "{by_name}");
        assert!(!by_name.contains("notes.txt"), "{by_name}");
        let by_path = text_out(
            grep_in(&json!({"pattern": "needle", "glob": "docs/**"}), &Policy::default(), dir.path()).unwrap(),
        );
        assert_eq!(by_path, "docs/notes.txt:1:a needle in prose");
    }

    #[test]
    fn grep_reports_limit_truncation_and_no_matches() {
        let dir = fixture();
        let limited =
            text_out(grep_in(&json!({"pattern": "needle", "limit": 2}), &Policy::default(), dir.path()).unwrap());
        assert_eq!(limited.lines().count(), 3, "2 matches + note: {limited}");
        assert!(limited.contains("[limit 2 reached"), "{limited}");
        let none = text_out(grep_in(&json!({"pattern": "absent"}), &Policy::default(), dir.path()).unwrap());
        assert_eq!(none, NO_MATCHES);
    }

    #[test]
    fn grep_rejects_bad_arguments() {
        let dir = fixture();
        assert!(grep_in(&json!({"pattern": "("}), &Policy::default(), dir.path()).is_err(), "bad regex");
        assert!(grep_in(&json!({}), &Policy::default(), dir.path()).is_err(), "missing pattern");
        assert!(
            grep_in(&json!({"pattern": "x", "output_mode": "sideways"}), &Policy::default(), dir.path()).is_err(),
            "bad output_mode"
        );
        assert!(
            grep_in(&json!({"pattern": "x", "path": "nope"}), &Policy::default(), dir.path()).is_err(),
            "missing root is an error, not silence"
        );
        assert!(grep_in(&json!({"pattern": "x", "limit": 0}), &Policy::default(), dir.path()).is_err(), "zero limit");
    }

    #[test]
    fn grep_on_a_single_explicit_file() {
        let dir = fixture();
        // generated.rs is gitignored for walks but searchable when named.
        let out = text_out(
            grep_in(&json!({"pattern": "needle", "path": "src/generated.rs"}), &Policy::default(), dir.path()).unwrap(),
        );
        assert_eq!(out, "src/generated.rs:1:needle but gitignored");
    }

    #[test]
    fn read_deny_rules_filter_discovered_files() {
        let dir = fixture();
        let policy = policy_with_deny(&["Read(**/.env)"]);
        let out = text_out(grep_in(&json!({"pattern": "needle"}), &policy, dir.path()).unwrap());
        assert!(!out.contains(".env") && !out.contains("SECRET"), "denied file leaks: {out}");
        assert!(out.contains("src/lib.rs:1:needle"), "rest still searchable: {out}");
        let listed = text_out(glob_in(&json!({"pattern": "**/*"}), &policy, dir.path()).unwrap());
        assert!(!listed.lines().any(|l| l == ".env"), "glob leaks denied name: {listed}");

        // A denied directory name withholds its contents too.
        let policy = policy_with_deny(&["Read(**/docs)"]);
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &policy, dir.path()).unwrap());
        assert!(!out.contains("docs/notes.txt"), "denied dir leaks: {out}");
    }

    #[test]
    fn glob_matches_by_name_and_by_path_sorted() {
        let dir = fixture();
        let rs = text_out(glob_in(&json!({"pattern": "*.rs"}), &Policy::default(), dir.path()).unwrap());
        assert_eq!(rs, "src/lib.rs\nsrc/main.rs", "gitignored .rs files excluded: {rs}");
        let under_src = text_out(glob_in(&json!({"pattern": "src/**"}), &Policy::default(), dir.path()).unwrap());
        assert_eq!(under_src, "src/lib.rs\nsrc/main.rs");
        let scoped =
            text_out(glob_in(&json!({"pattern": "*.txt", "path": "docs"}), &Policy::default(), dir.path()).unwrap());
        assert_eq!(scoped, "docs/notes.txt");
        let limited =
            text_out(glob_in(&json!({"pattern": "**/*", "limit": 2}), &Policy::default(), dir.path()).unwrap());
        assert!(limited.contains("[showing first 2 of"), "{limited}");
        let none = text_out(glob_in(&json!({"pattern": "*.zzz"}), &Policy::default(), dir.path()).unwrap());
        assert_eq!(none, NO_MATCHES);
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_not_followed_so_walks_cannot_loop() {
        let dir = fixture();
        // A symlinked directory pointing at an ancestor and a symlinked file:
        // neither is followed, so the walk terminates and reports nothing
        // through the links.
        std::os::unix::fs::symlink(dir.path(), dir.path().join("src/loop")).unwrap();
        std::os::unix::fs::symlink(dir.path().join(".env"), dir.path().join("docs/link.txt")).unwrap();
        let out = text_out(
            grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), dir.path()).unwrap(),
        );
        assert!(!out.contains("loop"), "walked through a symlinked dir: {out}");
        assert!(!out.contains("link.txt"), "searched a symlinked file: {out}");
        assert!(out.contains("src/lib.rs"), "{out}");
    }

    #[test]
    fn nested_gitignore_and_negation() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::write(root.join(".gitignore"), "*.log\n!important.log\n").unwrap();
        std::fs::write(root.join("a.log"), "needle\n").unwrap();
        std::fs::write(root.join("important.log"), "needle\n").unwrap();
        std::fs::create_dir(root.join("sub")).unwrap();
        std::fs::write(root.join("sub/.gitignore"), "secret.txt\n").unwrap();
        std::fs::write(root.join("sub/secret.txt"), "needle\n").unwrap();
        std::fs::write(root.join("sub/open.txt"), "needle\n").unwrap();
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(out, "important.log\nsub/open.txt", "{out}");
    }
}
