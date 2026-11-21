#!/bin/sh
# Red/green tests for the ratchets in scripts/check-safe.sh, run on a scratch
# clone of this repository (scripts/ci.sh lint runs them):
#   - a change that adds a `@trusted` site fails;
#   - one that removes a site passes without touching scripts/;
#   - one that adds a site with a `Ratchet-Override` trailer passes and prints it;
#   - a committed scripts/*-budget or *-floor file fails;
#   - two branches that both improve one ratchet merge without conflict.
set -eu
cd "$(dirname "$0")/.."
# shellcheck disable=SC2046 # one name per word
unset $(git rev-parse --local-env-vars)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/repo"
# A fresh repository holding the working tree's files (a clone of a partial
# clone may not be able to fetch its objects).
git ls-files -co --exclude-standard | while read -r f; do [ -e "$f" ] && echo "$f"; done | tar cf - -T - | tar xf - -C "$tmp/repo"
cd "$tmp/repo"
git init -q
git config user.email test@example.com
git config user.name test
git config commit.gpgsign false
rm -f scripts/*-budget scripts/*-budget-* scripts/*-floor
git add -A && git commit -q -m base
git branch -q -f base
export NANO_RATCHET_BASE=base NANO_RATCHET_REQUIRE=1
fails=0
ok() { printf 'ok   %s\n' "$1"; }
no() { printf 'FAIL %s\n' "$1"; cat out; fails=$((fails + 1)); }
check() { ./scripts/check-safe.sh > out 2>&1; }

# A file in source/ with one commented @trusted function.
add_trusted() {
    cat > source/nano/ratchet_fixture_test.d <<'D'
module nano.ratchet_fixture;
@safe:
// Memory safe: does nothing.
void ratchetFixture() @trusted {}
D
    git add source/nano/ratchet_fixture_test.d
}

git checkout -q -b add base
add_trusted
git commit -q -m 'add a @trusted site'
if check; then no "adding a @trusted site fails"; elif grep -q 'Error: trusted-budget: 17' out; then ok "adding a @trusted site fails"; else no "adding a @trusted site fails (message)"; fi

git commit -q --allow-empty -m 'justify it' -m 'Ratchet-Override: trusted-budget the fixture needs it'
if check && grep -q 'Ratchet-Override: the fixture needs it' out; then ok "a Ratchet-Override trailer allows it and is printed"; else no "a Ratchet-Override trailer allows it and is printed"; fi

# Remove one @trusted outside safeio.d: drop the attribute from its line.
remove_trusted() {
    f=$(grep -rlE '(^|[^/`[:alnum:]])@trusted\b' source --include='*.d' | grep -v safeio.d | head -n 1)
    line=$(grep -nE '(^|[^/`[:alnum:]])@trusted\b' "$f" | grep -vE ':[[:space:]]*//' | head -n 1 | cut -d: -f1)
    sed "${line}s/ *@trusted//" "$f" > "$f.new" && mv "$f.new" "$f"
    git add "$f"
}
git checkout -q -b remove base
remove_trusted
git commit -q -m 'remove a @trusted site'
if check && git diff --quiet base -- scripts; then ok "removing a site passes without editing scripts/"; else no "removing a site passes without editing scripts/"; fi

git checkout -q -b reintroduce base
echo 16 > scripts/trusted-budget
git add scripts/trusted-budget && git commit -q -m 'bring back a count file'
if check; then no "a committed count file fails"; elif grep -q 'scripts/trusted-budget: ratchets' out; then ok "a committed count file fails"; else no "a committed count file fails (message)"; fi

# Two parallel PRs that improve the same ratchet (pure-throw-budget and
# trusted-budget differently) both merge cleanly into base, one after the other.
git checkout -q -b pr1 base
remove_trusted
git commit -q -m 'pr1 improves trusted-budget'
git checkout -q -b pr2 base
f=$(grep -rlE '(^|[^/`[:alnum:]])@trusted\b' source --include='*.d' | grep -v safeio.d | tail -n 1)
line=$(grep -nE '(^|[^/`[:alnum:]])@trusted\b' "$f" | grep -vE ':[[:space:]]*//' | tail -n 1 | cut -d: -f1)
sed "${line}s/ *@trusted//" "$f" > "$f.new" && mv "$f.new" "$f"
git add "$f" && git commit -q -m 'pr2 improves trusted-budget'
git checkout -q -b main2 base
if git merge -q --no-edit pr1 && git merge -q --no-edit pr2 && check; then ok "two PRs improving one ratchet both merge cleanly"; else no "two PRs improving one ratchet both merge cleanly"; fi

[ "$fails" = 0 ] || { echo "$fails ratchet test(s) failed" >&2; exit 1; }
