#!/usr/bin/env bash
# tests/explorefirst_ac9_status.test.sh — PRD-mcphost-explore-first-light
# AC9 (P1): given one completed run, when `status` is invoked, then it
# prints last run date, pack path, novelty result, and next fire, and
# exits 0.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup
"$RUNNER" >/dev/null

out="$("$RUNNER" status)"
rc=$?

assert_eq "$rc" "0" "status exits 0"
assert_contains "$out" "last_run=2026-09-13T03:00:00Z" "status prints the last run date"
assert_contains "$out" "pack=$prd_dir/evidence/mcp-host/exploration/20260913T030000Z" "status prints the pack path"
assert_contains "$out" "novelty=3/4" "status prints the novelty result"
assert_contains "$out" "gate_met=yes" "status prints the gate result"
assert_contains "$out" "next_fire=" "status prints the next scheduled fire"

exit "$fail"
