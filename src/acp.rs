use anyhow::Result;
use serde_json::{json, Value};
use std::io::{self, Write};
use tokio::io::{AsyncBufReadExt, BufReader};

use std::collections::VecDeque;

use tokio::sync::mpsc;

use crate::agent::{Agent, AgentEvent, Steer, StopReason};
use crate::providers;

/// ACP protocol version
const PROTOCOL_VERSION: i32 = 1;

fn result(id: Option<&Value>, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn error(id: Option<&Value>, code: i64, message: impl std::fmt::Display) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message.to_string() } })
}

/// Input ID for idempotent prompts: `messageId`, or `_meta.inputId`.
fn input_id(params: &Value) -> Option<&str> {
    params
        .get("messageId")
        .or_else(|| params.get("_meta").and_then(|m| m.get("inputId")))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
}

/// What the run loop should do with a message.
pub enum Action {
    Respond(Value),
    /// Run a model turn for a `session/prompt`.
    Turn { id: Option<Value>, input_id: Option<String>, text: String },
    Nothing,
}

fn prompt_text(params: &Value) -> String {
    params
        .get("prompt")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect()
}

/// A message arriving while a turn runs.
enum DuringTurn {
    Cancel,
    Steer(String),
    Defer,
}

fn classify_during_turn(msg: &Value, active: Option<&str>) -> DuringTurn {
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let for_active = match params.get("sessionId").and_then(Value::as_str) {
        Some(requested) => Some(requested) == active,
        None => true,
    };
    match msg.get("method").and_then(Value::as_str) {
        Some("session/cancel") if for_active => DuringTurn::Cancel,
        Some("session/prompt") if for_active => {
            let text = prompt_text(&params);
            let trimmed = text.trim();
            // Slash commands operate on the agent itself, so they wait for the turn.
            if trimmed.is_empty() || trimmed.starts_with('/') {
                DuringTurn::Defer
            } else {
                DuringTurn::Steer(text)
            }
        }
        _ => DuringTurn::Defer,
    }
}

/// ACP tool kind, for client display.
fn tool_kind(name: &str) -> &'static str {
    match name {
        "bash" => "execute",
        "read_file" => "read",
        "write_file" | "edit_file" => "edit",
        name if crate::plan::is_plan_tool(name) || name == crate::goal::TOOL_NAME => "think",
        _ => "other",
    }
}

/// The ACP `session/update` payload for an agent event. `title` carries the
/// tool name because clients (e.g. c8ctl-nano's transcript producer) record it
/// as the tool name.
pub fn update_for(event: &AgentEvent) -> Option<Value> {
    let text = |text: &str| json!({ "type": "text", "text": text });
    Some(match event {
        AgentEvent::UserMessage { text: body } => {
            json!({ "sessionUpdate": "user_message_chunk", "content": text(body) })
        }
        AgentEvent::AssistantMessage { message_id, text: body } => json!({
            "sessionUpdate": "agent_message_chunk",
            "messageId": message_id,
            "content": text(body),
        }),
        AgentEvent::ToolCall { call } => json!({
            "sessionUpdate": "tool_call",
            "toolCallId": call.id,
            "title": call.name,
            "kind": tool_kind(&call.name),
            "status": "in_progress",
            "rawInput": call.arguments,
        }),
        AgentEvent::ToolResult { call, ok, output } => json!({
            "sessionUpdate": "tool_call_update",
            "toolCallId": call.id,
            "status": if *ok { "completed" } else { "failed" },
            "rawOutput": output,
            "content": [{ "type": "content", "content": text(output) }],
        }),
        AgentEvent::Thinking { text: body } => {
            json!({ "sessionUpdate": "agent_thought_chunk", "content": text(body) })
        }
        // `_meta.plan` carries the full plan (ids, notes, dependencies) so a
        // client can hand it back in `session/new` to continue the work.
        AgentEvent::Plan { plan } => json!({
            "sessionUpdate": "plan",
            "entries": plan.acp_entries(),
            "_meta": { "plan": plan },
        }),
        AgentEvent::TextDelta { .. } | AgentEvent::ThinkingDelta { .. } | AgentEvent::Context | AgentEvent::Compacted => {
            return None;
        }
    })
}

/// Start a session, seeded with `_meta.plan` when the client carries a plan
/// over from an earlier run. The seeded plan is echoed in the result's
/// `_meta.plan` rather than as a `session/update`, which the client could not
/// yet attribute to a session.
fn new_session(agent: &mut Agent, params: &Value) -> anyhow::Result<String> {
    let plan = match params.pointer("/_meta/plan") {
        Some(value) if !value.is_null() => Some(crate::plan::Plan::from_value(value)?),
        _ => None,
    };
    // The client already showed the model the plan (e.g. in a resume prompt).
    let announce = params.pointer("/_meta/planInPrompt").and_then(Value::as_bool) != Some(true);
    let session_id = agent.new_session()?;
    if let Some(plan) = plan {
        agent.set_plan(plan, announce)?;
    }
    Ok(session_id)
}

/// Make `params.cwd` the working directory for tools (one session per process).
fn apply_cwd(params: &Value) -> Result<(), String> {
    let Some(cwd) = params.get("cwd").and_then(Value::as_str).filter(|c| !c.is_empty()) else {
        return Ok(());
    };
    let path = std::path::Path::new(cwd);
    if !path.is_absolute() || !path.is_dir() {
        return Err(format!("cwd {cwd:?} must be an existing absolute directory"));
    }
    std::env::set_current_dir(path).map_err(|e| format!("cannot enter cwd {cwd:?}: {e}"))
}

/// Handle an ACP JSON-RPC message received while no turn is running.
pub async fn handle_message(agent: &mut Agent, msg: Value) -> Action {
    let id = msg.get("id");
    let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));
    match msg.get("method").and_then(Value::as_str) {
        Some("session/prompt") => {
            // One active session per process: refuse prompts addressed elsewhere
            // rather than writing them into the wrong conversation and log.
            if let Some(requested) = params.get("sessionId").and_then(Value::as_str)
                && agent.session_id() != Some(requested)
            {
                return Action::Respond(error(
                    id,
                    -32602,
                    format!(
                        "session {requested:?} is not active (active: {}); call session/load first",
                        agent.session_id().unwrap_or("none")
                    ),
                ));
            }
            match handle_inner(agent, &msg).await {
                Some(response) => Action::Respond(response),
                None => Action::Turn {
                    id: id.cloned(),
                    input_id: input_id(&params).map(str::to_string),
                    text: prompt_text(&params),
                },
            }
        }
        // Nothing is running; a notification gets no reply.
        Some("session/cancel") => match id {
            Some(id) => Action::Respond(result(Some(id), json!({}))),
            None => Action::Nothing,
        },
        _ => match handle_inner(agent, &msg).await {
            Some(response) => Action::Respond(response),
            None => Action::Nothing,
        },
    }
}

/// Non-turn methods and slash commands; `None` for a prompt that needs a turn.
async fn handle_inner(agent: &mut Agent, msg: &Value) -> Option<Value> {
    let method = msg.get("method").and_then(|m| m.as_str());
    let id = msg.get("id");
    let default_params = json!({});
    let params = msg.get("params").unwrap_or(&default_params);

    match method {
        Some("initialize") => Some(result(
            id,
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "agentInfo": { "name": "nano-coder", "version": env!("CARGO_PKG_VERSION") },
                "agentCapabilities": {
                    "loadSession": agent.config().persist_sessions,
                    "tools": true,
                    "hooks": true,
                    "compact": true,
                    // Extension: `session/new` accepts `_meta.plan` (see new_session).
                    "_meta": { "planSeed": agent.config().plan_tools }
                }
            }),
        )),
        Some("session/new") => Some(match apply_cwd(params) {
            Err(e) => error(id, -32602, e),
            Ok(()) => match new_session(agent, params) {
                Ok(session_id) => {
                    let mut meta = json!({ "projectInstructions": agent.project_instruction_files() });
                    if !agent.plan().is_empty() {
                        meta["plan"] = json!(agent.plan());
                    }
                    result(id, json!({ "sessionId": session_id, "_meta": meta }))
                }
                Err(e) => error(id, -32603, format!("{e:#}")),
            },
        }),
        Some("session/load") => {
            let Some(session_id) = params.get("sessionId").and_then(Value::as_str) else {
                return Some(error(id, -32602, "session/load requires params.sessionId"));
            };
            if let Err(e) = apply_cwd(params) {
                return Some(error(id, -32602, e));
            }
            Some(match agent.load_session(session_id) {
                Ok(()) => {
                    // ACP: replay the conversation before answering session/load.
                    agent.replay_history();
                    result(
                        id,
                        json!({
                            "sessionId": session_id,
                            "_meta": { "projectInstructions": agent.project_instruction_files() },
                        }),
                    )
                }
                Err(e) => error(id, -32603, format!("{e:#}")),
            })
        }
        Some("session/prompt") => {
            let prompt_text = prompt_text(params);
            let command = prompt_text.trim();

            // Handle /compact [instructions] via ACP
            if command == "/compact" || command.starts_with("/compact ") {
                let instructions = command.strip_prefix("/compact").map(str::trim).filter(|i| !i.is_empty());
                return Some(match agent.compact(instructions).await {
                    Err(e) => error(id, -32603, format!("{e:#}")),
                    Ok(None) => result(id, json!({ "stopReason": "end_turn", "compacted": false })),
                    Ok(Some(report)) => result(
                        id,
                        json!({
                            "stopReason": "end_turn",
                            "compacted": true,
                            "before": report.messages_before,
                            "after": report.messages_after,
                            "tokensBefore": report.tokens_before,
                            "tokensAfter": report.tokens_after,
                            "summarized": report.summarized,
                            "fallback": report.fallback,
                        }),
                    ),
                });
            }

            // Handle /settings command via ACP (return current settings)
            if command == "/settings" {
                let config = agent.config();
                return Some(result(
                    id,
                    json!({
                        "stopReason": "end_turn",
                        "settings": {
                            "model": config.model,
                            "provider": agent.provider_name(),
                            "provider_model": agent.model_name(),
                            "temperature": config.temperature,
                            "max_tokens": config.max_tokens,
                            "system_prompt": config.system_prompt,
                            "session_id": agent.session_id(),
                        }
                    }),
                ));
            }

            // Handle /tools command via ACP (list tools)
            if command == "/tools" {
                let tools: Vec<String> = agent.tool_definitions().into_iter().map(|d| d.name).collect();
                return Some(result(id, json!({ "stopReason": "end_turn", "tools": tools })));
            }

            if command == "/plan" {
                return Some(result(
                    id,
                    json!({ "stopReason": "end_turn", "plan": agent.plan(), "text": agent.plan().render(true, usize::MAX) }),
                ));
            }

            if command == "/providers" {
                let (user, _) = agent.config().effective_providers();
                let names: Vec<String> = providers::effective_providers(&user).into_keys().collect();
                return Some(result(id, json!({ "stopReason": "end_turn", "providers": names })));
            }

            if let Some(spec) = command.strip_prefix("/model ") {
                return Some(match agent.set_model(spec.trim()) {
                    Ok(()) => result(
                        id,
                        json!({ "stopReason": "end_turn", "provider": agent.provider_name(), "model": agent.model_name() }),
                    ),
                    Err(e) => error(id, -32602, format!("{e:#}")),
                });
            }

            None
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
    write_line(&msg);
}

fn write_line(msg: &Value) {
    let mut stdout = io::stdout().lock();
    writeln!(stdout, "{msg}").unwrap();
    stdout.flush().unwrap();
}

/// Run the ACP protocol loop. Stdin is read concurrently with turns so that
/// `session/cancel` and steering prompts reach a running turn.
pub async fn run_acp(agent: &mut Agent) -> Result<()> {
    agent.set_event_sink(Box::new(|session_id, event| {
        if let Some(update) = update_for(event) {
            send_notification("session/update", json!({ "sessionId": session_id, "update": update }));
        }
    }));

    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            match serde_json::from_str::<Value>(line) {
                Ok(msg) => {
                    if tx.send(msg).is_err() {
                        break;
                    }
                }
                Err(e) => eprintln!("ACP parse error: {e}"),
            }
        }
    });

    let mut deferred: VecDeque<Value> = VecDeque::new();
    loop {
        let msg = match deferred.pop_front() {
            Some(msg) => msg,
            None => match rx.recv().await {
                Some(msg) => msg,
                None => break,
            },
        };
        match handle_message(agent, msg).await {
            Action::Respond(response) => write_line(&response),
            Action::Nothing => {}
            Action::Turn { id, input_id, text } => {
                run_turn(agent, id, input_id, text, &mut rx, &mut deferred).await;
            }
        }
    }
    Ok(())
}

/// Run one prompt turn while routing concurrent messages: cancels and steers
/// go to the turn, everything else waits until it ends.
async fn run_turn(
    agent: &mut Agent,
    id: Option<Value>,
    input_id: Option<String>,
    text: String,
    rx: &mut mpsc::UnboundedReceiver<Value>,
    deferred: &mut VecDeque<Value>,
) {
    let control = agent.control();
    let active = agent.session_id().map(str::to_string);
    // Length of `deferred` when each steer arrived, so a steer that runs as its
    // own prompt keeps its place among messages deferred during the turn.
    let mut steer_marks: Vec<usize> = Vec::new();
    let outcome = {
        let turn = agent.run_turn(input_id.as_deref(), &text);
        tokio::pin!(turn);
        loop {
            tokio::select! {
                // Poll the turn first: its first poll resets the control, which
                // must happen before a buffered cancel or steer is routed to it.
                biased;
                outcome = &mut turn => break outcome,
                Some(msg) = rx.recv() => match classify_during_turn(&msg, active.as_deref()) {
                    DuringTurn::Cancel => {
                        control.cancel();
                        if let Some(cancel_id) = msg.get("id") {
                            write_line(&result(Some(cancel_id), json!({})));
                        }
                    }
                    DuringTurn::Steer(steer) => {
                        steer_marks.push(deferred.len());
                        control.steer(&steer, msg.get("id").cloned());
                    }
                    DuringTurn::Defer => deferred.push_back(msg),
                },
            }
        }
    };
    let (response, stop, reported) = match outcome {
        Ok(outcome) => (outcome.response, outcome.stop_reason, outcome.outcome),
        Err(e) => (format!("Error: {e:#}"), StopReason::EndTurn, None),
    };
    // A prompt sent as a notification runs but gets no reply.
    if let Some(id) = &id {
        let mut reply = json!({ "stopReason": stop.as_acp(), "response": response });
        // Extension: the model's explicit completed/blocked report.
        if let Some(reported) = reported {
            reply["_meta"] = json!({ "outcome": reported });
        }
        write_line(&result(Some(id), reply));
    }

    // Steers folded into this turn are answered by it.
    for steer in control.take_absorbed() {
        if let Some(tag) = steer.tag {
            write_line(&result(
                Some(&tag),
                json!({ "stopReason": stop.as_acp(), "_meta": { "steered": true, "inputOf": id } }),
            ));
        }
    }
    // Steers that arrived too late to join the turn: dropped on cancel,
    // otherwise run next as ordinary prompts, in arrival order.
    let leftover = control.take_pending();
    if stop == StopReason::Cancelled {
        for steer in leftover {
            if let Some(tag) = steer.tag {
                write_line(&result(Some(&tag), json!({ "stopReason": "cancelled" })));
            }
        }
    } else {
        requeue_steers(deferred, leftover, &steer_marks, active.as_deref());
    }
}

/// Queue steers that missed their turn as ordinary prompts, each at the
/// position `deferred` had when it arrived, so they run in the order the
/// client sent them relative to messages deferred during the turn
/// (tla/AgentLoop.tla, `SendOrder`). `leftover` are the last steers to arrive
/// (earlier ones were absorbed in order), so they match the tail of `marks`.
fn requeue_steers(deferred: &mut VecDeque<Value>, leftover: Vec<Steer>, marks: &[usize], active: Option<&str>) {
    let first = marks.len().saturating_sub(leftover.len());
    let placed: Vec<(usize, Steer)> = leftover
        .into_iter()
        .enumerate()
        .map(|(i, steer)| (marks.get(first + i).copied().unwrap_or(deferred.len()), steer))
        .collect();
    // Marks are nondecreasing: insert the latest first so earlier marks stay valid.
    for (mark, steer) in placed.into_iter().rev() {
        let mut prompt = json!({
            "jsonrpc": "2.0",
            "method": "session/prompt",
            "params": { "sessionId": active, "prompt": [{ "type": "text", "text": steer.text }] },
        });
        if let Some(tag) = steer.tag {
            prompt["id"] = tag;
        }
        deferred.insert(mark.min(deferred.len()), prompt);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn steer(text: &str, tag: i64) -> Steer {
        Steer { text: text.to_string(), tag: Some(json!(tag)) }
    }

    fn order(deferred: &VecDeque<Value>) -> Vec<String> {
        deferred
            .iter()
            .map(|m| match m.get("method").and_then(Value::as_str) {
                Some("session/prompt") => prompt_text(&m["params"]),
                other => other.unwrap_or_default().to_string(),
            })
            .collect()
    }

    #[test]
    fn leftover_steers_keep_their_arrival_position() {
        // Deferred before the turn: "early". During the turn: /plan, steer a,
        // session/set_mode, steer b.
        let mut deferred: VecDeque<Value> = VecDeque::from([json!({"method": "early"})]);
        let mut marks = Vec::new();
        deferred.push_back(json!({"method": "session/prompt", "params": {"prompt": [{"type": "text", "text": "/plan"}]}}));
        marks.push(deferred.len());
        deferred.push_back(json!({"method": "session/set_mode"}));
        marks.push(deferred.len());

        requeue_steers(&mut deferred, vec![steer("a", 1), steer("b", 2)], &marks, Some("s"));
        assert_eq!(order(&deferred), ["early", "/plan", "a", "session/set_mode", "b"]);
        assert_eq!(deferred[2]["id"], json!(1));
        assert_eq!(deferred[2]["params"]["sessionId"], json!("s"));
    }

    #[test]
    fn only_unabsorbed_steers_are_requeued() {
        // Three steers arrived; the first was absorbed into the turn.
        let mut deferred: VecDeque<Value> = VecDeque::new();
        let marks = [0, 0, 1];
        deferred.push_back(json!({"method": "cmd"}));
        requeue_steers(&mut deferred, vec![steer("b", 2), steer("c", 3)], &marks, None);
        assert_eq!(order(&deferred), ["b", "cmd", "c"]);
    }
}
