#!/usr/bin/env python3
"""Compare standard and smart compaction across session logs.

Usage: scripts/compaction-report.py [SESSION_DIR_OR_FILES...]
       (default: ~/Library/Application Support/nano-coder/sessions or
        ~/.local/share/nano-coder/sessions)

Per session it finds the compaction mode(s) used (from `replace` records),
then reports, per mode: sessions, compactions, turns after the first
compaction, how many of those used the history tools, and reported outcomes.
Sessions compacted in both modes are counted as "mixed". Sessions without a
compaction are skipped. Rows are split by the model recorded with the
session's first compaction.

A second table is the compaction-cost baseline (issue #275): what the
summary requests themselves cost, per model and mode. nano-coder records
each summary request's usage and duration on the summary message in the
`replace` record. Per compaction it reports the tokens the summarizer
re-read (its input), the summary it wrote (its output), the request time,
the context size just before compacting, and the share of all tokens in
those sessions spent on compaction. This is the number a summary built
without a model call drives to zero.
"""
import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path


def default_dirs():
    home = Path.home()
    return [home / base / app / "sessions"
            for base in ("Library/Application Support", ".local/share")
            for app in ("nano-coder", "agentic-harness")]


def session_files(args):
    paths = [Path(a).expanduser() for a in args] or [d for d in default_dirs() if d.is_dir()]
    for path in paths:
        if path.is_dir():
            yield from sorted(path.glob("*.jsonl"))
        elif path.is_file():
            yield path


def percentile(values, q):
    if not values:
        return 0
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))]


def is_summary(m):
    return (isinstance(m, dict) and m.get("role") == "user" and str(m.get("content") or "").startswith("[")
            and (isinstance(m.get("usage"), dict) or isinstance(m.get("duration_ms"), (int, float))))


def costs(path):
    """Per-compaction cost records, plus the session's total tokens.

    A replace keeps earlier summaries in its message list, so each summary
    is counted once (keyed by its timestamp and usage)."""
    seen, out, total, context = set(), [], 0, 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind, data = record.get("type"), record.get("data") or {}
            if kind == "message" and data.get("role") == "assistant" and isinstance(data.get("usage"), dict):
                usage = data["usage"]
                context = int(usage.get("prompt_tokens") or 0)
                total += context + int(usage.get("completion_tokens") or 0)
            elif kind == "replace" and "mode" in data:
                for m in data.get("messages") or []:
                    if not is_summary(m):
                        continue
                    key = json.dumps([m.get("timestamp"), m.get("usage"), m.get("duration_ms")], sort_keys=True)
                    if key in seen:
                        continue
                    seen.add(key)
                    usage = m.get("usage") if isinstance(m.get("usage"), dict) else {}
                    tin, tout = int(usage.get("prompt_tokens") or 0), int(usage.get("completion_tokens") or 0)
                    total += tin + tout
                    out.append({"key": (data.get("model", "?"), data["mode"]), "in": tin, "out": tout,
                                "ms": int(m.get("duration_ms") or 0), "before": context,
                                "chars": len(str(m.get("content") or "")), "has_usage": bool(usage)})
    return out, total


def cost_report(files):
    rows, totals = defaultdict(list), defaultdict(int)
    for path in files:
        items, total = costs(path)
        for key in {i["key"] for i in items}:
            totals[key] += total
        for i in items:
            rows[i["key"]].append(i)
    if not rows:
        return
    print("\nCompaction cost (per compaction; p50/p90):")
    width = max(len(model) for model, _ in rows)
    header = (f"{'model':<{width}} {'mode':<9} {'logged':>7} {'ctx before':>13} {'summary in':>13} "
              f"{'summary out':>11} {'summary chars':>13} {'seconds':>11} {'total tok':>10} {'share':>6}")
    print(header)
    print("-" * len(header))
    for key in sorted(rows):
        rs = rows[key]
        used = [r for r in rs if r["has_usage"]]
        pair = lambda f, rs=used, scale=1: f"{percentile([r[f] for r in rs], .5) / scale:.0f}/{percentile([r[f] for r in rs], .9) / scale:.0f}"
        spent = sum(r["in"] + r["out"] for r in used)
        share = f"{100 * spent / totals[key]:5.1f}%" if totals[key] else "    -"
        print(f"{key[0]:<{width}} {key[1]:<9} {len(rs):>7} {pair('before'):>13} {pair('in'):>13} {pair('out'):>11} "
              f"{pair('chars', rs):>13} {pair('ms', rs, 1000):>11} {spent:>10} {share:>6}")
    print("ctx before = prompt tokens of the last request before compacting; summary in/out = the summary\n"
          "request's tokens; total tok = all summary-request tokens; share = of all tokens in those sessions (cached\n"
          "prompt tokens count in full, so it understates the summary's share of cost).\n"
          "Only compactions recorded by a build that logs summary usage carry tokens.")


def analyse(path):
    modes, compactions, model = set(), 0, "?"
    after = {"turns": 0, "with_history": 0, "history_calls": 0, "outcomes": Counter()}
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind, data = record.get("type"), record.get("data") or {}
            if kind == "replace" and "mode" in data:
                if not compactions:
                    model = data.get("model", "?")
                compactions += 1
                modes.add(data["mode"])
            elif kind == "turn_end" and compactions:
                after["turns"] += 1
                calls = data.get("history_calls", 0)
                after["history_calls"] += calls
                after["with_history"] += bool(calls)
                outcome = (data.get("outcome") or {}).get("status", "none")
                after["outcomes"][outcome] += 1
    if not compactions:
        return None
    mode = modes.pop() if len(modes) == 1 else "mixed"
    return (model, mode), compactions, after


def main():
    totals = defaultdict(lambda: {"sessions": 0, "compactions": 0, "turns": 0, "with_history": 0,
                                  "history_calls": 0, "outcomes": Counter()})
    files = list(session_files(sys.argv[1:]))
    for path in files:
        result = analyse(path)
        if not result:
            continue
        mode, compactions, after = result
        t = totals[mode]
        t["sessions"] += 1
        t["compactions"] += compactions
        for key in ("turns", "with_history", "history_calls"):
            t[key] += after[key]
        t["outcomes"].update(after["outcomes"])
    if not totals:
        print("No compacted sessions found (only compactions recorded by a build with smart compaction count).")
        return
    width = max(len(model) for model, _ in totals)
    header = f"{'model':<{width}} {'mode':<9} {'sessions':>8} {'compact':>8} {'turns*':>7} {'hist.turns':>10} {'hist.calls':>10}  outcomes (turns after 1st compaction)"
    print(header)
    print("-" * len(header))
    for key in sorted(totals):
        model, mode = key
        t = totals[key]
        outcomes = ", ".join(f"{k} {v}" for k, v in sorted(t["outcomes"].items()))
        print(f"{model:<{width}} {mode:<9} {t['sessions']:>8} {t['compactions']:>8} {t['turns']:>7} {t['with_history']:>10} {t['history_calls']:>10}  {outcomes}")
    print("* turns that ended after the session's first compaction")
    cost_report(files)


if __name__ == "__main__":
    main()
