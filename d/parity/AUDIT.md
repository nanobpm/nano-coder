# What the Rust nano-coder has that the D port doesn't

Audit of Rust `main` at 80ca911 (0.68.0 plus #190) against `epic/d-port` at bb3665b, done on 2026-11-14.

## Status (2026-11-14, after the suggested order below)

All five priorities are ported on `epic/d-port`, with Rust's tests:

| Priority | Commit |
| --- | --- |
| `edit_file` robustness and atomic writes | 04b734a |
| #184 pinned requests (`compaction_pin_requests`) | ff2cf44 |
| Saved cut-off continuations, stitched on resume and redelivery (#114) | 1495709 |
| Trust hardening (skill containment, hook gating, the non-interactive note, locked trust-file writes) | 8498140 |
| #186 idle compaction; the `persist_sessions`, `session_dir` and `verify_before_complete` keys | 36a2086 |

The `rusty-harness` folder migration is `na`, because D has always used its own `nano-coder-d` folders. #185 (the ProbeState refactor) leaves three probe tests as `todo` rows. BASELINE is now 80ca911, and the manifest stands at 800 `test`, 45 `claimed`, 27 `na`, 57 `gap` and 480 `todo`, with a budget of 525. The tables below are the audit as written, before this work.

## Method

- **Parity manifest** (`manifest.tsv`): 684 `test`, 45 `claimed`, 23 `na`, 139 `gap`, 485 `todo`, plus 33 new Rust tests that aren't listed yet.
- **Gap rows:** grouped by their notes into features.
- **Todo rows:** triaged by feature, by looking for each feature they name in the D source. This step did not verify the 485 rows one by one; most are untested edge cases of features D already has.
- **Commits since the triaged baseline** (c18eb56): #184, #185, #186 and #188.
- **User-facing surface:** CLI flags, slash commands, built-in tools and config keys, compared mechanically. The flags, commands and tools all match.

## Missing features

### Rust features released since D's last sync (not ported)

| Rust | What | Size |
|---|---|---|
| #184 | Compaction pins the user's original requests (exact text, first request ~1.5k chars, later ones one line, `#N` log IDs in smart mode) instead of re-summarising them. Config key `compaction_pin_requests`. | 1,100 lines, 17 tests |
| #186 | Compacting at the idle prompt when the context is already past the threshold, held until the prompt has been quiet (`idle_compact`, `idle_compact_hold_secs`). | 700 lines, 4 tests |
| #185 | `ProbeState` refactor: the first step of Rust's background capability probe (see below). | refactor |

### Existing features where D is simpler (`gap` rows)

| Area | What D lacks | Rows |
|---|---|---|
| `edit_file` robustness | Removing `read_file` line-number prefixes pasted into `old_string` (13); handling Windows (CRLF) line endings (8); re-indenting the replacement to fit the matched block (7); a "closest lines" hint when there's no match (4); showing every changed region in the result (1) | 33 |
| Safe file writes | `write_file`/`edit_file` write in place; Rust writes a temp file, re-checks and renames atomically | 4 |
| Cut-off replies | D continues a cut-off reply within a turn, but doesn't save the pending continuation, so resuming or redelivering can't stitch it together | 18 |
| Trust (#147) | A simplified port: no symlink-containment, `.git` or cycle checks when detecting skills (8); no hook-enablement gating or non-interactive note (12); trust-file writes have no locking or newline checks (6) | 26 |
| Capability probing | D probes the model's limits synchronously when the client is built; Rust refines the context window in a background probe and records each figure's source (config, probe or learned) | 9 |
| Timers | No rollback of timer and plan state when saving it to the session log fails; some cases not handled or tested across resume | ~10 |
| Streaming display | No "response reset" event (a partial reply printed before a connection drop stays on screen); no reconciliation of trailing thinking text | 7 |
| Spill marker | The marker for truncated output has no sha256 digest, which Rust's repeat detector uses | 4 |
| Terminal output | Tabs aren't expanded; plain (non-frame) tool previews let escape sequences through | 5 |
| Offline wait (#149) | Different notice text, no curl-noise cleanup, no tests bounding how long it waits | 7 |
| Key command | A descendant process that escapes the process group (`setsid`) isn't detected | 3 |
| Compaction retry | Mid-reply connection drops are retried for turns, not for the summary request | 2 |
| Smaller | Unsetting a key inside an inline TOML table; a fake registry for update tests; question prompts on a narrow terminal; flagging timer-started turns in the log; token usage on replace records | 6 |

### Found outside the manifest

| Area | What D lacks |
|---|---|
| Config keys | `persist_sessions` and `verify_before_complete` exist only as `--no-session` / `--no-verify`; `session_dir` (custom session folder) isn't supported at all |
| Legacy config folder | Rust moves the old `rusty-harness` data folder and leaves a link behind; D only reads the current folder |
| Image re-encoding | Rust decodes and re-encodes images in-process (`image` crate). D reads headers itself but calls `sips` (macOS) or ImageMagick to resize or convert, and fails with an error when neither is installed |

## Not missing

- **Already present in D:** the loop detector, vision-model families, Copilot endpoint routing, recents, trajectories, `<think>` tag splitting, `.gitignore` handling in search, double-Escape clearing, input history, the `/timing` and `/raw` commands, the AIC usage figures, timers and Herdr.
- **Intentionally `na`:** brew channel (D has no Homebrew release), the replay stash (#157) and Rust-only eval tooling (#183).

## Suggested order

1. **`edit_file` robustness and atomic writes.** This is the tool models call most, and its failures cost whole turns.
2. **#184 pinned requests.** It changes what survives a long session.
3. **Saving cut-off continuations.** Without it, D loses work on resume.
4. **Trust hardening.** It's security-relevant.
5. **#186 idle compaction**, then config keys and the remaining polish.
