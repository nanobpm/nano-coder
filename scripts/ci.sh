#!/bin/sh
# The checks CI runs, in one place: .github/workflows/ci.yml calls this, and
# .githooks/pre-push runs `quick` before every push, so a push has passed the
# same checks CI will run. Add a check here, not in the workflow.
#
#   scripts/ci.sh [all|lint|test|quick]   (default: all)
#
#   lint   platform matrix, check-safe, parity manifest, docs links, ratchet tests, dscanner                   (CI job `lint`)
#   test   unit tests, release build, docs reference drift and smoke checks (CI jobs `test (<os>)`)
#   quick  check-safe, both builds typechecked, unit tests (pre-push)
#   all    lint + test
set -eu
cd "$(dirname "$0")/.."
# Run from a git hook, git's repository variables (GIT_DIR, GIT_INDEX_FILE, ...)
# are set; tests that run git in temp directories would act on this repository.
# shellcheck disable=SC2046 # one name per word
unset $(git rev-parse --local-env-vars)

step() { printf '\n==> %s\n' "$*"; }

# Typecheck the release and the unittest build: names that only one of them
# sees (e.g. test-only imports) fail here instead of in CI. `$1` adds flags,
# e.g. a cross target.
typecheck() {
    files=$(find source -name '*.d' | sort)
    for build in "" "-unittest"; do
        step "typecheck ${build:-release} ${1:-}"
        # shellcheck disable=SC2086 # word splitting is intended
        ldc2 -o- -w -lowmem -allinst -preview=dip1000 -preview=nosharedaccess -Isource -Jsource ${1:-} $build $files
    done
}

lint() {
    step "platforms: PR CI tests every Release platform"
    ./scripts/check-platforms.sh
    step "check-safe"
    # In CI the ratchets must be compared against the merge base (the
    # workflow fetches full history so origin/main is there); outside CI the
    # caller's NANO_RATCHET_REQUIRE is kept.
    if [ -n "${CI:-}" ]; then
        NANO_RATCHET_REQUIRE=1 ./scripts/check-safe.sh
    else
        ./scripts/check-safe.sh
    fi
    step "parity manifest"
    # Needs the rust-final tag (CI checks out with fetch-depth 0, which
    # fetches tags); a shallow or tagless clone skips it.
    if git rev-parse -q --verify 'refs/tags/rust-final^{commit}' >/dev/null; then
        python3 scripts/check-parity.py
    else
        echo "skipped: tag rust-final missing (git fetch origin tag rust-final)"
    fi
    step "release notes"
    node --test scripts/release-notes.test.mjs
    node -e 'JSON.parse(require("fs").readFileSync("source/release-notes.json", "utf8"))'
    # Needs the release tags (CI fetches full history); a tagless clone skips it.
    if git rev-parse -q --verify "refs/tags/v$(sed -nE 's/^enum string packageVersion = "([^"]+)";/\1/p' source/app.d)" >/dev/null; then
        node scripts/release-notes.mjs --check
    else
        echo "skipped: the current version's tag is missing (git fetch --tags)"
    fi
    step "docs links"
    python3 scripts/check-docs.py
    step "ratchet tests"
    ./scripts/test-ratchets.sh
    step "dscanner"
    dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source
}

# Unit tests run modules in parallel (scripts/serial-tests lists the ones that
# run alone) and fail a module over its time limit (scripts/slow-tests); CI
# machines get 3x the limits. The 10 slowest modules are listed. NANO_TEST_ONLY
# is cleared so an exported filter cannot make CI pass on a subset.
unit() {
    step "dub test"
    NANO_TEST_ONLY= NANO_TEST_JOBS=${NANO_TEST_JOBS:-4} NANO_TEST_TIMES=${NANO_TEST_TIMES:-10} \
        NANO_TEST_BUDGET_SCALE=${NANO_TEST_BUDGET_SCALE:-${CI:+3}} dub test -q
    step "test watchdog names a hung module"
    # NANO_TEST_STUCK=1 adds a module that never returns; the watchdog must
    # name it and fail the run within its hard limit (seconds, not hours).
    # perl's alarm survives exec: a parent-side deadline (SIGALRM kills the
    # runner) so a broken watchdog fails this check instead of hanging CI.
    status=0
    out=$(NANO_TEST_ONLY= NANO_TEST_STUCK=1 NANO_TEST_JOBS=4 NANO_TEST_BUDGET_SCALE=0.3 \
        perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 300 ./nano-coder-test-application 2>&1) || status=$?
    if [ "$status" -eq 0 ]; then
        echo "the stuck test module passed"; exit 1
    fi
    if [ "$status" -eq 142 ]; then
        echo "the watchdog did not end the run within 300s:"; printf '%s\n' "$out" | tail -20; exit 1
    fi
    printf '%s\n' "$out" | grep -q "1 module FAILED unittests: nano.testenv_test (hung past" \
        || { echo "the watchdog did not name the stuck module:"; printf '%s\n' "$out" | tail -20; exit 1; }
}

# The modules that read the user's home, config and repositories, run the way
# a Nano Workforce worker runs them (issue #374): a populated HOME (user
# instructions, skills, Claude settings, nano-coder config, trusted projects)
# and a TMPDIR inside a git checkout's .git. They must pass regardless.
hostile_home() {
    step "unit tests with a populated HOME and TMPDIR inside a git checkout"
    # Not under a temp root nor this checkout's .git: the workspace sandbox
    # always grants both, so a fake HOME there would be writable. Under the
    # real HOME, not XDG_CACHE_HOME: that may point at a temp root.
    work=$HOME/.cache/nano-coder-hostile.$$
    mkdir -p "$(dirname "$work")"
    rm -rf "$work"
    fake=$work/home
    mkdir -p "$fake/.agents/skills/intruder" "$fake/.claude/skills/intruder2" "$fake/.claude/rules" \
        "$fake/.config/nano-coder" "$work/checkout/.git/tmp"
    printf 'INTRUDER user instructions\n' > "$fake/.agents/AGENTS.md"
    printf 'INTRUDER claude instructions\n' > "$fake/.claude/CLAUDE.md"
    printf 'INTRUDER rule\n' > "$fake/.claude/rules/r.md"
    printf -- '---\nname: intruder\ndescription: Intrudes.\n---\nx\n' > "$fake/.agents/skills/intruder/SKILL.md"
    printf -- '---\nname: intruder2\ndescription: Intrudes.\n---\nx\n' > "$fake/.claude/skills/intruder2/SKILL.md"
    printf '{"permissions":{"deny":["Bash(*)"]},"hooks":{}}\n' > "$fake/.claude/settings.json"
    printf 'bash_timeout_secs = 1\n[permissions]\ndeny = ["bash"]\n' > "$fake/.config/nano-coder/config.toml"
    printf '/\n%s\n' "$work" > "$fake/.config/nano-coder/trusted-projects"
    printf 'INTRUDER checkout instructions\n' > "$work/checkout/AGENTS.md"
    status=0
    HOME=$fake XDG_CONFIG_HOME=$fake/.config TMPDIR=$work/checkout/.git/tmp NANO_TEST_JOBS=4 \
        NANO_TEST_BUDGET_SCALE=${NANO_TEST_BUDGET_SCALE:-${CI:+3}} \
        NANO_TEST_ONLY=nano.instructions,nano.permissions_test,nano.skills,nano.system_prompt,nano.tools.search,nano.trust,nano.agent_bound_test,nano.gitroot \
        ./nano-coder-test-application || status=$?
    rm -rf "$work"
    [ "$status" -eq 0 ] || exit "$status"
}

test_() {
    unit
    hostile_home
    typecheck
    # The other OS too, so a macOS-only or Linux-only symbol fails on either.
    case "$(uname -s)" in
        Darwin) typecheck -mtriple=x86_64-linux-gnu ;;
    esac
    step "release build"
    dub build -q -b release
    ./nano-coder --version
    step "docs reference drift"
    # docs/{cli,commands,tools,configuration}.md hold blocks generated from
    # `nano-coder --dump-reference` (issue #397): a flag, command, tool or
    # config key added without regenerating them fails here.
    ./scripts/gen-reference.sh ./nano-coder
    if ! git diff --exit-code --stat -- docs/; then
        git diff -- docs/ | head -60
        echo "docs/ is out of date with the code: a flag, slash command, tool or config key changed."
        echo "Run scripts/gen-reference.sh (after dub build -b release) and commit docs/."
        exit 1
    fi
    step "compaction eval self-test (fake model)"
    out=$(mktemp -d)
    python3 eval/compaction/run.py --self-test --seeds 1 --filler-turns 4 --modes standard,smart,extract --bin ./nano-coder --out "$out"
    rm -rf "$out"
    step "npm launcher syntax"
    for f in npm/nano-coder/bin/nano-coder npm/nano-coder/lib/platform.js scripts/npm-packages.mjs \
        scripts/set-version.mjs scripts/homebrew-formula.mjs scripts/release-notes.mjs; do
        node --check "$f"
    done
}

quick() {
    step "check-safe"
    ./scripts/check-safe.sh
    typecheck
    unit
    hostile_home
}

case "${1:-all}" in
    lint) lint ;;
    test) test_ ;;
    quick) quick ;;
    all) lint; test_ ;;
    *) echo "usage: scripts/ci.sh [all|lint|test|quick]" >&2; exit 2 ;;
esac
step "ok"
