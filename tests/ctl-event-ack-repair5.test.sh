#!/usr/bin/env bash
# A1296 package 3 repair 5 (review-5 F1, F2): the router-version-mismatch pause covers acks (F1); the evidence decision and the ack are atomic per delivery (F2).
# Stubs only (tmux PATH shim, router stubs, a gated asks-view shim); HOME, queue root and RT_DIR under the test temp dir. BBIN=<bridge> runs the same cases against another bridge copy.
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
# gated asks-view: the FIRST call announces itself (av.entered) and blocks until av.release exists (bounded 30 s); later calls answer at once. No timing luck: the test opens the window, acts inside it, then closes it.
printf '#!/bin/sh\nif [ ! -e %s/av.seen ]; then : > %s/av.seen; : > %s/av.entered; i=0; while [ ! -e %s/av.release ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done; fi\necho "event:e1"\n' "$T" "$T" "$T" "$T" > "$T/asks-gated"
chmod +x "$T/bin/tmux" "$T/ew" "$T/rt-stub" "$T/asks-view" "$T/asks-gated"
BRD="$T/br"; RTD="$T/rt"
case "$BRD" in "$T"/*) ;; *) echo "queue root outside temp dir"; exit 1;; esac
case "$RTD" in "$T"/*) ;; *) echo "route root outside temp dir"; exit 1;; esac
BBIN="${BBIN:-$B}"
br() { env -i HOME="$T/home" PATH="$T/bin:$PATH" BR_DIR="$BRD" RT_DIR="$RTD" EW_BIN="$T/ew" TMUX_BIN="$T/bin/tmux" RT_BIN="${RTBIN:-$T/rt-stub}" ASKS_VIEW_BIN="${AVBIN:-$T/asks-view}" CTL_PANE=t:0.0 RETRY_SEC=600 WAIT_MAX_SEC=1 BR_FABLE=0 BR_CYCLES="${BR_CYCLES:-1}" ${BRX:-} bash "$BBIN" "$@"; }
fresh() { rm -rf "$BRD" "$RTD" "$T"/av.*; mkdir -p "$BRD/queue" "$BRD/done" "$RTD/routed" "$RTD/results"; : > "$T/tmux.log"; : > "$T/router.log"; : > "$T/asks-view.out"; }
NOW=$(date +%s)
mkqa() { echo "{\"id\":\"$1\",\"event\":{\"event\":\"${4:-inbox}\",\"detail\":{}},\"created\":$2,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"$3\"}" > "$BRD/queue/$1.json"; }
routea() { echo "{\"id\":\"$1\",\"route\":\"${3:-deterministic}\",\"reason\":\"t\",\"row\":\"${4:-}\",\"attempt_id\":\"$2\"}" > "$RTD/routed/$1.json"; }
gooda() { echo "{\"id\":\"$1\",\"route\":\"${3:-deterministic}\",\"result\":\"executed\",\"exit\":0,\"attempt_id\":\"$2\"}" > "$RTD/results/$1.json"; }
q() { ls "$BRD/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$BRD/done"/*.json 2>/dev/null | wc -l; }
nrec() { ls "$RTD/handled" 2>/dev/null | grep -vc '^\.'; }
receipt() { [ -e "$RTD/handled/$1" ]; }
qatt() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt_id") or "")' "$BRD/queue/$1.json" 2>/dev/null; }
runmode() { case "$1" in explicit) br ack "$2" 2>&1;; all) br ack --all 2>&1;; run) BR_CYCLES=1 br run 2>&1;; esac; }

# --- F1: while the router lacks `# ctl-event-proto: attempt-v1` (half-install) acks are paused: explicit ack and ack --all refuse (nonzero, no done/, no receipt, the mismatch reason), resolve stays
mkdir -p "$T/rv"; grep -v '^# ctl-event-proto:' "$RTR" > "$T/rv/ctl-event-route.sh"; chmod +x "$T/rv/ctl-event-route.sh"
for shape in attempt legacy; do
  for how in explicit all; do
    fresh; if [ $shape = attempt ]; then mkqa e1 $NOW A1 timeout; else echo "{\"id\":\"e1\",\"event\":{\"event\":\"timeout\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"; fi
    o="$(RTBIN="$T/rv/ctl-event-route.sh" runmode $how e1)"; rc=$?
    [ "$how" = explicit ] || rc=$(RTBIN="$T/rv/ctl-event-route.sh" br ack --all >/dev/null 2>&1; echo $?)
    [ "$rc" != 0 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(q)" = 1 ] && printf '%s' "$o" | grep -q 'router-version-mismatch'; chk "F1 half-install ($shape queue file), ack $how: refused (nonzero, no done/, no receipt, queue kept, mismatch reason printed)" $?
  done
done
fresh; mkqa e1 $NOW A1 timeout; RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1; RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1
[ "$(d)" = 0 ] && [ "$(nrec)" = 0 ]; chk "F1 half-install: a repeated explicit ack stays refused (no done/, no receipt)" $?
# an id with a routed cache + good result under the mismatch is still not acked by hand or by --all
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1; gooda e1 A1
RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1; rc1=$?; RTBIN="$T/rv/ctl-event-route.sh" br ack --all >/dev/null 2>&1; rc2=$?
[ "$rc1" != 0 ] && [ "$rc2" != 0 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(q)" = 1 ]; chk "F1 half-install: ack e1 and ack --all of an id with a result and a cache are refused too" $?
# an already-acked id: the pause covers every ack call, nothing is written
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1; gooda e1 A1; br ack e1 >/dev/null 2>&1; n0=$(d)
RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(d)" = "$n0" ] && [ "$(nrec)" = 1 ]; chk "F1 half-install: ack of an already-acked id is refused as well (no write)" $?
# resolve stays available as the operator exit: disposition record, queue file kept under resolved/, no done/, no receipt
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1; echo '{"id":"e1","route":"deterministic","result":"blocked-row","exit":2,"attempt_id":"A1"}' > "$RTD/results/e1.json"   # a typed-failure id: the case resolve exists for
o="$(RTBIN="$T/rv/ctl-event-route.sh" br resolve e1 --disposition operator-handled --reason "half-install" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(q)" = 0 ] && ls "$BRD/resolved"/e1*.json >/dev/null 2>&1 && ls "$BRD/dispositions"/e1*.json >/dev/null 2>&1; chk "F1 half-install: resolve still works (disposition + resolved/, no done/, no receipt)" $?
# controls: a matching router, a custom stub router (outside the handshake) and BR_ROUTE=0 keep the old behaviour; the pause lifts when the router is fixed
fresh; mkqa e1 $NOW A1 timeout; cp "$RTR" "$T/rv/ctl-event-route.sh"
RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ] && receipt e1; chk "F1 control: with the matching router the same explicit ack of a pane-delivered id is accepted" $?
fresh; mkqa e1 $NOW A1 timeout; br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ] && receipt e1; chk "F1 control: a stub router outside the handshake does not pause acks" $?
grep -v '^# ctl-event-proto:' "$RTR" > "$T/rv/ctl-event-route.sh"
fresh; mkqa e1 $NOW A1 timeout; BRX="BR_ROUTE=0" RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ] && receipt e1; chk "F1 control: BR_ROUTE=0 (routing disabled, router never consulted) does not pause acks" $?
fresh; mkqa e1 $NOW A1 timeout; RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1
cp "$RTR" "$T/rv/ctl-event-route.sh"; br ack e1 >/dev/null 2>&1; RTBIN="$T/rv/ctl-event-route.sh" br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ]; chk "F1 control: after the router is fixed the held id is acked normally" $?

# --- F2: the evidence decision and the ack are atomic per delivery. Window = the (gated) asks-view row-marker lookup inside evidence_ok; inside it the id is acked and requeued as attempt B
toctou() { # <mode: all|run|explicit>
  local mode=$1 pid rc i
  fresh; echo "event:e1" > "$T/asks-view.out"; mkqa e1 $NOW A1; routea e1 A1 deterministic R1; gooda e1 A1
  ( AVBIN="$T/asks-gated" runmode $mode e1 > "$T/p1.out"; echo $? > "$T/p1.rc" ) &
  pid=$!
  i=0; while [ ! -e "$T/av.entered" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
  [ -e "$T/av.entered" ] || { : > "$T/av.release"; wait $pid; return 9; }   # harness error: the window never opened
  if [ $mode = explicit ]; then   # the explicit ack holds the queue lock across its evidence check: the requeue waits for it
    ( br requeue e1 > "$T/p3.out" 2>&1 ) & local rp=$!; sleep 0.4; : > "$T/av.release"; wait $pid; wait $rp
  else
    AVBIN="$T/asks-view" br ack e1 > "$T/p2.out" 2>&1; br requeue e1 > "$T/p3.out" 2>&1; : > "$T/av.release"; wait $pid
  fi
  return 0
}
for mode in all run; do
  toctou $mode; h=$?
  [ $h = 0 ]; chk "F2 harness ($mode): the gated asks-view window opened" $?
  A2=$(qatt e1)
  [ "$(d)" = 1 ] && [ ! -e "$BRD/done/e1.r1.json" ] && [ "$(nrec)" = 1 ] && receipt e1 && [ ! -e "$RTD/handled/e1.r1" ] && [ "$(q)" = 1 ] && [ -n "$A2" ] && [ "$A2" != A1 ]; chk "F2 ack --all/run ($mode): requeued attempt B is NOT acked on attempt A's evidence (one done/, one receipt, B stays queued)" $?
  if [ $mode = all ]; then [ "$(cat "$T/p1.rc" 2>/dev/null)" = 1 ] && grep -q 'skipped' "$T/p1.out"; chk "F2 ack --all: exits 1 and names the skipped id when the attempt changed under it" $?; fi
  # attempt B then needs its own evidence: with it, B is acked as its own delivery
  if [ -n "$A2" ]; then routea e1 "$A2" deterministic R1; gooda e1 "$A2"; AVBIN="$T/asks-view" br ack --all >/dev/null 2>&1; [ "$(d)" = 2 ] && [ -e "$BRD/done/e1.r1.json" ] && receipt e1.r1 && [ "$(q)" = 0 ]; chk "F2 ($mode): attempt B is acked once it has its own evidence (done/e1.r1.json + receipt e1.r1)" $?; fi
done
toctou explicit; h=$?
[ $h = 0 ]; chk "F2 harness (explicit): the gated asks-view window opened" $?
A2=$(qatt e1)
[ "$(d)" = 1 ] && receipt e1 && [ "$(nrec)" = 1 ] && [ "$(q)" = 1 ] && [ -n "$A2" ] && [ "$A2" != A1 ] && [ "$(cat "$T/p1.rc" 2>/dev/null)" = 0 ]; chk "F2 explicit ack <id>: evidence check and ack share one lock hold (A acked, the racing requeue waits and then queues B unacked)" $?

echo "ctl-event-ack-repair5 test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
