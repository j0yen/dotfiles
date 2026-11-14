#!/usr/bin/env bash
# ctl-event-bridge fixture test: stubs only (tmux, waiter), temp HOME, no real pane, no real log.
# RED (the fault): the bare one-shot waiter emits one event, exits 0, and a second event is never consumed.
# GREEN: ctl-event-bridge.sh run loops past events, queues them, delivers with ack/retry.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
BR="$root/.local/bin/ctl-event-bridge.sh"; EWS="$root/.local/bin/ctl-event-wait.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0; f=0
chk() { n=$((n+1)); if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1"; f=1; fi; }
mkdir -p "$T/home"
printf '#!/bin/sh\necho "$@" >> %s/tmux.log\nif [ "$1" = list-panes ]; then [ -f %s/nopane ] && exit 1; echo claude; fi\nexit 0\n' "$T" "$T" > "$T/tmux"
printf '#!/bin/sh\nl=$(head -n1 %s/ev 2>/dev/null)\nif [ -n "$l" ]; then sed -i 1d %s/ev; echo "$l"; else echo "{\\"event\\":\\"timeout\\"}"; fi\nexit 0\n' "$T" "$T" > "$T/ew"
chmod +x "$T/tmux" "$T/ew"
ev() { printf '%s\n' '{"event":"inbox","ts":"t","detail":{"lines":["x | hermes-urgent | go"]}}' '{"event":"verifier","ts":"t","detail":{"files":["a"]}}' > "$T/ev"; }
br() { env -i HOME="$T/home" PATH="$PATH" BR_DIR="$T/br" EW_BIN="$T/ew" TMUX_BIN="$T/tmux" CTL_PANE=t:0.0 RETRY_SEC="${RETRY_SEC:-1}" BR_CYCLES="${BR_CYCLES:-4}" WAIT_MAX_SEC=1 bash "$BR" "$@"; }
q() { ls "$T/br/queue"/*.json 2>/dev/null | wc -l; }
d() { ls "$T/br/done"/*.json 2>/dev/null | wc -l; }
sends() { local c; c=$(grep -c -- '-l ctl-event' "$T/tmux.log" 2>/dev/null); echo "${c:-0}"; }

# RED reproduction: bare waiter stub, run once = one event, then nothing consumes the second
ev; "$T/ew" wait >/dev/null; rc=$?; [ "$rc" = 0 ] && [ "$(wc -l < "$T/ev")" = 1 ]; chk "RED: bare waiter consumes one event and exits; second event left unread" $?

# GREEN: both events queue and deliver
ev; : > "$T/tmux.log"; br run
[ "$(q)" = 2 ]; chk "both events landed in queue/ (inbox then verifier)" $?
[ "$(sends)" -ge 2 ]; chk "each event delivered via send-keys (sends=$(sends))" $?
grep -q 'Enter' "$T/tmux.log"; chk "Enter sent after text" $?
grep -q 'deliver' "$T/br/deliveries.log"; chk "deliveries.log has deliver lines" $?
# ack
br ack --all >/dev/null 2>&1; [ $? = 1 ] && [ "$(q)" = 2 ]; chk "ack --all leaves unrouted pane-delivered ids queued (no consumer evidence), exit 1" $?
for i in "$T"/br/queue/*.json; do br ack "$(basename "$i" .json)" >/dev/null; done; [ "$(q)" = 0 ] && [ "$(d)" = 2 ]; chk "ack <id> per id moves both to done/" $?
: > "$T/tmux.log"; BR_CYCLES=2 br run; [ "$(sends)" = 0 ]; chk "after ack a further cycle delivers nothing" $?
br ack nope >/dev/null 2>&1; [ $? = 1 ]; chk "ack unknown id exits 1" $?
# timeout creates nothing
rm -rf "$T/br"; : > "$T/ev"; : > "$T/tmux.log"; BR_CYCLES=2 br run
[ "$(q)" = 0 ] && [ "$(sends)" = 0 ]; chk "timeout event: no queue file, no send-keys" $?
# redelivery after RETRY_SEC
rm -rf "$T/br"; printf '%s\n' '{"event":"inbox","detail":{}}' > "$T/ev"; : > "$T/tmux.log"; RETRY_SEC=1 BR_CYCLES=1 br run
s1="$(sends)"; sleep 2; BR_CYCLES=1 RETRY_SEC=1 br run; s2="$(sends)"
[ "$s2" -gt "$s1" ] && [ "$(q)" = 1 ]; chk "unacked event redelivered after RETRY_SEC ($s1 -> $s2)" $?
# restart recovery: leftover queue file, new run delivers it
: > "$T/tmux.log"; sleep 2; BR_CYCLES=1 RETRY_SEC=1 br run; [ "$(sends)" -ge 1 ]; chk "restart: leftover queue file redelivered by a new run" $?
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["pane_ok"] is True and d["queue_pending"]==1' "$T/br/status.json"; chk "status.json fields (pane_ok true, queue_pending 1)" $?
# SIGTERM ends a running loop
env -i HOME="$T/home" PATH="$PATH" BR_DIR="$T/br" EW_BIN="$T/ew" TMUX_BIN="$T/tmux" CTL_PANE=t:0.0 WAIT_MAX_SEC=1 BR_CYCLES=0 bash "$BR" run & bp=$!
sleep 1; kill -TERM "$bp"; for _ in 1 2 3 4 5; do kill -0 "$bp" 2>/dev/null || break; sleep 1; done; ! kill -0 "$bp" 2>/dev/null; chk "SIGTERM ends the loop" $?
# no pane
rm -rf "$T/br"; touch "$T/nopane"; printf '%s\n' '{"event":"inbox","detail":{}}' > "$T/ev"; : > "$T/tmux.log"; BR_CYCLES=2 RETRY_SEC=0 br run
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["pane_ok"] is False' "$T/br/status.json"; chk "no pane: status pane_ok=false" $?
[ "$(q)" = 1 ] && grep -q 'no-pane' "$T/br/deliveries.log" && [ "$(sends)" = 0 ]; chk "no pane: event stays queued, no-pane logged, retried" $?
rm -f "$T/nopane"
# locale: waiter selftest clean
err="$(LC_ALL=en_US.UTF-8 bash "$EWS" --selftest 2>&1 >"$T/st.out")"; rc=$?
[ "$rc" = 0 ] && ! printf '%s' "$err" | grep -q 'comm:'; chk "waiter --selftest passes under en_US.UTF-8 with no comm: on stderr (rc=$rc)" $?
grep -q '^export LC_ALL=C$' "$EWS"; chk "waiter exports LC_ALL=C" $?
echo "ctl-event-bridge test: $n checks, $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"
exit $f
