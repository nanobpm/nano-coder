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
| `summ.kept` | runs whose summary itself still contains the expected detail |
| `pass\|lost` | pass rate among runs whose summary **lost** the detail |
| `lost` | how many runs that is |
| `used hist` | runs where the agent called `history_search` / `history_read` |
| `hist/run` | average history-tool calls per run |

`pass|lost` is the number to compare between modes. When the summary keeps
the detail, both modes should pass, so those runs say nothing about
retrieval. With standard mode, `pass|lost` should be near zero. If it isn't,
the model is guessing or the question leaks the answer. If smart mode has a
high `pass|lost` but low `used hist`, check the answers in the results file.

A per-case pass table follows. Every run is written as one JSON line to
`eval/compaction/results/<timestamp>.jsonl`, with the answer, tool calls,
summary size and the path of the session log (kept, so you can read what
happened). `run.py report FILE...` prints the table again, optionally
combining several files.

## Cases

Built-in synthetic cases (`--synthetic a,b`; `--seeds N` variants each, with
`--filler-turns` turns of unrelated work and look-alike errors after the
detail):

| case | the detail |
| --- | --- |
| `buried-error` | a method name in one failed build's output |
| `user-constraint` | the branch name and port the user asked for in the first message |
| `working-command` | the exact command that finally made tests pass, after failed attempts |
| `rejected-approach` | an approach the user ruled out, and why (PR number, deadlock) |
| `recent-control` | a detail in the last message, which compaction keeps. Both modes should pass; if not, the question or grading is off |

Unique values are derived from the seed, so the answer can't be known
without the history. More filler makes the summary lossier: the default of
15 turns is about 100k characters.

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

Fork at a `turn_end` line; the harness warns if you don't. Questions should
ask for something checkable, and `expect` should be specific enough that a
guess won't match.

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
- Runs cost tokens: each is one summary request plus a short turn. Start
  with `--seeds 1`.
