//! Anthropic Messages API client.

use anyhow::{Result, anyhow};
use async_trait::async_trait;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};

use super::{HttpTransport, ResolvedProvider, StreamAction};
use crate::llm::{ChatRequest, LLMClient, LLMResponse, Message, Role, StreamEvent, StreamSink, TokenUsage, ToolCall, report_whole};

const API_VERSION: &str = "2023-06-01";
/// The Messages API requires `max_tokens`.
const DEFAULT_MAX_TOKENS: i64 = 8192;

pub struct AnthropicClient {
    transport: HttpTransport,
}

impl AnthropicClient {
    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        Ok(Self {
            transport: HttpTransport::new(provider)?,
        })
    }

    pub fn build_body(&self, request: &ChatRequest<'_>) -> Value {
        build_body(&self.transport, request)
    }
}

/// Messages API request body for `request`, with provider overrides applied.
pub(crate) fn build_body(transport: &HttpTransport, request: &ChatRequest<'_>) -> Value {
        let provider = transport.provider();
        let system: Vec<&str> = request
            .messages
            .iter()
            .filter(|m| m.role == Role::System && !m.content.is_empty())
            .map(|m| m.content.as_str())
            .collect();
        let mut body = json!({
            "model": provider.model,
            "max_tokens": request.max_tokens.unwrap_or(DEFAULT_MAX_TOKENS),
            "messages": encode_messages(request.messages),
        });
        if !system.is_empty() {
            body["system"] = json!(system.join("\n\n"));
        }
        if !request.tools.is_empty() {
            body["tools"] = request
                .tools
                .iter()
                .map(|tool| {
                    json!({
                        "name": tool.name,
                        "description": tool.description,
                        "input_schema": tool.parameters,
                    })
                })
                .collect();
        }
        if let Some(temperature) = request.temperature {
            // Anthropic's range is 0..=1.
            body["temperature"] = json!(temperature.clamp(0.0, 1.0));
        }
        transport.finish_body(body)
}

/// Encode messages as content blocks, merging consecutive same-role turns
/// (tool results travel as `user` messages and must be grouped).
fn encode_messages(messages: &[Message]) -> Vec<Value> {
    let mut encoded: Vec<(String, Vec<Value>)> = Vec::new();
    for message in messages {
        let (role, blocks) = match message.role {
            Role::System => continue,
            Role::User => ("user", vec![json!({"type": "text", "text": message.content})]),
            Role::Tool => (
                "user",
                vec![{
                    let mut block = json!({
                        "type": "tool_result",
                        "tool_use_id": message.tool_call_id,
                        "content": message.content,
                    });
                    if message.is_error {
                        block["is_error"] = json!(true);
                    }
                    block
                }],
            ),
            Role::Assistant => {
                // Reasoning blocks must precede the text and tool use they led to.
                // Blocks from other providers (e.g. OpenAI-style reasoning) are not replayable here.
                let mut blocks: Vec<Value> = message
                    .thinking_blocks
                    .iter()
                    .filter(|b| matches!(b.get("type").and_then(Value::as_str), Some("thinking" | "redacted_thinking")))
                    .cloned()
                    .collect();
                if !message.content.is_empty() {
                    blocks.push(json!({"type": "text", "text": message.content}));
                }
                for call in &message.tool_calls {
                    let input = if call.arguments.is_object() { call.arguments.clone() } else { json!({}) };
                    blocks.push(json!({"type": "tool_use", "id": call.id, "name": call.name, "input": input}));
                }
                if blocks.is_empty() {
                    continue;
                }
                ("assistant", blocks)
            }
        };
        match encoded.last_mut() {
            Some((last_role, last_blocks)) if last_role == role => last_blocks.extend(blocks),
            _ => encoded.push((role.to_string(), blocks)),
        }
    }
    encoded
        .into_iter()
        .map(|(role, content)| json!({"role": role, "content": content}))
        .collect()
}

pub fn parse_response(value: &Value) -> Result<LLMResponse> {
    let blocks = value
        .get("content")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("response has no content: {value}"))?;
    let mut content = String::new();
    let mut thinking = String::new();
    let mut thinking_blocks = Vec::new();
    let mut tool_calls = Vec::new();
    for block in blocks {
        match block.get("type").and_then(Value::as_str) {
            Some("text") => content.push_str(block.get("text").and_then(Value::as_str).unwrap_or_default()),
            Some("thinking") => {
                thinking.push_str(block.get("thinking").and_then(Value::as_str).unwrap_or_default());
                thinking_blocks.push(block.clone());
            }
            Some("redacted_thinking") => thinking_blocks.push(block.clone()),
            Some("tool_use") => tool_calls.push(ToolCall {
                id: block.get("id").and_then(Value::as_str).unwrap_or_default().to_string(),
                name: block.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
                arguments: block.get("input").cloned().unwrap_or_else(|| json!({})),
            }),
            _ => {}
        }
    }
    Ok(LLMResponse {
        content,
        tool_calls,
        usage: value.get("usage").map(|usage| parse_usage(usage, 0)),
        stop_reason: value.get("stop_reason").and_then(Value::as_str).map(str::to_string),
        thinking,
        thinking_blocks,
    })
}

/// Usage with `prompt` already known (from `message_start`) added in.
fn parse_usage(usage: &Value, prompt: i64) -> TokenUsage {
    let field = |name: &str| usage.get(name).and_then(Value::as_i64).unwrap_or(0);
    let prompt = prompt + field("input_tokens") + field("cache_read_input_tokens") + field("cache_creation_input_tokens");
    let completion = field("output_tokens");
    TokenUsage { prompt_tokens: prompt, completion_tokens: completion, total_tokens: prompt + completion }
}

/// Content block being streamed.
enum Block {
    Text(String),
    Thinking { thinking: String, signature: String },
    Opaque(Value),
    ToolUse { id: String, name: String, json: String },
}

/// Accumulates a streamed Messages response.
#[derive(Default)]
pub(crate) struct StreamAccumulator {
    blocks: Vec<(u64, Block)>,
    prompt_tokens: i64,
    usage: Option<TokenUsage>,
    stop_reason: Option<String>,
}

impl StreamAccumulator {
    fn block(&mut self, index: u64) -> Option<&mut Block> {
        self.blocks.iter_mut().find(|(i, _)| *i == index).map(|(_, b)| b)
    }

    pub(crate) fn push(&mut self, data: &str, sink: StreamSink<'_>) -> Result<()> {
        let event: Value = serde_json::from_str(data).map_err(|e| anyhow!("invalid stream event ({e}): {data}"))?;
        let str_of = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
        let index = event.get("index").and_then(Value::as_u64).unwrap_or(0);
        match event.get("type").and_then(Value::as_str) {
            Some("message_start") => {
                if let Some(usage) = event.pointer("/message/usage") {
                    let start = parse_usage(usage, 0);
                    self.prompt_tokens = start.prompt_tokens;
                    self.usage = Some(start);
                }
            }
            Some("content_block_start") => {
                let block = event.get("content_block").cloned().unwrap_or(Value::Null);
                let block = match block.get("type").and_then(Value::as_str) {
                    Some("text") => Block::Text(str_of(&block, "text")),
                    Some("thinking") => Block::Thinking { thinking: str_of(&block, "thinking"), signature: str_of(&block, "signature") },
                    Some("tool_use") => Block::ToolUse { id: str_of(&block, "id"), name: str_of(&block, "name"), json: String::new() },
                    _ => Block::Opaque(block),
                };
                self.blocks.push((index, block));
            }
            Some("content_block_delta") => {
                let delta = event.get("delta").cloned().unwrap_or(Value::Null);
                let piece = |key: &str| delta.get(key).and_then(Value::as_str).unwrap_or_default();
                match (self.block(index), delta.get("type").and_then(Value::as_str)) {
                    (Some(Block::Text(text)), Some("text_delta")) => {
                        text.push_str(piece("text"));
                        sink(StreamEvent::Text(piece("text")));
                    }
                    (Some(Block::Thinking { thinking, .. }), Some("thinking_delta")) => {
                        thinking.push_str(piece("thinking"));
                        sink(StreamEvent::Thinking(piece("thinking")));
                    }
                    (Some(Block::Thinking { signature, .. }), Some("signature_delta")) => signature.push_str(piece("signature")),
                    (Some(Block::ToolUse { json, .. }), Some("input_json_delta")) => json.push_str(piece("partial_json")),
                    _ => {}
                }
            }
            Some("message_delta") => {
                if let Some(reason) = event.pointer("/delta/stop_reason").and_then(Value::as_str) {
                    self.stop_reason = Some(reason.to_string());
                }
                if let Some(usage) = event.get("usage") {
                    let mut total = parse_usage(usage, 0);
                    // `message_delta` usage repeats input tokens on some versions.
                    total.prompt_tokens = total.prompt_tokens.max(self.prompt_tokens);
                    total.total_tokens = total.prompt_tokens + total.completion_tokens;
                    self.usage = Some(total);
                }
            }
            Some("error") => {
                let error = event.get("error").cloned().unwrap_or(event.clone());
                return Err(anyhow!("stream error: {error}"));
            }
            _ => {}
        }
        Ok(())
    }

    pub(crate) fn finish(self) -> LLMResponse {
        let mut response = LLMResponse { usage: self.usage, stop_reason: self.stop_reason, ..Default::default() };
        for (_, block) in self.blocks {
            match block {
                Block::Text(text) => response.content.push_str(&text),
                Block::Thinking { thinking, signature } => {
                    response.thinking.push_str(&thinking);
                    response.thinking_blocks.push(json!({"type": "thinking", "thinking": thinking, "signature": signature}));
                }
                Block::Opaque(block) => {
                    if block.get("type").and_then(Value::as_str) == Some("redacted_thinking") {
                        response.thinking_blocks.push(block);
                    }
                }
                Block::ToolUse { id, name, json } => response.tool_calls.push(ToolCall {
                    id,
                    name,
                    arguments: match ToolCall::decode_arguments(&json) {
                        Value::Object(map) => Value::Object(map),
                        _ => json!({}),
                    },
                }),
            }
        }
        response
    }
}

/// Stream a Messages request to `url`, accumulating a full response.
/// `auth` adds provider-specific authentication and version headers.
pub(crate) async fn stream(
    transport: &HttpTransport,
    url: &str,
    body: Value,
    auth: impl Fn(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    sink: StreamSink<'_>,
) -> Result<LLMResponse> {
    let body = transport.stream_body(body, json!({ "stream": true }));
    let mut accumulator = StreamAccumulator::default();
    let whole = transport
        .post_stream_to(url, &body, auth, &mut |action| match action {
            StreamAction::Data(data) => {
                let visible = AtomicBool::new(false);
                accumulator.push(data, &|event| {
                    if event.has_content() {
                        visible.store(true, Ordering::Relaxed);
                    }
                    sink(event);
                })?;
                Ok(visible.load(Ordering::Relaxed))
            }
            StreamAction::Reset => {
                accumulator = StreamAccumulator::default();
                Ok(false)
            }
        })
        .await?;
    if let Some(value) = whole {
        let response = parse_response(&value)?;
        report_whole(sink, &response);
        return Ok(response);
    }
    Ok(accumulator.finish())
}

#[async_trait]
impl LLMClient for AnthropicClient {
    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
        let body = self.build_body(request);
        let api_key = self.transport.provider().api_key.clone();
        let value = self
            .transport
            .post_json("/messages", &body, |builder| {
                let builder = builder.header("anthropic-version", API_VERSION);
                match &api_key {
                    Some(key) => builder.header("x-api-key", key),
                    None => builder,
                }
            })
            .await?;
        parse_response(&value)
    }

    async fn chat_stream(&self, request: &ChatRequest<'_>, sink: StreamSink<'_>) -> Result<LLMResponse> {
        let provider = self.transport.provider();
        if !provider.stream {
            let response = self.chat(request).await?;
            report_whole(sink, &response);
            return Ok(response);
        }
        let api_key = provider.api_key.clone();
        let url = format!("{}/messages", provider.base_url);
        stream(&self.transport, &url, self.build_body(request), |builder| {
            let builder = builder.header("anthropic-version", API_VERSION);
            match &api_key {
                Some(key) => builder.header("x-api-key", key),
                None => builder,
            }
        }, sink)
        .await
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
    use crate::providers::{ProviderConfig, resolve, test_server};
    use crate::tools::ToolDefinition;
    use std::collections::HashMap;

    fn client(base_url: &str) -> AnthropicClient {
        let mut user = HashMap::new();
        user.insert(
            "anthropic".to_string(),
            ProviderConfig {
                base_url: Some(base_url.into()),
                api_key: Some("ak-test".into()),
                retry_initial_backoff_ms: Some(1),
                ..Default::default()
            },
        );
        AnthropicClient::new(resolve("anthropic/claude-test", &user, "mock").unwrap()).unwrap()
    }

    #[test]
    fn encodes_system_tools_and_grouped_tool_results() {
        let messages = vec![
            Message::system("be brief"),
            Message::user("time and date?"),
            Message::assistant_with_tools(
                "checking",
                vec![
                    ToolCall { id: "t1".into(), name: "get_time".into(), arguments: json!({}) },
                    ToolCall { id: "t2".into(), name: "bash".into(), arguments: json!("{bad") },
                ],
            ),
            Message::tool_result("t1", "get_time", "noon"),
            Message::tool_result("t2", "bash", "Error"),
        ];
        let tools = [ToolDefinition::new("get_time", "time", json!({"type":"object"}))];
        let body = client("http://x").build_body(&ChatRequest {
            messages: &messages,
            tools: &tools,
            temperature: Some(1.5),
            max_tokens: None,
        });
        assert_eq!(body["system"], "be brief");
        assert_eq!(body["max_tokens"], DEFAULT_MAX_TOKENS);
        assert_eq!(body["temperature"], 1.0);
        assert_eq!(body["tools"][0]["input_schema"]["type"], "object");
        let encoded = body["messages"].as_array().unwrap();
        assert_eq!(encoded.len(), 3);
        assert_eq!(encoded[1]["content"][1]["type"], "tool_use");
        assert_eq!(encoded[1]["content"][2]["input"], json!({}));
        assert_eq!(encoded[2]["role"], "user");
        assert_eq!(encoded[2]["content"].as_array().unwrap().len(), 2);
        assert_eq!(encoded[2]["content"][1]["tool_use_id"], "t2");
    }

    #[tokio::test]
    async fn retries_overload_and_parses_tool_use() {
        let ok = json!({
            "content": [
                {"type": "text", "text": "Let me check."},
                {"type": "tool_use", "id": "toolu_1", "name": "bash", "input": {"command": "date"}}
            ],
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        })
        .to_string();
        let (url, captured) = test_server::serve(vec![
            (529, "retry-after: 0.01\r\n", r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.into()),
            (200, "", ok),
        ])
        .await;
        let messages = [Message::user("date?")];
        let response = client(&url)
            .chat(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: Some(64) })
            .await
            .unwrap();
        assert_eq!(response.content, "Let me check.");
        assert_eq!(response.tool_calls[0].arguments["command"], "date");
        assert_eq!(response.usage.unwrap().total_tokens, 15);
        let captured = captured.lock().unwrap();
        assert_eq!(captured[1].path, "/messages");
        let headers = captured[1].headers.to_lowercase();
        assert!(headers.contains("x-api-key: ak-test"));
        assert!(headers.contains("anthropic-version: 2023-06-01"));
    }

    #[tokio::test]
    async fn streams_thinking_text_and_tool_use_and_replays_thinking() {
        let events = [
            json!({"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":1}}}),
            json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}),
            json!({"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan."}}),
            json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}),
            json!({"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}),
            json!({"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Running"}}),
            json!({"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"bash","input":{}}}),
            json!({"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}),
            json!({"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"ls\"}"}}),
            json!({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}),
            json!({"type":"message_stop"}),
        ];
        let body: String = events.iter().map(|e| format!("event: {}\ndata: {e}\n\n", e["type"].as_str().unwrap())).collect();
        let (url, captured) = test_server::serve(vec![(200, "content-type: text/event-stream\r\n", body)]).await;
        let messages = [Message::user("hello")];
        let seen = std::sync::Mutex::new(String::new());
        let sink = |event: StreamEvent<'_>| {
            if let StreamEvent::Thinking(t) = event {
                seen.lock().unwrap().push_str(t);
            }
        };
        let response = client(&url)
            .chat_stream(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: Some(64) }, &sink)
            .await
            .unwrap();
        assert_eq!(*seen.lock().unwrap(), "Plan.");
        assert_eq!(response.content, "Running");
        assert_eq!(response.thinking, "Plan.");
        assert_eq!(response.tool_calls[0].arguments, json!({"command": "ls"}));
        assert_eq!(response.usage, Some(TokenUsage { prompt_tokens: 20, completion_tokens: 9, total_tokens: 29 }));
        assert_eq!(captured.lock().unwrap()[0].body["stream"], true);

        let assistant = Message {
            thinking_blocks: response.thinking_blocks.clone(),
            ..Message::assistant_with_tools(&response.content, response.tool_calls.clone())
        };
        let encoded = encode_messages(&[Message::user("hello"), assistant]);
        assert_eq!(encoded[1]["content"][0], json!({"type": "thinking", "thinking": "Plan.", "signature": "sig"}));
        assert_eq!(encoded[1]["content"][1]["type"], "text");
    }

    #[test]
    fn skips_reasoning_blocks_from_openai_compatible_providers() {
        let assistant = Message {
            thinking_blocks: vec![json!({"type": "reasoning_content", "text": "from kimi"})],
            ..Message::assistant("hi")
        };
        let encoded = encode_messages(&[Message::user("hello"), assistant]);
        assert_eq!(encoded[1]["content"], json!([{"type": "text", "text": "hi"}]));
    }

    #[tokio::test]
    async fn retries_after_empty_delta_and_resets_accumulator() {
        // The first attempt delivers a *complete* SSE event whose `text_delta`
        // is empty — the sink is invoked but nothing visible reaches the caller
        // — and is then severed mid-stream. An empty delta must not flip the
        // "visible output emitted" flag, so the transient failure is still
        // retried (regression for empty deltas suppressing retries). The retry
        // must also reset the attempt-local accumulator so the text buffered on
        // the first attempt is not duplicated onto the second.
        let start = json!({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}});
        let empty = json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}});
        let mut truncated: String = [&start, &empty]
            .iter()
            .map(|e| format!("event: {}\ndata: {e}\n\n", e["type"].as_str().unwrap()))
            .collect();
        // A second event begins but is cut off before it completes.
        truncated.push_str("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"wor");
        let good_events = [
            json!({"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":1}}}),
            json!({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
            json!({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}),
            json!({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}),
            json!({"type":"message_stop"}),
        ];
        let good: String = good_events
            .iter()
            .map(|e| format!("event: {}\ndata: {e}\n\n", e["type"].as_str().unwrap()))
            .collect();
        let (url, captured) = test_server::serve(vec![
            (200, "content-type: text/event-stream\r\nx-truncate: 1\r\n", truncated),
            (200, "content-type: text/event-stream\r\n", good),
        ])
        .await;
        let messages = [Message::user("hi")];
        let seen = std::sync::Mutex::new(Vec::new());
        let sink = |event: StreamEvent<'_>| {
            if let StreamEvent::Text(t) = event
                && !t.is_empty()
            {
                seen.lock().unwrap().push(t.to_string());
            }
        };
        let response = client(&url)
            .chat_stream(&ChatRequest { messages: &messages, tools: &[], temperature: None, max_tokens: Some(64) }, &sink)
            .await
            .unwrap();
        // An empty delta must not suppress the retry.
        assert_eq!(captured.lock().unwrap().len(), 2);
        // The accumulator was reset before the retry: text is not duplicated.
        assert_eq!(response.content, "world");
        assert_eq!(*seen.lock().unwrap(), vec!["world"]);
    }
}
