//! The `report_outcome` tool: the model's explicit "done" or "blocked"
//! signal, so an orchestrator need not guess from the stop reason.
//!
//! Reporting an outcome ends the turn: the summary becomes the final answer
//! and the outcome is returned with it (ACP `_meta.outcome`) and recorded at
//! the turn's end. The idea comes from grok-build's `update_goal` tool.

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::llm::{Message, Role};
use crate::tools::ToolDefinition;

pub const TOOL_NAME: &str = "report_outcome";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Completed,
    Blocked,
    /// The agent has a question or needs a decision from the user to proceed.
    NeedsInput,
}

impl Status {
    pub fn parse(text: &str) -> Option<Self> {
        match text.trim().to_ascii_lowercase().replace(['-', ' '], "_").as_str() {
            "completed" | "complete" | "done" | "success" | "succeeded" => Some(Status::Completed),
            "blocked" | "stuck" | "failed" | "failure" | "needs_help" => Some(Status::Blocked),
            "needs_input" | "question" | "ask" | "clarify" | "needs_decision" => Some(Status::NeedsInput),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Status::Completed => "completed",
            Status::Blocked => "blocked",
            Status::NeedsInput => "needs_input",
        }
    }

    /// Extract the outcome status from `report_outcome` arguments, tolerating
    /// arguments sent as a JSON string (as [`Outcome::from_args`] does).
    pub fn from_args(args: &Value) -> Option<Self> {
        let parsed;
        let args = match args {
            Value::String(text) => {
                parsed = serde_json::from_str::<Value>(text).ok()?;
                &parsed
            }
            other => other,
        };
        args.get("status").and_then(Value::as_str).and_then(Status::parse)
    }
}

/// A reported outcome.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Outcome {
    pub status: Status,
    pub summary: String,
}

impl Outcome {
    /// Parse the tool's arguments, tolerating arguments sent as a JSON string.
    pub fn from_args(args: &Value) -> Result<Self> {
        let parsed;
        let args = match args {
            Value::String(text) => {
                parsed = serde_json::from_str::<Value>(text).unwrap_or(Value::Null);
                &parsed
            }
            other => other,
        };
        let Some(status) = args.get("status").and_then(Value::as_str) else {
            bail!("report_outcome needs `status`: \"completed\", \"blocked\" or \"needs_input\"");
        };
        let Some(status) = Status::parse(status) else {
            bail!("report_outcome `status` must be \"completed\", \"blocked\" or \"needs_input\", got {status:?}");
        };
        let summary = args.get("summary").and_then(Value::as_str).unwrap_or_default().trim();
        if summary.is_empty() {
            bail!("report_outcome needs a `summary`");
        }
        Ok(Outcome { status, summary: summary.to_string() })
    }

    /// The turn's final answer.
    pub fn response(&self) -> String {
        match self.status {
            Status::Completed => self.summary.clone(),
            Status::Blocked => format!("Blocked: {}", self.summary),
            Status::NeedsInput => format!("Question: {}", self.summary),
        }
    }

    /// The latest successful `report_outcome` call among `messages` (one
    /// turn's messages), for finishing a turn interrupted after the call.
    pub fn reported_in(messages: &[Message]) -> Option<Self> {
        let succeeded = |id: &str| {
            messages
                .iter()
                .any(|m| m.role == Role::Tool && m.tool_call_id.as_deref() == Some(id) && !m.is_error)
        };
        messages
            .iter()
            .rev()
            .filter(|m| m.role == Role::Assistant)
            .flat_map(|m| m.tool_calls.iter().rev())
            .filter(|call| call.name == TOOL_NAME && succeeded(&call.id))
            .find_map(|call| Outcome::from_args(&call.arguments).ok())
    }
}

pub fn definition() -> ToolDefinition {
    ToolDefinition::new(
        TOOL_NAME,
        "Report the outcome of the task you were given. This ends your turn: the summary becomes your final \
         answer. Use status \"completed\" only when the whole task is done and checked (for example, tests pass); \
         summarize what changed and include any PR URLs, branches, or commits. Use status \"blocked\" only when \
         you cannot make progress: after three or more different failed attempts at the same problem, or when \
         you need access or information that only a person can give. Use status \"needs_input\" when you have a \
         question or need a decision from the user to proceed; put the question in the summary. Do not \
         call this for partial progress.",
        json!({
            "type": "object",
            "properties": {
                "status": { "type": "string", "enum": ["completed", "blocked", "needs_input"] },
                "summary": {
                    "type": "string",
                    "description": "Completed: what was done, with PR URLs or commits. Blocked: what was tried and what is needed to continue. NeedsInput: the question or decision you need from the user."
                }
            },
            "required": ["status", "summary"]
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::ToolCall;

    #[test]
    fn parses_arguments_leniently() {
        let outcome = Outcome::from_args(&json!({"status": "Done", "summary": " opened #12 "})).unwrap();
        assert_eq!(outcome, Outcome { status: Status::Completed, summary: "opened #12".into() });
        let outcome = Outcome::from_args(&json!(r#"{"status": "stuck", "summary": "no token"}"#)).unwrap();
        assert_eq!(outcome.status, Status::Blocked);
        assert_eq!(outcome.response(), "Blocked: no token");
        assert!(Outcome::from_args(&json!({"status": "maybe", "summary": "x"})).is_err());
        assert!(Outcome::from_args(&json!({"status": "completed"})).is_err());
        assert!(Outcome::from_args(&json!({})).is_err());
    }

    #[test]
    fn finds_the_last_successful_report() {
        let call = |id: &str, status: &str| ToolCall {
            id: id.into(),
            name: TOOL_NAME.into(),
            arguments: json!({"status": status, "summary": id}),
            item_id: None,
            malformed_arguments: None,
        };
        let messages = vec![
            Message::user("go"),
            Message::assistant_with_tools("", vec![call("a", "blocked")]),
            Message::tool_result("a", TOOL_NAME, "ok"),
            Message::assistant_with_tools("", vec![call("b", "completed")]),
            Message::tool_error("b", TOOL_NAME, "failed"),
        ];
        assert_eq!(Outcome::reported_in(&messages).unwrap().summary, "a");
        assert_eq!(Outcome::reported_in(&messages[..1]), None);
    }
}
