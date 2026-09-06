#!/usr/bin/env bash
# tests/loop_ac8_budget_cap.test.sh — PRD-grand-loop-scaffold AC8: given four
# ledger lines today that reached MEASURE, a fifth tick exits 0 with
# "skip: daily cap (4/4)" and no measure runs.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup
mkdir -p "$loop_dir"
today="$(date -u +%F)"
for i in 1 2 3 4; do
  echo "${today}T0${i}:00:00Z version=0.1.0 billing_mode=off real_tenants=1 new_real_tenants=0 real_wow_rate=0 paying_tenants=0 paid_mrr_usd=0 gross_churn=- exclusions=- family=flat reason=\"seed\" reached_measure=1" >> "$ledger"
done

export FAKE_PROBE_MODE=ok FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":1,"paying_tenants":0,"paid_mrr_usd":0}'

rc=0
out="$(run_tick)" || rc=$?
assert_eq "$rc" "0" "fifth tick exits 0"
assert_contains "$out" "skip: daily cap (4/4)" "fifth tick prints skip: daily cap (4/4)"

nlines_after="$(wc -l < "$ledger")"
assert_eq "$nlines_after" "4" "no new ledger line was written (still 4)"

if [ -d "$loop_dir/measure" ] && [ -n "$(ls -A "$loop_dir/measure" 2>/dev/null)" ]; then
  echo "NOT OK - a measure directory was created despite the cap"; fail=1
else
  echo "ok - no measure directory created"
fi

exit $fail
