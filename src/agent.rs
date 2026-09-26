use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::Result;
use chrono::Utc;
use serde_json::{Value, json};

use crate::config::Config;
use crate::context::{self, Activity, SharedStats};
use crate::hooks::{HookContext, HookEvent, HookRegistry};
use crate::instructions::ProjectInstructions;
use crate::skills::{self, Skills};
use crate::goal::{self, Outcome};
use crate::output;
use crate::permissions::Policy;
use crate::plan::{self, Plan};
use crate::reminders::{self, Reminders};
use crate::llm::{ChatRequest, DetectedWindow, LLMClient, LLMResponse, Message, Role, StreamEvent, ToolCall};
use crate::providers;
use crate::session::{self, PendingInput, Record, SessionLog};
use crate::tools::ToolRegistry;

const INTERRUPTED_TOOL_RESULT: &str =
    "Error: the harness stopped before this tool call completed; its outcome is unknown.";
const CANCELLED_TOOL_RESULT: &str = "Error: the turn was cancelled before this tool call ran.";
pub const CANCELLED_RESPONSE: &str = "[turn cancelled]";

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
    /// Only emitted when replaying history.
    UserMessage { text: &'a str },
    AssistantMessage { message_id: &'a str, text: &'a str },
    /// Streamed piece of the assistant's answer (only when streaming).
    TextDelta { text: &'a str },
    /// Streamed piece of the model's reasoning (only when streaming).
    ThinkingDelta { text: &'a str },
    /// The model's complete reasoning for one response, emitted before the
    /// response's `AssistantMessage`.
    Thinking { text: &'a str },
    ToolCall { call: &'a ToolCall },
    ToolResult { call: &'a ToolCall, ok: bool, output: &'a str },
    /// Context statistics or activity changed (see `Agent::context_stats`).
    Context,
    /// The conversation was compacted.
    Compacted,
    /// The task plan changed (or is being replayed).
    Plan { plan: &'a Plan },
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
}

impl std::fmt::Display for CompactReport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "compacted {} messages: ~{} -> ~{} tokens ({} -> {} messages)",
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
pub type EventSink = Box<dyn Fn(Option<&str>, &AgentEvent) + Send + Sync>;

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
    /// Window reported by the endpoint (see `detect_context_window`).
    detected_window: Option<DetectedWindow>,
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
            detected_window: None,
            compact_floor: 0,
            streaming: false,
            instructions: None,
            skills: Skills::default(),
            plan: Plan::default(),
            reminders: Reminders::default(),
            tool_output_limit: output::DEFAULT_MAX_OUTPUT_LENGTH,
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
        let (providers, default_provider) = config.effective_providers();
        providers::build_client(spec, &providers, &default_provider)
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
        self.client = Self::client_for(&self.config, spec)?;
        self.config.model = spec.to_string();
        self.calibration = None;
        self.learned_window = None;
        self.detected_window = None;
        self.compact_floor = 0;
        self.detect_context_window().await;
        Ok(())
    }

    /// Ask the endpoint for the model's context window, unless config sets it.
    pub async fn detect_context_window(&mut self) {
        self.detected_window = None;
        if self.configured_window().is_none() {
            let probe = self.client.detect_context_window();
            self.detected_window = tokio::time::timeout(DETECT_TIMEOUT, probe).await.ok().flatten();
        }
        self.refresh_stats();
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
            .map(|d| context::text_tokens(&d.name) + context::text_tokens(&d.description) + context::text_tokens(&d.parameters.to_string()))
            .sum();
        (context::messages_tokens(&self.conversation) + tools, false)
    }

    /// Recompute the shared statistics and notify the event sink.
    pub fn refresh_stats(&self) {
        let (tokens, calibrated) = self.estimate_context_tokens();
        let cwd = std::env::current_dir()
            .map(|p| p.display().to_string())
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
            stats.plan = (!self.plan.items.is_empty()).then(|| self.plan.progress());
            stats.cwd = cwd;
        }
        self.emit(AgentEvent::Context);
    }

    fn set_activity(&self, activity: Activity) {
        let changed = {
            let mut stats = self.stats.lock().unwrap();
            let changed = stats.activity != activity;
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

    /// Start a fresh conversation, persisted under a new session ID if enabled.
    pub fn new_session(&mut self) -> Result<String> {
        let id = session::new_session_id();
        self.load_project_instructions();
        let system = Message { timestamp: Some(session::now()), ..Message::system(&self.system_prompt()) };
        // Stage the new log before mutating any live state so a disk/permission
        // failure leaves the current session (conversation, id, log) intact
        // instead of detaching the agent from it.
        let session = if self.config.persist_sessions {
            let mut log = SessionLog::create(&self.config.session_dir(), &id)?;
            log.append(&Record::Message(system.clone()))?;
            Some(log)
        } else {
            None
        };
        self.conversation = vec![system];
        self.completed_inputs.clear();
        self.completed_outcomes.clear();
        self.pending_input = None;
        self.plan = Plan::default();
        self.reminders = Reminders::default();
        self.session = session;
        self.session_id = Some(id.clone());
        self.calibration = None;
        self.compact_floor = 0;
        {
            // A fresh session starts with clean cumulative counters so the
            // status line and `/context` reflect only this session. Shared
            // with startup, where these are already zero.
            let mut stats = self.stats.lock().unwrap();
            stats.session_input_tokens = 0;
            stats.session_output_tokens = 0;
            stats.compactions = 0;
        }
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
        self.calibration = None;
        self.compact_floor = 0;
        self.repair_dangling_tool_calls()?;
        self.refresh_stats();
        Ok(())
    }

    /// Give every tool call without a result a synthetic error result, so the
    /// conversation is valid for providers that require paired results.
    fn repair_dangling_tool_calls(&mut self) -> Result<()> {
        let Some(index) = self
            .conversation
            .iter()
            .rposition(|m| m.role == Role::Assistant && !m.tool_calls.is_empty())
        else {
            return Ok(());
        };
        let answered: HashSet<&str> = self.conversation[index + 1..]
            .iter()
            .filter_map(|m| m.tool_call_id.as_deref())
            .collect();
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
            log.append(&Record::Message(message.clone()))?;
        }
        self.conversation.push(message);
        Ok(())
    }

    fn replace_conversation(&mut self, messages: Vec<Message>) -> Result<()> {
        self.replace_keeping_pending(messages, None)
    }

    /// Replace the conversation; `pending_position` keeps the in-flight input
    /// alive with its user message at that index.
    fn replace_keeping_pending(&mut self, mut messages: Vec<Message>, pending_position: Option<usize>) -> Result<()> {
        let now = session::now();
        for message in &mut messages {
            message.timestamp.get_or_insert(now);
        }
        if let Some(log) = &mut self.session {
            log.append(&Record::Replace {
                messages: messages.clone(),
                pending_position,
                recorded_at: now,
            })?;
        }
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
        let extra = self.instructions.as_ref().map(ProjectInstructions::render).unwrap_or_default();
        format!("{}{extra}{}", self.config.system_prompt, self.skills.render_index())
    }

    /// Discover instruction files and skills for the current working directory.
    fn load_project_instructions(&mut self) {
        let enabled = self.config.project_instructions && std::env::var_os("AGENTIC_NO_PROJECT_INSTRUCTIONS").is_none();
        let cwd = std::env::current_dir().ok();
        self.instructions = enabled
            .then(|| cwd.clone())
            .flatten()
            .map(|cwd| ProjectInstructions::discover(&cwd, &self.config.project_instruction_files));
        let skills_enabled = self.config.skills.enabled && std::env::var_os("NANO_CODER_NO_SKILLS").is_none();
        self.skills = match cwd.filter(|_| skills_enabled) {
            Some(cwd) => Skills::discover(&cwd, &self.config.skills),
            None => Skills::default(),
        };
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
            && let Some(response) = self.completed_inputs.get(id) {
                eprintln!("[agent] input {id:?} already processed; returning recorded response");
                return Ok(end_turn((response.clone(), self.completed_outcomes.get(id).cloned())));
            }
        self.control.start_turn();
        self.reminders.start_turn();
        let resuming = self
            .pending_input
            .clone()
            .filter(|pending| input_id == Some(pending.id.as_str()));
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
        let ctx = HookContext::new(HookEvent::AfterContextLoad)
            .with_data("message_count", json!(self.conversation.len()));
        self.hooks.trigger(&ctx);

        let tools = self.tool_definitions();
        let max_iterations = self.config.max_iterations.max(1);
        let mut final_response = None;
        let mut last_content = String::new();
        let mut cancelled = false;
        let mut reported: Option<Outcome> = None;

        for iteration in 1..=max_iterations {
            if self.control.is_cancelled() {
                cancelled = true;
                break;
            }
            self.absorb_steers()?;

            // Trigger before_llm_send hook
            let ctx = HookContext::new(HookEvent::BeforeLLMSend)
                .with_data("iteration", json!(iteration))
                .with_data("message_count", json!(self.conversation.len()))
                .with_data("provider", json!(self.client.provider_name()))
                .with_data("model", json!(self.client.model_name()));
            self.hooks.trigger(&ctx);

            if self.over_threshold() {
                self.compact_logged(CompactTrigger::Threshold, None).await?;
                if self.control.is_cancelled() {
                    cancelled = true;
                    break;
                }
            }

            let mut overflow_retried = false;
            let response = loop {
                self.set_activity(Activity::Thinking);
                let request = ChatRequest {
                    messages: &self.conversation,
                    tools: &tools,
                    temperature: Some(self.config.temperature),
                    max_tokens: Some(self.config.max_tokens as i64),
                };
                let control = self.control.clone();
                let (event_sink, session_id) = (&self.event_sink, self.session_id.as_deref());
                let on_stream = |event: StreamEvent<'_>| {
                    if let Some(sink) = event_sink {
                        match event {
                            StreamEvent::Text(text) => sink(session_id, &AgentEvent::TextDelta { text }),
                            StreamEvent::Thinking(text) => sink(session_id, &AgentEvent::ThinkingDelta { text }),
                        }
                    }
                };
                let call = if self.streaming && event_sink.is_some() {
                    self.client.chat_stream(&request, &on_stream)
                } else {
                    self.client.chat(&request)
                };
                let result = tokio::select! {
                    response = call => Some(response),
                    () = control.cancelled() => None,
                };
                match result {
                    None => break None,
                    Some(Ok(response)) => break Some(response),
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
                        self.learned_window = Some(
                            context::limit_from_error(&message).unwrap_or(estimate * 9 / 10).max(1_000),
                        );
                        eprintln!("[agent] context overflow ({message}); compacting and retrying");
                        let compacted = self.compact_logged(CompactTrigger::Overflow, None).await?;
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
            self.record_usage(&response, true);

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
                self.push(Message { thinking_blocks: response.thinking_blocks.clone(), ..Message::assistant(&response.content) })?;
                self.emit_assistant_text(&response.content);
                // A steer that arrived while the answer was being written gets
                // a reply in this turn rather than being left for the next.
                if iteration < max_iterations && self.control.has_steers() && !self.control.is_cancelled() {
                    last_content = response.content.clone();
                    continue;
                }
                final_response = Some(response.content.clone());
                break;
            }

            last_content = response.content.clone();
            self.push(Message {
                thinking_blocks: response.thinking_blocks.clone(),
                ..Message::assistant_with_tools(&response.content, response.tool_calls.clone())
            })?;
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
                let result = if let Err(reason) = self.policy.check(&tool_call.name, &tool_call.arguments) {
                    // The policy is consulted before dispatching to any handler, so deny
                    // rules and the pre-tool check also cover plan, skill and outcome tools.
                    Err(anyhow::anyhow!(reason))
                } else if is_plan_tool {
                    self.run_plan_tool(tool_call)
                } else if is_skill_tool {
                    self.skills.load(&tool_call.arguments).map(Value::String)
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
                    && let Some(nested) = self.instructions.as_mut().and_then(|i| i.nested_for(std::path::Path::new(path)))
                {
                    result_text.push_str(&nested);
                }
                // bash, read_file and load_skill bound their own output (and bash keeps the whole).
                if !matches!(tool_call.name.as_str(), "bash" | "read_file") && !is_skill_tool {
                    let name = format!("tool-{}-{}.txt", sanitize(&tool_call.id), sanitize(&tool_call.name));
                    result_text = output::bound_and_spill(&result_text, self.tool_output_limit, &output::spill_dir(), &name);
                }
                if self.config.reminders && !is_plan_tool && !is_outcome_tool {
                    for note in self.reminders.after_tool_call(&self.plan) {
                        result_text.push_str("\n\n");
                        result_text.push_str(&reminders::wrap(&note));
                    }
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
                format!("{last_content}\n[stopped after {max_iterations} LLM calls without a final answer]")
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
    /// summary focuses on. Returns `None` when there is nothing to compact.
    pub async fn compact(&mut self, instructions: Option<&str>) -> Result<Option<CompactReport>> {
        self.control.start_turn();
        let report = self.compact_logged(CompactTrigger::Manual, instructions).await;
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

    async fn compact_logged(&mut self, trigger: CompactTrigger, instructions: Option<&str>) -> Result<Option<CompactReport>> {
        self.set_activity(Activity::Compacting);
        let report = self.compact_with(trigger, instructions).await?;
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

    async fn compact_with(&mut self, trigger: CompactTrigger, instructions: Option<&str>) -> Result<Option<CompactReport>> {
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
        let transcript = context::render_transcript(summarized, summary_input_chars);
        let mut request_text = format!("Conversation to summarize:\n\n{transcript}");
        if let Some(focus) = instructions.map(str::trim).filter(|f| !f.is_empty()) {
            request_text.push_str(&format!("\n\nWhen summarizing, focus on: {focus}"));
        }
        let summary_messages = [Message::system(context::SUMMARY_SYSTEM_PROMPT), Message::user(&request_text)];
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
                (format!("{}\n{}", context::SUMMARY_PREFIX, response.content.trim()), None)
            }
            Ok(_) => (self.dropped_note(summarized.len()), Some("empty summary".to_string())),
            Err(e) => (self.dropped_note(summarized.len()), Some(format!("{e:#}"))),
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
                context::clip_message(message, (window / 8).max(1_000));
            }
        }

        let summarized = split - body_start;
        self.replace_keeping_pending(messages, pending_position)?;
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

    fn dropped_note(&self, count: usize) -> String {
        format!("[{count} earlier messages were removed to fit the context window; no summary is available]")
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
    }

    type Seen = Arc<Mutex<Vec<Vec<Message>>>>;

    /// `message` without its timestamp, for comparing with a constructed one.
    fn unstamped(message: &Message) -> Message {
        Message { timestamp: None, ..message.clone() }
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
            tool_calls: vec![ToolCall { id: id.into(), name: "echo".into(), arguments: json!({"text": "pong"}) }],
            ..Default::default()
        }
    }

    fn text(content: &str) -> LLMResponse {
        LLMResponse { content: content.into(), ..Default::default() }
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
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() })
            .unwrap();
        log.append(&Record::Message(Message::user("run it"))).unwrap();
        log.append(&Record::Message(Message::assistant_with_tools(
            "",
            vec![ToolCall { id: "c9".into(), name: "echo".into(), arguments: json!({}) }],
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
        log.append(&Record::Input { id: "msg-1".into(), text: "run it".into(), recorded_at: session::now() })
            .unwrap();
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
                Record::Message(Message::user("run it")),
                Record::Message(Message::assistant("already answered")),
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
        let report = agent.compact(Some("the ping")).await.unwrap().expect("compacted");
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
    async fn auto_compaction_mid_turn_keeps_the_turn_going() {
        let dir = tempfile::tempdir().unwrap();
        let big = LLMResponse {
            tool_calls: vec![ToolCall { id: "b1".into(), name: "big".into(), arguments: json!({}) }],
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
        let overflow = "HTTP 400: This model's maximum context length is 4000 tokens. However, you requested 5000 tokens.".to_string();
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

    #[tokio::test]
    async fn detected_window_sits_between_config_and_model_name() {
        struct Reports;
        #[async_trait]
        impl LLMClient for Reports {
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
        assert!(agent.detected_window.is_none(), "no probe when config sets the window");
    }

    #[test]
    fn estimate_is_anchored_to_reported_usage() {
        let (mut agent, _) = agent(vec![], std::path::Path::new("/nonexistent"));
        let (raw, calibrated) = agent.estimate_context_tokens();
        assert!(!calibrated && raw > 0);
        let response = LLMResponse {
            content: "hi".into(),
            usage: Some(crate::llm::TokenUsage { prompt_tokens: 1_000, completion_tokens: 50, total_tokens: 1_050 }),
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
    async fn adds_project_instructions_to_the_system_prompt_and_nested_ones_to_file_results() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        std::fs::create_dir_all(repo.join("pkg")).unwrap();
        std::fs::write(repo.join("AGENTS.md"), "Run make test before committing.").unwrap();
        std::fs::write(repo.join("pkg/AGENTS.md"), "Never edit generated files.").unwrap();
        let file = repo.join("pkg/lib.rs");
        let read = LLMResponse {
            tool_calls: vec![ToolCall { id: "r1".into(), name: "read_file".into(), arguments: json!({"path": file}) }],
            ..Default::default()
        };
        let again = LLMResponse {
            tool_calls: vec![ToolCall { id: "r2".into(), name: "read_file".into(), arguments: json!({"path": file}) }],
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
        LLMResponse { tool_calls: vec![ToolCall { id: id.into(), name: name.into(), arguments }], ..Default::default() }
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
        let (mut agent, seen) = agent(vec![call("s1", "load_skill", json!({"name": "release"})), text("done")], dir.path());
        agent.new_session().unwrap();
        assert!(!agent.tool_definitions().iter().any(|d| d.name == "load_skill"), "no skills, no tool");
        agent.skills = Skills::discover_in(&repo, &agent.config.skills, &skills::Locations::default());
        agent.set_system_prompt("base").unwrap();
        assert!(agent.tool_definitions().iter().any(|d| d.name == "load_skill"));
        agent.send_message("ship it").await.unwrap();

        let last = seen.lock().unwrap().last().unwrap().clone();
        assert!(last[0].content.contains("- `release`: Cut a release.") && !last[0].content.contains("Bump the version"));
        assert!(last[3].content.contains("Skill: release") && last[3].content.contains("Bump the version, then tag it."));
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

        let plans: Vec<Value> = events.lock().unwrap().iter().filter(|u| u["sessionUpdate"] == "plan").cloned().collect();
        assert_eq!(plans.len(), 2, "one per change; failed and read-only calls send none");
        assert_eq!(plans[1]["entries"][0], json!({"content": "Find it", "priority": "medium", "status": "completed"}));
        assert_eq!(plans[1]["_meta"]["plan"]["items"][0]["notes"][0], "it is in parser.rs:40");
        assert_eq!(Plan::from_value(&plans[1]["_meta"]["plan"]).unwrap(), agent.plan().clone());

        agent.compact(None).await.unwrap().expect("compacted");
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
        ToolCall { id: id.into(), name: goal::TOOL_NAME.into(), arguments: json!({"status": status, "summary": summary}) }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn reporting_an_outcome_ends_the_turn_and_is_recorded() {
        let dir = tempfile::tempdir().unwrap();
        let batch = LLMResponse {
            tool_calls: vec![
                report("o1", "completed", "Opened PR #5"),
                ToolCall { id: "c1".into(), name: "echo".into(), arguments: json!({"text": "pong"}) },
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
        assert_eq!(unstamped(&tail[1]), Message::tool_result("c1", "echo", "pong"), "later calls in the batch still run");
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
        assert!(reminded.starts_with("pong\n\n<system-reminder>\n") && reminded.contains("#1 \"Find it\" is still in progress"), "{reminded}");
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
            tool_calls: vec![ToolCall { id: "b1".into(), name: "broken".into(), arguments: json!({}) }],
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
        let tail: Vec<(Role, &str)> = second.iter().rev().take(2).map(|m| (m.role.clone(), m.content.as_str())).collect();
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
    async fn cancel_during_model_call_stops_the_turn() {
        let dir = tempfile::tempdir().unwrap();
        let (mut agent, _) = interfering(vec![], dir.path(), |_, control| {
            let control = control.clone();
            tokio::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                control.cancel();
            });
        }, Some(1));
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
                ToolCall { id: "b1".into(), name: "bash".into(), arguments: json!({"command": "sleep 30"}) },
                ToolCall { id: "e1".into(), name: "echo".into(), arguments: json!({"text": "never"}) },
            ],
            ..Default::default()
        };
        let (mut agent, seen) = interfering(vec![calls], dir.path(), |_, _| {}, None);
        let bash_config = crate::bash::BashConfig { cancel: Some(agent.control().cancel_flag()), ..Default::default() };
        agent.tools().register(crate::bash::definition(), Box::new(move |args| Ok(json!(crate::bash::run(&bash_config, &args)))));
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
        let (mut agent, _) = interfering(
            vec![text("done")],
            dir.path(),
            |_, control| control.steer("late", None),
            None,
        );
        agent.config.max_iterations = 1;
        agent.new_session().unwrap();
        let outcome = agent.run_turn(None, "go").await.unwrap();
        assert_eq!(outcome.stop_reason, StopReason::EndTurn);
        assert_eq!(outcome.response, "done");
        assert_eq!(agent.control().take_pending().len(), 1, "late steer left for the caller to requeue");
    }
}
