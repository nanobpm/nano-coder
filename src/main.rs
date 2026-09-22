use anyhow::Result;
use chrono::Local;
use dialoguer::{Input, Select};
use serde_json::json;
use std::io::{self, Write};

mod agent;
mod config;
mod hooks;
mod llm;
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
    // Log all lifecycle events
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

async fn run_command(agent: &mut Agent, cmd: &str) -> Result<bool> {
    match cmd {
        "/exit" | "/quit" => Ok(false),
        "/help" => {
            println!("Commands:");
            println!("  /help      - Show this help");
            println!("  /compact   - Compact conversation history");
            println!("  /settings  - View/edit settings");
            println!("  /tools     - List available tools");
            println!("  /exit      - Exit the agent");
            Ok(true)
        }
        "/compact" => {
            let before = agent.conversation_length();
            agent.compact();
            let after = agent.conversation_length();
            println!("Conversation compacted: {} -> {} messages", before, after);
            Ok(true)
        }
        "/settings" => {
            run_settings(agent).await?;
            Ok(true)
        }
        "/tools" => {
            println!("Available tools:");
            for name in agent.tools().list_tools() {
                if let Some(def) = agent.tools().get_definition(&name) {
                    println!("  {} - {}", def.name, def.description);
                }
            }
            Ok(true)
        }
        _ => {
            let response = agent.send_message(cmd).await?;
            println!("\n{}", response);
            Ok(true)
        }
    }
}

async fn run_settings(agent: &mut Agent) -> Result<()> {
    loop {
        println!("\nSettings:");
        println!("  1. Model: {}", agent.config().model);
        println!("  2. Temperature: {}", agent.config().temperature);
        println!("  3. Max tokens: {}", agent.config().max_tokens);
        println!("  4. System prompt");
        println!("  5. Done");

        let selection = Select::new()
            .with_prompt("Select setting")
            .items(&["Model", "Temperature", "Max tokens", "System prompt", "Done"])
            .default(4)
            .interact()?;

        match selection {
            0 => {
                let input: String = Input::new()
                    .with_prompt("Model name")
                    .default(agent.config().model.clone())
                    .interact_text()?;
                let prompt = agent.config().system_prompt.clone();
                agent.set_system_prompt(&prompt);
                println!("Model set to: {}", input);
            }
            1 => {
                let input: f64 = Input::new()
                    .with_prompt("Temperature (0.0-2.0)")
                    .default(agent.config().temperature)
                    .interact_text()?;
                println!("Temperature set to: {}", input);
            }
            2 => {
                let input: i32 = Input::new()
                    .with_prompt("Max tokens")
                    .default(agent.config().max_tokens)
                    .interact_text()?;
                println!("Max tokens set to: {}", input);
            }
            3 => {
                let input: String = Input::new()
                    .with_prompt("System prompt")
                    .default(agent.config().system_prompt.clone())
                    .interact_text()?;
                agent.set_system_prompt(&input);
                println!("System prompt updated");
            }
            _ => break,
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    // Load config
    let config_mgr = ConfigManager::new()?;
    let config = config_mgr.get().clone();

    // Create agent with mock LLM
    let client = Box::new(MockLLMClient::new(&config.model));
    let mut agent = Agent::new(client, config);

    // Register tools and hooks
    register_builtin_tools(&mut agent);
    register_hooks(&mut agent);

    println!("Agentic Harness v0.1.0");
    println!("Model: {}", agent.config().model);
    println!("Type /help for commands\n");

    // Main loop
    let mut running = true;
    while running {
        io::stdout().write_all(b"> ").unwrap();
        io::stdout().flush().unwrap();

        let mut input = String::new();
        if io::stdin().read_line(&mut input).is_err() {
            break;
        }
        let input = input.trim().to_string();
        if input.is_empty() {
            continue;
        }

        match run_command(&mut agent, &input).await {
            Ok(continue_running) => {
                running = continue_running;
            }
            Err(e) => {
                eprintln!("Error: {}", e);
            }
        }
    }

    println!("\nGoodbye!");
    Ok(())
}
