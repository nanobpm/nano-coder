use anyhow::Result;
use serde_json::json;

use crate::hooks::{HookEvent, HookContext, HookRegistry};
use crate::llm::{LLMClient, Message};
use crate::tools::ToolRegistry;
use crate::config::Config;

/// Agent manages the conversation loop, tool execution, and hooks
pub struct Agent {
    client: Box<dyn LLMClient>,
    tools: ToolRegistry,
    hooks: HookRegistry,
    config: Config,
    conversation: Vec<Message>,
}

impl Agent {
    pub fn new(client: Box<dyn LLMClient>, config: Config) -> Self {
        let mut agent = Self {
            client,
            tools: ToolRegistry::new(),
            hooks: HookRegistry::new(),
            config,
            conversation: vec![],
        };

        // Add system message
        agent.conversation.push(Message::system(&agent.config.system_prompt));

        agent
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

    /// Set the system prompt and reset conversation
    pub fn set_system_prompt(&mut self, prompt: &str) {
        self.config.system_prompt = prompt.to_string();
        self.conversation.clear();
        self.conversation.push(Message::system(prompt));
    }

    /// Send a user message and get agent response (with tool execution)
    pub async fn send_message(&mut self, user_input: &str) -> Result<String> {
        // Trigger before_context_load hook
        let ctx = HookContext::new(HookEvent::BeforeContextLoad)
            .with_data("user_input", json!(user_input));
        self.hooks.trigger(&ctx);

        // Add user message to conversation
        self.conversation.push(Message::user(user_input));

        // Trigger after_context_load hook
        let ctx = HookContext::new(HookEvent::AfterContextLoad)
            .with_data("message_count", json!(self.conversation.len()));
        self.hooks.trigger(&ctx);

        // Get tools JSON for LLM
        let tools_json = self.tools.to_json_array();

        // Main loop: handle LLM responses and tool calls
        let mut final_response = String::new();
        let mut iteration = 0;
        const MAX_ITERATIONS: i32 = 10;

        while iteration < MAX_ITERATIONS {
            iteration += 1;

            // Trigger before_llm_send hook
            let ctx = HookContext::new(HookEvent::BeforeLLMSend)
                .with_data("iteration", json!(iteration))
                .with_data("message_count", json!(self.conversation.len()));
            self.hooks.trigger(&ctx);

            // Send to LLM
            let response = self.client.chat(&self.conversation, Some(&tools_json))?;

            // Trigger after_llm_response hook
            let ctx = HookContext::new(HookEvent::AfterLLMResponse)
                .with_data("iteration", json!(iteration))
                .with_data("has_tool_calls", json!(!response.tool_calls.is_empty()));
            self.hooks.trigger(&ctx);

            // If LLM wants to call tools, execute them
            if !response.tool_calls.is_empty() {
                for tool_call in &response.tool_calls {
                    // Trigger before_tool_call hook
                    let ctx = HookContext::new(HookEvent::BeforeToolCall)
                        .with_data("tool_name", json!(&tool_call.name))
                        .with_data("arguments", tool_call.arguments.clone());
                    self.hooks.trigger(&ctx);

                    // Execute tool
                    let result = match self.tools.execute(&tool_call.name, tool_call.arguments.clone()) {
                        Ok(value) => value,
                        Err(e) => json!({ "error": e.to_string() }),
                    };

                    // Trigger after_tool_call hook
                    let ctx = HookContext::new(HookEvent::AfterToolCall)
                        .with_data("tool_name", json!(&tool_call.name))
                        .with_data("result", result.clone());
                    self.hooks.trigger(&ctx);

                    // Add tool result to conversation
                    let result_str = result.to_string();
                    self.conversation.push(Message::tool_result(&tool_call.id, &tool_call.name, &result_str));
                }

                // Continue loop to get LLM's response with tool results
                continue;
            }

            // No more tool calls - this is the final response
            final_response = response.content;
            self.conversation.push(Message::assistant(&final_response));
            break;
        }

        Ok(final_response)
    }

    /// Compact the conversation to reduce context size
    pub fn compact(&mut self) {
        // Keep system message and last few exchanges
        let system = self.conversation.first().cloned();
        let recent: Vec<Message> = self.conversation.iter().rev().take(4).cloned().collect();

        self.conversation.clear();
        if let Some(sys) = system {
            self.conversation.push(sys);
        }
        for msg in recent.into_iter().rev() {
            self.conversation.push(msg);
        }
    }

    /// Get conversation length
    pub fn conversation_length(&self) -> usize {
        self.conversation.len()
    }
}

