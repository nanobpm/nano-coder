---
title: "Permissions and sandbox"
description: "Allow and deny rules, the built-in guards and the OS sandbox."
order: 6
section: "Using nano-coder"
---

# Permissions and sandbox

Every tool call passes deny rules, allow rules and built-in guards, and shell commands can run in an OS sandbox. This page explains the rules and how to configure them.

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
