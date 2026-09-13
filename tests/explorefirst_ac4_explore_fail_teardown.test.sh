#!/usr/bin/env bash
# tests/explorefirst_ac4_explore_fail_teardown.test.sh — PRD-mcphost-explore-first-light
# AC4: given the explore stage fails partway, when the runner exits, then
# the exit is nonzero naming stage `explore`, the instance process is gone,
# the ephemeral data directory is gone, and the journal line exists.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup
export FAKE_SYNTHORG_EXPLORE_MODE=fail

"$RUNNER" >/dev/null 2>&1
rc=$?

assert_eq "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero" "runner exits nonzero when explore fails"
assert_contains "$(tail -1 "$prd_dir/vibeloop/exploration-ledger.md")" "stage=explore" "ledger fail line names stage=explore"
assert_contains "$(cat "$log_file")" "FAIL stage=explore" "journal line names the failing stage"

# instance process gone: the fake mcphost's `serve` pid should not survive
sleep 0.3
assert_eq "$(pgrep -f "$bin/mcphost serve" | wc -l)" "0" "no leaked fake-mcphost serve process after an explore-stage failure"

# ephemeral data dir gone: nothing under TMPDIR matching this run's pattern remains
leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mcphost-explore-data.*' -newer "$log_file" 2>/dev/null | wc -l)"
assert_eq "$leftover" "0" "ephemeral data directory removed on the explore-stage failure path"

# no pack was written for this attempt
assert_eq "$(find "$prd_dir/evidence/mcp-host/exploration" -mindepth 1 -maxdepth 1 -type d -not -name '.weeks' 2>/dev/null | wc -l)" "0" "no pack directory exists after an explore-stage failure"

exit "$fail"
