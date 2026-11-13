# Compaction eval

Measures whether smart compaction helps an agent recover details that a
summary lost, across providers and models.

Each run takes a session log (synthetic, or a real one forked at a line),
loads it in `nano-coder --acp --model MODEL`, runs `/compact --standard` or
`/compact --smart`, then asks a question whose answer is only in the
compacted part. The answer is graded with regexes.

```sh
cargo build --release
# Check the harness itself; no provider needed (fake model, see below).
eval/compaction/run.py --self-test
# Compare models; providers and keys come from your config.toml.
eval/compaction/run.py --models anthropic/claude-sonnet-4-5,openai/gpt-4o-mini,ollama/qwen3:8b
eval/compaction/run.py --models github-copilot/gpt-4.1 --seeds 5 --repeats 2 --jobs 8
```

Needs Python 3.9+ (stdlib only) and a built `nano-coder`. It uses
`target/release`, then `target/debug`, then `PATH`; `--bin` overrides.
Provider settings come from `--config`, which defaults to
`~/.config/nano-coder/config.toml`. The harness overrides only `session_dir`,
`compaction_mode`, `auto_compact` (off), `persist_sessions` and
`project_instructions` (off). Each run gets a fresh session directory and an
empty working directory.

## Reading the table

| column | meaning |
| --- | --- |
| `pass` | answers that match every `expect` regex and no `forbid` regex |
| `kept` | runs where the detail survived compaction, in the summary or in the recent messages kept verbatim |
| `pass\|lost` | pass rate among runs where the detail was **lost** |
| `lost` | how many runs that is |
| `used hist` | runs where the agent called `history_search` / `history_read` |
| `hist/run` | average history-tool calls per run |

`pass|lost` is the number to compare between modes. When the detail
survives, both modes should pass, so those runs say nothing about
retrieval. With standard mode, `pass|lost` should be near zero. If it isn't,
the model is guessing or the question leaks the answer. If smart mode has a
high `pass|lost` but low `used hist`, check the answers in the results file.

| column | meaning |
| --- | --- |
| `95% CI` | Wilson interval of `pass\|lost` — the spread a point estimate hides |
| `in tok` / `out tok` | mean input/output tokens per run, from the session log's `usage` records (0 when the provider reports none) |

A per-case pass table follows. Every run is written as one JSON line to
`eval/compaction/results/<timestamp>.jsonl`, with the answer, tool calls,
summary size, token usage, wall time and the path of the session log (kept,
so you can read what happened). `run.py report FILE...` prints the table
again, optionally combining several files.

## Noise band and comparing two runs

A point estimate of `pass|lost` can't tell a real gain from luck. Two tools
help:

```sh
# Run the unchanged baseline several times and record the noise band δ
# (per model x mode cell) to results/<stamp>.calibration.json:
eval/compaction/run.py calibrate --trials 5 --models …
# Compare a candidate run against a saved baseline:
eval/compaction/run.py report --baseline A.jsonl B.jsonl --delta results/….calibration.json
```

`calibrate` repeats the whole eval `--trials` times on the *unchanged* code
and estimates δ per cell as the 95th percentile of |Δ`pass|lost`| between
two bootstrap resamples — each resample redraws one trial's repetitions
*within each case*, preserving kept/lost membership and the fixed case mix,
so case difficulty is not mistaken for run-to-run noise — floored at the
observed spread of the per-trial rates (the calibration step of RRSI,
[arXiv:2609.24972](https://arxiv.org/abs/2609.24972)). The calibration file
stores δ at full precision; only the printed table rounds.

`report --baseline A.jsonl B.jsonl` prints, per cell: Δ`pass|lost` with its
95% interval (Newcombe's method from the two Wilson intervals), δ, and the
change in mean input/output tokens and seconds per run. A cell is *within
noise* when |Δ| ≤ δ (without `--delta`: when the interval contains 0), and
the verdict says so — adding "; adds cost" when the change also spends more
tokens. `--delta` also accepts a plain fraction, e.g. `--delta 0.1`. Token
deltas and cost claims appear only when every run on both sides carries
token fields; a baseline from before cost logging shows `n/a` instead of
reading the missing data as zero.

**Acceptance rule** (convention, not enforced by the harness): accept a
harness or compaction change only if Δ`pass|lost` > δ **and** its extra
tokens are justified by that gain. A change within the noise band must not
add cost.

## Cases

Built-in synthetic cases (`--synthetic a,b`; `--seeds N` variants each, with
`--filler-turns` turns of unrelated work and look-alike errors after the
detail):

| case | the detail |
| --- | --- |
| `buried-error` | a method name in one failed build's output |
| `long-log-error` | an error line from the middle of a ~50k-character build log |
| `user-constraint` | the branch name and port the user asked for in the first message |
| `working-command` | the exact command that finally made tests pass, after failed attempts |
| `rejected-approach` | an approach the user ruled out, and why (PR number, deadlock) |
| `recent-control` | a detail in the last message, which compaction keeps. Both modes should pass; if not, the question or grading is off |
| `pinned-request` | a flag, a pass count and a label stated once in the first message, compacted **twice** (issue #66) |

Unique values are derived from the seed, so the answer can't be known
without the history. More filler makes the summary lossier: the default of
15 turns is about 100k characters.

### The pinned-request block (issue #66)

Compaction pins the user's requests verbatim after the summary, rebuilt from
the original messages on every compaction rather than re-summarized from the
previous summary. The `pinned-request` case is the scenario that needs it: a
detail stated once in the first message, folded by **two** compactions, then
questioned. A repeated-compaction case only proves the pin was regenerated when
**every** requested compaction actually completed: a skipped compaction leaves
the prior pin in place for grading, and a fallback (a later success overwriting
an earlier failure) breaks the chain. `run_one` therefore rejects such a run as
soon as any requested compaction is skipped or falls back, so a pass can only
mean the full chain completed. Cases whose detail lives in a *user* message
(`user-constraint`, `rejected-approach`, `pinned-request`) survive in both
modes while the pin is on; cases whose detail lives in a *tool output*
(`buried-error`, `long-log-error`, `working-command`) are not pinned and still
exercise the history tools.

To measure the block's effect, append `-nopin` to a mode to run it with the
pin disabled (`compaction_pin_requests = false`):

```sh
eval/compaction/run.py --models … --modes standard,smart,standard-nopin,smart-nopin
```

Each `-nopin` cell is reported separately, so `standard` vs `standard-nopin`
is the with/without-pin A/B for standard compaction (and likewise for smart).

Real sessions: list the turns of a log, pick a fork point right after a
detail was established plus some later work, and write a case file:

```sh
eval/compaction/run.py turns ~/Library/Application\ Support/nano-coder/sessions/sess-X.jsonl
```

```json
[
  {"name": "flaky-auth", "log": "~/…/sess-X.jsonl", "fork_line": 412,
   "question": "What was the exact panic message from the first failing auth test?",
   "expect": ["called `Option::unwrap\\(\\)` on a `None` value"], "forbid": []},
  {"name": "long-constraint", "synthetic": "user-constraint", "seed": 3, "filler_turns": 40}
]
```

```sh
eval/compaction/run.py --synthetic '' --cases my-cases.json --models …
```

By default the agent can't use bash or the file tools (`--tools history`):
synthetic projects don't exist, so the agent would otherwise explore your
real disk. The answer has to come from context or the history tools. For a
real fork you can pass `--tools all` and give the case a `"cwd"` (its
project directory). The agent could then rediscover things by reading code,
which is realistic but noisier.

Fork at a `turn_end` line; the harness warns if you don't. Questions should
ask for something checkable, and `expect` should be specific enough that a
guess won't match.

## Slow models

Writing the summary is most of a run's cost: hundreds of output tokens,
which takes minutes on a slow local model. To test whether a model *uses*
the history well, reuse compactions from an earlier run instead:

```sh
eval/compaction/run.py --models macbook/qwen3.8-neo-coder \
  --reuse-compaction eval/compaction/results/<copilot-run>.jsonl \
  --shuffle --max-minutes 20 --jobs 1 --timeout 1200 --terse \
  --extra-body '{"chat_template_kwargs": {"enable_thinking": false}}'
```

- `--reuse-compaction` takes the smart runs from that file where the
  detail was lost. It cuts each log right after its compaction, and the new
  model only answers the question. The summary was written by the earlier
  model, so this measures retrieval, not summarizing.
- `--shuffle` and `--max-minutes` time-box a sample of the jobs.
- `--terse` asks for a one-line answer.
- `--extra-body` is merged into requests of the providers under test, for
  example to turn thinking off. If a provider already sets `extra_body` in your
  config, the two are deep-merged (CLI fields win), so you can override one
  nested field without dropping the rest.

## Self-test

`--self-test` starts `fake_llm.py`, an OpenAI-compatible endpoint that plays
an oracle agent. It writes a summary that loses every detail, reads its
context perfectly, and uses the history tools whenever they're offered. The
run then checks the expected pattern: standard fails the buried cases, smart
passes them with at least one history call, and both pass the control. It
exits non-zero otherwise. CI runs it. It tests the harness and the feature
wiring, not how good any real model is.

## Caveats

- Regex grading is strict: a correct paraphrase can fail. Look at the
  answers in the results file before drawing conclusions.
- The same model writes the summary and answers the question, as in real
  use. So a model that summarizes well gains less from retrieval.
- Synthetic logs are cleaner than real work. Use them for quick
  comparisons, and real forks for confidence.
- Local models: use `--jobs 1` if the server handles one request at a
  time, and raise `--timeout`. Summarizing about 100k characters on a 27B
  model can take several minutes.
- Runs cost tokens: each is one summary request plus a short turn. Start
  with `--seeds 1`.
