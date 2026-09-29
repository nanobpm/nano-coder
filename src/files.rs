//! File tools: `read_file`, `write_file`, `edit_file`.
//!
//! Relative paths resolve against the process working directory, which ACP
//! `session/new` sets from `params.cwd`.

use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};

use crate::output;
use crate::tools::{ToolDefinition, ToolRegistry};

const DEFAULT_READ_LINES: usize = 2000;
const MAX_LINE_CHARS: usize = 2000;
const MAX_READ_BYTES: usize = 100_000;

/// Content hashes of files as the model last saw them: recorded by
/// `read_file` and by this module's own writes. `edit_file`, and `write_file`
/// over an existing file, refuse to write unless the file on disk still
/// matches, so an edit planned against text that has since changed (a `bash`
/// command, a formatter, the user in their editor) can't land on the wrong
/// code. Keyed by canonical path so symlinks and relative paths agree.
static SEEN: LazyLock<Mutex<HashMap<PathBuf, u64>>> = LazyLock::new(Default::default);

fn seen_key(path: &Path) -> PathBuf {
    std::fs::canonicalize(path)
        .or_else(|_| std::path::absolute(path))
        .unwrap_or_else(|_| path.to_path_buf())
}

fn digest(bytes: &[u8]) -> u64 {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

fn remember(path: &Path, bytes: &[u8]) {
    SEEN.lock().unwrap_or_else(|e| e.into_inner()).insert(seen_key(path), digest(bytes));
}

/// Fail unless `current` (the file's bytes on disk) is what the model last saw.
fn check_fresh(path: &Path, current: &[u8]) -> Result<()> {
    let seen = SEEN.lock().unwrap_or_else(|e| e.into_inner()).get(&seen_key(path)).copied();
    match seen {
        None => bail!(
            "{} has not been read yet; read it with read_file before changing it",
            path.display()
        ),
        Some(hash) if hash != digest(current) => bail!(
            "{} has changed since it was last read (by a command, a tool or the user); read it again before changing it",
            path.display()
        ),
        Some(_) => Ok(()),
    }
}

fn string_arg<'a>(args: &'a Value, name: &str) -> Result<&'a str> {
    args.get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing string argument {name:?}"))
}

fn path_arg(args: &Value) -> Result<PathBuf> {
    let path = string_arg(args, "path")?;
    if path.trim().is_empty() {
        bail!("path must not be empty");
    }
    Ok(PathBuf::from(path))
}

fn count_arg(args: &Value, name: &str) -> Result<Option<usize>> {
    match args.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|n| *n >= 1)
            .map(|n| Some(n as usize))
            .ok_or_else(|| anyhow!("{name} must be a positive integer")),
    }
}

/// Numbered lines `offset..offset+limit` (1-based) of a text file.
pub fn read_file(args: &Value) -> Result<String> {
    let path = path_arg(args)?;
    let offset = count_arg(args, "offset")?.unwrap_or(1);
    let limit = count_arg(args, "limit")?.unwrap_or(DEFAULT_READ_LINES);
    let bytes = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    if bytes.iter().take(8192).any(|b| *b == 0) {
        bail!("{} looks like a binary file ({} bytes)", path.display(), bytes.len());
    }
    remember(&path, &bytes);
    let text = String::from_utf8_lossy(&bytes);
    let total = text.lines().count();
    if total == 0 {
        return Ok(format!("({} is empty)", path.display()));
    }
    if offset > total {
        bail!("offset {offset} is past the end of {} ({total} lines)", path.display());
    }
    let mut out = String::new();
    for (index, line) in text.lines().enumerate().skip(offset - 1).take(limit) {
        let line = if line.chars().count() > MAX_LINE_CHARS {
            format!("{}... [line truncated]", line.chars().take(MAX_LINE_CHARS).collect::<String>())
        } else {
            line.to_string()
        };
        out.push_str(&format!("{:>6}\t{line}\n", index + 1));
    }
    let last = (offset - 1 + limit).min(total);
    if last < total {
        out.push_str(&format!(
            "[showing lines {offset}-{last} of {total}; use offset={} to continue]\n",
            last + 1
        ));
    }
    Ok(output::bound_output(&out, MAX_READ_BYTES).0)
}

fn write_atomically(path: &Path, content: &str) -> Result<()> {
    // Write through symlinks: renaming onto the link would replace it with a file.
    let resolved;
    let path = if path.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) {
        resolved = std::fs::canonicalize(path)
            .with_context(|| format!("resolve symlink {}", path.display()))?;
        resolved.as_path()
    } else {
        path
    };
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let name = path.file_name().ok_or_else(|| anyhow!("{} is not a file path", path.display()))?;
    let tmp = path.with_file_name(format!(".{}.tmp-{}", name.to_string_lossy(), std::process::id()));
    std::fs::write(&tmp, content).with_context(|| format!("write {}", tmp.display()))?;
    if let Ok(meta) = std::fs::metadata(path) {
        std::fs::set_permissions(&tmp, meta.permissions()).ok();
    }
    std::fs::rename(&tmp, path).with_context(|| format!("replace {}", path.display()))
}

/// A located edit: replace each of `ranges` in the text with `new`. `how` says which
/// relaxed rule found it (None for an exact match).
struct Located {
    ranges: Vec<(usize, usize)>,
    new: String,
    how: Option<&'static str>,
}

/// Convert `s` to the file's line endings: `read_file` shows lines without
/// `\r`, so the model writes `\n` even for CRLF files.
fn to_file_endings(text: &str, s: &str) -> String {
    if text.contains("\r\n") && !s.contains('\r') {
        s.replace('\n', "\r\n")
    } else {
        s.to_string()
    }
}

/// `read_file` prefixes each line with a right-aligned number and a tab. If
/// the model copied those into `old_string` (every non-blank line has one),
/// strip them from both strings.
fn strip_line_numbers(old: &str, new: &str) -> Option<(String, String)> {
    fn prefixed(line: &str) -> Option<&str> {
        let (num, rest) = line.trim_start().split_once('\t')?;
        (!num.is_empty() && num.bytes().all(|b| b.is_ascii_digit())).then_some(rest)
    }
    let lines: Vec<&str> = old.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() || !lines.iter().all(|l| prefixed(l).is_some()) {
        return None;
    }
    let strip = |s: &str| {
        let body: Vec<&str> = s.split('\n').map(|l| prefixed(l).unwrap_or(l)).collect();
        body.join("\n")
    };
    Some((strip(old), strip(new)))
}

/// The file's lines as (start, end-of-content, end-including-terminator)
/// byte offsets.
fn line_spans(text: &str) -> Vec<(usize, usize, usize)> {
    let mut spans = Vec::new();
    let mut at = 0;
    for line in text.split_inclusive('\n') {
        let content = line.trim_end_matches('\n').trim_end_matches('\r');
        spans.push((at, at + content.len(), at + line.len()));
        at += line.len();
    }
    spans
}

/// `old`'s lines without a trailing empty line, and whether it ended in `\n`.
fn old_lines(old: &str) -> (Vec<&str>, bool) {
    let ends_nl = old.ends_with('\n');
    let body = if ends_nl { &old[..old.len() - 1] } else { old };
    (body.split('\n').map(|l| l.trim_end_matches('\r')).collect(), ends_nl)
}

fn leading_ws(s: &str) -> &str {
    &s[..s.len() - s.trim_start().len()]
}

/// Match `old` line by line, ignoring trailing whitespace (`trim_start`:
/// all leading and trailing whitespace). Only a unique match is used; with
/// `trim_start` the replacement is re-indented by the difference between the
/// file's indentation and `old`'s.
fn match_lines(text: &str, old: &str, new: &str, trim_start: bool) -> Result<Option<Located>> {
    let spans = line_spans(text);
    let (lines, ends_nl) = old_lines(old);
    let k = lines.len();
    if lines.iter().all(|l| l.trim().is_empty()) || spans.len() < k {
        return Ok(None);
    }
    let norm = |s: &str| if trim_start { s.trim().to_string() } else { s.trim_end().to_string() };
    let file_line = |i: usize| &text[spans[i].0..spans[i].1];
    let hits: Vec<usize> = (0..=spans.len() - k)
        .filter(|&i| (0..k).all(|j| norm(file_line(i + j)) == norm(lines[j])))
        .collect();
    let how = if trim_start { "ignoring indentation" } else { "ignoring trailing whitespace" };
    let i = match hits.as_slice() {
        [] => return Ok(None),
        [i] => *i,
        _ => bail!(
            "old_string matches {} places ({how}); add surrounding context to make it unique",
            hits.len()
        ),
    };
    let start = spans[i].0;
    let end = if ends_nl { spans[i + k - 1].2 } else { spans[i + k - 1].1 };
    let mut new = new.to_string();
    if trim_start && let Some(j) = lines.iter().position(|l| !l.trim().is_empty()) {
        let (want, had) = (leading_ws(file_line(i + j)), leading_ws(lines[j]));
        if want != had {
            new = new
                .split('\n')
                .map(|l| match l.strip_prefix(had) {
                    Some(rest) if !l.trim().is_empty() => format!("{want}{rest}"),
                    _ => l.to_string(),
                })
                .collect::<Vec<_>>()
                .join("\n");
        }
    }
    Ok(Some(Located { ranges: vec![(start, end)], new: to_file_endings(text, &new), how: Some(how) }))
}

/// Find where `old` is in `text`: exactly first (as the model saw it, then
/// with `read_file` line numbers removed), then line by line ignoring
/// trailing whitespace, then ignoring indentation. Relaxed matches must be
/// unique; fuzzier matching (edit distance) is deliberately not attempted,
/// since a wrong guess edits the wrong code.
fn locate(text: &str, old: &str, new: &str, replace_all: bool) -> Result<Located> {
    let mut attempts = vec![(old.to_string(), new.to_string(), None)];
    if let Some((o, n)) = strip_line_numbers(old, new) {
        attempts.push((o, n, Some("after removing read_file line numbers")));
    }
    for (o, n, how) in &attempts {
        let (o, n) = if text.contains(o.as_str()) {
            (o.clone(), n.clone())
        } else {
            (to_file_endings(text, o), to_file_endings(text, n))
        };
        let ranges: Vec<(usize, usize)> = text.match_indices(o.as_str()).map(|(at, _)| (at, at + o.len())).collect();
        match ranges.len() {
            0 => {}
            1 => return Ok(Located { ranges, new: n, how: *how }),
            _ if replace_all => return Ok(Located { ranges, new: n, how: *how }),
            count => bail!(
                "old_string occurs {count} times; add surrounding context to make it unique or set replace_all"
            ),
        }
    }
    for trim_start in [false, true] {
        for (o, n, _) in &attempts {
            if let Some(found) = match_lines(text, o, n, trim_start)? {
                return Ok(found);
            }
        }
    }
    bail!("old_string not found; read the file and copy the text exactly{}", near_miss(text, &attempts.last().unwrap().0))
}

/// Lines `lo..=hi` (0-based) of `text`, numbered as `read_file` shows them.
/// Long spans keep their first and last 20 lines.
fn numbered(lines: &[&str], lo: usize, hi: usize) -> String {
    let fmt = |i: usize| {
        let line: String = lines[i].chars().take(MAX_LINE_CHARS).collect();
        format!("{:>6}\t{line}\n", i + 1)
    };
    if hi + 1 - lo > 40 {
        let mut out: String = (lo..lo + 20).map(fmt).collect();
        out.push_str("   ...\n");
        out.extend((hi - 19..=hi).map(fmt));
        out
    } else {
        (lo..=hi).map(fmt).collect()
    }
}

/// The edited region of `text` (bytes `start..end`) with three lines of
/// context either side, so the model can check the result without a re-read.
fn snippet(text: &str, start: usize, end: usize) -> String {
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return "(the file is now empty)\n".into();
    }
    let first = text[..start].matches('\n').count().min(lines.len() - 1);
    let region = &text[start..end];
    let last = (first + region.strip_suffix('\n').unwrap_or(region).matches('\n').count()).min(lines.len() - 1);
    numbered(&lines, first.saturating_sub(3), (last + 3).min(lines.len() - 1))
}

/// For a failed match: the window of the file sharing the most (trimmed,
/// non-blank) lines with `old`, so the next attempt can copy it exactly.
fn near_miss(text: &str, old: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let (want, _) = old_lines(old);
    let k = want.len().min(lines.len());
    if k == 0 {
        return String::new();
    }
    let score = |i: usize| {
        (0..k)
            .filter(|&j| !want[j].trim().is_empty() && lines[i + j].trim() == want[j].trim())
            .count()
    };
    let Some((best, i)) = (0..=lines.len() - k).map(|i| (score(i), i)).max_by_key(|&(s, i)| (s, std::cmp::Reverse(i)))
    else {
        return String::new();
    };
    if best == 0 {
        return String::new();
    }
    let of = want.iter().filter(|l| !l.trim().is_empty()).count();
    format!(
        ". Closest match ({best} of {of} lines agree), lines {}-{}:\n{}",
        i + 1,
        i + k,
        numbered(&lines, i, i + k - 1)
    )
}

pub fn write_file(args: &Value) -> Result<String> {
    let path = path_arg(args)?;
    let content = string_arg(args, "content")?;
    let existed = path.exists();
    if existed && let Ok(current) = std::fs::read(&path) {
        check_fresh(&path, &current)?;
    }
    write_atomically(&path, content)?;
    remember(&path, content.as_bytes());
    Ok(format!(
        "{} {} ({} bytes)",
        if existed { "Overwrote" } else { "Created" },
        path.display(),
        content.len()
    ))
}

pub fn edit_file(args: &Value) -> Result<String> {
    let path = path_arg(args)?;
    let old = string_arg(args, "old_string")?;
    let new = string_arg(args, "new_string")?;
    let replace_all = args.get("replace_all").and_then(Value::as_bool).unwrap_or(false);
    if old.is_empty() {
        bail!("old_string must not be empty (use write_file to create a file)");
    }
    if old == new {
        bail!("old_string and new_string are identical");
    }
    let bytes = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    check_fresh(&path, &bytes)?;
    let text = String::from_utf8(bytes).map_err(|_| anyhow!("{} is not valid UTF-8", path.display()))?;
    let found = locate(&text, old, new, replace_all).map_err(|e| anyhow!("{}: {e}", path.display()))?;
    let mut updated = String::with_capacity(text.len() + found.new.len());
    let mut last = 0;
    let mut first_new = 0;
    for (n, &(start, end)) in found.ranges.iter().enumerate() {
        updated.push_str(&text[last..start]);
        if n == 0 {
            first_new = updated.len();
        }
        updated.push_str(&found.new);
        last = end;
    }
    updated.push_str(&text[last..]);
    write_atomically(&path, &updated)?;
    remember(&path, updated.as_bytes());
    Ok(format!(
        "Replaced {} occurrence(s) in {}{}:\n{}",
        found.ranges.len(),
        path.display(),
        found.how.map(|h| format!(" (matched {h})")).unwrap_or_default(),
        snippet(&updated, first_new, first_new + found.new.len())
    ))
}

pub fn register(tools: &ToolRegistry) {
    tools.register(
        ToolDefinition::new(
            "read_file",
            "Read a text file, returning numbered lines. Use offset/limit to page through large files.",
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path, absolute or relative to the working directory" },
                    "offset": { "type": "integer", "description": "1-based first line to return (default 1)" },
                    "limit": { "type": "integer", "description": "Maximum number of lines (default 2000)" }
                },
                "required": ["path"]
            }),
        ),
        Box::new(|args| read_file(&args).map(Value::String)),
    );
    tools.register(
        ToolDefinition::new(
            "write_file",
            "Create a file, or overwrite one you have read, creating parent directories. Prefer edit_file for changes to existing files.",
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "content": { "type": "string" }
                },
                "required": ["path", "content"]
            }),
        ),
        Box::new(|args| write_file(&args).map(Value::String)),
    );
    tools.register(
        ToolDefinition::new(
            "edit_file",
            "Replace text in a file you have read (read it again if it changed since). old_string must match exactly once unless replace_all is true; if there is no exact match, a unique match ignoring trailing whitespace or indentation is used. Returns the edited lines with context.",
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "old_string": { "type": "string", "description": "Exact text to replace, including whitespace" },
                    "new_string": { "type": "string" },
                    "replace_all": { "type": "boolean", "description": "Replace every occurrence (default false)" }
                },
                "required": ["path", "old_string", "new_string"]
            }),
        ),
        Box::new(|args| edit_file(&args).map(Value::String)),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_pages_with_line_numbers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.txt");
        std::fs::write(&path, "one\ntwo\nthree\n").unwrap();
        let p = path.to_str().unwrap();
        let all = read_file(&json!({ "path": p })).unwrap();
        assert!(all.contains("     1\tone\n") && all.contains("     3\tthree\n"));
        let page = read_file(&json!({ "path": p, "offset": 2, "limit": 1 })).unwrap();
        assert!(page.starts_with("     2\ttwo\n"));
        assert!(page.contains("use offset=3"));
        assert!(read_file(&json!({ "path": p, "offset": 9 })).is_err());
    }

    #[test]
    fn read_rejects_binary() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("b.bin");
        std::fs::write(&path, [0u8, 1, 2]).unwrap();
        assert!(read_file(&json!({ "path": path })).is_err());
    }

    #[test]
    fn write_creates_parents_and_edit_requires_unique_match() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/dir/c.txt");
        let p = path.to_str().unwrap();
        assert!(write_file(&json!({ "path": p, "content": "a b a\n" })).unwrap().starts_with("Created"));
        let err = edit_file(&json!({ "path": p, "old_string": "a", "new_string": "x" })).unwrap_err();
        assert!(err.to_string().contains("occurs 2 times"));
        edit_file(&json!({ "path": p, "old_string": "a b", "new_string": "z b" })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "z b a\n");
        edit_file(&json!({ "path": p, "old_string": "a", "new_string": "q", "replace_all": true })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "z b q\n");
        assert!(edit_file(&json!({ "path": p, "old_string": "nope", "new_string": "x" })).is_err());
        assert!(write_file(&json!({ "path": p, "content": "new" })).unwrap().starts_with("Overwrote"));
    }

    #[test]
    fn edit_matches_crlf_files_as_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("w.txt");
        std::fs::write(&path, "a\r\nb\r\nc\r\n").unwrap();
        let p = path.to_str().unwrap();
        read_file(&json!({ "path": p })).unwrap();
        edit_file(&json!({ "path": p, "old_string": "a\nb", "new_string": "x\ny" })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "x\r\ny\r\nc\r\n");
    }

    #[cfg(unix)]
    #[test]
    fn writes_through_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("AGENTS.md");
        let link = dir.path().join("CLAUDE.md");
        std::fs::write(&target, "old\n").unwrap();
        std::os::unix::fs::symlink("AGENTS.md", &link).unwrap();
        let l = link.to_str().unwrap();
        read_file(&json!({ "path": l })).unwrap();
        edit_file(&json!({ "path": l, "old_string": "old", "new_string": "new" })).unwrap();
        write_file(&json!({ "path": l, "content": "newer\n" })).unwrap();
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "newer\n");
    }

    /// A file with `content`, already read (so edits are allowed).
    fn read_fixture(dir: &tempfile::TempDir, name: &str, content: &str) -> String {
        let path = dir.path().join(name);
        std::fs::write(&path, content).unwrap();
        let p = path.to_str().unwrap().to_string();
        read_file(&json!({ "path": p })).unwrap();
        p
    }

    #[test]
    fn edits_and_overwrites_require_a_current_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.txt");
        std::fs::write(&path, "one\n").unwrap();
        let p = path.to_str().unwrap();
        let edit = json!({ "path": p, "old_string": "one", "new_string": "two" });
        let err = edit_file(&edit).unwrap_err().to_string();
        assert!(err.contains("has not been read"), "{err}");
        let err = write_file(&json!({ "path": p, "content": "x" })).unwrap_err().to_string();
        assert!(err.contains("has not been read"), "{err}");
        read_file(&json!({ "path": p })).unwrap();
        // Changed on disk after the read (a command, the user): refused.
        std::fs::write(&path, "one\nmore\n").unwrap();
        let err = edit_file(&edit).unwrap_err().to_string();
        assert!(err.contains("changed since it was last read"), "{err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "one\nmore\n");
        // Re-read, then edit; our own write keeps the file current for the next edit.
        read_file(&json!({ "path": p })).unwrap();
        edit_file(&edit).unwrap();
        edit_file(&json!({ "path": p, "old_string": "more", "new_string": "less" })).unwrap();
        write_file(&json!({ "path": p, "content": "replaced\n" })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "replaced\n");
    }

    #[test]
    fn relaxed_matches_ignore_whitespace_and_line_numbers() {
        let dir = tempfile::tempdir().unwrap();
        let p = read_fixture(&dir, "r.py", "def f():\n    x = 1  \n    return x\n");
        // Trailing whitespace differs.
        let out = edit_file(&json!({ "path": p, "old_string": "    x = 1\n", "new_string": "    x = 2\n" })).unwrap();
        assert!(out.contains("ignoring trailing whitespace"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "def f():\n    x = 2\n    return x\n");
        // Indentation differs: the replacement is re-indented to the file's.
        let out = edit_file(&json!({
            "path": p, "old_string": "x = 2\nreturn x", "new_string": "x = 3\nif x:\n    return x"
        }))
        .unwrap();
        assert!(out.contains("ignoring indentation"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "def f():\n    x = 3\n    if x:\n        return x\n");
        // read_file's line-number prefixes copied into old_string.
        let out = edit_file(&json!({ "path": p, "old_string": "     2\t    x = 3", "new_string": "    x = 4" })).unwrap();
        assert!(out.contains("line numbers"), "{out}");
        assert!(std::fs::read_to_string(&p).unwrap().contains("    x = 4\n"));
    }

    #[test]
    fn relaxed_matches_must_be_unique() {
        let dir = tempfile::tempdir().unwrap();
        let p = read_fixture(&dir, "u.rs", "fn a() {\n    ok()\n}\nfn b() {\n  ok()\n}\n");
        let err = edit_file(&json!({ "path": p, "old_string": "ok()", "new_string": "no()" })).unwrap_err().to_string();
        assert!(err.contains("occurs 2 times"), "{err}");
        let err = edit_file(&json!({ "path": p, "old_string": "\tok()\n", "new_string": "\tno()\n" }))
            .unwrap_err()
            .to_string();
        assert!(err.contains("matches 2 places (ignoring indentation)"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "fn a() {\n    ok()\n}\nfn b() {\n  ok()\n}\n");
    }

    #[test]
    fn a_miss_shows_the_closest_lines() {
        let dir = tempfile::tempdir().unwrap();
        let p = read_fixture(&dir, "m.rs", "fn main() {\n    let x = 1;\n    println!(\"{x}\");\n}\n");
        let err = edit_file(&json!({
            "path": p, "old_string": "let x = 1;\nprintln!(\"{y}\");", "new_string": "z"
        }))
        .unwrap_err()
        .to_string();
        assert!(err.contains("not found"), "{err}");
        assert!(err.contains("Closest match (1 of 2 lines agree), lines 2-3"), "{err}");
        assert!(err.contains("     3\t    println!(\"{x}\");"), "{err}");
    }

    #[test]
    fn edit_result_shows_the_changed_lines_in_context() {
        let dir = tempfile::tempdir().unwrap();
        let body: String = (1..=20).map(|n| format!("line {n}\n")).collect();
        let p = read_fixture(&dir, "c.txt", &body);
        let out = edit_file(&json!({ "path": p, "old_string": "line 10\n", "new_string": "ten\nTEN\n" })).unwrap();
        assert!(out.starts_with("Replaced 1 occurrence(s) in "), "{out}");
        assert!(out.contains("     7\tline 7\n") && out.contains("    10\tten\n    11\tTEN\n"), "{out}");
        assert!(out.contains("    14\tline 13\n") && !out.contains("line 14") && !out.contains("line 6\n"), "{out}");
    }
}
