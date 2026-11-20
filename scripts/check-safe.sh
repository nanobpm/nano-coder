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
# Absence: a value that may be missing is an `Option!T` (nano.option), whose
# value can't be reached without handling `none`. A class reference that may
# be null says nothing, so null checks on class-typed names are capped by
# scripts/class-null-budget (scripts/class-null.awk lists them); new code
# uses Option, or an object that is always there (an empty Skills, say).
# `Nullable!` doesn't force handling either (its `.get` on empty returns
# T.init in release builds), so its uses only go down
# (scripts/nullable-budget). Class declarations other than exceptions are
# capped by scripts/class-budget (`static class`, used only for helpers
# inside unittests, isn't counted), so a new reference type is a visible
# decision: prefer a struct, an enum or a SumType for a value.
nfiles=$(find source -name '*.d' | wc -l | tr -d ' ')
files=$(find source -name '*.d' | sort)
# shellcheck disable=SC2086 # the list is passed three times, one per pass
classnull=$(awk -v n="$nfiles" -f scripts/class-null.awk $files $files $files)
if [ "$(printf '%s' "$classnull" | grep -c .)" -gt "$(cat scripts/class-null-budget)" ]; then
    printf '%s\n' "$classnull" >&2
    echo "Use nano.option.Option!T for a reference that may be absent (see its module comment)." >&2
fi
ratchet "outside *_test.d" "$(printf '%s' "$classnull" | grep -c .)" scripts/class-null-budget "null checks on class references"
ratchet "outside *_test.d" "$(find source -name '*.d' ! -name '*_test.d' | xargs grep -hE 'Nullable!' | grep -vE '^[[:space:]]*//' | grep -oE 'Nullable!' | wc -l | tr -d ' ')" scripts/nullable-budget "\`Nullable!\` uses (use nano.option.Option!T)"
ratchet "outside *_test.d" "$(find source -name '*.d' ! -name '*_test.d' | xargs grep -hE '^[[:space:]]*((final|abstract|private|public)[[:space:]]+)*class[[:space:]]+[A-Z]' | grep -vcE 'class[[:space:]]+[A-Za-z0-9_]*(Error|Exception)\b|:[[:space:]]*Exception')" scripts/class-budget "class declarations (exceptions aside)"
# Fields and globals: source/nano/nullaudit.d checks at compile time that
# no field or module-level variable holds a bare class reference; each is
# `NotNull!C`, `Option!C`, or marked `@nullable("why")`. The marks are
# capped by scripts/nullable-mark-budget, and null_audit_test.d must list
# every module (app.d checks itself; entry.d is only `main`).
missing=$(find source -name '*.d' ! -name '*_test.d' ! -path source/app.d ! -path source/entry.d | sort | xargs sed -n 's/^module \([a-z_.]*\);.*/\1/p' | while read -r m; do
    grep -q "^static import $m;" source/nano/null_audit_test.d || echo "$m"
done)
if [ -n "$missing" ]; then
    echo "Error: add to source/nano/null_audit_test.d (static import and the modules list): $missing" >&2
    status=1
fi
ratchet "outside *_test.d" "$(find source -name '*.d' ! -name '*_test.d' | xargs grep -hE '^[[:space:]]*@nullable\(' | wc -l | tr -d ' ')" scripts/nullable-mark-budget "\`@nullable\` marks"
# Purity. Functions marked `pure` (outside tests) and pure-core modules (ones
# starting with `pure:`) may only grow in number: removing `pure` makes a
# function depend on hidden state, a reviewed choice (lower the floor). Each
# `pure:` module is listed in pure_core_test.d, whose compile-time audit
# (nano.pureaudit) also checks the member functions the label doesn't reach.
floor() { # name count floor-file what
    want=$(cat "$3")
    if [ "$2" -lt "$want" ]; then
        echo "Error: $2 $4 $1, the floor is $want ($3); keep functions pure (move I/O to the caller), or justify and lower it" >&2
        status=1
    elif [ "$2" -gt "$want" ]; then
        echo "check-safe: $2 $4 $1, above the floor of $want; raise $3 to $2" >&2
    fi
}
floor "outside *_test.d" "$(find source -name '*.d' ! -name '*_test.d' | xargs grep -hE '\bpure\b' | grep -vE '^[[:space:]]*(//|\*|/\+)' | grep -vE '^pure:$' | grep -oE '\bpure\b' | wc -l | tr -d ' ')" scripts/pure-floor "\`pure\` attributes"
pure_mods=$(grep -lE '^pure:$' $(find source -name '*.d' ! -name '*_test.d') | sort | xargs sed -n 's/^module \([a-z_.]*\);.*/\1/p' | grep -v '^nano\.pureaudit$')
floor "in source" "$(printf '%s\n' "$pure_mods" | grep -c .)" scripts/pure-module-floor "pure-core modules (\`pure:\`)"
for m in $pure_mods; do
    grep -q "^    $m,$" source/nano/pure_core_test.d || { echo "Error: $m starts with \`pure:\`; add it to pureCore in source/nano/pure_core_test.d" >&2; status=1; }
done
# Errors as values: a pure-core module returns a Result (nano.result) rather
# than throwing. What throws there is a parser unwinding to its own entry
# point, which turns it into the error result, so its exception class must be
# private; the throws themselves are capped by scripts/pure-throw-budget.
pure_files=$(grep -lE '^pure:$' $(find source -name '*.d' ! -name '*_test.d') | grep -v 'pureaudit.d$')
if grep -nE '^[[:space:]]*((public|final|abstract|static)[[:space:]]+)*class[[:space:]]+[A-Za-z_]+[[:space:]]*:[[:space:]]*(Exception|Error)\b' $pure_files; then
    echo "Error: an exception class in a pure-core module must be private; return a Result (nano.result) instead of throwing" >&2
    status=1
fi
ratchet "in pure-core modules" "$(cat $pure_files | grep -vE '^[[:space:]]*//' | grep -cE '\bthrow\b')" scripts/pure-throw-budget "\`throw\`s (return a Result instead)"
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
exit $status
