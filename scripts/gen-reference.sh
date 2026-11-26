#!/bin/sh
# Render `nano-coder --dump-reference` into the generated blocks of docs/
# (issue #397): docs/cli.md, docs/commands.md, docs/tools.md and
# docs/configuration.md, between `<!-- BEGIN GENERATED: <name> -->` and
# `<!-- END GENERATED -->`. The prose around the blocks is hand-written.
#
#   scripts/gen-reference.sh [path/to/nano-coder]   (default: ./nano-coder)
#
# Run it after changing a flag, slash command, tool or config key; CI runs it
# and fails when docs/ changes (scripts/ci.sh, "docs reference drift").
set -eu
cd "$(dirname "$0")/.."
bin=${1:-./nano-coder}
[ -x "$bin" ] || { echo "gen-reference: no $bin; build it first (dub build -b release)" >&2; exit 1; }
"$bin" --dump-reference | python3 scripts/render-reference.py docs
