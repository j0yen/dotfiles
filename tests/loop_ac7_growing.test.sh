#!/usr/bin/env bash
# tests/loop_ac7_growing.test.sh — PRD-grand-loop-scaffold AC7: two
# consecutive live measures with paid_mrr_usd 29 then 58 -> the second
# tick's family is growing.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup
mkdir -p "$loop_dir"
echo "slug: foo status: live" > "$loop_dir/candidates.yaml"  # non-held row: discovery must not preempt growing/flat
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok

export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"live","real_tenants":10,"new_real_tenants":0,"real_wow_rate":0.5,"paying_tenants":3,"paid_mrr_usd":29,"gross_churn":0.02}'
run_tick > /dev/null
first_line="$(tail -n1 "$ledger")"
assert_contains "$first_line" "paid_mrr_usd=29" "first tick: ledger records paid_mrr_usd=29"

export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"live","real_tenants":11,"new_real_tenants":0,"real_wow_rate":0.5,"paying_tenants":4,"paid_mrr_usd":58,"gross_churn":0.02}'
run_tick > /dev/null
second_line="$(tail -n1 "$ledger")"
assert_contains "$second_line" "family=growing" "second tick: family=growing (29 -> 58)"

exit $fail
