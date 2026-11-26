---
title: "Task plans and outcomes"
description: "The agent's task plan, which survives compaction, and the outcome it reports at the end."
order: 10
section: "Using nano-coder"
---

# Task plans and outcomes

For long tasks the agent keeps a plan outside the conversation, and it can end a task with an explicit outcome.

## Task Plans

The `plan_*` tools give the agent a plan that lives outside the conversation. This helps most
with small context windows: the model can write down what it has done and learned, then let the
conversation be summarized without losing track.

- `plan_add` - add steps (title strings or `{title, after, note}`), and optionally set the `goal`.
  Items get numeric ids; `after` lists items that must be finished first.
- `plan_update` - set an item's `status` (`pending`, `in_progress`, `done`, `blocked`,
  `dropped`), rename it, or add a `note`. `updates: [...]` changes several items in one call.
- `plan_show` - the whole plan with every note.

Each change returns a compact checklist ending with what is in progress or ready next. A bad
call (unknown id, bad status) changes nothing.

A finished plan (every item done or dropped) is history: `plan_add` then starts a new plan
(ids from 1, new goal) and the finished one is kept in the session log as a `plan_archive`
record. Each item keeps at most 4 KB of notes; older ones are replaced by
"(older notes dropped)".

The harness keeps the plan in front of the model:
- **Compaction.** The summary message is followed by the plan with the notes of open items (up
  to 8,000 characters); finished items show only a note count (`plan_show` has every note). A
  finished plan is reduced to one line ("Previous plan '…' completed (N items)"), also when
  carried over to a new session.
- **Resume.** Every change is written to the session log, and `--resume` / `session/load`
  restore the latest plan.
- **Another worker.** ACP `session/new` can be seeded with `_meta.plan` (see ACP above). The
  model then gets the plan, and is told to check which "done" work was already committed or
  pushed.

In the terminal, normal verbosity shows plan changes as a checklist instead of tool calls
(verbose shows both). The status line shows `plan 2/5`, and `/context` and `/plan` show more.
To turn plans off, set `plan_tools = false`.

**Reminders.** A tool result can end with a `<system-reminder>` note that the model sees with
the result:
- after 12 tool calls with no plan change while items are open, naming the item in progress
  (or the next one) and asking for `plan_update`; again every 12 calls;
- once per session, after 10 tool calls in one turn with no plan, suggesting `plan_add`;
- when the model repeats the same tool call — same tool, same (normalised) arguments, same
  result — three times in a row, telling it to change approach or report `blocked`. The
  warning fires at most twice per turn; if the model keeps repeating after that, the turn
  ends with a `blocked` outcome instead of burning budget, and any remaining calls in the
  same batch are skipped rather than run. For `bash`, the match strips a trailing run of
  read-only diagnostic pipeline stages (`| wc -l`, `| head`, `| grep …`, …) off the base
  command (parsed quote- and escape-aware, so a `|` inside quotes or a `||` operator never
  splits a command), so appending `| wc -l`/`| grep …`-style stages does not dodge it while
  the stable base — which may itself contain non-diagnostic stages like `sed` — keeps
  matching. Stripping stops at the first stage that could change state (a writer like
  `tee`, a redirection, a write option such as `sort -o`, a shell control construct like
  `;`/`$(…)`, or an unrecognised command), so everything to its left stays in the
  fingerprint and genuinely different calls are never conflated. The result fingerprint
  ignores only the per-call spill filename in the output bounder's `complete output in …`
  marker (matched through its `...` terminator, so even a `session_dir` path with spaces is
  normalised; not arbitrary output that merely resembles one). The marker also carries a
  `(sha256:<digest>)` of the *complete* output, so identical runaway output is still recognised
  while a result that changes only in its truncated middle — invisible to the bounded head,
  tail and byte count — stays distinct and is never hard-stopped as a false repeat. The
  fingerprint likewise folds in each attached image's content hash, so a `read_file` of a
  changing image (whose result text is only the unchanging metadata) is told apart by the
  bytes the model actually received. Enabled
  plan, outcome and
  `question` calls break the streak (so only genuinely consecutive repeats count, and an
  interleaved such call makes the calls around it non-consecutive); when plan tools are
  *disabled* a repeated hallucinated `plan_*` call is itself detected rather than exempted.

Plan and outcome calls don't count. Set `reminders = false` to turn them off.

## Outcomes

`report_outcome` is the model's explicit end-of-task signal: `status` is `completed` (the
whole task is done and checked; the summary lists PRs or commits), `blocked` (after three
or more different failed attempts, or when only a person can unblock it; the summary says
what is needed), or `needs_input` (the model has a question or needs a decision; the summary
is the question). The call ends the turn. Other calls in the same response still run, then the
summary becomes the final answer (`Blocked: ...` / `Question: ...`), and the outcome is returned
in ACP `_meta.outcome` and recorded in the session log's `turn_end` record. If the harness
stops after the call but before the turn ends, resuming the input finishes it with the
recorded outcome without calling the model again. In the terminal the call shows as
`✔ completed`, `■ blocked`, or `? needs input` followed by the summary. Set `outcome_tool = false` to leave the
tool out.

`needs_input` is the structural "waiting on the user" signal: an orchestrator (or auto mode)
can tell it apart from a clean `completed` without guessing from the text. For a richer,
multi-choice question that does not end the turn, the model uses the `question` tool instead.
