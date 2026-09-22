#!/usr/bin/env bash
# tests/liveness_ac05_stderr_tail.test.sh — PRD-grand-loop-liveness-contract
# AC5: mcphost-deploy probe exits 1 with two stderr lines -> the ledger row
# carries a stderr_tail= field with both lines escaped, and
# state/last-failure.txt holds them verbatim.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup

export FAKE_PROBE_MODE=fail
export FAKE_PROBE_STDERR=$'connection refused: hub:8443\nretrying gave up after 3 attempts'

run_tick >/dev/null

line="$(tail -n1 "$ledger" 2>/dev/null)"
assert_contains "$line" 'stderr_tail="connection refused: hub:8443\nretrying gave up after 3 attempts"' \
  "ledger row carries both stderr lines, escaped, in stderr_tail="

failure_file="$loop_dir/state/last-failure.txt"
[ -f "$failure_file" ] || { echo "NOT OK - state/last-failure.txt was not written"; fail=1; }
content="$(cat "$failure_file" 2>/dev/null)"
expected=$'connection refused: hub:8443\nretrying gave up after 3 attempts'
assert_eq "$content" "$expected" "state/last-failure.txt holds the stderr verbatim (real newlines)"

exit $fail
