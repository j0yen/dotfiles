#!/usr/bin/env bash
# tests/explorefirst_ac5_budget_assert_fail.test.sh — PRD-mcphost-explore-first-light
# AC5: given the budget assert reports the run would exceed the pinned
# budget, when the runner reaches the explore stage, then it fails loudly
# at that stage and no partial pack is exported.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup
export FAKE_SYNTHORG_OBS_MODE=fail

"$RUNNER" >/dev/null 2>&1
rc=$?

assert_eq "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero" "runner exits nonzero when the budget assert fails"
assert_contains "$(tail -1 "$prd_dir/vibeloop/exploration-ledger.md")" "stage=explore" "budget-assert failure is recorded as stage=explore (obs runs inside the explore stage)"
assert_contains "$(cat "$log_file")" "budget assert exceeded" "journal names the budget-assert failure"

# usecases/export-evidence never ran
n_mine="$(grep -c '^usecases ' "$synthorg_calls" 2>/dev/null)"; n_mine="${n_mine:-0}"
n_export="$(grep -c '^export-evidence ' "$synthorg_calls" 2>/dev/null)"; n_export="${n_export:-0}"
assert_eq "$n_mine" "0" "mining never runs after a failed budget assert"
assert_eq "$n_export" "0" "export never runs after a failed budget assert"
assert_eq "$(find "$prd_dir/evidence/mcp-host/exploration" -mindepth 1 -maxdepth 1 -type d -not -name '.weeks' 2>/dev/null | wc -l)" "0" "no partial pack exported"

exit "$fail"
