# nano-coder in D: porting status

`d/` is a D reimplementation of nano-coder. It builds with LDC and dub, and it
runs alongside the Rust crate at the repo root. The Rust crate is still the
reference implementation, and the port reads the same `~/.config/nano-coder/config.toml`.

```sh
cd d
dub test                 # unit tests (all modules)
dub build -b release     # ./nano-coder-d
./nano-coder-d -p "list the *.d files here"
```

LDC is used because DMD has no Apple Silicon target. You need libcurl,
which macOS and most Linux distributions already have.

## What works (the core loop)

| D module | Rust source | Status |
|---|---|---|
| `nano/toml.d` | (the `toml` crate) | A TOML subset with tables, dotted/quoted keys, all string forms, ints, floats, bools, arrays, inline tables and arrays of tables. Values come back as a std.json tree. |
| `nano/config.d` | `config.rs`, `providers/mod.rs` (presets, `parse_model_spec`, resolve) | Supports `model`, `default_provider`, `temperature`, `max_tokens`, `system_prompt`, `max_iterations` and `bash_timeout_secs`. `[providers.*]` supports kind, base_url, api_key / api_key_env / api_key_command, default_model, headers, extra_body, drop_params, max_tokens_param, stream, temperature, timeout_secs and max_retries. Built-in presets are included. Any other key is ignored. |
| `nano/http.d` | `providers/retry.rs`, transport | Uses libcurl (std.net.curl). It has an idle timeout via the low-speed limit and backoff retries on 408/409/429/5xx and connection errors (streams retry only before their first byte), plus an incremental SSE parser. |
| `nano/llm.d` | `llm.rs` | Message, ToolCall (invalid-argument preservation), LLMResponse, ChatRequest, the `LLMClient` interface and `ThinkSplitter`. |
| `nano/providers/openai.d` | `providers/openai.rs`, `providers/github_copilot.rs` | Chat Completions, streaming and non-streaming. It handles streamed tool calls, `reasoning_content`, `<think>` splitting and usage. The Copilot client exchanges the OAuth token, sends editor headers and sets X-Initiator. Copilot always goes through `/chat/completions`. |
| `nano/providers/anthropic.d` | `providers/anthropic.rs` | Messages API, streaming and non-streaming. It merges parallel tool results into one turn, puts cache_control on the system prompt and the latest message, and counts cached tokens in usage. |
| `nano/providers/mock.d` | `providers/mock.rs` | A scripted client for tests. Unlike the Rust mock, it has no keyword triggers. |
| `nano/tools/package.d` | `tools.rs`, `output.rs` | The registry, argument helpers, and head/tail truncation that spills the full output to a file. |
| `nano/tools/bash.d` | `bash.rs` | `bash -c` runs in its own session. The timeout kills the whole process group, and stdout and stderr are captured to files. |
| `nano/tools/files.d` | `files.rs` | `read_file`, `write_file` and `edit_file` with the same schemas. Writes and edits are refused if the file wasn't read first or has changed since. Fuzzy matching ignores trailing whitespace, then indentation. Images are reported as unsupported. |
| `nano/tools/search.d` | `search.rs` | `grep` and `glob` with the same schemas. They honour nested .gitignore files and skip `.git`, symlinks and binary files. Results are sorted and capped. |
| `nano/shell.d` | `shell.rs` | The shell word/redirect/heredoc parser the guards inspect. |
| `nano/paths.d` | `std::path` usage in `permissions.rs` | Lexical path semantics (components, normalize, parent, starts_with) plus symlink resolution. |
| `nano/cmdexpand.d` | `permissions.rs` 548–2549 | Expands commands for inspection: wrappers, nested `bash -c`, loops, option scans, containers, heredocs, assignments and loop-bound variables. `Blocked` is Rust's `Err(String)`. |
| `nano/guard.d` | `permissions.rs` 2549–3320 | The built-in guards: root/home/workspace deletes, devices, protected branches, databases, `cd` tracking. |
| `nano/permissions.d` | `permissions.rs` 1–547 | Rules (`Bash`/`Read`/`Edit`/tool names, `:*` prefixes, `**` paths), deny, then allow, then guards, `readDenied`, `ruleMatches`, `validateRule`. Also plan mode, which Rust handles in the agent. Bad rules are rejected at startup. |
| `nano/permissions_test.d` | `permissions.rs` tests | 46 of the 47 Rust tests, translated one to one. `sandbox_confines_file_tools` is left out (no sandbox). |
| `nano/control.d` | `TurnControl` in `agent.rs` | Cancel and steer. Ctrl-C cancels a running turn: libcurl aborts through its progress callback, bash kills the process group, and remaining tool calls are recorded as cancelled. In a TTY, a line typed mid-turn becomes a steer that joins the next model call; if it arrives too late it runs as the next prompt. A `/command` waits for the turn to end. |
| `nano/acp.d` | `acp.rs` | `--acp`: the Agent Client Protocol over stdio (`initialize`, `session/new`, `session/load` with history replay, `session/prompt`, `session/cancel`). A reader thread routes cancels and steers while a turn runs, defers everything else, and requeues late steers at the position they arrived. Prompts can run `/tools`, `/settings` and `/model`; other `/…` prompts are rejected and `//…` sends a literal slash. Not ported: `/compact`, `/plan`, `/providers` over ACP, `_meta.projectInstructions`, input IDs. Hooks load per session (`session/load` runs `SessionStart` with source `resume`). |
| `nano/skills.d` | `skills.rs` | Skills: `SKILL.md` folders in the repo (`.agents`/`.github`/`.claude` skills under the git root, confined to it), `ai.lock` entries and plugins (spm store, else a git fetch into the cache, from `allowed_hosts` only, with spm's lock validation), and `~/.agents/skills`. The index goes into the system prompt; `load_skill` returns the body and lists the skill's files. `[skills]` config. All Rust tests ported. |
| `nano/claude_hooks.d` | `claude_hooks.rs` | Claude Code-compatible command hooks from nano's `[hooks]`, `~/.claude/settings.json` and the project's `.claude/settings{,.local}.json`: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` (at most 3 blocks per turn). Matchers on Claude or nano tool names, `if` permission-rule filters checked at load, dedup, shell and exec forms, `${CLAUDE_PROJECT_DIR}`. Runs each hook in its own session through a single-threaded `poll` loop with bounded output; a PreToolUse hook that crashes, times out, overflows or leaves a descendant holding its pipes fails closed. PreToolUse rewrites are checked against the policy again. `--no-hooks`, `disable_hooks`, `disable_project_hooks`, `claude_user_hooks`, `/hooks`, the startup notice. All Rust tests ported. Project hooks run inside an active sandbox; user hooks don't. The internal registry (`hooks.rs`) isn't needed: D reports through `AgentEvents`. |
| `nano/memory.d`, `nano/memsecret.d` | `memory.rs` | Cross-session memory: `memory_save`/`memory_search`/`memory_forget`, user and project scopes (project key = normalised git remote with credentials stripped, else the git root), the Rust store layout and JSONL format in the same default directory (both ports share one store), `flock`ed atomic owner-only rewrites that keep unparsed lines byte for byte, expiry, the capped prompt index, and the secret filter. Read-only for ACP, `-p`, piped stdio and plan mode. `/memory [forget ID]`. All Rust tests ported (the secret and remote cases are generated from the Rust assertions). |
| `nano/sandbox.d` | `sandbox.rs` | `[sandbox]` (`mode` off/workspace/read-only, `writable`, `network`, `tool_caches`), `--sandbox`, `NANO_CODER_SANDBOX`. Bash commands and project hooks run under `sandbox-exec` with Rust's Seatbelt profile; writable roots are the workspace, its git dirs (poisoned `.git` pointers rejected, linked worktrees accepted), temp dirs, tool caches (plus `~/.dub`), device nodes and extras, never `/`. Fails closed when it can't apply. A failed command that looks sandbox-denied gets a note describing the roots. Rust's tests are ported and run against the real sandbox. Linux Landlock isn't ported. |
| `nano/session.d` | `session.rs`, `session_index.rs` and `resume.rs` (partly), `instructions.rs` (partly) | Rust's log format, version 1: `session`, `input`, `message` (with timestamp, usage, duration and stop reason), `turn_end` and `replace` records. A torn last line is dropped and truncated. Writes a `hooks` audit record (files, sources, content hashes identical to Rust's). Reading skips `plan`/`hooks` and keeps message fields D doesn't model. `--resume [id\|last]` (`last` = newest session in this cwd) and `--list-sessions [--all] [--json]`. Also AGENTS.md/CLAUDE.md from the git root down to the cwd, plus `~/.config/nano-coder/AGENTS.md`. Tested both ways: Rust lists and resumes D logs, and D resumes Rust logs. |
| `nano/agent.d` | `agent.rs` (core loop only) | Runs model call → tools → results until done or `max_iterations`. It gives specific advice for invalid arguments, unknown tools and blocked calls. |
| `app.d` | `main.rs`, `ui.rs` (minimal) | Flags: `--model`, `--config`, `-p`, `--resume`, `--plan`, `--allow`, `--deny`, `--list-models`, `--list-sessions`, `--acp`, `--no-session`, `--verbose`, `--version`. A plain readln REPL with `/model`, `/plan`, `/normal`, `/clear`, `/usage` and `/quit`. Piped stdin runs one prompt per line. |

Sessions are written to `nano-coder-d/sessions` under the platform data
directory (override with `NANO_CODER_D_SESSIONS`). The format is the same as Rust's, so pointing this at the Rust
directory works; it's kept separate by default so the port can't damage real sessions.

## Known differences from the Rust version

- **Sessions.** No index cache (`.index.jsonl`), titles, interactive picker,
  `--trajectory`, spill files or attachments. A crashed turn is reported on
  resume but not re-run.
- **Interrupts.** Ctrl-C cancels a turn and typed lines steer it (`nano/control.d`),
  but there is no prompt queue UI.
- **Copilot routing.** Every model goes through Chat Completions. Rust sends
  some models to Responses or Anthropic Messages (`copilot_api_for_model`).
- **Anthropic** has only unit tests. The Copilot/OpenAI path was tested live.

## Not ported yet (by Rust module)

Roughly in dependency order. Sizes are Rust lines.

1. **Agent loop features** (`agent.rs`, 11.1k). Context accounting and
   auto-compaction (`context.rs` 0.7k, `history.rs` 0.6k for smart compaction's
   history tools), system reminders (`reminders.rs` 1.8k), turn caps and
   modes (`mode.rs`), the editable `/queue` (`queue.rs` 0.3k), and `report_outcome`
   (`goal.rs`).
2. ~~**Permissions vs. sandbox**~~: file-tool writes are held to the sandbox's writable roots (lexical and symlink-resolved path), as in Rust.
3. ~~**Sandbox**~~: Seatbelt done in `nano/sandbox.d`. Still to do: the Linux Landlock backend (until then the D build fails closed on Linux when a sandbox is configured).
4. **Providers.** OpenAI Responses (`openai_responses.rs` 1.0k), Copilot model routing
   and login (`--login`, device flow), Muse (`muse.rs` 1.9k), Qwen
   (`qwen.rs` 0.3k), and capability detection (context window, thinking levels,
   vision) from `providers/mod.rs` 1.9k and `llm.rs`.
5. **Thinking, temperature and vision settings**, including per-model
   `[providers.X.models."M"]` (`thinking.rs` 2.2k, `temperature.rs` 0.6k, `vision.rs` 0.5k).
6. **Image attachments** (`attachment.rs` 1.1k), for `read_file` images.
7. **Instructions, full version** (`instructions.rs` 2.0k): `@path` imports,
   rules dirs with `paths:` front matter, nested files attached when touched,
   and the import-escape guard.
8. ~~**Skills**~~ (`skills.rs` 0.9k): done in `nano/skills.d`. ~~**Memory**~~ (`memory.rs` 3.2k): done in `nano/memory.d`. Still to do: **plan tools**
   (`plan.rs` 0.6k) and the **question tool** (`question.rs` 0.4k).
9. ~~**Hooks**~~: done in `nano/claude_hooks.d` (project hooks run inside the sandbox).
10. **Sessions, rest** (`session_index.rs` cache and titles, `resume.rs` picker,
    `trajectory.rs` 1.3k). The format and `--list-sessions` are done.
11. ~~**ACP server**~~ (`acp.rs` 0.9k): done in `nano/acp.d`, except the commands listed above.
12. **Terminal UI** (`lineedit.rs` 3.3k, `frame.rs` 1.4k, `status.rs` 1.1k,
    `ui.rs` 3.0k, `input_history.rs`, `commands.rs` 0.6k, `turn_commands.rs`
    0.5k, `recents.rs`, `settings.rs` 2.2k): the raw-mode line editor, frame
    renderer, status bar, slash-command menu and `/settings`.
13. **Packaging**: npm platform packages and release workflow for the D binary.

Notes for porting:
- Keep tool names, schemas and error wording identical to Rust. Models and
  nano-workforce depend on them.
- Each D module has its tests in `unittest` blocks. Port the Rust tests along
  with the code.
