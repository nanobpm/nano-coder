---
title: "Lifecycle hooks"
description: "Claude Code\u2013compatible user hooks and the internal agent events."
order: 14
section: "Using nano-coder"
---

# Lifecycle hooks

Hooks run your commands at points in the agent's lifecycle: before and after tool calls, at the end of a turn, and more.

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
