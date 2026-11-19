#!/bin/sh
# The checks CI runs, in one place: .github/workflows/ci.yml calls this, and
# .githooks/pre-push runs `quick` before every push, so a push has passed the
# same checks CI will run. Add a check here, not in the workflow.
#
#   scripts/ci.sh [all|lint|test|quick]   (default: all)
#
#   lint   check-safe and dscanner                     (CI job `lint`)
#   test   unit tests, release build and smoke checks  (CI jobs `test (<os>)`)
#   quick  check-safe, both builds typechecked, unit tests (pre-push)
#   all    lint + test
set -eu
cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$*"; }

# Typecheck the release and the unittest build: names that only one of them
# sees (e.g. test-only imports) fail here instead of in CI. `$1` adds flags,
# e.g. a cross target.
typecheck() {
    files=$(find source -name '*.d' | sort)
    for build in "" "-unittest"; do
        step "typecheck ${build:-release} ${1:-}"
        # shellcheck disable=SC2086 # word splitting is intended
        ldc2 -o- -w -allinst -preview=dip1000 -preview=nosharedaccess -Isource ${1:-} $build $files
    done
}

lint() {
    step "check-safe"
    ./scripts/check-safe.sh
    step "dscanner"
    dub run -q dscanner@0.16.0-beta.5 -- --styleCheck --config dscanner.ini source
}

unit() {
    step "dub test"
    dub test -q
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
        scripts/set-version.mjs scripts/homebrew-formula.mjs; do
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
