---
title: "Herdr"
description: "How nano-coder reports its state inside a Herdr pane."
order: 15
section: "Using nano-coder"
---

# Herdr

Run inside a [Herdr](https://herdr.dev) pane (`HERDR_ENV=1`, `HERDR_PANE_ID` and
`HERDR_BIN_PATH` set), the interactive CLI reports itself to Herdr: `working` while a
turn runs, `blocked` while a question or the turn limit waits for you, and `idle` at the
prompt. A saved session is reported with the command that resumes it
(`nano-coder --resume <id> --model <provider/model>`, plus `--config` if given), so Herdr
can reopen it after a restart (Herdr 0.9.2 or later). A session with a
[handle](messaging.md#session-handles) shows it as the pane's agent label and reports a `name` token, re-sent each turn in case something else in the pane cleared it.
The pane is released when you quit; `/relaunch` keeps it, and the relaunched process
reports again. A nano-coder started from inside a session (the bash tool, a hook, a
script) does not report to the parent's pane: the parent marks its pane with
`NANO_CODER_HERDR_OWNER=<pid>`, which processes it starts inherit. The `herdr` CLI stays
usable from the bash tool.
Reports run in the background and failures are ignored; outside Herdr nothing is sent.

While the agent has a timer set, nano-coder also reports a `timer` token showing ⏰.
Herdr's state icon is fixed per state, so put `$timer` next to it in your Herdr
`config.toml`. Herdr only takes per-agent layouts for its built-in agents, so this is the
layout for every agent; the token takes no space where no timer is reported:

```toml
[ui.sidebar.agents]
rows = [
  ["state_icon", "$timer", "workspace", "tab"],
  ["agent"],
]
```
