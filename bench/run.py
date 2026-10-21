#!/usr/bin/env python3
"""Rust vs D nano-coder harness benchmark.

Measures, on the same commit:
  * build time: clean release and debug builds, and a rebuild after touching
    one source file;
  * binary size (as built, and stripped);
  * runtime: wall time, peak RSS and peak memory footprint (macOS) for the
    same scripted task (glob, read, edit, bash, grep, final answer) against a
    deterministic local mock model, so only the harness is measured.

Usage: bench/run.py [--runs N] [--skip-build] [--out bench/results.json]
Run from the repo root. Needs cargo, dub + ldc2, python3, /usr/bin/time.
"""
import argparse
import json
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
D_DIR = ROOT / "d"
RUST_TARGET = ROOT / "target-bench"
RUST_BIN = RUST_TARGET / "release" / "nano-coder"
D_BIN = D_DIR / "nano-coder-d"
PROMPT = "Update notes.txt: replace beta with gamma, show it, and confirm."


def sh(cmd, cwd=None, env=None):
    t0 = time.perf_counter()
    subprocess.run(cmd, cwd=cwd, env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return time.perf_counter() - t0


def builds():
    env = dict(os.environ, CARGO_TARGET_DIR=str(RUST_TARGET))
    r = {}
    print("rust: fetching dependencies", file=sys.stderr)
    sh(["cargo", "fetch"], cwd=ROOT, env=env)
    shutil.rmtree(RUST_TARGET, ignore_errors=True)
    print("rust: clean release build", file=sys.stderr)
    r["rust_clean_release_s"] = sh(["cargo", "build", "--release"], cwd=ROOT, env=env)
    (ROOT / "src" / "files.rs").touch()
    r["rust_touch_one_file_release_s"] = sh(["cargo", "build", "--release"], cwd=ROOT, env=env)
    print("rust: clean debug build", file=sys.stderr)
    r["rust_clean_debug_s"] = sh(["cargo", "build"], cwd=ROOT, env=env)
    (ROOT / "src" / "files.rs").touch()
    r["rust_touch_one_file_debug_s"] = sh(["cargo", "build"], cwd=ROOT, env=env)

    print("d: builds", file=sys.stderr)
    shutil.rmtree(D_DIR / ".dub", ignore_errors=True)
    r["d_clean_debug_s"] = sh(["dub", "build", "--force", "-q"], cwd=D_DIR)
    (D_DIR / "source" / "nano" / "tools" / "files.d").touch()
    r["d_touch_one_file_debug_s"] = sh(["dub", "build", "-q"], cwd=D_DIR)
    r["d_clean_release_s"] = sh(["dub", "build", "--force", "-q", "-b", "release"], cwd=D_DIR)
    (D_DIR / "source" / "nano" / "tools" / "files.d").touch()
    r["d_touch_one_file_release_s"] = sh(["dub", "build", "-q", "-b", "release"], cwd=D_DIR)
    return r


def sizes():
    r = {}
    for name, b in (("rust", RUST_BIN), ("d", D_BIN)):
        r[f"{name}_binary_bytes"] = b.stat().st_size
        tmp = Path(tempfile.mkdtemp()) / b.name
        shutil.copy(b, tmp)
        subprocess.run(["strip", str(tmp)], check=True, stderr=subprocess.DEVNULL)
        r[f"{name}_stripped_bytes"] = tmp.stat().st_size
        r[f"{name}_linked_libs"] = [l.strip().split(" ")[0] for l in
                                    subprocess.run(["otool", "-L", str(b)], capture_output=True, text=True).stdout.splitlines()[1:]]
    return r


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


TIME_RE = {
    "real_s": re.compile(r"([\d.]+) real"),
    "max_rss_bytes": re.compile(r"(\d+)\s+maximum resident set size"),
    "peak_footprint_bytes": re.compile(r"(\d+)\s+peak memory footprint"),
    "instructions": re.compile(r"(\d+)\s+instructions retired"),
}


def runtime(runs):
    work = Path(tempfile.mkdtemp(prefix="nano-bench-"))
    home = work / "home"
    task = work / "task"
    home.mkdir()
    task.mkdir()
    port = free_port()
    server = subprocess.Popen([sys.executable, str(ROOT / "bench" / "mock_openai.py"), str(port), str(task)])
    time.sleep(0.5)
    config = work / "config.toml"
    config.write_text(f"""model = "mock/mock-model"
persist_sessions = false
project_instructions = false
temperature = "default"
max_iterations = 20

[providers.mock]
kind = "openai"
base_url = "http://127.0.0.1:{port}/v1"
api_key = "bench"
""")
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
               XDG_DATA_HOME=str(home / ".local/share"), NO_COLOR="1")
    cmds = {
        "rust": [str(RUST_BIN), "--config", str(config)],
        "d": [str(D_BIN), "--config", str(config), "--no-session"],
    }
    results = {}
    try:
        for name, cmd in cmds.items():
            samples = []
            for i in range(runs + 1):  # first run is a warm-up, discarded
                (task / "notes.txt").write_text("alpha\nbeta\n")
                p = subprocess.run(["/usr/bin/time", "-l"] + cmd, input=PROMPT + "\n", text=True,
                                   capture_output=True, cwd=task, env=env, timeout=120)
                content = (task / "notes.txt").read_text()
                if content != "alpha\ngamma\n":
                    raise SystemExit(f"{name}: task failed (notes.txt = {content!r})\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}")
                s = {k: float(m.group(1)) for k, rx in TIME_RE.items() if (m := rx.search(p.stderr))}
                if i:
                    samples.append(s)
            results[name] = {k: {"median": statistics.median(v[k] for v in samples),
                                 "min": min(v[k] for v in samples),
                                 "max": max(v[k] for v in samples)} for k in samples[0]}
            # idle footprint: start the REPL and exit immediately
            p = subprocess.run(["/usr/bin/time", "-l"] + cmd, input="", text=True, capture_output=True,
                               cwd=task, env=env, timeout=60)
            results[name]["startup_exit"] = {k: float(m.group(1)) for k, rx in TIME_RE.items() if (m := rx.search(p.stderr))}
    finally:
        server.terminate()
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--out", default=str(ROOT / "bench" / "results.json"))
    a = ap.parse_args()
    out = {"commit": subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
           "rustc": subprocess.run(["rustc", "--version"], capture_output=True, text=True).stdout.strip(),
           "ldc2": subprocess.run(["ldc2", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
           "machine": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()}
    if not a.skip_build:
        out["build"] = builds()
    out["size"] = sizes()
    out["runtime"] = runtime(a.runs)
    Path(a.out).write_text(json.dumps(out, indent=2))
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
