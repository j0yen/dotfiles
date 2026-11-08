#!/usr/bin/env bash
# tests/liveness_ac06_demand_exit1.test.sh — PRD-grand-loop-liveness-contract
# AC6: a demand read that writes an alarm row exits 1, and the journal line
# begins `alarm:`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=fail
export GRAND_LOOP_DEMAND_TODAY=2026-09-16

run_demand run >/dev/null
rc=$?

assert_eq "$rc" "1" "a run that writes an alarm row exits 1"

line1="$(tail -n1 "$ledger" 2>/dev/null)"
assert_contains "$line1" "\"alarm\":true" "the ledger row is an alarm row"

journal="$(cat "$GRAND_LOOP_DEMAND_LOG")"
alarm_line="$(printf '%s\n' "$journal" | grep '^[0-9TZ:-]* alarm:' || true)"
[ -n "$alarm_line" ]; assert_eq "$?" "0" "the journal has a line beginning alarm: (after the timestamp prefix)"
assert_not_contains "$journal" " ok: demand row appended date=$GRAND_LOOP_DEMAND_TODAY" "the journal never says ok for this alarm run"

exit $fail
