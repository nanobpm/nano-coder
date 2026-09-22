# Agentic Harness (Rust)

An interactive CLI agentic harness built in Rust with tool calling, lifecycle hooks, and ACP protocol support for headless orchestration.

## Features

- **Interactive CLI**: REPL-based interface for conversing with the agent
- **ACP Protocol**: JSON-RPC 2.0 over stdio for headless orchestration (c8ctl-nano compatible)
- **Tool Calling**: Agent can invoke registered tools during conversation
- **Lifecycle Hooks**: 6 hook events for observing/intercepting agent behavior
- **Configuration**: TOML-based config file at `~/.config/agentic-harness/config.toml`
- **Commands**: `/help`, `/compact`, `/settings`, `/tools`, `/exit`

## Two Execution Modes

### Interactive CLI Mode

```bash
cargo run
```

Starts the interactive REPL where you can chat with the agent and use slash commands.

### ACP Headless Mode (c8ctl-nano compatible)

```bash
cargo run --bin agentic-harness-acp
```

Speaks the Agent Communication Protocol (ACP) over stdio using newline-delimited JSON-RPC 2.0 messages. Compatible with c8ctl-nano's `spawnCaptureAcp` executor.

**Protocol methods supported:**
- `initialize` → returns protocol version and capabilities
- `session/new` → creates a new session, returns sessionId
- `session/prompt` → processes a prompt, supports tool calls
- `session/cancel` → cancels the current turn

**Slash commands work via ACP too:**
- `/compact` - reduces conversation history
- `/settings` - returns current settings as JSON
- `/tools` - lists registered tools

## Architecture

```
src/
├── main.rs              # Interactive CLI entry point
├── bin/agentic-harness-acp.rs  # ACP protocol binary
├── agent.rs             # Agent core: conversation management, tool execution loop
├── acp.rs               # ACP JSON-RPC protocol handler
├── hooks.rs             # Lifecycle hook registry and event system
├── tools.rs             # Tool registration and dispatch system
├── llm.rs               # LLM client interface + mock implementation
└── config.rs            # Configuration file loading and management
```

## Lifecycle Hooks

The harness exposes 6 lifecycle hook events:

| Hook | When it fires |
|------|---------------|
| `before_context_load` | Before processing user input |
| `after_context_load` | After adding user message to conversation |
| `before_llm_send` | Before sending messages to LLM |
| `after_llm_response` | After receiving LLM response |
| `before_tool_call` | Before executing a tool |
| `after_tool_call` | After tool execution completes |

## Built-in Tools

- `get_time` - Get current date and time
- `get_weather` - Get weather for a city (mock)
- `list_files` - List files in current directory (mock)
- `echo` - Echo back input text

## Commands

- `/help` - Show available commands
- `/compact` - Reduce conversation history to last few exchanges
- `/settings` - Interactive settings menu (model, temperature, max tokens, system prompt)
- `/tools` - List registered tools
- `/exit` - Exit the agent

## Building and Running

```bash
cargo build --release
./target/release/agentic-harness
```

Or run directly:

```bash
cargo run
```

## Configuration

Create `~/.config/agentic-harness/config.toml`:

```toml
model = "gpt-4o-mini"
temperature = 0.7
max_tokens = 4096
system_prompt = "You are a helpful assistant with access to tools."
api_key = "your-api-key"
base_url = "https://api.openai.com/v1"
```

## Extending

### Adding Tools

```rust
let tool_def = ToolDefinition::new(
    "my_tool",
    "Description of what the tool does",
    json!({ "type": "object", "properties": { ... } })
);
agent.tools().register(tool_def, Box::new(|args| {
    // Tool implementation
    Ok(json!({ "result": "..." }))
}));
```

### Adding Hooks

```rust
agent.hooks().register(HookEvent::BeforeToolCall, Box::new(|ctx| {
    let tool_name = ctx.data.get("tool_name").and_then(|v| v.as_str());
    println!("About to call tool: {}", tool_name);
}));
```

### Custom LLM Client

Implement the `LLMClient` trait:

```rust
impl LLMClient for MyClient {
    fn chat(&self, messages: &[Message], tools: Option<&Value>) -> Result<LLMResponse> {
        // Call your LLM API
    }
    
    fn model_name(&self) -> &str {
        "my-model"
    }
}
```
