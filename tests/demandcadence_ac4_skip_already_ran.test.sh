#!/usr/bin/env bash
# tests/demandcadence_ac4_skip_already_ran.test.sh — PRD-grand-loop-demand-cadence
# AC4: a second invocation the same day exits 0 with "skip: already ran"
# logged, and appends no row.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export FAKE_MEASURE_MODE=ok
export GRAND_LOOP_DEMAND_TODAY=2026-09-13
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":2,"real_wow_rate":0.1,"gross_churn":null,"validated":false}'

run_demand run >/dev/null
nlines1="$(wc -l < "$ledger")"
assert_eq "$nlines1" "1" "first run today appends one row"

out2="$(run_demand run)"
rc2=$?
assert_eq "$rc2" "0" "second run today exits 0"
assert_contains "$out2" "skip: already ran" "second run today reports skip: already ran"
assert_contains "$(cat "$GRAND_LOOP_DEMAND_LOG")" "skip: already ran" "skip is logged"

nlines2="$(wc -l < "$ledger")"
assert_eq "$nlines2" "1" "second run today appends no row"

exit $fail
