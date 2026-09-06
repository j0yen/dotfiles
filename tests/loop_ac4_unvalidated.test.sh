#!/usr/bin/env bash
# tests/loop_ac4_unvalidated.test.sh — PRD-grand-loop-scaffold AC4: a fake
# measure that exits 3 with "unvalidated: 2 labels, 5 required" ends the
# cycle in family=instrument, and the loop note says how many labels are
# missing; the tick still exits 0 (the loop keeps ticking).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup

export FAKE_PROBE_MODE=ok
export FAKE_MEASURE_MODE=unvalidated
export FAKE_UNVALIDATED_MSG="2 labels, 5 required"

rc=0
out="$(run_tick)" || rc=$?
assert_eq "$rc" "0" "unvalidated measure: tick still exits 0"

line="$(tail -n1 "$ledger" 2>/dev/null)"
assert_contains "$line" "family=instrument" "ledger line: family=instrument"
assert_contains "$line" "2 labels, 5 required" "ledger line: names the missing-label count"
assert_contains "$line" "reached_measure=1" "ledger line: reached_measure=1 (MEASURE did run)"

note="$(grep '(grand-loop):' "$profile" | tail -n1)"
assert_contains "$note" "family=instrument" "loop note: family=instrument"
assert_contains "$note" "2 labels, 5 required" "loop note: names the missing-label count"

exit $fail
