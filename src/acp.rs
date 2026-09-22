use anyhow::Result;
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};

use crate::agent::Agent;
use crate::hooks::{HookEvent, HookContext};

/// ACP protocol version
const PROTOCOL_VERSION: i32 = 1;

/// Handle an ACP JSON-RPC message and return the response (if any)
pub fn handle_message(agent: &mut Agent, msg: Value) -> Option<Value> {
    let method = msg.get("method").and_then(|m| m.as_str());
    let id = msg.get("id");

    match method {
        Some("initialize") => {
            Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "agentCapabilities": {
                        "tools": true,
                        "hooks": true,
                        "compact": true
                    }
                }
            }))
        }
        Some("session/new") => {
            let session_id = format!("sess-{}", std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis());
            Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": { "sessionId": session_id }
            }))
        }
        Some("session/prompt") => {
            // Extract prompt text
            let default_params = json!({});
            let params = msg.get("params").unwrap_or(&default_params);
            let prompt_arr = params.get("prompt").and_then(|p| p.as_array());
            let mut prompt_text = String::new();
            if let Some(arr) = prompt_arr {
                for item in arr {
                    if let Some(text) = item.get("text").and_then(|t| t.as_str()) {
                        prompt_text.push_str(text);
                    }
                }
            }

            // Handle /compact command via ACP
            if prompt_text.trim() == "/compact" {
                let before = agent.conversation_length();
                agent.compact();
                let after = agent.conversation_length();
                return Some(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "stopReason": "end_turn",
                        "compacted": true,
                        "before": before,
                        "after": after
                    }
                }));
            }

            // Handle /settings command via ACP (return current settings)
            if prompt_text.trim() == "/settings" {
                let config = agent.config();
                return Some(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "stopReason": "end_turn",
                        "settings": {
                            "model": config.model,
                            "temperature": config.temperature,
                            "max_tokens": config.max_tokens,
                            "system_prompt": config.system_prompt
                        }
                    }
                }));
            }

            // Handle /tools command via ACP (list tools)
            if prompt_text.trim() == "/tools" {
                let tools = agent.tools().list_tools();
                return Some(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "stopReason": "end_turn",
                        "tools": tools
                    }
                }));
            }

            // Send prompt to agent (async via tokio)
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();

            let response = match rt.block_on(agent.send_message(&prompt_text)) {
                Ok(resp) => resp,
                Err(e) => format!("Error: {}", e),
            };

            Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "stopReason": "end_turn",
                    "response": response
                }
            }))
        }
        Some("session/cancel") => {
            Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "stopReason": "cancelled"
                }
            }))
        }
        _ => None,
    }
}

/// Send a JSON-RPC notification to stdout
pub fn send_notification(method: &str, params: Value) {
    let msg = json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params
    });
    writeln!(io::stdout(), "{}", msg.to_string()).unwrap();
    io::stdout().flush().unwrap();
}

/// Send a JSON-RPC response to stdout
pub fn send_response(id: &Value, result: Value) {
    let msg = json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    });
    writeln!(io::stdout(), "{}", msg.to_string()).unwrap();
    io::stdout().flush().unwrap();
}

/// Run the ACP protocol loop
pub fn run_acp(agent: &mut Agent) -> Result<()> {
    let stdin = io::stdin();
    let mut lines = stdin.lock().lines();

    while let Some(Ok(line)) = lines.next() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Parse JSON-RPC message
        let msg: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("ACP parse error: {}", e);
                continue;
            }
        };

        // Handle the message
        if let Some(response) = handle_message(agent, msg) {
            send_response(
                &response["id"],
                response["result"].clone()
            );
        }
    }

    Ok(())
}
