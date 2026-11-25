#!/bin/sh
# Every D module is @safe: it must carry a module-level `@safe:`, and may not
# switch the rest of a module off with `@system:` or `@trusted:`. Escapes go
# in small `@trusted` lambdas or functions. Runs before each `dub build` and
# `dub test` (dub.json preBuildCommands), so a violation fails the build.
cd "$(dirname "$0")/.." || exit 2
status=0
for f in $(grep -rL '^@safe:' source --include='*.d'); do
    echo "$f(1): Error: module is missing a module-level \`@safe:\` (see scripts/check-safe.sh)" >&2
    status=1
done
if grep -rnE '^[[:space:]]*@(system|trusted)[[:space:]]*:' source --include='*.d' >&2; then
    echo "Error: \`@system:\`/\`@trusted:\` turn off @safe for the rest of a scope; mark the smallest function or lambda instead" >&2
    status=1
fi
# `@system` code is only allowed at the C boundary (`extern (C)` prototypes
# and the signal handler); everything else is @safe or a small @trusted.
if grep -rnE '(^|[^/`[:alnum:]])@system\b' source --include='*.d' | grep -vE ':[[:space:]]*(///|//)' | grep -v 'extern (C)' >&2; then
    echo "Error: \`@system\` is only allowed on \`extern (C)\` declarations; use @safe, or @trusted on the smallest function or lambda" >&2
    status=1
fi
# `@trusted` may only go down: the count outside safeio.d (ratchet
# trusted-budget) and inside it (trusted-budget-safeio). Move a new escape
# into safeio.d, or make the code @safe. All ratchets are measured by
# scripts/ratchets.sh and compared against the merge base at the end.
# The "E profile": threads start through safeio's `spawn`/`spawnDaemon`,
# which take a context-free function and sendable arguments, so whatever two
# threads share shows in the types. Outside safeio.d there are no raw
# threads, no `__gshared` and no unions. The one escape hatch,
# `Isolated.assumeIsolated` (an unchecked "nothing else refers to this"), is
# capped like `@trusted`.
code() { grep -rnE "$1" source --include='*.d' | grep -v '^source/nano/safeio.d:' | grep -vE ':[0-9]+:[[:space:]]*(///|//)'; }
if code '\bnew Thread\b|\bisDaemon\b|\bstd\.concurrency\b' >&2; then
    echo "Error: start threads with nano.safeio.spawn/spawnDaemon (sendable arguments only)" >&2
    status=1
fi
if code '\b__gshared\b|(^|[^[:alnum:]_])union\b' >&2; then
    echo "Error: \`__gshared\` and unions are only allowed in safeio.d; use \`shared\` with Locked/atomics, or std.sumtype" >&2
    status=1
fi
# Time: only nano/clock.d reads the clock or sleeps. Everything else calls
# wallNow/stdTimeNow/monoNow/since/sleepFor, so a test can run any
# time-dependent path under a FakeClock (instant sleeps, chosen "now").
if code '\bClock\.curr(Std)?Time\b|\bMonoTime\.currTime\b|\bThread\.sleep\b|\bStopWatch\b' | grep -v '^source/nano/clock.d:' >&2; then
    echo "Error: read the clock and sleep through nano.clock (wallNow, monoNow, since, sleepFor) so tests can fake time" >&2
    status=1
fi
# The C locale stays "C": safeio.cStrtod is pure on that promise.
if grep -rnE '\bsetlocale\b' source | grep -vE ':[0-9]+:[[:space:]]*//' >&2; then
    echo "Error: don't call setlocale; cStrtod (toml, trajectory) is pure only while the C locale is \"C\"" >&2
    status=1
fi
# Every `@trusted` needs a comment right above its declaration saying why it
# is memory safe (blank lines and the earlier lines of a wrapped signature
# may come between). The compiler can't check a `@trusted` body; a reviewer
# checks it against that comment. The same goes for `assumeIsolated` (why
# nothing else refers to the value).
if ! find source -name '*.d' | sort | xargs awk '
    FNR == 1 { ok = 0 }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*\/\// { ok = 1; next }
    /(^|[^\/`[:alnum:]])@trusted([^[:alnum:]_]|$)|[.]assumeIsolated\(/ {
        if (!ok && FILENAME !~ /safeio[.]d$/ || !ok && $0 ~ /@trusted/) { printf "%s(%d): Error: `@trusted` or `assumeIsolated` without a comment above it saying why it is safe\n", FILENAME, FNR > "/dev/stderr"; bad = 1 }
        if ($0 ~ /[;{}][[:space:]]*$/) ok = 0
        next
    }
    /[;{}][[:space:]]*$/ { ok = 0 }
    END { exit bad }'; then
    status=1
fi
# Size arithmetic: `size_t` wraps on underflow, so "what's left" is
# `saturatingSub` from nano.arith, not a hand-written `a > b ? a - b : 0`
# (easy to get subtly wrong), and arithmetic that must not wrap is
# `checkedSub`/`checkedAdd`/`checkedMul`. In the token-budget modules
# (context.d, agent.d) the raw subtractions left are capped by
# ratchet subtraction-budget; most are index steps guarded on the same line.
if code '([[:alnum:]_.]+) >=? ([[:alnum:]_.]+) \? \1 - \2 : 0' | grep -v '^source/nano/arith.d:' >&2; then
    echo "Error: use nano.arith.saturatingSub(a, b) instead of \`a > b ? a - b : 0\`" >&2
    status=1
fi
# Catches: a `catch (Exception)` that swallows (neither rethrows nor uses
# the exception) says why in a `//` comment, so "deliberately best effort"
# and "forgot to handle it" look different. `Throwable` and `Error` are
# never caught. The number of `catch (Exception)` outside the *_test.d
# modules is capped by ratchet catch-budget.
if find source -name '*.d' ! -name '*_test.d' | sort | xargs awk -f scripts/catch.awk | grep . >&2; then
    status=1
fi
# Exhaustiveness: a `switch` over an enum is a `final switch`, so adding a
# member breaks the build wherever it isn't handled (Rust's `match`). Skipped
# members are listed in a `case`, not hidden behind `default:`.
if find source -name '*.d' | sort | xargs awk -f scripts/enum-switch.awk | grep . >&2; then
    status=1
fi
# Absence: a value that may be missing is an `Option!T` (nano.option), whose
# value can't be reached without handling `none`. A class reference that may
# be null says nothing, so null checks on class-typed names are capped by
# ratchet class-null-budget (scripts/class-null.awk lists them); new code
# uses Option, or an object that is always there (an empty Skills, say).
# `Nullable!` doesn't force handling either (its `.get` on empty returns
# T.init in release builds), so its uses only go down
# (ratchet nullable-budget). Class declarations other than exceptions are
# capped by ratchet class-budget (`static class`, used only for helpers
# inside unittests, isn't counted), so a new reference type is a visible
# decision: prefer a struct, an enum or a SumType for a value.
# Fields and globals: source/nano/nullaudit.d checks at compile time that
# no field or module-level variable holds a bare class reference; each is
# `NotNull!C`, `Option!C`, or marked `@nullable("why")`. The marks are
# capped by ratchet nullable-mark-budget, and null_audit_test.d must list
# every module (app.d checks itself; entry.d is only `main`).
missing=$(find source -name '*.d' ! -name '*_test.d' ! -path source/app.d ! -path source/entry.d | sort | xargs sed -n 's/^module \([a-z_.]*\);.*/\1/p' | while read -r m; do
    grep -q "^static import $m;" source/nano/null_audit_test.d || echo "$m"
done)
if [ -n "$missing" ]; then
    echo "Error: add to source/nano/null_audit_test.d (static import and the modules list): $missing" >&2
    status=1
fi
# `cast(` outside unittest blocks, *_test.d and safeio.d (scripts/cast.awk).
# Text to bytes is `representation`; bytes to text goes through safeio's
# utf8Text/utf8View/lossyText; JSON numbers through nano.arith's toSize or
# std.conv's `to`. What's left are class downcasts and arith's own checks.
# Purity. Functions marked `pure` (outside tests) and pure-core modules (ones
# starting with `pure:`) may only grow in number: removing `pure` makes a
# function depend on hidden state, a reviewed choice (a Ratchet-Override). Each
# `pure:` module is listed in pure_core_test.d, whose compile-time audit
# (nano.pureaudit) also checks the member functions the label doesn't reach.
pure_mods=$(grep -lE '^pure:$' $(find source -name '*.d' ! -name '*_test.d') | sort | xargs sed -n 's/^module \([a-z_.]*\);.*/\1/p' | grep -v '^nano\.pureaudit$')
for m in $pure_mods; do
    grep -q "^    $m,$" source/nano/pure_core_test.d || { echo "Error: $m starts with \`pure:\`; add it to pureCore in source/nano/pure_core_test.d" >&2; status=1; }
done
# Errors as values: a pure-core module returns a Result (nano.result) rather
# than throwing. What throws there is a parser unwinding to its own entry
# point, which turns it into the error result, so its exception class must be
# private; the throws themselves are capped by ratchet pure-throw-budget.
pure_files=$(grep -lE '^pure:$' $(find source -name '*.d' ! -name '*_test.d') | grep -v 'pureaudit.d$')
if grep -nE '^[[:space:]]*((public|final|abstract|static)[[:space:]]+)*class[[:space:]]+[A-Za-z_]+[[:space:]]*:[[:space:]]*(Exception|Error)\b' $pure_files; then
    echo "Error: an exception class in a pure-core module must be private; return a Result (nano.result) instead of throwing" >&2
    status=1
fi
for m in $(sed -n 's/^    \(nano\.[a-z_.]*\),$/\1/p' source/nano/pure_core_test.d); do
    printf '%s\n' "$pure_mods" | grep -qx "$m" || { echo "Error: $m is in pure_core_test.d but doesn't start with \`pure:\`" >&2; status=1; }
done
# Test-only imports stay inside the tests. A file-level `version (unittest)`
# import is in scope for the whole module in the test build only, so non-test
# code can use it, pass `dub test` and fail the release build. Put the import
# inside the unittest block or test helper that uses it. Modules that are
# test-only from the top (`version (unittest):`) are exempt.
leaks=$(find source -name '*.d' | sort | while read -r f; do
    grep -qE '^version *\(unittest\) *:' "$f" && continue
    awk -v f="$f" '
        /^version *\(unittest\) *((private|public|static) +)*import[[:space:]]/ { print f "(" NR "): " $0; next }
        /^version *\(unittest\) *\{?[[:space:]]*$/ { pending = 1; if ($0 ~ /\{/) { inblock = 1; pending = 0 }; next }
        pending && /^\{/ { inblock = 1; pending = 0; next }
        { pending = 0 }
        inblock && /^\}/ { inblock = 0; next }
        inblock && /^    ((private|public|static) +)*import[[:space:]]/ { print f "(" NR "): " $0 }
    ' "$f"
done)
if [ -n "$leaks" ]; then
    echo "$leaks" >&2
    echo "Error: file-level \`version (unittest)\` imports leak into non-test code in the test build only; import inside the unittest block or test helper instead" >&2
    status=1
fi
# Ratchets (scripts/ratchets.sh): each count is compared against the merge
# base of HEAD with the target branch, measured by the same script in a
# temporary worktree. There are no committed numbers to keep in step, so
# improving a count needs no edit under scripts/ and parallel PRs can't
# conflict over one. A count that gets worse fails, unless a commit since the
# merge base carries a reviewed `Ratchet-Override: <name> <reason>` trailer.
#   NANO_RATCHET_BASE     the target branch or commit (default origin/main;
#                         CI sets the pre-push commit on pushes to main)
#   NANO_RATCHET_REQUIRE  1: fail when the base can't be found (CI lint sets
#                         it); otherwise the comparison is skipped with a note
# Base counts are cached in the git dir by merge-base commit and script hash.
for f in scripts/*-budget scripts/*-budget-* scripts/*-floor; do
    [ -e "$f" ] || continue
    echo "Error: $f: ratchets are measured against the merge base (scripts/ratchets.sh), not committed; delete the file" >&2
    status=1
done
# A measurement must succeed and give one numeric line per ratchet: a failed
# or truncated one would otherwise skip comparisons and let regressions in.
nratchets=$(grep -c '^out ' scripts/ratchets.sh)
# One validator for fresh and cached measurements: exactly $nratchets rows,
# unique names, a max/min direction and a numeric count on each.
valid_measurement() {
    printf '%s\n' "$1" | awk -v n="$nratchets" '
        NF < 4 || $3 !~ /^[0-9]+$/ || ($2 != "max" && $2 != "min") || seen[$1]++ { bad = 1 }
        END { exit (bad || NR != n) }'
}
measure() {
    m=$(./scripts/ratchets.sh "$1") || { echo "Error: scripts/ratchets.sh failed on $2" >&2; return 1; }
    if ! valid_measurement "$m"; then
        echo "Error: scripts/ratchets.sh gave an incomplete or malformed measurement of $2:" >&2
        printf '%s\n' "$m" >&2
        return 1
    fi
    printf '%s\n' "$m"
}
here=$(measure . "the working tree") || exit 1
# The commit messages of pull request $1, separated by blank lines:
# NANO_RATCHET_PR_MESSAGES_DIR/<n> when set (tests), else the GitHub API when
# GITHUB_REPOSITORY is set (CI, with GH_TOKEN); nothing otherwise.
pr_messages() {
    if [ -n "${NANO_RATCHET_PR_MESSAGES_DIR:-}" ]; then
        cat "$NANO_RATCHET_PR_MESSAGES_DIR/$1" 2>/dev/null
    elif [ -n "${GITHUB_REPOSITORY:-}" ] && command -v gh >/dev/null 2>&1; then
        gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$1/commits" --jq '.[].commit.message + "\n"' 2>/dev/null
    fi
}
base_ref=${NANO_RATCHET_BASE:-origin/main}
base=""
if git rev-parse --git-dir >/dev/null 2>&1; then
    base=$(git merge-base HEAD "$base_ref" 2>/dev/null)
fi
if [ -z "$base" ]; then
    if [ "${NANO_RATCHET_REQUIRE:-}" = 1 ]; then
        echo "Error: no merge base with $base_ref to compare the ratchets against (set NANO_RATCHET_BASE, or fetch it: CI needs fetch-depth: 0)" >&2
        status=1
    else
        echo "check-safe: no merge base with $base_ref; ratchets not compared (set NANO_RATCHET_BASE)" >&2
    fi
else
    key=$base-$(cat scripts/ratchets.sh scripts/*.awk | git hash-object --stdin)
    cache=$(git rev-parse --git-common-dir)/nano-ratchets
    measure_cached() {
        m=$(cat "$1") || return 1
        if ! valid_measurement "$m"; then
            echo "Error: corrupt ratchet cache $1; delete it" >&2
            return 1
        fi
        printf '%s\n' "$m"
    }
    if [ -s "$cache/$key" ]; then
        then_=$(measure_cached "$cache/$key") || exit 1
    else
        tree=$(mktemp -d "${TMPDIR:-/tmp}/nano-ratchet.XXXXXX")
        rmdir "$tree"
        # Remove the worktree however we leave, interrupts included.
        drop_tree() { git worktree remove --force "$tree" >/dev/null 2>&1; rm -rf "$tree"; git worktree prune >/dev/null 2>&1; }
        trap drop_tree EXIT
        trap 'drop_tree; trap - EXIT; exit 130' INT
        trap 'drop_tree; trap - EXIT; exit 143' TERM
        trap 'drop_tree; trap - EXIT; exit 129' HUP
        git worktree add -q --detach "$tree" "$base" >/dev/null 2>&1 || { echo "Error: git worktree add $base failed" >&2; exit 1; }
        then_=$(measure "$tree" "the merge base $base") || exit 1
        drop_tree
        trap - EXIT INT TERM HUP
        # Publish atomically: concurrent checks in other worktrees share it.
        mkdir -p "$cache" && part=$(mktemp "$cache/.$key.XXXXXX") &&
            printf '%s\n' "$then_" > "$part" && mv -f "$part" "$cache/$key"
    fi
    overrides=$(git log --format='%(trailers:key=Ratchet-Override,valueonly)' "$base..HEAD" 2>/dev/null | grep .)
    # A squash merge keeps only the PR title `… (#N)` and the sign-offs, so the
    # trailers of the PR's commits are lost on main. For each commit whose
    # subject ends in `(#N)`, read the trailers of PR N's commits too.
    pr_overrides=$(git log --format=%s "$base..HEAD" 2>/dev/null |
        sed -n 's/.*(#\([0-9][0-9]*\))[[:space:]]*$/\1/p' | sort -u | while read -r pr; do
            pr_messages "$pr" | sed -n 's/^Ratchet-Override:[[:space:]]*//p'
        done)
    overrides=$(printf '%s\n%s\n' "$overrides" "$pr_overrides" | grep .)
    short=$(git rev-parse --short "$base")
    bad=$(printf '%s\n' "$here" | while read -r name dir now what; do
        was=$(printf '%s\n' "$then_" | awk -v n="$name" '$1 == n { print $3 }')
        [ -n "$was" ] || { echo "Error: $name: no count at the merge base" >&2; echo "$name"; continue; }
        if [ "$dir" = max ]; then worse=$((now > was)); else worse=$((now < was)); fi
        [ "$worse" = 1 ] || continue
        why=$(printf '%s\n' "$overrides" | awk -v n="$name" '$1 == n { $1 = ""; sub(/^ +/, ""); print; exit }')
        if [ -n "$why" ]; then
            echo "check-safe: $name: $now $what, was $was at $short; allowed by Ratchet-Override: $why" >&2
        else
            echo "Error: $name: $now $what, was $was at the merge base $short; fix the code, or justify it with a \`Ratchet-Override: $name <reason>\` commit trailer" >&2
            echo "$name"
        fi
    done)
    [ -z "$bad" ] || status=1
    # The class-null detector lists what it found, to help fix a regression.
    case "$bad" in *class-null-budget*)
        files=$(find source -name '*.d' | sort)
        # shellcheck disable=SC2086 # the list is passed three times, one per pass
        awk -v n="$(printf '%s\n' "$files" | grep -c .)" -f scripts/class-null.awk $files $files $files >&2 ;;
    esac
fi
exit $status
