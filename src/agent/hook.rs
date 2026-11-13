//! Claude Code-compatible external-hook session state (issue #116, extraction 4).
//!
//! `Agent` delegates every interaction with the user's Claude Code hooks to
//! [`HookState`]: the loaded [`HookManager`] plus the per-session bookkeeping
//! that decides *when* each hook fires — whether `SessionStart` has run for the
//! active session, the `SessionStart` context cached across a rejected first
//! prompt, whether the session was resumed (so `SessionStart` reports
//! `source: "resume"`), and the per-turn cap on `Stop`-hook blocks.
//!
//! Invariants owned here:
//! - `SessionStart` runs **once per session** and may have side effects, so its
//!   context is cached ([`HookState::run_session_start`] /
//!   [`HookState::take_session_start_context`]) and delivered with the first
//!   *accepted* prompt rather than re-running the hook after a
//!   `UserPromptSubmit` rejection.
//! - `Stop`-hook blocks are capped per turn ([`MAX_STOP_BLOCKS`]) so a hook that
//!   always blocks cannot trap the turn loop; the counter resets each turn
//!   ([`HookState::begin_turn`]).

use crate::claude_hooks::{self, HookManager};
use crate::mode::AgentMode;

pub(super) use claude_hooks::MAX_STOP_BLOCKS;

/// Result of the `SessionStart`/`UserPromptSubmit` hooks for a fresh prompt.
pub(super) enum ClaudePromptHook {
    /// Proceed, attaching any additional context to the prompt.
    Proceed(Option<String>),
    /// Reject the prompt with this reason.
    Reject(String),
}

/// The loaded hook manager and the per-session/per-turn state that drives it.
#[derive(Default)]
pub(super) struct HookState {
    /// Claude Code-compatible user hooks (see `claude_hooks.rs`); `None` until
    /// loaded (headless/test agents may never load them).
    hooks: Option<HookManager>,
    /// Whether the `SessionStart` hooks have run for the active session.
    session_started: bool,
    /// `SessionStart` context that has been collected but not yet delivered to
    /// the model. `SessionStart` runs once per session and may have side
    /// effects, so its context must survive a `UserPromptSubmit` rejection of
    /// the first prompt: it is cached here and delivered with the first
    /// *accepted* prompt (or the resumed turn) rather than re-running the hook.
    pending_session_start_context: Option<String>,
    /// Whether the active session was resumed (loaded) rather than created new,
    /// so `SessionStart` reports `source: "resume"` instead of `"startup"`.
    session_resumed: bool,
    /// Number of times a `Stop` hook has blocked the turn end this turn, capped
    /// to avoid loops.
    stop_blocks: u32,
}

impl HookState {
    /// Install a freshly loaded hook manager and reset the per-session flags so
    /// the new configuration's `SessionStart` runs afresh.
    pub(super) fn install(&mut self, manager: HookManager) {
        self.hooks = Some(manager);
        self.session_started = false;
        self.pending_session_start_context = None;
    }

    pub(super) fn manager(&self) -> Option<&HookManager> {
        self.hooks.as_ref()
    }

    /// One-line startup notice for project hooks, printed by the CLI/ACP once
    /// the agent is built. `None` when there is nothing to report.
    pub(super) fn notice(&self) -> Option<String> {
        self.hooks.as_ref().and_then(|h| h.startup_notice())
    }

    /// `/hooks`: every loaded hook with its source, then every skipped hook.
    pub(super) fn listing(&self) -> String {
        match &self.hooks {
            Some(hooks) => hooks.listing(),
            None => "No hooks loaded.\n".to_string(),
        }
    }

    /// Push the active session's identity into the hook manager so every hook
    /// receives the correct `session_id`, `transcript_path` and
    /// `permission_mode`.
    pub(super) fn sync_session(
        &mut self,
        session_id: &str,
        transcript_path: Option<&std::path::Path>,
        mode: &AgentMode,
    ) {
        let mode = match mode {
            AgentMode::Plan => "plan",
            _ => "default",
        };
        if let Some(hooks) = &mut self.hooks {
            hooks.set_session(session_id, transcript_path, mode);
        }
    }

    /// Run the once-per-session `SessionStart` hooks if they have not run yet.
    /// Any context is cached in `pending_session_start_context` (not returned)
    /// so it survives a `UserPromptSubmit` rejection of the first prompt:
    /// `SessionStart` runs once and may have side effects, so its context must
    /// not be re-collected by re-running the hook. Separate from
    /// `UserPromptSubmit` so the resume path (which must not re-validate an
    /// already-accepted prompt) can still deliver `SessionStart` context when a
    /// restored session continues.
    pub(super) fn ensure_session_start(&mut self) {
        if self.hooks.is_none() || self.session_started {
            return;
        }
        self.session_started = true;
        let trigger = if self.session_resumed { "resume" } else { "startup" };
        let outcome = self.hooks.as_ref().expect("checked above").run_session_start(trigger);
        if let Some(ctx) = outcome.context_block() {
            // Prepend to anything already cached (there should not be, but do
            // not drop context if the hook somehow produced it twice).
            let cached = self.pending_session_start_context.take();
            self.pending_session_start_context = Some(match cached {
                Some(existing) if !existing.is_empty() => format!("{existing}\n\n{ctx}"),
                _ => ctx,
            });
        }
    }

    /// Drain any cached `SessionStart` context for delivery to the model.
    pub(super) fn take_session_start_context(&mut self) -> Option<String> {
        self.pending_session_start_context.take()
    }

    /// Run the `SessionStart` (once per session) and `UserPromptSubmit` hooks
    /// for a fresh prompt. Returns either any additional context to attach to
    /// the prompt, or a rejection reason.
    pub(super) fn run_prompt_hooks(&mut self, user_input: &str) -> ClaudePromptHook {
        if self.hooks.is_none() {
            return ClaudePromptHook::Proceed(None);
        }
        self.ensure_session_start();
        let outcome = self.hooks.as_ref().expect("checked above").run_user_prompt_submit(user_input);
        if outcome.blocked {
            // The prompt is rejected, so its context is not delivered — but the
            // SessionStart context collected above must NOT be discarded with
            // it. `session_started` is already true, so leaving it cached in
            // `pending_session_start_context` delivers it with the first
            // accepted prompt instead of losing it (or re-running the hook).
            return ClaudePromptHook::Reject(outcome.block_reason.unwrap_or_default());
        }
        let mut contexts = Vec::new();
        // The prompt was accepted: deliver any cached SessionStart context now.
        if let Some(ctx) = self.take_session_start_context() {
            contexts.push(ctx);
        }
        if let Some(ctx) = outcome.context_block() {
            contexts.push(ctx);
        }
        if contexts.is_empty() {
            ClaudePromptHook::Proceed(None)
        } else {
            ClaudePromptHook::Proceed(Some(contexts.join("\n\n")))
        }
    }

    /// Run the `Stop` hooks when the turn is about to end. Returns a reason to
    /// keep the agent going, or `None` to let the turn end. Blocks are capped
    /// per turn to avoid loops.
    pub(super) fn run_stop_hooks(&mut self) -> Option<String> {
        if self.hooks.is_none() || self.stop_blocks >= MAX_STOP_BLOCKS {
            return None;
        }
        let active = self.stop_blocks > 0;
        let outcome = self.hooks.as_ref().expect("checked above").run_stop(active);
        if outcome.blocked {
            self.stop_blocks += 1;
            Some(
                outcome
                    .block_reason
                    .filter(|r| !r.trim().is_empty())
                    .unwrap_or_else(|| "A Stop hook asked the agent to keep going.".to_string()),
            )
        } else {
            None
        }
    }

    /// Reset the per-turn `Stop`-hook block counter at the start of a turn.
    pub(super) fn begin_turn(&mut self) {
        self.stop_blocks = 0;
    }

    /// Reset the per-session flags for a freshly created session: `SessionStart`
    /// has not run, no context is cached, and the session is new (not resumed).
    pub(super) fn reset_fresh(&mut self) {
        self.session_started = false;
        self.pending_session_start_context = None;
        self.session_resumed = false;
    }

    /// Reset the per-session flags for a resumed (loaded) session: like
    /// [`HookState::reset_fresh`], but `SessionStart` reports
    /// `source: "resume"`.
    pub(super) fn reset_resumed(&mut self) {
        self.session_started = false;
        self.pending_session_start_context = None;
        self.session_resumed = true;
    }
}
