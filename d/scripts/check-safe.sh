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
# `@trusted` outside safeio.d may only go down: the count is capped by
# scripts/trusted-budget. Move a new escape into safeio.d (or make the code
# @safe); after removing some, lower the budget to the new count.
budget=$(cat scripts/trusted-budget)
count=$(grep -rnE '(^|[^/`[:alnum:]])@trusted\b' source --include='*.d' | grep -v '^source/nano/safeio.d:' | grep -cvE ':[[:space:]]*(///|//)')
if [ "$count" -gt "$budget" ]; then
    echo "Error: $count \`@trusted\` outside source/nano/safeio.d, budget is $budget (scripts/trusted-budget); put the escape in safeio.d or make the code @safe" >&2
    status=1
elif [ "$count" -lt "$budget" ]; then
    echo "check-safe: $count \`@trusted\` outside safeio.d, below the budget of $budget; lower scripts/trusted-budget to $count" >&2
fi
exit $status
