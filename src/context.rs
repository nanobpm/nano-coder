//! Context-window accounting and compaction helpers.

use std::sync::{Arc, Mutex};

use regex::Regex;

use crate::llm::{Message, Role};

/// Used when neither config nor the model name gives a window.
pub const DEFAULT_CONTEXT_WINDOW: usize = 128_000;

/// Tokens kept verbatim at the end of the conversation when compacting.
pub const KEEP_RECENT_TOKENS: usize = 20_000;

/// Output cap for the summary request.
pub const SUMMARY_MAX_TOKENS: i64 = 4_096;

pub const SUMMARY_PREFIX: &str = "[Summary of the earlier conversation, written when the context was compacted]";

pub const SUMMARY_SYSTEM_PROMPT: &str = "You are compacting an AI agent's conversation so it can keep working with a smaller context. \
Write a summary that lets the agent continue without the original messages. Include:\n\
- the user's goals, requirements and constraints (quote exact wording where it matters);\n\
- decisions made and why;\n\
- work completed: files created or edited (with paths), commands run and their key results, \
commits, branches, pull requests and URLs (with exact names and numbers);\n\
- the current state and what was in progress when the summary was written;\n\
- open problems, errors still unresolved, and the next steps;\n\
- identifiers and values the agent will need again.\n\
Be concise but do not drop facts the agent would otherwise have to rediscover. Do not invent anything. \
Output only the summary.";

/// What the agent is doing, for the status line.
#[derive(Debug, Clone, Default, PartialEq)]
pub enum Activity {
    #[default]
    Idle,
    Thinking,
    Tool(String),
    Compacting,
}

/// Context and usage figures, shared with the status line.
#[derive(Debug, Clone, Default)]
pub struct ContextStats {
    pub provider: String,
    pub model: String,
    /// Estimated tokens the next request would send.
    pub tokens: usize,
    /// True when `tokens` is anchored to usage reported by the provider.
    pub calibrated: bool,
    pub window: usize,
    pub messages: usize,
    pub session_input_tokens: u64,
    pub session_output_tokens: u64,
    pub compactions: u32,
    /// Auto-compaction threshold as a fraction of the window (None = off).
    pub auto_compact: Option<f64>,
    pub activity: Activity,
    /// Plan progress as (done, total), when there is a plan.
    pub plan: Option<(usize, usize)>,
    /// Working directory shown on the status line.
    pub cwd: String,
}

impl ContextStats {
    pub fn percent(&self) -> f64 {
        if self.window == 0 { 0.0 } else { self.tokens as f64 * 100.0 / self.window as f64 }
    }
}

pub type SharedStats = Arc<Mutex<ContextStats>>;

/// `12.3k`-style token count.
pub fn format_tokens(tokens: usize) -> String {
    match tokens {
        0..=999 => tokens.to_string(),
        1_000..=99_999 => format!("{:.1}k", tokens as f64 / 1_000.0),
        100_000..=999_999 => format!("{}k", tokens / 1_000),
        _ => format!("{:.2}M", tokens as f64 / 1_000_000.0),
    }
}

/// Rough token count for text (about four characters per token).
pub fn text_tokens(text: &str) -> usize {
    text.len().div_ceil(4)
}

pub fn message_tokens(message: &Message) -> usize {
    let calls: usize = message
        .tool_calls
        .iter()
        .map(|c| text_tokens(&c.name) + text_tokens(&c.arguments.to_string()) + 4)
        .sum();
    text_tokens(&message.content) + calls + 4
}

pub fn messages_tokens(messages: &[Message]) -> usize {
    messages.iter().map(message_tokens).sum()
}

/// Context window by model family, for models whose provider config has none.
pub fn window_for_model(model: &str) -> Option<usize> {
    let m = model.to_lowercase();
    let table: &[(&str, usize)] = &[
        ("claude", 200_000),
        ("gpt-4.1", 1_047_576),
        ("gpt-5", 400_000),
        ("gpt-4o", 128_000),
        ("o4-mini", 200_000),
        ("o3", 200_000),
        ("o1", 200_000),
        ("gemini", 1_048_576),
        ("deepseek", 128_000),
        ("grok", 256_000),
        ("mistral-large", 128_000),
        ("codestral", 256_000),
        ("kimi", 256_000),
        ("gpt-oss", 131_072),
        ("mock", 16_000),
    ];
    table.iter().find(|(needle, _)| m.contains(needle)).map(|(_, window)| *window)
}

/// Does this provider error say the request did not fit the context window?
pub fn is_context_overflow(error: &str) -> bool {
    let e = error.to_lowercase();
    [
        "context_length_exceeded",
        "maximum context length",
        "context length",
        "context window",
        "context size",
        "prompt is too long",
        "input is too long",
        "too many tokens",
        "reduce the length",
        "exceeds the available context",
    ]
    .iter()
    .any(|needle| e.contains(needle))
}

/// The window size stated in a context-overflow error, if any.
pub fn limit_from_error(error: &str) -> Option<usize> {
    let patterns = [
        r"(?i)maximum context length is (\d+)",
        r"(?i)context size \((\d+) tokens\)",
        r"(?i)> ?(\d+) maximum",
        r"(?i)context window (?:of|is) (\d+)",
        r"(?i)limit of (\d+) tokens",
    ];
    patterns.iter().find_map(|p| {
        Regex::new(p).ok()?.captures(error)?.get(1)?.as_str().parse().ok()
    })
}

fn clip(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let head: String = text.chars().take(max_chars * 2 / 3).collect();
    let tail: String = {
        let chars: Vec<char> = text.chars().collect();
        chars[chars.len() - max_chars / 3..].iter().collect()
    };
    format!("{head}\n…[{} characters omitted]…\n{tail}", text.chars().count() - max_chars)
}

/// Shorten an oversized message in place (tool output kept head and tail).
pub fn clip_message(message: &mut Message, max_tokens: usize) -> bool {
    if text_tokens(&message.content) <= max_tokens {
        return false;
    }
    message.content = clip(&message.content, max_tokens * 4);
    true
}

/// Render messages as a plain transcript for the summarizer, newest content
/// kept when it exceeds `max_chars`.
pub fn render_transcript(messages: &[Message], max_chars: usize) -> String {
    let mut blocks: Vec<String> = Vec::new();
    for message in messages {
        let block = match message.role {
            Role::System => continue,
            Role::User => format!("USER:\n{}", clip(&message.content, 6_000)),
            Role::Assistant => {
                let mut block = String::from("ASSISTANT:");
                if !message.content.trim().is_empty() {
                    block.push('\n');
                    block.push_str(&clip(&message.content, 6_000));
                }
                for call in &message.tool_calls {
                    block.push_str(&format!("\n[called {}({})]", call.name, clip(&call.arguments.to_string(), 1_500)));
                }
                block
            }
            Role::Tool => {
                let name = message.name.as_deref().unwrap_or("tool");
                let label = if message.is_error { "failed" } else { "result" };
                format!("TOOL {label} ({name}):\n{}", clip(&message.content, 2_000))
            }
        };
        blocks.push(block);
    }
    let mut kept: Vec<String> = Vec::new();
    let mut total = 0;
    for block in blocks.into_iter().rev() {
        if total + block.len() > max_chars {
            kept.push("…[earlier messages omitted]…".to_string());
            break;
        }
        total += block.len() + 2;
        kept.push(block);
    }
    kept.reverse();
    kept.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_overflow_errors_and_limits() {
        let openai = "HTTP 400: This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.";
        let anthropic = "HTTP 400: prompt is too long: 210000 tokens > 200000 maximum";
        let llamacpp = "HTTP 400: the request exceeds the available context size (8192 tokens), try increasing it";
        for (error, limit) in [(openai, 128_000), (anthropic, 200_000), (llamacpp, 8_192)] {
            assert!(is_context_overflow(error), "{error}");
            assert_eq!(limit_from_error(error), Some(limit), "{error}");
        }
        assert!(!is_context_overflow("HTTP 401: invalid api key"));
    }

    #[test]
    fn transcript_keeps_the_newest_messages() {
        let messages: Vec<Message> = (0..50).map(|i| Message::user(&format!("message {i} {}", "x".repeat(100)))).collect();
        let text = render_transcript(&messages, 1_000);
        assert!(text.starts_with("…[earlier messages omitted]…"));
        assert!(text.contains("message 49"));
        assert!(!text.contains("message 0 "));
    }

    #[test]
    fn model_windows() {
        assert_eq!(window_for_model("claude-sonnet-4-5"), Some(200_000));
        assert_eq!(window_for_model("gpt-4.1-mini"), Some(1_047_576));
        assert_eq!(window_for_model("llama3"), None);
    }
}
