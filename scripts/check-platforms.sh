#!/bin/sh
# Fails if the PR CI test matrix (.github/workflows/ci.yml, job `test`) does
# not cover every runner the Release workflow (.github/workflows/release.yml,
# job `build`) tests on: a platform-only failure must show up on the PR, not
# after merge on the release (#389).
set -eu
cd "$(dirname "$0")/.."
release=$(sed -n 's/^ *- { *os: *\([^,} ]*\).*/\1/p' .github/workflows/release.yml | sort -u)
ci=$(sed -n 's/^ *os: *\[\(.*\)\] *$/\1/p' .github/workflows/ci.yml | tr ',' '\n' | tr -d ' ' | sed '/^$/d' | sort -u)
[ -n "$release" ] || { echo "check-platforms: no os entries found in release.yml build matrix" >&2; exit 1; }
[ -n "$ci" ] || { echo "check-platforms: no os list found in ci.yml test matrix" >&2; exit 1; }
missing=$(printf '%s\n' "$release" | while read -r os; do
    printf '%s\n' "$ci" | grep -qx "$os" || echo "$os"
done)
if [ -n "$missing" ]; then
    echo "check-platforms: Release tests on platforms PR CI does not:" >&2
    printf '%s\n' "$missing" | sed 's/^/  /' >&2
    echo "add them to the test matrix in .github/workflows/ci.yml" >&2
    exit 1
fi
echo "check-platforms: CI covers every Release platform"
