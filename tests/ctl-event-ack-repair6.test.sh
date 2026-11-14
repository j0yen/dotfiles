#!/usr/bin/env bash
# A1296 package 3 repair 6 (review-6 F3, F4, F5 and the residual pins F6 F7 R1 R2 R6-1 R6-2): a failing outcome of ANY route never acks (typed-success ALLOWLIST), the Fable route included;
# a supported explicit typed success still acks exactly once with attempt-bound evidence; a refusal keeps the pending/UNKNOWN delivery's attempt_id and queue file.
# Stubs only (tmux PATH shim, router stub, gated asks-view shim); HOME, queue root and RT_DIR under the test temp dir. BBIN=<bridge> / RBIN=<router> run the same cases against other copies.
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
printf '#!/bin/sh\nif [ ! -e %s/av.seen ]; then : > %s/av.seen; : > %s/av.entered; i=0; while [ ! -e %s/av.release ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done; fi\necho "event:e1"\n' "$T" "$T" "$T" "$T" > "$T/asks-gated"
chmod +x "$T/bin/tmux" "$T/ew" "$T/rt-stub" "$T/asks-view" "$T/asks-gated"
BRD="$T/br"; RTD="$T/rt"
case "$BRD" in "$T"/*) ;; *) echo "queue root outside temp dir"; exit 1;; esac
case "$RTD" in "$T"/*) ;; *) echo "route root outside temp dir"; exit 1;; esac
BBIN="${BBIN:-$B}"; RBIN="${RBIN:-$RTR}"
br() { env -i HOME="$T/home" PATH="$T/bin:$PATH" BR_DIR="$BRD" RT_DIR="$RTD" EW_BIN="$T/ew" TMUX_BIN="$T/bin/tmux" RT_BIN="${RTBIN:-$T/rt-stub}" ASKS_VIEW_BIN="${AVBIN:-$T/asks-view}" CTL_PANE=t:0.0 RETRY_SEC=600 WAIT_MAX_SEC=1 BR_FABLE=0 BR_CYCLES="${BR_CYCLES:-1}" ${BRX:-} bash "$BBIN" "$@"; }
fresh() { rm -rf "$BRD" "$RTD" "$T"/av.* "$T"/held; mkdir -p "$BRD/queue" "$BRD/done" "$RTD/routed" "$RTD/results"; : > "$T/tmux.log"; : > "$T/router.log"; : > "$T/asks-view.out"; }
NOW=$(date +%s)
mkqa() { echo "{\"id\":\"$1\",\"event\":{\"event\":\"${4:-inbox}\",\"detail\":{}},\"created\":$2,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"$3\"}" > "$BRD/queue/$1.json"; }
routea() { echo "{\"id\":\"$1\",\"route\":\"${3:-deterministic}\",\"reason\":\"t\",\"row\":\"${4:-}\",\"attempt_id\":\"$2\"}" > "$RTD/routed/$1.json"; }
q() { ls "$BRD/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$BRD/done"/*.json 2>/dev/null | wc -l; }
nrec() { ls "$RTD/handled" 2>/dev/null | grep -vc '^\.'; }
receipt() { [ -e "$RTD/handled/$1" ]; }
acklines() { local c; c=$(grep -c " ack $1\( \|\$\)" "$BRD/deliveries.log" 2>/dev/null); echo "${c:-0}"; }
qatt() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt_id") or "")' "$BRD/queue/$1.json" 2>/dev/null; }
runmode() { case "$1" in explicit) br ack "$2" 2>&1;; all) br ack --all 2>&1;; run) BR_CYCLES=1 br run 2>&1;; esac; }
nothing_acked() { [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(q)" = 1 ] && [ "$(acklines e1)" = 0 ]; }
# result file: res <id> <route> <result> <exit-json-or-empty> [extra-json-members]  (attempt A1)
res() { local ex=""; [ -n "$4" ] && ex=",\"exit\":$4"; printf '{"id":"%s","route":"%s","result":"%s"%s,"attempt_id":"A1"%s}' "$1" "$2" "$3" "$ex" "${5:+,$5}" > "$RTD/results/$1.json"; }

# A refused outcome: explicit ack refuses (nonzero), ack --all and run ack nothing, the queue file keeps its attempt_id (no new attempt), resolve records a non-success disposition (no done/, no receipt).
# refcase <name> <cache 0|1> <cache-route> <result> <exit-or-empty> [extra-members]
refcase() {
  local nm="$1" mode rc o
  for mode in explicit all run; do
    fresh; mkqa e1 $NOW A1 timeout; [ "$2" = 1 ] && routea e1 A1 "$3"; res e1 "$3" "$4" "$5" "${6:-}"
    o="$(runmode $mode e1)"; rc=$?
    if [ $mode = explicit ]; then [ "$rc" != 0 ] && nothing_acked && [ "$(qatt e1)" = A1 ] && [ "$(ls "$BRD/queue" | wc -l)" = 1 ]; else nothing_acked && [ "$(qatt e1)" = A1 ] && [ "$(ls "$BRD/queue" | wc -l)" = 1 ]; fi
    chk "$nm: $mode refuses/skips (no done/, no receipt, queue kept, attempt_id A1 kept, no new attempt)" $?
  done
  fresh; mkqa e1 $NOW A1 timeout; [ "$2" = 1 ] && routea e1 A1 "$3"; res e1 "$3" "$4" "$5" "${6:-}"
  o="$(br resolve e1 --disposition abandoned --reason t 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(q)" = 0 ] && python3 -I -c 'import json,glob,sys
fs=glob.glob(sys.argv[1]+"/dispositions/e1*.json"); d=json.load(open(fs[0])); sys.exit(0 if d["success"] is False and d["attempt_id"]=="A1" else 1)' "$BRD"
  chk "$nm: resolve records a non-success disposition (success=false, no done/, no receipt)" $?
}
# An accepted outcome acks exactly once on every route that acks it: one done/, one receipt, one ack line; a repeat adds nothing.
okcase() { # okcase <name> <route> <result> <exit> [row]   (cache present, attempt A1)
  local nm="$1" mode
  for mode in explicit all run; do
    [ "$2" = fable ] && [ $mode != explicit ] && continue   # --all and run never ack a fable id: the consumer's explicit ack only (header)
    fresh; mkqa e1 $NOW A1 timeout; routea e1 A1 "$2" "${5:-}"; res e1 "$2" "$3" "$4" "${5:+\"row\":\"$5\"}"; [ -z "${5:-}" ] || echo "event:e1" > "$T/asks-view.out"
    runmode $mode e1 >/dev/null; runmode $mode e1 >/dev/null
    [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ] && receipt e1 && [ "$(q)" = 0 ] && [ "$(acklines e1)" = 1 ]; chk "$nm: $mode acks exactly once (one done/, one receipt, one ack line)" $?
  done
}

# ============ F4: typed denied / aborted / timeout at exit 0 (and a sibling error key) never ack; only an explicit typed-success type acks (ALLOWLIST) ============
for t in denied aborted timeout cancelled canceled ok success done unknown-type error-row blocked-row refused failed; do
  refcase "F4 det cache, result '$t' exit 0" 1 deterministic "$t" 0
done
refcase "F4 haiku cache, result 'denied' exit 0" 1 haiku denied 0
refcase "F4 det cache, executed exit 0 + sibling error key" 1 deterministic executed 0 '"error":"boom"'
refcase "F4 haiku cache, executed exit 0 + sibling error key" 1 haiku executed 0 '"error":"boom"'
refcase "F4 no cache (result only), result 'aborted' exit 0" 0 deterministic aborted 0
refcase "F4 no cache (result only), executed exit 0 + sibling error key" 0 deterministic executed 0 '"error":"boom"'
refcase "F4 det cache, UNKNOWN status in an exit-0 executed result" 1 deterministic executed 0 '"status":"UNKNOWN"'

# ============ F3: a failing Fable-route outcome never acks ============
refcase "F3 fable result (no cache), blocked-row exit 2" 0 fable blocked-row 2
refcase "F3 fable result (no cache), executed exit 1" 0 fable executed 1
refcase "F3 fable result (no cache), deliver with no exit field" 0 fable deliver ""
refcase "F3 fable cache + result blocked-row exit 2" 1 fable blocked-row 2
refcase "F3 fable cache + result executed exit 1" 1 fable executed 1
refcase "F3 fable cache + result deliver with no exit field" 1 fable deliver ""
refcase "F3 fable cache + result denied exit 0" 1 fable denied 0
refcase "F3 fable cache + result deliver exit 0 + sibling error key" 1 fable deliver 0 '"error":"boom"'
refcase "F3 fable cache + UNKNOWN status in a deliver result" 1 fable deliver 0 '"status":"UNKNOWN"'
refcase "F3 fable result (no cache) UNKNOWN status" 0 fable deliver 0 '"status":"UNKNOWN"'
# the refusal names its reason class (survivor of mutant G: the exit check skipped for the Fable route)
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1 fable; res e1 fable deliver ""; o="$(br ack e1 2>&1)"; printf '%s' "$o" | grep -q 'reason class: invalid-exit'; chk "F3 fable cache + result with no exit field: refusal names reason class invalid-exit" $?
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1 fable; res e1 fable executed 1; o="$(br ack e1 2>&1)"; printf '%s' "$o" | grep -q 'reason class: typed-failure'; chk "F3 fable cache + result exit 1: refusal names reason class typed-failure" $?
# attempt-bound: a fable result of ANOTHER delivery is not this delivery's evidence
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1 fable; printf '{"id":"e1","route":"fable","result":"deliver","exit":0,"attempt_id":"A0"}' > "$RTD/results/e1.json"
br ack e1 >/dev/null 2>&1; rc=$?; [ "$rc" != 0 ] && nothing_acked && [ "$(qatt e1)" = A1 ]; chk "F3 fable cache + result of another attempt: explicit ack refuses (attempt-bound evidence)" $?

# ============ positive controls: a listed typed success keeps truthful attempt-bound evidence and acks exactly once ============
TS="$(sed -n 's/^TYPED_SUCCESS="\(.*\)"$/\1/p' "$B")"
[ -n "$TS" ]; chk "allowlist: the bridge carries a TYPED_SUCCESS list ($TS)" $?
for t in unchanged deliver surfaced-row surfaced-dup continued informational dispatch-owned record executed; do
  case " $TS " in *" $t "*) ok=0;; *) ok=1;; esac; chk "allowlist: '$t' is a listed typed success" $ok
done
for t in $TS; do okcase "control det cache '$t'" deterministic "$t" 0; done
okcase "control haiku cache 'executed'" haiku executed 0
okcase "control det cache 'surfaced-row' with its asks row marker" deterministic surfaced-row 0 R1
for t in deliver executed unchanged; do okcase "control fable cache '$t'" fable "$t" 0; done
# fable: no result at all (the router has not written one) = the consumer's explicit word still acks; pane-delivered (no cache, no result) too
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1 fable; br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ] && [ "$(acklines e1)" = 1 ]; chk "control fable cache, no result file: the consumer's explicit ack still acks once" $?
fresh; mkqa e1 $NOW A1 timeout; br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ]; chk "control pane-delivered (no cache, no result): explicit ack still acks once" $?
# done record keeps the delivery's attempt_id (truthful attempt-bound ack evidence)
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1 fable; res e1 fable deliver 0; br ack e1 >/dev/null 2>&1
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["attempt_id"]=="A1" and d["acked"]>0 else 1)' "$BRD/done/e1.json"; chk "control fable: done/e1.json carries attempt_id A1 and the ack time" $?
# requeued fable delivery: the old attempt's result does not ack the new attempt
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1 fable; res e1 fable deliver 0; br ack e1 >/dev/null 2>&1; br requeue e1 >/dev/null 2>&1; A2=$(qatt e1)
br ack e1 >/dev/null 2>&1; [ -n "$A2" ] && [ "$A2" != A1 ] && [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "control fable: after requeue the stale cache/result of attempt A1 does not ack attempt B (stays queued)" $?

# ============ no drift between the router's success names and the bridge allowlist ============
python3 -I -c 'import re,sys
src=open(sys.argv[1]).read(); ts=set(sys.argv[2].split())
names=set(re.findall(r"\"([a-z][a-z-]*)\"\s*,\s*0\b",src))-{"refused"}   # finish(..., "<result>", 0): the router success names; "refused" at exit 0 is the router`s no-effect outcome and stays a failure name
miss=sorted(n for n in names if n not in ts)
print("router exit-0 names:",sorted(names),"missing from allowlist:",miss); sys.exit(1 if miss or len(names)<5 else 0)' "$RTR" "$TS"; chk "allowlist: every router exit-0 result name (except refused) is listed (no drift)" $?

# ============ R6-1 (O2): the judged-attempt check runs UNDER the queue flock. The asks-view shim starts a lock holder that swaps the queue file to attempt A2 inside its hold; ack --all has judged A1 and must not ack A2 ============
cat > "$T/asks-swap" <<SH
#!/bin/sh
if [ ! -e $T/av.seen ]; then : > $T/av.seen; ( ( flock 9; : > $T/held; sleep 1.5; python3 -I -c "import json;p='$BRD/queue/e1.json';d=json.load(open(p));d['attempt_id']='A2';json.dump(d,open(p,'w'))" ) 9>$BRD/.ack.lock ) >/dev/null 2>&1 & n=0; while [ ! -e $T/held ] && [ \$n -lt 200 ]; do sleep 0.02; n=\$((n+1)); done; fi
echo "event:e1"
SH
chmod +x "$T/asks-swap"
fresh; echo "event:e1" > "$T/asks-view.out"; mkqa e1 $NOW A1 timeout; routea e1 A1 deterministic R1; res e1 deterministic executed 0 '"row":"R1"'
AVBIN="$T/asks-swap" br ack --all >"$T/p1.out" 2>&1
[ -e "$T/held" ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(q)" = 1 ] && [ "$(qatt e1)" = A2 ] && [ ! -e "$BRD/done/e1.json" ]; chk "R6-1 attempt swapped to A2 under the lock after the judgement: A2 is NOT acked on A1's evidence (queue kept, no done/, no receipt)" $?

# ============ R6-2 (O8): judged attempt EMPTY (legacy attempt-less delivery), then acked + requeued as a new attempt in the window: the new attempt is not acked ============
fresh; echo "event:e1" > "$T/asks-view.out"
echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"
echo '{"id":"e1","route":"deterministic","reason":"t","row":"R1"}' > "$RTD/routed/e1.json"; echo '{"id":"e1","route":"deterministic","result":"executed","exit":0}' > "$RTD/results/e1.json"
( AVBIN="$T/asks-gated" br ack --all > "$T/p2.out" 2>&1; echo $? > "$T/p2.rc" ) &
pid=$!; i=0; while [ ! -e "$T/av.entered" ] && [ $i -lt 200 ]; do sleep 0.05; i=$((i+1)); done
[ -e "$T/av.entered" ]; chk "R6-2 harness: the gated asks-view window opened" $?
AVBIN="$T/asks-view" br ack e1 >/dev/null 2>&1; br requeue e1 >/dev/null 2>&1; : > "$T/av.release"; wait $pid
[ "$(q)" = 1 ] && [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ] && [ ! -e "$BRD/done/e1.r1.json" ] && [ -n "$(qatt e1)" ]; chk "R6-2 judged attempt empty, new attempt swapped in: the new attempt stays queued (one done/, one receipt)" $?

# ============ F7 (O14, review-5 X9): the receipt is written AFTER the done record: a crash before the done write leaves no receipt ============
fresh; mkqa e1 $NOW A1 timeout; routea e1 A1; res e1 deterministic executed 0
BRX="BR_CRASH_AT=pre" br ack e1 >/dev/null 2>&1
[ "$(q)" = 1 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ]; chk "F7 crash before the done write: queue kept, no done/, NO receipt (receipt is never written before the done record)" $?
# ============ F7 (O15, review-5 X10): the settle pass finishes EVERY cut-off ack, not only the first queue file ============
fresh; mkdir -p "$RTD/handled"
for i in 1 2; do mkqa e$i $NOW A$i timeout; python3 -I -c "import json;d=json.load(open('$BRD/queue/e$i.json'));d['acked']=1;json.dump(d,open('$BRD/done/e$i.json','w'))"; done
br ack --all >/dev/null 2>&1
[ "$(q)" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 2 ]; chk "F7 two crash leftovers (done + queue, same attempt): ack --all settles both (q=0, d=2, receipts=2)" $?

# ============ F6 (residual, pinned): a done/ record with no receipt and no queue file is NOT repaired (the receipt-restore scan was removed for latency; the head's own order done, receipt, rm cannot produce it) ============
for kind in legacy attempt; do
  fresh; mkdir -p "$RTD/handled"
  if [ $kind = legacy ]; then echo '{"id":"e1","event":{"event":"inbox"},"created":1,"attempts":1,"last_delivery":5,"acked":9}' > "$BRD/done/e1.json"; else echo '{"id":"e1","event":{"event":"inbox"},"created":1,"attempts":1,"last_delivery":5,"attempt_id":"A1","acked":9}' > "$BRD/done/e1.json"; fi
  o1="$(br ack e1 2>&1)"; r1=$(nrec); br ack --all >/dev/null 2>&1; r2=$(nrec); BR_CYCLES=1 br run >/dev/null 2>&1; r3=$(nrec)
  printf '%s' "$o1" | grep -q 'already acked' && [ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$r3" = 0 ]; chk "F6 residual pin ($kind): done record without receipt and without a queue file says 'already acked' and restores no receipt (ack/--all/run)" $?
done

# ============ R1 (residual, pinned): no routed cache + a success result: explicit ack accepts, ack --all skips it (rc 1), run acks nothing ============
fresh; mkqa e1 $NOW A1 timeout; res e1 deterministic executed 0; br ack e1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ]; chk "R1 residual pin: result without cache, explicit ack accepts (one done/, one receipt)" $?
fresh; mkqa e1 $NOW A1 timeout; res e1 deterministic executed 0; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && nothing_acked; chk "R1 residual pin: result without cache, ack --all skips it (rc 1, nothing acked)" $?
fresh; mkqa e1 $NOW A1 timeout; res e1 deterministic executed 0; BR_CYCLES=1 br run >/dev/null 2>&1
nothing_acked; chk "R1 residual pin: result without cache, run acks nothing" $?

# ============ F5 / R2: the router's bridge handshake keys on the parent's argv, not on a substring of the command line ============
mkdir -p "$T/fake" "$T/rt5"; echo '{"id":"e1","event":{"event":"timeout","detail":{}},"created":1,"attempts":0,"last_delivery":0,"attempt_id":"A1"}' > "$T/q5.json"
rtrun() { env -i HOME="$T/home" PATH="$T/bin:$PATH" RT_DIR="$T/rt5/$1" ${2:-} bash "$RBIN" route "$T/q5.json" >/dev/null 2>"$T/e5.$1"; echo $?; }
cat > "$T/wrap-plain.sh" <<EOS
rc=\$(RT_DIR=$T/rt5/p bash $RBIN route $T/q5.json >/dev/null 2>$T/e5.p; echo \$?); echo \$rc > $T/rc.plain
EOS
cat > "$T/fake/ctl-event-bridge.sh" <<EOS
rc=\$(RT_DIR=$T/rt5/a bash $RBIN route $T/q5.json >/dev/null 2>$T/e5.a; echo \$?); echo \$rc > $T/rc.old
rc=\$(BR_PROTO=attempt-v1 RT_DIR=$T/rt5/b bash $RBIN route $T/q5.json >/dev/null 2>$T/e5.b; echo \$?); echo \$rc > $T/rc.new
EOS
env -i HOME="$T/home" PATH="$T/bin:$PATH" bash "$T/wrap-plain.sh"; [ "$(cat "$T/rc.plain")" = 0 ]; chk "F5 control: a plain parent routes (rc 0)" $?
env -i HOME="$T/home" PATH="$T/bin:$PATH" bash -c "# wrapper for ctl-event-bridge.sh (a comment only)
. $T/wrap-plain.sh; :"; [ "$(cat "$T/rc.plain")" = 0 ]; chk "F5 a non-bridge parent whose command line merely mentions ctl-event-bridge.sh still routes (rc 0), no bridge-version-mismatch" $?
env -i HOME="$T/home" PATH="$T/bin:$PATH" bash "$T/fake/ctl-event-bridge.sh"
[ "$(cat "$T/rc.old")" = 3 ] && grep -q 'bridge-version-mismatch' "$T/e5.a"; chk "F5 control: a parent that IS a ctl-event-bridge.sh without BR_PROTO gets rc 3 bridge-version-mismatch" $?
[ "$(cat "$T/rc.new")" = 0 ]; chk "F5 control: a ctl-event-bridge.sh parent announcing BR_PROTO=attempt-v1 routes (rc 0)" $?
mkdir -p "$T/ren"; cp "$T/fake/ctl-event-bridge.sh" "$T/ren/renamed-bridge.sh"; rm -f "$T/rc.old"; env -i HOME="$T/home" PATH="$T/bin:$PATH" bash "$T/ren/renamed-bridge.sh"
[ "$(cat "$T/rc.old")" = 0 ]; chk "R2 residual pin: an older bridge under another file name is not detected (the router routes it, rc 0)" $?

echo "ctl-event-ack-repair6 test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
