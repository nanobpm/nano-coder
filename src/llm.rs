use anyhow::Result;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

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

/// Provider-neutral conversation message. Assistant messages carry the tool
/// calls they requested so the next request can replay them faithfully.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Message {
    pub role: Role,
    pub content: String,
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
}

impl Message {
    fn new(role: Role, content: &str) -> Self {
        Self {
            role,
            content: content.to_string(),
            tool_calls: vec![],
            is_error: false,
            thinking_blocks: vec![],
            tool_call_id: None,
            name: None,
            timestamp: None,
            log_line: None,
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
        Self {
            tool_calls,
            ..Self::new(Role::Assistant, content)
        }
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
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TokenUsage {
    pub prompt_tokens: i64,
    pub completion_tokens: i64,
    pub total_tokens: i64,
    /// AI Credits the request cost, when the provider reports them (GitHub
    /// Copilot's `copilot_usage.total_nano_aiu`, converted to credits).
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
fn stop_reason_is_length(stop_reason: Option<&str>) -> bool {
    stop_reason.is_some_and(|reason| {
        matches!(
            reason.to_ascii_lowercase().as_str(),
            "length" | "max_tokens" | "max_output_tokens"
        )
    })
}

/// Everything a provider needs to produce one completion.
#[derive(Debug, Clone)]
pub struct ChatRequest<'a> {
    pub messages: &'a [Message],
    pub tools: &'a [ToolDefinition],
    pub temperature: Option<f64>,
    pub max_tokens: Option<i64>,
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
    fn model_name(&self) -> &str;
    fn provider_name(&self) -> &str;
}

/// A context window reported by the provider's endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectedWindow {
    pub tokens: usize,
    /// Where it came from, e.g. `/v1/models max_model_len`.
    pub source: String,
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
                .find(|&n| self.pending.len() >= n && self.pending.is_char_boundary(self.pending.len() - n) && tag.starts_with(&self.pending[self.pending.len() - n..]))
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
        let mut emit = |think: bool, piece: &str| if think { thinking.push_str(piece) } else { content.push_str(piece) };
        splitter.push(text, &mut emit);
        splitter.finish(&mut emit);
        (content.trim_start().to_string(), thinking.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_think_tags_across_chunks() {
        let mut splitter = ThinkSplitter::default();
        let (mut content, mut thinking) = (String::new(), String::new());
        let mut emit = |think: bool, piece: &str| if think { thinking.push_str(piece) } else { content.push_str(piece) };
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
        let ok = ToolCall { id: "c2".into(), name: "write_file".into(), arguments: json!({"path": "/tmp/x"}), item_id: None, malformed_arguments: None };
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
