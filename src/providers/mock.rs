//! Offline scripted client: triggers tool calls from keywords so the harness
//! can be exercised without a model endpoint.

use anyhow::Result;
use async_trait::async_trait;
use serde_json::json;
use std::sync::atomic::{AtomicI64, Ordering};

use crate::llm::{ChatRequest, LLMClient, LLMResponse, Role, StreamEvent, StreamSink, TokenUsage, ToolCall};

pub struct MockLLMClient {
    provider: String,
    model: String,
    call_count: AtomicI64,
}

impl MockLLMClient {
    /// `provider` is the resolved provider's name, kept so temperature (and
    /// any other provider-keyed) lookup reads the entry the client was built
    /// from — a custom provider with `kind = "mock"` must resolve against its
    /// own entry, not the built-in `mock` one.
    pub fn new(provider: &str, model: &str) -> Self {
        Self { provider: provider.to_string(), model: model.to_string(), call_count: AtomicI64::new(0) }
    }

    fn usage(completion_tokens: i64) -> Option<TokenUsage> {
        Some(TokenUsage { prompt_tokens: 50, completion_tokens, total_tokens: 50 + completion_tokens, aic: None })
    }

    fn pick_tool(content: &str) -> Option<(&'static str, serde_json::Value)> {
        let content = content.to_lowercase();
        // "question"/"ask" drives the `question` tool, so the interactive
        // picker flow (and the rule that a queued message is never injected
        // while a question is pending) can be exercised without a model.
        // Match as standalone words so ordinary prompts like "finish the task"
        // (which merely *contain* "ask") don't trip the picker unexpectedly.
        if has_word(&content, "question") || has_word(&content, "ask") {
            return Some((
                "question",
                json!({
                    "questions": [{
                        "question": "Which way should I go?",
                        "header": "Direction",
                        "options": [{ "label": "Left" }, { "label": "Right" }]
                    }]
                }),
            ));
        }
        if content.contains("time") || content.contains("clock") {
            return Some(("get_time", json!({})));
        }
        if content.contains("file") || content.contains("list") {
            return Some(("bash", json!({ "command": "ls -la" })));
        }
        if content.contains("bash") || content.contains("command") || content.contains("run") {
            let command = if content.contains("echo") {
                "echo hello world"
            } else if content.contains("sleep") {
                "sleep 3"
            } else if content.contains("pwd") {
                "pwd"
            } else {
                "ls -la"
            };
            return Some(("bash", json!({ "command": command })));
        }
        None
    }
}

/// True when `needle` appears in `haystack` as a standalone word (delimited by
/// non-alphanumeric characters), so substrings like "ask" inside "task" don't
/// match. Both arguments are expected to already be lowercase.
fn has_word(haystack: &str, needle: &str) -> bool {
    haystack.split(|c: char| !c.is_alphanumeric()).any(|word| word == needle)
}

/// Mock reasoning, produced when the user's latest message mentions "think".
fn mock_thinking(request: &ChatRequest<'_>) -> String {
    let asked = request
        .messages
        .iter()
        .rev()
        .find(|m| m.role == Role::User)
        .is_some_and(|m| m.content.to_lowercase().contains("think"));
    if !asked {
        return String::new();
    }
    "The user wants me to think this through. First I should restate the problem, \
     then consider what tools might help, weigh the options, and check for edge cases. \
     Nothing here needs a tool, so a direct answer is best. I will keep it short."
        .to_string()
}

#[async_trait]
impl LLMClient for MockLLMClient {
    fn clone_boxed(&self) -> Box<dyn LLMClient> {
        Box::new(Self::new(&self.model))
    }

    /// Streams word by word, with small delays, to exercise streaming output.
    async fn chat_stream(&self, request: &ChatRequest<'_>, sink: StreamSink<'_>) -> Result<LLMResponse> {
        let response = self.chat(request).await?;
        for (text, thinking) in [(&response.thinking, true), (&response.content, false)] {
            for word in text.split_inclusive(' ') {
                sink(if thinking { StreamEvent::Thinking(word) } else { StreamEvent::Text(word) });
                tokio::time::sleep(std::time::Duration::from_millis(if thinking { 40 } else { 15 })).await;
            }
        }
        Ok(response)
    }

    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
        let thinking = mock_thinking(request);
        let call_id = self.call_count.fetch_add(1, Ordering::SeqCst) + 1;
        let last = request.messages.last();

        if let Some(tool_msg) = last.filter(|m| m.role == Role::Tool) {
            let name = tool_msg.name.as_deref().unwrap_or("unknown");
            return Ok(LLMResponse {
                content: format!("Based on the {} tool result: {}", name, tool_msg.content),
                usage: Self::usage(30),
                stop_reason: Some("stop".into()),
                ..Default::default()
            });
        }

        if let Some(user_msg) = last.filter(|m| m.role == Role::User) {
            let available = |name: &str| request.tools.iter().any(|t| t.name == name);
            if let Some((name, arguments)) = Self::pick_tool(&user_msg.content).filter(|(n, _)| available(n)) {
                return Ok(LLMResponse {
                    tool_calls: vec![ToolCall {
                        id: format!("call_{call_id}"),
                        name: name.to_string(),
                        arguments,
                        item_id: None,
                        malformed_arguments: None,
                    }],
                    usage: Self::usage(20),
                    stop_reason: Some("tool_calls".into()),
                    ..Default::default()
                });
            }
        }

        Ok(LLMResponse {
            content: format!(
                "This is a mock response from {} (call #{}). I'm simulating an LLM agent. Try asking me about the time, or to list files or run a command, to see tool calls in action.",
                self.model, call_id
            ),
            usage: Self::usage(30),
            stop_reason: Some("stop".into()),
            thinking,
            ..Default::default()
        })
    }

    fn model_name(&self) -> &str {
        &self.model
    }

    fn provider_name(&self) -> &str {
        &self.provider
    }
}
