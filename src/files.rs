//! File tools: `read_file`, `write_file`, `edit_file`.
//!
//! Relative paths resolve against the process working directory, which ACP
//! `session/new` sets from `params.cwd`.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};

use crate::output;
use crate::tools::{ToolDefinition, ToolRegistry};

const DEFAULT_READ_LINES: usize = 2000;
const MAX_LINE_CHARS: usize = 2000;
const MAX_READ_BYTES: usize = 100_000;

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

pub fn write_file(args: &Value) -> Result<String> {
    let path = path_arg(args)?;
    let content = string_arg(args, "content")?;
    let existed = path.exists();
    write_atomically(&path, content)?;
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
    let text = std::fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    // read_file shows lines without `\r`; match CRLF files the way the model saw them.
    let (old, new) = if text.contains("\r\n") && !old.contains('\r') && !text.contains(old) {
        (old.replace('\n', "\r\n"), new.replace("\r\n", "\n").replace('\n', "\r\n"))
    } else {
        (old.to_string(), new.to_string())
    };
    let (old, new) = (old.as_str(), new.as_str());
    let count = text.matches(old).count();
    match count {
        0 => bail!("old_string not found in {}; read the file and copy the text exactly", path.display()),
        n if n > 1 && !replace_all => bail!(
            "old_string occurs {n} times in {}; add surrounding context to make it unique or set replace_all",
            path.display()
        ),
        _ => {}
    }
    let updated = if replace_all { text.replace(old, new) } else { text.replacen(old, new, 1) };
    write_atomically(&path, &updated)?;
    Ok(format!("Replaced {} occurrence(s) in {}", if replace_all { count } else { 1 }, path.display()))
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
            "Create or overwrite a file with the given content, creating parent directories.",
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
            "Replace exact text in a file. old_string must match exactly once unless replace_all is true.",
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
        edit_file(&json!({ "path": l, "old_string": "old", "new_string": "new" })).unwrap();
        write_file(&json!({ "path": l, "content": "newer\n" })).unwrap();
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "newer\n");
    }
}
