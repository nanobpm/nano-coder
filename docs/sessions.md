---
title: "Sessions and updates"
description: "Session logs, resuming, titles, updating nano-coder and what changed after an update."
order: 7
section: "Using nano-coder"
---

# Sessions and updates

Every session is logged, so you can resume it later, here or from another directory. This page also covers updating nano-coder.

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

## Resuming a session

For example:

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

## Titles

**Titles.** With `session_titles = true`, once a session has a prompt that says something (not
just "hi"), nano-coder asks the model for a title of at most six words in the background. It uses
`title_model` (a cheap one is enough) or the session's model. The request is a few hundred tokens
(counted in the status line's token and AI Credit totals once it finishes),
tried at most once per session per run (so a failed or deleted title is retried after a restart,
not on the next turn). The picker then shows `title · last prompt`. Titles live only in the index,
so older nano-coders can still read the logs. Deleting `.index.jsonl` loses them; a new run then
asks again on the session's next turn.

## Updating

`/update` updates the installation the running binary came from. For npm it reads the install
prefix from the executable's path (`<prefix>/lib/node_modules/@nanobpm/…`, following the global
`bin/nano-coder` link) and runs `npm install -g --prefix <prefix> @nanobpm/nano-coder@latest`, so
a copy installed with `--prefix ~/.local`, under nvm or volta, is updated in place even when
`npm config get prefix` points elsewhere. For Homebrew it reads the prefix from the keg
(`<prefix>/Cellar/nano-coder/…`) and runs that prefix's own `<prefix>/bin/brew` (the `brew` on
PATH only when the prefix has none). A release tarball or a local build is never changed.

Before running anything, `/update` checks that the current user can write the install location
(npm: `<prefix>/lib/node_modules` and `<prefix>/bin`; Homebrew: `<prefix>/Cellar` and the tap
checkout). If it can't, for example a root-owned `/usr/lib/node_modules`, it runs nothing and
prints the folder and the exact command to run by hand (`sudo npm install -g --prefix /usr
@nanobpm/nano-coder@latest`, or for Homebrew the command to run as the user that owns the
installation). The running session is unchanged.

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
