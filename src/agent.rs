use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::Utc;
use serde_json::{Value, json};

use crate::claude_hooks;
use crate::config::{CompactionMode, Config};
use crate::context::{self, Activity, SharedStats};
use crate::goal::{self, Outcome};
use crate::history;
use crate::hooks::{HookContext, HookEvent, HookRegistry};
use crate::instructions::ProjectInstructions;
use crate::llm::{
    ChatRequest, ContextCap, DetectedWindow, LLMClient, LLMResponse, Message, Role, StreamEvent, ToolCall,
};
use crate::memory;
use crate::output;
use crate::permissions::Policy;
use crate::plan::{self, Plan};
use crate::providers;
use crate::reminders::{self, Reminders};
use crate::session::{self, PendingInput, Record, SessionLog};
use crate::skills::{self, Skills};
use crate::tools::ToolRegistry;

const INTERRUPTED_TOOL_RESULT: &str =
    "Error: the harness stopped before this tool call completed; its outcome is unknown.";
const CANCELLED_TOOL_RESULT: &str = "Error: the turn was cancelled before this tool call ran.";
pub const CANCELLED_RESPONSE: &str = "[turn cancelled]";

/// Output room `request_max_tokens()` tries to keep free within the context
/// window, and the reservation `over_threshold()` compacts against. It is a
/// target, not a floor: when fewer tokens actually remain and pre-send
/// compaction is unavailable (`auto_compact` disabled) or suppressed by the
/// `compact_floor` guard, a request is capped to the real room and can go below
/// this — staying valid and inside the window matters more than holding the
/// reserve.
const MIN_OUTPUT_RESERVE: usize = 4096;

/// Tokens kept free beyond prompt + output: the prompt estimate can undercount.
fn output_margin(window: usize) -> usize {
    window / 50
}

/// Accumulates streamed output to estimate a live output rate (completion
/// tokens per second), throttled so the status line does not redraw on every
/// delta. Tokens are estimated from streamed bytes (~4 bytes/token) and
/// reconciled against exact usage at turn end.
struct RateMeter {
    /// When this generation's LLM call began, captured before the request is
    /// sent. Used as the `finish` denominator ONLY for a whole-response burst —
    /// which hands the entire body over in a single delta at completion,
    /// leaving no delta span to divide by — so a one-shot response still
    /// reports the issue's `usage / elapsed` average over the real call
    /// duration instead of a near-zero span.
    generation_start: Instant,
    /// When the first non-empty output delta arrived. The live per-delta rate
    /// and the periodic refresh both divide by elapsed since this instant (not
    /// `generation_start`) so idle time-to-first-token — and any empty thinking
    /// deltas before it — does not depress the displayed rate, and so a paused
    /// stream decays smoothly and continuously with the live rate. `None` until
    /// the first real output byte.
    first_token_at: Option<Instant>,
    /// When the most recent non-empty delta arrived. Compared with
    /// `first_token_at` only to tell a genuine multi-delta stream (deltas that
    /// spanned at least `MULTI_DELTA_SPAN` → divide by the first-token elapsed)
    /// from a burst — a single delta, or the back-to-back thinking+text
    /// callbacks of a one-shot `report_whole` (no real span → fall back to
    /// `generation_start`). It selects the denominator; it never suppresses the
    /// rate.
    last_token_at: Option<Instant>,
    /// Total output bytes streamed so far this turn.
    bytes: usize,
    /// When the rate was last published, for throttling.
    last_emit: Option<Instant>,
}

impl Default for RateMeter {
    fn default() -> Self {
        Self::new(Instant::now())
    }
}

impl RateMeter {
    /// Minimum spacing between rate updates (~4 Hz) to avoid flicker/overhead.
    const THROTTLE: Duration = Duration::from_millis(250);

    /// Minimum span between the first and most recent delta for output to count
    /// as a genuine incremental stream (`finish` then divides by the first-token
    /// elapsed). Below it — including the two back-to-back callbacks
    /// `report_whole` emits for a one-shot response's thinking and text — there
    /// is effectively no delta span, so `finish` falls back to the whole-call
    /// `generation_start` denominator instead of dividing by microseconds. This
    /// only selects the denominator; it never suppresses the rate.
    const MULTI_DELTA_SPAN: Duration = Duration::from_millis(250);

    /// Create a meter whose generation clock starts at `generation_start` —
    /// the moment the LLM call is issued, so `finish` can report throughput
    /// over the whole call even when output arrives as a single burst.
    fn new(generation_start: Instant) -> Self {
        Self { generation_start, first_token_at: None, last_token_at: None, bytes: 0, last_emit: None }
    }

    /// Record `bytes` of streamed output produced at `now`. Returns the current
    /// live rate (tokens/sec) once the deltas have spanned `MULTI_DELTA_SPAN`
    /// and the throttle allows a refresh, otherwise `None` (first token, a
    /// sub-span burst such as `report_whole`'s back-to-back thinking+text
    /// callbacks, or throttled). The live rate divides by elapsed since the
    /// FIRST token so pre-output idle does not dilute it, and the span gate
    /// keeps a one-shot burst from momentarily publishing a microsecond-based
    /// near-infinite value; `finish` handles the one-shot average.
    fn record(&mut self, bytes: usize, now: Instant) -> Option<f64> {
        // Ignore zero-byte deltas: some producers emit empty text/thinking
        // deltas, and starting the clock on one would depress the later rate
        // even though no output has arrived yet.
        if bytes == 0 {
            return None;
        }
        let start = *self.first_token_at.get_or_insert(now);
        self.last_token_at = Some(now);
        self.bytes += bytes;
        let elapsed = now.duration_since(start).as_secs_f64();
        // Stay silent until the deltas have spanned a meaningful interval, so a
        // burst delivered in back-to-back callbacks does not publish a rate
        // computed over mere microseconds.
        if now.duration_since(start) < Self::MULTI_DELTA_SPAN {
            return None;
        }
        let due = self.last_emit.is_none_or(|t| now.duration_since(t) >= Self::THROTTLE);
        if !due {
            return None;
        }
        self.last_emit = Some(now);
        Some(self.bytes.div_ceil(4) as f64 / elapsed)
    }

    /// Re-sample the live rate for the periodic status-bar refresh, ignoring
    /// the throttle. Divides the streamed-byte estimate by elapsed since the
    /// FIRST token — the same denominator as the live `record` rate — so a
    /// pause or hung endpoint decays the displayed value smoothly and
    /// continuously as elapsed grows, rather than jumping. Returns `None`
    /// before the first output delta or if no measurable time has elapsed.
    fn sample(&self, now: Instant) -> Option<f64> {
        let start = self.first_token_at?;
        let elapsed = now.duration_since(start).as_secs_f64();
        if elapsed <= 0.0 {
            return None;
        }
        Some(self.bytes.div_ceil(4) as f64 / elapsed)
    }

    /// Compute the final rate at turn end using the exact completion-token
    /// count when known, otherwise the streamed-byte estimate. A genuine
    /// multi-delta stream (its deltas spanned time) divides by elapsed since
    /// the first token, continuous with the live rate; a single-delta burst
    /// (`report_whole`, or a `stream = true` provider that returns one
    /// plain-JSON body) has no delta span, so it falls back to elapsed since
    /// `generation_start` — the whole-call `usage / elapsed` average — instead
    /// of dividing by the microseconds it took to hand the body over. Returns
    /// `None` when no output delta was streamed (nothing to measure) or no
    /// measurable time elapsed.
    fn finish(&self, tokens: Option<u64>, now: Instant) -> Option<f64> {
        let first = self.first_token_at?;
        // A stream whose deltas spanned a meaningful interval divides by the
        // first-token elapsed; a burst — a single delta, or the back-to-back
        // thinking+text callbacks of a one-shot `report_whole` — has no real
        // span and falls back to the whole-call duration.
        let start = match self.last_token_at {
            Some(last) if last.duration_since(first) >= Self::MULTI_DELTA_SPAN => first,
            _ => self.generation_start,
        };
        let elapsed = now.duration_since(start).as_secs_f64();
        if elapsed <= 0.0 {
            return None;
        }
        let tokens = tokens.map_or_else(|| self.bytes.div_ceil(4) as f64, |t| t as f64);
        Some(tokens / elapsed)
    }
}

/// A steering message sent while a turn is running. `tag` identifies the
/// request that carried it (e.g. the ACP request ID) so it can be answered.
#[derive(Debug, Clone)]
pub struct Steer {
    pub text: String,
    pub tag: Option<Value>,
}

/// Why a turn ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopReason {
    EndTurn,
    Cancelled,
    MaxTurnRequests,
}

impl StopReason {
    /// ACP `stopReason` value.
    pub fn as_acp(self) -> &'static str {
        match self {
            StopReason::EndTurn => "end_turn",
            StopReason::Cancelled => "cancelled",
            StopReason::MaxTurnRequests => "max_turn_requests",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TurnOutcome {
    pub response: String,
    pub stop_reason: StopReason,
    /// Reported by the model with `report_outcome`.
    pub outcome: Option<Outcome>,
}

struct ControlInner {
    steers: Mutex<VecDeque<Steer>>,
    absorbed: Mutex<Vec<Steer>>,
    cancelled: Arc<AtomicBool>,
    cancel_tx: tokio::sync::watch::Sender<bool>,
    mode: Mutex<crate::mode::AgentMode>,
    /// `/thinking LEVEL` for this session; wins over the config. Shared so a
    /// level set mid-turn applies from the agent's next model call.
    thinking: Mutex<Option<crate::thinking::Thinking>>,
}

/// Steering and cancellation for the running turn. Cheap to clone and safe to
/// use from another task while the agent is busy.
#[derive(Clone)]
pub struct TurnControl {
    inner: Arc<ControlInner>,
}

impl Default for TurnControl {
    fn default() -> Self {
        Self {
            inner: Arc::new(ControlInner {
                steers: Mutex::new(VecDeque::new()),
                absorbed: Mutex::new(Vec::new()),
                cancelled: Arc::new(AtomicBool::new(false)),
                cancel_tx: tokio::sync::watch::channel(false).0,
                mode: Mutex::new(crate::mode::AgentMode::default()),
                thinking: Mutex::new(None),
            }),
        }
    }
}

impl TurnControl {
    /// Queue a message for the running turn; it is added before the next model call.
    pub fn steer(&self, text: &str, tag: Option<Value>) {
        self.inner.steers.lock().unwrap().push_back(Steer { text: text.to_string(), tag });
    }

    pub fn has_steers(&self) -> bool {
        !self.inner.steers.lock().unwrap().is_empty()
    }

    /// Steers not yet added to the conversation.
    pub fn take_pending(&self) -> Vec<Steer> {
        self.inner.steers.lock().unwrap().drain(..).collect()
    }

    /// Steers added to the conversation since the last call.
    pub fn take_absorbed(&self) -> Vec<Steer> {
        std::mem::take(&mut *self.inner.absorbed.lock().unwrap())
    }

    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::SeqCst);
        self.inner.cancel_tx.send_replace(true);
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::SeqCst)
    }

    /// The current operating mode (normal/plan/auto).
    pub fn mode(&self) -> crate::mode::AgentMode {
        *self.inner.mode.lock().unwrap()
    }

    pub fn set_mode(&self, mode: crate::mode::AgentMode) {
        *self.inner.mode.lock().unwrap() = mode;
    }

    /// The session's `/thinking` level, if one is set.
    pub fn thinking(&self) -> Option<crate::thinking::Thinking> {
        self.inner.thinking.lock().unwrap().clone()
    }

    /// Set (or with `None`, clear) the session's `/thinking` level. A running
    /// turn sends it from its next model call.
    pub fn set_thinking(&self, thinking: Option<crate::thinking::Thinking>) {
        *self.inner.thinking.lock().unwrap() = thinking;
    }

    /// Advance to the next mode in the Shift+Tab cycle; returns it.
    pub fn cycle_mode(&self) -> crate::mode::AgentMode {
        let mut mode = self.inner.mode.lock().unwrap();
        *mode = mode.next();
        *mode
    }

    /// Flag for synchronous tools (e.g. bash) to poll.
    pub fn cancel_flag(&self) -> Arc<AtomicBool> {
        self.inner.cancelled.clone()
    }

    /// Resolves once `cancel` has been called.
    pub async fn cancelled(&self) {
        let mut rx = self.inner.cancel_tx.subscribe();
        let _ = rx.wait_for(|cancelled| *cancelled).await;
    }

    fn start_turn(&self) {
        self.inner.cancelled.store(false, Ordering::SeqCst);
        self.inner.cancel_tx.send_replace(false);
        self.inner.absorbed.lock().unwrap().clear();
    }
}

/// Live progress of a turn, for streaming to a client (ACP `session/update`).
#[derive(Debug)]
pub enum AgentEvent<'a> {
    /// Emitted when replaying history and for steer/queued messages absorbed
    /// mid-turn.
    UserMessage {
        text: &'a str,
    },
    AssistantMessage {
        message_id: &'a str,
        text: &'a str,
    },
    /// Streamed piece of the assistant's answer (only when streaming).
    TextDelta {
        text: &'a str,
    },
    /// Streamed piece of the model's reasoning (only when streaming).
    ThinkingDelta {
        text: &'a str,
    },
    /// The model's complete reasoning for one response, emitted before the
    /// response's `AssistantMessage`.
    Thinking {
        text: &'a str,
    },
    ToolCall {
        call: &'a ToolCall,
    },
    ToolResult {
        call: &'a ToolCall,
        ok: bool,
        output: &'a str,
    },
    /// Context statistics or activity changed (see `Agent::context_stats`).
    Context,
    /// The conversation was compacted.
    Compacted,
    /// The task plan changed (or is being replayed).
    Plan {
        plan: &'a Plan,
    },
}

/// Result of a compaction.
#[derive(Debug, Clone, PartialEq)]
pub struct CompactReport {
    pub messages_before: usize,
    pub messages_after: usize,
    pub tokens_before: usize,
    pub tokens_after: usize,
    /// Messages folded into the summary (or dropped, if summarizing failed).
    pub summarized: usize,
    /// Why summarizing failed, when messages were dropped instead.
    pub fallback: Option<String>,
    /// The summary hit the output limit and is incomplete.
    pub truncated: bool,
    /// The mode the compaction ran in.
    pub mode: CompactionMode,
}

impl std::fmt::Display for CompactReport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}compacted {} messages: ~{} -> ~{} tokens ({} -> {} messages)",
            if self.mode == CompactionMode::Smart { "smart-" } else { "" },
            self.summarized,
            context::format_tokens(self.tokens_before),
            context::format_tokens(self.tokens_after),
            self.messages_before,
            self.messages_after
        )?;
        if let Some(reason) = &self.fallback {
            write!(f, "; summary failed ({reason}), older messages were dropped")?;
        } else if self.truncated {
            write!(f, "; the summary hit the output limit and is incomplete")?;
        }
        Ok(())
    }
}

/// Why compaction was requested.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CompactTrigger {
    Manual,
    Threshold,
    Overflow,
}

/// What a compaction folded away, handed to `replace_keeping_pending` so the
/// durable `Record::Replace` keeps the log-line range and mode while the real
/// pre-compaction turns are stashed for `replay_history` to restore on a
/// legacy → frame switch (which otherwise replays only the synthetic summary).
struct CompactionRecord {
    /// First and last log line folded into the summary.
    range: Option<(u64, u64)>,
    mode: CompactionMode,
    /// The folded messages (the real pre-compaction turns), in order.
    folded: Vec<Message>,
    /// Index, in the new (compacted) conversation, of the synthetic
    /// restatement of the active input when it was itself folded into the
    /// summary. `replay_history` skips it so the one submitted prompt is not
    /// shown twice (once from `folded`, once from the restatement).
    restated: Option<usize>,
}

/// Receives events with the active session ID.
pub type EventSink = Box<dyn Fn(Option<&str>, &AgentEvent) + Send + Sync>;

/// Result of the `SessionStart`/`UserPromptSubmit` hooks for a fresh prompt.
enum ClaudePromptHook {
    /// Proceed, attaching any additional context to the prompt.
    Proceed(Option<String>),
    /// Reject the prompt with this reason.
    Reject(String),
}

/// The thinking level the status line shows: the one actually sent, if any.
fn status_thinking(thinking: &crate::thinking::Resolved) -> Option<String> {
    match &thinking.effective {
        // An extra_body override sends its own value, not the configured
        // level, so no generated level is shown.
        _ if thinking.overridden => None,
        // `drop_params` strips the generated field after the body is built, so
        // the level never reaches the wire either.
        _ if thinking.dropped => None,
        crate::thinking::Thinking::Default => None,
        level => Some(level.to_string()),
    }
}

/// Agent manages the conversation loop, tool execution, and hooks
pub struct Agent {
    client: Box<dyn LLMClient>,
    tools: ToolRegistry,
    hooks: HookRegistry,
    config: Config,
    conversation: Vec<Message>,
    session: Option<SessionLog>,
    /// Active session ID (also set when persistence is disabled).
    session_id: Option<String>,
    /// Responses for inputs already processed, by input ID (deduplication).
    completed_inputs: HashMap<String, String>,
    /// Outcomes reported by completed inputs, by input ID.
    completed_outcomes: HashMap<String, Outcome>,
    /// An input that was accepted but whose turn never finished (crash, kill, or error).
    pending_input: Option<PendingInput>,
    input_counter: u64,
    event_sink: Option<EventSink>,
    /// Test-only hook fired between a request's thinking snapshot and its
    /// status-line update, to interleave a mid-update `/thinking` change.
    #[cfg(test)]
    after_thinking_snapshot: Option<Box<dyn Fn() + Send + Sync>>,
    message_counter: u64,
    control: TurnControl,
    stats: SharedStats,
    /// Conversation length and exact token count from the last response's
    /// reported usage, used to anchor the context estimate.
    calibration: Option<(usize, usize)>,
    /// Window learned from a context-overflow error (until the model changes).
    learned_window: Option<usize>,
    /// Window reported by the endpoint (see `detect_context_window`).
    detected_window: Option<DetectedWindow>,
    /// Thinking levels reported by the endpoint (see `detect_context_window`).
    reported_thinking: Option<crate::thinking::Reported>,
    /// Vision capability reported by the endpoint (see `detect_context_window`).
    reported_vision: Option<crate::vision::Vision>,
    /// Context size right after the last compaction; auto-compaction waits
    /// for real growth past it so an incompressible context is not
    /// re-summarized on every call.
    compact_floor: usize,
    /// Stream model output as `TextDelta` / `ThinkingDelta` events.
    streaming: bool,
    /// AGENTS.md and similar files for the working directory.
    instructions: Option<ProjectInstructions>,
    /// Skills offered through `load_skill` (see `skills.rs`).
    skills: Skills,
    /// The agent's task plan (see `plan.rs`).
    plan: Plan,
    reminders: Reminders,
    /// Tool results longer than this are cut, with the whole kept on disk.
    tool_output_limit: usize,
    /// Checked before every tool call (see `permissions.rs`).
    policy: Policy,
    /// Claude Code-compatible user hooks (see `claude_hooks.rs`); `None` until
    /// loaded (headless/test agents may never load them).
    claude_hooks: Option<claude_hooks::HookManager>,
    /// Whether the `SessionStart` hooks have run for the active session.
    claude_session_started: bool,
    /// `SessionStart` context that has been collected but not yet delivered to
    /// the model. `SessionStart` runs once per session and may have side
    /// effects, so its context must survive a `UserPromptSubmit` rejection of
    /// the first prompt: it is cached here and delivered with the first
    /// *accepted* prompt (or the resumed turn) rather than re-running the hook.
    pending_session_start_context: Option<String>,
    /// Whether the active session was resumed (loaded) rather than created new,
    /// so `SessionStart` reports `source: "resume"` instead of `"startup"`.
    claude_session_resumed: bool,
    /// Number of times a `Stop` hook has blocked the turn end this turn, capped
    /// to avoid loops.
    claude_stop_blocks: u32,
    /// Rendezvous for the `question` tool: the handler blocks here until the
    /// turn loop answers.
    questions: crate::question::QuestionBroker,
    /// Where truncated tool output is kept whole (per session when persisted);
    /// shared with the bash tool.
    spill_dir: Arc<RwLock<std::path::PathBuf>>,
    /// History-tool calls in the current turn.
    turn_history_calls: u32,
    /// Session-log size when the current turn began; the session-index update
    /// in `finish_turn` folds the input records committed since into the
    /// cached summary (from the log's tail) instead of rescanning the whole
    /// log.
    turn_log_offset: Option<u64>,
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
    /// scrollback, so the replay is the only copy. Kept across replays (every
    /// renderer rebuild needs it), replaced by the next compaction, and
    /// cleared by any non-compaction conversation replacement (a plain rebuild
    /// or system-prompt change) and on a new or resumed session. `None` when
    /// no compaction has run (or none was captured).
    pre_compaction_transcript: Option<Vec<Message>>,
    /// Index, in the compacted conversation, of the synthetic restatement of
    /// the active input the current `pre_compaction_transcript` compaction
    /// folded into its summary (see `CompactionRecord::restated`).
    /// `replay_history` skips it so the prompt is not shown twice. Tracked and
    /// cleared in lockstep with `pre_compaction_transcript`.
    pre_compaction_restated: Option<usize>,
    /// Cross-session memory store, present when `config.memory` is not `off`
    /// (see `memory.rs`). Whether the model may write to it is `config.memory`.
    memory: Option<memory::Store>,
    /// Cached rendered memory index, tagged with the `writable` flag it was
    /// built for. `apply_mode_to_system_prompt` runs at turn start and before
    /// every LLM request, and building the index synchronously reads and parses
    /// both scope files, so without this cache each model iteration would add
    /// filesystem work proportional to the whole store. Invalidated whenever the
    /// store is mutated (save/search/forget) so a change still surfaces
    /// promptly; a `writable` flip (plan-mode toggle) rebuilds once to vary the
    /// save guidance.
    memory_index_cache: Option<(bool, String)>,
    /// Session IDs a title has already been requested for in this process, so
    /// a title is asked for at most once per session per process even as the
    /// agent switches between sessions (A → B → A) before the background task
    /// stores A's title (see `request_title`).
    titles_requested: HashSet<String>,
}

/// System prompt for session titles (`session_titles = true`).
const TITLE_PROMPT: &str = "You name coding-assistant sessions. Reply with a title of at most six words \
that says what the user is working on, from their requests below. Reply with the title only: no quotes, \
no trailing period.";

/// Backstop for the whole capability probe (window + thinking), which is a
/// serial chain of at most [`providers::openai::MAX_PROBE_CHAIN`] requests each
/// already bounded by `providers::openai::PROBE_TIMEOUT`. This outer cap must
/// exceed that serial budget, else it would fire mid-chain and discard a window
/// the first request already detected when an optional follow-up (e.g. the
/// thinking probe) is slow; sized above it, it only trips if a single request
/// ignores its own timeout. The `+ 2s` is scheduling/connection margin.
const DETECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(
    providers::openai::MAX_PROBE_CHAIN as u64 * providers::openai::PROBE_TIMEOUT.as_secs() + 2,
);

impl Agent {
    pub fn new(client: Box<dyn LLMClient>, config: Config) -> Self {
        let conversation = vec![Message { timestamp: Some(session::now()), ..Message::system(&config.system_prompt) }];
        let policy = Policy::new(&config.permissions, &config.sandbox);
        let memory = Self::build_memory(&config);
        Self {
            policy,
            client,
            tools: ToolRegistry::new(),
            hooks: HookRegistry::new(),
            claude_hooks: None,
            claude_session_started: false,
            pending_session_start_context: None,
            claude_session_resumed: false,
            claude_stop_blocks: 0,
            config,
            conversation,
            session: None,
            session_id: None,
            completed_inputs: HashMap::new(),
            completed_outcomes: HashMap::new(),
            pending_input: None,
            input_counter: 0,
            event_sink: None,
            #[cfg(test)]
            after_thinking_snapshot: None,
            message_counter: 0,
            control: TurnControl::default(),
            stats: SharedStats::default(),
            calibration: None,
            learned_window: None,
            detected_window: None,
            reported_thinking: None,
            reported_vision: None,
            compact_floor: 0,
            streaming: false,
            instructions: None,
            skills: Skills::default(),
            plan: Plan::default(),
            reminders: Reminders::default(),
            tool_output_limit: output::DEFAULT_MAX_OUTPUT_LENGTH,
            questions: crate::question::QuestionBroker::new(),
            spill_dir: Arc::new(RwLock::new(output::spill_dir())),
            turn_history_calls: 0,
            turn_log_offset: None,
            history_available: false,
            history_hint_pending: false,
            pre_compaction_transcript: None,
            pre_compaction_restated: None,
            titles_requested: HashSet::new(),
            memory,
            memory_index_cache: None,
        }
    }

    /// Build the memory store from config: `None` when memory is off, else a
    /// store rooted at the configured directory and keyed to the current git
    /// repository (project scope is unavailable outside a repo). Also `None`
    /// when no per-user data directory is available and none was configured:
    /// `memory_dir()` refuses the world-shared system temp fallback, so memory
    /// is disabled rather than persisted to an attacker-reachable location.
    fn build_memory(config: &Config) -> Option<memory::Store> {
        if !config.memory.enabled() {
            return None;
        }
        let dir = config.memory_dir()?;
        let project = std::env::current_dir().ok().and_then(|cwd| memory::project_key(&cwd));
        Some(memory::Store::new(dir, project, config.memory_expiry_days))
    }

    /// Rekey the memory store's project scope from the current working
    /// directory. ACP applies `params.cwd` only *after* the agent is
    /// constructed, so the store — keyed to the launch directory at build time —
    /// must be rebuilt once a session's cwd is known, or ACP sessions read the
    /// wrong repository's project memories. A no-op for the CLI, where the cwd
    /// never changes.
    fn rekey_memory(&mut self) {
        if self.memory.is_some() {
            self.memory = Self::build_memory(&self.config);
            self.memory_index_cache = None;
        }
    }

    /// Whether the memory tools are offered at all.
    fn memory_enabled(&self) -> bool {
        self.config.memory.enabled() && self.memory.is_some()
    }

    pub fn memory(&self) -> Option<&memory::Store> {
        self.memory.as_ref()
    }

    /// Downgrade full memory to read-only (headless/ACP default: no human vets
    /// a save live). A no-op if memory is already read-only or off.
    pub fn restrict_memory_to_read_only(&mut self) {
        if self.config.memory == crate::config::MemoryMode::On {
            self.config.memory = crate::config::MemoryMode::ReadOnly;
        }
    }

    /// Build an agent whose client is resolved from `config.model`.
    pub fn from_config(config: Config) -> Result<Self> {
        let policy = Policy::new(&config.permissions, &config.sandbox);
        if !policy.errors.is_empty() {
            anyhow::bail!("invalid [permissions] rules: {}", policy.errors.join("; "));
        }
        let client = Self::client_for(&config, &config.model)?;
        Ok(Self::new(client, config))
    }

    /// With `session_titles` on, ask the model (`title_model`, else the
    /// session's) for a title in the background, once the session has a
    /// telling prompt and no title yet. Failures are silent: the request is
    /// tried again in a later run.
    fn request_title(&mut self, path: std::path::PathBuf, summary: &crate::session_index::Summary) {
        if !self.config.session_titles || self.titles_requested.contains(&summary.id) || summary.title.is_some() {
            return;
        }
        let Some(source) = crate::session_index::title_source(summary) else { return };
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        // The fallback is the model actually serving this session (the live
        // client's resolved provider/model), not `config.model` re-resolved:
        // a bare or provider-only spec would re-resolve against a provider
        // default a `/settings` visit may have edited without switching the
        // live client (see `settings.rs`), picking a different model.
        let spec = self
            .config
            .title_model
            .clone()
            .unwrap_or_else(|| format!("{}/{}", self.client.provider_name(), self.client.model_name()));
        let config = self.config.clone();
        self.titles_requested.insert(summary.id.clone());
        runtime.spawn(async move {
            // Client setup can run a configured `api_key_command` via a
            // blocking `Command::output`, so it belongs off the turn path:
            // build it inside the task, on the blocking pool.
            let Ok(client) = tokio::task::spawn_blocking(move || Self::client_for(&config, &spec))
                .await
                .unwrap_or_else(|join| Err(anyhow::anyhow!("title client setup: {join}")))
            else {
                return;
            };
            let messages = [Message::system(TITLE_PROMPT), Message::user(&source)];
            // Room for reasoning models that think before answering.
            let request = ChatRequest {
                messages: &messages,
                tools: &[],
                temperature: None,
                max_tokens: Some(400),
                thinking: None,
                vision: None,
                attachments_dir: None,
            };
            let reply = tokio::time::timeout(Duration::from_secs(60), client.chat(&request)).await;
            if let Ok(Ok(response)) = reply
                && let Some(title) = crate::session_index::clean_title(&response.content)
                && let Ok(false) = crate::session_index::set_title(&path, &title)
            {
                // Another process titled the session first; keep that one.
            }
        });
    }

    fn client_for(config: &Config, spec: &str) -> Result<Box<dyn LLMClient>> {
        let (providers, default_provider) = config.effective_providers();
        providers::build_client(spec, &providers, &default_provider)
    }

    pub fn tools(&self) -> &ToolRegistry {
        &self.tools
    }

    pub fn hooks(&self) -> &HookRegistry {
        &self.hooks
    }

    /// Load the Claude Code-compatible user hooks for `cwd` from every source
    /// (project `.claude/settings.json`, the user's `~/.claude/settings.json`
    /// and nano's own `[hooks]`), honoring the `disable_*` config flags.
    pub fn load_claude_hooks(&mut self, cwd: &std::path::Path) {
        let opts = claude_hooks::LoadOptions {
            disable_hooks: self.config.disable_hooks,
            disable_project_hooks: self.config.disable_project_hooks,
            claude_user_hooks: self.config.claude_user_hooks,
            nano_hooks: &self.config.hooks,
            sandbox: self.config.sandbox.clone(),
        };
        let manager = claude_hooks::HookManager::load(&opts, cwd);
        self.claude_hooks = Some(manager);
        self.claude_session_started = false;
        self.pending_session_start_context = None;
        self.sync_claude_hook_session();
    }

    /// One-line startup notice for project hooks, printed by the CLI/ACP once
    /// the agent is built. `None` when there is nothing to report.
    pub fn claude_hooks_notice(&self) -> Option<String> {
        self.claude_hooks.as_ref().and_then(|h| h.startup_notice())
    }

    /// `/hooks`: every loaded hook with its source, then every skipped hook.
    pub fn claude_hooks_listing(&self) -> String {
        match &self.claude_hooks {
            Some(hooks) => hooks.listing(),
            None => "No hooks loaded.\n".to_string(),
        }
    }

    /// Push the active session's identity into the hook manager so every hook
    /// receives the correct `session_id`, `transcript_path` and
    /// `permission_mode`.
    fn sync_claude_hook_session(&mut self) {
        let id = self.session_id.clone().unwrap_or_default();
        let transcript = self.session.as_ref().map(|log| log.path().to_path_buf());
        let mode = match self.control.mode() {
            crate::mode::AgentMode::Plan => "plan",
            _ => "default",
        };
        if let Some(hooks) = &mut self.claude_hooks {
            hooks.set_session(&id, transcript.as_deref(), mode);
        }
    }

    /// Record which hook configuration files were loaded (path, source and a
    /// content hash) in the session log, so the transcript establishes what
    /// hook config applied even after exit — the audit trail issue #92
    /// requires. Best-effort: an audit-append failure never fails session
    /// setup, and a session without a log (headless/no-persist) is a no-op.
    fn persist_claude_hook_config(&mut self) {
        let files: Vec<session::HookFile> = match &self.claude_hooks {
            Some(hooks) => hooks
                .files
                .iter()
                .map(|file| session::HookFile {
                    path: file.path.display().to_string(),
                    source: file.source.label().to_string(),
                    hash: file.hash.clone(),
                })
                .collect(),
            None => return,
        };
        if files.is_empty() {
            return;
        }
        if let Some(log) = &mut self.session {
            let _ = log.append(&Record::Hooks { files, recorded_at: session::now() });
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
    fn run_claude_session_start(&mut self) {
        if self.claude_hooks.is_none() || self.claude_session_started {
            return;
        }
        self.claude_session_started = true;
        let trigger = if self.claude_session_resumed { "resume" } else { "startup" };
        let outcome = self.claude_hooks.as_ref().expect("checked above").run_session_start(trigger);
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
    fn take_session_start_context(&mut self) -> Option<String> {
        self.pending_session_start_context.take()
    }

    /// Run the `SessionStart` (once per session) and `UserPromptSubmit` hooks
    /// for a fresh prompt. Returns either any additional context to attach to
    /// the prompt, or a rejection reason.
    fn run_claude_prompt_hooks(&mut self, user_input: &str) -> ClaudePromptHook {
        if self.claude_hooks.is_none() {
            return ClaudePromptHook::Proceed(None);
        }
        self.run_claude_session_start();
        let outcome = self.claude_hooks.as_ref().expect("checked above").run_user_prompt_submit(user_input);
        if outcome.blocked {
            // The prompt is rejected, so its context is not delivered — but the
            // SessionStart context collected above must NOT be discarded with
            // it. `claude_session_started` is already true, so leaving it cached
            // in `pending_session_start_context` delivers it with the first
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
    fn run_claude_stop_hooks(&mut self) -> Option<String> {
        if self.claude_hooks.is_none() || self.claude_stop_blocks >= claude_hooks::MAX_STOP_BLOCKS {
            return None;
        }
        let active = self.claude_stop_blocks > 0;
        let outcome = self.claude_hooks.as_ref().expect("checked above").run_stop(active);
        if outcome.blocked {
            self.claude_stop_blocks += 1;
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

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn config_mut(&mut self) -> &mut Config {
        &mut self.config
    }

    pub fn provider_name(&self) -> &str {
        self.client.provider_name()
    }

    pub fn model_name(&self) -> &str {
        self.client.model_name()
    }

    /// The temperature the current model is sent, and where it comes from.
    pub fn temperature(&self) -> crate::temperature::Resolved {
        self.temperature_for(self.thinking().anthropic_thinking_on())
    }

    /// Temperature resolution for a request whose Anthropic thinking state is
    /// `anthropic_thinking_on`. A normal turn passes the live thinking level;
    /// a request that sends no thinking field (e.g. compaction) passes whether
    /// the model still thinks without one (see
    /// [`crate::thinking::Resolved::always_anthropic_thinking`]), so a
    /// configured temperature is dropped only for a model that really thinks.
    /// Fixed-model and `extra_body` rules apply either way.
    fn temperature_for(&self, anthropic_thinking_on: bool) -> crate::temperature::Resolved {
        // Resolve against the live client, not `config.model`: a `/settings`
        // edit to the active provider (e.g. its `default_model`, kept when
        // "Pick a model … now?" is declined) mutates the config without
        // rebuilding the client, and requests still go to the client's model.
        let (user, _default_provider) = self.config.effective_providers();
        let providers = providers::effective_providers(&user);
        let entry = providers.get(self.provider_name()).cloned();
        // The live client's API kind is what governs the request: a `/settings`
        // edit can change the active provider's `kind` while the user declines
        // the model switch, so the client still speaks the old API even though
        // the config now names a new one. A client reporting no kind (a test
        // double imitating no real provider API) gets no kind-specific rule —
        // falling back to the provider entry's kind would apply rules from a
        // mutated config entry to a client that never spoke that API. Clients
        // that need kind-specific rules report their kind explicitly.
        let kind = self.client.kind();
        let provider = entry.unwrap_or_default();
        let resolved = crate::temperature::resolve(self.config.temperature, kind, &provider, self.model_name());
        // Anthropic accepts no custom temperature while the model thinks.
        if anthropic_thinking_on {
            return resolved.fixed_by("thinking is on, and Anthropic then requires the default temperature".into());
        }
        resolved
    }

    /// The thinking, temperature and output-cap settings for one model call,
    /// all derived from a single snapshot of the session's `/thinking` level.
    ///
    /// The level arrives by value: the caller snapshots the shared control
    /// once and this helper never re-reads it, so a `/thinking` typed while
    /// the request is being built cannot make temperature observe a different
    /// level than the one sent. Temperature is derived from the same
    /// resolution the request sends, never a second read that could observe a
    /// different level (see
    /// `request_settings_derives_temperature_from_the_snapshot_not_a_reread`).
    fn request_settings_for(
        &self,
        level: Option<crate::thinking::Thinking>,
    ) -> (crate::thinking::Resolved, crate::temperature::Resolved, i64) {
        let thinking = self.thinking_for(level.as_ref());
        let temperature = self.temperature_for(thinking.anthropic_thinking_on());
        let max_tokens = self.request_max_tokens();
        (thinking, temperature, max_tokens)
    }

    /// The thinking level the current model is sent, and where it comes from.
    /// Resolved against the live client, like [`Agent::temperature`].
    pub fn thinking(&self) -> crate::thinking::Resolved {
        self.thinking_for(self.control.thinking().as_ref())
    }

    /// Thinking resolution for a request carrying `session` as its
    /// session-level `/thinking` setting. Split from [`Agent::thinking`] so a
    /// request resolves its level, temperature and output cap from one
    /// snapshot: re-reading the shared control between them would let a
    /// `/thinking` typed mid-read make temperature observe a different level
    /// than the one sent (see [`Agent::request_settings_for`]).
    fn thinking_for(&self, session: Option<&crate::thinking::Thinking>) -> crate::thinking::Resolved {
        let (user, _default_provider) = self.config.effective_providers();
        let providers = providers::effective_providers(&user);
        let provider = providers.get(self.provider_name()).cloned().unwrap_or_default();
        let mut resolved = crate::thinking::resolve_with(
            &self.config.thinking,
            session,
            self.client.kind(),
            &provider,
            self.model_name(),
            self.reported_thinking.as_ref(),
        );
        // A fixed budget must stay below the output cap. Always check, even
        // when an earlier adjustment already warned: a level fitted down (e.g.
        // `xhigh` → a known level) can still ask for a budget the cap can't
        // fit, and the no-room case must drop the level everywhere — otherwise
        // the Anthropic builder omits thinking while status, ACP, trajectory,
        // and temperature resolution still treat it as active.
        if let Some(crate::thinking::Request::Budget(budget)) = resolved.request() {
            let max_tokens = self.request_max_tokens();
            let feasibility = match crate::thinking::capped_budget(budget, max_tokens) {
                Some(sent) if sent < budget => Some(format!(
                    "max_tokens {max_tokens} caps the {} thinking budget at {sent} of {budget} tokens; \
                     raise max_tokens for the full budget",
                    resolved.effective
                )),
                None => {
                    // No room for any budget: send no level so every surface
                    // agrees thinking is off for this request.
                    resolved.effective = crate::thinking::Thinking::Default;
                    Some(format!("max_tokens {max_tokens} leaves no room for a thinking budget; thinking stays off"))
                }
                _ => None,
            };
            if let Some(extra) = feasibility {
                resolved.warning = Some(match resolved.warning.take() {
                    Some(existing) => format!("{existing}\n{extra}"),
                    None => extra,
                });
            }
        }
        resolved
    }

    /// Set (or with `None`, clear) the thinking level for this session.
    pub fn set_thinking(&mut self, thinking: Option<crate::thinking::Thinking>) {
        self.control.set_thinking(thinking);
        self.refresh_stats();
    }

    /// Switch to another `provider/model`, keeping the conversation.
    /// Atomic: when the new spec cannot build a client (a missing credential,
    /// a failing `api_key_command`, …) the previous model spec is restored so
    /// the config keeps naming the client the session is actually still using.
    /// (An unknown provider prefix is not such a failure — `parse_model_spec`
    /// falls back to the default provider — so it does not trigger this path.)
    pub async fn set_model(&mut self, spec: &str) -> Result<()> {
        let previous = std::mem::replace(&mut self.config.model, spec.to_string());
        if let Err(e) = self.refresh_client().await {
            self.config.model = previous;
            return Err(e);
        }
        Ok(())
    }

    /// Rebuild the LLM client for the current model, resetting the state that
    /// is tied to a client: the context calibration, the window learned from
    /// overflow errors, the window detected from the endpoint, and the
    /// post-compaction floor. Used after a provider edit (which can change the
    /// endpoint, key, or model the current spec resolves to) and on model
    /// switches.
    pub async fn refresh_client(&mut self) -> Result<()> {
        self.client = Self::client_for(&self.config, &self.config.model)?;
        self.calibration = None;
        self.learned_window = None;
        self.detected_window = None;
        self.reported_thinking = None;
        self.compact_floor = 0;
        self.detect_context_window().await;
        Ok(())
    }

    /// Ask the endpoint for the model's context window (unless config sets
    /// it) and the thinking levels it supports. Both are probed together so a
    /// server whose window and thinking detections read the same response
    /// (OpenAI-compatible `/models`, llama.cpp `/props`, Ollama `/api/show`)
    /// is not queried twice serially.
    pub async fn detect_context_window(&mut self) {
        self.detected_window = None;
        if self.configured_window().is_some() {
            // The configured window wins, so the window half of the combined
            // probe is discarded — running it anyway can only hurt: a
            // configured LM Studio provider would make the unnecessary
            // `/api/v0/models` follow-up, adding the full probe timeout at
            // startup/model switches when the endpoint is slow. Probe only
            // the thinking levels (`resolve_with` still consumes their
            // adaptive/format data even when the level list is configured).
            self.detect_thinking().await;
            return;
        }
        let probe = self.client.detect_capabilities();
        let (window, thinking, vision) = tokio::time::timeout(DETECT_TIMEOUT, probe).await.ok().unwrap_or_default();
        self.detected_window = window;
        self.reported_thinking = thinking;
        // Vision is derived from the same probe responses `detect_capabilities`
        // already fetched, so it costs no extra round trip. A configured
        // `vision` override still wins at resolution time (`vision()` ignores
        // this report when an override is set), so storing the report here is
        // harmless even then.
        self.reported_vision = vision;
        self.refresh_stats();
    }

    /// Probe only the thinking levels the endpoint reports, leaving the
    /// (already cleared) detected window alone. Used when the window comes
    /// from config and the window half of the combined probe would be
    /// discarded anyway.
    async fn detect_thinking(&mut self) {
        let probe = self.client.detect_thinking_levels();
        self.reported_thinking = tokio::time::timeout(DETECT_TIMEOUT, probe).await.ok().flatten();
        self.detect_vision().await;
        self.refresh_stats();
    }

    /// Probe the vision capability the endpoint reports, leaving any configured
    /// override to win at resolution time (`vision()`). Used only on the
    /// configured-window path (`detect_thinking`), where the combined
    /// `detect_capabilities` probe is skipped to avoid an unwanted window
    /// follow-up; the default path derives vision from that combined probe
    /// instead of calling this. Skipped when a configured `vision` override
    /// already decides the capability: the probe re-fetches `/models` plus
    /// llama.cpp `/props` or Ollama `/api/show`, so running it for an unused
    /// result adds a serial probe budget on a slow endpoint for nothing.
    async fn detect_vision(&mut self) {
        let (user, _default_provider) = self.config.effective_providers();
        let providers = providers::effective_providers(&user);
        let provider = providers.get(self.provider_name()).cloned().unwrap_or_default();
        let (override_, _source) =
            crate::vision::configured_override(self.config.vision, &provider, self.model_name());
        if override_.is_some() {
            // A configured override wins at resolution time, so the endpoint
            // report would be discarded; leave it unset and skip the probe.
            self.reported_vision = None;
            return;
        }
        let probe = self.client.detect_vision();
        self.reported_vision = tokio::time::timeout(DETECT_TIMEOUT, probe).await.ok().flatten();
    }

    /// The effective vision capability for the current model: a configured
    /// `vision` override wins, else the endpoint report, else the built-in
    /// assumption for current Anthropic / OpenAI families. `None` = the model
    /// cannot view images.
    pub fn vision(&self) -> Option<crate::vision::Vision> {
        let (user, _default_provider) = self.config.effective_providers();
        let providers = providers::effective_providers(&user);
        let provider = providers.get(self.provider_name()).cloned().unwrap_or_default();
        crate::vision::resolve(
            self.config.vision,
            self.client.kind(),
            &provider,
            self.model_name(),
            self.reported_vision.as_ref(),
        )
    }

    /// Capability context appended to a non-image binary-file error: whether
    /// the current model can view images at all. The generic binary error in
    /// `read_file` cannot add this itself, so it is appended at dispatch where
    /// the resolved vision capability is known.
    fn binary_vision_hint(&self) -> String {
        if self.vision().is_some() {
            " (the current model can view images, but this is not a supported image type: \
             PNG, JPEG, GIF or WebP)"
                .to_string()
        } else {
            " (the current model can't view images; switch to a vision model or set `vision = true`)".to_string()
        }
    }

    /// Turn a `read_file` image result (`{"image": {…, path}}`, metadata only)
    /// into the tool-result text and its attachment. The caller gates this on
    /// `tool_call.name == "read_file"`, since only that tool owns this private
    /// `{"image": …}` protocol. Returns `Ok(None)` when `result` is not an
    /// image result. When the model cannot view images, returns `Err` with the
    /// text error (a hint naming the fix). When it can, the file is re-read by
    /// `path`, downscaled to the model's limits, stored under the session's
    /// attachments directory, and returned as `(text, attachments)`.
    fn image_result(&self, result: &Value) -> Result<Option<(String, Vec<crate::llm::Attachment>)>, String> {
        let Some(image) = result.get("image") else { return Ok(None) };
        let path_str = image.get("path").and_then(Value::as_str).unwrap_or_default();
        let path = std::path::PathBuf::from(path_str);
        let Some(vision) = self.vision() else {
            return Err(format!(
                "{} is an image ({}), but the current model can't view images; \
                 switch to a vision model or set `vision = true`",
                path.display(),
                image.get("media_type").and_then(Value::as_str).unwrap_or("unknown type")
            ));
        };
        if path_str.is_empty() {
            return Err("image result had no path".to_string());
        }
        // Re-read the source by path rather than carrying its base64 through the
        // tool result: encoding the whole image into the result (and cloning it
        // for the `AfterToolCall` hook) would cost several times its file size
        // before `prepare` reduces it below the model's limits.
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) => return Err(format!("{}: could not read image: {e}", path.display())),
        };
        let Some(format) = crate::attachment::ImageFormat::sniff(&bytes) else {
            return Err(format!("{}: unrecognised image data", path.display()));
        };
        // Downscale to the model's limits and store the prepared bytes by hash.
        let limits = vision.image_limits();
        let prepared = match crate::attachment::prepare(
            &bytes,
            format,
            limits.max_dimension,
            limits.max_bytes,
            &limits.accepted_media_types,
        ) {
            Ok(prepared) => prepared,
            Err(e) => return Err(format!("{}: could not process image: {e}", path.display())),
        };
        let attachment = crate::llm::Attachment {
            media_type: prepared.media_type,
            path: path.clone(),
            sha256: crate::attachment::sha256_hex(&prepared.bytes),
            width: prepared.width,
            height: prepared.height,
            bytes: prepared.bytes.len(),
            extension: prepared.extension,
        };
        if let Err(e) = crate::attachment::store(&self.attachments_dir(), &attachment, &prepared.bytes) {
            return Err(format!("{}: could not store image: {e}", path.display()));
        }
        let text = format!(
            "{}, {}×{}, {}",
            attachment.media_type,
            attachment.width,
            attachment.height,
            crate::context::format_bytes(attachment.bytes)
        );
        Ok(Some((text, vec![attachment])))
    }

    /// `context_window` from config or the provider entry.
    fn configured_window(&self) -> Option<(usize, &'static str)> {
        let (user, default_provider) = self.config.effective_providers();
        let (configured, _) = providers::context_window(&self.config.model, &user, &default_provider);
        match (self.config.context_window, configured) {
            (Some(window), _) => Some((window, "context_window in config")),
            (None, Some(window)) => Some((window, "provider context_window")),
            (None, None) => None,
        }
    }

    /// Context statistics, updated as the agent works.
    pub fn context_stats(&self) -> SharedStats {
        self.stats.clone()
    }

    /// Context window for the current model: learned from an overflow error,
    /// else `context_window` from config or the provider, the window the
    /// endpoint reports, or one known for the model name.
    pub fn context_window(&self) -> usize {
        self.context_window_with_source().0
    }

    /// Whether the context window caps the whole request (prompt + output) or
    /// only the prompt. Only an endpoint-reported window can be prompt-only
    /// (GitHub Copilot's `max_prompt_tokens`); config, model-name, and learned
    /// windows all describe the total prompt + output budget.
    ///
    /// `Prompt` only while the detected window is the *selected* limit: a lower
    /// window learned from a context-overflow error overrides it in
    /// `context_window_with_source()`, and that learned window is a total cap,
    /// so the output reservation must count against it again.
    fn context_cap(&self) -> ContextCap {
        if self.configured_window().is_none()
            && let Some(detected) = &self.detected_window
            && self.learned_window.is_none_or(|learned| learned >= detected.tokens)
        {
            return detected.cap;
        }
        ContextCap::Total
    }

    /// The combined prompt + output window to enforce alongside a prompt-only
    /// cap: the window the endpoint advertised (`total_tokens`), further
    /// tightened by any window learned from a context-overflow error. A learned
    /// window is a total-request cap, so when it sits below the advertised
    /// combined window it becomes the effective combined limit even while it
    /// stays above the prompt-only `tokens` cap (which keeps `context_cap()`
    /// `Prompt`). Without this, `request_max_tokens()` would size output against
    /// the larger advertised window and overflow again on the sole retry.
    ///
    /// When the endpoint advertised no combined window (`total_tokens` is
    /// `None`, e.g. Copilot reporting only `max_prompt_tokens`), a learned total
    /// window is the *only* combined limit: it is enforced on its own so a retry
    /// is not sized against the prompt-only cap and pushed past the learned
    /// total again.
    fn combined_window(&self) -> Option<usize> {
        let advertised = self.detected_window.as_ref().and_then(|d| d.total_tokens);
        match (advertised, self.learned_window) {
            (Some(advertised), Some(learned)) => Some(advertised.min(learned)),
            (Some(advertised), None) => Some(advertised),
            (None, Some(learned)) => Some(learned),
            (None, None) => None,
        }
    }

    /// The context window and where it came from, for `/context`.
    pub fn context_window_with_source(&self) -> (usize, String) {
        let (user, default_provider) = self.config.effective_providers();
        let (_, model) = providers::context_window(&self.config.model, &user, &default_provider);
        let (window, source) = if let Some((window, source)) = self.configured_window() {
            (window, source.to_string())
        } else if let Some(detected) = &self.detected_window {
            (detected.tokens, format!("reported by the endpoint ({})", detected.source))
        } else if let Some(window) =
            context::window_for_model(&model).or_else(|| context::window_for_model(self.client.model_name()))
        {
            (window, "known for the model name".to_string())
        } else {
            (context::DEFAULT_CONTEXT_WINDOW, "default".to_string())
        };
        match self.learned_window {
            Some(learned) if learned < window => (learned, "learned from a context-overflow error".to_string()),
            _ => (window, source),
        }
    }

    /// Estimated tokens the next request would send, anchored to the last
    /// reported usage when available.
    pub fn estimate_context_tokens(&self) -> (usize, bool) {
        if let Some((len, tokens)) = self.calibration
            && len <= self.conversation.len()
        {
            return (tokens + context::messages_tokens(&self.conversation[len..]), true);
        }
        let tools: usize = self
            .tool_definitions()
            .iter()
            .map(|d| {
                context::text_tokens(&d.name)
                    + context::text_tokens(&d.description)
                    + context::text_tokens(&d.parameters.to_string())
            })
            .sum();
        (context::messages_tokens(&self.conversation) + tools, false)
    }

    /// Recompute the shared statistics and notify the event sink.
    pub fn refresh_stats(&self) {
        let (tokens, calibrated) = self.estimate_context_tokens();
        let cwd = std::env::current_dir()
            .map(|p| crate::status::tilde_path(&p, dirs::home_dir().as_deref()))
            .unwrap_or_else(|_| ".".to_string());
        {
            let mut stats = self.stats.lock().unwrap();
            stats.provider = self.client.provider_name().to_string();
            stats.model = self.client.model_name().to_string();
            stats.tokens = tokens;
            stats.calibrated = calibrated;
            stats.window = self.context_window();
            stats.messages = self.conversation.len();
            stats.auto_compact = self.config.auto_compact.then_some(self.config.auto_compact_threshold);
            stats.smart_compact = self.config.compaction_mode == CompactionMode::Smart && self.session.is_some();
            stats.plan = (!self.plan.items.is_empty()).then(|| self.plan.progress());
            stats.cwd = cwd;
            stats.mode = self.control.mode();
            stats.thinking = status_thinking(&self.thinking());
        }
        self.emit(AgentEvent::Context);
    }

    fn set_activity(&self, activity: Activity) {
        let changed = {
            let mut stats = self.stats.lock().unwrap();
            let changed = stats.activity != activity;
            if !matches!(activity, Activity::Thinking) {
                // Generation has stopped; drop the live output rate.
                stats.tokens_per_sec = None;
            }
            stats.activity = activity;
            changed
        };
        if changed {
            self.emit(AgentEvent::Context);
        }
    }

    fn record_usage(&mut self, response: &LLMResponse, counts_as_context: bool) {
        let Some(usage) = &response.usage else { return };
        {
            let mut stats = self.stats.lock().unwrap();
            stats.session_input_tokens += usage.prompt_tokens.max(0) as u64;
            stats.session_output_tokens += usage.completion_tokens.max(0) as u64;
            if let Some(aic) = usage.aic {
                *stats.session_aic.get_or_insert(0.0) += aic;
            }
        }
        if counts_as_context && usage.prompt_tokens > 0 {
            // Anchored at the assistant message about to be pushed.
            let total = (usage.prompt_tokens + usage.completion_tokens.max(0)) as usize;
            self.calibration = Some((self.conversation.len() + 1, total));
        }
    }

    /// Handle for steering or cancelling the running turn from another task.
    pub fn control(&self) -> TurnControl {
        self.control.clone()
    }

    /// The question broker, for the turn loop to answer a pending `question`.
    pub fn questions(&self) -> crate::question::QuestionBroker {
        self.questions.clone()
    }

    /// The current operating mode (normal/plan/auto).
    pub fn mode(&self) -> crate::mode::AgentMode {
        self.control.mode()
    }

    /// Switch mode; refreshes the status line and (for plan mode) the tool
    /// gating takes effect at the next model call. Takes `&self` so it can be
    /// called while a turn future holds a `&mut` borrow.
    pub fn set_mode(&self, mode: crate::mode::AgentMode) {
        self.control.set_mode(mode);
        self.refresh_stats();
    }

    /// Patch the stored system message for the current mode: plan mode appends
    /// a read-only note (and leaving plan mode removes it). Advisory only —
    /// the tool gating is the real guarantee. Needs `&mut`, so callers apply it
    /// between turns.
    ///
    /// Rebuilds the full system prompt (not just the note) so the memory index
    /// guidance reflects the current mode: `memory_writable()` is false in plan
    /// mode, so the index must not advertise `memory_save` while planning.
    fn apply_mode_to_system_prompt(&mut self) {
        // Compute the prompt before borrowing the conversation mutably, so the
        // immutable borrow of `self` (for `system_prompt`) does not conflict.
        let base = self.system_prompt_cached();
        let content = match self.control.mode() {
            crate::mode::AgentMode::Plan => format!("{base}{}", crate::mode::PLAN_PROMPT_NOTE),
            _ => base,
        };
        let Some(first) = self.conversation.first_mut().filter(|m| m.role == Role::System) else { return };
        first.content = content;
    }

    /// Rebuild the system message so the folded memory index reflects the
    /// current store. Called after a `/memory forget` (or the forget tool) so a
    /// deleted memory leaves the active system prompt immediately instead of
    /// lingering until the next session. A no-op when memory is off.
    pub fn refresh_memory_index(&mut self) {
        if self.memory.is_none() {
            return;
        }
        // Drop the cached index so the rebuild re-reads the store rather than
        // reusing a snapshot taken before the change.
        self.memory_index_cache = None;
        // `apply_mode_to_system_prompt` rebuilds the full system prompt
        // (including the memory index) and applies the plan-mode note.
        self.apply_mode_to_system_prompt();
    }

    /// Add queued steering messages to the conversation.
    fn absorb_steers(&mut self) -> Result<()> {
        for steer in self.control.take_pending() {
            self.push(Message::user(&steer.text))?;
            self.emit(AgentEvent::UserMessage { text: &steer.text });
            self.control.inner.absorbed.lock().unwrap().push(steer);
        }
        Ok(())
    }

    pub fn set_streaming(&mut self, streaming: bool) {
        self.streaming = streaming;
    }

    pub fn set_event_sink(&mut self, sink: EventSink) {
        self.event_sink = Some(sink);
    }

    fn emit(&self, event: AgentEvent) {
        if let Some(sink) = &self.event_sink {
            sink(self.session_id.as_deref(), &event);
        }
    }

    fn emit_assistant_text(&mut self, text: &str) {
        if text.trim().is_empty() || self.event_sink.is_none() {
            return;
        }
        self.message_counter += 1;
        let message_id = format!("msg-{}-{}", Utc::now().timestamp_millis(), self.message_counter);
        self.emit(AgentEvent::AssistantMessage { message_id: &message_id, text });
    }

    /// Re-emit the conversation as events (ACP `session/load` replay).
    pub fn replay_history(&mut self) {
        if self.event_sink.is_none() {
            return;
        }
        // After a compaction the conversation holds the synthetic summary where
        // the folded turns were; replaying it as-is would show that summary as
        // a user turn and drop the real pre-compaction turns (a legacy → frame
        // switch clears the legacy scrollback on the frame's first redraw, so
        // this replay is the only copy). Replay the captured pre-compaction
        // turns first, then skip the summary (the first non-system message) so
        // the internal text is never exposed. The stash is kept (cloned, not
        // taken) so every renderer rebuild replays the real turns — a legacy →
        // frame → legacy → frame round trip must not fall back to exposing the
        // summary on the second switch. It is replaced by the next compaction
        // and cleared on a new or resumed session.
        let pre_compaction = self.pre_compaction_transcript.clone();
        let skip_summary = pre_compaction.is_some();
        let conversation = self.conversation.clone();
        let mut calls: HashMap<&str, &ToolCall> = HashMap::new();
        if let Some(turns) = &pre_compaction {
            for message in turns {
                self.replay_message(message, &mut calls);
            }
        }
        // The summary is the first non-system message of the compacted
        // conversation; everything after it (kept + new turns) replays as-is,
        // except the synthetic restatement of a folded active input (its
        // original is already replayed from the stash above), which is skipped
        // so the one submitted prompt is not shown twice.
        let restated = self.pre_compaction_restated;
        let mut skipped_summary = !skip_summary;
        for (idx, message) in conversation.iter().enumerate() {
            if !skipped_summary && message.role != Role::System {
                skipped_summary = true;
                continue;
            }
            if Some(idx) == restated {
                continue;
            }
            self.replay_message(message, &mut calls);
        }
        if !self.plan.is_empty() {
            self.emit(AgentEvent::Plan { plan: &self.plan });
        }
    }

    /// Emit one message's replay events, registering its tool calls so a later
    /// tool result can be paired back with its call (see `replay_history`).
    fn replay_message<'m>(&mut self, message: &'m Message, calls: &mut HashMap<&'m str, &'m ToolCall>) {
        match message.role {
            Role::System => {}
            Role::User => self.emit(AgentEvent::UserMessage { text: &message.content }),
            Role::Assistant => {
                self.emit_assistant_text(&message.content);
                for call in &message.tool_calls {
                    calls.insert(call.id.as_str(), call);
                    self.emit(AgentEvent::ToolCall { call });
                }
            }
            Role::Tool => {
                let Some(call) = message.tool_call_id.as_deref().and_then(|id| calls.get(id)) else {
                    return;
                };
                let ok = !message.is_error;
                self.emit(AgentEvent::ToolResult { call, ok, output: &message.content });
            }
        }
    }

    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    pub fn session_path(&self) -> Option<&std::path::Path> {
        self.session.as_ref().map(SessionLog::path)
    }

    /// Directory for complete copies of truncated tool output, shared so the
    /// bash tool follows session changes.
    pub fn spill_dir_handle(&self) -> Arc<RwLock<std::path::PathBuf>> {
        self.spill_dir.clone()
    }

    fn spill_dir(&self) -> std::path::PathBuf {
        self.spill_dir.read().unwrap().clone()
    }

    /// Directory this session's image attachments are stored in. Persisted
    /// sessions keep them beside their log so the references in the log stay
    /// valid after the process exits; an ephemeral session uses a
    /// process-local temp dir.
    fn attachments_dir(&self) -> std::path::PathBuf {
        if let (Some(id), true) = (self.session_id.as_deref(), self.session.is_some()) {
            session::attachments_dir_for(&self.config.session_dir(), id)
        } else {
            std::env::temp_dir().join(format!("nano-coder-attachments-{}", std::process::id()))
        }
    }

    /// Persisted sessions keep spilled output beside their log, so the paths
    /// in the log stay valid after the process exits.
    fn set_spill_dir(&self, id: &str) {
        let dir = if self.session.is_some() {
            session::spill_dir_for(&self.config.session_dir(), id)
        } else {
            output::spill_dir()
        };
        *self.spill_dir.write().unwrap() = dir;
    }

    /// Whether the history tools are offered: a real smart summary is in
    /// context (tracked in `history_available`) and there is a session log to
    /// read. Detecting the summary from message text would let a user message
    /// beginning with the prefix unlock the tools, so state is tracked
    /// explicitly instead.
    fn history_tools_enabled(&self) -> bool {
        self.session.is_some() && self.history_available
    }

    /// Start a fresh conversation, persisted under a new session ID if enabled.
    pub fn new_session(&mut self) -> Result<String> {
        let id = session::new_session_id();
        // ACP sets the session cwd before this runs, so the memory store (keyed
        // to the launch directory at build time) must be rekeyed to the new
        // project scope, and that rekeyed index folded into the prompt below.
        // Build it into a *temporary* rather than committing to `self.memory`
        // now: in ACP `cwd` has already changed, so a `SessionLog::create` /
        // initial-append failure below must not leave the live store rekeyed to
        // the new repository while the old conversation/session are still
        // active. The staged store is committed with the rest of the live state
        // only after staging succeeds (failure-atomic staging; Copilot finding,
        // src/agent.rs).
        let staged_memory = self.memory.is_some().then(|| Self::build_memory(&self.config));
        // Discover instructions/skills into temporaries so a staging failure
        // below leaves self.instructions/self.skills (and the live system
        // prompt they render) untouched, rather than pairing the old
        // conversation with newly discovered instructions.
        let (instructions, skills) = self.discover_project_instructions();
        // Render the prompt with the fresh session's default (Normal) mode's
        // writability — a previous Plan mode would otherwise suppress the memory
        // save guidance — and against the *staged* memory store, so the folded
        // index reflects the new scope without committing it. Do *not* reset
        // `control` or `self.memory` here: the live session must stay untouched
        // until staging below succeeds, so a `SessionLog::create` /
        // initial-append failure cannot leave the current session switched out
        // of Plan/Auto mode, or paired with the new repository's memory scope,
        // while `new_session` returns an error (failure-atomic staging; Copilot
        // finding, src/agent.rs).
        let default_mode = crate::mode::AgentMode::default();
        let writable = self.config.memory.writable() && default_mode != crate::mode::AgentMode::Plan;
        let staged_store = staged_memory.as_ref().and_then(|m| m.as_ref());
        let system = Message {
            timestamp: Some(session::now()),
            ..Message::system(&self.system_prompt_with(&instructions, &skills, writable, staged_store))
        };
        // Stage the new log before mutating any live state so a disk/permission
        // failure leaves the current session (conversation, id, log,
        // instructions, skills, mode, memory scope) intact instead of detaching
        // the agent from it.
        let session = if self.config.persist_sessions {
            let cwd = std::env::current_dir().ok().map(|d| d.display().to_string());
            let model = Some(format!("{}/{}", self.client.provider_name(), self.client.model_name()));
            let mut log = SessionLog::create_with(&self.config.session_dir(), &id, cwd, model)?;
            log.append(&Record::Message(Box::new(system.clone())))?;
            Some(log)
        } else {
            None
        };
        // Staging succeeded — now commit all live state, including the mode
        // reset and the memory rekey deferred from above.
        self.control.set_mode(default_mode);
        if let Some(memory) = staged_memory {
            self.memory = memory;
            self.memory_index_cache = None;
        }
        self.instructions = instructions;
        self.skills = skills;
        self.conversation = vec![system];
        // `/thinking` is session-scoped, so the previous session's override
        // must not leak into this one. Clear it here — after staging has
        // succeeded — so a `SessionLog::create` / initial-append failure above
        // still leaves the live session (and its override) untouched.
        self.control.set_thinking(None);
        self.completed_inputs.clear();
        self.completed_outcomes.clear();
        self.pending_input = None;
        self.plan = Plan::default();
        self.reminders = Reminders::default();
        self.session = session;
        self.session_id = Some(id.clone());
        self.set_spill_dir(&id);
        self.claude_session_started = false;
        self.pending_session_start_context = None;
        self.claude_session_resumed = false;
        self.sync_claude_hook_session();
        self.persist_claude_hook_config();
        self.calibration = None;
        self.compact_floor = 0;
        self.history_available = false;
        self.history_hint_pending = false;
        // A fresh session has no compaction behind it, so there is no
        // pre-compaction transcript for `replay_history` to restore.
        self.pre_compaction_transcript = None;
        self.pre_compaction_restated = None;
        {
            // A fresh session starts with clean cumulative counters so the
            // status line and `/context` reflect only this session. Shared
            // with startup, where these are already zero.
            let mut stats = self.stats.lock().unwrap();
            stats.session_input_tokens = 0;
            stats.session_output_tokens = 0;
            stats.session_aic = None;
            stats.compactions = 0;
            stats.history_searches = 0;
            stats.history_reads = 0;
        }
        // Mode was already reset to the default before the system prompt was
        // rendered above, so the memory index guidance is correct.
        self.refresh_stats();
        Ok(id)
    }

    /// Resume a persisted session.
    pub fn load_session(&mut self, id: &str) -> Result<()> {
        let (mut log, mut restored) = SessionLog::open(&self.config.session_dir(), id)?;
        // Stage the repair on a scratch conversation and append its records
        // *before* committing any agent state: when this append fails (a full
        // disk, say), the load reports an error with this process still in
        // the previous session instead of switched over with the renderer
        // left on the old transcript. The conversation is moved out of
        // `restored` rather than cloned: the original is never read again, so
        // a load never holds two copies of a potentially large history.
        let mut staged = std::mem::take(&mut restored.conversation);
        let mut repairs = Self::repair_dangling_tool_calls_on(&staged);
        for message in &mut repairs {
            // Stamp and number each repair exactly like `push` does, so the
            // repaired result keeps its event time (for `/trajectory`) and its
            // persisted `#N` (for citations) without waiting for a reload.
            message.timestamp.get_or_insert_with(session::now);
            let line = log.append(&Record::Message(Box::new(message.clone())))?;
            message.log_line.get_or_insert(line);
        }
        staged.extend(repairs);
        self.conversation = staged;
        // Instructions are re-read so a resumed session sees the current files.
        self.load_project_instructions();
        // Rekey memory to the session cwd (ACP applies it before this runs), so
        // memory_search hits the requested repository's project scope.
        self.rekey_memory();
        // A loaded session starts in the default mode, not whatever mode the
        // previous session left selected. Reset it *before* rendering the
        // system prompt below: `system_prompt()` derives memory writability
        // from the live mode, so rendering while still in Plan would bake
        // read-only memory guidance into a session that is actually writable
        // (Normal) until the next prompt refresh (Copilot finding,
        // src/agent.rs). Mirrors `new_session`, which renders for the default
        // mode's writability.
        self.control.set_mode(crate::mode::AgentMode::default());
        let system = Message { timestamp: Some(session::now()), ..Message::system(&self.system_prompt()) };
        match self.conversation.first_mut() {
            Some(first) if first.role == Role::System => *first = system,
            _ => self.conversation.insert(0, system),
        }
        self.completed_inputs = restored.completed;
        self.completed_outcomes = restored.outcomes;
        self.pending_input = restored.pending_input;
        self.plan = restored.plan.unwrap_or_default();
        // Reminders belong to the session being left (`/resume` mid-process).
        self.reminders = Reminders::default();
        // `/thinking` is session-scoped, so the previous session's override
        // must not leak into the resumed one. Cleared here — after the staged
        // conversation and its repairs have committed — so a failed load leaves
        // the live session's override intact.
        self.control.set_thinking(None);
        // `titles_requested` is deliberately not reset: it tracks which
        // sessions this process already asked to title, so switching
        // A → B → A does not launch a second (paid) title request for A.
        self.session = Some(log);
        self.session_id = Some(id.to_string());
        self.set_spill_dir(id);
        self.calibration = None;
        self.compact_floor = 0;
        // Whether the history tools are offered is durable state: restore it
        // from the log (the last replace's mode) rather than the message text.
        self.history_available = restored.history_available;
        // Keep the post-compaction hint one-time per compaction: if it was
        // already emitted (or a history tool already used) after the latest
        // smart compaction, a resume must not append it again.
        self.history_hint_pending = restored.history_available && !restored.history_hint_consumed;
        // A resumed session does not rebuild the pre-compaction transcript
        // (the folded turns are recoverable via the history tools, and the
        // replace record's summarized range is not exposed here), so a
        // post-resume legacy → frame switch replays the compacted
        // conversation — the pre-change behaviour.
        self.pre_compaction_transcript = None;
        self.pre_compaction_restated = None;
        self.claude_session_started = false;
        self.pending_session_start_context = None;
        self.claude_session_resumed = true;
        self.sync_claude_hook_session();
        self.persist_claude_hook_config();
        {
            // History-tool usage is per-session live state: a resumed session
            // starts fresh so `/context` and the status line report only calls
            // made after the load, not ones left over from a prior session in
            // this same agent. Mirrors `new_session`, including the token
            // totals (only nonzero when `/resume` switches sessions).
            let mut stats = self.stats.lock().unwrap();
            stats.session_input_tokens = 0;
            stats.session_output_tokens = 0;
            stats.session_aic = None;
            stats.compactions = 0;
            stats.history_searches = 0;
            stats.history_reads = 0;
        }
        // Tool-call repair ran on the staged conversation above; the mode was
        // already reset to the default before the system prompt was rendered
        // above, so the memory index guidance is correct.
        self.refresh_stats();
        Ok(())
    }

    /// Append a synthetic error result for every tool call without one, so the
    /// conversation is valid for providers that require paired results. Pure:
    /// `load_session` persists the returned repairs (stamped and numbered like
    /// `push` does) *before* committing the conversation, so a failed repair
    /// write cannot leave the agent switched while the UI still shows the
    /// previous session.
    fn repair_dangling_tool_calls_on(conversation: &[Message]) -> Vec<Message> {
        let Some(index) = conversation.iter().rposition(|m| m.role == Role::Assistant && !m.tool_calls.is_empty())
        else {
            return Vec::new();
        };
        let answered: HashSet<&str> =
            conversation[index + 1..].iter().filter_map(|m| m.tool_call_id.as_deref()).collect();
        conversation[index]
            .tool_calls
            .iter()
            .filter(|call| !answered.contains(call.id.as_str()))
            .map(|call| Message::tool_error(&call.id, &call.name, INTERRUPTED_TOOL_RESULT))
            .collect()
    }

    fn push(&mut self, mut message: Message) -> Result<()> {
        message.timestamp.get_or_insert_with(session::now);
        if let Some(log) = &mut self.session {
            let line = log.append(&Record::Message(Box::new(message.clone())))?;
            message.log_line.get_or_insert(line);
        }
        self.conversation.push(message);
        Ok(())
    }

    fn replace_conversation(&mut self, messages: Vec<Message>) -> Result<()> {
        self.replace_keeping_pending(messages, None, None)
    }

    /// Replace the conversation; `pending_position` keeps the in-flight input
    /// alive with its user message at that index. `compaction` records the
    /// folded log-line range and mode, and carries the folded messages
    /// themselves (the real pre-compaction turns) so `replay_history` can
    /// rebuild the visible transcript after a legacy → frame switch instead
    /// of exposing the synthetic summary.
    fn replace_keeping_pending(
        &mut self,
        mut messages: Vec<Message>,
        pending_position: Option<usize>,
        compaction: Option<CompactionRecord>,
    ) -> Result<()> {
        let now = session::now();
        for message in &mut messages {
            message.timestamp.get_or_insert(now);
        }
        // The history tools follow the compaction: a smart summary offers them,
        // any other replacement (standard compaction or a plain rebuild) drops
        // them. Track it explicitly so message text cannot spoof the state.
        let history_available = matches!(compaction, Some(CompactionRecord { mode: CompactionMode::Smart, .. }));
        // Destructure once: the folded turns go to the replay stash, the range
        // and mode to the durable replace record, and the restated-input index
        // to the replay skip.
        let (range, mode, folded_turns, restated) = match compaction {
            Some(CompactionRecord { range, mode, folded, restated }) => (range, Some(mode), Some(folded), restated),
            None => (None, None, None, None),
        };
        if let Some(log) = &mut self.session {
            log.append(&Record::Replace {
                messages: messages.clone(),
                pending_position,
                summarized: range,
                mode,
                // Record the resolved provider/model, not the raw user spec
                // (which can be a bare model name under a default provider), so
                // mode comparisons keep the provider dimension.
                model: mode.map(|_| format!("{}/{}", self.client.provider_name(), self.client.model_name())),
                recorded_at: now,
            })?;
        }
        // Flip the flag only once the durable replace record is appended, so a
        // failed replacement leaves the active history state unchanged.
        self.history_available = history_available;
        self.history_hint_pending = history_available;
        self.conversation = messages;
        // Assign unconditionally: a compaction stashes its folded turns for the
        // replay, and any other replacement (a plain rebuild, a system-prompt
        // change, …) clears the stash so a later replay cannot resurrect the
        // previous conversation and skip the first new user turn as though it
        // were a synthetic summary.
        self.pre_compaction_transcript = folded_turns.filter(|f| !f.is_empty());
        // Track the restatement to skip alongside the stash; a cleared stash
        // (any non-compaction replacement) clears it too.
        self.pre_compaction_restated = self.pre_compaction_transcript.as_ref().and(restated);
        self.pending_input = match (self.pending_input.take(), pending_position) {
            (Some(pending), Some(position)) => Some(PendingInput { position, ..pending }),
            _ => None,
        };
        self.calibration = None;
        self.refresh_stats();
        Ok(())
    }

    /// Set the system prompt and reset conversation
    pub fn set_system_prompt(&mut self, prompt: &str) -> Result<()> {
        let previous = std::mem::replace(&mut self.config.system_prompt, prompt.to_string());
        let result = self.replace_conversation(vec![Message::system(&self.system_prompt())]);
        // Keep config and conversation consistent: `replace_conversation` can
        // fail while appending the durable replace record, which leaves the
        // active conversation untouched. Roll the config prompt back so the two
        // never drift out of sync on a failed update.
        if result.is_err() {
            self.config.system_prompt = previous;
        }
        result
    }

    /// The configured system prompt plus any project instructions and the
    /// skill index.
    pub fn system_prompt(&self) -> String {
        self.system_prompt_from(&self.instructions, &self.skills)
    }

    /// Whether memory saves are actually offered right now: the mode must be
    /// writable *and* the agent must not be in plan mode, whose read-only tool
    /// gating drops `memory_save`. The memory index guidance uses this so a
    /// plan-mode prompt never advertises an unavailable tool.
    pub fn memory_writable(&self) -> bool {
        self.config.memory.writable() && self.control.mode() != crate::mode::AgentMode::Plan
    }

    /// Render the system prompt from a given instruction/skill set, so a new
    /// session can build its prompt from freshly discovered temporaries before
    /// committing them to `self`. Uses the current mode's memory writability.
    fn system_prompt_from(&self, instructions: &Option<ProjectInstructions>, skills: &Skills) -> String {
        self.system_prompt_for(instructions, skills, self.memory_writable())
    }

    /// Render the system prompt with an explicit memory-writability value, so a
    /// caller can render for a mode other than the one currently committed to
    /// `control` (e.g. a fresh session's default mode before that mode is
    /// applied). `system_prompt_from` is this with the live writability.
    fn system_prompt_for(&self, instructions: &Option<ProjectInstructions>, skills: &Skills, writable: bool) -> String {
        self.system_prompt_with(instructions, skills, writable, self.memory.as_ref())
    }

    /// Like [`Agent::system_prompt_for`] but with an explicit memory store, so a
    /// caller can fold in a *staged* store that has not yet been committed to
    /// `self.memory` (e.g. `new_session` renders with the rekeyed store before
    /// committing it, so a later staging failure cannot leave the store paired
    /// with the old session — failure-atomic staging).
    fn system_prompt_with(
        &self,
        instructions: &Option<ProjectInstructions>,
        skills: &Skills,
        writable: bool,
        memory: Option<&memory::Store>,
    ) -> String {
        let extra = instructions.as_ref().map(ProjectInstructions::render).unwrap_or_default();
        let memory =
            memory.filter(|_| self.config.memory.enabled()).map(|store| store.index(writable)).unwrap_or_default();
        format!("{}{extra}{}{memory}", self.config.system_prompt, skills.render_index())
    }

    /// Like [`Agent::system_prompt`] but serves the memory index from the
    /// per-session cache. `apply_mode_to_system_prompt` runs before every model
    /// request, and rendering the index reads and parses both scope files, so
    /// recomputing it each iteration would add filesystem work proportional to
    /// the whole store to every turn. Instructions and skills are already
    /// in-memory, so only the memory index is cached.
    fn system_prompt_cached(&mut self) -> String {
        let memory = self.cached_memory_index();
        let extra = self.instructions.as_ref().map(ProjectInstructions::render).unwrap_or_default();
        format!("{}{extra}{}{memory}", self.config.system_prompt, self.skills.render_index())
    }

    /// The rendered memory index, cached for the current `writable` state. The
    /// cache is invalidated on any store mutation (see `refresh_memory_index`
    /// and the memory-tool dispatch); a `writable` flip rebuilds once so the
    /// save guidance matches the mode.
    fn cached_memory_index(&mut self) -> String {
        if self.memory.is_none() || !self.config.memory.enabled() {
            return String::new();
        }
        let writable = self.memory_writable();
        if let Some((cached_writable, index)) = &self.memory_index_cache
            && *cached_writable == writable
        {
            return index.clone();
        }
        let index = self.memory.as_ref().map(|store| store.index(writable)).unwrap_or_default();
        self.memory_index_cache = Some((writable, index.clone()));
        index
    }

    /// Discover instruction files and skills for the current working directory,
    /// returning them without mutating `self`.
    fn discover_project_instructions(&self) -> (Option<ProjectInstructions>, Skills) {
        let enabled = self.config.project_instructions && std::env::var_os("AGENTIC_NO_PROJECT_INSTRUCTIONS").is_none();
        let cwd = std::env::current_dir().ok();
        let instructions = enabled
            .then(|| cwd.clone())
            .flatten()
            .map(|cwd| ProjectInstructions::discover_with(&cwd, self.instruction_options()));
        let skills_enabled = self.config.skills.enabled && std::env::var_os("NANO_CODER_NO_SKILLS").is_none();
        let skills = match cwd.filter(|_| skills_enabled) {
            Some(cwd) => Skills::discover(&cwd, &self.config.skills),
            None => Skills::default(),
        };
        (instructions, skills)
    }

    fn instruction_options(&self) -> crate::instructions::Options {
        use crate::instructions::expand_home;
        crate::instructions::Options {
            names: self.config.project_instruction_files.clone(),
            user_files: self.config.user_instruction_files.iter().map(|p| expand_home(p)).collect(),
            user_rules_dirs: self.config.user_rules_dirs.iter().map(|p| expand_home(p)).collect(),
            imports_outside_project: self.config.instruction_imports_outside_project,
        }
    }

    /// Discover instruction files and skills, committing them to `self`.
    fn load_project_instructions(&mut self) {
        let (instructions, skills) = self.discover_project_instructions();
        self.instructions = instructions;
        self.skills = skills;
    }

    pub fn skills(&self) -> &Skills {
        &self.skills
    }

    /// Load instructions into a conversation that was started without a
    /// session (persistence disabled).
    pub fn apply_project_instructions(&mut self) {
        self.load_project_instructions();
        let prompt = self.system_prompt();
        if let Some(first) = self.conversation.first_mut().filter(|m| m.role == Role::System) {
            first.content = prompt;
        }
        self.refresh_stats();
    }

    pub fn plan(&self) -> &Plan {
        &self.plan
    }

    /// Replace the plan with one carried over from an earlier run (e.g. from
    /// its transcript), and tell the model about it unless `announce` is false. No event is sent: the
    /// caller reports the plan (ACP returns it in the `session/new` result).
    pub fn set_plan(&mut self, plan: Plan, announce: bool) -> Result<()> {
        self.plan = plan;
        if announce && self.config.plan_tools && !self.plan.is_empty() {
            self.push(Message::user(&self.plan.carried_over_note()))?;
        }
        self.record_plan()?;
        self.refresh_stats();
        Ok(())
    }

    fn record_plan(&mut self) -> Result<()> {
        if let Some(log) = &mut self.session {
            log.append(&Record::Plan { plan: self.plan.clone(), recorded_at: session::now() })?;
        }
        Ok(())
    }

    fn plan_changed(&mut self) -> Result<()> {
        self.reminders.plan_changed();
        self.record_plan()?;
        self.emit(AgentEvent::Plan { plan: &self.plan });
        self.refresh_stats();
        Ok(())
    }

    /// Registered tools plus the plan tools when enabled.
    pub fn tool_definitions(&self) -> Vec<crate::tools::ToolDefinition> {
        let mut tools = self.tools.definitions();
        if self.config.plan_tools {
            tools.extend(plan::definitions());
        }
        if self.config.outcome_tool {
            tools.push(goal::definition());
        }
        if !self.skills.is_empty() {
            tools.push(skills::definition());
        }
        if self.history_tools_enabled() {
            tools.extend(history::definitions());
        }
        if self.memory_enabled() {
            tools.extend(memory::definitions(self.memory_writable()));
        }
        // Plan mode is read-only: only analysis/planning/reporting tools are
        // offered (the dispatch backstops this for calls already in flight).
        if self.control.mode() == crate::mode::AgentMode::Plan {
            tools.retain(|t| crate::mode::plan_allows(&t.name));
        }
        tools
    }

    /// Paths of the instruction files in the system prompt.
    pub fn project_instruction_files(&self) -> Vec<String> {
        self.instructions.as_ref().map(ProjectInstructions::loaded_paths).unwrap_or_default()
    }

    /// Rules attached only when a file they cover is touched.
    pub fn on_demand_instruction_files(&self) -> Vec<String> {
        self.instructions.as_ref().map(ProjectInstructions::on_demand_paths).unwrap_or_default()
    }

    /// Instruction files or imports that were skipped, with the reason.
    pub fn instruction_warnings(&self) -> Vec<String> {
        self.instructions.as_ref().map(|i| i.warnings.clone()).unwrap_or_default()
    }

    /// Send a user message and get agent response (with tool execution)
    #[cfg(test)]
    pub async fn send_message(&mut self, user_input: &str) -> Result<String> {
        self.send_input(None, user_input).await
    }

    /// Send a user message identified by `input_id`. Redelivering an ID that
    /// already completed returns the recorded response without re-running the
    /// turn; redelivering the ID of an interrupted turn resumes it.
    #[cfg(test)]
    pub async fn send_input(&mut self, input_id: Option<&str>, user_input: &str) -> Result<String> {
        Ok(self.run_turn(input_id, user_input).await?.response)
    }

    /// Like `send_input`, also reporting why the turn stopped. Steers queued on
    /// `control()` during the turn are added before the next model call;
    /// `control().cancel()` stops the turn at the next opportunity.
    pub async fn run_turn(&mut self, input_id: Option<&str>, user_input: &str) -> Result<TurnOutcome> {
        let end_turn = |(response, outcome): (String, Option<Outcome>)| TurnOutcome {
            response,
            stop_reason: StopReason::EndTurn,
            outcome,
        };
        if let Some(id) = input_id
            && let Some(response) = self.completed_inputs.get(id)
        {
            eprintln!("[agent] input {id:?} already processed; returning recorded response");
            return Ok(end_turn((response.clone(), self.completed_outcomes.get(id).cloned())));
        }
        self.control.start_turn();
        self.reminders.start_turn();
        self.claude_stop_blocks = 0;
        self.sync_claude_hook_session();
        self.apply_mode_to_system_prompt();
        self.turn_history_calls = 0;
        // Log size before this turn's records: the session-index update in
        // `finish_turn` folds the input records committed by this turn into
        // the cached summary (from the log's tail) instead of rescanning the
        // whole log.
        self.turn_log_offset = self.session.as_ref().map(|log| log.size());
        let resuming = self.pending_input.clone().filter(|pending| input_id == Some(pending.id.as_str()));
        let input_id = match input_id {
            Some(id) => id.to_string(),
            None => {
                self.input_counter += 1;
                format!("in-{}-{}", Utc::now().timestamp_millis(), self.input_counter)
            }
        };

        // Trigger before_context_load hook
        let ctx = HookContext::new(HookEvent::BeforeContextLoad)
            .with_data("user_input", json!(user_input))
            .with_data("input_id", json!(input_id))
            .with_data("resuming", json!(resuming.is_some()));
        self.hooks.trigger(&ctx);

        match resuming {
            Some(pending) => {
                // A restored session still gets its once-per-session
                // `SessionStart` hooks (with the `resume` trigger) before the
                // model continues the pending turn. `UserPromptSubmit` is *not*
                // re-run: the prompt was already accepted before the interrupt,
                // so validating it again could reject input the user already
                // sent. Any SessionStart context is appended as a user message
                // so the model sees it on the continued turn. The hook runs at
                // most once and caches its context; the cache is drained only
                // when the context is actually delivered (below), so the two
                // early-return replay branches — which complete an
                // already-answered turn from the log without a model call —
                // leave it cached rather than dropping it.
                self.run_claude_session_start();
                let recorded = self.conversation.get(pending.position);
                if !recorded.is_some_and(|m| m.role == Role::User) {
                    // The input was logged but its user message was not.
                    self.conversation.truncate(pending.position);
                    self.push(Message::user(&pending.text))?;
                } else if let Some(last) = self.conversation.last().filter(|m| {
                    self.conversation.len() > pending.position + 1
                        && m.role == Role::Assistant
                        && m.tool_calls.is_empty()
                }) {
                    // The final answer was recorded but the turn end was not.
                    let response = last.content.clone();
                    let outcome = Outcome::reported_in(&self.conversation[pending.position..]);
                    return self.finish_turn(input_id, response, outcome).map(end_turn);
                } else if self.config.outcome_tool
                    && self.conversation.last().is_some_and(|m| m.role == Role::Tool)
                    && let Some(outcome) = Outcome::reported_in(&self.conversation[pending.position..])
                {
                    // The outcome was reported but the answer it implies was not recorded.
                    let response = outcome.response();
                    self.push(Message::assistant(&response))?;
                    return self.finish_turn(input_id, response, Some(outcome)).map(end_turn);
                }
                if let Some(ctx) = self.take_session_start_context() {
                    self.push(Message::user(&reminders::wrap(&ctx)))?;
                }
            }
            None => {
                let extra = match self.run_claude_prompt_hooks(user_input) {
                    ClaudePromptHook::Reject(reason) => {
                        self.pending_input = Some(PendingInput {
                            id: input_id.clone(),
                            text: user_input.to_string(),
                            position: self.conversation.len(),
                        });
                        if let Some(log) = &mut self.session {
                            log.append(&Record::Input {
                                id: input_id.clone(),
                                text: user_input.to_string(),
                                recorded_at: session::now(),
                            })?;
                        }
                        self.push(Message::user(user_input))?;
                        let reason = if reason.trim().is_empty() {
                            "Your message was blocked by a UserPromptSubmit hook.".to_string()
                        } else {
                            reason
                        };
                        self.push(Message::assistant(&reason))?;
                        self.emit_assistant_text(&reason);
                        return self.finish_turn(input_id, reason, None).map(end_turn);
                    }
                    ClaudePromptHook::Proceed(extra) => extra,
                };
                self.pending_input = Some(PendingInput {
                    id: input_id.clone(),
                    text: user_input.to_string(),
                    position: self.conversation.len(),
                });
                if let Some(log) = &mut self.session {
                    log.append(&Record::Input {
                        id: input_id.clone(),
                        text: user_input.to_string(),
                        recorded_at: session::now(),
                    })?;
                }
                let message = match &extra {
                    Some(extra) => format!("{user_input}\n\n{}", reminders::wrap(extra)),
                    None => user_input.to_string(),
                };
                self.push(Message::user(&message))?;
            }
        }

        // Trigger after_context_load hook
        let ctx =
            HookContext::new(HookEvent::AfterContextLoad).with_data("message_count", json!(self.conversation.len()));
        self.hooks.trigger(&ctx);

        // A cap of 0 is unbounded.
        let max_iterations = self.config.max_iterations;
        let mut final_response = None;
        let mut last_content = String::new();
        let mut cancelled = false;
        let mut reported: Option<Outcome> = None;

        // The cap is mode-dependent and can be extended when the user says
        // "keep going". Auto mode disables it; normal mode asks (interactive
        // only); ACP/headless keeps the hard stop. Re-evaluated from the live
        // mode each iteration so a mid-turn Shift+Tab changes cap behavior too.
        let mut granted_extra = 0usize;
        let mut iteration = 0usize;
        loop {
            iteration += 1;
            let budget = match (self.control.mode(), max_iterations) {
                (crate::mode::AgentMode::Auto, _) | (_, 0) => usize::MAX,
                _ => max_iterations.saturating_add(granted_extra),
            };
            if iteration > budget {
                // Cap reached. Only normal mode in an interactive session asks
                // to continue; anything else (auto, ACP/headless) stops.
                let can_prompt =
                    self.control.mode() == crate::mode::AgentMode::Normal && self.questions.is_interactive();
                if can_prompt {
                    match self.questions.cap().wait().await {
                        crate::question::CapDecision::Continue => {
                            granted_extra = granted_extra.saturating_add(max_iterations);
                            // This probe iteration hit the cap without running a
                            // model call, so rewind it: the next loop pass
                            // re-increments to the same number and actually
                            // spends it on a call. Without this the extended run
                            // skips one iteration (cap 2 -> calls 1, 2, 4) and
                            // the final `completed = iteration - 1` overcounts.
                            iteration = iteration.saturating_sub(1);
                            continue;
                        }
                        crate::question::CapDecision::Stop => break,
                    }
                }
                break;
            }
            if self.control.is_cancelled() {
                cancelled = true;
                break;
            }
            self.absorb_steers()?;

            // Refresh the mode note on the system prompt before rebuilding the
            // tools, so a mid-turn Shift+Tab keeps the prompt and the available
            // tool set in sync: leaving plan mode drops the read-only note (and
            // exposes mutating tools) while entering it re-adds the note.
            self.apply_mode_to_system_prompt();

            // Rebuild the tool set each call so a mid-turn mode switch (e.g.
            // Shift+Tab out of plan mode) takes effect at the next model call.
            // The dispatch-time gate still backstops a switch into plan mode.
            // Built after the threshold compaction below so a smart summary
            // created there adds the history tools to this same request.

            // Trigger before_llm_send hook
            let ctx = HookContext::new(HookEvent::BeforeLLMSend)
                .with_data("iteration", json!(iteration))
                .with_data("message_count", json!(self.conversation.len()))
                .with_data("provider", json!(self.client.provider_name()))
                .with_data("model", json!(self.client.model_name()));
            self.hooks.trigger(&ctx);

            if self.over_threshold() {
                self.compact_logged(CompactTrigger::Threshold, self.config.compaction_mode, None).await?;
                if self.control.is_cancelled() {
                    cancelled = true;
                    break;
                }
            }

            let mut overflow_retried = false;
            // Reset per attempt, so the recorded duration is the request that
            // produced the response, not earlier overflowed attempts.
            let mut request_started;
            // The values of the attempt that produced the response, carried
            // out of the retry loop for the trajectory. Re-resolved per
            // attempt (below), so these are what the successful request
            // actually sent, not a stale pre-compaction resolution.
            let mut sent_temperature = None;
            let mut sent_thinking = None;
            let response = loop {
                self.set_activity(Activity::Thinking);
                // Re-resolved every retry iteration, not just once before the
                // loop: an overflow retry compacts (below), which shrinks the
                // estimated context and so grows `request_max_tokens()`, and
                // thinking's budget feasibility and its coupled temperature
                // depend on it. Resolving once would freeze a pre-compaction
                // no-room `Default` (or a pre-compaction capped-budget
                // warning) into the successful post-compaction retry, sending
                // no level the request now has room for; resolving per attempt
                // keeps the sent request and the trajectory's record of it in
                // step with the attempt that produced the response.
                // Snapshot thinking once, then derive temperature from that
                // same resolution: `temperature()` would re-read the shared
                // control's level internally, so resolving the two
                // independently lets a `/thinking` typed between the reads
                // make temperature observe a different level than the one
                // actually sent (e.g. omitting a configured temperature while
                // sending `off`, or reporting a temperature the provider drops
                // once thinking is on). One snapshot, passed by value, keeps
                // the request internally consistent — the helper has no second
                // read a mid-build `/thinking` change could land on.
                let (resolved_thinking, resolved_temperature, request_max_tokens) =
                    self.request_settings_for(self.control.thinking());
                // Test-only interleave point: a `/thinking` change landing here,
                // between the snapshot and the status update, must not leak the
                // newer level into the status this request shows.
                #[cfg(test)]
                if let Some(hook) = &self.after_thinking_snapshot {
                    hook();
                }
                // A `/thinking` typed mid-turn changes the level between
                // steps: keep the status line in step with what is sent. Set it
                // from this request's `resolved_thinking` snapshot rather than
                // re-resolving through `refresh_stats()`: a `/thinking` landing
                // between `request_settings_for` and that refresh would
                // otherwise show the newer level while this request still sends
                // the snapshot, desynchronizing status from the request.
                let status = status_thinking(&resolved_thinking);
                let status_changed = {
                    let mut stats = self.stats.lock().unwrap();
                    if stats.thinking != status {
                        stats.thinking = status;
                        true
                    } else {
                        false
                    }
                };
                if status_changed {
                    self.emit(AgentEvent::Context);
                }
                // Rebuilt every retry iteration, not just once before the loop:
                // an overflow retry compacts (in smart mode) below, which unlocks
                // the history tools, so recomputing here lets the retried request
                // actually offer `history_search`/`history_read` for the folded
                // history instead of reusing the pre-compaction tool set.
                let tools = self.tool_definitions();
                let attachments_dir = self.attachments_dir();
                let request = ChatRequest {
                    messages: &self.conversation,
                    tools: &tools,
                    temperature: resolved_temperature.value(),
                    max_tokens: Some(request_max_tokens),
                    thinking: resolved_thinking.request(),
                    vision: self.vision(),
                    attachments_dir: Some(attachments_dir.as_path()),
                };
                let control = self.control.clone();
                let (event_sink, session_id) = (&self.event_sink, self.session_id.as_deref());
                let stats = self.stats.clone();
                let rate_meter = Arc::new(Mutex::new(RateMeter::new(Instant::now())));
                // A fresh generation has no measured rate yet. Clear any rate
                // carried over from the previous response and redraw, so the
                // status bar never shows a stale tokens/sec until the new
                // meter's first throttled sample. `set_activity(Thinking)` does
                // not clear it (it clears only on non-Thinking transitions), so
                // when a queued steer keeps activity at `Thinking` across
                // requests the old rate would otherwise linger.
                let had_rate = stats.lock().unwrap().tokens_per_sec.take().is_some();
                if had_rate && let Some(sink) = event_sink {
                    sink(session_id, &AgentEvent::Context);
                }
                // A live tokens/sec meter is only meaningful when the UI is in
                // streaming mode with a sink to draw to. Whether the provider
                // actually streams is judged by the `RateMeter` from delivered
                // output: a `report_whole` provider hands the whole body over in
                // one delta at completion, so no live per-delta rate is
                // published (zero elapsed since the first token), and `finish`
                // instead reports the call's `usage / elapsed` average.
                let meter_live = self.streaming && event_sink.is_some();
                let on_stream = |event: StreamEvent<'_>| {
                    let Some(sink) = event_sink else { return };
                    let text = match event {
                        StreamEvent::Text(text) => {
                            sink(session_id, &AgentEvent::TextDelta { text });
                            text
                        }
                        StreamEvent::Thinking(text) => {
                            sink(session_id, &AgentEvent::ThinkingDelta { text });
                            text
                        }
                    };
                    // Update the live output rate, throttled so the status line
                    // does not redraw on every delta.
                    if !meter_live {
                        return;
                    }
                    let rate = rate_meter.lock().unwrap().record(text.len(), Instant::now());
                    if let Some(rate) = rate {
                        stats.lock().unwrap().tokens_per_sec = Some(rate);
                        sink(session_id, &AgentEvent::Context);
                    }
                };
                let streaming = self.streaming && event_sink.is_some();
                request_started = Instant::now();
                let mut call =
                    if streaming { self.client.chat_stream(&request, &on_stream) } else { self.client.chat(&request) };
                // While streaming, refresh the displayed rate on a timer even
                // when no new deltas arrive. The rate is cumulative
                // (estimated_tokens / elapsed), so a pause or a hung endpoint
                // must keep lowering the shown value as elapsed grows instead
                // of leaving the last sample frozen on the status bar — that is
                // what distinguishes a slow stream from a stalled one.
                let mut refresh = tokio::time::interval(Duration::from_secs(1));
                refresh.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                refresh.tick().await; // discard the immediate first tick
                let result = loop {
                    tokio::select! {
                        response = &mut call => break Some(response),
                        () = control.cancelled() => break None,
                        _ = refresh.tick(), if meter_live => {
                            let rate = rate_meter.lock().unwrap().sample(Instant::now());
                            if let Some(rate) = rate {
                                stats.lock().unwrap().tokens_per_sec = Some(rate);
                                if let Some(sink) = event_sink {
                                    sink(session_id, &AgentEvent::Context);
                                }
                            }
                        }
                    }
                };
                // `call` still borrows `request` (and thus `self`); drop it now
                // so the overflow branch below can take `&mut self` to compact.
                drop(call);
                match result {
                    None => break None,
                    Some(Ok(response)) => {
                        // Sample the meter once at completion using the exact
                        // completion-token count when the provider reports it.
                        // `finish` divides by the whole-call elapsed, so a
                        // one-shot/bursty response that never published a live
                        // per-delta rate still reports a `usage / elapsed`
                        // average.
                        let tokens = response.usage.as_ref().and_then(|u| u64::try_from(u.completion_tokens).ok());
                        if let Some(rate) =
                            meter_live.then(|| rate_meter.lock().unwrap().finish(tokens, Instant::now())).flatten()
                        {
                            stats.lock().unwrap().tokens_per_sec = Some(rate);
                            if let Some(sink) = event_sink {
                                sink(session_id, &AgentEvent::Context);
                            }
                        }
                        // Retain this attempt's resolution for the trajectory:
                        // it is what the successful request actually sent.
                        sent_temperature = Some(resolved_temperature);
                        sent_thinking = Some(resolved_thinking);
                        break Some(response);
                    }
                    Some(Err(e)) => {
                        let message = format!("{e:#}");
                        if overflow_retried || !context::is_context_overflow(&message) {
                            self.set_activity(Activity::Idle);
                            return Err(e);
                        }
                        // The request did not fit: learn the real window and
                        // compact once before retrying.
                        overflow_retried = true;
                        let estimate = self.estimate_context_tokens().0;
                        self.learned_window =
                            Some(context::limit_from_error(&message).unwrap_or(estimate * 9 / 10).max(1_000));
                        eprintln!("[agent] context overflow ({message}); compacting and retrying");
                        let compacted =
                            self.compact_logged(CompactTrigger::Overflow, self.config.compaction_mode, None).await?;
                        if compacted.is_none() || self.control.is_cancelled() {
                            if self.control.is_cancelled() {
                                break None;
                            }
                            self.set_activity(Activity::Idle);
                            return Err(e);
                        }
                    }
                }
            };
            let Some(response) = response else {
                cancelled = true;
                break;
            };
            // The loop only breaks `Some` after recording both, so these are
            // the values the successful request actually sent.
            let (sent_temperature, sent_thinking) = (
                sent_temperature.expect("a response implies a sent request"),
                sent_thinking.expect("a response implies a sent request"),
            );
            let duration_ms = u64::try_from(request_started.elapsed().as_millis()).unwrap_or(u64::MAX);
            self.record_usage(&response, true);
            // Log-only trajectory data carried by the assistant message.
            let trajectory = |message: Message| Message {
                thinking_blocks: response.thinking_blocks.clone(),
                thinking: response.thinking.clone(),
                usage: response.usage.clone(),
                duration_ms: Some(duration_ms),
                temperature: Some(sent_temperature.describe()),
                // Only when a level is sent or set for this model, provider or
                // session, so logs without thinking levels stay unchanged.
                thinking_level: (sent_thinking.effective != crate::thinking::Thinking::Default
                    || sent_thinking.source != crate::thinking::Source::Global)
                    .then(|| sent_thinking.describe()),
                ..message
            };

            // Trigger after_llm_response hook
            let usage = response.usage.as_ref().map(|u| {
                json!({"prompt_tokens": u.prompt_tokens, "completion_tokens": u.completion_tokens, "total_tokens": u.total_tokens})
            });
            let ctx = HookContext::new(HookEvent::AfterLLMResponse)
                .with_data("iteration", json!(iteration))
                .with_data("has_tool_calls", json!(!response.tool_calls.is_empty()))
                .with_data("stop_reason", json!(response.stop_reason))
                .with_data("usage", json!(usage));
            self.hooks.trigger(&ctx);

            if !response.thinking.is_empty() {
                self.emit(AgentEvent::Thinking { text: &response.thinking });
            }
            if response.tool_calls.is_empty() {
                self.push(trajectory(Message::assistant(&response.content)))?;
                self.emit_assistant_text(&response.content);
                // A steer that arrived while the answer was being written gets
                // a reply in this turn rather than being left for the next.
                if iteration < budget && self.control.has_steers() && !self.control.is_cancelled() {
                    last_content = response.content.clone();
                    continue;
                }
                // Claude Code Stop hooks can keep the turn going, with the
                // reason as the next message (capped to avoid loops).
                if iteration < budget
                    && !self.control.is_cancelled()
                    && let Some(reason) = self.run_claude_stop_hooks()
                {
                    self.push(Message::user(&reminders::wrap(&reason)))?;
                    last_content = response.content.clone();
                    continue;
                }
                final_response = Some(response.content.clone());
                break;
            }

            last_content = response.content.clone();
            self.push(trajectory(Message::assistant_with_tools(&response.content, response.tool_calls.clone())))?;
            self.emit_assistant_text(&response.content);
            for tool_call in &response.tool_calls {
                if self.control.is_cancelled() {
                    self.push(Message::tool_error(&tool_call.id, &tool_call.name, CANCELLED_TOOL_RESULT))?;
                    self.emit(AgentEvent::ToolResult { call: tool_call, ok: false, output: CANCELLED_TOOL_RESULT });
                    continue;
                }
                // Trigger before_tool_call hook. Include the permission
                // decision so observers can tell an allowed call from one the
                // policy will deny (issue #92: `before_tool_call` fires before
                // the permission check, so without this it couldn't).
                let permission = match self.policy.check(&tool_call.name, &tool_call.arguments) {
                    Ok(()) => "allow".to_string(),
                    Err(reason) => format!("deny: {reason}"),
                };
                let ctx = HookContext::new(HookEvent::BeforeToolCall)
                    .with_data("tool_name", json!(&tool_call.name))
                    .with_data("tool_call_id", json!(&tool_call.id))
                    .with_data("arguments", tool_call.arguments.clone())
                    .with_data("permission", json!(permission));
                self.hooks.trigger(&ctx);
                self.emit(AgentEvent::ToolCall { call: tool_call });
                self.set_activity(Activity::Tool(tool_call.name.clone()));

                // Claude Code PreToolUse hooks run after the permission check,
                // before the tool runs: they can deny the call, rewrite its
                // input, or add context for the model.
                let mut effective_arguments = tool_call.arguments.clone();
                let mut hook_context: Vec<String> = Vec::new();
                let mut pre_hook_deny: Option<String> = None;
                if let Some(claude_hooks) = self.claude_hooks.as_ref() {
                    let runnable = tool_call.raw_arguments_error(response.stop_reason.as_deref()).is_none()
                        && !(self.control.mode() == crate::mode::AgentMode::Plan
                            && !crate::mode::plan_allows(&tool_call.name))
                        && self.policy.check(&tool_call.name, &tool_call.arguments).is_ok();
                    if runnable {
                        let outcome =
                            claude_hooks.run_pre_tool_use(&tool_call.name, &tool_call.arguments, &tool_call.id);
                        // A hook's `additionalContext` applies whatever the
                        // decision: a deny/ask hook can still have useful context
                        // for the model (e.g. why the call is risky), so collect
                        // it independently of the decision. Input rewrites, by
                        // contrast, only apply to a call that is allowed to run.
                        if let Some(ctx) = outcome.context_block() {
                            hook_context.push(ctx);
                        }
                        if outcome.denies() {
                            pre_hook_deny = Some(
                                outcome.block_reason.unwrap_or_else(|| "blocked by a PreToolUse hook".to_string()),
                            );
                        } else if outcome.decision == Some(claude_hooks::Decision::Ask) {
                            // A hook asked for confirmation (`ask`), possibly
                            // overriding another hook's `allow`. nano has no
                            // interactive hook-approval step in Phase 1, so fail
                            // closed and block the call rather than letting an
                            // unapproved tool run — matching the fail-safe stance
                            // nano takes elsewhere for PreToolUse.
                            pre_hook_deny = Some(
                                outcome
                                    .block_reason
                                    .filter(|r| !r.trim().is_empty())
                                    .unwrap_or_else(|| {
                                        "a PreToolUse hook requested confirmation (ask), which nano cannot prompt for yet; blocking the call"
                                            .to_string()
                                    }),
                            );
                        } else if let Some(updated) = &outcome.updated_input {
                            effective_arguments =
                                claude_hooks::apply_updated_input(&tool_call.name, &tool_call.arguments, updated);
                        }
                    }
                }

                // A PreToolUse hook may have rewritten the arguments into
                // `effective_arguments`. From here on that rewritten input is the
                // single source of truth for what actually runs: build an
                // effective call and dispatch every branch against it. Reading the
                // original `tool_call.arguments` below would let a hook rewrite
                // bypass the permission policy, be silently dropped by a special-
                // tool branch (plan/skill/history/memory/outcome), or point the
                // nested-instructions lookup at the wrong file.
                let rewritten_call = if effective_arguments == tool_call.arguments {
                    None
                } else {
                    let mut call = tool_call.clone();
                    call.arguments = effective_arguments.clone();
                    Some(call)
                };
                let effective_call: &ToolCall = rewritten_call.as_ref().unwrap_or(tool_call);

                let is_plan_tool = self.config.plan_tools && plan::is_plan_tool(&tool_call.name);
                let is_outcome_tool = self.config.outcome_tool && tool_call.name == goal::TOOL_NAME;
                let is_skill_tool = tool_call.name == skills::TOOL_NAME && !self.skills.is_empty();
                let is_history_tool = history::is_history_tool(&tool_call.name) && self.history_tools_enabled();
                let is_memory_tool = memory::is_memory_tool(&tool_call.name) && self.memory_enabled();
                // Whether a tool handler actually ran. The pre-dispatch
                // rejections below (malformed input, plan-mode, policy, a
                // PreToolUse deny) never invoke a handler, so a PostToolUse hook
                // with side effects must not fire for them — it runs only after
                // a real dispatch (issue #92 scopes PostToolUse to tools that
                // ran, including ones that then errored).
                let mut dispatched = false;
                let result = if let Some(error) = tool_call.raw_arguments_error(response.stop_reason.as_deref()) {
                    // The argument JSON arrived malformed (usually a truncated
                    // stream). Don't run anything against garbage arguments and
                    // don't let a handler misreport it as a missing field —
                    // hand the model a clear, actionable error so it retries.
                    Err(anyhow::anyhow!(error))
                } else if self.control.mode() == crate::mode::AgentMode::Plan
                    && !crate::mode::plan_allows(&tool_call.name)
                {
                    // Backstop for a mutating call already in flight when plan
                    // mode was switched on mid-turn.
                    Err(anyhow::anyhow!("{} is disabled in plan mode (read-only)", tool_call.name))
                } else if let Err(reason) = self.policy.check(&effective_call.name, &effective_call.arguments) {
                    // The policy is consulted before dispatching to any handler, so deny
                    // rules and the pre-tool check also cover plan, skill and outcome tools.
                    // Re-check the *effective* (possibly hook-rewritten) arguments here:
                    // the earlier check ran on the original input, so without this a
                    // PreToolUse hook could rewrite a bash command or a file path past
                    // the user's allow/deny rules.
                    Err(anyhow::anyhow!(reason))
                } else if let Some(reason) = pre_hook_deny {
                    // A PreToolUse hook denied the call (or failed closed).
                    Err(anyhow::anyhow!(reason))
                } else if is_plan_tool {
                    dispatched = true;
                    self.run_plan_tool(effective_call)
                } else if is_skill_tool {
                    dispatched = true;
                    self.skills.load(&effective_call.arguments).map(Value::String)
                } else if is_history_tool {
                    dispatched = true;
                    self.run_history_tool(effective_call).map(Value::String)
                } else if is_memory_tool {
                    dispatched = true;
                    self.run_memory_tool(effective_call).map(Value::String)
                } else if is_outcome_tool {
                    dispatched = true;
                    Outcome::from_args(&effective_call.arguments).map(|outcome| {
                        let text = format!("Recorded outcome: {}. Your turn ends now.", outcome.status.as_str());
                        reported = Some(outcome);
                        Value::String(text)
                    })
                } else {
                    // Tool handlers are synchronous and may block (e.g. bash).
                    dispatched = true;
                    self.tools.execute_blocking(&effective_call.name, effective_call.arguments.clone()).await
                };
                let mut ok = result.is_ok();
                let result = match result {
                    Ok(value) => value,
                    Err(e) => json!({ "error": e.to_string() }),
                };

                // Trigger after_tool_call hook
                let ctx = HookContext::new(HookEvent::AfterToolCall)
                    .with_data("tool_name", json!(&tool_call.name))
                    .with_data("tool_call_id", json!(&tool_call.id))
                    .with_data("result", result.clone());
                self.hooks.trigger(&ctx);

                // A `read_file` image result carries the source bytes; turn it
                // into a message attachment (downscaled to the model's limits)
                // when the model can view images, else a text error with a hint.
                let mut attachments: Vec<crate::llm::Attachment> = Vec::new();
                let mut result_text = match result {
                    Value::String(text) => text,
                    // Only `read_file` owns the private `{"image": …}` result
                    // protocol. Any other tool that returns a structured value
                    // (even one with a top-level `image` field) is stringified
                    // unchanged, so it is never misread as an attachment or a
                    // spurious "image result had no data" error.
                    other if tool_call.name == "read_file" => match self.image_result(&other) {
                        Ok(Some((text, found))) => {
                            attachments = found;
                            text
                        }
                        Ok(None) => other.to_string(),
                        // The image read fine but the model can't view it: surface
                        // it as a tool error so the model treats it as a failure.
                        Err(text) => {
                            ok = false;
                            text
                        }
                    },
                    other => other.to_string(),
                };
                // A non-image binary file takes read_file's generic "looks
                // like a binary file" error, which cannot name the model's
                // image capability itself. Append that context here so the
                // message says whether this model could have viewed an image
                // (README "Vision").
                if !ok && tool_call.name == "read_file" && result_text.contains("looks like a binary file") {
                    result_text.push_str(&self.binary_vision_hint());
                }
                if ok
                    && matches!(tool_call.name.as_str(), "read_file" | "write_file" | "edit_file")
                    && let Some(path) = effective_call.arguments.get("path").and_then(Value::as_str)
                    && let Some(nested) =
                        self.instructions.as_mut().and_then(|i| i.nested_for(std::path::Path::new(path)))
                {
                    result_text.push_str(&nested);
                }
                // bash, read_file and load_skill bound their own output (and bash keeps the whole).
                if !matches!(tool_call.name.as_str(), "bash" | "read_file" | history::READ_TOOL) && !is_skill_tool {
                    let name = format!("tool-{}-{}.txt", sanitize(&tool_call.id), sanitize(&tool_call.name));
                    result_text =
                        output::bound_and_spill(&result_text, self.tool_output_limit, &self.spill_dir(), &name);
                }
                // Claude Code PostToolUse hooks: add context for the model, or
                // block with feedback. Combined with any PreToolUse context.
                // Only after a handler actually ran — a blocked/rejected call
                // (policy, plan mode, malformed input, a PreToolUse deny) never
                // reached a tool, so its PostToolUse side effects must not fire.
                if dispatched && let Some(hooks) = &self.claude_hooks {
                    let outcome =
                        hooks.run_post_tool_use(&tool_call.name, &effective_arguments, &result_text, &tool_call.id);
                    if let Some(ctx) = outcome.context_block() {
                        hook_context.push(ctx);
                    }
                    if outcome.blocked
                        && let Some(reason) = outcome.block_reason.filter(|r| !r.trim().is_empty())
                    {
                        hook_context.push(reason);
                    }
                }
                for ctx in &hook_context {
                    result_text.push_str("\n\n");
                    result_text.push_str(&reminders::wrap(ctx));
                }
                if self.config.reminders && !is_plan_tool && !is_outcome_tool {
                    if ok && tool_call.name == memory::SAVE_TOOL {
                        self.reminders.memory_saved();
                    }
                    let memory_writable = self.memory_enabled() && self.memory_writable();
                    for note in self.reminders.after_tool_call(&self.plan, memory_writable) {
                        result_text.push_str("\n\n");
                        result_text.push_str(&reminders::wrap(&note));
                    }
                }
                if history::is_history_tool(&tool_call.name) {
                    self.history_hint_pending = false;
                } else if history::looks_failed(&tool_call.name, ok, &result_text)
                    && self.history_hint_pending
                    && self.history_tools_enabled()
                {
                    self.history_hint_pending = false;
                    result_text.push_str("\n\n");
                    result_text.push_str(history::FAILED_TOOL_HINT);
                }
                // The display output (trajectory event, ACP) notes each attached
                // image as `[image: path, WxH]`; the model-facing `result_text`
                // stays the short text part.
                let mut display_output = result_text.clone();
                for attachment in &attachments {
                    if !display_output.is_empty() {
                        display_output.push('\n');
                    }
                    display_output.push_str(&attachment.placeholder());
                }
                let message = if ok {
                    Message::tool_result(&tool_call.id, &tool_call.name, &result_text)
                } else {
                    Message::tool_error(&tool_call.id, &tool_call.name, &result_text)
                }
                .with_attachments(attachments);
                self.push(message)?;
                self.emit(AgentEvent::ToolResult { call: tool_call, ok, output: &display_output });
            }
            self.refresh_stats();
            if reported.is_some() {
                // A reported outcome ends the turn like a tool-free answer, so it
                // must pass the same Stop gate: a Stop hook may ask the agent to
                // keep going (capped). If it does, clear the reported outcome —
                // the turn is no longer complete — and continue the loop.
                if iteration < budget
                    && !self.control.is_cancelled()
                    && let Some(reason) = self.run_claude_stop_hooks()
                {
                    self.push(Message::user(&reminders::wrap(&reason)))?;
                    last_content = reported.take().map(|outcome| outcome.response()).unwrap_or_default();
                    continue;
                }
                // Every call in the batch has its result; the summary is the answer.
                let response = reported.as_ref().expect("checked").response();
                self.push(Message::assistant(&response))?;
                self.emit_assistant_text(&response);
                final_response = Some(response);
                break;
            }
        }
        self.set_activity(Activity::Idle);
        self.refresh_stats();

        let stop_reason = if cancelled || (final_response.is_none() && self.control.is_cancelled()) {
            StopReason::Cancelled
        } else if final_response.is_some() {
            StopReason::EndTurn
        } else {
            StopReason::MaxTurnRequests
        };
        let response = match stop_reason {
            StopReason::EndTurn => final_response.unwrap_or_default(),
            StopReason::Cancelled => CANCELLED_RESPONSE.to_string(),
            StopReason::MaxTurnRequests => {
                // `iteration` was incremented past the cap before the loop
                // broke, so the number of completed calls is one fewer.
                let completed = iteration.saturating_sub(1);
                format!("{last_content}\n[stopped after {completed} LLM calls without a final answer]")
                    .trim_start()
                    .to_string()
            }
        };
        let outcome = reported.filter(|_| stop_reason == StopReason::EndTurn);
        let (response, outcome) = self.finish_turn(input_id, response, outcome)?;
        Ok(TurnOutcome { response, stop_reason, outcome })
    }

    fn finish_turn(
        &mut self,
        input_id: String,
        response: String,
        outcome: Option<Outcome>,
    ) -> Result<(String, Option<Outcome>)> {
        if let Some(log) = &mut self.session {
            log.append(&Record::TurnEnd {
                input_id: input_id.clone(),
                response: response.clone(),
                outcome: outcome.clone(),
                history_calls: self.turn_history_calls,
                recorded_at: session::now(),
            })?;
            // Keep the `--resume` picker's summary current. Only a cache:
            // the picker rebuilds a missing or stale summary from the log.
            let model = format!("{}/{}", self.client.provider_name(), self.client.model_name());
            let from = self.turn_log_offset.unwrap_or(0);
            // `update` folds every input record committed to the log since
            // `from` straight from the log's tail, so a resumed pending input
            // (which lies before `from`) is never recounted and a concurrent
            // writer's prompt (after `from`) is never lost.
            if let Ok(summary) = crate::session_index::update(log.path(), from, Some(model)) {
                let path = log.path().to_path_buf();
                self.request_title(path, &summary);
            }
        }
        match &outcome {
            Some(outcome) => self.completed_outcomes.insert(input_id.clone(), outcome.clone()),
            None => self.completed_outcomes.remove(&input_id),
        };
        self.completed_inputs.insert(input_id, response.clone());
        self.pending_input = None;
        Ok((response, outcome))
    }

    /// Summarize older messages into one, keeping recent messages (and the
    /// in-flight turn's user message) verbatim. `instructions` steer what the
    /// summary focuses on; `mode` overrides `compaction_mode` for this call.
    /// Returns `None` when there is nothing to compact.
    pub async fn compact(
        &mut self,
        mode: Option<CompactionMode>,
        instructions: Option<&str>,
    ) -> Result<Option<CompactReport>> {
        self.control.start_turn();
        let mode = mode.unwrap_or(self.config.compaction_mode);
        let report = self.compact_logged(CompactTrigger::Manual, mode, instructions).await;
        self.set_activity(Activity::Idle);
        report
    }

    fn over_threshold(&self) -> bool {
        if !self.config.auto_compact {
            return false;
        }
        let threshold = self.config.auto_compact_threshold.clamp(0.1, 0.99);
        let (tokens, _) = self.estimate_context_tokens();
        let window = self.context_window();
        // Endpoints such as vLLM and Splash reject a request whose prompt plus
        // `max_tokens` exceeds the window, so the output reservation counts
        // against the window too — unless the window caps the prompt alone
        // (GitHub Copilot's `max_prompt_tokens`), where output tokens do not
        // consume it and reserving them would compact early. `request_max_tokens`
        // shrinks the reservation down to MIN_OUTPUT_RESERVE; compact before even
        // that would not fit. A prompt-only cap still keeps the estimation
        // margin: the prompt estimate can undercount, and without the margin a
        // prompt estimated just under the cap could really exceed it and be
        // rejected.
        let reserved = match self.context_cap() {
            ContextCap::Total => {
                (self.config.max_tokens.max(0) as usize).min(MIN_OUTPUT_RESERVE) + output_margin(window)
            }
            ContextCap::Prompt => output_margin(window),
        };
        let limit = (window as f64 * threshold).min(window.saturating_sub(reserved) as f64);
        // A prompt-only cap does not consume output tokens, but the endpoint's
        // larger combined window still bounds prompt + output. When the gap
        // between the two is under the reserve, a prompt can sit below the
        // prompt threshold while leaving too little output room in the combined
        // window — `request_max_tokens()` would then shrink `max_tokens` below
        // the target instead of compacting. Compact against the combined window
        // too, so the reservation is carved out of whichever limit is tighter.
        let limit = match self.combined_window() {
            Some(combined) if self.context_cap() == ContextCap::Prompt => {
                let combined_reserved =
                    (self.config.max_tokens.max(0) as usize).min(MIN_OUTPUT_RESERVE) + output_margin(combined);
                limit.min(combined.saturating_sub(combined_reserved) as f64)
            }
            _ => limit,
        };
        tokens as f64 > limit && tokens > self.compact_floor + window / 10
    }

    /// `max_tokens` for the next request: the configured value, lowered so the
    /// estimated prompt plus the reservation fits the context window (with a
    /// margin for estimation error). Aims to keep MIN_OUTPUT_RESERVE of output
    /// space, but never requests more than the room actually left: when fewer
    /// than MIN_OUTPUT_RESERVE tokens remain and pre-send compaction is
    /// unavailable (`auto_compact` disabled) or suppressed by the `compact_floor`
    /// guard, capping to the real room keeps `prompt + max_tokens` inside the
    /// window instead of overflowing it. Always at least 1 so the request is valid.
    ///
    /// A prompt-only window (GitHub Copilot's `max_prompt_tokens`) caps the prompt
    /// alone, so output room is not carved out of it — but the endpoint's larger
    /// combined window still bounds prompt + output, so `max_tokens` is capped to
    /// the room left in *that* window rather than sent unchanged.
    fn request_max_tokens(&self) -> i64 {
        let configured = self.config.max_tokens.max(1) as usize;
        let (tokens, _) = self.estimate_context_tokens();
        if self.context_cap() == ContextCap::Prompt {
            // The prompt cap does not consume output tokens; only the combined
            // window (when the endpoint advertised one, tightened by any learned
            // overflow limit) limits prompt + output.
            let Some(combined) = self.combined_window() else {
                return configured as i64;
            };
            let room = combined.saturating_sub(tokens + output_margin(combined));
            return configured.min(room).max(1) as i64;
        }
        let window = self.context_window();
        let room = window.saturating_sub(tokens + output_margin(window));
        configured.min(room).max(1) as i64
    }

    async fn compact_logged(
        &mut self,
        trigger: CompactTrigger,
        mode: CompactionMode,
        instructions: Option<&str>,
    ) -> Result<Option<CompactReport>> {
        self.set_activity(Activity::Compacting);
        let report = self.compact_with(trigger, mode, instructions).await?;
        if let Some(report) = &report {
            self.compact_floor = report.tokens_after;
            if trigger != CompactTrigger::Manual {
                eprintln!("[agent] auto-{report}");
            }
            self.stats.lock().unwrap().compactions += 1;
            self.emit(AgentEvent::Compacted);
        }
        self.refresh_stats();
        Ok(report)
    }

    async fn compact_with(
        &mut self,
        trigger: CompactTrigger,
        mode: CompactionMode,
        instructions: Option<&str>,
    ) -> Result<Option<CompactReport>> {
        // Smart compaction points into the session log; without one it
        // falls back to a plain summary.
        let mode = if self.session.is_some() { mode } else { CompactionMode::Standard };
        let smart = mode == CompactionMode::Smart;
        let window = self.context_window();
        let body_start = usize::from(self.conversation.first().is_some_and(|m| m.role == Role::System));
        let len = self.conversation.len();
        // A manual compaction keeps only the latest message verbatim.
        let keep_budget = match trigger {
            CompactTrigger::Manual => 0,
            _ => context::KEEP_RECENT_TOKENS.min(window / 4),
        };

        // Split where no tool result is separated from its call: the kept
        // tail starts at a user or assistant message.
        let boundaries: Vec<usize> = (body_start + 1..len)
            .filter(|&i| matches!(self.conversation[i].role, Role::User | Role::Assistant))
            .collect();
        let Some(&last_boundary) = boundaries.last() else { return Ok(None) };
        let mut split = last_boundary;
        let mut tail_tokens = 0;
        let mut next = len;
        for &boundary in boundaries.iter().rev() {
            tail_tokens += context::messages_tokens(&self.conversation[boundary..next]);
            next = boundary;
            if tail_tokens > keep_budget {
                break;
            }
            split = boundary;
        }
        if split == boundaries[0] {
            // Everything fits the keep budget, but the context is still too
            // big (a small window): summarize all but the latest message.
            split = last_boundary;
        }
        let (tokens_before, _) = self.estimate_context_tokens();
        let summarized = &self.conversation[body_start..split];
        if summarized.is_empty() {
            return Ok(None);
        }
        // The real turns about to be folded into the summary, kept so a later
        // legacy → frame switch can replay them (see `replace_keeping_pending`).
        // On a *repeated* compaction the first summarized message is the
        // previous synthetic summary and the stash of real turns lives in
        // `pre_compaction_transcript`: expand that summary back to its real
        // turns and append only the newly folded ones, so the earlier history
        // is preserved rather than displayed as the older summary. Any
        // synthetic restatement a prior compaction appended (tracked by
        // `pre_compaction_restated`) is dropped from the stash too, so it never
        // carries forward as a replayed duplicate.
        let summarized_msgs = match &self.pre_compaction_transcript {
            Some(prev) => {
                let mut turns = prev.clone();
                for (offset, message) in summarized.iter().enumerate().skip(1) {
                    if self.pre_compaction_restated == Some(body_start + offset) {
                        continue;
                    }
                    turns.push(message.clone());
                }
                turns
            }
            None => summarized.to_vec(),
        };

        let output_budget = context::summary_output_budget(window, self.config.max_tokens as i64);
        // The transcript and the summary's own output share the request budget.
        // Against a total/combined cap the prompt and output must fit together,
        // so the output budget is carved out of the window. A prompt-only cap
        // (GitHub Copilot's `max_prompt_tokens`) does not spend output tokens,
        // so the transcript gets the whole prompt window; only a combined window
        // the endpoint advertised still bounds prompt + output. This mirrors
        // `request_max_tokens()`'s cap handling.
        let input_window = match self.context_cap() {
            ContextCap::Prompt => match self.combined_window() {
                Some(combined) => window.min(combined.saturating_sub(output_budget as usize)),
                None => window,
            },
            ContextCap::Total => window.saturating_sub(output_budget as usize),
        };
        let summary_input_chars = input_window.saturating_sub(2_000).max(2_000) * 3;
        let transcript = context::render_transcript(summarized, summary_input_chars, smart);
        let lines: Vec<u64> = summarized.iter().filter_map(|m| m.log_line).collect();
        let range = lines.iter().min().zip(lines.iter().max()).map(|(a, b)| (*a, *b));
        let mut request_text = format!("Conversation to summarize:\n\n{transcript}");
        if let Some(focus) = instructions.map(str::trim).filter(|f| !f.is_empty()) {
            request_text.push_str(&format!("\n\nWhen summarizing, focus on: {focus}"));
        }
        let system_prompt = if smart {
            format!("{}{}", context::SUMMARY_SYSTEM_PROMPT, context::SMART_SUMMARY_INSTRUCTIONS)
        } else {
            context::SUMMARY_SYSTEM_PROMPT.to_string()
        };
        let summary_messages = [Message::system(&system_prompt), Message::user(&request_text)];
        let request = ChatRequest {
            messages: &summary_messages,
            tools: &[],
            // Compaction goes through the same resolution as a chat turn, so a
            // legacy `extra_body` temperature override still applies (the
            // transport no longer re-inserts it) and fixed-temperature models
            // still send none. This request sends no thinking field
            // (`thinking: None`), which turns thinking off only for a model
            // that supports an `off` level — so resolve temperature as
            // thinking-off there, and a configured temperature is not dropped
            // as if the configured level were sent. A model whose levels omit
            // `off` (Fable, Claude 5.5+) always thinks, so it still gets no
            // custom temperature.
            temperature: self.temperature_for(self.thinking().always_anthropic_thinking()).value(),
            max_tokens: Some(output_budget),
            // A summary needs no extended reasoning; the model's own default
            // applies, as before thinking levels existed.
            thinking: None,
            // The summary request never includes images: the transcript renders
            // them as text placeholders, and the freshly built summary messages
            // carry no attachments.
            vision: None,
            attachments_dir: None,
        };
        let control = self.control.clone();
        // Stream the summary even though its text is used only once complete.
        // A summary prompt is new text that no prefix cache holds. A local
        // model can take minutes to read it before sending its first token.
        // A non-streaming request sends no bytes in that time, so a proxy or
        // tunnel with an idle timeout drops it, and every retry starts over.
        // A stream carries the server's keepalives (and falls back to one
        // whole response for providers configured with `stream = false`).
        let discard = |_: StreamEvent<'_>| {};
        let result = tokio::select! {
            result = self.client.chat_stream(&request, &discard) => result,
            () = control.cancelled() => return Ok(None),
        };
        let mut truncated = false;
        let (summary, fallback) = match result {
            Ok(response) if !response.content.trim().is_empty() => {
                self.record_usage(&response, false);
                // A summary cut off at the output limit silently loses whatever
                // it had not reached yet; say so, so the agent re-checks state
                // instead of trusting an incomplete record.
                truncated = crate::llm::stop_reason_is_length(response.stop_reason.as_deref());
                let mut body = response.content.trim().to_string();
                if truncated {
                    body.push_str(context::SUMMARY_TRUNCATED_NOTE);
                }
                let summary = if smart {
                    format!("{}\n{}\n\n{}", context::SMART_SUMMARY_PREFIX, body, context::smart_summary_note(range))
                } else {
                    format!("{}\n{}", context::SUMMARY_PREFIX, body)
                };
                (summary, None)
            }
            Ok(response) => {
                // An empty summary can still have burned the whole output
                // allowance on reasoning; account for it like any other
                // successful response so the status line and `/context` do not
                // under-report this compaction request. Computed before the
                // mutable borrow in `record_usage`.
                let dropped = self.dropped_note(summarized.len(), smart.then_some(range).flatten());
                let reason = if crate::llm::stop_reason_is_length(response.stop_reason.as_deref()) {
                    "empty summary: the output limit was reached before any summary text".to_string()
                } else {
                    "empty summary".to_string()
                };
                self.record_usage(&response, false);
                (dropped, Some(reason))
            }
            Err(e) => (self.dropped_note(summarized.len(), smart.then_some(range).flatten()), Some(format!("{e:#}"))),
        };

        let mut messages: Vec<Message> = self.conversation[..body_start].to_vec();
        let summary = if self.config.plan_tools && !self.plan.is_empty() {
            format!("{summary}\n\n{}", self.plan.context_note())
        } else {
            summary
        };
        messages.push(Message::user(&summary));
        // When the active input is itself folded into the summary it is
        // restated after it; `restated_index` records where, so the replay can
        // skip that synthetic copy (the original is in `summarized_msgs`).
        let mut restated_index = None;
        let pending_position = match &self.pending_input {
            // The in-flight input was folded into the summary: restate it.
            Some(pending) if pending.position < split => {
                messages.push(Message::user(&pending.text));
                let idx = messages.len() - 1;
                restated_index = Some(idx);
                Some(idx)
            }
            Some(pending) => Some(pending.position - split + messages.len()),
            None => None,
        };
        messages.extend(self.conversation[split..].iter().cloned());
        if trigger != CompactTrigger::Manual {
            // A single huge tool result can still overflow on its own.
            for message in messages.iter_mut().skip(body_start + 1).filter(|m| m.role == Role::Tool) {
                if context::clip_message(message, (window / 8).max(1_000))
                    && smart
                    && let Some(line) = message.log_line
                {
                    message.content.push_str(&format!("\n[clipped at compaction; history_read #{line} has it whole]"));
                }
            }
        }

        let summarized = split - body_start;
        // The folded turns ride along so `replay_history` can restore them on
        // a legacy → frame switch (the frame's first redraw clears the legacy
        // scrollback, and the compacted conversation holds only the summary).
        self.replace_keeping_pending(
            messages,
            pending_position,
            Some(CompactionRecord { range, mode, folded: summarized_msgs, restated: restated_index }),
        )?;
        if let Some(instructions) = &mut self.instructions {
            instructions.forget_nested();
        }
        Ok(Some(CompactReport {
            messages_before: len,
            messages_after: self.conversation.len(),
            tokens_before,
            tokens_after: self.estimate_context_tokens().0,
            summarized,
            fallback,
            truncated,
            mode,
        }))
    }

    fn run_plan_tool(&mut self, call: &ToolCall) -> Result<Value> {
        let outcome = self.plan.apply(&call.name, &call.arguments)?;
        if outcome.changed {
            self.plan_changed()?;
        }
        Ok(Value::String(outcome.text))
    }

    #[cfg(test)]
    fn set_tool_output_limit(&mut self, limit: usize) {
        self.tool_output_limit = limit;
    }

    /// Stand-in for a failed summary. Given the dropped log range (smart
    /// mode), it is a smart summary too, so the history tools stay offered.
    fn dropped_note(&self, count: usize, range: Option<(u64, u64)>) -> String {
        let note =
            format!("[{count} earlier messages were removed to fit the context window; no summary is available]");
        match range {
            Some(range) => {
                format!("{}\n{note}\n\n{}", context::SMART_SUMMARY_PREFIX, context::smart_summary_note(Some(range)))
            }
            None => note,
        }
    }

    fn run_history_tool(&mut self, call: &ToolCall) -> Result<String> {
        let path = self.session_path().ok_or_else(|| anyhow::anyhow!("no session log"))?.to_path_buf();
        self.turn_history_calls += 1;
        let read = call.name == history::READ_TOOL;
        {
            let mut stats = self.stats.lock().unwrap();
            if read { stats.history_reads += 1 } else { stats.history_searches += 1 }
        }
        if read {
            history::read(&path, &call.arguments, &self.spill_dir())
        } else {
            history::search(&path, &call.arguments)
        }
    }

    fn run_memory_tool(&mut self, call: &ToolCall) -> Result<String> {
        let store = self.memory.as_ref().ok_or_else(|| anyhow::anyhow!("memory is disabled"))?;
        // Read-only memory offers only search; refuse a save/forget that
        // arrived anyway (e.g. an in-flight call from before a mode change).
        if !self.config.memory.writable() && call.name != memory::SEARCH_TOOL {
            return Err(anyhow::anyhow!("{} is disabled: memory is read-only here", call.name));
        }
        let session = self.session_id.as_deref();
        // A search must not mutate the store when the session is read-only —
        // either because the agent is in Plan mode, OR because memory is
        // configured read-only (`MemoryMode::ReadOnly`, e.g. a configured
        // read-only session or any ACP/headless session downgraded to it).
        // Checking only Plan mode let a configured read-only search still reach
        // the mutating path, where it acquires locks, prunes expired records,
        // bumps `last_used`, and rewrites the JSONL file (Copilot finding,
        // src/agent.rs). Route search through the read-only path in both cases
        // so it neither bumps `last_used` nor prunes/rewrites the store.
        let read_only = self.control.mode() == crate::mode::AgentMode::Plan || !self.config.memory.writable();
        // A mode switch can land after the outer dispatch gate but before this
        // handler runs (the control is switchable while a turn holds `&mut
        // Agent`). `memory::run` only honours `read_only` for search — save and
        // forget mutate unconditionally — so re-check the mode here and refuse a
        // mutating op that arrived while the agent is in Plan mode, or it would
        // write to the store despite the read-only guarantee (Copilot finding,
        // src/agent.rs).
        if read_only && call.name != memory::SEARCH_TOOL {
            return Err(anyhow::anyhow!("{} is disabled in plan mode (read-only)", call.name));
        }
        let result = memory::run(store, &call.name, &call.arguments, session, read_only);
        // Any non-plan memory op can change the folded system-prompt index — a
        // save adds an entry, a matching search bumps `last_used` (and may
        // prune), a forget deletes one — so drop the cached index; the next
        // prompt rebuild re-reads the store. A plan-mode/read-only search never
        // mutates, so it need not invalidate.
        //
        // Invalidate on *every* non-plan op, not only on `Ok`: a failed mutating
        // operation can already have changed disk state — `read_scope_file(..,
        // true)` may prune a scope before a later error, and a two-scope search
        // may write the first scope before the second write fails — so the
        // cached prompt could otherwise retain expired entries or a stale MRU
        // ordering. Invalidating on an error with no mutation is harmless
        // (Copilot finding, src/agent.rs).
        if !read_only {
            self.memory_index_cache = None;
        }
        // A successful forget deletes an entry the folded system-prompt index
        // still shows; rebuild it so the removed fact leaves the active prompt
        // at once rather than resurfacing on the next turn.
        if call.name == memory::FORGET_TOOL && result.is_ok() {
            self.refresh_memory_index();
        }
        result
    }

    /// Get conversation length
    #[cfg(test)]
    pub fn conversation_length(&self) -> usize {
        self.conversation.len()
    }

    #[cfg(test)]
    pub fn conversation(&self) -> &[Message] {
        &self.conversation
    }
}

/// Keep only characters that are safe in a file name.
fn sanitize(text: &str) -> String {
    text.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).take(64).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::{LLMResponse, ToolCall};
    use crate::tools::ToolDefinition;
    use async_trait::async_trait;
    use std::sync::{Arc, Mutex};

    #[tokio::test(flavor = "multi_thread")]
    async fn failed_model_switch_restores_the_previous_spec() {
        // A `/model` spec that cannot build a client must not leave
        // `config.model` naming the rejected spec while the session keeps the
        // old client: the switch is atomic. (An unknown provider is not a
        // failure — the spec falls back to the default provider — so the
        // failing build is a provider whose `api_key_command` cannot run.)
        let mut config = Config::default();
        config.providers.insert(
            "broken".to_string(),
            providers::ProviderConfig {
                kind: Some(providers::ProviderKind::Openai),
                base_url: Some("http://localhost:9".to_string()),
                api_key_command: Some("definitely-not-a-real-command-nano".to_string()),
                ..Default::default()
            },
        );
        let mut agent = Agent::new(Box::new(providers::mock::MockLLMClient::new("mock", "gpt-4o-mini")), config);
        let before = agent.config().model.clone();
        let error = agent.set_model("broken/some-model").await.unwrap_err();
        assert!(format!("{error:#}").contains("definitely-not-a-real-command-nano"), "unexpected error: {error:#}");
        assert_eq!(agent.config().model, before, "config keeps the spec still in use");
        assert_eq!(agent.model_name(), "gpt-4o-mini", "the live client is unchanged");
        // …and a valid spec still switches.
        agent.set_model("mock/other-model").await.unwrap();
        assert_eq!(agent.config().model, "mock/other-model");
        assert_eq!(agent.model_name(), "other-model");
    }

    #[test]
    fn replay_history_replays_every_user_message() {
        // A renderer switch replays the conversation into the newly active
        // renderer via the installed sink. The interactive prompt's in-flight
        // line is not part of the conversation (it is recorded only when
        // submitted), so no user message is skipped — including a trailing one
        // with no assistant reply yet, and repeated texts.
        let mut agent =
            Agent::new(Box::new(providers::mock::MockLLMClient::new("mock", "gpt-4o-mini")), Config::default());
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen_sink = seen.clone();
        agent.set_event_sink(Box::new(move |_, event| {
            if let AgentEvent::UserMessage { text } = event {
                seen_sink.lock().unwrap().push(text.to_string());
            }
        }));
        agent.conversation.push(Message::user("same"));
        agent.conversation.push(Message::assistant("first answer"));
        agent.conversation.push(Message::user("same"));
        agent.replay_history();
        assert_eq!(*seen.lock().unwrap(), vec!["same".to_string(), "same".to_string()]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn replay_history_after_compaction_restores_real_turns_not_summary() {
        // A legacy → frame renderer switch replays history into a frame whose
        // first redraw clears the legacy scrollback, so the replay is the only
        // copy of the visible transcript. After a compaction the conversation
        // holds the synthetic summary where the folded turns were: the replay
        // must restore the REAL pre-compaction turns from the captured stash
        // and never expose the summary as a user turn.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _seen) = agent(vec![tool_call("c1"), text("done"), text("SUMMARY: pinged once")], dir.path());
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, Some("the ping")).await.unwrap().expect("compacted");
        assert!(report.summarized > 0);
        // The compacted conversation really did fold the turns into a summary.
        assert!(agent.conversation().iter().any(|m| m.role == Role::User && m.content.contains("SUMMARY")));
        assert!(!agent.conversation().iter().any(|m| m.role == Role::User && m.content == "ping"));

        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen_sink = seen.clone();
        agent.set_event_sink(Box::new(move |_, event| {
            if let AgentEvent::UserMessage { text } = event {
                seen_sink.lock().unwrap().push(text.to_string());
            }
        }));
        agent.replay_history();
        let users = seen.lock().unwrap().clone();
        assert!(users.contains(&"ping".to_string()), "real pre-compaction turn restored: {users:?}");
        assert!(!users.iter().any(|t| t.contains("SUMMARY")), "synthetic summary not exposed: {users:?}");

        // A legacy → frame → legacy → frame round trip replays history a
        // second time: the stash must persist across replays so the second
        // switch restores the real turns again instead of falling back to the
        // compacted conversation (which would expose the summary).
        seen.lock().unwrap().clear();
        agent.replay_history();
        let users = seen.lock().unwrap().clone();
        assert!(users.contains(&"ping".to_string()), "second replay still restores the real turn: {users:?}");
        assert!(!users.iter().any(|t| t.contains("SUMMARY")), "second replay still hides the summary: {users:?}");

        // A plain conversation replacement (no compaction — e.g. a system-prompt
        // change) must CLEAR the stash: replaying the new conversation must not
        // resurrect the folded turns or skip the first new user turn as though
        // it were a synthetic summary.
        agent.set_system_prompt("fresh prompt").unwrap();
        seen.lock().unwrap().clear();
        agent.replay_history();
        let users = seen.lock().unwrap().clone();
        assert!(!users.contains(&"ping".to_string()), "stale stash not resurrected after plain replacement: {users:?}");
        assert!(
            !users.iter().any(|t| t.contains("SUMMARY")),
            "summary not replayed after plain replacement: {users:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn replay_after_repeated_compaction_preserves_the_original_turns() {
        // A second compaction summarizes a conversation that already starts
        // with the first compaction's synthetic summary. Snapshotting that
        // slice verbatim would stash the older summary in place of the real
        // turns, so a later legacy → frame switch would drop the original
        // history and show that summary as a user message. The stash must
        // expand the previous summary back to its real turns and append only
        // the newly folded ones.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _seen) =
            agent(vec![text("r1"), text("SUMMARY: one"), text("r2"), text("SUMMARY: two")], dir.path());
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        assert!(agent.compact(None, None).await.unwrap().is_some());
        agent.send_message("pong").await.unwrap();
        assert!(agent.compact(None, None).await.unwrap().is_some());
        // Both compactions really folded their input away.
        assert!(!agent.conversation().iter().any(|m| m.role == Role::User && m.content == "ping"));
        assert!(!agent.conversation().iter().any(|m| m.role == Role::User && m.content == "pong"));

        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen_sink = seen.clone();
        agent.set_event_sink(Box::new(move |_, event| {
            if let AgentEvent::UserMessage { text } = event {
                seen_sink.lock().unwrap().push(text.to_string());
            }
        }));
        agent.replay_history();
        let users = seen.lock().unwrap().clone();
        assert!(users.contains(&"ping".to_string()), "first-compaction turn preserved: {users:?}");
        assert!(users.contains(&"pong".to_string()), "second-compaction turn preserved: {users:?}");
        assert!(!users.iter().any(|t| t.contains("SUMMARY")), "no synthetic summary exposed: {users:?}");
    }

    #[test]
    fn rate_meter_tracks_scripted_stream() {
        // A slow ~2 tok/s stream: 8 bytes (≈2 tokens) per second.
        let mut meter = RateMeter::default();
        let t0 = Instant::now();
        // First delta starts the clock; zero elapsed yields no rate yet.
        assert_eq!(meter.record(8, t0), None);
        // One second later, 16 bytes total ≈ 4 tokens over 1s → ~4 tok/s...
        let one = meter.record(8, t0 + Duration::from_secs(1)).expect("rate after first second");
        assert!((one - 4.0).abs() < 0.01, "got {one}");
        // ...settling toward ~2 tok/s as the stream continues at 8 bytes/sec.
        let mut last = one;
        for sec in 2..=8 {
            if let Some(rate) = meter.record(8, t0 + Duration::from_secs(sec)) {
                last = rate;
            }
        }
        // 72 bytes ≈ 18 tokens over 8s ≈ 2.25 tok/s.
        assert!((last - 2.25).abs() < 0.1, "settled rate {last}");
    }

    #[test]
    fn rate_meter_throttles_updates() {
        let mut meter = RateMeter::default();
        let t0 = Instant::now();
        assert_eq!(meter.record(100, t0), None); // first token, no rate
        // Emits once ~250ms in, then suppresses closely-spaced deltas.
        assert!(meter.record(100, t0 + Duration::from_millis(300)).is_some());
        assert!(meter.record(100, t0 + Duration::from_millis(350)).is_none());
        assert!(meter.record(100, t0 + Duration::from_millis(600)).is_some());
    }

    #[test]
    fn rate_meter_ignores_empty_deltas() {
        // Empty deltas must not start the clock; otherwise the idle gap before
        // real output arrives would depress the reported rate.
        let mut meter = RateMeter::default();
        let t0 = Instant::now();
        assert_eq!(meter.record(0, t0), None);
        // A real 4-byte (~1 token) delta one second later starts the clock now,
        // so the first published rate reflects only actual output.
        assert_eq!(meter.record(4, t0 + Duration::from_secs(1)), None);
        let rate = meter.record(4, t0 + Duration::from_millis(1_500)).expect("rate after real output");
        // 8 bytes ≈ 2 tokens over 0.5s ≈ 4 tok/s (not diluted by the empty delta).
        assert!((rate - 4.0).abs() < 0.01, "got {rate}");
    }

    #[test]
    fn rate_meter_finish_falls_back_to_usage_over_elapsed_for_one_shot() {
        // A whole completion handed over in a single delta (a `report_whole`
        // fallback, or any provider that returns one plain-JSON body): `record`
        // sees zero elapsed since the first token and never publishes a live
        // rate, but `finish` divides by the whole-call elapsed (from generation
        // start), so a one-shot response still reports the issue's `usage /
        // elapsed` average instead of a near-infinite delta-span division.
        let t0 = Instant::now();
        let mut meter = RateMeter::new(t0);
        assert_eq!(meter.record(400, t0), None); // single burst delta, no live rate
        // Exact usage wins over the byte estimate: 200 tokens over 2s = 100 tok/s.
        let rate = meter.finish(Some(200), t0 + Duration::from_secs(2)).expect("one-shot rate");
        assert!((rate - 100.0).abs() < 0.01, "got {rate}");
        // Without usage, fall back to the byte estimate (400 bytes ≈ 100 tokens / 2s).
        let est = meter.finish(None, t0 + Duration::from_secs(2)).expect("estimated rate");
        assert!((est - 50.0).abs() < 0.01, "got {est}");
        // No output delta ever streamed (e.g. a tool-call-only turn) → no rate,
        // even though exact usage is known: there is nothing that was generated
        // as visible output to meter.
        assert_eq!(RateMeter::new(t0).finish(Some(10), t0 + Duration::from_secs(1)), None);

        // `report_whole` emits a one-shot response's thinking and text as two
        // back-to-back callbacks microseconds apart. That sub-MULTI_DELTA_SPAN
        // pair must NOT be mistaken for a genuine stream: it still divides by
        // the whole-call duration, not the microseconds between callbacks.
        let mut two_callbacks = RateMeter::new(t0);
        assert_eq!(two_callbacks.record(200, t0), None); // thinking callback
        assert_eq!(two_callbacks.record(200, t0 + Duration::from_millis(1)), None); // text callback, ~0 span
        // 200 tokens over the 2s call, not 400 bytes / 1ms.
        let burst = two_callbacks.finish(Some(200), t0 + Duration::from_secs(2)).expect("burst rate");
        assert!((burst - 100.0).abs() < 0.01, "got {burst}");
    }

    #[test]
    fn rate_meter_finish_uses_first_token_denominator_for_multi_delta_stream() {
        // A genuine stream whose deltas span time reconciles at completion
        // against the first-token elapsed — continuous with the live rate and
        // the periodic refresh — not the whole-call duration, so a long
        // time-to-first-token does not deflate the final number.
        let t0 = Instant::now();
        // Generation starts 2s before the first token (slow TTFT), then two
        // deltas arrive 1s apart.
        let mut meter = RateMeter::new(t0);
        let first = t0 + Duration::from_secs(2);
        assert_eq!(meter.record(400, first), None); // first token, no live rate yet
        assert!(meter.record(400, first + Duration::from_secs(1)).is_some());
        // 200 exact tokens over the 3s SINCE THE FIRST TOKEN (not 5s since the
        // call began) = ~66.7 tok/s; the TTFT is excluded.
        let rate = meter.finish(Some(200), first + Duration::from_secs(3)).expect("stream rate");
        assert!((rate - 200.0 / 3.0).abs() < 0.01, "got {rate}");
    }

    #[test]
    fn rate_meter_sample_decays_during_pause() {
        // The periodic status-bar refresh re-samples the meter with `sample`
        // (byte estimate, first-token denominator) while no new deltas arrive.
        // Because the rate is cumulative (estimated_tokens / elapsed since the
        // first token), each later sample must report a strictly lower value,
        // so a pause or hang visibly lowers the displayed rate — continuously
        // with the live rate — instead of leaving a stale sample frozen.
        let t0 = Instant::now();
        let mut meter = RateMeter::new(t0);
        assert_eq!(meter.record(400, t0), None); // one delta records 400 bytes ≈ 100 tokens
        let at_1s = meter.sample(t0 + Duration::from_secs(1)).expect("rate at 1s");
        let at_2s = meter.sample(t0 + Duration::from_secs(2)).expect("rate at 2s");
        let at_5s = meter.sample(t0 + Duration::from_secs(5)).expect("rate at 5s");
        assert!(at_2s < at_1s, "pause must lower the rate: {at_2s} !< {at_1s}");
        assert!(at_5s < at_2s, "a longer pause lowers it further: {at_5s} !< {at_2s}");
        // 100 estimated tokens over 5s = 20 tok/s.
        assert!((at_5s - 20.0).abs() < 0.01, "got {at_5s}");
        // Before the first output delta there is nothing to sample.
        assert_eq!(RateMeter::new(t0).sample(t0 + Duration::from_secs(1)), None);
    }

    /// Replays scripted responses and records the requests it saw.
    struct Scripted {
        responses: Mutex<Vec<LLMResponse>>,
        seen: Arc<Mutex<Vec<Vec<Message>>>>,
    }

    #[async_trait]
    impl LLMClient for Scripted {
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            self.seen.lock().unwrap().push(request.messages.to_vec());
            Ok(self.responses.lock().unwrap().remove(0))
        }
        fn model_name(&self) -> &str {
            "scripted"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
        /// Reports a kind explicitly: a kindless client gets no kind-specific
        /// temperature rules, even when its config provider entry has one.
        fn kind(&self) -> Option<providers::ProviderKind> {
            Some(providers::ProviderKind::Openai)
        }
    }

    type Seen = Arc<Mutex<Vec<Vec<Message>>>>;

    /// `message` without its timestamp (or other timing), for comparing with a
    /// constructed one.
    fn unstamped(message: &Message) -> Message {
        Message { timestamp: None, log_line: None, duration_ms: None, temperature: None, ..message.clone() }
    }

    fn agent(responses: Vec<LLMResponse>, dir: &std::path::Path) -> (Agent, Seen) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = Scripted { responses: Mutex::new(responses), seen: seen.clone() };
        let config = Config {
            session_dir: Some(dir.to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        let agent = Agent::new(Box::new(client), config);
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        (agent, seen)
    }

    fn tool_call(id: &str) -> LLMResponse {
        LLMResponse {
            tool_calls: vec![ToolCall {
                id: id.into(),
                name: "echo".into(),
                arguments: json!({"text": "pong"}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        }
    }

    /// A scripted response calling `read_file` on `path`.
    fn read_call(id: &str, path: &str) -> LLMResponse {
        LLMResponse {
            tool_calls: vec![ToolCall {
                id: id.into(),
                name: "read_file".into(),
                arguments: json!({"path": path}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        }
    }

    /// An agent with the real file tools and a scripted client; `vision` sets
    /// the global `vision` override (the scripted client's "scripted" model is
    /// not a known vision family, so detection alone would report blind).
    fn file_agent(responses: Vec<LLMResponse>, dir: &std::path::Path, vision: Option<bool>) -> (Agent, Seen) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = Scripted { responses: Mutex::new(responses), seen: seen.clone() };
        let config = Config {
            session_dir: Some(dir.to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            vision,
            ..Config::default()
        };
        let agent = Agent::new(Box::new(client), config);
        crate::files::register(agent.tools());
        (agent, seen)
    }

    /// Write a small PNG and return its path.
    fn write_png(dir: &std::path::Path, name: &str, w: u32, h: u32) -> std::path::PathBuf {
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(w, h, image::Rgb([5, 50, 250])));
        let path = dir.join(name);
        img.save(&path).unwrap();
        path
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn read_file_attaches_an_image_for_a_vision_model() {
        let dir = tempfile::tempdir().unwrap();
        let png = write_png(dir.path(), "board.png", 64, 32);
        let (mut agent, seen) =
            file_agent(vec![read_call("c1", png.to_str().unwrap()), text("a blue board")], dir.path(), Some(true));
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "look").await.unwrap();
        assert_eq!(outcome.response, "a blue board");

        // The tool-result message carries the image attachment and a text part.
        let image_message = agent
            .conversation()
            .iter()
            .find(|m| m.role == Role::Tool && !m.attachments.is_empty())
            .expect("a tool result with an attachment");
        assert!(
            image_message.content.starts_with("image/png, 64×32, ") && image_message.content.ends_with('B'),
            "text part: {}",
            image_message.content
        );
        let attachment = &image_message.attachments[0];
        assert_eq!(attachment.media_type, "image/png");
        assert_eq!((attachment.width, attachment.height), (64, 32));
        assert_eq!(attachment.path, png);

        // The bytes are stored once under the session's attachments directory.
        let stored = session::attachments_dir_for(&agent.config().session_dir(), agent.session_id().unwrap())
            .join(format!("{}.png", attachment.sha256));
        assert!(stored.exists(), "stored at {}", stored.display());

        // The next request sends the image (the scripted client saw it).
        let requests = seen.lock().unwrap();
        let second = &requests[1];
        let tool = second.iter().find(|m| m.role == Role::Tool).unwrap();
        assert_eq!(tool.attachments.len(), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn read_file_image_errors_with_a_hint_when_the_model_cannot_see() {
        let dir = tempfile::tempdir().unwrap();
        let png = write_png(dir.path(), "board.png", 64, 32);
        // No vision override and a non-vision model: the read returns a text error.
        let (mut agent, _seen) = file_agent(vec![read_call("c1", png.to_str().unwrap()), text("ok")], dir.path(), None);
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "look").await.unwrap();
        let tool = agent.conversation().iter().find(|m| m.role == Role::Tool).expect("a tool result");
        assert!(tool.is_error, "the read failed");
        assert!(tool.attachments.is_empty());
        assert!(tool.content.contains("can't view images"), "hint: {}", tool.content);
        assert!(tool.content.contains("vision = true"), "names the fix: {}", tool.content);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn read_file_binary_error_notes_vision_capability() {
        let dir = tempfile::tempdir().unwrap();
        // A non-image binary file (contains NUL bytes, no image magic).
        let bin = dir.path().join("blob.bin");
        std::fs::write(&bin, [0u8, 1, 2, 3, 255, 0, 42]).unwrap();

        // A vision-capable model: the binary error still says it can view images
        // (so the model knows the failure is the file type, not its capability).
        let (mut agent, _) =
            file_agent(vec![read_call("c1", bin.to_str().unwrap()), text("ok")], dir.path(), Some(true));
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "read").await.unwrap();
        let tool = agent.conversation().iter().find(|m| m.role == Role::Tool).expect("a tool result");
        assert!(tool.is_error, "binary read failed");
        assert!(tool.content.contains("looks like a binary file"), "binary error: {}", tool.content);
        assert!(tool.content.contains("can view images"), "capability hint: {}", tool.content);

        // A non-vision model: the same error names the missing capability.
        let (mut agent, _) =
            file_agent(vec![read_call("c1", bin.to_str().unwrap()), text("ok")], dir.path(), Some(false));
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "read").await.unwrap();
        let tool = agent.conversation().iter().find(|m| m.role == Role::Tool).expect("a tool result");
        assert!(tool.content.contains("can't view images"), "capability hint: {}", tool.content);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn only_read_file_decodes_image_results() {
        let dir = tempfile::tempdir().unwrap();
        // A vision-capable model, so the `{"image": …}` shape WOULD be decoded
        // into an attachment (or an "image result had no data" error) if the
        // decoding were gated on the result shape rather than the tool name.
        let (mut agent, _) = file_agent(
            vec![
                LLMResponse {
                    tool_calls: vec![ToolCall {
                        id: "c1".into(),
                        name: "shot".into(),
                        arguments: json!({}),
                        item_id: None,
                        malformed_arguments: None,
                    }],
                    ..Default::default()
                },
                text("ok"),
            ],
            dir.path(),
            Some(true),
        );
        // A non-`read_file` tool that legitimately returns a structured object
        // with a top-level `image` field.
        agent.tools().register(
            ToolDefinition::new("shot", "shot", json!({"type": "object"})),
            Box::new(|_| {
                Ok(json!({ "image": { "media_type": "image/png", "path": "/nope.png",
                    "width": 1, "height": 1, "bytes": 3 } }))
            }),
        );
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        let tool = agent.conversation().iter().find(|m| m.role == Role::Tool).expect("a tool result");
        assert!(!tool.is_error, "a non-read_file image-shaped result is not an image error: {}", tool.content);
        assert!(tool.attachments.is_empty(), "no attachment is created for a non-read_file tool");
        assert!(
            tool.content.contains("\"image\""),
            "the structured result is stringified unchanged: {}",
            tool.content
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_resumed_session_keeps_attachments_and_survives_a_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let png = write_png(dir.path(), "board.png", 64, 32);
        let session_id;
        let sha;
        {
            let (mut agent, _) =
                file_agent(vec![read_call("c1", png.to_str().unwrap()), text("done")], dir.path(), Some(true));
            agent.new_session().unwrap();
            agent.run_turn(Some("in-1"), "look").await.unwrap();
            session_id = agent.session_id().unwrap().to_string();
            sha =
                agent.conversation().iter().find(|m| !m.attachments.is_empty()).unwrap().attachments[0].sha256.clone();
        }
        // Resume: the attachment reference survives in the log.
        let (mut agent, _) = file_agent(vec![text("again")], dir.path(), Some(true));
        agent.load_session(&session_id).unwrap();
        let tool = agent.conversation().iter().find(|m| !m.attachments.is_empty()).expect("attachment kept");
        assert_eq!(tool.attachments[0].sha256, sha);

        // Delete the stored image; the request builder falls back to a
        // placeholder instead of failing.
        let stored =
            session::attachments_dir_for(&agent.config().session_dir(), &session_id).join(format!("{sha}.png"));
        std::fs::remove_file(&stored).unwrap();
        let attachments_dir = agent.attachments_dir();
        let request = crate::llm::ChatRequest {
            messages: agent.conversation(),
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: agent.vision(),
            attachments_dir: Some(attachments_dir.as_path()),
        };
        match &request.resolve_attachments(tool)[0] {
            crate::llm::ResolvedAttachment::Omitted(text) => {
                assert!(text.contains("no longer available"), "{text}");
            }
            other => panic!("missing file should be a placeholder, got {other:?}"),
        }
    }

    fn text(content: &str) -> LLMResponse {
        LLMResponse { content: content.into(), ..Default::default() }
    }

    #[test]
    fn temperature_resolves_against_the_live_client() {
        // `Scripted` reports provider "test" and model "scripted", whatever
        // `config.model` says — so resolution must follow the client.
        let dir = tempfile::tempdir().unwrap();
        let (agent, _) = agent(vec![], dir.path());
        assert_eq!(agent.temperature().source, crate::temperature::Source::Global);

        // A temperature set for the client's provider/model is what it is sent …
        let mut config = agent.config().clone();
        config.providers.insert(
            "test".into(),
            providers::ProviderConfig {
                kind: Some(providers::ProviderKind::Openai),
                temperature: Some(crate::temperature::Temperature::Value(0.4)),
                ..Default::default()
            },
        );
        let agent = Agent::new(
            Box::new(Scripted { responses: Mutex::new(vec![]), seen: Arc::new(Mutex::new(vec![])) }),
            config,
        );
        let resolved = agent.temperature();
        assert_eq!((resolved.value(), resolved.source), (Some(0.4), crate::temperature::Source::Provider));

        // … even when `config.model` drifts from the live client, as a
        // `/settings` edit to the provider's `default_model` leaves it: the
        // config now points at a fixed-temperature reasoning model, but the
        // client still speaks for "scripted", which takes a temperature.
        let mut config = agent.config().clone();
        config.model = "github-copilot/gpt-5".into();
        let agent = Agent::new(
            Box::new(Scripted { responses: Mutex::new(vec![]), seen: Arc::new(Mutex::new(vec![])) }),
            config,
        );
        let resolved = agent.temperature();
        assert_eq!((resolved.value(), resolved.source), (Some(0.4), crate::temperature::Source::Provider));
        assert_eq!(resolved.fixed, None);
    }

    /// A kindless client (one imitating no real provider API) gets no
    /// kind-specific rule, even when its config provider entry names a kind:
    /// editing the provider's `kind` must not clamp or fix the temperature of
    /// a client that never spoke that API.
    struct Kindless;

    #[async_trait]
    impl LLMClient for Kindless {
        async fn chat(&self, _request: &ChatRequest<'_>) -> Result<LLMResponse> {
            unreachable!("no chat in this test")
        }
        fn model_name(&self) -> &str {
            "mock"
        }
        fn provider_name(&self) -> &str {
            "mock"
        }
    }

    #[test]
    fn temperature_ignores_config_kind_for_a_kindless_client() {
        let mut config = Config::default();
        // The active `mock` provider edited to Anthropic, the switch declined:
        // the kindless client must not inherit Anthropic's 0..=1 clamp.
        config.providers.insert(
            "mock".into(),
            providers::ProviderConfig {
                kind: Some(providers::ProviderKind::Anthropic),
                temperature: Some(crate::temperature::Temperature::Value(1.5)),
                ..Default::default()
            },
        );
        let agent = Agent::new(Box::new(Kindless), config);
        let resolved = agent.temperature();
        assert_eq!((resolved.value(), resolved.source), (Some(1.5), crate::temperature::Source::Provider));
        assert_eq!(resolved.warning, None);
    }

    /// A custom provider with `kind = "mock"` must keep its own name on the
    /// built client, so temperature resolution reads its entry — not the
    /// built-in `mock` preset (which has no temperature, so the global would
    /// be reported/sent instead).
    #[test]
    fn temperature_resolves_for_a_custom_mock_provider() {
        let mut config = Config { model: "demo/foo".into(), ..Default::default() };
        config.providers.insert(
            "demo".into(),
            providers::ProviderConfig {
                kind: Some(providers::ProviderKind::Mock),
                default_model: Some("foo".into()),
                temperature: Some(crate::temperature::Temperature::Value(0.2)),
                ..Default::default()
            },
        );
        let client = providers::build_client("demo/foo", &config.providers, "mock").unwrap();
        // The client was built from the `demo` entry, so it reports `demo` …
        assert_eq!(client.provider_name(), "demo");
        let agent = Agent::new(client, config);
        // … and the temperature lookup resolves against `demo`, not `mock`.
        let resolved = agent.temperature();
        assert_eq!((resolved.value(), resolved.source), (Some(0.2), crate::temperature::Source::Provider));
    }

    fn memory_agent(mode: crate::config::MemoryMode, responses: Vec<LLMResponse>, dir: &std::path::Path) -> Agent {
        let client = Scripted { responses: Mutex::new(responses), seen: Arc::new(Mutex::new(Vec::new())) };
        let config = Config {
            session_dir: Some(dir.join("sessions")),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            memory: mode,
            memory_dir: Some(dir.join("memory")),
            ..Config::default()
        };
        Agent::new(Box::new(client), config)
    }

    #[test]
    fn memory_tools_track_the_configured_mode() {
        let dir = tempfile::tempdir().unwrap();
        let names = |a: &Agent| a.tool_definitions().into_iter().map(|d| d.name).collect::<Vec<_>>();

        let on = memory_agent(crate::config::MemoryMode::On, vec![], dir.path());
        let on_names = names(&on);
        for tool in [memory::SAVE_TOOL, memory::SEARCH_TOOL, memory::FORGET_TOOL] {
            assert!(on_names.contains(&tool.to_string()), "on offers {tool}");
        }

        let read_only = memory_agent(crate::config::MemoryMode::ReadOnly, vec![], dir.path());
        let ro_names = names(&read_only);
        assert!(ro_names.contains(&memory::SEARCH_TOOL.to_string()));
        assert!(!ro_names.contains(&memory::SAVE_TOOL.to_string()), "read-only hides save");

        let off = memory_agent(crate::config::MemoryMode::Off, vec![], dir.path());
        assert!(!names(&off).iter().any(|n| memory::is_memory_tool(n)), "off offers no memory tools");
        assert!(off.memory().is_none());
    }

    #[test]
    fn plan_mode_drops_save_from_tools_and_index_guidance() {
        let dir = tempfile::tempdir().unwrap();
        let agent = memory_agent(crate::config::MemoryMode::On, vec![], dir.path());
        // A saved fact gives the index something to render.
        agent.memory().unwrap().save(memory::Scope::User, "a durable fact", None, None).unwrap();

        let normal_prompt = agent.system_prompt();
        assert!(normal_prompt.contains(memory::SAVE_TOOL), "normal mode offers save guidance: {normal_prompt}");
        let names = |a: &Agent| a.tool_definitions().into_iter().map(|d| d.name).collect::<Vec<_>>();
        assert!(names(&agent).contains(&memory::SAVE_TOOL.to_string()), "normal mode offers the save tool");

        agent.set_mode(crate::mode::AgentMode::Plan);
        let plan_prompt = agent.system_prompt();
        assert!(
            !plan_prompt.contains(memory::SAVE_TOOL),
            "plan mode drops the unavailable save tool from the index guidance: {plan_prompt}"
        );
        assert!(plan_prompt.contains(memory::SEARCH_TOOL), "plan mode still offers search: {plan_prompt}");
        assert!(!names(&agent).contains(&memory::SAVE_TOOL.to_string()), "plan mode hides the save tool");

        agent.set_mode(crate::mode::AgentMode::Normal);
        assert!(agent.system_prompt().contains(memory::SAVE_TOOL), "leaving plan mode restores save guidance");
    }

    #[test]
    fn stored_system_message_reflects_mode_change() {
        let dir = tempfile::tempdir().unwrap();
        let mut agent = memory_agent(crate::config::MemoryMode::On, vec![], dir.path());
        agent.memory().unwrap().save(memory::Scope::User, "a durable fact", None, None).unwrap();
        agent.new_session().unwrap();

        // In Normal mode the stored system message advertises memory_save.
        assert!(
            agent.conversation.first().unwrap().content.contains(memory::SAVE_TOOL),
            "normal mode stored prompt offers save"
        );

        // Entering plan mode must rebuild the stored prompt so it no longer
        // advertises the unavailable save tool (Copilot finding, src/agent.rs).
        agent.set_mode(crate::mode::AgentMode::Plan);
        agent.apply_mode_to_system_prompt();
        let plan_content = agent.conversation.first().unwrap().content.clone();
        assert!(!plan_content.contains(memory::SAVE_TOOL), "plan mode stored prompt drops save guidance");
        assert!(plan_content.contains("PLAN MODE"), "plan note present");

        // Leaving plan mode restores the save guidance.
        agent.set_mode(crate::mode::AgentMode::Normal);
        agent.apply_mode_to_system_prompt();
        let normal_content = agent.conversation.first().unwrap().content.clone();
        assert!(normal_content.contains(memory::SAVE_TOOL), "normal mode restores save guidance");
        assert!(!normal_content.contains("PLAN MODE"), "plan note removed");
    }

    #[test]
    fn load_session_renders_prompt_with_default_mode_writability() {
        let dir = tempfile::tempdir().unwrap();
        let mut agent = memory_agent(crate::config::MemoryMode::On, vec![], dir.path());
        agent.memory().unwrap().save(memory::Scope::User, "a durable fact", None, None).unwrap();
        let id = agent.new_session().unwrap();

        // Load while still in Plan mode: the resumed session is Normal
        // (writable), so its stored system prompt must advertise memory_save —
        // not Plan's read-only guidance (Copilot finding, src/agent.rs).
        agent.set_mode(crate::mode::AgentMode::Plan);
        agent.load_session(&id).unwrap();
        assert_eq!(agent.mode(), crate::mode::AgentMode::Normal, "load_session resets the mode");
        let loaded = agent.conversation.first().unwrap().content.clone();
        assert!(
            loaded.contains(memory::SAVE_TOOL),
            "loaded session is writable, so its prompt offers save guidance: {loaded}"
        );
        assert!(!loaded.contains("PLAN MODE"), "loaded session carries no plan note: {loaded}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn memory_save_persists_and_surfaces_in_the_prompt() {
        let dir = tempfile::tempdir().unwrap();
        let save = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "m1".into(),
                name: memory::SAVE_TOOL.into(),
                arguments: json!({"scope": "user", "text": "python comes from uv"}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let mut agent = memory_agent(crate::config::MemoryMode::On, vec![save, text("done")], dir.path());
        agent.new_session().unwrap();
        assert_eq!(agent.send_message("remember that").await.unwrap(), "done");
        // The save is confirmed to the model (and so shown in the transcript).
        let path = agent.session_path().unwrap().to_path_buf();
        let logged: Vec<Message> = history::load(&path).unwrap().into_iter().map(|(_, m)| m).collect();
        assert!(
            logged.iter().any(|m| m.role == Role::Tool && m.content.contains("remembered (user")),
            "transcript records the save"
        );
        // A fresh session on the same store surfaces the fact in its prompt.
        let mut next = memory_agent(crate::config::MemoryMode::On, vec![], dir.path());
        next.new_session().unwrap();
        assert!(next.system_prompt().contains("python comes from uv"), "index carries into the next session");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn read_only_memory_refuses_a_save() {
        let dir = tempfile::tempdir().unwrap();
        let save = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "m1".into(),
                name: memory::SAVE_TOOL.into(),
                arguments: json!({"scope": "user", "text": "should not persist"}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let mut agent = memory_agent(crate::config::MemoryMode::ReadOnly, vec![save, text("ok")], dir.path());
        agent.new_session().unwrap();
        agent.send_message("try to save").await.unwrap();
        assert!(agent.memory().unwrap().all().unwrap().is_empty(), "read-only did not persist the save");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn plan_mode_blocks_a_memory_mutation_that_reached_the_handler() {
        // A mode switch can land after the outer dispatch gate but before the
        // memory handler runs (the control is switchable while a turn holds
        // `&mut Agent`). `memory::run` only honours `read_only` for search, so
        // the handler must re-check the mode itself and refuse a save/forget
        // that arrived while the agent is in Plan mode (Copilot finding,
        // src/agent.rs).
        let dir = tempfile::tempdir().unwrap();
        let mut agent = memory_agent(crate::config::MemoryMode::On, vec![], dir.path());
        agent.new_session().unwrap();
        // Switch to Plan mode *after* dispatch would have occurred, then call
        // the handler directly — the in-flight save must be refused.
        agent.set_mode(crate::mode::AgentMode::Plan);
        let save = ToolCall {
            id: "m1".into(),
            name: memory::SAVE_TOOL.into(),
            arguments: json!({"scope": "user", "text": "should not persist"}),
            item_id: None,
            malformed_arguments: None,
        };
        let err = agent.run_memory_tool(&save).unwrap_err();
        assert!(err.to_string().contains("plan mode"), "save refused in plan mode: {err}");
        assert!(agent.memory().unwrap().all().unwrap().is_empty(), "plan mode did not persist the save");
        // A read-only search is still allowed in Plan mode.
        let search = ToolCall {
            id: "m2".into(),
            name: memory::SEARCH_TOOL.into(),
            arguments: json!({"pattern": "anything"}),
            item_id: None,
            malformed_arguments: None,
        };
        assert!(agent.run_memory_tool(&search).is_ok(), "plan mode still allows a read-only search");
    }

    #[test]
    fn configured_read_only_memory_search_does_not_mutate_the_store() {
        // A session configured `MemoryMode::ReadOnly` (e.g. an ACP/headless
        // session downgraded to read-only) must keep search read-only: the
        // `read_only` flag now honours the configured memory mode, not only Plan
        // mode, so a search no longer acquires a write lock, prunes, bumps
        // `last_used`, or rewrites the JSONL file (Copilot finding, src/agent.rs).
        let dir = tempfile::tempdir().unwrap();
        let mut agent = memory_agent(crate::config::MemoryMode::ReadOnly, vec![], dir.path());
        agent.new_session().unwrap();
        // Seed a matching fact directly through the store (save mutates
        // regardless of mode; the mode gate lives at the agent layer).
        agent.memory().unwrap().save(memory::Scope::User, "the deploy command is make ship", None, None).unwrap();
        let file = dir.path().join("memory").join("user.jsonl");
        let before = std::fs::read(&file).unwrap();

        let search = ToolCall {
            id: "s1".into(),
            name: memory::SEARCH_TOOL.into(),
            arguments: json!({"pattern": "deploy"}),
            item_id: None,
            malformed_arguments: None,
        };
        let out = agent.run_memory_tool(&search).unwrap();
        assert!(out.contains("make ship"), "the read-only search still returns the matching fact: {out}");

        let after = std::fs::read(&file).unwrap();
        assert_eq!(before, after, "a read-only-mode search must leave the store file byte-for-byte unchanged");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn logs_thinking_usage_and_duration_with_assistant_messages() {
        let dir = tempfile::tempdir().unwrap();
        let usage =
            |n| Some(crate::llm::TokenUsage { prompt_tokens: n, completion_tokens: 1, total_tokens: n + 1, aic: None });
        let responses = vec![
            LLMResponse { thinking: "call the tool".into(), usage: usage(10), ..tool_call("c1") },
            LLMResponse { thinking: "now answer".into(), usage: usage(20), ..text("done") },
        ];
        let (mut agent, _) = agent(responses, dir.path());
        agent.new_session().unwrap();
        assert_eq!(agent.send_message("ping").await.unwrap(), "done");
        let path = agent.session_path().unwrap().to_path_buf();
        let logged: Vec<Message> = history::load(&path).unwrap().into_iter().map(|(_, m)| m).collect();
        let assistants: Vec<&Message> = logged.iter().filter(|m| m.role == Role::Assistant).collect();
        assert_eq!(assistants.len(), 2);
        assert_eq!((assistants[0].thinking.as_str(), assistants[0].usage.clone()), ("call the tool", usage(10)));
        assert_eq!((assistants[1].thinking.as_str(), assistants[1].usage.clone()), ("now answer", usage(20)));
        assert!(assistants.iter().all(|m| m.duration_ms.is_some()));
        // Only assistant messages carry trajectory data.
        assert!(
            logged.iter().filter(|m| m.role != Role::Assistant).all(|m| m.duration_ms.is_none() && m.usage.is_none())
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn records_assistant_tool_calls_before_results() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(vec![tool_call("c1"), text("done")], dir.path());
        assert_eq!(agent.send_message("ping").await.unwrap(), "done");
        let second = &seen.lock().unwrap()[1];
        assert_eq!(second[2].role, Role::Assistant);
        assert_eq!(second[2].tool_calls[0].id, "c1");
        assert_eq!(unstamped(&second[3]), Message::tool_result("c1", "echo", "pong"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn malformed_tool_call_skips_handler_and_reports_actionable_error() {
        let dir = tempfile::tempdir().unwrap();
        // A tool call whose argument JSON never decoded (a truncated stream).
        let malformed = LLMResponse {
            tool_calls: vec![ToolCall::from_raw_arguments("c1".into(), "echo".into(), "{\"text\":", None)],
            ..Default::default()
        };
        let (mut agent, seen) = agent(vec![malformed, text("recovered")], dir.path());
        assert_eq!(agent.send_message("ping").await.unwrap(), "recovered");

        // The dispatch loop short-circuits before any handler: the tool result
        // is the actionable malformed-arguments error, not a handler response.
        let second = &seen.lock().unwrap()[1];
        let result = second.iter().find(|m| m.role == Role::Tool).expect("a tool result was recorded");
        let error = &result.content;
        assert!(error.contains("malformed JSON"), "got: {error}");
        assert!(error.contains("echo"), "names the tool: {error}");
        // The handler never ran: `echo` would have produced `pong`, but the
        // malformed call has no decodable `text` to echo.
        assert_ne!(error, "pong");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resumes_sessions_and_deduplicates_inputs() {
        let dir = tempfile::tempdir().unwrap();
        let (mut first, _) = agent(vec![text("one")], dir.path());
        let id = first.new_session().unwrap();
        assert_eq!(first.send_input(Some("msg-1"), "hello").await.unwrap(), "one");
        drop(first);

        let (mut second, seen) = agent(vec![text("two")], dir.path());
        second.load_session(&id).unwrap();
        assert_eq!(second.conversation_length(), 3);
        // Redelivery of a completed input does not call the model.
        assert_eq!(second.send_input(Some("msg-1"), "hello").await.unwrap(), "one");
        assert!(seen.lock().unwrap().is_empty());
        assert_eq!(second.send_input(Some("msg-2"), "again").await.unwrap(), "two");
        assert_eq!(seen.lock().unwrap()[0].len(), 4);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn titles_sessions_once_a_prompt_says_something() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("one"), text("two"), text("three")], dir.path());
        agent.config.session_titles = true;
        agent.config.title_model = Some("mock/titler".into());
        agent.new_session().unwrap();
        let title = |dir: &std::path::Path| crate::session_index::list(dir).unwrap()[0].title.clone();

        agent.send_input(None, "hi").await.unwrap();
        assert!(agent.titles_requested.is_empty(), "a terse first prompt is not enough to name the session");
        agent.send_input(None, "Fix the flaky deploy test in CI").await.unwrap();
        assert!(!agent.titles_requested.is_empty());
        let mut found = None;
        for _ in 0..50 {
            found = title(dir.path());
            if found.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let found = found.expect("the title arrives in the index");
        // The seven-word mock reply is held to six words (see `clean_title`).
        assert_eq!(found, "This is a mock response from…", "{found}");
        // Later turns keep it (the per-turn summary carries it over).
        agent.send_input(None, "and the release notes").await.unwrap();
        assert_eq!(title(dir.path()), Some(found));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_title_fallback_uses_the_sessions_live_model() {
        // With no `title_model` configured the title request must fall back to
        // the model actually serving this session (the live client's resolved
        // provider/model), not `config.model` re-resolved. Here `config.model`
        // is the bare provider `ollama`, which has no `default_model`, so
        // re-resolving it fails to build a client and the title is silently
        // skipped. The live client (`test/scripted`) resolves to a mock, so
        // the session still gets titled.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("one")], dir.path());
        agent.config.session_titles = true;
        agent.config.model = "ollama".into();
        assert_eq!(agent.model_name(), "scripted");
        assert!(agent.config.title_model.is_none());
        agent.new_session().unwrap();
        agent.send_input(None, "Fix the flaky deploy test in CI").await.unwrap();
        let mut found = None;
        for _ in 0..50 {
            found =
                crate::session_index::list(dir.path()).ok().and_then(|s| s.into_iter().next()).and_then(|s| s.title);
            if found.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(
            found.is_some(),
            "the fallback titled the session from the live model, not the unresolvable config.model"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_title_is_requested_at_most_once_per_session_across_switches() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("one"), text("two")], dir.path());
        agent.config.session_titles = true;
        agent.config.title_model = Some("mock/titler".into());
        let a = agent.new_session().unwrap();
        agent.send_input(None, "Fix the flaky deploy test in CI").await.unwrap();
        assert!(agent.titles_requested.contains(&a));
        // Switching A → B → A must not forget that A was already requested:
        // loading a session no longer clears the per-process set, so A cannot
        // launch a second paid title request before its first one lands.
        let _b = agent.new_session().unwrap();
        agent.load_session(&a).unwrap();
        assert!(agent.titles_requested.contains(&a), "A stays requested across the switch");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn no_titles_unless_enabled() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("one")], dir.path());
        agent.new_session().unwrap();
        agent.send_input(None, "Fix the flaky deploy test in CI").await.unwrap();
        assert!(agent.titles_requested.is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn switching_sessions_in_process_resets_totals_and_indexes() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("one"), text("two")], dir.path());
        let a = agent.new_session().unwrap();
        agent.send_input(None, "alpha question here").await.unwrap();
        let b = agent.new_session().unwrap();
        agent.send_input(None, "beta question here").await.unwrap();
        agent.stats.lock().unwrap().session_input_tokens = 99;
        {
            // Seed every counter `load_session` resets so each reset is
            // actually exercised, not just the input-token one.
            let mut stats = agent.stats.lock().unwrap();
            stats.session_output_tokens = 77;
            stats.session_aic = Some(1.25);
            stats.compactions = 2;
            stats.history_searches = 3;
            stats.history_reads = 4;
        }

        // `/resume` mid-process: back to A, with B's totals gone.
        agent.load_session(&a).unwrap();
        assert_eq!(agent.session_id(), Some(a.as_str()));
        assert!(agent.conversation.iter().any(|m| m.content == "alpha question here"));
        assert!(!agent.conversation.iter().any(|m| m.content == "beta question here"));
        {
            let stats = agent.stats.lock().unwrap();
            assert_eq!(stats.session_input_tokens, 0);
            assert_eq!(stats.session_output_tokens, 0);
            assert_eq!(stats.session_aic, None);
            assert_eq!(stats.compactions, 0);
            assert_eq!(stats.history_searches, 0);
            assert_eq!(stats.history_reads, 0);
        }

        // Each finished turn updated the picker's index.
        let sessions = crate::session_index::list(dir.path()).unwrap();
        let ids: Vec<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
        assert!(ids.contains(&a.as_str()) && ids.contains(&b.as_str()), "{ids:?}");
        assert!(sessions.iter().all(|s| s.cwd.is_some() && s.model.is_some()));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn repairs_interrupted_turns_on_resume() {
        let dir = tempfile::tempdir().unwrap();
        let id = "sess-crash";
        let mut log = SessionLog::create(dir.path(), id).unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        log.append(&Record::Message(Box::new(Message::assistant_with_tools(
            "",
            vec![ToolCall {
                id: "c9".into(),
                name: "echo".into(),
                arguments: json!({}),
                item_id: None,
                malformed_arguments: None,
            }],
        ))))
        .unwrap();
        drop(log);

        let (mut agent, seen) = agent(vec![text("recovered")], dir.path());
        agent.load_session(id).unwrap();
        let repaired = &agent.conversation()[3];
        assert_eq!(unstamped(repaired), Message::tool_error("c9", "echo", INTERRUPTED_TOOL_RESULT));
        // The repair is stamped and numbered like a `push`: `/trajectory` can
        // show its event time and citations can use its persisted `#N`
        // without waiting for a reload.
        assert!(repaired.timestamp.is_some());
        assert_eq!(repaired.log_line, Some(6));
        // Redelivering the interrupted input resumes without duplicating the user message.
        assert_eq!(agent.send_input(Some("msg-1"), "run it").await.unwrap(), "recovered");
        let request = &seen.lock().unwrap()[0];
        assert_eq!(request.iter().filter(|m| m.role == Role::User).count(), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_repair_on_resume_leaves_the_live_session_untouched() {
        let dir = tempfile::tempdir().unwrap();
        // The live session the agent is currently in.
        let (mut agent, _) = agent(vec![text("one")], dir.path());
        let live = agent.new_session().unwrap();
        assert_eq!(agent.send_input(Some("msg-1"), "hello").await.unwrap(), "one");
        let live_len = agent.conversation_length();

        // A crashed session on disk whose resume needs a (fallible) repair append.
        let crashed = "sess-readonly";
        let mut log = SessionLog::create(dir.path(), crashed).unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "m1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        log.append(&Record::Message(Box::new(Message::assistant_with_tools(
            "",
            vec![ToolCall {
                id: "c9".into(),
                name: "echo".into(),
                arguments: json!({}),
                item_id: None,
                malformed_arguments: None,
            }],
        ))))
        .unwrap();
        drop(log);
        // Make the crashed session's log read-only so the repair append fails.
        let log_path = dir.path().join(format!("{crashed}.jsonl"));
        let mut perms = std::fs::metadata(&log_path).unwrap().permissions();
        perms.set_readonly(true);
        std::fs::set_permissions(&log_path, perms).unwrap();

        // The switch must fail and leave the agent in its prior live session,
        // not half-switched into the crashed one.
        assert!(agent.load_session(crashed).is_err());
        assert_eq!(agent.session_id(), Some(live.as_str()));
        assert_eq!(agent.conversation_length(), live_len);

        // Restore writability so the tempdir cleanup (and any retry) works.
        let mut perms = std::fs::metadata(&log_path).unwrap().permissions();
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        std::fs::set_permissions(&log_path, perms).unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resumed_pending_input_is_not_folded_into_the_index_twice() {
        // An interrupted session whose pending input is already in the log:
        // resuming and finishing that turn must not fold the prompt into the
        // session-index summary again (the cache already covers it).
        let dir = tempfile::tempdir().unwrap();
        crashed_session(dir.path(), "sess", vec![]);
        // The picker/listing indexes the interrupted log before the resume.
        assert_eq!(crate::session_index::list(dir.path()).unwrap()[0].prompts, 1);

        let (mut agent, _) = agent(vec![text("done")], dir.path());
        agent.load_session("sess").unwrap();
        assert_eq!(agent.send_input(Some("msg-1"), "run it").await.unwrap(), "done");

        let sessions = crate::session_index::list(dir.path()).unwrap();
        assert_eq!(sessions[0].prompts, 1, "the resumed input is counted once, not folded again");
        assert_eq!(sessions[0].last_prompt.as_deref(), Some("run it"));
    }

    fn crashed_session(dir: &std::path::Path, id: &str, records: Vec<Record>) {
        let mut log = SessionLog::create(dir, id).unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        for record in records {
            log.append(&record).unwrap();
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_restores_a_lost_user_message() {
        let dir = tempfile::tempdir().unwrap();
        crashed_session(dir.path(), "lost-user", vec![]);
        let (mut agent, seen) = agent(vec![text("answer")], dir.path());
        agent.load_session("lost-user").unwrap();
        assert_eq!(agent.send_input(Some("msg-1"), "run it").await.unwrap(), "answer");
        let request = &seen.lock().unwrap()[0];
        assert_eq!(request.last().map(unstamped).as_ref(), Some(&Message::user("run it")));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_finishes_a_recorded_answer_without_calling_the_model() {
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "lost-end",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(Message::assistant("already answered"))),
            ],
        );
        let (mut agent, seen) = agent(vec![], dir.path());
        agent.load_session("lost-end").unwrap();
        assert_eq!(agent.send_input(Some("msg-1"), "run it").await.unwrap(), "already answered");
        assert!(seen.lock().unwrap().is_empty());
        drop(agent);
        let (_, restored) = SessionLog::open(dir.path(), "lost-end").unwrap();
        assert_eq!(restored.completed["msg-1"], "already answered");
        assert!(restored.pending_input.is_none());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn manual_compaction_summarizes_older_messages() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(vec![tool_call("c1"), text("done"), text("SUMMARY: pinged once")], dir.path());
        let id = agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, Some("the ping")).await.unwrap().expect("compacted");
        assert_eq!((report.messages_before, report.messages_after, report.summarized), (5, 3, 3));
        assert_eq!(report.fallback, None);

        let request = seen.lock().unwrap()[2].clone();
        assert_eq!(request[0].content, context::SUMMARY_SYSTEM_PROMPT);
        assert!(request[1].content.contains("[called echo("), "{}", request[1].content);
        assert!(request[1].content.contains("TOOL result (echo):\npong"), "{}", request[1].content);
        assert!(request[1].content.contains("focus on: the ping"));

        let conversation = agent.conversation().to_vec();
        assert_eq!(conversation[1].role, Role::User);
        assert!(conversation[1].content.starts_with(context::SUMMARY_PREFIX));
        assert!(conversation[1].content.ends_with("SUMMARY: pinged once"));
        assert_eq!(unstamped(&conversation[2]), Message::assistant("done"));
        assert_eq!(agent.context_stats().lock().unwrap().compactions, 1);

        drop(agent);
        let (_, restored) = SessionLog::open(dir.path(), &id).unwrap();
        assert_eq!(restored.conversation, conversation);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_summary_cut_off_at_the_output_limit_is_flagged() {
        // A reasoning model can spend most of the summary's output budget
        // thinking; a summary that stops at the limit must say it is
        // incomplete instead of passing for a full record.
        let dir = tempfile::tempdir().unwrap();
        let cut = LLMResponse {
            content: "SUMMARY: step 1 half do".into(),
            stop_reason: Some("length".into()),
            ..Default::default()
        };
        let (mut agent, _) = agent(vec![tool_call("c1"), text("done"), cut], dir.path());
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert_eq!(report.fallback, None);
        assert!(report.truncated);
        assert!(report.to_string().contains("hit the output limit"), "{report}");
        let summary = &agent.conversation()[1].content;
        assert!(summary.contains("SUMMARY: step 1 half do"), "{summary}");
        assert!(summary.contains(context::SUMMARY_TRUNCATED_NOTE.trim()), "{summary}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_empty_summary_at_the_output_limit_names_the_cause() {
        let dir = tempfile::tempdir().unwrap();
        let empty = LLMResponse { stop_reason: Some("length".into()), ..Default::default() };
        let (mut agent, _) = agent(vec![tool_call("c1"), text("done"), empty], dir.path());
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert!(report.fallback.as_deref().is_some_and(|f| f.contains("output limit")), "{report}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn smart_compaction_cites_log_lines_and_offers_history_tools() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(
            vec![
                tool_call("c1"),
                text("done"),
                text("SUMMARY: pinged once, got pong (#6)"),
                call("h1", history::SEARCH_TOOL, json!({"pattern": "PONG"})),
                call("h2", history::READ_TOOL, json!({"id": "#6"})),
                text("it said pong"),
            ],
            dir.path(),
        );
        let id = agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let names = |agent: &Agent| agent.tool_definitions().into_iter().map(|d| d.name).collect::<Vec<_>>();
        assert!(!names(&agent).iter().any(|n| history::is_history_tool(n)), "no history tools before a smart summary");

        let report = agent.compact(Some(CompactionMode::Smart), None).await.unwrap().expect("compacted");
        assert_eq!(report.mode, CompactionMode::Smart);
        assert!(report.to_string().starts_with("smart-compacted 3 messages"), "{report}");
        let request = seen.lock().unwrap()[2].clone();
        assert!(request[0].content.ends_with(context::SMART_SUMMARY_INSTRUCTIONS));
        assert!(request[1].content.contains("[#4] USER:\nping"), "{}", request[1].content);
        assert!(request[1].content.contains("[#6] TOOL result (echo):\npong"), "{}", request[1].content);
        let summary = agent.conversation()[1].content.clone();
        assert!(summary.starts_with(context::SMART_SUMMARY_PREFIX) && summary.contains("messages #4–#6"), "{summary}");
        assert!(names(&agent).contains(&history::SEARCH_TOOL.to_string()));

        assert_eq!(agent.send_message("what did the tool say?").await.unwrap(), "it said pong");
        let last = seen.lock().unwrap().last().unwrap().clone();
        let results: Vec<&Message> = last.iter().filter(|m| m.role == Role::Tool).collect();
        assert!(
            results[0].content.starts_with("#6 tool echo") && results[0].content.contains(": pong"),
            "{}",
            results[0].content
        );
        assert!(
            results[1].content.starts_with("#6 tool echo") && results[1].content.ends_with("\npong"),
            "{}",
            results[1].content
        );
        {
            let stats = agent.context_stats();
            let stats = stats.lock().unwrap();
            assert_eq!((stats.history_searches, stats.history_reads), (1, 1));
        }

        drop(agent);
        let log = std::fs::read_to_string(dir.path().join(format!("{id}.jsonl"))).unwrap();
        let records: Vec<Record> = log.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert!(
            records.iter().any(|r| matches!(
                r,
                Record::Replace { summarized: Some((4, 6)), mode: Some(CompactionMode::Smart), .. }
            ))
        );
        assert!(matches!(records.last(), Some(Record::TurnEnd { history_calls: 2, .. })));
        // Kept messages keep their IDs across resume.
        let (_, restored) = SessionLog::open(dir.path(), &id).unwrap();
        assert_eq!(restored.conversation[2].log_line, Some(7));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_tool_after_smart_compaction_points_to_history_once() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(
            vec![
                tool_call("c1"),
                text("done"),
                text("SUMMARY: pinged"),
                call("b1", "broken", json!({})),
                call("b2", "broken", json!({})),
                text("gave up"),
                call("b3", "broken", json!({})),
                text("again"),
            ],
            dir.path(),
        );
        agent.tools().register(
            ToolDefinition::new("broken", "fails", json!({"type": "object"})),
            Box::new(|_| Err(anyhow::anyhow!("boom"))),
        );
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        agent.compact(Some(CompactionMode::Smart), None).await.unwrap().expect("compacted");
        agent.send_message("what was the error?").await.unwrap();
        let tool_results = |seen: &Seen| -> Vec<String> {
            let last = seen.lock().unwrap().last().unwrap().clone();
            last.iter()
                .filter(|m| m.role == Role::Tool && m.name.as_deref() == Some("broken"))
                .map(|m| m.content.clone())
                .collect()
        };
        let results = tool_results(&seen);
        assert_eq!(results.len(), 2);
        assert!(results[0].contains(history::FAILED_TOOL_HINT), "first failure gets the hint: {}", results[0]);
        assert!(!results[1].contains(history::FAILED_TOOL_HINT), "only once: {}", results[1]);
        agent.send_message("try once more").await.unwrap();
        let results = tool_results(&seen);
        assert_eq!(results.len(), 3);
        assert!(!results[2].contains(history::FAILED_TOOL_HINT), "not again in a later turn: {}", results[2]);

        // Standard compaction never hints (no history tools).
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = self::agent(
            vec![tool_call("c1"), text("done"), text("SUMMARY"), call("b1", "broken", json!({})), text("x")],
            dir.path(),
        );
        agent.tools().register(
            ToolDefinition::new("broken", "fails", json!({"type": "object"})),
            Box::new(|_| Err(anyhow::anyhow!("boom"))),
        );
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        agent.compact(Some(CompactionMode::Standard), None).await.unwrap().expect("compacted");
        agent.send_message("what was the error?").await.unwrap();
        assert!(!tool_results(&seen).iter().any(|r| r.contains(history::FAILED_TOOL_HINT)));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_spoofed_summary_prefix_does_not_unlock_history_tools() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![], dir.path());
        agent.new_session().unwrap();
        // A user message that merely begins with the summary prefix must not be
        // mistaken for a real smart summary: the history tools stay gated until
        // an actual smart compaction sets the state.
        agent.push(Message::user(&format!("{}\nnot a real summary", context::SMART_SUMMARY_PREFIX))).unwrap();
        assert!(
            !agent.tool_definitions().iter().any(|d| history::is_history_tool(&d.name)),
            "history tools must not be unlocked by message text alone"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn smart_mode_needs_a_session_log() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![tool_call("c1"), text("done"), text("SUMMARY")], dir.path());
        agent.config_mut().persist_sessions = false;
        agent.config_mut().compaction_mode = CompactionMode::Smart;
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert_eq!(report.mode, CompactionMode::Standard);
        assert!(agent.conversation()[1].content.starts_with(context::SUMMARY_PREFIX));
        assert!(!agent.tool_definitions().iter().any(|d| history::is_history_tool(&d.name)));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn persisted_sessions_spill_beside_their_log() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![call("big1", "echo", json!({"text": "y".repeat(50)})), text("ok")], dir.path());
        agent.set_tool_output_limit(10);
        let id = agent.new_session().unwrap();
        agent.send_message("go").await.unwrap();
        let path = session::spill_dir_for(dir.path(), &id).join("tool-big1-echo.txt");
        assert_eq!(std::fs::read_to_string(path).unwrap(), "y".repeat(50));
        assert_eq!(*agent.spill_dir_handle().read().unwrap(), session::spill_dir_for(dir.path(), &id));
    }

    #[test]
    fn new_session_resets_cumulative_counters() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![], dir.path());
        {
            // Seed the cumulative counters shared with `/context` and the
            // status line, as if a prior session had accrued usage.
            let stats = agent.context_stats();
            let mut stats = stats.lock().unwrap();
            stats.session_input_tokens = 1_234;
            stats.session_output_tokens = 567;
            stats.session_aic = Some(1.5);
            stats.compactions = 3;
        }
        agent.new_session().unwrap();
        let stats = agent.context_stats();
        let stats = stats.lock().unwrap();
        assert_eq!(stats.session_input_tokens, 0);
        assert_eq!(stats.session_output_tokens, 0);
        assert_eq!(stats.session_aic, None);
        assert_eq!(stats.compactions, 0);
    }

    #[test]
    fn record_usage_accumulates_aic_when_reported() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![], dir.path());
        let response = |aic: Option<f64>| LLMResponse {
            usage: Some(crate::llm::TokenUsage { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15, aic }),
            ..Default::default()
        };
        // A provider that reports credits accumulates them.
        agent.record_usage(&response(Some(0.0116)), false);
        agent.record_usage(&response(Some(0.0425)), false);
        assert_eq!(agent.context_stats().lock().unwrap().session_aic, Some(0.0541));
        // A response without credits leaves the total untouched.
        agent.record_usage(&response(None), false);
        assert_eq!(agent.context_stats().lock().unwrap().session_aic, Some(0.0541));
    }

    /// Replays scripted responses and records each request's `max_tokens`
    /// and whether it was a compaction summary.
    struct Budgeted {
        responses: Mutex<Vec<LLMResponse>>,
        seen: BudgetLog,
    }

    #[async_trait]
    impl LLMClient for Budgeted {
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            let summary = request.messages[0].content.starts_with(context::SUMMARY_SYSTEM_PROMPT);
            self.seen.lock().unwrap().push((request.max_tokens, summary));
            Ok(self.responses.lock().unwrap().remove(0))
        }
        fn model_name(&self) -> &str {
            "budgeted"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
    }

    type BudgetLog = Arc<Mutex<Vec<(Option<i64>, bool)>>>;

    /// An agent with `window` tokens of context, `max_tokens = 16384`, a
    /// threshold high enough that only the output reservation can trigger
    /// compaction, and a `big` tool returning `chars` characters.
    fn budgeted_agent(
        responses: Vec<LLMResponse>,
        window: usize,
        chars: usize,
        dir: &std::path::Path,
    ) -> (Agent, BudgetLog) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = Budgeted { responses: Mutex::new(responses), seen: seen.clone() };
        let config = Config {
            session_dir: Some(dir.to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            context_window: Some(window),
            auto_compact_threshold: 0.99,
            max_tokens: 16_384,
            ..Config::default()
        };
        let agent = Agent::new(Box::new(client), config);
        agent.tools().register(
            ToolDefinition::new("big", "big", json!({"type": "object"})),
            Box::new(move |_| Ok(json!("word ".repeat(chars / 5)))),
        );
        (agent, seen)
    }

    fn big_call(id: &str) -> LLMResponse {
        LLMResponse {
            tool_calls: vec![ToolCall {
                id: id.into(),
                name: "big".into(),
                arguments: json!({}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        }
    }

    /// An Anthropic-kind Claude client that records the temperature and
    /// thinking level of each request.
    type SeenSettings = Arc<Mutex<Vec<(Option<f64>, Option<crate::thinking::Request>)>>>;

    struct Claude {
        seen: SeenSettings,
    }

    #[async_trait]
    impl LLMClient for Claude {
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            self.seen.lock().unwrap().push((request.temperature, request.thinking.clone()));
            Ok(text("ok"))
        }
        fn model_name(&self) -> &str {
            "claude-sonnet-4-6"
        }
        fn provider_name(&self) -> &str {
            "anthropic"
        }
        fn kind(&self) -> Option<providers::ProviderKind> {
            Some(providers::ProviderKind::Anthropic)
        }
    }

    /// An Anthropic double that calls a tool once, then answers.
    struct ClaudeWithTool {
        seen: SeenSettings,
        responses: Mutex<Vec<LLMResponse>>,
    }

    #[async_trait]
    impl LLMClient for ClaudeWithTool {
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            self.seen.lock().unwrap().push((request.temperature, request.thinking.clone()));
            Ok(self.responses.lock().unwrap().remove(0))
        }
        fn model_name(&self) -> &str {
            "claude-sonnet-4-6"
        }
        fn provider_name(&self) -> &str {
            "anthropic"
        }
        fn kind(&self) -> Option<providers::ProviderKind> {
            Some(providers::ProviderKind::Anthropic)
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_thinking_level_set_mid_turn_applies_from_the_next_step() {
        use crate::thinking::{Request, Source, Thinking};
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = ClaudeWithTool { seen: seen.clone(), responses: Mutex::new(vec![tool_call("c1"), text("done")]) };
        let config = Config { session_dir: Some(dir.path().to_path_buf()), ..Default::default() };
        let mut agent = Agent::new(Box::new(client), config);
        agent.new_session().unwrap();
        // `/thinking high` typed while the turn runs: the CLI sets it on the
        // shared control, here from inside the tool, between the two steps.
        let control = agent.control();
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(move |_| {
                control.set_thinking(Some(Thinking::Level("high".into())));
                Ok(json!("pong"))
            }),
        );
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        let sent: Vec<_> = seen.lock().unwrap().iter().map(|(_, t)| t.clone()).collect();
        assert_eq!(sent, vec![None, Some(Request::Effort("high".into()))]);
        assert_eq!(agent.thinking().source, Source::Session);
        assert_eq!(agent.context_stats().lock().unwrap().thinking.as_deref(), Some("high"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_mid_turn_thinking_change_applies_from_the_next_step_and_drops_the_temperature() {
        use crate::thinking::{Request, Thinking};
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = ClaudeWithTool { seen: seen.clone(), responses: Mutex::new(vec![tool_call("c1"), text("done")]) };
        // A custom temperature is configured, so the two steps differ only in
        // whether thinking drops it: step 1 (no level) sends it, step 2
        // (thinking on) must not.
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            temperature: crate::temperature::Temperature::Value(0.5),
            ..Default::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.new_session().unwrap();
        // `/thinking high` typed mid-turn from inside the tool, between steps.
        // This exercises the BETWEEN-steps path (the next step picks the level
        // up); the WITHIN-one-request race — a change landing between the
        // snapshot and the temperature read of a single call — is covered by
        // `request_settings_derives_temperature_from_the_snapshot_not_a_reread`,
        // which a between-steps tool mutation cannot reproduce.
        let control = agent.control();
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(move |_| {
                control.set_thinking(Some(Thinking::Level("high".into())));
                Ok(json!("pong"))
            }),
        );
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        // Temperature and thinking come from one snapshot per step, so the
        // step that turns thinking on drops the temperature in the SAME
        // request — never sends `high` with a stale custom temperature.
        let sent: Vec<_> = seen.lock().unwrap().iter().cloned().collect();
        assert_eq!(
            sent,
            vec![(Some(0.5), None), (None, Some(Request::Effort("high".into())))],
            "the thinking-on step must drop the temperature in its own request"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn status_line_reflects_the_level_the_request_sends_not_a_reread() {
        use crate::thinking::{Request, Thinking};
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = ClaudeWithTool { seen: seen.clone(), responses: Mutex::new(vec![tool_call("c1"), text("done")]) };
        let config = Config { session_dir: Some(dir.path().to_path_buf()), ..Default::default() };
        let mut agent = Agent::new(Box::new(client), config);
        agent.new_session().unwrap();
        // Record `stats.thinking` at every `Context` emission, so the test can
        // see the value the status line showed at each step's status update.
        let stats = agent.context_stats();
        let shown = Arc::new(Mutex::new(Vec::new()));
        let (shown_sink, shown_stats) = (shown.clone(), stats.clone());
        agent.set_event_sink(Box::new(move |_, event| {
            if matches!(event, AgentEvent::Context) {
                shown_sink.lock().unwrap().push(shown_stats.lock().unwrap().thinking.clone());
            }
        }));
        // The session level is `low` from before the turn, so step 1 snapshots
        // and sends `low`. `stats.thinking` starts `None`, so step 1's
        // status-change branch fires (None → low) — the moment under test.
        let control = agent.control();
        control.set_thinking(Some(Thinking::Level("low".into())));
        // The tool only keeps the turn going into a second step; it does not
        // touch the level.
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(move |_| Ok(json!("pong"))),
        );
        // A `/thinking high` lands between step 1's snapshot and its status
        // update (the `after_thinking_snapshot` window). The status step 1
        // shows must be the level step 1 SENT (`low`), not the `high` a re-read
        // of the shared control would observe. The hook fires once, in that
        // window, while the control still reads `low`.
        let flipped = Arc::new(AtomicBool::new(false));
        let hook_flipped = flipped.clone();
        let hook_control = agent.control();
        let probe = agent.control();
        agent.after_thinking_snapshot = Some(Box::new(move || {
            let at_step1 = matches!(probe.thinking(), Some(Thinking::Level(ref l)) if l == "low");
            if at_step1 && !hook_flipped.swap(true, Ordering::SeqCst) {
                hook_control.set_thinking(Some(Thinking::Level("high".into())));
            }
        }));
        agent.run_turn(Some("in-1"), "go").await.unwrap();

        let sent: Vec<_> = seen.lock().unwrap().iter().map(|(_, t)| t.clone()).collect();
        assert_eq!(
            sent,
            vec![Some(Request::Effort("low".into())), Some(Request::Effort("high".into()))],
            "step 1 sends the pre-flip `low`; step 2 picks up the flipped `high`"
        );
        assert!(flipped.load(Ordering::SeqCst), "the interleave fired at step 1");
        // The first status line that shows a level is step 1's update. It must
        // show `low` — the level step 1's request sent. The OLD code re-resolved
        // the (now `high`) control via `refresh_stats()`, showing `high` while
        // the request sent `low`: this assertion is red against that code.
        let first_shown = shown.lock().unwrap().iter().find_map(|t| t.clone());
        assert_eq!(
            first_shown.as_deref(),
            Some("low"),
            "step 1's status must show the level its request sent (`low`), not the mid-step re-read (`high`)"
        );
    }

    #[test]
    fn request_settings_derives_temperature_from_the_snapshot_not_a_reread() {
        // `request_settings_for` takes the session level by value, so it has
        // no shared-control read a mid-build `/thinking` change could land on:
        // temperature is derived from the same snapshot the request sends.
        // This pins that contract: a level resolved from the snapshot must
        // drive the temperature even when the live control disagrees.
        use crate::thinking::{Request, Thinking};
        let dir = tempfile::tempdir().unwrap();
        // A custom temperature is configured, so a stale thinking read shows
        // up as a temperature the thinking-on request must not send.
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            temperature: crate::temperature::Temperature::Value(0.5),
            ..Default::default()
        };
        let agent = Agent::new(Box::new(Claude { seen: Arc::new(Mutex::new(Vec::new())) }), config);
        // The live control says `high` (thinking on, which on Anthropic drops
        // the temperature), but the request's snapshot — taken before a
        // mid-build `/thinking high` landed — carries no level.
        agent.control().set_thinking(Some(Thinking::Level("high".into())));

        let (thinking, temperature, _) = agent.request_settings_for(None);

        // The snapshot wins: the request sends no level AND keeps the
        // temperature. Deriving temperature from the live control instead
        // would drop it for a `high` the request never carries — the
        // within-one-request inconsistency the by-value snapshot removes.
        assert_eq!(thinking.request(), None);
        assert_eq!(
            temperature.value(),
            Some(0.5),
            "temperature must come from the snapshot the request sends, not a second read of the control"
        );
        // And the converse: a snapshot carrying the level drives the
        // temperature drop even when the control has since been cleared.
        agent.control().set_thinking(None);
        let (thinking, temperature, _) = agent.request_settings_for(Some(Thinking::Level("high".into())));
        assert_eq!(thinking.request(), Some(Request::Effort("high".into())));
        assert_eq!(
            temperature.value(),
            None,
            "a thinking-on snapshot must drop the temperature even if the control was cleared mid-build"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn thinking_level_is_sent_and_drops_the_temperature_on_anthropic() {
        use crate::thinking::{Request, Source, Thinking};
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            temperature: crate::temperature::Temperature::Value(0.5),
            ..Default::default()
        };
        let mut agent = Agent::new(Box::new(Claude { seen: seen.clone() }), config);
        agent.new_session().unwrap();

        // Nothing configured: no level, and the temperature is sent.
        agent.run_turn(Some("in-1"), "a").await.unwrap();
        // A session level: sent as adaptive effort, and the temperature dropped.
        agent.set_thinking(Some(Thinking::Level("high".into())));
        assert_eq!(agent.thinking().source, Source::Session);
        assert!(agent.temperature().fixed.is_some());
        agent.run_turn(Some("in-2"), "b").await.unwrap();
        // Off: sent, and the temperature comes back.
        agent.set_thinking(Some(Thinking::Off));
        agent.run_turn(Some("in-3"), "c").await.unwrap();
        assert_eq!(
            *seen.lock().unwrap(),
            vec![(Some(0.5), None), (None, Some(Request::Effort("high".into()))), (Some(0.5), Some(Request::Off))]
        );
        // The log records the level only once one is set.
        let logged: Vec<Option<String>> = agent
            .conversation()
            .iter()
            .filter(|m| m.role == Role::Assistant)
            .map(|m| m.thinking_level.clone())
            .collect();
        assert_eq!(
            logged,
            vec![None, Some("high (set for this session)".into()), Some("off (set for this session)".into())]
        );

        // `reset` goes back to the config.
        agent.set_thinking(None);
        assert_eq!((agent.thinking().effective, agent.thinking().source), (Thinking::Default, Source::Global));
    }

    #[test]
    fn status_bar_reports_nothing_for_a_dropped_level() {
        use crate::thinking::Thinking;
        // `drop_params` strips the generated field after the body is built, so
        // the level never reaches the wire. The status projection must show no
        // level — like an extra_body override — not the configured one.
        let mut config = Config::default();
        config.providers.insert(
            "mock".into(),
            providers::ProviderConfig { drop_params: Some(vec!["reasoning_effort".into()]), ..Default::default() },
        );
        let mut agent = Agent::new(Box::new(providers::mock::MockLLMClient::new("mock", "gpt-5")), config);
        agent.set_thinking(Some(Thinking::Level("high".into())));
        assert!(agent.thinking().dropped, "the reasoning_effort field is dropped");
        assert_eq!(agent.context_stats().lock().unwrap().thinking, None, "a dropped level is not shown as sent");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn session_transitions_clear_the_thinking_override() {
        use crate::thinking::{Source, Thinking};
        // `/thinking` is session-scoped, so the previous session's override must
        // not leak into a new or resumed session.
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            persist_sessions: true,
            project_instructions: false,
            ..Default::default()
        };
        let mut agent = Agent::new(Box::new(providers::mock::MockLLMClient::new("mock", "gpt-4o-mini")), config);
        agent.new_session().unwrap();
        agent.set_thinking(Some(Thinking::Level("high".into())));
        assert_eq!(agent.thinking().source, Source::Session);

        // A new session drops the override back to the config default.
        agent.new_session().unwrap();
        assert_eq!((agent.thinking().effective, agent.thinking().source), (Thinking::Default, Source::Global));

        // … and so does resuming a persisted session.
        let resumed = agent.new_session().unwrap();
        agent.set_thinking(Some(Thinking::Level("high".into())));
        agent.load_session(&resumed).unwrap();
        assert_eq!((agent.thinking().effective, agent.thinking().source), (Thinking::Default, Source::Global));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_new_session_keeps_the_thinking_override() {
        use crate::thinking::{Source, Thinking};
        // Failure-atomic staging: when `new_session` cannot persist, the live
        // session — including its `/thinking` override — must stay untouched.
        let dir = tempfile::tempdir().unwrap();
        // A regular file where the session directory must be makes
        // `SessionLog::create` fail, so the switch cannot commit.
        let blocker = dir.path().join("sessions");
        std::fs::write(&blocker, b"not a directory").unwrap();
        let config = Config {
            session_dir: Some(blocker),
            persist_sessions: true,
            project_instructions: false,
            ..Default::default()
        };
        let mut agent = Agent::new(Box::new(providers::mock::MockLLMClient::new("mock", "gpt-4o-mini")), config);
        agent.set_thinking(Some(Thinking::Level("high".into())));
        assert!(agent.new_session().is_err(), "the unwritable session dir fails the switch");
        assert_eq!(agent.thinking().source, Source::Session, "the live session's override survives a failed switch");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn compaction_keeps_the_temperature_when_turns_think_on_anthropic() {
        use crate::thinking::Thinking;
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            temperature: crate::temperature::Temperature::Value(0.5),
            ..Default::default()
        };
        let mut agent = Agent::new(Box::new(Claude { seen: seen.clone() }), config);
        agent.new_session().unwrap();
        agent.set_thinking(Some(Thinking::Level("high".into())));
        // A normal turn thinks, so Anthropic drops the custom temperature.
        assert!(agent.temperature().fixed.is_some());
        // Compaction sends no thinking field, which disables thinking for a
        // model with an `off` level, so the configured temperature is
        // resolved as thinking-off and still sent.
        let compaction = agent.temperature_for(agent.thinking().always_anthropic_thinking());
        assert!(compaction.fixed.is_none(), "compaction keeps the custom temperature");
        assert_eq!(compaction.value(), Some(0.5));
        // Nothing is configured, so the same holds before any turn runs.
        agent.set_thinking(None);
        let compaction = agent.temperature_for(agent.thinking().always_anthropic_thinking());
        assert!(compaction.fixed.is_none(), "compaction keeps the custom temperature by default too");
        assert_eq!(compaction.value(), Some(0.5));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn compaction_sends_no_temperature_to_an_always_thinking_model() {
        // A model whose known levels omit `off` (Fable, Claude 5.5+) always
        // thinks, so the compaction request — which sends no thinking field —
        // still thinks, and a configured custom temperature is invalid there.
        struct Fable;
        #[async_trait]
        impl LLMClient for Fable {
            async fn chat(&self, _request: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!("no chat in this test")
            }
            fn model_name(&self) -> &str {
                "claude-fable-5"
            }
            fn provider_name(&self) -> &str {
                "anthropic"
            }
            fn kind(&self) -> Option<providers::ProviderKind> {
                Some(providers::ProviderKind::Anthropic)
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            temperature: crate::temperature::Temperature::Value(0.5),
            ..Default::default()
        };
        let mut agent = Agent::new(Box::new(Fable), config);
        agent.new_session().unwrap();
        // Nothing is configured, yet the model always thinks, so the
        // compaction request — which sends no thinking field — still thinks,
        // and a configured custom temperature is invalid there.
        assert!(agent.thinking().always_anthropic_thinking());
        let compaction = agent.temperature_for(agent.thinking().always_anthropic_thinking());
        assert!(compaction.fixed.is_some(), "an always-thinking model gets no custom temperature, even for compaction");
        assert_eq!(compaction.value(), None);
        // A configured level that compaction does not send changes nothing:
        // the model always thinks.
        agent.set_thinking(Some(crate::thinking::Thinking::Level("high".into())));
        let compaction = agent.temperature_for(agent.thinking().always_anthropic_thinking());
        assert!(compaction.fixed.is_some(), "an unsent level does not unlock the temperature");
        assert_eq!(compaction.value(), None);
    }

    #[test]
    fn a_small_max_tokens_caps_the_thinking_budget_with_a_warning() {
        let dir = tempfile::tempdir().unwrap();
        let config = Config { session_dir: Some(dir.path().to_path_buf()), max_tokens: 4096, ..Default::default() };
        struct OldClaude;
        #[async_trait]
        impl LLMClient for OldClaude {
            async fn chat(&self, _request: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!("no chat in this test")
            }
            fn model_name(&self) -> &str {
                "claude-sonnet-4-5"
            }
            fn provider_name(&self) -> &str {
                "anthropic"
            }
            fn kind(&self) -> Option<providers::ProviderKind> {
                Some(providers::ProviderKind::Anthropic)
            }
        }
        let mut agent = Agent::new(Box::new(OldClaude), config);
        agent.set_thinking(Some(crate::thinking::Thinking::Level("high".into())));
        let warning = agent.thinking().warning.unwrap();
        assert!(warning.contains("caps the high thinking budget"), "{warning}");
    }

    #[test]
    fn no_room_for_a_budget_drops_the_level_everywhere() {
        use crate::thinking::Thinking;
        struct OldClaude;
        #[async_trait]
        impl LLMClient for OldClaude {
            async fn chat(&self, _request: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!("no chat in this test")
            }
            fn model_name(&self) -> &str {
                "claude-sonnet-4-5"
            }
            fn provider_name(&self) -> &str {
                "anthropic"
            }
            fn kind(&self) -> Option<providers::ProviderKind> {
                Some(providers::ProviderKind::Anthropic)
            }
        }
        // `max_tokens` below the minimum budget leaves no room at all.
        let make = || {
            let dir = tempfile::tempdir().unwrap();
            let config = Config {
                session_dir: Some(dir.path().to_path_buf()),
                max_tokens: 1024,
                temperature: crate::temperature::Temperature::Value(0.5),
                ..Default::default()
            };
            (Agent::new(Box::new(OldClaude), config), dir)
        };

        // A known level with no room: effective drops to Default so the level
        // is not reported active, no thinking request is sent, and the
        // Anthropic temperature lock lifts (thinking is actually off).
        let (mut agent, _dir) = make();
        agent.set_thinking(Some(Thinking::Level("high".into())));
        let resolved = agent.thinking();
        assert_eq!(resolved.effective, Thinking::Default);
        assert_eq!(resolved.request(), None);
        assert!(resolved.warning.unwrap().contains("leaves no room"));
        assert!(agent.temperature().fixed.is_none(), "no thinking means no temperature lock");

        // An adjusted level (`xhigh` → `high`) is still checked even though the
        // fit already warned; both warnings are kept.
        let (mut agent, _dir) = make();
        agent.set_thinking(Some(Thinking::Level("xhigh".into())));
        let resolved = agent.thinking();
        assert_eq!(resolved.effective, Thinking::Default);
        let warning = resolved.warning.unwrap();
        assert!(warning.contains("using"), "keeps the fit warning: {warning}");
        assert!(warning.contains("leaves no room"), "adds the feasibility warning: {warning}");
    }

    #[test]
    fn refreshing_stats_tracks_a_max_tokens_driven_thinking_change() {
        use crate::thinking::Thinking;
        struct OldClaude;
        #[async_trait]
        impl LLMClient for OldClaude {
            async fn chat(&self, _request: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!("no chat in this test")
            }
            fn model_name(&self) -> &str {
                "claude-sonnet-4-5"
            }
            fn provider_name(&self) -> &str {
                "anthropic"
            }
            fn kind(&self) -> Option<providers::ProviderKind> {
                Some(providers::ProviderKind::Anthropic)
            }
        }
        let dir = tempfile::tempdir().unwrap();
        let config = Config { session_dir: Some(dir.path().to_path_buf()), max_tokens: 16_384, ..Default::default() };
        let mut agent = Agent::new(Box::new(OldClaude), config);
        // A fixed-budget level fits the roomy cap: the status bar shows it.
        agent.set_thinking(Some(Thinking::Level("high".into())));
        assert_eq!(agent.context_stats().lock().unwrap().thinking.as_deref(), Some("high"));

        // Shrinking `max_tokens` leaves no budget room, so `thinking()` drops
        // the level. A refresh (what the `/settings` max_tokens edit now does)
        // must carry that drop into the stats; without it the bar stays stale.
        agent.config_mut().max_tokens = 1024;
        agent.refresh_stats();
        assert_eq!(agent.context_stats().lock().unwrap().thinking, None, "refresh reflects the dropped level");

        // Restoring the cap brings the level back on the next refresh.
        agent.config_mut().max_tokens = 16_384;
        agent.refresh_stats();
        assert_eq!(agent.context_stats().lock().unwrap().thinking.as_deref(), Some("high"), "refresh restores it");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn max_tokens_is_sent_unchanged_when_the_window_has_room() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = budgeted_agent(vec![big_call("b1"), text("done")], 200_000, 4_000, dir.path());
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(*seen.lock().unwrap(), vec![(Some(16_384), false), (Some(16_384), false)]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn prompt_only_window_does_not_shrink_max_tokens() {
        // A prompt-only window (GitHub Copilot's `max_prompt_tokens`) caps the
        // prompt alone, so the output reservation is not carved out of it: even
        // with the prompt near the window, `max_tokens` goes through unchanged
        // and no compaction is triggered by output room.
        let dir = tempfile::tempdir().unwrap();
        let window = 24_000;
        let (mut agent, seen) = budgeted_agent(vec![big_call("b1"), text("done")], window, 40_000, dir.path());
        agent.config_mut().context_window = None;
        agent.detected_window = Some(DetectedWindow {
            tokens: window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
        });
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 2, "no compaction against a prompt-only cap: {seen:?}");
        assert_eq!(seen[1], (Some(16_384), false), "max_tokens unchanged: {seen:?}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_lower_learned_window_restores_the_output_reservation() {
        // A prompt-only detected window (Copilot's `max_prompt_tokens`) leaves
        // `max_tokens` unchanged — until a context overflow teaches a *lower*
        // window. That learned window is a total prompt + output cap, so it
        // overrides the detected one and the output reservation counts again:
        // `max_tokens` is capped to the room instead of overflowing the learned
        // window a second time.
        let dir = tempfile::tempdir().unwrap();
        let detected = 24_000;
        let learned = 16_000;
        // One ~9k-token tool result: below the learned window's compaction
        // trigger, yet close enough that the reservation caps `max_tokens`.
        let (mut agent, seen) = budgeted_agent(vec![big_call("b1"), text("done")], detected, 36_000, dir.path());
        agent.config_mut().context_window = None;
        agent.detected_window = Some(DetectedWindow {
            tokens: detected,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
        });
        agent.learned_window = Some(learned);
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        let (tokens, _) = agent.estimate_context_tokens();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 2, "no compaction: {seen:?}");
        let (Some(max_tokens), false) = seen[1] else { panic!("{seen:?}") };
        assert!(max_tokens < 16_384, "capped to the learned window's room: {max_tokens}");
        assert!(tokens + max_tokens as usize <= learned, "{tokens} + {max_tokens} > {learned}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_prompt_only_window_is_capped_to_the_combined_window() {
        // Copilot advertises both `max_prompt_tokens` (prompt-only) and the
        // larger `max_context_window_tokens` (prompt + output). The prompt cap
        // does not consume output tokens, but the combined window still bounds
        // the whole request: `max_tokens` is capped to the room left in it
        // rather than sent unchanged.
        let dir = tempfile::tempdir().unwrap();
        let prompt_window = 100_000;
        let combined = 110_000;
        // No tool call, so nothing triggers compaction; a large user message
        // (user input is not bounded like tool output) fills the prompt to
        // ~96k tokens — under the prompt-only cap but within 16k of the
        // combined window, so `max_tokens` is capped to the combined room.
        let (mut agent, seen) = budgeted_agent(vec![text("done")], prompt_window, 0, dir.path());
        agent.config_mut().context_window = None;
        agent.detected_window = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: Some(combined),
        });
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), &"w".repeat(384_000)).await.unwrap();
        let (tokens, _) = agent.estimate_context_tokens();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "no tool call, no compaction: {seen:?}");
        let (Some(max_tokens), false) = seen[0] else { panic!("{seen:?}") };
        assert!(max_tokens < 16_384, "capped to the combined window's room: {max_tokens}");
        assert!(tokens + max_tokens as usize <= combined, "{tokens} + {max_tokens} > {combined}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn prompt_only_window_compacts_against_the_combined_window() {
        // Copilot advertises `max_prompt_tokens = 100K` (prompt-only) and
        // `max_context_window_tokens = 102K` (prompt + output): a gap under the
        // reserve. A ~97.7K-token prompt is below the 0.99 prompt threshold
        // (99K) yet leaves under MIN_OUTPUT_RESERVE of output room in the
        // combined window. The output reservation must count against the
        // combined window so compaction triggers here — otherwise
        // `request_max_tokens()` would shrink `max_tokens` below the target
        // instead of compacting as promised.
        let dir = tempfile::tempdir().unwrap();
        let prompt_window = 100_000;
        let combined = 102_000;
        let (mut agent, seen) = budgeted_agent(vec![text("SUMMARY"), text("done")], prompt_window, 0, dir.path());
        agent.config_mut().context_window = None;
        agent.detected_window = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: Some(combined),
        });
        agent.new_session().unwrap();
        // Compactable history: a large earlier exchange. The running prompt is
        // ~97.7K tokens — over the combined window's reserve limit
        // (102K - 4096 - 102K/50 ~= 95.9K) but under the prompt-only 0.99
        // threshold (99K) — so only the combined-window reservation can trigger
        // compaction here.
        agent.push(Message::user("q")).unwrap();
        agent.push(Message::assistant(&"a".repeat(388_000))).unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.response, "done");
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 2, "summary, then the real call: {seen:?}");
        assert!(seen[0].1, "the first request is the compaction summary: {seen:?}");
        assert!(agent.context_stats().lock().unwrap().compactions >= 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_prompt_only_window_keeps_the_estimation_margin() {
        // Copilot reports only `max_prompt_tokens = 100K` (prompt-only) and no
        // combined window. The prompt cap does not consume output tokens, so no
        // output reservation is carved out of it — but the estimation margin
        // (`output_margin`) still is, because the prompt estimate can undercount
        // and a prompt estimated just under the cap could really exceed it and
        // be rejected. A prompt sitting between the margin-protected limit
        // (100K - 100K/50 = 98K) and the raw 0.99 threshold (99K) must compact.
        let dir = tempfile::tempdir().unwrap();
        let prompt_window = 100_000;
        let (mut agent, seen) = budgeted_agent(vec![text("SUMMARY"), text("done")], prompt_window, 0, dir.path());
        agent.config_mut().context_window = None;
        agent.detected_window = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
        });
        agent.new_session().unwrap();
        // A ~98.5K-token prompt: over the margin-protected limit (98K) but under
        // the raw 0.99 threshold (99K), so only the estimation margin can
        // trigger compaction here.
        agent.push(Message::user("q")).unwrap();
        agent.push(Message::assistant(&"a".repeat(392_000))).unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.response, "done");
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 2, "summary, then the real call: {seen:?}");
        assert!(seen[0].1, "the first request is the compaction summary: {seen:?}");
        assert!(agent.context_stats().lock().unwrap().compactions >= 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_learned_window_tightens_the_effective_combined_window() {
        // Copilot advertises `max_prompt_tokens = 100K` (prompt-only) and a
        // larger `max_context_window_tokens = 128K` (prompt + output). A context
        // overflow then teaches a real 110K total cap — above the prompt-only
        // cap (so `context_cap()` stays `Prompt`) but below the advertised 128K
        // combined window. That learned total must become the effective combined
        // limit: `max_tokens` is capped to the room left in 110K, not 128K, so
        // the request does not overflow the learned window again.
        let dir = tempfile::tempdir().unwrap();
        let prompt_window = 100_000;
        let advertised = 128_000;
        let learned = 110_000;
        let (mut agent, seen) = budgeted_agent(vec![text("done")], prompt_window, 0, dir.path());
        agent.config_mut().context_window = None;
        agent.detected_window = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: Some(advertised),
        });
        agent.learned_window = Some(learned);
        agent.new_session().unwrap();
        // A ~96K-token prompt: under the prompt-only cap (no compaction) but
        // within the reserve of the learned 110K combined window. Against the
        // advertised 128K it would leave ample room and send `max_tokens`
        // unchanged; against the learned 110K it is capped.
        agent.run_turn(Some("in-1"), &"w".repeat(384_000)).await.unwrap();
        let (tokens, _) = agent.estimate_context_tokens();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "no compaction: {seen:?}");
        let (Some(max_tokens), false) = seen[0] else { panic!("{seen:?}") };
        assert!(max_tokens < 16_384, "capped to the learned combined window's room: {max_tokens}");
        assert!(tokens + max_tokens as usize <= learned, "{tokens} + {max_tokens} > {learned}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_learned_window_is_the_combined_cap_when_no_total_is_advertised() {
        // Copilot reports only `max_prompt_tokens = 100K` (prompt-only) and no
        // `max_context_window_tokens`, so `total_tokens` is `None`. A context
        // overflow then teaches a real 110K total cap — above the prompt-only
        // cap, so `context_cap()` stays `Prompt`. With no advertised combined
        // window, the learned total is the *only* prompt + output limit:
        // `max_tokens` must be capped to the room left in it rather than sent
        // unchanged and overflowing the learned window again on the retry.
        let dir = tempfile::tempdir().unwrap();
        let prompt_window = 100_000;
        let learned = 110_000;
        let (mut agent, seen) = budgeted_agent(vec![text("done")], prompt_window, 0, dir.path());
        agent.config_mut().context_window = None;
        agent.detected_window = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
        });
        agent.learned_window = Some(learned);
        agent.new_session().unwrap();
        // A ~96K-token prompt: under the prompt-only cap (no compaction) but
        // within the reserve of the learned 110K combined window. With no
        // advertised combined window, `combined_window()` must fall back to the
        // learned total so `max_tokens` is capped to its room.
        agent.run_turn(Some("in-1"), &"w".repeat(384_000)).await.unwrap();
        let (tokens, _) = agent.estimate_context_tokens();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1, "no compaction: {seen:?}");
        let (Some(max_tokens), false) = seen[0] else { panic!("{seen:?}") };
        assert!(max_tokens < 16_384, "capped to the learned combined window's room: {max_tokens}");
        assert!(tokens + max_tokens as usize <= learned, "{tokens} + {max_tokens} > {learned}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn max_tokens_shrinks_so_prompt_and_output_fit_the_window() {
        let dir = tempfile::tempdir().unwrap();
        let window = 24_000;
        let (mut agent, seen) = budgeted_agent(vec![big_call("b1"), text("done")], window, 40_000, dir.path());
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        let (tokens, _) = agent.estimate_context_tokens();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 2, "no compaction: {seen:?}");
        let (Some(max_tokens), false) = seen[1] else { panic!("{seen:?}") };
        assert!((MIN_OUTPUT_RESERVE as i64..16_384).contains(&max_tokens), "lowered: {max_tokens}");
        // The prompt estimate here includes the final "done", a few tokens.
        assert!(tokens + max_tokens as usize <= window, "{tokens} + {max_tokens} > {window}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn max_tokens_is_capped_to_the_room_when_compaction_is_disabled() {
        let dir = tempfile::tempdir().unwrap();
        // A small window nearly filled by one tool result leaves fewer than
        // MIN_OUTPUT_RESERVE tokens free. With auto_compact disabled there is no
        // pre-send compaction to open room, so the request must cap max_tokens to
        // the real room instead of flooring it to MIN_OUTPUT_RESERVE and pushing
        // prompt + max_tokens past the window.
        let window = 12_000;
        let (mut agent, seen) = budgeted_agent(vec![big_call("b1"), text("done")], window, 40_000, dir.path());
        agent.config.auto_compact = false;
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        let (tokens, _) = agent.estimate_context_tokens();
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 2, "no compaction when disabled: {seen:?}");
        let (Some(max_tokens), false) = seen[1] else { panic!("{seen:?}") };
        assert!(max_tokens >= 1, "request stays valid: {max_tokens}");
        assert!((max_tokens as usize) < MIN_OUTPUT_RESERVE, "capped below the floor: {max_tokens}");
        assert!(tokens + max_tokens as usize <= window, "{tokens} + {max_tokens} > {window}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn compacts_below_the_threshold_when_output_would_not_fit() {
        let dir = tempfile::tempdir().unwrap();
        // Two tool results (each clipped to about 10K tokens) leave less than
        // MIN_OUTPUT_RESERVE free, though
        // the prompt is far below the 0.99 threshold.
        let window = 24_000;
        let (mut agent, seen) = budgeted_agent(
            vec![big_call("b1"), big_call("b2"), text("SUMMARY"), text("done")],
            window,
            40_000,
            dir.path(),
        );
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.response, "done");
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 4, "call, call, summary, call: {seen:?}");
        assert!(seen[2].1, "the third request is the summary: {seen:?}");
        assert!(agent.context_stats().lock().unwrap().compactions >= 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn auto_compaction_mid_turn_keeps_the_turn_going() {
        let dir = tempfile::tempdir().unwrap();
        let big = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "b1".into(),
                name: "big".into(),
                arguments: json!({}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let (mut agent, seen) = agent(vec![big, text("SUMMARY"), text("done")], dir.path());
        agent.config.context_window = Some(3_000);
        agent.config.auto_compact_threshold = 0.5;
        agent.tools().register(
            ToolDefinition::new("big", "big", json!({"type": "object"})),
            Box::new(|_| Ok(json!("x".repeat(8_000)))),
        );
        let id = agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.response, "done");

        let requests = seen.lock().unwrap().clone();
        assert_eq!(requests.len(), 3, "call, summary, call");
        let last = &requests[2];
        assert!(last[1].content.starts_with(context::SUMMARY_PREFIX));
        assert_eq!(unstamped(&last[2]), Message::user("go"), "the in-flight input is restated");
        assert_eq!(last[3].tool_calls[0].id, "b1");
        assert_eq!(last[4].role, Role::Tool);
        assert!(last[4].content.contains("characters omitted"), "oversized result clipped");

        drop(agent);
        let (_, restored) = SessionLog::open(dir.path(), &id).unwrap();
        assert!(restored.pending_input.is_none());
        assert_eq!(restored.completed["in-1"], "done");
        assert_eq!(restored.conversation.last().map(unstamped), Some(Message::assistant("done")));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn replay_after_mid_turn_compaction_shows_the_folded_input_once() {
        // When auto-compaction folds the active input, the compacted
        // conversation restates it after the summary while the real copy rides
        // along in the replay stash. A legacy → frame switch replays BOTH the
        // stash and the conversation, so the synthetic restatement must be
        // skipped or the one submitted prompt would be shown twice.
        let dir = tempfile::tempdir().unwrap();
        let big = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "b1".into(),
                name: "big".into(),
                arguments: json!({}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let (mut agent, _seen) = agent(vec![big, text("SUMMARY"), text("done")], dir.path());
        agent.config.context_window = Some(3_000);
        agent.config.auto_compact_threshold = 0.5;
        agent.tools().register(
            ToolDefinition::new("big", "big", json!({"type": "object"})),
            Box::new(|_| Ok(json!("x".repeat(8_000)))),
        );
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();

        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen_sink = seen.clone();
        agent.set_event_sink(Box::new(move |_, event| {
            if let AgentEvent::UserMessage { text } = event {
                seen_sink.lock().unwrap().push(text.to_string());
            }
        }));
        agent.replay_history();
        let gos = seen.lock().unwrap().iter().filter(|t| t.as_str() == "go").count();
        assert_eq!(gos, 1, "the folded input is replayed exactly once: {:?}", seen.lock().unwrap());
        assert!(
            !seen.lock().unwrap().iter().any(|t| t.contains("SUMMARY")),
            "synthetic summary not exposed: {:?}",
            seen.lock().unwrap()
        );
    }
    /// `chat_stream`: a non-streaming summary request gets an idle-timeout
    /// error, as through a tunnel that drops connections sending no bytes.
    struct StreamOnlySummary {
        streamed: Arc<Mutex<usize>>,
    }

    #[async_trait]
    impl LLMClient for StreamOnlySummary {
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            if request.messages[0].content.starts_with(context::SUMMARY_SYSTEM_PROMPT) {
                anyhow::bail!("error sending request: idle connection dropped")
            }
            Ok(text("done"))
        }
        async fn chat_stream(
            &self,
            request: &ChatRequest<'_>,
            sink: crate::llm::StreamSink<'_>,
        ) -> Result<LLMResponse> {
            *self.streamed.lock().unwrap() += 1;
            assert!(request.messages[0].content.starts_with(context::SUMMARY_SYSTEM_PROMPT));
            sink(StreamEvent::Text("SUMMARY: "));
            sink(StreamEvent::Text("streamed"));
            Ok(text("SUMMARY: streamed"))
        }
        fn model_name(&self) -> &str {
            "stream-only-summary"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn compaction_streams_the_summary_request() {
        let dir = tempfile::tempdir().unwrap();
        let streamed = Arc::new(Mutex::new(0));
        let client = StreamOnlySummary { streamed: streamed.clone() };
        let config = Config { session_dir: Some(dir.path().to_path_buf()), ..Config::default() };
        let mut agent = Agent::new(Box::new(client), config);
        agent.new_session().unwrap();
        agent.send_message("one").await.unwrap();
        agent.send_message("two").await.unwrap();
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert_eq!(report.fallback, None, "summary must not fall back to dropping messages");
        assert_eq!(*streamed.lock().unwrap(), 1);
        assert!(agent.conversation()[1].content.ends_with("SUMMARY: streamed"));
    }

    /// Replays scripted results, including errors.
    struct Fallible {
        results: Mutex<Vec<std::result::Result<LLMResponse, String>>>,
        seen: Seen,
    }

    #[async_trait]
    impl LLMClient for Fallible {
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            self.seen.lock().unwrap().push(request.messages.to_vec());
            self.results.lock().unwrap().remove(0).map_err(|e| anyhow::anyhow!(e))
        }
        fn model_name(&self) -> &str {
            "fallible"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn context_overflow_compacts_and_retries_once() {
        let dir = tempfile::tempdir().unwrap();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        let overflow =
            "HTTP 400: This model's maximum context length is 4000 tokens. However, you requested 5000 tokens."
                .to_string();
        let client = Fallible {
            results: Mutex::new(vec![Ok(tool_call("c1")), Err(overflow), Ok(text("SUMMARY")), Ok(text("done"))]),
            seen: seen.clone(),
        };
        let config = Config { session_dir: Some(dir.path().to_path_buf()), ..Config::default() };
        let mut agent = Agent::new(Box::new(client), config);
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        agent.new_session().unwrap();
        assert_eq!(agent.send_message("ping").await.unwrap(), "done");
        assert_eq!(seen.lock().unwrap().len(), 4);
        let stats = agent.context_stats().lock().unwrap().clone();
        assert_eq!(stats.window, 4_000, "window learned from the error");
        assert_eq!(stats.compactions, 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_second_overflow_is_returned() {
        let dir = tempfile::tempdir().unwrap();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        let overflow = || Err("HTTP 400: prompt is too long: 9000 tokens > 8000 maximum".to_string());
        let client = Fallible {
            results: Mutex::new(vec![Ok(tool_call("c1")), overflow(), Ok(text("SUMMARY")), overflow()]),
            seen,
        };
        let config = Config { session_dir: Some(dir.path().to_path_buf()), ..Config::default() };
        let mut agent = Agent::new(Box::new(client), config);
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        agent.new_session().unwrap();
        let error = agent.send_message("ping").await.unwrap_err();
        assert!(format!("{error:#}").contains("prompt is too long"));
        assert_eq!(agent.context_stats().lock().unwrap().activity, Activity::Idle);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn overflow_smart_compaction_rebuilds_tools_before_retry() {
        // Records the tool names offered in each request, replaying scripted
        // results (some overflowing).
        struct ToolSpy {
            results: Mutex<Vec<std::result::Result<LLMResponse, String>>>,
            tools_seen: Arc<Mutex<Vec<Vec<String>>>>,
        }
        #[async_trait]
        impl LLMClient for ToolSpy {
            async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
                self.tools_seen.lock().unwrap().push(request.tools.iter().map(|t| t.name.clone()).collect());
                self.results.lock().unwrap().remove(0).map_err(|e| anyhow::anyhow!(e))
            }
            fn model_name(&self) -> &str {
                "toolspy"
            }
            fn provider_name(&self) -> &str {
                "test"
            }
        }

        let dir = tempfile::tempdir().unwrap();
        let tools_seen: Arc<Mutex<Vec<Vec<String>>>> = Arc::new(Mutex::new(Vec::new()));
        let overflow =
            "HTTP 400: This model's maximum context length is 4000 tokens. However, you requested 5000 tokens."
                .to_string();
        let client = ToolSpy {
            // 0: initial call -> tool call; 1: next request overflows (still
            // pre-compaction tools); 2: the summary request (no tools); 3: the
            // retry after the smart compaction (must now offer history tools).
            results: Mutex::new(vec![
                Ok(tool_call("c1")),
                Err(overflow),
                Ok(text("SUMMARY: pinged")),
                Ok(text("done")),
            ]),
            tools_seen: tools_seen.clone(),
        };
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            compaction_mode: CompactionMode::Smart,
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        agent.new_session().unwrap();
        assert_eq!(agent.send_message("ping").await.unwrap(), "done");

        let seen = tools_seen.lock().unwrap();
        assert_eq!(seen.len(), 4);
        // The overflowing attempt (before compaction) does not yet offer the
        // history tools...
        assert!(
            !seen[1].iter().any(|n| history::is_history_tool(n)),
            "history tools before smart compaction: {:?}",
            seen[1]
        );
        // ...but the retry issued after the overflow-triggered smart compaction
        // must, so the model can retrieve the folded history it was just told
        // about. Without rebuilding `tools` per iteration this reused seen[1].
        assert!(
            seen[3].contains(&history::SEARCH_TOOL.to_string()) && seen[3].contains(&history::READ_TOOL.to_string()),
            "retry after smart compaction must offer history tools: {:?}",
            seen[3]
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn overflow_retry_reresolves_thinking_against_the_post_compaction_room() {
        use crate::thinking::{Request, Thinking};
        // The thinking field and max_tokens recorded for each request.
        type SeenRequests = Arc<Mutex<Vec<(Option<Request>, Option<i64>)>>>;
        // Records the thinking field and max_tokens of each request, replaying
        // scripted results (one overflowing).
        struct ThinkingSpy {
            results: Mutex<Vec<std::result::Result<LLMResponse, String>>>,
            seen: SeenRequests,
        }
        #[async_trait]
        impl LLMClient for ThinkingSpy {
            async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
                self.seen.lock().unwrap().push((request.thinking.clone(), request.max_tokens));
                self.results.lock().unwrap().remove(0).map_err(|e| anyhow::anyhow!(e))
            }
            fn model_name(&self) -> &str {
                "claude-sonnet-4-5"
            }
            fn provider_name(&self) -> &str {
                "anthropic"
            }
            fn kind(&self) -> Option<providers::ProviderKind> {
                Some(providers::ProviderKind::Anthropic)
            }
        }

        let dir = tempfile::tempdir().unwrap();
        let seen: SeenRequests = Arc::new(Mutex::new(Vec::new()));
        let overflow =
            "HTTP 400: This model's maximum context length is 18000 tokens. However, you requested 19000 tokens."
                .to_string();
        let client = ThinkingSpy {
            // 0: the turn request overflows (the prompt is near the window, so
            // the output cap leaves no room for the thinking budget and the
            // level is dropped); 1: the compaction summary; 2: the retried
            // turn request, which after compaction has room for the budget
            // again and must send the level.
            results: Mutex::new(vec![Err(overflow), Ok(text("SUMMARY: done")), Ok(text("done"))]),
            seen: seen.clone(),
        };
        // An 18k window with a 16k-token prompt: `max_tokens` is capped to the
        // remaining room (18k − 16k − 360 margin ≈ 1.6k), below the 16k budget
        // `high` asks for, so the first attempt drops the level. Compaction
        // shrinks the prompt, the cap lifts past the budget, and the retry
        // sends it.
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            // Isolate memory in the temp dir: this test asserts exact token
            // arithmetic against an 18k window, and the post-compaction room the
            // retry re-resolves must not depend on the developer's real,
            // ever-growing memory index (which is injected into the system
            // prompt and would shift the count under the 16k budget).
            memory_dir: Some(dir.path().join("memory")),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            context_window: Some(18_000),
            max_tokens: 16_384,
            // The window arithmetic below leaves no room for the memory section.
            memory: crate::config::MemoryMode::Off,
            // Off, so the big prompt reaches the turn request and overflows
            // there instead of being auto-compacted beforehand.
            auto_compact: false,
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.new_session().unwrap();
        // `/thinking` is session-scoped, so set it after opening the session it
        // applies to (a session transition clears the previous override).
        agent.set_thinking(Some(Thinking::Level("high".into())));
        agent.push(Message::user(&"x".repeat(64_000))).unwrap();
        assert_eq!(agent.send_message("go").await.unwrap(), "done");

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 3, "overflow, summary, retry: {seen:?}");
        // The overflowing attempt had no room for the budget, so it sent no
        // thinking field.
        assert_eq!(seen[0].0, None, "no room before compaction: {:?}", seen[0]);
        let pre_cap = seen[0].1.unwrap();
        assert!(pre_cap < 1025, "capped below the minimum budget before compaction: {pre_cap}");
        // The summary request never thinks.
        assert_eq!(seen[1].0, None);
        // The retry re-resolved against the post-compaction room and sends the
        // full budget — not the stale pre-compaction drop.
        assert_eq!(seen[2].0, Some(Request::Budget(16_384)), "retry sends the level: {:?}", seen[2]);
        assert!(seen[2].1.unwrap() >= 16_384, "room for the budget after compaction: {:?}", seen[2]);
        // The trajectory records what the successful retry sent, not the
        // pre-compaction drop.
        let last = agent.conversation().iter().rev().find(|m| m.role == Role::Assistant).unwrap();
        assert_eq!(last.thinking_level.as_deref(), Some("high (set for this session)"));
    }

    #[tokio::test]
    async fn detected_window_sits_between_config_and_model_name() {
        struct Reports;
        #[async_trait]
        impl LLMClient for Reports {
            async fn chat(&self, _: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!()
            }
            async fn detect_context_window(&self) -> Option<DetectedWindow> {
                Some(DetectedWindow::total(65_536, "test"))
            }
            fn model_name(&self) -> &str {
                "claude-test"
            }
            fn provider_name(&self) -> &str {
                "test"
            }
        }
        let mut agent = Agent::new(Box::new(Reports), Config::default());
        assert_eq!(agent.context_window_with_source().1, "known for the model name");
        agent.detect_context_window().await;
        assert_eq!(agent.context_window_with_source(), (65_536, "reported by the endpoint (test)".into()));
        agent.config_mut().context_window = Some(32_000);
        agent.detect_context_window().await;
        assert_eq!(agent.context_window_with_source(), (32_000, "context_window in config".into()));
        assert!(agent.detected_window.is_none(), "no probe when config sets the window");
    }

    #[tokio::test]
    async fn a_configured_window_probes_only_the_thinking_levels() {
        // With the window set in config, the window half of the combined probe
        // is discarded — so it is not run at all (a configured LM Studio
        // provider would otherwise make the unnecessary `/api/v0/models`
        // follow-up). The thinking half still runs: `resolve_with` consumes the
        // reported adaptive/format data even when the level list is configured.
        use std::sync::{Arc, Mutex};
        struct Probes {
            calls: Arc<Mutex<Vec<&'static str>>>,
        }
        #[async_trait]
        impl LLMClient for Probes {
            async fn chat(&self, _: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!()
            }
            async fn detect_capabilities(
                &self,
            ) -> (Option<DetectedWindow>, Option<crate::thinking::Reported>, Option<crate::vision::Vision>) {
                self.calls.lock().unwrap().push("capabilities");
                (Some(DetectedWindow::total(65_536, "test")), None, None)
            }
            async fn detect_thinking_levels(&self) -> Option<crate::thinking::Reported> {
                self.calls.lock().unwrap().push("thinking");
                Some(crate::thinking::Reported {
                    levels: vec!["off".into(), "on".into()],
                    adaptive: false,
                    format: crate::thinking::Format::Effort,
                })
            }
            fn model_name(&self) -> &str {
                "claude-test"
            }
            fn provider_name(&self) -> &str {
                "test"
            }
        }
        let calls = Arc::new(Mutex::new(Vec::new()));
        let config = Config { context_window: Some(32_000), ..Default::default() };
        let mut agent = Agent::new(Box::new(Probes { calls: calls.clone() }), config);
        agent.detect_context_window().await;
        assert_eq!(*calls.lock().unwrap(), ["thinking"], "the discarded window half is not probed");
        assert_eq!(
            agent.reported_thinking.as_ref().map(|r| r.levels.as_slice()),
            Some(["off".to_string(), "on".to_string()].as_slice()),
            "the thinking levels are still probed"
        );
        assert!(agent.detected_window.is_none(), "the configured window stands");
    }

    #[test]
    fn estimate_is_anchored_to_reported_usage() {
        let (mut agent, _) = agent(vec![], std::path::Path::new("/nonexistent"));
        let (raw, calibrated) = agent.estimate_context_tokens();
        assert!(!calibrated && raw > 0);
        let response = LLMResponse {
            content: "hi".into(),
            usage: Some(crate::llm::TokenUsage {
                prompt_tokens: 1_000,
                completion_tokens: 50,
                total_tokens: 1_050,
                aic: None,
            }),
            ..Default::default()
        };
        agent.record_usage(&response, true);
        agent.conversation.push(Message::assistant("hi"));
        assert_eq!(agent.estimate_context_tokens(), (1_050, true));
        agent.conversation.push(Message::user("abcdefgh"));
        assert_eq!(agent.estimate_context_tokens(), (1_050 + 2 + 4, true));
        let stats = agent.context_stats();
        assert_eq!(stats.lock().unwrap().session_input_tokens, 1_000);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn streams_deltas_and_reports_thinking_before_the_answer() {
        let dir = tempfile::tempdir().unwrap();
        let thought = LLMResponse {
            content: "answer".into(),
            thinking: "reasoning".into(),
            thinking_blocks: vec![json!({"type": "thinking", "thinking": "reasoning", "signature": "s"})],
            ..Default::default()
        };
        let (mut agent, seen) = agent(vec![thought, text("later")], dir.path());
        agent.set_streaming(true);
        let names = Arc::new(Mutex::new(Vec::new()));
        let sink = names.clone();
        agent.set_event_sink(Box::new(move |_, event| {
            let name = match event {
                AgentEvent::ThinkingDelta { text } => format!("thinking-delta:{text}"),
                AgentEvent::TextDelta { text } => format!("text-delta:{text}"),
                AgentEvent::Thinking { text } => format!("thinking:{text}"),
                AgentEvent::AssistantMessage { text, .. } => format!("message:{text}"),
                _ => return,
            };
            sink.lock().unwrap().push(name);
        }));
        agent.send_message("hi").await.unwrap();
        assert_eq!(
            *names.lock().unwrap(),
            ["thinking-delta:reasoning", "text-delta:answer", "thinking:reasoning", "message:answer"]
        );
        // Thinking blocks travel with the assistant message; ACP reports a thought chunk.
        agent.send_message("again").await.unwrap();
        assert_eq!(seen.lock().unwrap()[1][2].thinking_blocks.len(), 1);
        let update = crate::acp::update_for(&AgentEvent::Thinking { text: "r" }).unwrap();
        assert_eq!(update["sessionUpdate"], "agent_thought_chunk");
        assert!(crate::acp::update_for(&AgentEvent::TextDelta { text: "r" }).is_none());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn one_shot_provider_publishes_usage_over_elapsed_rate() {
        // A provider whose `chat_stream` falls back to `report_whole` (default
        // trait impl) hands the whole response to the sink in one delta at
        // completion, so no live per-delta rate is published. The meter still
        // reports the turn's average at completion — exact `usage / elapsed`,
        // divided by the whole-call duration from generation start rather than
        // the near-zero delta span — which is the issue's one-shot fallback.
        // (The live rate is cleared when the turn goes idle, so it is observed
        // here as it is published, via the event sink during the turn.)
        let dir = tempfile::tempdir().unwrap();
        let mut response = text("the whole answer at once");
        response.usage = Some(crate::llm::TokenUsage { prompt_tokens: 3, completion_tokens: 6, ..Default::default() });
        let (mut agent, _) = agent(vec![response], dir.path());
        agent.set_streaming(true);
        let stats = agent.context_stats();
        let observed = Arc::new(Mutex::new(None::<f64>));
        let (obs, st) = (observed.clone(), stats.clone());
        agent.set_event_sink(Box::new(move |_, event| {
            if matches!(event, AgentEvent::Context)
                && let Some(rate) = st.lock().unwrap().tokens_per_sec
            {
                *obs.lock().unwrap() = Some(rate);
            }
        }));
        agent.new_session().unwrap();
        agent.send_message("hi").await.unwrap();
        let observed = *observed.lock().unwrap();
        assert!(
            observed.is_some_and(|r| r > 0.0),
            "a one-shot completion reports a usage/elapsed average, got {observed:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn adds_project_instructions_to_the_system_prompt_and_nested_ones_to_file_results() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(repo.join("pkg")).unwrap();
        std::fs::write(repo.join("AGENTS.md"), "Run make test before committing.").unwrap();
        std::fs::write(repo.join("pkg/AGENTS.md"), "Never edit generated files.").unwrap();
        let file = repo.join("pkg/lib.rs");
        let read = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "r1".into(),
                name: "read_file".into(),
                arguments: json!({"path": file}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let again = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "r2".into(),
                name: "read_file".into(),
                arguments: json!({"path": file}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let (mut agent, seen) = agent(vec![read, again, text("done")], dir.path());
        agent.tools().register(
            ToolDefinition::new("read_file", "read", json!({"type": "object"})),
            Box::new(|_| Ok(json!("fn main() {}"))),
        );
        agent.new_session().unwrap();
        agent.instructions = Some(ProjectInstructions::discover(&repo, &agent.config.project_instruction_files));
        agent.set_system_prompt("base").unwrap();
        assert_eq!(agent.project_instruction_files().len(), 1);
        agent.send_message("look").await.unwrap();

        let last = seen.lock().unwrap().last().unwrap().clone();
        assert!(last[0].content.starts_with("base") && last[0].content.contains("Run make test"));
        assert!(!last[0].content.contains("Never edit"));
        assert!(last[3].content.starts_with("fn main() {}") && last[3].content.contains("Never edit generated files."));
        // Attached once only.
        assert_eq!(last[5].content, "fn main() {}");
    }

    fn call(id: &str, name: &str, arguments: Value) -> LLMResponse {
        LLMResponse {
            tool_calls: vec![ToolCall {
                id: id.into(),
                name: name.into(),
                arguments,
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn indexes_skills_in_the_system_prompt_and_loads_them_on_request() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(repo.join(".agents/skills/release")).unwrap();
        std::fs::write(
            repo.join(".agents/skills/release/SKILL.md"),
            "---\nname: release\ndescription: Cut a release.\n---\nBump the version, then tag it.\n",
        )
        .unwrap();
        let (mut agent, seen) =
            agent(vec![call("s1", "load_skill", json!({"name": "release"})), text("done")], dir.path());
        agent.new_session().unwrap();
        assert!(!agent.tool_definitions().iter().any(|d| d.name == "load_skill"), "no skills, no tool");
        agent.skills = Skills::discover_in(&repo, &agent.config.skills, &skills::Locations::default());
        agent.set_system_prompt("base").unwrap();
        assert!(agent.tool_definitions().iter().any(|d| d.name == "load_skill"));
        agent.send_message("ship it").await.unwrap();

        let last = seen.lock().unwrap().last().unwrap().clone();
        assert!(
            last[0].content.contains("- `release`: Cut a release.") && !last[0].content.contains("Bump the version")
        );
        assert!(
            last[3].content.contains("Skill: release") && last[3].content.contains("Bump the version, then tag it.")
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn plan_survives_compaction_and_resume() {
        let dir = tempfile::tempdir().unwrap();
        let responses = vec![
            call("p1", "plan_add", json!({"goal": "Fix the bug", "items": ["Find it", "Fix it"]})),
            call("p2", "plan_update", json!({"id": 1, "status": "done", "note": "it is in parser.rs:40"})),
            call("p3", "plan_update", json!({"id": 7, "status": "done"})),
            text("found it"),
            text("SUMMARY: looked for the bug"),
        ];
        let (mut agent, seen) = agent(responses, dir.path());
        let events = record_events(&mut agent);
        let id = agent.new_session().unwrap();
        agent.send_message("go").await.unwrap();

        let first = seen.lock().unwrap()[1].clone();
        assert!(first[3].content.starts_with("Set the goal, added items 1-2."), "{}", first[3].content);
        let last = seen.lock().unwrap()[3].clone();
        assert!(last[7].is_error && last[7].content.contains("items are 1, 2"), "{}", last[7].content);
        assert_eq!(agent.plan().progress(), (1, 2));
        assert_eq!(agent.context_stats().lock().unwrap().plan, Some((1, 2)));

        let plans: Vec<Value> =
            events.lock().unwrap().iter().filter(|u| u["sessionUpdate"] == "plan").cloned().collect();
        assert_eq!(plans.len(), 2, "one per change; failed and read-only calls send none");
        assert_eq!(plans[1]["entries"][0], json!({"content": "Find it", "priority": "medium", "status": "completed"}));
        assert_eq!(plans[1]["_meta"]["plan"]["items"][0]["notes"][0], "it is in parser.rs:40");
        assert_eq!(Plan::from_value(&plans[1]["_meta"]["plan"]).unwrap(), agent.plan().clone());

        agent.compact(None, None).await.unwrap().expect("compacted");
        let summary = agent.conversation()[1].content.clone();
        assert!(summary.contains("SUMMARY: looked for the bug") && summary.contains("Goal: Fix the bug"), "{summary}");
        assert!(summary.contains("- it is in parser.rs:40") && summary.contains("Next: 2. Fix it"), "{summary}");

        let plan = agent.plan().clone();
        drop(agent);
        let (mut resumed, _) = agent_with_plan_off(dir.path(), false);
        resumed.load_session(&id).unwrap();
        assert_eq!(resumed.plan(), &plan);
        let (mut fresh, _) = agent_with_plan_off(dir.path(), false);
        fresh.new_session().unwrap();
        assert!(fresh.plan().is_empty());
    }

    #[test]
    fn plan_tools_can_be_turned_off() {
        let dir = tempfile::tempdir().unwrap();
        let (on, _) = agent_with_plan_off(dir.path(), false);
        assert!(on.tool_definitions().iter().any(|d| d.name == "plan_add"));
        let (off, _) = agent_with_plan_off(dir.path(), true);
        assert!(!off.tool_definitions().iter().any(|d| d.name.starts_with("plan_")));
    }

    fn agent_with_plan_off(dir: &std::path::Path, off: bool) -> (Agent, Seen) {
        let (mut agent, seen) = agent(Vec::new(), dir);
        agent.config.plan_tools = !off;
        (agent, seen)
    }

    fn report(id: &str, status: &str, summary: &str) -> ToolCall {
        ToolCall {
            id: id.into(),
            name: goal::TOOL_NAME.into(),
            arguments: json!({"status": status, "summary": summary}),
            item_id: None,
            malformed_arguments: None,
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn reporting_an_outcome_ends_the_turn_and_is_recorded() {
        let dir = tempfile::tempdir().unwrap();
        let batch = LLMResponse {
            tool_calls: vec![
                report("o1", "completed", "Opened PR #5"),
                ToolCall {
                    id: "c1".into(),
                    name: "echo".into(),
                    arguments: json!({"text": "pong"}),
                    item_id: None,
                    malformed_arguments: None,
                },
            ],
            ..Default::default()
        };
        // No further responses: another model call would panic.
        let (mut first, _) = agent(vec![batch], dir.path());
        let id = first.new_session().unwrap();
        let outcome = first.run_turn(Some("msg-1"), "ship it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "Opened PR #5");
        assert_eq!(outcome.outcome, Some(Outcome { status: goal::Status::Completed, summary: "Opened PR #5".into() }));
        let tail = &first.conversation()[first.conversation_length() - 3..];
        assert_eq!(
            unstamped(&tail[1]),
            Message::tool_result("c1", "echo", "pong"),
            "later calls in the batch still run"
        );
        assert_eq!(unstamped(&tail[2]), Message::assistant("Opened PR #5"));
        drop(first);

        let (mut resumed, seen) = agent(vec![], dir.path());
        resumed.load_session(&id).unwrap();
        let again = resumed.run_turn(Some("msg-1"), "ship it").await.unwrap();
        assert_eq!(again.outcome, outcome.outcome);
        assert!(seen.lock().unwrap().is_empty());
    }

    /// Build an agent with custom permission `deny` rules (and no helper
    /// tools), for the PreToolUse-rewrite tests below.
    fn agent_with_deny(responses: Vec<LLMResponse>, dir: &std::path::Path, deny: Vec<String>) -> Agent {
        let client = Scripted { responses: Mutex::new(responses), seen: Arc::new(Mutex::new(Vec::new())) };
        let config = Config {
            session_dir: Some(dir.to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            permissions: crate::permissions::PermissionsConfig { deny, ..Default::default() },
            ..Config::default()
        };
        Agent::new(Box::new(client), config)
    }

    /// Write a project `.claude/settings.json` with a PreToolUse hook that
    /// rewrites a matched tool's input to `updated_input_json` (Claude
    /// `tool_input` space) and allows it.
    fn write_pre_tool_use_hook(dir: &std::path::Path, matcher: &str, updated_input_json: &str) {
        let command = format!(
            "cat >/dev/null; printf '%s' '{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{updated_input_json}}}}}'",
        );
        let settings = json!({
            "hooks": { "PreToolUse": [ { "matcher": matcher, "hooks": [ { "type": "command", "command": command } ] } ] }
        });
        let claude = dir.join(".claude");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(claude.join("settings.json"), serde_json::to_string(&settings).unwrap()).unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn pre_tool_use_rewrite_is_rechecked_against_policy() {
        let dir = tempfile::tempdir().unwrap();
        // A PreToolUse hook rewrites every Bash command to `forbidden-cmd`,
        // which the policy denies — even though the original `ls` is allowed.
        write_pre_tool_use_hook(dir.path(), "Bash", r#"{"command":"forbidden-cmd"}"#);
        let ran = Arc::new(Mutex::new(Vec::<String>::new()));
        let recorder = ran.clone();
        let response = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "b1".into(),
                name: "bash".into(),
                arguments: json!({"command": "ls"}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let mut agent = agent_with_deny(vec![response, text("done")], dir.path(), vec!["Bash(forbidden-cmd*)".into()]);
        agent.tools().register(
            ToolDefinition::new("bash", "bash", json!({"type": "object"})),
            Box::new(move |args| {
                recorder.lock().unwrap().push(args["command"].as_str().unwrap_or("").to_string());
                Ok(json!("ran"))
            }),
        );
        agent.load_claude_hooks(dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "list files").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        let conversation = agent.conversation();
        let tool_result = conversation.iter().find(|m| m.role == Role::Tool).expect("a tool result");
        assert!(
            tool_result.is_error,
            "the hook-rewritten command must be re-checked against the policy and denied: {}",
            tool_result.content
        );
        assert!(
            ran.lock().unwrap().is_empty(),
            "the denied, rewritten command must never reach the bash handler, saw: {:?}",
            ran.lock().unwrap()
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn pre_tool_use_rewrite_reaches_special_tools() {
        let dir = tempfile::tempdir().unwrap();
        // A hook rewrites the outcome tool's `status` — a special-tool branch
        // that must honour the rewrite rather than silently drop it.
        write_pre_tool_use_hook(dir.path(), "report_outcome", r#"{"status":"blocked"}"#);
        let response = LLMResponse { tool_calls: vec![report("o1", "completed", "all green")], ..Default::default() };
        let mut agent = agent_with_deny(vec![response], dir.path(), Vec::new());
        agent.load_claude_hooks(dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "finish").await.unwrap();
        assert_eq!(
            outcome.outcome.map(|o| o.status),
            Some(goal::Status::Blocked),
            "a PreToolUse rewrite of a special tool's arguments must reach its handler, not be dropped"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn pre_tool_use_context_survives_a_deny() {
        let dir = tempfile::tempdir().unwrap();
        // A PreToolUse hook that both denies the call *and* returns
        // `additionalContext`: the context must still reach the model (it often
        // explains the risk), even though the call itself is blocked.
        let command = "cat >/dev/null; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"not allowed\",\"additionalContext\":\"ctx-explains-why\"}}'";
        let settings = json!({
            "hooks": { "PreToolUse": [ { "matcher": "echo", "hooks": [ { "type": "command", "command": command } ] } ] }
        });
        let claude = dir.path().join(".claude");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(claude.join("settings.json"), serde_json::to_string(&settings).unwrap()).unwrap();

        let (mut agent, _seen) = agent(vec![tool_call("e1"), text("done")], dir.path());
        agent.load_claude_hooks(dir.path());
        agent.new_session().unwrap();
        agent.send_message("go").await.unwrap();
        let conversation = agent.conversation();
        let result = conversation.iter().find(|m| m.role == Role::Tool).expect("a tool result");
        assert!(result.is_error, "the denied call is blocked: {}", result.content);
        assert!(result.content.contains("not allowed"), "the deny reason surfaces: {}", result.content);
        assert!(
            result.content.contains("ctx-explains-why"),
            "the deny hook's additionalContext still reaches the model: {}",
            result.content
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_runs_session_start_hooks_for_the_continued_turn() {
        let dir = tempfile::tempdir().unwrap();
        // A `resume`-matched SessionStart hook. A restored session that
        // redelivers a pending input must still run its once-per-session
        // SessionStart hooks before the model continues — without re-validating
        // the already-accepted prompt via UserPromptSubmit.
        let settings = json!({
            "hooks": {
                "SessionStart": [ { "matcher": "resume", "hooks": [ { "type": "command", "command": "echo resumed-context" } ] } ],
                "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "echo should-not-run-on-resume" } ] } ]
            }
        });
        let claude = dir.path().join(".claude");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(claude.join("settings.json"), serde_json::to_string(&settings).unwrap()).unwrap();

        // A crashed session whose turn never finished: the input was accepted
        // but no answer was recorded, so the resume path continues the turn.
        crashed_session(dir.path(), "resume-start", vec![Record::Message(Box::new(Message::user("run it")))]);
        let (mut agent, seen) = agent(vec![text("continued")], dir.path());
        agent.load_claude_hooks(dir.path());
        agent.load_session("resume-start").unwrap();
        let response = agent.send_input(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(response, "continued");
        let request = &seen.lock().unwrap()[0];
        let resumed = request.iter().any(|m| m.role == Role::User && m.content.contains("resumed-context"));
        assert!(resumed, "SessionStart resume context is delivered on the continued turn: {request:?}");
        let revalidated = request.iter().any(|m| m.content.contains("should-not-run-on-resume"));
        assert!(!revalidated, "UserPromptSubmit is not re-run for an already-accepted prompt: {request:?}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn session_start_context_survives_a_rejected_first_prompt() {
        let dir = tempfile::tempdir().unwrap();
        // SessionStart emits context once per session. UserPromptSubmit rejects
        // the first prompt (the one containing "reject-me") and accepts the
        // next. The SessionStart context collected on the rejected attempt must
        // NOT be discarded with the rejection — `claude_session_started` is
        // already true, so without caching it would never be delivered. It must
        // reach the model with the first *accepted* prompt, and SessionStart
        // must not re-run (it may have side effects).
        let settings = json!({
            "hooks": {
                "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo startup-context; echo ran >> session_start_count" } ] } ],
                "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "grep -q reject-me && exit 2 || exit 0" } ] } ]
            }
        });
        let claude = dir.path().join(".claude");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(claude.join("settings.json"), serde_json::to_string(&settings).unwrap()).unwrap();

        let (mut agent, seen) = agent(vec![text("accepted answer")], dir.path());
        agent.load_claude_hooks(dir.path());

        // First prompt is rejected by UserPromptSubmit: no model call is made.
        let rejected = agent.send_message("reject-me").await.unwrap();
        assert!(rejected.contains("blocked") || !rejected.is_empty(), "the rejection is surfaced: {rejected}");
        assert!(seen.lock().unwrap().is_empty(), "a rejected prompt never reaches the model");

        // Second prompt is accepted; the model must see the SessionStart context
        // even though SessionStart ran on the (rejected) first attempt.
        let response = agent.send_message("hello").await.unwrap();
        assert_eq!(response, "accepted answer");
        let request = &seen.lock().unwrap()[0];
        let delivered = request.iter().any(|m| m.role == Role::User && m.content.contains("startup-context"));
        assert!(delivered, "SessionStart context is delivered with the first accepted prompt: {request:?}");
        // SessionStart ran exactly once (on the first attempt), not re-run.
        let count = std::fs::read_to_string(dir.path().join("session_start_count")).unwrap_or_default();
        assert_eq!(
            count.matches("ran").count(),
            1,
            "SessionStart runs once per session, not re-run on the accepted prompt"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_finishes_a_reported_outcome_without_calling_the_model() {
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "lost-outcome",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(Message::assistant_with_tools(
                    "",
                    vec![report("o1", "blocked", "need a token")],
                ))),
                Record::Message(Box::new(Message::tool_result("o1", goal::TOOL_NAME, "Recorded outcome: blocked."))),
            ],
        );
        let (mut agent, seen) = agent(vec![], dir.path());
        agent.load_session("lost-outcome").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.response, "Blocked: need a token");
        assert_eq!(outcome.outcome.map(|o| o.status), Some(goal::Status::Blocked));
        assert!(seen.lock().unwrap().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn stale_plan_gets_a_reminder_in_a_tool_result() {
        let dir = tempfile::tempdir().unwrap();
        let mut responses = vec![
            call("p1", "plan_add", json!({"items": ["Find it", "Fix it"]})),
            call("p2", "plan_update", json!({"id": 1, "status": "in_progress"})),
        ];
        responses.extend((0..reminders::PLAN_STALE_AFTER).map(|i| tool_call(&format!("c{i}"))));
        responses.push(text("done"));
        let (mut agent, seen) = agent(responses, dir.path());
        agent.send_message("go").await.unwrap();
        let last = seen.lock().unwrap().last().unwrap().clone();
        let results: Vec<&Message> = last.iter().filter(|m| m.name.as_deref() == Some("echo")).collect();
        assert!(results[..results.len() - 1].iter().all(|m| m.content == "pong"));
        let reminded = &results.last().unwrap().content;
        assert!(
            reminded.starts_with("pong\n\n<system-reminder>\n")
                && reminded.contains("#1 \"Find it\" is still in progress"),
            "{reminded}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn long_tool_output_is_cut_and_kept_on_disk() {
        let dir = tempfile::tempdir().unwrap();
        let long = "x".repeat(100);
        let (mut agent, seen) = agent(vec![call("big1", "echo", json!({"text": long})), text("ok")], dir.path());
        agent.set_tool_output_limit(10);
        agent.send_message("go").await.unwrap();
        let result = seen.lock().unwrap()[1].last().unwrap().content.clone();
        let path = output::spill_dir().join("tool-big1-echo.txt");
        assert!(result.contains(&format!("complete output in {}", path.display())), "{result}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), long);
        let _ = std::fs::remove_file(path);
    }

    fn record_events(agent: &mut Agent) -> Arc<Mutex<Vec<Value>>> {
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        agent.set_event_sink(Box::new(move |session_id, event| {
            if let Some(mut update) = crate::acp::update_for(event) {
                update["sessionId"] = json!(session_id);
                sink.lock().unwrap().push(update);
            }
        }));
        events
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn emits_acp_updates_for_messages_and_tools() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![tool_call("c1"), text("done")], dir.path());
        agent.tools().register(
            ToolDefinition::new("broken", "fails", json!({"type": "object"})),
            Box::new(|_| Err(anyhow::anyhow!("boom"))),
        );
        let session_id = agent.new_session().unwrap();
        let events = record_events(&mut agent);
        agent.send_message("ping").await.unwrap();

        let events = events.lock().unwrap().clone();
        let kinds: Vec<&str> = events.iter().map(|e| e["sessionUpdate"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["tool_call", "tool_call_update", "agent_message_chunk"]);
        assert_eq!(events[0]["toolCallId"], "c1");
        assert_eq!(events[0]["title"], "echo");
        assert_eq!(events[0]["rawInput"], json!({"text": "pong"}));
        assert_eq!(events[1]["status"], "completed");
        assert_eq!(events[1]["rawOutput"], "pong");
        assert_eq!(events[2]["content"]["text"], "done");
        assert!(events[2]["messageId"].as_str().is_some_and(|id| !id.is_empty()));
        assert!(events.iter().all(|e| e["sessionId"] == json!(session_id)));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn failed_tool_reports_failed_status_and_replay_covers_history() {
        let dir = tempfile::tempdir().unwrap();
        let broken = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "b1".into(),
                name: "broken".into(),
                arguments: json!({}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let (mut agent, _) = agent(vec![broken, text("sorry")], dir.path());
        agent.tools().register(
            ToolDefinition::new("broken", "fails", json!({"type": "object"})),
            Box::new(|_| Err(anyhow::anyhow!("boom"))),
        );
        let session_id = agent.new_session().unwrap();
        let live = record_events(&mut agent);
        agent.send_message("try").await.unwrap();
        assert_eq!(live.lock().unwrap()[1]["status"], "failed");

        let (mut resumed, _) = self::agent(vec![], dir.path());
        resumed.load_session(&session_id).unwrap();
        let replayed = record_events(&mut resumed);
        resumed.replay_history();
        let replayed = replayed.lock().unwrap().clone();
        let kinds: Vec<&str> = replayed.iter().map(|e| e["sessionUpdate"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["user_message_chunk", "tool_call", "tool_call_update", "agent_message_chunk"]);
        assert_eq!(replayed[0]["content"]["text"], "try");
        assert_eq!(replayed[2]["toolCallId"], "b1");
        assert_eq!(replayed[2]["status"], "failed", "replay matches the live status");
    }

    type OnCall = Box<dyn Fn(usize, &TurnControl) + Send + Sync>;

    /// Scripted client that can act on the turn control during a given call.
    struct Interfering {
        responses: Mutex<Vec<LLMResponse>>,
        seen: Seen,
        control: Mutex<Option<TurnControl>>,
        on_call: OnCall,
        hang_on: Option<usize>,
    }

    #[async_trait]
    impl LLMClient for Interfering {
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            let call = {
                let mut seen = self.seen.lock().unwrap();
                seen.push(request.messages.to_vec());
                seen.len()
            };
            let control = self.control.lock().unwrap().clone().unwrap();
            (self.on_call)(call, &control);
            if self.hang_on == Some(call) {
                std::future::pending::<()>().await;
            }
            Ok(self.responses.lock().unwrap().remove(0))
        }
        fn model_name(&self) -> &str {
            "interfering"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
    }

    fn interfering(
        responses: Vec<LLMResponse>,
        dir: &std::path::Path,
        on_call: impl Fn(usize, &TurnControl) + Send + Sync + 'static,
        hang_on: Option<usize>,
    ) -> (Agent, Seen) {
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        let client = Interfering {
            responses: Mutex::new(responses),
            seen: seen.clone(),
            control: Mutex::new(None),
            on_call: Box::new(on_call),
            hang_on,
        };
        let slot = Arc::new(client);
        let config = Config { session_dir: Some(dir.to_path_buf()), ..Config::default() };
        struct Shared(Arc<Interfering>);
        #[async_trait]
        impl LLMClient for Shared {
            async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
                self.0.chat(request).await
            }
            fn model_name(&self) -> &str {
                "interfering"
            }
            fn provider_name(&self) -> &str {
                "test"
            }
        }
        let agent = Agent::new(Box::new(Shared(slot.clone())), config);
        *slot.control.lock().unwrap() = Some(agent.control());
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        (agent, seen)
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn steer_during_tool_call_joins_next_model_call() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = interfering(
            vec![tool_call("c1"), text("adjusted")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    control.steer("use the other file", Some(json!(7)));
                }
            },
            None,
        );
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "do it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "adjusted");
        let second = seen.lock().unwrap()[1].clone();
        let tail: Vec<(Role, &str)> =
            second.iter().rev().take(2).map(|m| (m.role.clone(), m.content.as_str())).collect();
        assert_eq!(tail, [(Role::User, "use the other file"), (Role::Tool, "pong")]);
        let absorbed = agent.control().take_absorbed();
        assert_eq!(absorbed.len(), 1);
        assert_eq!(absorbed[0].tag, Some(json!(7)));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn steer_during_final_answer_extends_the_turn() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = interfering(
            vec![text("first draft"), text("revised")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    control.steer("make it shorter", None);
                }
            },
            None,
        );
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "write").await.unwrap();
        assert_eq!(outcome.response, "revised");
        assert_eq!(seen.lock().unwrap().len(), 2);
        let conversation = agent.conversation();
        let n = conversation.len();
        assert_eq!(conversation[n - 3].content, "first draft");
        assert_eq!(conversation[n - 2].content, "make it shorter");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn new_generation_clears_stale_output_rate() {
        let dir = tempfile::tempdir().unwrap();
        // A shared slot lets the on_call hook reach the agent's live stats.
        let stats_slot: Arc<Mutex<Option<SharedStats>>> = Arc::new(Mutex::new(None));
        let observed: Arc<Mutex<Vec<Option<f64>>>> = Arc::new(Mutex::new(Vec::new()));
        let slot = stats_slot.clone();
        let seen_rates = observed.clone();
        let (mut agent, _) = interfering(
            vec![text("first draft"), text("revised")],
            dir.path(),
            move |call, control| {
                let stats = slot.lock().unwrap().clone().unwrap();
                if call == 1 {
                    // Simulate a rate left over from this response, then queue a
                    // steer so the turn continues into a second generation
                    // without transitioning through `Activity::Idle`.
                    stats.lock().unwrap().tokens_per_sec = Some(123.0);
                    control.steer("make it shorter", None);
                } else {
                    // The second generation must start with a cleared rate,
                    // even though the activity never left `Thinking`.
                    seen_rates.lock().unwrap().push(stats.lock().unwrap().tokens_per_sec);
                }
            },
            None,
        );
        *stats_slot.lock().unwrap() = Some(agent.context_stats());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "write").await.unwrap();
        assert_eq!(outcome.response, "revised");
        assert_eq!(observed.lock().unwrap().as_slice(), [None], "stale rate cleared at generation start");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn cancel_during_model_call_stops_the_turn() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = interfering(
            vec![],
            dir.path(),
            |_, control| {
                let control = control.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    control.cancel();
                });
            },
            Some(1),
        );
        let id = agent.new_session().unwrap();
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(5), agent.run_turn(Some("in-1"), "hang"))
            .await
            .expect("cancel ends the turn")
            .unwrap();
        assert_eq!(outcome.stop_reason, StopReason::Cancelled);
        assert_eq!(outcome.response, CANCELLED_RESPONSE);
        // The turn is closed: redelivery returns the recorded result.
        let (mut resumed, _) = agent_for_resume(dir.path());
        resumed.load_session(&id).unwrap();
        assert_eq!(resumed.send_input(Some("in-1"), "hang").await.unwrap(), CANCELLED_RESPONSE);
    }

    fn agent_for_resume(dir: &std::path::Path) -> (Agent, Seen) {
        agent(vec![], dir)
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn cancel_kills_running_bash_and_skips_remaining_calls() {
        let dir = tempfile::tempdir().unwrap();
        let calls = LLMResponse {
            tool_calls: vec![
                ToolCall {
                    id: "b1".into(),
                    name: "bash".into(),
                    arguments: json!({"command": "sleep 30"}),
                    item_id: None,
                    malformed_arguments: None,
                },
                ToolCall {
                    id: "e1".into(),
                    name: "echo".into(),
                    arguments: json!({"text": "never"}),
                    item_id: None,
                    malformed_arguments: None,
                },
            ],
            ..Default::default()
        };
        let (mut agent, seen) = interfering(vec![calls], dir.path(), |_, _| {}, None);
        let bash_config = crate::bash::BashConfig { cancel: Some(agent.control().cancel_flag()), ..Default::default() };
        agent.tools().register(
            crate::bash::definition(),
            Box::new(move |args| Ok(json!(crate::bash::run(&bash_config, &args)))),
        );
        agent.new_session().unwrap();
        let control = agent.control();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            control.cancel();
        });
        let started = std::time::Instant::now();
        let outcome = agent.run_turn(None, "sleep").await.unwrap();
        assert!(started.elapsed() < std::time::Duration::from_secs(10), "bash was killed");
        assert_eq!(outcome.stop_reason, StopReason::Cancelled);
        assert_eq!(seen.lock().unwrap().len(), 1, "no model call after cancel");
        let conversation = agent.conversation();
        let n = conversation.len();
        assert!(conversation[n - 2].content.contains("cancelled"), "{}", conversation[n - 2].content);
        assert_eq!(conversation[n - 1].content, CANCELLED_TOOL_RESULT);
        assert!(conversation[n - 1].is_error);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn steer_on_last_iteration_keeps_the_final_answer() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) =
            interfering(vec![text("done")], dir.path(), |_, control| control.steer("late", None), None);
        agent.config.max_iterations = 1;
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "done");
        assert_eq!(agent.control().take_pending().len(), 1, "late steer left for the caller to requeue");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn plan_mode_gates_mutating_tools() {
        let dir = tempfile::tempdir().unwrap();
        // The model tries to call `bash` (mutating), then answers with text.
        let calls = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "b1".into(),
                name: "bash".into(),
                arguments: json!({"command": "rm -rf /"}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let (mut agent, _) = agent(vec![calls, text("cannot do that in plan mode")], dir.path());
        agent.new_session().unwrap();
        agent.set_mode(crate::mode::AgentMode::Plan);
        let outcome = agent.run_turn(None, "delete everything").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        let conversation = agent.conversation();
        let tool_result = conversation.iter().find(|m| m.role == Role::Tool).expect("a tool result was recorded");
        assert!(tool_result.is_error, "gated call is an error");
        assert!(tool_result.content.contains("disabled in plan mode"), "{}", tool_result.content);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn plan_mode_keeps_read_only_tools() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![tool_call("e1"), text("done")], dir.path());
        agent.new_session().unwrap();
        agent.set_mode(crate::mode::AgentMode::Plan);
        let outcome = agent.run_turn(None, "echo something").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        let conversation = agent.conversation();
        let tool_result = conversation.iter().find(|m| m.role == Role::Tool).expect("echo ran");
        assert!(!tool_result.is_error, "echo is read-only and allowed in plan mode");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn new_session_and_load_reset_the_mode() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("hi")], dir.path());
        let id = agent.new_session().unwrap();
        agent.set_mode(crate::mode::AgentMode::Plan);
        assert_eq!(agent.mode(), crate::mode::AgentMode::Plan);
        // A fresh session starts back in the default mode.
        agent.new_session().unwrap();
        assert_eq!(agent.mode(), crate::mode::AgentMode::Normal, "new_session resets the mode");
        // So does loading an existing one.
        agent.set_mode(crate::mode::AgentMode::Auto);
        agent.load_session(&id).unwrap();
        assert_eq!(agent.mode(), crate::mode::AgentMode::Normal, "load_session resets the mode");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn auto_mode_disables_the_turn_cap() {
        let dir = tempfile::tempdir().unwrap();
        // More tool calls than the cap; auto mode should run them all.
        let (mut agent, seen) =
            agent(vec![tool_call("e1"), tool_call("e2"), tool_call("e3"), text("done")], dir.path());
        agent.config.max_iterations = 2;
        agent.new_session().unwrap();
        agent.set_mode(crate::mode::AgentMode::Auto);
        let outcome = agent.run_turn(None, "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn, "auto mode runs past the cap");
        assert_eq!(outcome.response, "done");
        assert_eq!(seen.lock().unwrap().len(), 4, "all four model calls ran");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn zero_turn_cap_is_unbounded() {
        let dir = tempfile::tempdir().unwrap();
        // More tool calls than any finite cap; a cap of 0 should run them all.
        let (mut agent, seen) =
            agent(vec![tool_call("e1"), tool_call("e2"), tool_call("e3"), text("done")], dir.path());
        agent.config.max_iterations = 0;
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn, "a cap of 0 is unbounded");
        assert_eq!(outcome.response, "done");
        assert_eq!(seen.lock().unwrap().len(), 4, "all four model calls ran");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn normal_mode_cap_stops_headless() {
        let dir = tempfile::tempdir().unwrap();
        // Non-interactive (no one answers the cap prompt): the cap stops the turn.
        let (mut agent, seen) = agent(vec![tool_call("e1"), tool_call("e2"), tool_call("e3")], dir.path());
        agent.config.max_iterations = 2;
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTurnRequests);
        assert_eq!(seen.lock().unwrap().len(), 2, "stopped at the cap");
    }
}
