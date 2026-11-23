#!/bin/sh
# The checks CI runs, in one place: .github/workflows/ci.yml calls this, and
# .githooks/pre-push runs `quick` before every push, so a push has passed the
# same checks CI will run. Add a check here, not in the workflow.
#
#   scripts/ci.sh [all|lint|test|quick]   (default: all)
#
#   lint   check-safe, parity manifest, ratchet tests, dscanner                    (CI job `lint`)
#   test   unit tests, release build and smoke checks  (CI jobs `test (<os>)`)
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
        ldc2 -o- -w -allinst -preview=dip1000 -preview=nosharedaccess -Isource -Jsource ${1:-} $build $files
    done
}

lint() {
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
    step "ratchet tests"
    ./scripts/test-ratchets.sh
    step "dscanner"
    dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source
}

# Unit tests run modules in parallel (scripts/serial-tests lists the ones that
# run alone) and fail a module over its time limit (scripts/slow-tests); CI
# machines get 3x the limits. The 10 slowest modules are listed.
unit() {
    step "dub test"
    NANO_TEST_JOBS=${NANO_TEST_JOBS:-4} NANO_TEST_TIMES=${NANO_TEST_TIMES:-10} \
        NANO_TEST_BUDGET_SCALE=${NANO_TEST_BUDGET_SCALE:-${CI:+3}} dub test -q
}

test_() {
    unit
    typecheck
    # The other OS too, so a macOS-only or Linux-only symbol fails on either.
    case "$(uname -s)" in
        Darwin) typecheck -mtriple=x86_64-linux-gnu ;;
    esac
    step "release build"
    dub build -q -b release
    ./nano-coder --version
    step "compaction eval self-test (fake model)"
    out=$(mktemp -d)
    python3 eval/compaction/run.py --self-test --seeds 1 --filler-turns 4 --bin ./nano-coder --out "$out"
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
}

case "${1:-all}" in
    lint) lint ;;
    test) test_ ;;
    quick) quick ;;
    all) lint; test_ ;;
    *) echo "usage: scripts/ci.sh [all|lint|test|quick]" >&2; exit 2 ;;
esac
step "ok"
