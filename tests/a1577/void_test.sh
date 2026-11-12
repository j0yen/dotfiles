#!/bin/bash
# launcher void trap controls (extracted verbatim from ctl-relaunch.cand2.sh), HOME sandboxed
here=$(cd "$(dirname "$0")" && pwd); bad=0
line=$(grep -m1 '^_KILLED=0; _NOVOID=0;' "$here/ctl-relaunch.cand2.sh"); spent=$(grep -m1 'already launched (spent)' "$here/ctl-relaunch.cand2.sh"); mark=$(grep -m1 -o '_KILLED=1; \[ -n "${WM_SUCC_INV:-}" \] && {[^}]*}' "$here/ctl-relaunch.cand2.sh")
run(){ H=$(mktemp -d); HOME=$H WM_SUCC_INV=$1 bash -c "$line; $2" ; echo "$H"; }
H=$(run inv-pre 'exit 76' | tail -1); grep -qx inv-pre "$H/.local/state/aide/succ-void" && echo "OK VOID prelaunch refusal (exit 76 before kill) voids the planned invocation" || { echo "WRONG VOID prelaunch"; bad=1; }
H=$(run inv-post '_KILLED=1; exit 75' | tail -1); [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID post-kill exit leaves the bind live (not voided)" || { echo "WRONG VOID postkill"; bad=1; }
H=$(run "" 'exit 74' | tail -1); [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID no planned invocation: nothing voided" || { echo "WRONG VOID empty"; bad=1; }
# spent live id: an id already launched is refused (77) and NOT voided; the marker is written at the kill step
H=$(mktemp -d); mkdir -p "$H/.local/state/aide"; echo inv-live > "$H/.local/state/aide/succ-launched"
HOME=$H WM_SUCC_INV=inv-live bash -c "note(){ :; }; $line; $spent; exit 0"; rc=$?
[ $rc = 77 ] && [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID spent live id refused 77, bind not voided" || { echo "WRONG VOID spent rc=$rc"; bad=1; }
H=$(mktemp -d); HOME=$H WM_SUCC_INV=inv-new bash -c "$line; $mark; exit 75"; grep -qx inv-new "$H/.local/state/aide/succ-launched" && [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID kill step records launched marker, no void" || { echo "WRONG VOID marker"; bad=1; }
v=$(grep -m1 'is not a single' "$here/ctl-relaunch.cand2.sh")
H=$(mktemp -d); HOME=$H WM_SUCC_INV="liveX liveY" bash -c "note(){ :; }; $line; $v; exit 0"; rc=$?
[ $rc = 78 ] && [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID S2 multi-token invocation refused 78, nothing voided" || { echo "WRONG VOID S2 rc=$rc"; bad=1; }
# H2: the trap is installed before the model-policy / hold-gate early exits; unvalidated or launched ids are never written
first=$(grep -n '^_KILLED=0; _NOVOID=0;' "$here/ctl-relaunch.cand2.sh" | head -1 | cut -d: -f1); pol=$(grep -n 'ctl_model_policy || exit' "$here/ctl-relaunch.cand2.sh" | head -1 | cut -d: -f1); hg=$(grep -n 'hold-gate.sh' "$here/ctl-relaunch.cand2.sh" | head -1 | cut -d: -f1)
[ "$first" -lt "$pol" ] && [ "$first" -lt "$hg" ] && echo "OK VOID H2 trap installed before model-policy and hold-gate exits" || { echo "WRONG VOID H2 order"; bad=1; }
H=$(run inv-h2 'exit 64' | tail -1); grep -qx inv-h2 "$H/.local/state/aide/succ-void" && echo "OK VOID H2 exit 64 voids the planned invocation" || { echo "WRONG VOID H2 64"; bad=1; }
H=$(run $'liveX\nliveY zz' 'exit 1' | tail -1); [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID H2 unvalidated multi-line id never written" || { echo "WRONG VOID H2 multiline"; bad=1; }
H=$(mktemp -d); mkdir -p "$H/.local/state/aide"; echo inv-l2 > "$H/.local/state/aide/succ-launched"; HOME=$H WM_SUCC_INV=inv-l2 bash -c "$line; exit 64"; [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID H2 launched id never voided at an early exit" || { echo "WRONG VOID H2 launched"; bad=1; }
# R12-a: leading-hyphen ids are data, never grep options (trap, spent 77, SPENT)
for hid in -x -v -e -f; do H=$(mktemp -d); mkdir -p "$H/.local/state/aide"; printf "%s\n" "$hid" > "$H/.local/state/aide/succ-launched"; HOME=$H WM_SUCC_INV="$hid" bash -c "$line; exit 64" </dev/null; [ ! -s "$H/.local/state/aide/succ-void" ] && echo "OK VOID R12-a launched id $hid never voided" || { echo "WRONG VOID R12-a trap $hid"; bad=1; }
HOME=$H WM_SUCC_INV="$hid" bash -c "note(){ :; }; $line; $spent; exit 0" </dev/null; rc=$?; [ $rc = 77 ] && echo "OK VOID R12-a spent $hid refused 77" || { echo "WRONG VOID R12-a spent $hid rc=$rc"; bad=1; }; done
H=$(mktemp -d); HOME=$H WM_SUCC_INV=-x bash -c "$line; exit 64" </dev/null; grep -qx -- -x "$H/.local/state/aide/succ-void" && echo "OK VOID R12-a unlaunched -x voided normally" || { echo "WRONG VOID R12-a plain"; bad=1; }
grep -q 'grep -qxF -- "$INV" "$SPENT"' "$here/ctl-relaunch.cand2.sh" && echo "OK VOID R12-a SPENT check uses --" || { echo "WRONG VOID R12-a SPENT"; bad=1; }
[ $bad = 0 ] && echo A1577-VOID-CONTROLS-PASS || echo VOID-FAILED
