#!/usr/bin/env bash
# slot-admit-pressure.test.sh - fixture meminfo/PSI files via SLOT_ADMIT_MEMINFO/SLOT_ADMIT_PSI; covers below --at,
# the swap and PSI edges, a custom --max-swap-gib, a missing PSI file and a bad --open.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../.local/bin/slot-admit-pressure.sh
fail=0
d=$(mktemp -d "${TMPDIR:-/tmp}/slot-admit-pressure-test.XXXXXX")
trap 'rm -rf "$d"' EXIT

mem() { # swap_used_kb
  printf 'MemTotal:       65536000 kB\nSwapTotal:      33554432 kB\nSwapFree:       %s kB\n' "$((33554432 - $1))" > "$d/meminfo"
}
psi() { # full avg10
  printf 'some avg10=1.00 avg60=0.50 avg300=0.10 total=123\nfull avg10=%s avg60=0.00 avg300=0.00 total=45\n' "$1" > "$d/psi"
}
check() { # name want_rc want_out [args...]
  local name=$1 wrc=$2 wout=$3; shift 3
  local out rc
  out=$(SLOT_ADMIT_MEMINFO=$d/meminfo SLOT_ADMIT_PSI=$d/psi "$script" "$@" 2>&1); rc=$?
  if [ "$rc" -eq "$wrc" ] && [ "$out" = "$wout" ]; then echo "PASS: $name"; else echo "FAIL: $name rc=$rc out=$out"; fail=1; fi
}
checkrc() { # name want_rc [args...]  (stdout/stderr text not compared)
  local name=$1 wrc=$2; shift 2
  local rc
  SLOT_ADMIT_MEMINFO=$d/meminfo SLOT_ADMIT_PSI=$d/psi "$script" "$@" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$wrc" ]; then echo "PASS: $name"; else echo "FAIL: $name rc=$rc"; fail=1; fi
}

mem 8388608; psi 50.00   # swap 8.0G, psi 50: would refuse if the limits applied
check "below --at is n/a" 0 "OK pressure n/a open=1" --open 1
mem 4089446; psi 0.00    # 3.9G
check "swap 3.9G psi 0 ok" 0 "OK pressure swap=3.9G psi_full10=0.00 open=2" --open 2
mem 4508876; psi 0.00    # 4.3G
check "swap 4.3G psi 0 refuse" 1 "REFUSE pressure swap=4.3G psi_full10=0.00 open=2" --open 2
mem 1048576; psi 10.00
check "psi 10.00 refuse" 1 "REFUSE pressure swap=1.0G psi_full10=10.00 open=2" --open 2
psi 9.99
check "psi 9.99 ok" 0 "OK pressure swap=1.0G psi_full10=9.99 open=2" --open 2
mem 4508876; psi 0.00
check "custom --max-swap-gib 8 at 4.3G ok" 0 "OK pressure swap=4.3G psi_full10=0.00 open=2" --open 2 --max-swap-gib 8
check "custom --at 2 applies at open 1" 1 "REFUSE pressure swap=4.3G psi_full10=0.00 open=1" --open 1 --at 2
rm -f "$d/psi"
checkrc "missing PSI file exit 2" 2 --open 2
psi 0.00
checkrc "bad --open exit 2" 2 --open x
checkrc "missing --open exit 2" 2

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
