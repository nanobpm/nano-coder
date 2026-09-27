#!/usr/bin/env python3
"""Compaction eval: does smart compaction help the agent recover details?

For each case x model x mode x repeat it:
  1. writes a session log (synthetic, or a real log forked at a line),
  2. starts `nano-coder --acp --model MODEL`, loads the session,
  3. runs `/compact --MODE`, then asks the case's question,
  4. grades the answer (every `expect` regex must match, no `forbid` regex),
     and records whether the summary itself kept the detail and how many
     history-tool calls the agent made.

The key number is the pass rate when the summary LOST the detail: that is
the only place retrieval can make a difference.

Examples:
  eval/compaction/run.py --models mock/gpt-4o-mini --repeats 1           # smoke test
  eval/compaction/run.py --models anthropic/claude-sonnet-4-5,openai/gpt-4o-mini
  eval/compaction/run.py --cases my-cases.json --models ollama/qwen3:8b
  eval/compaction/run.py turns ~/…/sessions/sess-X.jsonl                   # pick fork lines
  eval/compaction/run.py report results/2026-….jsonl                      # re-print a table
"""
import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from collections import defaultdict
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import cases as synthetic  # noqa: E402

# Denied unless --tools all: synthetic logs describe a project that doesn't
# exist, so without history tools the agent would explore the real disk.
WORK_TOOLS = ("bash", "read_file", "write_file", "edit_file")
OVERRIDDEN = ("session_dir", "compaction_mode", "auto_compact", "persist_sessions", "project_instructions", "model")


def default_config():
    # nano-coder, then the pre-rename agentic-harness (as the binary does).
    for base in (Path.home() / ".config/nano-coder", Path.home() / ".config/agentic-harness"):
        if (base / "config.toml").is_file():
            return base / "config.toml"
    return None


def default_binary():
    for candidate in (REPO / "target/release/nano-coder", REPO / "target/debug/nano-coder"):
        if candidate.is_file():
            return str(candidate)
    return shutil.which("nano-coder") or "nano-coder"


def config_text(base, session_dir, mode):
    """The user's config (for providers and keys) with eval overrides on top.
    Overridden top-level keys are removed from the base so TOML stays valid."""
    lines = []
    if base:
        in_table = False
        for line in Path(base).read_text().splitlines():
            if line.strip().startswith("["):
                in_table = True
            key = line.split("=", 1)[0].strip()
            if not in_table and key in OVERRIDDEN:
                continue
            lines.append(line)
    head = [
        f"session_dir = {json.dumps(str(session_dir))}",
        f'compaction_mode = "{mode}"',
        "auto_compact = false",
        "persist_sessions = true",
        "project_instructions = false",
    ]
    return "\n".join(head + lines) + "\n"


def fork_records(path, line):
    """Records 1..line of a real session log (1-based, inclusive)."""
    records = []
    with open(Path(path).expanduser(), encoding="utf-8") as f:
        for number, text in enumerate(f, 1):
            if number > line:
                break
            if text.strip():
                records.append(json.loads(text))
    if records and records[-1].get("type") != "turn_end":
        print(f"warning: {path}:{line} is not a turn_end record; the fork resumes mid-turn", file=sys.stderr)
    return records


def load_cases(args):
    """Built-in synthetic cases, plus any from --cases files.

    A case file is a JSON list of objects:
      {"name": "...", "log": "path.jsonl", "fork_line": 120,
       "question": "...", "expect": ["regex", ...], "forbid": ["regex", ...]}
    or synthetic: {"name": "...", "synthetic": "buried-error", "seed": 3, "filler_turns": 20}
    """
    out = []
    names = [n for n in args.synthetic.split(",") if n] if args.synthetic else []
    for name in names:
        if name not in synthetic.CASES:
            sys.exit(f"unknown synthetic case {name!r}; choose from {', '.join(synthetic.CASES)}")
        for seed in range(args.seeds):
            case = synthetic.build(name, seed, args.filler_turns)
            case["name"] = f"{name}/s{seed}"
            out.append(case)
    for file in args.cases or []:
        for spec in json.loads(Path(file).read_text()):
            if "synthetic" in spec:
                case = synthetic.build(spec["synthetic"], spec.get("seed", 0), spec.get("filler_turns", args.filler_turns))
                case.update({k: spec[k] for k in ("name", "question", "expect", "forbid") if k in spec})
            else:
                case = {
                    "name": spec["name"],
                    "records": fork_records(spec["log"], spec["fork_line"]),
                    "question": spec["question"],
                    "expect": spec.get("expect", []),
                    "forbid": spec.get("forbid", []),
                    "cwd": spec.get("cwd"),
                }
            out.append(case)
    return out


def write_log(records, session_dir, session_id):
    session_dir.mkdir(parents=True, exist_ok=True)
    with open(session_dir / f"{session_id}.jsonl", "w", encoding="utf-8") as f:
        for i, record in enumerate(records):
            if i == 0:
                record = {**record, "data": {**record["data"], "id": session_id}}
            f.write(json.dumps(record) + "\n")


class Acp:
    """Minimal JSON-RPC client for `nano-coder --acp`."""

    def __init__(self, argv, cwd, stderr_path, timeout):
        self.stderr = open(stderr_path, "w")
        self.proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.stderr, text=True, bufsize=1)
        self.next_id = 0
        self.deadline = time.monotonic() + timeout
        self.updates = []
        self.lines = []
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.cond = threading.Condition()
        self.reader.start()

    def _read(self):
        for line in self.proc.stdout:
            with self.cond:
                self.lines.append(line)
                self.cond.notify_all()
        with self.cond:
            self.lines.append(None)
            self.cond.notify_all()

    def call(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        while True:
            with self.cond:
                while not self.lines:
                    remaining = self.deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError(f"{method} timed out")
                    self.cond.wait(remaining)
                line = self.lines.pop(0)
            if line is None:
                raise RuntimeError(f"nano-coder exited during {method}")
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("method") == "session/update":
                self.updates.append(msg["params"]["update"])
            elif msg.get("id") == request_id:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error'].get('message')}")
                return msg.get("result")

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        self.stderr.close()


def matches_all(patterns, text):
    return all(re.search(p, text or "", re.IGNORECASE) for p in patterns)


def matches_any(patterns, text):
    return any(re.search(p, text or "", re.IGNORECASE) for p in patterns)


def read_log(path):
    records = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return records


def run_one(args, case, model, mode, repeat, work_root):
    run_dir = work_root / f"{case['name'].replace('/', '_')}-{model.replace('/', '_').replace(':', '_')}-{mode}-r{repeat}"
    session_dir, cwd = run_dir / "sessions", run_dir / "cwd"
    cwd.mkdir(parents=True, exist_ok=True)
    if case.get("cwd") and args.tools == "all":
        cwd = Path(case["cwd"]).expanduser()
    session_id = f"eval-{uuid.uuid4().hex[:12]}"
    write_log(case["records"], session_dir, session_id)
    config = run_dir / "config.toml"
    config.write_text(config_text(args.config, session_dir, mode))
    result = {"case": case["name"], "model": model, "mode": mode, "repeat": repeat, "tools": args.tools, "session": str(session_dir / f"{session_id}.jsonl")}
    started = time.monotonic()
    argv = [args.bin, "--acp", "--config", str(config), "--model", model]
    if args.tools == "history":
        argv += [a for tool in WORK_TOOLS for a in ("--deny", tool)]
    acp = Acp(argv, cwd, run_dir / "stderr.txt", args.timeout)
    try:
        acp.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        acp.call("session/load", {"sessionId": session_id, "cwd": str(cwd), "mcpServers": []})
        compacted = acp.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": f"/compact --{mode}"}]})
        result["compacted"] = bool(compacted and compacted.get("compacted"))
        result["fallback"] = compacted.get("fallback") if compacted else None
        acp.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": case["question"]}]})
    except Exception as e:
        result["error"] = f"{type(e).__name__}: {e}"
    finally:
        acp.close()
    result["seconds"] = round(time.monotonic() - started, 1)

    records = read_log(result["session"])
    replace_at = next((i for i in range(len(records) - 1, -1, -1)
                       if records[i]["type"] == "replace" and "mode" in records[i]["data"]), None)
    summary, kept, after = "", "", []
    if replace_at is not None:
        after = records[replace_at + 1:]
        remaining = records[replace_at]["data"]["messages"]
        summary = next((m["content"] for m in remaining if m["role"] == "user" and m["content"].startswith("[")), "")
        # Everything left in context: summary plus the recent messages compaction keeps.
        kept = "\n".join(str(m.get("content") or "") + json.dumps(m.get("tool_calls") or []) for m in remaining)
    tool_calls = [c["name"] for r in after if r["type"] == "message" for c in r["data"].get("tool_calls", [])]
    turn_end = next((r["data"] for r in reversed(after) if r["type"] == "turn_end"), None)
    answer = turn_end["response"] if turn_end else ""
    if "error" not in result:
        if not turn_end:
            result["error"] = "no answer recorded (provider error?); see " + str(run_dir / "stderr.txt")
        elif result.get("fallback") and "failed" in str(result["fallback"]):
            result["error"] = "compaction failed: " + str(result["fallback"])[:300]
    result.update({
        "answer": answer,
        "passed": bool(turn_end) and matches_all(case["expect"], answer) and not matches_any(case["forbid"], answer),
        "kept": matches_all(case["expect"], kept),
        "summary_kept": matches_all(case["expect"], summary),
        "summary_chars": len(summary),
        "history_calls": sum(1 for n in tool_calls if n.startswith("history_")),
        "tool_calls": tool_calls,
    })
    if not args.keep and cwd == run_dir / "cwd":
        shutil.rmtree(cwd, ignore_errors=True)
    return result


def pct(n, d):
    return f"{100 * n / d:5.1f}%" if d else "    - "


def report(results, out=sys.stdout):
    groups = defaultdict(list)
    for r in results:
        groups[(r["model"], r["mode"])].append(r)
    width = max([len(m) for m, _ in groups] + [5])
    header = (f"{'model':<{width}}  {'mode':<8} {'runs':>4} {'errors':>6} {'pass':>7} {'kept':>9} "
              f"{'pass|lost':>9} {'lost':>4} {'used hist':>9} {'hist/run':>8} {'secs':>6}")
    print(header, file=out)
    print("-" * len(header), file=out)
    for (model, mode), rs in sorted(groups.items()):
        ok = [r for r in rs if "error" not in r]
        lost = [r for r in ok if not r.get("kept", r["summary_kept"])]
        print(f"{model:<{width}}  {mode:<8} {len(rs):>4} {len(rs) - len(ok):>6} "
              f"{pct(sum(r['passed'] for r in ok), len(ok)):>7} {pct(sum(r['summary_kept'] for r in ok), len(ok)):>9} "
              f"{pct(sum(r['passed'] for r in lost), len(lost)):>9} {len(lost):>4} "
              f"{pct(sum(r['history_calls'] > 0 for r in ok), len(ok)):>9} "
              f"{(sum(r['history_calls'] for r in ok) / len(ok) if ok else 0):>8.2f} "
              f"{(sum(r['seconds'] for r in rs) / len(rs)):>6.1f}", file=out)
    print("\nkept = the detail survived compaction (in the summary or the recent messages kept verbatim).\n"
          "pass|lost = pass rate among runs where it did not (where retrieval can matter).", file=out)
    by_case = defaultdict(lambda: defaultdict(list))
    for r in results:
        by_case[r["case"].split("/")[0]][(r["model"], r["mode"])].append(r)
    print("\nPer case (pass / runs):", file=out)
    columns = sorted(groups)
    labels = [f"{m.split('/')[-1]}:{mo}" for m, mo in columns]
    widths = [max(len(label), 7) for label in labels]
    print(f"  {'case':<20}" + "".join(f"  {label:>{w}}" for label, w in zip(labels, widths)), file=out)
    for case, cols in sorted(by_case.items()):
        cells = []
        for col, w in zip(columns, widths):
            rs = [r for r in cols.get(col, []) if "error" not in r]
            cell = f"{sum(r['passed'] for r in rs)}/{len(rs)}"
            cells.append(f"  {cell:>{w}}")
        print(f"  {case:<20}" + "".join(cells), file=out)


def self_test_verdict(results):
    """With the oracle: standard fails buried cases, smart passes them via the
    history tools, and both pass the control. Returns a process exit code."""
    problems = []
    for r in results:
        base = r["case"].split("/")[0]
        if "error" in r:
            problems.append(f"{r['case']} {r['mode']}: {r['error']}")
        elif base == "recent-control":
            if not (r["passed"] and r["kept"]):
                problems.append(f"{r['case']} {r['mode']}: control failed (passed={r['passed']} kept={r['kept']})")
        elif r["kept"]:
            problems.append(f"{r['case']} {r['mode']}: the detail survived a lossy summary?")
        elif r["mode"] == "standard" and (r["passed"] or r["history_calls"]):
            problems.append(f"{r['case']} standard: passed={r['passed']} history_calls={r['history_calls']}")
        elif r["mode"] == "smart" and not (r["passed"] and r["history_calls"]):
            problems.append(f"{r['case']} smart: passed={r['passed']} history_calls={r['history_calls']}")
    print("\nself-test:", "OK" if not problems else "FAILED\n  " + "\n  ".join(problems))
    return 1 if problems else 0


def list_turns(path):
    """Print turn_end lines of a session log, to choose fork points."""
    last_input = ""
    for number, record in enumerate(read_log(Path(path).expanduser()), 1):
        if record["type"] == "input":
            last_input = record["data"]["text"]
        elif record["type"] == "turn_end":
            print(f"{number:>6}  {' '.join(last_input.split())[:100]}")
        elif record["type"] == "replace" and "mode" in record["data"]:
            print(f"{number:>6}  (compaction)")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "turns":
        return list_turns(sys.argv[2])
    if len(sys.argv) > 1 and sys.argv[1] == "report":
        return report([json.loads(l) for f in sys.argv[2:] for l in open(f) if l.strip()])

    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--models", help="comma-separated provider/model specs, as for --model")
    p.add_argument("--self-test", action="store_true",
                   help="check the harness against a built-in fake model (fake/oracle); no provider needed")
    p.add_argument("--modes", default="standard,smart")
    p.add_argument("--synthetic", default=",".join(synthetic.CASES),
                   help="comma-separated built-in cases ('' for none): " + ", ".join(synthetic.CASES))
    p.add_argument("--cases", action="append", help="JSON case file (repeatable)")
    p.add_argument("--seeds", type=int, default=2, help="variants per synthetic case")
    p.add_argument("--filler-turns", type=int, default=15, help="unrelated turns after the detail in synthetic cases")
    p.add_argument("--repeats", type=int, default=1)
    p.add_argument("--jobs", type=int, default=4, help="parallel runs (use 1 for a local model that serves one request at a time)")
    p.add_argument("--tools", choices=("history", "all"), default="history",
                   help="history: deny bash and file tools, so answers come from context or history (default); "
                        "all: normal tools, for forks of real sessions run in their project")
    p.add_argument("--timeout", type=int, default=600, help="seconds per run")
    p.add_argument("--config", default=default_config(), help="base config with providers (default: your config.toml)")
    p.add_argument("--bin", default=default_binary())
    p.add_argument("--out", default=str(HERE / "results"))
    p.add_argument("--keep", action="store_true", help="keep each run's working directory")
    args = p.parse_args()

    if args.self_test:
        import fake_llm
        base_url = fake_llm.start()
        base = Path(tempfile.mkdtemp(prefix="compaction-eval-fake-")) / "config.toml"
        base.write_text(f'[providers.fake]\nkind = "openai"\nbase_url = "{base_url}"\napi_key = "x"\nstream = false\ncontext_window = 128000\n')
        args.config, args.models = str(base), "fake/oracle"
    if not args.models:
        p.error("--models is required (or use --self-test)")
    cases = load_cases(args)
    if not cases:
        sys.exit("no cases")
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    modes = [m.strip() for m in args.modes.split(",") if m.strip()]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    results_path = out_dir / f"{stamp}.jsonl"
    work_root = Path(tempfile.mkdtemp(prefix=f"compaction-eval-{stamp}-"))
    jobs = [(c, m, mo, r) for c in cases for m in models for mo in modes for r in range(args.repeats)]
    print(f"{len(jobs)} runs ({len(cases)} cases x {len(models)} models x {len(modes)} modes x {args.repeats}); "
          f"logs in {work_root}; results in {results_path}", file=sys.stderr)

    results = []
    lock = threading.Lock()
    with open(results_path, "w") as sink, concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = [pool.submit(run_one, args, *job, work_root) for job in jobs]
        for done, future in enumerate(concurrent.futures.as_completed(futures), 1):
            r = future.result()
            with lock:
                results.append(r)
                sink.write(json.dumps(r) + "\n")
                sink.flush()
            status = "ERROR " + r["error"] if "error" in r else ("pass" if r["passed"] else "FAIL")
            print(f"[{done}/{len(jobs)}] {r['case']} {r['model']} {r['mode']}: {status} "
                  f"(kept: {r.get('kept')}, history calls: {r.get('history_calls')})", file=sys.stderr)
    print()
    report(results)
    print(f"\nresults: {results_path}\nsession logs: {work_root}")
    if args.self_test:
        sys.exit(self_test_verdict(results))


if __name__ == "__main__":
    main()
