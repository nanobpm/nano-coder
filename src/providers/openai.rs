//! OpenAI Chat Completions client. Works with any OpenAI-compatible endpoint.

use anyhow::{Result, anyhow};
use async_trait::async_trait;
use serde_json::{Value, json};

use super::{HttpTransport, ResolvedProvider};
use crate::llm::{
    ChatRequest, DetectedWindow, LLMClient, LLMResponse, Message, Role, StreamEvent, StreamSink, ThinkSplitter, TokenUsage, ToolCall,
    report_whole,
};

pub struct OpenAiClient {
    transport: HttpTransport,
}

impl OpenAiClient {
    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        Ok(Self {
            transport: HttpTransport::new(provider)?,
        })
    }

    pub fn build_body(&self, request: &ChatRequest<'_>) -> Value {
        build_body(&self.transport, request)
    }
}

/// Chat Completions request body for `request`, with provider overrides applied.
pub(crate) fn build_body(transport: &HttpTransport, request: &ChatRequest<'_>) -> Value {
        let provider = transport.provider();
        let mut body = json!({
            "model": provider.model,
            "messages": request.messages.iter().map(|m| encode_message(m, provider.replay_reasoning)).collect::<Vec<_>>(),
        });
        if !request.tools.is_empty() {
            body["tools"] = request
                .tools
                .iter()
                .map(|tool| {
                    json!({
                        "type": "function",
                        "function": {
                            "name": tool.name,
                            "description": tool.description,
                            "parameters": tool.parameters,
                        }
                    })
                })
                .collect();
        }
        if let Some(temperature) = request.temperature {
            body["temperature"] = json!(temperature);
        }
        if let Some(max_tokens) = request.max_tokens {
            body[provider.max_tokens_param.as_str()] = json!(max_tokens);
        }
        transport.finish_body(body)
}

fn encode_message(message: &Message, replay_reasoning: bool) -> Value {
    let mut encoded = match message.role {
        Role::Assistant if !message.tool_calls.is_empty() => json!({
            "role": "assistant",
            "content": if message.content.is_empty() { Value::Null } else { json!(message.content) },
            "tool_calls": message.tool_calls.iter().map(|call| json!({
                "id": call.id,
                "type": "function",
                "function": { "name": call.name, "arguments": call.encoded_arguments() },
            })).collect::<Vec<_>>(),
        }),
        Role::Tool => json!({
            "role": "tool",
            "tool_call_id": message.tool_call_id,
            "content": message.content,
        }),
        _ => json!({ "role": message.role.to_string(), "content": message.content }),
    };
    if replay_reasoning && message.role == Role::Assistant {
        let reasoning = message
            .thinking_blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some(REASONING_BLOCK))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<String>();
        if !reasoning.is_empty() {
            encoded["reasoning_content"] = json!(reasoning);
        }
    }
    encoded
}

/// `thinking_blocks` entry holding a response's `reasoning_content`, kept only
/// for providers with `replay_reasoning`.
const REASONING_BLOCK: &str = "reasoning_content";

fn reasoning_blocks(replay: bool, reasoning: &str) -> Vec<Value> {
    if replay && !reasoning.is_empty() {
        vec![json!({ "type": REASONING_BLOCK, "text": reasoning })]
    } else {
        vec![]
    }
}

/// Parse a Chat Completions response.
/// `replay` keeps the reasoning in `thinking_blocks` so it can be sent back.
pub fn parse_response(value: &Value, replay: bool) -> Result<LLMResponse> {
    let choice = value
        .get("choices")
        .and_then(|c| c.get(0))
        .ok_or_else(|| anyhow!("response has no choices: {value}"))?;
    let message = choice.get("message").cloned().unwrap_or(Value::Null);
    let content = match message.get("content") {
        Some(Value::String(text)) => text.clone(),
        // Some servers return content parts.
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(""),
        _ => String::new(),
    };
    let (content, inline_thinking) = ThinkSplitter::split_all(&content);
    let reasoning = reasoning_of(&message).unwrap_or_default();
    // Replay only the provider's actual `reasoning_content`, never the generic
    // `reasoning` fallback, which must not be echoed back under Kimi's field.
    let thinking_blocks = reasoning_blocks(replay, reasoning_content_of(&message).unwrap_or_default());
    let mut thinking = reasoning.to_string();
    if !inline_thinking.is_empty() {
        if !thinking.is_empty() {
            thinking.push('\n');
        }
        thinking.push_str(&inline_thinking);
    }
    let tool_calls = message
        .get("tool_calls")
        .and_then(Value::as_array)
        .map(|calls| {
            calls
                .iter()
                .enumerate()
                .map(|(index, call)| {
                    let function = call.get("function").cloned().unwrap_or(Value::Null);
                    let raw = match function.get("arguments") {
                        Some(Value::String(s)) => s.clone(),
                        Some(Value::Null) | None => String::new(),
                        Some(other) => other.to_string(),
                    };
                    ToolCall {
                        id: call
                            .get("id")
                            .and_then(Value::as_str)
                            .filter(|id| !id.is_empty())
                            .map(str::to_string)
                            .unwrap_or_else(|| format!("call_{index}")),
                        name: function
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        arguments: ToolCall::decode_arguments(&raw),
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(LLMResponse {
        content,
        tool_calls,
        usage: parse_usage(value),
        stop_reason: choice
            .get("finish_reason")
            .and_then(Value::as_str)
            .map(str::to_string),
        thinking,
        thinking_blocks,
    })
}

fn parse_usage(value: &Value) -> Option<TokenUsage> {
    value.get("usage").filter(|u| u.is_object()).map(|usage| {
        let field = |name: &str| usage.get(name).and_then(Value::as_i64).unwrap_or(0);
        TokenUsage {
            prompt_tokens: field("prompt_tokens"),
            completion_tokens: field("completion_tokens"),
            total_tokens: field("total_tokens"),
        }
    })
}

/// Reasoning text: `reasoning_content` (DeepSeek, llama.cpp, vLLM) or
/// `reasoning` (OpenRouter, Ollama).
fn reasoning_of(value: &Value) -> Option<&str> {
    ["reasoning_content", "reasoning"]
        .iter()
        .find_map(|key| value.get(*key).and_then(Value::as_str))
        .filter(|text| !text.is_empty())
}

/// The provider's actual `reasoning_content` field only (never the generic
/// `reasoning` fallback). Replay must echo this verbatim, so a value the
/// response never supplied under `reasoning_content` must not be sent back.
fn reasoning_content_of(value: &Value) -> Option<&str> {
    value
        .get(REASONING_BLOCK)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
}

/// Accumulates a streamed Chat Completions response.
#[derive(Default)]
pub(crate) struct StreamAccumulator {
    content: String,
    thinking: String,
    /// Reasoning from the `reasoning_content` field only (not inline `<think>`).
    reasoning: String,
    replay: bool,
    splitter: ThinkSplitter,
    /// Tool calls by stream index: (id, name, raw arguments).
    calls: Vec<(String, String, String)>,
    usage: Option<TokenUsage>,
    finish_reason: Option<String>,
}

impl StreamAccumulator {
    pub fn new(replay: bool) -> Self {
        Self { replay, ..Default::default() }
    }

    pub fn push(&mut self, data: &str, sink: StreamSink<'_>) -> Result<()> {
        let value: Value = serde_json::from_str(data).map_err(|e| anyhow!("invalid stream event ({e}): {data}"))?;
        if let Some(error) = value.get("error").filter(|e| !e.is_null()) {
            return Err(anyhow!("stream error: {error}"));
        }
        if let Some(usage) = parse_usage(&value) {
            self.usage = Some(usage);
        }
        let Some(choice) = value.get("choices").and_then(|c| c.get(0)) else {
            return Ok(());
        };
        let delta = choice.get("delta").cloned().unwrap_or(Value::Null);
        if let Some(reasoning) = reasoning_of(&delta) {
            self.thinking.push_str(reasoning);
            sink(StreamEvent::Thinking(reasoning));
        }
        // Accumulate replay reasoning from the actual `reasoning_content` field
        // only, so the generic `reasoning` fallback is never replayed.
        if let Some(reasoning_content) = reasoning_content_of(&delta) {
            self.reasoning.push_str(reasoning_content);
        }
        if let Some(text) = delta.get("content").and_then(Value::as_str) {
            let (content, thinking) = (&mut self.content, &mut self.thinking);
            self.splitter.push(text, &mut |think, piece| emit_piece(content, thinking, sink, think, piece));
        }
        for (position, call) in delta.get("tool_calls").and_then(Value::as_array).into_iter().flatten().enumerate() {
            let index = call.get("index").and_then(Value::as_u64).map(|i| i as usize).unwrap_or(position);
            if self.calls.len() <= index {
                self.calls.resize(index + 1, Default::default());
            }
            let entry = &mut self.calls[index];
            if let Some(id) = call.get("id").and_then(Value::as_str).filter(|id| !id.is_empty()) {
                entry.0 = id.to_string();
            }
            let function = call.get("function").cloned().unwrap_or(Value::Null);
            if let Some(name) = function.get("name").and_then(Value::as_str) {
                entry.1.push_str(name);
            }
            if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
                entry.2.push_str(arguments);
            }
        }
        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            self.finish_reason = Some(reason.to_string());
        }
        Ok(())
    }

    pub fn finish(mut self, sink: StreamSink<'_>) -> LLMResponse {
        let (content, thinking) = (&mut self.content, &mut self.thinking);
        self.splitter.finish(&mut |think, piece| emit_piece(content, thinking, sink, think, piece));
        let tool_calls = self
            .calls
            .into_iter()
            .enumerate()
            .filter(|(_, (_, name, _))| !name.is_empty())
            .map(|(index, (id, name, raw))| ToolCall {
                id: if id.is_empty() { format!("call_{index}") } else { id },
                name,
                arguments: ToolCall::decode_arguments(&raw),
            })
            .collect();
        LLMResponse {
            content: self.content.trim_start().to_string(),
            tool_calls,
            usage: self.usage,
            stop_reason: self.finish_reason,
            thinking: self.thinking.trim().to_string(),
            thinking_blocks: reasoning_blocks(self.replay, &self.reasoning),
        }
    }
}

fn emit_piece(content: &mut String, thinking: &mut String, sink: StreamSink<'_>, think: bool, piece: &str) {
    if think {
        thinking.push_str(piece);
        sink(StreamEvent::Thinking(piece));
    } else {
        // Drop the blank lines that usually follow `</think>`.
        let piece = if content.is_empty() { piece.trim_start() } else { piece };
        if !piece.is_empty() {
            content.push_str(piece);
            sink(StreamEvent::Text(piece));
        }
    }
}

/// Stream a Chat Completions request to `url`.
pub(crate) async fn stream_chat(
    transport: &HttpTransport,
    url: &str,
    body: Value,
    auth: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    sink: StreamSink<'_>,
) -> Result<LLMResponse> {
    let body = transport.stream_body(body, json!({ "stream": true, "stream_options": { "include_usage": true } }));
    let replay = transport.provider().replay_reasoning;
    let mut accumulator = StreamAccumulator::new(replay);
    let whole = transport.post_stream_to(url, &body, auth, &mut |data| accumulator.push(data, sink)).await?;
    if let Some(value) = whole {
        let response = parse_response(&value, replay)?;
        report_whole(sink, &response);
        return Ok(response);
    }
    Ok(accumulator.finish(sink))
}

#[async_trait]
impl LLMClient for OpenAiClient {
    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
        let body = self.build_body(request);
        let api_key = self.transport.provider().api_key.clone();
        let value = self
            .transport
            .post_json("/chat/completions", &body, |builder| match &api_key {
                Some(key) => builder.bearer_auth(key),
                None => builder,
            })
            .await?;
        parse_response(&value, self.transport.provider().replay_reasoning)
    }

    async fn chat_stream(&self, request: &ChatRequest<'_>, sink: StreamSink<'_>) -> Result<LLMResponse> {
        let provider = self.transport.provider();
        if !provider.stream {
            let response = self.chat(request).await?;
            report_whole(sink, &response);
            return Ok(response);
        }
        let api_key = provider.api_key.clone();
        let url = format!("{}/chat/completions", provider.base_url);
        stream_chat(&self.transport, &url, self.build_body(request), |builder| match &api_key {
            Some(key) => builder.bearer_auth(key),
            None => builder,
        }, sink)
        .await
    }

    async fn detect_context_window(&self) -> Option<DetectedWindow> {
        detect_window(&self.transport).await
    }

    async fn list_models(&self) -> Result<Vec<String>> {
        let provider = self.transport.provider();
        let mut request = self.transport.http().get(format!("{}/models", provider.base_url));
        for (name, value) in &provider.headers {
            request = request.header(name, value);
        }
        if let Some(key) = &provider.api_key {
            request = request.bearer_auth(key);
        }
        let response = request.send().await?;
        let status = response.status();
        let value: Value = response.json().await?;
        if !status.is_success() {
            return Err(anyhow!("listing models failed (HTTP {status}): {value}"));
        }
        // OpenAI shape `{data:[{id}]}`; GitHub Models returns a bare array.
        let items = value.get("data").unwrap_or(&value).as_array().cloned().unwrap_or_default();
        let mut models: Vec<String> = items
            .iter()
            .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_string))
            .collect();
        models.sort();
        Ok(models)
    }

    fn model_name(&self) -> &str {
        &self.transport.provider().model
    }

    fn provider_name(&self) -> &str {
        &self.transport.provider().name
    }
}

/// Per-request timeout for context-window probes.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// Ask an OpenAI-compatible endpoint for the loaded model's context window.
///
/// `/models` covers vLLM (`max_model_len`), DwarfStar ds4, OpenRouter, Together
/// and Kimi (`context_length`), Groq (`context_window`) and Mistral
/// (`max_context_length`). Servers whose `/models` lacks it are recognised by
/// `owned_by` or name and asked their own API: llama.cpp `/props`, LM Studio
/// `/api/v0/models`, Ollama `/api/ps` and `/api/show`.
pub(crate) async fn detect_window(transport: &HttpTransport) -> Option<DetectedWindow> {
    let provider = transport.provider();
    let base = provider.base_url.as_str();
    let root = base.strip_suffix("/v1").unwrap_or(base);
    let model = provider.model.as_str();
    let models = probe(transport, reqwest::Method::GET, &format!("{base}/models"), None).await;
    let entry = models.as_ref().and_then(|m| model_entry(m, model));
    if let Some(found) = entry.and_then(window_in_entry) {
        return Some(found);
    }
    let owner = entry.and_then(|e| e.get("owned_by")).and_then(Value::as_str).unwrap_or_default();
    let is_ollama = provider.name == "ollama" || root.ends_with(":11434") || matches!(owner, "library" | "ollama");
    if owner == "llamacpp" || provider.name == "llamacpp" {
        let url = format!("{root}/props?model={}", urlencode(model));
        let props = probe(transport, reqwest::Method::GET, &url, None).await?;
        return props
            .pointer("/default_generation_settings/n_ctx")
            .or_else(|| props.get("n_ctx"))
            .and_then(as_tokens)
            .map(|tokens| DetectedWindow { tokens, source: "llama.cpp /props n_ctx".into() });
    }
    if owner == "organization_owner" || provider.name == "lmstudio" {
        let listed = probe(transport, reqwest::Method::GET, &format!("{root}/api/v0/models"), None).await?;
        return model_entry(&listed, model)
            .and_then(|m| m.get("loaded_context_length"))
            .and_then(as_tokens)
            .map(|tokens| DetectedWindow { tokens, source: "LM Studio loaded_context_length".into() });
    }
    if is_ollama {
        return ollama_window(transport, root, model).await;
    }
    None
}

/// Ollama: the loaded model's context from `/api/ps`, else `num_ctx` from the
/// model's parameters. The model's maximum (`model_info`) is not used: Ollama
/// runs with a smaller default unless `num_ctx` says otherwise.
async fn ollama_window(transport: &HttpTransport, root: &str, model: &str) -> Option<DetectedWindow> {
    let same = |name: &str| name == model || name.strip_suffix(":latest") == Some(model);
    if let Some(ps) = probe(transport, reqwest::Method::GET, &format!("{root}/api/ps"), None).await {
        let loaded = ps.get("models").and_then(Value::as_array).into_iter().flatten().find(|m| {
            ["name", "model"].iter().any(|k| m.get(*k).and_then(Value::as_str).is_some_and(same))
        });
        if let Some(tokens) = loaded.and_then(|m| m.get("context_length")).and_then(as_tokens) {
            return Some(DetectedWindow { tokens, source: "Ollama /api/ps context_length".into() });
        }
    }
    let show = probe(transport, reqwest::Method::POST, &format!("{root}/api/show"), Some(json!({ "model": model }))).await?;
    let parameters = show.get("parameters").and_then(Value::as_str)?;
    parameters
        .lines()
        .find_map(|line| line.trim().strip_prefix("num_ctx")?.trim().parse().ok())
        .map(|tokens| DetectedWindow { tokens, source: "Ollama num_ctx".into() })
}

async fn probe(transport: &HttpTransport, method: reqwest::Method, url: &str, body: Option<Value>) -> Option<Value> {
    let provider = transport.provider();
    let mut request = transport.http().request(method, url).timeout(PROBE_TIMEOUT);
    for (name, value) in &provider.headers {
        request = request.header(name, value);
    }
    if let Some(key) = &provider.api_key {
        request = request.bearer_auth(key);
    }
    if let Some(body) = body {
        request = request.json(&body);
    }
    let response = request.send().await.ok()?;
    if !response.status().is_success() {
        return None;
    }
    response.json().await.ok()
}

/// The `/models` entry for `model`; a server listing a single model (such as
/// ds4, which accepts aliases) is taken to be serving it.
fn model_entry<'a>(models: &'a Value, model: &str) -> Option<&'a Value> {
    let items = models.get("data").unwrap_or(models).as_array()?;
    items
        .iter()
        .find(|m| m.get("id").and_then(Value::as_str) == Some(model))
        .or(if items.len() == 1 { items.first() } else { None })
}

fn window_in_entry(entry: &Value) -> Option<DetectedWindow> {
    [
        "/max_model_len",
        "/loaded_context_length",
        "/context_length",
        "/top_provider/context_length",
        "/context_window",
        "/max_context_length",
    ]
    .iter()
    .find_map(|pointer| {
        let tokens = entry.pointer(pointer).and_then(as_tokens)?;
        Some(DetectedWindow { tokens, source: format!("/models {}", pointer.trim_start_matches('/').replace('/', ".")) })
    })
}

fn as_tokens(value: &Value) -> Option<usize> {
    value.as_u64().filter(|&n| n > 0).map(|n| n as usize)
}

fn urlencode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{ProviderConfig, ProviderKind, resolve, test_server};
    use crate::tools::ToolDefinition;
    use std::collections::HashMap;

    fn provider(base_url: &str, extra: &str) -> ResolvedProvider {
        let mut user = HashMap::new();
        user.insert(
            "test".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some(base_url.into()),
                api_key: Some("sk-test".into()),
                retry_initial_backoff_ms: Some(1),
                extra_body: Some(toml::from_str(extra).unwrap()),
                drop_params: Some(vec!["temperature".into()]),
                ..Default::default()
            },
        );
        resolve("test/some-model", &user, "mock").unwrap()
    }

    fn conversation() -> Vec<Message> {
        vec![
            Message::system("sys"),
            Message::user("what time is it?"),
            Message::assistant_with_tools(
                "",
                vec![ToolCall { id: "c1".into(), name: "get_time".into(), arguments: json!({}) }],
            ),
            Message::tool_result("c1", "get_time", "noon"),
        ]
    }

    #[test]
    fn encodes_tool_round_trip_and_provider_overrides() {
        let client = OpenAiClient::new(provider("http://x", "think = false")).unwrap();
        let messages = conversation();
        let tools = [ToolDefinition::new("get_time", "time", json!({"type":"object"}))];
        let body = client.build_body(&ChatRequest {
            messages: &messages,
            tools: &tools,
            temperature: Some(0.2),
            max_tokens: Some(100),
        });
        assert_eq!(body["model"], "some-model");
        assert_eq!(body["think"], false);
        assert!(body.get("temperature").is_none());
        assert_eq!(body["max_tokens"], 100);
        assert_eq!(body["messages"][2]["content"], Value::Null);
        assert_eq!(body["messages"][2]["tool_calls"][0]["function"]["arguments"], "{}");
        assert_eq!(body["messages"][3]["tool_call_id"], "c1");
        assert_eq!(body["tools"][0]["function"]["name"], "get_time");
    }

    #[test]
    fn replay_ignores_generic_reasoning_field() {
        // With replay enabled but only the generic `reasoning` field present,
        // the value is shown as thinking but never stored as a replay block.
        let response = parse_response(
            &json!({ "choices": [{"message": {"content": "hi", "reasoning": "generic"}}] }),
            true,
        )
        .unwrap();
        assert_eq!(response.thinking, "generic");
        assert!(response.thinking_blocks.is_empty());
    }

    #[test]
    fn parses_tool_calls_and_bad_arguments() {
        let response = parse_response(&json!({
            "choices": [{"finish_reason": "tool_calls", "message": {"content": null, "tool_calls": [
                {"id": "a", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}},
                {"id": "b", "type": "function", "function": {"name": "bash", "arguments": "{oops"}}
            ]}}],
            "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}
        }), false)
        .unwrap();
        assert_eq!(response.tool_calls[0].arguments["command"], "ls");
        assert_eq!(response.tool_calls[1].arguments, Value::String("{oops".into()));
        assert_eq!(response.usage.unwrap().total_tokens, 7);
        assert_eq!(response.stop_reason.as_deref(), Some("tool_calls"));
    }

    #[tokio::test]
    async fn retries_rate_limits_then_succeeds() {
        let ok = json!({"choices":[{"message":{"content":"hi"},"finish_reason":"stop"}]}).to_string();
        let (url, captured) = test_server::serve(vec![
            (429, "retry-after: 0\r\n", r#"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#.into()),
            (503, "", "upstream".into()),
            (200, "", ok),
        ])
        .await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hello")];
        let response = client
            .chat(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None })
            .await
            .unwrap();
        assert_eq!(response.content, "hi");
        let captured = captured.lock().unwrap();
        assert_eq!(captured.len(), 3);
        assert_eq!(captured[2].path, "/chat/completions");
        assert_eq!(captured[2].body["model"], "some-model");
        assert!(captured[2].headers.to_lowercase().contains("authorization: bearer sk-test"));
    }

    #[tokio::test]
    async fn retries_truncated_success_bodies() {
        let ok = json!({"choices":[{"message":{"content":"whole"}}]}).to_string();
        let (url, captured) = test_server::serve(vec![
            (200, "x-truncate: 1\r\n", r#"{"choices":[{"mess"#.into()),
            (200, "", ok),
        ])
        .await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hello")];
        let response = client
            .chat(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None })
            .await
            .unwrap();
        assert_eq!(response.content, "whole");
        assert_eq!(captured.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn does_not_retry_auth_errors() {
        let (url, captured) = test_server::serve(vec![(
            401,
            "",
            r#"{"error":{"message":"bad key","type":"invalid_request_error","code":"invalid_api_key"}}"#.into(),
        )])
        .await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hello")];
        let err = client
            .chat(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None })
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("invalid_api_key"), "{err:#}");
        assert_eq!(captured.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn streams_reasoning_text_and_tool_calls() {
        let events = [
            json!({"choices":[{"delta":{"role":"assistant","reasoning_content":"Let me "}}]}),
            json!({"choices":[{"delta":{"reasoning_content":"check."}}]}),
            json!({"choices":[{"delta":{"content":"<think>more</think>\n\nChecking"}}]}),
            json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"bash","arguments":"{\"comm"}}]}}]}),
            json!({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"and\":\"ls\"}"}}]},"finish_reason":"tool_calls"}]}),
            json!({"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}),
        ];
        let mut body: String = events.iter().map(|e| format!("data: {e}\n\n")).collect();
        body.push_str("data: [DONE]\n\n");
        let (url, captured) = test_server::serve(vec![(200, "content-type: text/event-stream\r\n", body)]).await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hello")];
        let seen = std::sync::Mutex::new(Vec::new());
        let sink = |event: StreamEvent<'_>| {
            seen.lock().unwrap().push(match event {
                StreamEvent::Text(t) => format!("T:{t}"),
                StreamEvent::Thinking(t) => format!("R:{t}"),
            })
        };
        let response = client
            .chat_stream(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None }, &sink)
            .await
            .unwrap();
        assert_eq!(response.thinking, "Let me check.more");
        assert_eq!(response.content, "Checking");
        assert_eq!(response.tool_calls, vec![ToolCall { id: "call_a".into(), name: "bash".into(), arguments: json!({"command": "ls"}) }]);
        assert_eq!(response.usage.unwrap().total_tokens, 17);
        assert_eq!(response.stop_reason.as_deref(), Some("tool_calls"));
        assert_eq!(*seen.lock().unwrap(), vec!["R:Let me ", "R:check.", "R:more", "T:Checking"]);
        assert!(response.thinking_blocks.is_empty(), "reasoning is kept only with replay_reasoning");
        let captured = captured.lock().unwrap();
        assert_eq!(captured[0].body["stream"], true);
        assert_eq!(captured[0].body["stream_options"]["include_usage"], true);
    }

    #[tokio::test]
    async fn replays_reasoning_content_when_enabled() {
        let events = [
            json!({"choices":[{"delta":{"role":"assistant","reasoning_content":"Need ls."}}]}),
            json!({"choices":[{"delta":{"content":"<think>inline</think>ok"}}]}),
            json!({"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"bash","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}),
        ];
        let body: String = events.iter().map(|e| format!("data: {e}\n\n")).collect::<String>() + "data: [DONE]\n\n";
        let (url, _) = test_server::serve(vec![(200, "content-type: text/event-stream\r\n", body)]).await;
        let mut resolved = provider(&url, "");
        resolved.replay_reasoning = true;
        let client = OpenAiClient::new(resolved.clone()).unwrap();
        let messages = [Message::user("hello")];
        let request = ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None };
        let response = client.chat_stream(&request, &|_| {}).await.unwrap();
        // Only the provider's reasoning field is replayed, not inline <think> text.
        assert_eq!(response.thinking_blocks, vec![json!({"type": "reasoning_content", "text": "Need ls."})]);

        let assistant = Message {
            tool_calls: response.tool_calls.clone(),
            thinking_blocks: response.thinking_blocks.clone(),
            ..Message::assistant(&response.content)
        };
        let history = [Message::user("hello"), assistant, Message {
            thinking_blocks: vec![json!({"type": "thinking", "thinking": "t", "signature": "s"})],
            ..Message::assistant("done")
        }];
        let request = ChatRequest { messages: &history, tools: &[], temperature: None, max_tokens: None };
        let body = client.build_body(&request);
        assert_eq!(body["messages"][1]["reasoning_content"], "Need ls.");
        assert!(body["messages"][2].get("reasoning_content").is_none(), "Anthropic blocks are not replayed");
        resolved.replay_reasoning = false;
        let body = OpenAiClient::new(resolved).unwrap().build_body(&request);
        assert!(body["messages"][1].get("reasoning_content").is_none());
    }

    #[tokio::test]
    async fn stream_falls_back_to_json_and_splits_think_tags() {
        let ok = json!({"choices":[{"message":{"content":"<think>hmm</think>\nhi"},"finish_reason":"stop"}]}).to_string();
        let (url, _) = test_server::serve(vec![(200, "", ok)]).await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hello")];
        let response = client
            .chat_stream(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: None }, &|_| {})
            .await
            .unwrap();
        assert_eq!((response.content.as_str(), response.thinking.as_str()), ("hi", "hmm"));
    }

    async fn detect(provider_name: &str, responses: Vec<(u16, &'static str, String)>) -> (Option<DetectedWindow>, Vec<String>) {
        let (url, captured) = test_server::serve(responses).await;
        let mut user = HashMap::new();
        user.insert(
            provider_name.to_string(),
            ProviderConfig { kind: Some(ProviderKind::Openai), base_url: Some(format!("{url}/v1")), ..Default::default() },
        );
        let resolved = resolve(&format!("{provider_name}/qwen3:8b"), &user, "mock").unwrap();
        let found = OpenAiClient::new(resolved).unwrap().detect_context_window().await;
        let paths = captured.lock().unwrap().iter().map(|c| c.path.clone()).collect();
        (found, paths)
    }

    fn window(tokens: usize, source: &str) -> Option<DetectedWindow> {
        Some(DetectedWindow { tokens, source: source.into() })
    }

    #[tokio::test]
    async fn detects_window_from_models_listing() {
        let models = json!({"data": [
            {"id": "other", "max_model_len": 1},
            {"id": "qwen3:8b", "owned_by": "vllm", "max_model_len": 32768}
        ]});
        let (found, paths) = detect("local", vec![(200, "", models.to_string())]).await;
        assert_eq!(found, window(32768, "/models max_model_len"));
        assert_eq!(paths, ["/v1/models"]);

        // ds4 lists one model (and accepts aliases for it).
        let models = json!({"data": [{"id": "qwen3.8-flash-next", "top_provider": {"context_length": 8192}}]});
        let (found, _) = detect("local", vec![(200, "", models.to_string())]).await;
        assert_eq!(found, window(8192, "/models top_provider.context_length"));
    }

    #[tokio::test]
    async fn asks_llama_cpp_for_its_loaded_context() {
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "llamacpp", "meta": {"n_ctx_train": 262144}}]});
        let props = json!({"default_generation_settings": {"n_ctx": 65536}});
        let (found, paths) = detect("local", vec![(200, "", models.to_string()), (200, "", props.to_string())]).await;
        assert_eq!(found, window(65536, "llama.cpp /props n_ctx"));
        assert_eq!(paths, ["/v1/models", "/props?model=qwen3%3A8b"]);
    }

    #[tokio::test]
    async fn recognizes_llama_cpp_by_provider_name() {
        // A llama.cpp `/models` response without the `llamacpp` owner is still
        // probed when the provider is named `llamacpp`.
        let models = json!({"data": [{"id": "qwen3:8b"}]});
        let props = json!({"default_generation_settings": {"n_ctx": 65536}});
        let (found, paths) = detect("llamacpp", vec![(200, "", models.to_string()), (200, "", props.to_string())]).await;
        assert_eq!(found, window(65536, "llama.cpp /props n_ctx"));
        assert_eq!(paths, ["/v1/models", "/props?model=qwen3%3A8b"]);
    }

    #[tokio::test]
    async fn recognizes_lm_studio_by_provider_name() {
        // LM Studio configured under the natural `lmstudio` name is asked its
        // own API even when the `/models` owner is not `organization_owner`.
        let models = json!({"data": [{"id": "qwen3:8b"}]});
        let listed = json!({"data": [{"id": "qwen3:8b", "loaded_context_length": 12288}]});
        let (found, paths) = detect("lmstudio", vec![(200, "", models.to_string()), (200, "", listed.to_string())]).await;
        assert_eq!(found, window(12288, "LM Studio loaded_context_length"));
        assert_eq!(paths, ["/v1/models", "/api/v0/models"]);
    }

    #[tokio::test]
    async fn uses_ollama_num_ctx_not_the_model_maximum() {
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "library"}]});
        let ps = json!({"models": []});
        let show = json!({"parameters": "temperature 0.6\nnum_ctx                        16384", "model_info": {"qwen3.context_length": 40960}});
        let (found, paths) = detect(
            "ollama",
            vec![(200, "", models.to_string()), (200, "", ps.to_string()), (200, "", show.to_string())],
        )
        .await;
        assert_eq!(found, window(16384, "Ollama num_ctx"));
        assert_eq!(paths, ["/v1/models", "/api/ps", "/api/show"]);

        let ps = json!({"models": [{"name": "qwen3:8b", "context_length": 8192}]});
        let (found, _) = detect("ollama", vec![(200, "", models.to_string()), (200, "", ps.to_string())]).await;
        assert_eq!(found, window(8192, "Ollama /api/ps context_length"));
    }

    #[tokio::test]
    async fn reports_nothing_when_the_endpoint_does_not_say() {
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "system"}, {"id": "b"}]});
        let (found, paths) = detect("hosted", vec![(200, "", models.to_string())]).await;
        assert_eq!(found, None);
        assert_eq!(paths, ["/v1/models"], "unknown servers get no extra probes");
        let (found, _) = detect("hosted", vec![(404, "", "{}".into())]).await;
        assert_eq!(found, None);
    }
}
