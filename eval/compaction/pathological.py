"""Pathological compaction cases: robustness, not recall.

Ported from the stress corpus of pi-compaction-rank
(https://github.com/a-canary/pi-compaction-rank, stress/corpus.ts, MIT),
adapted to nano-coder's session log, plus cases for the failure modes that
corpus found in other compaction extensions: a summary-merge ratchet over
many compactions, and a failed or empty summary written as if it were real.

These cases do not ask whether a detail was recalled. Each run compacts the
log (some more than once), asks a trivial question, and `check` asserts
invariants on what compaction wrote:

- the run finished: nano-coder answered after compacting
- every compaction left a non-empty summary
- a failed or empty summary is never presented as a real one: it falls back
  to the "no summary is available" note (with the history pointer in smart mode)
- the kept messages never split a tool call from its result
- the user's first request survives in the pinned block
- repeated compactions don't ratchet the summary size upwards

They need no provider: the self-test runs them against fake_llm.py, whose
summary behaviour a case selects with a marker in its log.
"""
import json
import random

from cases import Log, noise

# fake_llm.py reacts to these markers in the transcript it is asked to summarize.
EMPTY_SUMMARY_MARKER = "EVAL-SUMMARY-EMPTY"
FAIL_SUMMARY_MARKER = "EVAL-SUMMARY-FAIL"

QUESTION = "Reply with one word: done."
# The harness's default follow-up between repeated compactions (run.py).
ACK_PROMPT = "Reply with a bare acknowledgement and nothing else."


def big(n, unit="abcdefghij"):
    return (unit * (n // len(unit) + 1))[:n]


def huge_tool_result(seed):
    """c04: one tool result of several MB."""
    log = Log()
    log.user("Read the big file and tell me what is in it.")
    log.tool("read_file", {"path": "/tmp/huge.bin"}, big(2_000_000))
    log.answer("It is a large repetitive blob.")
    return log, {}


def many_tiny_turns(seed):
    """c05: thousands of tiny turns."""
    log = Log()
    for i in range(2500):
        log.user(f"u{i}")
        log.answer(f"a{i}")
    return log, {}


def unicode_and_control(seed):
    """c06 + c10: emoji, RTL overrides, zero-width, NUL, DEL, ANSI, CR."""
    log = Log()
    log.user("emoji 🎉🔥 rtl \u202eabc\u202c zwsp\u200b\u200b nul\u0000 del\u007f bell\u0007 esc\u001bd")
    log.bash("printf colours", "\x1b[31mred\x1b[0m\r\nCRLF" + "\r" * 5000)
    log.answer("中文 тест العربية " + big(2000, "\u0000\t"))
    return log, {}


def null_content(seed):
    """c07: messages with null or missing content."""
    log = Log()
    log.user("x")
    log.records.append({"type": "message", "data": {"role": "assistant", "content": None}})
    log.records.append({"type": "message", "data": {"role": "assistant"}})
    log.answer("ok")
    return log, {}


def huge_tool_args(seed):
    """c08: a tool call whose arguments are ~1 MB."""
    log = Log()
    log.user("Write the file.")
    log.tool("write_file", {"path": "/tmp/a.ts", "content": big(1_000_000)}, "ok")
    log.answer("Written.")
    return log, {}


def batch_tool_calls(seed):
    """c12: one assistant message with 200 parallel tool calls."""
    log = Log()
    log.user("Run the batch.")
    calls = [{"id": f"call_b{i}", "name": "bash", "arguments": {"command": f"cmd{i}"}} for i in range(200)]
    log.msg("assistant", "", tool_calls=calls)
    for i in range(200):
        log.msg("tool", f"out{i}", tool_call_id=f"call_b{i}", name="bash")
    log.answer("All 200 commands ran.")
    return log, {}


def orphan_tool_result(seed):
    """c13: a tool result whose call never existed."""
    log = Log()
    log.user("x")
    log.msg("tool", "orphan", tool_call_id="nope", name="ghost")
    log.answer("ok")
    return log, {}


def duplicates(seed):
    """c14: hundreds of identical exchanges."""
    log = Log()
    for _ in range(500):
        log.user("identical prompt")
        log.answer("identical answer")
    return log, {}


def deep_nested_args(seed):
    """c17: deeply nested tool arguments."""
    log = Log()
    log.user("x")
    args = {"a": {"b": {"c": [1, 2, 3, {"d": big(50_000)}, {"e": [{"i": i, "s": big(200)} for i in range(200)]}]}}}
    log.tool("weird", args, "ok")
    log.answer("ok")
    return log, {}


def huge_single_turn(seed):
    """One user turn whose tool work alone exceeds what compaction keeps, so
    the cut has to land inside the turn without splitting a call from its
    result."""
    rng = random.Random(seed)
    log = Log()
    log.user("Get every crate building; keep going until all are green.")
    for i in range(60):
        log.bash(f"cargo build -p crate{i}", noise(rng, 120))
    log.answer("All crates build.")
    return log, {}


def summary_ratchet(seed):
    """The summary-merge ratchet: eight compactions, each folding the
    previous summary back in. The summary must not grow without new work."""
    rng = random.Random(seed)
    log = Log()
    log.user("Keep the lease crate green while I review.")
    for i in range(6):
        log.bash(f"cargo test -p lease case{i}", noise(rng, 40))
    log.answer("The lease crate is green.")
    return log, {"compactions": 8}


def empty_summary(seed):
    """The model returns an empty summary: it must not be written as one."""
    log = Log()
    log.user(f"Summarize nothing. {EMPTY_SUMMARY_MARKER}")
    log.bash("true", "")
    log.answer("ok")
    return log, {"expect_fallback": True}


def failed_summary(seed):
    """The summary request errors: history is replaced only by an honest
    "no summary is available" note."""
    log = Log()
    log.user(f"Summarize this. {FAIL_SUMMARY_MARKER}")
    log.bash("true", "")
    log.answer("ok")
    return log, {"expect_fallback": True}


CASES = {
    "huge-tool-result": huge_tool_result,
    "many-tiny-turns": many_tiny_turns,
    "unicode-control": unicode_and_control,
    "null-content": null_content,
    "huge-tool-args": huge_tool_args,
    "batch-tool-calls": batch_tool_calls,
    "orphan-tool-result": orphan_tool_result,
    "duplicates": duplicates,
    "deep-nested-args": deep_nested_args,
    "huge-single-turn": huge_single_turn,
    "summary-ratchet": summary_ratchet,
    "empty-summary": empty_summary,
    "failed-summary": failed_summary,
}


def build(name, seed):
    log, opts = CASES[name](seed)
    first_request = next(r["data"]["text"] for r in log.records if r["type"] == "input")
    return {"name": f"patho:{name}/s{seed}", "records": log.records, "question": QUESTION,
            "expect": [], "forbid": [], "pathological": True, "first_request": first_request, **opts}


NO_SUMMARY = "no summary is available"


def _summary_of(messages):
    return next((m.get("content") or "" for m in messages
                 if m.get("role") == "user" and str(m.get("content") or "").startswith("[")), None)


def _pairing(messages):
    """Tool calls and results in `messages` must pair up: no result without
    its call, no call without its result."""
    problems, open_calls = [], set()
    for i, m in enumerate(messages):
        if m.get("role") == "assistant":
            for c in m.get("tool_calls") or []:
                open_calls.add(c.get("id"))
        elif m.get("role") == "tool":
            cid = m.get("tool_call_id")
            if cid in open_calls:
                open_calls.discard(cid)
            else:
                problems.append(f"kept tool result {cid!r} (message {i}) has no call before it")
    if open_calls:
        problems.append(f"{len(open_calls)} kept tool call(s) have no result")
    return problems


def summary_sizes(new_records):
    """Characters of each compaction's summary, in order."""
    return [len(_summary_of(r["data"].get("messages") or []) or "")
            for r in new_records if r["type"] == "replace" and "mode" in r["data"]]


def check(case, mode, records, seeded):
    """Invariant violations for one run (empty when robust).

    `records` is the whole log after the run; the first `seeded` were the case."""
    new = records[seeded:]
    replaces = [r["data"] for r in new if r["type"] == "replace" and "mode" in r["data"]]
    want = int(case.get("compactions", 1))
    problems = []
    if not any(r["type"] == "turn_end" for r in new):
        problems.append("no answer after compacting (did nano-coder crash or hang?)")
    if len(replaces) < want:
        # A compaction may legitimately skip when there is nothing to fold;
        # that is only a problem when the case needs every one.
        if want > 1 or not replaces:
            problems.append(f"{len(replaces)} of {want} compactions happened")
    sizes = []
    for k, data in enumerate(replaces, 1):
        messages = data.get("messages") or []
        summary = _summary_of(messages)
        if not summary or not summary.strip():
            problems.append(f"compaction {k} wrote an empty summary")
            continue
        sizes.append(len(summary))
        if case.get("expect_fallback") and mode.startswith("extract"):
            # Extract makes no model call, so a failing model can't fail it:
            # it must write its normal summary.
            if NO_SUMMARY in summary:
                problems.append(f"compaction {k}: extract fell back, but it needs no model")
        elif case.get("expect_fallback"):
            if NO_SUMMARY not in summary:
                problems.append(f"compaction {k}: a failed or empty summary was not reported as missing")
            if not mode.startswith("standard") and "history_read" not in summary and "history_search" not in summary:
                problems.append(f"compaction {k}: the fallback note doesn't point at the history tools")
        elif NO_SUMMARY in summary:
            problems.append(f"compaction {k} fell back unexpectedly")
        problems += [f"compaction {k}: {p}" for p in _pairing(messages)]
        first = case.get("first_request") or ""
        visible = "\n".join(str(m.get("content") or "") for m in messages)
        if first and first.replace("\u0000", "")[:60] not in visible.replace("\u0000", "") and "-nopin" not in mode:
            problems.append(f"compaction {k}: the first user request is not pinned")
    if len(sizes) > 2:
        # Between compactions the harness sends one short follow-up, which is
        # a new user request and is pinned verbatim, so each summary may grow
        # by that request plus its list marker. Anything more is the previous
        # summary being folded in and restated: a ratchet. The first step is
        # exempt, as the first summary is folded in once.
        step = len(case.get("between", ACK_PROMPT)) + 32
        grown = [(k + 1, b - a) for k, (a, b) in enumerate(zip(sizes[1:], sizes[2:]), 2) if b - a > step]
        if grown:
            problems.append(f"summary ratchets upwards across compactions: sizes {sizes}, "
                            f"(compaction, growth) beyond {step} chars: {grown}")
    return problems


def self_check():
    """`check` must flag each violation it claims to guard against: a broken
    invariant that no case trips would otherwise pass silently. Returns a list
    of problems with `check` itself (empty when it catches them all)."""
    req = "Keep the lease crate green."
    case = {"first_request": req}

    def run(summaries, kept=(), answered=True, **opts):
        records = [{"type": "replace", "data": {"mode": "smart", "messages": [
            {"role": "user", "content": s}, {"role": "user", "content": req}, *kept]}} for s in summaries]
        if answered:
            records.append({"type": "turn_end", "data": {}})
        return check({**case, **opts}, "smart", records, 0)

    good = "[Summary] fine; see history_read"
    call = {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "name": "bash"}]}
    result = {"role": "tool", "content": "ok", "tool_call_id": "c1"}
    expectations = {
        "a healthy run": (run([good], [call, result]), False),
        "no answer": (run([good], answered=False), True),
        "a terse summary": (run(["[ ]"]), False),
        "a blank summary": (run([""]), True),
        "a missing compaction": (run([good], compactions=2), True),
        "a result without its call": (run([good], [result]), True),
        "a call without its result": (run([good], [call]), True),
        "an unpinned first request": (check(case, "smart", [{"type": "replace", "data": {"mode": "smart", "messages": [
            {"role": "user", "content": good}]}}, {"type": "turn_end", "data": {}}], 0), True),
        "a failed summary presented as real": (run([good], expect_fallback=True), True),
        "an honest fallback": (run([f"[x] {NO_SUMMARY}; history_read"], expect_fallback=True), False),
        "a ratchet": (run(["[a]" + "x" * n for n in (100, 200, 400, 800)], compactions=4), True),
        "a plateau": (run(["[a]" + "x" * n for n in (100, 150, 200, 250)], compactions=4), False),
    }
    problems = []
    for what, (violations, expected) in expectations.items():
        if bool(violations) != expected:
            problems.append(f"check() {'missed' if expected else 'wrongly flagged'} {what}: {violations}")
    return problems


if __name__ == "__main__":
    import sys
    case = build(sys.argv[1] if len(sys.argv) > 1 else "summary-ratchet", 0)
    for record in case["records"]:
        print(json.dumps(record))
