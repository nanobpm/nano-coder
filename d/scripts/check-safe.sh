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
# `@trusted` may only go down: the count outside safeio.d is capped by
# scripts/trusted-budget, and the count inside it by
# scripts/trusted-budget-safeio. Move a new escape into safeio.d (or make the
# code @safe), and raise that budget in the same change so review sees it;
# after removing some, lower the budget to the new count.
trusted() { grep -nE '(^|[^/`[:alnum:]])@trusted\b' "$@" | grep -vE ':[[:space:]]*(///|//)'; }
ratchet() { # name count budget-file [what]
    budget=$(cat "$3")
    what=${4:-\`@trusted\`}
    if [ "$2" -gt "$budget" ]; then
        echo "Error: $2 $what $1, budget is $budget ($3); make the code safe, or justify the escape and raise the budget" >&2
        status=1
    elif [ "$2" -lt "$budget" ]; then
        echo "check-safe: $2 $what $1, below the budget of $budget; lower $3 to $2" >&2
    fi
}
ratchet "outside safeio.d" "$(trusted -r source --include='*.d' | grep -c -v '^source/nano/safeio.d:')" scripts/trusted-budget
ratchet "in safeio.d" "$(trusted source/nano/safeio.d | wc -l | tr -d ' ')" scripts/trusted-budget-safeio
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
ratchet "outside safeio.d" "$(code '\bassumeIsolated\(' | wc -l | tr -d ' ')" scripts/isolation-budget "\`assumeIsolated\` calls"
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
# scripts/subtraction-budget; most are index steps guarded on the same line.
if code '([[:alnum:]_.]+) >=? ([[:alnum:]_.]+) \? \1 - \2 : 0' | grep -v '^source/nano/arith.d:' >&2; then
    echo "Error: use nano.arith.saturatingSub(a, b) instead of \`a > b ? a - b : 0\`" >&2
    status=1
fi
subs=$(awk '
    /^[[:space:]]*(\/\/|\*)/ { next }
    {
        s = $0
        gsub(/\\./, "", s); gsub(/"[^"]*"/, "\"\"", s); gsub(/`[^`]*`/, "``", s); sub(/\/\/.*/, "", s)
        gsub(/\$[[:space:]]*-/, "", s)
        n += gsub(/[[:alnum:]_)\]][[:space:]]+-[[:space:]]+[[:alnum:]_(]/, "", s)
    }
    END { print n + 0 }' source/nano/context.d source/nano/agent.d)
ratchet "in context.d and agent.d" "$subs" scripts/subtraction-budget "raw subtractions"
# Catches: a `catch (Exception)` that swallows (neither rethrows nor uses
# the exception) says why in a `//` comment, so "deliberately best effort"
# and "forgot to handle it" look different. `Throwable` and `Error` are
# never caught. The number of `catch (Exception)` outside the *_test.d
# modules is capped by scripts/catch-budget.
if find source -name '*.d' ! -name '*_test.d' | sort | xargs awk -f scripts/catch.awk | grep . >&2; then
    status=1
fi
ratchet "outside *_test.d" "$(find source -name '*.d' ! -name '*_test.d' | xargs grep -hE 'catch[[:space:]]*\([[:space:]]*Exception\b' | grep -vcE '^[[:space:]]*//')" scripts/catch-budget "\`catch (Exception)\`"
# Exhaustiveness: a `switch` over an enum is a `final switch`, so adding a
# member breaks the build wherever it isn't handled (Rust's `match`). Skipped
# members are listed in a `case`, not hidden behind `default:`.
if find source -name '*.d' | sort | xargs awk -f scripts/enum-switch.awk | grep . >&2; then
    status=1
fi
exit $status
