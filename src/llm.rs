use anyhow::Result;
use serde_json::{json, Value};

/// LLM message role
#[derive(Debug, Clone, PartialEq)]
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

/// LLM message
#[derive(Debug, Clone)]
pub struct Message {
    pub role: Role,
    pub content: String,
    pub tool_call_id: Option<String>,
    pub name: Option<String>,
}

impl Message {
    pub fn system(content: &str) -> Self {
        Self {
            role: Role::System,
            content: content.to_string(),
            tool_call_id: None,
            name: None,
        }
    }

    pub fn user(content: &str) -> Self {
        Self {
            role: Role::User,
            content: content.to_string(),
            tool_call_id: None,
            name: None,
        }
    }

    pub fn assistant(content: &str) -> Self {
        Self {
            role: Role::Assistant,
            content: content.to_string(),
            tool_call_id: None,
            name: None,
        }
    }

    pub fn tool_result(tool_call_id: &str, name: &str, content: &str) -> Self {
        Self {
            role: Role::Tool,
            content: content.to_string(),
            tool_call_id: Some(tool_call_id.to_string()),
            name: Some(name.to_string()),
        }
    }

    pub fn to_json(&self) -> Value {
        let mut obj = json!({
            "role": self.role.to_string(),
            "content": self.content,
        });
        if let Some(id) = &self.tool_call_id {
            obj["tool_call_id"] = json!(id);
        }
        if let Some(name) = &self.name {
            obj["name"] = json!(name);
        }
        obj
    }
}

/// LLM response
#[derive(Debug, Clone)]
pub struct LLMResponse {
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
    pub usage: Option<TokenUsage>,
}

/// Token usage information
#[derive(Debug, Clone)]
pub struct TokenUsage {
    pub prompt_tokens: i32,
    pub completion_tokens: i32,
    pub total_tokens: i32,
}

/// Tool call requested by LLM
#[derive(Debug, Clone)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

/// LLM client trait
pub trait LLMClient {
    fn chat(&self, messages: &[Message], tools: Option<&Value>) -> Result<LLMResponse>;
    fn model_name(&self) -> &str;
}

/// Mock LLM client for demonstration
pub struct MockLLMClient {
    model: String,
    call_count: std::sync::Arc<std::sync::atomic::AtomicI32>,
}

impl MockLLMClient {
    pub fn new(model: &str) -> Self {
        Self {
            model: model.to_string(),
            call_count: std::sync::Arc::new(std::sync::atomic::AtomicI32::new(0)),
        }
    }

    fn next_call_id(&self) -> i32 {
        self.call_count.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1
    }

    /// Check if we should call a tool (user asked, haven't called tool for this query yet)
    fn should_call_tool(&self, messages: &[Message], user_content: &str) -> bool {
        // Count user messages and tool results
        let user_count = messages.iter().filter(|m| m.role == Role::User).count();
        let tool_count = messages.iter().filter(|m| m.role == Role::Tool).count();

        // Only call a tool if there are more user messages than tool results
        // (meaning this is a new query that hasn't had a tool called yet)
        if user_count <= tool_count {
            return false;
        }

        // Check if the query matches any tool triggers
        let content = user_content.to_lowercase();
        content.contains("time") || content.contains("clock") ||
        content.contains("weather") ||
        content.contains("file") || content.contains("read") || content.contains("list") ||
        content.contains("bash") || content.contains("command") || content.contains("run")
    }
}

impl LLMClient for MockLLMClient {
    fn chat(&self, messages: &[Message], _tools: Option<&Value>) -> Result<LLMResponse> {
        let call_id = self.next_call_id();

        // Find last user message
        let last_user = messages.iter().rev().find(|m| m.role == Role::User);

        // If there's a tool result and no new user query, respond with text
        if last_user.is_none() {
            let last_tool = messages.iter().rev().find(|m| m.role == Role::Tool);
            if let Some(tool_msg) = last_tool {
                let name = tool_msg.name.as_deref().unwrap_or("unknown");
                return Ok(LLMResponse {
                    content: format!("Based on the {} tool result: {}", name, tool_msg.content),
                    tool_calls: vec![],
                    usage: Some(TokenUsage {
                        prompt_tokens: 50,
                        completion_tokens: 30,
                        total_tokens: 80,
                    }),
                });
            }
        }

        // Check if we should call a tool
        if let Some(user_msg) = last_user {
            if self.should_call_tool(messages, &user_msg.content) {
                let content = user_msg.content.to_lowercase();

                // If user asks about time, use time tool
                if content.contains("time") || content.contains("clock") {
                    return Ok(LLMResponse {
                        content: String::new(),
                        tool_calls: vec![ToolCall {
                            id: format!("call_{}", call_id),
                            name: "get_time".to_string(),
                            arguments: json!({}),
                        }],
                        usage: Some(TokenUsage {
                            prompt_tokens: 50,
                            completion_tokens: 20,
                            total_tokens: 70,
                        }),
                    });
                }

                // If user asks about weather, use weather tool
                if content.contains("weather") {
                    let city = if content.contains("nyc") || content.contains("new york") {
                        "New York"
                    } else if content.contains("london") {
                        "London"
                    } else {
                        "San Francisco"
                    };
                    return Ok(LLMResponse {
                        content: String::new(),
                        tool_calls: vec![ToolCall {
                            id: format!("call_{}", call_id),
                            name: "get_weather".to_string(),
                            arguments: json!({ "city": city }),
                        }],
                        usage: Some(TokenUsage {
                            prompt_tokens: 50,
                            completion_tokens: 20,
                            total_tokens: 70,
                        }),
                    });
                }

                // If user asks about files, use file tool
                if content.contains("file") || content.contains("read") || content.contains("list") {
                    return Ok(LLMResponse {
                        content: String::new(),
                        tool_calls: vec![ToolCall {
                            id: format!("call_{}", call_id),
                            name: "list_files".to_string(),
                            arguments: json!({}),
                        }],
                        usage: Some(TokenUsage {
                            prompt_tokens: 50,
                            completion_tokens: 20,
                            total_tokens: 70,
                        }),
                    });
                }

                // If user asks to run a bash command
                if content.contains("bash") || content.contains("command") || content.contains("run") {
                    // Extract the command from the user's message
                    let cmd = if content.contains("echo") {
                        "echo hello world"
                    } else if content.contains("pwd") {
                        "pwd"
                    } else {
                        "ls -la"
                    };
                    return Ok(LLMResponse {
                        content: String::new(),
                        tool_calls: vec![ToolCall {
                            id: format!("call_{}", call_id),
                            name: "bash".to_string(),
                            arguments: json!({ "command": cmd }),
                        }],
                        usage: Some(TokenUsage {
                            prompt_tokens: 50,
                            completion_tokens: 20,
                            total_tokens: 70,
                        }),
                    });
                }
            }
        }

        // Default: respond with text
        Ok(LLMResponse {
            content: format!("This is a mock response from {} (call #{}). I'm simulating an LLM agent. Try asking me about the time, weather, or files to see tool calls in action.", self.model, call_id),
            tool_calls: vec![],
            usage: Some(TokenUsage {
                prompt_tokens: 50,
                completion_tokens: 30,
                total_tokens: 80,
            }),
        })
    }

    fn model_name(&self) -> &str {
        &self.model
    }
}
