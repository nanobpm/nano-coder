---
title: "Sub-agents"
description: "Hand read-only investigations to sub-agents with their own context, in the foreground or background."
order: 12
section: "Using nano-coder"
---

# Sub-agents

The `agent` tool lets the agent delegate a broad, read-only investigation to a fresh agent, so only the report enters its context.

## Sub-agents in a turn

**Sub-agents.** The `agent` tool hands a broad, read-only investigation (`task`) to a fresh agent
with its own context window; only its report (with `file:line` citations and its turns, tokens and
time) comes back. Several `agent` calls in one reply run in parallel, up to
`subagent_max_concurrency`; a call that can change files (an edit, `bash`) between them is a barrier,
so an `agent` call after it starts only once the change is made. A sub-agent has `read_file`, `grep` and `glob` (no shell, so it cannot change files); every call goes
through this session's permission policy and hooks (a denied call is an error for the sub-agent, it
never prompts), Esc/Ctrl-C stops it, and its usage counts toward the session's. Its log is written
next to the session's (`<session>/sub-<call id>.jsonl`), referenced from the `agent` result, and
expanded by `--trajectory`. When a sub-agent ends (done, cancelled or stopped), the parent session
log gets one `subagent_usage` record (`version` 1: `id`, child `log` path, `model`, `input_tokens`,
`output_tokens`, and `aic` when reported), so anything reading the parent log sees sub-agent spend.
`/trajectory` shows it as a `SUB-AGENT sub-N (model)` row and ends with a `Total:` line that counts
it once beside the main agent's usage (`--json` adds a `totals` object when there were sub-agents);
older logs without the record still load.

To give the agent a curated, cost-controlled choice of sub-agent models, list them:

```toml
[[subagent_models]]
model = "github-copilot/claude-haiku-4.5"
use   = "quick searches, reading and summarising files"
max_turns = 20                 # optional: timeout_secs, max_turns, max_tokens override subagent_*
[[subagent_models]]
model = "github-copilot/gpt-5"
use   = "harder analysis across many files"
```

The `agent` tool's `model` then becomes a choice of these (the description lists each with its
`use`), the first is the default, and a call naming another model gets an error listing them.
At startup each must resolve against the configured providers: one that doesn't (an unknown or
disabled provider, no model) is dropped with a warning, as is a malformed entry; if none is left,
sub-agents run on `subagent_model` or the session's model and a call may name any model, as without
the list. `subagents = false` starts sessions with the tool off; `/subagents on` turns it on.

## Background sub-agents

**Background sub-agents.** `agent(task, background: true)` starts the sub-agent and returns at once
with a handle (`sub-3`), its model and its limits; the agent carries on while it runs. Four tools
come with the `agent` tool:

- `agent_status(id?)`: state (queued, running, done, cancelled, truncated), turns, tool calls,
  tokens, elapsed time and its last few tool calls, for one sub-agent or all of this session's.
- `agent_read(id, since?)`: its log (messages and tool calls) from line `since`, at most 16 KB,
  ending with the `since` to continue from. The log is streamed, never loaded whole.
- `agent_cancel(id, reason)`: asks it to report what it has in one final step; that report is the
  result, marked cancelled and partial. One that can't report within 5 s is cut off with an empty
  report.
- `agent_wait(ids, timeout_s)`: blocks until they finish or the timeout passes, and returns their
  results (or their status, for ones still running).

A background result is delivered once: as a reminder before the agent's next model call, or, at the
idle prompt, as an automatic turn (like a fired timer); an `agent_wait` or `agent_cancel` that returns
it counts as delivery. Background and blocking sub-agents share `subagent_max_concurrency` (extra
ones queue). A background sub-agent may outlive the turn that started it; its tool calls are served
between the agent's steps and at the idle prompt (the plain, no-editor prompt too). Esc Esc, mid-turn
or at the idle prompt, stops every sub-agent, background ones included; `/exit`, `/restart`,
`/resume`, an ACP `session/load`, the end of a `-p` run and a relaunch stop them too (their logs stay,
and a result never delivered is recorded in the session log). Under `--acp`, which has no idle loop
to serve them between prompts, `background: true` is refused; blocking sub-agents still run. Their tool calls go through the session's policy
and hooks as above; the progress display shows them, and in Herdr the pane shows as working while
any run.
