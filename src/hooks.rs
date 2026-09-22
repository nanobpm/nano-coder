use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Lifecycle hook event types
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum HookEvent {
    BeforeContextLoad,
    AfterContextLoad,
    BeforeLLMSend,
    AfterLLMResponse,
    BeforeToolCall,
    AfterToolCall,
}

impl std::fmt::Display for HookEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HookEvent::BeforeContextLoad => write!(f, "before_context_load"),
            HookEvent::AfterContextLoad => write!(f, "after_context_load"),
            HookEvent::BeforeLLMSend => write!(f, "before_llm_send"),
            HookEvent::AfterLLMResponse => write!(f, "after_llm_response"),
            HookEvent::BeforeToolCall => write!(f, "before_tool_call"),
            HookEvent::AfterToolCall => write!(f, "after_tool_call"),
        }
    }
}

/// Hook context data passed to hook handlers
#[derive(Debug, Clone)]
pub struct HookContext {
    pub event: HookEvent,
    pub data: HashMap<String, serde_json::Value>,
}

impl HookContext {
    pub fn new(event: HookEvent) -> Self {
        Self {
            event,
            data: HashMap::new(),
        }
    }

    pub fn with_data(mut self, key: &str, value: serde_json::Value) -> Self {
        self.data.insert(key.to_string(), value);
        self
    }
}

/// Hook handler function type
pub type HookHandler = Box<dyn Fn(&HookContext) + Send + Sync>;

/// Hook registry for managing lifecycle hooks
#[derive(Default)]
pub struct HookRegistry {
    hooks: Arc<Mutex<HashMap<HookEvent, Vec<HookHandler>>>>,
}

impl HookRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a hook handler for a specific event
    pub fn register(&self, event: HookEvent, handler: HookHandler) {
        let mut hooks = self.hooks.lock().unwrap();
        hooks.entry(event).or_default().push(handler);
    }

    /// Trigger all registered hooks for an event
    pub fn trigger(&self, context: &HookContext) {
        let hooks = self.hooks.lock().unwrap();
        if let Some(handlers) = hooks.get(&context.event) {
            for handler in handlers {
                handler(context);
            }
        }
    }

    /// Check if any hooks are registered for an event
    pub fn has_hooks(&self, event: &HookEvent) -> bool {
        let hooks = self.hooks.lock().unwrap();
        hooks.get(event).map_or(false, |handlers| !handlers.is_empty())
    }
}
