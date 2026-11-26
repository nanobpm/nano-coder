---
title: "Troubleshooting"
description: "Network errors, authentication, sandbox denials, and where logs and session files are."
order: 30
section: "Reference"
---

# Troubleshooting

When something goes wrong, start here: the common errors, what they mean, and where
nano-coder keeps its files.

## Where files are

`<data dir>` below is `~/Library/Application Support` on macOS and `$XDG_DATA_HOME`
(default `~/.local/share`) on Linux.

| What | Where |
|---|---|
| Config | `~/.config/nano-coder/config.toml` (or `--config PATH`), see [Configuration](configuration.md) |
| Session logs | `<data dir>/nano-coder/sessions/<id>.jsonl` (or `session_dir`), see [Sessions](sessions.md#sessions) |
| Session index (picker cache) | `.index.jsonl` in the session directory; rebuilt if deleted, but session titles live only there, so back it up first (deleting it loses them) |
| Memories | `<data dir>/nano-coder/memory` (or `memory_dir`), see [Memory](memory.md) |
| GitHub Copilot credentials | `<data dir>/nano-coder/github-copilot.json` |
| Last version run | `<data dir>/nano-coder/last_version` |
| Trusted repositories | `~/.config/nano-coder/trusted-projects` |

`/session` prints the current session's id and log path. `nano-coder --trajectory <id>`
replays a session turn by turn (`--json` or `--markdown` to export), which is usually the
quickest way to see what the agent did and why a call failed.

## Network errors

Connection errors and HTTP 408/409/425/429/5xx/529 are retried with backoff (see
[Retries](providers.md#retries)). If every retry fails:

- Check the provider's `base_url` (`/providers` lists them) and that the host is reachable.
- A local server on another machine (Ollama, llama.cpp) must listen on the network, not
  only on localhost: see [Local servers on another machine](providers.md#local-servers-on-another-machine-macos).
- A slow model that is silent for a long time hits the idle timeout; raise the
  provider's `timeout_secs`.
- In the `workspace` or `read-only` sandbox, `network = false` blocks outbound connections
  from shell commands (not from nano-coder's own model calls).

## Authentication

Authentication and permission errors are not retried. A provider's key comes from the
variable named by `api_key_env` (the preset's, e.g. `ANTHROPIC_API_KEY`), from
`api_key_command` (used when the variable is unset), or from a literal `api_key`. Check that the variable is exported in the shell that starts nano-coder,
and that the key matches the endpoint (for example, a Model Studio key is bound to a region:
see [Providers](providers.md)). For GitHub Copilot, run `nano-coder --login github-copilot`
again, or set `GITHUB_COPILOT_OAUTH_TOKEN` for headless workers.

## Sandbox and permission denials

A tool result that says a call was denied comes from one of three places, checked in this
order (see [Permissions and sandbox](permissions-sandbox.md)):

1. a `deny` rule in `[permissions]` or `--deny`;
2. a built-in guard (destructive commands, protected branches) that no `allow` rule covers;
3. the OS sandbox: a write outside the workspace and the `writable` paths fails with
   "Operation not permitted" or "Permission denied".

Add an `allow` rule (or `--allow RULE`) for a command you want to permit, add a path to
`[sandbox] writable`, or pick another mode with `--sandbox`. In plan mode every mutating
tool is refused; `/mode normal` (or Shift+Tab) leaves it.

## Skills or hooks don't load

A repository's own skills and `.claude/settings*.json` hooks load only once you trust it:
an interactive start asks "Trust this repo?", while `-p` and piped runs skip them. Use
`--yolo` to trust without asking. `/skills` and `/hooks` list what loaded.
