//! OpenAI Responses API translation (`POST {base_url}/responses`).
//!
//! Some Copilot-served models (`gpt-*`, `grok-*`, ...) are only reachable
//! through the Responses endpoint and reject `/chat/completions` with an
//! `unsupported_api_for_model` HTTP 400. The Responses wire format differs from
//! Chat Completions — a flat `input` item list instead of `messages`, and an
//! `output` item list instead of `choices` — so this module builds and parses
//! that format while presenting the provider-neutral `ChatRequest`/`LLMResponse`
//! types used everywhere else.

use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use super::{HttpTransport, StreamAction};
use crate::llm::{
    ChatRequest, LLMResponse, Role, StreamEvent, StreamSink, TokenUsage, ToolCall, report_whole,
};

/// Responses API request body for `request`, with provider overrides applied.
pub(crate) fn build_body(transport: &HttpTransport, request: &ChatRequest<'_>) -> Value {
    let provider = transport.provider();
    let mut instructions: Vec<&str> = Vec::new();
    let mut input: Vec<Value> = Vec::new();
    for message in request.messages {
        match message.role {
            Role::System => {
                if !message.content.is_empty() {
                    instructions.push(message.content.as_str());
                }
            }
            Role::User => input.push(json!({ "role": "user", "content": message.content })),
            Role::Assistant => {
                if !message.content.is_empty() {
                    input.push(json!({ "role": "assistant", "content": message.content }));
                }
                for call in &message.tool_calls {
                    input.push(json!({
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.encoded_arguments(),
                    }));
                }
            }
            Role::Tool => input.push(json!({
                "type": "function_call_output",
                "call_id": message.tool_call_id.as_deref().unwrap_or_default(),
                "output": message.content,
            })),
        }
    }
    let mut body = json!({ "model": provider.model, "input": input });
    if !instructions.is_empty() {
        body["instructions"] = json!(instructions.join("\n\n"));
    }
    if !request.tools.is_empty() {
        body["tools"] = request
            .tools
            .iter()
            .map(|tool| {
                json!({
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters,
                })
            })
            .collect();
    }
    if let Some(temperature) = request.temperature {
        body["temperature"] = json!(temperature);
    }
    if let Some(max_tokens) = request.max_tokens {
        body["max_output_tokens"] = json!(max_tokens);
    }
    transport.finish_body(body)
}

/// Text carried by a Responses content-part list (`output_text` parts).
fn parts_text(content: &Value) -> String {
    content
        .as_array()
        .into_iter()
        .flatten()
        .filter(|part| part.get("type").and_then(Value::as_str) != Some("refusal"))
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect()
}

/// Reasoning text carried by a `reasoning` output item (`summary`/`content`).
fn reasoning_text(item: &Value) -> String {
    ["summary", "content"]
        .iter()
        .filter_map(|key| item.get(*key))
        .map(parts_text)
        .collect()
}

/// Parse a complete (non-streamed) Responses payload.
pub(crate) fn parse_response(value: &Value) -> Result<LLMResponse> {
    let output = value
        .get("output")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("response has no output: {value}"))?;
    let mut content = String::new();
    let mut thinking = String::new();
    let mut tool_calls = Vec::new();
    for item in output {
        match item.get("type").and_then(Value::as_str) {
            Some("message") => {
                content.push_str(&parts_text(item.get("content").unwrap_or(&Value::Null)))
            }
            Some("reasoning") => thinking.push_str(&reasoning_text(item)),
            Some("function_call") => tool_calls.push(ToolCall {
                id: item
                    .get("call_id")
                    .or_else(|| item.get("id"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                name: item
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                arguments: ToolCall::decode_arguments(
                    item.get("arguments")
                        .and_then(Value::as_str)
                        .unwrap_or_default(),
                ),
            }),
            _ => {}
        }
    }
    Ok(LLMResponse {
        content,
        tool_calls,
        usage: parse_usage(value.get("usage")),
        stop_reason: value
            .get("status")
            .and_then(Value::as_str)
            .map(str::to_string),
        thinking,
        thinking_blocks: Vec::new(),
    })
}

fn parse_usage(usage: Option<&Value>) -> Option<TokenUsage> {
    let usage = usage.filter(|u| u.is_object())?;
    let field = |name: &str| usage.get(name).and_then(Value::as_i64).unwrap_or(0);
    let prompt = field("input_tokens");
    let completion = field("output_tokens");
    let total = usage
        .get("total_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(prompt + completion);
    Some(TokenUsage {
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: total,
    })
}

/// A function call being streamed, keyed by its `output_index`.
#[derive(Default)]
struct PartialCall {
    id: String,
    name: String,
    arguments: String,
}

/// Accumulates a streamed Responses payload.
#[derive(Default)]
struct StreamAccumulator {
    content: String,
    thinking: String,
    calls: Vec<(u64, PartialCall)>,
    usage: Option<TokenUsage>,
    stop_reason: Option<String>,
}

impl StreamAccumulator {
    fn call(&mut self, index: u64) -> &mut PartialCall {
        if !self.calls.iter().any(|(i, _)| *i == index) {
            self.calls.push((index, PartialCall::default()));
        }
        self.calls
            .iter_mut()
            .find(|(i, _)| *i == index)
            .map(|(_, c)| c)
            .unwrap()
    }

    fn push(&mut self, data: &str, sink: StreamSink<'_>) -> Result<()> {
        let event: Value = serde_json::from_str(data)
            .map_err(|e| anyhow!("invalid stream event ({e}): {data}"))?;
        let str_of = |v: &Value, key: &str| {
            v.get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        let index = event
            .get("output_index")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        match event.get("type").and_then(Value::as_str) {
            Some("response.output_text.delta") => {
                let piece = str_of(&event, "delta");
                self.content.push_str(&piece);
                sink(StreamEvent::Text(&piece));
            }
            Some("response.reasoning_summary_text.delta" | "response.reasoning_text.delta") => {
                let piece = str_of(&event, "delta");
                self.thinking.push_str(&piece);
                sink(StreamEvent::Thinking(&piece));
            }
            Some("response.output_item.added") => {
                let item = event.get("item").cloned().unwrap_or(Value::Null);
                if item.get("type").and_then(Value::as_str) == Some("function_call") {
                    let call = self.call(index);
                    call.id = item
                        .get("call_id")
                        .or_else(|| item.get("id"))
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    call.name = str_of(&item, "name");
                }
            }
            Some("response.function_call_arguments.delta") => {
                let piece = str_of(&event, "delta");
                self.call(index).arguments.push_str(&piece);
            }
            Some("response.completed" | "response.incomplete" | "response.failed") => {
                if let Some(response) = event.get("response") {
                    if let Some(usage) = parse_usage(response.get("usage")) {
                        self.usage = Some(usage);
                    }
                    if let Some(status) = response.get("status").and_then(Value::as_str) {
                        self.stop_reason = Some(status.to_string());
                    }
                }
            }
            Some("error" | "response.error") => {
                let error = event.get("error").cloned().unwrap_or(event.clone());
                return Err(anyhow!("stream error: {error}"));
            }
            _ => {}
        }
        Ok(())
    }

    fn finish(mut self) -> LLMResponse {
        self.calls.sort_by_key(|(index, _)| *index);
        let tool_calls = self
            .calls
            .into_iter()
            .filter(|(_, call)| !call.name.is_empty())
            .enumerate()
            .map(|(position, (_, call))| ToolCall {
                id: if call.id.is_empty() {
                    format!("call_{position}")
                } else {
                    call.id
                },
                name: call.name,
                arguments: ToolCall::decode_arguments(&call.arguments),
            })
            .collect();
        LLMResponse {
            content: self.content,
            tool_calls,
            usage: self.usage,
            stop_reason: self.stop_reason,
            thinking: self.thinking,
            thinking_blocks: Vec::new(),
        }
    }
}

/// Stream a Responses request to `url`, accumulating a full response.
/// `auth` adds provider-specific authentication headers.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::Message;
    use crate::providers::{ProviderConfig, resolve};
    use crate::tools::ToolDefinition;
    use std::collections::HashMap;

    fn transport() -> HttpTransport {
        let user: HashMap<String, ProviderConfig> = HashMap::new();
        HttpTransport::new(resolve("openai/gpt-test", &user, "mock").unwrap()).unwrap()
    }

    #[test]
    fn builds_input_instructions_tools_and_calls() {
        let messages = vec![
            Message::system("be brief"),
            Message::user("time?"),
            Message::assistant_with_tools(
                "checking",
                vec![ToolCall {
                    id: "call_1".into(),
                    name: "get_time".into(),
                    arguments: json!({"tz": "utc"}),
                }],
            ),
            Message::tool_result("call_1", "get_time", "noon"),
        ];
        let tools = [ToolDefinition::new(
            "get_time",
            "time",
            json!({"type": "object"}),
        )];
        let body = build_body(
            &transport(),
            &ChatRequest {
                messages: &messages,
                tools: &tools,
                temperature: Some(0.5),
                max_tokens: Some(64),
            },
        );
        assert_eq!(body["instructions"], "be brief");
        assert_eq!(body["max_output_tokens"], 64);
        assert_eq!(body["tools"][0]["type"], "function");
        assert_eq!(body["tools"][0]["name"], "get_time");
        let input = body["input"].as_array().unwrap();
        assert_eq!(input[0], json!({ "role": "user", "content": "time?" }));
        assert_eq!(
            input[1],
            json!({ "role": "assistant", "content": "checking" })
        );
        assert_eq!(input[2]["type"], "function_call");
        assert_eq!(input[2]["call_id"], "call_1");
        assert_eq!(input[2]["arguments"], r#"{"tz":"utc"}"#);
        assert_eq!(input[3]["type"], "function_call_output");
        assert_eq!(input[3]["call_id"], "call_1");
        assert_eq!(input[3]["output"], "noon");
    }

    #[test]
    fn parses_output_reasoning_text_and_calls() {
        let value = json!({
            "status": "completed",
            "output": [
                { "type": "reasoning", "summary": [{ "type": "summary_text", "text": "think" }] },
                { "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "hello" }] },
                { "type": "function_call", "call_id": "c1", "name": "bash", "arguments": "{\"cmd\":\"ls\"}" }
            ],
            "usage": { "input_tokens": 10, "output_tokens": 5, "total_tokens": 15 }
        });
        let response = parse_response(&value).unwrap();
        assert_eq!(response.content, "hello");
        assert_eq!(response.thinking, "think");
        assert_eq!(response.stop_reason.as_deref(), Some("completed"));
        assert_eq!(response.tool_calls[0].id, "c1");
        assert_eq!(response.tool_calls[0].name, "bash");
        assert_eq!(response.tool_calls[0].arguments["cmd"], "ls");
        assert_eq!(response.usage.unwrap().total_tokens, 15);
    }

    #[test]
    fn stream_accumulator_collects_text_thinking_and_calls() {
        let events = [
            json!({"type": "response.reasoning_summary_text.delta", "delta": "pl"}),
            json!({"type": "response.reasoning_summary_text.delta", "delta": "an"}),
            json!({"type": "response.output_text.delta", "delta": "he"}),
            json!({"type": "response.output_text.delta", "delta": "llo"}),
            json!({"type": "response.output_item.added", "output_index": 1, "item": {"type": "function_call", "call_id": "c9", "name": "bash"}}),
            json!({"type": "response.function_call_arguments.delta", "output_index": 1, "delta": "{\"cmd\":"}),
            json!({"type": "response.function_call_arguments.delta", "output_index": 1, "delta": "\"ls\"}"}),
            json!({"type": "response.completed", "response": {"status": "completed", "usage": {"input_tokens": 3, "output_tokens": 4}}}),
        ];
        let mut accumulator = StreamAccumulator::default();
        let sink: StreamSink<'_> = &|_| {};
        for event in events {
            accumulator.push(&event.to_string(), sink).unwrap();
        }
        let response = accumulator.finish();
        assert_eq!(response.content, "hello");
        assert_eq!(response.thinking, "plan");
        assert_eq!(response.stop_reason.as_deref(), Some("completed"));
        assert_eq!(response.tool_calls[0].id, "c9");
        assert_eq!(response.tool_calls[0].name, "bash");
        assert_eq!(response.tool_calls[0].arguments["cmd"], "ls");
        assert_eq!(response.usage.unwrap().total_tokens, 7);
    }
}
