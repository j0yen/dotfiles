#!/usr/bin/env bash
# A1296 package 3 repair 3 (review-3 R3-1..R3-5): evidence is bound to a persisted attempt identity (`attempt_id`: written into the queue file by the
# bridge, copied into the router's result, cache and stage files, matched by the bridge), not to file mtimes; ack/receipt recovery is crash-idempotent
# (crash seam BR_CRASH_AT, SIGKILL of the bridge at a step boundary of ackone_locked); a failure-held id has a sanctioned operator exit (`resolve`).
# Stubs only (tmux PATH shim, router stub; the real router only on a `timeout` event, no model call); HOME, queue root and RT_DIR under the test temp dir.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
B="$root/.local/bin/ctl-event-bridge.sh"; RTR="$root/.local/bin/ctl-event-route.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0; f=0
chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
mkdir -p "$T/home" "$T/bin"
printf '#!/bin/sh\necho "$@" >> %s/tmux.log\n[ "$1" = list-panes ] && echo claude\nexit 0\n' "$T" > "$T/bin/tmux"
printf '#!/bin/sh\necho "{\\"event\\":\\"timeout\\"}"\n' > "$T/ew"
printf '#!/bin/sh\necho "$@" >> %s/router.log\nexit 75\n' "$T" > "$T/rt-stub"
printf '#!/bin/sh\ncat %s/asks-view.out 2>/dev/null\nexit 0\n' "$T" > "$T/asks-view"
chmod +x "$T/bin/tmux" "$T/ew" "$T/rt-stub" "$T/asks-view"
BRD="$T/br"; RTD="$T/rt"
case "$BRD" in "$T"/*) ;; *) echo "queue root outside temp dir"; exit 1;; esac
case "$RTD" in "$T"/*) ;; *) echo "route root outside temp dir"; exit 1;; esac
br() { env -i HOME="$T/home" PATH="$T/bin:$PATH" BR_DIR="$BRD" RT_DIR="$RTD" EW_BIN="$T/ew" TMUX_BIN="$T/bin/tmux" RT_BIN="${RTBIN:-$T/rt-stub}" ASKS_VIEW_BIN="$T/asks-view" CTL_PANE=t:0.0 RETRY_SEC=600 WAIT_MAX_SEC=1 BR_FABLE=0 BR_CYCLES="${BR_CYCLES:-1}" BR_CRASH_AT="${BR_CRASH_AT:-}" bash "$B" "$@"; }
fresh() { rm -rf "$BRD" "$RTD"; mkdir -p "$BRD/queue" "$BRD/done" "$RTD/routed" "$RTD/results"; : > "$T/tmux.log"; : > "$T/router.log"; : > "$T/asks-view.out"; }
NOW=$(date +%s)
# queue file instance: id, created, attempt_id [, event kind]
mkqa() { echo "{\"id\":\"$1\",\"event\":{\"event\":\"${4:-inbox}\",\"detail\":{}},\"created\":$2,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"$3\"}" > "$BRD/queue/$1.json"; }
routea() { echo "{\"id\":\"$1\",\"route\":\"${3:-deterministic}\",\"reason\":\"t\",\"row\":\"\",\"attempt_id\":\"$2\"}" > "$RTD/routed/$1.json"; }
gooda() { echo "{\"id\":\"$1\",\"route\":\"${3:-deterministic}\",\"result\":\"executed\",\"exit\":0,\"attempt_id\":\"$2\"}" > "$RTD/results/$1.json"; }
rraw() { printf '%s' "$2" > "$RTD/results/$1.json"; }
q() { ls "$BRD/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$BRD/done"/*.json 2>/dev/null | wc -l; }
nrec() { ls "$RTD/handled" 2>/dev/null | grep -vc '^\.'; }
receipt() { [ -e "$RTD/handled/$1" ]; }
acklines() { local c; c=$(grep -c " ack $1\$" "$BRD/deliveries.log" 2>/dev/null); echo "${c:-0}"; }
ndisp() { ls "$BRD/dispositions"/*.json 2>/dev/null | wc -l; }
sends() { local c; c=$(grep -c -- '-l ctl-event' "$T/tmux.log" 2>/dev/null); echo "${c:-0}"; }
rcalls() { wc -l < "$T/router.log"; }
runmode() { # $1 mode explicit|all|run ; $2 id -> output on stdout/stderr
  case "$1" in explicit) br ack "$2" 2>&1;; all) br ack --all 2>&1;; run) BR_CYCLES=1 br run 2>&1;; esac; }
# first delivery (attempt A1, created long ago) acked, then a requeue of the same id as a NEW delivery (attempt A2, created NOW)
first_then_requeue() { fresh; mkqa e1 $((NOW-1000)) A1; routea e1 A1; gooda e1 A1; br ack e1 >/dev/null 2>&1
  touch -d "@$((NOW-900))" "$RTD/results/e1.json" "$RTD/routed/e1.json"; mkqa e1 $NOW A2; }

# --- R3-1: evidence is bound to the attempt identity, never to mtimes
for how in explicit all run; do
  first_then_requeue; o="$(runmode $how e1)"
  [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ]; chk "R3-1 requeue, previous attempt's evidence left behind (old mtime), $how: refused, queued, one done, one receipt" $?
  first_then_requeue; touch -d "@$((NOW+5))" "$RTD/results/e1.json" "$RTD/routed/e1.json"; o="$(runmode $how e1)"
  [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ]; chk "R3-1 requeue, STALE evidence touched NEWER than created, $how: still refused (mtime is not identity)" $?
  first_then_requeue; routea e1 A2; gooda e1 A2; touch -d "@$((NOW-5))" "$RTD/results/e1.json" "$RTD/routed/e1.json"; o="$(runmode $how e1)"
  [ "$(q)" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 2 ] && receipt e1.r1; chk "R3-1 requeue, genuine fresh evidence (attempt A2) touched OLDER than created, $how: accepted, own done + own receipt" $?
  first_then_requeue; routea e1 A2; gooda e1 A2; o="$(runmode $how e1)"
  [ "$(q)" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 2 ]; chk "R3-1 requeue, fresh evidence, $how: accepted once as its own delivery" $?
  first_then_requeue; routea e1 A2; gooda e1 A1; touch -d "@$((NOW+5))" "$RTD/results/e1.json"; o="$(runmode $how e1)"
  [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "R3-1 requeue, stale RESULT (A1) + fresh cache (A2), $how: refused (both files must carry the attempt)" $?
  first_then_requeue; routea e1 A1; gooda e1 A2; touch -d "@$((NOW+5))" "$RTD/routed/e1.json"; o="$(runmode $how e1)"
  [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "R3-1 requeue, fresh result (A2) + stale CACHE (A1), $how: refused" $?
done
fresh; mkqa e1 $NOW A1; routea e1 B9; gooda e1 B9; o="$(br ack e1 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && printf '%s' "$o" | grep -q 'attempt-mismatch'; chk "R3-1 first delivery with evidence of a foreign attempt: refused (attempt-mismatch)" $?
fresh; mkqa e1 $NOW A1; routea e1 A1; rraw e1 '{"id":"e1","route":"deterministic","result":"executed","exit":0}'; br ack e1 >/dev/null 2>&1; [ "$(d)" = 0 ]; chk "R3-1 result without attempt_id on an attempt-bearing delivery: refused" $?
# a legacy requeue (queue file with no attempt identity) cannot be bound to any evidence on the explicit/--all paths
fresh; echo '{"id":"e1","acked":1,"attempt_id":"A0"}' > "$BRD/done/e1.json"; echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"
routea e1 A0; gooda e1 A0; br ack e1 >/dev/null 2>&1; [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "R3-1 requeue with no attempt identity in the queue file: refused on explicit ack" $?
# the bridge stamps a new delivery with an attempt id and the real router carries it (timeout event, no model call)
fresh; printf '#!/bin/sh\nl=$(head -n1 %s/ev); if [ -n "$l" ]; then sed -i 1d %s/ev; echo "$l"; else echo {\\"event\\":\\"timeout\\"}; fi\n' "$T" "$T" > "$T/ew2"; chmod +x "$T/ew2"
echo '{"event":"inbox","detail":{}}' > "$T/ev"
env -i HOME="$T/home" PATH="$T/bin:$PATH" BR_DIR="$BRD" RT_DIR="$RTD" EW_BIN="$T/ew2" TMUX_BIN="$T/bin/tmux" RT_BIN="$T/rt-stub" CTL_PANE=t:0.0 WAIT_MAX_SEC=1 BR_CYCLES=1 bash "$B" run >/dev/null 2>&1
a="$(python3 -I -c 'import json,sys,glob; print(json.load(open(glob.glob(sys.argv[1]+"/queue/*.json")[0])).get("attempt_id",""))' "$BRD")"; [ -n "$a" ] && printf '%s' "$a" | grep -qE '^[0-9]+-[0-9a-f]{8}$'; chk "R3-1 queue_event records an attempt_id (epoch-8hex) in the queue file" $?
# REAL router, requeue with a new attempt: new route + new result + new cache carrying the new attempt, the previous attempt archived, no stale replay
fresh; rm -f "$T/ev"; mkqa e1 $NOW A1 timeout
RTBIN="$RTR" BR_CYCLES=1 br run >/dev/null 2>&1
[ "$(d)" = 1 ] && [ "$(q)" = 0 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt_id"))' "$RTD/results/e1.json")" = A1 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt_id"))' "$RTD/routed/e1.json")" = A1 ]; chk "R3-1 real router, first delivery: result and cache carry attempt A1, acked once" $?
mkqa e1 $((NOW+1)) A2 timeout
for i in 1 2 3; do RTBIN="$RTR" BR_CYCLES=1 br run >/dev/null 2>&1; done
[ "$(d)" = 2 ] && [ "$(q)" = 0 ] && [ "$(nrec)" = 2 ] && receipt e1.r1 && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt_id"))' "$RTD/results/e1.json")" = A2 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt_id"))' "$RTD/routed/e1.json")" = A2 ]; chk "R3-1 real router, genuine requeue (attempt A2): re-routed (no stale cache replay), result+cache carry A2, acked as its own delivery without any touch" $?
ls "$RTD/attempts/e1" 2>/dev/null | grep -q A1; chk "R3-1 real router: the previous attempt's cache/result are archived under attempts/e1/A1, not served or deleted" $?
fresh; mkqa e1 $NOW A1 timeout; RTBIN="$RTR" BR_CYCLES=1 br run >/dev/null 2>&1; cp "$RTD/routed/e1.json" "$T/c1"; mkqa e1 $NOW A1 timeout
RT_DIR="$RTD" "$RTR" route "$BRD/queue/e1.json" > "$T/replay" 2>/dev/null; [ "$(cat "$T/replay")" = "$(cat "$T/c1")" ]; chk "R3-1 real router: the same attempt replays its cache byte for byte (replay stays idempotent)" $?

# --- R3-2: crash-idempotent ack/receipt recovery (state-based: done + queue of the same attempt; and SIGKILL at every step boundary)
fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1
echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"A1\",\"acked\":$NOW}" > "$BRD/done/e1.json"
for how in explicit all run; do
  fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1
  echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"A1\",\"acked\":$NOW}" > "$BRD/done/e1.json"
  runmode $how e1 >/dev/null; runmode $how e1 >/dev/null
  [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ ! -e "$BRD/done/e1.r1.json" ] && receipt e1 && [ ! -e "$RTD/handled/e1.r1" ] && [ "$(nrec)" = 1 ]; chk "R3-2 done + queue file of the SAME attempt (crash after done write), restart via $how: queue removed, original receipt e1 written, no e1.r1 done or receipt" $?
done
for step in pre tmp done rm clear receipt; do
  for how in explicit all run; do
    fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1
    BR_CRASH_AT=$step br ack e1 >/dev/null 2>&1; crc=$?
    [ "$crc" != 0 ] && [ "$(acklines e1)" = 0 ]; chk "R3-2 crash seam: SIGKILL at step '$step' kills the ack mid-flight (rc=$crc, no ack line yet)" $?
    runmode $how e1 >/dev/null; runmode $how e1 >/dev/null
    [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ -e "$BRD/done/e1.json" ] && [ ! -e "$BRD/done/e1.r1.json" ] && receipt e1 && [ "$(nrec)" = 1 ] && [ "$(acklines e1)" -le 1 ] && ! grep -q 'delivery=r1' "$BRD/deliveries.log" 2>/dev/null; chk "R3-2 crash at '$step', restart via $how: one done/e1.json, original receipt e1, no second done/receipt (q=$(q) d=$(d) receipts=$(nrec))" $?
    mkqa e1 $((NOW+1)) A2; routea e1 A2; gooda e1 A2; br ack e1 >/dev/null 2>&1
    [ "$(d)" = 2 ] && [ -e "$BRD/done/e1.r1.json" ] && receipt e1 && receipt e1.r1 && [ "$(nrec)" = 2 ] && [ "$(q)" = 0 ]; chk "R3-2 after crash '$step' recovery: a genuine new delivery (A2) is distinct: its own done/e1.r1.json and receipt e1.r1" $?
  done
done
fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1; BR_CRASH_AT=done BR_CYCLES=1 br run >/dev/null 2>&1; crc=$?
[ "$crc" != 0 ] && [ "$(d)" = 1 ] && [ "$(q)" = 1 ]; chk "R3-2 crash seam inside run (step done): run is killed with done + queue present" $?
BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && receipt e1 && [ "$(nrec)" = 1 ]; chk "R3-2 run restart after that crash completes the original ack (no second done)" $?

# --- R3-3: operator disposition for failure-held ids
mk_fail() { fresh; mkqa e1 $NOW A1; routea e1 A1 haiku; rraw e1 "{\"id\":\"e1\",\"route\":\"haiku\",\"result\":\"$1\",\"exit\":$2,\"attempt_id\":\"A1\"}"; }
mk_fail blocked-row 2
o="$(br resolve e1 --disposition operator-handled --reason "row opened by hand" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(ndisp)" = 1 ] && [ "$(rcalls)" = 0 ] && [ "$(sends)" = 0 ] && ls "$BRD/resolved"/*.json >/dev/null 2>&1; chk "R3-3 resolve a typed-failure id: disposition record written, queue file moved to resolved/ (kept), NO done/, NO handled receipt, no router call, no pane send" $?
python3 -I -c 'import json,sys,glob
r=json.load(open(glob.glob(sys.argv[1]+"/dispositions/*.json")[0]))
assert r["id"]=="e1" and r["disposition"]=="operator-handled" and r["reason"]=="row opened by hand" and r["attempt_id"]=="A1" and r["evidence_class"]=="typed-failure" and r["success"] is False and r["replayed"] is False' "$BRD"; chk "R3-3 the disposition record names id, attempt, class, reason, the refusal class it overrode, success=false, replayed=false" $?
br ack e1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(d)" = 0 ] && ! receipt e1; chk "R3-3 after resolve, ack e1 is not a handled/success claim (exit non-zero, no receipt)" $?
br resolve e1 --disposition operator-handled --reason "row opened by hand" >/dev/null 2>&1; [ $? = 0 ] && [ "$(ndisp)" = 1 ]; chk "R3-3 resolve is idempotent (second call: exit 0, no second record)" $?
mk_fail blocked-row 2
o="$(br ack e1 2>&1)"; a1=$?; o2="$(br ack --all 2>&1)"; a2=$?; BR_CYCLES=2 br run >/dev/null 2>&1
[ "$a1" != 0 ] && [ "$a2" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "R3-3 ack, ack --all and run keep refusing a typed-failure id until an operator names it" $?
mk_fail UNKNOWN 0; BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(q)" = 1 ] && [ "$(ndisp)" = 0 ]; chk "R3-3 UNKNOWN stays unresolved by itself (no disposition without an operator)" $?
br resolve e1 --disposition abandoned --reason "named by operator" >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(ndisp)" = 1 ] && [ "$(d)" = 0 ] && ! receipt e1 && [ "$(rcalls)" -le 1 ]; chk "R3-3 UNKNOWN resolved only when the operator names it; not a success receipt, never replayed" $?
mk_fail blocked-row 2; for bad in "--disposition nonsense --reason x" "--disposition abandoned" "--disposition abandoned --reason " "--reason x"; do
  br resolve e1 $bad >/dev/null 2>&1; [ $? != 0 ] && [ "$(q)" = 1 ] && [ "$(ndisp)" = 0 ]; chk "R3-3 resolve with bad arguments ($bad) is refused, queue untouched" $?
done
fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1; o="$(br resolve e1 --disposition abandoned --reason x 2>&1)"; rc=$?; [ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(ndisp)" = 0 ]; chk "R3-3 resolve refuses an id with valid evidence (use ack)" $?
fresh; mkqa e1 $NOW A1; mkdir -p "$RTD/held"; : > "$RTD/held/e1"; br resolve e1 --disposition not-actionable --reason "file gone" >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(ndisp)" = 1 ] && [ ! -e "$RTD/held/e1" ] && [ "$(d)" = 0 ]; chk "R3-3 resolve a held-unreadable id: record written, held marker cleared, not acked" $?
br resolve zzz --disposition abandoned --reason x >/dev/null 2>&1; [ $? != 0 ]; chk "R3-3 resolve an unknown id: refused" $?
# crash between the disposition record and the queue move: recovery finishes the move, one record
mk_fail blocked-row 2; BR_CRASH_AT=disp br resolve e1 --disposition abandoned --reason x >/dev/null 2>&1; crc=$?
[ "$crc" != 0 ] && [ "$(ndisp)" = 1 ] && [ "$(q)" = 1 ]; chk "R3-3 crash seam: SIGKILL between the disposition record and the queue move (record + queue present)" $?
BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(ndisp)" = 1 ] && [ "$(d)" = 0 ] && ! receipt e1; chk "R3-3 run after that crash finishes the move: one record, not acked, no receipt" $?

# --- R3-4: former 'equivalent' mutants N and X
fresh; mkqa e1 $NOW A1; printf '{"id":"e1","route":"deterministic\\n","reason":"t","row":"","attempt_id":"A1"}\n' > "$RTD/routed/e1.json"; rraw e1 '{"id":"e1","result":"executed","exit":0,"attempt_id":"A1"}'
br ack e1 >/dev/null 2>&1; r1=$?; br ack --all >/dev/null 2>&1; [ "$r1" != 0 ] && [ "$(d)" = 0 ]; chk "R3-4/N cache route 'deterministic\\n' + result without a route key is not evidence (explicit and --all)" $?
for c in 1.5 true '"1"' null; do
  first_then_requeue; routea e1 A2; gooda e1 A2
  echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$c,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"A2\"}" > "$BRD/queue/e1.json"
  o="$(br ack e1 2>&1)"; [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && printf '%s' "$o" | grep -q 'reason class: invalid-created'; chk "R3-4/X requeue with created=$c is refused (invalid-created), never a traceback" $?
  printf '%s' "$o" | grep -q Traceback && chk "R3-4/X no traceback for created=$c" 1
done
first_then_requeue; routea e1 A2; gooda e1 A2; echo '{"id":"e1","event":{"event":"inbox","detail":{}},"attempts":0,"last_delivery":0,"attempt_id":"A2"}' > "$BRD/queue/e1.json"
o="$(br ack e1 2>&1)"; [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && printf '%s' "$o" | grep -q 'invalid-created'; chk "R3-4/X requeue with created missing is refused (invalid-created)" $?

# --- R3-5: remaining gaps (mutants Z2, Z3, Z9 of review 3)
fresh; mkqa e1 $NOW A1; routea e1 A1; rraw e1 '{"id":"e1","route":"deterministic","result":"executed","exit":0,"status":"done","attempt_id":"A1"}'; br ack e1 >/dev/null 2>&1; br ack --all >/dev/null 2>&1; [ "$(d)" = 0 ]; chk "R3-5/Z2 a result carrying a status key (even a benign value) is refused" $?
fresh; mkqa e1 $NOW A1; routea e1 A1; rraw e1 '{"id":"e1","route":"deterministic","result":"refused","exit":0,"attempt_id":"A1"}'; o="$(br ack e1 2>&1)"; br ack --all >/dev/null 2>&1; [ "$(d)" = 0 ] && printf '%s' "$o" | grep -q typed-failure; chk "R3-5/Z3 result token 'refused' with exit 0 is refused (typed-failure) via explicit and --all" $?
fresh; mkqa e1 $NOW A1; routea e1 A1; rraw e1 '{"id":"e1","route":"deterministic","result":"executed","exit":0,"attempt_id":"A1"}'; BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(d)" = 1 ]; chk "R3-5 control: the same shape without the status/refused residue is accepted" $?
echo "ctl-event-ack-repair3 test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
