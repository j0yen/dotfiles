#!/usr/bin/env bash
# tests/demandcadence_ac2_alarm_streak.test.sh — PRD-grand-loop-demand-cadence
# AC2: a measure that exits nonzero writes an alarm row + a journal alarm
# line; two consecutive such runs publish an agorabus event.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=fail

export GRAND_LOOP_DEMAND_TODAY=2026-09-13
run_demand run >/dev/null

line1="$(tail -n1 "$ledger" 2>/dev/null)"
assert_contains "$line1" "\"alarm\":true" "first failing run: row is an alarm row"
assert_contains "$line1" "\"exit_code\":1" "first failing run: exit code recorded"
assert_contains "$(cat "$GRAND_LOOP_DEMAND_LOG")" "ALARM" "first failing run: journal has an ALARM line"
assert_not_contains "$(cat "$agorabus_calls")" "demand-alarm-streak" "one alarm alone does not publish a streak event"

export GRAND_LOOP_DEMAND_TODAY=2026-09-14
run_demand run >/dev/null

nlines="$(wc -l < "$ledger")"
assert_eq "$nlines" "2" "two alarm rows total"
assert_contains "$(cat "$agorabus_calls")" "demand-alarm-streak" "two consecutive alarms publish an agorabus event"

exit $fail
