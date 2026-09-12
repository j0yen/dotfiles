#!/usr/bin/env bash
# tests/demandcadence_ac9_status.test.sh — PRD-grand-loop-demand-cadence
# AC9: with rows on the ledger, `grand-loop-demand.sh status` prints the
# last row's metrics, days since last success, and validated state, and
# exits 0.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=ok
export GRAND_LOOP_DEMAND_TODAY=2026-09-13
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":1,"real_wow_rate":0.1,"gross_churn":null,"validated":false}'
run_demand run >/dev/null

export GRAND_LOOP_DEMAND_TODAY=2026-09-14
export FAKE_MEASURE_JSON='{"paid_mrr_usd":19,"paying_tenants":1,"real_tenants":1,"real_wow_rate":0.2,"gross_churn":null,"validated":false}'
run_demand run >/dev/null

export GRAND_LOOP_DEMAND_TODAY=2026-09-15
export FAKE_MEASURE_JSON='{"paid_mrr_usd":19,"paying_tenants":1,"real_tenants":1,"real_wow_rate":0.1,"gross_churn":null,"validated":false}'
run_demand run >/dev/null

status_out="$(run_demand status)"
status_rc=$?
assert_eq "$status_rc" "0" "status exits 0"
assert_contains "$status_out" "last row:" "status prints the last row"
assert_contains "$status_out" "paid_mrr_usd=19" "status prints the last row's paid_mrr_usd"
assert_contains "$status_out" "days since:" "status prints days since last success"
assert_contains "$status_out" "validated:" "status prints validated state"

exit $fail
