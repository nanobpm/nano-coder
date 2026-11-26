---
title: "Session handles and messages"
description: "Name sessions and let them send each other messages."
order: 13
section: "Using nano-coder"
---

# Session handles and messages

Sessions can be named with a handle and, when enabled, send each other messages.

## Session handles

Session ids and model-written titles change or collide, so a session can take a stable,
user-chosen **handle**: `/name perf` at the prompt, or `nano-coder --name perf` at launch
(with `--resume`, `--name` renames the resumed session). `/name` alone shows it and
`/name --clear` removes it. A handle is lowercase letters, digits and `-`, at most 32
characters, and can't start with `sess-` (so it never looks like an id). A handle needs
a saved session: with `--no-session` or `persist_sessions = false` it is refused.

- **Stored with the session.** The handle is a `name` record in the session log (the last
  one wins) and is kept in the session index, so it survives `/resume`, `/relaunch` and
  `/update`; ACP clients set it with `session/set_name` (`{"name": "perf"}`, `null`
  clears) and see it as `name` in the `_meta` of `session/new` and `session/load`
  (a `--name` another running session holds fails either request). A named
  session is kept by `session_retention_days`, like a titled one.
- **Unique among running sessions.** Setting a handle a running session holds is refused,
  naming that session; a stopped session's handle can be reused. Running holders are
  recorded in the peer registry (`<peers dir>/<handle>.name`, with the holder's session
  directory, so sessions with different `session_dir`s still can't share a handle).
- **Resolution order.** `session_send`'s `to`, the history tools' `session`, `--resume` and
  `/resume` try, in order: an exact session id, a handle (a running holder first, then
  the newest stopped one), a unique id prefix, then a title. A handle always beats a title
  that happens to be the same word, and a handle can't look like a session id (`sess-…`
  is refused), so an id and a handle never compete.
- **Visible.** The status bar shows `@perf`, `/session` and the exit message show it (the
  exit message suggests `--resume=perf` when no other saved session used the handle), a
  sent message is labelled `[from perf · …]`, `sessions_list` marks it `[name: perf]`, the
  system prompt tells the agent its own handle, and a Herdr pane label shows it.

Two agents that talk by name, in two terminals (both with `session_messages = true`):

```
nano-coder --name nano-engine     # works on the engine
nano-coder --name perf            # runs the benchmarks
```

In `perf`: *"send the regression numbers to nano-engine"* — the agent calls
`session_send(to: "nano-engine", …)`, and `nano-engine` sees `[from perf · …] …`. Both
keep the names across restarts: `nano-coder --resume perf`.

## Inter-session messages

Cross-session history lets an agent *read* another session's log; inter-session messages
let it *talk* to a running one. With `session_messages = true` (default `false`) a session
listens on a Unix socket in a peer registry (`<data dir>/peers/<session-id>.sock`, the
directory created mode 0700; `NANO_CODER_PEERS` overrides the directory) and the agent
gets a fourth cross-session tool:

- `session_send(to, text, confirm?)` - deliver a message to another running session.
  `to` resolves like the history tools' `session` argument (a handle, an id, a unique id
  prefix, or a title from `sessions_list`, which marks reachable sessions `[messages]`). The
  result is one of `delivered`, `queued` (the target is mid-turn; the message sits in its
  `/queue`, visible, editable and withdrawable like a typed steer), `awaiting
  confirmation` (the target's user is being asked), `refused` (the target has messages
  off or declined, or is busy: its socket refused the connection but its process is still
  running), or `not running` (no live socket; a stale socket file from a dead session is
  removed by the sender that finds it). Each listener records its process next to its
  socket (`<session-id>.pid`: pid and start time), so a socket is only removed once that
  process is gone. A session closes any peer listener it inherited across a `/relaunch`
  before listening, so `/messages on` can rebind. The send goes through the sender's
  permission policy as a `session_send(...)` rule.

The delivered message joins the target's input labelled with its origin, e.g.
`[from session 1234abcd · ts-performance-matrix] …` (or `[from perf · ts-performance-matrix] …`
when the sender has a [handle](#session-handles)), and is logged like any input with
the sender's full session id in the record (`from_session` on the input and message). Mid-turn it is steered into the running turn; idle it starts
a turn. With `session_messages_confirm = true` (the default) the target first shows the
message and waits for its user to accept or decline; with it off, a message (including a
reply from a turn a peer message started) is delivered at once. `confirm: true` on
`session_send` asks the target's user whatever their confirm setting.

**Loop guard.** The cost risk of two agents replying to each other is bounded two ways:

- *Hop limit.* Every message carries a hop count and a thread id (the originating
  message's context, kept by replies in both directions). A send from a turn you started
  is hop 1; a send from a turn started by a hop-N message is hop N+1. Above
  `session_messages_max_hops` (default 4) the send is refused with "thread hop limit
  reached: stop, or ask your user". A message from an older nano-coder without a hop
  counts as hop 1, and so does an interrupted peer turn after a resume.
- *Per-pair rate cap.* One session sends another at most
  `session_messages_max_per_hour` messages (default 10; 0 = no cap) in any hour, so loops
  that keep starting fresh threads stop too.

On the wire each message is one A2A-shaped JSON object per line (`role`,
`parts` with `text`, `messageId`, `contextId` = the sender's session id, and
`metadata.nano.hop` / `metadata.nano.thread`), so a later A2A
bridge can map it directly. The receiver serves only a peer with its own uid
(`SO_PEERCRED`/`getpeereid`) and drops any other, and the 0700 registry directory keeps
other users from planting or reaching a socket. `/messages on|off` and `/messages confirm
on|off` switch the settings for the current session (`--save` writes them to the config
file); `/messages` alone shows the state. The state is restored on resume (`--resume`,
`/resume`, `/relaunch`, ACP `session/load`): a session that had messages on listens again
under its id; if the socket can't be opened the resume goes on with messages off and says why. With the Herdr integration active a received
message shows as activity on the target's pane.

A session served over ACP (`--acp`, typically an unattended worker) does **not** inherit
`session_messages`: it joins the registry and offers `session_send` only when opted in for
ACP, with `--session-messages` or `acp_session_messages = true` in the config (a session
loaded with `session/load` that had messages on stays off without the opt-in). Opted in,
it receives messages as user input with the label, sent to the client as a
`user_message_chunk` whose `_meta.peer.fromSession` is the sender's session id so the
client can tell them from its own input. ACP has no question channel, so a message that
would need confirmation is declined with a note asking the sender to re-send with confirm
off.
