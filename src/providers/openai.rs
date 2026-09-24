//! OpenAI Chat Completions client. Works with any OpenAI-compatible endpoint.

use anyhow::{Result, anyhow};
use async_trait::async_trait;
use serde_json::{Value, json};

use super::{HttpTransport, ResolvedProvider};
use crate::llm::{
    ChatRequest, LLMClient, LLMResponse, Message, Role, StreamEvent, StreamSink, ThinkSplitter, TokenUsage, ToolCall,
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
    let thinking_blocks = reasoning_blocks(replay, reasoning);
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
            self.reasoning.push_str(reasoning);
            sink(StreamEvent::Thinking(reasoning));
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
}
