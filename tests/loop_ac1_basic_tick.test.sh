#!/usr/bin/env bash
# tests/loop_ac1_basic_tick.test.sh — PRD-grand-loop-scaffold AC1:
# a healthy probe + a measure with real_tenants=4, paid_mrr_usd=0,
# billing_mode=off, and no candidates.yaml stamps all four phases in
# state.json and writes one ledger line with family=discovery.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup

export FAKE_PROBE_MODE=ok
export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"new_real_tenants":1,"real_wow_rate":0.2,"paying_tenants":0,"paid_mrr_usd":0,"gross_churn":null,"exclusions":{"harness_prefix":3}}'

out="$(run_tick)"
assert_contains "$out" "family=discovery" "tick: reports family=discovery"

for phase in PREFLIGHT MEASURE DIGEST IDLE; do
  stamp="$(python3 -c "import json;print(json.load(open('$state'))['phases'].get('$phase',{}).get('stamp',''))" 2>/dev/null)"
  [ -n "$stamp" ] && echo "ok - state.json has a $phase stamp" || { echo "NOT OK - state.json missing $phase stamp"; fail=1; }
done

[ -f "$ledger" ] || { echo "NOT OK - ledger.md was not created"; fail=1; }
line="$(tail -n1 "$ledger" 2>/dev/null)"
assert_contains "$line" "real_tenants=4" "ledger line: real_tenants=4"
assert_contains "$line" "paid_mrr_usd=0" "ledger line: paid_mrr_usd=0"
assert_contains "$line" "billing_mode=off" "ledger line: billing_mode=off"
assert_contains "$line" "family=discovery" "ledger line: family=discovery"
assert_contains "$line" "reached_measure=1" "ledger line: reached_measure=1"
nlines="$(wc -l < "$ledger")"
assert_eq "$nlines" "1" "ledger has exactly one new line"

exit $fail
