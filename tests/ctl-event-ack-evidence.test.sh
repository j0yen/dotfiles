#!/usr/bin/env bash
# A1144/A1148/A1303 package 3: `ack` needs consumer evidence. Stubs only (tmux PATH shim, router stub), temp HOME, queue root and RT_DIR under the test temp dir.
# deterministic/haiku ids = results/<id>.json with exit + routed cache; pane-delivered (route=fable) ids = an explicit `ack <id>` only; `ack --all` acks the evidenced ids, skips the rest, exits 1.
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
chmod +x "$T/bin/tmux" "$T/ew" "$T/rt-stub"
BRD="$T/br"; RTD="$T/rt"
# seam guard: both roots resolve under the test temp dir before any write
case "$BRD" in "$T"/*) ;; *) echo "queue root outside temp dir"; exit 1;; esac
case "$RTD" in "$T"/*) ;; *) echo "route root outside temp dir"; exit 1;; esac
br() { env -i HOME="$T/home" PATH="$T/bin:$PATH" BR_DIR="$BRD" RT_DIR="$RTD" EW_BIN="$T/ew" TMUX_BIN="$T/bin/tmux" RT_BIN="$T/rt-stub" CTL_PANE=t:0.0 RETRY_SEC=600 WAIT_MAX_SEC=1 BR_FABLE=0 BR_CYCLES="${BR_CYCLES:-1}" bash "$B" "$@"; }
fresh() { rm -rf "$BRD" "$RTD"; mkdir -p "$BRD/queue" "$BRD/done" "$RTD/routed" "$RTD/results"; : > "$T/tmux.log"; : > "$T/router.log"; }
mkq() { echo "{\"id\":\"$1\",\"event\":{\"event\":\"inbox\",\"detail\":{}},\"created\":1,\"attempts\":0,\"last_delivery\":0}" > "$BRD/queue/$1.json"; }
route() { echo "{\"id\":\"$1\",\"route\":\"$2\",\"reason\":\"t\",\"row\":\"\"}" > "$RTD/routed/$1.json"; }
result() { echo "{\"id\":\"$1\",\"result\":\"${2:-executed}\",\"exit\":0}" > "$RTD/results/$1.json"; }
q() { ls "$BRD/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$BRD/done"/*.json 2>/dev/null | wc -l; }
sends() { local c; c=$(grep -c -- '-l ctl-event' "$T/tmux.log" 2>/dev/null); echo "${c:-0}"; }
acklines() { local c; c=$(grep -c " ack $1\$" "$BRD/deliveries.log" 2>/dev/null); echo "${c:-0}"; }

# AC1: ack --all without evidence leaves the item queued
fresh; mkq u1; out="$(br ack --all 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "AC1 unseen item: ack --all exits non-zero, item stays queued (rc=$rc)" $?
fresh; mkq h1; mkdir -p "$RTD/held"; : > "$RTD/held/h1"; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "AC1 held item: ack --all exits non-zero, item stays queued (rc=$rc)" $?
fresh; mkq e1; route e1 deterministic; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ]; chk "AC1 deterministic id with a cache but no result: not acked" $?
fresh; mkq e1; route e1 haiku; result e1 UNKNOWN; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ]; chk "AC1 result status UNKNOWN: not acked" $?
fresh; mkq p1; route p1 fable; result p1; br ack --all >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ]; chk "AC1 pane-delivered (route=fable) id: ack --all never acks it" $?
# mixed batch
fresh; mkq e1; route e1 deterministic; result e1; mkq u1; out="$(br ack --all 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(d)" = 1 ] && [ -f "$BRD/done/e1.json" ] && [ -f "$BRD/queue/u1.json" ] && printf '%s' "$out" | grep -q 'u1'; chk "AC1 mixed: one evidenced + one unseen = 1 in done/, u1 queued and named, exit 1 (rc=$rc)" $?
fresh; br ack --all >/dev/null 2>&1; [ $? = 0 ]; chk "ack --all on an empty queue exits 0" $?
fresh; mkq e1; route e1 haiku; result e1; br ack --all >/dev/null 2>&1; [ $? = 0 ] && [ "$(d)" = 1 ] && [ "$(q)" = 0 ]; chk "all evidenced: ack --all exits 0, done/ holds it" $?

# AC2: evidenced ack once; a second ack is idempotent
fresh; mkq e1; route e1 deterministic; result e1; br ack e1 >/dev/null 2>&1; rc1=$?
[ "$rc1" = 0 ] && [ "$(d)" = 1 ] && [ "$(acklines e1)" = 1 ] && [ -e "$RTD/handled/e1" ]; chk "AC2 ack <id> with evidence: done/ once, one ack log line, handled receipt" $?
br ack e1 >/dev/null 2>&1; rc2=$?
[ "$rc2" = 0 ] && [ "$(d)" = 1 ] && [ "$(acklines e1)" = 1 ] && [ "$(sends)" = 0 ]; chk "AC2 second ack idempotent: exit 0, still one done/ file, one ack line, no delivery (rc=$rc2)" $?
br ack nope >/dev/null 2>&1; [ $? = 1 ]; chk "AC2 unknown id still exits 1" $?
fresh; mkq p1; route p1 fable; br ack p1 >/dev/null 2>&1; [ $? = 0 ] && [ "$(d)" = 1 ]; chk "AC2 pane-delivered id: explicit ack <id> is the consumer evidence" $?

# AC3: state-based crash recovery (router result + cache written, ack not)
fresh; mkq e1; route e1 deterministic; result e1; BR_CYCLES=2 br run
[ "$(d)" = 1 ] && [ "$(q)" = 0 ] && [ "$(acklines e1)" = 1 ] && [ "$(sends)" = 0 ] && [ ! -s "$T/router.log" ]; chk "AC3 deterministic: next sweep acks from the cache once, no pane delivery, router not re-run" $?
fresh; mkq p1; route p1 fable; result p1; BR_CYCLES=2 br run
[ "$(sends)" = 1 ] && [ "$(q)" = 1 ] && [ ! -s "$T/router.log" ]; chk "AC3 fable-routed: exactly one pane delivery across two sweeps, stays queued, router not re-run" $?
br ack p1 >/dev/null 2>&1; [ "$(d)" = 1 ] && [ "$(acklines p1)" = 1 ]; chk "AC3 fable-routed: explicit ack reaches done/ once" $?
fresh; mkq k1; mkdir -p "$RTD/held"; : > "$RTD/held/k1"; result k1 UNKNOWN; sum="$(cksum < "$RTD/results/k1.json")"; BR_CYCLES=2 br run
[ "$(sends)" = 0 ] && [ "$(q)" = 1 ] && [ "$(d)" = 0 ] && [ "$(cksum < "$RTD/results/k1.json")" = "$sum" ]; chk "AC3 UNKNOWN: neither delivered nor acked, status unchanged" $?
echo "ctl-event-ack-evidence test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; exit $f
