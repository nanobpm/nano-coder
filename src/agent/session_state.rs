//! Session persistence and redelivery state (issue #116, extraction 2).
//!
//! `Agent` delegates the active session's durable log and its redelivery
//! bookkeeping to [`SessionState`]:
//!
//! - **The log** — the optional [`SessionLog`] (absent when persistence is off)
//!   and the active session ID, plus `turn_log_offset`, the log size when the
//!   current turn began (so the session-index update in `finish_turn` folds
//!   only this turn's records into the cached summary).
//! - **Redelivery dedup** — the `completed_*` maps recording how each processed
//!   input ended (its response, outcome, and any non-`EndTurn` stop reason), so
//!   a redelivered input replays its recorded result instead of re-running.
//! - **The pending input** — an input accepted but whose turn never finished
//!   (crash, kill, or error), resumed on the next turn.
//! - **ID counters** — the per-process input and message counters behind
//!   `in-…` / `msg-…` IDs.
//!
//! Invariants owned here:
//! - A completed input's response, outcome and stop reason are recorded
//!   together ([`SessionState::record_completion`]) and the pending input is
//!   cleared in the same step, so a redelivery never sees a half-finished turn.
//! - A non-`EndTurn` stop reason is stored only for turns that did not end
//!   cleanly; clean turns are absent (treated as `EndTurn`), so the map stays
//!   sparse (issue #114).

use std::collections::HashMap;

use anyhow::Result;

use crate::goal::Outcome;
use crate::session::{PendingInput, Record, SessionLog};

use super::StopReason;

/// Session persistence and redelivery state extracted from `Agent`.
#[derive(Default)]
pub(super) struct SessionState {
    /// The active session's durable log; `None` when persistence is disabled.
    log: Option<SessionLog>,
    /// Active session ID (also set when persistence is disabled).
    id: Option<String>,
    /// Responses for inputs already processed, by input ID (deduplication).
    completed_inputs: HashMap<String, String>,
    /// Outcomes reported by completed inputs, by input ID.
    completed_outcomes: HashMap<String, Outcome>,
    /// Non-`EndTurn` stop reasons of completed inputs, by input ID, so a
    /// redelivered input replays how its turn actually ended — e.g. a truncated
    /// `MaxTokens` turn — instead of a clean `EndTurn` (issue #114). Clean turns
    /// are absent.
    completed_stop_reasons: HashMap<String, StopReason>,
    /// An input that was accepted but whose turn never finished (crash, kill, or error).
    pending_input: Option<PendingInput>,
    /// Per-process counter behind `in-…` input IDs.
    input_counter: u64,
    /// Per-process counter behind `msg-…` message IDs.
    message_counter: u64,
    /// Session-log size when the current turn began; the session-index update
    /// in `finish_turn` folds the input records committed since into the
    /// cached summary (from the log's tail) instead of rescanning the whole
    /// log.
    turn_log_offset: Option<u64>,
}

impl SessionState {
    // --- the log -----------------------------------------------------------

    /// Whether a durable session log is attached (persistence enabled).
    pub(super) fn is_persistent(&self) -> bool {
        self.log.is_some()
    }

    /// The active session ID, if any.
    pub(super) fn id(&self) -> Option<&str> {
        self.id.as_deref()
    }

    /// The path of the active session log, if persisted.
    pub(super) fn path(&self) -> Option<&std::path::Path> {
        self.log.as_ref().map(SessionLog::path)
    }

    /// The transcript path handed to the hook manager, if persisted.
    pub(super) fn transcript_path(&self) -> Option<std::path::PathBuf> {
        self.log.as_ref().map(|log| log.path().to_path_buf())
    }

    /// Append a record to the durable log. A no-op returning `Ok(0)` when the
    /// session is not persisted.
    pub(super) fn append(&mut self, record: &Record) -> Result<u64> {
        match &mut self.log {
            Some(log) => log.append(record),
            None => Ok(0),
        }
    }

    /// Append a record, discarding the result (best-effort audit trails).
    pub(super) fn append_best_effort(&mut self, record: &Record) {
        if let Some(log) = &mut self.log {
            let _ = log.append(record);
        }
    }

    /// Mark the start of a turn: the session-index update folds only the
    /// records committed from this offset.
    pub(super) fn begin_turn(&mut self) {
        self.turn_log_offset = self.log.as_ref().map(|log| log.size());
    }

    /// The log offset the current turn began at (0 when none was marked).
    pub(super) fn turn_log_offset(&self) -> u64 {
        self.turn_log_offset.unwrap_or(0)
    }

    /// Attach a freshly created session log and ID (a new session).
    pub(super) fn install(&mut self, log: Option<SessionLog>, id: String) {
        self.log = log;
        self.id = Some(id);
    }

    /// Attach a loaded session log and ID (a resumed session).
    pub(super) fn install_loaded(&mut self, log: SessionLog, id: &str) {
        self.log = Some(log);
        self.id = Some(id.to_string());
    }

    // --- redelivery dedup --------------------------------------------------

    /// The recorded result of an already-processed input, if any: its
    /// response, how its turn actually ended, and its outcome.
    pub(super) fn completed(&self, id: &str) -> Option<(String, StopReason, Option<Outcome>)> {
        self.completed_inputs.get(id).map(|response| {
            let stop_reason = self.completed_stop_reasons.get(id).copied().unwrap_or(StopReason::EndTurn);
            (response.clone(), stop_reason, self.completed_outcomes.get(id).cloned())
        })
    }

    /// Record a completed input's response, outcome and stop reason together,
    /// and clear the pending input: the turn is finished, so a redelivery
    /// replays this result and there is nothing left to resume.
    pub(super) fn record_completion(
        &mut self,
        input_id: String,
        response: String,
        outcome: Option<Outcome>,
        stop_reason: StopReason,
    ) {
        match &outcome {
            Some(outcome) => self.completed_outcomes.insert(input_id.clone(), outcome.clone()),
            None => self.completed_outcomes.remove(&input_id),
        };
        if stop_reason.is_end_turn() {
            self.completed_stop_reasons.remove(&input_id);
        } else {
            self.completed_stop_reasons.insert(input_id.clone(), stop_reason);
        }
        self.completed_inputs.insert(input_id, response);
        self.pending_input = None;
    }

    // --- the pending input -------------------------------------------------

    /// The in-flight (accepted but unfinished) input, if any.
    pub(super) fn pending(&self) -> Option<&PendingInput> {
        self.pending_input.as_ref()
    }

    /// A mutable handle to the in-flight input, if any.
    pub(super) fn pending_mut(&mut self) -> Option<&mut PendingInput> {
        self.pending_input.as_mut()
    }

    /// The pending input when it matches `input_id` (a resume of that input).
    pub(super) fn pending_matching(&self, input_id: Option<&str>) -> Option<PendingInput> {
        self.pending_input.clone().filter(|pending| input_id == Some(pending.id.as_str()))
    }

    /// Accept a new pending input.
    pub(super) fn set_pending(&mut self, pending: PendingInput) {
        self.pending_input = Some(pending);
    }

    /// The in-flight input's output-limit continuation snapshot, if any.
    pub(super) fn pending_continuation(&self) -> Option<(String, usize)> {
        self.pending_input.as_ref().and_then(|p| p.continuation.clone())
    }

    /// The in-flight input's spent recall-note budget (0 when none).
    pub(super) fn pending_recall_notes(&self) -> usize {
        self.pending_input.as_ref().map_or(0, |p| p.recall_notes)
    }

    /// After a conversation replacement, re-anchor the surviving pending input
    /// to `position` (and mark its continuation boundary at
    /// `continuation_base`); drop it when there is no surviving position.
    pub(super) fn reanchor_pending(&mut self, position: Option<usize>, continuation_base: usize) {
        self.pending_input = match (self.pending_input.take(), position) {
            (Some(pending), Some(position)) => {
                Some(PendingInput { position, continuation_base: Some(continuation_base), ..pending })
            }
            _ => None,
        };
    }

    // --- ID counters -------------------------------------------------------

    /// The next `in-…` input ID.
    pub(super) fn next_input_id(&mut self) -> String {
        self.input_counter += 1;
        format!("in-{}-{}", chrono::Utc::now().timestamp_millis(), self.input_counter)
    }

    /// The next `msg-…` message ID.
    pub(super) fn next_message_id(&mut self) -> String {
        self.message_counter += 1;
        format!("msg-{}-{}", chrono::Utc::now().timestamp_millis(), self.message_counter)
    }

    // --- lifecycle ---------------------------------------------------------

    /// Clear the redelivery and pending state for a freshly created session.
    pub(super) fn reset_for_new_session(&mut self) {
        self.completed_inputs.clear();
        self.completed_outcomes.clear();
        self.completed_stop_reasons.clear();
        self.pending_input = None;
    }

    /// Restore the redelivery and pending state from a loaded session log.
    pub(super) fn restore_from(
        &mut self,
        completed: HashMap<String, String>,
        outcomes: HashMap<String, Outcome>,
        stop_reasons: HashMap<String, StopReason>,
        pending_input: Option<PendingInput>,
    ) {
        self.completed_inputs = completed;
        self.completed_outcomes = outcomes;
        self.completed_stop_reasons = stop_reasons;
        self.pending_input = pending_input;
    }
}
