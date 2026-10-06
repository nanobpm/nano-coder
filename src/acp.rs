use anyhow::Result;
use serde_json::{Value, json};
use std::io::{self, Write};
use tokio::io::{AsyncBufReadExt, BufReader};

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

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
    Turn {
        id: Option<Value>,
        input_id: Option<String>,
        text: String,
    },
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

/// Enforce the terminal's `/…` invariant on an ACP prompt that no command
/// handled: `Err(note)` to reject a slash line instead of sending it to the
/// model, `Ok(text)` for the turn text (a `//…` prompt unescaped to a single
/// leading `/`, anything else passed through unchanged).
fn enforce_slash_invariant(text: String) -> Result<String, String> {
    let trimmed = text.trim();
    if trimmed.starts_with('/') && crate::commands::unescape_prompt(trimmed).is_none() {
        return Err(crate::commands::rejection(trimmed).unwrap_or_else(|| {
            // `rejection` returns None here only for a *known* command, which
            // reached this fallback because ACP doesn't implement it. Name that
            // reason rather than blaming arguments it was never given.
            let word = trimmed.split_whitespace().next().unwrap_or(trimmed);
            format!("Can't run {word}: this command is not available over ACP")
        }));
    }
    Ok(crate::commands::unescape_prompt(trimmed).map(str::to_string).unwrap_or(text))
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
            if trimmed.is_empty() {
                DuringTurn::Defer
            } else if trimmed.starts_with('/') && crate::commands::unescape_prompt(trimmed).is_none() {
                // A real slash command operates on the agent itself, so it
                // waits for the turn. A `//…` escaped prompt is an ordinary
                // message, so it steers instead (below), as the terminal does.
                DuringTurn::Defer
            } else {
                // Plain text, or a `//…` prompt unescaped to a single leading
                // `/`, steers the running turn.
                DuringTurn::Steer(crate::commands::unescape_prompt(trimmed).map(str::to_string).unwrap_or(text))
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
        AgentEvent::TextDelta { .. }
        | AgentEvent::ThinkingDelta { .. }
        | AgentEvent::Context
        | AgentEvent::Compacted => {
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
/// `_meta` for session/new and session/load: loaded instruction files,
/// on-demand (path-scoped) rules, skills, and any skill/instruction warnings.
fn session_meta(agent: &Agent) -> Value {
    let mut meta =
        json!({ "projectInstructions": agent.project_instruction_files(), "skills": agent.skills().names() });
    let on_demand = agent.on_demand_instruction_files();
    if !on_demand.is_empty() {
        meta["projectInstructionsOnDemand"] = json!(on_demand);
    }
    if !agent.skills().warnings.is_empty() {
        meta["skillWarnings"] = json!(agent.skills().warnings);
    }
    // Surface skipped imports/rules (e.g. left the repository) at session start,
    // analogous to skillWarnings, so an ACP client sees the same safety notices
    // the interactive banner and `/context` show.
    let instruction_warnings = agent.instruction_warnings();
    if !instruction_warnings.is_empty() {
        meta["instructionWarnings"] = json!(instruction_warnings);
    }
    meta
}

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
                // Any `/…` prompt that no ACP command handled gets the same
                // treatment as terminal input: a `//…` prompt is unescaped
                // (one leading `/` removed), and every other slash line is
                // rejected here instead of being sent to the model as a turn.
                // This covers deferred prompts too, since they are re-run
                // through `handle_message` from the turn loop.
                None => match enforce_slash_invariant(prompt_text(&params)) {
                    Err(note) => match id {
                        Some(id) => {
                            Action::Respond(result(Some(id), json!({ "stopReason": "end_turn", "response": note })))
                        }
                        None => Action::Nothing,
                    },
                    Ok(text) => Action::Turn {
                        id: id.cloned(),
                        input_id: input_id(&params).map(str::to_string),
                        text,
                    },
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
                    // Hooks are not yet exposed over ACP (they run from the
                    // user's own Claude/nano settings, server-side); don't
                    // advertise a client-configurable hook capability.
                    "hooks": false,
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
                    let mut meta = session_meta(agent);
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
                            "_meta": session_meta(agent),
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
                let args = command.strip_prefix("/compact").unwrap_or_default();
                let (mode, instructions) = crate::commands::parse_compact_args(args);
                return Some(match agent.compact(mode, instructions).await {
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
                            "mode": report.mode.as_str(),
                            "fallback": report.fallback,
                            "truncated": report.truncated,
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
                            // The value sent to the model (null: its default).
                            "temperature": agent.temperature().value(),
                            "temperature_source": agent.temperature().source.label(),
                            // The level sent to the model (null: none, the model decides).
                            "thinking": thinking_value(&agent.thinking()),
                            "thinking_source": agent.thinking().source.label(),
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

            // `/thinking` reports the level; `/thinking LEVEL` (or `reset`)
            // sets it. The bare command must be status-only — otherwise it
            // falls through to `Action::Turn` and the literal slash command is
            // sent to the model instead of reporting the current level.
            if command == "/thinking" || command.starts_with("/thinking ") {
                let arg = command.strip_prefix("/thinking").unwrap_or_default().trim();
                if !arg.is_empty() {
                    if arg.eq_ignore_ascii_case("reset") {
                        agent.set_thinking(None);
                    } else {
                        match arg.parse::<crate::thinking::Thinking>() {
                            Ok(level) => agent.set_thinking(Some(level)),
                            Err(e) => return Some(error(id, -32602, e)),
                        }
                    }
                }
                let thinking = agent.thinking();
                let mut body = json!({
                    "stopReason": "end_turn",
                    "thinking": thinking_value(&thinking),
                    "thinking_source": thinking.source.label(),
                    "thinking_levels": thinking.levels,
                });
                if let Some(warning) = thinking.warning {
                    body["warning"] = json!(warning);
                }
                return Some(result(id, body));
            }

            if command == "/providers" {
                let (user, _) = agent.config().effective_providers();
                let names: Vec<String> = providers::effective_providers(&user).into_keys().collect();
                return Some(result(id, json!({ "stopReason": "end_turn", "providers": names })));
            }

            if let Some(spec) = command.strip_prefix("/model ") {
                return Some(match agent.set_model(spec.trim()).await {
                    Ok(()) => {
                        let temp = agent.temperature();
                        let mut body = json!({
                            "stopReason": "end_turn",
                            "provider": agent.provider_name(),
                            "model": agent.model_name(),
                            // The value sent to the new model (null: its default).
                            "temperature": temp.value(),
                            "temperature_source": temp.source.label(),
                        });
                        // Surface the ignored/adjusted-setting warning so an ACP
                        // client switching to a fixed-temperature model sees the
                        // same condition as the interactive path.
                        let thinking = agent.thinking();
                        body["thinking"] = thinking_value(&thinking);
                        body["thinking_source"] = json!(thinking.source.label());
                        let warnings: Vec<String> = temp.warning.into_iter().chain(thinking.warning).collect();
                        if !warnings.is_empty() {
                            body["warning"] = json!(warnings.join("\n"));
                        }
                        result(id, body)
                    }
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

/// Returns `true` if `msg` is shaped like a JSON-RPC 2.0 request/notification:
/// an object carrying `"jsonrpc": "2.0"` and a string `method`. Bare JSON
/// values such as `{}`, `null`, or `42` are rejected so that non-ACP input is
/// not mistaken for a valid ACP session.
fn is_jsonrpc_request(msg: &Value) -> bool {
    msg.get("jsonrpc").and_then(Value::as_str) == Some("2.0") && msg.get("method").and_then(Value::as_str).is_some()
}

/// Run the ACP protocol loop. Stdin is read concurrently with turns so that
/// `session/cancel` and steering prompts reach a running turn.
///
/// Returns `true` if at least one valid JSON-RPC request was received on
/// stdin. Returns `false` when stdin reached EOF without a single parseable
/// request (e.g. the client isn't speaking ACP), so the caller can exit
/// non-zero instead of masking a misconfiguration as success.
pub async fn run_acp(agent: &mut Agent) -> Result<bool> {
    agent.set_event_sink(Box::new(|session_id, event| {
        if let Some(update) = update_for(event) {
            send_notification("session/update", json!({ "sessionId": session_id, "update": update }));
        }
    }));

    // Set once any line parses into a valid JSON-RPC message.
    let saw_valid = Arc::new(AtomicBool::new(false));

    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    let reader_saw_valid = Arc::clone(&saw_valid);
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        let mut first_line = true;
        while let Ok(Some(line)) = lines.next_line().await {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            match serde_json::from_str::<Value>(line) {
                Ok(msg) => {
                    // Only count input that actually looks like a JSON-RPC
                    // request as "valid ACP": arbitrary valid JSON such as
                    // `{}` or `null` is a no-op for `handle_message`, so a
                    // non-ACP client that happens to emit valid JSON must not
                    // be reported as a successful ACP session.
                    if is_jsonrpc_request(&msg) {
                        reader_saw_valid.store(true, Ordering::Relaxed);
                    }
                    if tx.send(msg).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    // A non-JSON first line usually means the client isn't
                    // speaking ACP at all; say so plainly instead of only
                    // surfacing a serde byte position.
                    if first_line {
                        eprintln!(
                            "input doesn't look like ACP JSON-RPC (expected JSON-RPC 2.0, one message per line): {e}"
                        );
                    } else {
                        eprintln!("ACP parse error: {e}");
                    }
                }
            }
            first_line = false;
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
    Ok(saw_valid.load(Ordering::Relaxed))
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
        // A steer unescaped from `//…` (so its text starts with `/`) must be
        // re-escaped when requeued as a prompt, or `handle_message` would
        // reject it as a slash command instead of unescaping it back to the
        // message the user sent — matching the terminal's requeue path.
        let text = if steer.text.starts_with('/') { format!("/{}", steer.text) } else { steer.text };
        let mut prompt = json!({
            "jsonrpc": "2.0",
            "method": "session/prompt",
            "params": { "sessionId": active, "prompt": [{ "type": "text", "text": text }] },
        });
        if let Some(tag) = steer.tag {
            prompt["id"] = tag;
        }
        deferred.insert(mark.min(deferred.len()), prompt);
    }
}

/// The thinking level sent, for ACP replies: the level name, `"off"`, or null
/// when none is sent. An `extra_body` override sends its own value rather than
/// the configured level, so null is reported then too — the generated level
/// never reaches the wire.
fn thinking_value(resolved: &crate::thinking::Resolved) -> serde_json::Value {
    match &resolved.effective {
        _ if resolved.overridden => serde_json::Value::Null,
        // `drop_params` strips the generated field after the body is built, so
        // the level never reaches the wire either; report none then too.
        _ if resolved.dropped => serde_json::Value::Null,
        crate::thinking::Thinking::Default => serde_json::Value::Null,
        other => json!(other.to_string()),
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
        deferred
            .push_back(json!({"method": "session/prompt", "params": {"prompt": [{"type": "text", "text": "/plan"}]}}));
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

    #[test]
    fn thinking_value_reports_nothing_for_a_dropped_level() {
        // `drop_params` strips the generated field after the body is built, so
        // the level never reaches the wire. ACP must report null — like an
        // extra_body override — not the configured level that was dropped.
        let provider: crate::providers::ProviderConfig =
            toml::from_str("drop_params = [\"reasoning_effort\"]").unwrap();
        let dropped = crate::thinking::resolve(
            &crate::thinking::Thinking::Default,
            Some(&crate::thinking::Thinking::Level("high".into())),
            Some(crate::providers::ProviderKind::Openai),
            &provider,
            "gpt-5",
        );
        assert!(dropped.dropped, "the reasoning_effort field is dropped");
        assert_eq!(thinking_value(&dropped), serde_json::Value::Null, "a dropped level is reported as null");

        // The same level with nothing dropped still reports its name.
        let sent = crate::thinking::resolve(
            &crate::thinking::Thinking::Default,
            Some(&crate::thinking::Thinking::Level("high".into())),
            Some(crate::providers::ProviderKind::Openai),
            &crate::providers::ProviderConfig::default(),
            "gpt-5",
        );
        assert!(!sent.dropped);
        assert_eq!(thinking_value(&sent), json!("high"));
    }

    #[test]
    fn slash_prompts_never_reach_the_model_over_acp() {
        // Unknown command: rejected with a suggestion, not sent as a turn.
        let note = enforce_slash_invariant("/exin".to_string()).unwrap_err();
        assert!(note.starts_with("Unknown command /exin. Did you mean /exit?"), "{note}");
        // A known command ACP doesn't implement is rejected as unavailable
        // over ACP — not blamed for arguments it never had.
        let help = enforce_slash_invariant("/help".to_string()).unwrap_err();
        assert_eq!(help, "Can't run /help: this command is not available over ACP");
        // Even with trailing arguments, a known unimplemented command reports
        // the real reason rather than "unexpected arguments".
        assert_eq!(
            enforce_slash_invariant("/help me".to_string()).unwrap_err(),
            "Can't run /help: this command is not available over ACP"
        );
        // A path-like slash line is rejected with the `//` escape hint.
        assert!(enforce_slash_invariant("/usr/lib is big".to_string()).unwrap_err().contains("type //usr/lib"));
        // Leading whitespace doesn't smuggle a slash line past the check.
        assert!(enforce_slash_invariant("  /exin".to_string()).is_err());
        // `//…` is an escaped prompt: the turn sees it with one `/` removed.
        assert_eq!(enforce_slash_invariant("//usr/lib is big".to_string()).unwrap(), "/usr/lib is big");
        // Plain prompts pass through untouched (verbatim, including whitespace).
        assert_eq!(enforce_slash_invariant("hello world\n".to_string()).unwrap(), "hello world\n");
    }

    #[test]
    fn escaped_prompts_steer_mid_turn_while_commands_defer() {
        let prompt = |t: &str| json!({"method": "session/prompt", "params": {"prompt": [{"type": "text", "text": t}]}});
        // A `//…` escaped prompt steers the running turn, unescaped to one `/`,
        // instead of waiting for the turn and starting a separate one.
        match classify_during_turn(&prompt("//usr/lib is big"), None) {
            DuringTurn::Steer(t) => assert_eq!(t, "/usr/lib is big"),
            _ => panic!("escaped prompt should steer mid-turn"),
        }
        // Plain text steers verbatim.
        match classify_during_turn(&prompt("keep going"), None) {
            DuringTurn::Steer(t) => assert_eq!(t, "keep going"),
            _ => panic!("plain text should steer"),
        }
        // A real slash command waits for the turn; an empty prompt defers.
        assert!(matches!(classify_during_turn(&prompt("/plan"), None), DuringTurn::Defer));
        assert!(matches!(classify_during_turn(&prompt("   "), None), DuringTurn::Defer));
    }

    #[test]
    fn requeued_escaped_steers_are_re_escaped() {
        // A steer unescaped from `//…` that missed its turn is requeued with
        // its `/` restored, so `handle_message` unescapes it back to a prompt
        // rather than rejecting it as an unknown slash command.
        let mut deferred: VecDeque<Value> = VecDeque::new();
        requeue_steers(&mut deferred, vec![steer("/usr/lib is big", 1)], &[0], Some("s"));
        assert_eq!(prompt_text(&deferred[0]["params"]), "//usr/lib is big");
        // Plain-text steers are requeued verbatim.
        let mut deferred: VecDeque<Value> = VecDeque::new();
        requeue_steers(&mut deferred, vec![steer("keep going", 2)], &[0], Some("s"));
        assert_eq!(prompt_text(&deferred[0]["params"]), "keep going");
    }

    #[test]
    fn only_jsonrpc_requests_count_as_valid_acp() {
        // Genuine JSON-RPC requests/notifications are accepted.
        assert!(is_jsonrpc_request(&json!({"jsonrpc": "2.0", "method": "initialize", "id": 1})));
        assert!(is_jsonrpc_request(&json!({"jsonrpc": "2.0", "method": "session/cancel"})));

        // Arbitrary valid JSON that isn't an ACP request must be rejected, so a
        // non-ACP client emitting valid JSON isn't reported as success.
        assert!(!is_jsonrpc_request(&json!({})));
        assert!(!is_jsonrpc_request(&Value::Null));
        assert!(!is_jsonrpc_request(&json!(42)));
        assert!(!is_jsonrpc_request(&json!({"method": "initialize"})));
        assert!(!is_jsonrpc_request(&json!({"jsonrpc": "2.0"})));
        assert!(!is_jsonrpc_request(&json!({"jsonrpc": "2.0", "method": 1})));
    }
}
