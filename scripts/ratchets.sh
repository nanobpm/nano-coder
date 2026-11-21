#!/bin/sh
# The ratchets: counts that may only move one way. Prints one line per
# ratchet for the source tree in the directory given (default .):
#
#   <name> <max|min> <count> <what>
#
# `max` counts (budgets) may not go up, `min` counts (floors) may not go
# down. scripts/check-safe.sh runs this on the working tree and, with the
# same script, on the merge base with the target branch (in a temporary
# worktree), and fails when the working tree is worse. There are no committed
# numbers: improving a count needs no edit under scripts/, and two PRs that
# both improve one can't conflict. Loosening one is a `Ratchet-Override:
# <name> <reason>` trailer on a commit in the PR.
#
# The helper scripts (*.awk) are read from this script's directory, so both
# trees are measured by identical code.
S=$(cd "$(dirname "$0")" && pwd)
cd "${1:-.}" || exit 2
out() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4"; }
num() { wc -l | tr -d ' '; }
nontest() { find source -name '*.d' ! -name '*_test.d' | sort; }
code() { grep -rnE "$1" source --include='*.d' | grep -v '^source/nano/safeio.d:' | grep -vE ':[0-9]+:[[:space:]]*(///|//)'; }
trusted() { grep -nE '(^|[^/`[:alnum:]])@trusted\b' "$@" | grep -vE ':[[:space:]]*(///|//)'; }

out trusted-budget max "$(trusted -r source --include='*.d' | grep -v '^source/nano/safeio.d:' | num)" '`@trusted` outside safeio.d'
out trusted-budget-safeio max "$(trusted source/nano/safeio.d | num)" '`@trusted` in safeio.d'
out isolation-budget max "$(code '\bassumeIsolated\(' | num)" '`assumeIsolated` calls outside safeio.d'
subs=$(awk '
    /^[[:space:]]*(\/\/|\*)/ { next }
    {
        s = $0
        gsub(/\\./, "", s); gsub(/"[^"]*"/, "\"\"", s); gsub(/`[^`]*`/, "``", s); sub(/\/\/.*/, "", s)
        gsub(/\$[[:space:]]*-/, "", s)
        n += gsub(/[[:alnum:]_)\]][[:space:]]+-[[:space:]]+[[:alnum:]_(]/, "", s)
    }
    END { print n + 0 }' source/nano/context.d source/nano/agent.d)
out subtraction-budget max "$subs" 'raw subtractions in context.d and agent.d'
out catch-budget max "$(nontest | xargs grep -hE 'catch[[:space:]]*\([[:space:]]*Exception\b' | grep -vE '^[[:space:]]*//' | num)" '`catch (Exception)` outside *_test.d'
nfiles=$(find source -name '*.d' | num)
files=$(find source -name '*.d' | sort)
# shellcheck disable=SC2086 # the list is passed three times, one per pass
out class-null-budget max "$(awk -v n="$nfiles" -f "$S/class-null.awk" $files $files $files | grep -c .)" 'null checks on class references outside *_test.d (use nano.option.Option!T)'
out nullable-budget max "$(nontest | xargs grep -hE 'Nullable!' | grep -vE '^[[:space:]]*//' | grep -oE 'Nullable!' | num)" '`Nullable!` uses outside *_test.d (use nano.option.Option!T)'
out class-budget max "$(nontest | xargs grep -hE '^[[:space:]]*((final|abstract|private|public)[[:space:]]+)*class[[:space:]]+[A-Z]' | grep -vE 'class[[:space:]]+[A-Za-z0-9_]*(Error|Exception)\b|:[[:space:]]*Exception' | num)" 'class declarations (exceptions aside) outside *_test.d'
out nullable-mark-budget max "$(nontest | xargs grep -hE '^[[:space:]]*@nullable\(' | num)" '`@nullable` marks outside *_test.d'
out cast-budget max "$(find source -name '*.d' ! -name '*_test.d' ! -name safeio.d | sort | xargs awk -f "$S/cast.awk" | num)" '`cast(`s outside unittests, *_test.d and safeio.d'
out pure-floor min "$(nontest | xargs grep -hE '\bpure\b' | grep -vE '^[[:space:]]*(//|\*|/\+)' | grep -vE '^pure:$' | grep -oE '\bpure\b' | num)" '`pure` attributes outside *_test.d'
# shellcheck disable=SC2046 # one file per word
pure_files=$(grep -lE '^pure:$' /dev/null $(nontest) | grep -v 'pureaudit.d$')
out pure-module-floor min "$(printf '%s\n' "$pure_files" | grep -c .)" 'pure-core modules (`pure:`)'
# shellcheck disable=SC2086 # one file per word
out pure-throw-budget max "$(cat /dev/null $pure_files | grep -vE '^[[:space:]]*//' | grep -cE '\bthrow\b')" '`throw`s in pure-core modules (return a Result instead)'
