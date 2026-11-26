---
title: "Context and compaction"
description: "The status line, manual and automatic compaction, smart compaction and cross-session history."
order: 8
section: "Using nano-coder"
---

# Context and compaction

A long session fills the model's context window. nano-coder shows how full it is and summarizes older messages to make room.

## Status Line and Compaction

In an interactive terminal the bottom row shows the provider/model, the working directory
(home shown as `~`; on a narrow terminal the middle directories collapse to `…`, as in
`~/…/src/providers`, before other items are dropped), context usage
(`~` marks an estimate; without it the figure is anchored to the provider's reported usage),
a fill bar, message count, session input/output tokens, the auto-compaction threshold and
count (labelled `smart-compact` when compactions are smart, else `auto-compact`), the active mode when it is `plan` or `auto` (the default `normal` is not shown, to
save space), and what the agent is doing. With a GitHub Copilot model it also shows the session's
AI Credits (`0.4 AIC`), summed from the `total_nano_aiu` each response reports. Token and
AIC totals include sub-agents as they run: each model call a running or background sub-agent
makes (compactions included) moves them, and its final usage is counted once when it finishes.
A request interrupted before the provider reported its usage (a cancel, a dropped stream) is
left out rather than estimated; a sub-agent's result says how many (`N interrupted requests
not counted`). The frame
renderer draws the bar as the frame's final row; it follows resizes, and is off when stdin/stdout isn't a TTY or `AGENTIC_NO_STATUS` is set. The conversation is kept
directly above the status line (empty space collects at the top), so shrinking the window
drops empty rows rather than pushing the conversation out of view.

The context window comes from, in order: `context_window` in the config, `context_window`
on the provider, the window the endpoint reports, a built-in table of known models, then
128k. `/context` shows which one applied. If a provider rejects a request as too long, the
harness takes the limit from the error, compacts, and retries once.

The endpoint is asked at startup and on `/model` (at most 5 seconds; skipped when config
sets the window). The window a server has *loaded* is preferred over the model's maximum:

| Server | Source |
|---|---|
| vLLM | `/v1/models` `max_model_len` |
| DwarfStar ds4, OpenRouter, Together, Kimi | `/models` `context_length` |
| Groq / Mistral | `/models` `context_window` / `max_context_length` |
| llama.cpp | `/props` `n_ctx` (per slot) |
| LM Studio | `/api/v0/models` `loaded_context_length` |
| Ollama | `/api/ps` for a loaded model, else `num_ctx`; never the model maximum, since Ollama runs with a smaller default |
| GitHub Copilot | `/models` `max_prompt_tokens` |

Compaction asks the current model to summarize older messages, keeping the recent tail
(up to 20k tokens, never starting at a tool result). Auto-compaction runs before a model
call when usage passes the threshold, or earlier if the prompt would leave less than the
reserved output room (`MIN_OUTPUT_RESERVE`, plus an estimation margin) within the window.
It won't run again until the context has grown by
another 10% of the window, so a context that can't shrink isn't summarized on every call.
If summarizing fails, the older messages are dropped with a note. The session log records
the new conversation, so `--resume` continues from it.

### Smart compaction

A summary is lossy: whatever it leaves out is gone for the agent, even though the session
log still has every original message. Smart compaction keeps the whole history reachable.
It is the default (`compaction_mode = "smart"`); set `compaction_mode = "standard"` for plain
summaries, or override one compaction with `/compact --standard` or `--smart`. It needs a
session log, and falls back to a standard summary when `persist_sessions` is off.

- **Message IDs.** A message's ID is the line of the session log where it was first
  recorded, shown as `#N`. IDs are stable across compactions and `--resume`.
- **Recorded detail.** Each assistant message in the log also keeps the model's reasoning
  text (`thinking`), the request's token `usage` and its wall-clock `duration_ms`. These
  are for inspecting a session later (see #57) and `history_read`, which includes the
  reasoning. These recorded log fields themselves are never sent back to the model. This
  is separate from `replay_reasoning` (see above): when a provider has reasoning replay
  enabled, its reasoning blocks are still returned to the model as that provider requires.
- **Citing summary.** The summarizer sees each message labelled `[#N]` and is asked to cite
  `(#N)` for details whose exact text may matter (errors, commands, outputs, the user's
  wording) instead of copying them. The summary ends with the range it covers and a note
  that the originals can be retrieved. Tool results clipped at compaction point at their ID.
- **History tools.** Once a smart summary is in the context, the agent gets two tools
  over the current session's log (and only that one):
  - `history_search(pattern, role?, before?, after?, order?, limit?, session?)` - case-insensitive
    regex (or plain text) search. Newest first by default (`order=oldest` for early
    history); each matching message is one `#N role name (time): snippet` line with up to
    three snippets (and a `[K matches]` count when more matched). Earlier history lookups
    are not searched.
  - `history_read(id, max_output_length?, session?)` - one message in full, bounded like other tool
    output (the whole is spilled to a file when it is longer). With `node` instead of `id` it expands
    a layered summary node (see below).
  Before a smart compaction the tools are not offered, so they cost nothing.

**Extract mode** (`compaction_mode = "extract"`, or `/compact --extract`) is smart
compaction whose summary is built in code instead of by the model: no request, so it
costs no tokens and takes milliseconds. It lists the files touched, the shell commands
and how they ended, error lines and links, and the agent's last words before compacting,
each with its `(#N)`, plus the pinned requests and the plan as usual. It says where
things are rather than what they mean, so the agent leans on the history tools. An
earlier extract summary is merged rather than nested, so each section stays capped. See
[#273](https://github.com/nanobpm/nano-coder/issues/273) for its measurement against smart.

**Layered summaries** (`compaction_summary_dag = true`, issue
[#274](https://github.com/nanobpm/nano-coder/issues/274)) stop smart and extract compaction from
re-summarising the previous summary. Each compaction summarises only the new span into a
*node*, shown under a header such as `[[node S7 level=1 range=#2-#300 children=S1,S2]]`, and
carries the older nodes forward verbatim. When the nodes' text outgrows about a tenth of the
context window, the oldest six are condensed into one node a level up: one extra model call
(none in extract mode, which condenses in code), at most once per compaction. So the summary
grows only logarithmically with session length, and early detail stays one lookup away:
`history_read(node="S7")` expands a node to the nodes it condensed, or a level-0 node to a
one-line digest of each original message it covers; `history_search(…, node="S7")` searches
only that node's range (a node with no recorded range is an error rather than a whole-session
search). The rendered node list is capped at twice that budget in bytes: over it, each node
keeps its header and its prose is cut to an equal share. Each compaction's `replace` record lists the nodes it created under
`summary_nodes`; older records are read as before.

#### Agent-adjusted compaction

The `session_settings` tool lets the agent manage its own context (issue
[#293](https://github.com/nanobpm/nano-coder/issues/293)):

- `action: "get"` - the effective settings: nano-coder version, model, compaction mode, auto-compaction and its
  threshold, context use and window, whether the history tools are on.
- `action: "set"`, `key: "compaction_mode"`, `value: standard|smart|extract` - changes the mode
  for **this session only**. Nothing is written to `config.toml`; a resumed session starts from
  the config again. After a change, the same setting can't change again for 3 turns.
- `action: "compact_now"` (optional `mode`, `focus`) - compacts before the agent's next request,
  e.g. before reading something large or once old tool output is no longer needed. It doesn't
  change the session's mode.

Every change takes a `reason`, is shown as an `[agent] …` line and is logged as a `setting`
record; a compaction's `replace` record carries its `trigger` (`manual`, `threshold`,
`overflow`, `idle` or `agent`), which `scripts/compaction-report.py` tabulates. Security and
cost settings (permissions, sandbox, yolo, hooks, providers and keys, model, thinking) are
refused whatever the request, so a prompt injection can't loosen them. Sub-agents don't get
the tool. It is allowed in plan mode: it changes the harness, not the workspace.

#### Cross-session history

With `cross_session_history = true` (the default) the agent can also read *other* sessions'
logs, so when several nano-coder sessions run on one machine context moves between them
without copy-paste. A third tool joins the history tools, and `history_search`/`history_read`
take an optional `session` argument:

- `sessions_list(filter?, live?, messages?, limit?)` - this machine's sessions, live ones
  first, then newest first: id, title or first request, working directory, last activity,
  and `[live pid N]` when a process currently has the session open (probed with the session
  log's own lock; the pid, and `[now in DIR]` when that process has since changed
  directory, come from `/proc` on Linux). `filter` keeps sessions whose id, title or
  directory contains it (case-insensitive); `live: true` keeps open sessions and
  `messages: true` those `session_send` can reach. `limit` (default 50, max 500) caps the
  lines and the result says how many more matched. Titles are capped at 120 bytes, and a
  worker (ACP job) session whose first input is a job payload is titled
  `jobType · pik processInstanceKey`, e.g. `senior:pr-review · pik 289676`. The listing is
  also capped in bytes like any tool output.
- `session` - a handle, an id, a unique id prefix, or a title from `sessions_list` (see
  [Session handles](messaging.md#session-handles) for the order). An ambiguous match
  is an error listing the candidates; without the argument the tools read the current
  session, as before.

Reads are read-only and bounded: the other session's log is streamed like the current one
(never loaded whole, same byte caps), and a live session's log is only read — never locked,
moved or rewritten. A session whose working directory is the current workspace (or below
it) may be read outright. Reading one from another directory asks for confirmation first
(default ask): a question offers to allow it, a non-Yes answer refuses the read, and a
headless run (no one to ask) refuses it closed. The permission policy still applies as a
read of that log, so a `Read(...)` deny rule hides the session from `sessions_list`
entirely — its title and first request are never shown. With
`cross_session_history = false` there is no `sessions_list` tool, the history tools are
advertised without the `session` argument (and refuse it if called with one), and other
sessions' logs are never opened.

To judge whether it helps, the log records each compaction's `mode`, `model` and the
`summarized` line range (on the `replace` record), and each turn's `history_calls` (on
`turn_end`). `/context` shows the mode and this session's history-tool use.
`scripts/compaction-report.py [SESSION_DIR]` tabulates compacted sessions by model and mode:
compactions, turns after the first compaction, turns that used the history tools, and
reported outcomes. `eval/compaction/` has a harness that compares the two modes across
providers and models on synthetic or forked real sessions (see its README). See [#29](https://github.com/nanobpm/nano-coder/issues/29) for the design.
