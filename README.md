# nano-coder

**A 6MB coding agent. Run a fleet on your laptop.**

nano-coder is a coding agent for the terminal, written in Rust. It uses about 6MB of resident memory, where Node-based agent CLIs take 150–660MB, so you can run dense fleets of agent workers on one machine. It runs interactively, or headless over ACP as a worker for [nano-workforce](https://github.com/nanobpm/nano-workforce) via c8ctl-nano.

## Install

```sh
npm install -g @nanobpm/nano-coder   # prebuilt binaries for macOS and Linux (x64, arm64)
cargo install nano-coder             # or build from source
```

## Features

- **Interactive CLI**: REPL-based interface for conversing with the agent
- **ACP Protocol**: JSON-RPC 2.0 over stdio for headless orchestration (c8ctl-nano compatible)
- **Providers**: OpenAI-compatible and Anthropic endpoints (remote or local), selected per model as `provider/model`, with retry/backoff
- **Tool Calling**: Agent can invoke registered tools during conversation, including a real `bash` tool with timeouts and bounded output
- **Sessions**: Append-only JSONL session logs with resume and input-ID deduplication
- **Lifecycle Hooks**: 6 hook events for observing/intercepting agent behavior
- **Configuration**: TOML-based config file at `~/.config/nano-coder/config.toml`
- **Commands**: `/help`, `/compact`, `/context`, `/verbosity`, `/settings`, `/tools`, `/skills`, `/exit`
- **Streaming output**: answers stream in, thinking shows collapsed (Ctrl-O expands it), tool calls show inline
- **Status line** pinned to the bottom of the terminal, plus manual and automatic context compaction
- **Task plans**: `plan_*` tools keep a plan with notes outside the conversation, so long tasks survive compaction, resume and a change of worker
- **Project instructions**: `AGENTS.md` (or `CLAUDE.md`, `.github/copilot-instructions.md`) from the repository is added to the system prompt
- **Skills**: `SKILL.md` folders from the repository, `~/.agents/skills`, and an spm `ai.lock`, loaded on demand with `load_skill`

## Two Execution Modes

### Interactive CLI Mode (default)

```bash
cargo run
```

Starts the interactive REPL where you can chat with the agent and use slash commands.

While a turn is running you can type a message and press Enter to **steer** it: the
message joins the conversation before the next model call (even if the model had
just produced its final answer, the turn continues with the steer). **Esc Esc** (twice within a second) or **Ctrl-C** cancels
the running turn, killing any running bash command; a second Ctrl-C at the prompt exits.
With piped (non-terminal) stdin, lines read during a turn are queued as later prompts.

### ACP Headless Mode (--acp flag)

```bash
cargo run -- --acp
```

Speaks the Agent Communication Protocol (ACP) over stdio using newline-delimited JSON-RPC 2.0 messages. Compatible with c8ctl-nano's `spawnCaptureAcp` executor.

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
- `session/cancel` → cancels the current turn (normally sent as a notification, which
  gets no reply). The running model call is abandoned, a running bash command is
  killed, remaining tool calls are recorded as cancelled, and the turn's
  `session/prompt` resolves with `stopReason: "cancelled"`

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
`_meta.outcome`: `{"status": "completed" | "blocked", "summary": "..."}`. A client can use it
instead of guessing from the stop reason: `blocked` means the model needs help (an
escalation). Redelivering the input returns the same outcome. See [Outcomes](#outcomes).

**Slash commands work via ACP too:**
- `/compact [focus]` - summarizes the conversation; the result has `compacted`, `before`,
  `after`, `tokensBefore`, `tokensAfter`, `summarized` and `fallback`
- `/settings` - returns current settings as JSON
- `/tools` - lists registered tools
- `/plan` - returns `plan` (JSON) and `text` (the rendered plan)
- `/providers` - lists providers
- `/model provider/model` - switches model

## Architecture

```
src/
├── main.rs      # Single binary entry point (interactive + ACP modes)
├── agent.rs     # Agent core: conversation management, tool execution loop
├── acp.rs       # ACP JSON-RPC protocol handler
├── hooks.rs     # Lifecycle hook registry and event system
├── tools.rs     # Tool registration and dispatch system
├── llm.rs       # Provider-neutral messages and the async LLMClient trait
├── providers/   # Provider registry + presets, HTTP transport with retries
│   ├── openai.rs    # OpenAI Chat Completions (and compatible servers)
│   ├── anthropic.rs # Anthropic Messages API
│   ├── github_copilot.rs # UNOFFICIAL Copilot-subscription provider
│   ├── retry.rs     # Retry classification and backoff
│   └── mock.rs      # Offline scripted client
├── bash.rs      # bash tool: timeout, file capture, bounded output
├── files.rs     # read_file / write_file / edit_file tools
├── output.rs    # Head/tail output bounding, spilling long output to disk
├── session.rs   # Versioned append-only JSONL session log
├── context.rs   # Token accounting, context-window heuristics, overflow detection
├── status.rs    # Bottom-of-terminal status line
├── ui.rs        # Verbosity levels and the streaming output renderer
├── lineedit.rs  # Key-by-key prompt input (Ctrl-O, steering on the status line)
├── instructions.rs # AGENTS.md / CLAUDE.md discovery for the system prompt
├── plan.rs      # Task plan and the plan_add / plan_update / plan_show tools
├── goal.rs      # report_outcome tool (completed / blocked)
├── commands.rs  # Slash-command table for /help and the as-you-type menu
├── skills.rs    # SKILL.md discovery, ai.lock sources and the load_skill tool
├── reminders.rs # <system-reminder> notes appended to tool results
├── settings.rs  # /settings menu and config-file writer
└── config.rs    # Configuration file loading and management
```

Mode selection: `--acp` flag enables ACP headless mode; default is interactive CLI.

## Lifecycle Hooks

The harness exposes 6 lifecycle hook events:

| Hook | When it fires |
|------|---------------|
| `before_context_load` | Before processing user input |
| `after_context_load` | After adding user message to conversation |
| `before_llm_send` | Before sending messages to LLM |
| `after_llm_response` | After receiving LLM response |
| `before_tool_call` | Before executing a tool |
| `after_tool_call` | After tool execution completes |

## Built-in Tools

- `get_time` - Get current date and time
- `echo` - Echo back input text
- `bash` - Run `bash -c <command>` (stdin closed, own process group). Arguments:
  `command`, optional `timeout_seconds` (default `bash_timeout_secs`, 600) and
  `max_output_length` (default 40,000, max 1,000,000 characters each for stdout and stderr).
  Returns stdout, then `Stderr:` and `Exit code: N` when relevant, or `(no output)`.
  Long output keeps its head and tail with `...N bytes truncated; complete output in <path>...`;
  the full capture stays in that file.
- `read_file` - Numbered lines of a text file; `path`, optional `offset` (1-based) and `limit`
  (default 2000 lines). Refuses binary files.
- `write_file` - Create or overwrite a file (`path`, `content`), creating parent directories.
- `edit_file` - Replace exact text (`path`, `old_string`, `new_string`, optional `replace_all`).
  Fails unless `old_string` matches exactly once (or `replace_all` is set).
- `plan_add`, `plan_update`, `plan_show` - The agent's task plan (see [Task Plans](#task-plans)).
- `report_outcome` - Report the task `completed` or `blocked`, with a `summary`; ends the turn
  (see [Outcomes](#outcomes)).
- `load_skill` - Return a skill's instructions and list its other files; `name`. Offered only
  when skills were found (see [Skills](#skills)).

Any other tool's result longer than 40,000 characters is cut the same way as bash output,
with the whole result saved under the temp directory (`nano-coder-<pid>/tool-<id>-<name>.txt`)
and its path in the marker. `read_file` pages instead.

Relative paths resolve against the working directory (ACP `session/new` `cwd`). Writes are
atomic (temp file + rename). There is no permission prompt: run workers in a disposable
workspace.

## Commands

Typing `/` at the prompt lists the commands under it, and each further character narrows the
list. Tab completes the command, or the part all matches share. Esc hides the list. The
list is built from the same table as `/help` (`src/commands.rs`).

- `/help` - Show available commands
- `/compact [focus]` - Summarize older messages with the current model, keeping the latest
  message. Optional text tells the summary what to focus on. Esc Esc or Ctrl-C cancels
- `/verbosity [quiet|normal|verbose|debug]` - Show or set how much is printed (see below)
- `/context` - Show context usage, window, session token totals, auto-compaction state and the loaded instruction files
- `/settings` - Interactive settings menu:
  - **Model**: pick a provider, then a model from its live model list (or type an ID)
  - **Add or edit a provider**: name, API kind (OpenAI-compatible, Anthropic, Copilot),
    base URL, key source (env var, shell command, or a literal key; the file is then
    written with mode 0600) and default model
  - temperature, max tokens, system prompt
  - **Context**: auto-compaction on/off, threshold, context-window override
  - **Verbosity**
  - **Save to config file**: writes only the keys you changed into the config file
    (`--config` or `~/.config/nano-coder/config.toml`), keeping comments and
    other settings. Leaving with unsaved changes asks whether to save
- `/tools` - List registered tools
- `/skills` - List the skills the agent can load, where each lives, and any loading warnings
- `/plan` - Show the agent's task plan with all notes
- `/model [provider/model]` - Show or switch the model (conversation is kept)
- `/providers` - List providers, endpoints and whether their API key is available
- `/session` - Show the session ID and log path
- `/exit` - Exit the agent

## Building and Running

```bash
cargo build --release
./target/release/nano-coder
```

Or run directly:

```bash
cargo run
cargo run -- --model anthropic/claude-sonnet-4-5
cargo run -- --model ollama/qwen2.5:1.5b
cargo run -- --resume sess-20260923T012518-7e7923f8
```

Flags: `--login github-copilot`, `--list-models PROVIDER`, `--acp`, `--model provider/model` (or `AGENTIC_HARNESS_MODEL`), `--resume SESSION_ID`,
`--config PATH`, `--verbosity LEVEL` (`-v`).

## Configuration

Create `~/.config/nano-coder/config.toml` (every field is optional). Directories from before the rename (`agentic-harness`) are still used if the new ones don't exist:

```toml
model = "anthropic/claude-sonnet-4-5"   # provider/model
default_provider = "mock"               # used when the model has no known provider prefix
temperature = 0.7
max_tokens = 4096
max_iterations = 50                     # LLM calls per user input
system_prompt = "You are a helpful assistant with access to tools."
bash_timeout_secs = 600
persist_sessions = true
# session_dir = "/path/to/sessions"    # default: <platform data dir>/nano-coder/sessions
auto_compact = true                     # summarize automatically when the context fills up
auto_compact_threshold = 0.8            # fraction of the context window
# context_window = 128000               # override the window (providers can set it too)
verbosity = "normal"                    # quiet | normal | verbose | debug (or --verbosity)
project_instructions = true             # load AGENTS.md etc. (see Project Instructions)
project_instruction_files = ["AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md"]
plan_tools = true                       # offer the plan_* tools (see Task Plans)
outcome_tool = true                     # offer report_outcome (see Outcomes)
reminders = true                        # append <system-reminder> notes to tool results

[skills]                                # see Skills
enabled = true
dirs = [".agents/skills", ".github/skills", ".claude/skills"]   # relative to the git root
user_dirs = ["~/.agents/skills"]
ai_lock = true                          # load skills pinned in ai.lock
fetch = true                            # fetch ai.lock commits missing from the spm store
allowed_hosts = ["github.com"]          # hosts ai.lock entries may be fetched from ("*" = any)
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
| `qwen` | openai | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
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
timeout_secs = 300
max_retries = 3
```

`qwen` is Qwen Cloud (Alibaba Cloud Model Studio), e.g. `--model qwen/qwen3.8-max`. The
preset uses the Singapore endpoint. API keys are bound to a region, so for another region
or your workspace domain override `base_url`, e.g.
`https://dashscope-us.aliyuncs.com/compatible-mode/v1` or
`https://<WorkspaceId>.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`.

`kimi` is the Kimi API from platform.kimi.ai, e.g. `--model kimi/kimi-k3` or
`kimi/kimi-k2.7-code`. The preset drops `temperature` (K3 fixes it) and sets
`replay_reasoning = true`, which sends each assistant message's `reasoning_content` back
as thinking models like K3 require. Set `extra_body = { reasoning_effort = "low" }` to
make K3 think less.

Other per-provider fields: `replay_reasoning`, `max_tokens_param` (`max_tokens`, or `max_completion_tokens`
which is the `openai` default), `retry_initial_backoff_ms`, `retry_max_backoff_ms` and
`retryable_statuses`.

The old top-level `api_key` / `base_url` still work. They apply to `default_provider`,
which becomes `openai` if it was `mock`.

List a provider's models with `--list-models <provider>` (OpenAI-compatible endpoints and
`github-copilot`).

### GitHub Copilot (unofficial)

The `github-copilot` provider uses a GitHub Copilot subscription by authenticating **as the
VS Code Copilot Chat extension**: a device-flow login with VS Code's OAuth client ID, an
exchange for a short-lived Copilot session token, and Chat Completions calls with VS Code's
editor headers. This is the approach several open-source agents (e.g. pi) take, but it is
**not a GitHub-sanctioned integration**. It may breach GitHub's terms or your organisation's
Copilot policy, it can break without notice, and misuse could get an account flagged. It is
never used unless you select it.

```bash
nano-coder --login github-copilot          # interactive; saves the OAuth token (0600)
nano-coder --list-models github-copilot
nano-coder --model github-copilot/gpt-4.1
```

Headless workers can't do the device flow; set `GITHUB_COPILOT_OAUTH_TOKEN` to a token from a
previous login instead (credentials live in `<data dir>/nano-coder/github-copilot.json`).
Tool follow-ups are sent with `X-Initiator: agent`, so a turn is billed like one VS Code
request. `GITHUB_COPILOT_DOMAIN` selects a GHE.com host. Models that Copilot serves only
through its Responses API are not supported.

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

**Thinking.** Reasoning streams as a single line that updates in place
(`∴ Thinking: ...`) and becomes `∴ Thought for 3.1s · 812 chars` when the answer starts.
**Ctrl-O** switches to showing thinking in full, including the block that is streaming. At
the prompt it prints the last thinking in full. Press it again to collapse. Reasoning is read
from `reasoning_content` / `reasoning` fields (DeepSeek, llama.cpp, vLLM, OpenRouter, Ollama),
from `<think>...</think>` in the content, and from Anthropic `thinking` blocks. Anthropic
thinking blocks are kept with the conversation so tool use keeps working when thinking is
enabled (e.g. `extra_body = { thinking = { type = "enabled", budget_tokens = 4000 } }`).

**Tool calls** show as `● bash ls -la`, then `⎿` with the first line of the result (or the
error).

**Input.** On a terminal, input is read key by key. While a turn runs, what you type shows
on the status line; Enter sends it as a steer, Esc Esc or Ctrl-C cancels the turn. The prompt supports
Backspace, Ctrl-U (clear), Ctrl-W (delete word) and Ctrl-D (exit on an empty line).

Streaming uses server-sent events. Set `stream = false` on a provider whose endpoint doesn't
support it. ACP mode doesn't stream text, but sends each response's reasoning as an
`agent_thought_chunk` update.

## Status Line and Compaction

In an interactive terminal the bottom row shows the provider/model, context usage
(`~` marks an estimate; without it the figure is anchored to the provider's reported usage),
a fill bar, message count, session input/output tokens, the auto-compaction threshold and
count, and what the agent is doing. It uses a terminal scroll region, follows resizes, and is
off when stdin/stdout isn't a TTY or `AGENTIC_NO_STATUS` is set.

The context window comes from, in order: `context_window` in the config, `context_window`
on the provider, a built-in table of known models, then 128k. If a provider rejects a
request as too long, the harness takes the limit from the error, compacts, and retries once.

Compaction asks the current model to summarize older messages, keeping the recent tail
(up to 20k tokens, never starting at a tool result). Auto-compaction runs before a model
call when usage passes the threshold. It won't run again until the context has grown by
another 10% of the window, so a context that can't shrink isn't summarized on every call.
If summarizing fails, the older messages are dropped with a note. The session log records
the new conversation, so `--resume` continues from it.

## Project Instructions

When a session starts, the harness looks for instruction files in every directory from the
git root (the nearest ancestor containing `.git`) down to the working directory. Outside a
repository only the working directory is checked. In each directory the first file found from
`project_instruction_files` is used, so `AGENTS.md` wins over `CLAUDE.md`, which wins over
`.github/copilot-instructions.md`. The files are appended to the system prompt, root first,
under a "Repository instructions" heading that tells the model to follow them. So the model
has them before it makes any change, without having to decide to read them. Each file is
capped at 32 KiB and the total at 64 KiB.

Instruction files deeper in the tree than the working directory, such as `pkg/AGENTS.md`,
are loaded lazily. The first time `read_file`, `write_file` or `edit_file` touches a path
under such a directory, its instructions are appended to that tool result, once per
directory. After a compaction they are attached again the next time they apply. Files that
the `bash` tool touches don't trigger this.

Instructions are read again when a session is resumed, so edits to `AGENTS.md` take effect.
`/context` lists the loaded files. To turn loading off, set `project_instructions = false`,
or set `AGENTIC_NO_PROJECT_INSTRUCTIONS`.

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

Skills are found again when a session starts or is resumed. Problems are listed at startup
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

The harness keeps the plan in front of the model:
- **Compaction.** The summary message is followed by the full plan with notes (up to 8,000
  characters; notes on finished items go first when it's too long).
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
- once per session, after 10 tool calls in one turn with no plan, suggesting `plan_add`.

Plan and outcome calls don't count. Set `reminders = false` to turn them off.

## Outcomes

`report_outcome` is the model's explicit end-of-task signal: `status` is `completed` (the
whole task is done and checked; the summary lists PRs or commits) or `blocked` (after three
or more different failed attempts, or when only a person can unblock it; the summary says
what is needed). The call ends the turn. Other calls in the same response still run, then the
summary becomes the final answer (`Blocked: ...` for blocked), and the outcome is returned
in ACP `_meta.outcome` and recorded in the session log's `turn_end` record. If the harness
stops after the call but before the turn ends, resuming the input finishes it with the
recorded outcome without calling the model again. In the terminal the call shows as
`✔ completed` or `■ blocked` followed by the summary. Set `outcome_tool = false` to leave the
tool out.

## Sessions

When `persist_sessions` is on, each conversation is written to `<session_dir>/<id>.jsonl`.
The file is an append-only log whose first record is a versioned header, followed by
`input`, `message`, `turn_end` and `replace` (compaction / system-prompt reset) records.
Resume a session with `--resume <id>` or ACP `session/load`.

- An unsupported format version is an explicit error on resume.
- Only records ending in a newline count as committed. A half-written last line from a
  crash is discarded and truncated before the next write.
- Tool calls left without results by a crash get a synthetic error result when the session
  is loaded, so the conversation stays valid for providers.
- Input IDs are remembered. Redelivering a completed input returns its recorded response.
  Redelivering an input whose turn was interrupted resumes that turn without duplicating
  the user message.

## Formal Verification

`tla/` holds TLA+ specifications of ACP turn routing (steer, cancel, deferred
messages) and of session-log crash recovery, model-checked with TLC. Run
`tla/check.sh` (needs Java and `tla2tools.jar`); see `tla/README.md` for the
properties and findings.

## Extending

### Adding Tools

```rust
let tool_def = ToolDefinition::new(
    "my_tool",
    "Description of what the tool does",
    json!({ "type": "object", "properties": { ... } })
);
agent.tools().register(tool_def, Box::new(|args| {
    // Tool implementation
    Ok(json!({ "result": "..." }))
}));
```

The model sees a JSON string result as plain text and any other value as serialized JSON.

### Adding Hooks

```rust
agent.hooks().register(HookEvent::BeforeToolCall, Box::new(|ctx| {
    let tool_name = ctx.data.get("tool_name").and_then(|v| v.as_str());
    println!("About to call tool: {}", tool_name);
}));
```

### Custom LLM Client

Implement the async `LLMClient` trait (or add a `ProviderKind` in `src/providers/`):

```rust
#[async_trait::async_trait]
impl LLMClient for MyClient {
    async fn chat(&self, request: &ChatRequest<'_>) -> Result<LLMResponse> {
        // request.messages, request.tools, request.temperature, request.max_tokens
    }
    fn model_name(&self) -> &str { "my-model" }
    fn provider_name(&self) -> &str { "mine" }
}
```

## Acknowledgements

Retry classification, output bounding, bash result formatting and the session-log design
are adapted from [unreal-agent](https://github.com/unreallabsai/unreal-agent)
(MIT, Copyright (c) 2026 Unreal Labs). System reminders and the outcome tool follow ideas in
[grok-build](https://github.com/xai-org/grok-build)'s `<system-reminder>` notes and
`update_goal` tool.
