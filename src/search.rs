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
//!   results (contents and names alike) via [`Policy::read_deny_scan`], which
//!   resolves the working directory once per search instead of canonicalizing
//!   every candidate against the filesystem.
//! * Binary files (NUL in the first 8 KiB, the `read_file` test) and files
//!   over 16 MiB are skipped by `grep`; results are sorted by path and
//!   capped, with an explicit truncation note rather than silent loss.
//! * Ignore loading is bounded on every axis: a per-file byte cap, a
//!   per-directory rule cap, a per-rule pattern-length cap, and a global
//!   compiled-rule budget shared across the whole walk, so a tree of
//!   near-cap ignore files cannot compile unbounded regexes.

use std::fs::File;
use std::io::{BufRead, BufReader, Read};
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
/// Cap on compiled `.gitignore` rules per directory: each rule is a compiled
/// regex, so an adversarial ignore file (e.g. 1 MiB of `x\n` lines) would
/// otherwise compile and retain hundreds of thousands of regexes before any
/// result limit applies.
const MAX_IGNORE_RULES: usize = 1_024;
/// Cap on compiled ignore rules across the *whole walk*. The per-directory
/// cap alone still lets a tree with many directories each carrying a near-cap
/// `.gitignore` compile N × `MAX_IGNORE_RULES` regexes; once this global
/// budget is spent, further ignore files stop contributing rules (fail-open
/// toward visibility, like an unreadable or oversized ignore file).
const MAX_TOTAL_IGNORE_RULES: usize = 16_384;
/// Cap on the length of a single ignore rule. `path_glob` compiles a rule
/// into a regex whose size and runtime grow linearly with the pattern (it
/// emits no nesting, backreferences or counted repetitions), so a length cap
/// is also a per-rule compile-cost cap: a multi-megabyte single line cannot
/// be turned into an equally large regex.
const MAX_IGNORE_RULE_CHARS: usize = 1_024;
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
    // The stat check above only covers the size at open time: a file that
    // keeps growing (an appended log) or one long unterminated line would
    // otherwise let `read_until` allocate and scan past the cap regardless
    // of `limit`. Take at most MAX_FILE_BYTES + 1 bytes from the reader so
    // peak memory stays at the cap even for a single over-cap line — the
    // plain `read_until` loop below would buffer cap + line before the
    // discard decision. A file that ends exactly at the take boundary is
    // caught after the loop via the take's remaining `limit`.
    let mut reader = BufReader::new(file.take(MAX_FILE_BYTES + 1));
    let mut raw: Vec<u8> = Vec::new();
    let mut sniffed = 0usize;
    let mut line_no = 0usize;
    let mut consumed = 0u64;
    loop {
        raw.clear();
        match reader.read_until(b'\n', &mut raw) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        consumed += raw.len() as u64;
        if consumed > MAX_FILE_BYTES {
            // Past the per-file budget: discard any matches gathered so far,
            // exactly as if the stat had already reported the file oversized.
            return FileMatches::default();
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
            if found.lines.len() < collect_up_to {
                found.lines.push((line_no, clip_line(line)));
            }
        }
        // Test for an early return after *every* line, not only matching ones.
        // Otherwise a file whose last useful match lands before the early-exit
        // condition is met would keep scanning its non-matching tail (up to
        // 16 MiB) for nothing. Gate on a completed binary-sniff window (at EOF
        // the loop ends anyway) so a NUL later in the window is never missed —
        // binary exclusion must depend on the file's contents, not on the mode
        // or limit.
        if sniffed >= BINARY_SNIFF_BYTES {
            if first_only && found.count > 0 {
                return found;
            }
            if collect_up_to > 0 && found.lines.len() >= collect_up_to {
                // Past what the caller can use; `count` already proves it.
                return found;
            }
        }
    }
    // The take adapter stops the read at MAX_FILE_BYTES + 1. A file that
    // reaches that boundary without a newline ever crossing it (a single
    // over-cap line, or content that grew to exactly cap + 1) is over
    // budget: discard its matches just like the in-loop crossing does.
    if reader.get_ref().limit() == 0 {
        return FileMatches::default();
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
        let trimmed = pattern.trim();
        let cleaned = trimmed.strip_prefix("./").unwrap_or(trimmed).trim_start_matches('/');
        if cleaned.is_empty() {
            bail!("glob pattern must not be empty");
        }
        let regex = permissions::path_glob(cleaned).map_err(anyhow::Error::msg)?;
        // Decide name-vs-root-relative from the *original* pattern, before the
        // leading `./` or `/` is stripped. Those prefixes mark a root-relative
        // pattern (`./*.rs`, `/main.rs`); keying `by_name` off the stripped
        // form would drop that and wrongly match the name at any depth.
        Ok(Self { regex, by_name: !trimmed.contains('/') })
    }

    fn matches(&self, file: &FoundFile) -> bool {
        if self.by_name {
            let name = file.rel.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
            return self.regex.is_match(&name);
        }
        if self.regex.is_match(&slash(&file.rel)) {
            return true;
        }
        // The display path is only a valid match target for an explicitly
        // named file root. For a directory search a file's display path
        // includes the search root, so matching it would wrongly let a
        // root-qualified pattern (e.g. `src/**/*.rs` under `path: "src"`)
        // match files that are not actually under that sub-path.
        file.explicit_file && self.regex.is_match(file.display.trim_start_matches("./"))
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
    /// True only for an explicitly named file root (`path` was a file).
    explicit_file: bool,
}

fn collect_files(root: &str, cwd: &Path, policy: &Policy) -> Result<Vec<FoundFile>> {
    let root_path = Path::new(root);
    let fs_root = if root_path.is_absolute() { root_path.to_path_buf() } else { cwd.join(root_path) };
    let metadata = std::fs::metadata(&fs_root)
        .with_context(|| format!("search path {} does not exist or is not readable", root))?;

    if metadata.is_file() {
        // An explicitly named file is searched even if a .gitignore rule or
        // the include glob would skip it in a walk; deny rules still apply.
        if let Some(scan) = policy.read_deny_scan(cwd)
            && scan.denied(&fs_root)
        {
            return Ok(Vec::new());
        }
        let rel = root_path.file_name().map(PathBuf::from).unwrap_or_else(|| root_path.to_path_buf());
        return Ok(vec![FoundFile { fs_path: fs_root, display: root.to_string(), rel, explicit_file: true }]);
    }
    if !metadata.is_dir() {
        bail!("search path {root} is neither a file nor a directory");
    }

    // Precompute the Read-deny check once per search: applicable rules and
    // the resolved working directory are fixed for the whole walk, so the
    // per-entry filter below is pure path manipulation and regex matching
    // instead of one `canonicalize` syscall per discovered entry. `None`
    // means no Read-deny rule exists, so no permission work at all.
    let scan = policy.read_deny_scan(cwd);
    let mut budget = MAX_TOTAL_IGNORE_RULES;
    let mut out = Vec::new();
    walk_dir(&fs_root, &PathBuf::new(), root, scan.as_ref(), &[], &mut budget, &mut out, true)?;
    out.sort_by(|a, b| a.display.cmp(&b.display));
    Ok(out)
}

#[allow(clippy::too_many_arguments)]
fn walk_dir(
    dir: &Path,
    rel_dir: &Path,
    root: &str,
    scan: Option<&permissions::ReadDenyScan>,
    inherited: &[IgnoreRule],
    budget: &mut usize,
    out: &mut Vec<FoundFile>,
    is_root: bool,
) -> Result<()> {
    let mut rules: Vec<IgnoreRule> = inherited.to_vec();
    rules.extend(load_gitignore(dir, rel_dir, scan, budget));

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
        if let Some(scan) = scan
            && scan.denied(&fs_path)
        {
            continue;
        }
        if file_type.is_dir() {
            walk_dir(&fs_path, &rel, root, scan, &rules, budget, out, false)?;
        } else if file_type.is_file() {
            out.push(FoundFile { display: display_path(root, &rel), fs_path, rel, explicit_file: false });
        }
    }
    Ok(())
}

fn display_path(root: &str, rel: &Path) -> String {
    let rel = slash(rel);
    let trimmed = root.trim_end_matches('/');
    if trimmed == "." {
        return rel;
    }
    if trimmed.is_empty() {
        // `root` is empty (cwd) or consists only of slashes (a filesystem
        // root like `/`). Keep the leading slash for the latter so the
        // returned path stays absolute and usable with `read_file`.
        return if root.is_empty() { rel } else { format!("/{rel}") };
    }
    // Keep `trimmed` exactly as given; do not strip a leading `./`. Trimming
    // can turn a relative root like `.//src` into the absolute `/src`, so the
    // reported path would open a different file (or fail) under `read_file`.
    format!("{trimmed}/{rel}")
}

fn slash(path: &Path) -> String {
    // A backslash is a path separator only on Windows; on Unix it is a valid
    // filename character, so rewriting it would corrupt real paths.
    #[cfg(windows)]
    {
        path.to_string_lossy().replace('\\', "/")
    }
    #[cfg(not(windows))]
    {
        path.to_string_lossy().into_owned()
    }
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

fn load_gitignore(
    dir: &Path,
    rel_dir: &Path,
    scan: Option<&permissions::ReadDenyScan>,
    budget: &mut usize,
) -> Vec<IgnoreRule> {
    let path = dir.join(".gitignore");
    // Apply the same safety checks the walker uses for discovered entries
    // *before* reading: never follow a symlink out of the tree, never open a
    // non-regular file (a FIFO would block, a device like `/dev/zero` would
    // allocate without bound), and honour Read-deny rules.
    let Ok(meta) = std::fs::symlink_metadata(&path) else { return Vec::new() };
    if !meta.file_type().is_file() {
        return Vec::new();
    }
    if let Some(scan) = scan
        && scan.denied(&path)
    {
        return Vec::new();
    }
    // Bound the read so a pathological `.gitignore` cannot exhaust memory
    // before any result limit applies. grep's 16 MiB per-file guard covers
    // searched content, not this traversal step, so a large regular or sparse
    // ignore file would otherwise be slurped whole even for `glob` with
    // `limit: 1`. Skip files the stat already reports as oversized, and cap the
    // actual read too so growth between the stat and the open cannot bypass the
    // check.
    if meta.len() > MAX_FILE_BYTES {
        return Vec::new();
    }
    let Ok(file) = File::open(&path) else { return Vec::new() };
    let mut text = String::new();
    if file.take(MAX_FILE_BYTES + 1).read_to_string(&mut text).is_err() {
        return Vec::new();
    }
    if text.len() as u64 > MAX_FILE_BYTES {
        return Vec::new();
    }
    // The byte cap alone does not bound compiled state: a small file of
    // repeated short lines still compiles one regex per rule, all retained
    // for the traversal. Cap the rule count too; past the budget the file's
    // rules stop applying (fail-open toward visibility, like an unreadable or
    // oversized ignore file) rather than compiling unbounded regexes before
    // any result limit applies.
    let per_dir = MAX_IGNORE_RULES.min(*budget);
    let rules: Vec<IgnoreRule> =
        text.lines().filter_map(|line| parse_ignore_line(line, rel_dir)).take(per_dir).collect();
    // The per-directory cap is not a total: a tree of many directories each
    // carrying a near-cap ignore file would still compile N × MAX_IGNORE_RULES
    // regexes. Draw every compiled rule from the walk-wide budget so the
    // total stays bounded no matter how the tree is shaped.
    *budget -= rules.len();
    rules
}

fn parse_ignore_line(line: &str, base: &Path) -> Option<IgnoreRule> {
    let line = line.trim_end();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    // `path_glob` compiles a rule into a regex whose size grows linearly with
    // the pattern, so a length cap is also a per-rule compile-cost cap: a
    // single multi-megabyte line cannot become an equally large regex. An
    // over-long rule is dropped, not fatal — same fail-open policy as the
    // other ignore-file guards.
    if line.chars().count() > MAX_IGNORE_RULE_CHARS {
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

    #[test]
    fn binary_exclusion_is_independent_of_mode_and_limit() {
        // Four matching lines then a NUL inside the sniff window. Binary
        // exclusion must not depend on the mode or on how early a match-driven
        // return fires, so every mode (and a limit of 1) must skip this file.
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("trap.txt"), b"needle\nneedle\nneedle\nneedle\n\x00rest").unwrap();
        for args in [
            json!({"pattern": "needle"}),
            json!({"pattern": "needle", "limit": 1}),
            json!({"pattern": "needle", "output_mode": "files"}),
            json!({"pattern": "needle", "output_mode": "files", "limit": 1}),
            json!({"pattern": "needle", "output_mode": "count"}),
        ] {
            let out = text_out(grep_in(&args, &Policy::default(), dir.path()).unwrap());
            assert_eq!(out, NO_MATCHES, "binary file leaked for {args}");
        }
    }

    #[test]
    fn root_qualified_glob_does_not_match_via_display_path() {
        // Under `path: "src"`, a pattern that names the root again must only
        // match files genuinely under that sub-path, not every file whose
        // display path happens to start with the root.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("src/src")).unwrap();
        std::fs::write(root.join("src/lib.rs"), "x\n").unwrap();
        std::fs::write(root.join("src/src/inner.rs"), "x\n").unwrap();
        let out =
            text_out(glob_in(&json!({"pattern": "src/**/*.rs", "path": "src"}), &Policy::default(), root).unwrap());
        assert_eq!(out, "src/src/inner.rs", "display-path fallback over-matched: {out}");
        // grep's include filter shares the same rule.
        let grep_out = text_out(
            grep_in(
                &json!({"pattern": "x", "glob": "src/**/*.rs", "path": "src", "output_mode": "files"}),
                &Policy::default(),
                root,
            )
            .unwrap(),
        );
        assert_eq!(grep_out, "src/src/inner.rs", "grep include filter over-matched: {grep_out}");
    }

    #[test]
    fn oversized_gitignore_is_skipped() {
        // A pathological `.gitignore` (larger than the per-file byte cap) must
        // not be slurped into memory; it is skipped entirely, so its rules do
        // not apply and matching files stay visible.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut rules = String::from("*.rs\n");
        rules.push_str(&"#".repeat((MAX_FILE_BYTES as usize) + 1024));
        std::fs::write(root.join(".gitignore"), rules).unwrap();
        std::fs::write(root.join("a.rs"), "needle\n").unwrap();
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(out, "a.rs", "oversized .gitignore was honoured: {out}");
    }

    #[test]
    fn gitignore_rule_budget_stops_compilation() {
        // A `.gitignore` under the byte cap can still hold an unbounded number
        // of rules (one compiled regex each). Past MAX_IGNORE_RULES the file's
        // rules must stop applying, so a rule flood cannot compile and retain
        // hundreds of thousands of regexes before any result limit applies.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut rules = String::new();
        for i in 0..(MAX_IGNORE_RULES + 1) {
            rules.push_str(&format!("f{i}\n"));
        }
        std::fs::write(root.join(".gitignore"), rules).unwrap();
        // The rule that lands past the budget must not take effect.
        std::fs::write(root.join(format!("f{MAX_IGNORE_RULES}")), "needle\n").unwrap();
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(out, format!("f{MAX_IGNORE_RULES}"), "rule past the budget was honoured: {out}");
    }

    #[test]
    fn search_file_discards_matches_past_byte_cap() {
        // The stat check only covers the size at open time. A file whose
        // content crosses the cap while being read (one long unterminated
        // line, or an appended log) must be treated as oversized: matches
        // gathered before the crossing are discarded, not returned.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut content = String::from("needle\n");
        content.push_str(&"x".repeat((MAX_FILE_BYTES as usize) + 1024));
        std::fs::write(root.join("growing.log"), content).unwrap();
        for args in [
            json!({"pattern": "needle"}),
            json!({"pattern": "needle", "output_mode": "files"}),
            json!({"pattern": "needle", "output_mode": "count"}),
        ] {
            let out = text_out(grep_in(&args, &Policy::default(), root).unwrap());
            assert_eq!(out, NO_MATCHES, "match past the byte cap leaked for {args}");
        }
    }

    #[test]
    fn search_file_bounds_peak_memory_at_the_cap() {
        // A single unterminated line longer than the cap: the streaming take
        // reader must bound what is buffered at MAX_FILE_BYTES + 1 (peak
        // memory at the cap, not cap + line) and still discard the file.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut content = String::from("needle ");
        content.push_str(&"x".repeat((MAX_FILE_BYTES as usize) * 2));
        std::fs::write(root.join("oneline.log"), content).unwrap();
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(out, NO_MATCHES, "over-cap single line leaked: {out}");
    }

    #[test]
    fn search_file_accepts_content_just_under_the_cap() {
        // The streaming take reader must not reject a file that stays within
        // the budget: content ending exactly at MAX_FILE_BYTES with a final
        // newline never crosses the cap.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut content = String::from("needle\n");
        content.push_str(&"x".repeat(MAX_FILE_BYTES as usize - content.len() - 1));
        content.push('\n');
        assert_eq!(content.len() as u64, MAX_FILE_BYTES);
        std::fs::write(root.join("exact.log"), content).unwrap();
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(out, "exact.log", "at-cap content wrongly discarded: {out}");
    }

    #[test]
    fn global_ignore_rule_budget_spans_directories() {
        // The per-directory cap is not a total: without the walk-wide budget
        // a tree of many directories each carrying a near-cap .gitignore
        // would compile N × MAX_IGNORE_RULES regexes. Once the global budget
        // is spent, further ignore files must stop contributing rules.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let per_dir = 512;
        let dirs = MAX_TOTAL_IGNORE_RULES / per_dir + 2;
        for i in 0..dirs {
            let sub = root.join(format!("d{i:03}"));
            std::fs::create_dir(&sub).unwrap();
            let rules: String = (0..per_dir).map(|r| format!("f{r}\n")).collect();
            std::fs::write(sub.join(".gitignore"), rules).unwrap();
            // This file is ignored only while the directory's rules are
            // still within the global budget.
            std::fs::write(sub.join("f0"), "needle\n").unwrap();
        }
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        let visible: Vec<&str> = out.lines().collect();
        // Directories are walked in name order; the budget runs out part-way
        // through the last two, so exactly their files stay visible.
        let expected: Vec<String> = (dirs - 2..dirs).map(|i| format!("d{i:03}/f0")).collect();
        assert_eq!(visible, expected, "global budget not enforced: {out}");
    }

    #[test]
    fn oversized_single_ignore_rule_is_dropped() {
        // A pathological single line (far past MAX_IGNORE_RULE_CHARS) must
        // not be compiled into an equally large regex: the rule is dropped,
        // so the file it tried to ignore stays visible, while well-formed
        // rules around it still apply.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let long_rule = format!("**/{}", "a".repeat(MAX_IGNORE_RULE_CHARS * 4));
        std::fs::write(root.join(".gitignore"), format!("{long_rule}\n*.log\n")).unwrap();
        std::fs::write(root.join("a.rs"), "needle\n").unwrap();
        std::fs::write(root.join("b.log"), "needle\n").unwrap();
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(out, "a.rs", "over-long rule was honoured or broke neighbours: {out}");
    }

    #[test]
    fn read_deny_scan_matches_read_denied_without_per_entry_stat() {
        // The batched scan must agree with the per-path check while doing no
        // per-candidate filesystem resolution — including when the working
        // directory itself is reached through a symlink.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join("config")).unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        let policy = policy_with_deny(&["Read(**/.env)"]);
        let scan = policy.read_deny_scan(&root).expect("deny rules present");
        assert!(scan.denied(&root.join("config/.env")));
        assert!(!scan.denied(&root.join("src/main.rs")));

        #[cfg(unix)]
        {
            let alias = root.join("alias");
            std::os::unix::fs::symlink(&root, &alias).unwrap();
            let scan = policy.read_deny_scan(&alias).expect("deny rules present");
            assert!(scan.denied(&alias.join("config/.env")), "symlinked cwd leaks a denied path");
            assert!(!scan.denied(&alias.join("src/main.rs")));
        }

        // No Read-deny rules → no scan, so the walker skips permission work
        // entirely (the pre-existing fast path).
        assert!(Policy::default().read_deny_scan(&root).is_none());
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_gitignore_is_not_followed() {
        // A `.gitignore` that is a symlink (which could point outside the tree
        // at a device or FIFO) must not be read; its rules must not apply.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::write(root.join("rules.txt"), "*.rs\n").unwrap();
        std::os::unix::fs::symlink(root.join("rules.txt"), root.join(".gitignore")).unwrap();
        std::fs::write(root.join("a.rs"), "needle\n").unwrap();
        let out =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(out, "a.rs", "symlinked .gitignore was honoured: {out}");
    }

    #[test]
    fn display_path_preserves_filesystem_root() {
        assert_eq!(display_path("/", Path::new("etc/hosts")), "/etc/hosts");
        assert_eq!(display_path("//", Path::new("etc/hosts")), "/etc/hosts");
        assert_eq!(display_path(".", Path::new("a.rs")), "a.rs");
        assert_eq!(display_path("", Path::new("a.rs")), "a.rs");
        assert_eq!(display_path("src", Path::new("a.rs")), "src/a.rs");
        assert_eq!(display_path("src/", Path::new("a.rs")), "src/a.rs");
    }

    #[cfg(not(windows))]
    #[test]
    fn slash_keeps_literal_backslashes_on_unix() {
        // A backslash is a valid filename character on Unix, not a separator.
        assert_eq!(slash(Path::new("a\\b.rs")), "a\\b.rs");
        assert_eq!(display_path("src", Path::new("a\\b.rs")), "src/a\\b.rs");
    }

    #[test]
    fn root_relative_pattern_is_not_name_matched() {
        // A leading `./` or `/` marks a root-relative pattern: `./*.rs` and
        // `/main.rs` must match only at the root, not the bare name at any
        // depth. `by_name` is decided from the original pattern, so stripping
        // the prefix must not collapse them into name matches.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("main.rs"), "x\n").unwrap();
        std::fs::write(root.join("sub/main.rs"), "x\n").unwrap();
        for pattern in ["./*.rs", "/main.rs"] {
            let out = text_out(glob_in(&json!({"pattern": pattern}), &Policy::default(), root).unwrap());
            assert_eq!(out, "main.rs", "root-relative pattern {pattern} leaked a nested file: {out}");
        }
        // A bare name pattern still matches at any depth.
        let out = text_out(glob_in(&json!({"pattern": "main.rs"}), &Policy::default(), root).unwrap());
        assert_eq!(out, "main.rs\nsub/main.rs", "bare-name pattern should match at any depth: {out}");
    }

    #[test]
    fn display_path_preserves_relative_root() {
        // Trimming a leading `./` can turn a relative root into an absolute
        // path (`.//src` -> `/src`), which would open a different file.
        assert_eq!(display_path("./src", Path::new("a.rs")), "./src/a.rs");
        assert_eq!(display_path(".//src", Path::new("a.rs")), ".//src/a.rs");
    }

    #[test]
    fn explicit_file_root_preserves_relative_prefix() {
        // An explicitly named file root is reported verbatim; a leading `./`
        // (or `.//`) must survive so the path stays relative and usable with
        // `read_file`, never collapsing to an absolute `/a.rs`.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::write(root.join("a.rs"), "needle\n").unwrap();
        let out = text_out(
            grep_in(&json!({"pattern": "needle", "path": ".//a.rs", "output_mode": "files"}), &Policy::default(), root)
                .unwrap(),
        );
        assert_eq!(out, ".//a.rs", "explicit-file display dropped its relative prefix: {out}");
    }

    #[test]
    fn early_return_is_correct_with_long_nonmatching_tail() {
        // A single early match followed by a long non-matching tail: the
        // per-line early return must still report the file in every mode and
        // count accurately, without over-scanning or under-counting.
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let mut body = String::from("needle\nneedle\n");
        for _ in 0..5000 {
            body.push_str("filler\n");
        }
        std::fs::write(root.join("big.txt"), &body).unwrap();
        let files =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "files"}), &Policy::default(), root).unwrap());
        assert_eq!(files, "big.txt");
        let count =
            text_out(grep_in(&json!({"pattern": "needle", "output_mode": "count"}), &Policy::default(), root).unwrap());
        assert_eq!(count, "big.txt:2");
        let content = text_out(grep_in(&json!({"pattern": "needle", "limit": 1}), &Policy::default(), root).unwrap());
        assert!(content.starts_with("big.txt:1:needle"), "content mode wrong: {content}");
    }
}
