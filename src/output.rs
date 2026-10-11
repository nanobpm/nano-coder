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

/// A spill's out-of-band identity, handed from the bounder to the loop
/// detector so the detector never re-parses the rendered — model-influenceable
/// — marker to tell two results apart (issue #65).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Spill {
    /// Hex SHA-256 (16 chars) of the complete spilled content.
    pub digest: String,
    /// The exact path string the rendered marker carries (`<dir>/<name>`), so
    /// the detector can normalise *this* marker only and leave any other
    /// marker-looking text (a digest-free look-alike in stderr or hook context)
    /// untouched.
    pub path: String,
}

/// Bound `text` to `limit` characters; when it is longer, save it whole in
/// `dir` and point at that file from the truncation marker, so the model can
/// search or page through the rest. The spill never overwrites an existing
/// file: for a persisted session the recorded paths must stay valid, so if
/// `name` is taken (a reused tool-call ID after a resume or provider retry) a
/// fresh `stem-2.ext`, `stem-3.ext`, … is reserved instead. Also returns the
/// spilled capture's [`Spill`] identity (digest + exact marker path) when the
/// text was truncated and spilled, so the caller can hand it to the loop
/// detector **out of band** instead of the detector re-parsing the rendered
/// marker (issue #65). The spill is `None` when nothing spilled.
pub fn bound_and_spill_digest(
    text: &str,
    limit: usize,
    dir: &std::path::Path,
    name: &str,
) -> (String, Option<Spill>) {
    if text.chars().count() <= limit {
        return (text.to_string(), None);
    }
    let saved = std::fs::create_dir_all(dir).ok().and_then(|()| reserve_and_write(dir, name, text));
    let display = saved.as_ref().map(|p| p.display().to_string());
    let digest = content_digest(text);
    let (bounded, _) = bound_parts(text, Some(text), text.len() as u64, limit, display.as_deref(), Some(&digest));
    let spill = display.map(|path| Spill { digest, path });
    (bounded, spill)
}

/// Write `text` to a new file in `dir` derived from `name`, never clobbering an
/// existing spill. Probes `name`, then `stem-2.ext`, `stem-3.ext`, … with
/// `create_new` until one is created, so paths already recorded in a session
/// log keep pointing at their original contents. Returns the path written, or
/// `None` on error.
fn reserve_and_write(dir: &std::path::Path, name: &str, text: &str) -> Option<std::path::PathBuf> {
    use std::io::Write;
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) => (stem, format!(".{ext}")),
        None => (name, String::new()),
    };
    for attempt in 1..=10_000u32 {
        let candidate = if attempt == 1 { dir.join(name) } else { dir.join(format!("{stem}-{attempt}{ext}")) };
        match std::fs::File::create_new(&candidate) {
            Ok(mut file) => return file.write_all(text.as_bytes()).ok().map(|()| candidate),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return None,
        }
    }
    None
}

/// Bound a complete in-memory string to `limit` characters.
pub fn bound_output(text: &str, limit: usize) -> (String, bool) {
    bound_parts(text, None, text.len() as u64, limit, None, Some(&content_digest(text)))
}

/// Bound output given its `head` and, when the full text was not read, its
/// `tail`. `full_size` is the complete size in bytes; `path` is where the
/// complete output lives, if anywhere. `digest` is a hex SHA-256 distinguishing
/// the output's content, when the caller has it (an in-memory string is hashed
/// whole; a large capture file is hashed incrementally as the command writes it,
/// so the digest still covers the complete content without an unbounded
/// post-exit reread). It is embedded in the marker so the loop detector's
/// fingerprint can tell two bounded previews apart when their head, tail and
/// byte count match but their content differs (issue #65).
pub fn bound_parts(
    head: &str,
    tail: Option<&str>,
    full_size: u64,
    limit: usize,
    path: Option<&str>,
    digest: Option<&str>,
) -> (String, bool) {
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
    if let Some(digest) = digest {
        marker.push_str(" (sha256:");
        marker.push_str(digest);
        marker.push(')');
    }
    if let Some(path) = path {
        marker.push_str("; complete output in ");
        marker.push_str(path);
    }
    (format!("{head_part}{marker}...{tail_part}"), true)
}

/// Hex SHA-256 of a complete in-memory output, truncated to 16 hex chars (64
/// bits) — enough to tell two bounded previews apart for the loop detector
/// without bloating the marker. For the bounder's marker.
pub fn content_digest(text: &str) -> String {
    use sha2::Digest;
    short_digest(sha2::Sha256::digest(text.as_bytes()))
}

/// The first 16 hex chars (64 bits) of a SHA-256 digest.
pub(crate) fn short_digest(digest: impl AsRef<[u8]>) -> String {
    digest.as_ref().iter().take(8).map(|b| format!("{b:02x}")).collect()
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
    let limit = value.as_i64().ok_or_else(|| "max_output_length must be a positive integer".to_string())?;
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
        assert_eq!(bounded, format!("ab...6 bytes truncated (sha256:{})...ij", content_digest("abcdefghij")));
    }

    #[test]
    fn is_utf8_safe_and_mentions_path() {
        let text = "é".repeat(10);
        let (bounded, truncated) = bound_parts(&text, Some(&text), 1000, 3, Some("/tmp/out"), Some(&content_digest(&text)));
        assert!(truncated);
        assert_eq!(
            bounded,
            format!("é...994 bytes truncated (sha256:{}); complete output in /tmp/out...éé", content_digest(&text))
        );
    }

    #[test]
    fn spills_long_output_to_a_file() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(bound_and_spill_digest("short", 10, dir.path(), "a.txt"), ("short".to_string(), None));
        assert!(!dir.path().join("a.txt").exists());
        let (bounded, spilled) = bound_and_spill_digest("abcdefghij", 4, dir.path(), "b.txt");
        let path = dir.path().join("b.txt");
        let digest = content_digest("abcdefghij");
        assert_eq!(
            bounded,
            format!("ab...6 bytes truncated (sha256:{digest}); complete output in {}...ij", path.display())
        );
        // The spill's identity (digest + exact marker path) is handed back out
        // of band for the loop detector.
        assert_eq!(spilled, Some(Spill { digest, path: path.display().to_string() }));
        assert_eq!(std::fs::read_to_string(path).unwrap(), "abcdefghij");
    }

    #[test]
    fn spill_never_overwrites_an_existing_file() {
        let dir = tempfile::tempdir().unwrap();
        // First long result claims the base name.
        let (first, _) = bound_and_spill_digest("abcdefghij", 4, dir.path(), "tool-x.txt");
        assert!(first.contains("tool-x.txt"));
        assert_eq!(std::fs::read_to_string(dir.path().join("tool-x.txt")).unwrap(), "abcdefghij");
        // A second result reusing the same name (e.g. a retried tool-call ID)
        // must not clobber the first: it reserves a fresh suffixed name.
        let (second, _) = bound_and_spill_digest("klmnopqrst", 4, dir.path(), "tool-x.txt");
        assert!(second.contains("tool-x-2.txt"));
        assert_eq!(std::fs::read_to_string(dir.path().join("tool-x.txt")).unwrap(), "abcdefghij");
        assert_eq!(std::fs::read_to_string(dir.path().join("tool-x-2.txt")).unwrap(), "klmnopqrst");
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
