#!/bin/bash
# R14-a controls: run the extracted wiring block in a sandbox HOME with a stub producer (no ledger, no relaunch)
here=$(cd "$(dirname "$0")" && pwd); bad=0
blk=$(awk '/^if \[ -n "\$\{WM_SUCC_ASK:-\}" \]/{f=1} f{print} f&&/^fi$/{exit}' "$here/ctl-account-follow.cand.sh")
[ -n "$blk" ] || { echo "WRONG no block"; exit 1; }
run(){ # $1 ask, $2 planned inv, $3 stub mode
  H=$(mktemp -d); mkdir -p "$H/.local/lib"; LOG="$H/log"
  cat > "$H/.local/lib/a1577_produce.py" <<PY
import sys,os
open(os.path.expanduser("~/called"),"w").write(" ".join(sys.argv[1:]))
if "$3"=="refuse": sys.exit(3)
inv=[a.split("=",1)[1] for a in sys.argv if a.startswith("--inv=")][0]
print("WM_SUCC_INV="+inv); print("WM_SUCC_BINDING=/x/b.json")
PY
  ( set -uo pipefail; HOME=$H; export HOME; LOG=$H/log; WM_SUCC_ASK=$1; [ -n "$2" ] && WM_SUCC_INV=$2; eval "$blk"; echo "INV=${WM_SUCC_INV:-unset} BIND=${WM_SUCC_BINDING:-unset}" ) > "$H/out" 2>&1
  echo "$H"
}
H=$(run A1 inv-1 ok); grep -q "inv=inv-1" $H/called && grep -q "INV=inv-1 BIND=/x/b.json" $H/out && echo "OK producer called with --ask=/--inv=, env exported" || { echo "WRONG ok-path: $(cat $H/out $H/called 2>&1|head -c 200)"; bad=1; }
H=$(run -A inv--x ok); grep -q -- "--ask=-A" $H/called && grep -q -- "--inv=inv--x" $H/called && echo "OK dash ask id is a value" || { echo "WRONG dash"; bad=1; }
H=$(run A1 inv-1 refuse); grep -q "INV=unset BIND=unset" $H/out && grep -q "UNVERIFIED" $H/log && echo "OK refusal leaves UNVERIFIED, vars unset" || { echo "WRONG refuse"; bad=1; }
H=$(run A1 "" ok); [ -s $H/called ] && echo "OK random id path calls producer" || { echo "WRONG random"; bad=1; }
[ $bad = 0 ] && echo A1577-WIRING-RUN-CONTROLS-PASS || echo FAILED
