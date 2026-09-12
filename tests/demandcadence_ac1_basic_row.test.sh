#!/usr/bin/env bash
# tests/demandcadence_ac1_basic_row.test.sh — PRD-grand-loop-demand-cadence
# AC1: a healthy fake measure produces a dated out directory and exactly one
# ledger row with all named fields including `validated`.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

export GRAND_LOOP_DEMAND_TODAY=2026-09-13
export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":4,"real_wow_rate":0.1,"gross_churn":null,"validated":false}'

out="$(run_demand run)"
assert_contains "$out" "ok: demand row appended" "run reports ok"

[ -f "$ledger" ] || { echo "NOT OK - ledger.jsonl exists"; fail=1; }
line="$(tail -n1 "$ledger" 2>/dev/null)"
for field in date paid_mrr_usd paying_tenants real_tenants real_wow_rate gross_churn validated exit_code out_dir; do
  assert_contains "$line" "\"$field\":" "ledger row has $field"
done

out_dir_val="$(python3 -c "import json,sys;print(json.loads(sys.argv[1])['out_dir'])" "$line" 2>/dev/null)"
[ -n "$out_dir_val" ] && [ -d "$clone/$out_dir_val" ] && echo "ok - dated out directory exists ($out_dir_val)" \
  || { echo "NOT OK - dated out directory missing ($out_dir_val)"; fail=1; }

nlines="$(wc -l < "$ledger")"
assert_eq "$nlines" "1" "exactly one ledger row appended"

exit $fail
