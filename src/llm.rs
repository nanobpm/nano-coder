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
}

/// Tool call requested by LLM. `arguments` is the decoded JSON object; if the
/// model produced invalid JSON it is kept verbatim as a `Value::String`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

impl ToolCall {
    pub fn decode_arguments(raw: &str) -> Value {
        if raw.trim().is_empty() {
            return json!({});
        }
        serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_string()))
    }

    pub fn encoded_arguments(&self) -> String {
        match &self.arguments {
            Value::String(raw) => raw.clone(),
            other => other.to_string(),
        }
    }
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
}
