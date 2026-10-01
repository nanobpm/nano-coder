//! Summaries of saved sessions for `--resume`: where each ran, how much was
//! said, and the last prompt, so sessions can be told apart.
//!
//! Summaries are cached in `.index.jsonl` in the session directory, one JSON
//! object per line; the latest line for an ID wins. Writers only append (one
//! `write` per line), so several running nano-coders can share the file
//! without locking. A summary records the size of the log it was made from:
//! when the log has grown since (a session from an older version, or another
//! process that didn't update the index), it is rebuilt from the log.
//!
//! The cache is named `.index.jsonl` (not `index.jsonl`) so its file stem
//! `.index` is rejected by [`crate::session::validate_id`] (ids may not start
//! with `.`): the cache can therefore never collide with — or hide — a real
//! session log, which `index.jsonl` could (a session whose id is `index`).

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use chrono::{DateTime, FixedOffset, Local};
use serde::{Deserialize, Serialize};

use crate::session::Record;

// The cache file's stem (`.index`) is rejected by `validate_id`, so it can
// never collide with a valid session log name. A leading dot also keeps it
// out of the way of `list()`'s per-entry scan (a `.`-prefixed stem fails
// `validate_id`, so it is skipped like any other non-session file).
const INDEX_FILE: &str = ".index.jsonl";

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

/// Fold one input record into `summary` (bump the count, track first/last and
/// context prompts). Shared by [`summarize`], which scans a whole log, and
/// [`update`], which folds just the turn's own input.
fn fold_input(summary: &mut Summary, text: &str) {
    summary.prompts += 1;
    if summary.first_prompt.is_none() {
        summary.first_prompt = Some(text.to_string());
    }
    if let Some(previous) = summary.last_prompt.replace(text.to_string())
        && !is_terse(&previous)
    {
        summary.context_prompt = Some(previous);
    }
    // Context is only worth showing when the last prompt needs it.
    if summary.last_prompt.as_deref().is_none_or(|last| !is_terse(last)) {
        summary.context_prompt = None;
    }
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
    // The id comes from the file name, which `SessionLog::open` validates
    // before resuming; a log whose name is not a valid id (`.hidden`, over
    // 128 bytes, outside [A-Za-z0-9._-]) would always fail to open, so it
    // must not be advertised in the picker as a resumable session.
    crate::session::validate_id(&summary.id)
        .with_context(|| format!("session log {} has an invalid id", path.display()))?;
    // Only newline-terminated records are committed (see `session`).
    let committed = bytes.iter().rposition(|&b| b == b'\n').map(|i| i + 1).unwrap_or(0);
    let mut records = bytes[..committed].split(|&b| b == b'\n').filter(|line| !line.is_empty());
    // The first committed record must be a session header this build can open:
    // the same format version and an id matching the file name. An input-only,
    // renamed, or future-version log would be rejected by `SessionLog::open`
    // (see `session`), so it must not be advertised in the picker as a
    // resumable session.
    match records.next().map(serde_json::from_slice::<Record>) {
        Some(Ok(Record::Session { version, id, created_at, cwd, model }))
            if version == crate::session::FORMAT_VERSION && id == summary.id =>
        {
            summary.created_at = Some(created_at);
            summary.cwd = cwd;
            summary.model = model;
        }
        _ => anyhow::bail!("session log {} has no resumable header", path.display()),
    }
    for line in records {
        if !line.starts_with(br#"{"type":"input""#) {
            continue;
        }
        if let Ok(Record::Input { text, .. }) = serde_json::from_slice::<Record>(line) {
            fold_input(&mut summary, &text);
        }
    }
    Ok(summary)
}

fn index_path(dir: &Path) -> PathBuf {
    dir.join(INDEX_FILE)
}

/// The index's summaries by ID (latest line wins) and its line count.
/// Unreadable lines are skipped: the index is only a cache. Bytes are read
/// (not `read_to_string`) and split on `b'\n'` so one non-UTF-8 or otherwise
/// corrupt line is isolated rather than discarding the whole index — a
/// discarded index never reaches the rewrite threshold (it reports zero
/// lines), so it could not self-heal and every listing would rescan every log.
fn load(dir: &Path) -> (HashMap<String, Summary>, usize) {
    let Ok(bytes) = fs::read(index_path(dir)) else { return Default::default() };
    let mut map = HashMap::new();
    let mut lines = 0;
    for line in bytes.split(|&b| b == b'\n') {
        let line = trim_ascii(line);
        if line.is_empty() {
            continue;
        }
        lines += 1;
        if let Ok(summary) = serde_json::from_slice::<Summary>(line) {
            map.insert(summary.id.clone(), summary);
        }
    }
    (map, lines)
}

/// `line` without leading/trailing ASCII whitespace (the byte-level
/// counterpart of `str::trim` for the index's per-line reads).
fn trim_ascii(line: &[u8]) -> &[u8] {
    let start = line.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(line.len());
    let end = line.iter().rposition(|b| !b.is_ascii_whitespace()).map_or(start, |i| i + 1);
    &line[start..end]
}

/// Append summaries, one `write` per line so concurrent writers don't
/// interleave within a line. A short write is a failed cache update, not
/// something to retry: `write_all` would issue a second `write` for the
/// remainder, and another append-only writer could land between the two
/// fragments and corrupt both records.
fn append(dir: &Path, summaries: &[Summary]) -> Result<()> {
    if summaries.is_empty() {
        return Ok(());
    }
    let mut file = OpenOptions::new().create(true).append(true).open(index_path(dir))?;
    for summary in summaries {
        let mut line = serde_json::to_vec(summary)?;
        line.push(b'\n');
        if file.write(&line)? != line.len() {
            anyhow::bail!("short write to session index");
        }
    }
    Ok(())
}

/// Rewrite the index with one line per session (atomically, via rename).
/// The rewrite merges whatever landed in the file since the read before
/// renaming, so a concurrent append (which can carry a model change that
/// exists only in the index) survives. `since` is sampled before the read, so
/// it never names a byte the read missed; an append landing after the merge
/// read and before the rename is still lost without cross-process locking,
/// which costs only a rebuild from the log — except when that line carried an
/// index-only model change, a known residual risk of the lock-free design.
fn rewrite(dir: &Path, summaries: &HashMap<String, Summary>, since: u64) -> Result<()> {
    let mut merged = summaries.clone();
    if let Ok(mut file) = OpenOptions::new().read(true).open(index_path(dir))
        && let Ok(pos) = file.seek(SeekFrom::Start(since))
    {
        // Read bytes and split on `b'\n'` (as `load()` does) rather than
        // `read_to_string`: one non-UTF-8 or torn line must be isolated, not
        // fail the whole tail read — otherwise every later valid concurrent
        // summary is discarded here and then lost to the rename (an
        // index-only model change included), defeating `load()`'s per-line
        // corruption isolation. `since` is a whole-line boundary, so each
        // complete line is a full record; a torn trailing line fails to
        // deserialize and is skipped.
        let mut rest = Vec::new();
        if pos == since && file.read_to_end(&mut rest).is_ok() {
            for line in rest.split(|&b| b == b'\n') {
                let line = trim_ascii(line);
                if line.is_empty() {
                    continue;
                }
                if let Ok(summary) = serde_json::from_slice::<Summary>(line) {
                    merged.insert(summary.id.clone(), summary);
                }
            }
        }
    }
    let mut text = String::new();
    let mut sorted: Vec<&Summary> = merged.values().collect();
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
///
/// The turn's own input is folded into the cached summary rather than
/// rescanning the whole log: rereading every prior prompt and tool-output
/// record on each completed turn would make index maintenance cumulative
/// quadratic I/O. The cached summary must cover the log up to `from` (the
/// log's size before the turn's input was appended); when it is missing or
/// older — the first turn, an older version that didn't index, a crash —
/// fall back to one full scan. `list()` likewise rebuilds from the log
/// whenever a summary is missing or stale.
pub fn update(path: &Path, from: u64, input: Option<&str>, model: Option<String>) -> Result<()> {
    let dir = path.parent().context("session log has no directory")?;
    let id = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default();
    let metadata = fs::metadata(path)?;
    let last_used = DateTime::<Local>::from(metadata.modified()?).fixed_offset();
    // Sample the index size before reading so a compaction's `since` never
    // names a byte the read did not cover (the same race `list()` guards).
    let index_len = fs::metadata(index_path(dir)).map(|m| m.len()).unwrap_or(0);
    let (mut index, lines) = load(dir);
    let mut summary = match index.remove(id) {
        Some(mut cached) if cached.log_bytes == from => {
            // The cache covers the log up to the turn's first record, so the
            // input is not in it yet: fold just this one instead of
            // rescanning the log.
            if let Some(text) = input {
                fold_input(&mut cached, text);
            }
            cached
        }
        // Missing or stale: rebuild from the log, which already holds the
        // input record, so fold nothing.
        _ => summarize(path)?,
    };
    summary.last_used = last_used;
    summary.log_bytes = metadata.len();
    if model.is_some() {
        summary.model = model;
    }
    // Without a listing, one append per turn grows the index without bound and
    // makes the next turn's `load` reread all of it (1+2+…+N over a session).
    // When the file has grown well past one line per indexed session, compact
    // it instead of appending. `index` is the latest-per-id map `load` just
    // read; it may still hold sessions whose logs were deleted, which a later
    // `list()` drops — keeping them here only delays that cleanup, it never
    // resurrects them into a listing.
    if lines > index.len() * 2 + 64 {
        index.insert(summary.id.clone(), summary);
        rewrite(dir, &index, index_len)
    } else {
        append(dir, &[summary])
    }
}

/// Every saved session with at least one prompt, most recently used first.
/// Sessions the index lacks, or whose log changed since it was indexed, are
/// summarized from their logs, and the index is updated.
pub fn list(dir: &Path) -> Result<Vec<Summary>> {
    // Sample the size before reading so `index_len` never names a byte the
    // read did not cover: sampled after `load`, an append landing between the
    // two would be absent from `index` yet inside `since`, and `rewrite`
    // would seek past it and the rename would discard it.
    let index_len = fs::metadata(index_path(dir)).map(|m| m.len()).unwrap_or(0);
    let (mut index, lines) = load(dir);
    // Only a missing directory means "no sessions". A permission or I/O error
    // must surface, not be misreported as an empty directory ("No saved
    // sessions" / "no match"), which would hide the real failure.
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("read session directory {}", dir.display())),
    };
    let mut current: HashMap<String, Summary> = HashMap::new();
    let mut updates = Vec::new();
    for entry in entries {
        // Propagate per-entry traversal errors with directory context rather
        // than silently flattening them away: `flatten()` would drop an
        // `io::Result<DirEntry>` failure and return an incomplete list as
        // success, contradicting the read_dir error handling above.
        let entry = entry.with_context(|| format!("read entry in session directory {}", dir.display()))?;
        let path = entry.path();
        // Skip the cache. Its stem `.index` is already rejected by the
        // `validate_id` check below, but name it explicitly so the intent is
        // clear and a future rename stays correct. A legacy `index.jsonl`
        // cache (from before the rename) is NOT skipped here: its stem
        // `index` is a valid id, so if it is a real session log it is listed
        // (it was hidden before), and if it is just a stale cache its first
        // line is a `Summary`, not a `Session` header, so `summarize` rejects
        // it and it is skipped as an unresumable log.
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") || path.file_name() == Some(INDEX_FILE.as_ref()) {
            continue;
        }
        let Some(id) = path.file_stem().and_then(|s| s.to_str()).map(str::to_string) else { continue };
        // Validate the file-stem id before trusting a cache hit: a cached
        // summary lets a log whose name `SessionLog::open` would reject
        // (`.hidden`, over 128 bytes, outside [A-Za-z0-9._-]) bypass
        // `summarize`'s check, so it would be advertised yet always fail to
        // resume. Skip it like `summarize` would.
        if crate::session::validate_id(&id).is_err() {
            continue;
        }
        let size = entry
            .metadata()
            .with_context(|| format!("read metadata for session log {}", path.display()))?
            .len();
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
                // A structurally invalid/unresumable log is skipped like
                // `summarize` intends, but a real filesystem failure (an
                // `io::Error` in the chain, from `fs::read`/`metadata`/
                // `modified`) must surface, not be misreported as a missing or
                // corrupt session — same contract as the `read_dir` and
                // per-entry errors above.
                Err(e) if e.chain().any(|c| c.is::<std::io::Error>()) => return Err(e),
                Err(_) => continue,
            },
        };
        current.insert(id, summary);
    }
    // Rewrite when the file has grown well past one line per session (or
    // lists logs that are gone); otherwise just append what changed.
    if lines + updates.len() > current.len() * 2 + 64 || !index.is_empty() {
        let _ = rewrite(dir, &current, index_len);
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
    fn summarize_rejects_logs_open_would_refuse() {
        let dir = tempfile::tempdir().unwrap();
        // A renamed log: the header id no longer matches the file name, so
        // `SessionLog::open` would reject it — it must not be summarized.
        let mut log = SessionLog::create(dir.path(), "original").unwrap();
        input(&mut log, "i1", "A prompt in the renamed log");
        let original = log.path().to_path_buf();
        drop(log);
        let renamed = dir.path().join("renamed.jsonl");
        fs::rename(&original, &renamed).unwrap();
        assert!(summarize(&renamed).is_err(), "renamed log must not summarize");

        // An input-only log (no session header) is unresumable too.
        let headerless = dir.path().join("headerless.jsonl");
        fs::write(&headerless, b"{\"type\":\"input\",\"data\":{\"id\":\"i1\",\"text\":\"hi\"}}\n").unwrap();
        assert!(summarize(&headerless).is_err(), "input-only log must not summarize");

        // A valid log whose header id matches its file name still summarizes.
        let mut good = SessionLog::create(dir.path(), "good").unwrap();
        input(&mut good, "i1", "A valid prompt here");
        let summary = summarize(good.path()).unwrap();
        assert_eq!(summary.id, "good");
        assert_eq!(summary.prompts, 1);
    }

    #[test]
    fn summarize_rejects_ids_open_would_refuse() {
        let dir = tempfile::tempdir().unwrap();
        // `.hidden` and over-128-byte ids are rejected by `SessionLog::open`
        // (`validate_id`), so a log named one must not be summarized — the
        // picker would otherwise advertise a session that always fails to
        // resume. Craft one by writing a valid log under a bad file name.
        let mut log = SessionLog::create(dir.path(), "good").unwrap();
        input(&mut log, "i1", "A prompt in a badly named log");
        let good = log.path().to_path_buf();
        drop(log);
        let hidden = dir.path().join(".hidden.jsonl");
        fs::rename(&good, &hidden).unwrap();
        // The header id ("good") no longer matches the file stem (".hidden"),
        // and ".hidden" is itself an invalid id: rejected either way.
        assert!(summarize(&hidden).is_err(), "a log named with an invalid id must not summarize");
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
    fn cache_filename_cannot_collide_with_a_session_id() {
        // The cache file's stem must be an id `validate_id` rejects, so the
        // cache can never collide with — or hide — a real session log.
        let stem = Path::new(INDEX_FILE).file_stem().and_then(|s| s.to_str()).unwrap();
        assert!(
            crate::session::validate_id(stem).is_err(),
            "cache file stem {stem:?} must not be a valid session id"
        );

        // A session whose id is `index` (the legacy cache name's stem) is a
        // real, resumable session and must be listed, not hidden by the cache.
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "index").unwrap();
        input(&mut log, "i1", "A prompt from the session named index");
        drop(log);
        let sessions = list(dir.path()).unwrap();
        assert_eq!(
            sessions.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            ["index"],
            "a session named `index` must be listed, not hidden by the cache"
        );
        // Listing it wrote the cache under its own non-colliding name, leaving
        // the session's own `index.jsonl` log untouched as a session log.
        assert!(index_path(dir.path()).exists(), "the cache is written to {INDEX_FILE}");
    }

    #[test]
    fn list_skips_invalid_id_even_on_cache_hit() {
        let dir = tempfile::tempdir().unwrap();
        // A log named with an id `SessionLog::open` rejects (`.hidden`), with a
        // cache entry whose `log_bytes` matches, must not be advertised: the
        // cache hit would otherwise bypass `summarize`'s `validate_id` and the
        // picker would offer a session that always fails to resume.
        let hidden = dir.path().join(".hidden.jsonl");
        fs::write(&hidden, b"{\"type\":\"input\",\"data\":{\"id\":\"i1\",\"text\":\"hi\"}}\n").unwrap();
        let size = fs::metadata(&hidden).unwrap().len();
        let cached = Summary {
            id: ".hidden".into(),
            cwd: None,
            model: None,
            created_at: None,
            last_used: crate::session::now(),
            prompts: 1,
            first_prompt: Some("hi".into()),
            last_prompt: Some("hi".into()),
            context_prompt: None,
            log_bytes: size,
        };
        append(dir.path(), &[cached]).unwrap();
        // Despite the matching cache entry, the invalid id is skipped.
        assert!(list(dir.path()).unwrap().is_empty(), "an invalid id must not be listed from cache");
    }

    #[test]
    fn list_propagates_directory_errors_except_not_found() {
        // A missing directory is "no sessions", not an error.
        let missing = tempfile::tempdir().unwrap();
        let absent = missing.path().join("does-not-exist");
        assert!(list(&absent).unwrap().is_empty(), "a missing directory means no sessions");
        // Any other read failure (here: the path is a file, so `read_dir`
        // yields ENOTDIR) must surface, not be misreported as empty.
        let dir = tempfile::tempdir().unwrap();
        let not_a_dir = dir.path().join("a-file");
        fs::write(&not_a_dir, b"x").unwrap();
        assert!(list(&not_a_dir).is_err(), "a non-NotFound read_dir error must propagate");
    }

    #[test]
    fn update_records_current_model_and_list_keeps_it() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create_with(dir.path(), "m", None, Some("openai/gpt-5".into())).unwrap();
        input(&mut log, "i1", "Switch models halfway through");
        update(log.path(), 0, None, Some("anthropic/claude".into())).unwrap();
        assert_eq!(list(dir.path()).unwrap()[0].model.as_deref(), Some("anthropic/claude"));
        // Even when the log has changed since, the later model survives.
        input(&mut log, "i2", "Another prompt after switching");
        assert_eq!(list(dir.path()).unwrap()[0].model.as_deref(), Some("anthropic/claude"));
    }

    #[test]
    fn update_folds_the_turns_input_into_the_cached_summary() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create_with(dir.path(), "s", Some("/work/repo".into()), None).unwrap();
        // First turn: no cached summary, so the log is scanned once (the
        // input record is already in the log, so nothing is folded).
        input(&mut log, "i1", "Investigate the flaky deploy test");
        update(log.path(), 0, None, None).unwrap();
        let scanned = list(dir.path()).unwrap();
        assert_eq!(scanned[0].prompts, 1);
        assert_eq!(scanned[0].first_prompt.as_deref(), Some("Investigate the flaky deploy test"));

        // Later turns fold just their own input into the cached summary.
        let from = log.size();
        input(&mut log, "i2", "Fix the retry logic in the deployer");
        update(log.path(), from, Some("Fix the retry logic in the deployer"), None).unwrap();
        let from = log.size();
        input(&mut log, "i3", "do it");
        update(log.path(), from, Some("do it"), None).unwrap();

        let sessions = list(dir.path()).unwrap();
        assert_eq!(sessions[0].prompts, 3);
        assert_eq!(sessions[0].last_prompt.as_deref(), Some("do it"));
        assert_eq!(sessions[0].context_prompt.as_deref(), Some("Fix the retry logic in the deployer"));
        assert_eq!(sessions[0].log_bytes, log.size());
    }

    #[test]
    fn update_rescans_when_the_cache_is_stale() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s").unwrap();
        input(&mut log, "i1", "First prompt for the session");
        // `from` naming a different log size than the cache cannot match:
        // the summary is rebuilt from the log and the input is not folded
        // (the rescan already saw its record).
        update(log.path(), u64::MAX, Some("First prompt for the session"), None).unwrap();
        let sessions = list(dir.path()).unwrap();
        assert_eq!(sessions[0].prompts, 1);
        assert_eq!(sessions[0].last_prompt.as_deref(), Some("First prompt for the session"));
    }

    #[test]
    fn rewrite_merges_lines_appended_since_the_read() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = SessionLog::create(dir.path(), "a").unwrap();
        input(&mut a, "i1", "Session a's prompt");
        let mut b = SessionLog::create(dir.path(), "b").unwrap();
        input(&mut b, "i1", "Session b's prompt");
        list(dir.path()).unwrap();

        // A rewrite that read the index before another process appended b's
        // newer summary must not lose that line (it can carry a model change
        // that exists only in the index).
        let (current, _) = load(dir.path());
        let since = fs::metadata(index_path(dir.path())).unwrap().len();
        let mut newer = summarize(b.path()).unwrap();
        newer.model = Some("anthropic/claude".into());
        append(dir.path(), &[newer]).unwrap();
        rewrite(dir.path(), &current, since).unwrap();

        let sessions = list(dir.path()).unwrap();
        let b = sessions.iter().find(|s| s.id == "b").unwrap();
        assert_eq!(b.model.as_deref(), Some("anthropic/claude"));
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn rewrite_isolates_a_corrupt_tail_line_instead_of_discarding_later_ones() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = SessionLog::create(dir.path(), "a").unwrap();
        input(&mut a, "i1", "Session a's prompt");
        let mut b = SessionLog::create(dir.path(), "b").unwrap();
        input(&mut b, "i1", "Session b's prompt");
        list(dir.path()).unwrap();

        // A rewrite that read the index before a torn/corrupt line and then a
        // valid concurrent summary landed must still merge the valid one: a
        // non-UTF-8 tail must not make the read discard the lines after it
        // (which can carry an index-only model change), or the rename loses
        // them — the same per-line isolation `load()` guarantees.
        let (current, _) = load(dir.path());
        let since = fs::metadata(index_path(dir.path())).unwrap().len();
        let mut tail = b"\xff\xfe not utf8\n".to_vec();
        let mut newer = summarize(b.path()).unwrap();
        newer.model = Some("anthropic/claude".into());
        let mut line = serde_json::to_vec(&newer).unwrap();
        line.push(b'\n');
        tail.extend_from_slice(&line);
        let mut file = OpenOptions::new().append(true).open(index_path(dir.path())).unwrap();
        file.write_all(&tail).unwrap();
        drop(file);
        rewrite(dir.path(), &current, since).unwrap();

        let sessions = list(dir.path()).unwrap();
        let b = sessions.iter().find(|s| s.id == "b").unwrap();
        assert_eq!(b.model.as_deref(), Some("anthropic/claude"), "the valid line after the corrupt one survives");
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn index_is_compacted_and_forgets_deleted_logs() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "k").unwrap();
        input(&mut log, "i1", "Keep this session around");
        for _ in 0..100 {
            update(log.path(), 0, None, None).unwrap();
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

    #[test]
    fn update_compacts_the_index_without_a_listing() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s").unwrap();
        input(&mut log, "i1", "Keep this session around");
        // Many turns with no intervening `list()`: the index must stay bounded
        // (compacted once it passes the threshold), not grow one line per turn.
        // 200 appends would be 200 lines unbounded; bounded it never exceeds
        // the compaction threshold of `sessions * 2 + 64`.
        for _ in 0..200 {
            update(log.path(), 0, None, None).unwrap();
        }
        let (index, lines) = load(dir.path());
        assert_eq!(index.len(), 1, "one live session");
        assert!(lines <= index.len() * 2 + 64, "index grew past the compaction threshold: {lines} lines");
        // The surviving summary is still correct.
        let sessions = list(dir.path()).unwrap();
        assert_eq!(sessions[0].id, "s");
        assert_eq!(sessions[0].prompts, 1);
    }

    #[test]
    fn load_isolates_a_non_utf8_line_instead_of_discarding_the_index() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = SessionLog::create(dir.path(), "a").unwrap();
        input(&mut a, "i1", "Session a's prompt");
        let mut b = SessionLog::create(dir.path(), "b").unwrap();
        input(&mut b, "i1", "Session b's prompt");
        list(dir.path()).unwrap();
        let (before, _) = load(dir.path());
        assert_eq!(before.len(), 2);

        // A line that is not valid UTF-8 must not make the read discard the
        // whole index: the good lines still load, so the listing reuses them
        // and the rewrite threshold still counts them.
        let mut bytes = fs::read(index_path(dir.path())).unwrap();
        bytes.extend_from_slice(b"\xff\xfe not utf8\n");
        fs::write(index_path(dir.path()), bytes).unwrap();
        let (after, lines) = load(dir.path());
        assert_eq!(after.len(), 2, "the two good lines survive the corrupt one");
        assert_eq!(lines, 3, "the corrupt line still counts toward compaction");
        assert_eq!(after["a"].prompts, 1);
        assert_eq!(after["b"].prompts, 1);
    }
}
