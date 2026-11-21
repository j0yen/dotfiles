#!/usr/bin/env bash
# A1296 package 3 repair 4 (review-4 R4-1..R4-7): no-cache evidence rules, typed-vs-printed attempt ids (Z9b), bounded settle work, the requeue path,
# the router header contract (N1), router/bridge version handshake, legacy leftover recovery.
# Stubs only (tmux PATH shim, router stubs; the real router only on a `timeout` event, no model call); HOME, queue root and RT_DIR under the test temp dir.
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
printf '#!/bin/sh\necho "$@" >> %s/router.log\nexit 1\n' "$T" > "$T/rt-fail"
printf '#!/bin/sh\ncat %s/asks-view.out 2>/dev/null\nexit 0\n' "$T" > "$T/asks-view"
chmod +x "$T/bin/tmux" "$T/ew" "$T/rt-stub" "$T/rt-fail" "$T/asks-view"
BRD="$T/br"; RTD="$T/rt"
case "$BRD" in "$T"/*) ;; *) echo "queue root outside temp dir"; exit 1;; esac
case "$RTD" in "$T"/*) ;; *) echo "route root outside temp dir"; exit 1;; esac
BBIN="${BBIN:-$B}"
br() { env -i HOME="$T/home" PATH="$T/bin:$PATH" BR_DIR="$BRD" RT_DIR="$RTD" EW_BIN="$T/ew" TMUX_BIN="$T/bin/tmux" RT_BIN="${RTBIN:-$T/rt-stub}" ASKS_VIEW_BIN="$T/asks-view" CTL_PANE=t:0.0 RETRY_SEC=600 WAIT_MAX_SEC=1 BR_FABLE=0 BR_CYCLES="${BR_CYCLES:-1}" bash "$BBIN" "$@"; }
fresh() { rm -rf "$BRD" "$RTD"; mkdir -p "$BRD/queue" "$BRD/done" "$RTD/routed" "$RTD/results"; : > "$T/tmux.log"; : > "$T/router.log"; : > "$T/asks-view.out"; }
NOW=$(date +%s)
mkqa() { echo "{\"id\":\"$1\",\"event\":{\"event\":\"${4:-inbox}\",\"detail\":{}},\"created\":$2,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"$3\"}" > "$BRD/queue/$1.json"; }
routea() { echo "{\"id\":\"$1\",\"route\":\"${3:-deterministic}\",\"reason\":\"t\",\"row\":\"\",\"attempt_id\":\"$2\"}" > "$RTD/routed/$1.json"; }
gooda() { echo "{\"id\":\"$1\",\"route\":\"${3:-deterministic}\",\"result\":\"executed\",\"exit\":0,\"attempt_id\":\"$2\"}" > "$RTD/results/$1.json"; }
rraw() { printf '%s' "$2" > "$RTD/results/$1.json"; }
q() { ls "$BRD/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$BRD/done"/*.json 2>/dev/null | wc -l; }
nrec() { ls "$RTD/handled" 2>/dev/null | grep -vc '^\.'; }
receipt() { [ -e "$RTD/handled/$1" ]; }
ndisp() { ls "$BRD/dispositions"/*.json 2>/dev/null | wc -l; }
sends() { local c; c=$(grep -c -- '-l ctl-event' "$T/tmux.log" 2>/dev/null); echo "${c:-0}"; }
rcalls() { wc -l < "$T/router.log"; }
runmode() { case "$1" in explicit) br ack "$2" 2>&1;; all) br ack --all 2>&1;; run) BR_CYCLES=1 br run 2>&1;; esac; }

# --- R4-1: no routed cache + a result file: the same evidence rules as the cache-present path (the router wrote the result, then crashed before the cache)
SHAPES="blocked-row-exit2 error-row-exit4 unknown-status typed-name-exit0 exit1 nested-unknown"
mkres() { case $1 in
  blocked-row-exit2) rraw e1 '{"id":"e1","route":"deterministic","result":"blocked-row","exit":2,"attempt_id":"A1"}';;
  error-row-exit4) rraw e1 '{"id":"e1","route":"haiku","result":"error-row","exit":4,"attempt_id":"A1"}';;
  unknown-status) rraw e1 '{"id":"e1","route":"deterministic","result":"executed","status":"UNKNOWN","attempt_id":"A1"}';;
  typed-name-exit0) rraw e1 '{"id":"e1","route":"deterministic","result":"refused","exit":0,"attempt_id":"A1"}';;
  exit1) rraw e1 '{"id":"e1","route":"deterministic","result":"row-created","exit":1,"attempt_id":"A1"}';;
  nested-unknown) rraw e1 '{"id":"e1","route":"deterministic","result":"executed","exit":0,"detail":{"x":["Unknown"]},"attempt_id":"A1"}';;
  esac; }
for k in $SHAPES; do
  for rt in present absent; do
    rtb="$T/rt-fail"; [ $rt = absent ] && rtb=/nonexistent
    for how in explicit all run; do
      fresh; mkqa e1 $NOW A1; mkres $k; o="$(RTBIN=$rtb runmode $how e1)"
      [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ]; chk "R4-1 no cache, $k, router $rt, $how: refused, queued, no done, no receipt" $?
    done
    fresh; mkqa e1 $NOW A1; mkres $k; RTBIN=$rtb br ack e1 2>&1 | grep -q 'refused e1'; chk "R4-1 no cache, $k, router $rt: explicit ack names the refusal on stderr" $?
  done
  fresh; mkqa e1 $NOW A1; mkres $k; o="$(br resolve e1 --disposition operator-handled --reason "fixture $k" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && [ "$(ndisp)" = 1 ] && [ "$(rcalls)" = 0 ] && [ "$(sends)" = 0 ]; chk "R4-1 no cache, $k: resolve ACCEPTS it (disposition record, no done/, no receipt, no router call, no pane send)" $?
  python3 -I -c 'import json,sys,glob
r=json.load(open(glob.glob(sys.argv[1]+"/dispositions/*.json")[0]))
assert r["id"]=="e1" and r["success"] is False and r["replayed"] is False and r["disposition"]=="operator-handled" and r["attempt_id"]=="A1"' "$BRD" 2>/dev/null; chk "R4-1 no cache, $k: the disposition record is success=false, never a handled receipt" $?
  br ack e1 >/dev/null 2>&1; br ack --all >/dev/null 2>&1; BR_CYCLES=2 br run >/dev/null 2>&1; [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ]; chk "R4-1 no cache, $k: after resolve, ack/--all/run never produce done/ or a receipt" $?
done
# attempt-bound: a result of another attempt (or none) with no cache is not evidence either
fresh; mkqa e1 $NOW A1; rraw e1 '{"id":"e1","route":"deterministic","result":"executed","exit":0,"attempt_id":"B9"}'; br ack e1 >/dev/null 2>&1; br ack --all >/dev/null 2>&1; [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "R4-1 no cache, success shape of a FOREIGN attempt: refused" $?
fresh; mkqa e1 $NOW A1; rraw e1 'not json{'; br ack e1 >/dev/null 2>&1; [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "R4-1 no cache, unparseable result file: refused" $?
# controls: pane-delivered id (no result, no cache) keeps the consumer's explicit ack; a success result of this attempt with no cache keeps being acked (brief Amendment 2: result = mechanical evidence, the cache is only the router's index); fable route result is the consumer's word
fresh; mkqa e1 $NOW A1; br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ] && receipt e1; chk "R4-1 control: pane-delivered id (no result, no cache): explicit ack accepted" $?
fresh; mkqa e1 $NOW A1; gooda e1 A1; br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ] && receipt e1; chk "R4-1 control: success result of this attempt, no cache: explicit ack accepted (retained behaviour)" $?
fresh; mkqa e1 $NOW A1; gooda e1 A1; br ack --all >/dev/null 2>&1; [ "$(d)" = 0 ]; chk "R4-1 control: ack --all still never acks a no-cache id (needs the routed cache)" $?
fresh; mkqa e1 $NOW A1; rraw e1 '{"id":"e1","route":"fable","result":"deliver","exit":0,"attempt_id":"A1"}'; br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ]; chk "R4-1 control: fable-route result, no cache: the consumer's explicit ack accepted" $?
# the real router, result written then the cache lost (crash window), success shape: acked once; and the failing shape written by hand is refused
fresh; mkqa e1 $NOW A1 timeout; RT_DIR="$RTD" "$RTR" route "$BRD/queue/e1.json" >/dev/null 2>&1; rm -f "$RTD/routed/e1.json"; [ -f "$RTD/results/e1.json" ]; chk "R4-1 real router wrote results/e1.json (cache removed to model the crash window)" $?
python3 -I -c 'import json,sys
p=sys.argv[1]; r=json.load(open(p)); r["result"]="blocked-row"; r["exit"]=2; json.dump(r,open(p,"w"))' "$RTD/results/e1.json"; br ack e1 >/dev/null 2>&1; [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "R4-1 real-router result turned blocked-row exit 2, cache lost: explicit ack refused" $?

# --- R4-2: Z9b. The typed attempt comparison in evidence_ok (:108) is the single guard for a cache attempt_id that PRINTS the same but differs in JSON type
fresh; mkqa e1 123 $NOW; echo '{"id":"e1","route":"deterministic","reason":"t","row":"","attempt_id":123}' > "$RTD/routed/e1.json"; gooda e1 123; br ack e1 >/dev/null 2>&1; [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "R4-2/Z9b cache attempt_id 123 (JSON int) vs queue/result \"123\": explicit ack refused" $?
fresh; mkqa e1 123 $NOW; echo '{"id":"e1","route":"deterministic","reason":"t","row":"","attempt_id":123}' > "$RTD/routed/e1.json"; gooda e1 123; br ack --all >/dev/null 2>&1; [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "R4-2/Z9b same, ack --all: refused" $?
fresh; echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"; echo '{"id":"e1","route":"deterministic","reason":"t","row":"","attempt_id":""}' > "$RTD/routed/e1.json"; echo '{"id":"e1","route":"deterministic","result":"executed","exit":0}' > "$RTD/results/e1.json"
br ack e1 >/dev/null 2>&1; [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "R4-2/Z9b legacy queue (no attempt_id) + cache attempt_id \"\": explicit ack refused" $?
br ack --all >/dev/null 2>&1; [ "$(d)" = 0 ]; chk "R4-2/Z9b same, ack --all: refused" $?
fresh; echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"; echo '{"id":"e1","route":"deterministic","reason":"t","row":""}' > "$RTD/routed/e1.json"; echo '{"id":"e1","route":"deterministic","result":"executed","exit":0}' > "$RTD/results/e1.json"
br ack e1 >/dev/null 2>&1; [ "$(d)" = 1 ]; chk "R4-2 control: legacy queue + legacy cache + legacy result (all attempt-less): accepted" $?

# --- R4-3: the settle pass does O(queue) work, not O(done/)
real_py="$(command -v python3)"; printf '#!/bin/sh\necho x >> %s/py.count\nexec %s "$@"\n' "$T" "$real_py" > "$T/bin/python3"; chmod +x "$T/bin/python3"
pyc() { : > "$T/py.count"; "$@" >/dev/null 2>&1; wc -l < "$T/py.count"; }
fresh; c0=$(pyc br ack --all)
for i in $(seq 1 150); do echo "{\"id\":\"old$i\",\"acked\":1}" > "$BRD/done/old$i.json"; echo "{\"id\":\"new$i\",\"acked\":1,\"attempt_id\":\"A$i\"}" > "$BRD/done/new$i.json"; : > "$RTD/handled/.x" 2>/dev/null; mkdir -p "$RTD/handled"; : > "$RTD/handled/new$i"; done
c1=$(pyc br ack --all); [ "$c1" -le "$c0" ]; chk "R4-3 ack --all with 300 done entries (150 legacy w/o receipt, 150 receipted): python starts $c1 <= $c0 (empty done/)" $?
c2=$(pyc br ack nosuchid); c3=$(pyc br resolve nosuchid --disposition abandoned --reason x); rm -rf "$BRD/done"/*; c4=$(pyc br ack nosuchid); c5=$(pyc br resolve nosuchid --disposition abandoned --reason x)
[ "$c2" -le "$c4" ] && [ "$c3" -le "$c5" ]; chk "R4-3 ack <id> and resolve with 300 done entries do the same python work as with none ($c2/$c3 vs $c4/$c5)" $?
fresh; for i in $(seq 1 150); do echo "{\"id\":\"old$i\",\"acked\":1}" > "$BRD/done/old$i.json"; done; mkqa e1 $NOW A1 timeout; c6=$(pyc env RTBIN="$RTR" BR_CYCLES=1 bash -c "$(declare -f br); BBIN='$BBIN' T='$T' BRD='$BRD' RTD='$RTD' br run"); [ "$(d)" = 151 ]; chk "R4-3 run over a large done/ still acks the queued id once" $?
rm -f "$T/bin/python3"
# recovery is not dropped: a SIGKILL at every step boundary still ends with one done, one receipt
for step in pre tmp done rm clear receipt; do
  fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1; BR_CRASH_AT=$step br ack e1 >/dev/null 2>&1; br ack --all >/dev/null 2>&1; br ack e1 >/dev/null 2>&1
  [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && receipt e1 && [ "$(nrec)" = 1 ]; chk "R4-3 crash at '$step': recovery keeps one done + one receipt" $?
done

# --- R4-4: requeue
fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1; br ack e1 >/dev/null 2>&1
cp "$BRD/done/e1.json" "$BRD/queue/e1.json"; o="$(BR_CYCLES=1 br run 2>&1)"
[ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ] && [ "$(rcalls)" = 0 ] && printf '%s' "$o" | grep -q 'ctl-event-bridge.sh requeue e1' && grep -q 'ctl-event-bridge.sh requeue e1' "$BRD/deliveries.log" && ls "$BRD/recovered"/e1.* >/dev/null 2>&1; chk "R4-4 a done/ record copied back into queue/ is not redelivered, and is NOT silent: typed message names the requeue command, deliveries.log line, queue copy kept under recovered/" $?
fresh; mkqa e1 $NOW A1; routea e1 A1; gooda e1 A1; br ack e1 >/dev/null 2>&1; o="$(br requeue e1 2>&1)"; rc=$?
a2="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("attempt_id","")); print(d.get("attempts"), d.get("last_delivery"), "acked" in d)' "$BRD/queue/e1.json" 2>/dev/null | tr '\n' ' ')"
[ "$rc" = 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && printf '%s' "$a2" | grep -qE '^[0-9]+-[0-9a-f]{8} 0 0 False'; chk "R4-4 requeue e1: a new queue file with a NEW attempt_id (attempts 0, no acked field), done/ record kept ($a2)" $?
o="$(br ack e1 2>&1)"; [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "R4-4 the requeued delivery cannot be acked on the old attempt's evidence" $?
br requeue e1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(q)" = 1 ]; chk "R4-4 requeue of an id that is already queued: refused" $?
o="$(br requeue nosuchid 2>&1)"; rc=$?; [ $rc != 0 ] && printf '%s' "$o" | grep -q '^unknown id: nosuchid'; chk "R4-4 requeue of an unknown id: refused with the typed 'unknown id' message" $?
br requeue 'bad id!' >/dev/null 2>&1; [ $? != 0 ]; chk "R4-4 requeue with an invalid id: refused" $?
newa="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["attempt_id"])' "$BRD/queue/e1.json")"; routea e1 "$newa"; gooda e1 "$newa"; br ack e1 >/dev/null 2>&1
[ "$(q)" = 0 ] && [ "$(d)" = 2 ] && receipt e1 && receipt e1.r1 && [ "$(nrec)" = 2 ]; chk "R4-4 requeue + fresh evidence of the new attempt: acked as its own delivery (done/e1.r1.json + receipt e1.r1)" $?
fresh; mkqa e1 $NOW A1 timeout; RTBIN="$RTR" BR_CYCLES=1 br run >/dev/null 2>&1; br requeue e1 >/dev/null 2>&1; RTBIN="$RTR" BR_CYCLES=2 br run >/dev/null 2>&1
[ "$(q)" = 0 ] && [ "$(d)" = 2 ] && receipt e1.r1; chk "R4-4 real router: requeue is routed afresh (new attempt) and acked as e1.r1" $?
fresh; mkqa e1 $NOW A1; routea e1 A1; rraw e1 '{"id":"e1","route":"deterministic","result":"blocked-row","exit":2,"attempt_id":"A1"}'; br resolve e1 --disposition abandoned --reason x >/dev/null 2>&1; br requeue e1 >/dev/null 2>&1
[ "$(q)" = 1 ] && [ "$(d)" = 0 ] && [ "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("attempt_id"))' "$BRD/queue/e1.json")" != A1 ]; chk "R4-4 a resolved id can be requeued: new attempt, still no done/ entry" $?

# crash-leftover recovery does not depend on the evidence files: done + queue of the same attempt, the router's cache still there but its result lost or a typed failure
for k in lost failed; do for how in explicit all run; do
  fresh; mkqa e1 $NOW A1; routea e1 A1; [ $k = failed ] && rraw e1 '{"id":"e1","route":"deterministic","result":"blocked-row","exit":2,"attempt_id":"A1"}'
  echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0,\"attempt_id\":\"A1\",\"acked\":$NOW}" > "$BRD/done/e1.json"
  runmode $how e1 >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && receipt e1 && [ ! -e "$BRD/done/e1.r1.json" ]; chk "R4-3 leftover (done + queue, same attempt) with the evidence $k, $how: the original ack is completed without evidence (settle runs before the evidence check)" $?
done; done

# --- R4-5: router header states the bridge's N1 rule
hdr="$(sed -n 1,30p "$RTR")"
printf '%s' "$hdr" | grep -q 'exit 0 AND a typed success result'; chk "R4-5 router header: consumer success = exit 0 and a typed success result" $?
printf '%s' "$hdr" | grep -q 'every nonzero exit'; chk "R4-5 router header: every nonzero exit / typed failure is not-done, owned ask or not" $?
printf '%s' "$hdr" | grep -q 'resolve'; chk "R4-5 router header: names resolve as the exit for a failure-held id" $?
! printf '%s' "$hdr" | grep -q 'exit field + owned ask\|and, when work could not$'; chk "R4-5 router header no longer defines success as 'exit field + owned ask'" $?

# --- R4-6: version handshake, four combinations (real router, timeout event)
GR="${P3_BASE_REPO:-$root}"   # a git clone that contains the base commit (default: this repo; the mutation runner points it at the real worktree)
git -C "$GR" show ae079b2b5a7a3d0ec3131a1abc10a0f5e68598f9:.local/bin/ctl-event-bridge.sh > "$T/base-bridge.sh" 2>/dev/null && mkdir -p "$T/basebin" "$T/headbin" && cp "$T/base-bridge.sh" "$T/basebin/ctl-event-bridge.sh" \
 && git -C "$GR" show ae079b2b5a7a3d0ec3131a1abc10a0f5e68598f9:.local/bin/ctl-event-route.sh > "$T/basebin/ctl-event-route.sh" && cp "$B" "$T/headbin/ctl-event-bridge.sh" && cp "$RTR" "$T/headbin/ctl-event-route.sh" && chmod +x "$T/basebin"/* "$T/headbin"/* && have_base=1 || have_base=0
combo() { # $1 bridge dir, $2 router dir
  fresh; mkqa e1 $NOW A1 timeout; echo '{"id":"e1","event":{"event":"timeout","detail":{}},"created":'$NOW',"attempts":0,"last_delivery":0}' > "$BRD/queue/e1.json"; [ "$1" = headbin ] && mkqa e1 $NOW A1 timeout
  rm -f "$BRD/route.err"; BBIN="$T/$1/ctl-event-bridge.sh" RTBIN="$T/$2/ctl-event-route.sh" BR_CYCLES=2 br run >/dev/null 2>&1; }
if [ $have_base = 1 ]; then
  combo headbin headbin; [ "$(d)" = 1 ] && [ "$(q)" = 0 ] && [ "$(sends)" = 0 ] && receipt e1; chk "R4-6 head bridge + head router: acked once, no pane send" $?
  combo basebin basebin; [ "$(d)" = 1 ] && [ "$(q)" = 0 ]; chk "R4-6 base bridge + base router: base behaviour (acked)" $?
  combo headbin basebin; [ "$(d)" = 0 ] && [ "$(q)" = 1 ] && [ "$(sends)" = 0 ] && [ "$(nrec)" = 0 ] && grep -q 'router-version-mismatch' "$BRD/route.err"; chk "R4-6 head bridge + base router: fails closed with a typed message (route.err router-version-mismatch), nothing acked, nothing sent to the pane" $?
  combo basebin headbin; [ "$(d)" = 0 ] && [ "$(nrec)" = 0 ] && grep -q 'bridge-version-mismatch' "$BRD/route.err"; chk "R4-6 base bridge + head router: the router refuses to route for a bridge that does not announce attempt-v1 (route.err bridge-version-mismatch), nothing acked" $?
else echo "SKIP R4-6 combinations (base commit ae079b2b not available in this clone)"; fi
# the handshake never blocks direct router calls or a stub router
fresh; mkqa e1 $NOW A1 timeout; RT_DIR="$RTD" "$RTR" route "$BRD/queue/e1.json" >/dev/null 2>&1; [ -f "$RTD/routed/e1.json" ]; chk "R4-6 control: a direct router call (caller is not a bridge) still routes" $?
fresh; mkqa e1 $NOW A1; RTBIN="$T/rt-fail" BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(sends)" = 1 ]; chk "R4-6 control: a stub router without the router header is not handshake-checked (unrouted id still delivered fail-safe)" $?

# a caller named ctl-event-bridge.sh that announces another protocol (or none) gets no routing; attempt-v1 routes (the handshake is exact)
mkdir -p "$T/fakebr"; printf '#!/bin/bash\nexport RT_DIR="$1"; shift\nif [ -n "${BRP:-}" ]; then export BR_PROTO="$BRP"; fi\n"$RTR_BIN" route "$@"\nexit $?\n' > "$T/fakebr/ctl-event-bridge.sh"; chmod +x "$T/fakebr/ctl-event-bridge.sh"
for bp in "" attempt-v0 x; do fresh; mkqa e1 $NOW A1 timeout; o="$(RTR_BIN="$RTR" BRP="$bp" bash "$T/fakebr/ctl-event-bridge.sh" "$RTD" "$BRD/queue/e1.json" 2>&1)"; rc=$?
  [ $rc = 3 ] && printf '%s' "$o" | grep -q 'bridge-version-mismatch' && [ ! -e "$RTD/routed/e1.json" ]; chk "R4-6 router called by a bridge announcing BR_PROTO='${bp:-<none>}': refused (exit 3, bridge-version-mismatch), nothing routed" $?
done
fresh; mkqa e1 $NOW A1 timeout; RTR_BIN="$RTR" BRP=attempt-v1 bash "$T/fakebr/ctl-event-bridge.sh" "$RTD" "$BRD/queue/e1.json" >/dev/null 2>&1; [ -f "$RTD/routed/e1.json" ]; chk "R4-6 router called by a bridge announcing attempt-v1: routes" $?
# the bridge's own handshake needs only the router file (no process call): a real-router copy with the protocol line removed is a mismatch, with it a match
mkdir -p "$T/rv"; grep -v '^# ctl-event-proto:' "$RTR" > "$T/rv/ctl-event-route.sh"; chmod +x "$T/rv/ctl-event-route.sh"; fresh; mkqa e1 $NOW A1 timeout
o="$(RTBIN="$T/rv/ctl-event-route.sh" BR_CYCLES=1 br run 2>&1)"; [ "$(d)" = 0 ] && [ "$(sends)" = 0 ] && grep -q 'router-version-mismatch' "$BRD/route.err" && printf '%s' "$o" | grep -q 'router-version-mismatch'; chk "R4-6 a router copy without the 'ctl-event-proto: attempt-v1' line: head bridge fails closed (typed route.err line, nothing acked, nothing sent)" $?
cp "$RTR" "$T/rv/ctl-event-route.sh"; fresh; mkqa e1 $NOW A1 timeout; RTBIN="$T/rv/ctl-event-route.sh" BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(d)" = 1 ] && [ "$(sends)" = 0 ]; chk "R4-6 the same copy with the protocol line: acked once" $?

# --- R4-7: legacy leftover (done/<id>.json beside queue/<id>.json, neither with attempt_id)
legacy_leftover() { fresh; echo "{\"id\":\"e1\",\"event\":{\"event\":\"timeout\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"; echo "{\"id\":\"e1\",\"event\":{\"event\":\"timeout\",\"detail\":{}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0,\"acked\":$NOW}" > "$BRD/done/e1.json"; }
for how in explicit all run; do
  legacy_leftover; o="$(runmode $how e1)"; o="$(runmode $how e1)"
  [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && [ ! -e "$BRD/done/e1.r1.json" ] && receipt e1 && [ "$(nrec)" = 1 ] && [ "$(rcalls)" = 0 ]; chk "R4-7 legacy done+queue leftover, $how: original ack completed (queue removed, receipt for the ORIGINAL, no done/e1.r1, no router call)" $?
done
legacy_leftover; RTBIN="$RTR" BR_CYCLES=2 br run >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && receipt e1 && [ ! -e "$RTD/handled/e1.r1" ] && [ ! -e "$RTD/routed/e1.json" ]; chk "R4-7 legacy leftover through run + REAL router: no second routing effect (no routed cache written), receipt e1 only" $?
legacy_leftover; echo "{\"id\":\"e1\",\"event\":{\"event\":\"timeout\",\"detail\":{}},\"created\":$((NOW+500)),\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"; BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "R4-7 control: an attempt-less queue file whose payload DIFFERS from the done record is still a new delivery (kept queued)" $?

legacy_leftover; echo "{\"id\":\"e1\",\"event\":{\"event\":\"inbox\",\"detail\":{\"other\":1}},\"created\":$NOW,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/e1.json"; BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && ! receipt e1; chk "R4-7 control: same id and created but a DIFFERENT event payload is not the done delivery (kept queued, no receipt invented)" $?

echo "ctl-event-ack-repair4 test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
