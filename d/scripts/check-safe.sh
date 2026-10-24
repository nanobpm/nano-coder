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
ratchet() { # name count budget-file
    budget=$(cat "$3")
    if [ "$2" -gt "$budget" ]; then
        echo "Error: $2 \`@trusted\` $1, budget is $budget ($3); make the code @safe, or justify the escape and raise the budget" >&2
        status=1
    elif [ "$2" -lt "$budget" ]; then
        echo "check-safe: $2 \`@trusted\` $1, below the budget of $budget; lower $3 to $2" >&2
    fi
}
ratchet "outside safeio.d" "$(trusted -r source --include='*.d' | grep -c -v '^source/nano/safeio.d:')" scripts/trusted-budget
ratchet "in safeio.d" "$(trusted source/nano/safeio.d | wc -l | tr -d ' ')" scripts/trusted-budget-safeio
# Every `@trusted` needs a comment right above its declaration saying why it
# is memory safe (blank lines and the earlier lines of a wrapped signature
# may come between). The compiler can't check a `@trusted` body; a reviewer
# checks it against that comment.
if ! find source -name '*.d' | sort | xargs awk '
    FNR == 1 { ok = 0 }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*\/\// { ok = 1; next }
    /(^|[^\/`[:alnum:]])@trusted([^[:alnum:]_]|$)/ {
        if (!ok) { printf "%s(%d): Error: `@trusted` without a comment above it saying why it is safe\n", FILENAME, FNR > "/dev/stderr"; bad = 1 }
        if ($0 ~ /[;{}][[:space:]]*$/) ok = 0
        next
    }
    /[;{}][[:space:]]*$/ { ok = 0 }
    END { exit bad }'; then
    status=1
fi
exit $status
