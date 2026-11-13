//! Compaction, calibration and replay state (issue #116, extraction 3).
//!
//! `Agent` delegates the state that tracks *how full the context is* and *what
//! a compaction folded away* to [`CompactionState`]:
//!
//! - **Token calibration** — the `(conversation_len, tokens)` anchor from the
//!   last response's reported usage, from which `estimate_context_tokens`
//!   extrapolates, plus the window / output-token caps *learned* from
//!   context-overflow and output-limit rejection errors (used until the model
//!   changes, issue #114).
//! - **Compaction gating** — `compact_floor`, the context size right after the
//!   last compaction, so auto-compaction waits for real growth past it instead
//!   of re-summarizing an incompressible context on every call.
//! - **History / replay** — whether a real smart-compaction summary is in
//!   context (`history_available`, gating the history tools), the one-time
//!   post-compaction `history_hint_pending` pointer, and the
//!   `pre_compaction_transcript` stash (with its `pre_compaction_restated`
//!   skip-index) that lets `replay_history` rebuild the real folded turns
//!   instead of exposing the synthetic summary.
//!
//! Invariants owned here:
//! - `pre_compaction_restated` is tracked and cleared **in lockstep with**
//!   `pre_compaction_transcript` ([`CompactionState::replace_stash`] and the
//!   reset/restore methods), so the replay skip-index never outlives the stash
//!   it indexes into.
//! - `history_available` flips only once the durable replace record is
//!   appended ([`CompactionState::set_history_available`] is called after the
//!   log write), so a failed replacement leaves the active state unchanged.

use crate::llm::Message;

/// Compaction, calibration and replay state extracted from `Agent`.
#[derive(Default)]
pub(super) struct CompactionState {
    /// Conversation length and exact token count from the last response's
    /// reported usage, used to anchor the context estimate.
    calibration: Option<(usize, usize)>,
    /// Window learned from a context-overflow error (until the model changes).
    learned_window: Option<usize>,
    /// Output-token cap learned from an output-limit rejection error, used
    /// until the model changes. With automatic `max_tokens` an unlisted model
    /// whose real cap is below `DEFAULT_MAX_OUTPUT_TOKENS` would otherwise be
    /// rejected every request until a background `/model`-switch probe lands;
    /// learning the cap from the first rejection lets the retry succeed without
    /// blocking the switch on the probe (issue #114).
    learned_max_output: Option<usize>,
    /// Context size right after the last compaction; auto-compaction waits
    /// for real growth past it so an incompressible context is not
    /// re-summarized on every call.
    compact_floor: usize,
    /// Whether a real smart-compaction summary is in context, gating the
    /// history tools. Tracked explicitly (set by compaction, restored from the
    /// replace record's mode) rather than sniffed from message text, so a user
    /// message that merely begins with the summary prefix cannot unlock them.
    history_available: bool,
    /// A failed tool call (e.g. bash, read_file) after a smart compaction gets a one-time
    /// pointer to the history tools (models tend to look on disk for what
    /// was only in the conversation). Cleared once shown or once the agent
    /// uses a history tool.
    history_hint_pending: bool,
    /// The real pre-compaction turns, captured when a compaction folded them
    /// into the synthetic summary. `replay_history` replays THESE (and skips
    /// the summary) so a legacy → frame renderer switch rebuilds the visible
    /// transcript instead of exposing the summary as a user turn and dropping
    /// the folded turns — the frame's first full redraw clears the legacy
    /// scrollback, so the replay is the only copy. The same stash is persisted
    /// in the compaction's `Record::Replace`, so a resume or /relaunch (a fresh
    /// process over the session log) restores it and replays the real turns
    /// too. Kept across replays (every renderer rebuild needs it), replaced by
    /// the next compaction, and cleared by any non-compaction conversation
    /// replacement (a plain rebuild or system-prompt change) and on a new
    /// session. `None` when no compaction has run (or none was captured).
    pre_compaction_transcript: Option<Vec<Message>>,
    /// Index, in the compacted conversation, of the synthetic restatement of
    /// the active input the current `pre_compaction_transcript` compaction
    /// folded into its summary (see `CompactionRecord::restated`).
    /// `replay_history` skips it so the prompt is not shown twice. Tracked and
    /// cleared in lockstep with `pre_compaction_transcript`.
    pre_compaction_restated: Option<usize>,
}

impl CompactionState {
    // --- token calibration -------------------------------------------------

    /// The calibration anchor: `(conversation_len, tokens)` from the last
    /// response's reported usage.
    pub(super) fn calibration(&self) -> Option<(usize, usize)> {
        self.calibration
    }

    /// Anchor the estimate at `len` messages / `tokens` tokens (a response's
    /// reported usage).
    pub(super) fn calibrate(&mut self, len: usize, tokens: usize) {
        self.calibration = Some((len, tokens));
    }

    /// Drop the calibration anchor (a model change or any conversation
    /// replacement invalidates it).
    pub(super) fn clear_calibration(&mut self) {
        self.calibration = None;
    }

    // --- learned limits ----------------------------------------------------

    /// Whether the window learned from a context-overflow error is at least
    /// `tokens` (so a detected window of `tokens` is no tighter).
    pub(super) fn learned_window_at_least(&self, tokens: usize) -> bool {
        self.learned_window.is_none_or(|learned| learned >= tokens)
    }

    /// The combined prompt + output window from the model's advertised total
    /// and the learned cap, taking the tighter of the two when both exist.
    pub(super) fn combined_window(&self, advertised_total: Option<usize>) -> Option<usize> {
        match (advertised_total, self.learned_window) {
            (Some(advertised), Some(learned)) => Some(advertised.min(learned)),
            (Some(advertised), None) => Some(advertised),
            (None, Some(learned)) => Some(learned),
            (None, None) => None,
        }
    }

    /// Clamp `base` to the output-token cap learned from an output-limit
    /// rejection (an observed hard ceiling for this model, issue #114).
    pub(super) fn cap_output(&self, base: i64) -> i64 {
        match self.learned_max_output {
            Some(cap) => base.min(cap as i64),
            None => base,
        }
    }

    /// The effective context window: the learned cap when it is tighter than
    /// the `known` window, with a source label for the status line.
    pub(super) fn effective_window(&self, known: usize, source: String) -> (usize, String) {
        match self.learned_window {
            Some(learned) if learned < known => (learned, "learned from a context-overflow error".to_string()),
            _ => (known, source),
        }
    }

    /// Learn the real context window from a context-overflow error.
    pub(super) fn learn_window(&mut self, window: usize) {
        self.learned_window = Some(window);
    }

    /// Learn the real output-token cap from an output-limit rejection.
    pub(super) fn learn_max_output(&mut self, cap: usize) {
        self.learned_max_output = Some(cap);
    }

    /// Test-only: set the learned window directly.
    #[cfg(test)]
    pub(super) fn set_learned_window(&mut self, window: usize) {
        self.learned_window = Some(window);
    }

    /// Test-only: set the calibration anchor directly.
    #[cfg(test)]
    pub(super) fn set_calibration(&mut self, len: usize, tokens: usize) {
        self.calibration = Some((len, tokens));
    }

    // --- compaction gating -------------------------------------------------

    /// Whether `tokens` has grown far enough past the post-compaction floor
    /// (by `window / 10`) to be worth auto-compacting again.
    pub(super) fn exceeds_floor(&self, tokens: usize, window: usize) -> bool {
        tokens > self.compact_floor + window / 10
    }

    /// Record the context size right after a compaction as the new floor.
    pub(super) fn set_floor(&mut self, tokens: usize) {
        self.compact_floor = tokens;
    }

    // --- history / replay --------------------------------------------------

    /// Whether a real smart-compaction summary is in context (so the history
    /// tools may be offered).
    pub(super) fn history_available(&self) -> bool {
        self.history_available
    }

    /// Flip the history-tools gate. When a smart summary is now in context the
    /// one-time hint is re-armed; when it is dropped the hint goes with it.
    pub(super) fn set_history_available(&mut self, available: bool) {
        self.history_available = available;
        self.history_hint_pending = available;
    }

    /// Whether the one-time post-compaction history hint is still pending.
    pub(super) fn history_hint_pending(&self) -> bool {
        self.history_hint_pending
    }

    /// Consume the one-time hint (it has been shown, or a history tool ran).
    pub(super) fn clear_history_hint(&mut self) {
        self.history_hint_pending = false;
    }

    /// The stashed pre-compaction turns for `replay_history`.
    pub(super) fn stash(&self) -> Option<&Vec<Message>> {
        self.pre_compaction_transcript.as_ref()
    }

    /// The stashed pre-compaction turns as a slice (`&[]` when none).
    pub(super) fn stash_slice(&self) -> &[Message] {
        self.pre_compaction_transcript.as_deref().unwrap_or(&[])
    }

    /// The replay skip-index of the synthetic restatement of the folded active
    /// input.
    pub(super) fn restated(&self) -> Option<usize> {
        self.pre_compaction_restated
    }

    /// Number of turns in the stash (0 when none).
    pub(super) fn stash_len(&self) -> usize {
        self.pre_compaction_transcript.as_ref().map_or(0, Vec::len)
    }

    /// Whether the stash holds turns a repeated compaction would extend.
    pub(super) fn has_stash(&self) -> bool {
        self.pre_compaction_transcript.as_ref().is_some_and(|p| !p.is_empty())
    }

    /// Replace the replay stash after a conversation replacement. A compaction
    /// stashes its `folded` turns (extending the existing stash in place when
    /// `extends`); any other replacement clears the stash so a later replay
    /// cannot resurrect the previous conversation. `restated` is kept only
    /// alongside a surviving stash — a cleared stash clears it too.
    pub(super) fn replace_stash(&mut self, folded: Option<Vec<Message>>, extends: bool, restated: Option<usize>) {
        self.pre_compaction_transcript = match folded {
            Some(new) if extends => {
                let mut stash = self.pre_compaction_transcript.take().unwrap_or_default();
                stash.extend(new);
                Some(stash)
            }
            other => other.filter(|f| !f.is_empty()),
        };
        self.pre_compaction_restated = self.pre_compaction_transcript.as_ref().and(restated);
    }

    // --- lifecycle ---------------------------------------------------------

    /// Reset the client-tied state on a model change: the calibration anchor
    /// and learned caps are for the old model, and the compaction floor resets
    /// so the new model's context is measured afresh.
    pub(super) fn reset_for_model_change(&mut self) {
        self.calibration = None;
        self.learned_window = None;
        self.learned_max_output = None;
        self.compact_floor = 0;
    }

    /// Reset for a freshly created session: no calibration, no compaction
    /// behind it, no history tools and no replay stash.
    pub(super) fn reset_for_new_session(&mut self) {
        self.calibration = None;
        self.compact_floor = 0;
        self.history_available = false;
        self.history_hint_pending = false;
        self.pre_compaction_transcript = None;
        self.pre_compaction_restated = None;
    }

    /// Restore the durable compaction/history state from a loaded session log.
    /// The history-tools gate comes from the last replace's mode (not message
    /// text); the hint stays one-time per compaction (a resume does not
    /// re-append it); the replay stash is rebuilt from the folded turns the
    /// compaction persisted.
    pub(super) fn restore_from(
        &mut self,
        history_available: bool,
        history_hint_consumed: bool,
        folded: Option<Vec<Message>>,
        restated: Option<usize>,
    ) {
        self.calibration = None;
        self.compact_floor = 0;
        self.history_available = history_available;
        self.history_hint_pending = history_available && !history_hint_consumed;
        self.pre_compaction_transcript = folded;
        self.pre_compaction_restated = restated;
    }
}
