---
title: "Headless mode (ACP)"
description: "Run nano-coder as a headless worker over the Agent Client Protocol."
order: 3
section: "Using nano-coder"
---

# Headless mode (ACP)

`nano-coder --acp` runs without a terminal UI and speaks JSON-RPC 2.0 on stdin/stdout, so an orchestrator (for example [nano-workforce](https://github.com/nanobpm/nano-workforce)) can drive a fleet of workers.

## ACP Headless Mode (--acp flag)

```bash
nano-coder --acp
```

Speaks the Agent Communication Protocol (ACP) over stdio using newline-delimited JSON-RPC 2.0 messages. Compatible with c8ctl-nano's `spawnCaptureAcp` executor.

Shell commands run in the `workspace` [OS sandbox](permissions-sandbox.md#permissions-and-sandbox) unless a
sandbox mode is set explicitly (`--sandbox off` restores unsandboxed runs). At startup
the effective mode and its source go to stderr (`nano-coder: sandbox workspace
(default-headless)`), and the `/settings` reply carries `sandbox` and `sandbox_source`.

Inter-session messages are off in ACP mode whatever `session_messages` says; pass
`--session-messages` (or set `acp_session_messages = true`) to make the session reachable
(see [Inter-session messages](messaging.md#inter-session-messages)).

The web tools (`web_search`, `web_fetch`) are likewise off in ACP mode; pass `--web` to
offer them (and, with `[web] fetch_permission = "ask"`, to approve `web_fetch` calls no rule covers). `--no-web` turns them off in
any mode. See [Web tools](tools.md#web-tools).

**Protocol methods supported:**
- `initialize` → returns protocol version and capabilities (`loadSession` when persistence is on)
- `session/new` → starts a fresh conversation (and session log), returns sessionId.
  `params.cwd` (absolute, existing directory) becomes the working directory for tools
- `session/load` → `{ "sessionId": ... }` resumes a persisted session, first replaying the
  conversation as `session/update` notifications (as the ACP spec requires)
- `session/prompt` → processes a prompt, supports tool calls. One session is active per
  process; a `sessionId` other than the active one is rejected (use `session/load` to switch). An optional `messageId`
  (or `_meta.inputId`) makes it idempotent: redelivering an ID that already completed
  returns the recorded response without calling the model again
- `session/set_name` → `{ "name": "perf" }` sets the active session's [handle](messaging.md#session-handles)
  (`null` or `""` clears it); the result is `{ "sessionId", "name" }`, and an invalid or
  taken handle is an error. `--name` names every new or loaded session.
- `session/cancel` → cancels the current turn (normally sent as a notification, which
  gets no reply). The running model call is abandoned, a running bash command is
  killed, remaining tool calls are recorded as cancelled, and the turn's
  `session/prompt` resolves with `stopReason: "cancelled"`

**Usage.** A `session/prompt` result carries `usage` (`inputTokens`, `outputTokens`,
`totalTokens`) for the turn, including finished sub-agents, when the provider reported
tokens. When a provider reported AI Credits during the turn, `usage._meta.aic` holds the
credits the turn used (sub-agents included); it is omitted otherwise, and standard ACP
clients ignore it.

**Steering.** A `session/prompt` for the active session that arrives while a turn is
running is a steer, not a queued prompt. It is added as a user message before the next
model call (echoed as a `user_message_chunk`) and answered when the turn ends with
`{ "stopReason": ..., "_meta": { "steered": true, "inputOf": <main prompt id> } }`.
A steer that arrives too late to join the turn runs as an ordinary prompt, or is
answered with `stopReason: "cancelled"` if the turn was cancelled. Slash-command prompts
and other requests that arrive mid-turn are handled after the turn ends. Everything
handled after the turn, late steers included, runs in the order the client sent it.
`stopReason` is `end_turn`, `cancelled`, or `max_turn_requests`.

**Streaming updates.** During a turn the harness sends `session/update` notifications:
`agent_message_chunk` (with a `messageId`), `tool_call` (`toolCallId`, `title` = tool name,
`kind`, `rawInput`) and `tool_call_update` (`completed`/`failed`, `rawOutput`). These are the
events c8ctl-nano's transcript producer records into the engine's AgentInstance history.

**Project instructions.** `session/new` and `session/load` results include
`_meta.projectInstructions`: the absolute paths of the instruction files that were added to
the system prompt for the session's `cwd` (see [Project Instructions](instructions-skills.md#project-instructions)).
`_meta.skills` lists the skills found for it, and `_meta.skillWarnings` (when present) explains
any that could not be loaded (see [Skills](instructions-skills.md#skills)).

**Plans.** Each plan change sends a `plan` update: ACP `entries` (`content`, `priority`,
`status`) plus `_meta.plan`, the full plan with ids, notes and dependencies. To continue a job
on another worker, pass the last `_meta.plan` as `session/new` `params._meta.plan` (bare ACP
`entries` are accepted too). The new session starts with that plan, the `session/new` result
echoes it in `_meta.plan`, and the model is told about it with the first prompt (unless
`_meta.planInPrompt: true` says the client already put the plan in the prompt). `initialize`
advertises this as `agentCapabilities._meta.planSeed`. See [Task Plans](plans-outcomes.md#task-plans).

**Outcomes.** When the model calls `report_outcome`, the `session/prompt` result carries
`_meta.outcome`: `{"status": "completed" | "blocked" | "needs_input", "summary": "..."}`. A client can use it
instead of guessing from the stop reason: `blocked` means the model needs help (an
escalation). Redelivering the input returns the same outcome. See [Outcomes](plans-outcomes.md#outcomes).

**Slash commands work via ACP too:**
- `/compact [--smart|--standard] [focus]` - summarizes the conversation; the result has
  `compacted`, `before`, `after`, `tokensBefore`, `tokensAfter`, `summarized`, `mode`, `fallback`
  and `truncated`
- `/settings` - returns current settings as JSON
- `/tools` - lists registered tools
- `/plan` - returns `plan` (JSON) and `text` (the rendered plan)
- `/providers` - lists providers
- `/model provider/model` - switches model

**Exit status.** Normal shutdown — stdin closing after at least one valid request was
processed — exits `0`. If stdin reaches EOF without a single parseable JSON-RPC request
(e.g. the client isn't speaking ACP), the harness prints
`no valid ACP requests received on stdin …` to stderr and exits `2`, so a misconfigured
caller can't mistake a no-op run for success. A non-JSON first line is called out
explicitly (`input doesn't look like ACP JSON-RPC …`).
