//! OpenAI Chat Completions client. Works with any OpenAI-compatible endpoint.

use anyhow::{Result, anyhow};
use async_trait::async_trait;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};

use super::{HttpTransport, ProviderKind, ResolvedProvider, StreamAction};
use crate::llm::{
    ChatRequest, DetectedWindow, LLMClient, LLMResponse, Message, Role, StreamEvent, StreamSink, ThinkSplitter,
    TokenUsage, ToolCall, report_whole,
};
use crate::thinking::Request;

pub struct OpenAiClient {
    transport: HttpTransport,
}

impl OpenAiClient {
    pub fn new(provider: ResolvedProvider) -> Result<Self> {
        Ok(Self { transport: HttpTransport::new(provider)? })
    }

    pub fn build_body(&self, request: &ChatRequest<'_>) -> Value {
        build_body(&self.transport, request)
    }
}

/// Chat Completions request body for `request`, with provider overrides applied.
pub(crate) fn build_body(transport: &HttpTransport, request: &ChatRequest<'_>) -> Value {
    build_body_with_plan(transport, request, &request.attachment_plan())
}

/// As [`build_body`], but reusing a caller-supplied attachment plan so a client
/// that already resolved one (e.g. to set a vision header) does not rescan and
/// rehash every stored sidecar a second time.
pub(crate) fn build_body_with_plan(
    transport: &HttpTransport,
    request: &ChatRequest<'_>,
    plan: &crate::llm::AttachmentPlan,
) -> Value {
    let provider = transport.provider();
    let mut body = json!({
        "model": provider.model,
        "messages": encode_messages(request, provider.replay_reasoning, plan),
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
    match &request.thinking {
        Some(Request::Effort(level)) => body["reasoning_effort"] = json!(level),
        Some(Request::Off) => body["reasoning_effort"] = json!("none"),
        // llama.cpp ignores `reasoning_effort`; the chat template's own
        // variables switch thinking.
        Some(Request::TemplateSwitch(on)) => body["chat_template_kwargs"] = json!({ "enable_thinking": on }),
        Some(Request::TemplateEffort(level)) => body["chat_template_kwargs"] = json!({ "reasoning_effort": level }),
        // Budgets and the Anthropic adaptive enable-half are only resolved for
        // Anthropic Messages.
        Some(Request::Budget(_) | Request::AdaptiveOn) | None => {}
    }
    transport.finish_body(body)
}

/// Encode the conversation as Chat Completions messages. `tool` messages carry
/// only text, so a tool result's images are sent in a `user` message right
/// after the run of tool results they belong to (as `{type:"image_url"}`
/// parts); the tool message notes the attachment follows. Omitted or missing
/// attachments become a text placeholder appended to the tool message.
fn encode_messages(request: &ChatRequest<'_>, replay_reasoning: bool, plan: &crate::llm::AttachmentPlan) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    // Image parts collected from the current run of tool messages, flushed into
    // one user message when the run ends.
    let mut pending_images: Vec<crate::llm::ImageData> = Vec::new();
    let flush = |out: &mut Vec<Value>, pending: &mut Vec<crate::llm::ImageData>| {
        if pending.is_empty() {
            return;
        }
        let mut content: Vec<Value> = vec![json!({"type": "text", "text": "[attached image]"})];
        for image in pending.drain(..) {
            content.push(json!({
                "type": "image_url",
                "image_url": { "url": format!("data:{};base64,{}", image.media_type, image.data_base64) },
            }));
        }
        out.push(json!({ "role": "user", "content": content }));
    };
    // The image quota is resolved once per request by the caller and shared.
    for message in request.messages {
        if message.role != Role::Tool {
            flush(&mut out, &mut pending_images);
        }
        if message.role == Role::Tool && !message.attachments.is_empty() {
            let mut content = message.content.clone();
            let mut added_image = false;
            for item in request.resolve_attachments_with(message, plan) {
                match item {
                    crate::llm::ResolvedAttachment::Image(image) => {
                        pending_images.push(image);
                        added_image = true;
                    }
                    crate::llm::ResolvedAttachment::Omitted(text) => {
                        content.push('\n');
                        content.push_str(&text);
                    }
                }
            }
            let mut encoded = json!({
                "role": "tool",
                "tool_call_id": message.tool_call_id,
                "content": content,
            });
            if added_image {
                // Note on the tool message that *its own* image follows, so the
                // text alone still reads coherently. Gated on this message adding
                // an image — not on `pending_images` (which may hold an earlier
                // tool's image) — so a tool with only a missing/omitted
                // attachment does not falsely claim an image follows. The image
                // is flushed only after the whole consecutive run of tool
                // results, so say "after the tool results", not "in the next
                // message" (another `tool` message may come next).
                encoded["content"] = json!(format!("{content}\n[image attached after the tool results]"));
            }
            out.push(encoded);
            continue;
        }
        out.push(encode_message(message, replay_reasoning));
    }
    flush(&mut out, &mut pending_images);
    out
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
    if replay && !reasoning.is_empty() { vec![json!({ "type": REASONING_BLOCK, "text": reasoning })] } else { vec![] }
}

/// Parse a Chat Completions response.
/// `replay` keeps the reasoning in `thinking_blocks` so it can be sent back.
pub fn parse_response(value: &Value, replay: bool) -> Result<LLMResponse> {
    let choice =
        value.get("choices").and_then(|c| c.get(0)).ok_or_else(|| anyhow!("response has no choices: {value}"))?;
    let message = choice.get("message").cloned().unwrap_or(Value::Null);
    let content = match message.get("content") {
        Some(Value::String(text)) => text.clone(),
        // Some servers return content parts.
        Some(Value::Array(parts)) => {
            parts.iter().filter_map(|p| p.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("")
        }
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
                    let id = call
                        .get("id")
                        .and_then(Value::as_str)
                        .filter(|id| !id.is_empty())
                        .map(str::to_string)
                        .unwrap_or_else(|| format!("call_{index}"));
                    let name = function.get("name").and_then(Value::as_str).unwrap_or_default().to_string();
                    ToolCall::from_raw_arguments(id, name, &raw, None)
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(LLMResponse {
        content,
        tool_calls,
        usage: parse_usage(value),
        stop_reason: choice.get("finish_reason").and_then(Value::as_str).map(str::to_string),
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
            aic: crate::llm::copilot_aic(value),
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
    value.get(REASONING_BLOCK).and_then(Value::as_str).filter(|text| !text.is_empty())
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
            .map(|(index, (id, name, raw))| {
                ToolCall::from_raw_arguments(if id.is_empty() { format!("call_{index}") } else { id }, name, &raw, None)
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
                accumulator = StreamAccumulator::new(replay);
                Ok(false)
            }
        })
        .await?;
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
        stream_chat(
            &self.transport,
            &url,
            self.build_body(request),
            |builder| match &api_key {
                Some(key) => builder.bearer_auth(key),
                None => builder,
            },
            sink,
        )
        .await
    }

    async fn detect_context_window(&self) -> Option<DetectedWindow> {
        detect_window(&self.transport).await
    }

    async fn detect_thinking_levels(&self) -> Option<crate::thinking::Reported> {
        detect_thinking(&self.transport).await
    }

    async fn detect_vision(&self) -> Option<crate::vision::Vision> {
        detect_vision(&self.transport).await
    }

    async fn detect_capabilities(
        &self,
    ) -> (Option<DetectedWindow>, Option<crate::thinking::Reported>, Option<crate::vision::Vision>) {
        detect_capabilities(&self.transport).await
    }

    async fn detect_thinking_and_vision(
        &self,
    ) -> (Option<crate::thinking::Reported>, Option<crate::vision::Vision>) {
        detect_thinking_and_vision(&self.transport).await
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
        let mut models: Vec<String> =
            items.iter().filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_string)).collect();
        models.sort();
        Ok(models)
    }

    fn model_name(&self) -> &str {
        &self.transport.provider().model
    }

    fn provider_name(&self) -> &str {
        &self.transport.provider().name
    }

    fn kind(&self) -> Option<ProviderKind> {
        Some(ProviderKind::Openai)
    }
}

/// Per-request timeout for context-window probes.
pub(crate) const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// The most serial requests `detect_capabilities` chains: `/models` and then at
/// most one follow-up (`/props`, `/api/show`, `/api/v0/models`, or the
/// concurrent Ollama `/api/ps`+`/api/show` join, which counts as one). The
/// caller's overall cap must exceed `MAX_PROBE_CHAIN × PROBE_TIMEOUT` so a
/// window already found by the first request survives a slow optional follow-up.
pub(crate) const MAX_PROBE_CHAIN: u32 = 2;

/// Ask an OpenAI-compatible endpoint for the loaded model's context window.
///
/// `/models` covers vLLM (`max_model_len`), DwarfStar ds4, OpenRouter, Together
/// and Kimi (`context_length`), Groq (`context_window`) and Mistral
/// (`max_context_length`). Servers whose `/models` lacks it are recognised by
/// `owned_by` or name and asked their own API: llama.cpp `/props`, LM Studio
/// `/api/v0/models`, Ollama `/api/ps` and `/api/show`.
/// Which server software an OpenAI-compatible endpoint is, as far as the
/// probes need to know: from the `/models` entry's `owned_by`, the preset name
/// or Ollama's default port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Server {
    LlamaCpp,
    LmStudio,
    Ollama,
    Other,
}

fn identify(provider_name: &str, root: &str, entry: Option<&Value>) -> Server {
    let owner = entry.and_then(|e| e.get("owned_by")).and_then(Value::as_str).unwrap_or_default();
    if owner == "llamacpp" || provider_name == "llamacpp" {
        Server::LlamaCpp
    } else if owner == "organization_owner" || provider_name == "lmstudio" {
        Server::LmStudio
    } else if provider_name == "ollama" || root.ends_with(":11434") || matches!(owner, "library" | "ollama") {
        Server::Ollama
    } else {
        Server::Other
    }
}

/// The thinking levels a local server reports for the model: Ollama's
/// `thinking` capability (`/api/show`), or what llama.cpp's chat template
/// accepts (`/props`). Other servers report none.
pub(crate) async fn detect_thinking(transport: &HttpTransport) -> Option<crate::thinking::Reported> {
    let provider = transport.provider();
    let base = provider.base_url.as_str();
    let root = base.strip_suffix("/v1").unwrap_or(base);
    let model = provider.model.as_str();
    let models = probe(transport, reqwest::Method::GET, &format!("{base}/models"), None).await;
    let entry = models.as_ref().and_then(|m| model_entry(m, model));
    match identify(&provider.name, root, entry) {
        Server::LlamaCpp => {
            let url = format!("{root}/props?model={}", urlencode(model));
            crate::thinking::Reported::from_llamacpp_props(&probe(transport, reqwest::Method::GET, &url, None).await?)
        }
        Server::Ollama => {
            let url = format!("{root}/api/show");
            let show = probe(transport, reqwest::Method::POST, &url, Some(json!({ "model": model }))).await?;
            crate::thinking::Reported::from_ollama_show(&show)
        }
        Server::LmStudio | Server::Other => None,
    }
}

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
    let server = identify(&provider.name, root, entry);
    if server == Server::LlamaCpp {
        let url = format!("{root}/props?model={}", urlencode(model));
        let props = probe(transport, reqwest::Method::GET, &url, None).await?;
        return props
            .pointer("/default_generation_settings/n_ctx")
            .or_else(|| props.get("n_ctx"))
            .and_then(as_tokens)
            .map(|tokens| DetectedWindow::total(tokens, "llama.cpp /props n_ctx"));
    }
    if server == Server::LmStudio {
        let listed = probe(transport, reqwest::Method::GET, &format!("{root}/api/v0/models"), None).await?;
        return model_entry(&listed, model)
            .and_then(|m| m.get("loaded_context_length"))
            .and_then(as_tokens)
            .map(|tokens| DetectedWindow::total(tokens, "LM Studio loaded_context_length"));
    }
    if server == Server::Ollama {
        return ollama_window(transport, root, model).await.0;
    }
    None
}

/// Probe the endpoint for both the context window and the thinking levels in
/// one pass. Both detections need the same `/models` list to identify the
/// server, and both then query the same server-specific endpoint (llama.cpp
/// `/props`, Ollama `/api/show`), so fetching each once and deriving both
/// halves keeps a slow or unavailable endpoint from being probed twice
/// serially at startup or on a model switch.
pub(crate) async fn detect_capabilities(
    transport: &HttpTransport,
) -> (Option<DetectedWindow>, Option<crate::thinking::Reported>, Option<crate::vision::Vision>) {
    let provider = transport.provider();
    let base = provider.base_url.as_str();
    let root = base.strip_suffix("/v1").unwrap_or(base);
    let model = provider.model.as_str();
    let models = probe(transport, reqwest::Method::GET, &format!("{base}/models"), None).await;
    let entry = models.as_ref().and_then(|m| model_entry(m, model));
    let server = identify(&provider.name, root, entry);
    match server {
        Server::LlamaCpp => {
            let url = format!("{root}/props?model={}", urlencode(model));
            let props = probe(transport, reqwest::Method::GET, &url, None).await;
            let window = props
                .as_ref()
                .and_then(|p| p.pointer("/default_generation_settings/n_ctx").or_else(|| p.get("n_ctx")))
                .and_then(as_tokens)
                .map(|tokens| DetectedWindow::total(tokens, "llama.cpp /props n_ctx"));
            // A window listed directly on the `/models` entry wins over /props.
            let window = entry.and_then(window_in_entry).or(window);
            let thinking = props.as_ref().and_then(crate::thinking::Reported::from_llamacpp_props);
            // Vision comes from the same `/props` response — no second probe.
            let vision = props.as_ref().and_then(crate::vision::Vision::from_llamacpp_props);
            (window, thinking, vision)
        }
        Server::Ollama => {
            let (window, show) = match entry.and_then(window_in_entry) {
                Some(found) => {
                    // The window came from `/models`; only thinking needs /api/show.
                    let url = format!("{root}/api/show");
                    let show = probe(transport, reqwest::Method::POST, &url, Some(json!({ "model": model }))).await;
                    (Some(found), show)
                }
                None => ollama_window(transport, root, model).await,
            };
            let thinking = show.as_ref().and_then(crate::thinking::Reported::from_ollama_show);
            // Vision comes from the same `/api/show` response — no second probe.
            let vision = show.as_ref().and_then(crate::vision::Vision::from_ollama_show);
            (window, thinking, vision)
        }
        Server::LmStudio => {
            let window = match entry.and_then(window_in_entry) {
                Some(found) => Some(found),
                None => probe(transport, reqwest::Method::GET, &format!("{root}/api/v0/models"), None)
                    .await
                    .as_ref()
                    .and_then(|listed| model_entry(listed, model))
                    .and_then(|m| m.get("loaded_context_length"))
                    .and_then(as_tokens)
                    .map(|tokens| DetectedWindow::total(tokens, "LM Studio loaded_context_length")),
            };
            (window, None, None)
        }
        Server::Other => (entry.and_then(window_in_entry), None, None),
    }
}

/// Probe the endpoint for the thinking levels and vision capability in one
/// pass, **without** the context-window follow-ups. Used on the
/// configured-window path, where the window is already known: both detections
/// share the same `/models` list to identify the server and the same
/// server-specific response (llama.cpp `/props`, Ollama `/api/show`), so
/// fetching it once keeps a slow or unavailable endpoint from being probed
/// twice serially (and from waiting through two probe budgets). The
/// window-only follow-ups (Ollama `/api/ps`, LM Studio `/api/v0/models`) are
/// skipped since the window is discarded here.
pub(crate) async fn detect_thinking_and_vision(
    transport: &HttpTransport,
) -> (Option<crate::thinking::Reported>, Option<crate::vision::Vision>) {
    let provider = transport.provider();
    let base = provider.base_url.as_str();
    let root = base.strip_suffix("/v1").unwrap_or(base);
    let model = provider.model.as_str();
    let models = probe(transport, reqwest::Method::GET, &format!("{base}/models"), None).await;
    let entry = models.as_ref().and_then(|m| model_entry(m, model));
    match identify(&provider.name, root, entry) {
        Server::LlamaCpp => {
            let url = format!("{root}/props?model={}", urlencode(model));
            let props = probe(transport, reqwest::Method::GET, &url, None).await;
            let thinking = props.as_ref().and_then(crate::thinking::Reported::from_llamacpp_props);
            let vision = props.as_ref().and_then(crate::vision::Vision::from_llamacpp_props);
            (thinking, vision)
        }
        Server::Ollama => {
            let url = format!("{root}/api/show");
            let show = probe(transport, reqwest::Method::POST, &url, Some(json!({ "model": model }))).await;
            let thinking = show.as_ref().and_then(crate::thinking::Reported::from_ollama_show);
            let vision = show.as_ref().and_then(crate::vision::Vision::from_ollama_show);
            (thinking, vision)
        }
        // These servers report neither thinking nor vision from their own
        // endpoints; the built-in assumption or a config override decides.
        Server::LmStudio | Server::Other => (None, None),
    }
}

/// Probe the endpoint for the loaded model's vision capability: llama.cpp
/// `/props` (`modalities.vision`) or Ollama `/api/show` (the `vision`
/// capability). Other OpenAI-compatible servers report nothing here; the
/// built-in assumption or a config override decides for them.
pub(crate) async fn detect_vision(transport: &HttpTransport) -> Option<crate::vision::Vision> {
    let provider = transport.provider();
    let base = provider.base_url.as_str();
    let root = base.strip_suffix("/v1").unwrap_or(base);
    let model = provider.model.as_str();
    let models = probe(transport, reqwest::Method::GET, &format!("{base}/models"), None).await;
    let entry = models.as_ref().and_then(|m| model_entry(m, model));
    match identify(&provider.name, root, entry) {
        Server::LlamaCpp => {
            let url = format!("{root}/props?model={}", urlencode(model));
            let props = probe(transport, reqwest::Method::GET, &url, None).await?;
            crate::vision::Vision::from_llamacpp_props(&props)
        }
        Server::Ollama => {
            let url = format!("{root}/api/show");
            let show = probe(transport, reqwest::Method::POST, &url, Some(json!({ "model": model }))).await?;
            crate::vision::Vision::from_ollama_show(&show)
        }
        Server::LmStudio | Server::Other => None,
    }
}

/// Ollama: the loaded model's context from `/api/ps`, else `num_ctx` from the
/// model's parameters. The model's maximum (`model_info`) is not used: Ollama
/// runs with a smaller default unless `num_ctx` says otherwise. Returns the
/// window alongside the `/api/show` response so the caller can derive the
/// thinking levels from it without a second fetch. `/api/ps` and `/api/show`
/// are probed concurrently: the caller caps the combined detection, and a
/// serial `/api/show` after a successful `/api/ps` could run past that cap and
/// discard the window `/api/ps` already found.
async fn ollama_window(transport: &HttpTransport, root: &str, model: &str) -> (Option<DetectedWindow>, Option<Value>) {
    let same = |name: &str| name == model || name.strip_suffix(":latest") == Some(model);
    let ps_url = format!("{root}/api/ps");
    let show_url = format!("{root}/api/show");
    let (ps, show) = tokio::join!(
        probe(transport, reqwest::Method::GET, &ps_url, None),
        probe(transport, reqwest::Method::POST, &show_url, Some(json!({ "model": model }))),
    );
    if let Some(ps) = ps {
        let loaded = ps
            .get("models")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find(|m| ["name", "model"].iter().any(|k| m.get(*k).and_then(Value::as_str).is_some_and(same)));
        if let Some(tokens) = loaded.and_then(|m| m.get("context_length")).and_then(as_tokens) {
            let window = DetectedWindow::total(tokens, "Ollama /api/ps context_length");
            return (Some(window), show);
        }
    }
    let window = show
        .as_ref()
        .and_then(|s| s.get("parameters"))
        .and_then(Value::as_str)
        .and_then(|parameters| {
            parameters
                .lines()
                .find_map(|line| line.trim().strip_prefix("num_ctx")?.trim().parse::<usize>().ok().filter(|&n| n > 0))
        })
        .map(|tokens| DetectedWindow::total(tokens, "Ollama num_ctx"));
    (window, show)
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
    items.iter().find(|m| m.get("id").and_then(Value::as_str) == Some(model)).or(if items.len() == 1 {
        items.first()
    } else {
        None
    })
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
        Some(DetectedWindow {
            tokens,
            source: format!("/models {}", pointer.trim_start_matches('/').replace('/', ".")),
            cap: crate::llm::ContextCap::Total,
            total_tokens: None,
        })
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

    /// A real, decodable 10×10 PNG. `read_for_limits` reads the dimensions from
    /// the stored bytes, so an attachment's file must be a valid image — magic
    /// bytes alone no longer resolve to a sendable image.
    fn real_png() -> Vec<u8> {
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(10, 10, image::Rgb([7, 8, 9])));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner()
    }

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

    #[test]
    fn encodes_thinking_levels_and_lets_extra_body_win() {
        let messages = [Message::user("q")];
        let request = |thinking| ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking,
            vision: None,
            attachments_dir: None,
        };
        let client = OpenAiClient::new(provider("http://x", "")).unwrap();
        assert_eq!(client.build_body(&request(Some(Request::Effort("high".into()))))["reasoning_effort"], "high");
        assert_eq!(client.build_body(&request(Some(Request::Off)))["reasoning_effort"], "none");
        assert!(client.build_body(&request(None)).get("reasoning_effort").is_none());
        let client = OpenAiClient::new(provider("http://x", "reasoning_effort = \"low\"")).unwrap();
        assert_eq!(client.build_body(&request(Some(Request::Effort("high".into()))))["reasoning_effort"], "low");

        // llama.cpp: chat template variables, no `reasoning_effort`.
        let client = OpenAiClient::new(provider("http://x", "")).unwrap();
        let body = client.build_body(&request(Some(Request::TemplateSwitch(false))));
        assert_eq!(body["chat_template_kwargs"], json!({ "enable_thinking": false }));
        assert!(body.get("reasoning_effort").is_none());
        let body = client.build_body(&request(Some(Request::TemplateEffort("high".into()))));
        assert_eq!(body["chat_template_kwargs"], json!({ "reasoning_effort": "high" }));
    }

    #[test]
    fn tool_result_image_goes_in_a_followup_user_message() {
        let dir = tempfile::tempdir().unwrap();
        // A real, decodable PNG: `read_for_limits` reads the dimensions from the
        // bytes, so the stored file must be a valid image, not magic-byte filler.
        let bytes = real_png();
        let attachment = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("/tmp/plot.png"),
            sha256: crate::attachment::sha256_hex(&bytes),
            width: 800,
            height: 600,
            bytes: bytes.len(),
            extension: "png".into(),
        };
        crate::attachment::store(dir.path(), &attachment, &bytes).unwrap();
        let messages = vec![
            Message::user("look at the plot"),
            Message::assistant_with_tools(
                "",
                vec![ToolCall {
                    id: "c1".into(),
                    name: "read_file".into(),
                    arguments: json!({"path": "/tmp/plot.png"}),
                    item_id: None,
                    malformed_arguments: None,
                }],
            ),
            Message::tool_result("c1", "read_file", "image/png, 800×600, 50 KB").with_attachments(vec![attachment]),
        ];
        let vision = crate::vision::Vision {
            max_images: 1,
            max_image_bytes: crate::attachment::DEFAULT_MAX_BYTES,
            media_types: Vec::new(),
        };
        let client = OpenAiClient::new(provider("http://x", "")).unwrap();
        let body = client.build_body(&ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: Some(vision),
            attachments_dir: Some(dir.path()),
        });
        let encoded = body["messages"].as_array().unwrap();
        // user, assistant, tool (text + a note), then a user message with the image.
        assert_eq!(encoded.len(), 4);
        assert_eq!(encoded[2]["role"], "tool");
        assert!(encoded[2]["content"].as_str().unwrap().contains("[image attached after the tool results]"));
        assert_eq!(encoded[3]["role"], "user");
        let parts = encoded[3]["content"].as_array().unwrap();
        // The carrying user message uses a distinct, non-self-referential label —
        // not the tool message's forward-pointing note repeated here.
        assert_eq!(parts[0]["text"], "[attached image]");
        assert_eq!(parts[1]["type"], "image_url");
        let expected = format!(
            "data:image/png;base64,{}",
            base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &bytes)
        );
        assert_eq!(parts[1]["image_url"]["url"], json!(expected));
    }

    #[test]
    fn tool_without_its_own_image_does_not_claim_one_follows() {
        // Two consecutive tool results flushed into one user message: the first
        // carries an image, the second only a missing attachment. The second
        // tool must NOT say "[image attached after the tool results]" — that image
        // belongs to the first tool, not it.
        let dir = tempfile::tempdir().unwrap();
        let bytes = real_png();
        let present = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("/tmp/present.png"),
            sha256: crate::attachment::sha256_hex(&bytes),
            width: 10,
            height: 10,
            bytes: bytes.len(),
            extension: "png".into(),
        };
        crate::attachment::store(dir.path(), &present, &bytes).unwrap();
        // A second attachment whose file was never written (missing on resume).
        let missing = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("/tmp/missing.png"),
            sha256: crate::attachment::sha256_hex(b"missing-bytes"),
            width: 10,
            height: 10,
            bytes: 13,
            extension: "png".into(),
        };
        let messages = vec![
            Message::assistant_with_tools(
                "",
                vec![
                    ToolCall {
                        id: "c1".into(),
                        name: "read_file".into(),
                        arguments: json!({"path": "/tmp/present.png"}),
                        item_id: None,
                        malformed_arguments: None,
                    },
                    ToolCall {
                        id: "c2".into(),
                        name: "read_file".into(),
                        arguments: json!({"path": "/tmp/missing.png"}),
                        item_id: None,
                        malformed_arguments: None,
                    },
                ],
            ),
            Message::tool_result("c1", "read_file", "present").with_attachments(vec![present]),
            Message::tool_result("c2", "read_file", "missing").with_attachments(vec![missing]),
        ];
        let vision = crate::vision::Vision {
            max_images: 4,
            max_image_bytes: crate::attachment::DEFAULT_MAX_BYTES,
            media_types: Vec::new(),
        };
        let client = OpenAiClient::new(provider("http://x", "")).unwrap();
        let body = client.build_body(&ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: Some(vision),
            attachments_dir: Some(dir.path()),
        });
        let encoded = body["messages"].as_array().unwrap();
        // assistant, tool c1 (adds image + note), tool c2 (no image), user (image).
        let c1 = &encoded[1];
        let c2 = &encoded[2];
        assert_eq!(c1["tool_call_id"], "c1");
        assert!(
            c1["content"].as_str().unwrap().contains("[image attached after the tool results]"),
            "the tool that actually added an image should note it: {c1}"
        );
        assert_eq!(c2["tool_call_id"], "c2");
        assert!(
            !c2["content"].as_str().unwrap().contains("[image attached after the tool results]"),
            "a tool with no image of its own must not claim one follows: {c2}"
        );
        assert!(
            c2["content"].as_str().unwrap().contains("no longer available"),
            "the missing attachment should resolve to a placeholder: {c2}"
        );
    }

    #[test]
    fn trajectory_data_is_never_sent() {
        let logged = Message {
            thinking: "private reasoning".into(),
            usage: Some(crate::llm::TokenUsage {
                prompt_tokens: 10,
                completion_tokens: 5,
                total_tokens: 15,
                aic: Some(0.5),
            }),
            duration_ms: Some(1234),
            ..Message::assistant("answer")
        };
        for replay in [false, true] {
            assert_eq!(encode_message(&logged, replay), encode_message(&Message::assistant("answer"), replay));
        }
    }

    fn conversation() -> Vec<Message> {
        vec![
            Message::system("sys"),
            Message::user("what time is it?"),
            Message::assistant_with_tools(
                "",
                vec![ToolCall {
                    id: "c1".into(),
                    name: "get_time".into(),
                    arguments: json!({}),
                    item_id: None,
                    malformed_arguments: None,
                }],
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
            thinking: None,
            vision: None,
            attachments_dir: None,
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
        let response =
            parse_response(&json!({ "choices": [{"message": {"content": "hi", "reasoning": "generic"}}] }), true)
                .unwrap();
        assert_eq!(response.thinking, "generic");
        assert!(response.thinking_blocks.is_empty());
    }

    #[test]
    fn parses_tool_calls_and_bad_arguments() {
        let response = parse_response(
            &json!({
                "choices": [{"finish_reason": "tool_calls", "message": {"content": null, "tool_calls": [
                    {"id": "a", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}},
                    {"id": "b", "type": "function", "function": {"name": "bash", "arguments": "{oops"}}
                ]}}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}
            }),
            false,
        )
        .unwrap();
        assert_eq!(response.tool_calls[0].arguments["command"], "ls");
        // Bad JSON is preserved as dedicated metadata, not folded into the
        // argument object.
        assert_eq!(response.tool_calls[1].arguments, json!({}));
        assert_eq!(response.tool_calls[1].invalid_arguments(), Some("{oops"));
        assert_eq!(response.usage.unwrap().total_tokens, 7);
        assert_eq!(response.stop_reason.as_deref(), Some("tool_calls"));
    }

    #[test]
    fn parses_copilot_aic_from_response() {
        let response = parse_response(
            &json!({
                "choices": [{"finish_reason": "stop", "message": {"content": "hi"}}],
                "usage": {"prompt_tokens": 8, "completion_tokens": 10, "total_tokens": 18},
                "copilot_usage": {"total_nano_aiu": 11_600_000}
            }),
            false,
        )
        .unwrap();
        assert_eq!(response.usage.unwrap().aic, Some(0.0116));
        // Non-Copilot responses carry no credits.
        let plain = parse_response(
            &json!({
                "choices": [{"finish_reason": "stop", "message": {"content": "hi"}}],
                "usage": {"prompt_tokens": 8, "completion_tokens": 10, "total_tokens": 18}
            }),
            false,
        )
        .unwrap();
        assert_eq!(plain.usage.unwrap().aic, None);
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
            .chat(&ChatRequest {
                messages: &messages,
                tools: &[],
                temperature: None,
                max_tokens: None,
                thinking: None,
                vision: None,
                attachments_dir: None,
            })
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
        let (url, captured) =
            test_server::serve(vec![(200, "x-truncate: 1\r\n", r#"{"choices":[{"mess"#.into()), (200, "", ok)]).await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hello")];
        let response = client
            .chat(&ChatRequest {
                messages: &messages,
                tools: &[],
                temperature: None,
                max_tokens: None,
                thinking: None,
                vision: None,
                attachments_dir: None,
            })
            .await
            .unwrap();
        assert_eq!(response.content, "whole");
        assert_eq!(captured.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn slow_but_steady_stream_survives_beyond_idle_timeout() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;
        // Idle timeout of 1s, but the stream lasts ~2.5s total, dripping an event
        // every 500ms. A *total* request timeout would kill this healthy stream;
        // an idle (read) timeout must not, because no single gap exceeds 1s.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 4096];
            let _ = socket.read(&mut buf).await.unwrap();
            socket
                .write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n")
                .await
                .unwrap();
            for piece in ["hel", "lo", " wor", "ld"] {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                let event = json!({ "choices": [{ "delta": { "content": piece } }] });
                socket.write_all(format!("data: {event}\n\n").as_bytes()).await.unwrap();
            }
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            socket.write_all(b"data: [DONE]\n\n").await.unwrap();
            socket.shutdown().await.ok();
        });
        let mut user = HashMap::new();
        user.insert(
            "slow".to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some(format!("http://{addr}")),
                api_key: Some("sk-test".into()),
                timeout_secs: Some(1),
                ..Default::default()
            },
        );
        let client = OpenAiClient::new(resolve("slow/some-model", &user, "mock").unwrap()).unwrap();
        let messages = [Message::user("hi")];
        let sink = |_e: StreamEvent<'_>| {};
        let response = client
            .chat_stream(
                &ChatRequest {
                    messages: &messages,
                    tools: &[],
                    temperature: None,
                    max_tokens: None,
                    thinking: None,
                    vision: None,
                    attachments_dir: None,
                },
                &sink,
            )
            .await
            .unwrap();
        assert_eq!(response.content, "hello world");
    }

    #[tokio::test]
    async fn retries_mid_stream_disconnect_before_any_output() {
        // First attempt: valid SSE headers, but the body is cut off before any
        // complete event arrives — `x-truncate` advertises more bytes than are
        // sent and then the connection closes, simulating a transient timeout or
        // reset mid-stream (the user-reported "reading response stream ...
        // operation timed out"). Nothing was emitted, so the whole request is
        // retried; the second attempt streams cleanly.
        let truncated = r#"data: {"choices":[{"delta":{"content":"par"#.to_string();
        let events = [
            json!({"choices":[{"delta":{"role":"assistant","content":"hello"}}]}),
            json!({"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}),
        ];
        let mut good: String = events.iter().map(|e| format!("data: {e}\n\n")).collect();
        good.push_str("data: [DONE]\n\n");
        let (url, captured) = test_server::serve(vec![
            (200, "content-type: text/event-stream\r\nx-truncate: 1\r\n", truncated),
            (200, "content-type: text/event-stream\r\n", good),
        ])
        .await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hi")];
        let seen = std::sync::Mutex::new(Vec::new());
        let sink = |event: StreamEvent<'_>| {
            if let StreamEvent::Text(t) = event {
                seen.lock().unwrap().push(t.to_string());
            }
        };
        let response = client
            .chat_stream(
                &ChatRequest {
                    messages: &messages,
                    tools: &[],
                    temperature: None,
                    max_tokens: None,
                    thinking: None,
                    vision: None,
                    attachments_dir: None,
                },
                &sink,
            )
            .await
            .unwrap();
        assert_eq!(response.content, "hello world");
        // Output is delivered exactly once — no duplication from the retry.
        assert_eq!(*seen.lock().unwrap(), vec!["hello", " world"]);
        assert_eq!(captured.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn does_not_retry_mid_stream_disconnect_after_partial_output() {
        // The first attempt delivers one *complete* SSE event — so a payload has
        // already been handed to the caller — and then the connection is cut off
        // mid-stream (`x-truncate` advertises more bytes than are sent) before a
        // terminating `[DONE]`. Retrying here would re-request and duplicate the
        // already-emitted output, so the error must surface instead and no second
        // request may be made. This guards the `emitted == true` branch.
        let mut truncated =
            format!("data: {}\n\n", json!({"choices":[{"delta":{"role":"assistant","content":"hello"}}]}));
        // A second event begins but is severed before it is complete.
        truncated.push_str(r#"data: {"choices":[{"delta":{"content":" wor"#);
        let (url, captured) =
            test_server::serve(vec![(200, "content-type: text/event-stream\r\nx-truncate: 1\r\n", truncated)]).await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hi")];
        let seen = std::sync::Mutex::new(Vec::new());
        let sink = |event: StreamEvent<'_>| {
            if let StreamEvent::Text(t) = event {
                seen.lock().unwrap().push(t.to_string());
            }
        };
        let result = client
            .chat_stream(
                &ChatRequest {
                    messages: &messages,
                    tools: &[],
                    temperature: None,
                    max_tokens: None,
                    thinking: None,
                    vision: None,
                    attachments_dir: None,
                },
                &sink,
            )
            .await;
        // The mid-stream failure surfaces rather than being silently retried.
        assert!(result.is_err(), "expected the truncated stream to error, got {result:?}");
        // The already-delivered payload is seen exactly once — never duplicated.
        assert_eq!(*seen.lock().unwrap(), vec!["hello"]);
        // Crucially, no retry was attempted after output began.
        assert_eq!(captured.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn retries_after_metadata_only_event_and_resets_accumulator() {
        // The first attempt delivers one *complete* SSE event that carries only
        // metadata (a tool-call delta) — nothing visible ever reaches the
        // caller's sink — and is then severed mid-stream. Because no visible
        // output was emitted, the request must still be retried (the fix for
        // treating every `on_data` call as "emitted"). The retry must also reset
        // the attempt-local accumulator, otherwise the tool-call name/arguments
        // buffered on the first attempt would be duplicated onto the second.
        let call = json!({"choices":[{"delta":{"role":"assistant","tool_calls":[
            {"index":0,"id":"c1","type":"function","function":{"name":"get_time","arguments":"{}"}}
        ]}}]});
        let mut truncated = format!("data: {call}\n\n");
        // A second event begins but is cut off before it completes.
        truncated.push_str(r#"data: {"choices":[{"delta":{"content":" wor"#);
        let events = [call.clone(), json!({"choices":[{"delta":{},"finish_reason":"tool_calls"}]})];
        let mut good: String = events.iter().map(|e| format!("data: {e}\n\n")).collect();
        good.push_str("data: [DONE]\n\n");
        let (url, captured) = test_server::serve(vec![
            (200, "content-type: text/event-stream\r\nx-truncate: 1\r\n", truncated),
            (200, "content-type: text/event-stream\r\n", good),
        ])
        .await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hi")];
        let seen = std::sync::Mutex::new(Vec::new());
        let sink = |event: StreamEvent<'_>| {
            if let StreamEvent::Text(t) = event {
                seen.lock().unwrap().push(t.to_string());
            }
        };
        let response = client
            .chat_stream(
                &ChatRequest {
                    messages: &messages,
                    tools: &[],
                    temperature: None,
                    max_tokens: None,
                    thinking: None,
                    vision: None,
                    attachments_dir: None,
                },
                &sink,
            )
            .await
            .unwrap();
        // A metadata-only event must not suppress the retry.
        assert_eq!(captured.lock().unwrap().len(), 2);
        // No visible text was ever emitted to the caller.
        assert!(seen.lock().unwrap().is_empty(), "no visible output expected, got {:?}", seen.lock().unwrap());
        // The accumulator was reset before the retry: the tool call is not
        // duplicated ("get_timeget_time"/"{}{}") across the two attempts.
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(response.tool_calls[0].name, "get_time");
        assert_eq!(response.tool_calls[0].arguments, json!({}));
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
            .chat(&ChatRequest {
                messages: &messages,
                tools: &[],
                temperature: None,
                max_tokens: None,
                thinking: None,
                vision: None,
                attachments_dir: None,
            })
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
            .chat_stream(
                &ChatRequest {
                    messages: &messages,
                    tools: &[],
                    temperature: None,
                    max_tokens: None,
                    thinking: None,
                    vision: None,
                    attachments_dir: None,
                },
                &sink,
            )
            .await
            .unwrap();
        assert_eq!(response.thinking, "Let me check.more");
        assert_eq!(response.content, "Checking");
        assert_eq!(
            response.tool_calls,
            vec![ToolCall {
                id: "call_a".into(),
                name: "bash".into(),
                arguments: json!({"command": "ls"}),
                item_id: None,
                malformed_arguments: None
            }]
        );
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
        let request = ChatRequest {
            messages: &messages,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: None,
            attachments_dir: None,
        };
        let response = client.chat_stream(&request, &|_| {}).await.unwrap();
        // Only the provider's reasoning field is replayed, not inline <think> text.
        assert_eq!(response.thinking_blocks, vec![json!({"type": "reasoning_content", "text": "Need ls."})]);

        let assistant = Message {
            tool_calls: response.tool_calls.clone(),
            thinking_blocks: response.thinking_blocks.clone(),
            ..Message::assistant(&response.content)
        };
        let history = [
            Message::user("hello"),
            assistant,
            Message {
                thinking_blocks: vec![json!({"type": "thinking", "thinking": "t", "signature": "s"})],
                ..Message::assistant("done")
            },
        ];
        let request = ChatRequest {
            messages: &history,
            tools: &[],
            temperature: None,
            max_tokens: None,
            thinking: None,
            vision: None,
            attachments_dir: None,
        };
        let body = client.build_body(&request);
        assert_eq!(body["messages"][1]["reasoning_content"], "Need ls.");
        assert!(body["messages"][2].get("reasoning_content").is_none(), "Anthropic blocks are not replayed");
        resolved.replay_reasoning = false;
        let body = OpenAiClient::new(resolved).unwrap().build_body(&request);
        assert!(body["messages"][1].get("reasoning_content").is_none());
    }

    #[tokio::test]
    async fn stream_falls_back_to_json_and_splits_think_tags() {
        let ok =
            json!({"choices":[{"message":{"content":"<think>hmm</think>\nhi"},"finish_reason":"stop"}]}).to_string();
        let (url, _) = test_server::serve(vec![(200, "", ok)]).await;
        let client = OpenAiClient::new(provider(&url, "")).unwrap();
        let messages = [Message::user("hello")];
        let response = client
            .chat_stream(
                &ChatRequest {
                    messages: &messages,
                    tools: &[],
                    temperature: None,
                    max_tokens: None,
                    thinking: None,
                    vision: None,
                    attachments_dir: None,
                },
                &|_| {},
            )
            .await
            .unwrap();
        assert_eq!((response.content.as_str(), response.thinking.as_str()), ("hi", "hmm"));
    }

    async fn detect(
        provider_name: &str,
        responses: Vec<(u16, &'static str, String)>,
    ) -> (Option<DetectedWindow>, Vec<String>) {
        let (url, captured) = test_server::serve(responses).await;
        let mut user = HashMap::new();
        user.insert(
            provider_name.to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some(format!("{url}/v1")),
                ..Default::default()
            },
        );
        let resolved = resolve(&format!("{provider_name}/qwen3:8b"), &user, "mock").unwrap();
        let found = OpenAiClient::new(resolved).unwrap().detect_context_window().await;
        let paths = captured.lock().unwrap().iter().map(|c| c.path.clone()).collect();
        (found, paths)
    }

    fn window(tokens: usize, source: &str) -> Option<DetectedWindow> {
        Some(DetectedWindow::total(tokens, source))
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
        let (found, paths) =
            detect("llamacpp", vec![(200, "", models.to_string()), (200, "", props.to_string())]).await;
        assert_eq!(found, window(65536, "llama.cpp /props n_ctx"));
        assert_eq!(paths, ["/v1/models", "/props?model=qwen3%3A8b"]);
    }

    #[tokio::test]
    async fn recognizes_lm_studio_by_provider_name() {
        // LM Studio configured under the natural `lmstudio` name is asked its
        // own API even when the `/models` owner is not `organization_owner`.
        let models = json!({"data": [{"id": "qwen3:8b"}]});
        let listed = json!({"data": [{"id": "qwen3:8b", "loaded_context_length": 12288}]});
        let (found, paths) =
            detect("lmstudio", vec![(200, "", models.to_string()), (200, "", listed.to_string())]).await;
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

    async fn detect_levels(
        provider_name: &str,
        responses: Vec<(u16, &'static str, String)>,
    ) -> (Option<crate::thinking::Reported>, Vec<String>) {
        let (url, captured) = test_server::serve(responses).await;
        let user = HashMap::from([(
            provider_name.to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some(format!("{url}/v1")),
                ..Default::default()
            },
        )]);
        let resolved = resolve(&format!("{provider_name}/qwen3:8b"), &user, "mock").unwrap();
        let found = OpenAiClient::new(resolved).unwrap().detect_thinking_levels().await;
        let paths = captured.lock().unwrap().iter().map(|c| c.path.clone()).collect();
        (found, paths)
    }

    #[tokio::test]
    async fn detects_thinking_levels_on_ollama_and_llama_cpp() {
        use crate::thinking::Format;
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "library"}]});
        let show = json!({"capabilities": ["completion", "thinking"]});
        let (found, paths) =
            detect_levels("box", vec![(200, "", models.to_string()), (200, "", show.to_string())]).await;
        assert_eq!(found.map(|r| r.format), Some(Format::Effort));
        assert_eq!(paths, ["/v1/models", "/api/show"]);

        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "llamacpp"}]});
        let props = json!({"chat_template": "{% if enable_thinking %}"});
        let (found, paths) =
            detect_levels("box", vec![(200, "", models.to_string()), (200, "", props.to_string())]).await;
        assert_eq!(found.map(|r| r.levels), Some(vec!["off".to_string(), "on".to_string()]));
        assert_eq!(paths, ["/v1/models", "/props?model=qwen3%3A8b"]);

        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "system"}]});
        let (found, paths) = detect_levels("hosted", vec![(200, "", models.to_string())]).await;
        assert_eq!(found, None);
        assert_eq!(paths, ["/v1/models"], "unknown servers get no extra probes");
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

    async fn detect_both(
        provider_name: &str,
        responses: Vec<(u16, &'static str, String)>,
    ) -> (Option<DetectedWindow>, Option<crate::thinking::Reported>, Vec<String>) {
        let (url, captured) = test_server::serve(responses).await;
        let user = HashMap::from([(
            provider_name.to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some(format!("{url}/v1")),
                ..Default::default()
            },
        )]);
        let resolved = resolve(&format!("{provider_name}/qwen3:8b"), &user, "mock").unwrap();
        let (window, thinking, _vision) = OpenAiClient::new(resolved).unwrap().detect_capabilities().await;
        let paths = captured.lock().unwrap().iter().map(|c| c.path.clone()).collect();
        (window, thinking, paths)
    }

    #[tokio::test]
    async fn combined_detection_probes_each_endpoint_once() {
        use crate::thinking::Format;
        // llama.cpp: one /models and one /props serve both the window and the
        // thinking levels — no second serial round-trip.
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "llamacpp"}]});
        let props =
            json!({"default_generation_settings": {"n_ctx": 65536}, "chat_template": "{% if enable_thinking %}"});
        let (win, thinking, paths) =
            detect_both("box", vec![(200, "", models.to_string()), (200, "", props.to_string())]).await;
        assert_eq!(win, window(65536, "llama.cpp /props n_ctx"));
        assert_eq!(thinking.map(|r| r.levels), Some(vec!["off".to_string(), "on".to_string()]));
        assert_eq!(paths, ["/v1/models", "/props?model=qwen3%3A8b"], "each endpoint probed once");

        // Ollama: /models, /api/ps, and a single shared /api/show.
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "library"}]});
        let ps = json!({"models": []});
        let show = json!({"capabilities": ["completion", "thinking"], "parameters": "num_ctx 16384"});
        let (win, thinking, paths) = detect_both(
            "ollama",
            vec![(200, "", models.to_string()), (200, "", ps.to_string()), (200, "", show.to_string())],
        )
        .await;
        assert_eq!(win, window(16384, "Ollama num_ctx"));
        assert_eq!(thinking.map(|r| r.format), Some(Format::Effort));
        assert_eq!(paths, ["/v1/models", "/api/ps", "/api/show"], "/api/show is shared, not repeated");
    }

    async fn detect_tv(
        provider_name: &str,
        responses: Vec<(u16, &'static str, String)>,
    ) -> (Option<crate::thinking::Reported>, Option<crate::vision::Vision>, Vec<String>) {
        let (url, captured) = test_server::serve(responses).await;
        let user = HashMap::from([(
            provider_name.to_string(),
            ProviderConfig {
                kind: Some(ProviderKind::Openai),
                base_url: Some(format!("{url}/v1")),
                ..Default::default()
            },
        )]);
        let resolved = resolve(&format!("{provider_name}/qwen3:8b"), &user, "mock").unwrap();
        let (thinking, vision) = OpenAiClient::new(resolved).unwrap().detect_thinking_and_vision().await;
        let paths = captured.lock().unwrap().iter().map(|c| c.path.clone()).collect();
        (thinking, vision, paths)
    }

    #[tokio::test]
    async fn thinking_and_vision_probe_shares_one_fetch() {
        // On the configured-window path the window probe is skipped, but
        // thinking and vision must still come from a single shared endpoint
        // fetch — not two serial probes that re-fetch /models and /props or
        // /api/show.

        // llama.cpp: one /models and one /props serve both thinking and vision.
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "llamacpp"}]});
        let props = json!({"modalities": {"vision": true}, "chat_template": "{% if enable_thinking %}"});
        let (thinking, vision, paths) =
            detect_tv("box", vec![(200, "", models.to_string()), (200, "", props.to_string())]).await;
        assert_eq!(thinking.map(|r| r.levels), Some(vec!["off".to_string(), "on".to_string()]));
        assert!(vision.is_some(), "vision derived from the shared /props");
        assert_eq!(paths, ["/v1/models", "/props?model=qwen3%3A8b"], "each endpoint probed once, no /api/ps");

        // Ollama: one /models and one /api/show — and no window-only /api/ps.
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "library"}]});
        let show = json!({"capabilities": ["completion", "thinking", "vision"]});
        let (thinking, vision, paths) =
            detect_tv("ollama", vec![(200, "", models.to_string()), (200, "", show.to_string())]).await;
        assert!(thinking.is_some(), "thinking derived from the shared /api/show");
        assert!(vision.is_some(), "vision derived from the same /api/show");
        assert_eq!(paths, ["/v1/models", "/api/show"], "/api/show fetched once, no /api/ps window probe");
    }

    #[tokio::test]
    async fn ollama_ps_window_survives_a_failed_show_probe() {
        use crate::thinking::Format;
        // /api/ps and /api/show are probed concurrently: a slow or failed
        // /api/show must not discard the window /api/ps already reported (the
        // agent caps the combined probe, so a serial /api/show could run past
        // the cap and lose it).
        let models = json!({"data": [{"id": "qwen3:8b", "owned_by": "library"}]});
        let ps = json!({"models": [{"name": "qwen3:8b", "context_length": 32768}]});
        let (win, thinking, paths) = detect_both(
            "ollama",
            vec![(200, "", models.to_string()), (200, "", ps.to_string()), (500, "", "{}".into())],
        )
        .await;
        assert_eq!(win, window(32768, "Ollama /api/ps context_length"), "the /api/ps window is kept");
        assert_eq!(thinking, None, "no thinking levels without /api/show");
        assert_eq!(paths.len(), 3, "/models, /api/ps and /api/show were each probed once: {paths:?}");

        // A working /api/show still serves the thinking levels alongside.
        let show = json!({"capabilities": ["completion", "thinking"]});
        let (win, thinking, _) = detect_both(
            "ollama",
            vec![(200, "", models.to_string()), (200, "", ps.to_string()), (200, "", show.to_string())],
        )
        .await;
        assert_eq!(win, window(32768, "Ollama /api/ps context_length"));
        assert_eq!(thinking.map(|r| r.format), Some(Format::Effort));
    }
}
