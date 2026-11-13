#!/usr/bin/env bash
# A1296 package 3 repair 1: explicit `ack <id>` needs the same consumer evidence as the automatic path, a typed result schema fails closed
# (UNKNOWN in any form is never evidence), the result id is bound to the event id, same-event acks are idempotent under concurrency,
# and regressions for the route_pending gate, the exit field, the held check in --all and the pane prompt text.
# Stubs only (tmux PATH shim, router stub); HOME, queue root and RT_DIR under the test temp dir.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
B="$root/.local/bin/ctl-event-bridge.sh"
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
br() { env -i HOME="$T/home" PATH="$T/bin:$PATH" BR_DIR="$BRD" RT_DIR="$RTD" EW_BIN="$T/ew" TMUX_BIN="$T/bin/tmux" RT_BIN="$T/rt-stub" ASKS_VIEW_BIN="$T/asks-view" CTL_PANE=t:0.0 RETRY_SEC=600 WAIT_MAX_SEC=1 BR_FABLE=0 BR_CYCLES="${BR_CYCLES:-1}" bash "$B" "$@"; }
fresh() { rm -rf "$BRD" "$RTD"; mkdir -p "$BRD/queue" "$BRD/done" "$RTD/routed" "$RTD/results"; : > "$T/tmux.log"; : > "$T/router.log"; : > "$T/asks-view.out"; }
mkq() { echo "{\"id\":\"$1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":1,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/$1.json"; }
route() { echo "{\"id\":\"$1\",\"route\":\"$2\",\"reason\":\"t\",\"row\":\"${3:-}\"}" > "$RTD/routed/$1.json"; }
rraw() { printf '%s' "$2" > "$RTD/results/$1.json"; }   # raw result body
good() { rraw "$1" "{\"id\":\"$1\",\"route\":\"${2:-deterministic}\",\"result\":\"executed\",\"exit\":0}"; }
q() { ls "$BRD/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$BRD/done"/*.json 2>/dev/null | wc -l; }
sends() { local c; c=$(grep -c -- '-l ctl-event' "$T/tmux.log" 2>/dev/null); echo "${c:-0}"; }
acklines() { local c; c=$(grep -c " ack $1\$" "$BRD/deliveries.log" 2>/dev/null); echo "${c:-0}"; }
receipt() { [ -e "$RTD/handled/$1" ]; }

# --- F1: explicit ack refuses every no-evidence shape: not done, no receipt, non-zero, a stated reason on stderr
shape() { # name route result-body|-none-|-held-  [cache-route]
  local name="$1" rt="$2" body="$3"
  fresh; mkq e1; route e1 "$rt"
  case "$body" in -none-) ;; -held-) good e1; mkdir -p "$RTD/held"; : > "$RTD/held/e1";; *) rraw e1 "$body";; esac
  err="$(br ack e1 2>&1 >/dev/null)"; rc=$?
  [ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && ! receipt e1 && [ -n "$err" ]; chk "F1 explicit ack refused: $name (rc=$rc)" $?
}
shape "det, result missing" deterministic -none-
shape "det, result malformed" deterministic 'not json {'
shape "det, result {}" deterministic '{}'
shape "det, result without exit" deterministic '{"id":"e1","route":"deterministic","result":"executed"}'
shape "det, result UNKNOWN" deterministic '{"id":"e1","route":"deterministic","result":"UNKNOWN","exit":0}'
shape "det, foreign id" deterministic '{"id":"OTHER","route":"deterministic","result":"executed","exit":0}'
shape "det, wrong route in result" deterministic '{"id":"e1","route":"haiku","result":"executed","exit":0}'
shape "det, held with valid evidence" deterministic -held-
shape "haiku, no result" haiku -none-
shape "route=error cache with a result" error '{"id":"e1","route":"error","result":"error-row","exit":4}'
fresh; mkq e1; echo 'garbage' > "$RTD/routed/e1.json"; good e1; br ack e1 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "F1 explicit ack refused: malformed routed cache (rc=$rc)" $?
fresh; mkq e1; route e1 deterministic; good e1; echo '{"id":"e1","route":"deterministic","result":"executed","exit":0,"row":"x"}' > /dev/null
route e1 deterministic r9; br ack e1 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ]; chk "F1 explicit ack refused: cache names a row whose marker is not in the ledger view (rc=$rc)" $?
echo "event:e1 row" > "$T/asks-view.out"; br ack e1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(d)" = 1 ]; chk "F1 explicit ack accepted: row marker present in the ledger view" $?
# positives stay
fresh; mkq e1; route e1 haiku; good e1 haiku; br ack e1 >/dev/null 2>&1; [ $? = 0 ] && [ "$(d)" = 1 ] && receipt e1 && [ "$(acklines e1)" = 1 ]; chk "F1 explicit ack with full evidence (haiku): done/ once + receipt" $?
fresh; mkq p1; route p1 fable; br ack p1 >/dev/null 2>&1; [ $? = 0 ] && [ "$(d)" = 1 ]; chk "F1 pane-delivered id: explicit ack still the consumer evidence" $?
fresh; mkq u1; br ack u1 >/dev/null 2>&1; [ $? = 0 ] && [ "$(d)" = 1 ]; chk "F1 unrouted id (router absent, legacy path): explicit ack accepted" $?
fresh; mkq p1; route p1 fable; mkdir -p "$RTD/held"; : > "$RTD/held/p1"; br ack p1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(q)" = 1 ]; chk "F1 held marker beside a fable cache: explicit ack refused" $?
fresh; mkq k1; mkdir -p "$RTD/held"; : > "$RTD/held/k1"; br ack k1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(d)" = 0 ] && [ "$(q)" = 1 ] && [ -e "$RTD/held/k1" ]; chk "F1 held-unreadable id (no cache, router exit 75): explicit ack refused, never moved to done/ (brief item 3)" $?
fresh; mkq u1; err="$(br ack --all 2>&1 >/dev/null)"; printf '%s' "$err" | grep -q 'ack each by id'; [ $? != 0 ] && printf '%s' "$err" | grep -q u1; chk "F1 --all skip message names the id and does not suggest the per-id bypass" $?

# --- F2: typed schema, UNKNOWN in any form is never done (explicit and --all)
u() { # name body
  fresh; mkq e1; route e1 deterministic; rraw e1 "$2"
  br ack e1 >/dev/null 2>&1; r1=$?; a1="$(d)"
  br ack --all >/dev/null 2>&1; r2=$?
  [ "$r1" != 0 ] && [ "$r2" != 0 ] && [ "$a1" = 0 ] && [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "F2 not valid evidence: $1" $?
}
u "lowercase unknown" '{"id":"e1","route":"deterministic","result":"unknown","exit":0}'
u "mixed-case Unknown" '{"id":"e1","route":"deterministic","result":"Unknown","exit":0}'
u "padded UNKNOWN" '{"id":"e1","route":"deterministic","result":" UNKNOWN ","exit":0}'
u "nested status UNKNOWN" '{"id":"e1","route":"deterministic","result":{"status":"UNKNOWN"},"exit":0}'
u "top-level status UNKNOWN" '{"id":"e1","route":"deterministic","result":"executed","status":"UNKNOWN","exit":0}'
u "UNKNOWN in a list" '{"id":"e1","route":"deterministic","result":["UNKNOWN"],"exit":0}'
u "UNKNOWN in outcome" '{"id":"e1","route":"deterministic","result":"executed","outcome":{"k":"unknown"},"exit":0}'
u "exit as string" '{"id":"e1","route":"deterministic","result":"executed","exit":"0"}'
u "exit as boolean" '{"id":"e1","route":"deterministic","result":"executed","exit":true}'
u "exit null" '{"id":"e1","route":"deterministic","result":"executed","exit":null}'
u "exit float" '{"id":"e1","route":"deterministic","result":"executed","exit":0.5}'
u "result not a string" '{"id":"e1","route":"deterministic","result":3,"exit":0}'
u "top-level array" '[{"id":"e1","result":"executed","exit":0}]'
fresh; mkq e1; route e1 deterministic; rraw e1 '{"id":"e1","route":"deterministic","result":"blocked-row","exit":2,"reason":"why","row":"","ts":"t","model_calls":1,"outcome":["ok"],"kind":"inbox"}'
br ack e1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "F2/N1 router-shaped blocked-row exit 2 (extra router keys) is a typed failure: not evidence" $?
fresh; mkq e1; route e1 deterministic; rraw e1 '{"id":"e1","route":"deterministic","result":"record","exit":0,"reason":"why","row":"","ts":"t","model_calls":1,"outcome":["ok"],"kind":"inbox"}'
br ack e1 >/dev/null 2>&1; [ $? = 0 ] && [ "$(d)" = 1 ]; chk "F2 router-shaped success result (exit 0, extra router keys) is valid evidence" $?

# --- F3: result id bound to the event id; replay of an old result and re-delivery stay possible
fresh; mkq e1; route e1 deterministic; rraw e1 '{"id":"OTHER","route":"deterministic","result":"executed","exit":0}'
br ack e1 >/dev/null 2>&1; r1=$?; br ack --all >/dev/null 2>&1; r2=$?
[ "$r1" != 0 ] && [ "$r2" != 0 ] && [ "$(d)" = 0 ]; chk "F3 result id differs from the acked event id: refused (explicit and --all)" $?
fresh; mkq e1; echo '{"id":"OTHER","route":"deterministic","reason":"t","row":""}' > "$RTD/routed/e1.json"; good e1
br ack e1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(d)" = 0 ]; chk "F3 routed cache id differs from the acked event id: refused" $?
fresh; mkq e1; route e1 deterministic; good e1; touch -d '2001-01-01' "$RTD/results/e1.json" "$RTD/routed/e1.json"
br ack e1 >/dev/null 2>&1; [ $? = 0 ] && [ "$(d)" = 1 ]; chk "F3 no age cap: a 2001-dated result for the right id still counts (replay reuses old results)" $?
fresh; mkq p1; route p1 fable; BR_CYCLES=1 br run; br ack p1 >/dev/null 2>&1; mkq p1; : > "$T/tmux.log"; BR_CYCLES=1 br run
[ "$(sends)" = 1 ] && [ "$(q)" = 1 ]; chk "F3 deliberate re-delivery: a re-queued acked fable id is delivered again" $?

# --- F4: same-event acks idempotent under a lock
fresh; mkq e1; route e1 deterministic; good e1; br ack e1 >/dev/null 2>&1; l0="$(acklines e1)"
out="$(br ack e1 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(acklines e1)" = "$l0" ] && [ "$(q)" = 0 ] && [ "$(d)" = 1 ] && printf '%s' "$out" | grep -q 'already acked'; chk "F4 second ack of the same delivery (no queued file): exit 0, no second ack line, no new done/ entry" $?
dups=0; trials=30; bad=0
for i in $(seq 1 $trials); do
  fresh; mkq e1; route e1 deterministic; good e1
  for k in 1 2 3; do br ack e1 > "$T/o$k" 2>&1 & done; wait
  [ "$(acklines e1)" = 1 ] || dups=$((dups+1))
  [ "$(cat "$T"/o1 "$T"/o2 "$T"/o3 | grep -c '^acked 1$')" = 1 ] || bad=$((bad+1))
  { [ "$(d)" = 1 ] && [ "$(q)" = 0 ]; } || bad=$((bad+1))
done
echo "F4 concurrency: trials=$trials dup_ack_trials=$dups bad=$bad"
[ "$dups" = 0 ] && [ "$bad" = 0 ]; chk "F4 3 concurrent acks x $trials trials: 0 duplicate ack lines, exactly one 'acked 1', one done/ file" $?
dups=0
for i in $(seq 1 $trials); do
  fresh; mkq e1; route e1 deterministic; good e1
  br ack e1 >/dev/null 2>&1 & br ack --all >/dev/null 2>&1 & BR_CYCLES=1 br run >/dev/null 2>&1 & wait
  [ "$(acklines e1)" = 1 ] || dups=$((dups+1))
done
[ "$dups" = 0 ]; chk "F4 ack <id> + ack --all + run concurrently x $trials: 0 duplicate ack lines" $?

# --- F5: regressions for the surviving mutations
for body in -none- '{"id":"e1","route":"deterministic","result":"executed"}' '{"id":"e1","route":"deterministic","result":"UNKNOWN","exit":0}'; do
  fresh; mkq e1; route e1 deterministic; [ "$body" = -none- ] || rraw e1 "$body"
  BR_CYCLES=2 br run; [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && ! receipt e1 && grep -q 'ack-refused e1' "$BRD/deliveries.log"; chk "F5/M5 run (route_pending): det id without valid evidence stays queued, ack-refused logged (${body:0:30})" $?
done
fresh; mkq e1; route e1 haiku; BR_CYCLES=2 br run; [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "F5/M5 run: haiku id without result stays queued" $?
fresh; mkq e1; route e1 deterministic; rraw e1 '{"id":"e1","route":"deterministic","result":"executed"}'; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(d)" = 0 ]; chk "F5/M1b ack --all: result without an exit field is not evidence" $?
fresh; mkq e1; route e1 deterministic; rraw e1 '{"id":"e1","route":"deterministic","result":"executed","exit":""}'; br ack --all >/dev/null 2>&1; [ $? != 0 ] && [ "$(d)" = 0 ]; chk "F5/M1b ack --all: empty exit field is not evidence" $?
fresh; mkq e1; route e1 deterministic; good e1; mkdir -p "$RTD/held"; : > "$RTD/held/e1"; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(d)" = 0 ] && [ "$(q)" = 1 ]; chk "F5/M3c ack --all: held id with otherwise valid evidence stays queued (rc=$rc)" $?
fresh; mkq p1; route p1 fable; BR_CYCLES=1 br run
grep -q -- 'ack <id>' "$T/tmux.log" && ! grep -q -- 'ack --all' "$T/tmux.log"; chk "F5/M6 pane prompt tells the consumer 'ack <id>' and never 'ack --all'" $?
echo "ctl-event-ack-repair1 test: $n checks, dup_ack_trials_total=$dups, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
