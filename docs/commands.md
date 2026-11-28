---
title: "Slash commands"
description: "The interactive slash commands."
order: 20
section: "Reference"
---

# Slash commands

Type `/` at the prompt to see the commands; Tab completes them. The table at the end is generated from the code.

## Commands

A line starting with `/` is never sent to the model. Enter on an unknown command (`/exin`)
keeps it in the input with a hint (`Unknown command /exin. Did you mean /exit?`) so you
can fix it. To send a message that starts with `/`, such as a path, type `//`:
`//usr/lib is 4 GB, why?` sends `/usr/lib is 4 GB, why?`.

Typing `/` at the prompt lists the commands under it, and each further character narrows the
list. Tab completes the command, or the part all matches share. Esc hides the list. The
list is built from the same table as `/help` (`nano/commands.d`). Commands with a known
argument set (`/model`, `/mode`, `/verbosity`, `/thinking`) get the same treatment for their first
argument: a type-ahead list narrows as you type and Tab completes it.

- `/help` - Show available commands
- `/compact [--smart|--standard|--extract] [focus]` - Summarize older messages with the current model,
  keeping the latest message. `--smart` / `--standard` / `--extract` override `compaction_mode` for this
  compaction (see [Smart compaction](context-compaction.md#smart-compaction)). Optional text tells the
  summary what to focus on. Esc Esc or Ctrl-C cancels
- `/verbosity [quiet|normal|verbose|debug]` - Show or set how much is printed (see below)
- `/context` - Show context usage, window, the effective `max_tokens` and its source, session token totals, AI Credits (GitHub Copilot), auto-compaction state and the loaded instruction files
- `/settings` - Interactive settings menu:
  - **Model**: starts with the last four models you used, then pick a provider and a
    model from its live model list (or type an ID)
  - **Add or edit a provider**: name, API kind (OpenAI-compatible, Anthropic, Copilot),
    base URL, key source (env var, shell command, or a literal key; the file is then
    written with mode 0600) and default model
  - temperature, max tokens, system prompt
  - **Turn cap** (`max_iterations`): LLM calls per input (0 = unbounded); a positive cap makes normal mode ask before stopping. In a headless (non-interactive) session an unbounded cap falls back to a 300-call safety net
  - **Context**: auto-compaction on/off, threshold, compaction mode, context-window override
  - **Verbosity**
  - **Sub-agents**: on/off (as `/subagents on|off`, from the next request), the default
    model (`subagent_model`, or the session's), max concurrent, timeout, max turns and
    max tokens, and the candidate models (`[[subagent_models]]`): add, edit or remove
    one, each with its "use for" text and optional timeout, turns and tokens (0 = default)
  - **Session messages**: on/off (as `/messages on|off`) and confirm incoming on/off
    (as `/messages confirm on|off`)
  - **Save to config file**: writes only the keys you changed into the config file
    (`--config` or `~/.config/nano-coder/config.toml`), keeping comments and
    other settings. Leaving with unsaved changes asks whether to save
- `/tools` - List registered tools
- `/skills` - List the skills the agent can load, where each lives, and any loading warnings
- `/subagents [on|off] [--save]` - Without an argument, show whether sub-agents are on and the models they may run on with their limits. `on`/`off` switches the `agent` tool for this session from the next request (sub-agents already running finish); `--save` also writes `subagents` to the config file. Changing the tool list invalidates the provider's prompt cache once. Works over ACP too (the result carries `subagents`, `models` and `text`, and `saved` with `--save`)
- `/subagents` also lists every sub-agent of the session (the last 200; older ones are counted): its id, model, state (queued, running, done, cancelled, truncated), the first line of its task, turns, tokens and elapsed time
- `/subagents show <id>` - Render a sub-agent's transcript (prompt, answers, tool calls with folded output) from its log, read a message at a time, so even a long log shows without being loaded whole
- `/subagents stop <id>` / `/subagents stop all` - Stop running or queued sub-agents as the agent's `agent_cancel` does: each gets a few seconds to report what it has (marked cancelled; one that can't is cut off), and the agent receives that as the sub-agent's result. Typed during a turn, it runs when the turn ends. Tab completes `show`/`stop` and the sub-agent ids. `show` and `stop` are terminal-only (not over ACP)
- `/messages [on|off|confirm on|off] [--save]` - Without an argument, show whether this session sends and receives inter-session messages (see [Inter-session messages](messaging.md#inter-session-messages)). `on` opens the registry socket and offers `session_send` from the next request; `off` closes it. `confirm on|off` switches whether an incoming message waits for you to accept it. `--save` writes `session_messages` / `session_messages_confirm` to the config file
- `/plan` - Show the agent's task plan with all notes
- `/memory [entities] [forget ID] [migrate [--dry-run]]` - List cross-session memories with their ids, each entity's facts, delete one by id, or tag, merge and supersede existing memories with your confirmation (see [Memory](memory.md#memory))
- `/hooks` - List the loaded external user hooks (from `.claude/settings.json` and friends), the files they came from, and any skipped entries (see [Lifecycle Hooks](hooks.md#lifecycle-hooks))
- `/queue [list|add text|remove N...|edit N text|clear]` - Show or edit the queued messages and unread steers. Works while a turn runs, so a queued message or steer can be removed or rewritten before it is sent.
- `/model [provider/model]` - Show the current model and pick a new one. The list starts with the last four models you used (the current one marked; the previous one highlighted, so `/model` then Enter switches back), then the providers: pick a provider to scroll its model list (Esc steps back). With an argument, switches directly (conversation is kept). Typing `/model ` shows a type-ahead of the current model, recently used models, and each configured provider's default model; Tab completes (a bare provider name completes to its default model). Recently used models are kept in `~/.local/share/nano-coder/recent-models.json`
- `/mode [normal|plan|auto]` - Show or set the agent mode (Shift+Tab cycles it, at the prompt or mid-turn):
  - **normal** - full tools; reaching a positive turn cap asks whether to keep going
  - **plan** - read-only: mutating tools (`bash`, `write_file`, `edit_file`, `apply_patch`) are gated, only analysis and output
  - **auto** - no turn cap (headless runs still get the 300-call safety cap); a `question` left unanswered for 15s is answered with "the user is away from the keyboard, make the best decision you can"
- `/thinking [level|default|off|reset]` - Show the thinking level in use and the levels the current model takes, or set one for this session (`reset` goes back to the configured level). See [Thinking](providers.md#thinking)
- `/providers` - List providers, endpoints and whether their API key is available
- `/session` - Show the session ID, its handle (if any) and log path
- `/name [HANDLE|--clear]` - Show, set or clear this session's handle: a stable name other sessions use to reach it (see [Session handles](messaging.md#session-handles))
- `/trajectory` - Show this session's trajectory turn by turn: user input, thinking, answers, tool calls and results, sub-agent usage, tokens and timings, and the session's total usage. Each message row is labelled with its `#N` session-log ID, the same ID `history_read` and smart-compaction summaries use (compaction and crash-recovered input rows have no `#N`, as they aren't cited that way). It opens in your pager (`$PAGER`, default `less`), even when it would fit on the screen, so you dismiss it with `q` and it doesn't stay in the transcript or your scrollback — but only at an idle prompt on a terminal: invoked mid-turn (while a turn runs) or with piped output it prints inline instead. `/trajectory --json` or `/trajectory --markdown` prints an export instead; `nano-coder --trajectory SESSION_ID [--json|--markdown]` does the same for any saved session
- `/resume [SESSION|last]` - Switch to a saved session without restarting: the same picker as `--resume` (leaving out the session in use), or the session with that handle, ID, unique ID prefix or title, or `last` (the most recent other session in this directory). Run it at the prompt, not during a turn
- `/restart` - Start a fresh session (clean context) without exiting
- `/exit` - Exit the agent (prints the session's `--resume` command first, when session persistence is enabled)

## Command reference

<!-- BEGIN GENERATED: commands -->
<!-- Generated by scripts/gen-reference.sh from `nano-coder --dump-reference`; edit the code, not this block. -->

| Command | Arguments | Description |
|---|---|---|
| `/help` |  | Show this help |
| `/compact` | `[--smart\|--standard\|--extract] [focus]` | Summarize older messages to free context (optional mode and focus) |
| `/context` |  | Show context-window use and token totals |
| `/settings` |  | View/edit settings |
| `/verbosity` | `[quiet\|normal\|verbose\|debug]` | Show or set output detail |
| `/plan` |  | Show the agent's task plan with notes |
| `/timers` |  | List the timers the agent set for itself |
| `/memory` | `[forget ID\|entities\|migrate [--dry-run]]` | List cross-session memories (forget one, view entities, or migrate: tag, merge and supersede with confirmation) |
| `/hooks` |  | List loaded user hooks (.claude/settings.json and friends) |
| `/queue` | `[list\|add text\|remove N...\|edit N text\|clear]` | Show or edit the queued messages |
| `/tools` |  | List available tools |
| `/skills` |  | List skills the agent can load |
| `/subagents` | `[on\|off] [--save] \| show <id> \| stop <id>\|all` | List sub-agents, show or stop one, or switch the agent tool on/off |
| `/messages` | `[on\|off\|confirm on\|off] [--save]` | Show or switch inter-session messages (session_send) and confirmation |
| `/model` | `[provider/model]` | Show the model and pick a new one (or switch directly) |
| `/mode` | `[normal\|plan\|auto]` | Show or set the agent mode (Shift+Tab cycles) |
| `/thinking` | `[level\|default\|off\|reset]` | Show or set the thinking level for this session |
| `/providers` |  | List configured providers |
| `/session` |  | Show the session ID, handle and log path |
| `/name` | `[HANDLE\|--clear]` | Show, set or clear this session's handle (other sessions reach it by name) |
| `/version` |  | Show the nano-coder version |
| `/changes` | `[version]` | Show what changed since the previous release (or since version) |
| `/trajectory` | `[--json\|--markdown]` | Show this session's turn-by-turn trajectory in your pager (or export it) |
| `/resume` | `[SESSION\|last]` | Switch to a saved session: pick one, or give its handle, ID or title |
| `/restart` |  | Start a fresh session (clean context) without exiting |
| `/update` |  | Install the latest release through the channel nano-coder was installed from |
| `/relaunch` |  | Restart the binary, resuming this session (picks up a just-installed update) |
| `/exit` |  | Exit the agent |
| `/quit` |  | Exit the agent (alias for /exit) |

<!-- END GENERATED -->
