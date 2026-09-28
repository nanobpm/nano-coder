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


# Built-in provider presets nano-coder ships (src/providers/mod.rs `presets()`).
# These are valid provider names even without a `[providers.<name>]` table, so a
# spec like `github-copilot/gpt-4.1` resolves to the preset, not the default.
PRESET_PROVIDERS = frozenset({
    "openai", "anthropic", "openrouter", "fireworks", "groq", "together",
    "deepseek", "kimi", "mistral", "gemini", "github-copilot", "qwen",
    "ollama", "llamacpp", "mock",
})


def _load_toml(text):
    """Parse `text` with a real TOML parser, or `None` if none is available.
    `tomllib` is stdlib on Python 3.11+; `tomli` is the 3.10-and-earlier
    back-port. A malformed config also yields `None` so callers fall back."""
    try:
        import tomllib as toml
    except ModuleNotFoundError:
        try:
            import tomli as toml
        except ModuleNotFoundError:
            return None
    try:
        return toml.loads(text)
    except Exception:
        return None


def _toml_parses(text):
    """`True`/`False` whether `text` is valid TOML, or `None` when no parser is
    installed. Unlike `_load_toml`, this distinguishes a malformed document from
    a missing parser so callers can validate emitted config rather than silently
    falling back."""
    try:
        import tomllib as toml
    except ModuleNotFoundError:
        try:
            import tomli as toml
        except ModuleNotFoundError:
            return None
    try:
        toml.loads(text)
        return True
    except Exception:
        return False


def _effective_providers_regex(text):
    """Best-effort fallback for when no TOML parser is installed. Handles
    bare, double-quoted and single-quoted `[providers.<name>]` keys and both
    quote styles for a top-level `default_provider`, so it mirrors the real
    parser for the common config forms without a dependency."""
    header = re.compile(r"""(?m)^\s*\[providers\.\s*(?:"([^"]+)"|'([^']+)'|([^.\]\s"']+))""")
    providers = set(PRESET_PROVIDERS)
    for dq, sq, bare in header.findall(text):
        providers.add(dq or sq or bare)
    default, has_legacy, in_table = "mock", False, False
    for line in text.splitlines():
        if line.lstrip().startswith("["):
            in_table = True
            continue
        if in_table:
            continue
        key = line.split("=", 1)[0].strip()
        if key == "default_provider":
            m = re.search(r"""(?:"([^"]*)"|'([^']*)')""", line)
            if m:
                default = m.group(1) if m.group(1) is not None else m.group(2)
        elif key in ("api_key", "base_url"):
            has_legacy = True
    if default == "mock" and has_legacy:
        default = "openai"
    return providers, default


def effective_providers(base):
    """`(provider names, default_provider)` as nano-coder resolves them
    (src/providers/mod.rs `effective_providers`, src/config.rs): the built-in
    presets overlaid with configured `[providers.<name>]` tables, and the
    effective default provider. `default_provider` defaults to `mock`; a
    legacy top-level `api_key`/`base_url` promotes a `mock` default to
    `openai`. Only top-level keys count — provider-table keys are ignored."""
    text = Path(base).read_text() if base and Path(base).is_file() else ""
    data = _load_toml(text)
    if data is None:
        return _effective_providers_regex(text)
    configured = data.get("providers")
    configured = set(configured) if isinstance(configured, dict) else set()
    providers = set(PRESET_PROVIDERS) | configured
    default = data.get("default_provider")
    default = default if isinstance(default, str) else "mock"
    has_legacy = isinstance(data.get("api_key"), str) or isinstance(data.get("base_url"), str)
    if default == "mock" and has_legacy:
        default = "openai"
    return providers, default


def provider_for(model, base):
    """The provider table a model spec targets, matching nano-coder's rule
    (src/providers/mod.rs `parse_model_spec`): `provider/model` uses the head
    only when it names a known provider — a built-in preset OR a configured
    `[providers.<name>]` table; otherwise the whole spec is a model on the
    config's `default_provider`. So `gpt-4o` and `qwen3:8b` resolve to the
    default provider, while `github-copilot/gpt-4.1` resolves to the
    `github-copilot` preset even with no table for it."""
    providers, default = effective_providers(base)
    if "/" in model:
        head = model.split("/", 1)[0]
        if head in providers:
            return head
    elif model in providers:
        return model
    return default


def extra_body_arg(text):
    """Parse a --extra-body value, requiring it to decode to a JSON object.

    The merge path treats the value as a TOML table (it calls `.items()` on
    it), so a bare JSON array, string, or number would raise an
    ``AttributeError`` deep in a worker rather than reporting bad CLI input.

    A nested JSON ``null`` is also rejected here: TOML cannot represent it, and
    `config_text` runs inside a worker, so leaving it to fail there would abort
    the whole evaluation with a `SystemExit` instead of a clean CLI error."""
    try:
        value = json.loads(text)
    except json.JSONDecodeError as e:
        raise argparse.ArgumentTypeError(f"invalid JSON: {e}")
    if not isinstance(value, dict):
        raise argparse.ArgumentTypeError(
            f"must be a JSON object (e.g. '{{\"chat_template_kwargs\": {{...}}}}'), "
            f"not a JSON {type(value).__name__}")

    def reject_null(node, path):
        if node is None:
            where = "".join(path) or "the top level"
            raise argparse.ArgumentTypeError(
                f"contains a JSON null at {where}, which TOML cannot represent; "
                f"remove the null field or give it a real value")
        if isinstance(node, dict):
            for k, v in node.items():
                reject_null(v, path + [f".{k}"])
        elif isinstance(node, list):
            for i, v in enumerate(node):
                reject_null(v, path + [f"[{i}]"])

    reject_null(value, [])
    return value


def config_text(base, session_dir, mode, extra_body=None, providers=()):
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
    tail = []
    if extra_body:
        # Inline-table form of the JSON; appended per provider under test.
        def toml_value(v):
            if v is None:
                sys.exit("error: --extra-body contains a JSON null, which TOML cannot represent; "
                         "remove the null field or give it a real value")
            if isinstance(v, bool):
                return "true" if v else "false"
            if isinstance(v, dict):
                return "{ " + ", ".join(f"{json.dumps(k)} = {toml_value(x)}" for k, x in v.items()) + " }"
            if isinstance(v, list):
                return "[" + ", ".join(toml_value(x) for x in v) + "]"
            return json.dumps(v)
        def toml_key(name):
            # A TOML dotted-key segment: bare when it is a valid bare key,
            # otherwise a quoted key so provider names with dots/spaces (e.g.
            # `my.provider`) address one table instead of nesting.
            if re.fullmatch(r"[A-Za-z0-9_-]+", name):
                return name
            return json.dumps(name)
        def deep_merge(base_body, override):
            # Recursively overlay `override` onto `base_body`; a scalar/list in
            # `override` replaces, but two tables merge so the CLI can set one
            # nested field (e.g. chat_template_kwargs.enable_thinking) without
            # dropping the base's siblings.
            out = dict(base_body)
            for k, v in override.items():
                if isinstance(v, dict) and isinstance(out.get(k), dict):
                    out[k] = deep_merge(out[k], v)
                else:
                    out[k] = v
            return out
        def header_segments(line):
            # Dotted-key segments of a `[table]`/`[[table]]` header (quoted
            # segments keep dots/spaces), or None when `line` is not a header.
            m = re.match(r"\s*\[\[?(.*?)\]\]?\s*(?:#.*)?$", line)
            if not m:
                return None
            return [dq or sq or bare for dq, sq, bare
                    in re.findall(r'"([^"]*)"|\'([^\']*)\'|([^.\s]+)', m.group(1))]
        def key_segments(key_part):
            # All dotted-key segments of a `key = value` assignment's key
            # (quoted segments keep their dots/spaces).
            return [dq or sq or bare for dq, sq, bare
                    in re.findall(r'"([^"]*)"|\'([^\']*)\'|([^.\s]+)', key_part)]
        def strip_extra_body(cfg_lines, provider):
            # Drop an existing extra_body for `provider` (an inline
            # `extra_body = {...}` or dotted `extra_body.<field> = ...`
            # assignment under `[providers.<p>]`, or a
            # `[providers.<p>.extra_body]` sub-table and any of its own
            # sub-tables) so the merged table we emit is the only one — two
            # declarations of the same key would be invalid TOML. Match on the
            # full dotted path (`cur` + the assignment's key segments) so a
            # fully-qualified root assignment such as
            # `providers.<p>.extra_body = {...}` (or `providers.<p>.extra_body.x`)
            # is stripped too, not just keys written under a `[providers.<p>]`
            # header.
            target = ["providers", provider, "extra_body"]
            kept, cur, dropping = [], [], False
            for line in cfg_lines:
                segs = header_segments(line)
                if segs is not None:
                    cur, dropping = segs, segs[:len(target)] == target
                    if not dropping:
                        kept.append(line)
                    continue
                if dropping:
                    continue
                if "=" in line \
                        and (cur + key_segments(line.split("=", 1)[0]))[:len(target)] == target:
                    continue
                kept.append(line)
            return kept
        parsed = _load_toml("\n".join(lines))
        base_providers = parsed.get("providers") if isinstance(parsed, dict) else None
        for provider in providers:
            key = toml_key(provider)
            if base_providers is None:
                # No TOML parser installed: we cannot read the existing table to
                # merge it, so fall back to detecting and skipping rather than
                # emitting a duplicate. Match a bare or quoted provider header.
                text = "\n".join(lines)
                prov_pat = rf"(?:{re.escape(provider)}|{re.escape(json.dumps(provider))})"
                # Recognize the same indented/quoted/dotted forms strip_extra_body
                # handles: an existing `[providers.<p>.extra_body]` sub-table, or an
                # `extra_body`/`extra_body.<field>` key (bare or quoted, optionally
                # indented) under `[providers.<p>]`. `[.=]` after the key name avoids
                # matching unrelated keys such as `extra_body_extra`.
                eb_key = r"[ \t]*(?:extra_body|\"extra_body\"|'extra_body')[ \t]*[.=]"
                if re.search(rf"(?m)^[ \t]*\[providers\.{prov_pat}\.extra_body\]", text) \
                        or re.search(rf"(?ms)^[ \t]*\[providers\.{prov_pat}\](?:(?!^[ \t]*\[).)*?^{eb_key}", text):
                    print(f"warning: providers.{provider} already sets extra_body and no TOML parser is "
                          f"available to merge it; --extra-body ignored for it", file=sys.stderr)
                    continue
                merged = extra_body
            else:
                prov_conf = base_providers.get(provider)
                has_extra_body = isinstance(prov_conf, dict) and "extra_body" in prov_conf
                existing = prov_conf.get("extra_body") if isinstance(prov_conf, dict) else None
                existing = existing if isinstance(existing, dict) else {}
                if has_extra_body:
                    lines = strip_extra_body(lines, provider)
                merged = deep_merge(existing, extra_body)
            tail.append(f"[providers.{key}.extra_body]")
            tail += [f"{json.dumps(k)} = {toml_value(v)}" for k, v in merged.items()]
    result = "\n".join(head + lines + tail) + "\n"
    if extra_body and _toml_parses(result) is False:
        # A parser is available (so we read/merged the base) yet the emitted
        # config is invalid TOML. This happens when a provider under test is
        # written as an inline table — `foo = { ... }` under `[providers]`, or a
        # root-level `providers = { foo = { ... } }` — because `[providers.<p>.
        # extra_body]` cannot extend an inline table (whether or not it already
        # had an extra_body). Reject with a clear error instead of writing an
        # unusable config that fails opaquely when nano-coder loads it.
        raise ValueError(
            "--extra-body produced invalid TOML: a provider under test is defined "
            "as a TOML inline table (e.g. `provider = { ... }` under `[providers]`, "
            "or `providers = { ... }`), which `[providers.<name>.extra_body]` cannot "
            "extend. Rewrite the affected provider as a standard `[providers.<name>]` "
            "table (header form) to use --extra-body."
        )
    return result


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


def reuse_cases(results_files):
    """Compacted logs from earlier runs, cut right after the compaction, so a
    new model only answers the question (no summary to write: the costly part
    on a slow model). Keeps smart runs whose detail was lost and that did not
    error; the summary was written by the earlier run's model."""
    out = []
    for file in results_files:
        for line in open(file):
            if not line.strip():
                continue
            r = json.loads(line)
            if r.get("mode") != "smart" or "error" in r or r.get("kept", r.get("summary_kept")):
                continue
            records = read_log(r["session"])
            at = max((i for i, x in enumerate(records) if x["type"] == "replace" and "mode" in x["data"]), default=None)
            if at is None:
                continue
            if "question" in r:
                question, expect, forbid = r["question"], r["expect"], r.get("forbid", [])
            else:
                # Older results: rebuild the synthetic case from name and seed.
                # Only the built-in `name/s<seed>` shape (a known synthetic case
                # plus an integer seed) can be reconstructed; any other legacy
                # case name (e.g. a custom `--cases` entry) is skipped rather than
                # aborting the whole reuse run.
                m = re.fullmatch(r"(.*)/s(\d+)", r["case"])
                if not m or m.group(1) not in synthetic.CASES:
                    print(f"warning: skipping {r['case']}: not a rebuildable synthetic case",
                          file=sys.stderr)
                    continue
                name, seed = m.group(1), int(m.group(2))
                case = synthetic.build(name, seed, 15)
                question, expect, forbid = case["question"], case["expect"], case["forbid"]
                text = json.dumps(records[:at])
                if not matches_all(expect, text):
                    print(f"warning: skipping {r['case']}: rebuilt answer not in its log", file=sys.stderr)
                    continue
            out.append({
                "name": f"{r['case']}@{r['model'].split('/')[-1]}",
                "records": records[:at + 1],
                "question": question, "expect": expect, "forbid": forbid,
                "precompacted": True,
            })
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


def run_one(args, index, case, model, mode, repeat, work_root):
    run_dir = work_root / f"{case['name'].replace('/', '_')}-{model.replace('/', '_').replace(':', '_')}-{mode}-r{repeat}-j{index}"
    session_dir, cwd = run_dir / "sessions", run_dir / "cwd"
    cwd.mkdir(parents=True, exist_ok=True)
    if case.get("cwd") and args.tools == "all":
        cwd = Path(case["cwd"]).expanduser()
    session_id = f"eval-{uuid.uuid4().hex[:12]}"
    write_log(case["records"], session_dir, session_id)
    config = run_dir / "config.toml"
    config.write_text(config_text(args.config, session_dir, mode, args.extra_body, [provider_for(model, args.config)]))
    result = {"case": case["name"], "model": model, "mode": mode, "repeat": repeat, "tools": args.tools,
              "question": case["question"], "expect": case["expect"], "forbid": case["forbid"], "session": str(session_dir / f"{session_id}.jsonl")}
    started = time.monotonic()
    argv = [args.bin, "--acp", "--config", str(config), "--model", model]
    if args.tools == "history":
        argv += [a for tool in WORK_TOOLS for a in ("--deny", tool)]
    acp = Acp(argv, cwd, run_dir / "stderr.txt", args.timeout)
    try:
        acp.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        acp.call("session/load", {"sessionId": session_id, "cwd": str(cwd), "mcpServers": []})
        if case.get("precompacted"):
            result["compacted"], result["fallback"] = True, None
        else:
            compacted = acp.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": f"/compact --{mode}"}]})
            result["compacted"] = bool(compacted and compacted.get("compacted"))
            result["fallback"] = compacted.get("fallback") if compacted else None
        question = case["question"] + (" Answer in one line." if args.terse else "")
        acp.call("session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": question}]})
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
    p.add_argument("--reuse-compaction", action="append", metavar="RESULTS",
                   help="answer only: reuse compacted logs from earlier smart runs where the detail was lost "
                        "(skips writing a summary; for slow models). Implies --modes smart and no synthetic cases")
    p.add_argument("--extra-body", type=extra_body_arg, metavar="JSON",
                   help='merged into requests of the providers under test, e.g. \'{"chat_template_kwargs": {"enable_thinking": false}}\'')
    p.add_argument("--shuffle", action="store_true", help="run jobs in a random (seeded) order, for a time-boxed sample")
    p.add_argument("--max-minutes", type=float, help="start no new runs after this long; unstarted runs are skipped")
    p.add_argument("--terse", action="store_true", help='append "Answer in one line." to questions')
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
    # Runs start in their own working directory, so resolve paths now.
    if os.sep in args.bin:
        args.bin = str(Path(args.bin).resolve())
    elif shutil.which(args.bin):
        args.bin = shutil.which(args.bin)

    if args.self_test:
        import fake_llm
        base_url = fake_llm.start()
        base = Path(tempfile.mkdtemp(prefix="compaction-eval-fake-")) / "config.toml"
        base.write_text(f'[providers.fake]\nkind = "openai"\nbase_url = "{base_url}"\napi_key = "x"\nstream = false\ncontext_window = 128000\n')
        args.config, args.models = str(base), "fake/oracle"
    if not args.models:
        p.error("--models is required (or use --self-test)")
    if args.reuse_compaction:
        args.modes, args.synthetic = "smart", ""
    cases = load_cases(args) + (reuse_cases(args.reuse_compaction) if args.reuse_compaction else [])
    if not cases:
        sys.exit("no cases")
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    modes = [m.strip() for m in args.modes.split(",") if m.strip()]
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    results_path = out_dir / f"{stamp}.jsonl"
    work_root = Path(tempfile.mkdtemp(prefix=f"compaction-eval-{stamp}-"))
    # A unique index per job keeps run_dir distinct even when two cases share a
    # name (duplicate reuse entries, or the same case across --cases files), so
    # parallel jobs never share and overwrite each other's config/session files.
    jobs = [(i, c, m, mo, r) for i, (c, m, mo, r) in enumerate(
        (c, m, mo, r) for c in cases for m in models for mo in modes for r in range(args.repeats))]
    print(f"{len(jobs)} runs ({len(cases)} cases x {len(models)} models x {len(modes)} modes x {args.repeats}); "
          f"logs in {work_root}; results in {results_path}", file=sys.stderr)

    if args.shuffle:
        import random
        random.Random(0).shuffle(jobs)
    deadline = time.monotonic() + args.max_minutes * 60 if args.max_minutes else None

    def run_job(*job):
        if deadline and time.monotonic() > deadline:
            return None
        return run_one(args, *job, work_root)

    results = []
    lock = threading.Lock()
    with open(results_path, "w") as sink, concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = [pool.submit(run_job, *job) for job in jobs]
        for done, future in enumerate(concurrent.futures.as_completed(futures), 1):
            r = future.result()
            if r is None:
                continue
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
