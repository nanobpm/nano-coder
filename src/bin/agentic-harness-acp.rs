use anyhow::Result;
use chrono::Local;
use serde_json::{json, Value};

// For binaries in src/bin/, modules must be declared with explicit paths
#[path = "../agent.rs"]
mod agent;
#[path = "../acp.rs"]
mod acp;
#[path = "../config.rs"]
mod config;
#[path = "../hooks.rs"]
mod hooks;
#[path = "../llm.rs"]
mod llm;
#[path = "../tools.rs"]
mod tools;

use agent::Agent;
use config::ConfigManager;
use hooks::HookEvent;
use llm::MockLLMClient;
use tools::ToolDefinition;

fn register_builtin_tools(agent: &mut Agent) {
    // get_time tool
    let time_def = ToolDefinition::new(
        "get_time",
        "Get the current date and time",
        json!({ "type": "object", "properties": {} }),
    );
    agent.tools().register(time_def, Box::new(|_| {
        Ok(json!({ "time": Local::now().to_string() }))
    }));

    // get_weather tool (mock)
    let weather_def = ToolDefinition::new(
        "get_weather",
        "Get current weather for a city",
        json!({
            "type": "object",
            "properties": {
                "city": { "type": "string", "description": "City name" }
            },
            "required": ["city"]
        }),
    );
    agent.tools().register(weather_def, Box::new(|args| {
        let city = args["city"].as_str().unwrap_or("Unknown");
        Ok(json!({
            "city": city,
            "temperature": "72°F",
            "condition": "Partly cloudy"
        }))
    }));

    // list_files tool
    let files_def = ToolDefinition::new(
        "list_files",
        "List files in the current directory",
        json!({ "type": "object", "properties": {} }),
    );
    agent.tools().register(files_def, Box::new(|_| {
        Ok(json!({ "files": ["Cargo.toml", "src/", "README.md"] }))
    }));

    // echo tool
    let echo_def = ToolDefinition::new(
        "echo",
        "Echo back the input text",
        json!({
            "type": "object",
            "properties": {
                "text": { "type": "string" }
            },
            "required": ["text"]
        }),
    );
    agent.tools().register(echo_def, Box::new(|args| {
        let text = args["text"].as_str().unwrap_or("");
        Ok(json!({ "echo": text }))
    }));
}

fn register_hooks(agent: &mut Agent) {
    // Log all lifecycle events to stderr (stdout is reserved for JSON-RPC)
    for event in [
        HookEvent::BeforeContextLoad,
        HookEvent::AfterContextLoad,
        HookEvent::BeforeLLMSend,
        HookEvent::AfterLLMResponse,
        HookEvent::BeforeToolCall,
        HookEvent::AfterToolCall,
    ] {
        let event_name = event.to_string();
        agent.hooks().register(event.clone(), Box::new(move |ctx| {
            match ctx.event {
                HookEvent::BeforeContextLoad => {
                    let input = ctx.data.get("user_input").and_then(|v| v.as_str()).unwrap_or("");
                    eprintln!("[hook] {} - user: {}", event_name, input);
                }
                HookEvent::AfterContextLoad => {
                    let count = ctx.data.get("message_count").and_then(|v| v.as_i64()).unwrap_or(0);
                    eprintln!("[hook] {} - messages: {}", event_name, count);
                }
                HookEvent::BeforeLLMSend => {
                    let iter = ctx.data.get("iteration").and_then(|v| v.as_i64()).unwrap_or(0);
                    eprintln!("[hook] {} - iteration: {}", event_name, iter);
                }
                HookEvent::AfterLLMResponse => {
                    let has_tools = ctx.data.get("has_tool_calls").and_then(|v| v.as_bool()).unwrap_or(false);
                    eprintln!("[hook] {} - tool_calls: {}", event_name, has_tools);
                }
                HookEvent::BeforeToolCall => {
                    let name = ctx.data.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
                    eprintln!("[hook] {} - tool: {}", event_name, name);
                }
                HookEvent::AfterToolCall => {
                    let name = ctx.data.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
                    eprintln!("[hook] {} - tool: {}", event_name, name);
                }
            }
        }));
    }
}

fn main() -> Result<()> {
    // Load config
    let config_mgr = ConfigManager::new()?;
    let config = config_mgr.get().clone();

    // Create agent with mock LLM
    let client = Box::new(MockLLMClient::new(&config.model));
    let mut agent = Agent::new(client, config);

    // Register tools and hooks
    register_builtin_tools(&mut agent);
    register_hooks(&mut agent);

    eprintln!("ACP harness ready (model: {})", agent.config().model);

    // Run ACP protocol loop
    acp::run_acp(&mut agent)?;

    Ok(())
}