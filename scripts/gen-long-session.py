#!/usr/bin/env python3
"""Write a long Rust-format session log for resume-memory checks (issue #244).

    scripts/gen-long-session.py <dir> [id] [messages] [replaces]

~10k message records with ~60 `replace` records, each restating the whole
Rust `folded` stash (the shape that made a resume hold hundreds of MB).
Measure: NANO_CODER_SESSIONS=<dir> nano-coder --model mock/demo --no-hooks
--resume <id> in a pty, wait for the prompt, then `vmmap --summary <pid>`.
"""
import json, os, sys

out, sid = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "sess-long-244")
n = int(sys.argv[3]) if len(sys.argv) > 3 else 10000
reps = int(sys.argv[4]) if len(sys.argv) > 4 else 60
os.makedirs(out, exist_ok=True)
every = max(1, n // reps)
folded, live, line = [], [], 1
with open(os.path.join(out, sid + ".jsonl"), "w") as f:
    def w(t, d):
        global line
        f.write(json.dumps({"type": t, "data": d}) + "\n")
        line += 1
    w("session", {"version": 1, "id": sid, "cwd": "/tmp", "created_at": "2026-11-03T06:18:49Z"})
    for i in range(0, n, 2):
        iid = "in-%d" % i
        q = "request %d: please look at module %d and fix the flaky part" % (i, i % 97)
        w("input", {"id": iid, "text": q})
        u = {"role": "user", "content": q}
        a = {"role": "assistant", "content": "done %d: changed the retry loop and added a test for it" % i}
        w("message", u); w("message", a)
        w("turn_end", {"input_id": iid, "response": a["content"]})
        live += [u, a]
        if (i + 2) // every != i // every:  # crossed an interval boundary
            folded += live
            live = []
            w("replace", {"messages": [{"role": "user", "content": "summary up to %d" % i}], "folded": folded,
                          "summarized": [1, line - 1]})
