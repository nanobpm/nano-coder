#!/usr/bin/env bash
# Model-check the harness specs with TLC. Usage: tla/check.sh [--deep]
# Needs Java and tla2tools.jar (TLA2TOOLS, default ~/bin/tla2tools.jar;
# download from https://github.com/tlaplus/tlaplus/releases).
set -euo pipefail
cd "$(dirname "$0")"
jar="${TLA2TOOLS:-$HOME/bin/tla2tools.jar}"
[[ -f "$jar" ]] || { echo "tla2tools.jar not found at $jar (set TLA2TOOLS)" >&2; exit 2; }
meta="$(mktemp -d)"
trap 'rm -rf "$meta"' EXIT

runs=("AgentLoop.cfg MCAgentLoop" "SessionRecovery.cfg SessionRecovery")
[[ "${1:-}" == "--deep" ]] && runs+=("SessionRecoveryDeep.cfg SessionRecovery")

status=0
for run in "${runs[@]}"; do
    read -r cfg module <<<"$run"
    echo "== $module ($cfg)"
    if ! java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -config "$cfg" \
        -metadir "$meta/$cfg" -cleanup "$module" >"$meta/$cfg.log" 2>&1; then
        status=1
    fi
    grep -E "^Error|violated|No error has been found|distinct states found" "$meta/$cfg.log" | head -5
    grep -q "No error has been found" "$meta/$cfg.log" || { status=1; cat "$meta/$cfg.log"; }
done
exit $status
