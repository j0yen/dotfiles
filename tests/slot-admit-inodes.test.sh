#!/usr/bin/env bash
# slot-admit-inodes.test.sh - stubs df on PATH; covers 69/70/100 %, "-", and a custom --max.
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../.local/bin/slot-admit-inodes.sh
fail=0
d=$(mktemp -d "${TMPDIR:-/tmp}/slot-admit-test.XXXXXX")
trap 'rm -rf "$d"' EXIT
cat > "$d/df" <<'STUB'
#!/bin/sh
printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\nstub 100 0 100 %s /x\n' "$STUB_USE"
STUB
chmod +x "$d/df"

check() { # name use want_rc want_out [args...]
  local name=$1 use=$2 wrc=$3 wout=$4; shift 4
  local out rc
  out=$(STUB_USE=$use PATH="$d:$PATH" "$script" "$@" 2>&1); rc=$?
  if [ "$rc" -eq "$wrc" ] && [ "$out" = "$wout" ]; then echo "PASS: $name"; else echo "FAIL: $name rc=$rc out=$out"; fail=1; fi
}
check "69% ok" "69%" 0 "OK inodes 69%"
check "70% refuse" "70%" 1 "REFUSE inodes 70%"
check "100% refuse" "100%" 1 "REFUSE inodes 100%"
check "dash n/a" "-" 0 "OK inodes n/a"
check "custom max 90 at 85" "85%" 0 "OK inodes 85%" /tmp --max 90
check "custom max 50 at 60" "60%" 1 "REFUSE inodes 60%" --max 50
check "path arg" "10%" 0 "OK inodes 10%" /var

[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
