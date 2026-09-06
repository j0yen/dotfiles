#!/usr/bin/env bash
# tests/loop_ac6_families.test.sh — PRD-grand-loop-scaffold AC6, three
# scenarios in one file (the AC itself bundles them):
#   - new_real_tenants=6 over 30 days, real_wow_rate=0.17 -> activation
#   - 7 tenants with wow:true, paying_tenants=0, billing_mode=live -> monetization
#   - gross_churn=0.12 -> retention
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

# -- activation --------------------------------------------------------
loop_setup
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":10,"new_real_tenants":6,"real_wow_rate":0.17,"paying_tenants":0,"paid_mrr_usd":0}'
unset FAKE_TENANTS_JSONL
run_tick > /dev/null
line="$(tail -n1 "$ledger")"
assert_contains "$line" "family=activation" "activation: new_real_tenants=6, wow_rate=0.17 under 0.3"

# -- monetization --------------------------------------------------------
loop_setup
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"live","real_tenants":10,"new_real_tenants":0,"real_wow_rate":0.7,"paying_tenants":0,"paid_mrr_usd":0}'
wow_lines=""
for i in 1 2 3 4 5 6 7; do wow_lines="${wow_lines}{\"namespace\":\"t$i\",\"wow\":true}"$'\n'; done
export FAKE_TENANTS_JSONL="$wow_lines"
run_tick > /dev/null
line="$(tail -n1 "$ledger")"
assert_contains "$line" "family=monetization" "monetization: 7 wow tenants, 0 paying, billing live"

# -- retention --------------------------------------------------------
loop_setup
export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"live","real_tenants":10,"new_real_tenants":0,"real_wow_rate":0.5,"paying_tenants":5,"paid_mrr_usd":100,"gross_churn":0.12}'
unset FAKE_TENANTS_JSONL
run_tick > /dev/null
line="$(tail -n1 "$ledger")"
assert_contains "$line" "family=retention" "retention: gross_churn=0.12"

exit $fail
