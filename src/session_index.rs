//! Summaries of saved sessions for `--resume`: where each ran, how much was
//! said, and the last prompt, so sessions can be told apart.
//!
//! Summaries are cached in `index.jsonl` in the session directory, one JSON
//! object per line; the latest line for an ID wins. Writers only append (one
//! `write` per line), so several running nano-coders can share the file
//! without locking. A summary records the size of the log it was made from:
//! when the log has grown since (a session from an older version, or another
//! process that didn't update the index), it is rebuilt from the log.

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::{DateTime, FixedOffset, Local};
use serde::{Deserialize, Serialize};

use crate::session::Record;

const INDEX_FILE: &str = "index.jsonl";

/// What the session picker shows for one saved session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Summary {
    pub id: String,
    /// Working directory the session started in (unknown for older logs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// `provider/model` last used (unknown for older logs).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<DateTime<FixedOffset>>,
    /// When the log was last written.
    pub last_used: DateTime<FixedOffset>,
    /// Prompts typed (input records).
    pub prompts: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub first_prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_prompt: Option<String>,
    /// When the last prompt says little on its own ("do it"), the most recent
    /// one before it that says more.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_prompt: Option<String>,
    /// Size of the log this summary was made from.
    pub log_bytes: u64,
}

/// Whether a prompt says too little to identify a session by itself.
pub fn is_terse(text: &str) -> bool {
    let text = text.trim();
    text.starts_with('/') || (text.chars().count() < 24 && text.split_whitespace().count() <= 4)
}

/// Summarize the session log at `path`. Only the header and input records are
/// decoded; other lines (often large tool output) are skipped unparsed.
pub fn summarize(path: &Path) -> Result<Summary> {
    let bytes = fs::read(path).with_context(|| format!("read session log {}", path.display()))?;
    let metadata = fs::metadata(path)?;
    let last_used = DateTime::<Local>::from(metadata.modified()?).fixed_offset();
    let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_string();
    let mut summary = Summary {
        id,
        cwd: None,
        model: None,
        created_at: None,
        last_used,
        prompts: 0,
        first_prompt: None,
        last_prompt: None,
        context_prompt: None,
        log_bytes: bytes.len() as u64,
    };
    // Only newline-terminated records are committed (see `session`).
    let committed = bytes.iter().rposition(|&b| b == b'\n').map(|i| i + 1).unwrap_or(0);
    for line in bytes[..committed].split(|&b| b == b'\n') {
        let header = line.starts_with(br#"{"type":"session""#);
        if !header && !line.starts_with(br#"{"type":"input""#) {
            continue;
        }
        match serde_json::from_slice::<Record>(line) {
            Ok(Record::Session { id, created_at, cwd, model, .. }) => {
                summary.id = id;
                summary.created_at = Some(created_at);
                summary.cwd = cwd;
                summary.model = model;
            }
            Ok(Record::Input { text, .. }) => {
                summary.prompts += 1;
                if summary.first_prompt.is_none() {
                    summary.first_prompt = Some(text.clone());
                }
                if let Some(previous) = summary.last_prompt.take()
                    && !is_terse(&previous)
                {
                    summary.context_prompt = Some(previous);
                }
                summary.last_prompt = Some(text);
            }
            _ => {}
        }
    }
    // Context is only worth showing when the last prompt needs it.
    if summary.last_prompt.as_deref().is_none_or(|last| !is_terse(last)) {
        summary.context_prompt = None;
    }
    Ok(summary)
}

fn index_path(dir: &Path) -> PathBuf {
    dir.join(INDEX_FILE)
}

/// The index's summaries by ID (latest line wins) and its line count.
/// Unreadable lines are skipped: the index is only a cache.
fn load(dir: &Path) -> (HashMap<String, Summary>, usize) {
    let Ok(text) = fs::read_to_string(index_path(dir)) else { return Default::default() };
    let mut map = HashMap::new();
    let mut lines = 0;
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        lines += 1;
        if let Ok(summary) = serde_json::from_str::<Summary>(line) {
            map.insert(summary.id.clone(), summary);
        }
    }
    (map, lines)
}

/// Append summaries, one `write` per line so concurrent writers don't
/// interleave within a line.
fn append(dir: &Path, summaries: &[Summary]) -> Result<()> {
    if summaries.is_empty() {
        return Ok(());
    }
    let mut file = OpenOptions::new().create(true).append(true).open(index_path(dir))?;
    for summary in summaries {
        let mut line = serde_json::to_vec(summary)?;
        line.push(b'\n');
        file.write_all(&line)?;
    }
    Ok(())
}

/// Rewrite the index with one line per session (atomically, via rename).
/// Lines another process appends between the read and the rename are lost,
/// which only costs a rebuild from the log later.
fn rewrite(dir: &Path, summaries: &HashMap<String, Summary>) -> Result<()> {
    let mut text = String::new();
    let mut sorted: Vec<&Summary> = summaries.values().collect();
    sorted.sort_by(|a, b| a.id.cmp(&b.id));
    for summary in sorted {
        text.push_str(&serde_json::to_string(summary)?);
        text.push('\n');
    }
    let tmp = dir.join(format!("{INDEX_FILE}.tmp-{}", std::process::id()));
    fs::write(&tmp, text)?;
    fs::rename(&tmp, index_path(dir))?;
    Ok(())
}

/// Record the session log at `path` in the index, after a turn. `model` is
/// the `provider/model` in use now, which may differ from the one the
/// session started with.
pub fn update(path: &Path, model: Option<String>) -> Result<()> {
    let dir = path.parent().context("session log has no directory")?;
    let mut summary = summarize(path)?;
    if model.is_some() {
        summary.model = model;
    }
    append(dir, &[summary])
}

/// Every saved session with at least one prompt, most recently used first.
/// Sessions the index lacks, or whose log changed since it was indexed, are
/// summarized from their logs, and the index is updated.
pub fn list(dir: &Path) -> Result<Vec<Summary>> {
    let (mut index, lines) = load(dir);
    let Ok(entries) = fs::read_dir(dir) else { return Ok(Vec::new()) };
    let mut current: HashMap<String, Summary> = HashMap::new();
    let mut updates = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") || path.file_name() == Some(INDEX_FILE.as_ref()) {
            continue;
        }
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_string) else { continue };
        let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
        let summary = match index.remove(&id) {
            Some(summary) if summary.log_bytes == size => summary,
            stale => match summarize(&path) {
                Ok(mut fresh) => {
                    // Keep a model the index learned after the session started.
                    if let Some(old) = stale {
                        fresh.model = old.model.or(fresh.model);
                    }
                    updates.push(fresh.clone());
                    fresh
                }
                Err(_) => continue,
            },
        };
        current.insert(id, summary);
    }
    // Rewrite when the file has grown well past one line per session (or
    // lists logs that are gone); otherwise just append what changed.
    if lines + updates.len() > current.len() * 2 + 64 || !index.is_empty() {
        let _ = rewrite(dir, &current);
    } else {
        let _ = append(dir, &updates);
    }
    let mut sessions: Vec<Summary> = current.into_values().filter(|s| s.prompts > 0).collect();
    sessions.sort_by_key(|s| std::cmp::Reverse(s.last_used));
    Ok(sessions)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{SessionLog, now};

    fn input(log: &mut SessionLog, id: &str, text: &str) {
        log.append(&Record::Input { id: id.into(), text: text.into(), recorded_at: now() }).unwrap();
    }

    #[test]
    fn terse_prompts() {
        assert!(is_terse("Do it"));
        assert!(is_terse("  yes please  "));
        assert!(is_terse("/model openai/gpt-5"));
        assert!(!is_terse("Fix the flaky deploy test in CI"));
        assert!(!is_terse("Refactor the session index"));
    }

    #[test]
    fn summarizes_prompts_and_header() {
        let dir = tempfile::tempdir().unwrap();
        let mut log =
            SessionLog::create_with(dir.path(), "s1", Some("/work/repo".into()), Some("openai/gpt-5".into())).unwrap();
        input(&mut log, "i1", "Investigate the flaky deploy test");
        input(&mut log, "i2", "Fix the retry logic in the deployer");
        input(&mut log, "i3", "do it");
        // A torn final line is ignored, like on resume.
        let path = log.path().to_path_buf();
        drop(log);
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(br#"{"type":"input","data":{"id":"i4","te"#).unwrap();

        let summary = summarize(&path).unwrap();
        assert_eq!(summary.id, "s1");
        assert_eq!(summary.cwd.as_deref(), Some("/work/repo"));
        assert_eq!(summary.model.as_deref(), Some("openai/gpt-5"));
        assert_eq!(summary.prompts, 3);
        assert_eq!(summary.first_prompt.as_deref(), Some("Investigate the flaky deploy test"));
        assert_eq!(summary.last_prompt.as_deref(), Some("do it"));
        assert_eq!(summary.context_prompt.as_deref(), Some("Fix the retry logic in the deployer"));
        assert_eq!(summary.log_bytes, fs::metadata(&path).unwrap().len());
    }

    #[test]
    fn no_context_when_last_prompt_is_telling() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s").unwrap();
        input(&mut log, "i1", "Investigate the flaky deploy test");
        input(&mut log, "i2", "Now write the release notes for it");
        let summary = summarize(log.path()).unwrap();
        assert_eq!(summary.context_prompt, None);
        assert_eq!(summary.cwd, None, "older logs have no cwd");
    }

    #[test]
    fn list_indexes_skips_empty_and_refreshes_stale() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = SessionLog::create(dir.path(), "a").unwrap();
        input(&mut a, "i1", "First session prompt here");
        SessionLog::create(dir.path(), "empty").unwrap();

        let sessions = list(dir.path()).unwrap();
        assert_eq!(sessions.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["a"]);
        let (index, _) = load(dir.path());
        assert_eq!(index.len(), 2, "empty sessions are indexed too, just not listed");

        // The log grows without an index update (an older version): rebuilt.
        input(&mut a, "i2", "Second prompt for the session");
        let sessions = list(dir.path()).unwrap();
        assert_eq!(sessions[0].prompts, 2);
        assert_eq!(sessions[0].last_prompt.as_deref(), Some("Second prompt for the session"));
    }

    #[test]
    fn update_records_current_model_and_list_keeps_it() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create_with(dir.path(), "m", None, Some("openai/gpt-5".into())).unwrap();
        input(&mut log, "i1", "Switch models halfway through");
        update(log.path(), Some("anthropic/claude".into())).unwrap();
        assert_eq!(list(dir.path()).unwrap()[0].model.as_deref(), Some("anthropic/claude"));
        // Even when the log has changed since, the later model survives.
        input(&mut log, "i2", "Another prompt after switching");
        assert_eq!(list(dir.path()).unwrap()[0].model.as_deref(), Some("anthropic/claude"));
    }

    #[test]
    fn index_is_compacted_and_forgets_deleted_logs() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "k").unwrap();
        input(&mut log, "i1", "Keep this session around");
        for _ in 0..100 {
            update(log.path(), None).unwrap();
        }
        let gone = SessionLog::create(dir.path(), "gone").unwrap();
        list(dir.path()).unwrap();
        fs::remove_file(gone.path()).unwrap();
        list(dir.path()).unwrap();
        let (index, lines) = load(dir.path());
        assert_eq!((index.len(), lines), (1, 1));
        // Garbage in the index is skipped, not fatal.
        fs::write(index_path(dir.path()), "not json\n").unwrap();
        assert_eq!(list(dir.path()).unwrap().len(), 1);
    }
}
