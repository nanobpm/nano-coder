//! Model-facing output bounding.
//!
//! Ported from unreal-agent's `harness/operation/output.go`
//! (MIT, Copyright (c) 2026 Unreal Labs): keep the head and tail of long
//! output, mark how much was dropped, and point at the full capture.

/// Default model-facing output cap, in characters.
pub const DEFAULT_MAX_OUTPUT_LENGTH: usize = 40_000;
/// Largest `max_output_length` a model may request.
pub const MAX_OUTPUT_LENGTH: usize = 1_000_000;

/// Where complete copies of truncated tool output are kept.
pub fn spill_dir() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("nano-coder-{}", std::process::id()))
}

/// Bound `text` to `limit` characters; when it is longer, save it whole in
/// `dir` as `name` and point at that file from the truncation marker, so
/// the model can search or page through the rest.
pub fn bound_and_spill(text: &str, limit: usize, dir: &std::path::Path, name: &str) -> String {
    if text.chars().count() <= limit {
        return text.to_string();
    }
    let path = dir.join(name);
    let saved = std::fs::create_dir_all(dir).and_then(|()| std::fs::write(&path, text)).is_ok();
    let display = path.display().to_string();
    bound_parts(text, Some(text), text.len() as u64, limit, saved.then_some(display.as_str())).0
}

/// Bound a complete in-memory string to `limit` characters.
pub fn bound_output(text: &str, limit: usize) -> (String, bool) {
    bound_parts(text, None, text.len() as u64, limit, None)
}

/// Bound output given its `head` and, when the full text was not read, its
/// `tail`. `full_size` is the complete size in bytes; `path` is where the
/// complete output lives, if anywhere.
pub fn bound_parts(head: &str, tail: Option<&str>, full_size: u64, limit: usize, path: Option<&str>) -> (String, bool) {
    let tail = match tail {
        Some(tail) => tail,
        None => {
            if head.chars().count() <= limit {
                return (head.to_string(), false);
            }
            head
        }
    };
    let head_part = take_head(head, limit / 2);
    let tail_part = take_tail(tail, limit - limit / 2);
    let skipped = full_size.saturating_sub((head_part.len() + tail_part.len()) as u64);
    let mut marker = format!("...{skipped} bytes truncated");
    if let Some(path) = path {
        marker.push_str("; complete output in ");
        marker.push_str(path);
    }
    (format!("{head_part}{marker}...{tail_part}"), true)
}

fn take_head(text: &str, chars: usize) -> &str {
    match text.char_indices().nth(chars) {
        Some((end, _)) => &text[..end],
        None => text,
    }
}

fn take_tail(text: &str, chars: usize) -> &str {
    if chars == 0 {
        return "";
    }
    match text.char_indices().rev().nth(chars - 1) {
        Some((start, _)) => &text[start..],
        None => text,
    }
}

/// Parse an optional model-supplied `max_output_length`.
pub fn parse_max_output_length(value: Option<&serde_json::Value>) -> Result<usize, String> {
    let Some(value) = value.filter(|v| !v.is_null()) else {
        return Ok(DEFAULT_MAX_OUTPUT_LENGTH);
    };
    let limit = value
        .as_i64()
        .ok_or_else(|| "max_output_length must be a positive integer".to_string())?;
    if limit <= 0 {
        return Err("max_output_length must be a positive integer".into());
    }
    if limit as usize > MAX_OUTPUT_LENGTH {
        return Err(format!("max_output_length must not exceed {MAX_OUTPUT_LENGTH}"));
    }
    Ok(limit as usize)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn leaves_short_output_alone() {
        assert_eq!(bound_output("hello", 5), ("hello".to_string(), false));
    }

    #[test]
    fn keeps_head_and_tail() {
        let (bounded, truncated) = bound_output("abcdefghij", 4);
        assert!(truncated);
        assert_eq!(bounded, "ab...6 bytes truncated...ij");
    }

    #[test]
    fn is_utf8_safe_and_mentions_path() {
        let text = "é".repeat(10);
        let (bounded, truncated) = bound_parts(&text, Some(&text), 1000, 3, Some("/tmp/out"));
        assert!(truncated);
        assert_eq!(bounded, "é...994 bytes truncated; complete output in /tmp/out...éé");
    }

    #[test]
    fn spills_long_output_to_a_file() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(bound_and_spill("short", 10, dir.path(), "a.txt"), "short");
        assert!(!dir.path().join("a.txt").exists());
        let bounded = bound_and_spill("abcdefghij", 4, dir.path(), "b.txt");
        let path = dir.path().join("b.txt");
        assert_eq!(bounded, format!("ab...6 bytes truncated; complete output in {}...ij", path.display()));
        assert_eq!(std::fs::read_to_string(path).unwrap(), "abcdefghij");
    }

    #[test]
    fn validates_limits() {
        assert_eq!(parse_max_output_length(None), Ok(DEFAULT_MAX_OUTPUT_LENGTH));
        assert_eq!(parse_max_output_length(Some(&json!(10))), Ok(10));
        assert!(parse_max_output_length(Some(&json!(0))).is_err());
        assert!(parse_max_output_length(Some(&json!("5"))).is_err());
        assert!(parse_max_output_length(Some(&json!(MAX_OUTPUT_LENGTH + 1))).is_err());
    }
}
