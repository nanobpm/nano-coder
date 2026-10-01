//! Append-only, versioned JSONL session log with resume.
//!
//! Design follows unreal-agent's `harness/sessionstore/localfile`
//! (MIT, Copyright (c) 2026 Unreal Labs):
//! - the first record is a header carrying the format version, and an
//!   unsupported version is an explicit error on resume;
//! - only newline-terminated records are committed, so a torn final line from
//!   a crash is discarded (and truncated away before the next append);
//! - every input carries an ID, so redelivered inputs are recognised.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, FixedOffset, Local, Utc};
use serde::{Deserialize, Serialize};

use crate::llm::{Message, Role};

pub const FORMAT_VERSION: u32 = 1;

/// The current time with the local UTC offset, for records and messages.
pub fn now() -> DateTime<FixedOffset> {
    Local::now().fixed_offset()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data", rename_all = "snake_case")]
pub enum Record {
    Session {
        version: u32,
        id: String,
        created_at: DateTime<FixedOffset>,
        /// Working directory the session started in (absent in older logs).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
        /// `provider/model` the session started with (absent in older logs).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
    },
    Input {
        id: String,
        text: String,
        recorded_at: DateTime<FixedOffset>,
    },
    Message(Message),
    TurnEnd {
        input_id: String,
        response: String,
        /// Reported with `report_outcome` during the turn.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        outcome: Option<crate::goal::Outcome>,
        /// `history_search` / `history_read` calls made during the turn.
        #[serde(default, skip_serializing_if = "is_zero")]
        history_calls: u32,
        recorded_at: DateTime<FixedOffset>,
    },
    /// The conversation was replaced wholesale (compaction, system-prompt reset).
    Replace {
        messages: Vec<Message>,
        /// Set when an in-flight input survives the replacement (compaction
        /// mid-turn): the index of its user message in `messages`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pending_position: Option<usize>,
        /// Compaction only: first and last log line folded into the summary.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        summarized: Option<(u64, u64)>,
        /// Compaction only: `standard` or `smart`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        mode: Option<crate::config::CompactionMode>,
        /// Compaction only: the `provider/model` in use, for comparing modes.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        recorded_at: DateTime<FixedOffset>,
    },
    /// The task plan after a change; the latest one wins.
    Plan {
        plan: crate::plan::Plan,
        recorded_at: DateTime<FixedOffset>,
    },
}

/// An input that was accepted but whose turn has not ended.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingInput {
    pub id: String,
    pub text: String,
    /// Conversation length when the input was accepted; its user message, if
    /// recorded, is at this index.
    pub position: usize,
}

/// State rebuilt from a session log.
#[derive(Debug, Default)]
pub struct Restored {
    pub conversation: Vec<Message>,
    /// Responses for completed inputs, by input ID.
    pub completed: HashMap<String, String>,
    /// Outcomes reported by completed inputs, by input ID.
    pub outcomes: HashMap<String, crate::goal::Outcome>,
    /// An input accepted but not completed before the log ended.
    pub pending_input: Option<PendingInput>,
    pub plan: Option<crate::plan::Plan>,
    /// Whether the last replacement was a smart compaction, so the resumed
    /// session should offer the history tools without re-sniffing message text.
    pub history_available: bool,
    /// Whether the one-time post-compaction history hint was already emitted
    /// (or a history tool was already used) after the latest smart compaction,
    /// so a resume does not append it a second time.
    pub history_hint_consumed: bool,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

pub struct SessionLog {
    path: PathBuf,
    file: File,
    /// Committed records in the file (the last line number written).
    lines: u64,
}

/// Directory for complete copies of truncated tool output of session `id`.
pub fn spill_dir_for(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.spill"))
}

pub fn default_dir() -> PathBuf {
    crate::config::app_dir(&dirs::data_local_dir().unwrap_or_else(std::env::temp_dir)).join("sessions")
}

pub fn new_session_id() -> String {
    format!("sess-{}-{:08x}", Utc::now().format("%Y%m%dT%H%M%S"), fastrand::u32(..))
}

/// Session IDs name files, so restrict them to a safe alphabet.
pub fn validate_id(id: &str) -> Result<()> {
    let valid = !id.is_empty()
        && id.len() <= 128
        && !id.starts_with('.')
        && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    if !valid {
        bail!("invalid session id {id:?}: use 1-128 of [A-Za-z0-9._-], not starting with '.'");
    }
    Ok(())
}

fn path_for(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.jsonl"))
}

fn encode(record: &Record) -> Result<Vec<u8>> {
    let mut line = serde_json::to_vec(record).context("encode session record")?;
    line.push(b'\n');
    Ok(line)
}

impl SessionLog {
    #[cfg(test)]
    pub fn create(dir: &Path, id: &str) -> Result<Self> {
        Self::create_with(dir, id, None, None)
    }

    /// [`create`](Self::create), recording where and with what model the
    /// session started (shown when picking a session to resume).
    pub fn create_with(dir: &Path, id: &str, cwd: Option<String>, model: Option<String>) -> Result<Self> {
        validate_id(id)?;
        fs::create_dir_all(dir).with_context(|| format!("create session dir {}", dir.display()))?;
        let path = path_for(dir, id);
        let mut file = OpenOptions::new()
            .create_new(true)
            .append(true)
            .open(&path)
            .with_context(|| format!("create session log {}", path.display()))?;
        let header = Record::Session { version: FORMAT_VERSION, id: id.to_string(), created_at: now(), cwd, model };
        file.write_all(&encode(&header)?)?;
        file.sync_data()?;
        Ok(Self { path, file, lines: 1 })
    }

    pub fn open(dir: &Path, id: &str) -> Result<(Self, Restored)> {
        validate_id(id)?;
        let path = path_for(dir, id);
        let bytes = fs::read(&path).with_context(|| format!("read session log {}", path.display()))?;
        let committed = bytes
            .iter()
            .rposition(|&b| b == b'\n')
            .map(|i| i + 1)
            .ok_or_else(|| anyhow!("session log {} has no committed records", path.display()))?;
        let restored =
            decode(&bytes[..committed], id).with_context(|| format!("load session log {}", path.display()))?;
        let file = OpenOptions::new()
            .append(true)
            .open(&path)
            .with_context(|| format!("open session log {}", path.display()))?;
        if committed < bytes.len() {
            // Drop a torn trailing record so later appends stay line-aligned.
            file.set_len(committed as u64)?;
        }
        // Count PHYSICAL lines, not just nonempty records: `append` writes at
        // the next physical line, and `decode`/`read_records_at` number
        // messages by physical line, so a blank line in the log must advance
        // the counter too — otherwise a reopened session appends at the right
        // physical line but returns a `#N` that collides with an existing
        // message and diverges from `history_read`.
        let lines = bytes[..committed].iter().filter(|&&b| b == b'\n').count() as u64;
        Ok((Self { path, file, lines }, restored))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Append a record; returns its 1-based line number in the log.
    pub fn append(&mut self, record: &Record) -> Result<u64> {
        self.file
            .write_all(&encode(record)?)
            .with_context(|| format!("append to session log {}", self.path.display()))?;
        if matches!(record, Record::TurnEnd { .. } | Record::Replace { .. }) {
            self.file.sync_data()?;
        }
        self.lines += 1;
        Ok(self.lines)
    }
}

/// Every committed record from a session log, in order, for offline tools
/// like the trajectory view. Unlike [`SessionLog::open`], this does not fold
/// records into a [`Restored`] snapshot: it returns them verbatim so a reader
/// can reconstruct the turn-by-turn ledger (inputs, per-message
/// thinking/usage/timing, tool results, compactions). A torn trailing line
/// from a crash is discarded, exactly as on resume.
pub fn read_records(dir: &Path, id: &str) -> Result<Vec<Record>> {
    validate_id(id)?;
    read_records_at(&path_for(dir, id), Some(id))
}

/// [`read_records`] for a known log path (the live session's own file).
/// `expected_id`, when given, is checked against the session header's `id` so a
/// renamed or misplaced log is rejected rather than read as the wrong session;
/// pass `None` for the live session's own file, whose path is authoritative.
pub fn read_records_at(path: &Path, expected_id: Option<&str>) -> Result<Vec<Record>> {
    let bytes = fs::read(path).with_context(|| format!("read session log {}", path.display()))?;
    // Require at least one committed (newline-terminated) record; a log with none
    // is empty or torn, and treating it as an empty trajectory would be
    // misleading.
    let committed = bytes
        .iter()
        .rposition(|&b| b == b'\n')
        .map(|i| i + 1)
        .ok_or_else(|| anyhow!("session log {} has no committed records", path.display()))?;
    let mut records = Vec::new();
    // Record ordinals count only decodable records (the session header is
    // record 1), but a message's `log_line` is its PHYSICAL line number:
    // `history_read`/`history_search` enumerate physical lines and skip empty
    // ones, so a blank line in the log must not shift every later `#N`.
    let mut index = 0usize;
    for (line_no, line) in bytes[..committed].split(|&b| b == b'\n').enumerate() {
        if line.is_empty() {
            continue;
        }
        let record: Record = serde_json::from_slice(line)
            .with_context(|| format!("decode record {} of {}", index + 1, path.display()))?;
        // Enforce the same invariants `SessionLog::open` does: the first record
        // must be a session header of a supported format version.
        match &record {
            Record::Session { version, id, .. } => {
                if index != 0 {
                    bail!("session record must be first (found at record {})", index + 1);
                }
                if *version != FORMAT_VERSION {
                    bail!("unsupported session format version {version} (this build supports {FORMAT_VERSION})");
                }
                // Match `SessionLog::open`: a log whose header id differs from the
                // requested id was renamed or misplaced, so refuse to read it as
                // the requested session.
                if let Some(expected) = expected_id
                    && id != expected
                {
                    bail!("session log header id {id:?} does not match {expected:?}");
                }
            }
            _ if index == 0 => bail!("session log {} does not start with a session header", path.display()),
            _ => {}
        }
        // Number messages by log line, as `SessionLog::open` does, so the
        // trajectory cites the same `#N` IDs as `history_read` and smart
        // summaries. Assign the physical line unconditionally: a direct message
        // record's ID IS its physical line (`history_read` enumerates lines and
        // knows nothing of a serialized field), so a syntactically valid log
        // carrying a stale `log_line` on a direct record must not export a
        // different `#N` than `history_read` shows. Embedded IDs are meaningful
        // only on messages nested inside `replace` records.
        let mut record = record;
        if let Record::Message(message) = &mut record {
            message.log_line = Some(line_no as u64 + 1);
        }
        records.push(record);
        index += 1;
    }
    // A log made up solely of newline bytes passes the `rposition` check but
    // filters down to zero records, so the session-header invariant above is
    // never enforced. Reject it rather than return a misleading empty ledger.
    if records.is_empty() {
        bail!("session log {} has no decodable records", path.display());
    }
    Ok(records)
}

/// Compare two messages by their durable content, ignoring only the transient
/// `timestamp`/`log_line` fields that differ between a direct record and the
/// copy retained inside a later `replace` record. Durable provider content
/// (including `thinking_blocks`) is compared, so two assistant messages with
/// identical visible text/tool calls but different reasoning blocks are not
/// treated as the same message.
fn same_content(a: &Message, b: &Message) -> bool {
    a.role == b.role
        && a.content == b.content
        && a.tool_calls == b.tool_calls
        && a.tool_call_id == b.tool_call_id
        && a.name == b.name
        && a.is_error == b.is_error
        && a.thinking_blocks == b.thinking_blocks
}

/// Backfill stable `[#N]` IDs onto a `replace` record's retained messages from
/// the original message records they were folded from. Logs written before the
/// stable-ID feature stored `replace` messages without `log_line`, so a later
/// smart compaction would emit them without `[#N]` citations even though the
/// original records are still present. Match each un-IDed retained message to
/// the first not-yet-claimed original with identical content, preserving order
/// so duplicate messages map to distinct originals. `summarized` (the folded
/// line range, when the log recorded one) bounds the search to originals past
/// the summary, so a duplicate whose earlier occurrence was folded into the
/// summary is not mis-mapped to that folded copy; pre-range legacy logs fall
/// back to the first content match. The system message is skipped: it is never
/// `[#N]`-cited and carries no `log_line` in a live session, so backfilling it
/// would make a reloaded session disagree with the in-memory one. Messages with
/// no matching original (e.g. a freshly generated summary) are left un-IDed.
fn backfill_log_lines(messages: &mut [Message], originals: &[Message], summarized: Option<(u64, u64)>) {
    let floor = summarized.map_or(0, |(_, end)| end);
    let mut claimed = vec![false; originals.len()];
    for message in messages.iter_mut().filter(|m| m.log_line.is_none() && m.role != Role::System) {
        if let Some((index, original)) = originals
            .iter()
            .enumerate()
            .find(|(i, o)| !claimed[*i] && o.log_line.is_some_and(|line| line > floor) && same_content(o, message))
        {
            message.log_line = original.log_line;
            claimed[index] = true;
        }
    }
}

fn decode(bytes: &[u8], expected_id: &str) -> Result<Restored> {
    let mut restored = Restored::default();
    // Every direct message record seen so far, with its assigned `log_line`, so
    // a later `replace` from a legacy log can recover the IDs of retained messages.
    let mut originals: Vec<Message> = Vec::new();
    // Record ordinals count only decodable records (the session header is
    // record 1), but a message's `log_line` is its PHYSICAL line number:
    // `history_read`/`history_search` enumerate physical lines and skip empty
    // ones, so a blank line in the log must not shift every later `#N`.
    let mut index = 0usize;
    for (line_no, line) in bytes.split(|&b| b == b'\n').enumerate() {
        if line.is_empty() {
            continue;
        }
        let record: Record = serde_json::from_slice(line).with_context(|| format!("decode record {}", index + 1))?;
        match record {
            Record::Session { version, id, .. } => {
                if index != 0 {
                    bail!("session record must be first (found at record {})", index + 1);
                }
                if version != FORMAT_VERSION {
                    bail!("unsupported session format version {version} (this build supports {FORMAT_VERSION})");
                }
                if id != expected_id {
                    bail!("session log header id {id:?} does not match {expected_id:?}");
                }
            }
            _ if index == 0 => bail!("session log does not start with a session header"),
            Record::Input { id, text, .. } => {
                restored.pending_input = Some(PendingInput { id, text, position: restored.conversation.len() });
            }
            Record::Message(mut message) => {
                // A direct record's ID is its physical line (`history_read`
                // enumerates lines), so assign it unconditionally: a stale
                // serialized `log_line` must not override the line the history
                // tools would cite. Embedded IDs are meaningful only on
                // messages nested inside `replace` records.
                message.log_line = Some(line_no as u64 + 1);
                if crate::history::consumes_hint(&message) {
                    restored.history_hint_consumed = true;
                }
                originals.push(message.clone());
                restored.conversation.push(message);
            }
            Record::TurnEnd { input_id, response, outcome, .. } => {
                if restored.pending_input.as_ref().is_some_and(|p| p.id == input_id) {
                    restored.pending_input = None;
                }
                match outcome {
                    Some(outcome) => restored.outcomes.insert(input_id.clone(), outcome),
                    None => restored.outcomes.remove(&input_id),
                };
                restored.completed.insert(input_id, response);
            }
            Record::Replace { mut messages, pending_position, summarized, mode, .. } => {
                backfill_log_lines(&mut messages, &originals, summarized);
                restored.conversation = messages;
                restored.pending_input = match (restored.pending_input.take(), pending_position) {
                    (Some(pending), Some(position)) => Some(PendingInput { position, ..pending }),
                    _ => None,
                };
                // A smart compaction offers the history tools; restore that
                // state from the mode rather than sniffing the summary text.
                restored.history_available = matches!(mode, Some(crate::config::CompactionMode::Smart));
                // The one-time hint re-arms with each compaction; only messages
                // recorded after this replace can consume it.
                restored.history_hint_consumed = false;
            }
            Record::Plan { plan, .. } => restored.plan = Some(plan),
        }
        index += 1;
    }
    Ok(restored)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stale_log_line_on_a_direct_record_is_renumbered_to_its_physical_line() {
        // A direct message record's `#N` IS its physical line: `history_read`
        // enumerates lines and knows nothing of a serialized field, so both
        // readers must assign the physical line unconditionally rather than
        // trust an embedded `log_line`. (Live logs never carry one on direct
        // records — it is written only inside `replace` records — but a
        // syntactically valid log can.)
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let stale: Record =
            serde_json::from_str(r#"{"type":"message","data":{"role":"user","content":"hi","log_line":99}}"#).unwrap();
        assert_eq!(stale, Record::Message(Message { log_line: Some(99), ..Message::user("hi") }));
        let mut log = String::new();
        for record in [
            Record::Session { version: FORMAT_VERSION, id: "s".into(), created_at: now(), cwd: None, model: None },
            input("i"),
            stale,
        ] {
            log.push_str(&serde_json::to_string(&record).unwrap());
            log.push('\n');
        }
        std::fs::write(&path, log).unwrap();
        let records = read_records_at(&path, Some("s")).unwrap();
        let Record::Message(message) = &records[2] else { panic!("a message record") };
        assert_eq!(message.log_line, Some(3), "the physical line wins over the serialized field");
        let (_, restored) = SessionLog::open(dir.path(), "s").unwrap();
        assert_eq!(restored.conversation[0].log_line, Some(3));
    }

    #[test]
    fn reads_utc_records_and_unstamped_messages_from_older_logs() {
        let input: Record = serde_json::from_str(
            r#"{"type":"input","data":{"id":"i","text":"hi","recorded_at":"2026-01-01T00:00:00Z"}}"#,
        )
        .unwrap();
        let Record::Input { recorded_at, .. } = input else { panic!() };
        assert_eq!(recorded_at.to_rfc3339(), "2026-01-01T00:00:00+00:00");
        let message: Record =
            serde_json::from_str(r#"{"type":"message","data":{"role":"user","content":"hi"}}"#).unwrap();
        assert_eq!(message, Record::Message(Message::user("hi")));
        // New records carry the local offset.
        let now = serde_json::to_string(&now()).unwrap();
        assert!(now.contains('+') || now.contains("-0") || now.contains("-1"), "{now}");
    }

    fn input(id: &str) -> Record {
        Record::Input { id: id.into(), text: "hi".into(), recorded_at: now() }
    }

    fn turn_end(id: &str) -> Record {
        Record::TurnEnd {
            input_id: id.into(),
            response: "hello".into(),
            outcome: None,
            history_calls: 0,
            recorded_at: now(),
        }
    }

    #[test]
    fn round_trips_and_tracks_inputs() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s1").unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap();
        log.append(&input("in-1")).unwrap();
        log.append(&Record::Message(Message::user("hi"))).unwrap();
        log.append(&Record::Message(Message::assistant("hello"))).unwrap();
        log.append(&turn_end("in-1")).unwrap();
        log.append(&input("in-2")).unwrap();
        log.append(&Record::Message(Message::user("again"))).unwrap();
        drop(log);

        let (_, restored) = SessionLog::open(dir.path(), "s1").unwrap();
        assert_eq!(restored.conversation.len(), 4);
        assert_eq!(restored.completed.get("in-1").map(String::as_str), Some("hello"));
        assert_eq!(restored.pending_input, Some(PendingInput { id: "in-2".into(), text: "hi".into(), position: 3 }));
        assert!(SessionLog::create(dir.path(), "s1").is_err(), "create must not clobber");
    }

    #[test]
    fn replace_resets_conversation() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s2").unwrap();
        log.append(&Record::Message(Message::user("a"))).unwrap();
        log.append(&Record::Replace {
            messages: vec![Message::system("new")],
            pending_position: None,
            summarized: None,
            mode: None,
            model: None,
            recorded_at: now(),
        })
        .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s2").unwrap();
        assert_eq!(restored.conversation, vec![Message::system("new")]);
    }

    #[test]
    fn replace_backfills_log_lines_for_legacy_retained_messages() {
        // A pre-feature log stores `replace` messages without `log_line`. Decoding
        // must recover each retained message's ID from its original record so
        // smart compaction can still cite it as `[#N]`.
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s5").unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap(); // #2
        log.append(&Record::Message(Message::user("first"))).unwrap(); // #3
        log.append(&Record::Message(Message::assistant("reply"))).unwrap(); // #4
        // Retained messages carry no `log_line`, as a legacy compaction would write.
        log.append(&Record::Replace {
            messages: vec![
                Message::system("sys"),
                Message::user("first"),
                Message::assistant("reply"),
                Message::assistant("summary"),
            ],
            pending_position: None,
            summarized: None,
            mode: None,
            model: None,
            recorded_at: now(),
        })
        .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s5").unwrap();
        let lines: Vec<Option<u64>> = restored.conversation.iter().map(|m| m.log_line).collect();
        // System is skipped (never cited); "first" -> #3, "reply" -> #4 (record
        // #1 is the session header); the freshly generated "summary" stays un-IDed.
        assert_eq!(lines, vec![None, Some(3), Some(4), None]);
    }

    #[test]
    fn replace_can_keep_the_pending_input() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s3").unwrap();
        log.append(&Record::Input { id: "in-1".into(), text: "go".into(), recorded_at: now() }).unwrap();
        log.append(&Record::Message(Message::user("go"))).unwrap();
        let messages = vec![Message::system("sys"), Message::user("summary"), Message::user("go")];
        log.append(&Record::Replace {
            messages: messages.clone(),
            pending_position: Some(2),
            summarized: None,
            mode: None,
            model: None,
            recorded_at: now(),
        })
        .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s3").unwrap();
        // The retained "go" folds in original record #3, so its ID is backfilled.
        let mut expected = messages.clone();
        expected[2].log_line = Some(3);
        assert_eq!(restored.conversation, expected);
        assert_eq!(restored.pending_input, Some(PendingInput { id: "in-1".into(), text: "go".into(), position: 2 }));
    }

    #[test]
    fn backfill_uses_the_summarized_range_to_disambiguate_duplicates() {
        // Two identical "same" messages; a smart compaction folds the first
        // (records #2..=#4) into the summary and keeps only the later one.
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s6").unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap(); // #2 (folded)
        log.append(&Record::Message(Message::user("same"))).unwrap(); // #3 (folded)
        log.append(&Record::Message(Message::assistant("x"))).unwrap(); // #4 (folded)
        log.append(&Record::Message(Message::user("same"))).unwrap(); // #5 (retained)
        // The retained "same" carries no log_line, as a legacy write would.
        log.append(&Record::Replace {
            messages: vec![Message::user("summary"), Message::user("same")],
            pending_position: None,
            summarized: Some((2, 4)),
            mode: Some(crate::config::CompactionMode::Smart),
            model: None,
            recorded_at: now(),
        })
        .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s6").unwrap();
        // The range bounds the match past #4, so the retained "same" maps to the
        // second occurrence (#5), not the folded first one (#3).
        assert_eq!(restored.conversation[1].log_line, Some(5));
        assert!(restored.history_available, "a smart replace offers the history tools");
    }

    #[test]
    fn blank_lines_do_not_shift_message_ids() {
        // `history_read`/`history_search` number messages by PHYSICAL log line
        // (enumerating every line, skipping empties). A blank line in the log
        // must not shift the `#N` of every message after it.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s7.jsonl");
        let header = serde_json::to_string(&Record::Session {
            version: FORMAT_VERSION,
            id: "s7".into(),
            created_at: now(),
            cwd: None,
            model: None,
        })
        .unwrap();
        let user = serde_json::to_string(&Record::Message(Message::user("hi"))).unwrap();
        let answer = serde_json::to_string(&Record::Message(Message::assistant("hello"))).unwrap();
        // Physical lines: 1 header, 2 user, 3 BLANK, 4 assistant.
        std::fs::write(&path, format!("{header}\n{user}\n\n{answer}\n")).unwrap();

        let (_, restored) = SessionLog::open(dir.path(), "s7").unwrap();
        let lines: Vec<Option<u64>> = restored.conversation.iter().map(|m| m.log_line).collect();
        assert_eq!(lines, vec![Some(2), Some(4)], "the assistant message stays on physical line 4");

        // Reopening and appending writes on physical line 5 AND returns #5: the
        // blank line must advance the append counter too, or the new message's
        // `#N` collides with the existing assistant (#4) and diverges from
        // `history_read`.
        let (mut log, _) = SessionLog::open(dir.path(), "s7").unwrap();
        let line = log.append(&Record::Message(Message::user("again"))).unwrap();
        assert_eq!(line, 5, "the append lands on physical line 5, past the blank line 3");
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s7").unwrap();
        let lines: Vec<Option<u64>> = restored.conversation.iter().map(|m| m.log_line).collect();
        assert_eq!(lines, vec![Some(2), Some(4), Some(5)]);

        // The offline trajectory reader agrees, so `/trajectory` cites the same
        // `#N` as `history_read`.
        let records = read_records(dir.path(), "s7").unwrap();
        let ids: Vec<Option<u64>> = records
            .iter()
            .filter_map(|r| match r {
                Record::Message(m) => Some(m.log_line),
                _ => None,
            })
            .collect();
        assert_eq!(ids, vec![Some(2), Some(4), Some(5)]);
    }

    #[test]
    fn standard_replace_does_not_offer_history_tools() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s7").unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap();
        log.append(&Record::Replace {
            messages: vec![Message::user("summary")],
            pending_position: None,
            summarized: Some((2, 2)),
            mode: Some(crate::config::CompactionMode::Standard),
            model: None,
            recorded_at: now(),
        })
        .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s7").unwrap();
        assert!(!restored.history_available, "a standard replace drops the history tools");
    }

    #[test]
    fn hint_consumed_tracks_messages_after_the_latest_replace() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s7b").unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap();
        log.append(&Record::Replace {
            messages: vec![Message::user("summary")],
            pending_position: None,
            summarized: Some((2, 2)),
            mode: Some(crate::config::CompactionMode::Smart),
            model: None,
            recorded_at: now(),
        })
        .unwrap();
        drop(log);
        // Right after the smart compaction the hint is unconsumed.
        let (_, restored) = SessionLog::open(dir.path(), "s7b").unwrap();
        assert!(restored.history_available && !restored.history_hint_consumed);

        // A failed tool result carrying the hint consumes it for this compaction.
        let mut log = SessionLog::open(dir.path(), "s7b").unwrap().0;
        let hinted = format!("Exit code: 1\n\n{}", crate::history::FAILED_TOOL_HINT);
        log.append(&Record::Message(Message::tool_error("c1", "bash", &hinted))).unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s7b").unwrap();
        assert!(restored.history_hint_consumed, "a hint emitted after the replace is consumed");
    }

    #[test]
    fn backfill_distinguishes_messages_by_thinking_blocks() {
        // Two assistant messages share visible text but carry different reasoning
        // blocks. Backfill must not treat them as identical: the retained copy
        // must recover the ID of the original with matching thinking blocks.
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s8").unwrap();
        let think_a =
            Message { thinking_blocks: vec![serde_json::json!({"thinking": "a"})], ..Message::assistant("reply") };
        let think_b =
            Message { thinking_blocks: vec![serde_json::json!({"thinking": "b"})], ..Message::assistant("reply") };
        log.append(&Record::Message(Message::system("sys"))).unwrap(); // #2
        log.append(&Record::Message(think_a.clone())).unwrap(); // #3
        log.append(&Record::Message(think_b.clone())).unwrap(); // #4
        // A legacy replace retains only the second reasoning variant, un-IDed.
        log.append(&Record::Replace {
            messages: vec![Message::user("summary"), Message { log_line: None, ..think_b.clone() }],
            pending_position: None,
            summarized: None,
            mode: None,
            model: None,
            recorded_at: now(),
        })
        .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s8").unwrap();
        // Maps to #4 (matching thinking blocks), not #3.
        assert_eq!(restored.conversation[1].log_line, Some(4));
    }

    #[test]
    fn discards_torn_tail_and_appends_cleanly() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s3").unwrap();
        log.append(&Record::Message(Message::user("a"))).unwrap();
        drop(log);
        let path = path_for(dir.path(), "s3");
        let mut file = OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(br#"{"type":"message","data":{"role":"us"#).unwrap();
        drop(file);

        let (mut log, restored) = SessionLog::open(dir.path(), "s3").unwrap();
        assert_eq!(restored.conversation.len(), 1);
        log.append(&Record::Message(Message::user("b"))).unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s3").unwrap();
        assert_eq!(restored.conversation.len(), 2);
    }

    #[test]
    fn rejects_unsupported_versions_and_bad_ids() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(
            path_for(dir.path(), "future"),
            "{\"type\":\"session\",\"data\":{\"version\":99,\"id\":\"future\",\"created_at\":\"2026-01-01T00:00:00Z\"}}\n",
        )
        .unwrap();
        let err = SessionLog::open(dir.path(), "future").err().unwrap();
        assert!(format!("{err:#}").contains("unsupported session format version 99"), "{err:#}");
        assert!(validate_id("../etc/passwd").is_err());
        assert!(validate_id(".hidden").is_err());
        assert!(validate_id(&new_session_id()).is_ok());
    }

    #[test]
    fn golden_format_is_stable() {
        let record = Record::Message(Message::tool_result("c1", "bash", "ok"));
        assert_eq!(
            serde_json::to_string(&record).unwrap(),
            r#"{"type":"message","data":{"role":"tool","content":"ok","tool_call_id":"c1","name":"bash"}}"#
        );
    }

    #[test]
    fn read_records_rejects_a_header_id_that_differs_from_the_requested_id() {
        // A log written for session "real" but read back as "renamed" (a renamed
        // or misplaced file) must be rejected, matching SessionLog::open.
        let dir = tempfile::tempdir().unwrap();
        let path = path_for(dir.path(), "renamed");
        fs::write(
            &path,
            "{\"type\":\"session\",\"data\":{\"version\":1,\"id\":\"real\",\"created_at\":\"2026-01-01T00:00:00Z\"}}\n",
        )
        .unwrap();
        let err = read_records(dir.path(), "renamed").err().unwrap();
        assert!(format!("{err:#}").contains("does not match"), "{err:#}");
        // The live-session path (no expected id) accepts the same file: its own
        // path is authoritative, so no id check applies.
        assert!(read_records_at(&path, None).is_ok());
        // And an explicit matching id accepts it too.
        assert!(read_records_at(&path, Some("real")).is_ok());
    }
}
