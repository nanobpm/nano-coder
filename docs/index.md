---
title: "nano-coder"
description: "What nano-coder is, how to install it and how to run it for the first time."
order: 1
section: "Get started"
---

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
[Building and Running](../README.md#building-and-running).

```sh
nano-coder --help
```

`cargo install nano-coder` still installs the last Rust release (0.69), which is no longer updated.

## First run

Set an API key and pick a model (see [Providers and models](providers.md)):

```sh
export ANTHROPIC_API_KEY=...
nano-coder --model anthropic/claude-sonnet-4-5          # interactive
nano-coder --model anthropic/claude-sonnet-4-5 -p "Summarize this repository"   # one prompt, then exit
```

Without a configured model nano-coder runs on the offline `mock` provider, so you can try the
interface without a key. Put the model you use in `~/.config/nano-coder/config.toml`
(`model = "anthropic/claude-sonnet-4-5"`, see [Configuration](configuration.md)) to drop the flag.

nano-coder has two execution modes:

- **[Interactive](interactive.md)** (the default): a terminal UI where you chat with the agent,
  steer it mid-turn and use [slash commands](commands.md).
- **[Headless (ACP)](acp.md)** (`--acp`): JSON-RPC 2.0 over stdio, for orchestrators running
  fleets of workers.

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

## Where to go next

| Page | What it covers |
|---|---|
| [Interactive mode](interactive.md) | keys, steering and queueing, output, terminal status |
| [Headless mode (ACP)](acp.md) | the protocol, workers, exit status |
| [Providers and models](providers.md) | presets, custom endpoints, temperature, thinking, vision, Copilot, retries |
| [Built-in tools](tools.md) | shell, files, search, web and the agent's other tools |
| [Permissions and sandbox](permissions-sandbox.md) | rules, guards and the OS sandbox |
| [Sessions and updates](sessions.md) | logs, resuming, titles, updating |
| [Context and compaction](context-compaction.md) | status line, compaction, cross-session history |
| [Project instructions and skills](instructions-skills.md) | AGENTS.md, rules, skills |
| [Task plans and outcomes](plans-outcomes.md) | plan tools, report_outcome |
| [Memory](memory.md) | cross-session memory |
| [Sub-agents](sub-agents.md) | the `agent` tool, background sub-agents |
| [Session handles and messages](messaging.md) | naming sessions, inter-session messages |
| [Lifecycle hooks](hooks.md) | user hooks |
| [Herdr](herdr.md) | Herdr pane integration |
| [Slash commands](commands.md) | every `/command` |
| [Configuration](configuration.md) | every config key |
| [Command-line flags](cli.md) | every flag |
| [Troubleshooting](troubleshooting.md) | errors, logs and files |
