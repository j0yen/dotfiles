#!/usr/bin/env bash
# tests/loop_ac3_stop.test.sh — PRD-grand-loop-scaffold AC3:
#   - a STOP file alone: tick exits 0, ledger line says "skip: STOP", no
#     measure directory is created.
#   - STOP + MEASURE-OK together: the measure runs anyway and MEASURE-OK is
#     removed (the plateau deadlock the inner loop hit cannot recur here).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

loop_setup
mkdir -p "$loop_dir"
echo "operator paused the loop" > "$loop_dir/STOP"

export FAKE_PROBE_MODE=ok
export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"paying_tenants":0,"paid_mrr_usd":0}'

rc=0
run_tick > /tmp/loop_ac3_out.$$ 2>&1 || rc=$?
out="$(cat /tmp/loop_ac3_out.$$)"; rm -f /tmp/loop_ac3_out.$$
assert_eq "$rc" "0" "STOP alone: tick exits 0"
assert_contains "$out" "skip: STOP" "STOP alone: prints skip: STOP"
line="$(tail -n1 "$ledger" 2>/dev/null)"
assert_contains "$line" "skip: STOP" "STOP alone: ledger line says skip: STOP"
if [ -d "$loop_dir/measure" ] && [ -n "$(ls -A "$loop_dir/measure" 2>/dev/null)" ]; then
  echo "NOT OK - STOP alone: a measure directory was created"; fail=1
else
  echo "ok - STOP alone: no measure directory created"
fi

# --- STOP + MEASURE-OK: measure runs, MEASURE-OK is consumed -------------
touch "$loop_dir/MEASURE-OK"
out2="$(run_tick)"
assert_contains "$out2" "family=" "STOP+MEASURE-OK: measure ran and a family was classified"
[ -f "$loop_dir/MEASURE-OK" ] && { echo "NOT OK - MEASURE-OK was not removed"; fail=1; } || echo "ok - MEASURE-OK removed after forcing a measure"
if [ -d "$loop_dir/measure" ] && [ -n "$(ls -A "$loop_dir/measure" 2>/dev/null)" ]; then
  echo "ok - STOP+MEASURE-OK: a measure directory was created"
else
  echo "NOT OK - STOP+MEASURE-OK: no measure directory created"; fail=1
fi

exit $fail
