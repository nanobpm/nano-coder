---
title: "Interactive mode"
description: "Chat with the agent in your terminal: steering, queueing, keys, output and terminal status."
order: 2
section: "Using nano-coder"
---

# Interactive mode

Run `nano-coder` with no `-p` and no `--acp` to chat with the agent in your terminal. This page covers the keys, how to steer or queue messages mid-turn, what the output shows, and how nano-coder reports its state to the terminal.

## Interactive CLI Mode (default)

```bash
nano-coder
```

Starts the interactive REPL where you can chat with the agent and use slash commands.

While a turn is running you can type a message and press **Enter** to **steer** the
agent: the message is added to the conversation before the agent's next step (after the
tool calls in flight finish), so it can change course without the turn being cancelled.
A steer that arrives as the turn finishes is queued instead, and one that arrives as the
turn is cancelled is dropped (with a note showing its text).

Press **Ctrl-Enter** (or Cmd-Enter) instead to **queue** the message: it waits in a queue
and runs as a later prompt — one per turn, in the order you sent them. Ctrl-Enter needs a
terminal that reports modified keys (modifyOtherKeys or the kitty keyboard protocol, e.g.
xterm, kitty, WezTerm, Ghostty, iTerm2); elsewhere use `/queue add message`. The status
line shows how many are waiting. Edit the queue at any time
(even mid-turn) with `/queue`: `/queue` lists the waiting messages, `/queue remove N`
drops one (or several, `/queue remove N M`), `/queue edit N new text` rewrites one, and
`/queue clear` empties the queue. Steers you have sent but the agent has not read yet
show in the same list (marked `steer`, with the id from the `↪ steer #N` note), and
`remove`/`edit`/`clear` apply to them too — so a steer the running turn has made stale can
be withdrawn or rewritten before the agent's next step. A queued message is never injected while the agent is
asking for input (the `question` tool's picker owns the terminal until you answer).
Slash commands work mid-turn too, where it is safe:
- **Right away:** read-only ones (`/help`, `/tools`, `/skills`, `/providers`, `/session`, `/plan`,
  `/context`, `/trajectory` (`--json`/`--markdown`), and `/mode` or `/verbosity` without an
  argument) show the current state. `/plan` shows the plan as the agent updates it.
- **From the agent's next step:** `/mode NAME` applies when the agent takes its next step.
- **From the next model call:** `/model provider/model` switches model mid-turn — even in
  the middle of a tool loop (the history carries over) — applied just before the agent's
  next model call.
- **Right away (for the rest of the turn):** `/verbosity LEVEL` changes the output level
  immediately, so it affects the remaining events streamed by the current turn.
- **After the turn:** commands that change the conversation or take over the keyboard
  (`/compact`, `/restart`, `/settings`, the bare `/model` picker, `/exit`) wait for the
  turn to finish.

**Esc Esc** (twice within a second) or **Ctrl-C** cancels
the running turn, killing any running bash command; a second Ctrl-C at the prompt exits.
At the idle prompt, **Esc Esc** instead clears the input, so a half-typed or pasted prompt
can be discarded without deleting it character by character; while background sub-agents run,
it also stops them.
With piped (non-terminal) stdin, lines read during a turn are queued as later prompts
(never steer).

**Ctrl-O** (at the prompt or mid-turn) expands collapsed tool calls, tool results and
thinking blocks, a batch (about two screens' worth) at a time going up from the bottom,
and re-draws the transcript so they are expanded in the scrollback too. If what you
scrolled back to is still collapsed, press Ctrl-O again to reach further back; once
everything is expanded, the next Ctrl-O collapses it all. Switching to `verbose` (or
`debug`) expands the existing results as well as later ones, and switching back
collapses them. The expanded text is not kept in memory: it lives in a temporary file
that is removed when nano-coder exits (without one, only the latest 4 MB of it).

## Output and Verbosity

In the interactive CLI, answers stream in as the model writes them. Output detail is set
with `/verbosity`, `--verbosity`, or `verbosity` in the config (default `normal`):

| Level | Shows |
|-------|-------|
| `quiet` | Final answers only |
| `normal` | Streamed answers, collapsed thinking, one line per tool call and its result |
| `verbose` | Also the first lines of each tool's output |
| `debug` | Also lifecycle hook events (`[hook] ...`) |

**Thinking.** Reasoning shows as a single collapsed line while it streams and becomes
`∴ Thought for 3.1s · 812 chars` when the answer starts. Reasoning is read
from `reasoning_content` / `reasoning` fields (DeepSeek, llama.cpp, vLLM, OpenRouter, Ollama),
from `<think>...</think>` in the content, and from Anthropic `thinking` blocks. Anthropic
thinking blocks are kept with the conversation so tool use keeps working when thinking is
enabled (e.g. `extra_body = { thinking = { type = "enabled", budget_tokens = 4000 } }`).

**Tool calls** show as `● bash ls -la`, then `⎿` with the first line of the result (or the
error).

**Input.** On a terminal, input is read key by key. While a turn runs, what you type shows
in the input editor; Enter sends it to steer the running turn, Ctrl-Enter (or Cmd-Enter)
adds it to the message queue (one queued message runs per following turn; `/queue` lists,
edits and removes them), and Esc Esc or Ctrl-C cancels the turn. The prompt supports
editing: Left/Right move the cursor, Home/End (or Ctrl-A/Ctrl-E) jump to the start/end,
Alt/Option-Left/Right (or Alt-B/Alt-F) move by word, and Up/Down recall submitted lines from
the session's input history (Down past the newest restores what you were typing; history keeps up to 200 entries and 512 KiB, and a single prompt over 512 KiB is not recalled). A resumed session (`--resume`, `/resume`, `/relaunch`) recalls the prompts typed before the resume; prompts sent by another session are not included. The mouse is never captured, so the
terminal keeps its native behaviour — the wheel scrolls the scrollback and drag selects text. Backspace and Delete remove the character before/under the cursor, Ctrl-U clears the
input, Ctrl-W deletes the word before the cursor, and Esc Esc (twice within a second)
clears the whole input at the prompt. At the prompt between turns,
Ctrl-Enter (or Cmd-Enter) inserts a newline without sending, and pasted text keeps its line breaks as a single multi-line input
instead of sending line by line. Ctrl-D exits on an empty line.

Streaming uses server-sent events. Set `stream = false` on a provider whose endpoint doesn't
support it. ACP mode doesn't stream text, but sends each response's reasoning as an
`agent_thought_chunk` update.

Every message (your prompt, answers, tool calls and results, thinking, notes) starts with
the local time as `HH:MM:SS`. The prompt's time is rewritten when you press Enter, so it
shows when the message was sent. Turn this off with `timestamps = false`.

**Renderer.** In a terminal nano-coder uses an **app-owned frame renderer**: it composes the whole screen — transcript, input
editor, then the status bar as the last line — into one frame and diff-renders it through a
single writer, wrapped in synchronized-output markers so a half-drawn frame is never visible.
On a width change it re-renders the entire frame (clearing the screen and scrollback) instead
of relying on the terminal's native reflow, and resizes are debounced (~40ms) so a drag
settles on one clean redraw. The `/` command menu is drawn under the input editor as part of
the frame. The prompt shows whose turn it is: a green `›` with a dim `ready` hint
when nano-coder is waiting for you, and a spinner with `working 12s · Enter steers, Esc Esc
cancels` while a turn runs (the hint shows while the input is empty). The `working` count is
working time, not wall time: while the turn is blocked waiting for a picker — the agent
asking a question, or the turn-cap prompt — the clock pauses, so the time you spend
answering does not inflate it. It never captures the mouse. When stdout is not a terminal
(piped or redirected), output is plain text instead. The scroll-region `renderer = "legacy"`
option was removed; a config that still sets `renderer` loads, with a one-line notice.

## Terminal Status

The interactive CLI tells the terminal what the session is doing with the
[Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status)
(OSC 7501), so a terminal that supports it (e.g. Rex) can show it in tabs, session
pickers or notifications; other terminals ignore it. Every report says `app=nano-coder`
and carries the session's [handle](messaging.md#session-handles) as its title when one is set:

- `working` while a turn runs (also while background sub-agents run at the prompt);
- `blocked` while it waits on you: `kind=question` for a question or a peer-message
  confirmation, `kind=permission` for an approval (going past the turn cap, reading
  another workspace's session), `kind=auth` during `--login`, with the question as the
  message;
- `done` after a turn, with the answer's first line, until you type; then `idle`;
- `error` when a turn failed, with the reason;
- the record is cleared when you quit.

A report is sent only when it changes, and again after `/resume` or a failed
`/relaunch`. Reports go through the terminal renderer, so they never split other
output, and only when stdout is a terminal: headless runs (`-p`, `--acp`, piped
output) and a nano-coder started from the bash tool send nothing. Inside tmux they
are wrapped for tmux's passthrough when `allow-passthrough` is `on` or `all`
(`set -g allow-passthrough on`), and skipped otherwise. Inside Herdr they are sent
as well as the Herdr reports below. Turn them off with `program_status = false`
under `[terminal]`.
