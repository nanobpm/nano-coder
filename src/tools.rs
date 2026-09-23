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
    handlers: Arc<Mutex<HashMap<String, SharedHandler>>>,
}

type SharedHandler = Arc<dyn Fn(serde_json::Value) -> Result<serde_json::Value> + Send + Sync>;

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a tool with its definition and handler
    pub fn register(&self, definition: ToolDefinition, handler: ToolHandler) {
        let name = definition.name.clone();
        self.definitions.lock().unwrap().insert(name.clone(), definition);
        self.handlers.lock().unwrap().insert(name, Arc::from(handler));
    }

    /// Get a tool definition by name
    #[allow(dead_code)]
    pub fn get_definition(&self, name: &str) -> Option<ToolDefinition> {
        self.definitions.lock().unwrap().get(name).cloned()
    }

    /// List all registered tool names, sorted
    #[allow(dead_code)]
    pub fn list_tools(&self) -> Vec<String> {
        let defs = self.definitions.lock().unwrap();
        let mut names: Vec<String> = defs.keys().cloned().collect();
        names.sort();
        names
    }

    /// All tool definitions sorted by name, so requests are stable across
    /// turns (keeps provider prompt caches warm).
    pub fn definitions(&self) -> Vec<ToolDefinition> {
        let defs = self.definitions.lock().unwrap();
        let mut all: Vec<ToolDefinition> = defs.values().cloned().collect();
        all.sort_by(|a, b| a.name.cmp(&b.name));
        all
    }

    /// Execute a tool on the blocking pool, so the caller's task stays free
    /// to route steers and cancels while the handler runs.
    pub async fn execute_blocking(&self, name: &str, args: serde_json::Value) -> Result<serde_json::Value> {
        let Some(handler) = self.handlers.lock().unwrap().get(name).cloned() else {
            return Err(anyhow::anyhow!("Tool '{}' not found", name));
        };
        tokio::task::spawn_blocking(move || handler(args))
            .await
            .unwrap_or_else(|e| Err(anyhow::anyhow!("tool '{}' panicked: {e}", name)))
    }
}
