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
    for path in session_files(sys.argv[1:]):
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


if __name__ == "__main__":
    main()
