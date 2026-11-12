#!/bin/bash
# R13-a controls: the wiring passes --inv=<id>, so an id starting with '-' is a value, not an option (private, no ledger, no relaunch)
here=$(cd "$(dirname "$0")" && pwd); bad=0
grep -q -- '--inv="\$_inv"' "$here/ctl-account-follow.cand.sh" && ! grep -q -- '--inv "\$_inv"' "$here/ctl-account-follow.cand.sh" && echo "OK WIRING uses --inv=" || { echo "WRONG WIRING"; bad=1; }
for id in -x -v --ask -e; do
  o=$(python3 -I -B "$here/a1577_produce.py" --ask A-PRIVATE-NONE --outdir "$(mktemp -d)" --inv="$id" 2>&1); rc=$?
  case "$o" in *"expected one argument"*|*"unrecognized"*) echo "WRONG PARSE id=$id (option-parsed): $o" | head -c 200; bad=1;; *) echo "OK PARSE id=$id taken as value (rc=$rc)";; esac
done
[ $bad = 0 ] && echo A1577-INV-EQ-CONTROLS-PASS || echo FAILED
