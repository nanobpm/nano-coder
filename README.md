# nano-coder

**A 4MB coding agent. Run a fleet on your laptop.**

nano-coder is a coding agent for the terminal, written in D. It uses about 4MB of memory, so you
can run dense fleets of agent workers on one machine. It runs interactively, or headless over ACP
as a worker for [nano-workforce](https://github.com/nanobpm/nano-workforce) via c8ctl-nano.

## Install

```sh
npm install -g @nanobpm/nano-coder       # prebuilt binaries for macOS and Linux (x64, arm64)
brew install nanobpm/tap/nano-coder      # the same binaries through Homebrew
```

The Linux binaries need glibc 2.35+ and the system libcurl. To build from source, see
[Building and Running](#building-and-running).

## Quick start

```sh
export ANTHROPIC_API_KEY=...
nano-coder --model anthropic/claude-sonnet-4-5            # chat in the terminal
nano-coder --model anthropic/claude-sonnet-4-5 -p "Fix the failing test"   # one prompt, then exit
nano-coder --acp                                          # headless worker (JSON-RPC over stdio)
```

Type `/help` at the prompt for the commands.

## Documentation

The user documentation lives in [`docs/`](docs/index.md) and is published for the latest
release at https://nanobpm.io/nano-coder/docs/.

- [Getting started](docs/index.md)
- [Interactive mode](docs/interactive.md) and [headless mode (ACP)](docs/acp.md)
- [Providers and models](docs/providers.md)
- [Built-in tools](docs/tools.md)
- [Permissions and sandbox](docs/permissions-sandbox.md)
- [Sessions and updates](docs/sessions.md)
- [Context and compaction](docs/context-compaction.md)
- [Project instructions and skills](docs/instructions-skills.md)
- [Task plans and outcomes](docs/plans-outcomes.md)
- [Memory](docs/memory.md)
- [Sub-agents](docs/sub-agents.md)
- [Session handles and messages](docs/messaging.md)
- [Lifecycle hooks](docs/hooks.md)
- [Herdr](docs/herdr.md)
- Reference: [slash commands](docs/commands.md), [configuration](docs/configuration.md),
  [command-line flags](docs/cli.md), [troubleshooting](docs/troubleshooting.md)

The rest of this README is for contributors.

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

## Building and Running

You need [LDC](https://github.com/ldc-developers/ldc) 1.43+ and dub, plus the libcurl
development headers on Linux.

```bash
dub build -b release   # ./nano-coder
./nano-coder
```

The build passes `-lowmem` to LDC (GC during compilation), which roughly halves its peak memory so it fits on small machines and alongside other builds.

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
N slowest modules. `NANO_TEST_ONLY=nano.skills,nano.trust` runs only the named modules. The
runner gives each run its own TMPDIR and makes it a git ceiling directory, so a host whose temp
directory sits inside a git checkout (a Nano Workforce worker's does) cannot leak that checkout into
the tests; `scripts/ci.sh` reruns the modules that read the home directory and repositories with a
populated fake HOME and such a TMPDIR. `NANO_TEST_JOBS=N` runs modules in parallel (`scripts/ci.sh` uses 4); modules
that change process-wide state (the cancel flag, environment variables) are listed in
`scripts/serial-tests` and run alone first. A module still running at twice its most-scaled limit
(at least 10 s) is treated as hung: the runner names it and exits failing instead of waiting
forever. In tests, HTTP retries wait out an unreachable server for at most 10 s (in use the wait is
unbounded until Ctrl-C). `NANO_TEST_STUCK=1` adds a module that never returns, to check the
watchdog (`ci.sh` does).

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

### Documentation

User-visible behaviour is documented in `docs/` (one page per topic, front matter with
`title`, `description`, `order` and `section`; links between pages are relative `.md`
links). The website publishes `docs/` from the latest release tag. The reference tables in
`docs/cli.md`, `docs/commands.md`, `docs/tools.md` and `docs/configuration.md` are generated
from `nano-coder --dump-reference` (the flag table in `source/app.d`, `nano.commands.commands`,
the tool definitions and `nano.config_keys.configKeys`): run `scripts/gen-reference.sh` after
`dub build -b release` whenever you change a flag, command, tool or config key. `scripts/ci.sh`
fails when docs/ is out of date, and checks every relative link and anchor in README.md and
docs/ (`scripts/check-docs.py`).


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
[Lifecycle Hooks](docs/hooks.md#lifecycle-hooks).

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
