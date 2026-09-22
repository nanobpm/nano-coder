use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use anyhow::Result;

/// Tool handler function type
pub type ToolHandler = Box<dyn Fn(serde_json::Value) -> Result<serde_json::Value> + Send + Sync>;

/// Tool definition with metadata
#[derive(Debug, Clone)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: serde_json::Value,
}

impl ToolDefinition {
    pub fn new(name: &str, description: &str, parameters: serde_json::Value) -> Self {
        Self {
            name: name.to_string(),
            description: description.to_string(),
            parameters,
        }
    }
}

/// Tool registry for managing tool definitions and handlers
#[derive(Default)]
pub struct ToolRegistry {
    definitions: Arc<Mutex<HashMap<String, ToolDefinition>>>,
    handlers: Arc<Mutex<HashMap<String, ToolHandler>>>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a tool with its definition and handler
    pub fn register(&self, definition: ToolDefinition, handler: ToolHandler) {
        let name = definition.name.clone();
        self.definitions.lock().unwrap().insert(name.clone(), definition);
        self.handlers.lock().unwrap().insert(name, handler);
    }

    /// Get a tool definition by name
    pub fn get_definition(&self, name: &str) -> Option<ToolDefinition> {
        self.definitions.lock().unwrap().get(name).cloned()
    }

    /// List all registered tool names
    pub fn list_tools(&self) -> Vec<String> {
        let defs = self.definitions.lock().unwrap();
        defs.keys().cloned().collect()
    }

    /// Execute a tool by name with arguments
    pub fn execute(&self, name: &str, args: serde_json::Value) -> Result<serde_json::Value> {
        let handlers = self.handlers.lock().unwrap();
        match handlers.get(name) {
            Some(handler) => handler(args),
            None => Err(anyhow::anyhow!("Tool '{}' not found", name)),
        }
    }

    /// Get all tool definitions as JSON array (for LLM context)
    pub fn to_json_array(&self) -> serde_json::Value {
        let defs = self.definitions.lock().unwrap();
        let mut arr = Vec::new();
        for (_, def) in defs.iter() {
            arr.push(serde_json::json!({
                "name": def.name,
                "description": def.description,
                "parameters": def.parameters,
            }));
        }
        serde_json::Value::Array(arr)
    }
}
