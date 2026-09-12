#!/usr/bin/env bash
# tests/demandcadence_ac3_tenant_moved.test.sh — PRD-grand-loop-demand-cadence
# AC3: real_tenants moving from a previous row's value publishes an
# agorabus event carrying both values and the date, and the row marks the
# transition.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=ok
export GRAND_LOOP_DEMAND_TODAY=2026-09-13
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":0,"real_wow_rate":null,"gross_churn":null,"validated":false}'
run_demand run >/dev/null
assert_not_contains "$(cat "$agorabus_calls")" "real-tenants-moved" "no prior baseline yet -> real_tenants:0 vs implicit 0 does not move"

export GRAND_LOOP_DEMAND_TODAY=2026-09-14
export FAKE_MEASURE_JSON='{"paid_mrr_usd":19,"paying_tenants":1,"real_tenants":1,"real_wow_rate":0.2,"gross_churn":null,"validated":false}'
run_demand run >/dev/null

calls="$(cat "$agorabus_calls")"
assert_contains "$calls" "real-tenants-moved" "real_tenants 0->1 publishes an agorabus event"
assert_contains "$calls" "\"from\":0" "event carries the previous value"
assert_contains "$calls" "\"to\":1" "event carries the new value"
assert_contains "$calls" "\"date\":\"2026-09-14\"" "event carries the date"

line2="$(tail -n1 "$ledger")"
assert_contains "$line2" "\"real_tenants_changed\":true" "row marks the transition"
assert_contains "$line2" "\"real_tenants_prev\":0" "row records the previous value"

exit $fail
