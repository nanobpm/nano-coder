# nano-coder

**A 4MB coding agent. Run a fleet on your laptop.**

nano-coder is a coding agent for the terminal, written in D. Up to 0.69 it was written in Rust; 1.0 is the D rewrite, with the same commands, config (`~/.config/nano-coder/config.toml`, `NANO_CODER_*`), session logs and ACP protocol. It uses about 4MB of memory (peak footprint on macOS), where Node-based agent CLIs take 150–660MB, so you can run dense fleets of agent workers on one machine. It runs interactively, or headless over ACP as a worker for [nano-workforce](https://github.com/nanobpm/nano-workforce) via c8ctl-nano.

## Install

```sh
npm install -g @nanobpm/nano-coder       # prebuilt binaries for macOS and Linux (x64, arm64)
brew install nanobpm/tap/nano-coder      # the same binaries through Homebrew
```

The Linux binaries need glibc 2.35+ and the system libcurl (`libcurl4` on Debian/Ubuntu,
`libcurl` on Fedora); macOS ships libcurl. To build from source, see
[Building and Running](#building-and-running).

```sh
nano-coder --help
```

`cargo install nano-coder` still installs the last Rust release (0.69), which is no longer updated.

## Features

- **Interactive CLI**: REPL-based interface for conversing with the agent
- **ACP Protocol**: JSON-RPC 2.0 over stdio for headless orchestration (c8ctl-nano compatible)
- **Providers**: OpenAI-compatible and Anthropic endpoints (remote or local), selected per model as `provider/model`, with retry/backoff
- **Tool Calling**: Agent can invoke registered tools during conversation, including a real `bash` tool with timeouts and bounded output
- **Sessions**: Append-only JSONL session logs with resume and input-ID deduplication
- **Lifecycle Hooks**: an `AgentEvents` interface for observing agent behavior, plus
  Claude Code–compatible external user hooks loaded from `.claude/settings.json`
- **Configuration**: TOML-based config file at `~/.config/nano-coder/config.toml`
- **Commands**: `/help`, `/version`, `/compact`, `/context`, `/verbosity`, `/settings`, `/tools`, `/skills`, `/subagents`, `/queue`, `/restart`, `/update`, `/relaunch`, `/changes`, `/exit`
- **Streaming output**: answers stream in, thinking shows collapsed, tool calls show inline
- **Status line** as the bottom row of the terminal, plus manual and automatic context compaction
- **Task plans**: `plan_*` tools keep a plan with notes outside the conversation, so long tasks survive compaction, resume and a change of worker
- **Project instructions**: `AGENTS.md` (or `CLAUDE.md`, `.github/copilot-instructions.md`) from the repository is added to the system prompt
- **Safety**: built-in guards block destructive commands (`rm -rf /`, `DROP DATABASE`, force-pushing `main`, ...), user allow/deny rules, and an optional OS sandbox (Seatbelt on macOS, Landlock on Linux)
- **Herdr**: inside a [Herdr](https://herdr.dev) pane, reports idle/working/blocked state and the resume command
- **Skills**: `SKILL.md` folders from the repository, `~/.agents/skills`, and an spm `ai.lock`, loaded on demand with `load_skill`

## Two Execution Modes

### Interactive CLI Mode (default)

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

### ACP Headless Mode (--acp flag)

```bash
nano-coder --acp
```

Speaks the Agent Communication Protocol (ACP) over stdio using newline-delimited JSON-RPC 2.0 messages. Compatible with c8ctl-nano's `spawnCaptureAcp` executor.

Shell commands run in the `workspace` [OS sandbox](#permissions-and-sandbox) unless a
sandbox mode is set explicitly (`--sandbox off` restores unsandboxed runs). At startup
the effective mode and its source go to stderr (`nano-coder: sandbox workspace
(default-headless)`), and the `/settings` reply carries `sandbox` and `sandbox_source`.

Inter-session messages are off in ACP mode whatever `session_messages` says; pass
`--session-messages` (or set `acp_session_messages = true`) to make the session reachable
(see [Inter-session messages](#inter-session-messages)).

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
- `session/set_name` → `{ "name": "perf" }` sets the active session's [handle](#session-handles)
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
the system prompt for the session's `cwd` (see [Project Instructions](#project-instructions)).
`_meta.skills` lists the skills found for it, and `_meta.skillWarnings` (when present) explains
any that could not be loaded (see [Skills](#skills)).

**Plans.** Each plan change sends a `plan` update: ACP `entries` (`content`, `priority`,
`status`) plus `_meta.plan`, the full plan with ids, notes and dependencies. To continue a job
on another worker, pass the last `_meta.plan` as `session/new` `params._meta.plan` (bare ACP
`entries` are accepted too). The new session starts with that plan, the `session/new` result
echoes it in `_meta.plan`, and the model is told about it with the first prompt (unless
`_meta.planInPrompt: true` says the client already put the plan in the prompt). `initialize`
advertises this as `agentCapabilities._meta.planSeed`. See [Task Plans](#task-plans).

**Outcomes.** When the model calls `report_outcome`, the `session/prompt` result carries
`_meta.outcome`: `{"status": "completed" | "blocked" | "needs_input", "summary": "..."}`. A client can use it
instead of guessing from the stop reason: `blocked` means the model needs help (an
escalation). Redelivering the input returns the same outcome. See [Outcomes](#outcomes).

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

## Architecture

```
source/
├── app.d        # Single binary entry point (interactive + ACP modes), REPL, key reader
└── nano/
    ├── agent.d      # Agent core: conversation management, tool execution loop
    ├── acp.d        # ACP JSON-RPC protocol handler
    ├── claude_hooks.d # External Claude Code–compatible user hooks engine
    ├── llm.d        # Provider-neutral messages and the LLMClient interface
    ├── http.d       # libcurl transport (streaming, timeouts)
    ├── retry.d      # Retry classification and backoff
    ├── providers/   # Provider registry + presets
    │   ├── openai.d     # OpenAI Chat Completions (and compatible servers)
    │   ├── responses.d  # OpenAI Responses API
    │   ├── anthropic.d  # Anthropic Messages API
    │   ├── mock.d       # Offline scripted client
    │   └── demo.d       # Offline demo model (`--model demo/demo`)
    ├── copilot.d    # UNOFFICIAL Copilot-subscription provider (login, tokens)
    ├── tools/       # Tool registry and the built-in tools
    │   ├── bash.d       # bash tool: timeout, file capture, bounded output
    │   ├── files.d      # read_file / write_file / edit_file / apply_patch
    │   └── search.d     # glob / grep
    ├── shell.d      # Bash parser used by the permission checks
    ├── permissions.d, guard.d # Allow/deny rules and built-in guards against destructive commands
    ├── sandbox.d, landlock.d  # Seatbelt (macOS) / Landlock (Linux) sandbox for shell commands
    ├── session.d    # Versioned append-only JSONL session log
    ├── session_index.d # Session summaries (.index.jsonl) for the --resume picker
    ├── resume.d     # --resume picker, --resume last, --list-sessions
    ├── context.d    # Token accounting, context-window heuristics, overflow detection
    ├── status.d     # Status bar contents (the frame's last row)
    ├── ui.d         # Verbosity levels and the streaming output renderer
    ├── frame.d, frameui.d # App-owned frame renderer and its owner thread
    ├── markdown.d, md*.d  # Markdown rendering of answers
    ├── lineedit.d   # Key-by-key prompt input (editing, history, mid-turn steer/queue)
    ├── control.d    # Turn control shared with the key reader: cancel, steers
    ├── instructions.d # AGENTS.md / CLAUDE.md discovery for the system prompt
    ├── plan.d       # Task plan and the plan_add / plan_update / plan_show tools
    ├── queue.d      # The interactive message queue and the /queue editor
    ├── goal.d       # report_outcome tool (completed / blocked / needs_input)
    ├── memory.d     # Cross-session memory: memory_save / memory_search / memory_forget / memory_verify / memory_entity
    ├── mode.d       # Agent mode (normal / plan / auto) and the plan-mode tool gate
    ├── question.d   # question tool and the mid-turn question / turn-cap rendezvous
    ├── commands.d   # Slash-command table for /help and the as-you-type menu
    ├── skills.d     # SKILL.md discovery, ai.lock sources and the load_skill tool
    ├── reminders.d  # <system-reminder> notes appended to tool results
    ├── herdr.d      # Herdr state / resume / release reports
    ├── settings.d, settings_dialog.d # /settings menu and config-file writer
    ├── config.d, toml.d, toml_edit.d # Configuration file loading and editing
    └── safeio.d     # The audited @trusted wrappers and thread-safe primitives
```

nano-coder was written in Rust up to 0.69; 1.0 is a rewrite in D. The Rust code is on the
`rust` branch. `PORTING.md` maps every Rust module to its D counterpart and lists the known
differences, `REVIEW.md` compares the safety and architecture of the two implementations, and
`parity/manifest.tsv` records how each Rust test was ported.

Mode selection: `--acp` flag enables ACP headless mode; default is interactive CLI.

## Lifecycle Hooks

nano-coder has two hook systems.

### Internal events (observe-only)

The agent loop reports what it does through the `AgentEvents` interface
(`nano/agent.d`): streamed text and reasoning, each tool call's start and end, token
usage, steering messages and complete replies. The CLI and ACP front ends implement it
to render output; an implementation can also log or collect metrics. These are
**observe-only**: they cannot block, modify or redirect the agent. (The Rust version's
six named internal hook events are replaced by this interface.)

### External user hooks (Claude Code–compatible)

nano-coder also runs **external user hooks** that follow the
[Claude Code hooks protocol](https://docs.claude.com/en/docs/claude-code/hooks),
so existing Claude Code hook configurations work unchanged. These are loaded,
in order, from:

1. `[hooks]` in nano-coder's own user config (`config.toml`), in Claude's structure
2. `~/.claude/settings.json` (your Claude Code user settings; disable with `claude_user_hooks = false`)
3. `<project>/.claude/settings.json` (project settings, committed)
4. `<project>/.claude/settings.local.json` (project-local, git-ignored)

Each hook is a `command` that nano-coder runs as a subprocess, passing the
event payload as JSON on stdin and interpreting its exit code and (optional)
JSON stdout per Claude's protocol. Hooks can **block** a tool call or prompt,
**modify** a tool's input, or **inject additional context**. nano-coder
translates its tool names (`bash`→`Bash`, `read_file`→`Read`, `write_file`→
`Write`, `edit_file`→`Edit`, `grep`→`Grep`, `glob`→`Glob`) and the `file_path`/
`path` argument so Claude-authored matchers and scripts match correctly.

Supported events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, and `Stop`. A `PreToolUse` hook that fails (crashes, times out,
or exits non-zero) **fails closed** and blocks the tool call; failures in other
events are non-blocking.

Run `/hooks` at the prompt to list the loaded hooks, which files they came
from, and any that were skipped (e.g. unsupported events reserved for later
phases). Disable them with `--no-hooks`, or granularly via the
`disable_hooks`, `disable_project_hooks`, and `claude_user_hooks` settings.

## Built-in Tools

- `get_time` - Get current date and time
- `bash` - Run `bash -c <command>` (stdin closed, own process group). Arguments:
  `command`, optional `timeout_seconds` (default `bash_timeout_secs`, 600) and
  `max_output_length` (default 40,000, max 1,000,000 characters each for stdout and stderr).
  Returns stdout, then `Stderr:` and `Exit code: N` when relevant, or `(no output)`.
  Long output keeps its head and tail with `...N bytes truncated (sha256:<digest>); complete output in <path>...`;
  the full capture stays in that file. The digest is the first 16 hex characters (64 bits) of a
  SHA-256 over the capture's complete content — a truncated prefix of the full `sha256sum` value,
  hashed incrementally while the command runs (not re-read after it exits) — so two results whose
  bounded head, tail and byte count match but whose content differs are still told apart, without
  an unbounded post-exit reread of a multi-gigabyte capture.
- `read_file` - Numbered lines of a text file; `path`, optional `offset` (1-based) and `limit`
  (default 2000 lines). Refuses binary files.
- `grep` - Search file contents for a regular expression (`pattern`, optional `path` — a file
  or directory, default the working directory —, optional `glob` include filter such as `*.rs`
  or `src/**/*.rs`, optional `output_mode` `content` (default; `path:line:text`), `files` or
  `count`, optional `limit`, default 250). Read-only and allowed in plan mode.
- `glob` - List files matching a glob `pattern` (optional `path`, `limit`). A pattern without
  `/` matches file names at any depth; with `/` it matches paths relative to the search root,
  `*` within one directory and `**` across directories. Read-only and allowed in plan mode.
- `grep` and `glob` respect `.gitignore` (a subset: comments, `!` negation, directory
  patterns, anchored patterns, `*`/`?`/`**`), skip `.git`, symlinks, binary files and files
  over 16 MiB, return results sorted by path, and say when the `limit` cut results short.
  Files covered by a `Read(...)` deny rule never appear in their output — neither contents
  nor names — and `Grep`/`Glob` rules can deny the tools outright (see
  [Permissions and Sandbox](#permissions-and-sandbox)).
- `write_file` - Create or overwrite a file (`path`, `content`), creating parent directories.
- `edit_file` - Replace text (`path`, `old_string`, `new_string`, optional `replace_all`).
  Fails unless `old_string` matches exactly once (or `replace_all` is set). With no exact match,
  it retries ignoring `read_file` line-number prefixes, then trailing whitespace, then
  indentation (re-indenting `new_string` to fit), and uses such a match only if it is unique;
  otherwise the error shows the closest lines. Returns the edited lines with 3 lines of context.
- `apply_patch` - Apply a content-anchored patch (`patch`, optional `dry_run`) that updates, adds,
  deletes and moves any number of files in one call:
  `*** Begin Patch` / `*** Update File: path` (hunks of ` ` context, `-` and `+` lines, each
  optionally after an `@@ <nearby line>` anchor) / `*** Add File: path` (`+` lines) /
  `*** Delete File: path` / `*** Move File: from -> to` / `*** End Patch`. No line numbers: each hunk
  must match exactly one place, using `edit_file`'s matching (exact, then ignoring trailing
  whitespace, then indentation; the tier used is reported), and applies to the file as the
  earlier hunks left it. Atomic: every hunk is applied in memory first, and nothing is written
  unless all succeed; a failure names the file and hunk and shows the closest lines. Every
  touched path (both ends of a move) passes the permission rules, plan mode, sandbox and the
  `Edit`/`Write` hooks exactly as a direct edit would. Returns the applied unified diff;
  `dry_run` returns it and writes nothing. A file read earlier that has changed on disk since
  must be read again first. Prefer `edit_file` for one surgical edit.
- `edit_file`, and `write_file` over an existing file, require the file to have been read with
  `read_file` (or written by these tools) in this process, and to be unchanged on disk since.
  Otherwise they ask the model to read it again, so an edit can't land on stale text.
- `plan_add`, `plan_update`, `plan_show` - The agent's task plan (see [Task Plans](#task-plans)).
- `timer_set`, `timer_list`, `timer_cancel`, `timer_done` - Timers the agent sets to come back
  to something later in the session. A fired timer is restated until `timer_done`; at most 10
  wait at once, and older ones are auto-closed (with a notice) beyond that.
- `session_settings` - The agent reads or adjusts its own session's settings (see
  [Agent-adjusted compaction](#agent-adjusted-compaction)).
- `report_outcome` - Report the task `completed`, `blocked` or `needs_input`, with a `summary`; ends
  the turn (see [Outcomes](#outcomes)).
- `question` - Ask the user a structured question and wait for the answer, without ending the turn.
  Interactive sessions only; in auto mode an unanswered question is resolved after 15s with the
  away message. Headless (ACP) sessions get an error instead.
- `load_skill` - Return a skill's instructions and list its other files; `name`. Offered only
  once skills are found (at start, or when one is added mid-session; see [Skills](#skills)).
- `memory_save`, `memory_search`, `memory_forget`, `memory_verify`, `memory_entity` - Cross-session memory: facts the model saves
  in one session and finds in later ones (see [Memory](#memory)). Offered when `memory` is on;
  read-only runs (headless/ACP) offer `memory_search` only.

Any other tool's result longer than 40,000 characters is cut the same way as bash output,
with the whole result saved under the temp directory (`nano-coder-<pid>/tool-<id>-<name>.txt`)
and its path in the marker. `read_file` pages instead.

Relative paths resolve against the working directory (ACP `session/new` `cwd`). Writes are
atomic (temp file + rename). There is no permission prompt; every call is checked against
the [permission rules and sandbox](#permissions-and-sandbox) instead.

## Permissions and Sandbox

nano-coder never stops to ask for approval (it runs headless in agent fleets). Every tool call
is checked before it runs instead, and a blocked call returns an error telling the model to
stop and ask the user rather than work around the block.

**Order of checks:** `deny` rules, then `allow` rules, then the built-in guards. Deny always
wins. An allow rule approves a shell command only when *every* command in it matches, so
`Bash(git *)` does not approve `git status && rm -rf /`.

**Rules** name a tool and an optional pattern:

| Rule | Matches |
|---|---|
| `Bash(rm -rf *)` | a shell command; `*` matches anything, including spaces and `/` |
| `Bash(git push:*)` | `git push` alone or with any arguments |
| `Read(~/.ssh/**)` | `read_file` paths and files `grep`/`glob` may reveal; `**` crosses directories, `*` does not |
| `Edit(**/.env)` / `Write(...)` | `write_file` and `edit_file` paths, and every path an `apply_patch` touches (relative to the working directory, or absolute) |
| `write_file`, `bash`, any tool name | every call to that tool |

**Shell commands are parsed, not pattern-matched as text.** The command line is split on `;`,
`&&`, `||`, `|`, `&`, newlines and parentheses; quotes are removed; `$(...)`, backticks and
`<(...)` are parsed as further commands. The guards and rules then see through assignments
(`FOO=1 cmd`), wrappers (`sudo`, `env`, `timeout`, `nice`, `xargs`, `nohup`, `command`, ...),
`bash -c '...'`, `eval`, `ssh host cmd`, `find -exec`, and here-documents fed to a shell. A command
that cannot be parsed, or a script computed at run time (`bash -c "$CMD"`,
`eval "$(curl ...)"`), is blocked.

**Built-in guards** (`builtin_rules = true`) block:

- recursive `rm` (and `mv`, `find -delete`, `chmod -R`/`chown -R`) on `/`, your home directory
  or its top-level folders, the working directory or its parents, top-level and system
  directories, and `.git`. `rm -rf *` counts as the working directory. An unset variable counts
  as empty, so `rm -rf "$DIR/"*` is blocked unless written `"${DIR:?}/"*`. Paths follow a `cd` and
  variable assignments earlier in the same command (`cd .. && rm -rf project` is blocked)
- `mkfs`, `fdisk`, `wipefs`, destructive `diskutil`, `dd of=/dev/...` and redirects to
  devices, fork bombs, `shutdown`/`reboot`
- destructive SQL (`DROP DATABASE|SCHEMA|TABLE`, `TRUNCATE`, `DELETE FROM` without `WHERE`,
  `ALTER TABLE ... DROP`, `FLUSHALL`, `dropDatabase()`) in a command that uses a database client
  (`psql`, `mysql`, `sqlite3`, `mongosh`, `redis-cli`, also via `docker exec`) or inline
  interpreter code (`python -c`), plus `dropdb`, `rails db:drop`, `prisma migrate reset`,
  `manage.py flush`
- `terraform destroy`, `pulumi destroy`, `kubectl delete namespace|--all`, `aws s3 rb`
- `git push --force` (or `+refspec`, `--all`, wildcard refspecs) to, or deleting, a protected
  branch, and `git push --mirror`

Add an allow rule for anything legitimate they block, e.g.
`allow = ["Bash(sqlite3 test.db *)"]`, or set `builtin_rules = false`.

**These checks catch mistakes, not adversaries.** A model can write a script and run it, and
nothing inspects that. The boundary is the OS sandbox, plus credentials: don't give the agent
production database URLs or broadly scoped tokens.

**Sandbox** (`--sandbox workspace`; on by default for headless runs, off interactively) runs each shell command under Seatbelt
(`sandbox-exec`) on macOS or Landlock on Linux (6.2+). Commands can read everywhere, but
write only to:

- `workspace`: the working directory, its git directories (including a worktree's shared
  one), temp directories, package-manager caches (`~/.cargo/registry`, `~/.npm`, `~/.cache`,
  `~/Library/Caches`, `~/.gradle`, `~/go/pkg/mod`, ...) and `writable` paths
- `read-only`: temp directories and `writable` paths

`write_file`, `edit_file` and `apply_patch` are held to the same directories. `network = false` blocks
outbound connections (macOS: except to localhost; Linux: all TCP, which needs Linux 6.7+).
If the sandbox is enabled but cannot be applied, commands fail instead of running
unsandboxed. When a sandboxed command fails with a permission error, the result tells the
model where it may write.

**Default mode.** The mode comes from, in order: `--sandbox`, `NANO_CODER_SANDBOX`, the
config's `[sandbox] mode`, and otherwise a default that depends on how nano-coder runs.
Headless runs (`--acp`, `-p`, piped stdin), where no one approves commands, default to
`workspace`; interactive terminal runs default to `off`. An explicit `off` at any level
restores unsandboxed behaviour. `/settings` shows the effective mode and its source
(`flag --sandbox`, `env NANO_CODER_SANDBOX`, `config`, `default-headless` or `default`).
A headless run whose sandbox can't be applied (e.g. Linux older than 6.2) exits at
startup with the opt-out spelled out rather than running unsandboxed.

**Breaking change for fleet operators:** headless workers that write outside the
workspace (other repositories, `~/.config/...`) now need `[sandbox] writable` grants or an
explicit opt-out (`--sandbox off`, `NANO_CODER_SANDBOX=off` or `[sandbox] mode = "off"`).

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
  compaction (see [Smart compaction](#smart-compaction)). Optional text tells the
  summary what to focus on. Esc Esc or Ctrl-C cancels
- `/verbosity [quiet|normal|verbose|debug]` - Show or set how much is printed (see below)
- `/context` - Show context usage, window, session token totals, AI Credits (GitHub Copilot), auto-compaction state and the loaded instruction files
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
- `/messages [on|off|confirm on|off] [--save]` - Without an argument, show whether this session sends and receives inter-session messages (see [Inter-session messages](#inter-session-messages)). `on` opens the registry socket and offers `session_send` from the next request; `off` closes it. `confirm on|off` switches whether an incoming message waits for you to accept it. `--save` writes `session_messages` / `session_messages_confirm` to the config file
- `/plan` - Show the agent's task plan with all notes
- `/memory [entities] [forget ID] [migrate [--dry-run]]` - List cross-session memories with their ids, each entity's facts, delete one by id, or tag, merge and supersede existing memories with your confirmation (see [Memory](#memory))
- `/hooks` - List the loaded external user hooks (from `.claude/settings.json` and friends), the files they came from, and any skipped entries (see [Lifecycle Hooks](#lifecycle-hooks))
- `/queue [list|add text|remove N...|edit N text|clear]` - Show or edit the queued messages and unread steers. Works while a turn runs, so a queued message or steer can be removed or rewritten before it is sent.
- `/model [provider/model]` - Show the current model and pick a new one. The list starts with the last four models you used (the current one marked; the previous one highlighted, so `/model` then Enter switches back), then the providers: pick a provider to scroll its model list (Esc steps back). With an argument, switches directly (conversation is kept). Typing `/model ` shows a type-ahead of the current model, recently used models, and each configured provider's default model; Tab completes (a bare provider name completes to its default model). Recently used models are kept in `~/.local/share/nano-coder/recent-models.json`
- `/mode [normal|plan|auto]` - Show or set the agent mode (Shift+Tab cycles it, at the prompt or mid-turn):
  - **normal** - full tools; reaching a positive turn cap asks whether to keep going
  - **plan** - read-only: mutating tools (`bash`, `write_file`, `edit_file`, `apply_patch`) are gated, only analysis and output
  - **auto** - no turn cap (headless runs still get the 300-call safety cap); a `question` left unanswered for 15s is answered with "the user is away from the keyboard, make the best decision you can"
- `/thinking [level|default|off|reset]` - Show the thinking level in use and the levels the current model takes, or set one for this session (`reset` goes back to the configured level). See [Thinking](#thinking)
- `/providers` - List providers, endpoints and whether their API key is available
- `/session` - Show the session ID, its handle (if any) and log path
- `/name [HANDLE|--clear]` - Show, set or clear this session's handle: a stable name other sessions use to reach it (see [Session handles](#session-handles))
- `/trajectory` - Show this session's trajectory turn by turn: user input, thinking, answers, tool calls and results, tokens and timings. Each message row is labelled with its `#N` session-log ID, the same ID `history_read` and smart-compaction summaries use (compaction and crash-recovered input rows have no `#N`, as they aren't cited that way). It opens in your pager (`$PAGER`, default `less`), even when it would fit on the screen, so you dismiss it with `q` and it doesn't stay in the transcript or your scrollback — but only at an idle prompt on a terminal: invoked mid-turn (while a turn runs) or with piped output it prints inline instead. `/trajectory --json` or `/trajectory --markdown` prints an export instead; `nano-coder --trajectory SESSION_ID [--json|--markdown]` does the same for any saved session
- `/resume [SESSION|last]` - Switch to a saved session without restarting: the same picker as `--resume` (leaving out the session in use), or the session with that handle, ID, unique ID prefix or title, or `last` (the most recent other session in this directory). Run it at the prompt, not during a turn
- `/restart` - Start a fresh session (clean context) without exiting
- `/exit` - Exit the agent (prints the session's `--resume` command first, when session persistence is enabled)

## Building and Running

You need [LDC](https://github.com/ldc-developers/ldc) 1.43+ and dub, plus the libcurl
development headers on Linux.

```bash
dub build -b release   # ./nano-coder
./nano-coder
```

The build passes `-lowmem` to LDC (GC during compilation), which roughly halves its peak memory so it fits on small machines and alongside other builds.

Then, for example:

```bash
nano-coder --model anthropic/claude-sonnet-4-5
nano-coder --model ollama/qwen2.5:1.5b
nano-coder --resume sess-20260923T012518-7e7923f8
nano-coder --resume        # pick a session
nano-coder --resume last   # the most recent session in this directory
```

**Resuming.** `--resume` without an ID opens a picker of this directory's saved sessions, most
recently used first. Each row shows when the session was last used, its project (the last part of
its directory), how many prompts it has, and its last prompt. When the last prompt says little
("do it"), the row also shows the more telling prompt before it. Type to filter, Enter to resume,
Esc to cancel. The last entry shows sessions from every directory. At the prompt, `/resume` does the same without restarting. Sessions with no prompts are
left out. Sessions from before this feature don't record their directory: they are shown in every
directory, with `?` as the project. Without a terminal, `--resume` prints the list and exits.
`--list-sessions [--all] [--json]` prints the list for scripts (`--all`: every directory).

A resumed session carries on with the runtime settings it stopped with, not the config defaults:
the model (`/model`), the mode (`/mode`), verbosity (`/verbosity`), the thinking level
(`/thinking`), the sub-agents switch (`/subagents on|off`) and the context settings (compaction
mode, auto-compact on/off and its threshold, and the context-window override, as changed in the
`/settings` panel's Context section) and inter-session messages (`/messages on|off` and
`/messages confirm on|off`, or the `/settings` panel). Each change is logged when it happens and the latest value
wins; a session logged before this feature starts from the model its header recorded. Precedence:
an explicit `-m`/`--model`, `--verbosity` or `--plan` on the resume command line wins, then the session's
last value, then the config default. Explicit startup flags are recorded too, so a later resume
without them keeps them. If the session's provider or model is no longer available
(the provider was removed or disabled), the resume falls back to the config default with a
one-line notice instead of failing. The startup banner's `Model:` line shows the model the
resumed session runs. `/relaunch` and the relaunch after `/update` keep the settings through the
same path: the relaunch passes the session's current model, verbosity and mode in place of the
original `-m`, `--verbosity`/`-v` and `--plan` flags, so a switch made mid-session is not undone.
An ACP `session/load` restores the same settings and re-renders the system prompt for the
restored mode.

The picker reads `.index.jsonl` in the session directory: one summary per session, updated at the
end of each turn. It is only a cache. A session that is missing from it, or whose log changed
since it was indexed, is summarized from its log again, and deleting the file rebuilds it.

**Sub-agents.** The `agent` tool hands a broad, read-only investigation (`task`) to a fresh agent
with its own context window; only its report (with `file:line` citations and its turns, tokens and
time) comes back. Several `agent` calls in one reply run in parallel, up to
`subagent_max_concurrency`; a call that can change files (an edit, `bash`) between them is a barrier,
so an `agent` call after it starts only once the change is made. A sub-agent has `read_file`, `grep` and `glob` (no shell, so it cannot change files); every call goes
through this session's permission policy and hooks (a denied call is an error for the sub-agent, it
never prompts), Esc/Ctrl-C stops it, and its usage counts toward the session's. Its log is written
next to the session's (`<session>/sub-<call id>.jsonl`), referenced from the `agent` result, and
expanded by `--trajectory`.

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

**Titles.** With `session_titles = true`, once a session has a prompt that says something (not
just "hi"), nano-coder asks the model for a title of at most six words in the background. It uses
`title_model` (a cheap one is enough) or the session's model. The request is a few hundred tokens,
tried at most once per session per run (so a failed or deleted title is retried after a restart,
not on the next turn). The picker then shows `title · last prompt`. Titles live only in the index,
so older nano-coders can still read the logs. Deleting `index.jsonl` loses them; a new run then
asks again on the session's next turn.

Flags: `--login github-copilot`, `--list-models PROVIDER`, `--trajectory SESSION_ID [--json|--markdown]`, `--acp`, `--model provider/model` (or `AGENTIC_HARNESS_MODEL`), `--resume [SESSION|last]` (a handle, ID, unique ID prefix or title), `--name HANDLE`, `--list-sessions [--all] [--json]`,
`--config PATH`, `--verbosity LEVEL` (`-v`), `--sandbox off|workspace|read-only` (or `NANO_CODER_SANDBOX`),
`--allow RULE` and `--deny RULE` (repeatable; added to the config's rules), `--version` (`-V`).

CI runs `scripts/ci.sh`, and so can you: `scripts/ci.sh` runs everything CI does (lint,
unit tests, release build, typecheck of both the release and unittest builds, smoke checks);
`scripts/ci.sh quick` is the fast subset. With `git config core.hooksPath .githooks`, the
pre-push hook runs `quick` before every push. Test-only imports go inside the unittest or
test helper that uses them, never in a file-level `version (unittest)` block, where non-test
code could use them and pass `dub test` but fail the release build. All code is `@safe`: every module starts with `@safe:`, and calls the
compiler can't check are wrapped in small, commented `@trusted` functions (shared ones in
`source/nano/safeio.d`). `check-safe.sh` fails the build on a module without `@safe:`, an
uncommented `@trusted`, raw threads or `__gshared` outside `safeio.d`, or more `@trusted` than
the merge base had. These counts are ratchets (`scripts/ratchets.sh`): check-safe measures each
one on the working tree and on the merge base with `origin/main` (`NANO_RATCHET_BASE` overrides),
in a temporary worktree, and fails when one gets worse. Nothing is committed, so improving a count
needs no edit and parallel PRs can't conflict; a deliberate loosening is a commit trailer
`Ratchet-Override: <ratchet> <reason>`, which check-safe prints. Because this repository allows
only squash merges (RELEASING.md), the trailer must survive the squash: check-safe reads the
trailers of the squashed commit on `main`, so an override that is dropped from the squash commit
message leaves the post-merge CI run comparing a loosened count against the pre-push commit with
no approval in `base..HEAD`, and the build fails. When merging such a PR, copy every approved
`Ratchet-Override:` trailer into the squash commit message's footer (GitHub's default squash
message lists the PR's commits; keep the trailer lines). The build uses `-preview=dip1000` and `-preview=nosharedaccess`.

Time goes through `nano.clock`: `wallNow`, `monoNow`, `since` and `sleepFor` instead of
`Clock.currTime`, `MonoTime.currTime`, `StopWatch` and `Thread.sleep`, which check-safe bans
elsewhere. A test can then install a `FakeClock` (per thread) to pick "now" and make sleeps
instant. Timeouts and grace periods that tests run into are parameters, so a test passes a
short one rather than waiting out the production value. The test runner
(`source/nano/testenv_test.d`) fails a module whose tests take over 1 s, unless
`scripts/slow-tests` gives it a higher limit and a reason. The limits are wall-clock, so a busy
host doesn't fail a correct change: before failing a module, the runner times a fixed calibration
(CPU, short sleeps, process spawns) and scales the limits by how much slower it ran than on an idle
machine, at most 3x. `NANO_TEST_TIMES=N dub test` lists the
N slowest modules. `NANO_TEST_JOBS=N` runs modules in parallel (`scripts/ci.sh` uses 4); modules
that change process-wide state (the cancel flag, environment variables) are listed in
`scripts/serial-tests` and run alone first.

Functions are `pure` wherever they can be: the result depends only on the arguments, with no
clock, environment, files or global state. Modules that start with `pure:` (parsing, markdown,
plans, context arithmetic, the status line and others) make up a pure core, and the I/O stays
in their callers. `pure:` doesn't reach member functions, so `source/nano/pure_core_test.d`
runs a compile-time audit (`nano.pureaudit`) over those modules. check-safe keeps that list in
step with the `pure:` modules, and the `pure` count and the number of pure modules can only
grow (ratchets `pure-floor` and `pure-module-floor`).

The pure core is also strongly pure: no public function takes a `ref`, `out` or other mutable
argument (the audit fails the build on one), so a call can't change what its caller passed.
Results come back as values, and so do errors: a function that can fail returns
`nano.result.Result!(T, E)` (`ok`/`err`, `match`, `map`, `andThen`, `toOption`, and
`orThrow!(e => new X(e))` for the code that still reports errors by throwing). A missing value is
`Option!T`. Inside the core, only the shell and TOML parsers throw, to unwind to their own entry
point, which returns the error. Their exception classes are private, and check-safe caps those
`throw`s (ratchet `pure-throw-budget`).

The agent loop is part of that core too. `nano.turn` is a state machine: `step(state, event)`
returns the next state and a list of effects. Events are what happened (a call is due, the model
replied, a call failed, tools ran, a Stop hook ran, compaction finished); effects are what to do
next (call the model, run the tools, continue a cut-off reply, run the Stop hook, finish). Every
decision in a turn is made in `step`: the turn cap, stream restarts, the output cap, compacting on
overflow, continuations, steers, Stop hook blocks and reported outcomes. `Agent.runTurn` only
carries effects out and feeds the results back in. `source/nano/turn_replay_test.d` replays
session logs through `step` and checks that each turn asks for what the log shows next and ends
with the recorded answer. Point `NANO_REPLAY_DIR` at a sessions directory to replay all of its
turns.

## What Changed After an Update

After an update (`/update` and `/relaunch`, `brew upgrade` or an npm update), the next
interactive start shows **"Updated X → Y"** with the changes of every release in between,
grouped as Features, Fixes and Performance, with each PR as a full link. It comes after
a resumed session's transcript, so it is the last thing on screen, and is never written
to the session log (a later resume doesn't show it again). At most 15 changes are listed,
then "…and N more" with a compare link.

- The version that ran last is kept in `<platform data dir>/nano-coder/last_version`. The
  first run ever only records it; a downgrade records the running version and shows nothing.
- The notes are compiled in. When they don't cover the range (a very old record, a local
  build), the releases are fetched from the GitHub API in the background (short timeouts,
  bounded size) and shown at the prompt; if that fails, a compare link
  (`https://github.com/nanobpm/nano-coder/compare/vX...vY`) is shown instead.
- Over ACP the notice is sent once, after the first `session/new` or `session/load`, as a
  `_nano/notice` notification (`{"sessionId", "level": "info", "text"}`); it never fetches.
  Headless prompts (`-p`, piped stdin) show nothing and leave the record alone.
- `show_release_notes = false` turns the notice off (the record is still kept).
- `/changes` shows the changes of this release again; `/changes 1.8.0` shows everything
  since 1.8.0. It never fetches: versions the build's notes lack give a compare link.
- A fetched start-up notice is recorded only once shown: quitting before it arrives shows it
  again at the next start.

## Configuration

Create `~/.config/nano-coder/config.toml` (every field is optional). Directories from before the rename (`agentic-harness`, for config and for data such as sessions) are moved to `nano-coder` at startup when the new ones don't exist yet. A symlink is left at the old path so an older nano-coder still finds them. If that compatibility symlink can't be created, a warning is printed and the link is retried on later starts; if the move itself fails, the old directory is used:

```toml
model = "anthropic/claude-sonnet-4-5"   # provider/model
default_provider = "mock"               # used when the model has no known provider prefix
temperature = 0.7                       # or "default" to send none (see Temperature below)
max_tokens = 4096
max_iterations = 0                      # LLM calls per user input (0 = unbounded; headless runs get a 300-call safety cap)
system_prompt = "You are a helpful assistant with access to tools."
bash_timeout_secs = 600
# bash_heartbeat_secs = 60               # supervisor-visible "still running" note interval (or NANO_CODER_BASH_HEARTBEAT_SECS)
persist_sessions = true
cross_session_history = true            # sessions_list + a session argument on the history tools: read other sessions' logs
session_messages = false                # listen for messages from other sessions + offer session_send (see Inter-session messages)
session_messages_confirm = true         # ask before an incoming session message is queued/run
acp_session_messages = false            # let --acp sessions send/receive messages (ACP ignores session_messages)
# session_dir = "/path/to/sessions"    # default: <platform data dir>/nano-coder/sessions
session_compress_after_days = 14        # gzip logs idle this long at startup (0 = never)
# session_retention_days = 0           # delete logs untouched this long (0 = keep; named sessions are kept)
session_titles = false                  # ask the model for a few-word title per session (--resume picker)
# title_model = "openai/gpt-4o-mini"    # model for titles (default: the session's model)
subagents = true                        # offer the `agent` tool: read-only sub-agents with their own context
# subagent_model = "openai/gpt-4o-mini" # model for sub-agents (default: the session's; a call may name one)
subagent_max_concurrency = 4            # sub-agents running at once (several `agent` calls in one reply)
subagent_timeout_secs = 600             # per sub-agent caps; past one it reports what it has, marked truncated
subagent_max_turns = 40
subagent_max_tokens = 1000000
# [[subagent_models]] tables offer a fixed choice of models (see Sub-agents)
auto_compact = true                     # summarize automatically when the context fills up
auto_compact_threshold = 0.8            # fraction of the context window
compaction_mode = "smart"               # smart | standard | extract (see Smart compaction)
# context_window = 128000               # override the window (providers can set it too)
verbosity = "normal"                    # quiet | normal | verbose | debug (or --verbosity)
timestamps = true                       # prefix CLI messages with the local time (HH:MM:SS)
project_instructions = true             # load AGENTS.md etc. (see Project Instructions)
project_instruction_files = ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".github/copilot-instructions.md"]
user_instruction_files = ["~/.claude/CLAUDE.md", "~/.agents/AGENTS.md"]   # yours, for every project
user_rules_dirs = ["~/.claude/rules"]
instruction_imports_outside_project = false   # let project @imports / rule links leave the repo
plan_tools = true                       # offer the plan_* tools (see Task Plans)
outcome_tool = true                     # offer report_outcome (see Outcomes)
reminders = true                        # append <system-reminder> notes to tool results
show_release_notes = true               # after an update, show what changed (see What Changed)
memory = "on"                           # on | read_only | off — cross-session memory (see Memory)
# memory_dir = "/path/to/memory"        # default: <platform data dir>/nano-coder/memory
memory_expiry_days = 90                 # expire memories unused this long (0 = never)
memory_recall = "entity"                # entity | anchor — how tool calls recall memories (see Memory)

[skills]                                # see Skills
enabled = true
dirs = [".agents/skills", ".github/skills", ".claude/skills"]   # relative to the git root
user_dirs = ["~/.agents/skills"]
ai_lock = true                          # load skills pinned in ai.lock
fetch = true                            # fetch ai.lock commits missing from the spm store
allowed_hosts = ["github.com"]          # hosts ai.lock entries may be fetched from ("*" = any)

[permissions]                           # see Permissions and Sandbox
builtin_rules = true                    # block destructive commands unless allowed
allow = []                              # e.g. ["Bash(sqlite3 test.db *)"]
deny = []                               # e.g. ["Bash(git push:*)", "Edit(**/.env)"]
protected_branches = ["main", "master", "trunk", "develop"]

[sandbox]
# mode = "workspace"                    # off | workspace | read-only (or --sandbox); unset: workspace headless, off interactive
writable = []                           # extra writable paths, e.g. ["~/.local/state/myapp"]
network = true                          # false blocks outbound connections
tool_caches = true                      # workspace mode: allow ~/.cargo/registry, ~/.npm, ~/.cache, ...
```

The default model is `gpt-4o-mini` on the `mock` provider, so the harness still works offline.

## Providers

A model is written as `provider/model`. The first path segment picks the provider if it
names one; otherwise the whole string is a model on `default_provider`. So
`openrouter/anthropic/claude-sonnet-4.5` sends `anthropic/claude-sonnet-4.5` to OpenRouter.

Built-in presets:

| Provider | Kind | Base URL | API key env |
|---|---|---|---|
| `openai` | openai | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `anthropic` | anthropic | `https://api.anthropic.com/v1` | `ANTHROPIC_API_KEY` |
| `openrouter` | openai | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` |
| `fireworks` | openai | `https://api.fireworks.ai/inference/v1` | `FIREWORKS_API_KEY` |
| `groq` | openai | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` |
| `together` | openai | `https://api.together.xyz/v1` | `TOGETHER_API_KEY` |
| `deepseek` | openai | `https://api.deepseek.com/v1` | `DEEPSEEK_API_KEY` |
| `kimi` | openai | `https://api.moonshot.ai/v1` | `MOONSHOT_API_KEY` |
| `mistral` | openai | `https://api.mistral.ai/v1` | `MISTRAL_API_KEY` |
| `gemini` | openai | `https://generativelanguage.googleapis.com/v1beta/openai` | `GEMINI_API_KEY` |
| `qwen` | openai | Model Studio (default: Standard, Singapore — all plans/regions below) | `DASHSCOPE_API_KEY` / `BAILIAN_*_PLAN_API_KEY` |
| `ollama` | openai | `http://localhost:11434/v1` | — |
| `llamacpp` | openai | `http://localhost:8080/v1` | — |
| `github-copilot` | github-copilot | from session token | `GITHUB_COPILOT_OAUTH_TOKEN` or `--login` (unofficial, see below) |
| `mock` | mock | — | — |

`kind = "openai"` means OpenAI Chat Completions, which also covers vLLM, LM Studio,
llama.cpp, DwarfStar ds4 and similar servers. `kind = "anthropic"` is the Anthropic
Messages API.

A `[providers.<name>]` table can add a new endpoint or override any field of a preset:

```toml
[providers.ollama]                      # point the preset at another host
base_url = "http://merlin.local:11434/v1"
default_model = "qwen3:8b"              # used by `--model ollama`

[providers.ds4]                         # a custom OpenAI-compatible endpoint
kind = "openai"
base_url = "http://localhost:8100/v1"
extra_body = { think = false }          # merged into every request body

[providers.openai]
drop_params = ["temperature"]           # for models that reject temperature

[providers.openrouter]
headers = { "HTTP-Referer" = "https://example.com", "X-Title" = "nano-coder" }
extra_body = { provider = { sort = "throughput" } }

[providers.work]
kind = "anthropic"
base_url = "https://llm-gateway.example.com/anthropic/v1"
api_key_env = "WORK_GATEWAY_KEY"        # or api_key = "..." (prefer the env var)
# api_key_command = "op read op://vault/gateway/key"   # used when the env var is unset
timeout_secs = 300                      # idle timeout: max silence between streamed bytes (default 600)
max_retries = 3
```

`qwen` is Qwen Cloud (Alibaba Cloud Model Studio), e.g. `--model qwen/qwen3.8-max`.
Model Studio serves the same models through three plans, each with its own hostnames and
API-key variable. All of them speak OpenAI Chat Completions, so each is just a `base_url`
+ `api_key_env`:

| Plan | Region | Base URL | API key env |
|---|---|---|---|
| Standard API key | Singapore (International) | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Standard API key | China (Beijing) | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Standard API key | US (Virginia) | `https://dashscope-us.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Standard API key | China (Hong Kong) | `https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| Token Plan | Singapore (International) | `https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` | `BAILIAN_TOKEN_PLAN_API_KEY` |
| Token Plan | China (Beijing) | `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` | `BAILIAN_TOKEN_PLAN_API_KEY` |
| Coding Plan | Singapore (International) | `https://coding-intl.dashscope.aliyuncs.com/v1` | `BAILIAN_CODING_PLAN_API_KEY` |
| Coding Plan | China (Beijing) | `https://coding.dashscope.aliyuncs.com/v1` | `BAILIAN_CODING_PLAN_API_KEY` |

The `qwen` preset defaults to **Standard API key, Singapore** (the first row). In
`/settings` → *Add or edit a provider* → `qwen` these eight endpoints are offered as a
*Qwen / Model Studio endpoint* picker (plus a custom URL), so you can switch plan and
region without retyping a URL. Picking a plan also points the provider at that plan's
API-key variable — the preset's `DASHSCOPE_API_KEY` becomes `BAILIAN_TOKEN_PLAN_API_KEY`
for Token Plan, and `BAILIAN_CODING_PLAN_API_KEY` for Coding Plan. Set the variable (or a
key command / literal key) at the key prompt that follows. API keys are also bound to a
*region*, so a key issued for another region still needs the matching endpoint row.

To configure an endpoint in the config file directly, override `base_url` and
`api_key_env` (append `/compatible-mode/v1` to a workspace domain, e.g.
`https://<WorkspaceId>.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`):

```toml
[providers.qwen]                        # Token Plan, China
base_url = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
api_key_env = "BAILIAN_TOKEN_PLAN_API_KEY"
```

`kimi` is the Kimi API from platform.kimi.ai, e.g. `--model kimi/kimi-k3` or
`kimi/kimi-k2.7-code`. The preset drops `temperature` (K3 fixes it) and sets
`replay_reasoning = true`, which sends each assistant message's `reasoning_content` back
as thinking models like K3 require. Set `extra_body = { reasoning_effort = "low" }` to
make K3 think less.

### Temperature

`temperature` is a number, or `"default"` to send none so the model uses its own default.
It can be set for all models, for one provider, or for one model; the most specific
setting wins:

```toml
temperature = 0.7                       # all models

[providers.groq]
temperature = "default"                 # every groq model uses its own default

[providers.anthropic.models."claude-sonnet-4-5"]
temperature = 0.3                       # this model only
```

Some models accept no temperature, and for them the model default is the only option:
GitHub Copilot's reasoning models (GPT-5 and later, Grok, …) and any provider with
`drop_params = ["temperature"]` (such as the `kimi` preset). A number set for such a
provider or model is ignored with a warning at startup and when you switch to it; the
top-level `temperature` just doesn't apply to them. Anthropic accepts 0 to 1, so a higher
value is sent as 1, with a warning. `/context` shows the temperature in use and where it
comes from, and `/settings` edits it for the current model, its provider, or all models.

### Thinking

`thinking` sets how much the model reasons before it answers: `"default"` sends nothing
(the model decides), `"off"` turns thinking off, and a level such as `"low"`, `"medium"`,
`"high"`, `"xhigh"` or `"max"` asks for that much. Like `temperature`, it can be set for all
models, one provider or one model, and `/thinking LEVEL` overrides them for the session:

```toml
thinking = "medium"                     # all models that support it

[providers.anthropic.models."claude-opus-4-7"]
thinking = "xhigh"                      # this model only
```

A model only gets levels it supports. They come from, in order: `thinking_levels` on the
model or provider; what the endpoint reports for the model; and a built-in table
of Claude (3.7 Sonnet and later) and OpenAI reasoning models (GPT-5 and later, o1/o3/o4).
Endpoints that report levels:

- **GitHub Copilot:** `/models` lists each model's levels, read with the same request as its
  context window.
- **Ollama:** a model with the `thinking` capability (`/api/show`) gets `off`, `low`,
  `medium` and `high`. Ollama refuses a level for a model without it, so none is sent then.
- **llama.cpp:** the loaded model's chat template (`/props`) decides. A template with an
  `enable_thinking` switch (Qwen 3 and the like) gets `off` and `on`, and any named level
  turns thinking on; a template that takes `reasoning_effort` (gpt-oss) gets `low`, `medium`
  and `high`.

Ollama and llama.cpp are recognized however the provider is named, the same way as for the
context window. For other models, list the levels yourself:

```toml
[providers.together.models."deepseek-r1"]
thinking_levels = ["low", "medium", "high"]   # add "off" if thinking can be turned off
```

A level the model lacks is moved to the nearest one it has (the highest below it, else the
lowest), and a model with no known levels is sent nothing. A setting for the provider, the
model or the session warns when it is adjusted or ignored; the top-level `thinking` doesn't
warn, since it applies to every model.

How the level is sent depends on the API: `reasoning_effort` (Chat Completions, Ollama
included; Ollama ignores its native `think` flag on `/v1`), `chat_template_kwargs` for
llama.cpp (`enable_thinking`, or `reasoning_effort` for templates that take a level; it
ignores the top-level `reasoning_effort`),
`reasoning.effort` (Responses), and for Anthropic Messages adaptive thinking with
`output_config.effort`, or on Claude 3.7 to 4.5 a fixed `budget_tokens` (1024 for minimal, then
2048, 8192, 16384, 32768, 65536 up to max). The budget has to stay below `max_tokens`, so raise
`max_tokens` to use a large one. Anthropic takes no custom temperature while thinking, so
none is sent then. A matching key in the provider's `extra_body` (`reasoning_effort`, `reasoning`,
`think`, `chat_template_kwargs`, `thinking`, `output_config`) is sent instead, with a warning; the
configured level is then reported as overridden (not as sent), since the override's value is what
reaches the wire. The status bar shows
`think LEVEL` while a level is sent, `/context` shows it with where it comes from,
`/settings` sets it for the current model, its provider or all models (picking from the
levels the model supports), and the session log records it for each reply.

### Vision

`read_file` returns images (PNG, JPEG, GIF and WebP, recognised by magic bytes) to
models that can view them: the result is a short text part (`image/png, 1600×900, 131 KB`)
plus an image attachment the model sees directly. Images over the provider's limits are
downscaled first (longest side 1568 px, under the model's byte cap), and re-encoded to
JPEG/PNG when the model doesn't accept the source type. Other binary files still return
the "looks like a binary file" error, which notes whether the current model supports
images.

Whether a model can see images comes from, in order: a `vision = true|false` override
(global, `[providers.<name>]`, or `[providers.<name>.models."<model>"]`, like `thinking`);
what the endpoint reports (GitHub Copilot `/models` `capabilities.supports.vision` and its
`limits.vision`, Ollama `/api/show`'s `vision` capability, llama.cpp `/props`
`modalities.vision`); and a built-in assumption for current Anthropic and OpenAI model
families. A model that can't see images gets the text error with a hint to switch models
or set `vision = true`:

```toml
vision = true                            # all models

[providers.ollama.models."my-clip-model"]
vision = true                            # this model only
```

A request carries only the newest few images the model allows (GitHub Copilot's
`max_prompt_images`, default 1); older ones become `[image omitted: path (sent earlier)]`.
Each image counts toward the context estimate at a fixed cost from its size, so the status
bar and auto-compaction stay honest, and compaction replaces images with the same
placeholder. Images are stored once per session under `<session>.attachments/` (named by
content hash), so session logs stay small and `--resume` still works; a missing file on
resume is sent as a text placeholder.

Other per-provider fields: `replay_reasoning`, `max_tokens_param` (`max_tokens`, or `max_completion_tokens`
which is the `openai` default), `retry_initial_backoff_ms`, `retry_max_backoff_ms` and
`retryable_statuses`.

The old top-level `api_key` / `base_url` still work. They apply to `default_provider`,
which becomes `openai` if it was `mock`.

List a provider's models with `--list-models <provider>` (OpenAI-compatible endpoints,
and `github-copilot`).

### Local servers on another machine (macOS)

macOS Local Network privacy can block nano-coder from reaching a model server on your
LAN (e.g. `http://192.168.0.141:8888/v1` or `http://merlin.local:11434/v1`). Requests fail
with `tcp connect error … No route to host (os error 65)`, while `curl` to the same URL
works. `localhost` is not affected.

- Allow it in **System Settings → Privacy & Security → Local Network**. The prompt and the
  entry go to the app that launched nano-coder (your terminal, or the editor running it over
  ACP). A locally built binary is unsigned, so macOS may treat each rebuild as a new app and
  ask again.
- Or forward a local port, which needs no permission:
  `ssh -N -L 18888:localhost:8888 user@192.168.0.141` (or `socat
  TCP-LISTEN:18888,bind=127.0.0.1,fork TCP:192.168.0.141:8888`), then set
  `base_url = "http://127.0.0.1:18888/v1"`.

### GitHub Copilot (unofficial)

The `github-copilot` provider uses a GitHub Copilot subscription by authenticating **as the
VS Code Copilot Chat extension**: a device-flow login with VS Code's OAuth client ID, an
exchange for a short-lived Copilot session token, and model calls with VS Code's editor
headers. Each model is routed to the upstream API Copilot serves it through — Chat
Completions by default, the OpenAI Responses endpoint for `gpt-*`/`grok-*`/`oswe*`/`mai-*`
models (e.g. `gpt-6-astra`, which Copilot serves *only* via Responses), and the Anthropic
Messages endpoint for Claude 4.x/5.x. This is the approach several open-source agents
(e.g. pi) take, but it is **not a GitHub-sanctioned integration**. It may breach GitHub's
terms or your organisation's Copilot policy, it can break without notice, and misuse could
get an account flagged. It is never used unless you select it.

```bash
nano-coder --login github-copilot          # interactive; saves the OAuth token (0600)
nano-coder --list-models github-copilot
nano-coder --model github-copilot/gpt-4.1
```

Headless workers can't do the device flow; set `GITHUB_COPILOT_OAUTH_TOKEN` to a token from a
previous login instead (credentials live in `<data dir>/nano-coder/github-copilot.json`).
Tool follow-ups are sent with `X-Initiator: agent`, so a turn is billed like one VS Code
request. `GITHUB_COPILOT_DOMAIN` selects a GHE.com host.

The sanctioned route is the [Copilot SDK](https://github.com/github/copilot-sdk), which
drives the Copilot CLI's own agent loop rather than exposing the model.

### Retries

Retry behaviour comes from unreal-agent's retry logic (MIT). Connection errors and
HTTP 408/409/425/429/5xx/529 are retried with exponential backoff (1s doubling to
30s, minus up to 20% jitter, 5 retries). `Retry-After` headers are honoured, and so is
"try again in Xs" in rate-limit messages. Overloads (`overloaded_error`,
`server_is_overloaded`, 529) back off from 10s up to 60s. Errors that can never succeed
on retry fail immediately: authentication and permission errors, invalid requests,
`context_length_exceeded`, quota and billing errors, and policy errors.

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

## Status Line and Compaction

In an interactive terminal the bottom row shows the provider/model, the working directory
(home shown as `~`; on a narrow terminal the middle directories collapse to `…`, as in
`~/…/src/providers`, before other items are dropped), context usage
(`~` marks an estimate; without it the figure is anchored to the provider's reported usage),
a fill bar, message count, session input/output tokens, the auto-compaction threshold and
count (labelled `smart-compact` when compactions are smart, else `auto-compact`), the active mode when it is `plan` or `auto` (the default `normal` is not shown, to
save space), and what the agent is doing. With a GitHub Copilot model it also shows the session's
AI Credits (`0.4 AIC`), summed from the `total_nano_aiu` each response reports. The frame
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
    output (the whole is spilled to a file when it is longer).
  Before a smart compaction the tools are not offered, so they cost nothing.

**Extract mode** (`compaction_mode = "extract"`, or `/compact --extract`) is smart
compaction whose summary is built in code instead of by the model: no request, so it
costs no tokens and takes milliseconds. It lists the files touched, the shell commands
and how they ended, error lines and links, and the agent's last words before compacting,
each with its `(#N)`, plus the pinned requests and the plan as usual. It says where
things are rather than what they mean, so the agent leans on the history tools. An
earlier extract summary is merged rather than nested, so each section stays capped. See
[#273](https://github.com/nanobpm/nano-coder/issues/273) for its measurement against smart.

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
  [Session handles](#session-handles) for the order). An ambiguous match
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

#### Inter-session messages

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
  off or declined), or `not running` (no live socket; a stale socket file from a dead
  session is removed by the sender that finds it). The send goes through the sender's
  permission policy as a `session_send(...)` rule.

The delivered message joins the target's input labelled with its origin, e.g.
`[from session 1234abcd · ts-performance-matrix] …` (or `[from perf · ts-performance-matrix] …`
when the sender has a [handle](#session-handles)), and is logged like any input with
the sender's full session id in the record (`from_session` on the input and message). Mid-turn it is steered into the running turn; idle it starts
a turn. With `session_messages_confirm = true` (the default) the target first shows the
message and waits for its user to accept or decline. A turn that was *started by* a peer
message cannot itself call `session_send` without `confirm: true` (which asks the
target's user whatever their confirm setting) — the loop guard, so two agents can't
ping-pong. On the wire each message is one A2A-shaped JSON object per line (`role`,
`parts` with `text`, `messageId`, `contextId` = the sender's session id), so a later A2A
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

## Project Instructions

nano-coder reads the instruction files you already have for other tools, including Claude
Code's, so there is nothing to duplicate.

**Your files.** Each file in `user_instruction_files` that exists (default `~/.claude/CLAUDE.md`
and `~/.agents/AGENTS.md`) is loaded first, under a "Your instructions" heading, followed by
the rules in `user_rules_dirs` (default `~/.claude/rules`).

**The repository's files.** When a session starts, the harness looks in every directory from
the git root (the nearest ancestor containing `.git`) down to the working directory. Outside
a repository only the working directory is checked. In each directory:

- the first file found from `project_instruction_files` is used, so `AGENTS.md` wins over
  `CLAUDE.md`, then `.claude/CLAUDE.md`, then `.github/copilot-instructions.md`;
- `CLAUDE.local.md` (personal, not committed) is loaded as well, after it.

Rules in `.claude/rules/**/*.md` at the git root are loaded after the root directory's
files. These files are appended to the system prompt, root first, under a "Repository
instructions" heading that tells the model to follow them. So the model has them before it
makes any change, without having to decide to read them. Block-level `<!-- ... -->` comments
are removed first. Each file is capped at 32 KiB and the total at 64 KiB; a file over the
limit is named, with a note to read it with `read_file`.

**Edits take effect at the next turn.** Before each prompt the files are read again. If what
they add to the system prompt has changed (a file was edited, added or removed), the system
prompt is rebuilt and a dim `[instruction files changed: ...]` line says so, so there's no
need to restart and lose the conversation. Resuming a session (`--resume`) also rebuilds it
from the current files. The provider's prompt cache misses once, on the turn after a change.
Edits to rules scoped with `paths:` and the files they import are picked up too, as are edits
to nested directories' files that already attached (including a file added there). After any
change, rules and nested files attach afresh the next time a matching file is touched, so one
already in the conversation may appear once more, but never in an old version.
ACP sessions (`--acp`) still read the files once, when the session starts.

**Imports.** `CLAUDE.md`, `CLAUDE.local.md`, rules and imported files can pull in other files
with `@path`, as in Claude Code: relative to the importing file, `~/` allowed, up to four
levels deep, each file once. Code spans and fenced code blocks are skipped, `\ ` escapes a
space, and a path that doesn't exist is treated as a mention. `AGENTS.md` has no import
syntax, so `@` there is never expanded. **Imports in repository files may not leave the
repository**: a committed `CLAUDE.md` could otherwise send `~/.ssh/...` to the model provider.
They are skipped with a warning in the banner and `/context`, and so are rules that are
symlinks to files outside it. Set `instruction_imports_outside_project = true` to allow them.
Your own files can import from anywhere.

**Rules for some paths.** A rule with `paths` front matter loads only when it is needed:

```markdown
---
paths:
  - "src/api/**/*.{ts,tsx}"
---
All API endpoints must validate their input.
```

Patterns are relative to the git root (`**` crosses directories, `*` and `?` don't, `{a,b}`
alternatives).

**Deeper directories and path rules load lazily.** Instruction files deeper than the working
directory, such as `pkg/AGENTS.md`, and rules whose `paths` match are attached to the result
of the first `read_file`, `write_file`, `edit_file` or `apply_patch` call that touches a matching path, once
each. After a compaction they are attached again the next time they apply. Files that the
`bash` tool touches don't trigger this.

Instructions are read again when a session is resumed, so edits take effect. `/context` lists
the loaded files, the rules waiting for a matching path, and anything skipped. To turn loading
off (yours and the repository's), set `project_instructions = false`, or set
`AGENTIC_NO_PROJECT_INSTRUCTIONS`.

## Skills

A skill is a folder with a `SKILL.md`: YAML front matter with a `name` and a `description`,
then instructions, plus any scripts or reference files it needs. Only the name and description
of each skill go into the system prompt, under a "Skills" heading (8 KiB at most). When a task
matches one, the model calls `load_skill`, which returns the instructions (32 KiB at most),
the skill's directory, and a list of its other files for `read_file`.

Skills are found in this order, and the first skill with a given name wins:

1. **Repository**: `.agents/skills`, `.github/skills` and `.claude/skills` under the git root,
   at any depth up to four folders (`skills/<group>/<skill>/SKILL.md` works).
2. **`ai.lock`**: skills pinned by [spm](https://github.com/camunda/spm-cli). Each locked
   skill is loaded, and so is each skill bundled in a locked plugin (its
   `.claude-plugin/plugin.json` `skills` folder, default `skills/`). Hooks, commands and MCP
   servers in plugins are not loaded.
3. **User**: `~/.agents/skills`.

nano-coder reads `ai.lock` itself and never runs `spm install`, which edits the workspace
(`.gitignore`, vendor folders). Changes like that would end up in commits and PRs. Each
pinned commit is read from spm's store (`$SPM_HOME/store`, default `~/.spm/store`) if it is
there. Otherwise it is fetched once into the nano-coder cache (`<cache dir>/nano-coder/skills`).
`ai.lock` is committed to the repository, so its entries are checked the way spm checks them:
a full 40-character commit, a store key that matches the URL and commit, and paths that stay
inside the checkout. Fetches are limited to `skills.allowed_hosts` (`"file"` allows
`file://`). With `fetch = false`, only commits already in the spm store or the cache are used.
An `ai.json` without an `ai.lock` is skipped with a warning, because unpinned references are
never resolved.

Skills are found when a session starts or is resumed, and edits take effect on the next turn
without a restart: before each turn (each prompt over ACP) nano-coder stats the skill folders
and each `SKILL.md` (size and mtime; nothing is read unless something changed). When a skill
was added, removed or edited, it finds them again, rebuilds the skills index in the system
prompt and shows one dim line such as `skills: updated web; added foo; removed bar`. An
unchanged set leaves the system prompt byte-identical, so the provider's prompt cache holds.
`/skills` lists the current set. Problems are listed at startup
and by `/skills` (and returned as `_meta.skillWarnings` over ACP); they never stop a session.
To turn skills off, set `skills.enabled = false` or set `NANO_CODER_NO_SKILLS`.

## Task Plans

The `plan_*` tools give the agent a plan that lives outside the conversation. This helps most
with small context windows: the model can write down what it has done and learned, then let the
conversation be summarized without losing track.

- `plan_add` - add steps (title strings or `{title, after, note}`), and optionally set the `goal`.
  Items get numeric ids; `after` lists items that must be finished first.
- `plan_update` - set an item's `status` (`pending`, `in_progress`, `done`, `blocked`,
  `dropped`), rename it, or add a `note`. `updates: [...]` changes several items in one call.
- `plan_show` - the whole plan with every note.

Each change returns a compact checklist ending with what is in progress or ready next. A bad
call (unknown id, bad status) changes nothing.

A finished plan (every item done or dropped) is history: `plan_add` then starts a new plan
(ids from 1, new goal) and the finished one is kept in the session log as a `plan_archive`
record. Each item keeps at most 4 KB of notes; older ones are replaced by
"(older notes dropped)".

The harness keeps the plan in front of the model:
- **Compaction.** The summary message is followed by the plan with the notes of open items (up
  to 8,000 characters); finished items show only a note count (`plan_show` has every note). A
  finished plan is reduced to one line ("Previous plan '…' completed (N items)"), also when
  carried over to a new session.
- **Resume.** Every change is written to the session log, and `--resume` / `session/load`
  restore the latest plan.
- **Another worker.** ACP `session/new` can be seeded with `_meta.plan` (see ACP above). The
  model then gets the plan, and is told to check which "done" work was already committed or
  pushed.

In the terminal, normal verbosity shows plan changes as a checklist instead of tool calls
(verbose shows both). The status line shows `plan 2/5`, and `/context` and `/plan` show more.
To turn plans off, set `plan_tools = false`.

**Reminders.** A tool result can end with a `<system-reminder>` note that the model sees with
the result:
- after 12 tool calls with no plan change while items are open, naming the item in progress
  (or the next one) and asking for `plan_update`; again every 12 calls;
- once per session, after 10 tool calls in one turn with no plan, suggesting `plan_add`;
- when the model repeats the same tool call — same tool, same (normalised) arguments, same
  result — three times in a row, telling it to change approach or report `blocked`. The
  warning fires at most twice per turn; if the model keeps repeating after that, the turn
  ends with a `blocked` outcome instead of burning budget, and any remaining calls in the
  same batch are skipped rather than run. For `bash`, the match strips a trailing run of
  read-only diagnostic pipeline stages (`| wc -l`, `| head`, `| grep …`, …) off the base
  command (parsed quote- and escape-aware, so a `|` inside quotes or a `||` operator never
  splits a command), so appending `| wc -l`/`| grep …`-style stages does not dodge it while
  the stable base — which may itself contain non-diagnostic stages like `sed` — keeps
  matching. Stripping stops at the first stage that could change state (a writer like
  `tee`, a redirection, a write option such as `sort -o`, a shell control construct like
  `;`/`$(…)`, or an unrecognised command), so everything to its left stays in the
  fingerprint and genuinely different calls are never conflated. The result fingerprint
  ignores only the per-call spill filename in the output bounder's `complete output in …`
  marker (matched through its `...` terminator, so even a `session_dir` path with spaces is
  normalised; not arbitrary output that merely resembles one). The marker also carries a
  `(sha256:<digest>)` of the *complete* output, so identical runaway output is still recognised
  while a result that changes only in its truncated middle — invisible to the bounded head,
  tail and byte count — stays distinct and is never hard-stopped as a false repeat. The
  fingerprint likewise folds in each attached image's content hash, so a `read_file` of a
  changing image (whose result text is only the unchanging metadata) is told apart by the
  bytes the model actually received. Enabled
  plan, outcome and
  `question` calls break the streak (so only genuinely consecutive repeats count, and an
  interleaved such call makes the calls around it non-consecutive); when plan tools are
  *disabled* a repeated hallucinated `plan_*` call is itself detected rather than exempted.

Plan and outcome calls don't count. Set `reminders = false` to turn them off.

## Outcomes

`report_outcome` is the model's explicit end-of-task signal: `status` is `completed` (the
whole task is done and checked; the summary lists PRs or commits), `blocked` (after three
or more different failed attempts, or when only a person can unblock it; the summary says
what is needed), or `needs_input` (the model has a question or needs a decision; the summary
is the question). The call ends the turn. Other calls in the same response still run, then the
summary becomes the final answer (`Blocked: ...` / `Question: ...`), and the outcome is returned
in ACP `_meta.outcome` and recorded in the session log's `turn_end` record. If the harness
stops after the call but before the turn ends, resuming the input finishes it with the
recorded outcome without calling the model again. In the terminal the call shows as
`✔ completed`, `■ blocked`, or `? needs input` followed by the summary. Set `outcome_tool = false` to leave the
tool out.

`needs_input` is the structural "waiting on the user" signal: an orchestrator (or auto mode)
can tell it apart from a clean `completed` without guessing from the text. For a richer,
multi-choice question that does not end the turn, the model uses the `question` tool instead.

## Memory

Cross-session memory lets the model save a fact in one session and find it in later ones, so
a project's quirks and the machine's setup are not rediscovered every time ("tests run with
`cargo test`, not `make test`"; "Python comes from `uv`"). A memory is a **hint to verify, not
a rule**: entries are dated, framed in the prompt as possibly out of date, shown in the
transcript when saved, undoable with `/memory`, and never grant any permission.

Two scopes:

- `user` - the machine and your habits (toolchains, auth, preferences).
- `project` - keyed by the git remote (fallback: the git root path); this repo's quirks and
  setup. Unavailable outside a git repository.

Storage mirrors the session log's format but not its write pattern: each scope is a JSONL
file, one entry per line, under `<memory_dir>/user.jsonl` and `<memory_dir>/projects/<key>.jsonl`
(default `<data>/memory`, next to `sessions/`). Every save, matching search, expiry prune, and
forget **atomically rewrites** the complete scope (write a sibling temp file, then rename) rather
than appending, so do not infer session-log-style append behaviour or append-write performance.
Each entry has an id, the text, created and last-used dates, the source session, and optional
evidence (a file path or command). Search is a case-insensitive regex
over the text and the optional evidence, as in `history_search` - no embeddings or vector
store.

**Tools** (offered when `memory` is on):
`memory_save(scope, text, evidence?, kind?, anchors?, entities?, fact_kind?, supersedes?, valid_while?, distinct?)`,
`memory_search(pattern?, scope?, entity?, fact_kind?)`, `memory_forget(id)`, `memory_verify(id)`,
`memory_entity(scope, entity?, alias?, relation?, target?)`.

**Entities, kinds and supersession.** All of these fields are optional; entries saved
before they existed load unchanged.

- `entities`: what the fact is about, as typed ids `type:name` with `type` one of `host`,
  `service`, `repo`, `tool`, `person`, `workflow`, `other` (e.g. `host:merlin`). Names are
  lower-cased and trimmed; an unknown type is an error.
- `fact_kind`: `fact`, `procedure`, `decision`, `pitfall`, `preference` or `pointer`. (`kind`,
  `hint` or `rule`, still decides how the memory is recalled.)
- `valid_while`: free text saying when the fact holds (e.g. `nano-workforce >= 0.216`).
- `verified_at`: the date the fact was saved or last re-checked; `memory_verify(id)` bumps it.
- `supersedes`: ids of memories the new one replaces. A replaced memory stays in the file
  (with `superseded_by`) and can still be read with `memory_search` on its exact id, but it is
  never recalled, shown in the index or `/memory`, or matched by other searches.
- **Entity registry:** each scope has an `entities.jsonl` (`<memory_dir>/entities.jsonl` for
  `user`, `projects/<key>.entities.jsonl` for a project) listing each entity's id, aliases
  (`merlin.local`, `merlin.ts` for `host:merlin`) and relations (`runs_on`, `reached_via`,
  `part_of`). `memory_save` registers entities it hasn't seen; an alias resolves to its entity
  on save and search. `memory_entity` adds an alias or a relation, or with no change lists the
  registry (or one entity).
- **Conflict check on save** (no model call): saving the same text and evidence as a current
  memory is refused with the existing id. A memory sharing an entity and `fact_kind` (missing
  counts as `fact`) that is a near-duplicate (word overlap ≥ 60%) or a likely contradiction
  (a shared anchor such as a host or path) is listed back to the model instead of saving; it
  saves again with `supersedes: [ids]` or `distinct: true`.
- `memory_search` filters by `entity` (an alias works) and `fact_kind`, and each hit ends with
  `{kind; entities; verified date}`. A search result is capped at 8,000 bytes.

**Recall from tool calls.** After a tool runs, memories relevant to its arguments are attached
to the result as a `<system-reminder>` note. With `memory_recall = "entity"` (the default) the
call resolves to the entities it touches — hosts (URLs, `ssh`/`scp` targets), repos (`-R o/r`,
the working directory's git remote) and the tool (the command name) — through the registry's
aliases, following `reached_via` / `runs_on` / `part_of` one hop
(`merlin.local:8080` → `host:merlin` and the services on it). At most 3 facts within 1,500 bytes
are recalled, ranked: rules first, then `fact_kind` weighted by context (`pitfall` and
`procedure` for command execution, `decision` and `preference` when planning or editing), then
`verified_at` recency, then last-used. A superseded memory is never recalled, a hint already in
context is not repeated, and an entity's other facts stay quiet for a few calls once one was
recalled (unless a different fact would be chosen). Memories with no entities yet keep the older
anchor-substring recall, so nothing regresses before they are migrated. The note names the
entity that triggered it (`📌 host:merlin — …`), and `/memory entities` lists each entity's
facts. Set `memory_recall = "anchor"` to compare or roll back to the pre-entity substring match.

**Migrating existing memories.** Memories saved before entities existed have no entities or
`fact_kind`, and may include duplicates and facts a later note contradicts. `/memory migrate`
(or `nano-coder --memory-migrate` from a shell) tidies them with the model's help:

- Untagged entries not reviewed before are sent to the session's model in batches of at most
  12 KB, each with a capped (6 KB) digest of the already-tagged entries. The model proposes,
  per entry, entities and a `fact_kind`, and across the batch and the tagged set, duplicates to
  merge and stale entries to supersede (naming the newer entry and why). Invalid proposals
  (unknown ids, bad entity types) are dropped and counted.
- Each batch's proposals are listed for review: **Accept all**, **Review each** (accept, skip
  or edit each item: a tag's entities and kind, a merge's text), **Skip this batch**, or
  **Stop** (resume later). Nothing changes without a confirmation.
- A merge keeps the chosen entry with the better text and the union of the anchors, evidence
  and entities; the duplicates and superseded entries stay on disk marked replaced
  (`superseded_by`), so they are never recalled or listed but remain readable by id.
- Before the first applied change, the memory files are copied to
  `<memory dir>/backups/migrate-<timestamp>/` and the path is printed. To undo, copy the files
  from there back into the memory directory.
- Progress is recorded in `<memory dir>/migrate-progress.json` after each batch, so an
  interrupted or stopped migration resumes where it left off, and a re-run only looks at
  entries that are still untagged and were saved since (skipped batches are not offered again;
  delete the progress file to review everything once more).
- `--dry-run` (`/memory migrate --dry-run`, `nano-coder --memory-migrate --dry-run`) writes the
  proposals to `<memory dir>/migrate-dry-run-<timestamp>.json` and changes nothing; it also
  works when memory is read-only. Applying needs memory `on` and, in the REPL, an interactive
  terminal outside Plan mode.

**Prompt.** A capped, dated index (most-recently-used first, ~4 KB with the guidance) is
appended to the system prompt at session start, framed as "notes from earlier sessions; may be
out of date; verify before relying on them". The rest is reachable with `memory_search`.

**What gets saved.** When saving is possible, the prompt says what is worth saving, even
before anything has been saved (adapted from Claude Code's auto memory):

- **Save:** corrections you give and approaches you confirm; your preferences; decisions and
  context the code and git history don't record; where to find things outside the repository;
  setup that was costly to work out.
- **Skip:** what the code, git history or instruction files already say, one-off debugging,
  session logs, and secrets.

Asking the model to remember something saves it. Asking for it to go in `AGENTS.md` or
`CLAUDE.md` edits that file instead. Once per session, after 30 tool calls without a save,
a reminder asks whether anything durable is worth saving (`reminders = false` turns
reminders off).

**Control and hygiene.**

- Each save is confirmed to the model (`remembered (scope, id): ...`), so it shows in the
  transcript. `/memory` lists every entry with its id; `/memory forget <id>` deletes one; the
  files are human-readable and can be edited directly.
- Obvious secrets (keys, tokens, passwords, `.env`-style assignments, private-key blocks) are
  rejected on save - store where to find them instead.
- Using an entry (a `memory_search` match) in a writable session bumps its last-used date;
  read-only and Plan-mode searches never bump it. Entries unused for
  `memory_expiry_days` (default 90; `0` disables) expire on the next load.
- Memories never touch the permission rules.

Set `memory = "on"` (full), `"read_only"` (index and `memory_search` only), or `"off"`.
Headless/ACP runs downgrade `on` to `read_only` by default, since no human vets a save live.

#### Session handles

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

## Sessions

When `persist_sessions` is on, each conversation is written to `<session_dir>/<id>.jsonl`.
The file is an append-only log whose first record is a versioned header, followed by
`input`, `message`, `turn_end` and `replace` (compaction / system-prompt reset) records.
Resume a session with `--resume <id>` or ACP `session/load`.
Record times and each message's `timestamp` are RFC 3339 with the local UTC offset
(for example `2026-09-24T13:02:12.44+12:00`). Older logs with UTC times still load.

- Truncated tool output is kept whole in `<session_dir>/<id>.spill/`, so the paths in the
  log stay valid after the process exits (temporary directory when sessions are not persisted).
- An unsupported format version is an explicit error on resume.
- Only records ending in a newline count as committed. A half-written last line from a
  crash is discarded and truncated before the next write.
- Tool calls left without results by a crash get a synthetic error result when the session
  is loaded, so the conversation stays valid for providers.
- Input IDs are remembered. Redelivering a completed input returns its recorded response.
  Redelivering an input whose turn was interrupted resumes that turn without duplicating
  the user message.
- To keep the log small, a compaction records only the user requests it adds to the
  pinned block (a `pinned_base` delta, not the whole stash), and plan changes are logged
  as deltas with a full snapshot every 20 changes.
- At startup, logs idle for `session_compress_after_days` (default 14) are gzipped in
  place (`<id>.jsonl.gz`); `--resume`, the picker, `--list-sessions`, `--trajectory` and
  the history tools read them transparently, and resuming one decompresses it back.
  `session_retention_days` (default 0 = keep forever) deletes logs untouched that long,
  except named sessions (a title or a handle). The tidy-up runs at most once a day and never touches a log a
  running session holds open.

## Herdr

Run inside a [Herdr](https://herdr.dev) pane (`HERDR_ENV=1`, `HERDR_PANE_ID` and
`HERDR_BIN_PATH` set), the interactive CLI reports itself to Herdr: `working` while a
turn runs, `blocked` while a question or the turn limit waits for you, and `idle` at the
prompt. A saved session is reported with the command that resumes it
(`nano-coder --resume <id> --model <provider/model>`, plus `--config` if given), so Herdr
can reopen it after a restart (Herdr 0.9.2 or later). A session with a
[handle](#session-handles) shows it as the pane's agent label and reports a `name` token, re-sent each turn in case something else in the pane cleared it.
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

## Formal Verification

`tla/` holds TLA+ specifications of ACP turn routing (steer, cancel, deferred
messages) and of session-log crash recovery, model-checked with TLC. Run
`tla/check.sh` (needs Java and `tla2tools.jar`); see `tla/README.md` for the
properties and findings.

## Extending

### Adding Tools

```d
agent.tools.register(ToolDefinition("my_tool", "Description of what the tool does",
    parseJSON(`{"type": "object", "properties": { ... }}`)),
    (JSONValue args) {
        // Tool implementation; the string is what the model sees.
        return "result";
    });
```

### Observing the agent

Pass your own `AgentEvents` to `agent.run`:

```d
class Logger : AgentEvents
{
    void toolStart(const ref ToolCall call) { writeln("About to call tool: ", call.name); }
    // text, toolEnd, usage, userMessage, assistantMessage ...
}
```

These callbacks observe only; to block, modify, or add context to a tool call
or prompt, use the external Claude-compatible user hooks described under
[Lifecycle Hooks](#lifecycle-hooks).

### Custom LLM Client

Implement the `LLMClient` interface (`nano/llm.d`), or add a provider in `nano/providers/`:

```d
class MyClient : LLMClient
{
    LLMResponse chat(const ref ChatRequest req, StreamSink sink) { /* req.messages, req.tools, ... */ }
    string[] listModels() { return ["my-model"]; }
    string modelName() const { return "my-model"; }
    string providerName() const { return "mine"; }
}
```

## Acknowledgements

Retry classification, output bounding, bash result formatting and the session-log design
are adapted from [unreal-agent](https://github.com/unreallabsai/unreal-agent)
(MIT, Copyright (c) 2026 Unreal Labs). System reminders and the outcome tool follow ideas in
[grok-build](https://github.com/xai-org/grok-build)'s `<system-reminder>` notes and
`update_goal` tool. The permission model (deny wins, allow rules must cover every command in
a chain, wrappers stripped before matching) and the Seatbelt/Landlock sandbox profiles follow
grok-build's and Codex's designs.
