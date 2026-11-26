---
title: "Configuration"
description: "The config file, an annotated example and every key."
order: 21
section: "Reference"
---

# Configuration

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
session_messages_max_hops = 4           # loop guard: refuse sends beyond this many hops in a message thread
session_messages_max_per_hour = 10      # loop guard: max messages to one session per hour (0 = no cap)
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
compaction_summary_dag = false          # layered, expandable summaries (see Smart compaction)
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

[terminal]
program_status = true                   # report the session's state to the terminal (OSC 7501, see Terminal Status)

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

## Key reference

<!-- BEGIN GENERATED: config -->
<!-- Generated by scripts/gen-reference.sh from `nano-coder --dump-reference`; edit the code, not this block. -->

| Key | Type | Default | Description |
|---|---|---|---|
| `model` | string | `"gpt-4o-mini"` | The `provider/model` to use (on the offline `mock` provider by default) |
| `default_provider` | string | `"mock"` | Provider for a model with no known provider prefix |
| `temperature` | float | `0.7` | Sampling temperature, or `"default"` to send none |
| `max_tokens` | integer | `0` | Most tokens per reply (0: the provider's default) |
| `thinking` | string |  | Thinking level for models that reason (see Thinking) |
| `vision` | boolean |  | Whether the model accepts images (default: guessed from the model name) |
| `context_window` | integer |  | Override the model's context window, in tokens |
| `max_iterations` | integer | `0` | LLM calls per user input (0 = unbounded; headless runs get a 300-call safety cap) |
| `system_prompt` | string |  | Replace the built-in system prompt |
| `timestamps` | boolean | `true` | Prefix CLI messages with the local time (HH:MM:SS) |
| `verbosity` | string | `"normal"` | quiet \| normal \| verbose \| debug (or `--verbosity`) |
| `renderer` | string |  | Retired: only `"frame"` remains; any other value prints a warning |
| `api_key` | string |  | Legacy: API key for the default provider (prefer `[providers.<name>]`) |
| `base_url` | string |  | Legacy: base URL for the default provider (prefer `[providers.<name>]`) |
| `bash_timeout_secs` | integer | `600` | Default timeout of a bash call |
| `bash_heartbeat_secs` | integer | `0` | Interval of the supervisor-visible "still running" note of a long bash call (0: the built-in interval; or NANO_CODER_BASH_HEARTBEAT_SECS) |
| `plan_tools` | boolean | `true` | Offer the plan_* tools (see Task Plans) |
| `outcome_tool` | boolean | `true` | Offer report_outcome (see Outcomes) |
| `reminders` | boolean | `true` | Append &lt;system-reminder&gt; notes to tool results |
| `verify_before_complete` | boolean | `true` | Remind the agent to verify edits before it finishes |
| `check_updates` | boolean | `true` | Check for a newer release at startup |
| `show_release_notes` | boolean | `true` | After an update, show what changed |
| `persist_sessions` | boolean | `true` | Write a session log |
| `session_dir` | string |  | Where session logs go (default: &lt;platform data dir&gt;/nano-coder/sessions) |
| `session_compress_after_days` | integer | `14` | Gzip logs idle this long at startup (0 = never) |
| `session_retention_days` | integer | `0` | Delete logs untouched this long (0 = keep; named sessions are kept) |
| `session_titles` | boolean | `false` | Ask the model for a few-word title per session (`--resume` picker) |
| `title_model` | string |  | Model for titles (default: the session's model) |
| `cross_session_history` | boolean | `true` | sessions_list and a session argument on the history tools: read other sessions' logs |
| `session_messages` | boolean | `false` | Listen for messages from other sessions and offer session_send |
| `session_messages_confirm` | boolean | `true` | Ask before an incoming session message is queued or run |
| `session_messages_max_hops` | integer | `4` | Loop guard: refuse sends beyond this many hops in a message thread |
| `session_messages_max_per_hour` | integer | `10` | Loop guard: most messages to one session per hour (0 = no cap) |
| `acp_session_messages` | boolean | `false` | Let `--acp` sessions send and receive messages |
| `subagents` | boolean | `true` | Offer the `agent` tool: read-only sub-agents with their own context |
| `subagent_model` | string |  | Model for sub-agents (default: the session's; a call may name one) |
| `subagent_max_concurrency` | integer | `4` | Sub-agents running at once |
| `subagent_timeout_secs` | integer | `600` | Per sub-agent wall-clock cap |
| `subagent_max_turns` | integer | `40` | Per sub-agent turn cap |
| `subagent_max_tokens` | integer | `1000000` | Per sub-agent token cap |
| `subagent_models[].model` | string |  | A model a sub-agent call may pick |
| `subagent_models[].use` | string |  | When to pick it, shown to the agent |
| `subagent_models[].timeout_secs` | integer |  | This model's wall-clock cap |
| `subagent_models[].max_turns` | integer |  | This model's turn cap |
| `subagent_models[].max_tokens` | integer |  | This model's token cap |
| `auto_compact` | boolean | `true` | Summarize automatically when the context fills up |
| `auto_compact_threshold` | float | `0.8` | Fraction of the context window that triggers compaction |
| `compaction_mode` | string | `"smart"` | smart \| standard \| extract |
| `compaction_pin_requests` | boolean | `true` | Keep the user's requests verbatim through compaction |
| `compaction_summary_dag` | boolean | `false` | Layered, expandable summaries |
| `idle_compact` | boolean | `true` | Compact while the session is idle, before the prompt cache expires |
| `idle_compact_hold_secs` | integer |  | How long an idle session waits before it compacts |
| `project_instructions` | boolean | `true` | Load AGENTS.md and friends |
| `project_instruction_files` | array | `["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", ".github/copilot-instructions.md"]` | Instruction files looked for in each directory |
| `user_instruction_files` | array | `["~/.claude/CLAUDE.md", "~/.agents/AGENTS.md"]` | Your own instruction files, for every project |
| `user_rules_dirs` | array | `["~/.claude/rules"]` | Directories of your rule files |
| `instruction_imports_outside_project` | boolean | `false` | Let project @imports and rule links leave the repository |
| `disable_hooks` | boolean | `false` | Run no user hooks (as `--no-hooks`) |
| `disable_project_hooks` | boolean | `false` | Ignore the repository's .claude/settings*.json hooks |
| `claude_user_hooks` | boolean | `true` | Load hooks from ~/.claude/settings.json |
| `hooks` | table |  | Hooks in Claude Code's format, as in .claude/settings.json |
| `memory` | string | `"on"` | on \| read_only \| off: cross-session memory |
| `memory_dir` | string |  | Where memories are kept (default: &lt;platform data dir&gt;/nano-coder/memory) |
| `memory_expiry_days` | integer | `90` | Expire memories unused this long (0 = never) |
| `memory_recall` | string | `"entity"` | entity \| anchor: how tool calls recall memories |
| `terminal.program_status` | boolean | `true` | Report the session's state to the terminal (OSC 7501) |
| `skills.enabled` | boolean | `true` | Load skills |
| `skills.dirs` | array | `[".agents/skills", ".github/skills", ".claude/skills"]` | Skill directories, relative to the git root |
| `skills.user_dirs` | array | `["~/.agents/skills"]` | Your own skill directories |
| `skills.ai_lock` | boolean | `true` | Load skills pinned in ai.lock |
| `skills.fetch` | boolean | `true` | Fetch ai.lock commits missing from the spm store |
| `skills.allowed_hosts` | array | `["github.com"]` | Hosts ai.lock entries may be fetched from ("*" = any) |
| `permissions.builtin_rules` | boolean | `true` | Block destructive commands unless allowed |
| `permissions.allow` | array | `[]` | Allow rules, e.g. `["Bash(sqlite3 test.db *)"]` |
| `permissions.deny` | array | `[]` | Deny rules, e.g. `["Bash(git push:*)", "Edit(**/.env)"]` |
| `permissions.protected_branches` | array | `["main", "master", "trunk", "develop"]` | Branches git commits and pushes to need approval on |
| `sandbox.mode` | string |  | off \| workspace \| read-only (or `--sandbox`); unset: workspace headless, off interactive |
| `sandbox.writable` | array | `[]` | Extra writable paths |
| `sandbox.network` | boolean | `true` | false blocks outbound connections |
| `sandbox.tool_caches` | boolean | `true` | Workspace mode: allow ~/.cargo/registry, ~/.npm, ~/.cache, ... |
| `web.search` | string |  | brave \| searxng: the web_search backend (unset: no web_search) |
| `web.api_key` | string |  | Brave API key (prefer api_key_env) |
| `web.api_key_env` | string |  | Environment variable holding the Brave API key |
| `web.api_key_command` | string |  | Command printing the Brave API key |
| `web.searxng_url` | string |  | Base URL of a SearXNG instance |
| `web.fetch` | boolean | `true` | Offer web_fetch |
| `web.allowed_hosts` | array | `[]` | Hosts web_fetch may reach (empty: any public host); `*.example.com` matches subdomains |
| `web.denied_hosts` | array | `[]` | Hosts web_fetch never reaches |
| `web.allow_private` | boolean | `false` | Let web_fetch reach private and local addresses |
| `web.max_result_bytes` | integer | `32768` | Most bytes of text a web tool returns per call |
| `web.max_download_bytes` | integer | `5242880` | Most bytes web_fetch downloads |
| `web.timeout_secs` | integer | `20` | Seconds a web request may take |
| `providers.<name>.kind` | string |  | openai \| anthropic \| github-copilot \| mock: the API it speaks |
| `providers.<name>.base_url` | string |  | The endpoint |
| `providers.<name>.api_key` | string |  | A literal key (prefer api_key_env) |
| `providers.<name>.api_key_env` | string |  | Environment variable holding the key |
| `providers.<name>.api_key_command` | string |  | Command printing the key, used when the variable is unset |
| `providers.<name>.default_model` | string |  | Model used by `--model <name>` |
| `providers.<name>.headers` | table |  | Extra HTTP headers |
| `providers.<name>.extra_body` | table |  | Merged into every request body |
| `providers.<name>.drop_params` | array |  | Request parameters to leave out, e.g. `["temperature"]` |
| `providers.<name>.max_tokens_param` | string |  | Name of the max-tokens parameter, e.g. `max_completion_tokens` |
| `providers.<name>.context_window` | integer |  | Context window of this provider's models |
| `providers.<name>.stream` | boolean | `true` | Stream replies |
| `providers.<name>.temperature` | float |  | Temperature for this provider's models |
| `providers.<name>.thinking` | string |  | Thinking level for this provider's models |
| `providers.<name>.vision` | boolean |  | Whether this provider's models accept images |
| `providers.<name>.thinking_levels` | array |  | The thinking levels its models support |
| `providers.<name>.models` | table |  | Per-model settings (see providers.&lt;name&gt;.models.&lt;model&gt;.*), or a list of model names |
| `providers.<name>.list_models` | string | `"endpoint"` | endpoint \| configured: where the model picker's list comes from |
| `providers.<name>.disabled` | boolean | `false` | Hide the provider and refuse its models |
| `providers.<name>.hidden` | boolean | `false` | Hide the provider from listings |
| `providers.<name>.timeout_secs` | integer |  | Idle timeout: most silence between streamed bytes (unset: 120) |
| `providers.<name>.max_retries` | integer | `5` | Retries of a failed request |
| `providers.<name>.retry_initial_backoff_ms` | integer |  | First retry delay |
| `providers.<name>.retry_max_backoff_ms` | integer |  | Longest retry delay |
| `providers.<name>.retryable_statuses` | array |  | HTTP statuses that are retried |
| `providers.<name>.replay_reasoning` | boolean | `false` | Send each assistant message's reasoning_content back |
| `providers.<name>.models.<model>.temperature` | float |  | Temperature for this model |
| `providers.<name>.models.<model>.thinking` | string |  | Thinking level for this model |
| `providers.<name>.models.<model>.vision` | boolean |  | Whether this model accepts images |
| `providers.<name>.models.<model>.thinking_levels` | array |  | The thinking levels this model supports |
| `providers.<name>.models.<model>.name` | string |  | Display name in the model picker |
| `providers.<name>.models.<model>.base_url` | string |  | Endpoint for this model, overriding the provider's |

<!-- END GENERATED -->
