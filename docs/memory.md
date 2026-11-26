---
title: "Memory"
description: "Facts the agent saves across sessions, and how to review, migrate and forget them."
order: 11
section: "Using nano-coder"
---

# Memory

nano-coder can remember facts between sessions: corrections, preferences and setup that was costly to discover.

Cross-session memory lets the model save a fact in one session and find it in later ones, so
a project's quirks and the machine's setup are not rediscovered every time ("tests run with
`cargo test`, not `make test`"; "Python comes from `uv`"). A memory is a **hint to verify, not
a rule**: entries are dated, framed in the prompt as possibly out of date, shown in the
transcript when saved, undoable with `/memory`, and never grant any permission.

Two scopes:

- `user` - the machine and your habits (toolchains, auth, preferences).
- `project` - keyed by the git remote (fallback: the git root path); this repo's quirks and
  setup. Unavailable outside a git repository.

Storage mirrors the session log's format but not its write pattern: each scope is a JSONL
file, one entry per line, under `<memory_dir>/user.jsonl` and `<memory_dir>/projects/<key>.jsonl`
(default `<data>/memory`, next to `sessions/`). Every save, matching search, expiry prune, and
forget **atomically rewrites** the complete scope (write a sibling temp file, then rename) rather
than appending, so do not infer session-log-style append behaviour or append-write performance.
Each entry has an id, the text, created and last-used dates, the source session, and optional
evidence (a file path or command). Search is a case-insensitive regex
over the text and the optional evidence, as in `history_search` - no embeddings or vector
store.

**Tools** (offered when `memory` is on):
`memory_save(scope, text, evidence?, kind?, anchors?, entities?, fact_kind?, supersedes?, valid_while?, distinct?)`,
`memory_search(pattern?, scope?, entity?, fact_kind?)`, `memory_forget(id)`, `memory_verify(id)`,
`memory_entity(scope, entity?, alias?, relation?, target?)`.

**Entities, kinds and supersession.** All of these fields are optional; entries saved
before they existed load unchanged.

- `entities`: what the fact is about, as typed ids `type:name` with `type` one of `host`,
  `service`, `repo`, `tool`, `person`, `workflow`, `other` (e.g. `host:merlin`). Names are
  lower-cased and trimmed; an unknown type is an error.
- `fact_kind`: `fact`, `procedure`, `decision`, `pitfall`, `preference` or `pointer`. (`kind`,
  `hint` or `rule`, still decides how the memory is recalled.)
- `valid_while`: free text saying when the fact holds (e.g. `nano-workforce >= 0.216`).
- `verified_at`: the date the fact was saved or last re-checked; `memory_verify(id)` bumps it.
- `supersedes`: ids of memories the new one replaces. A replaced memory stays in the file
  (with `superseded_by`) and can still be read with `memory_search` on its exact id, but it is
  never recalled, shown in the index or `/memory`, or matched by other searches.
- **Entity registry:** each scope has an `entities.jsonl` (`<memory_dir>/entities.jsonl` for
  `user`, `projects/<key>.entities.jsonl` for a project) listing each entity's id, aliases
  (`merlin.local`, `merlin.ts` for `host:merlin`) and relations (`runs_on`, `reached_via`,
  `part_of`). `memory_save` registers entities it hasn't seen; an alias resolves to its entity
  on save and search. `memory_entity` adds an alias or a relation, or with no change lists the
  registry (or one entity).
- **Conflict check on save** (no model call): saving the same text and evidence as a current
  memory is refused with the existing id. A memory sharing an entity and `fact_kind` (missing
  counts as `fact`) that is a near-duplicate (word overlap ≥ 60%) or a likely contradiction
  (a shared anchor such as a host or path) is listed back to the model instead of saving; it
  saves again with `supersedes: [ids]` or `distinct: true`.
- `memory_search` filters by `entity` (an alias works) and `fact_kind`, and each hit ends with
  `{kind; entities; verified date}`. A search result is capped at 8,000 bytes.

**Recall from tool calls.** After a tool runs, memories relevant to its arguments are attached
to the result as a `<system-reminder>` note. With `memory_recall = "entity"` (the default) the
call resolves to the entities it touches — hosts (URLs, `ssh`/`scp` targets), repos (`-R o/r`,
the working directory's git remote) and the tool (the command name) — through the registry's
aliases, following `reached_via` / `runs_on` / `part_of` one hop
(`merlin.local:8080` → `host:merlin` and the services on it). At most 3 facts within 1,500 bytes
are recalled, ranked: rules first, then `fact_kind` weighted by context (`pitfall` and
`procedure` for command execution, `decision` and `preference` when planning or editing), then
`verified_at` recency, then last-used. A superseded memory is never recalled, a hint already in
context is not repeated, and an entity's other facts stay quiet for a few calls once one was
recalled (unless a different fact would be chosen). Memories with no entities yet keep the older
anchor-substring recall, so nothing regresses before they are migrated. The note names the
entity that triggered it (`📌 host:merlin — …`), and `/memory entities` lists each entity's
facts. Set `memory_recall = "anchor"` to compare or roll back to the pre-entity substring match.

**Migrating existing memories.** Memories saved before entities existed have no entities or
`fact_kind`, and may include duplicates and facts a later note contradicts. `/memory migrate`
(or `nano-coder --memory-migrate` from a shell) tidies them with the model's help:

- Untagged entries not reviewed before are sent to the session's model in batches of at most
  12 KB, each with a capped (6 KB) digest of the already-tagged entries. The model proposes,
  per entry, entities and a `fact_kind`, and across the batch and the tagged set, duplicates to
  merge and stale entries to supersede (naming the newer entry and why). Invalid proposals
  (unknown ids, bad entity types) are dropped and counted.
- Each batch's proposals are listed for review: **Accept all**, **Review each** (accept, skip
  or edit each item: a tag's entities and kind, a merge's text), **Skip this batch**, or
  **Stop** (resume later). Nothing changes without a confirmation.
- A merge keeps the chosen entry with the better text and the union of the anchors, evidence
  and entities; the duplicates and superseded entries stay on disk marked replaced
  (`superseded_by`), so they are never recalled or listed but remain readable by id.
- Before the first applied change, the memory files are copied to
  `<memory dir>/backups/migrate-<timestamp>/` and the path is printed. To undo, copy the files
  from there back into the memory directory.
- Progress is recorded in `<memory dir>/migrate-progress.json` after each batch, so an
  interrupted or stopped migration resumes where it left off, and a re-run only looks at
  entries that are still untagged and were saved since (skipped batches are not offered again;
  delete the progress file to review everything once more).
- `--dry-run` (`/memory migrate --dry-run`, `nano-coder --memory-migrate --dry-run`) writes the
  proposals to `<memory dir>/migrate-dry-run-<timestamp>.json` and changes nothing; it also
  works when memory is read-only. Applying needs memory `on` and, in the REPL, an interactive
  terminal outside Plan mode.
- The report ends with the model usage of the run (`Model usage: N input, M output tokens`, plus
  AI Credits when the provider reports them), retried and failed requests included.

**Prompt.** A capped, dated index (most-recently-used first, ~4 KB with the guidance) is
appended to the system prompt at session start, framed as "notes from earlier sessions; may be
out of date; verify before relying on them". The rest is reachable with `memory_search`.

**What gets saved.** When saving is possible, the prompt says what is worth saving, even
before anything has been saved (adapted from Claude Code's auto memory):

- **Save:** corrections you give and approaches you confirm; your preferences; decisions and
  context the code and git history don't record; where to find things outside the repository;
  setup that was costly to work out.
- **Skip:** what the code, git history or instruction files already say, one-off debugging,
  session logs, and secrets.

Asking the model to remember something saves it. Asking for it to go in `AGENTS.md` or
`CLAUDE.md` edits that file instead. Once per session, after 30 tool calls without a save,
a reminder asks whether anything durable is worth saving (`reminders = false` turns
reminders off).

**Control and hygiene.**

- Each save is confirmed to the model (`remembered (scope, id): ...`), so it shows in the
  transcript. `/memory` lists every entry with its id; `/memory forget <id>` deletes one; the
  files are human-readable and can be edited directly.
- Obvious secrets (keys, tokens, passwords, `.env`-style assignments, private-key blocks) are
  rejected on save - store where to find them instead.
- Using an entry (a `memory_search` match) in a writable session bumps its last-used date;
  read-only and Plan-mode searches never bump it. Entries unused for
  `memory_expiry_days` (default 90; `0` disables) expire on the next load.
- Memories never touch the permission rules.

Set `memory = "on"` (full), `"read_only"` (index and `memory_search` only), or `"off"`.
Headless/ACP runs downgrade `on` to `read_only` by default, since no human vets a save live.
