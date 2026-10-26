use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::{DateTime, Local, Utc};
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
use crate::timers::{self, Timers};
use crate::tools::ToolRegistry;

const INTERRUPTED_TOOL_RESULT: &str =
    "Error: the harness stopped before this tool call completed; its outcome is unknown.";
const CANCELLED_TOOL_RESULT: &str = "Error: the turn was cancelled before this tool call ran.";
const LOOP_STOPPED_TOOL_RESULT: &str =
    "Error: the turn is ending as blocked (repeated-call loop detected); this tool call was not run.";
pub const CANCELLED_RESPONSE: &str = "[turn cancelled]";

/// Most times a single model call will be re-sent after the connection drops
/// mid-reply (a `StreamInterrupted`) before the turn gives up. Bounds the
/// "network came back but the stream keeps breaking" case.
const MAX_STREAM_RESTARTS: u32 = 10;

/// Turn cap for a headless (non-interactive) session whose configured cap is
/// unbounded — `max_iterations = 0`, or Auto mode, which disables the cap.
/// With no human present nothing else stops a runaway turn, so the cap is a
/// finite safety net instead (issue #65).
const HEADLESS_SAFETY_CAP: usize = 300;

/// How many times a turn re-prompts a model whose reply was cut off at the
/// output-token limit before giving up and ending the turn with a `MaxTokens`
/// stop reason. Keeps a model that keeps overrunning from looping forever while
/// still giving it a few chances to continue in smaller pieces.
const MAX_TRUNCATED_CONTINUATIONS: usize = 3;

/// Fallback `max_tokens` when the user configured none and the endpoint
/// published no output limit. Much larger than the old arbitrary 4096 default,
/// which cut long replies (whole-file writes) off mid-call; still an explicit
/// value, since Anthropic requires one and some OpenAI-compatible proxies apply
/// a small default when it is omitted.
const DEFAULT_MAX_OUTPUT_TOKENS: i64 = 32_768;

/// The nudge sent when a reply was cut off at the output-token limit, asking the
/// model to continue in smaller pieces rather than ending the turn.
fn truncated_continuation_note(completion_tokens: i64) -> String {
    let at = if completion_tokens > 0 {
        format!(" at the output-token limit ({completion_tokens} tokens)")
    } else {
        " at the output-token limit".to_string()
    };
    format!(
        "Your previous reply was cut off{at}; any tool call in it was not run. \
         Continue from where you left off, and write large outputs in smaller pieces \
         (e.g. `write_file` a skeleton, then `edit_file` to fill it in) so each reply \
         fits within the limit."
    )
}

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

/// The display form of a tool result: the model-facing `text` with each
/// attached image noted as `[image: path, WxH]` on its own line. Shared by the
/// live tool-result event and ACP / trajectory replay so a resumed session
/// shows the same image markers it showed live, instead of the bare text.
fn tool_result_display(text: &str, attachments: &[crate::llm::Attachment]) -> String {
    let mut out = text.to_string();
    for attachment in attachments {
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&attachment.placeholder());
    }
    out
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
    /// The interactive queue id (shared with queued messages) so `/queue`
    /// can list, edit or withdraw the steer before the agent reads it.
    pub id: Option<usize>,
}

/// Why a turn ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    #[default]
    EndTurn,
    Cancelled,
    MaxTurnRequests,
    /// The model's reply was cut off at the output-token limit and kept being
    /// cut off across the continuation cap, so the turn ended without a clean
    /// finish. Distinct from `EndTurn` so callers (ACP) can tell a truncated
    /// turn apart from a finished one.
    MaxTokens,
}

impl StopReason {
    /// ACP `stopReason` value.
    pub fn as_acp(self) -> &'static str {
        match self {
            StopReason::EndTurn => "end_turn",
            StopReason::Cancelled => "cancelled",
            StopReason::MaxTurnRequests => "max_turn_requests",
            StopReason::MaxTokens => "max_tokens",
        }
    }

    /// Whether this is the default clean finish. Used to keep the session log
    /// quiet: only a non-`EndTurn` stop reason is serialized on a `TurnEnd`
    /// record, and older records without the field restore to `EndTurn`.
    pub(crate) fn is_end_turn(&self) -> bool {
        matches!(self, StopReason::EndTurn)
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
    /// Fired whenever `set_model` queues/replaces a request, so an in-flight
    /// build of a now-stale spec can be cancelled immediately rather than
    /// waited out (see `Agent::apply_model_request`).
    model_tx: tokio::sync::watch::Sender<u64>,
    /// The plan as last published by the agent (every `AgentEvent::Plan`),
    /// so `/plan` can show it while a turn holds the agent.
    plan: Mutex<crate::plan::Plan>,
    /// The timers as last published by the agent (every change and
    /// `Agent::refresh_stats`), so `/timers` can list them while a turn holds
    /// the agent.
    timers: Mutex<crate::timers::Timers>,
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
                model: Mutex::new(None),
                model_tx: tokio::sync::watch::channel(0u64).0,
                plan: Mutex::new(crate::plan::Plan::default()),
                timers: Mutex::new(crate::timers::Timers::default()),
                thinking: Mutex::new(None),
            }),
        }
    }
}

impl TurnControl {
    /// Queue a message for the running turn; it is added before the next model call.
    pub fn steer(&self, text: &str, tag: Option<Value>) {
        self.inner.steers.lock().unwrap().push_back(Steer { text: text.to_string(), tag, id: None });
    }

    /// Queue a steer carrying a `/queue` id, so it can be edited or withdrawn
    /// until the agent reads it.
    pub fn steer_with_id(&self, text: &str, id: usize) {
        self.inner.steers.lock().unwrap().push_back(Steer { text: text.to_string(), tag: None, id: Some(id) });
    }

    /// Id-carrying steers the agent has not read yet, oldest first.
    pub fn pending_steers(&self) -> Vec<(usize, String)> {
        let steers = self.inner.steers.lock().unwrap();
        steers.iter().filter_map(|s| s.id.map(|id| (id, s.text.clone()))).collect()
    }

    /// Withdraw unread steers by id; returns how many were removed. A steer
    /// the agent already read is gone from the list, so it is not counted.
    pub fn remove_steers(&self, ids: &[usize]) -> usize {
        let mut steers = self.inner.steers.lock().unwrap();
        let before = steers.len();
        steers.retain(|s| !s.id.is_some_and(|id| ids.contains(&id)));
        before - steers.len()
    }

    /// Rewrite an unread steer; false when none has that id (never sent, or
    /// already read by the agent).
    pub fn edit_steer(&self, id: usize, text: &str) -> bool {
        let mut steers = self.inner.steers.lock().unwrap();
        match steers.iter_mut().find(|s| s.id == Some(id)) {
            Some(steer) => {
                steer.text = text.to_string();
                true
            }
            None => false,
        }
    }

    /// Withdraw every unread id-carrying steer; returns how many.
    pub fn clear_steers(&self) -> usize {
        let mut steers = self.inner.steers.lock().unwrap();
        let before = steers.len();
        steers.retain(|s| s.id.is_none());
        before - steers.len()
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

    /// Ask the running turn to switch to `spec` (`provider/model`) at its next
    /// model call; a later request replaces an earlier unapplied one.
    pub fn set_model(&self, spec: &str) {
        *self.inner.model.lock().unwrap() = Some(spec.to_string());
        // Notify any in-flight build of a now-stale spec so it cancels and the
        // loop rebuilds the newest spec immediately (see `apply_model_request`).
        self.inner.model_tx.send_modify(|generation| *generation += 1);
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

    /// The timers as the agent last published them.
    pub fn timers(&self) -> crate::timers::Timers {
        self.inner.timers.lock().unwrap().clone()
    }

    pub fn publish_timers(&self, timers: &crate::timers::Timers) {
        *self.inner.timers.lock().unwrap() = timers.clone();
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

    /// Resolves once a newer `/model` request is queued after the returned
    /// generation is captured. Used to cancel an in-flight build of a spec that
    /// a newer request has just superseded. The caller passes the `watch`
    /// generation snapshot taken *before* it started building, so a request that
    /// landed during the build is observed immediately.
    pub async fn model_request_changed(&self, mut rx: tokio::sync::watch::Receiver<u64>) {
        let _ = rx.changed().await;
    }

    /// Subscribe to `/model` request notifications; the returned receiver's
    /// current value is the generation at subscribe time.
    pub fn model_request_rx(&self) -> tokio::sync::watch::Receiver<u64> {
        self.inner.model_tx.subscribe()
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
    /// A timer fired mid-turn: its `⏰ timer N: <note>` notification. A
    /// dedicated variant (not `UserMessage`) so a plain/redirected renderer
    /// shows it — `UserMessage` is steer/replay chatter that plain output
    /// intentionally suppresses, and a timer firing is not either (issue #150).
    TimerFired {
        id: u32,
        note: &'a str,
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
    /// A streamed reply broke after some output had already been shown
    /// (`StreamInterrupted`) and the whole request is being re-sent from
    /// scratch. The partial reply was displayed but never recorded in history,
    /// so renderers must discard the abandoned text and reset any pending
    /// thinking before accepting the restarted stream's deltas — otherwise the
    /// replacement answer is appended to the stale prefix and the final
    /// `AssistantMessage` is suppressed.
    ResponseRestarted,
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
pub type EventSink = std::sync::Arc<dyn Fn(Option<&str>, &AgentEvent) + Send + Sync>;

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
    /// Non-`EndTurn` stop reasons of completed inputs, by input ID, so a
    /// redelivered input replays how its turn actually ended — e.g. a truncated
    /// `MaxTokens` turn — instead of a clean `EndTurn` (issue #114). Clean turns
    /// are absent.
    completed_stop_reasons: HashMap<String, StopReason>,
    /// An input that was accepted but whose turn never finished (crash, kill, or error).
    pending_input: Option<PendingInput>,
    input_counter: u64,
    event_sink: Option<EventSink>,
    /// Test-only hook fired between a request's thinking snapshot and its
    /// status-line update, to interleave a mid-update `/thinking` change.
    #[cfg(test)]
    after_thinking_snapshot: Option<Box<dyn Fn() + Send + Sync>>,
    /// Test-only hook fired right after a length-truncated chunk schedules its
    /// continuation reminder, to interleave a steer landing *between*
    /// continuation requests — after the post-response steer check, before the
    /// next iteration absorbs it (issue #114).
    #[cfg(test)]
    after_continuation_scheduled: Option<Box<dyn Fn() + Send + Sync>>,
    message_counter: u64,
    control: TurnControl,
    stats: SharedStats,
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
    /// Thinking levels reported by the endpoint (see `detect_context_window`).
    /// Shared for the same reason as `detected_window`.
    reported_thinking: std::sync::Arc<std::sync::Mutex<Option<crate::thinking::Reported>>>,
    /// Vision capability reported by the endpoint (see `detect_context_window`).
    /// Shared for the same reason as `detected_window`.
    reported_vision: std::sync::Arc<std::sync::Mutex<Option<crate::vision::Vision>>>,
    /// The model's own maximum output tokens as published by the endpoint,
    /// captured on **both** probe paths — the default combined probe and the
    /// configured-window path (which skips the window follow-up but still reads
    /// the shared `/models` entry that carries this limit). Kept separate from
    /// `detected_window` so a configured context window — which clears the
    /// detected window — never discards the discovered output limit (issue
    /// #114). Shared for the same reason as `detected_window`.
    reported_max_output: std::sync::Arc<std::sync::Mutex<Option<usize>>>,
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
    /// The session's timers (see `timers.rs`); the harness owns the clock.
    timers: Timers,
    /// Test hook: a shared "now" for the timers, replacing the wall clock, so
    /// a test (or a tool it registers) can advance time mid-turn.
    #[cfg(test)]
    timers_clock: Option<std::sync::Arc<std::sync::Mutex<DateTime<Local>>>>,
    /// Test hook: forces the next timers/plan persist (`timers_changed` /
    /// `record_plan`) to fail, so a test can exercise the apply-then-persist
    /// rollback without a real I/O failure. Consumed (reset) on the first
    /// failed persist.
    #[cfg(test)]
    fail_next_persist: bool,
    /// Whether the `timer_*` tools are offered. Off in ACP, which has no idle
    /// loop to fire them.
    timers_enabled: bool,
    /// Steps since the last timer fired or the pending set emptied, driving the
    /// `PENDING_NUDGE_EVERY` reminder for fired timers not yet marked done.
    pending_timer_steps: usize,
    /// Set by the REPL before an automatic timer turn (a wakeup, mid-turn
    /// firing, or pending nudge) so the user message `run_turn` pushes is
    /// marked `auto_initiated` — billed as agent-initiated, not a premium
    /// user request with no new user input. Consumed once per `run_turn`.
    auto_turn: bool,
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
    /// The [`Spill`](crate::output::Spill) identities of the captures the most
    /// recent bash call truncated and spilled, published by the bash tool so
    /// the loop detector gets each spill's identity **out of band** rather than
    /// re-parsing the rendered marker (issue #65).
    spill_digests: Arc<std::sync::Mutex<Vec<output::Spill>>>,
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

/// The shared slots a background capability probe publishes into (see
/// `Agent::detect_context_window_for_switch`).
struct DetectSlots {
    window: std::sync::Arc<std::sync::Mutex<Option<DetectedWindow>>>,
    thinking: std::sync::Arc<std::sync::Mutex<Option<crate::thinking::Reported>>>,
    vision: std::sync::Arc<std::sync::Mutex<Option<crate::vision::Vision>>>,
    max_output: std::sync::Arc<std::sync::Mutex<Option<usize>>>,
}

/// What a background capability probe found.
struct Detected {
    window: Option<DetectedWindow>,
    thinking: Option<crate::thinking::Reported>,
    vision: Option<crate::vision::Vision>,
    /// The model's published output-token limit, kept separate from `window`
    /// so a configured window (which carries none) never discards it (#114).
    max_output: Option<usize>,
}

#[cfg(test)]
impl Detected {
    /// A probe that reported only a window.
    fn window(window: DetectedWindow) -> Self {
        Detected { window: Some(window), thinking: None, vision: None, max_output: None }
    }
}

#[cfg(test)]
impl DetectSlots {
    /// Slots around an existing window slot, with fresh thinking/vision slots.
    fn window(window: std::sync::Arc<std::sync::Mutex<Option<DetectedWindow>>>) -> Self {
        DetectSlots { window, thinking: Default::default(), vision: Default::default(), max_output: Default::default() }
    }
}

impl Agent {
    pub fn new(client: Box<dyn LLMClient>, config: Config) -> Self {
        let conversation = vec![Message { timestamp: Some(session::now()), ..Message::system(&config.system_prompt) }];
        let policy = Policy::new(&config.permissions, &config.sandbox);
        let memory = Self::build_memory(&config);
        let outcome_tool = config.outcome_tool;
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
            completed_stop_reasons: HashMap::new(),
            pending_input: None,
            input_counter: 0,
            event_sink: None,
            #[cfg(test)]
            after_thinking_snapshot: None,
            #[cfg(test)]
            after_continuation_scheduled: None,
            message_counter: 0,
            control: TurnControl::default(),
            stats: SharedStats::default(),
            calibration: None,
            learned_window: None,
            learned_max_output: None,
            detected_window: std::sync::Arc::new(std::sync::Mutex::new(None)),
            detect_generation: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
            reported_thinking: std::sync::Arc::new(std::sync::Mutex::new(None)),
            reported_vision: std::sync::Arc::new(std::sync::Mutex::new(None)),
            reported_max_output: std::sync::Arc::new(std::sync::Mutex::new(None)),
            compact_floor: 0,
            streaming: false,
            instructions: None,
            skills: Skills::default(),
            plan: Plan::default(),
            timers: Timers::default(),
            #[cfg(test)]
            timers_clock: None,
            #[cfg(test)]
            fail_next_persist: false,
            timers_enabled: true,
            pending_timer_steps: 0,
            auto_turn: false,
            reminders: Reminders::new(outcome_tool),
            tool_output_limit: output::DEFAULT_MAX_OUTPUT_LENGTH,
            questions: crate::question::QuestionBroker::new(),
            spill_dir: Arc::new(RwLock::new(output::spill_dir())),
            spill_digests: Arc::new(std::sync::Mutex::new(Vec::new())),
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
            self.reported_thinking.lock().unwrap().as_ref(),
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
        // A direct switch supersedes any still-unapplied mid-turn `/model`
        // request: one queued during the final in-flight call of a prior turn
        // outlives that turn, and without clearing it the first call of the
        // next turn would consume the stale request and silently switch away
        // from the model this direct switch just selected. Consume it *before*
        // the fallible build below: if the new client fails to build we return
        // at the `?`, and a request left queued here would then fire on the
        // next turn even though the user's latest intent was this failed spec.
        self.control.take_model_request();
        let client = Self::build_client_off_runtime(&self.config, spec).await?;
        self.config.model = spec.to_string();
        self.install_client(client).await;
        Ok(())
    }

    /// Rebuild the LLM client for the current model, resetting the state that
    /// is tied to a client: the context calibration, the window learned from
    /// overflow errors, the window detected from the endpoint, and the
    /// post-compaction floor. Used after a provider edit (which can change the
    /// endpoint, key, or model the current spec resolves to) and on model
    /// switches.
    pub async fn refresh_client(&mut self) -> Result<()> {
        let spec = self.config.model.clone();
        let client = Self::build_client_off_runtime(&self.config, &spec).await?;
        self.install_client(client).await;
        Ok(())
    }

    /// Build a client for `spec` on the blocking pool.
    ///
    /// `client_for` → `build_client` → `resolve` can run an `api_key_command`
    /// as a child process. `set_model`/`refresh_client` are awaited from the
    /// async TUI/ACP command loops (between turns), so running that inline
    /// freezes the runtime for the command's full duration, stalling the
    /// UI/event loop. Offloading keeps the runtime responsive while the key
    /// command runs — the same pattern `apply_model_request` uses for the
    /// mid-turn switch.
    async fn build_client_off_runtime(config: &Config, spec: &str) -> Result<Box<dyn LLMClient>> {
        let config_for_build = config.clone();
        let spec_for_build = spec.to_string();
        tokio::task::spawn_blocking(move || Self::client_for(&config_for_build, &spec_for_build))
            .await
            .map_err(|join| anyhow::anyhow!("building client for {spec:?} panicked: {join}"))?
    }

    /// Install a freshly built client and reset the client-tied state, then
    /// detect the new model's window / thinking levels / vision (blocking).
    async fn install_client(&mut self, client: Box<dyn LLMClient>) {
        self.client = client;
        self.calibration = None;
        self.learned_window = None;
        self.learned_max_output = None;
        *self.detected_window.lock().unwrap() = None;
        *self.reported_thinking.lock().unwrap() = None;
        self.compact_floor = 0;
        self.detect_context_window().await;
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
    ///
    /// Returns `true` when the turn was cancelled (the switch was abandoned),
    /// so the caller must **stop before issuing the next model call**. Just
    /// abandoning the switch is not enough: the caller otherwise falls through
    /// into `compact_with` or the chat `select!`, where a cancellation that is
    /// already pending still races an immediately-ready model future — so one
    /// call could still land on the old model after the user cancelled.
    #[must_use]
    async fn apply_model_request(&mut self) -> bool {
        // Loop so that a newer `/model` request arriving while an earlier one
        // is being built is honoured: each pass builds exactly one spec, then
        // re-checks the slot and rebuilds the newest if it was superseded.
        loop {
            // Don't start (or keep) switching for a turn the user cancelled;
            // the pending request stays queued for the next turn's first call.
            // Signal the caller to stop before it reaches a model call.
            if self.control.is_cancelled() {
                return true;
            }
            let Some(spec) = self.control.take_model_request() else { return false };
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
            // runs. The build honours a cancel flag: on cancel it kills the
            // key-command child and fails fast, and we race the await against
            // `control.cancelled()` below so the turn returns promptly instead
            // of blocking on a hung command.
            //
            // The flag the build polls must be a **build-local** token, not the
            // turn-wide cancel flag. On cancel we drop `handle` below, but a
            // dropped `spawn_blocking` task keeps running — so the key-command
            // worker outlives this call. If it polled the turn-wide flag,
            // `run_turn` could return and the next turn's `start_turn()` would
            // reset that flag back to `false` before the worker's 50 ms poll
            // observed the cancel, letting the supposedly-killed helper run on
            // until its 120 s timeout. A token private to this build can never
            // be reset by the next turn, so once we set it the worker reliably
            // kills its child.
            let config_for_build = self.config.clone();
            let spec_for_build = spec.clone();
            let build_cancel = Arc::new(AtomicBool::new(false));
            let cancel_for_build = build_cancel.clone();
            let control = self.control.clone();
            // Subscribe to `/model` request notifications BEFORE spawning the
            // build, so a newer request that lands while this build runs is
            // observed by the `select!` below (the receiver's generation is
            // captured now; `changed()` fires on the next `set_model`).
            let model_rx = self.control.model_request_rx();
            let handle = tokio::task::spawn_blocking(move || {
                Self::client_for_cancellable(&config_for_build, &spec_for_build, Some(&cancel_for_build))
            });
            let built = tokio::select! {
                joined = handle => match joined {
                    Ok(result) => result,
                    Err(join) => Err(anyhow::anyhow!("building client for {spec:?} panicked: {join}")),
                },
                _ = control.cancelled() => {
                    // Cancelled mid-build: set the build-local token so the
                    // still-running blocking build observes it, kills its
                    // key-command child, and unblocks — even though we drop its
                    // handle here and the next turn will reset the turn-wide
                    // cancel flag. Then stop waiting and abort the switch rather
                    // than install a client for a turn the user just cancelled.
                    // The request has been consumed, so it will not fire into
                    // the next turn. Signal the caller to stop before its next
                    // model call.
                    build_cancel.store(true, Ordering::SeqCst);
                    return true;
                }
                _ = control.model_request_changed(model_rx) => {
                    // A newer `/model` request superseded this spec while it was
                    // still building. Cancel the stale build (its key-command
                    // child is killed via the build-local token) and loop at once
                    // to build the newest spec, instead of waiting out a slow or
                    // hung build for a spec that is already outdated.
                    build_cancel.store(true, Ordering::SeqCst);
                    continue;
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
            // client for a turn the user just cancelled. Signal the caller to
            // stop before its next model call.
            if self.control.is_cancelled() {
                return true;
            }
            match built {
                Ok(client) => {
                    self.client = client;
                    self.config.model = spec.clone();
                    self.calibration = None;
                    self.learned_window = None;
                    self.learned_max_output = None;
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
            return false;
        }
    }

    /// Ask the endpoint for the model's context window (unless config sets
    /// it) and the thinking levels and vision capability it supports. All are
    /// probed together so a server whose detections read the same response
    /// (OpenAI-compatible `/models`, llama.cpp `/props`, Ollama `/api/show`)
    /// is not queried several times serially.
    pub async fn detect_context_window(&mut self) {
        // Bump the generation so any in-flight background probe from an earlier
        // mid-turn switch (see `detect_context_window_for_switch`) is discarded
        // and cannot overwrite what this blocking detect establishes.
        self.detect_generation.fetch_add(1, Ordering::SeqCst);
        *self.detected_window.lock().unwrap() = None;
        *self.reported_max_output.lock().unwrap() = None;
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
        let (window, thinking, vision, max_output) =
            tokio::time::timeout(DETECT_TIMEOUT, probe).await.ok().unwrap_or_default();
        // Capture the published output limit separately so it survives even
        // when the detected window is `None` (an entry can publish an output
        // cap with no recognized window field) or when a later configured
        // window clears the detected window (issue #114). Fall back to the
        // window's own cap when the probe returns none independently.
        *self.reported_max_output.lock().unwrap() =
            max_output.or_else(|| window.as_ref().and_then(|w| w.max_output_tokens));
        *self.detected_window.lock().unwrap() = window;
        *self.reported_thinking.lock().unwrap() = thinking;
        // Vision is derived from the same probe responses `detect_capabilities`
        // already fetched, so it costs no extra round trip. Storing the report
        // is always the right move: a `vision = false` override discards it at
        // resolution time, but `true`/none keep it (`true` forces the capability
        // on yet preserves the endpoint's reported limits), so keeping it here
        // lets `resolve` apply those limits on the default path too.
        *self.reported_vision.lock().unwrap() = vision;
        self.refresh_stats();
    }

    /// Probe the thinking levels *and* vision capability together, leaving the
    /// (already cleared) detected window alone. Used when the window comes from
    /// config and the window half of the combined probe would be discarded
    /// anyway.
    ///
    /// Thinking and vision are derived from one shared endpoint response
    /// (llama.cpp `/props`, Ollama `/api/show`, Copilot `/models`), so probing
    /// them together fetches it once instead of running two serial probes — and
    /// waiting through two probe budgets — at startup or on a model switch.
    /// Storing the vision report unconditionally is correct: a `vision = false`
    /// override discards it at resolution time, while `true`/none keep it
    /// (`true` forces the capability on yet preserves the endpoint's reported
    /// limits), mirroring `detect_context_window` on the default path.
    async fn detect_thinking(&mut self) {
        let probe = self.client.detect_thinking_and_vision();
        let (thinking, vision, max_output) = tokio::time::timeout(DETECT_TIMEOUT, probe).await.ok().unwrap_or_default();
        *self.reported_thinking.lock().unwrap() = thinking;
        *self.reported_vision.lock().unwrap() = vision;
        // The output limit is a separate budget from the window, so keep it even
        // though the configured window wins over the probed one (issue #114).
        *self.reported_max_output.lock().unwrap() = max_output;
        self.refresh_stats();
    }

    /// The effective vision capability for the current model: a configured
    /// `vision` override wins, else the endpoint report, else the built-in
    /// assumption for current Anthropic / OpenAI families. `None` = the model
    /// cannot view images.
    pub fn vision(&self) -> Option<crate::vision::Vision> {
        let (user, _default_provider) = self.config.effective_providers();
        let providers = providers::effective_providers(&user);
        let mut provider = providers.get(self.provider_name()).cloned().unwrap_or_default();
        // First-party host detection must track the client actually in use, not
        // the possibly-edited config: after a provider edit whose client
        // rebuild fails, the saved config holds the new `base_url` while the
        // session keeps the old client. Mirror how `kind`/`model_name` already
        // come from the live client by overriding `base_url` with its captured
        // endpoint when it exposes one (`None` only for test doubles, where the
        // configured `base_url` is the right fallback).
        if let Some(endpoint) = self.client.endpoint() {
            provider.base_url = Some(endpoint.to_string());
        }
        crate::vision::resolve(
            self.config.vision,
            self.client.kind(),
            &provider,
            self.model_name(),
            self.reported_vision.lock().unwrap().as_ref(),
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
    /// attachments directory, and returned as `(text, attachments)` — the
    /// decode/resize/encode span runs on a blocking thread (see
    /// [`Self::prepare_image_attachment`]) so it never stalls the async runtime.
    async fn image_result(&self, result: &Value) -> Result<Option<(String, Vec<crate::llm::Attachment>)>, String> {
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
        let limits = vision.image_limits();
        let attachments_dir = self.attachments_dir();
        // Reading the source, decoding/resizing/re-encoding it to the model's
        // limits, hashing, and storing it are CPU- and I/O-heavy — precisely the
        // large-image path. Running them inline on the Tokio worker would block
        // the runtime for a substantial period, stalling every other session,
        // cancellation, and I/O task, even though ordinary tool handlers already
        // go through `execute_blocking`. Offload the whole span to a blocking
        // thread; only the cheap capability gating above stays on the runtime.
        tokio::task::spawn_blocking(move || Self::prepare_image_attachment(path, &limits, &attachments_dir))
            .await
            .map_err(|e| format!("image processing task failed: {e}"))?
    }

    /// The blocking span of [`Self::image_result`], run on a blocking thread:
    /// re-read the source by `path` (rather than carrying its base64 through the
    /// tool result, which would cost several times its file size before
    /// `prepare` reduces it), downscale/re-encode it to `limits`, store the
    /// prepared bytes by hash under `attachments_dir`, record the source as read
    /// (so a later `write_file`/`edit_file` on this path passes the freshness
    /// gate, exactly as a successful text read does), and return the tool-result
    /// text plus the attachment. Reached only once vision is on, so it never
    /// authorizes a write for a model that cannot view the image.
    fn prepare_image_attachment(
        path: std::path::PathBuf,
        limits: &crate::attachment::ImageLimits,
        attachments_dir: &std::path::Path,
    ) -> Result<Option<(String, Vec<crate::llm::Attachment>)>, String> {
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(e) => return Err(format!("{}: could not read image: {e}", path.display())),
        };
        let Some(format) = crate::attachment::ImageFormat::sniff(&bytes) else {
            return Err(format!("{}: unrecognised image data", path.display()));
        };
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
        if let Err(e) = crate::attachment::store(attachments_dir, &attachment, &prepared.bytes) {
            return Err(format!("{}: could not store image: {e}", path.display()));
        }
        crate::files::mark_image_read(&path, &bytes);
        let text = format!(
            "{}, {}×{}, {}",
            attachment.media_type,
            attachment.width,
            attachment.height,
            crate::context::format_bytes(attachment.bytes)
        );
        Ok(Some((text, vec![attachment])))
    }

    /// Window (and thinking-level / vision) detection after a mid-turn
    /// `/model` switch (see `apply_model_request`). Unlike [`Agent::detect_context_window`] this
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
        // The previous model's reports must not leak onto the new one; until
        // the background probe lands, the built-in assumptions apply.
        *self.reported_thinking.lock().unwrap() = None;
        *self.reported_vision.lock().unwrap() = None;
        *self.reported_max_output.lock().unwrap() = None;
        // Publish the new model's fallback stats (provider/model name + the
        // model-name or default window) right away, so a slow or `None` probe
        // cannot leave the UI on the previous model's window.
        self.refresh_stats();
        // A configured window is authoritative, so only the thinking levels
        // and vision are probed then (see `detect_thinking`).
        let configured = self.configured_window().is_some();
        let probe = self.client.clone_boxed();
        let slots = DetectSlots {
            window: self.detected_window.clone(),
            thinking: self.reported_thinking.clone(),
            vision: self.reported_vision.clone(),
            max_output: self.reported_max_output.clone(),
        };
        let sink = self.event_sink.clone();
        let stats = self.stats.clone();
        let current = self.detect_generation.clone();
        tokio::spawn(async move {
            let (detected, thinking, vision, max_output) = if configured {
                let (thinking, vision, max_output) =
                    tokio::time::timeout(DETECT_TIMEOUT, probe.detect_thinking_and_vision())
                        .await
                        .ok()
                        .unwrap_or_default();
                (None, thinking, vision, max_output)
            } else {
                let (window, thinking, vision, probed_max_output) =
                    tokio::time::timeout(DETECT_TIMEOUT, probe.detect_capabilities()).await.ok().unwrap_or_default();
                // Carry the published output limit forward separately: it
                // survives even when the detected window is `None` (an entry
                // can publish an output cap with no window field), falling back
                // to the window's own cap when the probe returns none (issue #114).
                let max_output = probed_max_output.or_else(|| window.as_ref().and_then(|w| w.max_output_tokens));
                (window, thinking, vision, max_output)
            };
            Self::finish_detect(
                Detected { window: detected, thinking, vision, max_output },
                generation,
                current,
                slots,
                sink,
                stats,
            );
        });
    }

    /// Publish a finished background probe's result: store the window (and
    /// the thinking-level / vision reports) and
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
        detected: Detected,
        generation: u64,
        current: std::sync::Arc<std::sync::atomic::AtomicU64>,
        slots: DetectSlots,
        sink: Option<EventSink>,
        stats: SharedStats,
    ) {
        let Detected { window: detected, thinking, vision, max_output } = detected;
        {
            // Check the generation under the window slot lock so a switch
            // racing this completion either bumps it before we read (we
            // discard) or clears the slots after we write (it then refreshes to
            // its own fallback). The window lock is held while the thinking
            // and vision reports are written too, so all three land together.
            let mut slot = slots.window.lock().unwrap();
            if current.load(Ordering::SeqCst) != generation {
                return;
            }
            *slots.thinking.lock().unwrap() = thinking;
            *slots.vision.lock().unwrap() = vision;
            // Published output limit lands with the rest; kept even when the
            // window slot stays empty (configured-window path) (issue #114).
            *slots.max_output.lock().unwrap() = max_output;
            if let Some(detected) = &detected {
                *slot = Some(detected.clone());
            }
        }
        let Some(detected) = detected else {
            if let Some(sink) = sink {
                sink(None, &AgentEvent::Context);
            }
            return;
        };
        let (window, source) = (detected.tokens, format!("reported by the endpoint ({})", detected.source));
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
                // *stricter* (smaller-or-equal) limit must replace it: the slot
                // already holds the detected window, and
                // `context_window_with_source()` prefers the detected value
                // whenever `learned < detected` is false — equality included.
                // Refusing on equality would leave `/context` and the status
                // line reporting "learned" while the agent internally uses the
                // endpoint source, so allow equality here too.
                || (stats.window_source == "learned from a context-overflow error" && window <= stats.window)
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
            && let Some(detected) = self.detected_window.lock().unwrap().as_ref()
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
        let advertised = self.detected_window.lock().unwrap().as_ref().and_then(|d| d.total_tokens);
        match (advertised, self.learned_window) {
            (Some(advertised), Some(learned)) => Some(advertised.min(learned)),
            (Some(advertised), None) => Some(advertised),
            (None, Some(learned)) => Some(learned),
            (None, None) => None,
        }
    }

    /// Forward-replay the in-flight output-limit continuation state for a turn
    /// being recovered after a crash, converging on the same `(answer, count)`
    /// the live loop held when it was interrupted (issue #114).
    ///
    /// Starts from `snapshot` — the answer text + continuation count persisted
    /// into a mid-turn compaction's `Replace` record, or empty when no
    /// compaction intervened — and walks `tail`, the turn's messages logged
    /// *after* that snapshot, in forward order:
    ///
    /// - a *continuation reminder* (`continuation`) counts one scheduled
    ///   continuation: the budget tracks scheduled reminders, matching the live
    ///   loop (which increments the count *before* pushing the reminder), not
    ///   truncated replies — the two diverge when the crash lands after a
    ///   truncated chunk but before its reminder is logged;
    /// - any *other* user message (a steer, a Stop-hook re-prompt, the restated
    ///   pending input) begins a new answer segment, so the accumulated prefix
    ///   resets;
    /// - a length-truncated plain assistant chunk extends the answer;
    /// - any other assistant message (a tool call, or a clean reply) and any
    ///   tool result begins a new segment, so the prefix resets (its tool-call
    ///   markup must never leak into the text answer).
    ///
    /// The count is turn-wide — a tool run clears the answer accumulator but
    /// still spends the budget — so it is only ever incremented, never reset;
    /// only the answer text resets at a segment boundary.
    fn replay_continuation(snapshot: Option<(String, usize)>, tail: &[Message]) -> (String, usize) {
        let (mut answer, mut count) = snapshot.unwrap_or_default();
        for msg in tail {
            match msg.role {
                Role::User if msg.continuation => count += 1,
                // A fired timer or pending-timer nudge is a harness-injected
                // user message delivered mid-turn, NOT a new answer segment:
                // the truncated answer it interrupts is still the one being
                // continued, so keep its prefix and do not count the message as
                // a continuation attempt (issue #150). A genuine steer or a
                // Stop-hook re-prompt (`auto_initiated` but not `timer`) stays a
                // segment reset via the arm below, since those discard the
                // cut-off prefix.
                Role::User if msg.timer => {}
                Role::User => answer.clear(),
                Role::Assistant
                    if msg.tool_calls.is_empty() && crate::llm::stop_reason_is_length(msg.stop_reason.as_deref()) =>
                {
                    answer.push_str(&msg.content);
                }
                Role::Assistant | Role::Tool => answer.clear(),
                Role::System => {}
            }
        }
        (answer, count)
    }

    /// Mirror the live output-limit continuation state into the pending input,
    /// so a mid-turn compaction captures it into the durable `Replace` record
    /// and a post-compaction crash still restores the answer prefix and the
    /// turn-wide count (issue #114). Cleared (`None`) when no continuation is
    /// in flight.
    fn sync_pending_continuation(&mut self, continued_answer: &str, truncated_continuations: usize) {
        // Snapshot the current conversation length before the `&mut` borrow:
        // it is the new replay boundary (see below).
        let boundary = self.conversation.len();
        if let Some(pending) = self.pending_input.as_mut() {
            pending.continuation = (!continued_answer.is_empty() || truncated_continuations > 0)
                .then(|| (continued_answer.to_string(), truncated_continuations));
            // Advance the replay boundary in lockstep with the snapshot. The
            // snapshot now accounts for *every* message logged so far, so a
            // same-Agent retry (a provider error leaves the turn pending and the
            // same input id is re-run on this live Agent) must replay only the
            // messages logged *after* this point. Leaving the boundary stale
            // would re-replay chunks and reminders already folded into the
            // snapshot — duplicating the answer prefix and double-counting the
            // continuation budget (issue #114).
            pending.continuation_base = Some(boundary);
        }
    }

    /// The base `max_tokens` for the next request before the context-window
    /// clamp: an explicit configured value overrides everything; otherwise the
    /// model's own published output limit (from the endpoint's capabilities),
    /// falling back to a large built-in value when none is published (issue
    /// #114). Never the old arbitrary 4096 default, which cut long replies off.
    fn output_token_base(&self) -> i64 {
        let base = self.output_token_base_uncapped();
        // A cap learned from an earlier output-limit rejection is an observed
        // hard ceiling for this model; never send above it, even over a
        // configured value, so the request stays valid until the model changes
        // (issue #114).
        match self.learned_max_output {
            Some(cap) => base.min(cap as i64),
            None => base,
        }
    }

    /// `output_token_base` before the learned-cap clamp.
    fn output_token_base_uncapped(&self) -> i64 {
        let configured = self.config.max_tokens;
        if configured > 0 {
            return i64::from(configured);
        }
        if let Some(limit) = self.detected_max_output() {
            return limit as i64;
        }
        // No endpoint-published limit: before the large unknown-model fallback,
        // honour a known output cap for this model (e.g. native OpenAI
        // `gpt-4o-mini`, whose 16,384 cap `/models` does not expose). Sending
        // the 32,768 fallback to such a model with a short prompt would exceed
        // its real cap and be rejected (issue #114). Check the live client's
        // model name as well as the configured one so a `/model` switch counts.
        if let Some(limit) = context::output_limit_for_model(&self.config.model)
            .or_else(|| context::output_limit_for_model(self.client.model_name()))
        {
            return limit as i64;
        }
        DEFAULT_MAX_OUTPUT_TOKENS
    }

    /// The model's own maximum output tokens as reported by the endpoint's
    /// capabilities probe, if any. `None` when unconfigured and unpublished.
    /// Read from the standalone report (populated on *both* the default and the
    /// configured-window probe paths), falling back to the detected window's
    /// copy, so a configured context window never suppresses the discovered
    /// output limit (issue #114).
    fn detected_max_output(&self) -> Option<usize> {
        // Copy the reported value out so its guard is released *before* locking
        // `detected_window`. `finish_detect` takes these locks in the opposite
        // order — window first, then `max_output` — so holding the report guard
        // across the window lock here inverts that order and can deadlock a
        // background model-switch probe when the report is still `None`
        // (issue #114).
        let reported = *self.reported_max_output.lock().unwrap();
        reported.or_else(|| self.detected_window.lock().unwrap().as_ref().and_then(|d| d.max_output_tokens))
    }

    /// The effective `max_tokens` the next request would send before the
    /// context-window clamp: the configured override, else the model's own
    /// published output limit, else the built-in fallback. For display and ACP
    /// reporting (the raw `config.max_tokens` is `0` when unset).
    pub fn effective_max_tokens(&self) -> i64 {
        self.output_token_base()
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
        // Mirror the vision wire plan: only the newest `max_images` attachments
        // are sent as images, older ones as text placeholders. Charging every
        // historical image its full token cost overcounts the real payload and
        // can trip auto-compaction before the window is actually full.
        let max_images = self.vision().map(|v| v.max_images).unwrap_or(0);
        // Which stored attachments are still intact on disk, hashed once and
        // shared across the slices below. The wire plan sends only *available*
        // images, so the estimate must charge availability the same way: a
        // missing/tampered newest reference is a placeholder, not an image slot,
        // and the older image the wire backfills in its place carries the full
        // image cost. Ignoring availability undercounts a resumed, image-heavy
        // request by thousands of tokens and delays compaction past the limit.
        let available = context::available_attachments(&self.conversation, Some(&self.attachments_dir()));
        if let Some((len, tokens)) = self.calibration
            && len <= self.conversation.len()
        {
            let (prefix, suffix) = self.conversation.split_at(len);
            // The calibrated `tokens` baked in the prefix's newest `max_images`
            // *available* attachments at full image cost. A post-anchor (suffix)
            // available attachment claims a newest-`max_images` slot and displaces
            // an older prefix image into a text placeholder on the wire — but the
            // anchor still carries that stale full-image cost while the suffix adds
            // the new image on top, double-charging past the quota. That
            // overestimate can trip auto-compaction early and shrink `max_tokens`.
            // The anchor is only valid while no prefix image is displaced;
            // otherwise fall through to a full recompute that mirrors the current
            // wire plan. Only *available* attachments claim image slots, so the
            // displacement check counts availability, not raw occurrences — a
            // missing suffix reference cannot displace a prefix image.
            let count_available = |msgs: &[Message]| {
                msgs.iter()
                    .flat_map(|m| m.attachments.iter())
                    .filter(|a| available.contains(&(*a as *const crate::llm::Attachment)))
                    .count()
            };
            let prefix_attachments = count_available(prefix);
            let suffix_attachments = count_available(suffix);
            let prefix_images = prefix_attachments.min(max_images);
            let prefix_images_after = prefix_attachments.min(max_images.saturating_sub(suffix_attachments));
            if prefix_images == prefix_images_after {
                return (tokens + context::messages_tokens_with_vision(suffix, max_images, &available), true);
            }
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
        (context::messages_tokens_with_vision(&self.conversation, max_images, &available) + tools, false)
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
            let (window, window_source) = self.context_window_with_source();
            stats.window = window;
            stats.window_source = window_source;
            stats.messages = self.conversation.len();
            stats.auto_compact = self.config.auto_compact.then_some(self.config.auto_compact_threshold);
            stats.smart_compact = self.config.compaction_mode == CompactionMode::Smart && self.session.is_some();
            stats.history_available = self.history_tools_enabled();
            stats.plan = (!self.plan.items.is_empty()).then(|| self.plan.progress());
            stats.timers = (!self.timers.is_empty()).then(|| self.timers.status_segment());
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

    /// Pull any queued steer messages into the conversation. Returns whether at
    /// least one steer was absorbed, so the caller can reset the output-limit
    /// continuation accumulator: an absorbed steer begins a new answer segment,
    /// and the discarded cut-off prefix must not be carried into the revised
    /// answer (issue #114).
    fn absorb_steers(&mut self) -> Result<bool> {
        let mut absorbed = false;
        for steer in self.control.take_pending() {
            self.push(Message::user(&steer.text))?;
            self.emit(AgentEvent::UserMessage { text: &steer.text });
            self.control.inner.absorbed.lock().unwrap().push(steer);
            absorbed = true;
        }
        // Timers fire at the start of a step, after the steers: their notes
        // land as a user message the next model call sees. A fired timer is
        // not a steer, so it does not reset the continuation accumulator.
        //
        // Skip the whole timer step when timers are disabled (an ACP-resumed
        // CLI session has no idle loop and `disable_timers()` has hidden
        // `timer_done`/`timer_cancel`): firing a restored timer or nudging here
        // would ask the agent to acknowledge a timer it has no tool to clear,
        // and would consume the restored state a later CLI resume still needs.
        if !self.timers_enabled {
            return Ok(absorbed);
        }
        let fired = self.fire_due_timers()?;
        // Fired timers stay `pending` until the agent calls `timer_done`.
        // Nudge about them every few steps so a note ignored mid-work is not
        // forgotten; the counter resets when a timer fires or nothing pends.
        if fired {
            self.pending_timer_steps = 0;
        } else if self.timers.has_pending() {
            self.pending_timer_steps += 1;
            if self.pending_timer_steps.is_multiple_of(timers::PENDING_NUDGE_EVERY)
                && let Some(note) = self.timers.pending_nudge(self.timers_now())
            {
                self.push(Message::user(&reminders::wrap(&note)).timer())?;
            }
        } else {
            self.pending_timer_steps = 0;
        }
        Ok(absorbed)
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
                // Mirror the live path's display output so a resumed ACP /
                // trajectory client still sees each persisted attachment's
                // `[image: path, WxH]` marker, not the bare model-facing text.
                let output = tool_result_display(&message.content, &message.attachments);
                self.emit(AgentEvent::ToolResult { call, ok, output: &output });
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

    /// Slot the bash tool publishes each call's spilled-capture identities
    /// into, so the loop detector reads them out of band (issue #65).
    pub fn spill_digests_handle(&self) -> Arc<std::sync::Mutex<Vec<output::Spill>>> {
        self.spill_digests.clone()
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
        self.completed_stop_reasons.clear();
        self.pending_input = None;
        self.plan = Plan::default();
        // A fresh session starts with no timers (`/restart` clears them).
        self.timers = Timers::default();
        self.control.publish_timers(&self.timers);
        self.pending_timer_steps = 0;
        self.reminders = Reminders::new(self.config.outcome_tool);
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
        self.completed_stop_reasons = restored.stop_reasons;
        self.pending_input = restored.pending_input;
        self.plan = restored.plan.unwrap_or_default();
        // Restore the session's timers; one that came due while nano-coder was
        // closed fires as overdue at the next step (or the idle prompt).
        self.timers = restored.timers.unwrap_or_default();
        self.control.publish_timers(&self.timers);
        self.pending_timer_steps = 0;
        // Reminders belong to the session being left (`/resume` mid-process).
        self.reminders = Reminders::new(self.config.outcome_tool);
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
                // Persist the surviving pending input's in-flight continuation
                // state: the truncated chunks it was built from may be folded
                // into the summary, so without this a post-compaction crash
                // loses the answer prefix and resets the count (issue #114).
                continuation: self.pending_input.as_ref().and_then(|p| p.continuation.clone()),
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
            (Some(pending), Some(position)) => {
                Some(PendingInput { position, continuation_base: Some(self.conversation.len()), ..pending })
            }
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
        #[cfg(test)]
        if std::mem::take(&mut self.fail_next_persist) {
            return Err(anyhow::anyhow!("forced plan persist failure (test)"));
        }
        if let Some(log) = &mut self.session {
            log.append(&Record::Plan { plan: self.plan.clone(), recorded_at: session::now() })?;
        }
        Ok(())
    }

    fn plan_changed(&mut self) -> Result<()> {
        // Persist first: a failed append must leave no observable side effect
        // (reminder reset, UI event) so `run_plan_tool` can cleanly roll the
        // live plan back.
        self.record_plan()?;
        self.reminders.plan_changed();
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
        if self.timers_enabled {
            tools.extend(timers::definitions());
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
            let stop_reason = self.completed_stop_reasons.get(id).copied().unwrap_or(StopReason::EndTurn);
            return Ok(TurnOutcome {
                response: response.clone(),
                stop_reason,
                outcome: self.completed_outcomes.get(id).cloned(),
            });
        }
        self.control.start_turn();
        self.reminders.start_turn();
        // Consume the automatic-turn origin for this turn (an automatic timer
        // wakeup/nudge): the main user message pushed below is marked
        // `auto_initiated` so it bills as agent-initiated. Taken once here so it
        // never leaks into the next, genuinely user-initiated turn.
        let auto_turn = std::mem::take(&mut self.auto_turn);
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
        // Where a resumed turn's input sits, so after the replay shortcuts
        // below we can rebuild any in-flight output-limit continuation state
        // from the messages logged before the interrupt (issue #114).
        let resume_position = resuming.as_ref().map(|pending| pending.position);
        // The continuation state persisted with the pending input (captured
        // into the `Replace` record at compaction time), extracted before the
        // `match resuming` below moves it. A mid-turn compaction folds the
        // truncated chunks into the summary, so this — not the conversation
        // tail — is where a post-compaction crash recovers them (issue #114).
        let persisted_continuation = resuming.as_ref().and_then(|pending| pending.continuation.clone());
        // The compaction boundary persisted with the pending input: the index
        // past the folded, summarized messages, so recovery replays only the
        // chunks logged *after* it over `persisted_continuation` (issue #114).
        // `None` when no compaction intervened — recovery then replays from the
        // input position with an empty snapshot.
        let resume_continuation_base = resuming.as_ref().and_then(|pending| pending.continuation_base);
        // Set to the conversation length just before a resume `SessionStart`
        // hook's context message is appended, so the continuation scan reads
        // the persisted turn tail rather than that freshly added context.
        let mut hook_context_start: Option<usize> = None;
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
                        // A length-truncated final assistant message is NOT a
                        // finished turn: its continuation was cut off by the
                        // interrupt, so fall through and resume the turn (the
                        // seeding below rebuilds the partial answer) instead of
                        // replaying it as a clean `EndTurn` (issue #114).
                        && !crate::llm::stop_reason_is_length(m.stop_reason.as_deref())
                }) {
                    // The final answer was recorded but the turn end was not.
                    // Rebuild the *whole* answer, not just the final chunk: a
                    // crash can land after the clean continuation that follows
                    // one or more length-truncated chunks, and replaying only
                    // `last.content` would permanently record the tail and drop
                    // the earlier prefix (issue #114). Replay the continuation
                    // chunks logged before this final chunk over any persisted
                    // snapshot — starting at the compaction boundary when a
                    // mid-turn compaction folded earlier chunks into the
                    // summary — then append the final clean chunk.
                    let end = self.conversation.len() - 1;
                    let boundary = pending.continuation_base.unwrap_or(pending.position).min(end);
                    let (prefix, _) =
                        Self::replay_continuation(pending.continuation.clone(), &self.conversation[boundary..end]);
                    let response = format!("{prefix}{}", last.content);
                    let outcome = Outcome::reported_in(&self.conversation[pending.position..]);
                    return self.finish_turn(input_id, response, outcome, StopReason::EndTurn).map(end_turn);
                } else if self.config.outcome_tool
                    && self.conversation.last().is_some_and(|m| m.role == Role::Tool)
                    && let Some(outcome) = Outcome::reported_in(&self.conversation[pending.position..])
                {
                    // The outcome was reported but the answer it implies was not recorded.
                    let response = outcome.response();
                    self.push(Message::assistant(&response))?;
                    return self.finish_turn(input_id, response, Some(outcome), StopReason::EndTurn).map(end_turn);
                }
                if let Some(ctx) = self.take_session_start_context() {
                    // Remember where the resume `SessionStart` hook context
                    // lands: it is appended *after* the persisted turn tail, so
                    // the continuation scan below must look at the messages
                    // logged *before* this point, not the conversation's new
                    // tail (issue #114).
                    hook_context_start = Some(self.conversation.len());
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
                            continuation: None,
                            continuation_base: None,
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
                        return self.finish_turn(input_id, reason, None, StopReason::EndTurn).map(end_turn);
                    }
                    ClaudePromptHook::Proceed(extra) => extra,
                };
                self.pending_input = Some(PendingInput {
                    id: input_id.clone(),
                    text: user_input.to_string(),
                    position: self.conversation.len(),
                    continuation: None,
                    continuation_base: None,
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
                let message = Message::user(&message);
                let message = if auto_turn { message.auto_initiated() } else { message };
                self.push(message)?;
            }
        }

        // Trigger after_context_load hook
        let ctx =
            HookContext::new(HookEvent::AfterContextLoad).with_data("message_count", json!(self.conversation.len()));
        self.hooks.trigger(&ctx);

        // A cap of 0 is unbounded.
        let max_iterations = self.config.max_iterations;
        // …except in a headless session, where no human can stop a runaway:
        // 0 (and Auto mode) fall back to a finite safety cap (issue #65). This
        // is re-evaluated from the *live* mode each iteration (below), not
        // snapshotted here, so a mid-turn mode switch (Normal ⇄ Auto) moves the
        // safety cap with it instead of leaving the Auto branch unbounded.
        let headless = !self.questions.is_interactive();
        let mut final_response = None;
        let mut last_content = String::new();
        let mut cancelled = false;
        let mut reported: Option<Outcome> = None;
        // How many times this turn re-prompted a reply cut off at the output
        // limit, and whether it ultimately gave up on one (so the turn ends
        // `MaxTokens`, not a clean `EndTurn`).
        let mut truncated_continuations = 0usize;
        let mut max_tokens_hit = false;
        // Contiguous answer text carried across output-limit continuations, so
        // the final response is the *whole* reply, not just its last chunk. A
        // reply cut off at the limit is pushed, re-prompted, and continued in a
        // fresh assistant message; `final_response` (legacy quiet mode, ACP)
        // would otherwise show only the tail. Accumulated only across length
        // cut-offs and reset whenever a new answer segment begins — a steer, a
        // Stop-hook re-prompt, or any tool run (whose dropped tool-call markup
        // must not leak into the text answer) (issue #114).
        let mut continued_answer = String::new();

        // Rebuild in-flight output-limit continuation state after a resume
        // (issue #114). A turn cut off mid-continuation has already logged one
        // or more length-truncated assistant chunks (each followed by an
        // auto-initiated continuation reminder). Without this, the resumed turn
        // starts with an empty `continued_answer` and a zero continuation
        // count, so the earlier chunks are dropped from the final answer and the
        // re-prompt budget resets. Scan the trailing run of truncated assistant
        // messages logged before the interrupt, seed the accumulator and count
        // from them, and — if the turn was cut off before the last chunk's
        // continuation reminder was logged — re-push that reminder so the model
        // actually continues.
        if let Some(start) = resume_position.filter(|&s| s <= self.conversation.len()) {
            // Read the persisted turn tail, stopping before any resume
            // `SessionStart` hook context appended above: that fresh message is
            // not part of the interrupted turn, and scanning into it would stop
            // the reconstruction at the hook boundary (issue #114).
            let scan_end = hook_context_start.unwrap_or(self.conversation.len()).max(start);
            // Replay from the compaction boundary over the persisted snapshot
            // when a mid-turn compaction folded the earlier chunks into the
            // summary; otherwise from the input position over an empty snapshot
            // (a crash with no intervening compaction). A single forward replay
            // reconstructs both the answer prefix and the turn-wide count, and —
            // crucially — also walks the messages logged *after* the compaction
            // (additional chunks, a segment reset), which the snapshot alone
            // does not capture (issue #114).
            let boundary = resume_continuation_base.unwrap_or(start).clamp(start, scan_end);
            let (answer, count) =
                Self::replay_continuation(persisted_continuation, &self.conversation[boundary..scan_end]);
            continued_answer = answer;
            truncated_continuations = count;
            // Whether the turn's last logged message is a length-truncated
            // chunk whose continuation reminder was never logged (the crash
            // landed before it). A property of the real conversation tail,
            // independent of the compaction boundary: the budget-spending chunk
            // may itself sit inside the folded, pre-boundary region (issue
            // #114).
            let last_is_truncated_assistant = self.conversation[start..scan_end].last().is_some_and(|m| {
                m.role == Role::Assistant
                    && m.tool_calls.is_empty()
                    && crate::llm::stop_reason_is_length(m.stop_reason.as_deref())
            });
            // Re-push the continuation reminder only when the interrupt cut the
            // turn off before logging it AND the budget still has room: a crash
            // after the budget-spending chunk must not send one more request
            // that would push the turn past the cap (it ends `MaxTokens`
            // instead) (issue #114).
            if last_is_truncated_assistant && truncated_continuations < MAX_TRUNCATED_CONTINUATIONS {
                self.push(Message::user(&reminders::wrap(&truncated_continuation_note(0))).continuation())?;
            }
            // Mirror the restored state back into the pending input so a later
            // mid-turn compaction captures it (issue #114).
            self.sync_pending_continuation(&continued_answer, truncated_continuations);

            // A crash after the budget-spending chunk (count already at the
            // cap) but before `TurnEnd` leaves a turn that must NOT call the
            // model again: the reminder guard above suppresses the re-prompt,
            // but the request loop would still run and a clean reply would be
            // recorded `EndTurn`, hiding that the answer was cut off. Finish
            // the recovered turn here as `MaxTokens`, preserving the
            // accumulated answer (issue #114).
            if last_is_truncated_assistant && truncated_continuations >= MAX_TRUNCATED_CONTINUATIONS {
                let response = continued_answer.clone();
                let outcome = Outcome::reported_in(&self.conversation[start..]);
                let (response, outcome) = self.finish_turn(input_id, response, outcome, StopReason::MaxTokens)?;
                return Ok(TurnOutcome { response, stop_reason: StopReason::MaxTokens, outcome });
            }
        }

        // "keep going". Auto mode disables it (interactive only); normal mode
        // asks (interactive only); ACP/headless keeps the hard stop.
        // Re-evaluated from the live mode each iteration so a mid-turn
        // Shift+Tab changes cap behavior too.
        let mut granted_extra = 0usize;
        let mut iteration = 0usize;
        // Set by the loop detector when the turn must end blocked (issue #65).
        let mut loop_stop: Option<String> = None;
        loop {
            iteration += 1;
            // Snapshot the live mode *once* per iteration and derive every
            // cap decision from it. `TurnControl::mode` can change mid-turn
            // (Shift+Tab), and reading it twice — once for `headless_cap` and
            // again inside the `budget` match — let a concurrent Normal⇄Auto
            // switch make the two describe different modes, so `headless_cap`
            // could be `false` while the `budget` match still took the
            // unbounded Auto branch and slipped a call past the promised
            // safety cap (issue #65).
            let mode = self.control.mode();
            let headless_cap = headless && (max_iterations == 0 || mode == crate::mode::AgentMode::Auto);
            let budget = match (mode, max_iterations) {
                _ if headless_cap => HEADLESS_SAFETY_CAP.saturating_add(granted_extra),
                (crate::mode::AgentMode::Auto, _) | (_, 0) => usize::MAX,
                _ => max_iterations.saturating_add(granted_extra),
            };
            if iteration > budget {
                // Cap reached. Only normal mode in an interactive session asks
                // to continue; anything else (auto, ACP/headless) stops.
                let can_prompt = mode == crate::mode::AgentMode::Normal && self.questions.is_interactive();
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
            if self.absorb_steers()? {
                // A steer absorbed here begins a new answer segment, like a
                // tool run or a Stop-hook re-prompt: drop any accumulated
                // output-limit continuation prefix so the revised answer is not
                // prefixed by the discarded cut-off chunk. The turn-wide
                // continuation budget is retained — the steer does not refund a
                // spent cut-off (issue #114).
                continued_answer.clear();
                self.sync_pending_continuation(&continued_answer, truncated_continuations);
            }
            // A `/model <spec>` typed mid-turn applies here, so the request
            // built below goes to the new model. If the turn was cancelled
            // while the switch was building, stop before the threshold
            // compaction or chat call below — otherwise one call could still
            // land on the old model after the user cancelled.
            if self.apply_model_request().await {
                cancelled = true;
                break;
            }

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
                // The threshold compaction is itself a model call; `compact_logged`
                // applies any `/model` queued since the top of the iteration
                // before summarizing, so the summary never goes out on the model
                // the user just switched away from.
                self.compact_logged(CompactTrigger::Threshold, self.config.compaction_mode, None).await?;
                if self.control.is_cancelled() {
                    cancelled = true;
                    break;
                }
            }

            let mut overflow_retried = false;
            // Whether this attempt already retried after learning the model's
            // real output-token cap from a rejection (issue #114); bounds the
            // retry to one so a persistent rejection still surfaces.
            let mut max_output_retried = false;
            // Reset per attempt, so the recorded duration is the request that
            // produced the response, not earlier overflowed attempts. Seeded so
            // an early cancel break (before the first attempt sets it) leaves it
            // defined; that path discards the response and never reads it.
            let mut request_started = Instant::now();
            // The values of the attempt that produced the response, carried
            // out of the retry loop for the trajectory. Re-resolved per
            // attempt (below), so these are what the successful request
            // actually sent, not a stale pre-compaction resolution.
            let mut sent_temperature = None;
            let mut sent_thinking = None;
            // Re-sends after a mid-reply connection drop (`StreamInterrupted`),
            // capped per model call so a persistently broken connection still
            // ends the turn instead of asking forever.
            let mut stream_restarts: u32 = 0;
            let response = loop {
                self.set_activity(Activity::Thinking);
                // Every attempt is a model call (and the overflow branch below
                // compacts with one more), so a `/model` queued while the
                // previous attempt or compaction was in flight applies here,
                // before the request is built — never after it. If the turn was
                // cancelled while the switch was building, stop before the chat
                // call below rather than issuing it on the old model.
                if self.apply_model_request().await {
                    break None;
                }
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
                        // Prefer cancellation: a cancel that is already pending
                        // when this request is in flight must win over an
                        // immediately-ready model future, so a cancelled turn
                        // never processes one more call on the (old) model.
                        biased;
                        () = control.cancelled() => break None,
                        response = &mut call => break Some(response),
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
                        // A stream that broke *after* visible output arrived: the
                        // partial reply was shown but never added to history, so
                        // discard it and re-send the same request (which itself
                        // waits out any network outage). Capped per model call so
                        // a persistently broken connection still ends the turn.
                        if let Some(interrupted) = providers::stream_interrupted(&e) {
                            if stream_restarts < MAX_STREAM_RESTARTS {
                                stream_restarts += 1;
                                let what = format!("{}/{}", self.client.provider_name(), self.client.model_name());
                                eprintln!(
                                    "[agent] {what}: {interrupted}; asking again ({stream_restarts}/{MAX_STREAM_RESTARTS})"
                                );
                                // Tell the renderers to discard the abandoned
                                // partial reply (and reset pending thinking)
                                // before the re-sent stream's deltas arrive, so
                                // the replacement answer starts fresh instead of
                                // being appended to the stale prefix.
                                if let Some(sink) = event_sink {
                                    sink(session_id, &AgentEvent::ResponseRestarted);
                                }
                                continue;
                            }
                            self.set_activity(Activity::Idle);
                            return Err(e);
                        }
                        let message = format!("{e:#}");
                        // An output-token-limit rejection: the configured or
                        // fallback `max_tokens` exceeds the model's real output
                        // cap. This is common right after a `/model` switch —
                        // the background capability probe that would publish the
                        // real cap has not landed yet, so automatic `max_tokens`
                        // falls back to the large default and the request is
                        // rejected. Learn the cap from the error and retry once
                        // at the lower value rather than failing the turn, so the
                        // switch never has to block on the probe (issue #114).
                        if !max_output_retried
                            && context::is_output_cap_error(&message)
                            && !context::is_context_overflow(&message)
                        {
                            max_output_retried = true;
                            // Derive the no-numeric-limit fallback from the
                            // budget this request actually *sent*
                            // (`request_max_tokens`, after the context-window
                            // clamp), not the unclamped base: a context-clamped
                            // request sends far less than the base, so halving
                            // the base can land *above* what was sent, making
                            // `learned < request_max_tokens` false and failing
                            // the turn without ever retrying (issue #114).
                            let learned = context::output_cap_from_error(&message)
                                .map(|c| c as i64)
                                .unwrap_or((request_max_tokens / 2).max(1_024))
                                .max(256);
                            // Only act when this actually lowers the request.
                            // Compare against the budget this request *sent*
                            // (`request_max_tokens`), not the current base: a
                            // background probe that publishes the real cap
                            // between the send and the rejection already lowers
                            // the base, so measuring against it would wrongly
                            // conclude the learned cap is no improvement and
                            // fail a turn that a retry at the sent budget's
                            // lower value would save (issue #114).
                            if learned < request_max_tokens {
                                self.learned_max_output = Some(learned as usize);
                                self.refresh_stats();
                                eprintln!(
                                    "[agent] output-limit rejection ({message}); retrying with max_tokens={learned}"
                                );
                                continue;
                            }
                        }
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
                        // The overflow compaction is a model call too;
                        // `compact_logged` applies a `/model` queued while the
                        // overflowing request was in flight before the summary
                        // goes out on the old model.
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
                // Recorded so a turn cut off at the output-token limit is
                // diagnosable from the session log (issue #114).
                stop_reason: response.stop_reason.clone(),
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
                    // A steer starts a new answer; drop any accumulated cut-off
                    // chunks so the steer's reply is not prefixed by the old one.
                    continued_answer.clear();
                    self.sync_pending_continuation(&continued_answer, truncated_continuations);
                    last_content = response.content.clone();
                    continue;
                }
                // Claude Code Stop hooks can keep the turn going, with the
                // reason as the next message (capped to avoid loops).
                if iteration < budget
                    && !self.control.is_cancelled()
                    && let Some(reason) = self.run_claude_stop_hooks()
                {
                    self.push(Message::user(&reminders::wrap(&reason)).auto_initiated())?;
                    // The Stop-hook reply is a fresh answer, not a continuation.
                    continued_answer.clear();
                    self.sync_pending_continuation(&continued_answer, truncated_continuations);
                    last_content = response.content.clone();
                    continue;
                }
                // A reply cut off at the output-token limit is not a finished
                // answer: the model stopped because it ran out of room, and any
                // tool call it was emitting was dropped before it could be
                // parsed (issue #114). Nudge it to continue in smaller pieces
                // rather than ending the turn as if it were done. Capped so a
                // model that keeps overrunning cannot loop forever; past the cap
                // the turn ends with a distinct `MaxTokens` stop reason so
                // callers can tell this apart from a clean finish.
                if crate::llm::stop_reason_is_length(response.stop_reason.as_deref()) {
                    if iteration < budget
                        && !self.control.is_cancelled()
                        && truncated_continuations < MAX_TRUNCATED_CONTINUATIONS
                    {
                        truncated_continuations += 1;
                        let tokens = response.usage.as_ref().map_or(0, |u| u.completion_tokens);
                        self.push(
                            Message::user(&reminders::wrap(&truncated_continuation_note(tokens))).continuation(),
                        )?;
                        // Keep this cut-off chunk so the finished answer is the
                        // whole reply, not just the final continuation's tail.
                        continued_answer.push_str(&response.content);
                        self.sync_pending_continuation(&continued_answer, truncated_continuations);
                        last_content = response.content.clone();
                        #[cfg(test)]
                        if let Some(hook) = self.after_continuation_scheduled.take() {
                            hook();
                        }
                        continue;
                    }
                    // The continuation cap is spent, or the turn cannot continue
                    // (cancelled / iteration budget). End, but flag it so the
                    // turn reports `MaxTokens` rather than a clean `EndTurn`.
                    max_tokens_hit = true;
                }
                // Prepend any chunks carried across output-limit continuations so
                // the final response is the contiguous answer, not its tail.
                final_response = Some(if continued_answer.is_empty() {
                    response.content.clone()
                } else {
                    format!("{continued_answer}{}", response.content)
                });
                break;
            }

            // Tool calls begin a new answer segment: the dropped tool-call markup
            // must not bleed into a later text answer, so reset the accumulator.
            continued_answer.clear();
            self.sync_pending_continuation(&continued_answer, truncated_continuations);
            last_content = response.content.clone();
            self.push(trajectory(Message::assistant_with_tools(&response.content, response.tool_calls.clone())))?;
            self.emit_assistant_text(&response.content);
            for tool_call in &response.tool_calls {
                if self.control.is_cancelled() {
                    self.push(Message::tool_error(&tool_call.id, &tool_call.name, CANCELLED_TOOL_RESULT))?;
                    self.emit(AgentEvent::ToolResult { call: tool_call, ok: false, output: CANCELLED_TOOL_RESULT });
                    continue;
                }
                if loop_stop.is_some() {
                    // The loop detector hard-stopped on an earlier call in this
                    // same batch (issue #65). Do not dispatch the rest — a
                    // response full of repeated or side-effecting calls must not
                    // keep running past the stop. Add a synthetic result per
                    // skipped call (as cancellation does) so the conversation
                    // still has exactly one result per tool call.
                    self.push(Message::tool_error(&tool_call.id, &tool_call.name, LOOP_STOPPED_TOOL_RESULT))?;
                    self.emit(AgentEvent::ToolResult { call: tool_call, ok: false, output: LOOP_STOPPED_TOOL_RESULT });
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
                        && (self.control.mode() != crate::mode::AgentMode::Plan
                            || crate::mode::plan_allows(&tool_call.name))
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
                let is_timer_tool = self.timers_enabled && timers::is_timer_tool(&tool_call.name);
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
                // Each bounder spill's identity (digest + exact marker path),
                // collected out of band at the point the result was produced
                // (the bash capture reader via the shared slot, the
                // `history_read` bound, or the generic tool-result bound
                // below), so the loop detector's fingerprint can normalise the
                // marker's volatile per-call path without ever trusting a
                // digest parsed out of the rendered — model-influenceable —
                // text (issue #65).
                let mut spill_digests: Vec<output::Spill> = Vec::new();
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
                } else if is_timer_tool {
                    dispatched = true;
                    self.run_timer_tool(effective_call)
                } else if is_skill_tool {
                    dispatched = true;
                    self.skills.load(&effective_call.arguments).map(Value::String)
                } else if is_history_tool {
                    dispatched = true;
                    self.run_history_tool_digest(effective_call).map(|(text, spilled)| {
                        spill_digests.extend(spilled);
                        Value::String(text)
                    })
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
                    other if tool_call.name == "read_file" => match self.image_result(&other).await {
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
                // A bash call publishes its spilled captures' identities into
                // the shared slot (see `BashConfig::spill_digests`); take them
                // so the loop detector gets each spill's identity out of band.
                if tool_call.name == "bash" {
                    spill_digests.extend(std::mem::take(&mut *self.spill_digests.lock().unwrap()));
                }
                if !matches!(tool_call.name.as_str(), "bash" | "read_file" | history::READ_TOOL) && !is_skill_tool {
                    let name = format!("tool-{}-{}.txt", sanitize(&tool_call.id), sanitize(&tool_call.name));
                    let (bounded, spilled) =
                        output::bound_and_spill_digest(&result_text, self.tool_output_limit, &self.spill_dir(), &name);
                    result_text = bounded;
                    spill_digests.extend(spilled);
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
                // Consume the one-time "look in history" hint *before* the loop
                // detector fingerprints the result (issue #65). The hint is
                // appended to only the first failed call, so a result that
                // carries it is genuinely different — to the model — from the
                // later identical failures. Fingerprinting after this append
                // keeps that first call out of the identical-result streak, so
                // the warning and hard stop fire at the documented thresholds
                // rather than one call early. The detector's own warning text
                // is still appended afterward, below.
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
                if self.config.reminders && (is_plan_tool || is_outcome_tool || is_timer_tool) {
                    // Plan, timer and outcome calls are never counted by the loop
                    // detector, but they must still break a repeat streak so an
                    // interleaved plan/timer/outcome call cannot mask otherwise
                    // consecutive repeats (issue #65).
                    self.reminders.reset_repeat();
                } else if self.config.reminders {
                    if ok && tool_call.name == memory::SAVE_TOOL {
                        self.reminders.memory_saved();
                    }
                    let memory_writable = self.memory_enabled() && self.memory_writable();
                    for note in self.reminders.after_tool_call(&self.plan, memory_writable) {
                        result_text.push_str("\n\n");
                        result_text.push_str(&reminders::wrap(&note));
                    }
                    // Loop detector (issue #65): nudge the model when it
                    // repeats an identical call, and end the turn blocked when
                    // it keeps repeating after the warnings are spent. A
                    // malformed call carries `arguments = {}`, so pass the full
                    // raw argument text as the fingerprint's argument component
                    // — otherwise two malformed payloads that diverge only past
                    // the 300-character error preview collapse to one
                    // fingerprint and a genuinely-different retry is
                    // hard-stopped as an identical repeat. Pass each image
                    // attachment's content hash too: a `read_file` of a changing
                    // image returns identical metadata text while the bytes
                    // differ, so without the hashes the fifth changing image
                    // would be hard-stopped as an identical result (issue #65).
                    let attachment_shas: Vec<&str> = attachments.iter().map(|a| a.sha256.as_str()).collect();
                    let spill_refs: Vec<&output::Spill> = spill_digests.iter().collect();
                    let hashes = reminders::ContentHashes { attachments: &attachment_shas, spills: &spill_refs };
                    match self.reminders.after_repeat_call(
                        &tool_call.name,
                        &effective_call.arguments,
                        tool_call.invalid_arguments(),
                        ok,
                        &result_text,
                        hashes,
                    ) {
                        reminders::RepeatVerdict::None => {}
                        reminders::RepeatVerdict::Warning(note) => {
                            result_text.push_str("\n\n");
                            result_text.push_str(&reminders::wrap(&note));
                        }
                        reminders::RepeatVerdict::HardStop(reason) => {
                            result_text.push_str("\n\n");
                            result_text.push_str(&reminders::wrap(
                                "This call already ran, but it has repeated too many times: the turn is ending \
                                 as blocked and any further retries are being stopped. Do not retry it.",
                            ));
                            loop_stop = Some(reason);
                        }
                    }
                }
                // The display output (trajectory event, ACP) notes each attached
                // image as `[image: path, WxH]`; the model-facing `result_text`
                // stays the short text part.
                let display_output = tool_result_display(&result_text, &attachments);
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
            if let Some(reason) = loop_stop.take() {
                // The loop detector's hard stop: the model kept repeating one
                // call after the warnings, so the turn ends here as `blocked`
                // rather than burning budget until the turn cap (issue #65).
                let outcome = Outcome { status: goal::Status::Blocked, summary: reason };
                let response = outcome.response();
                self.push(Message::assistant(&response))?;
                self.emit_assistant_text(&response);
                reported = Some(outcome);
                final_response = Some(response);
                break;
            }
            if reported.is_some() {
                // A reported outcome ends the turn like a tool-free answer, so it
                // must pass the same Stop gate: a Stop hook may ask the agent to
                // keep going (capped). If it does, clear the reported outcome —
                // the turn is no longer complete — and continue the loop.
                if iteration < budget
                    && !self.control.is_cancelled()
                    && let Some(reason) = self.run_claude_stop_hooks()
                {
                    self.push(Message::user(&reminders::wrap(&reason)).auto_initiated())?;
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
        } else if max_tokens_hit {
            StopReason::MaxTokens
        } else if final_response.is_some() {
            StopReason::EndTurn
        } else {
            StopReason::MaxTurnRequests
        };
        let response = match stop_reason {
            StopReason::EndTurn | StopReason::MaxTokens => final_response.unwrap_or_default(),
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
        let (response, outcome) = self.finish_turn(input_id, response, outcome, stop_reason)?;
        Ok(TurnOutcome { response, stop_reason, outcome })
    }

    fn finish_turn(
        &mut self,
        input_id: String,
        response: String,
        outcome: Option<Outcome>,
        stop_reason: StopReason,
    ) -> Result<(String, Option<Outcome>)> {
        if let Some(log) = &mut self.session {
            log.append(&Record::TurnEnd {
                input_id: input_id.clone(),
                response: response.clone(),
                outcome: outcome.clone(),
                stop_reason,
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
        if stop_reason.is_end_turn() {
            self.completed_stop_reasons.remove(&input_id);
        } else {
            self.completed_stop_reasons.insert(input_id.clone(), stop_reason);
        }
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
                (self.output_token_base().max(0) as usize).min(MIN_OUTPUT_RESERVE) + output_margin(window)
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
                    (self.output_token_base().max(0) as usize).min(MIN_OUTPUT_RESERVE) + output_margin(combined);
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
        let configured = self.output_token_base().max(1) as usize;
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
        // Compaction summarizes via a model call (`compact_with`), so a
        // `/model` queued but not yet applied — e.g. one typed during a turn's
        // final in-flight call, which `run_turn` never reaches a hook to apply,
        // followed by a manual `/compact` — must take effect before that call.
        // Applying here is the single choke point for *every* trigger (manual,
        // threshold, overflow), so no compaction path can summarize on the
        // model the user just switched away from. Idempotent: a no-op when the
        // caller already drained the slot before calling in. If the turn was
        // cancelled while the switch was building, stop before the summary call
        // rather than issuing it on the old model.
        if self.apply_model_request().await {
            self.refresh_stats();
            return Ok(None);
        }
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
        // Budget the kept tail against the wire plan, not the full image cost:
        // the request sends only the newest `max_images` attachments as images
        // and serializes every older one as a short text placeholder. The cost
        // of a candidate tail `conversation[k..]` is therefore the wire cost of
        // that whole span (which charges only its newest `max_images` as
        // images), *not* a sum of per-message full image costs — the latter
        // would overcount an image-heavy tail and discard far more recent
        // history than `KEEP_RECENT_TOKENS` intends. Grow the tail one boundary
        // at a time and keep the largest span whose wire cost fits the budget.
        let max_images = self.vision().map(|v| v.max_images).unwrap_or(0);
        // Hash the stored attachment set once and reuse it for every candidate
        // tail below, so availability costs O(N) file I/O, not O(N²). The budget
        // must charge availability the way the wire does: a missing/tampered
        // reference is a placeholder, and the older image the wire backfills in
        // its place carries the full image cost.
        let available = context::available_attachments(&self.conversation, Some(&self.attachments_dir()));
        let mut split = last_boundary;
        for &boundary in boundaries.iter().rev() {
            let tail = context::messages_tokens_with_vision(&self.conversation[boundary..], max_images, &available);
            if tail > keep_budget {
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
        // Owned, not a borrow of `self.conversation`: the summary retry loop
        // calls `apply_model_request()` (`&mut self`) to honour a `/model`
        // switch queued mid-compaction, which a borrow of the conversation
        // would block (issue #114).
        let summarized: Vec<Message> = self.conversation[body_start..split].to_vec();
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

        // The summary's output budget and the transcript's share of the window
        // are recomputed per attempt (the closure below): an output-cap
        // rejection learns the real cap and retries at the lower budget, and the
        // budget must move with it (issue #114).
        // The transcript and the summary's own output share the request budget.
        // Against a total/combined cap the prompt and output must fit together,
        // so the output budget is carved out of the window. A prompt-only cap
        // (GitHub Copilot's `max_prompt_tokens`) does not spend output tokens,
        // so the transcript gets the whole prompt window; only a combined window
        // the endpoint advertised still bounds prompt + output. This mirrors
        // `request_max_tokens()`'s cap handling. The model-dependent inputs
        // (`window`, `context_cap`, `combined_window`) are passed in per attempt
        // — not captured — so a `/model` switch honoured on a retry rebuilds
        // them for the new model (issue #114).
        let build_request =
            |output_budget: i64, window: usize, context_cap: ContextCap, combined_window: Option<usize>| {
                let input_window = match context_cap {
                    ContextCap::Prompt => match combined_window {
                        Some(combined) => window.min(combined.saturating_sub(output_budget as usize)),
                        None => window,
                    },
                    ContextCap::Total => window.saturating_sub(output_budget as usize),
                };
                let summary_input_chars = input_window.saturating_sub(2_000).max(2_000) * 3;
                let transcript = context::render_transcript(&summarized, summary_input_chars, smart);
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
                (summary_messages, output_budget)
            };
        let lines: Vec<u64> = summarized.iter().filter_map(|m| m.log_line).collect();
        let range = lines.iter().min().zip(lines.iter().max()).map(|(a, b)| (*a, *b));
        let control = self.control.clone();
        // Stream the summary even though its text is used only once complete.
        // A summary prompt is new text that no prefix cache holds. A local
        // model can take minutes to read it before sending its first token.
        // A non-streaming request sends no bytes in that time, so a proxy or
        // tunnel with an idle timeout drops it, and every retry starts over.
        // A stream carries the server's keepalives (and falls back to one
        // whole response for providers configured with `stream = false`).
        let discard = |_: StreamEvent<'_>| {};
        // Like a chat turn, the summary request can be rejected for exceeding
        // the model's real output cap (common right after a reload or `/model`
        // switch, before the capability probe lands). Learn the cap and retry
        // once at the lower budget instead of falling through to the
        // dropped-history fallback, which would lose the summarized context
        // (issue #114).
        let mut summary_output_retried = false;
        let result = loop {
            // Honour a `/model` switch queued while a previous summary attempt
            // was in flight, before building this attempt's request — the chat
            // retry loop does the same, and compaction's single call checked
            // before this loop existed. A switch rebuilds the model-dependent
            // window, temperature and output budget below so the retry goes to
            // the new model, not the one the user switched away from. If the
            // turn was cancelled while the switch was building, stop before the
            // summary call (issue #114).
            if self.apply_model_request().await {
                return Ok(None);
            }
            // Recomputed per attempt: a model switch above changes the window,
            // the cap source, the combined window and the temperature, and an
            // output-cap retry below changes the budget via `learned_max_output`.
            let window = self.context_window();
            let context_cap = self.context_cap();
            let combined_window = self.combined_window();
            // Resolved per attempt: it borrows `self`, which the retry's
            // `learned_max_output` assignment and the model switch above need
            // mutably, and a switch changes the value.
            let summary_temperature = self.temperature_for(self.thinking().always_anthropic_thinking()).value();
            let output_budget = context::summary_output_budget(window, self.output_token_base());
            let (summary_messages, budget) = build_request(output_budget, window, context_cap, combined_window);
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
                temperature: summary_temperature,
                max_tokens: Some(budget),
                // A summary needs no extended reasoning; the model's own default
                // applies, as before thinking levels existed.
                thinking: None,
                // The summary request never includes images: the transcript renders
                // them as text placeholders, and the freshly built summary messages
                // carry no attachments.
                vision: None,
                attachments_dir: None,
            };
            let attempt = tokio::select! {
                // Prefer cancellation: a cancel already pending when the summary
                // request is issued must win over an immediately-ready model
                // future, so a cancelled compaction never lands a call on the
                // model the user just switched away from.
                biased;
                () = control.cancelled() => return Ok(None),
                result = self.client.chat_stream(&request, &discard) => result,
            };
            match attempt {
                Err(e) if !summary_output_retried => {
                    let message = format!("{e:#}");
                    if context::is_output_cap_error(&message) && !context::is_context_overflow(&message) {
                        summary_output_retried = true;
                        // A numeric limit parsed from the error is the real cap.
                        // Without one, fall back to halving the budget this
                        // summary request actually *sent* — not the chat base,
                        // which can be larger than the summary budget (a 32,768
                        // base yields a 12,288 summary budget; halving the base
                        // infers a 16,384 cap that is NOT below the sent budget,
                        // so the `learned < budget` check would skip the retry
                        // and drop history) (issue #114).
                        let learned = context::output_cap_from_error(&message)
                            .map(|c| c as i64)
                            .unwrap_or((budget / 2).max(1_024))
                            .max(256);
                        // Retry only when the learned cap actually lowers the
                        // summary budget we just sent; otherwise the rejection
                        // is about something else and retrying would repeat it.
                        if learned < budget {
                            self.learned_max_output = Some(learned as usize);
                            self.refresh_stats();
                            eprintln!(
                                "[agent] summary output-limit rejection ({message}); retrying with max_tokens={learned}"
                            );
                            continue;
                        }
                    }
                    break Err(e);
                }
                other => break other,
            }
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
        // Same apply-then-persist atomicity as `run_timer_tool`: `apply`
        // mutates the live plan in place, so snapshot first and roll back on an
        // apply or persist failure rather than leaving the live plan changed
        // while reporting an error (issue #150 review).
        let snapshot = self.plan.clone();
        let outcome = match self.plan.apply(&call.name, &call.arguments) {
            Ok(outcome) => outcome,
            Err(err) => {
                self.plan = snapshot;
                return Err(err);
            }
        };
        if outcome.changed
            && let Err(err) = self.plan_changed()
        {
            self.plan = snapshot;
            self.control.publish_plan(&self.plan);
            self.refresh_stats();
            return Err(err);
        }
        Ok(Value::String(outcome.text))
    }

    /// "Now" for the timers: the wall clock, or the time a test set.
    fn timers_now(&self) -> DateTime<Local> {
        #[cfg(test)]
        if let Some(fixed) = &self.timers_clock {
            return *fixed.lock().unwrap();
        }
        Local::now()
    }

    /// Give the timers a shared clock for a test (`None` returns to the wall
    /// clock); advancing the cell moves time, even mid-turn.
    #[cfg(test)]
    pub fn set_timers_now(&mut self, now: Option<std::sync::Arc<std::sync::Mutex<DateTime<Local>>>>) {
        self.timers_clock = now;
    }

    /// Test hook: force the next timers/plan persist to fail, so a test can
    /// drive the apply-then-persist rollback without a real I/O failure.
    #[cfg(test)]
    pub fn fail_next_persist(&mut self) {
        self.fail_next_persist = true;
    }

    /// The session's timers.
    pub fn timers(&self) -> &Timers {
        &self.timers
    }

    /// Turn the timer tools off (ACP: no idle loop to fire them). Existing
    /// timers keep their state but cannot fire without the tools loop.
    pub fn disable_timers(&mut self) {
        self.timers_enabled = false;
    }

    fn run_timer_tool(&mut self, call: &ToolCall) -> Result<Value> {
        if !self.timers_enabled {
            return Err(anyhow::anyhow!(
                "{} is not available here: timers need the interactive harness's idle loop to fire",
                call.name
            ));
        }
        // `apply` mutates the live timers in place, and persisting them
        // afterwards can still fail. Snapshot first so an apply *or* persist
        // failure rolls the live timers back to their prior state — otherwise a
        // failed cancel/acknowledge would drop the timer in memory while
        // returning an error, leaving the published/persisted timers stale and
        // the live state silently diverged (issue #150 review).
        let snapshot = self.timers.clone();
        let outcome = match self.timers.apply(&call.name, &call.arguments, self.timers_now()) {
            Ok(outcome) => outcome,
            Err(err) => {
                self.timers = snapshot;
                return Err(err);
            }
        };
        if outcome.changed
            && let Err(err) = self.timers_changed()
        {
            self.timers = snapshot;
            self.control.publish_timers(&self.timers);
            self.refresh_stats();
            return Err(err);
        }
        Ok(Value::String(outcome.text))
    }

    /// Persist and publish the timers after a change (like `plan_changed`).
    fn timers_changed(&mut self) -> Result<()> {
        #[cfg(test)]
        if std::mem::take(&mut self.fail_next_persist) {
            return Err(anyhow::anyhow!("forced timers persist failure (test)"));
        }
        if let Some(log) = &mut self.session {
            log.append(&Record::Timers { timers: self.timers.clone(), recorded_at: session::now() })?;
        }
        self.control.publish_timers(&self.timers);
        self.refresh_stats();
        Ok(())
    }

    /// Timers due right now (they fire once), soonest first.
    pub fn take_fired_timers(&mut self) -> Result<Vec<timers::Timer>> {
        // `take_due` moves the due timers out of `items` and into `pending`
        // in place. If the subsequent persist fails we must roll the live
        // timers back: the caller (`fire_due_timers`) aborts on the error
        // before delivering their messages, so without a rollback the firing is
        // consumed in memory (gone from `items`, now `pending`) while never
        // delivered — a retry then finds nothing due, silently losing the
        // reminders and leaving the live state diverged from the
        // published/persisted snapshot (issue #150 review). Snapshot first and
        // reset the nudge counter only after persistence succeeds, so a failed
        // firing is fully atomic (deliver + persist, or leave state untouched).
        let snapshot = self.timers.clone();
        let fired = self.timers.take_due(self.timers_now());
        if !fired.is_empty() {
            if let Err(err) = self.timers_changed() {
                self.timers = snapshot;
                self.control.publish_timers(&self.timers);
                self.refresh_stats();
                return Err(err);
            }
            // Restart the pending-nudge interval whenever a timer fires, so a
            // counter left near the `PENDING_NUDGE_EVERY` threshold by an
            // earlier pending timer does not make the first model step after an
            // idle firing immediately re-nudge. `absorb_steers` resets it too;
            // doing it here makes both delivery paths (mid-turn and the idle
            // REPL loop, which calls this directly) share the reset. Only after
            // a successful persist, so a rolled-back firing keeps its counter.
            self.pending_timer_steps = 0;
        }
        Ok(fired)
    }

    /// Mark the next `run_turn` as an automatic timer turn (a wakeup, mid-turn
    /// firing, or pending nudge) so its user message is billed as
    /// agent-initiated rather than a premium user request (issue #150).
    pub fn mark_auto_turn(&mut self) {
        self.auto_turn = true;
    }

    /// Push the timers due at this step into the conversation as a user
    /// message, after the steers. Returns whether any fired.
    fn fire_due_timers(&mut self) -> Result<bool> {
        let fired = self.take_fired_timers()?;
        if fired.is_empty() {
            return Ok(false);
        }
        let now = self.timers_now();
        // The UI shows `⏰ timer N: <note>` per timer. A dedicated event (not
        // `UserMessage`): plain/redirected output suppresses `UserMessage` as
        // steer/replay chatter, but a mid-turn timer firing must be visible
        // there too — including headless `--wait-timers` runs (issue #150).
        for timer in &fired {
            self.emit(AgentEvent::TimerFired { id: timer.id, note: &timer.note });
        }
        self.push(Message::user(&Timers::fired_batch_message(&fired, now)).timer())?;
        Ok(true)
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

    /// Run a `history_search`/`history_read` call, also returning the identity
    /// of the spill a `history_read` produced, so the loop detector gets the
    /// spill's identity out of band (issue #65).
    fn run_history_tool_digest(&mut self, call: &ToolCall) -> Result<(String, Option<output::Spill>)> {
        let path = self.session_path().ok_or_else(|| anyhow::anyhow!("no session log"))?.to_path_buf();
        self.turn_history_calls += 1;
        let read = call.name == history::READ_TOOL;
        {
            let mut stats = self.stats.lock().unwrap();
            if read { stats.history_reads += 1 } else { stats.history_searches += 1 }
        }
        if read {
            history::read_digest(&path, &call.arguments, &self.spill_dir())
        } else {
            history::search(&path, &call.arguments).map(|text| (text, None))
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
    use crate::recents;
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
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
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
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
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
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
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

    /// `n` scripted responses that each repeat the same `echo` call.
    fn echo_loop(n: usize) -> Vec<LLMResponse> {
        (1..=n).map(|i| tool_call(&format!("c{i}"))).collect()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn identical_tool_calls_draw_a_loop_warning_on_the_third() {
        let dir = tempfile::tempdir().unwrap();
        // Two identical calls, then the model moves on: no reminder at all.
        let (mut quiet, _seen) = agent(vec![tool_call("c1"), tool_call("c2"), text("done")], dir.path());
        quiet.new_session().unwrap();
        quiet.run_turn(Some("in-1"), "go").await.unwrap();
        let tools: Vec<_> = quiet.conversation().iter().filter(|m| m.role == Role::Tool).collect();
        assert_eq!(tools.len(), 2);
        assert!(tools.iter().all(|m| !m.content.contains("<system-reminder>")), "no warning: {:?}", tools[1].content);

        // The third identical call is warned about.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent2, _seen) =
            agent(vec![tool_call("c1"), tool_call("c2"), tool_call("c3"), text("done")], dir.path());
        agent2.new_session().unwrap();
        agent2.run_turn(Some("in-1"), "go").await.unwrap();
        let tools: Vec<_> = agent2.conversation().iter().filter(|m| m.role == Role::Tool).collect();
        assert!(!tools[1].content.contains("<system-reminder>"), "second call is quiet: {}", tools[1].content);
        assert!(tools[2].content.contains("same `echo` call 3 times"), "third call warns: {}", tools[2].content);
        assert!(tools[2].content.contains("report_outcome"), "points at the way out: {}", tools[2].content);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_repeat_loop_ends_the_turn_blocked_after_the_warnings() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(echo_loop(20), dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        // The turn stops itself right after the second warning (call 5 of the
        // loop) instead of running the script dry.
        assert_eq!(seen.lock().unwrap().len(), reminders::REPEAT_WARN_AFTER + reminders::REPEAT_MAX_WARNINGS);
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        let reported = outcome.outcome.expect("the harness reports the outcome");
        assert_eq!(reported.status, goal::Status::Blocked);
        assert!(reported.summary.contains("echo"), "names the stuck call: {}", reported.summary);
        assert!(outcome.response.starts_with("Blocked:"), "{}", outcome.response);
        let tools: Vec<_> = agent.conversation().iter().filter(|m| m.role == Role::Tool).collect();
        assert_eq!(tools.len(), reminders::REPEAT_WARN_AFTER + reminders::REPEAT_MAX_WARNINGS);
        assert!(
            tools.last().unwrap().content.contains("turn is ending as blocked"),
            "{}",
            tools.last().unwrap().content
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_loop_detector_resets_on_a_new_turn() {
        let dir = tempfile::tempdir().unwrap();
        // Turn 1 loops until the warning fires and then stops; turn 2 repeats
        // the same call twice and answers — below the fresh turn's threshold.
        let mut responses = echo_loop(reminders::REPEAT_WARN_AFTER);
        responses.push(text("first done"));
        responses.extend(echo_loop(reminders::REPEAT_WARN_AFTER - 1));
        responses.push(text("second done"));
        let (mut agent, _seen) = agent(responses, dir.path());
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        let warned = agent
            .conversation()
            .iter()
            .filter(|m| m.role == Role::Tool && m.content.contains("same `echo` call"))
            .count();
        assert_eq!(warned, 1, "one warning in the first turn");
        // A new turn starts the count over: the same call twice more stays quiet.
        let reply = agent.run_turn(Some("in-2"), "again").await.unwrap();
        assert_eq!(reply.response, "second done");
        let tools: Vec<_> = agent.conversation().iter().filter(|m| m.role == Role::Tool).collect();
        assert_eq!(tools.len(), reminders::REPEAT_WARN_AFTER + reminders::REPEAT_WARN_AFTER - 1);
        let turn2 = &tools[reminders::REPEAT_WARN_AFTER..];
        assert!(turn2.iter().all(|m| !m.content.contains("same `echo` call")), "fresh turn: {:?}", turn2[0].content);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_hard_stop_skips_the_rest_of_the_batch() {
        let dir = tempfile::tempdir().unwrap();
        // One response that batches many identical calls. The detector hard-stops
        // partway through the batch; the remaining calls must NOT be dispatched,
        // yet each still needs exactly one (synthetic) result (issue #65).
        let batch = reminders::REPEAT_WARN_AFTER + reminders::REPEAT_MAX_WARNINGS + 3;
        let response = LLMResponse {
            tool_calls: (1..=batch)
                .map(|i| ToolCall {
                    id: format!("c{i}"),
                    name: "echo".into(),
                    arguments: json!({"text": "pong"}),
                    item_id: None,
                    malformed_arguments: None,
                })
                .collect(),
            ..Default::default()
        };
        let (mut agent, _seen) = agent(vec![response], dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.outcome.map(|o| o.status), Some(goal::Status::Blocked));
        let tools: Vec<_> = agent.conversation().iter().filter(|m| m.role == Role::Tool).collect();
        // Every call in the batch still has exactly one result.
        assert_eq!(tools.len(), batch);
        // Calls up to and including the hard stop ran (their result is the echo);
        // every later call is skipped with a synthetic "not run" result.
        let dispatched = reminders::REPEAT_WARN_AFTER + reminders::REPEAT_MAX_WARNINGS;
        assert!(tools[..dispatched].iter().all(|m| m.content.contains("pong")), "earlier calls ran");
        assert!(
            tools[dispatched..].iter().all(|m| m.content.contains("this tool call was not run")),
            "later calls skipped, not dispatched: {}",
            tools[dispatched].content
        );
    }

    /// A text response cut off at the output-token limit (`stop_reason:
    /// length`), carrying `completion_tokens` in its usage.
    fn cut_text(content: &str, completion_tokens: i64) -> LLMResponse {
        LLMResponse {
            content: content.into(),
            stop_reason: Some("length".into()),
            usage: Some(crate::llm::TokenUsage {
                prompt_tokens: 0,
                completion_tokens,
                total_tokens: completion_tokens,
                aic: None,
            }),
            ..Default::default()
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_reply_cut_off_at_the_output_limit_continues_instead_of_ending() {
        let dir = tempfile::tempdir().unwrap();
        // First reply is cut off at the output limit with no tool call; the turn
        // must not end there — it nudges the model to continue, then ends clean
        // on the finished second reply.
        let (mut agent, seen) = agent(vec![cut_text("half a file", 4096), text("all done")], dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        // The second reply *completes* the first rather than replacing it, so
        // the final response is the whole answer, not just its tail (issue #114).
        assert_eq!(outcome.response, "half a fileall done");
        // The model got a "cut off" continuation note as a user message before
        // the second call, mentioning the token count.
        let second = &seen.lock().unwrap()[1];
        let note = second.iter().rev().find(|m| m.role == Role::User).unwrap();
        assert!(note.content.contains("cut off"), "{}", note.content);
        assert!(note.content.contains("4096"), "{}", note.content);
        // The truncated assistant message records its stop reason in the log.
        let cut = agent.conversation().iter().find(|m| m.content == "half a file").unwrap();
        assert_eq!(cut.stop_reason.as_deref(), Some("length"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn repeated_output_limit_cut_offs_end_with_a_distinct_stop_reason() {
        let dir = tempfile::tempdir().unwrap();
        // Every reply is cut off at the output limit. The turn re-prompts up to
        // the cap, then gives up with `MaxTokens` rather than a clean `EndTurn`.
        let cuts: Vec<LLMResponse> =
            (0..MAX_TRUNCATED_CONTINUATIONS + 1).map(|_| cut_text("still going", 100)).collect();
        let (mut agent, seen) = agent(cuts, dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTokens);
        assert_eq!(outcome.stop_reason.as_acp(), "max_tokens");
        // The cap bounds the number of continuations: one initial call plus
        // `MAX_TRUNCATED_CONTINUATIONS` re-prompts.
        assert_eq!(seen.lock().unwrap().len(), MAX_TRUNCATED_CONTINUATIONS + 1);
        // Even giving up, the final response stitches the accumulated chunks
        // rather than returning only the last cut-off tail (issue #114).
        assert_eq!(outcome.response, "still going".repeat(MAX_TRUNCATED_CONTINUATIONS + 1));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn output_limit_continuations_accumulate_the_whole_answer() {
        let dir = tempfile::tempdir().unwrap();
        // Two cut-offs then a clean finish: the final response stitches all
        // three contiguous chunks, not just the last one (issue #114).
        let (mut agent, _seen) = agent(vec![cut_text("one ", 100), cut_text("two ", 100), text("three")], dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "one two three");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_same_agent_retry_after_a_provider_error_does_not_replay_the_snapshot_twice() {
        // A transient provider error leaves the turn pending with its in-flight
        // continuation snapshot synced into the live pending input. Retrying the
        // same input id on the *same* Agent must replay only the messages logged
        // *after* that snapshot — never the chunk/reminder already folded into
        // it — or the answer prefix duplicates and the continuation budget is
        // double-spent, cutting the turn off at `MaxTokens` a chunk early (issue
        // #114).
        struct ErrorThenScript {
            calls: Mutex<usize>,
            seen: Seen,
        }
        #[async_trait]
        impl LLMClient for ErrorThenScript {
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("test double is never cloned")
            }
            async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
                self.seen.lock().unwrap().push(request.messages.to_vec());
                let n = {
                    let mut calls = self.calls.lock().unwrap();
                    let n = *calls;
                    *calls += 1;
                    n
                };
                match n {
                    // First attempt: one chunk cut off at the output limit
                    // (schedules a single continuation).
                    0 => Ok(cut_text("one ", 50)),
                    // A transient provider error — not an output-cap or overflow
                    // rejection — so the turn fails and is left pending.
                    1 => anyhow::bail!("provider glitch"),
                    // The same-Agent retry: two more cut-off chunks, then a clean
                    // finish. With the budget counted once (count 1 restored),
                    // both fit before the cap; counted twice (count 2) the second
                    // would overrun it.
                    2 => Ok(cut_text("two ", 50)),
                    3 => Ok(cut_text("three ", 50)),
                    _ => Ok(text("four")),
                }
            }
            fn model_name(&self) -> &str {
                "scripted"
            }
            fn provider_name(&self) -> &str {
                "test"
            }
            fn kind(&self) -> Option<providers::ProviderKind> {
                Some(providers::ProviderKind::Openai)
            }
        }

        let dir = tempfile::tempdir().unwrap();
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(ErrorThenScript { calls: Mutex::new(0), seen: seen.clone() }), config);
        agent.new_session().unwrap();

        // First attempt schedules one continuation, then the provider errors and
        // the turn is left pending on this live Agent.
        let first = agent.run_turn(Some("in-1"), "go").await;
        assert!(first.is_err(), "the provider error fails the first attempt: {first:?}");

        // Same-Agent retry of the same input id. With the snapshot's replay
        // boundary advanced in lockstep, recovery restores exactly one spent
        // continuation (count 1, prefix "one "), so the retry has room for two
        // more cut-off chunks ("two ", "three ") before the clean finish.
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(
            outcome.stop_reason,
            StopReason::EndTurn,
            "the budget is spent once, so the turn is not cut short at MaxTokens"
        );
        assert_eq!(
            outcome.response, "one two three four",
            "the recovered prefix is counted once, not doubled into a premature stop"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_tool_run_resets_the_continuation_accumulator() {
        let dir = tempfile::tempdir().unwrap();
        // A cut-off text chunk is accumulated, but then the model runs a tool —
        // a new answer segment begins, so the earlier chunk (and any dropped
        // tool-call markup) must not prefix the final answer (issue #114).
        let (mut agent, _seen) =
            agent(vec![cut_text("stale partial", 100), tool_call("c1"), text("fresh answer")], dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "fresh answer");
    }

    /// An assistant message cut off at the output-token limit, as recorded in a
    /// session log (its `stop_reason` is `length`).
    fn truncated_assistant(content: &str) -> Message {
        Message { stop_reason: Some("length".into()), ..Message::assistant(content) }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn redelivering_a_truncated_turn_replays_its_stop_reason() {
        let dir = tempfile::tempdir().unwrap();
        // A turn that gives up at the continuation cap ends `MaxTokens`.
        let cuts: Vec<LLMResponse> = (0..MAX_TRUNCATED_CONTINUATIONS + 1).map(|_| cut_text("more", 50)).collect();
        let (mut agent, seen) = agent(cuts, dir.path());
        agent.new_session().unwrap();
        let first = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(first.stop_reason, StopReason::MaxTokens);
        seen.lock().unwrap().clear();
        // Redelivering the same input ID returns the recorded truncated stop
        // reason without calling the model, rather than a clean `EndTurn`
        // (issue #114).
        let replay = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(replay.stop_reason, StopReason::MaxTokens);
        assert_eq!(replay.response, first.response);
        assert!(seen.lock().unwrap().is_empty(), "a recorded turn is not re-run");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_truncated_turns_stop_reason_survives_a_reload() {
        let dir = tempfile::tempdir().unwrap();
        let cuts: Vec<LLMResponse> = (0..MAX_TRUNCATED_CONTINUATIONS + 1).map(|_| cut_text("more", 50)).collect();
        let (mut first, _) = agent(cuts, dir.path());
        let id = first.new_session().unwrap();
        assert_eq!(first.run_turn(Some("in-1"), "go").await.unwrap().stop_reason, StopReason::MaxTokens);
        // The persisted `TurnEnd` carries the truncated stop reason.
        drop(first);
        let (_, restored) = SessionLog::open(dir.path(), &id).unwrap();
        assert_eq!(restored.stop_reasons.get("in-1"), Some(&StopReason::MaxTokens));

        // After a reload, redelivering the input still reports `MaxTokens` from
        // the log, not a clean `EndTurn`, without calling the model (issue #114).
        let (mut second, seen) = agent(vec![], dir.path());
        second.load_session(&id).unwrap();
        let replay = second.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(replay.stop_reason, StopReason::MaxTokens);
        assert!(seen.lock().unwrap().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_after_a_logged_continuation_reminder_stitches_the_prefix() {
        // Interrupt case (a): the turn was cut off at the output limit AND its
        // continuation reminder was logged before the crash. The resume must
        // continue the turn and prepend the saved prefix, not start empty
        // (issue #114).
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "cut-a",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("partial "))),
                Record::Message(Box::new(
                    Message::user(&reminders::wrap(&truncated_continuation_note(50))).continuation(),
                )),
            ],
        );
        let (mut agent, seen) = agent(vec![text("done")], dir.path());
        agent.load_session("cut-a").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "partial done");
        // The model was called once to continue — the already-logged reminder is
        // not duplicated.
        let request = &seen.lock().unwrap()[0];
        let reminders = request.iter().filter(|m| m.auto_initiated).count();
        assert_eq!(reminders, 1, "the existing reminder is reused, not re-pushed");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_before_a_logged_continuation_reminder_re_prompts_and_stitches() {
        // Interrupt case (b): the turn was cut off at the output limit but the
        // crash landed before its continuation reminder was logged. The resume
        // must re-push the reminder so the model continues, and still prepend the
        // saved prefix (issue #114).
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "cut-b",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("partial "))),
            ],
        );
        let (mut agent, seen) = agent(vec![text("done")], dir.path());
        agent.load_session("cut-b").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "partial done");
        // A continuation reminder was synthesized so the model actually continues.
        let request = &seen.lock().unwrap()[0];
        let note = request.iter().rev().find(|m| m.auto_initiated).expect("a continuation reminder");
        assert!(note.content.contains("cut off"), "{}", note.content);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_truncated_final_assistant_is_not_replayed_as_a_clean_finish() {
        // A length-truncated trailing assistant message must NOT be treated as a
        // finished turn by the resume replay shortcut: the turn resumes and
        // continues instead of completing with a clean `EndTurn` (issue #114).
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "cut-final",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("partial "))),
            ],
        );
        let (mut agent, seen) = agent(vec![text("done")], dir.path());
        agent.load_session("cut-final").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        // The model was called (the turn continued) rather than short-circuited.
        assert!(!seen.lock().unwrap().is_empty(), "the truncated turn resumed with a model call");
        assert_eq!(outcome.response, "partial done");
    }

    /// A client that rejects any request whose `max_tokens` exceeds `cap`
    /// (mirroring a provider's output-limit rejection), then serves `response`.
    struct OutputCapClient {
        cap: i64,
        seen_max_tokens: Arc<Mutex<Vec<i64>>>,
        response: Mutex<Option<LLMResponse>>,
        /// Side effect run on the first rejection (e.g. publish a probed cap).
        on_reject: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    }

    #[async_trait]
    impl LLMClient for OutputCapClient {
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            let max_tokens = request.max_tokens.unwrap_or(0);
            self.seen_max_tokens.lock().unwrap().push(max_tokens);
            if max_tokens > self.cap {
                if let Some(hook) = self.on_reject.lock().unwrap().take() {
                    hook();
                }
                anyhow::bail!(
                    "max_tokens: {max_tokens} > {}, which is the maximum allowed number of output tokens",
                    self.cap
                );
            }
            Ok(self.response.lock().unwrap().clone().unwrap_or_default())
        }
        fn model_name(&self) -> &str {
            "scripted"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
        fn kind(&self) -> Option<providers::ProviderKind> {
            Some(providers::ProviderKind::Openai)
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_output_limit_rejection_is_learned_and_retried() {
        // Automatic `max_tokens` sends the large default to a model whose real
        // output cap `/models` never published (e.g. a freshly switched model
        // whose background probe has not landed). The rejection must be learned
        // and the request retried at the real cap, not fail the turn (issue
        // #114).
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = OutputCapClient {
            cap: 8_000,
            seen_max_tokens: seen.clone(),
            response: Mutex::new(Some(text("recovered"))),
            on_reject: Mutex::new(None),
        };
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "recovered");
        let sent = seen.lock().unwrap().clone();
        // First attempt sent the over-cap default and was rejected; the retry
        // sent a value within the learned cap.
        assert_eq!(sent.len(), 2, "one rejected attempt, then one retry: {sent:?}");
        assert!(sent[0] > 8_000, "first attempt sent the over-cap default: {}", sent[0]);
        assert!(sent[1] <= 8_000, "retry sent within the learned cap: {}", sent[1]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_output_limit_rejection_is_retried_against_the_sent_budget() {
        // The learned cap must be compared to the budget the request actually
        // *sent*, not the current (already-lowered) base. Simulate a background
        // probe that publishes the real cap *after* the request is built but
        // *before* its rejection is handled — the send uses the over-cap
        // fallback, then the base drops to the published cap. The retry must
        // still happen (the sent budget exceeded the cap) rather than
        // concluding `learned < base` is false and failing the turn (issue
        // #114).
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        // Build the agent around a placeholder client, grab its
        // `reported_max_output` slot, then swap in the cap client whose
        // rejection publishes the probed cap into that slot — the interleaving
        // where the base drops between the send and the rejection handling.
        let mut agent = Agent::new(
            Box::new(Scripted { responses: Mutex::new(vec![]), seen: Arc::new(Mutex::new(vec![])) }),
            config,
        );
        let reported = agent.reported_max_output.clone();
        let client = OutputCapClient {
            cap: 8_000,
            seen_max_tokens: seen.clone(),
            response: Mutex::new(Some(text("recovered"))),
            on_reject: Mutex::new(Some(Box::new(move || {
                *reported.lock().unwrap() = Some(8_000);
            }))),
        };
        agent.client = Box::new(client);
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "recovered");
        let sent = seen.lock().unwrap().clone();
        assert_eq!(sent.len(), 2, "one rejected attempt, then one retry: {sent:?}");
        assert!(sent[0] > 8_000, "first attempt sent the over-cap fallback: {}", sent[0]);
        assert!(sent[1] <= 8_000, "retry sent within the learned cap: {}", sent[1]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn replay_after_a_crash_rebuilds_the_whole_answer() {
        // Interrupt: the turn was cut off at the output limit (logging a
        // truncated chunk + reminder), then produced its clean final chunk, and
        // the crash landed before `TurnEnd`. The replay shortcut must rebuild
        // the *contiguous* answer — truncated prefix plus the final chunk — not
        // record only the final chunk (issue #114).
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "replay-prefix",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("partial "))),
                Record::Message(Box::new(
                    Message::user(&reminders::wrap(&truncated_continuation_note(50))).continuation(),
                )),
                Record::Message(Box::new(Message::assistant("done"))),
            ],
        );
        let (mut agent, seen) = agent(vec![], dir.path());
        agent.load_session("replay-prefix").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "partial done", "the replay rebuilds the whole answer, not just the tail");
        assert!(seen.lock().unwrap().is_empty(), "a recorded answer is replayed, not re-run");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_restores_the_continuation_budget_before_a_tool_run() {
        // The continuation budget is turn-wide, not just the trailing answer
        // run: two continuations, a tool run (which clears the answer
        // accumulator), and a third continuation must restore a count of 3, so
        // the resumed turn knows the budget is already spent (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let reminder = || Message::user(&reminders::wrap(&truncated_continuation_note(50))).continuation();
        crashed_session(
            dir.path(),
            "budget",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("a"))),
                Record::Message(Box::new(reminder())),
                Record::Message(Box::new(truncated_assistant("b"))),
                Record::Message(Box::new(reminder())),
                Record::Message(Box::new(Message::assistant_with_tools(
                    "",
                    vec![ToolCall {
                        id: "c1".into(),
                        name: "echo".into(),
                        arguments: json!({"text": "pong"}),
                        item_id: None,
                        malformed_arguments: None,
                    }],
                ))),
                Record::Message(Box::new(Message::tool_result("c1", "echo", "pong"))),
                Record::Message(Box::new(truncated_assistant("c"))),
                Record::Message(Box::new(reminder())),
            ],
        );
        // The budget (3) is already spent; the resumed turn must end `MaxTokens`
        // without issuing another continuation request. The single scripted
        // `cut_text` serves the post-tool continuation that the logged reminder
        // drives; the resumed turn appends the final logged chunk, hits the
        // spent budget, and stops.
        let (mut agent, seen) = agent(vec![cut_text("c", 50)], dir.path());
        agent.load_session("budget").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTokens, "the spent budget ends the turn at the cap");
        // Only the post-tool continuation ran; no request is sent once the
        // budget is spent.
        assert_eq!(seen.lock().unwrap().len(), 1, "one continuation request, then the budget stops the turn");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_restores_continuation_state_before_session_start_context() {
        // A resume `SessionStart` hook that supplies context appends a user
        // message *after* the persisted turn tail. The continuation scan must
        // read the messages logged *before* that hook context, or it stops at
        // the hook boundary and loses the truncated prefix (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let settings = json!({
            "hooks": {
                "SessionStart": [ { "matcher": "resume", "hooks": [ { "type": "command", "command": "echo hook-context" } ] } ]
            }
        });
        let claude = dir.path().join(".claude");
        std::fs::create_dir_all(&claude).unwrap();
        std::fs::write(claude.join("settings.json"), serde_json::to_string(&settings).unwrap()).unwrap();
        crashed_session(
            dir.path(),
            "hook-resume",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("partial "))),
            ],
        );
        let (mut agent, seen) = agent(vec![text("done")], dir.path());
        agent.load_claude_hooks(dir.path());
        agent.load_session("hook-resume").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "partial done", "the prefix is restored despite the hook context");
        // The model was called to continue (the turn did not short-circuit),
        // and the SessionStart context was still delivered.
        let request = &seen.lock().unwrap()[0];
        assert!(
            request.iter().any(|m| m.role == Role::User && m.content.contains("hook-context")),
            "SessionStart context is still delivered: {request:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_stops_reconstruction_at_a_stop_hook_reprompt() {
        // A Stop-hook re-prompt is `auto_initiated` like a continuation
        // reminder, but it begins a NEW answer segment. A logged truncated
        // `stale` chunk, a Stop-hook prompt, and a clean `fresh` reply must
        // replay as just `fresh` — the scan must stop at the Stop-hook prompt,
        // not reach back into the discarded `stale` prefix (issue #114).
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "stop-hook",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("stale"))),
                // A Stop-hook re-prompt: auto_initiated but NOT a continuation.
                Record::Message(Box::new(Message::user(&reminders::wrap("stop-hook reason")).auto_initiated())),
                Record::Message(Box::new(Message::assistant("fresh"))),
            ],
        );
        let (mut agent, seen) = agent(vec![], dir.path());
        agent.load_session("stop-hook").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "fresh", "the Stop-hook segment is not prefixed by the discarded chunk");
        assert!(seen.lock().unwrap().is_empty(), "a recorded clean answer is not re-run");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_before_a_stop_hook_reply_does_not_restore_the_discarded_prefix() {
        // The second crash point: a truncated `stale` chunk and a Stop-hook
        // re-prompt are logged, then the crash lands BEFORE the fresh reply.
        // The resumed turn continues from the Stop-hook prompt; the seeding
        // scan must NOT restore the discarded `stale` prefix into the new
        // answer (issue #114).
        let dir = tempfile::tempdir().unwrap();
        crashed_session(
            dir.path(),
            "stop-hook-seed",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("stale"))),
                // The Stop-hook re-prompt is the last logged message.
                Record::Message(Box::new(Message::user(&reminders::wrap("stop-hook reason")).auto_initiated())),
            ],
        );
        let (mut agent, seen) = agent(vec![text("fresh")], dir.path());
        agent.load_session("stop-hook-seed").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "fresh", "the continued answer is not prefixed by the discarded chunk");
        assert_eq!(seen.lock().unwrap().len(), 1, "the model is called once to answer the Stop-hook prompt");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_after_compaction_restores_the_persisted_continuation() {
        // A mid-turn compaction folds the truncated chunks into the summary, so
        // the conversation tail no longer holds them. The continuation state
        // persisted in the `Replace` record must still restore the answer prefix
        // and the turn-wide count, so the resumed turn stitches the whole answer
        // (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "compact-resume").unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        // The in-flight turn had two truncated chunks (count 2, text "one two ")
        // when a compaction folded them away; the Replace record carries that
        // state and keeps the pending input alive at the restated position.
        log.append(&Record::Replace {
            messages: vec![
                Message::system("sys"),
                Message::user("summary"),
                Message::user("run it"), // restated pending input
            ],
            pending_position: Some(2),
            summarized: Some((2, 6)),
            mode: Some(crate::config::CompactionMode::Standard),
            model: None,
            continuation: Some(("one two ".to_string(), 2)),
            recorded_at: session::now(),
        })
        .unwrap();
        drop(log);
        // The resumed turn continues from the restored prefix and count.
        let (mut agent, seen) = agent(vec![text("three")], dir.path());
        agent.load_session("compact-resume").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "one two three", "the persisted prefix is restored despite the compaction");
        assert_eq!(seen.lock().unwrap().len(), 1, "the model is called once to finish the turn");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_after_compaction_with_a_spent_budget_ends_max_tokens() {
        // A crash after a mid-turn compaction that followed the budget-spending
        // chunk: the persisted count is already at the cap, so the recovered
        // turn must end `MaxTokens` WITHOUT calling the model again (issue
        // #114).
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "compact-spent").unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        log.append(&Record::Replace {
            messages: vec![
                Message::system("sys"),
                Message::user("summary"),
                Message::user("run it"),
                // The last logged chunk was truncated (the crash landed before
                // its reminder), so the turn was mid-continuation.
                Message { stop_reason: Some("length".into()), ..Message::assistant("tail") },
            ],
            pending_position: Some(2),
            summarized: Some((2, 6)),
            mode: Some(crate::config::CompactionMode::Standard),
            model: None,
            continuation: Some(("one two three ".to_string(), MAX_TRUNCATED_CONTINUATIONS)),
            recorded_at: session::now(),
        })
        .unwrap();
        drop(log);
        let (mut agent, seen) = agent(vec![text("should not be called")], dir.path());
        agent.load_session("compact-spent").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTokens, "the spent budget ends the recovered turn");
        assert_eq!(outcome.response, "one two three ", "the accumulated answer is preserved");
        assert!(seen.lock().unwrap().is_empty(), "an exhausted recovered turn makes no model call");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_after_compaction_replays_chunks_logged_after_the_summary() {
        // A mid-turn compaction persisted the snapshot `("one ", 1)`, then the
        // turn logged a *further* truncated chunk and its reminder before the
        // crash. Recovery must replay those post-compaction records over the
        // snapshot — not stop at the persisted state — so the later chunk and
        // its spent continuation are not lost (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "compact-extra").unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        log.append(&Record::Replace {
            messages: vec![Message::system("sys"), Message::user("summary"), Message::user("run it")],
            pending_position: Some(2),
            summarized: Some((2, 6)),
            mode: Some(crate::config::CompactionMode::Standard),
            model: None,
            continuation: Some(("one ".to_string(), 1)),
            recorded_at: session::now(),
        })
        .unwrap();
        // Logged *after* the compaction: a second truncated chunk and its
        // reminder, then the crash.
        log.append(&Record::Message(Box::new(truncated_assistant("two ")))).unwrap();
        log.append(&Record::Message(Box::new(
            Message::user(&reminders::wrap(&truncated_continuation_note(50))).continuation(),
        )))
        .unwrap();
        drop(log);
        let (mut agent, seen) = agent(vec![text("three")], dir.path());
        agent.load_session("compact-extra").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "one two three", "the post-compaction chunk is folded into the whole answer");
        assert_eq!(seen.lock().unwrap().len(), 1, "the model is called once to finish the turn");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_after_compaction_resets_the_prefix_on_a_post_summary_tool_run() {
        // A post-compaction tool run begins a new answer segment, so the
        // persisted continuation prefix must be dropped from the eventual text
        // answer — its tool-call markup must not leak into it, even across the
        // compaction boundary (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "compact-tool").unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        log.append(&Record::Replace {
            messages: vec![Message::system("sys"), Message::user("summary"), Message::user("run it")],
            pending_position: Some(2),
            summarized: Some((2, 6)),
            mode: Some(crate::config::CompactionMode::Standard),
            model: None,
            continuation: Some(("one ".to_string(), 1)),
            recorded_at: session::now(),
        })
        .unwrap();
        // Logged after the compaction: a tool run that resets the answer
        // segment, then the crash before the fresh answer.
        log.append(&Record::Message(Box::new(Message::assistant_with_tools(
            "",
            vec![ToolCall {
                id: "c1".into(),
                name: "echo".into(),
                arguments: json!({"text": "pong"}),
                item_id: None,
                malformed_arguments: None,
            }],
        ))))
        .unwrap();
        log.append(&Record::Message(Box::new(Message::tool_result("c1", "echo", "pong")))).unwrap();
        drop(log);
        let (mut agent, seen) = agent(vec![text("fresh")], dir.path());
        agent.load_session("compact-tool").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "fresh", "the post-tool answer is not prefixed by the discarded continuation");
        assert_eq!(seen.lock().unwrap().len(), 1, "the model is called once after the tool run");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_after_compaction_replays_a_logged_clean_final_answer() {
        // A clean final answer logged *after* a mid-turn compaction, with the
        // crash before `TurnEnd`. The replay shortcut (no model call) must fold
        // the persisted snapshot prefix back in, not record only the final
        // chunk — the shortcut must be checkpoint-aware too (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "compact-clean").unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        log.append(&Record::Replace {
            messages: vec![Message::system("sys"), Message::user("summary"), Message::user("run it")],
            pending_position: Some(2),
            summarized: Some((2, 6)),
            mode: Some(crate::config::CompactionMode::Standard),
            model: None,
            continuation: Some(("one ".to_string(), 1)),
            recorded_at: session::now(),
        })
        .unwrap();
        // The clean final chunk logged after the compaction; the crash landed
        // before `TurnEnd`.
        log.append(&Record::Message(Box::new(Message::assistant("done")))).unwrap();
        drop(log);
        let (mut agent, seen) = agent(vec![text("should not be called")], dir.path());
        agent.load_session("compact-clean").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "one done", "the replay shortcut folds the persisted prefix into the answer");
        assert!(seen.lock().unwrap().is_empty(), "a recorded answer is replayed, not re-run");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_preserves_the_prefix_across_an_interleaved_timer_message() {
        // A timer fired mid-turn, between a truncated chunk and its final
        // chunk, and the crash landed before `TurnEnd`. The fired-timer user
        // message is a harness injection, not a new answer segment, so the
        // replay must keep the interrupted answer's prefix across it instead of
        // clearing it (issue #150).
        let dir = tempfile::tempdir().unwrap();
        let mut log = SessionLog::create(dir.path(), "timer-prefix").unwrap();
        log.append(&Record::Message(Box::new(Message::system("sys")))).unwrap();
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() }).unwrap();
        log.append(&Record::Message(Box::new(Message::user("run it")))).unwrap();
        // The in-flight turn: a truncated chunk, its continuation reminder, then
        // a fired timer's user message lands before the clean final chunk.
        log.append(&Record::Message(Box::new(truncated_assistant("one ")))).unwrap();
        log.append(&Record::Message(Box::new(
            Message::user(&reminders::wrap(&truncated_continuation_note(50))).continuation(),
        )))
        .unwrap();
        log.append(&Record::Message(Box::new(Message::user(&Timers::fired_batch_message(&[], Local::now())).timer())))
            .unwrap();
        log.append(&Record::Message(Box::new(Message::assistant("two")))).unwrap();
        drop(log);
        let (mut agent, seen) = agent(vec![text("should not be called")], dir.path());
        agent.load_session("timer-prefix").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(
            outcome.response, "one two",
            "the fired-timer message does not clear the interrupted answer's prefix"
        );
        assert!(seen.lock().unwrap().is_empty(), "a recorded answer is replayed, not re-run");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_after_the_third_cutoff_still_issues_the_last_continuation() {
        // No compaction: a crash after the third truncated chunk but before its
        // continuation reminder was logged. Only *two* reminders were scheduled,
        // so the live loop would have incremented to the third and requested a
        // fourth chunk — recovery must match it and issue that request, not
        // miscount the three truncated *replies* as three scheduled
        // continuations and end `MaxTokens` a request early (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let reminder = || Message::user(&reminders::wrap(&truncated_continuation_note(50))).continuation();
        crashed_session(
            dir.path(),
            "third-cutoff",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("a"))),
                Record::Message(Box::new(reminder())),
                Record::Message(Box::new(truncated_assistant("b"))),
                Record::Message(Box::new(reminder())),
                // The third truncated chunk, then the crash before its reminder.
                Record::Message(Box::new(truncated_assistant("c"))),
            ],
        );
        let (mut agent, seen) = agent(vec![text("d")], dir.path());
        agent.load_session("third-cutoff").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn, "the budget still had room for the fourth request");
        assert_eq!(outcome.response, "abcd", "the final chunk is stitched onto the recovered prefix");
        // The recovered turn re-pushed the missing reminder and issued the
        // fourth continuation request that completed the answer.
        assert_eq!(seen.lock().unwrap().len(), 1, "one continuation request finishes the turn");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn resume_with_a_spent_budget_before_turn_end_ends_max_tokens() {
        // No compaction: a crash after the fourth (budget-spending) truncated
        // chunk but before `TurnEnd`. Three reminders were scheduled (the cap),
        // so the recovered turn must end `MaxTokens` without another model call
        // — a clean reply would otherwise be recorded `EndTurn`, hiding the
        // cut-off (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let reminder = || Message::user(&reminders::wrap(&truncated_continuation_note(50))).continuation();
        crashed_session(
            dir.path(),
            "spent",
            vec![
                Record::Message(Box::new(Message::user("run it"))),
                Record::Message(Box::new(truncated_assistant("a"))),
                Record::Message(Box::new(reminder())),
                Record::Message(Box::new(truncated_assistant("b"))),
                Record::Message(Box::new(reminder())),
                Record::Message(Box::new(truncated_assistant("c"))),
                Record::Message(Box::new(reminder())),
                // The fourth truncated chunk spends the budget; the crash lands
                // before its reminder (which the cap would never schedule).
                Record::Message(Box::new(truncated_assistant("d"))),
            ],
        );
        let (mut agent, seen) = agent(vec![text("should not be called")], dir.path());
        agent.load_session("spent").unwrap();
        let outcome = agent.run_turn(Some("msg-1"), "run it").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTokens, "the spent budget ends the recovered turn");
        assert_eq!(outcome.response, "abcd", "the accumulated chunks are preserved");
        assert!(seen.lock().unwrap().is_empty(), "an exhausted recovered turn makes no model call");
    }

    fn echo_stream(n: usize) -> Vec<LLMResponse> {
        (1..=n)
            .map(|i| LLMResponse {
                tool_calls: vec![ToolCall {
                    id: format!("c{i}"),
                    name: "echo".into(),
                    arguments: json!({"text": format!("pong {i}")}),
                    item_id: None,
                    malformed_arguments: None,
                }],
                ..Default::default()
            })
            .collect()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_headless_turn_with_no_cap_stops_at_the_safety_cap() {
        let dir = tempfile::tempdir().unwrap();
        // max_iterations = 0 (unbounded) and a model that never stops calling.
        let (mut agent, seen) = agent(echo_stream(HEADLESS_SAFETY_CAP + 10), dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTurnRequests);
        assert_eq!(seen.lock().unwrap().len(), HEADLESS_SAFETY_CAP);
        assert!(outcome.outcome.is_none(), "a cap stop reports no outcome");
        assert!(
            outcome.response.contains(&format!("stopped after {HEADLESS_SAFETY_CAP} LLM calls")),
            "{}",
            outcome.response
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn auto_mode_does_not_disable_the_cap_in_a_headless_turn() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(echo_stream(HEADLESS_SAFETY_CAP + 10), dir.path());
        // A positive configured cap (not 0) and Auto set *after* new_session()
        // (which resets the mode to Normal) so the 300-call limit can only come
        // from Auto's headless fallback, not from the `max_iterations == 0`
        // path — otherwise a regression in the Auto branch would still pass.
        agent.config.max_iterations = HEADLESS_SAFETY_CAP + 50;
        agent.new_session().unwrap();
        agent.set_mode(crate::mode::AgentMode::Auto);
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTurnRequests);
        assert_eq!(seen.lock().unwrap().len(), HEADLESS_SAFETY_CAP);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn switching_to_auto_mid_turn_keeps_the_headless_safety_cap() {
        // The safety cap must follow the *live* mode, not a pre-loop snapshot:
        // a headless turn that starts in Normal (interactive-looking, unbounded
        // under the snapshot) and is switched to Auto mid-turn must still stop at
        // the 300-call safety cap rather than run unbounded (issue #65).
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(echo_stream(HEADLESS_SAFETY_CAP + 10), dir.path());
        // A positive configured cap above the safety cap, so the Normal snapshot
        // is unbounded-at-300 only via the live-mode recompute, not the
        // `max_iterations == 0` path.
        agent.config.max_iterations = HEADLESS_SAFETY_CAP + 50;
        let control = agent.control();
        agent.new_session().unwrap();
        // Flip Normal → Auto after the first model call is in flight.
        let switcher = tokio::spawn(async move {
            tokio::task::yield_now().await;
            control.set_mode(crate::mode::AgentMode::Auto);
        });
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        switcher.await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::MaxTurnRequests);
        assert_eq!(seen.lock().unwrap().len(), HEADLESS_SAFETY_CAP);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_interactive_session_keeps_an_unbounded_zero_cap() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(echo_loop(20), dir.path());
        agent.questions().set_interactive(true);
        agent.new_session().unwrap();
        // With a human present, max_iterations = 0 stays unbounded — and the
        // loop detector alone ends the repeat loop (blocked, not capped).
        let outcome = agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(seen.lock().unwrap().len(), reminders::REPEAT_WARN_AFTER + reminders::REPEAT_MAX_WARNINGS);
        assert_eq!(outcome.outcome.map(|o| o.status), Some(goal::Status::Blocked));
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
        assert!(tool.content.contains("\"image\""), "the structured result is stringified unchanged: {}", tool.content);
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

    /// Store `bytes` as an attachment in `dir` and return the matching reference,
    /// so the wire plan's availability gate (`attachment::exists`) sees it as
    /// present and intact. The stored bytes need not decode — `exists` only
    /// hash-matches — and the `width`/`height` are the logical dimensions the
    /// token estimator charges, independent of the bytes.
    fn stored_image(dir: &std::path::Path, bytes: &[u8], w: u32, h: u32) -> crate::llm::Attachment {
        let attachment = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("x.png"),
            sha256: crate::attachment::sha256_hex(bytes),
            width: w,
            height: h,
            bytes: bytes.len(),
            extension: "png".into(),
        };
        crate::attachment::store(dir, &attachment, bytes).unwrap();
        attachment
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
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
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
    async fn a_compaction_summary_is_retried_after_learning_the_output_cap() {
        // Compaction builds its summary request from the automatic output base
        // but must not bypass the output-cap recovery: an unpublished cap that
        // rejects the over-budget summary must be learned and the summary
        // retried at the lower value, not dropped to the lost-history fallback
        // (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = OutputCapClient {
            cap: 8_000,
            seen_max_tokens: seen.clone(),
            // `clone()`d each call, so the retried summary still returns a
            // non-empty body.
            response: Mutex::new(Some(text("SUMMARY: compacted"))),
            on_reject: Mutex::new(None),
        };
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        agent.new_session().unwrap();
        // A turn with some history to fold. The turn's own request fits the cap;
        // only the larger summary budget is rejected.
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert_eq!(report.fallback, None, "the summary succeeded on retry, not the dropped-history fallback");
        let sent = seen.lock().unwrap().clone();
        let over = sent.iter().filter(|&&m| m > 8_000).count();
        assert!(over >= 1, "the over-cap summary was attempted first: {sent:?}");
        let last = *sent.last().unwrap();
        assert!(last <= 8_000, "the retried summary sent within the learned cap: {sent:?}");
    }

    /// A client whose output-cap rejection carries NO parseable numeric limit,
    /// so the fallback path (halving) runs. Rejects only a *summary* request
    /// (detected by the compaction system prompt) over `cap`, so the setup chat
    /// turn is unaffected.
    struct NumberlessCapClient {
        cap: i64,
        seen_max_tokens: Arc<Mutex<Vec<i64>>>,
        response: Mutex<Option<LLMResponse>>,
    }

    #[async_trait]
    impl LLMClient for NumberlessCapClient {
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            let max_tokens = request.max_tokens.unwrap_or(0);
            let is_summary =
                request.messages.first().is_some_and(|m| m.role == Role::System && m.content.contains("compacting"));
            if is_summary {
                self.seen_max_tokens.lock().unwrap().push(max_tokens);
            }
            if is_summary && max_tokens > self.cap {
                // No number for `output_cap_from_error` to parse: the fallback
                // must derive the cap from the sent budget, not the chat base.
                anyhow::bail!("max_tokens is too large for this model");
            }
            Ok(self.response.lock().unwrap().clone().unwrap_or_default())
        }
        fn model_name(&self) -> &str {
            "scripted"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
        fn kind(&self) -> Option<providers::ProviderKind> {
            Some(providers::ProviderKind::Openai)
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_compaction_summary_cap_fallback_halves_the_sent_budget() {
        // With no numeric limit in the rejection, the fallback must halve the
        // budget the summary request actually *sent* (12,288 here), not the
        // chat base. Halving the 32,768 base infers 16,384 — not below the
        // 12,288 sent budget — so `learned < budget` is false and the retry is
        // skipped, dropping history (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        // The real cap (7,000) sits just below the 12,288 summary budget, so
        // the first summary is rejected; the halved-budget retry (6,144) fits.
        // A fallback that wrongly halves the 32,768 chat base infers 16,384 —
        // not below the 12,288 sent budget — so `learned < budget` is false and
        // the retry is skipped, dropping history (issue #114).
        let client = NumberlessCapClient {
            cap: 7_000,
            seen_max_tokens: seen.clone(),
            response: Mutex::new(Some(text("SUMMARY: compacted"))),
        };
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert_eq!(report.fallback, None, "the summary succeeded on the halved-budget retry: {report}");
        let sent = seen.lock().unwrap().clone();
        // Only summary requests are recorded by this client.
        assert!(sent.len() >= 2, "an over-cap summary, then a retry: {sent:?}");
        assert_eq!(sent[0], 12_288, "the first summary sent the full budget over the cap: {sent:?}");
        // The retry halved the *sent* summary budget (12,288 → 6,144), not the
        // 32,768 chat base (which would give 16,384 — not below 12,288 — and
        // skip the retry, dropping history).
        assert_eq!(sent[1], 6_144, "the retry halved the sent budget: {sent:?}");
        assert!(sent[1] <= 7_000, "the retried summary fits the cap: {sent:?}");
    }

    /// A client that rejects its FIRST chat request with an output-cap error
    /// carrying no parseable numeric limit (so the halving fallback runs), then
    /// succeeds. Records every request's `max_tokens`.
    struct ChatCapFallbackClient {
        seen_max_tokens: Arc<Mutex<Vec<i64>>>,
        calls: Arc<Mutex<usize>>,
    }

    #[async_trait]
    impl LLMClient for ChatCapFallbackClient {
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            self.seen_max_tokens.lock().unwrap().push(request.max_tokens.unwrap_or(0));
            let mut calls = self.calls.lock().unwrap();
            *calls += 1;
            if *calls == 1 {
                // No number for `output_cap_from_error` to parse: the fallback
                // must derive the cap from the sent budget, not the chat base.
                anyhow::bail!("max_tokens is too large for this model");
            }
            Ok(text("recovered"))
        }
        fn model_name(&self) -> &str {
            "scripted"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
        fn kind(&self) -> Option<providers::ProviderKind> {
            Some(providers::ProviderKind::Openai)
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_chat_output_cap_fallback_halves_the_sent_budget() {
        // A chat turn whose request is context-clamped below the 32,768 base is
        // rejected with an output-cap error carrying no numeric limit. The
        // fallback must halve the budget the request actually *sent*
        // (`request_max_tokens`), not the unclamped base: halving the base
        // lands *above* the clamped request, so `learned < request` is false,
        // the retry is skipped, and the turn fails instead of recovering (issue
        // #114).
        let dir = tempfile::tempdir().unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let client = ChatCapFallbackClient { seen_max_tokens: seen.clone(), calls: Arc::new(Mutex::new(0)) };
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            // A large base with a small total window clamps the request well
            // below the base, so halving the base cannot lower it.
            max_tokens: 32_768,
            context_window: Some(16_000),
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.new_session().unwrap();
        let response = agent.send_message("ping").await.unwrap();
        assert_eq!(response, "recovered", "the context-clamped retry recovered the turn");
        let sent = seen.lock().unwrap().clone();
        assert_eq!(sent.len(), 2, "an over-cap request, then the halved retry: {sent:?}");
        assert!(sent[0] < 32_768, "the request was context-clamped below the base: {sent:?}");
        // The crux: the clamped request sits at or below the base's half, so a
        // base-derived fallback (16,384) would not lower it and the retry would
        // be skipped — only halving the *sent* budget recovers the turn.
        assert!(sent[0] <= 16_384, "the base's half would not lower the clamped request: {sent:?}");
        assert_eq!(sent[1], sent[0] / 2, "the retry halves the sent budget, not the base: {sent:?}");
    }

    /// A client that rejects the FIRST summary request with a numeric
    /// output-cap error (so the summary is retried) and, on that same call,
    /// queues a `/model` switch — the interleaving where a switch lands while
    /// the first summary attempt is in flight (issue #114).
    struct SwitchOnSummaryClient {
        cap: i64,
        control: Mutex<Option<TurnControl>>,
        summary_calls: Arc<Mutex<usize>>,
    }

    #[async_trait]
    impl LLMClient for SwitchOnSummaryClient {
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            let max_tokens = request.max_tokens.unwrap_or(0);
            let is_summary =
                request.messages.first().is_some_and(|m| m.role == Role::System && m.content.contains("compacting"));
            if is_summary {
                let mut calls = self.summary_calls.lock().unwrap();
                *calls += 1;
                if *calls == 1 {
                    // Queue a `/model` switch while this first summary attempt is
                    // "in flight", then reject it for exceeding the cap.
                    self.control.lock().unwrap().as_ref().unwrap().set_model("mock/switched");
                    anyhow::bail!(
                        "max_tokens: {max_tokens} > {}, which is the maximum allowed number of output tokens",
                        self.cap
                    );
                }
            }
            Ok(text("SUMMARY: compacted"))
        }
        fn model_name(&self) -> &str {
            "scripted"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
        fn kind(&self) -> Option<providers::ProviderKind> {
            Some(providers::ProviderKind::Openai)
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_compaction_summary_retry_honours_a_pending_model_switch() {
        // A `/model` queued while the first summary attempt awaits its
        // output-cap rejection must be honoured before the retry: the retry
        // goes to the NEW model, not the one the user switched away from
        // (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let summary_calls = Arc::new(Mutex::new(0usize));
        let client =
            SwitchOnSummaryClient { cap: 8_000, control: Mutex::new(None), summary_calls: summary_calls.clone() };
        let config = Config {
            session_dir: Some(dir.path().to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        let slot = Arc::new(client);
        struct Shared(Arc<SwitchOnSummaryClient>);
        #[async_trait]
        impl LLMClient for Shared {
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                Box::new(Shared(self.0.clone()))
            }
            async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
                self.0.chat(request).await
            }
            fn model_name(&self) -> &str {
                "scripted"
            }
            fn provider_name(&self) -> &str {
                "test"
            }
            fn kind(&self) -> Option<providers::ProviderKind> {
                Some(providers::ProviderKind::Openai)
            }
        }
        let mut agent = Agent::new(Box::new(Shared(slot.clone())), config);
        *slot.control.lock().unwrap() = Some(agent.control());
        agent.tools().register(
            ToolDefinition::new("echo", "echo", json!({"type": "object"})),
            Box::new(|args| Ok(json!(args["text"].as_str().unwrap_or("").to_string()))),
        );
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert_eq!(report.fallback, None, "the summary succeeded on the new model: {report}");
        // Exactly one summary attempt went to the original client (the rejected
        // one); the retry was applied on the switched-to mock client.
        assert_eq!(*summary_calls.lock().unwrap(), 1, "only the rejected attempt hit the old model");
        assert_eq!(agent.model_name(), "switched", "the retry honoured the queued switch");
        assert_eq!(agent.control().take_model_request(), None, "the switch was consumed");
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
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
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
    ///
    /// Memory is off and its directory is pinned under `dir`: the default store
    /// lives in the user's real data directory, so leaving it enabled would leak
    /// the machine's own memories into the system prompt and with them into the
    /// token estimates these tests assert on.
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
            memory_dir: Some(dir.join("memory")),
            memory: crate::config::MemoryMode::Off,
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
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
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
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
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
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("test double is never cloned")
            }
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("test double is never cloned")
            }
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("test double is never cloned")
            }
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("test double is never cloned")
            }
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
    async fn an_unset_max_tokens_defaults_to_the_models_published_output_limit() {
        // No configured `max_tokens` (0 = unset): the request defaults to the
        // model's own output limit reported by the endpoint, not an arbitrary
        // small number. A configured value overrides it, and the context clamp
        // still applies in both cases.
        let dir = tempfile::tempdir().unwrap();
        let window = 200_000;
        let (mut agent, seen) = budgeted_agent(vec![big_call("b1"), text("done")], window, 4_000, dir.path());
        agent.config_mut().max_tokens = 0;
        agent.config_mut().context_window = None;
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: window,
            source: "Copilot /models max_context_window_tokens".into(),
            cap: ContextCap::Total,
            total_tokens: None,
            max_output_tokens: Some(64_000),
        });
        assert_eq!(agent.effective_max_tokens(), 64_000);
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        // The roomy window leaves the published limit unclamped.
        assert_eq!(seen.lock().unwrap()[0], (Some(64_000), false));

        // A configured value overrides the published limit.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = budgeted_agent(vec![big_call("b1"), text("done")], window, 4_000, dir.path());
        agent.config_mut().context_window = None;
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: window,
            source: "Copilot /models max_context_window_tokens".into(),
            cap: ContextCap::Total,
            total_tokens: None,
            max_output_tokens: Some(64_000),
        });
        // budgeted_agent configures max_tokens = 16_384.
        assert_eq!(agent.effective_max_tokens(), 16_384);
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "go").await.unwrap();
        assert_eq!(seen.lock().unwrap()[0], (Some(16_384), false));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_unset_max_tokens_uses_a_known_model_cap_before_the_large_fallback() {
        // gpt-4o / gpt-4o-mini cap output at 16,384 but do not publish it via
        // `/models`. With no configured or detected limit the automatic default
        // must honour that known cap, not the large unknown-model fallback that
        // the API would reject for a short prompt (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _seen) = budgeted_agent(vec![text("done")], 200_000, 4_000, dir.path());
        agent.config_mut().max_tokens = 0;
        assert!(agent.detected_max_output().is_none(), "no endpoint-published limit in this test");
        agent.config_mut().model = "gpt-4o-mini".into();
        assert_eq!(agent.effective_max_tokens(), 16_384);
        // An unknown model still gets the large fallback, unchanged.
        agent.config_mut().model = "some-unlisted-model".into();
        assert_eq!(agent.effective_max_tokens(), DEFAULT_MAX_OUTPUT_TOKENS);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_configured_window_preserves_the_probed_output_limit() {
        // With a configured context window the window probe is skipped and the
        // detected window stays empty, but the endpoint's published output limit
        // lives in its own slot so the automatic max_tokens still honours it
        // instead of collapsing to the large fallback (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _seen) = budgeted_agent(vec![text("done")], 200_000, 4_000, dir.path());
        agent.config_mut().max_tokens = 0;
        // The configured-window probe path leaves the detected window empty.
        assert!(agent.detected_window.lock().unwrap().is_none());
        // ...yet the output limit it read from the shared `/models` entry stands.
        *agent.reported_max_output.lock().unwrap() = Some(16_000);
        assert_eq!(agent.detected_max_output(), Some(16_000));
        assert_eq!(agent.effective_max_tokens(), 16_000);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_unset_max_tokens_falls_back_to_a_large_default_when_unpublished() {
        // No configured limit, no published one, and no *known* cap for the
        // model name: the large fallback is used, far above the old 4096
        // default, still clamped to the context window (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _seen) = budgeted_agent(vec![text("done")], 200_000, 4_000, dir.path());
        agent.config_mut().max_tokens = 0;
        agent.config_mut().model = "some-unlisted-model".into();
        assert_eq!(agent.effective_max_tokens(), DEFAULT_MAX_OUTPUT_TOKENS);
        const { assert!(DEFAULT_MAX_OUTPUT_TOKENS > 4096) };
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
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
            max_output_tokens: None,
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
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: detected,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
            max_output_tokens: None,
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
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: Some(combined),
            max_output_tokens: None,
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
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: Some(combined),
            max_output_tokens: None,
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
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
            max_output_tokens: None,
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
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: Some(advertised),
            max_output_tokens: None,
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
        *agent.detected_window.lock().unwrap() = Some(DetectedWindow {
            tokens: prompt_window,
            source: "Copilot /models max_prompt_tokens".into(),
            cap: ContextCap::Prompt,
            total_tokens: None,
            max_output_tokens: None,
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
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
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
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("test double is never cloned")
        }
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("test double is never cloned")
            }
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                Box::new(Reports)
            }
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
        assert!(agent.detected_window.lock().unwrap().is_none(), "no probe when config sets the window");
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
            fn clone_boxed(&self) -> Box<dyn LLMClient> {
                unimplemented!("test double is never cloned")
            }
            async fn chat(&self, _: &ChatRequest<'_>) -> Result<LLMResponse> {
                unreachable!()
            }
            async fn detect_capabilities(
                &self,
            ) -> (Option<DetectedWindow>, Option<crate::thinking::Reported>, Option<crate::vision::Vision>, Option<usize>)
            {
                self.calls.lock().unwrap().push("capabilities");
                (Some(DetectedWindow::total(65_536, "test")), None, None, None)
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
            agent.reported_thinking.lock().unwrap().as_ref().map(|r| r.levels.as_slice()),
            Some(["off".to_string(), "on".to_string()].as_slice()),
            "the thinking levels are still probed"
        );
        assert!(agent.detected_window.lock().unwrap().is_none(), "the configured window stands");
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

    #[test]
    fn calibrated_estimate_recomputes_when_a_suffix_image_displaces_a_prefix_image() {
        // The calibrated anchor charged the prefix's one in-quota image at full
        // image cost. A later `read_file` adds a newer image that, under
        // `max_images = 1`, displaces the prefix image into a placeholder on the
        // wire. Keeping the anchor's full-image cost *and* adding the new image
        // would double-charge past the quota and overestimate context (tripping
        // compaction early); the estimate must instead recompute the whole
        // conversation to mirror the real newest-N wire plan.
        let (mut agent, _) = agent(vec![], std::path::Path::new("/nonexistent"));
        *agent.reported_vision.lock().unwrap() = Some(crate::vision::Vision {
            max_images: 1,
            max_image_bytes: crate::attachment::DEFAULT_MAX_BYTES,
            media_types: Vec::new(),
        });
        // Both occurrences are intact on disk, so availability does not confound
        // the displacement the test exercises. Unique bytes keep this image's
        // sidecar distinct from any other test sharing the process temp dir.
        let adir = agent.attachments_dir();
        let img = stored_image(&adir, b"calib-displace-image", 1000, 1000);
        // Prefix: one message carrying an image, anchored to a reported total.
        agent.conversation.push(Message::user("look").with_attachments(vec![img.clone()]));
        agent.calibration = Some((agent.conversation.len(), 5_000));
        // No suffix yet: the anchor stands (no displacement).
        assert_eq!(agent.estimate_context_tokens(), (5_000, true));
        // A newer image in the suffix displaces the prefix image.
        agent.conversation.push(Message::user("again").with_attachments(vec![img.clone()]));
        let (tokens, calibrated) = agent.estimate_context_tokens();
        assert!(!calibrated, "a displaced prefix image invalidates the anchor");
        let tools: usize = agent
            .tool_definitions()
            .iter()
            .map(|d| {
                context::text_tokens(&d.name)
                    + context::text_tokens(&d.description)
                    + context::text_tokens(&d.parameters.to_string())
            })
            .sum();
        let available = context::available_attachments(&agent.conversation, Some(&agent.attachments_dir()));
        let expected = context::messages_tokens_with_vision(&agent.conversation, 1, &available) + tools;
        assert_eq!(tokens, expected, "recomputes the whole conversation per the wire plan");
        // The stale-anchor behaviour would have double-charged the prefix image.
        let stale = 5_000 + context::messages_tokens_with_vision(&agent.conversation[1..], 1, &available);
        assert!(tokens < stale, "recompute avoids the double-charge: {tokens} < {stale}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn compaction_tail_budget_mirrors_the_vision_wire_plan() {
        // The kept-tail budget must charge attachments the way the wire does:
        // only the newest `max_images` as images, older ones as short text
        // placeholders. Charging every attachment its full image cost
        // overcounts an image-heavy tail and discards far more recent history
        // than `KEEP_RECENT_TOKENS` intends.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("SUMMARY"), text("done")], dir.path());
        *agent.reported_vision.lock().unwrap() = Some(crate::vision::Vision {
            max_images: 1,
            max_image_bytes: crate::attachment::DEFAULT_MAX_BYTES,
            media_types: Vec::new(),
        });
        // A small window so the threshold trips and an auto (Threshold)
        // compaction runs; the keep budget is `KEEP_RECENT_TOKENS.min(window/4)`.
        // Memory off keeps the system prompt small so the image tail (not the
        // prompt) dominates the keep budget.
        agent.config.context_window = Some(6_000);
        agent.config.auto_compact_threshold = 0.5;
        agent.config.project_instructions = false;
        agent.config.memory = crate::config::MemoryMode::Off;
        agent.new_session().unwrap();
        // The image must be intact on disk for the wire plan (and so the kept-tail
        // budget) to count it as a sendable image rather than a placeholder.
        let img_ref = stored_image(&agent.attachments_dir(), b"compaction-tail-image", 1000, 1000);
        let img = || img_ref.clone();
        // One large old text turn, then 120 image turns. The keep budget is
        // window/4 = 1,500. Under `max_images = 1` the wire sends only the
        // newest image (~1,334 tokens); the 119 older ones are placeholders
        // (~14 tokens each with framing), so the image tail exceeds the budget
        // only after ~12 placeholders accrue. The split therefore lands
        // mid-list, keeping the newest ~12 image turns (1 image + ~11
        // placeholders ≈ 1,488) and folding the oldest ~108. Charging every
        // image in full (~120 × 1,340) would blow the budget after the very
        // first (newest) turn and fold all 119 older ones. The leading large
        // text turn is always folded.
        agent.conversation.push(Message::user(&"big ".repeat(4_000)));
        for i in 0..120 {
            agent.conversation.push(Message::user(&format!("img{i}")).with_attachments(vec![img()]));
        }
        agent.send_message("go").await.unwrap();
        assert_eq!(agent.context_stats().lock().unwrap().compactions, 1, "threshold compaction ran");
        let conversation = agent.conversation().to_vec();
        let kept: Vec<&str> = conversation.iter().map(|m| m.content.as_str()).collect();
        assert!(!kept.iter().any(|c| c.contains("big")), "the large text turn is folded: {kept:?}");
        // The newest image turn is always kept; the wire-mirroring budget keeps
        // a run of older image turns as placeholders that full-image accounting
        // (which would keep only the single newest) would have folded.
        assert!(kept.contains(&"img119"), "newest image turn kept: {kept:?}");
        let kept_images = kept.iter().filter(|c| c.starts_with("img")).count();
        assert!(kept_images > 1, "wire-mirroring budget keeps older image turns as placeholders, kept {kept_images}");
        assert!(
            kept_images < 120,
            "the image tail still exceeds the budget, so the oldest are folded, kept {kept_images}"
        );
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

    /// A client whose `chat_stream` emits a visible partial delta and then
    /// drops the connection (`StreamInterrupted`) for its first `breaks`
    /// attempts, answering in full afterwards. Mirrors a network that cuts out
    /// mid-reply and then recovers.
    struct BreaksMidReply {
        breaks_left: Mutex<u32>,
        answer: String,
        attempts: Arc<Mutex<u32>>,
    }

    #[async_trait]
    impl LLMClient for BreaksMidReply {
        fn clone_boxed(&self) -> Box<dyn LLMClient> {
            unimplemented!("tests never clone this client")
        }
        async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
            // Non-streaming fallback mirrors the streaming path's break/answer.
            self.chat_stream(request, &|_| {}).await
        }
        async fn chat_stream(
            &self,
            _request: &ChatRequest<'_>,
            sink: crate::llm::StreamSink<'_>,
        ) -> Result<LLMResponse> {
            *self.attempts.lock().unwrap() += 1;
            // Deliver some visible output, as a real stream would before it breaks.
            sink(StreamEvent::Text("partial reply "));
            {
                let mut left = self.breaks_left.lock().unwrap();
                if *left > 0 {
                    *left -= 1;
                    return Err(anyhow::Error::new(providers::StreamInterrupted {
                        reason: "connection reset by peer".into(),
                    }));
                }
            }
            sink(StreamEvent::Text(&self.answer));
            Ok(LLMResponse { content: self.answer.clone(), stop_reason: Some("stop".into()), ..Default::default() })
        }
        fn model_name(&self) -> &str {
            "breaks"
        }
        fn provider_name(&self) -> &str {
            "test"
        }
    }

    fn breaks_mid_reply_agent(breaks: u32, answer: &str, dir: &std::path::Path) -> (Agent, Arc<Mutex<u32>>) {
        let attempts = Arc::new(Mutex::new(0));
        let client =
            BreaksMidReply { breaks_left: Mutex::new(breaks), answer: answer.to_string(), attempts: attempts.clone() };
        let config = Config {
            session_dir: Some(dir.to_path_buf()),
            project_instructions: false,
            skills: crate::skills::SkillsConfig { enabled: false, ..Default::default() },
            ..Config::default()
        };
        let mut agent = Agent::new(Box::new(client), config);
        agent.set_streaming(true);
        // Streaming is only taken when an event sink is present.
        agent.set_event_sink(std::sync::Arc::new(|_, _| {}));
        (agent, attempts)
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn mid_reply_drops_are_retried_and_leave_no_partial_text_in_history() {
        // The stream breaks mid-reply twice, then answers: the agent discards
        // each partial reply and re-sends, so the turn completes with the full
        // answer and history holds no partial text.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, attempts) = breaks_mid_reply_agent(2, "the full answer", dir.path());
        agent.new_session().unwrap();
        let outcome = agent.run_turn(Some("in-1"), "hi").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(*attempts.lock().unwrap(), 3, "two breaks then one successful answer");
        let assistant: Vec<&str> =
            agent.conversation().iter().filter(|m| m.role == Role::Assistant).map(|m| m.content.as_str()).collect();
        assert_eq!(assistant, ["the full answer"], "only the full answer is recorded");
        assert!(
            !agent.conversation().iter().any(|m| m.content.contains("partial reply")),
            "no partial, mid-reply text reaches history"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn mid_reply_restart_emits_a_reset_event_before_resending() {
        // On each mid-reply break the agent emits `ResponseRestarted` so the
        // renderers discard the abandoned partial (and reset pending thinking)
        // before the re-sent stream's deltas arrive. Without it the replacement
        // answer is appended to the stale prefix and the final message is lost.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _attempts) = breaks_mid_reply_agent(2, "the full answer", dir.path());
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        agent.set_event_sink(std::sync::Arc::new(move |_, event| {
            let name = match event {
                AgentEvent::TextDelta { text } => format!("text-delta:{text}"),
                AgentEvent::ResponseRestarted => "restart".to_string(),
                AgentEvent::AssistantMessage { text, .. } => format!("message:{text}"),
                _ => return,
            };
            sink.lock().unwrap().push(name);
        }));
        agent.new_session().unwrap();
        agent.run_turn(Some("in-1"), "hi").await.unwrap();
        let seen = events.lock().unwrap().clone();
        // Two breaks -> two resets, each emitted after a shown partial and
        // before the request is re-sent.
        assert_eq!(seen.iter().filter(|e| *e == "restart").count(), 2, "one reset per mid-reply break: {seen:?}");
        assert_eq!(seen[0], "text-delta:partial reply ", "a partial is shown first: {seen:?}");
        assert_eq!(seen[1], "restart", "the reset follows the abandoned partial: {seen:?}");
        assert_eq!(seen.last().unwrap(), "message:the full answer", "the turn still completes whole: {seen:?}");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn too_many_mid_reply_drops_end_the_turn() {
        // One more break than the cap (`MAX_STREAM_RESTARTS`) is not recovered:
        // the turn ends with an error instead of asking forever.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, attempts) = breaks_mid_reply_agent(MAX_STREAM_RESTARTS + 1, "never reached", dir.path());
        agent.new_session().unwrap();
        let error = agent.run_turn(Some("in-1"), "hi").await.unwrap_err();
        assert!(format!("{error:#}").contains("connection lost mid-reply"), "{error:#}");
        // The cap bounds the re-sends: the initial send plus `MAX_STREAM_RESTARTS`
        // retries, all of which broke.
        assert_eq!(*attempts.lock().unwrap(), MAX_STREAM_RESTARTS + 1);
        assert!(
            agent.conversation().iter().all(|m| m.role != Role::Assistant),
            "a turn that never completed records no assistant message"
        );
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

    /// 12:00 local today, for the timer tests' injected clock.
    fn timer_noon() -> DateTime<Local> {
        let date = Local::now().date_naive();
        date.and_hms_opt(12, 0, 0).unwrap().and_local_timezone(Local).single().unwrap()
    }

    /// A shared clock at noon, so a tool the test registers can advance time
    /// mid-turn.
    fn timer_clock() -> std::sync::Arc<std::sync::Mutex<DateTime<Local>>> {
        std::sync::Arc::new(std::sync::Mutex::new(timer_noon()))
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_timer_set_in_a_turn_fires_mid_turn_when_the_clock_passes_it() {
        let dir = tempfile::tempdir().unwrap();
        let clock = timer_clock();
        let responses = vec![
            call("t1", "timer_set", json!({"after": "30m", "note": "check CI"})),
            // Advances the injected clock past the timer, so it fires at the
            // start of the next step — a deploy finishing while the turn runs.
            call("e1", "advance_clock", json!({})),
            text("done"),
        ];
        let (mut agent, seen) = agent(responses, dir.path());
        let events = record_events(&mut agent);
        agent.set_timers_now(Some(clock.clone()));
        let clock2 = clock.clone();
        agent.tools().register(
            ToolDefinition::new("advance_clock", "advance the clock", json!({"type": "object"})),
            Box::new(move |_| {
                *clock2.lock().unwrap() += chrono::Duration::minutes(31);
                Ok(json!("advanced"))
            }),
        );
        agent.new_session().unwrap();
        agent.run_turn(Some("msg-1"), "watch the build").await.unwrap();

        // The timer fired into the conversation as a user message the last
        // model call saw.
        let turns = seen.lock().unwrap();
        let last = turns.last().unwrap();
        let fired =
            last.iter().find(|m| m.role == Role::User && m.content.contains("fired:")).expect("a fired timer message");
        assert!(
            fired.content.contains("Timer 1, set at 12:00, fired: check CI")
                && fired.content.starts_with("<system-reminder>")
                && fired.content.contains("call timer_done with its id"),
            "{}",
            fired.content
        );
        // The UI event shows `⏰ timer N: <note>` through the userMessage event.
        let events = events.lock().unwrap();
        assert!(
            events.iter().any(|e| {
                e["content"]["text"].as_str() == Some("⏰ timer 1: check CI")
                    && e["sessionUpdate"].as_str() == Some("user_message_chunk")
            }),
            "{events:?}"
        );
        // It fired once: no active timers left, and it is now pending (waiting
        // to be marked done).
        assert!(agent.timers().is_empty());
        assert!(agent.timers().has_pending());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn disabled_timers_neither_fire_nor_nudge_on_a_turn() {
        // An ACP-resumed CLI session has no idle loop to fire timers, so
        // `disable_timers()` hides the timer tools. A due restored timer must
        // then stay put: firing or nudging here would ask the agent to
        // acknowledge a timer with a `timer_done` tool it no longer has, and
        // would consume state a later CLI resume still needs.
        let dir = tempfile::tempdir().unwrap();
        let clock = timer_clock();
        let (mut agent, seen) = agent(vec![text("done")], dir.path());
        agent.set_timers_now(Some(clock.clone()));
        agent.new_session().unwrap();
        // A restored timer that is already due by the time the turn runs.
        let now = *clock.lock().unwrap();
        agent.timers.apply("timer_set", &json!({"after": "30m", "note": "check CI"}), now).unwrap();
        *clock.lock().unwrap() += chrono::Duration::minutes(31);
        agent.disable_timers();
        agent.run_turn(Some("msg-1"), "look").await.unwrap();

        // No fired-timer message or nudge reached the model, and the timer is
        // untouched (still active, not fired/pending).
        {
            let turns = seen.lock().unwrap();
            assert!(
                turns.iter().all(|t| t.iter().all(|m| {
                    !m.content.contains("fired:") && !m.content.contains("Fired timers you haven't marked done:")
                })),
                "a disabled timer must not fire or nudge: {turns:?}"
            );
        }
        assert_eq!(agent.timers().len(), 1);
        assert!(!agent.timers().has_pending());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_pending_timer_nudges_every_few_steps_until_marked_done() {
        let dir = tempfile::tempdir().unwrap();
        let clock = timer_clock();
        // timer_set, advance the clock so it fires at the next step, then run
        // enough no-op steps to cross `PENDING_NUDGE_EVERY`, mark it done, and
        // run more steps to confirm the nudges stop. Distinct `echo` arguments
        // keep the repeat-loop detector from ending the turn.
        let mut responses = vec![
            call("t1", "timer_set", json!({"after": "30m", "note": "check CI"})),
            call("adv", "advance_clock", json!({})),
        ];
        for i in 0..crate::timers::PENDING_NUDGE_EVERY {
            responses.push(call(&format!("e{i}"), "echo", json!({"text": format!("step {i}")})));
        }
        responses.push(call("done", "timer_done", json!({"id": 1})));
        for i in 0..crate::timers::PENDING_NUDGE_EVERY {
            responses.push(call(&format!("f{i}"), "echo", json!({"text": format!("after {i}")})));
        }
        responses.push(text("ok"));

        let (mut agent, seen) = agent(responses, dir.path());
        agent.set_timers_now(Some(clock.clone()));
        let clock2 = clock.clone();
        agent.tools().register(
            ToolDefinition::new("advance_clock", "advance the clock", json!({"type": "object"})),
            Box::new(move |_| {
                *clock2.lock().unwrap() += chrono::Duration::minutes(31);
                Ok(json!("advanced"))
            }),
        );
        agent.new_session().unwrap();
        agent.run_turn(Some("msg-1"), "watch the build").await.unwrap();

        // Exactly one nudge was pushed before `timer_done`, and none after.
        let turns = seen.lock().unwrap();
        let last = turns.last().unwrap();
        let nudges = last
            .iter()
            .filter(|m| m.role == Role::User && m.content.contains("Fired timers you haven't marked done:"))
            .count();
        assert_eq!(nudges, 1, "one nudge total: {last:#?}");
        // The timer was marked done, so nothing is pending anymore.
        assert!(!agent.timers().has_pending());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn idle_take_fired_timers_returns_due_timers_once() {
        let dir = tempfile::tempdir().unwrap();
        let clock = timer_clock();
        let noon = *clock.lock().unwrap();
        let (mut agent, _) = agent(vec![], dir.path());
        agent.set_timers_now(Some(clock.clone()));
        agent.new_session().unwrap();
        agent.timers.apply("timer_set", &json!({"after": "30m", "note": "check CI"}), noon).unwrap();
        // Not yet due.
        assert!(agent.take_fired_timers().unwrap().is_empty());
        *clock.lock().unwrap() += chrono::Duration::minutes(31);
        let fired = agent.take_fired_timers().unwrap();
        assert_eq!(fired.len(), 1);
        assert_eq!(fired[0].note, "check CI");
        assert!(agent.take_fired_timers().unwrap().is_empty(), "a timer fires once");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn idle_firing_resets_the_pending_nudge_counter() {
        // Regression (PR #151): idle delivery calls `take_fired_timers`
        // directly. If an earlier pending timer left the nudge counter near its
        // threshold, a fresh idle firing must restart the interval so the next
        // model step does not immediately re-nudge.
        let dir = tempfile::tempdir().unwrap();
        let clock = timer_clock();
        let noon = *clock.lock().unwrap();
        let (mut agent, _) = agent(vec![], dir.path());
        agent.set_timers_now(Some(clock.clone()));
        agent.new_session().unwrap();
        // Simulate a counter advanced to the nudge threshold by an earlier
        // pending timer.
        agent.pending_timer_steps = timers::PENDING_NUDGE_EVERY - 1;
        agent.timers.apply("timer_set", &json!({"after": "30m", "note": "check CI"}), noon).unwrap();
        *clock.lock().unwrap() += chrono::Duration::minutes(31);
        let fired = agent.take_fired_timers().unwrap();
        assert_eq!(fired.len(), 1, "the timer fired via idle delivery");
        assert_eq!(agent.pending_timer_steps, 0, "a fresh firing restarts the nudge interval");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_automatic_timer_turn_marks_its_message_auto_initiated() {
        // Regression (PR #151): a timer wakeup carries no new user input, so
        // its user message must bill as agent-initiated.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![text("ok")], dir.path());
        agent.new_session().unwrap();
        agent.mark_auto_turn();
        agent.run_turn(None, "⏰ timer 1: check CI").await.unwrap();
        let auto = agent
            .conversation
            .iter()
            .find(|m| m.role == Role::User && m.content.contains("timer 1"))
            .expect("the timer user message");
        assert!(auto.auto_initiated, "an automatic timer turn is agent-initiated");

        // A following genuine user turn is NOT auto-initiated (the flag is
        // consumed once).
        let (mut agent2, _) = self::agent(vec![text("ok")], dir.path());
        agent2.new_session().unwrap();
        agent2.run_turn(None, "hello").await.unwrap();
        let user = agent2
            .conversation
            .iter()
            .find(|m| m.role == Role::User && m.content.contains("hello"))
            .expect("the user message");
        assert!(!user.auto_initiated, "a user-typed turn stays user-initiated");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn timers_survive_resume_and_restart_clears_them() {
        let dir = tempfile::tempdir().unwrap();
        let noon = timer_noon();
        let (mut agent, _) = agent(vec![], dir.path());
        let id = agent.new_session().unwrap();
        agent.timers.apply("timer_set", &json!({"after": "1h", "note": "check CI"}), noon).unwrap();
        agent.timers_changed().unwrap();

        let (mut resumed, _) = self::agent(vec![], dir.path());
        resumed.load_session(&id).unwrap();
        assert_eq!(resumed.timers().len(), 1);
        assert_eq!(resumed.timers().items[0].note, "check CI");

        // `/restart` (a new session) clears them.
        resumed.new_session().unwrap();
        assert!(resumed.timers().is_empty());
    }

    #[test]
    fn timer_tools_are_hidden_when_timers_are_disabled() {
        let dir = tempfile::tempdir().unwrap();
        let (mut on, _) = agent(Vec::new(), dir.path());
        assert!(on.tool_definitions().iter().any(|d| d.name == "timer_set"));
        on.disable_timers();
        assert!(!on.tool_definitions().iter().any(|d| d.name.starts_with("timer_")));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_timer_tool_persistence_failure_rolls_the_live_timers_back() {
        // A cancel/ack that fails to persist must not drop the timer in memory
        // while reporting an error: live and persisted/published state would
        // diverge. The tool must roll the live timers back (issue #150 review).
        let dir = tempfile::tempdir().unwrap();
        let clock = timer_clock();
        let (mut agent, _) = agent(Vec::new(), dir.path());
        agent.set_timers_now(Some(clock.clone()));
        agent.new_session().unwrap();

        let set = ToolCall {
            id: "s1".into(),
            name: "timer_set".into(),
            arguments: json!({"after": "30m", "note": "check CI"}),
            item_id: None,
            malformed_arguments: None,
        };
        agent.run_timer_tool(&set).unwrap();
        assert_eq!(agent.timers().len(), 1);

        // A cancel whose persist fails leaves the timer live (rolled back) and
        // surfaces the error.
        agent.fail_next_persist();
        let cancel = ToolCall {
            id: "c1".into(),
            name: "timer_cancel".into(),
            arguments: json!({"id": 1}),
            item_id: None,
            malformed_arguments: None,
        };
        assert!(agent.run_timer_tool(&cancel).is_err());
        assert_eq!(agent.timers().len(), 1, "a failed persist must not drop the live timer");

        // With persistence working, the same cancel succeeds and clears it.
        agent.run_timer_tool(&cancel).unwrap();
        assert!(agent.timers().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_plan_tool_persistence_failure_rolls_the_live_plan_back() {
        // Same apply-then-persist atomicity for the plan tool (sibling class).
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(Vec::new(), dir.path());
        agent.new_session().unwrap();

        agent.fail_next_persist();
        let add = ToolCall {
            id: "p1".into(),
            name: "plan_add".into(),
            arguments: json!({"items": ["write the fix"]}),
            item_id: None,
            malformed_arguments: None,
        };
        assert!(agent.run_plan_tool(&add).is_err());
        assert!(agent.plan.is_empty(), "a failed persist must not leave the live plan changed");

        // With persistence working, the add lands.
        agent.run_plan_tool(&add).unwrap();
        assert!(!agent.plan.is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_firing_persistence_failure_rolls_the_due_timers_back() {
        // Same apply-then-persist atomicity for the idle firing path
        // (`take_fired_timers`, sibling class). `take_due` moves the due timer
        // out of `items`; if the persist fails, the timer must be restored so a
        // retry re-fires it and delivers the reminder, and the nudge counter
        // must not be reset (issue #150 review).
        let dir = tempfile::tempdir().unwrap();
        let clock = timer_clock();
        let noon = *clock.lock().unwrap();
        let (mut agent, _) = agent(Vec::new(), dir.path());
        agent.set_timers_now(Some(clock.clone()));
        agent.new_session().unwrap();
        agent.pending_timer_steps = timers::PENDING_NUDGE_EVERY - 1;
        agent.timers.apply("timer_set", &json!({"after": "30m", "note": "check CI"}), noon).unwrap();
        agent.timers_changed().unwrap();
        *clock.lock().unwrap() += chrono::Duration::minutes(31);

        // The firing's persist fails: the due timer is rolled back (still an
        // active item, not consumed into `pending`) and the nudge counter is
        // untouched, so a later retry re-fires it.
        agent.fail_next_persist();
        assert!(agent.take_fired_timers().is_err());
        assert_eq!(agent.timers().items.len(), 1, "a failed firing persist must not consume the due timer");
        assert!(!agent.timers().has_pending(), "the rolled-back timer must not linger in pending");
        assert_eq!(
            agent.pending_timer_steps,
            timers::PENDING_NUDGE_EVERY - 1,
            "a rolled-back firing must not reset the nudge counter"
        );

        // With persistence working, the same firing delivers once.
        let fired = agent.take_fired_timers().unwrap();
        assert_eq!(fired.len(), 1, "the retry re-fires the previously-rolled-back timer");
        assert_eq!(fired[0].note, "check CI");
        assert_eq!(agent.pending_timer_steps, 0, "a successful firing resets the nudge counter");
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
        // Distinct arguments, so the loop detector (issue #65) stays quiet and
        // only the stale-plan reminder fires.
        responses.extend(
            (0..reminders::PLAN_STALE_AFTER)
                .map(|i| call(&format!("c{i}"), "echo", json!({"text": format!("pong {i}")}))),
        );
        responses.push(text("done"));
        let (mut agent, seen) = agent(responses, dir.path());
        agent.send_message("go").await.unwrap();
        let last = seen.lock().unwrap().last().unwrap().clone();
        let results: Vec<&Message> = last.iter().filter(|m| m.name.as_deref() == Some("echo")).collect();
        assert!(results[..results.len() - 1].iter().enumerate().all(|(i, m)| m.content == format!("pong {i}")));
        let reminded = &results.last().unwrap().content;
        assert!(
            reminded.starts_with(&format!("pong {}\n\n<system-reminder>\n", reminders::PLAN_STALE_AFTER - 1))
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

    #[test]
    fn replay_shows_the_image_marker_on_persisted_tool_results() {
        // ACP `session/load` replays persisted tool results through
        // `replay_message`. A resumed client must still see each attachment's
        // `[image: path, WxH]` marker, matching the live tool-result display —
        // not the bare model-facing text.
        let mut agent =
            Agent::new(Box::new(providers::mock::MockLLMClient::new("mock", "gpt-4o-mini")), Config::default());
        let img = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("x.png"),
            sha256: String::new(),
            width: 12,
            height: 34,
            bytes: 0,
            extension: "png".into(),
        };
        let call = ToolCall {
            id: "t1".into(),
            name: "read_file".into(),
            arguments: json!({}),
            item_id: None,
            malformed_arguments: None,
        };
        agent.conversation.push(Message::assistant_with_tools("", vec![call]));
        agent.conversation.push(Message::tool_result("t1", "read_file", "saw it").with_attachments(vec![img]));
        let events = record_events(&mut agent);
        agent.replay_history();
        let events = events.lock().unwrap().clone();
        let update =
            events.iter().find(|e| e["sessionUpdate"] == "tool_call_update").expect("the tool result is replayed");
        let raw = update["rawOutput"].as_str().unwrap();
        assert!(raw.contains("[image: x.png, 12×34]"), "replay keeps the image marker: {raw}");
        assert!(raw.contains("saw it"), "and the model-facing text: {raw}");
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

    #[tokio::test(flavor = "multi_thread")]
    async fn a_failed_direct_model_switch_still_clears_a_stale_queued_request() {
        // The stale-request clear must happen *before* the fallible client
        // build, not after it. A `/model B` whose client fails to build returns
        // at the `?`; if the stale mid-turn request A were cleared only after a
        // successful build, a failed B would leave A queued and the next turn's
        // first call would silently switch to the superseded A. Clearing up
        // front means a failed direct switch leaves no stale request behind.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = interfering_with(
            vec![],
            dir.path(),
            |_, _| {},
            None,
            |mut config| {
                // Syntactically valid, endpoint configured; only the key lookup
                // fails, so the client fails to build at `set_model` time.
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
        agent.new_session().unwrap();
        agent.control().set_model("mock/leftover");
        agent.set_model("flaky/x").await.expect_err("the unbuildable client fails the switch");
        assert_eq!(
            agent.control().take_model_request(),
            None,
            "the stale request was cleared before the failed build, not left to fire next turn"
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
                        // Fail fast: no retries, a short timeout, and no offline
                        // wait (`offline_budget_ms: 0`) so the unreachable
                        // endpoint surfaces its connect failure at once instead
                        // of waiting for the network to come back.
                        max_retries: Some(0),
                        timeout_secs: Some(2),
                        offline_budget_ms: Some(0),
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
    async fn model_switch_queued_before_manual_compaction_applies_to_the_summary() {
        // A `/model` typed during a turn's final in-flight call stays queued:
        // `run_turn` returns without reaching another apply hook. If the next
        // command is `/compact`, `Agent::compact` summarizes with a model call,
        // which must go to the newly selected model — not the one the user just
        // switched away from. Only the turn's two calls are scripted; a summary
        // left on the old client would pop an empty queue and panic, so a green
        // test proves the switch was applied before the summary.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(vec![tool_call("c1"), text("done")], dir.path());
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        // The still-queued mid-turn switch, left pending after the final call.
        agent.control().set_model("mock/summarizer");
        let report = agent.compact(None, None).await.unwrap().expect("compacted");
        assert!(report.summarized > 0, "the summary call actually ran");
        assert_eq!(agent.provider_name(), "mock", "switch applied before the summary call");
        assert_eq!(agent.model_name(), "summarizer");
        assert_eq!(agent.control().take_model_request(), None, "the request was consumed");
        // The old scripted client served only the turn's two calls, never the
        // summary (which went to the new client).
        assert_eq!(seen.lock().unwrap().len(), 2, "the summary did not go to the old client");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn cancelled_apply_model_request_signals_the_caller_and_keeps_the_request() {
        // A `/model` queued mid-turn plus a cancel that is already pending must
        // not install the new client, and `apply_model_request` must report the
        // cancellation so the caller stops before its next model call —
        // otherwise one call still lands on the (old) model after the user
        // cancelled. The request stays queued for the next turn's first call.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = agent(vec![], dir.path());
        let (provider, model) = (agent.provider_name().to_string(), agent.model_name().to_string());
        agent.control().set_model("mock/summarizer");
        agent.control().cancel();
        assert!(agent.apply_model_request().await, "a cancelled turn signals the caller to stop");
        assert_eq!(agent.provider_name(), provider, "the switch did not apply");
        assert_eq!(agent.model_name(), model);
        assert!(agent.control().has_model_request(), "the request stays queued for the next turn");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn cancel_during_key_command_build_kills_the_child_despite_a_turn_flag_reset() {
        // A `/model` switch cancelled *while its api_key_command child is still
        // building* must kill that child. `apply_model_request` drops the
        // blocking build's `JoinHandle` on cancel, but a dropped
        // `spawn_blocking` task keeps running, so the key-command worker
        // outlives the call. If the worker polled the turn-wide cancel flag,
        // the next turn's `start_turn()` would reset it to `false` before the
        // worker's 50 ms poll saw the cancel, and the supposedly-killed helper
        // would run on until its 120 s timeout. The build-local token the fix
        // uses cannot be reset by the next turn, so the child is killed and the
        // marker its command would touch never appears.
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("LEAKED");
        let (mut agent, _) = agent(vec![], dir.path());
        agent.config.providers.insert(
            "slowmock".to_string(),
            crate::providers::ProviderConfig {
                kind: Some(crate::providers::ProviderKind::Mock),
                default_model: Some("m".to_string()),
                // Sleeps, then (only if not killed) touches the marker. A
                // killed process group never reaches the `touch`.
                api_key_command: Some(format!("sleep 1; touch {}", marker.display())),
                ..Default::default()
            },
        );
        let control = agent.control().clone();
        control.set_model("slowmock/x");
        // Run the build on a task so we can cancel it mid-build (it blocks in
        // the key command's `sleep`), exercising the dropped-handle path rather
        // than the pre-build cancel guard.
        let build = tokio::spawn(async move { agent.apply_model_request().await });
        // Let the blocking build spawn and enter the key command's sleep.
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        control.cancel();
        assert!(build.await.unwrap(), "the cancelled build signals the caller to stop");
        // Simulate the next turn resetting the turn-wide cancel flag before the
        // detached worker's next poll — the exact sequence that let a
        // supposedly-cancelled helper survive when the build observed the
        // turn-wide flag instead of a build-local token.
        control.cancel_flag().store(false, Ordering::SeqCst);
        // Well past both the worker's 50 ms poll and the command's 1 s sleep.
        tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
        assert!(
            !marker.exists(),
            "the cancelled key-command child was killed via the build-local token, not left running \
             past the turn-wide flag reset to touch the marker",
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn cancelled_compaction_does_not_issue_the_summary_call() {
        // A cancel pending when compaction would summarize must stop before the
        // model call rather than race an immediately-ready response onto the
        // old model (the `biased;` select plus the caller guard). Only the
        // turn's two calls are scripted; a summary call would pop an empty
        // queue and panic, so a green test proves none was issued.
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(vec![tool_call("c1"), text("done")], dir.path());
        agent.new_session().unwrap();
        agent.send_message("ping").await.unwrap();
        agent.control().cancel();
        let report = agent.compact_logged(CompactTrigger::Manual, CompactionMode::Standard, None).await.unwrap();
        assert!(report.is_none(), "a cancelled compaction summarizes nothing");
        assert_eq!(seen.lock().unwrap().len(), 2, "no summary call was issued on cancel");
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
            Detected::window(DetectedWindow::total(999, "stale")),
            3,
            current.clone(),
            DetectSlots::window(slot.clone()),
            None,
            stats.clone(),
        );
        assert!(slot.lock().unwrap().is_none(), "a stale probe must not write the window slot");
        assert_eq!(stats.lock().unwrap().window, 0, "a stale probe must not touch the shared stats");

        // A probe for the live generation publishes normally.
        Agent::finish_detect(
            Detected::window(DetectedWindow::total(4096, "fresh")),
            5,
            current.clone(),
            DetectSlots::window(slot.clone()),
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
            Detected::window(DetectedWindow::total(8192, "max_model_len")),
            1,
            current.clone(),
            DetectSlots::window(slot.clone()),
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
            Detected::window(DetectedWindow::total(128_000, "max_model_len")),
            1,
            current.clone(),
            DetectSlots::window(slot.clone()),
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
            Detected::window(DetectedWindow::total(200_000, "max_model_len")),
            1,
            current.clone(),
            DetectSlots::window(slot.clone()),
            None,
            stats.clone(),
        );
        let s = stats.lock().unwrap();
        assert_eq!(s.window, 100_000, "a looser detected window must not replace the learned stat");
        assert_eq!(s.window_source, "learned from a context-overflow error");
    }

    #[test]
    fn an_equal_probe_replaces_a_learned_window_stat_source() {
        // When the detected window equals the learned one,
        // `context_window_with_source()` prefers the detected slot (the
        // `learned < window` guard is false on equality), so the shared stats
        // must follow and relabel the source. Otherwise `/context` keeps saying
        // "learned" while the agent internally reports the endpoint source.
        use std::sync::atomic::AtomicU64;
        let slot = Arc::new(Mutex::new(None));
        let current = Arc::new(AtomicU64::new(1));
        let stats = SharedStats::default();
        {
            let mut s = stats.lock().unwrap();
            s.window = 128_000;
            s.window_source = "learned from a context-overflow error".to_string();
        }
        Agent::finish_detect(
            Detected::window(DetectedWindow::total(128_000, "max_model_len")),
            1,
            current.clone(),
            DetectSlots::window(slot.clone()),
            None,
            stats.clone(),
        );
        let s = stats.lock().unwrap();
        assert_eq!(s.window, 128_000, "the window is unchanged on equality");
        assert!(
            s.window_source.starts_with("reported by the endpoint"),
            "an equal detected window relabels the source to match context_window_with_source: {}",
            s.window_source
        );
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
    async fn a_steer_between_continuations_drops_the_cut_off_prefix() {
        // A length-truncated chunk schedules its continuation, then a steer
        // lands *between* that scheduling and the next iteration's absorb —
        // after the post-response steer check already evaluated no steer. The
        // absorbed steer begins a new answer segment, so the revised answer
        // must NOT be prefixed by the discarded cut-off chunk (issue #114).
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, seen) = agent(vec![cut_text("cut ", 50), text("revised")], dir.path());
        let control = agent.control();
        // Fires right after the cut-off chunk schedules its reminder, mimicking
        // a steer that arrives in the window the post-response check just
        // missed.
        agent.after_continuation_scheduled = Some(Box::new(move || control.steer("change course", None)));
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "write").await.unwrap();
        assert_eq!(outcome.response, "revised", "the steered answer is not prefixed by the discarded cut-off chunk");
        assert_eq!(seen.lock().unwrap().len(), 2, "the cut-off chunk, then the steered continuation");
        let conversation = agent.conversation();
        assert!(
            conversation.iter().any(|m| m.role == Role::User && m.content == "change course"),
            "the steer was absorbed into the turn: {conversation:?}"
        );
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
        let call = LLMResponse {
            tool_calls: vec![ToolCall {
                id: "g1".into(),
                name: "grep".into(),
                arguments: json!({"pattern": "pong"}),
                item_id: None,
                malformed_arguments: None,
            }],
            ..Default::default()
        };
        let (mut agent, _) = agent(vec![call, text("done")], dir.path());
        agent.tools().register(
            ToolDefinition::new("grep", "search", json!({"type": "object"})),
            Box::new(|_| Ok(json!("a.txt:1:pong"))),
        );
        agent.new_session().unwrap();
        agent.set_mode(crate::mode::AgentMode::Plan);
        let outcome = agent.run_turn(None, "search for pong").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        let conversation = agent.conversation();
        let tool_result = conversation.iter().find(|m| m.role == Role::Tool).expect("grep ran");
        assert!(!tool_result.is_error, "grep is read-only and allowed in plan mode");
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
            snapshot.output("/tools", &normal, &crate::plan::Plan::default(), &crate::timers::Timers::default())
        else {
            panic!("/tools produced no block");
        };
        assert!(listing.contains("write_file"), "Plan-mode capture dropped the mutating tool: {listing}");

        // And under a live Plan mode it is still filtered out.
        let plan = crate::context::ContextStats { mode: crate::mode::AgentMode::Plan, ..Default::default() };
        let Some(crate::turn_commands::Output::Block(filtered)) =
            snapshot.output("/tools", &plan, &crate::plan::Plan::default(), &crate::timers::Timers::default())
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
            snapshot.output("/tools", &available, &crate::plan::Plan::default(), &crate::timers::Timers::default())
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
            snapshot.output("/tools", &unavailable, &crate::plan::Plan::default(), &crate::timers::Timers::default())
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
