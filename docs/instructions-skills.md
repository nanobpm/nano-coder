---
title: "Project instructions and skills"
description: "AGENTS.md and friends, and SKILL.md folders loaded on demand."
order: 9
section: "Using nano-coder"
---

# Project instructions and skills

Tell the agent how to work in your repository with instruction files, and give it on-demand know-how with skills.

## Project Instructions

nano-coder reads the instruction files you already have for other tools, including Claude
Code's, so there is nothing to duplicate.

**Your files.** Each file in `user_instruction_files` that exists (default `~/.claude/CLAUDE.md`
and `~/.agents/AGENTS.md`) is loaded first, under a "Your instructions" heading, followed by
the rules in `user_rules_dirs` (default `~/.claude/rules`).

**The repository's files.** When a session starts, the harness looks in every directory from
the git root (the nearest ancestor containing `.git`, not climbing into a directory listed in
`GIT_CEILING_DIRECTORIES`, as git itself does) down to the working directory. Outside
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
