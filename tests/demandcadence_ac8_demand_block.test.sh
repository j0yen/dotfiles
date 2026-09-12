#!/usr/bin/env bash
# tests/demandcadence_ac8_demand_block.test.sh — PRD-grand-loop-demand-cadence
# AC8: when measure.json carries a `demand` block, the row embeds it;
# when absent, the row says demand:"absent".
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=ok

export GRAND_LOOP_DEMAND_TODAY=2026-09-13
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":0,"real_wow_rate":0.0,"gross_churn":null,"validated":false,"demand":{"visits":10,"signups":2}}'
run_demand run >/dev/null
line1="$(tail -n1 "$ledger")"
assert_contains "$line1" "\"demand\":{" "demand block present: embedded in the row"
assert_contains "$line1" "\"visits\":10" "demand block's summary fields carried through"

export GRAND_LOOP_DEMAND_TODAY=2026-09-14
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":0,"real_wow_rate":0.0,"gross_churn":null,"validated":false}'
run_demand run >/dev/null
line2="$(tail -n1 "$ledger")"
assert_contains "$line2" "\"demand\":\"absent\"" "demand block absent: row says demand:absent"

exit $fail
