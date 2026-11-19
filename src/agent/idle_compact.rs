//! Idle-compaction gate (issue #182).
//!
//! Auto-compaction is a *rescue*: it fires mid-turn when the next request
//! would not fit. Idle compaction runs that same compaction earlier, at the
//! idle prompt, so the user's next message does not pay for it. The *when*
//! changes; the *how* (`compact_logged` with the configured mode) does not.
//!
//! This struct owns the rule "once per crossing": after an idle attempt that
//! did not compact (cancelled, nothing to fold, or an error), the gate stays
//! shut until the context has grown by real headroom again (the same
//! `window / 10` hysteresis `over_threshold` uses against `compact_floor`).
//! A successful compaction of *any* trigger re-arms it, because from then on
//! `compact_floor` itself keeps a compacted-but-still-large context from
//! being re-summarized until it climbs again.
//!
//! The issue asks for this to live with the compaction state extracted by
//! #116. Only the probe extraction of #116 has landed, so the gate is kept
//! as its own small struct here and composed into `Agent`; it can move into
//! that compaction state unchanged when the extraction lands.

/// Whether an idle compaction may be attempted, given the context size.
#[derive(Debug, Default, Clone)]
pub(super) struct IdleCompactGate {
    /// Context size at the last idle attempt that did not compact. `None`
    /// when the gate is armed.
    spent_at: Option<usize>,
}

impl IdleCompactGate {
    /// Whether the gate is open for a context of `tokens` in `window`. The
    /// caller still checks the threshold; this only enforces once-per-crossing.
    pub(super) fn armed(&self, tokens: usize, window: usize) -> bool {
        self.spent_at.is_none_or(|spent| tokens > spent + window / 10)
    }

    /// Record an idle attempt that did not compact at `tokens`.
    pub(super) fn spend(&mut self, tokens: usize) {
        self.spent_at = Some(tokens);
    }

    /// Re-arm after any compaction or a context reset.
    pub(super) fn reset(&mut self) {
        self.spent_at = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn armed_until_spent_then_only_after_real_growth() {
        let mut gate = IdleCompactGate::default();
        assert!(gate.armed(90_000, 100_000), "a fresh gate is armed");
        gate.spend(90_000);
        assert!(!gate.armed(90_000, 100_000), "a spent gate does not retry at the same size");
        assert!(!gate.armed(100_000, 100_000), "nor after growth inside the hysteresis band");
        assert!(gate.armed(100_001, 100_000), "a new crossing re-arms it");
        gate.reset();
        assert!(gate.armed(1, 100_000), "a compaction or reset re-arms it");
    }
}
