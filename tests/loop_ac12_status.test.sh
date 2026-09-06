#!/usr/bin/env bash
# tests/loop_ac12_status.test.sh — PRD-grand-loop-scaffold AC12 (partial,
# scaffold slice): `grand-loop-status` prints the last tick's family, the
# last live paid_mrr_usd/real_tenants, ticks today against the cap, the STOP
# state, and the newest loop note — all read-only, offline, no mcphost-deploy
# call. The "systemctl --user list-timers" next-fire line is exercised only
# for "prints something and doesn't error" since the units aren't installed
# in this offline suite (AC11); the unit files themselves are checked
# statically against the PRD's exact directives below.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=loop_test_helpers.sh
. "$here/loop_test_helpers.sh"

STATUS="$(cd "$here/.." && pwd)/.local/bin/grand-loop-status"
run_status() { bash "$STATUS"; }

loop_setup

# Before any tick: status should say so, not error.
out="$(run_status)"
assert_contains "$out" "last tick:   none yet" "status: no ledger yet -> 'none yet'"
assert_contains "$out" "STOP:        absent" "status: no STOP file -> absent"
assert_contains "$out" "ticks today: 0/4" "status: no ticks yet -> 0/4 default cap"

# One healthy tick: family=discovery, paid_mrr_usd=0, real_tenants=4 (mirrors AC1).
export FAKE_PROBE_MODE=ok
export FAKE_MEASURE_MODE=ok
export FAKE_MEASURE_JSON='{"deployed_version":"0.1.0","billing_mode":"off","real_tenants":4,"new_real_tenants":1,"real_wow_rate":0.2,"paying_tenants":0,"paid_mrr_usd":0,"gross_churn":null,"exclusions":{"harness_prefix":3}}'
run_tick >/dev/null

out="$(run_status)"
assert_contains "$out" "family=discovery" "status: last tick shows family=discovery"
assert_contains "$out" "paid_mrr_usd=0 real_tenants=4" "status: last live shows the measure's numbers"
assert_contains "$out" "ticks today: 1/4" "status: one tick counted against the cap"
assert_contains "$out" "loop note:" "status: prints a loop note line"
assert_contains "$out" "(grand-loop): family=discovery" "status: loop note carries today's family"
assert_contains "$out" "timer:" "status: prints a timer line without erroring"

# STOP present.
mkdir -p "$loop_dir"
touch "$loop_dir/STOP"
out="$(run_status)"
assert_contains "$out" "STOP:        present" "status: STOP file -> present"

# --- static check on the units (PRD "Units" bullet: exact directives) -----
repo_root="$(cd "$here/.." && pwd)"
svc="$repo_root/.config/systemd/user/grand-loop.service"
tmr="$repo_root/.config/systemd/user/grand-loop.timer"
[ -f "$svc" ] || { echo "NOT OK - grand-loop.service exists"; fail=1; }
[ -f "$tmr" ] || { echo "NOT OK - grand-loop.timer exists"; fail=1; }
svc_txt="$(cat "$svc" 2>/dev/null)"
tmr_txt="$(cat "$tmr" 2>/dev/null)"
assert_contains "$svc_txt" "Type=oneshot" "unit: service is oneshot"
assert_contains "$svc_txt" "ExecStart=%h/.local/bin/grand-loop-tick.sh" "unit: ExecStart matches the PRD path"
assert_contains "$svc_txt" "TimeoutStartSec=900" "unit: TimeoutStartSec=900"
assert_contains "$tmr_txt" "OnCalendar=*-*-* 00,06,12,18:00 UTC" "unit: OnCalendar matches the PRD cadence"
assert_contains "$tmr_txt" "RandomizedDelaySec=300" "unit: RandomizedDelaySec=300"
assert_contains "$tmr_txt" "Persistent=true" "unit: Persistent=true"
assert_contains "$tmr_txt" "Unit=grand-loop.service" "unit: timer points at the service"
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify "$svc" >/dev/null 2>&1
  assert_eq "$?" "0" "unit: grand-loop.service passes systemd-analyze verify"
fi

exit $fail
