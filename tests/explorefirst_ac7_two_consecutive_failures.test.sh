#!/usr/bin/env bash
# tests/explorefirst_ac7_two_consecutive_failures.test.sh — PRD-mcphost-explore-first-light
# AC7: given two consecutive weekly failures in the ledger, when the second
# failure is recorded, then an agorabus event is published naming both
# weeks.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=explorefirst_test_helpers.sh
. "$here/explorefirst_test_helpers.sh"

explorefirst_setup
export FAKE_SYNTHORG_EXPLORE_MODE=fail

# Week 1 failure.
export EXPLOREFIRST_NOW="2026-09-13T03:00:00Z"   # ISO week 2026-W37
"$RUNNER" >/dev/null 2>&1
assert_eq "$(wc -l < "$agorabus_calls")" "0" "one lone failure publishes nothing yet"

# Week 2 failure (consecutive).
export EXPLOREFIRST_NOW="2026-09-20T03:00:00Z"   # ISO week 2026-W38
"$RUNNER" >/dev/null 2>&1

assert_eq "$(wc -l < "$agorabus_calls")" "1" "the second consecutive failure publishes exactly one agorabus event"
bus_call="$(cat "$agorabus_calls")"
assert_contains "$bus_call" "mcphost.explore.consecutive-failures" "event published under the mcphost-explore consecutive-failures topic"
assert_contains "$bus_call" "2026-W37" "event names the first failed week"
assert_contains "$bus_call" "2026-W38" "event names the second failed week"

exit "$fail"
