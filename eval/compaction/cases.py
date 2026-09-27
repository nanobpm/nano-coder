"""Synthetic eval cases: session logs where one detail is established early
and then buried under enough later work that a summary is likely to lose it.

Each builder returns (records, question, expect, forbid). Unique tokens are
derived from `seed`, so a model cannot know the answer without the history.
"""
import json
import random
from datetime import datetime, timezone

NOW = datetime(2026, 1, 1, tzinfo=timezone.utc).isoformat()


class Log:
    def __init__(self, system="You are a helpful assistant with access to tools."):
        self.records = [{"type": "session", "data": {"version": 1, "id": "PLACEHOLDER", "created_at": NOW}}]
        self.msg("system", system)
        self.turns = 0
        self.calls = 0

    def msg(self, role, content, **extra):
        self.records.append({"type": "message", "data": {"role": role, "content": content, **extra}})

    def user(self, text):
        self.turns += 1
        self.input_id = f"in-{self.turns}"
        self.records.append({"type": "input", "data": {"id": self.input_id, "text": text, "recorded_at": NOW}})
        self.msg("user", text)

    def tool(self, name, arguments, output, error=False):
        self.calls += 1
        call_id = f"call_{self.calls}"
        self.msg("assistant", "", tool_calls=[{"id": call_id, "name": name, "arguments": arguments}])
        extra = {"tool_call_id": call_id, "name": name}
        if error:
            extra["is_error"] = True
        self.msg("tool", output, **extra)

    def answer(self, text):
        self.msg("assistant", text)
        self.records.append({"type": "turn_end", "data": {"input_id": self.input_id, "response": text, "recorded_at": NOW}})

    def bash(self, command, output, error=False):
        self.tool("bash", {"command": command}, output, error)


def noise(rng, lines=60, distractor=None):
    """Plausible build/test output, optionally with a distractor error line."""
    crates = ["lease", "cache", "auth", "store", "net", "cli", "proto"]
    out = []
    for i in range(lines):
        crate = rng.choice(crates)
        kind = rng.random()
        if kind < 0.5:
            out.append(f"   Compiling {crate}-{rng.randint(0, 9)}.{rng.randint(0, 30)}.{rng.randint(0, 9)} (/work/{crate})")
        elif kind < 0.8:
            out.append(f"test {crate}::tests::case_{rng.randint(100, 999)} ... ok")
        else:
            out.append(f"warning: unused variable: `tmp_{rng.randint(10, 99)}` --> src/{crate}.rs:{rng.randint(1, 400)}:{rng.randint(1, 80)}")
        if distractor and i == lines // 2:
            out.append(distractor)
    return "\n".join(out)


def filler(log, rng, turns):
    """Unrelated follow-on work with distractors that resemble the target."""
    topics = ["retry backoff", "log formatting", "the CLI flags", "the cache eviction test", "docs for the store API",
              "a clippy warning", "the CI matrix", "error messages in net", "the proto schema", "benchmarks"]
    for t in range(turns):
        topic = rng.choice(topics)
        log.user(f"Next, look at {topic}.")
        for _ in range(rng.randint(1, 3)):
            n = rng.randint(1000, 9999)
            distractor = rng.choice([
                f"error[E0425]: cannot find value `ttl_{n}` in this scope",
                f"error: test failed, to rerun pass `-p {rng.choice(['net', 'cli', 'store'])} --lib`",
                f"thread 'main' panicked at src/store.rs:{rng.randint(1, 300)}: index out of bounds",
            ])
            log.bash(f"cargo test -p {rng.choice(['net', 'cli', 'store', 'cache'])} {topic.split()[-1]}",
                     noise(rng, rng.randint(40, 90), distractor))
        log.answer(f"Done with {topic}: adjusted {rng.randint(2, 9)} lines and the tests pass.")


def buried_error(seed, filler_turns):
    rng = random.Random(seed)
    method = f"refresh_lease_v{rng.randint(10, 99)}_{rng.choice(['sync', 'fast', 'lazy'])}"
    log = Log()
    log.user("The lease tests are failing on CI. Find out why.")
    log.bash("cargo build -p lease", noise(rng, 80, f"error[E0599]: no method named `{method}` found for struct `TokenCache` in the current scope"), error=True)
    log.answer("The build fails in the lease crate: a method call on TokenCache doesn't resolve. I'll look at the cache API next.")
    filler(log, rng, filler_turns)
    return log.records, "Earlier, a cargo build of the lease crate failed. Quote the exact method name from that error message.", [method], []


def user_constraint(seed, filler_turns):
    rng = random.Random(seed)
    branch = f"jw/lease-fix-{rng.randint(1000, 9999)}"
    port = rng.randint(8100, 8999)
    log = Log()
    log.user(f"Fix the lease renewal race. Constraints: work on branch {branch}, run the dev server on port {port} (never 5173), and don't touch the proto crate.")
    log.bash("git status", "On branch main\nnothing to commit, working tree clean")
    log.answer("Understood. I'll start by reading the lease renewal code.")
    filler(log, rng, filler_turns)
    return log.records, "Remind me: what branch name and dev-server port did I ask for at the very start?", [branch, str(port)], ["5173"]


def working_command(seed, filler_turns):
    rng = random.Random(seed)
    feature = f"chaos{rng.randint(10, 99)}"
    threads = rng.choice([1, 2, 3])
    command = f"RUST_LOG=trace cargo test -p lease --features {feature} -- --test-threads={threads}"
    log = Log()
    log.user("Get the lease tests passing locally.")
    log.bash("cargo test -p lease", noise(rng, 60, "test result: FAILED. 3 passed; 2 failed"), error=True)
    log.bash("cargo test -p lease -- --nocapture", noise(rng, 60, "test result: FAILED. 3 passed; 2 failed"), error=True)
    log.bash(command, noise(rng, 60, "test result: ok. 5 passed; 0 failed"))
    log.answer("The lease tests pass now with the right feature and thread settings.")
    filler(log, rng, filler_turns)
    return log.records, "Which exact command finally made the lease tests pass? Give it verbatim.", [f"--features {feature}", f"--test-threads={threads}"], []


def rejected_approach(seed, filler_turns):
    rng = random.Random(seed)
    pr = rng.randint(300, 999)
    log = Log()
    log.user(f"Look at the TokenCache contention. Don't add a mutex around the cache: we tried that in PR #{pr} and it deadlocked under renewal.")
    log.bash("rg -n 'struct TokenCache' src", "src/cache.rs:14:pub struct TokenCache {")
    log.answer("Noted. I'll look at lock-free options for TokenCache.")
    filler(log, rng, filler_turns)
    return log.records, "Should I just add a mutex around TokenCache? Answer yes or no, and say which PR and what happened.", [rf"#?{pr}", "deadlock"], []


def recent_control(seed, filler_turns):
    """Control: the detail is in the last message, which compaction keeps."""
    rng = random.Random(seed)
    code = f"LX-{rng.randint(10000, 99999)}"
    log = Log()
    log.user("Start on the lease work.")
    log.answer("Starting.")
    filler(log, rng, filler_turns)
    log.user("What's the ticket number for this?")
    log.answer(f"The ticket is {code}.")
    return log.records, "What ticket number did you give me just now?", [code], []


CASES = {
    "buried-error": buried_error,
    "user-constraint": user_constraint,
    "working-command": working_command,
    "rejected-approach": rejected_approach,
    "recent-control": recent_control,
}


def build(name, seed, filler_turns):
    records, question, expect, forbid = CASES[name](seed, filler_turns)
    return {"name": name, "records": records, "question": question, "expect": expect, "forbid": forbid}


if __name__ == "__main__":
    import sys
    case = build(sys.argv[1] if len(sys.argv) > 1 else "buried-error", 1, 12)
    for record in case["records"]:
        print(json.dumps(record))
