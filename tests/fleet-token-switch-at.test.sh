#!/usr/bin/env bash
# tests/fleet-token-switch-at.test.sh -- fleet-token-switch-at.sh --dry-run under PATH stubs; no real rotate, systemd-run or token store runs.
set -euo pipefail
set +x
root="$(cd "$(dirname "$0")/.." && pwd)"
h="$root/.local/bin/fleet-token-switch-at.sh"
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
mkdir "$t/stub" "$t/empty"
for s in aide-relaunch.sh fleet-token-rotate.sh systemd-run; do
  printf '#!/bin/sh\necho STUB-RAN %s >> "%s/ran.log"\n' "$s" "$t" >"$t/stub/$s"; chmod +x "$t/stub/$s"
done
export PATH="$t/stub:/usr/bin:/bin"
export FLEET_TOKEN_ROTATE_CHECK_BIN="$t/stub/fleet-token-rotate.sh"   # the arm-time --check runs the stub, never the real store
out="$(bash "$h" acctB 09:30 --by joe-20261101 --dry-run 2>&1)" && rc=0 || rc=$?
[ "$rc" = 0 ] && ok "dry-run exits 0" || bad "dry-run exits 0 (rc=$rc)"
grep -q -- '--unit=fleet-token-switch-at-0930' <<<"$out" && ok "unit name fleet-token-switch-at-0930" || bad "unit name"
grep -Eq -- "--on-calendar=[0-9]{4}-[0-9]{2}-[0-9]{2}\\\\? 09:30:00" <<<"$out" && ok "calendar time 09:30:00" || bad "calendar time ($out)"
grep -q -- '--trigger' <<<"$out" && grep -q 'joe-0930' <<<"$out" && grep -q 'joe-20261101' <<<"$out" && ok "trigger joe-0930 and --by joe-20261101 present" || bad "trigger/by"
r="$(grep -ob 'fleet-token-rotate.sh' <<<"$out" | tail -1 | cut -d: -f1)"; a="$(grep -ob 'aide-relaunch.sh' <<<"$out" | tail -1 | cut -d: -f1)"
[ -n "$r" ] && [ -n "$a" ] && [ "$r" -lt "$a" ] && ok "fleet account switch listed before aide account switch" || bad "step order"
grep -Fq -- '\"\$5\"\ \"\$2\"\ \"\$6\"' <<<"$out" && ok "aide step runs relaunch with the account (\$2, same as fleet step) as first argument, then the reason (\$6)" || bad "aide step argv ($out)"
grep -Eq -- 'rotate\.sh acctB joe-20261101 joe-0930 .*aide-relaunch\.sh joe-switch-at-0930 *$' <<<"$out" && ok "argv tail: rotate account acctB feeds \$2; reason joe-switch-at-0930 is \$6" || bad "argv tail ($out)"
[ ! -e "$t/ran.log" ] && ok "dry-run ran no stub" || bad "dry-run ran a stub"
# arm path with the systemd-run stub
bash "$h" acctB 09:30 --by joe-20261101 >/dev/null 2>&1 && grep -q 'STUB-RAN systemd-run' "$t/ran.log" && ok "armed through the systemd-run stub" || bad "arm via stub"
# missing aide-relaunch.sh -> exit 2, nothing armed
rm -f "$t/stub/aide-relaunch.sh" "$t/ran.log"
bash "$h" acctB 09:30 --by joe-20261101 >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 2 ] && [ ! -e "$t/ran.log" ] && ok "absent aide-relaunch.sh: exit 2, nothing armed" || bad "absent relaunch (rc=$rc)"
# --check at arm time: a rotate stub exiting 64 on --check -> nothing armed, rc 64
printf '#!/bin/sh\n[ "$1" = --check ] && exit 64\necho STUB-RAN rotate >> "%s/ran.log"\n' "$t" >"$t/stub/fleet-token-rotate.sh"
printf '#!/bin/sh\necho STUB-RAN aide-relaunch.sh >> "%s/ran.log"\n' "$t" >"$t/stub/aide-relaunch.sh"; chmod +x "$t/stub/"*
rm -f "$t/ran.log"
bash "$h" acctB 09:30 --by joe-20261101 >/dev/null 2>"$t/err" && rc=0 || rc=$?
[ "$rc" = 64 ] && [ ! -e "$t/ran.log" ] && grep -q 'nothing armed' "$t/err" && ok "rotate --check rc 64: refuses to arm, no unit created" || bad "check refusal (rc=$rc)"
bash "$h" acctB 9:30 >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 64 ] && ok "bad time: exit 64" || bad "bad time (rc=$rc)"
[ "$fail" = 0 ] && echo "OK fleet-token-switch-at" || echo "NOT OK fleet-token-switch-at"
exit "$fail"
