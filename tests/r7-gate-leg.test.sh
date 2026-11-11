#!/usr/bin/env bash
# r7-gate-leg.sh: the unit carries infinity caps only, rejects bad input (A1299/W11).
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/.local/bin/r7-gate-leg.sh"
H=5825a0c2869084d43704e88a42feb37bfed858ea
fail=0; ck(){ [ "$1" = 0 ] && echo "PASS $2" || { echo "FAIL $2"; fail=1; }; }
o=$(bash "$S" --dry-run sdgate 71 $H); rc=$?; ck $rc "dry-run succeeds"
echo "$o" | grep -q -- '--unit=r7-sdgate-71 '; ck $? "unit name r7-sdgate-71"
echo "$o" | grep -q -- '-p MemoryMax=infinity -p TasksMax=infinity -p RuntimeMaxSec=infinity'; ck $? "all three caps infinity"
! echo "$o" | grep -Eq 'MemoryMax=[0-9]|TasksMax=[0-9]|RuntimeMaxSec=[0-9]'; ck $? "no finite cap"
echo "$o" | grep -q "r7-sdgate.sh 71 $H"; ck $? "runs the exact head"
bash "$S" --dry-run dfgate 386 $H | grep -q 'r7-dfgate.sh 386'; ck $? "dfgate routed"
bash "$S" --dry-run badkind 1 $H >/dev/null 2>&1; [ $? = 2 ]; ck $? "bad kind refused rc 2"
bash "$S" --dry-run sdgate 1 abc123 >/dev/null 2>&1; [ $? = 2 ]; ck $? "short head refused rc 2"
bash "$S" --dry-run sdgate 7x $H >/dev/null 2>&1; [ $? = 2 ]; ck $? "non-numeric pr refused rc 2"
exit $fail
