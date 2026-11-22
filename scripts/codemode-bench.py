#!/usr/bin/env python3
"""Codemode spike benchmark: run tasks with and without run_script, compare
model turns, tool calls, tokens and wall time from each run's session log."""
import json, os, subprocess, sys, time, glob

BIN = "/Users/joshua.wulf/workspace/nano-coder-codemode/nano-coder"
CWD = "/Users/joshua.wulf/workspace/nano-coder-codemode"
SESS = os.path.expanduser("~/Library/Application Support/nano-coder/sessions")

TASKS = {
    "safeio-usage": "For each public function or template declared at module level in source/nano/safeio.d, count how many "
                    "OTHER .d files under source/ reference it by name. List the ones referenced by zero or one other file, "
                    "with the count and (for one) the file.",
    "budget-history": "For each file named scripts/*-budget, report its current value and the date and short sha of the "
                      "last commit that changed it (git log). Answer as a table sorted by date.",
    "tools-imports": "For each .d file in source/nano/tools/, list the nano.* modules it imports. Then say which of those "
                     "imported modules import nano.tools (or a nano.tools.* module) back, i.e. any import cycles.",
    "test-gaps": "For each .d file in source/nano that is not a *_test.d file, check whether a matching <name>_test.d "
                 "exists and how many unittest blocks the module itself contains. List the 5 largest modules (by line "
                 "count) that have neither a _test.d file nor any unittest block of their own.",
    "tools-funcs": "For every .d file directly in source/nano/tools, list each top-level function it defines "
                   "(name only) and the file's total line count. Answer as a compact table.",
    "catch-top": "Which 5 modules under source/nano (excluding *_test.d) contain the most `catch (Exception` "
                 "occurrences? For the top one, show its first 3 such lines with line numbers.",
    "todo-blame": "Find every TODO or FIXME comment in source/ (all .d files). For each, give file:line, the comment "
                  "text, and the short sha and author date of the commit that last touched that line (git blame).",
}


def newest_session(after):
    best = None
    for p in glob.glob(os.path.join(SESS, "*.jsonl")):
        m = os.path.getmtime(p)
        if m >= after and (best is None or m > best[0]):
            best = (m, p)
    return best[1] if best else None


def stats(path):
    turns = calls = inp = out = cached = 0
    aic = 0.0
    names = {}
    for line in open(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("type") != "message":
            continue
        d = r["data"]
        if d.get("role") == "assistant":
            turns += 1
            u = d.get("usage") or {}
            inp += u.get("input_tokens", 0) or u.get("prompt_tokens", 0) or 0
            out += u.get("output_tokens", 0) or u.get("completion_tokens", 0) or 0
            aic += u.get("aic", 0) or 0
            cached += u.get("cache_read_input_tokens", 0) or u.get("cached_tokens", 0) or 0
            for c in d.get("tool_calls") or []:
                n = c.get("name") or (c.get("function") or {}).get("name")
                calls += 1
                names[n] = names.get(n, 0) + 1
    return dict(turns=turns, aic=round(aic, 2), calls=calls, input=inp, output=out, cached=cached, tools=names)


def run(task, arm):
    """arm: plain | steered (NANO_CODEMODE=1 with system guidance, prompt unchanged)."""
    env = dict(os.environ)
    if arm in ("codemode", "steered"):
        env["NANO_CODEMODE"] = "1"
    else:
        env.pop("NANO_CODEMODE", None)
    t0 = time.time()
    p = subprocess.run([BIN, "-p", TASKS[task]], cwd=CWD, env=env, capture_output=True, text=True, timeout=900)
    wall = time.time() - t0
    s = newest_session(t0 - 1)
    st = stats(s) if s else {}
    st.update(task=task, arm=arm, wall=round(wall, 1), session=os.path.basename(s or ""), rc=p.returncode)
    answer = p.stdout.strip()
    return st, answer


if __name__ == "__main__":
    tasks = sys.argv[1:] or list(TASKS)
    out = os.environ.get("CMBENCH_OUT", "/tmp/cmbench2")
    reps = int(os.environ.get("CMBENCH_REPS", "2"))
    os.makedirs(out, exist_ok=True)
    for rep in range(reps):
        for t in tasks:
            for arm in ("plain", "steered"):
                st, ans = run(t, arm)
                st["rep"] = rep
                open(f"{out}/{t}-{arm}-{rep}.txt", "w").write(ans)
                print(json.dumps(st), flush=True)
