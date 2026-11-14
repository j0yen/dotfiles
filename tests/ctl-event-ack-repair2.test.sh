#!/usr/bin/env bash
# A1296 package 3 repair 2 (review-2 N1-N5): typed success is the only evidence (exit 0, no typed failure), a requeued id is a distinct delivery with its own
# evidence/done entry/receipt, a held-unreadable id is never moved to done/ by an explicit ack, run mode prints the refusal reason class.
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


mkq2() { echo "{\"id\":\"$1\",\"event\":{\"event\":\"inbox\",\"detail\":{\"gen\":\"$3\"}},\"created\":$2,\"attempts\":0,\"last_delivery\":0${4:+,\"attempt_id\":\"$4\"}}" > "$BRD/queue/$1.json"; }
nrec() { ls "$RTD/handled" 2>/dev/null | grep -vc '^\.'; }
old_done() { echo '{"id":"e1","event":{"event":"inbox","detail":{"gen":"old"}},"created":1,"attempts":0,"last_delivery":0,"attempt_id":"A0","acked":5}' > "$BRD/done/e1.json"; mkdir -p "$RTD/handled"; : > "$RTD/handled/e1"; }

# --- N1: only the typed success shape (exit 0, no typed-failure result) is evidence; 4 exits x 2 results x explicit / --all / run
for ex in 2 1 75 -1; do for res in executed blocked-row; do
  for mode in explicit all run; do
    fresh; mkq e1; route e1 haiku; rraw e1 "{\"id\":\"e1\",\"route\":\"haiku\",\"result\":\"$res\",\"exit\":$ex}"
    case "$mode" in explicit) err="$(br ack e1 2>&1 >/dev/null)"; rc=$?;; all) err="$(br ack --all 2>&1 >/dev/null)"; rc=$?;; run) err="$(BR_CYCLES=2 br run 2>&1 >/dev/null)"; rc=1;; esac
    [ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && ! receipt e1 && [ -n "$err" ]; chk "N1 exit=$ex result=$res via $mode: not done, no receipt, reason stated" $?
  done
done; done
fresh; mkq e1; route e1 haiku; rraw e1 '{"id":"e1","route":"haiku","result":"blocked-row","exit":0}'
br ack e1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(q)" = 1 ]; chk "N1 typed-failure result token with exit 0 is still not success" $?
fresh; mkq e1; route e1 haiku; rraw e1 '{"id":"e1","route":"haiku","result":"blocked-row","exit":2}'; err="$(br ack e1 2>&1 >/dev/null)"; printf '%s' "$err" | grep -q 'typed-failure'; chk "N1 explicit ack names the reason class typed-failure" $?
for mode in explicit all run; do
  fresh; mkq e1; route e1 haiku; good e1 haiku
  case "$mode" in explicit) br ack e1 >/dev/null 2>&1;; all) br ack --all >/dev/null 2>&1;; run) BR_CYCLES=2 br run >/dev/null 2>&1;; esac
  [ "$(d)" = 1 ] && [ "$(q)" = 0 ] && receipt e1 && [ "$(acklines e1)" = 1 ]; chk "N1 success shape (exit 0, executed) is done once with a receipt via $mode" $?
done

# --- N2: a requeued id is a distinct delivery: own evidence, own done entry, own receipt, never deleted, never counted on the old entry
fresh; old_done; mkq2 e1 100 new
br ack e1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 2 ] && grep -q '"old"' "$BRD/done/e1.json" && grep -qh '"new"' "$BRD"/done/*.json && ! grep -q '"new"' "$BRD/done/e1.json"; chk "N2/Q1 requeued id, explicit ack (pane class): new payload gets its own done entry + receipt, old entry untouched" $?
fresh; old_done; sed -i 's/"attempt_id":"A0",//' "$BRD/done/e1.json"; mkq2 e1 100 new; : > "$RTD/handled/e1"; rm -f "$RTD/handled/e1"   # legacy done entry (no attempt_id): repair 3 restores the receipt of an attempt-bearing done entry, so this fixture stays legacy
br ack e1 >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 1 ]; chk "N2/Q4 done/ entry with no receipt + unseen requeue: the new queue file is acked on its own, not deleted unrecorded (d=2, 1 receipt)" $?
# stale det evidence on a requeue (repair 3: the evidence belongs to the previous attempt A0, the requeued delivery is attempt A2; evidence is bound by attempt_id, not mtime)
stale() { fresh; old_done; mkq2 e1 "$(date +%s)" new A2; route e1 deterministic; good e1; sed -i 's/}$/,"attempt_id":"A0"}/' "$RTD/results/e1.json" "$RTD/routed/e1.json"; touch -d '2001-01-01' "$RTD/results/e1.json" "$RTD/routed/e1.json"; }
stale; err="$(br ack e1 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && grep -q '"new"' "$BRD/queue/e1.json" && [ -n "$err" ]; chk "N2/Q1 requeued det id with stale (pre-payload) evidence: explicit ack refused, new payload kept queued" $?
stale; err="$(br ack --all 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 1 ] && grep -q '"new"' "$BRD/queue/e1.json"; chk "N2/Q2 requeued det id with stale evidence: ack --all skips it (not counted on the old entry), exit 1" $?
stale; BR_CYCLES=2 br run >/dev/null 2>&1; [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "N2 requeued det id with stale evidence: run leaves it queued" $?
fresh_ev() { sed -i 's/"attempt_id":"A0"/"attempt_id":"A2"/' "$RTD/results/e1.json" "$RTD/routed/e1.json"; }
stale; fresh_ev; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(q)" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 2 ] && grep -q '"old"' "$BRD/done/e1.json" && grep -qh '"new"' "$BRD"/done/*.json; chk "N2/Q-lock requeued id with fresh evidence, --all: second done entry + second receipt, old entry content preserved" $?
stale; fresh_ev; BR_CYCLES=1 br run >/dev/null 2>&1; [ "$(q)" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 2 ]; chk "N2 requeued id with fresh evidence, run: acked as its own delivery (d=2, 2 receipts)" $?
stale; fresh_ev; br ack e1 >/dev/null 2>&1; l="$(grep -c ' ack e1' "$BRD/deliveries.log")"; br ack e1 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(d)" = 2 ] && [ "$(nrec)" = 2 ] && [ "$(grep -c ' ack e1' "$BRD/deliveries.log")" = "$l" ]; chk "N2 same-delivery re-ack after the requeue ack: idempotent (exit 0, no third entry/receipt/ack line)" $?
dups=0; trials=30; bad=0
for i in $(seq 1 $trials); do
  fresh; old_done; mkq2 e1 100 new
  for k in 1 2 3; do br ack e1 > "$T/o$k" 2>&1 & done; wait
  [ "$(cat "$T"/o1 "$T"/o2 "$T"/o3 | grep -c '^acked 1$')" = 1 ] || dups=$((dups+1))
  { [ "$(d)" = 2 ] && [ "$(q)" = 0 ] && [ "$(nrec)" = 2 ]; } || bad=$((bad+1))
done
echo "N2 requeue concurrency: trials=$trials dup=$dups bad=$bad"
[ "$dups" = 0 ] && [ "$bad" = 0 ]; chk "N2 3 concurrent acks of one requeued delivery x $trials: exactly one 'acked 1', one new done entry, one new receipt" $?
dups2=0
for i in $(seq 1 $trials); do
  fresh; mkq e1; route e1 deterministic; good e1
  br ack e1 >/dev/null 2>&1 & br ack --all >/dev/null 2>&1 & BR_CYCLES=1 br run >/dev/null 2>&1 & wait
  { [ "$(acklines e1)" = 1 ] && [ "$(d)" = 1 ] && [ "$(nrec)" = 1 ]; } || dups2=$((dups2+1))
done
[ "$dups2" = 0 ]; chk "N2 same-event ack + --all + run concurrently x $trials: 0 duplicate ack lines, one done/, one receipt (dup_trials=$dups2)" $?

# --- N1/N4 schema residue: exit false / 0.0 / "0" and a non-token result are not success (mutants E, M)
for body in '{"id":"e1","route":"haiku","result":"executed","exit":false}' '{"id":"e1","route":"haiku","result":"executed","exit":0.0}' '{"id":"e1","route":"haiku","result":"executed","exit":"0"}' '{"id":"e1","route":"haiku","result":"Executed!","exit":0}' '{"id":"e1","route":"haiku","result":"","exit":0}'; do
  fresh; mkq e1; route e1 haiku; rraw e1 "$body"; err="$(br ack e1 2>&1 >/dev/null)"; rc=$?
  br ack --all >/dev/null 2>&1; r2=$?
  [ "$rc" != 0 ] && [ "$r2" != 0 ] && [ "$(d)" = 0 ] && [ "$(q)" = 1 ] && [ -n "$err" ]; chk "N1 not the typed success shape: ${body:30:60}" $?
done
# a requeued id whose queue file lacks a usable created stamp cannot prove its evidence is newer
fresh; old_done; echo '{"id":"e1","event":{"event":"inbox","detail":{"gen":"new"}},"attempts":0,"last_delivery":0}' > "$BRD/queue/e1.json"; route e1 deterministic; good e1
br ack e1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 1 ]; chk "N2 requeued det id with no created stamp: evidence cannot be bound to the payload, refused" $?

# --- N3: a held-unreadable id (held marker, no cache, no result) is never moved to done/ by an explicit ack
fresh; mkq e1; mkdir -p "$RTD/held"; : > "$RTD/held/e1"
err="$(br ack e1 2>&1 >/dev/null)"; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && ! receipt e1 && [ -e "$RTD/held/e1" ] && printf '%s' "$err" | grep -q 'held-unreadable'; chk "N3 held-unreadable explicit ack: refused (held-unreadable), queued, no done/, no receipt, marker kept" $?
fresh; mkq e1; BR_CYCLES=3 br run >/dev/null 2>&1; br ack e1 >/dev/null 2>&1; [ $? != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "N3 id the router held (exit 75) through run: explicit ack refused afterwards" $?

# --- N5: run mode names the refused id and reason class on stderr; a first-time held id gets its route.err line
rerr() { BR_CYCLES=1 br run 2>&1 >/dev/null; }
fresh; mkq e1; route e1 deterministic; rraw e1 '{"id":"e1","route":"deterministic","result":"UNKNOWN","exit":0}'; o="$(rerr)"; printf '%s' "$o" | grep -q 'e1' && printf '%s' "$o" | grep -q 'UNKNOWN'; chk "N5 run: UNKNOWN id -> stderr names e1 and UNKNOWN" $?
fresh; mkq e1; route e1 deterministic; o="$(rerr)"; printf '%s' "$o" | grep -q 'e1' && printf '%s' "$o" | grep -q 'missing'; chk "N5 run: no result -> stderr names e1 and missing" $?
fresh; mkq e1; route e1 haiku; rraw e1 '{"id":"e1","route":"haiku","result":"blocked-row","exit":2}'; o="$(rerr)"; printf '%s' "$o" | grep -q 'e1' && printf '%s' "$o" | grep -q 'typed-failure'; chk "N5 run: blocked-row exit 2 -> stderr names e1 and typed-failure" $?
fresh; mkq e1; o="$(rerr)"; printf '%s' "$o" | grep -q 'e1' && printf '%s' "$o" | grep -q 'held-unreadable'; chk "N5 run: router exit 75 -> stderr names e1 and held-unreadable" $?
grep -q 'held id e1: router exit 75' "$BRD/route.err"; chk "N5 first-time held id gets its route.err line" $?
echo "ctl-event-ack-repair2 test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
