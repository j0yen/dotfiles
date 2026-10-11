#!/usr/bin/env bash
# PRD dotfiles-handoff-generated AC2: with no status.json and no state.db the
# generator exits 0 within 3 s and Runs/Queue/Config read `not on this host`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/hgen_test_helpers.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export HOME="$work/home"; mkdir -p "$HOME"
export OPERATOR_CACHE_DIR="$work/cache" WM_BUILD_STATE_DIR="$work/state" HANDOFF_MEMORY_DIR="$work/memory"
export HANDOFF_MCPHOST_URL="http://127.0.0.1:9" HANDOFF_SYNTHORG_REPO="$work/none"
t0=$(date +%s%N)
"$HGEN" --out "$work/t.md"; assert_eq "$?" "0" "generator exits 0"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
assert_eq "$([ "$ms" -lt 3000 ] && echo yes)" "yes" "completes within 3 s (${ms} ms)"
out="$(cat "$work/t.md")"
sec() { awk -v s="## $1 " 'index($0,s)==1{f=1;next} /^## /{f=0} f' "$work/t.md"; }
assert_contains "$(sec Runs)" "open: not on this host" "Runs open: not on this host"
assert_contains "$(sec Runs)" "ended 24h: not on this host" "Runs ended: not on this host"
assert_contains "$(sec Queue)" "not on this host" "Queue: not on this host"
assert_contains "$(sec Config)" "not on this host" "Config: not on this host"
assert_eq "$(grep -c '^## ' "$work/t.md")" "8" "all 8 sections still present"
exit $fail
