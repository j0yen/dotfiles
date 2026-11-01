#!/usr/bin/env bash
# tests/fleet-token-rotate.test.sh -- the fleet-token rotation mechanism (store, rotate, 429 watch, schedule, seat-tick quota_account).
# Runs every new script's --selftest under a throwaway HOME (env -i; fake place/bell/record/systemctl/verify/probe commands, a fake clock, the
# canary token canary-tok-7f3e9a that must appear nowhere but the store file and the temp the fake place reads), plus static contract checks.
# The seat-tick selftest (~6 min, reads the real seats.tsv / goal.md read-only) runs only with FLEET_TOKEN_TEST_SEAT_TICK=1; here its new
# quota_account cases are checked to be present. Run: bash tests/fleet-token-rotate.test.sh
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/.local/bin"; units="$root/.config/systemd/user"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

scripts="fleet-token-store.sh fleet-token-rotate.sh fleet-token-429-watch.sh fleet-token-schedule.sh"
for s in $scripts; do
  chk "$s: bash -n" "bash -n '$bin/$s'"
  chk "$s: executable" "[ -x '$bin/$s' ]"
  chk "$s: 'set -euo pipefail' then an explicit 'set +x' near the top" "head -n 40 '$bin/$s' | grep -v '^#' | grep -n -E '^set -euo pipefail\$' >/dev/null && head -n 40 '$bin/$s' | grep -qx 'set +x'"
  tmp="$(mktemp -d)"
  if out="$(env -i PATH="$PATH" HOME="$tmp" bash "$bin/$s" --selftest 2>&1)"; then rc=0; else rc=$?; fi
  rm -rf "$tmp"
  n="$(printf '%s\n' "$out" | grep -c '^PASS ' || true)"
  if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '^SELFTEST PASS' && ! printf '%s\n' "$out" | grep -q '^FAIL'; then ok "$s --selftest ($n cases)"; else bad "$s --selftest"; printf '%s\n' "$out" | grep -E '^(FAIL|SELFTEST)' | head; fi
done
chk "lib: bash -n" "bash -n '$root/.local/lib/fleet-token-lib.sh'"
chk "no script or the lib touches the real token file (90-claude-oauth.conf) or environment.d" "! grep -l -E '90-claude-oauth|environment\\.d' '$bin'/fleet-token-store.sh '$bin'/fleet-token-rotate.sh '$bin'/fleet-token-429-watch.sh '$bin'/fleet-token-schedule.sh '$root/.local/lib/fleet-token-lib.sh' | grep -q ."

# watcher: PREMISE + EXPIRES 14 days from the commit date, parseable
chk "429 watch carries the PREMISE line" "grep -q '^# PREMISE: seat-tick.s quota_wait_until is the fleet-wide limit signal\$' '$bin/fleet-token-429-watch.sh'"
chk "429 watch EXPIRES parses" "e=\$(sed -nE 's/^EXPIRES=\"([^\"]+)\"\$/\\1/p' '$bin/fleet-token-429-watch.sh'); [ -n \"\$e\" ] && date -d \"\$e\" +%s >/dev/null"

# units
for u in fleet-token-429-watch.service fleet-token-429-watch.timer fleet-token-schedule.service fleet-token-schedule.timer; do
  chk "$u: ConditionHost=carbon" "grep -qx 'ConditionHost=carbon' '$units/$u'"
done
# blocked-until: the watcher and the weekly schedule read the SAME block file (one state dir, one helper)
chk "429 watch skip_reason and the schedule both consult ft_block_reason" "grep -q 'ft_block_reason' '$bin/fleet-token-429-watch.sh' && grep -q 'ft_block_reason' '$bin/fleet-token-schedule.sh'"
chk "no fleet-token unit or script overrides FLEET_TOKEN_STATE_DIR (watcher + schedule share \$FT_STATE on carbon)" "! grep -n 'FLEET_TOKEN_STATE_DIR' '$units'/fleet-token-*.service '$units'/fleet-token-*.timer | grep -q . && ! grep -n 'FLEET_TOKEN_STATE_DIR=' '$bin'/fleet-token-429-watch.sh '$bin'/fleet-token-schedule.sh '$bin'/fleet-token-store.sh '$bin'/fleet-token-rotate.sh | grep -q ."
chk "one date parser: no script outside the lib calls date -d on a reset text" "! grep -n 'date -d \"\$.*resets' '$bin'/fleet-token-{429-watch,schedule,store,rotate}.sh | grep -q ."
chk "429 watch timer: every 2 min" "grep -qx 'OnUnitActiveSec=2min' '$units/fleet-token-429-watch.timer'"
chk "schedule timer: Fri 14:05 America/Los_Angeles, Persistent=true" "grep -qx 'OnCalendar=Fri 14:05 America/Los_Angeles' '$units/fleet-token-schedule.timer' && grep -qx 'Persistent=true' '$units/fleet-token-schedule.timer'"
chk "the repo enables nothing (no timers.target symlink, no systemctl enable)" "! grep -rn -E 'systemctl[^|]* enable' '$bin'/fleet-token-*.sh | grep -q ."
if command -v systemd-analyze >/dev/null 2>&1; then
  chk "schedule OnCalendar parses" "systemd-analyze calendar 'Fri 14:05 America/Los_Angeles' >/dev/null 2>&1"
fi

# seat-tick: quota_account recorded and stale waits ignored (cases live in its selftest)
chk "seat-tick records quota_account and ignores a wait under another account" "grep -q 'quota_account:(if \$qa==\"\" then null else \$qa end)' '$bin/seat-tick.sh' && grep -q 'S_qw=\"\"; S_qa=\"\"; S_qk=\"\"; S_qpf=false; S_qpt=\"\"; fi' '$bin/seat-tick.sh'"
chk "seat-tick selftest has the quota_account cases (a)-(h)" "[ \$(grep -c 'chk \"quota_account (' '$bin/seat-tick.sh') -ge 8 ]"
if [ "${FLEET_TOKEN_TEST_SEAT_TICK:-}" = 1 ]; then
  if out="$(bash "$bin/seat-tick.sh" --selftest 2>&1)" && printf '%s\n' "$out" | grep -q '^SELFTEST PASS'; then ok "seat-tick.sh --selftest"; else bad "seat-tick.sh --selftest"; printf '%s\n' "$out" | grep '^FAIL' | head; fi
else
  echo "skip seat-tick.sh --selftest (~6 min; FLEET_TOKEN_TEST_SEAT_TICK=1 to run it)"
fi

[ "$fail" = 0 ] && echo "OK fleet-token-rotate" || echo "NOT OK fleet-token-rotate"
exit "$fail"
