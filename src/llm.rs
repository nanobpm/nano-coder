use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;

use crate::tools::ToolDefinition;

/// LLM message role
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

impl std::fmt::Display for Role {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Role::System => write!(f, "system"),
            Role::User => write!(f, "user"),
            Role::Assistant => write!(f, "assistant"),
            Role::Tool => write!(f, "tool"),
        }
    }
}

/// An image attached to a message (currently only produced by `read_file`).
///
/// The pixels live on disk under the session's `attachments/` directory, named
/// `<sha256>.<extension>`; the message records only the reference and metadata,
/// so session logs stay small and the same image is stored once. `content`
/// stays text. Request builders turn the attachment into provider bytes
/// (base64) for the newest few images the model accepts.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Attachment {
    /// MIME type of the stored bytes (e.g. `image/png`). After downscaling /
    /// re-encoding this is the type of what is actually sent.
    pub media_type: String,
    /// The path the image was read from (for display and re-`read_file`).
    pub path: PathBuf,
    /// Hex sha256 of the stored (prepared) bytes; names the attachment file.
    pub sha256: String,
    pub width: u32,
    pub height: u32,
    /// Byte size of the stored (prepared) image.
    pub bytes: usize,
    /// File extension of the stored copy (`png`, `jpg`, `gif`, `webp`).
    pub extension: String,
}

impl Attachment {
    /// The placeholder text shown where an image is summarized away, omitted
    /// past the model's per-request image limit, or missing on resume.
    pub fn placeholder(&self) -> String {
        format!("[image: {}, {}×{}]", self.path.display(), self.width, self.height)
    }
}

/// Provider-neutral conversation message. Assistant messages carry the tool
/// calls they requested so the next request can replay them faithfully.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub role: Role,
    pub content: String,
    /// Images attached to this message (tool results from `read_file`). Not
    /// sent as text; request builders encode the newest few per the model's
    /// limit. Kept in the session log as references.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attachments: Vec<Attachment>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ToolCall>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// For tool results: the tool failed (or never finished).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_error: bool,
    /// Provider-specific reasoning blocks that must be replayed with this
    /// assistant message (Anthropic `thinking` blocks with signatures).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub thinking_blocks: Vec<Value>,
    /// When the message was added to the conversation, with the local UTC
    /// offset. Kept in the session log; not sent to providers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<chrono::DateTime<chrono::FixedOffset>>,
    /// Line of the session log where this message was first recorded (its
    /// stable `#N` ID for the history tools). Not sent to providers; written
    /// to the log only inside `replace` records.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log_line: Option<u64>,
    /// Assistant messages: the reasoning text the model produced for this
    /// response. Kept in the session log (for the trajectory view and
    /// `history_read`); not sent to providers.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub thinking: String,
    /// Assistant messages: the token usage the provider reported for the
    /// request that produced this message. Log only; not sent to providers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<TokenUsage>,
    /// Assistant messages: wall-clock time of the request that produced this
    /// message, in milliseconds. Log only; not sent to providers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// Assistant messages: the effective sampling temperature sent for the
    /// request that produced this message and where it came from, e.g.
    /// `0.3 (set for this model)` or `model default (global setting)`. Recorded
    /// so runs can be compared. Log only; not sent to providers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature: Option<String>,
    /// Assistant messages: the thinking level sent for the request that
    /// produced this message and where it came from, e.g. `high (set for this
    /// model)`. Log only; not sent to providers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thinking_level: Option<String>,
}

impl Message {
    fn new(role: Role, content: &str) -> Self {
        Self {
            role,
            content: content.to_string(),
            attachments: vec![],
            tool_calls: vec![],
            is_error: false,
            thinking_blocks: vec![],
            tool_call_id: None,
            name: None,
            timestamp: None,
            log_line: None,
            thinking: String::new(),
            usage: None,
            duration_ms: None,
            temperature: None,
            thinking_level: None,
        }
    }

    pub fn system(content: &str) -> Self {
        Self::new(Role::System, content)
    }

    pub fn user(content: &str) -> Self {
        Self::new(Role::User, content)
    }

    pub fn assistant(content: &str) -> Self {
        Self::new(Role::Assistant, content)
    }

    pub fn assistant_with_tools(content: &str, tool_calls: Vec<ToolCall>) -> Self {
        Self { tool_calls, ..Self::new(Role::Assistant, content) }
    }

    pub fn tool_result(tool_call_id: &str, name: &str, content: &str) -> Self {
        Self {
            tool_call_id: Some(tool_call_id.to_string()),
            name: Some(name.to_string()),
            ..Self::new(Role::Tool, content)
        }
    }

    pub fn tool_error(tool_call_id: &str, name: &str, content: &str) -> Self {
        Self { is_error: true, ..Self::tool_result(tool_call_id, name, content) }
    }

    /// Attach `attachments` to this (tool-result) message.
    pub fn with_attachments(mut self, attachments: Vec<Attachment>) -> Self {
        self.attachments = attachments;
        self
    }
}

/// LLM response
#[derive(Debug, Clone, Default)]
pub struct LLMResponse {
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
    pub usage: Option<TokenUsage>,
    pub stop_reason: Option<String>,
    /// Reasoning text the model produced before answering, if any.
    pub thinking: String,
    /// Opaque reasoning blocks to replay with the assistant message.
    pub thinking_blocks: Vec<Value>,
}

/// Token usage information
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TokenUsage {
    pub prompt_tokens: i64,
    pub completion_tokens: i64,
    pub total_tokens: i64,
    /// AI Credits the request cost, when the provider reports them (GitHub
    /// Copilot's `copilot_usage.total_nano_aiu`, converted to credits).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub aic: Option<f64>,
}

/// Read GitHub Copilot's `copilot_usage.total_nano_aiu` from a response body
/// or terminal stream event, converted to AI Credits (1 credit = 1e9 nano).
/// `None` when the field is absent (non-Copilot providers, older responses).
pub fn copilot_aic(value: &Value) -> Option<f64> {
    let nano = value.pointer("/copilot_usage/total_nano_aiu").and_then(Value::as_f64)?;
    Some(nano / 1e9)
}

/// Tool-call requested by LLM. `arguments` is normally the decoded JSON
/// object. When the model produced invalid JSON (e.g. a truncated stream),
/// the failure is recorded out-of-band in [`ToolCall::malformed_arguments`]
/// and `arguments` is left empty, so the failure is explicit and replayable
/// instead of looking like a missing argument — and so no key is reserved in
/// the model-controlled argument object.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    /// Call id (`call_*`) used to pair a tool result with its call; stable
    /// across providers and the id carried in `function_call_output`.
    pub id: String,
    pub name: String,
    pub arguments: Value,
    /// Provider output-item id (OpenAI Responses `fc_*`) when the call came from
    /// the Responses API. Reasoning models pair the preserved reasoning item
    /// with its function call by this id, so it must be replayed on the
    /// `function_call` item of the next request. `None` for providers that have
    /// no separate item id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    /// The verbatim argument text when it could not be decoded as JSON (a
    /// truncated or malformed stream). Kept as dedicated metadata rather than
    /// inside `arguments` so it can never collide with a legitimate argument
    /// key the model produced, and so it is not replayed to the model as part
    /// of the argument object. `None` when the arguments decoded fine.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub malformed_arguments: Option<String>,
}

impl ToolCall {
    /// Build a call from the raw argument text a provider streamed. Valid JSON
    /// becomes `arguments`; malformed JSON is kept verbatim in
    /// `malformed_arguments` with `arguments` left empty, so the dispatch loop
    /// can reject the call with a clear retry error instead of running a tool
    /// against garbage or misreporting a missing field.
    pub fn from_raw_arguments(id: String, name: String, raw: &str, item_id: Option<String>) -> Self {
        let (arguments, malformed_arguments) = Self::split_arguments(raw);
        Self { id, name, arguments, item_id, malformed_arguments }
    }

    /// Decode raw argument text into the argument object, returning the
    /// verbatim text separately when decoding failed. Empty input is an empty
    /// object with no failure.
    fn split_arguments(raw: &str) -> (Value, Option<String>) {
        if raw.trim().is_empty() {
            return (json!({}), None);
        }
        match serde_json::from_str(raw) {
            Ok(value) => (value, None),
            // Keep the malformed text as dedicated metadata rather than
            // dropping it: an empty object alone would look like the model
            // omitted every argument, and a bare string would be re-sent
            // verbatim and fail again on replay.
            Err(_) => (json!({}), Some(raw.to_string())),
        }
    }

    pub fn encoded_arguments(&self) -> String {
        match &self.arguments {
            Value::String(raw) => raw.clone(),
            other => other.to_string(),
        }
    }

    /// The raw malformed argument text, when decoding failed.
    pub fn invalid_arguments(&self) -> Option<&str> {
        self.malformed_arguments.as_deref()
    }

    /// Model-facing error explaining that the arguments arrived malformed and
    /// the call must be retried. `None` when the arguments decoded fine.
    ///
    /// The recovery advice is tailored to `stop_reason`: malformed JSON has two
    /// very different causes, and the wrong advice loops forever. A truncated
    /// transport stream is transient, so retrying the *same* call fixes it — but
    /// a call cut off because the model hit the output-token limit will be cut
    /// off again every time it retries the same arguments, so there the model
    /// must make a *smaller* call. When the provider reports a length/truncation
    /// stop reason we say so explicitly; otherwise we keep the message
    /// cause-neutral rather than flatly asserting a transient error.
    pub fn raw_arguments_error(&self, stop_reason: Option<&str>) -> Option<String> {
        self.invalid_arguments().map(|raw| {
            let shown: String = raw.chars().take(300).collect();
            let truncated = if raw.chars().count() > 300 { "…" } else { "" };
            if stop_reason_is_length(stop_reason) {
                format!(
                    "the arguments for `{}` were cut off because the response hit the output-token \
                     limit (stop reason `{}`), so the call was not run: `{shown}{truncated}`. \
                     Retrying the same call will hit the same limit — make a smaller call instead, \
                     for example by splitting the work across multiple `{}` calls or reducing the \
                     argument size so the full JSON fits within the limit.",
                    self.name,
                    stop_reason.unwrap_or("length"),
                    self.name
                )
            } else {
                format!(
                    "the arguments for `{}` arrived as malformed JSON (usually a truncated \
                     response), so the call was not run: `{shown}{truncated}`. \
                     If this was a transient transport error, simply retry the same `{}` call with \
                     the same arguments; if it keeps happening, the response was probably truncated \
                     by the output-token limit, so make a smaller call instead (for example by \
                     splitting the content).",
                    self.name, self.name
                )
            }
        })
    }
}

/// Whether a provider stop reason means the response was truncated because it
/// hit the output-token limit (as opposed to a transient transport failure).
/// Covers the length/truncation signals across providers: OpenAI chat
/// (`length`), Anthropic (`max_tokens`), and OpenAI Responses
/// (`max_output_tokens`).
///
/// Note the bare OpenAI Responses `incomplete` status is deliberately NOT a
/// length signal: `incomplete` only says the response stopped early, not why —
/// it can also mean a content filter or other non-length reason. The Responses
/// provider resolves `incomplete` to its nested `incomplete_details.reason`
/// (e.g. `max_output_tokens`) before it reaches here, so only a genuine
/// length reason is classified as one and a generic `incomplete` keeps the
/// cause-neutral advice.
pub(crate) fn stop_reason_is_length(stop_reason: Option<&str>) -> bool {
    stop_reason.is_some_and(|reason| {
        matches!(reason.to_ascii_lowercase().as_str(), "length" | "max_tokens" | "max_output_tokens")
    })
}

/// Everything a provider needs to produce one completion.
#[derive(Debug, Clone)]
pub struct ChatRequest<'a> {
    pub messages: &'a [Message],
    pub tools: &'a [ToolDefinition],
    pub temperature: Option<f64>,
    pub max_tokens: Option<i64>,
    /// Thinking level to ask for; `None` sends nothing.
    pub thinking: Option<crate::thinking::Request>,
    /// The model's vision capability: how the newest few image attachments are
    /// sent and how many a request may carry. `None` (or `max_images == 0`)
    /// means attachments become text placeholders.
    pub vision: Option<crate::vision::Vision>,
    /// Directory message attachments are stored in, so the builder can read
    /// their bytes. `None` for requests that cannot carry images (compaction).
    pub attachments_dir: Option<&'a std::path::Path>,
}

impl ChatRequest<'_> {
    /// Whether an attachment's stored bytes are still on disk *and intact*
    /// (present and hash-matching, the same gate `read_base64` applies before
    /// encoding, so availability can never diverge from what the payload
    /// actually sends). A reference with no attachments dir, or whose file was
    /// deleted or tampered with before a resume, is unavailable and resolves
    /// to a placeholder.
    fn attachment_available(&self, attachment: &crate::llm::Attachment) -> bool {
        self.attachments_dir.map(|dir| crate::attachment::exists(dir, attachment)).unwrap_or(false)
    }

    /// The attachment *occurrences* this request sends as images: the newest
    /// `vision.max_images` *available* occurrences across the conversation (every
    /// older one is omitted, its message showing a placeholder instead).
    /// Identified by occurrence, not content hash, so reading the same image
    /// twice does not make *both* copies sendable and overflow a model's image
    /// limit — a model capped at one image keeps only the newest occurrence even
    /// when an older message repeats its SHA. Unavailable references (missing or
    /// tampered on resume) are excluded from the quota so a lost newest image
    /// does not consume a slot an older available image could have used; each
    /// still resolves to its own "no longer available" placeholder. An empty
    /// set (no vision, or `max_images == 0`) sends none.
    fn sendable(&self) -> std::collections::HashSet<*const crate::llm::Attachment> {
        self.attachment_plan().sendable
    }

    /// The per-request attachment resolution plan, computed **once** and reused
    /// across every message. Resolving each message independently recomputes
    /// `sendable()` — which hashes every stored image via `attachment::exists`
    /// — so a conversation with N image-bearing messages would hash the whole
    /// attachment set N times (O(N²) file I/O) even when `max_images` is 1.
    /// Building the plan here hashes each stored file at most once (O(N)); the
    /// serializers compute it before their message loop and pass it to
    /// [`Self::resolve_attachments_with`].
    pub fn attachment_plan(&self) -> AttachmentPlan {
        let max = self.vision.as_ref().map(|v| v.max_images).unwrap_or(0);
        let mut available: Vec<&crate::llm::Attachment> =
            self.messages.iter().flat_map(|m| m.attachments.iter()).filter(|a| self.attachment_available(a)).collect();
        let available_set: std::collections::HashSet<*const crate::llm::Attachment> =
            available.iter().map(|a| *a as *const crate::llm::Attachment).collect();
        // Keep the newest `max` as sendable: drop the oldest excess from the front.
        let keep = max.min(available.len());
        let drop = available.len() - keep;
        available.drain(..drop);
        let sendable = available.into_iter().map(|a| a as *const crate::llm::Attachment).collect();
        AttachmentPlan { available: available_set, sendable }
    }

    /// Resolve each of `message`'s attachments for the wire using a precomputed
    /// [`AttachmentPlan`], in order: either the image data to send, or the
    /// placeholder text standing in for it (omitted past the model's image
    /// limit, or missing on resume). Serializers build the plan once per
    /// request and pass it here for every message, so the attachment set is
    /// hashed once rather than once per message.
    pub fn resolve_attachments_with(&self, message: &Message, plan: &AttachmentPlan) -> Vec<ResolvedAttachment> {
        if message.attachments.is_empty() {
            return Vec::new();
        }
        message
            .attachments
            .iter()
            .map(|attachment| {
                let ptr = attachment as *const crate::llm::Attachment;
                if plan.sendable.contains(&ptr) {
                    return match self.attachments_dir.and_then(|dir| crate::attachment::read_base64(dir, attachment)) {
                        Some(data_base64) => ResolvedAttachment::Image(ImageData {
                            media_type: attachment.media_type.clone(),
                            data_base64,
                        }),
                        None => ResolvedAttachment::Omitted(format!(
                            "[image: {}, {}×{} (no longer available)]",
                            attachment.path.display(),
                            attachment.width,
                            attachment.height
                        )),
                    };
                }
                // Not selected: either an available image beyond the newest-N
                // quota (sent earlier), or a reference whose file is gone.
                if plan.available.contains(&ptr) {
                    ResolvedAttachment::Omitted(format!(
                        "[image omitted: {} (sent earlier)]",
                        attachment.path.display()
                    ))
                } else {
                    ResolvedAttachment::Omitted(format!(
                        "[image: {}, {}×{} (no longer available)]",
                        attachment.path.display(),
                        attachment.width,
                        attachment.height
                    ))
                }
            })
            .collect()
    }

    /// Resolve one message's attachments, building a fresh [`AttachmentPlan`]
    /// for it. Convenience for single-message callers and tests; serializers
    /// that resolve every message build the plan once with
    /// [`Self::attachment_plan`] and call [`Self::resolve_attachments_with`].
    #[cfg(test)]
    pub fn resolve_attachments(&self, message: &Message) -> Vec<ResolvedAttachment> {
        self.resolve_attachments_with(message, &self.attachment_plan())
    }

    /// Whether any message in the request carries an attachment that will be
    /// sent as an image (used by GitHub Copilot to set its vision header). An
    /// attachment counts only when it is both sendable *and* its stored file
    /// is intact (present and hash-matching) — a deleted or tampered file
    /// resolves to a text placeholder, not an image, so the vision header must
    /// not claim one.
    pub fn has_images(&self) -> bool {
        // `sendable()` already excludes references whose files are missing or
        // tampered, so a non-empty set means at least one real image is sent.
        !self.sendable().is_empty()
    }
}

/// An image's wire bytes: its (post-downscale) media type and base64 data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageData {
    pub media_type: String,
    pub data_base64: String,
}

/// How one attachment appears in a request: as image data, or as a text
/// placeholder (omitted past the model's image limit, or missing on resume).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedAttachment {
    Image(ImageData),
    Omitted(String),
}

/// A request's attachment resolution plan, computed once and shared across
/// messages: which attachment occurrences are available on disk, and which of
/// those fall within the image quota (and so are sent as images). Occurrences
/// are keyed by pointer, not content hash, so the same image read twice counts
/// as two occurrences. Build it with [`ChatRequest::attachment_plan`] and pass
/// it to [`ChatRequest::resolve_attachments_with`] for every message, so the
/// stored attachment set is hashed once per request instead of once per message.
pub struct AttachmentPlan {
    available: std::collections::HashSet<*const crate::llm::Attachment>,
    sendable: std::collections::HashSet<*const crate::llm::Attachment>,
}

impl<'a> ChatRequest<'a> {
    /// A request over `messages` with no tools, temperature, output cap,
    /// thinking or vision — the common test fixture. Field updates use struct
    /// update syntax (`ChatRequest { max_tokens: Some(1), ..test_request(&m) }`).
    #[cfg(test)]
    pub fn test_request(messages: &'a [Message]) -> Self {
        ChatRequest {
            messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: None,
            attachments_dir: None,
        }
    }
}

/// Incremental output while a response streams in.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum StreamEvent<'a> {
    Text(&'a str),
    Thinking(&'a str),
}

impl StreamEvent<'_> {
    /// Whether this event carries visible content for the caller. Empty deltas
    /// (e.g. an empty `text_delta`) reach the sink but deliver nothing, so they
    /// must not count as visible output when deciding whether a retry is safe.
    pub fn has_content(&self) -> bool {
        match self {
            StreamEvent::Text(text) | StreamEvent::Thinking(text) => !text.is_empty(),
        }
    }
}

/// Receives stream events as they arrive.
pub type StreamSink<'a> = &'a (dyn Fn(StreamEvent<'_>) + Send + Sync);

/// Report a complete (non-streamed) response to a stream sink.
pub fn report_whole(sink: StreamSink<'_>, response: &LLMResponse) {
    if !response.thinking.is_empty() {
        sink(StreamEvent::Thinking(&response.thinking));
    }
    if !response.content.is_empty() {
        sink(StreamEvent::Text(&response.content));
    }
}

/// LLM client trait
#[async_trait]
pub trait LLMClient: Send + Sync {
    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse>;
    /// Like `chat`, reporting text and reasoning to `sink` as it streams.
    /// The default does not stream: it reports the whole response at the end.
    async fn chat_stream(&self, request: &ChatRequest<'_>, sink: StreamSink<'_>) -> Result<LLMResponse> {
        let response = self.chat(request).await?;
        report_whole(sink, &response);
        Ok(response)
    }
    /// Model IDs offered by the endpoint, where it can list them.
    async fn list_models(&self) -> Result<Vec<String>> {
        anyhow::bail!("provider {:?} cannot list models", self.provider_name())
    }
    /// The context window the endpoint reports for the current model, if any.
    async fn detect_context_window(&self) -> Option<DetectedWindow> {
        None
    }
    /// The thinking levels the endpoint reports for the current model, if any.
    async fn detect_thinking_levels(&self) -> Option<crate::thinking::Reported> {
        None
    }
    /// The vision capability the endpoint reports for the current model, if
    /// any. `None` means "no report" (the built-in assumption / config override
    /// then decides), not "cannot see" — a provider that knows the model is
    /// blind reports `Some` with `max_images == 0` is not used; blindness is
    /// simply the absence of a capability.
    async fn detect_vision(&self) -> Option<crate::vision::Vision> {
        None
    }
    /// The window, thinking levels and vision capability the endpoint reports,
    /// probed together.
    ///
    /// The default probes each on its own; a provider whose detections would
    /// fetch the same endpoint response (OpenAI-compatible servers probe
    /// `/models`, then llama.cpp `/props` or Ollama `/api/show` for all three)
    /// overrides this to share one fetch, so a slow or unavailable endpoint is
    /// not probed two or three times serially.
    async fn detect_capabilities(
        &self,
    ) -> (Option<DetectedWindow>, Option<crate::thinking::Reported>, Option<crate::vision::Vision>) {
        (self.detect_context_window().await, self.detect_thinking_levels().await, self.detect_vision().await)
    }
    fn model_name(&self) -> &str;
    fn provider_name(&self) -> &str;
    /// The provider API kind this client speaks. `None` for test doubles that
    /// imitate no real provider API.
    fn kind(&self) -> Option<crate::providers::ProviderKind> {
        None
    }
}

/// A context window reported by the provider's endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectedWindow {
    pub tokens: usize,
    /// Where it came from, e.g. `/v1/models max_model_len`.
    pub source: String,
    /// Whether `tokens` caps the whole request (prompt + output) or the prompt
    /// alone. Total unless the endpoint says otherwise.
    pub cap: ContextCap,
    /// The combined prompt + output window, when the endpoint reports it
    /// alongside a prompt-only `tokens` cap (GitHub Copilot advertises both
    /// `max_prompt_tokens` and the larger `max_context_window_tokens`). A
    /// prompt-only `cap` leaves `max_tokens` unchanged, which can still push
    /// prompt + output past this window, so it is enforced as a second limit.
    /// `None` for a `Total` cap, where `tokens` already is the combined window.
    pub total_tokens: Option<usize>,
}

impl DetectedWindow {
    /// A window that caps the whole request, prompt + output.
    pub fn total(tokens: usize, source: impl Into<String>) -> Self {
        DetectedWindow { tokens, source: source.into(), cap: ContextCap::Total, total_tokens: None }
    }
}

/// Whether a context window caps the whole request or only the prompt.
///
/// Most endpoints reject a request whose prompt *plus* `max_tokens` exceeds the
/// window, so the output reservation counts against it (`Total`). GitHub Copilot
/// instead enforces a prompt-only budget (`max_prompt_tokens`) that sits below
/// the full window: output tokens do not consume it, so subtracting the output
/// reservation would compact and cap completions earlier than the real limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ContextCap {
    /// `tokens` is the combined prompt + output budget; reserve output room in it.
    #[default]
    Total,
    /// `tokens` caps the prompt alone; output tokens do not consume it.
    Prompt,
}

/// Splits `<think>...</think>` sections out of streamed content (servers that
/// return reasoning inline rather than in a separate field).
#[derive(Debug, Default)]
pub struct ThinkSplitter {
    in_think: bool,
    /// A possible partial tag held back until more text arrives.
    pending: String,
}

impl ThinkSplitter {
    /// Feed content; `emit` receives `(is_thinking, text)` pieces.
    pub fn push(&mut self, text: &str, emit: &mut dyn FnMut(bool, &str)) {
        self.pending.push_str(text);
        loop {
            let tag = if self.in_think { "</think>" } else { "<think>" };
            if let Some(at) = self.pending.find(tag) {
                if at > 0 {
                    emit(self.in_think, &self.pending[..at]);
                }
                self.pending.drain(..at + tag.len());
                self.in_think = !self.in_think;
                continue;
            }
            // Hold back a suffix that could be the start of the tag.
            let keep = (1..tag.len())
                .rev()
                .find(|&n| {
                    self.pending.len() >= n
                        && self.pending.is_char_boundary(self.pending.len() - n)
                        && tag.starts_with(&self.pending[self.pending.len() - n..])
                })
                .unwrap_or(0);
            let split = self.pending.len() - keep;
            if split > 0 {
                emit(self.in_think, &self.pending[..split]);
                self.pending.drain(..split);
            }
            return;
        }
    }

    pub fn finish(&mut self, emit: &mut dyn FnMut(bool, &str)) {
        if !self.pending.is_empty() {
            let rest = std::mem::take(&mut self.pending);
            emit(self.in_think, &rest);
        }
    }

    /// Split a complete content string into `(content, thinking)`.
    pub fn split_all(text: &str) -> (String, String) {
        if !text.contains("<think>") {
            return (text.to_string(), String::new());
        }
        let (mut content, mut thinking) = (String::new(), String::new());
        let mut splitter = Self::default();
        let mut emit =
            |think: bool, piece: &str| if think { thinking.push_str(piece) } else { content.push_str(piece) };
        splitter.push(text, &mut emit);
        splitter.finish(&mut emit);
        (content.trim_start().to_string(), thinking.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An attachment with a stable hash of `tag`, stored (when `dir` is set).
    fn attachment(tag: &str, dir: Option<&std::path::Path>) -> Attachment {
        let bytes = tag.as_bytes().to_vec();
        let a = Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from(format!("/tmp/{tag}.png")),
            sha256: crate::attachment::sha256_hex(&bytes),
            width: 10,
            height: 10,
            bytes: bytes.len(),
            extension: "png".into(),
        };
        if let Some(dir) = dir {
            crate::attachment::store(dir, &a, &bytes).unwrap();
        }
        a
    }

    fn vision(max_images: usize) -> crate::vision::Vision {
        crate::vision::Vision {
            max_images,
            max_image_bytes: crate::attachment::DEFAULT_MAX_BYTES,
            media_types: Vec::new(),
        }
    }

    #[test]
    fn attachments_round_trip_and_stay_off_plain_messages() {
        let message = Message::tool_result("c1", "read_file", "image/png, 10×10, 5 B")
            .with_attachments(vec![attachment("a", None)]);
        let json = serde_json::to_value(&message).unwrap();
        assert_eq!(json["attachments"][0]["media_type"], "image/png");
        assert_eq!(json["attachments"][0]["width"], 10);
        assert_eq!(serde_json::from_value::<Message>(json).unwrap(), message);
        // A message with no attachments writes no `attachments` field, and a
        // log from before attachments existed still loads.
        let plain = serde_json::to_value(Message::assistant("hi")).unwrap();
        assert!(plain.get("attachments").is_none());
        assert_eq!(serde_json::from_value::<Message>(plain).unwrap(), Message::assistant("hi"));
    }

    #[test]
    fn resolves_newest_n_images_and_omits_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let (a, b, c) =
            (attachment("a", Some(dir.path())), attachment("b", Some(dir.path())), attachment("c", Some(dir.path())));
        let messages = vec![
            Message::tool_result("t1", "read_file", "first").with_attachments(vec![a.clone()]),
            Message::tool_result("t2", "read_file", "second").with_attachments(vec![b.clone()]),
            Message::tool_result("t3", "read_file", "third").with_attachments(vec![c.clone()]),
        ];
        // A model capped at one image sends only the newest (c); a and b are omitted.
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        assert!(matches!(
            request.resolve_attachments(&messages[0])[0],
            ResolvedAttachment::Omitted(ref t) if t.contains("omitted") && t.contains("a.png")
        ));
        assert!(matches!(request.resolve_attachments(&messages[1])[0], ResolvedAttachment::Omitted(_)));
        assert!(matches!(request.resolve_attachments(&messages[2])[0], ResolvedAttachment::Image(_)));
        assert!(request.has_images());

        // Two images: b and c are sent, a is omitted.
        let request = ChatRequest {
            vision: Some(vision(2)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        assert!(matches!(request.resolve_attachments(&messages[0])[0], ResolvedAttachment::Omitted(_)));
        assert!(matches!(request.resolve_attachments(&messages[1])[0], ResolvedAttachment::Image(_)));
        assert!(matches!(request.resolve_attachments(&messages[2])[0], ResolvedAttachment::Image(_)));
    }

    #[test]
    fn repeated_same_image_counts_each_occurrence_not_unique_hashes() {
        // Reading the same image twice: a model capped at one image must send
        // only the newest occurrence, not both copies of the shared SHA.
        let dir = tempfile::tempdir().unwrap();
        let shared = attachment("dup", Some(dir.path()));
        let messages = vec![
            Message::tool_result("t1", "read_file", "first read").with_attachments(vec![shared.clone()]),
            Message::tool_result("t2", "read_file", "second read").with_attachments(vec![shared.clone()]),
        ];
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        assert!(
            matches!(request.resolve_attachments(&messages[0])[0], ResolvedAttachment::Omitted(_)),
            "the older occurrence of a repeated image must be omitted"
        );
        assert!(matches!(request.resolve_attachments(&messages[1])[0], ResolvedAttachment::Image(_)));
    }

    #[test]
    fn missing_attachment_file_becomes_a_placeholder() {
        let dir = tempfile::tempdir().unwrap();
        // Reference an image whose file was never written (e.g. deleted before resume).
        let missing = attachment("gone", None);
        let messages = vec![Message::tool_result("t1", "read_file", "saw it").with_attachments(vec![missing])];
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        match &request.resolve_attachments(&messages[0])[0] {
            ResolvedAttachment::Omitted(text) => {
                assert!(text.contains("gone.png"), "{text}");
                assert!(text.contains("no longer available"), "{text}");
            }
            other => panic!("missing file should be a placeholder, got {other:?}"),
        }
        // A deleted file resolves to a placeholder, so the request carries no
        // image and must not claim a vision request.
        assert!(!request.has_images(), "deleted file must not report a sendable image");
    }

    #[test]
    fn missing_newest_image_does_not_consume_quota_from_an_available_older_one() {
        // On resume the newest image's file is gone but an older one survives.
        // A model capped at one image must still send the available older image,
        // not waste its only slot on the missing newest reference.
        let dir = tempfile::tempdir().unwrap();
        let older = attachment("older", Some(dir.path())); // stored
        let newest_missing = attachment("newest", None); // never written
        let messages = vec![
            Message::tool_result("t1", "read_file", "older").with_attachments(vec![older]),
            Message::tool_result("t2", "read_file", "newest").with_attachments(vec![newest_missing]),
        ];
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        // The available older image is sent...
        assert!(
            matches!(request.resolve_attachments(&messages[0])[0], ResolvedAttachment::Image(_)),
            "available older image must fill the slot the missing newest cannot use"
        );
        // ...and the missing newest resolves to its own "no longer available"
        // placeholder, not "sent earlier".
        match &request.resolve_attachments(&messages[1])[0] {
            ResolvedAttachment::Omitted(text) => {
                assert!(text.contains("no longer available"), "{text}");
                assert!(!text.contains("sent earlier"), "{text}");
            }
            other => panic!("missing newest should be a placeholder, got {other:?}"),
        }
        assert!(request.has_images(), "an available image is sent despite the missing newest");
    }

    #[test]
    fn available_image_beyond_quota_says_sent_earlier() {
        // Two available images, capped at one: the older available one is over
        // quota and must read "sent earlier" (distinct from "no longer available").
        let dir = tempfile::tempdir().unwrap();
        let older = attachment("a", Some(dir.path()));
        let newest = attachment("b", Some(dir.path()));
        let messages = vec![
            Message::tool_result("t1", "read_file", "a").with_attachments(vec![older]),
            Message::tool_result("t2", "read_file", "b").with_attachments(vec![newest]),
        ];
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        match &request.resolve_attachments(&messages[0])[0] {
            ResolvedAttachment::Omitted(text) => assert!(text.contains("sent earlier"), "{text}"),
            other => panic!("over-quota available image should say sent earlier, got {other:?}"),
        }
        assert!(matches!(request.resolve_attachments(&messages[1])[0], ResolvedAttachment::Image(_)));
    }

    #[test]
    fn tampered_newest_image_consumes_no_quota_and_sets_no_false_header() {
        // The newest image's stored file was tampered with (its bytes no longer
        // match the recorded hash). Availability is the same hash-validated
        // gate `read_base64` applies, so the tampered newest is unavailable:
        // it must not consume the only image slot, the older intact image is
        // sent instead, and the tampered one resolves to a "no longer
        // available" placeholder rather than "sent earlier".
        let dir = tempfile::tempdir().unwrap();
        let older = attachment("older", Some(dir.path())); // stored, intact
        let newest = attachment("newest", Some(dir.path())); // stored, then tampered
        let tampered_path = dir.path().join(format!("{}.{}", newest.sha256, newest.extension));
        std::fs::write(&tampered_path, b"tampered").unwrap();
        let messages = vec![
            Message::tool_result("t1", "read_file", "older").with_attachments(vec![older]),
            Message::tool_result("t2", "read_file", "newest").with_attachments(vec![newest]),
        ];
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        assert!(
            matches!(request.resolve_attachments(&messages[0])[0], ResolvedAttachment::Image(_)),
            "the intact older image must fill the slot the tampered newest cannot use"
        );
        match &request.resolve_attachments(&messages[1])[0] {
            ResolvedAttachment::Omitted(text) => {
                assert!(text.contains("no longer available"), "{text}");
                assert!(!text.contains("sent earlier"), "{text}");
            }
            other => panic!("tampered newest should be a placeholder, got {other:?}"),
        }
        // An intact image is sent, so the vision header is still honest.
        assert!(request.has_images());
    }

    #[test]
    fn tampered_only_image_sets_no_vision_header() {
        // The request's only attachment is tampered: nothing sendable remains,
        // so the Copilot vision header must not claim an image that resolves
        // to a placeholder.
        let dir = tempfile::tempdir().unwrap();
        let only = attachment("only", Some(dir.path()));
        let tampered_path = dir.path().join(format!("{}.{}", only.sha256, only.extension));
        std::fs::write(&tampered_path, b"tampered").unwrap();
        let messages = vec![Message::tool_result("t1", "read_file", "x").with_attachments(vec![only])];
        let request = ChatRequest {
            vision: Some(vision(1)),
            attachments_dir: Some(dir.path()),
            ..ChatRequest::test_request(&messages)
        };
        assert!(matches!(request.resolve_attachments(&messages[0])[0], ResolvedAttachment::Omitted(_)));
        assert!(!request.has_images(), "a tampered file must not report a sendable image");
    }

    #[test]
    fn no_vision_sends_no_images() {
        let dir = tempfile::tempdir().unwrap();
        let messages = vec![
            Message::tool_result("t1", "read_file", "x").with_attachments(vec![attachment("a", Some(dir.path()))]),
        ];
        let request = ChatRequest { attachments_dir: Some(dir.path()), ..ChatRequest::test_request(&messages) };
        assert!(matches!(request.resolve_attachments(&messages[0])[0], ResolvedAttachment::Omitted(_)));
        assert!(!request.has_images());
    }

    #[test]
    fn trajectory_fields_round_trip_and_stay_out_of_plain_messages() {
        let message = Message {
            thinking: "because".into(),
            usage: Some(TokenUsage { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15, aic: None }),
            duration_ms: Some(42),
            ..Message::assistant("hi")
        };
        let json = serde_json::to_value(&message).unwrap();
        assert_eq!(json["thinking"], "because");
        assert_eq!(json["usage"], serde_json::json!({"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}));
        assert_eq!(json["duration_ms"], 42);
        assert_eq!(serde_json::from_value::<Message>(json).unwrap(), message);
        // Unset fields are not written, and logs from before they existed load.
        let plain = serde_json::to_value(Message::assistant("hi")).unwrap();
        assert_eq!(plain, serde_json::json!({"role": "assistant", "content": "hi"}));
        assert_eq!(serde_json::from_value::<Message>(plain).unwrap(), Message::assistant("hi"));
    }

    #[test]
    fn splits_think_tags_across_chunks() {
        let mut splitter = ThinkSplitter::default();
        let (mut content, mut thinking) = (String::new(), String::new());
        let mut emit =
            |think: bool, piece: &str| if think { thinking.push_str(piece) } else { content.push_str(piece) };
        for chunk in ["<th", "ink>plan ", "it</thi", "nk>Answer <b>", "</b> done"] {
            splitter.push(chunk, &mut emit);
        }
        splitter.finish(&mut emit);
        assert_eq!(thinking, "plan it");
        assert_eq!(content, "Answer <b></b> done");
        assert_eq!(ThinkSplitter::split_all("<think>x</think>\n\nhi"), ("hi".into(), "x".into()));
        assert_eq!(ThinkSplitter::split_all("plain"), ("plain".into(), String::new()));
    }

    #[test]
    fn reads_copilot_aic_from_nano() {
        let value = serde_json::json!({
            "usage": {"prompt_tokens": 8, "completion_tokens": 10, "total_tokens": 18},
            "copilot_usage": {"total_nano_aiu": 11_600_000}
        });
        assert_eq!(copilot_aic(&value), Some(0.0116));
        // Absent on non-Copilot responses.
        assert_eq!(copilot_aic(&serde_json::json!({"usage": {}})), None);
        // A zero cost is still reported (0x-multiplier models are free).
        assert_eq!(copilot_aic(&serde_json::json!({"copilot_usage": {"total_nano_aiu": 0}})), Some(0.0));
    }

    #[test]
    fn decodes_valid_arguments_and_marks_invalid_ones() {
        // Valid JSON decodes normally; empty input is an empty object.
        let valid = ToolCall::from_raw_arguments("c".into(), "write_file".into(), r#"{"path":"/tmp/x"}"#, None);
        assert_eq!(valid.arguments, json!({"path": "/tmp/x"}));
        assert_eq!(valid.invalid_arguments(), None);
        assert!(ToolCall::from_raw_arguments("c".into(), "t".into(), "", None).arguments.is_object());
        assert!(ToolCall::from_raw_arguments("c".into(), "t".into(), "   ", None).invalid_arguments().is_none());

        // Malformed JSON is preserved as dedicated metadata, not folded into
        // the argument object (so it can never collide with a real argument
        // key, and is not replayed to the model as an argument).
        let raw = r#"{"path":"/tmp/x","content":"abc"#;
        let call = ToolCall::from_raw_arguments("c1".into(), "write_file".into(), raw, None);
        assert_eq!(call.arguments, json!({}), "malformed args leave the object empty");
        assert_eq!(call.invalid_arguments(), Some(raw));
        let error = call.raw_arguments_error(None).expect("malformed args report an error");
        assert!(error.contains("write_file"), "names the tool: {error}");
        assert!(error.contains("malformed JSON"), "explains the failure: {error}");
        assert!(error.contains("retry the same"), "tells the model to retry: {error}");
        // The malformed payload is echoed so the model can see what arrived.
        assert!(error.contains(r#"{"path":"/tmp/x"#), "shows the raw text: {error}");

        // A well-formed call reports no error.
        let ok = ToolCall {
            id: "c2".into(),
            name: "write_file".into(),
            arguments: json!({"path": "/tmp/x"}),
            item_id: None,
            malformed_arguments: None,
        };
        assert!(ok.invalid_arguments().is_none());
        assert!(ok.raw_arguments_error(None).is_none());
    }

    #[test]
    fn raw_arguments_error_tailors_advice_to_stop_reason() {
        let raw = r#"{"path":"/tmp/x","content":"abc"#;
        let call = ToolCall::from_raw_arguments("c1".into(), "write_file".into(), raw, None);

        // A length/truncation stop reason means retrying the same call loops
        // forever, so the advice tells the model to make a smaller call and
        // does NOT claim a transient transport error.
        for reason in ["length", "max_tokens", "max_output_tokens"] {
            let error = call.raw_arguments_error(Some(reason)).expect("malformed args report an error");
            assert!(error.contains("output-token limit"), "names the cause for {reason}: {error}");
            assert!(error.contains("smaller call"), "advises shrinking for {reason}: {error}");
            assert!(!error.contains("retry the same"), "does not tell it to repeat for {reason}: {error}");
        }

        // An unknown / non-length stop reason — including a bare OpenAI Responses
        // `incomplete` status, which does not by itself prove an output-token
        // limit — keeps the cause-neutral message (retry, but shrink if it
        // recurs) rather than asserting a definite length stop.
        for reason in ["tool_use", "incomplete"] {
            let error = call.raw_arguments_error(Some(reason)).expect("malformed args report an error");
            assert!(error.contains("retry the same"), "offers a retry for {reason}: {error}");
            assert!(
                error.contains("truncated by the output-token limit"),
                "hedges on recurrence for {reason}: {error}"
            );
        }
    }

    #[test]
    fn raw_arguments_error_truncates_long_payloads() {
        let raw = format!(r#"{{"content":"{}"#, "x".repeat(1000));
        let call = ToolCall::from_raw_arguments("c".into(), "write_file".into(), &raw, None);
        let error = call.raw_arguments_error(None).unwrap();
        // Only the first 300 chars of the payload are echoed, with an ellipsis.
        assert!(error.contains('…'), "truncated payload is marked: {error}");
        assert!(error.len() < raw.len() + 400, "error stays bounded");
    }
}
