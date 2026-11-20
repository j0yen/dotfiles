#!/usr/bin/env bash
# tests/demandcadence_ac7_install_paths.test.sh — PRD-grand-loop-demand-cadence
# AC7: after install, every directory the unit writes to exists, and one
# observed live fire (a real `run` invocation) succeeds — no silent 209.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=demandcadence_test_helpers.sh
. "$here/demandcadence_test_helpers.sh"
demandcadence_setup

# Precondition: none of the unit's write-path parents exist yet.
rm -rf "$(dirname "$GRAND_LOOP_DEMAND_LOG")" "$(dirname "$GRAND_LOOP_DEMAND_MD_CACHE")" "$clone"

install_out="$(run_demand install)"
assert_contains "$install_out" "install: done" "install reports done"
# Review 034ad5b9 DC-F1: the exact call sequence, so a dropped daemon-reload or an added live call (restart, start, ...) turns this red.
want_calls=$'--user daemon-reload\n--user enable --now grand-loop-demand.timer'
[ "$(cat "$systemctl_calls")" = "$want_calls" ] && echo "ok - install's systemctl calls are exactly daemon-reload + enable --now timer, all to the test stand-in" \
  || { echo "NOT OK - install's systemctl calls differ from the exact two-line sequence: '$(cat "$systemctl_calls")'"; fail=1; }

[ -d "$(dirname "$GRAND_LOOP_DEMAND_LOG")" ] && echo "ok - log directory created" || { echo "NOT OK - log directory missing"; fail=1; }
[ -d "$(dirname "$GRAND_LOOP_DEMAND_MD_CACHE")" ] && echo "ok - mcphost-deploy cache directory created" || { echo "NOT OK - cache directory missing"; fail=1; }

export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"paid_mrr_usd":0,"paying_tenants":0,"real_tenants":0,"real_wow_rate":0.0,"gross_churn":null,"validated":false}'
export GRAND_LOOP_DEMAND_TODAY=2026-09-13
fire_out="$(run_demand run)"
fire_rc=$?
assert_eq "$fire_rc" "0" "the one observed live fire after install exits 0"
assert_contains "$fire_out" "ok: demand row appended" "the one observed live fire produced a row (no silent 209)"
[ -f "$ledger" ] && echo "ok - ledger written under the install-created clone dir" || { echo "NOT OK - ledger missing after live fire"; fail=1; }

exit $fail
