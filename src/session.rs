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
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::llm::Message;

pub const FORMAT_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data", rename_all = "snake_case")]
pub enum Record {
    Session {
        version: u32,
        id: String,
        created_at: DateTime<Utc>,
    },
    Input {
        id: String,
        text: String,
        recorded_at: DateTime<Utc>,
    },
    Message(Message),
    TurnEnd {
        input_id: String,
        response: String,
        /// Reported with `report_outcome` during the turn.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        outcome: Option<crate::goal::Outcome>,
        recorded_at: DateTime<Utc>,
    },
    /// The conversation was replaced wholesale (compaction, system-prompt reset).
    Replace {
        messages: Vec<Message>,
        /// Set when an in-flight input survives the replacement (compaction
        /// mid-turn): the index of its user message in `messages`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pending_position: Option<usize>,
        recorded_at: DateTime<Utc>,
    },
    /// The task plan after a change; the latest one wins.
    Plan {
        plan: crate::plan::Plan,
        recorded_at: DateTime<Utc>,
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
}

pub struct SessionLog {
    path: PathBuf,
    file: File,
}

pub fn default_dir() -> PathBuf {
    crate::config::app_dir(&dirs::data_local_dir().unwrap_or_else(std::env::temp_dir)).join("sessions")
}

pub fn new_session_id() -> String {
    format!(
        "sess-{}-{:08x}",
        Utc::now().format("%Y%m%dT%H%M%S"),
        fastrand::u32(..)
    )
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
    pub fn create(dir: &Path, id: &str) -> Result<Self> {
        validate_id(id)?;
        fs::create_dir_all(dir).with_context(|| format!("create session dir {}", dir.display()))?;
        let path = path_for(dir, id);
        let mut file = OpenOptions::new()
            .create_new(true)
            .append(true)
            .open(&path)
            .with_context(|| format!("create session log {}", path.display()))?;
        file.write_all(&encode(&Record::Session {
            version: FORMAT_VERSION,
            id: id.to_string(),
            created_at: Utc::now(),
        })?)?;
        file.sync_data()?;
        Ok(Self { path, file })
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
        let restored = decode(&bytes[..committed], id).with_context(|| format!("load session log {}", path.display()))?;
        let file = OpenOptions::new()
            .append(true)
            .open(&path)
            .with_context(|| format!("open session log {}", path.display()))?;
        if committed < bytes.len() {
            // Drop a torn trailing record so later appends stay line-aligned.
            file.set_len(committed as u64)?;
        }
        Ok((Self { path, file }, restored))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn append(&mut self, record: &Record) -> Result<()> {
        self.file
            .write_all(&encode(record)?)
            .with_context(|| format!("append to session log {}", self.path.display()))?;
        if matches!(record, Record::TurnEnd { .. } | Record::Replace { .. }) {
            self.file.sync_data()?;
        }
        Ok(())
    }
}

fn decode(bytes: &[u8], expected_id: &str) -> Result<Restored> {
    let mut restored = Restored::default();
    for (index, line) in bytes.split(|&b| b == b'\n').filter(|l| !l.is_empty()).enumerate() {
        let record: Record =
            serde_json::from_slice(line).with_context(|| format!("decode record {}", index + 1))?;
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
            Record::Message(message) => restored.conversation.push(message),
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
            Record::Replace { messages, pending_position, .. } => {
                restored.conversation = messages;
                restored.pending_input = match (restored.pending_input.take(), pending_position) {
                    (Some(pending), Some(position)) => Some(PendingInput { position, ..pending }),
                    _ => None,
                };
            }
            Record::Plan { plan, .. } => restored.plan = Some(plan),
        }
    }
    Ok(restored)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(id: &str) -> Record {
        Record::Input { id: id.into(), text: "hi".into(), recorded_at: Utc::now() }
    }

    fn turn_end(id: &str) -> Record {
        Record::TurnEnd { input_id: id.into(), response: "hello".into(), outcome: None, recorded_at: Utc::now() }
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
        assert_eq!(
            restored.pending_input,
            Some(PendingInput { id: "in-2".into(), text: "hi".into(), position: 3 })
        );
        assert!(SessionLog::create(dir.path(), "s1").is_err(), "create must not clobber");
    }

    #[test]
    fn replace_resets_conversation() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s2").unwrap();
        log.append(&Record::Message(Message::user("a"))).unwrap();
        log.append(&Record::Replace { messages: vec![Message::system("new")], pending_position: None, recorded_at: Utc::now() })
            .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s2").unwrap();
        assert_eq!(restored.conversation, vec![Message::system("new")]);
    }

    #[test]
    fn replace_can_keep_the_pending_input() {
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "s3").unwrap();
        log.append(&Record::Input { id: "in-1".into(), text: "go".into(), recorded_at: Utc::now() }).unwrap();
        log.append(&Record::Message(Message::user("go"))).unwrap();
        let messages = vec![Message::system("sys"), Message::user("summary"), Message::user("go")];
        log.append(&Record::Replace { messages: messages.clone(), pending_position: Some(2), recorded_at: Utc::now() })
            .unwrap();
        drop(log);
        let (_, restored) = SessionLog::open(dir.path(), "s3").unwrap();
        assert_eq!(restored.conversation, messages);
        assert_eq!(restored.pending_input, Some(PendingInput { id: "in-1".into(), text: "go".into(), position: 2 }));
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
}
