//! The `question` tool: the model asks the user a structured question and
//! blocks until it is answered, without ending its turn.
//!
//! The tool handler runs on the blocking pool (see
//! [`ToolRegistry::execute_blocking`]), so it can park on a channel while the
//! turn loop — which owns the terminal — renders the question and resolves it.
//! In auto mode the turn loop answers automatically after a timeout instead of
//! prompting ("the user is away from the keyboard").

use std::sync::{Arc, Mutex};

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{oneshot, watch};

use crate::tools::ToolDefinition;

pub const TOOL_NAME: &str = "question";

/// One option the user can pick.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

/// A single question with its choices.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Question {
    pub question: String,
    /// Very short label for the header/tab.
    #[serde(default)]
    pub header: String,
    #[serde(default)]
    pub options: Vec<QuestionOption>,
    /// Allow a free-text "type your own answer" choice (default true).
    #[serde(default = "default_custom")]
    pub custom: bool,
}

fn default_custom() -> bool {
    true
}

/// A pending `question` call: the parsed questions plus the way back to the
/// blocked tool.
pub struct QuestionRequest {
    pub questions: Vec<Question>,
    /// The turn loop listens on this to learn a question is waiting.
    notify: watch::Sender<bool>,
    /// The answer goes back over this oneshot to the blocked handler.
    answer_tx: Mutex<Option<oneshot::Sender<QuestionAnswer>>>,
}

/// How a question resolves: the user's answers (one string per question), an
/// automatic away answer, or a dismissal.
#[derive(Debug, Clone, PartialEq)]
pub enum QuestionAnswer {
    /// One answer string per question.
    Answers(Vec<String>),
    /// Auto mode answered because the user is away.
    Away,
    /// The user dismissed the question (Esc).
    Dismissed,
}

/// Shared broker between the blocking `question` tool and the turn loop.
/// Cheap to clone.
#[derive(Clone)]
pub struct QuestionBroker {
    pending: Arc<Mutex<Option<Arc<QuestionRequest>>>>,
    notify: watch::Sender<bool>,
    cap: Arc<CapBroker>,
    /// Whether anything will answer questions (the interactive CLI). When
    /// false — ACP/headless — `question` returns an error instead of blocking.
    interactive: Arc<std::sync::atomic::AtomicBool>,
}

impl Default for QuestionBroker {
    fn default() -> Self {
        Self {
            pending: Arc::new(Mutex::new(None)),
            notify: watch::channel(false).0,
            cap: Arc::new(CapBroker::default()),
            interactive: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }
}

impl QuestionBroker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a question and block the calling thread until it is answered.
    /// Called from the tool handler on the blocking pool.
    pub fn ask_blocking(&self, questions: Vec<Question>) -> QuestionAnswer {
        let (answer_tx, answer_rx) = oneshot::channel();
        let request = Arc::new(QuestionRequest {
            questions,
            notify: self.notify.clone(),
            answer_tx: Mutex::new(Some(answer_tx)),
        });
        *self.pending.lock().unwrap() = Some(request.clone());
        // Signal (and keep signalling) that a question is waiting.
        let _ = request.notify.send(true);
        // Park until the turn loop resolves us. The oneshot never errors while
        // the broker is alive, but a dropped sender means "shut down": treat as
        // dismissed.
        let answer = answer_rx.blocking_recv().unwrap_or(QuestionAnswer::Dismissed);
        *self.pending.lock().unwrap() = None;
        answer
    }

    /// The pending request, if a question is waiting for an answer.
    pub fn pending(&self) -> Option<Arc<QuestionRequest>> {
        self.pending.lock().unwrap().clone()
    }

    /// Subscribe to question-waiting notifications (`true` when one arrives).
    pub fn subscribe(&self) -> watch::Receiver<bool> {
        self.notify.subscribe()
    }

    /// Resolve the pending question (no-op when none is waiting).
    pub fn resolve(&self, answer: QuestionAnswer) {
        let request = self.pending.lock().unwrap().take();
        if let Some(request) = request
            && let Some(tx) = request.answer_tx.lock().unwrap().take()
        {
            let _ = tx.send(answer);
        }
    }

    /// The turn-cap rendezvous.
    pub fn cap(&self) -> CapBroker {
        (*self.cap).clone()
    }

    /// Mark that the interactive CLI will answer questions.
    pub fn set_interactive(&self, interactive: bool) {
        self.interactive.store(interactive, std::sync::atomic::Ordering::SeqCst);
    }

    /// Whether anything will answer questions.
    pub fn is_interactive(&self) -> bool {
        self.interactive.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// Whether to keep going when the turn cap is reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapDecision {
    /// Extend the budget by another `max_iterations`.
    Continue,
    /// Stop the turn now.
    Stop,
}

/// Rendezvous for the turn cap: the agent parks on a oneshot when it reaches
/// the cap in normal mode; the turn loop prompts and decides.
#[derive(Clone, Default)]
pub struct CapBroker {
    notify: watch::Sender<bool>,
    decision: Arc<Mutex<Option<oneshot::Sender<CapDecision>>>>,
}

impl CapBroker {
    /// Called by the agent at the cap: signal and await the decision.
    pub async fn wait(&self) -> CapDecision {
        let (tx, rx) = oneshot::channel();
        *self.decision.lock().unwrap() = Some(tx);
        let _ = self.notify.send(true);
        rx.await.unwrap_or(CapDecision::Stop)
    }

    /// Subscribe to cap-reached notifications.
    pub fn subscribe(&self) -> watch::Receiver<bool> {
        self.notify.subscribe()
    }

    /// Resolve a pending cap wait (no-op when none).
    pub fn decide(&self, decision: CapDecision) {
        if let Some(tx) = self.decision.lock().unwrap().take() {
            let _ = tx.send(decision);
        }
    }
}

impl QuestionRequest {
    /// The questions, for the turn loop to render.
    pub fn questions(&self) -> &[Question] {
        &self.questions
    }
}

/// Parse the tool's arguments into questions, tolerating a JSON-string body.
pub fn parse(args: &Value) -> Result<Vec<Question>> {
    let parsed;
    let args = match args {
        Value::String(text) => {
            parsed = serde_json::from_str::<Value>(text).unwrap_or(Value::Null);
            &parsed
        }
        other => other,
    };
    let list = args.get("questions").and_then(Value::as_array).cloned().unwrap_or_default();
    if list.is_empty() {
        bail!("question needs a non-empty `questions` array");
    }
    let mut questions = Vec::new();
    for item in list {
        let question: Question = serde_json::from_value(item)?;
        if question.question.trim().is_empty() {
            bail!("each question needs non-empty `question` text");
        }
        if !question.custom && question.options.is_empty() {
            // Without options and without a custom answer there is nothing to
            // present; the picker would build a selection with no choices.
            bail!("a question with `custom: false` needs at least one option");
        }
        questions.push(question);
    }
    Ok(questions)
}

/// The tool result text for an answer.
pub fn result_text(questions: &[Question], answer: &QuestionAnswer) -> String {
    match answer {
        QuestionAnswer::Away => {
            "The user is away from the keyboard; make the best decision you can and continue.".to_string()
        }
        QuestionAnswer::Dismissed => {
            "The user dismissed this question without answering; make the best decision you can and continue."
                .to_string()
        }
        QuestionAnswer::Answers(answers) => {
            let formatted = questions
                .iter()
                .enumerate()
                .map(|(i, q)| {
                    let answer = answers.get(i).filter(|a| !a.is_empty()).cloned().unwrap_or_else(|| "Unanswered".into());
                    format!("\"{}\"=\"{answer}\"", q.question)
                })
                .collect::<Vec<_>>()
                .join(", ");
            format!("User has answered your questions: {formatted}. Continue with the answers in mind.")
        }
    }
}

pub fn definition() -> ToolDefinition {
    ToolDefinition::new(
        TOOL_NAME,
        "Ask the user a question and wait for the answer, without ending your turn. Use when you need a \
         decision, preference, or clarification to proceed. Offer the likely choices as `options` (put a \
         recommended option first, with \"(Recommended)\" in its label); the user can also type a custom \
         answer. Do not use this for a final answer — use report_outcome when the task is done or blocked.",
        json!({
            "type": "object",
            "properties": {
                "questions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "question": { "type": "string", "description": "The complete question to ask" },
                            "header": { "type": "string", "description": "Very short label (max 30 chars)" },
                            "options": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "label": { "type": "string" },
                                        "description": { "type": "string" }
                                    },
                                    "required": ["label"]
                                }
                            },
                            "custom": { "type": "boolean", "description": "Allow a custom typed answer (default true)" }
                        },
                        "required": ["question"]
                    }
                }
            },
            "required": ["questions"]
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_questions_and_requires_text() {
        let args = json!({ "questions": [ { "question": "Which DB?", "options": [ {"label": "Postgres"}, {"label": "SQLite"} ] } ] });
        let questions = parse(&args).unwrap();
        assert_eq!(questions.len(), 1);
        assert_eq!(questions[0].question, "Which DB?");
        assert_eq!(questions[0].options.len(), 2);
        assert!(questions[0].custom, "custom defaults to true");

        assert!(parse(&json!({ "questions": [] })).is_err(), "empty array rejected");
        assert!(parse(&json!({ "questions": [ { "question": "  " } ] })).is_err(), "blank text rejected");

        // `custom: false` with no options has nothing to present.
        assert!(
            parse(&json!({ "questions": [ { "question": "Pick", "custom": false } ] })).is_err(),
            "non-custom question without options rejected"
        );
        assert!(
            parse(&json!({ "questions": [ { "question": "Pick", "custom": false, "options": [ {"label": "A"} ] } ] })).is_ok(),
            "non-custom question with an option accepted"
        );
    }

    #[test]
    fn ask_blocks_until_resolved() {
        let broker = QuestionBroker::new();
        let worker = broker.clone();
        let handle = std::thread::spawn(move || worker.ask_blocking(vec![Question {
            question: "Proceed?".into(),
            header: String::new(),
            options: vec![],
            custom: true,
        }]));
        // Wait for the request to register, then answer it from this side.
        let request = loop {
            if let Some(request) = broker.pending() {
                break request;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        };
        assert_eq!(request.questions[0].question, "Proceed?");
        broker.resolve(QuestionAnswer::Answers(vec!["yes".into()]));
        let answer = handle.join().unwrap();
        assert_eq!(answer, QuestionAnswer::Answers(vec!["yes".into()]));
        assert!(broker.pending().is_none(), "pending cleared after answering");
    }

    #[test]
    fn away_and_dismissed_have_stable_wording() {
        let questions = vec![Question { question: "Q".into(), header: String::new(), options: vec![], custom: true }];
        assert!(result_text(&questions, &QuestionAnswer::Away).contains("away from the keyboard"));
        assert!(result_text(&questions, &QuestionAnswer::Dismissed).contains("dismissed"));
        let answered = result_text(&questions, &QuestionAnswer::Answers(vec!["opt".into()]));
        assert!(answered.contains("\"Q\"=\"opt\""), "{answered}");
    }
}
