use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::Utc;
use serde_json::{Value, json};

use crate::config::{CompactionMode, Config};
use crate::context::{self, Activity, SharedStats};
use crate::goal::{self, Outcome};
use crate::history;
use crate::hooks::{HookContext, HookEvent, HookRegistry};
use crate::instructions::ProjectInstructions;
use crate::llm::{ChatRequest, DetectedWindow, LLMClient, LLMResponse, Message, Role, StreamEvent, ToolCall};
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
    /// A `/model <spec>` typed mid-turn: the agent applies it just before its
    /// next model call (see `Agent::apply_model_request`).
    model: Mutex<Option<String>>,
    /// The plan as last published by the agent (every `AgentEvent::Plan`),
    /// so `/plan` can show it while a turn holds the agent.
    plan: Mutex<crate::plan::Plan>,
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
                model: Mutex::new(None),
                plan: Mutex::new(crate::plan::Plan::default()),
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

    /// Ask the running turn to switch to `spec` (`provider/model`) at its next
    /// model call; a later request replaces an earlier unapplied one.
    pub fn set_model(&self, spec: &str) {
        *self.inner.model.lock().unwrap() = Some(spec.to_string());
    }

    /// The `/model <spec>` requested mid-turn, if any; the agent takes it once
    /// as it applies the switch.
    pub fn take_model_request(&self) -> Option<String> {
        self.inner.model.lock().unwrap().take()
    }

    /// Whether a `/model <spec>` request is currently queued, without consuming
    /// it. Used to detect a newer request that arrived while an earlier one was
    /// still being applied, so a now-stale built client is discarded instead of
    /// installed (see `Agent::apply_model_request`).
    pub fn has_model_request(&self) -> bool {
        self.inner.model.lock().unwrap().is_some()
    }

    /// Advance to the next mode in the Shift+Tab cycle; returns it.
    pub fn cycle_mode(&self) -> crate::mode::AgentMode {
        let mut mode = self.inner.mode.lock().unwrap();
        *mode = mode.next();
        *mode
    }

    /// The plan as the agent last published it.
    pub fn plan(&self) -> crate::plan::Plan {
        self.inner.plan.lock().unwrap().clone()
    }

    pub fn publish_plan(&self, plan: &crate::plan::Plan) {
        *self.inner.plan.lock().unwrap() = plan.clone();
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
    /// The agent switched models mid-turn (a `/model <spec>` typed during the
    /// turn, applied at the next model call). Both specs are in canonical
    /// `provider/model` form, ready for the UI to record in the recents MRU;
    /// `previous` is the model switched away from.
    ModelSwitched {
        spec: &'a str,
        previous: &'a str,
    },
    /// A `/model <spec>` typed mid-turn could not be applied: the spec did not
    /// build (unknown provider, missing model/endpoint, or a failing api-key
    /// command). The turn keeps running on the current model; the request is
    /// dropped rather than re-queued, so it cannot silently leak into later
    /// turns. The UI prints `error` as a note.
    ModelSwitchFailed {
        spec: &'a str,
        error: &'a str,
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

/// Receives events with the active session ID.
pub type EventSink = std::sync::Arc<dyn Fn(Option<&str>, &AgentEvent) + Send + Sync>;

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
    message_counter: u64,
    control: TurnControl,
    stats: SharedStats,
    /// Conversation length and exact token count from the last response's
    /// reported usage, used to anchor the context estimate.
    calibration: Option<(usize, usize)>,
    /// Window learned from a context-overflow error (until the model changes).
    learned_window: Option<usize>,
    /// Window reported by the endpoint (see `detect_context_window`). Shared
    /// and locked because a mid-turn `/model` switch probes in a background
    /// task (see `detect_context_window_for_switch`), which publishes here
    /// when it lands.
    detected_window: std::sync::Arc<std::sync::Mutex<Option<DetectedWindow>>>,
    /// Monotonic switch counter, bumped on every model change (see
    /// `detect_context_window_for_switch`). A background window probe captures
    /// the generation it was spawned under and discards its result if a later
    /// switch has since bumped it, so a slow probe for a superseded model can
    /// never overwrite the current model's detected window.
    detect_generation: std::sync::Arc<std::sync::atomic::AtomicU64>,
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
    /// Rendezvous for the `question` tool: the handler blocks here until the
    /// turn loop answers.
    questions: crate::question::QuestionBroker,
    /// Where truncated tool output is kept whole (per session when persisted);
    /// shared with the bash tool.
    spill_dir: Arc<RwLock<std::path::PathBuf>>,
    /// History-tool calls in the current turn.
    turn_history_calls: u32,
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
}

/// Upper bound on context-window detection at startup and model switches.
const DETECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

impl Agent {
    pub fn new(client: Box<dyn LLMClient>, config: Config) -> Self {
        let conversation = vec![Message { timestamp: Some(session::now()), ..Message::system(&config.system_prompt) }];
        let policy = Policy::new(&config.permissions, &config.sandbox);
        Self {
            policy,
            client,
            tools: ToolRegistry::new(),
            hooks: HookRegistry::new(),
            config,
            conversation,
            session: None,
            session_id: None,
            completed_inputs: HashMap::new(),
            completed_outcomes: HashMap::new(),
            pending_input: None,
            input_counter: 0,
            event_sink: None,
            message_counter: 0,
            control: TurnControl::default(),
            stats: SharedStats::default(),
            calibration: None,
            learned_window: None,
            detected_window: std::sync::Arc::new(std::sync::Mutex::new(None)),
            detect_generation: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
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
            history_available: false,
            history_hint_pending: false,
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

    fn client_for(config: &Config, spec: &str) -> Result<Box<dyn LLMClient>> {
        Self::client_for_cancellable(config, spec, None)
    }

    /// Like [`Agent::client_for`], but a running `api_key_command` honours
    /// `cancel`: the child process is killed and the build fails fast when the
    /// flag flips, so a mid-turn `/model` switch whose key command hangs cannot
    /// wedge the turn.
    fn client_for_cancellable(
        config: &Config,
        spec: &str,
        cancel: Option<&Arc<AtomicBool>>,
    ) -> Result<Box<dyn LLMClient>> {
        let (providers, default_provider) = config.effective_providers();
        providers::build_client_cancellable(spec, &providers, &default_provider, cancel)
    }

    pub fn tools(&self) -> &ToolRegistry {
        &self.tools
    }

    pub fn hooks(&self) -> &HookRegistry {
        &self.hooks
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

    /// Switch to another `provider/model`, keeping the conversation.
    pub async fn set_model(&mut self, spec: &str) -> Result<()> {
        // `client_for` → `build_client` → `resolve` can run an `api_key_command`
        // as a child process. `set_model` is awaited from the async TUI/ACP
        // command loops (between turns), so running that inline freezes the
        // runtime for the command's full duration, stalling the UI/event loop.
        // Offload the blocking build to the blocking thread pool and await it so
        // the runtime stays responsive while the key command runs — the same
        // pattern `apply_model_request` uses for the mid-turn switch.
        let config_for_build = self.config.clone();
        let spec_for_build = spec.to_string();
        self.client = tokio::task::spawn_blocking(move || {
            Self::client_for(&config_for_build, &spec_for_build)
        })
        .await
        .map_err(|join| anyhow::anyhow!("building client for {spec:?} panicked: {join}"))??;
        self.config.model = spec.to_string();
        // A direct switch supersedes any still-unapplied mid-turn `/model`
        // request: one queued during the final in-flight call of a prior turn
        // outlives that turn, and without clearing it the first call of the
        // next turn would consume the stale request and silently switch away
        // from the model this direct switch just selected.
        self.control.take_model_request();
        self.calibration = None;
        self.learned_window = None;
        *self.detected_window.lock().unwrap() = None;
        self.compact_floor = 0;
        self.detect_context_window().await;
        Ok(())
    }

    /// Apply a `/model <spec>` typed mid-turn (queued on the `TurnControl`),
    /// so the switch takes effect at the next model call. Switching in the
    /// middle of a tool loop is fine: the conversation history is
    /// provider-neutral. The spec is validated at queue time (see
    /// `providers::validate_spec`), so by the time it reaches here it almost
    /// always builds; if the client still fails to build (e.g. an api-key
    /// command that fails only now), the request is **dropped** — not
    /// re-queued — and the error is surfaced via `AgentEvent::ModelSwitchFailed`
    /// so the user is told and the dead request cannot leak into later turns.
    /// A successful switch emits `AgentEvent::ModelSwitched` so the UI can
    /// record it in the recents MRU while the turn holds the agent.
    ///
    /// Two races are handled: (1) if a newer `/model` request is queued while
    /// an earlier one is still building, the stale client is discarded and the
    /// newest spec is built instead, so the next model call never lands on a
    /// superseded spec; (2) if the turn is cancelled while a key command is
    /// building (or hanging), the build is killed and the switch is abandoned
    /// rather than blocking the turn.
    async fn apply_model_request(&mut self) {
        // Loop so that a newer `/model` request arriving while an earlier one
        // is being built is honoured: each pass builds exactly one spec, then
        // re-checks the slot and rebuilds the newest if it was superseded.
        loop {
            // Don't start (or keep) switching for a turn the user cancelled;
            // the pending request stays queued for the next turn's first call.
            if self.control.is_cancelled() {
                return;
            }
            let Some(spec) = self.control.take_model_request() else { return };
            // Record the model actually in use (resolved by the live client)
            // before switching, so a provider-default edit made in the same
            // session cannot rewrite which model we record leaving. Both specs
            // go out canonical, so the recents MRU never re-parses them.
            let (user, default_provider) = self.config.effective_providers();
            let all = providers::effective_providers(&user);
            let previous = crate::recents::canonical(
                &format!("{}/{}", self.client.provider_name(), self.client.model_name()),
                &all,
                &default_provider,
            );
            // `client_for` → `build_client` → `resolve` can run an
            // `api_key_command` as a child process. `apply_model_request` is
            // awaited from the async `run_turn` loop, so running that inline
            // freezes the worker for the command's full duration (or
            // indefinitely if it hangs), stalling streaming and cancel/other
            // input. Offload the blocking build to the blocking thread pool and
            // await it, so the runtime stays responsive while the key command
            // runs. The build also honours the turn's cancel flag: on cancel it
            // kills the key-command child and fails fast, and we race the await
            // against `control.cancelled()` below so the turn returns promptly
            // instead of blocking on a hung command.
            let config_for_build = self.config.clone();
            let spec_for_build = spec.clone();
            let cancel = self.control.cancel_flag();
            let control = self.control.clone();
            let handle = tokio::task::spawn_blocking(move || {
                Self::client_for_cancellable(&config_for_build, &spec_for_build, Some(&cancel))
            });
            let built = tokio::select! {
                joined = handle => match joined {
                    Ok(result) => result,
                    Err(join) => Err(anyhow::anyhow!("building client for {spec:?} panicked: {join}")),
                },
                _ = control.cancelled() => {
                    // Cancelled mid-build: the blocking build observes the same
                    // cancel flag, kills its key-command child, and unblocks, so
                    // stop waiting and abort the switch rather than install a
                    // client for a turn the user just cancelled. The request has
                    // been consumed, so it will not fire into the next turn.
                    return;
                }
            };
            // A newer `/model` request can arrive while the build above is
            // awaited. The spec we just built is then stale: installing it would
            // point the next model call at the superseded spec even though the
            // newer command was acked for that call. Discard this client
            // (success or failure) and loop to build the newest queued spec.
            if self.control.has_model_request() {
                continue;
            }
            // Cancellation can also land as the build finishes (the `select!`
            // may pick the completed build over `cancelled()`); don't install a
            // client for a turn the user just cancelled.
            if self.control.is_cancelled() {
                return;
            }
            match built {
                Ok(client) => {
                    self.client = client;
                    self.config.model = spec.clone();
                    self.calibration = None;
                    self.learned_window = None;
                    *self.detected_window.lock().unwrap() = None;
                    self.compact_floor = 0;
                    self.detect_context_window_for_switch();
                    let spec = crate::recents::canonical(&spec, &all, &default_provider);
                    self.emit(AgentEvent::ModelSwitched { spec: &spec, previous: &previous });
                }
                Err(e) => {
                    // The spec passed queue-time validation but the client still
                    // failed to build. Drop the request (do not re-queue it,
                    // which would retry the same failure every step and leak
                    // into the next turn) and tell the user; the turn stays on
                    // the current model.
                    let error = e.to_string();
                    self.emit(AgentEvent::ModelSwitchFailed { spec: &spec, error: &error });
                }
            }
            return;
        }
    }

    /// Ask the endpoint for the model's context window, unless config sets it.
    pub async fn detect_context_window(&mut self) {
        // Bump the generation so any in-flight background probe from an earlier
        // mid-turn switch (see `detect_context_window_for_switch`) is discarded
        // and cannot overwrite the window this blocking detect establishes.
        self.detect_generation.fetch_add(1, Ordering::SeqCst);
        *self.detected_window.lock().unwrap() = None;
        if self.configured_window().is_none() {
            let probe = self.client.detect_context_window();
            *self.detected_window.lock().unwrap() = tokio::time::timeout(DETECT_TIMEOUT, probe).await.ok().flatten();
        }
        self.refresh_stats();
    }

    /// Window detection after a mid-turn `/model` switch (see
    /// `apply_model_request`). Unlike [`Agent::detect_context_window`] this
    /// never blocks the agent loop on the probe: when the new spec carries a
    /// configured window (`context_window` in config or on the provider entry)
    /// that value is authoritative, so the HTTP probe is skipped outright;
    /// otherwise the probe runs in the background and the stats refresh it
    /// triggers lands whenever the endpoint answers. Either way the new
    /// model's fallback stats are published immediately so the status line and
    /// `/context` reflect the switch at once rather than showing the previous
    /// model's provider/window until (or unless) the probe lands. The next
    /// model call goes out immediately, with the model-name fallback window
    /// until the probe (if any) reports.
    fn detect_context_window_for_switch(&mut self) {
        // Bump the generation *before* clearing the slot so any in-flight probe
        // for the previous model is already invalidated: its `finish_detect`
        // re-reads the generation under the slot lock and discards a stale
        // result rather than clobbering this model's window.
        let generation = self.detect_generation.fetch_add(1, Ordering::SeqCst) + 1;
        *self.detected_window.lock().unwrap() = None;
        // Publish the new model's fallback stats (provider/model name + the
        // model-name or default window) right away, so a slow or `None` probe
        // cannot leave the UI on the previous model's window.
        self.refresh_stats();
        if self.configured_window().is_some() {
            return;
        }
        let probe = self.client.clone_boxed();
        let slot = self.detected_window.clone();
        let sink = self.event_sink.clone();
        let stats = self.stats.clone();
        let current = self.detect_generation.clone();
        tokio::spawn(async move {
            let detected = tokio::time::timeout(DETECT_TIMEOUT, probe.detect_context_window()).await.ok().flatten();
            Self::finish_detect(detected, generation, current, slot, sink, stats);
        });
    }

    /// Publish a finished background probe's result: store the window and
    /// refresh the stats, emitting `AgentEvent::Context` through the sink so
    /// the UI picks the window up whenever the probe lands. A failed or timed
    /// out probe publishes nothing — the model-name fallback window stays.
    /// A result whose `generation` no longer matches `current` is discarded:
    /// a later model switch has superseded this probe, so its window must not
    /// overwrite the newer model's. The stats update is also conservative: a
    /// fresher source (a configured window a later switch picked) is never
    /// overwritten. A learned window (from a context overflow) is normally
    /// fresher too, but a probe reporting a *stricter* (smaller) window is
    /// allowed to replace it: the slot already stores the detected window, so
    /// `context_window_with_source()` would otherwise start using the smaller
    /// value while `/context` and the status line kept reporting the larger
    /// learned one — leaving the two permanently inconsistent.
    fn finish_detect(
        detected: Option<DetectedWindow>,
        generation: u64,
        current: std::sync::Arc<std::sync::atomic::AtomicU64>,
        slot: std::sync::Arc<std::sync::Mutex<Option<DetectedWindow>>>,
        sink: Option<EventSink>,
        stats: SharedStats,
    ) {
        let Some(detected) = detected else { return };
        let (window, source) = (detected.tokens, format!("reported by the endpoint ({})", detected.source));
        {
            // Check the generation under the slot lock so a switch racing this
            // completion either bumps it before we read (we discard) or clears
            // the slot after we write (it then refreshes to its own fallback).
            let mut slot = slot.lock().unwrap();
            if current.load(Ordering::SeqCst) != generation {
                return;
            }
            *slot = Some(detected);
        }
        {
            let mut stats = stats.lock().unwrap();
            // Re-check: a switch may have superseded us between the two locks.
            if current.load(Ordering::SeqCst) != generation {
                return;
            }
            if stats.window_source.starts_with("reported by the endpoint")
                || stats.window_source == "known for the model name"
                || stats.window_source == "default"
                // A learned window is fresher, but a probe that reports a
                // *stricter* (smaller) limit must replace it: the slot already
                // holds the detected window, so refusing here would leave
                // `context_window_with_source()` using the smaller value while
                // `/context` and the status line keep reporting the larger
                // learned one.
                || (stats.window_source == "learned from a context-overflow error" && window < stats.window)
            {
                stats.window = window;
                stats.window_source = source;
            }
        }
        if let Some(sink) = sink {
            sink(None, &AgentEvent::Context);
        }
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

    /// The context window and where it came from, for `/context`.
    pub fn context_window_with_source(&self) -> (usize, String) {
        let (user, default_provider) = self.config.effective_providers();
        let (_, model) = providers::context_window(&self.config.model, &user, &default_provider);
        let (window, source) = if let Some((window, source)) = self.configured_window() {
            (window, source.to_string())
        } else if let Some(detected) = &*self.detected_window.lock().unwrap() {
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
        let cwd = std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_else(|_| ".".to_string());
        {
            let mut stats = self.stats.lock().unwrap();
            stats.provider = self.client.provider_name().to_string();
            stats.model = self.client.model_name().to_string();
            stats.tokens = tokens;
            stats.calibrated = calibrated;
            let (window, window_source) = self.context_window_with_source();
            stats.window = window;
            stats.window_source = window_source;
            stats.messages = self.conversation.len();
            stats.auto_compact = self.config.auto_compact.then_some(self.config.auto_compact_threshold);
            stats.smart_compact = self.config.compaction_mode == CompactionMode::Smart && self.session.is_some();
            stats.history_available = self.history_tools_enabled();
            stats.plan = (!self.plan.items.is_empty()).then(|| self.plan.progress());
            stats.cwd = cwd;
            stats.mode = self.control.mode();
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
    fn apply_mode_to_system_prompt(&mut self) {
        let Some(first) = self.conversation.first_mut().filter(|m| m.role == Role::System) else { return };
        // Strip any existing note, then add it back only in plan mode.
        let base = first.content.replace(crate::mode::PLAN_PROMPT_NOTE, "");
        first.content = match self.control.mode() {
            crate::mode::AgentMode::Plan => format!("{base}{}", crate::mode::PLAN_PROMPT_NOTE),
            _ => base,
        };
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
        if let AgentEvent::Plan { plan } = &event {
            self.control.publish_plan(plan);
        }
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
        let conversation = self.conversation.clone();
        let mut calls: HashMap<&str, &ToolCall> = HashMap::new();
        for message in &conversation {
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
                        continue;
                    };
                    let ok = !message.is_error;
                    self.emit(AgentEvent::ToolResult { call, ok, output: &message.content });
                }
            }
        }
        if !self.plan.is_empty() {
            self.emit(AgentEvent::Plan { plan: &self.plan });
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
        // Discover instructions/skills into temporaries so a staging failure
        // below leaves self.instructions/self.skills (and the live system
        // prompt they render) untouched, rather than pairing the old
        // conversation with newly discovered instructions.
        let (instructions, skills) = self.discover_project_instructions();
        let system = Message {
            timestamp: Some(session::now()),
            ..Message::system(&self.system_prompt_from(&instructions, &skills))
        };
        // Stage the new log before mutating any live state so a disk/permission
        // failure leaves the current session (conversation, id, log,
        // instructions, skills) intact instead of detaching the agent from it.
        let session = if self.config.persist_sessions {
            let mut log = SessionLog::create(&self.config.session_dir(), &id)?;
            log.append(&Record::Message(system.clone()))?;
            Some(log)
        } else {
            None
        };
        // Staging succeeded — now commit all live state.
        self.instructions = instructions;
        self.skills = skills;
        self.conversation = vec![system];
        self.completed_inputs.clear();
        self.completed_outcomes.clear();
        self.pending_input = None;
        self.plan = Plan::default();
        self.reminders = Reminders::default();
        self.session = session;
        self.session_id = Some(id.clone());
        self.set_spill_dir(&id);
        self.calibration = None;
        self.compact_floor = 0;
        self.history_available = false;
        self.history_hint_pending = false;
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
        // Each session starts in the default mode; a plan/auto selection does
        // not leak across `/restart` or a later session load.
        self.control.set_mode(crate::mode::AgentMode::default());
        self.refresh_stats();
        Ok(id)
    }

    /// Resume a persisted session.
    pub fn load_session(&mut self, id: &str) -> Result<()> {
        let (log, restored) = SessionLog::open(&self.config.session_dir(), id)?;
        self.conversation = restored.conversation;
        // Instructions are re-read so a resumed session sees the current files.
        self.load_project_instructions();
        let system = Message { timestamp: Some(session::now()), ..Message::system(&self.system_prompt()) };
        match self.conversation.first_mut() {
            Some(first) if first.role == Role::System => *first = system,
            _ => self.conversation.insert(0, system),
        }
        self.completed_inputs = restored.completed;
        self.completed_outcomes = restored.outcomes;
        self.pending_input = restored.pending_input;
        self.plan = restored.plan.unwrap_or_default();
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
        {
            // History-tool usage is per-session live state: a resumed session
            // starts fresh so `/context` and the status line report only calls
            // made after the load, not ones left over from a prior session in
            // this same agent. Mirrors `new_session`.
            let mut stats = self.stats.lock().unwrap();
            stats.history_searches = 0;
            stats.history_reads = 0;
        }
        self.repair_dangling_tool_calls()?;
        // A loaded session starts in the default mode, not whatever mode the
        // previous session left selected.
        self.control.set_mode(crate::mode::AgentMode::default());
        self.refresh_stats();
        Ok(())
    }

    /// Give every tool call without a result a synthetic error result, so the
    /// conversation is valid for providers that require paired results.
    fn repair_dangling_tool_calls(&mut self) -> Result<()> {
        let Some(index) = self.conversation.iter().rposition(|m| m.role == Role::Assistant && !m.tool_calls.is_empty())
        else {
            return Ok(());
        };
        let answered: HashSet<&str> =
            self.conversation[index + 1..].iter().filter_map(|m| m.tool_call_id.as_deref()).collect();
        let missing: Vec<Message> = self.conversation[index]
            .tool_calls
            .iter()
            .filter(|call| !answered.contains(call.id.as_str()))
            .map(|call| Message::tool_error(&call.id, &call.name, INTERRUPTED_TOOL_RESULT))
            .collect();
        for message in missing {
            self.push(message)?;
        }
        Ok(())
    }

    fn push(&mut self, mut message: Message) -> Result<()> {
        message.timestamp.get_or_insert_with(session::now);
        if let Some(log) = &mut self.session {
            let line = log.append(&Record::Message(message.clone()))?;
            message.log_line.get_or_insert(line);
        }
        self.conversation.push(message);
        Ok(())
    }

    fn replace_conversation(&mut self, messages: Vec<Message>) -> Result<()> {
        self.replace_keeping_pending(messages, None, None)
    }

    /// Replace the conversation; `pending_position` keeps the in-flight input
    /// alive with its user message at that index.
    /// `compaction` records the folded log-line range and mode.
    fn replace_keeping_pending(
        &mut self,
        mut messages: Vec<Message>,
        pending_position: Option<usize>,
        compaction: Option<(Option<(u64, u64)>, CompactionMode)>,
    ) -> Result<()> {
        let now = session::now();
        for message in &mut messages {
            message.timestamp.get_or_insert(now);
        }
        // The history tools follow the compaction: a smart summary offers them,
        // any other replacement (standard compaction or a plain rebuild) drops
        // them. Track it explicitly so message text cannot spoof the state.
        let history_available = matches!(compaction, Some((_, CompactionMode::Smart)));
        if let Some(log) = &mut self.session {
            log.append(&Record::Replace {
                messages: messages.clone(),
                pending_position,
                summarized: compaction.and_then(|(range, _)| range),
                mode: compaction.map(|(_, mode)| mode),
                // Record the resolved provider/model, not the raw user spec
                // (which can be a bare model name under a default provider), so
                // mode comparisons keep the provider dimension.
                model: compaction.map(|_| format!("{}/{}", self.client.provider_name(), self.client.model_name())),
                recorded_at: now,
            })?;
        }
        // Flip the flag only once the durable replace record is appended, so a
        // failed replacement leaves the active history state unchanged.
        self.history_available = history_available;
        self.history_hint_pending = history_available;
        self.conversation = messages;
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
        self.config.system_prompt = prompt.to_string();
        self.replace_conversation(vec![Message::system(&self.system_prompt())])
    }

    /// The configured system prompt plus any project instructions and the
    /// skill index.
    pub fn system_prompt(&self) -> String {
        self.system_prompt_from(&self.instructions, &self.skills)
    }

    /// Render the system prompt from a given instruction/skill set, so a new
    /// session can build its prompt from freshly discovered temporaries before
    /// committing them to `self`.
    fn system_prompt_from(&self, instructions: &Option<ProjectInstructions>, skills: &Skills) -> String {
        let extra = instructions.as_ref().map(ProjectInstructions::render).unwrap_or_default();
        format!("{}{extra}{}", self.config.system_prompt, skills.render_index())
    }

    /// Discover instruction files and skills for the current working directory,
    /// returning them without mutating `self`.
    fn discover_project_instructions(&self) -> (Option<ProjectInstructions>, Skills) {
        let enabled = self.config.project_instructions && std::env::var_os("AGENTIC_NO_PROJECT_INSTRUCTIONS").is_none();
        let cwd = std::env::current_dir().ok();
        let instructions = enabled
            .then(|| cwd.clone())
            .flatten()
            .map(|cwd| ProjectInstructions::discover(&cwd, &self.config.project_instruction_files));
        let skills_enabled = self.config.skills.enabled && std::env::var_os("NANO_CODER_NO_SKILLS").is_none();
        let skills = match cwd.filter(|_| skills_enabled) {
            Some(cwd) => Skills::discover(&cwd, &self.config.skills),
            None => Skills::default(),
        };
        (instructions, skills)
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

    /// Every registered tool plus the plan tools when enabled, with **no**
    /// mode filter applied. This is the full superset for all modes, but it
    /// still omits the history tools when they are disabled. Callers that must
    /// track a live change after capturing it (`/tools`, see
    /// [`crate::turn_commands::Snapshot`]) take
    /// [`tool_definitions_superset`](Self::tool_definitions_superset) instead —
    /// it builds on this and *also* keeps the history tools so a mid-turn
    /// availability change can be re-filtered live — and filter at render time.
    /// Use [`tool_definitions`](Self::tool_definitions) for the set the agent
    /// actually offers the model under the current mode.
    pub fn tool_definitions_all_modes(&self) -> Vec<crate::tools::ToolDefinition> {
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
        tools
    }

    /// The full tool superset for a mid-turn snapshot that filters live: like
    /// [`Self::tool_definitions_all_modes`] but *always* includes the history
    /// tools, regardless of their current availability. A smart auto-compaction
    /// can enable the history tools part-way through the same turn, so freezing
    /// their availability at snapshot capture would make a later mid-turn
    /// `/tools` omit tools the next model step actually receives. The snapshot
    /// instead re-filters them against the live `ContextStats::history_available`
    /// flag at render time, exactly as it re-filters the mode.
    pub fn tool_definitions_superset(&self) -> Vec<crate::tools::ToolDefinition> {
        let mut tools = self.tool_definitions_all_modes();
        if !self.history_tools_enabled() {
            tools.extend(history::definitions());
        }
        tools
    }

    /// Registered tools plus the plan tools when enabled, filtered to the
    /// tools the agent offers under the current mode.
    pub fn tool_definitions(&self) -> Vec<crate::tools::ToolDefinition> {
        let mut tools = self.tool_definitions_all_modes();
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
        self.apply_mode_to_system_prompt();
        self.turn_history_calls = 0;
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
            }
            None => {
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
            // A `/model <spec>` typed mid-turn applies here, so the request
            // built below goes to the new model.
            self.apply_model_request().await;

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
                // The threshold compaction below is itself a model call, so a
                // `/model` queued since the top of the iteration must apply to
                // it too — otherwise the summary is written by the model the
                // user just switched away from.
                self.apply_model_request().await;
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
            let response = loop {
                self.set_activity(Activity::Thinking);
                // Every attempt is a model call (and the overflow branch below
                // compacts with one more), so a `/model` queued while the
                // previous attempt or compaction was in flight applies here,
                // before the request is built — never after it.
                self.apply_model_request().await;
                // Rebuilt every retry iteration, not just once before the loop:
                // an overflow retry compacts (in smart mode) below, which unlocks
                // the history tools, so recomputing here lets the retried request
                // actually offer `history_search`/`history_read` for the folded
                // history instead of reusing the pre-compaction tool set.
                let tools = self.tool_definitions();
                let request = ChatRequest {
                    messages: &self.conversation,
                    tools: &tools,
                    temperature: Some(self.config.temperature),
                    max_tokens: Some(self.config.max_tokens as i64),
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
                        // Publish the just-learned window to the shared stats
                        // before the awaited compaction below: mid-turn
                        // `/context` renders exclusively from `SharedStats`, so
                        // without this refresh it keeps showing the old window
                        // and source for the whole client build and compaction.
                        self.refresh_stats();
                        eprintln!("[agent] context overflow ({message}); compacting and retrying");
                        // The overflow compaction is a model call too: apply a
                        // `/model` queued while the overflowing request was in
                        // flight before the summary goes out on the old model.
                        self.apply_model_request().await;
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
            let duration_ms = u64::try_from(request_started.elapsed().as_millis()).unwrap_or(u64::MAX);
            self.record_usage(&response, true);
            // Log-only trajectory data carried by the assistant message.
            let trajectory = |message: Message| Message {
                thinking_blocks: response.thinking_blocks.clone(),
                thinking: response.thinking.clone(),
                usage: response.usage.clone(),
                duration_ms: Some(duration_ms),
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
                // Trigger before_tool_call hook
                let ctx = HookContext::new(HookEvent::BeforeToolCall)
                    .with_data("tool_name", json!(&tool_call.name))
                    .with_data("tool_call_id", json!(&tool_call.id))
                    .with_data("arguments", tool_call.arguments.clone());
                self.hooks.trigger(&ctx);
                self.emit(AgentEvent::ToolCall { call: tool_call });
                self.set_activity(Activity::Tool(tool_call.name.clone()));

                let is_plan_tool = self.config.plan_tools && plan::is_plan_tool(&tool_call.name);
                let is_outcome_tool = self.config.outcome_tool && tool_call.name == goal::TOOL_NAME;
                let is_skill_tool = tool_call.name == skills::TOOL_NAME && !self.skills.is_empty();
                let is_history_tool = history::is_history_tool(&tool_call.name) && self.history_tools_enabled();
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
                } else if let Err(reason) = self.policy.check(&tool_call.name, &tool_call.arguments) {
                    // The policy is consulted before dispatching to any handler, so deny
                    // rules and the pre-tool check also cover plan, skill and outcome tools.
                    Err(anyhow::anyhow!(reason))
                } else if is_plan_tool {
                    self.run_plan_tool(tool_call)
                } else if is_skill_tool {
                    self.skills.load(&tool_call.arguments).map(Value::String)
                } else if is_history_tool {
                    self.run_history_tool(tool_call).map(Value::String)
                } else if is_outcome_tool {
                    Outcome::from_args(&tool_call.arguments).map(|outcome| {
                        let text = format!("Recorded outcome: {}. Your turn ends now.", outcome.status.as_str());
                        reported = Some(outcome);
                        Value::String(text)
                    })
                } else {
                    // Tool handlers are synchronous and may block (e.g. bash).
                    self.tools.execute_blocking(&tool_call.name, tool_call.arguments.clone()).await
                };
                let ok = result.is_ok();
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

                let mut result_text = match result {
                    Value::String(text) => text,
                    other => other.to_string(),
                };
                if ok
                    && matches!(tool_call.name.as_str(), "read_file" | "write_file" | "edit_file")
                    && let Some(path) = tool_call.arguments.get("path").and_then(Value::as_str)
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
                if self.config.reminders && !is_plan_tool && !is_outcome_tool {
                    for note in self.reminders.after_tool_call(&self.plan) {
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
                let message = if ok {
                    Message::tool_result(&tool_call.id, &tool_call.name, &result_text)
                } else {
                    Message::tool_error(&tool_call.id, &tool_call.name, &result_text)
                };
                self.push(message)?;
                self.emit(AgentEvent::ToolResult { call: tool_call, ok, output: &result_text });
            }
            self.refresh_stats();
            if let Some(outcome) = &reported {
                // Every call in the batch has its result; the summary is the answer.
                let response = outcome.response();
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
        tokens as f64 > window as f64 * threshold && tokens > self.compact_floor + window / 10
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

        let summary_input_chars = window.saturating_sub(context::SUMMARY_MAX_TOKENS as usize + 2_000).max(2_000) * 3;
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
            temperature: None,
            max_tokens: Some(context::SUMMARY_MAX_TOKENS.min(self.config.max_tokens as i64)),
        };
        let control = self.control.clone();
        let result = tokio::select! {
            result = self.client.chat(&request) => result,
            () = control.cancelled() => return Ok(None),
        };
        let (summary, fallback) = match result {
            Ok(response) if !response.content.trim().is_empty() => {
                self.record_usage(&response, false);
                let summary = if smart {
                    format!(
                        "{}\n{}\n\n{}",
                        context::SMART_SUMMARY_PREFIX,
                        response.content.trim(),
                        context::smart_summary_note(range)
                    )
                } else {
                    format!("{}\n{}", context::SUMMARY_PREFIX, response.content.trim())
                };
                (summary, None)
            }
            Ok(_) => (
                self.dropped_note(summarized.len(), smart.then_some(range).flatten()),
                Some("empty summary".to_string()),
            ),
            Err(e) => (self.dropped_note(summarized.len(), smart.then_some(range).flatten()), Some(format!("{e:#}"))),
        };

        let mut messages: Vec<Message> = self.conversation[..body_start].to_vec();
        let summary = if self.config.plan_tools && !self.plan.is_empty() {
            format!("{summary}\n\n{}", self.plan.context_note())
        } else {
            summary
        };
        messages.push(Message::user(&summary));
        let pending_position = match &self.pending_input {
            // The in-flight input was folded into the summary: restate it.
            Some(pending) if pending.position < split => {
                messages.push(Message::user(&pending.text));
                Some(messages.len() - 1)
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
        self.replace_keeping_pending(messages, pending_position, Some((range, mode)))?;
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
    use crate::recents;
    use crate::tools::ToolDefinition;
    use async_trait::async_trait;
    use std::sync::{Arc, Mutex};

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
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("tests never clone the scripted client")
        }
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
    }

    type Seen = Arc<Mutex<Vec<Vec<Message>>>>;

    /// `message` without its timestamp (or other timing), for comparing with a
    /// constructed one.
    fn unstamped(message: &Message) -> Message {
        Message { timestamp: None, log_line: None, duration_ms: None, ..message.clone() }
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

    fn text(content: &str) -> LLMResponse {
        LLMResponse { content: content.into(), ..Default::default() }
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
    async fn repairs_interrupted_turns_on_resume() {
        let dir = tempfile::tempdir().unwrap();
        let id = "sess-crash";
        let mut log = SessionLog::create(dir.path(), id).unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Message::user("run it"))).unwrap();
        log.append(&Record::Message(Message::assistant_with_tools(
            "",
            vec![ToolCall {
                id: "c9".into(),
                name: "echo".into(),
                arguments: json!({}),
                item_id: None,
                malformed_arguments: None,
            }],
        )))
        .unwrap();
        drop(log);

        let (mut agent, seen) = agent(vec![text("recovered")], dir.path());
        agent.load_session(id).unwrap();
        assert_eq!(unstamped(&agent.conversation()[3]), Message::tool_error("c9", "echo", INTERRUPTED_TOOL_RESULT));
        // Redelivering the interrupted input resumes without duplicating the user message.
        assert_eq!(agent.send_input(Some("msg-1"), "run it").await.unwrap(), "recovered");
        let request = &seen.lock().unwrap()[0];
        assert_eq!(request.iter().filter(|m| m.role == Role::User).count(), 1);
    }

    fn crashed_session(dir: &std::path::Path, id: &str, records: Vec<Record>) {
        let mut log = SessionLog::create(dir, id).unwrap();
        log.append(&Record::Message(Message::system("sys"))).unwrap();
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
            vec![Record::Message(Message::user("run it")), Record::Message(Message::assistant("already answered"))],
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

    /// Replays scripted results, including errors.
    struct Fallible {
        results: Mutex<Vec<std::result::Result<LLMResponse, String>>>,
        seen: Seen,
    }

    #[async_trait]
    impl LLMClient for Fallible {
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("tests never clone the fallible client")
        }
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("tests never clone the tool-spy client")
            }
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

    #[tokio::test]
    async fn detected_window_sits_between_config_and_model_name() {
        struct Reports;
        #[async_trait]
        impl LLMClient for Reports {
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                Box::new(Reports)
            }
            async fn chat(&self, _: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!()
            }
            async fn detect_context_window(&self) -> Option<DetectedWindow> {
                Some(DetectedWindow { tokens: 65_536, source: "test".into() })
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
        assert!(agent.detected_window.lock().unwrap().is_none(), "no probe when config sets the window");
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
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
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
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
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
        // Published on the control handle too, for `/plan` typed mid-turn.
        assert_eq!(&agent.control().plan(), agent.plan());

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

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_finishes_a_reported_outcome_without_calling_the_model() {
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "lost-outcome",
            vec![
                Record::Message(Message::user("run it")),
                Record::Message(Message::assistant_with_tools("", vec![report("o1", "blocked", "need a token")])),
                Record::Message(Message::tool_result("o1", goal::TOOL_NAME, "Recorded outcome: blocked.")),
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
        agent.set_event_sink(std::sync::Arc::new(move |session_id, event| {
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
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("tests never clone the interfering client")
        }
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
        interfering_with(responses, dir, on_call, hang_on, |config| config)
    }

    /// As [`interfering`], but lets a test tweak the agent `Config` (e.g. to
    /// register a provider that cannot build a client).
    fn interfering_with(
        responses: Vec<LLMResponse>,
        dir: &std::path::Path,
        on_call: impl Fn(usize, &TurnControl) + Send + Sync + 'static,
        hang_on: Option<usize>,
        config: impl FnOnce(Config) -> Config,
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
        let config = config(Config { session_dir: Some(dir.to_path_buf()), ..Config::default() });
        struct Shared(Arc<Interfering>);
        #[async_trait]
        impl LLMClient for Shared {
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                Box::new(Shared(self.0.clone()))
            }
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
    async fn model_switch_during_tool_call_applies_at_the_next_model_call() {
        // `/model <spec>` typed mid-turn (here: while the first response's
        // tool call is still being dispatched) is applied before the next
        // model call, in the middle of the tool loop.
        let dir = tempfile::tempdir().unwrap();
        // The recents MRU the `ModelSwitched` event feeds (as
        // `Terminal::model_switched` does for a switch at the prompt).
        let recents = Arc::new(Mutex::new(recents::Recents::default()));
        let recents_path = dir.path().join("recent-models.json");
        let (mut agent, _) = interfering(
            vec![tool_call("c1"), text("done")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    control.set_model("mock/switched");
                }
            },
            None,
        );
        {
            let slot = recents.clone();
            let path = recents_path.clone();
            agent.set_event_sink(std::sync::Arc::new(move |_, event| {
                if let AgentEvent::ModelSwitched { spec, previous } = event {
                    let mut recents = slot.lock().unwrap();
                    recents.record(previous);
                    recents.record(spec);
                    recents::save(&path, &recents);
                }
            }));
        }
        agent.new_session().unwrap();
        let before = format!("{}/{}", agent.provider_name(), agent.model_name());
        let outcome = agent.run_turn(Some("in-1"), "do it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        // The answer came from the mock client the turn switched to.
        assert!(outcome.response.starts_with("Based on the echo tool result: "), "{}", outcome.response);
        // The turn's second model call went to the new model.
        assert_eq!(agent.provider_name(), "mock", "switched mid-turn");
        assert_eq!(agent.model_name(), "switched");
        assert_eq!(agent.config().model, "mock/switched");
        assert_eq!(agent.control().take_model_request(), None, "the request was consumed");
        // Both sides of the switch were recorded, newest first.
        let models = recents.lock().unwrap().models().to_vec();
        let previous = recents::canonical(&before, &Default::default(), "mock");
        assert_eq!(models, ["mock/switched".to_string(), previous]);
        assert!(recents_path.exists(), "the MRU was persisted");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_newer_model_request_during_a_slow_build_supersedes_the_stale_one() {
        // A `/model` switch whose client build is slow (here: a provider whose
        // `api_key_command` sleeps) can be superseded by a newer `/model`
        // request arriving while that build is still in flight. The agent must
        // install the newest spec, not the stale one it happened to finish
        // building: otherwise the next model call would land on a superseded
        // model even though the newer command was acked for it.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = interfering_with(
            vec![tool_call("c1"), text("done")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    // Queue the slow-building switch, then — from another
                    // thread, while that build sleeps — queue a newer switch.
                    control.set_model("slow/x");
                    let newer = control.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(std::time::Duration::from_millis(100));
                        newer.set_model("mock/final");
                    });
                }
            },
            None,
            |mut config| {
                config.providers.insert(
                    "slow".to_string(),
                    crate::providers::ProviderConfig {
                        kind: Some(crate::providers::ProviderKind::Openai),
                        default_model: Some("m".to_string()),
                        base_url: Some("http://localhost:9/v1".to_string()),
                        // Build takes ~1s, so the newer request above is queued
                        // well before it finishes and the stale-check catches it.
                        api_key_command: Some("sleep 1; printf sk".to_string()),
                        ..Default::default()
                    },
                );
                config
            },
        );
        let switched = Arc::new(Mutex::new(Vec::<String>::new()));
        {
            let slot = switched.clone();
            agent.set_event_sink(std::sync::Arc::new(move |_, event| {
                if let AgentEvent::ModelSwitched { spec, .. } = event {
                    slot.lock().unwrap().push(spec.to_string());
                }
            }));
        }
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "do it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        // The newest spec won; the stale `slow/x` was discarded, never installed.
        assert_eq!(agent.provider_name(), "mock", "the newest switch took effect");
        assert_eq!(agent.model_name(), "final");
        assert_eq!(agent.config().model, "mock/final");
        assert_eq!(agent.control().take_model_request(), None, "both requests consumed");
        let switched = switched.lock().unwrap();
        assert_eq!(
            switched.as_slice(),
            ["mock/final".to_string()],
            "only the newest switch was announced: {switched:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn model_switch_to_an_unbuildable_spec_drops_the_request_and_reports_it() {
        // A `/model <spec>` that passes queue-time validation but whose client
        // still fails to build at the next model call must not fail silently:
        // the turn finishes on the current model, the dead request is dropped
        // (not re-queued, so it cannot leak into the next turn and retry
        // forever), and a `ModelSwitchFailed` event is emitted so the user is
        // told. Here the apply-time failure is a provider whose
        // `api_key_command` fails: the spec is fully valid — kind, model and
        // base_url all present — so `validate_spec` accepts it at queue time
        // (it never runs the command) and only building the client surfaces
        // the failure, exercising the advertised
        // validation-passes/apply-fails path.
        let dir = tempfile::tempdir().unwrap();
        // Two model calls (a tool call, then the final text) so the switch is
        // applied between them — a single final-answer call would end the turn
        // before `apply_model_request` ever runs.
        let (mut agent, _) = interfering_with(
            vec![tool_call("c1"), text("done")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    control.set_model("flaky/x");
                }
            },
            None,
            |mut config| {
                // Syntactically valid, endpoint configured; only the key
                // lookup fails, and that happens at apply time.
                config.providers.insert(
                    "flaky".to_string(),
                    crate::providers::ProviderConfig {
                        kind: Some(crate::providers::ProviderKind::Openai),
                        default_model: Some("m".to_string()),
                        base_url: Some("http://localhost:9/v1".to_string()),
                        api_key_command: Some("exit 1".to_string()),
                        ..Default::default()
                    },
                );
                config
            },
        );
        let failures = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
        {
            let slot = failures.clone();
            agent.set_event_sink(std::sync::Arc::new(move |_, event| {
                if let AgentEvent::ModelSwitchFailed { spec, error } = event {
                    slot.lock().unwrap().push((spec.to_string(), error.to_string()));
                }
            }));
        }
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "hi").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(agent.provider_name(), "test", "unchanged");
        assert_eq!(agent.model_name(), "interfering", "unchanged");
        // The request was consumed and dropped, not re-parked, so the next turn
        // does not silently retry the bad spec on the old model.
        assert_eq!(agent.control().take_model_request(), None, "the dead request was dropped");
        // The failure was surfaced to the UI, naming the spec.
        let failures = failures.lock().unwrap();
        assert_eq!(failures.len(), 1, "one failure reported: {failures:?}");
        assert_eq!(failures[0].0, "flaky/x");
        assert!(failures[0].1.contains("api_key_command"), "error explains the failure: {}", failures[0].1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_direct_model_switch_supersedes_a_stale_queued_request() {
        // A `/model` queued during a prior turn's final in-flight call is not
        // consumed before that turn ends, so it outlives the turn on the
        // `TurnControl`. A later direct (prompt-level) switch via
        // `Agent::set_model` must supersede it: otherwise the first model call
        // of the next turn would consume the stale request and silently switch
        // away from the model the direct switch just selected.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("done")], dir.path());
        agent.new_session().unwrap();
        agent.control().set_model("mock/stale");
        agent.set_model("mock/direct").await.unwrap();
        assert_eq!(agent.config().model, "mock/direct");
        assert_eq!(agent.model_name(), "direct", "the direct switch took effect");
        assert_eq!(
            agent.control().take_model_request(),
            None,
            "the stale queued request was cleared, not left to fire next turn"
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_direct_model_switch_with_a_slow_key_command_does_not_stall_the_runtime() {
        // `set_model` builds the new client, and building it can run an
        // `api_key_command` as a child process. That build must be offloaded to
        // the blocking pool (as `apply_model_request` does), not run inline on
        // the async executor: the between-turn `/model` switch is awaited from
        // the single-threaded TUI/ACP event loops, so an inline blocking build
        // would freeze the whole UI for the command's duration. Proof: on a
        // single-threaded runtime a concurrently-spawned async task keeps
        // ticking while the key command sleeps; if the build ran inline it would
        // monopolise the only executor thread and the ticker would not advance.
        use std::sync::atomic::AtomicUsize;
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent_with_slow_key_command(dir.path());
        agent.new_session().unwrap();

        let ticks = Arc::new(AtomicUsize::new(0));
        let ticker = {
            let ticks = ticks.clone();
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    ticks.fetch_add(1, Ordering::SeqCst);
                }
            })
        };

        agent.set_model("slowmock/x").await.unwrap();
        ticker.abort();

        assert_eq!(agent.model_name(), "x", "the switch took effect");
        assert_eq!(agent.config().model, "slowmock/x");
        // The key command sleeps ~300ms; at 10ms ticks the async ticker would
        // advance many times if (and only if) the executor stayed free. Require
        // several to rule out the inline-blocking regression without being
        // flaky about exact scheduling.
        assert!(
            ticks.load(Ordering::SeqCst) >= 5,
            "the runtime kept scheduling other tasks while the key command ran (ticks={}): a stall means the \
             blocking client build ran inline on the executor instead of spawn_blocking",
            ticks.load(Ordering::SeqCst),
        );
    }

    fn agent_with_slow_key_command(dir: &std::path::Path) -> (Agent, Seen) {
        let (mut agent, seen) = agent(vec![text("done")], dir);
        // A Mock provider needs no endpoint and builds instantly, so the only
        // slow part of the client build is its `api_key_command` child process —
        // isolating exactly the blocking work `set_model` must offload.
        agent.config.providers.insert(
            "slowmock".to_string(),
            crate::providers::ProviderConfig {
                kind: Some(crate::providers::ProviderKind::Mock),
                default_model: Some("m".to_string()),
                api_key_command: Some("sleep 0.3; printf sk".to_string()),
                ..Default::default()
            },
        );
        (agent, seen)
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn model_switch_queued_during_a_call_applies_before_threshold_compaction() {
        // Threshold auto-compaction is itself a model call, so a `/model`
        // queued while the triggering call was in flight must apply to the
        // summarization request — not after it. The mock client panics if it
        // is ever asked to chat, so the switch provably happened first.
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
        let (mut agent, _) = interfering_with(
            vec![big, text("done")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    control.set_model("mock/summarizer");
                }
            },
            None,
            |config| config,
        );
        // A tiny window with a low threshold forces compaction on the second
        // iteration, right after the big tool result lands.
        agent.config.context_window = Some(3_000);
        agent.config.auto_compact_threshold = 0.5;
        agent.tools().register(
            ToolDefinition::new("big", "big", json!({"type": "object"})),
            Box::new(|_| Ok(json!("x".repeat(8_000)))),
        );
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(agent.provider_name(), "mock", "switched before the compaction call");
        assert_eq!(agent.model_name(), "summarizer");
        assert_eq!(agent.control().take_model_request(), None, "the request was consumed");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn model_switch_queued_during_an_overflow_applies_to_the_compaction_and_retry() {
        // A `/model` typed while an overflowing request is in flight must be
        // consumed before the overflow compaction's summarization call, and
        // the retried request must go to the new model too — never the old
        // one. The switch target is an unreachable OpenAI endpoint, so any
        // call that reaches it fails to connect. The summary and the retry
        // both go to the new client (the switch is consumed before the
        // summary), so the turn fails to connect rather than completing on
        // the old model — proving the switch was not deferred past the
        // compaction.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = interfering_with(
            vec![tool_call("c1"), tool_call("c2")],
            dir.path(),
            |_, _| {},
            None,
            |mut config| {
                config.providers.insert(
                    "flaky".to_string(),
                    crate::providers::ProviderConfig {
                        kind: Some(crate::providers::ProviderKind::Openai),
                        default_model: Some("x".to_string()),
                        base_url: Some("http://127.0.0.1:9/v1".to_string()),
                        // Fail fast: no retries, a short timeout, so the test
                        // does not wait out the default backoff schedule.
                        max_retries: Some(0),
                        timeout_secs: Some(2),
                        ..Default::default()
                    },
                );
                config
            },
        );
        // The second call overflows; while it is "in flight" the user queues
        // the switch. The compaction summary and the retry both go to the new
        // client (the switch is consumed before the summary), so the turn
        // fails to connect there.
        let ok_tool: std::result::Result<LLMResponse, String> = Ok(tool_call("c1"));
        let overflow: std::result::Result<LLMResponse, String> =
            Err("HTTP 400: maximum context length is 4096 tokens.".to_string());
        let summary: std::result::Result<LLMResponse, String> = Ok(text("SUMMARY"));
        let control = agent.control();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        struct OverflowThenSummary {
            results: Mutex<Vec<std::result::Result<LLMResponse, String>>>,
            seen: Seen,
            control: TurnControl,
        }
        #[async_trait]
        impl LLMClient for OverflowThenSummary {
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("the probe is never spawned for a configured provider")
            }
            async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
                self.seen.lock().unwrap().push(request.messages.to_vec());
                if self.seen.lock().unwrap().len() == 2 {
                    // The overflowing call is in flight now: queue the switch.
                    self.control.set_model("flaky/x");
                }
                self.results.lock().unwrap().remove(0).map_err(|e| anyhow::anyhow!(e))
            }
            fn model_name(&self) -> &str {
                "scripted"
            }
            fn provider_name(&self) -> &str {
                "test"
            }
        }
        agent.client = Box::new(OverflowThenSummary {
            results: Mutex::new(vec![ok_tool, overflow, summary]),
            seen: seen.clone(),
            control,
        });
        agent.new_session().unwrap();
        let error = agent.run_turn(Some("in-1"), "hi").await.unwrap_err();
        let message = format!("{error:#}");
        assert!(!message.contains("maximum context length"), "the retry did not overflow on the old client: {message}");
        assert_eq!(agent.provider_name(), "flaky", "switched before the overflow retry");
        assert_eq!(agent.model_name(), "x");
        assert_eq!(agent.control().take_model_request(), None, "the request was consumed");
        // The old client served only the tool call and the overflowing call;
        // the compaction summary and the retry both went to the new client
        // (which is why the turn fails to connect).
        let calls = seen.lock().unwrap();
        assert_eq!(calls.len(), 2, "tool, overflow — everything after the switch left on the new client");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn mid_turn_model_switch_with_a_configured_window_skips_the_probe() {
        // A mid-turn `/model` switch must not stall the agent loop on the
        // context-window probe. When the new spec carries a configured window
        // (here: `context_window` on the provider entry) that value is
        // authoritative, so the HTTP probe is skipped outright and the next
        // model call goes out immediately.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = interfering_with(
            vec![tool_call("c1"), text("done")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    control.set_model("mock/probed");
                }
            },
            None,
            |mut config| {
                // A `context_window` on the provider entry is authoritative, so
                // the switch must not probe the endpoint at all.
                config.providers.insert(
                    "mock".to_string(),
                    crate::providers::ProviderConfig { context_window: Some(111_111), ..Default::default() },
                );
                config
            },
        );
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "hi").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(agent.provider_name(), "mock", "switched mid-turn");
        assert_eq!(agent.model_name(), "probed");
        // The configured window won immediately, with no endpoint probe.
        let (window, source) = agent.context_window_with_source();
        assert_eq!(window, 111_111, "{source}");
        assert_eq!(source, "provider context_window");
        assert!(agent.detected_window.lock().unwrap().is_none(), "a configured window skips the endpoint probe");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn mid_turn_model_switch_without_a_configured_window_probes_in_the_background() {
        // With no configured window the probe still runs, but in a background
        // task so the next model call is not delayed by it; the result is
        // published (and the stats refreshed) whenever it lands.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = interfering_with(
            vec![tool_call("c1"), text("done")],
            dir.path(),
            |call, control| {
                if call == 1 {
                    control.set_model("mock/probed");
                }
            },
            None,
            |config| config,
        );
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "hi").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(agent.provider_name(), "mock", "switched mid-turn");
        // The mock client reports no window, so the background probe publishes
        // nothing and the model-name fallback stays in effect.
        assert!(agent.detected_window.lock().unwrap().is_none());
    }

    #[test]
    fn a_stale_background_probe_is_discarded_after_a_later_switch() {
        // A window probe spawned for one model can finish after the user has
        // already switched to another. It must not overwrite the newer model's
        // window: `finish_detect` discards any result whose generation no
        // longer matches the live one.
        use std::sync::atomic::AtomicU64;
        let slot = Arc::new(Mutex::new(None));
        let current = Arc::new(AtomicU64::new(5));
        let stats = SharedStats::default();
        stats.lock().unwrap().window_source = "known for the model name".to_string();

        // Probe spawned under generation 3 lands after the generation moved to 5.
        Agent::finish_detect(
            Some(DetectedWindow { tokens: 999, source: "stale".to_string() }),
            3,
            current.clone(),
            slot.clone(),
            None,
            stats.clone(),
        );
        assert!(slot.lock().unwrap().is_none(), "a stale probe must not write the window slot");
        assert_eq!(stats.lock().unwrap().window, 0, "a stale probe must not touch the shared stats");

        // A probe for the live generation publishes normally.
        Agent::finish_detect(
            Some(DetectedWindow { tokens: 4096, source: "fresh".to_string() }),
            5,
            current.clone(),
            slot.clone(),
            None,
            stats.clone(),
        );
        assert_eq!(slot.lock().unwrap().as_ref().unwrap().tokens, 4096, "the live probe writes the slot");
        assert_eq!(stats.lock().unwrap().window, 4096, "the live probe refreshes the stats");
        assert!(stats.lock().unwrap().window_source.starts_with("reported by the endpoint"));
    }

    #[test]
    fn a_background_probe_refines_a_default_window_source() {
        // When the new model has no known window the fallback source is
        // "default"; a later endpoint probe must still be allowed to refine it
        // (the conservative stats gate exempts "default", not just the
        // model-name fallback).
        use std::sync::atomic::AtomicU64;
        let slot = Arc::new(Mutex::new(None));
        let current = Arc::new(AtomicU64::new(1));
        let stats = SharedStats::default();
        stats.lock().unwrap().window_source = "default".to_string();
        Agent::finish_detect(
            Some(DetectedWindow { tokens: 8192, source: "max_model_len".to_string() }),
            1,
            current.clone(),
            slot.clone(),
            None,
            stats.clone(),
        );
        assert_eq!(stats.lock().unwrap().window, 8192, "a probe must refine a default-source window");
    }

    #[test]
    fn a_stricter_probe_replaces_a_learned_window_stat() {
        // A probe can land after an overflow has published a learned window.
        // The slot already stores the detected window, so `context_window_with_source()`
        // starts using the smaller value; the shared stats must follow, or `/context`
        // and the status line keep reporting the larger learned window indefinitely.
        use std::sync::atomic::AtomicU64;
        let slot = Arc::new(Mutex::new(None));
        let current = Arc::new(AtomicU64::new(1));
        let stats = SharedStats::default();
        {
            let mut s = stats.lock().unwrap();
            s.window = 200_000;
            s.window_source = "learned from a context-overflow error".to_string();
        }
        Agent::finish_detect(
            Some(DetectedWindow { tokens: 128_000, source: "max_model_len".to_string() }),
            1,
            current.clone(),
            slot.clone(),
            None,
            stats.clone(),
        );
        let s = stats.lock().unwrap();
        assert_eq!(s.window, 128_000, "a stricter detected window must replace the learned stat");
        assert!(s.window_source.starts_with("reported by the endpoint"));
    }

    #[test]
    fn a_looser_probe_does_not_replace_a_learned_window_stat() {
        // A learned window reflects a real overflow, so a probe reporting a
        // *larger* window must not loosen it: the learned limit is the binding one.
        use std::sync::atomic::AtomicU64;
        let slot = Arc::new(Mutex::new(None));
        let current = Arc::new(AtomicU64::new(1));
        let stats = SharedStats::default();
        {
            let mut s = stats.lock().unwrap();
            s.window = 100_000;
            s.window_source = "learned from a context-overflow error".to_string();
        }
        Agent::finish_detect(
            Some(DetectedWindow { tokens: 200_000, source: "max_model_len".to_string() }),
            1,
            current.clone(),
            slot.clone(),
            None,
            stats.clone(),
        );
        let s = stats.lock().unwrap();
        assert_eq!(s.window, 100_000, "a looser detected window must not replace the learned stat");
        assert_eq!(s.window_source, "learned from a context-overflow error");
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
    async fn tools_snapshot_captured_in_plan_mode_still_lists_mutating_tools_live() {
        let dir = tempfile::tempdir().unwrap();
        let (agent, _) = agent(vec![], dir.path());
        // A mutating tool that plan mode strips.
        agent.tools().register(
            ToolDefinition::new("write_file", "write a file", json!({"type": "object"})),
            Box::new(|_| Ok(json!("ok"))),
        );
        assert!(!crate::mode::plan_allows("write_file"), "test needs a plan-disallowed tool");

        // Capture while in Plan mode: the capture must keep the full superset,
        // not the Plan-filtered set, or the mutating tool is lost for good.
        agent.set_mode(crate::mode::AgentMode::Plan);
        let snapshot = crate::turn_commands::Snapshot::capture(&agent);

        // A mid-turn `/mode normal` makes the live mode Normal; `/tools` must
        // then list the mutating tool the Plan-time capture would have dropped.
        let normal = crate::context::ContextStats { mode: crate::mode::AgentMode::Normal, ..Default::default() };
        let Some(crate::turn_commands::Output::Block(listing)) =
            snapshot.output("/tools", &normal, &crate::plan::Plan::default())
        else {
            panic!("/tools produced no block");
        };
        assert!(listing.contains("write_file"), "Plan-mode capture dropped the mutating tool: {listing}");

        // And under a live Plan mode it is still filtered out.
        let plan = crate::context::ContextStats { mode: crate::mode::AgentMode::Plan, ..Default::default() };
        let Some(crate::turn_commands::Output::Block(filtered)) =
            snapshot.output("/tools", &plan, &crate::plan::Plan::default())
        else {
            panic!("/tools produced no block");
        };
        assert!(!filtered.contains("write_file"), "plan mode must still hide the mutating tool: {filtered}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn tools_snapshot_captured_without_history_still_lists_it_live() {
        let dir = tempfile::tempdir().unwrap();
        let (agent, _) = agent(vec![], dir.path());
        // History tools are disabled at capture time: no smart summary is in
        // context yet, so `tool_definitions_all_modes` would drop them.
        assert!(!agent.history_tools_enabled(), "history must be disabled at capture for this test");

        // Capture must keep the history tools in the superset anyway, or a
        // same-turn smart auto-compaction that enables them later leaves
        // `/tools` unable to list tools the next model step actually receives.
        let snapshot = crate::turn_commands::Snapshot::capture(&agent);

        // With history live, `/tools` must list the history tools the
        // capture-time availability would have dropped.
        let available = crate::context::ContextStats { history_available: true, ..Default::default() };
        let Some(crate::turn_commands::Output::Block(listing)) =
            snapshot.output("/tools", &available, &crate::plan::Plan::default())
        else {
            panic!("/tools produced no block");
        };
        assert!(
            listing.contains(crate::history::SEARCH_TOOL) && listing.contains(crate::history::READ_TOOL),
            "capture dropped the history tools: {listing}"
        );

        // And while history is unavailable they are still filtered out.
        let unavailable = crate::context::ContextStats { history_available: false, ..Default::default() };
        let Some(crate::turn_commands::Output::Block(hidden)) =
            snapshot.output("/tools", &unavailable, &crate::plan::Plan::default())
        else {
            panic!("/tools produced no block");
        };
        assert!(
            !hidden.contains(crate::history::SEARCH_TOOL) && !hidden.contains(crate::history::READ_TOOL),
            "history tools must stay hidden while unavailable: {hidden}"
        );
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
