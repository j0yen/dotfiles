#!/usr/bin/env bash
# carbon-alive.test.sh — .local/bin/carbon-alive.sh with a fake ssh and a fake deliverer (A1446).
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; pass=0
ok() { echo "PASS $1"; pass=$((pass+1)); }; bad() { echo "FAIL $1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CONFIG_HOME="$T/cfg" CARBON_ALIVE_HOST=testhost
export CARBON_ALIVE_SSH="$here/tests/fixtures/carbon-alive-fake-ssh.sh"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/carbon-alive"
calls="$T/calls"; good="$T/deliver-ok.sh"; badd="$T/deliver-bad.sh"
printf '#!/bin/sh\necho "$1 $(cat)" >> %s\n' "$calls" > "$good"
printf '#!/bin/sh\ncat >/dev/null; exit 1\n' > "$badd"; chmod +x "$good" "$badd"
setdel() { echo "$1" > "$XDG_CONFIG_HOME/carbon-alive/deliver"; }
reset() { rm -rf "$XDG_STATE_HOME" "$calls"; : > "$calls"; unset CA_FAKE_RC CA_FAKE_UM CA_FAKE_GW CA_FAKE_BUS CA_FAKE_DASH CA_FAKE_EXEC CARBON_ALIVE_SEND_BUDGET_S
  rm -f "$XDG_CONFIG_HOME/carbon-alive/expect-executor"; setdel "$good"; clock=1000000; }
run() { CARBON_ALIVE_NOW="$clock" "$here/.local/bin/carbon-alive.sh"; local r=$?; clock=$((clock+${1:-120})); return $r; }
n() { grep -c "^$1 " "$calls"; }
st() { python3 -I -c "import json;print(json.load(open('$XDG_STATE_HOME/carbon-alive/state.json'))['state'])"; }
ex() { python3 -I -c "import json;print(json.load(open('$XDG_STATE_HOME/carbon-alive/state.json')).get('executor'))"; }
sdir="$XDG_STATE_HOME/carbon-alive"
# queue N alerts (at=1..N, id=e1..eN) straight into the outbox, as earlier runs would have
queue() { mkdir -p "$sdir"; python3 -I -c 'import json,sys
for i in range(1, int(sys.argv[1]) + 1): print(json.dumps({"kind": "alert", "host": "h", "state": "bus-down", "at": i, "id": "e%d" % i, "readings": {}}))' "$1" >> "$sdir/outbox.jsonl"; }

reset; run; run; run
[ "$(wc -l < "$calls")" = 0 ] && [ "$(st)" = ok ] && ok "a ok -> no alert" || bad "a ok -> no alert"

reset; export CA_FAKE_RC=255; run; [ "$(wc -l < "$calls")" = 0 ] || bad "b alert after one run"; run; run
[ "$(n alert)" = 1 ] && grep -q 'state": "host-unreachable' "$calls" && grep -q 'testhost' "$calls" && ok "b unreachable x2 -> one alert, none on third" || { bad "b unreachable"; cat "$calls"; }

reset; export CA_FAKE_UM=inactive; run; run
[ "$(n alert)" = 1 ] && [ "$(st)" = user-manager-down ] && ok "c user-manager-down" || bad "c user-manager-down"

reset; export CA_FAKE_DASH=900; run; run
[ "$(n alert)" = 1 ] && [ "$(st)" = dash-stale ] && ok "d dash-stale" || bad "d dash-stale"

reset; export CA_FAKE_UM=failed; run; run; unset CA_FAKE_UM; run; run
[ "$(n alert)" = 1 ] && [ "$(n recovery)" = 1 ] && [ "$(st)" = ok ] && ok "e outage then ok -> one recovery" || { bad "e recovery"; cat "$calls"; }

reset; export CA_FAKE_RC=255; setdel "$badd"; run; run
ob="$XDG_STATE_HOME/carbon-alive/outbox.jsonl"
[ "$(wc -l < "$ob")" = 1 ] || bad "f outbox should hold the alert"
setdel "$good"; unset CA_FAKE_RC; run
[ "$(n alert)" = 1 ] && [ ! -s "$ob" ] && ok "f failed delivery -> outbox -> replayed and emptied" || bad "f replay"
reset; export CA_FAKE_RC=255; setdel "$T/nonexistent"; run; run
[ "$(wc -l < "$XDG_STATE_HOME/carbon-alive/outbox.jsonl")" = 1 ] && ok "f2 missing deliverer -> outbox" || bad "f2 missing deliverer"

reset; export CA_FAKE_RC=255; run; run; run 600; run 600; run 600; run 600
# alert at t=120s; re-alert only when >=1800 s later: t=1200 no, 1800 yes... check counts
c="$(n alert)"
reset; export CA_FAKE_RC=255; run 100; run 100; run 1600; run 100; run 100
c2="$(n alert)"
[ "$c" = 2 ] && [ "$c2" = 2 ] && ok "g 30-min re-alert only after 1800 s (counts $c/$c2)" || bad "g re-alert counts $c/$c2"

reset; export CA_FAKE_BUS=down; run; run
[ "$(st)" = bus-down ] && [ "$(n alert)" = 1 ] && ok "h ssh ok, bus missing -> bus-down" || bad "h bus-down"

reset; export CA_FAKE_GW=failed; run; run
[ "$(st)" = gateway-down ] && ok "i gateway-down" || bad "i gateway-down"

# F1: an outage flapping between non-ok states still alerts (count = non-ok runs, not same-state runs)
reset; export CA_FAKE_GW=failed; run; unset CA_FAKE_GW; export CA_FAKE_BUS=down; run; c1="$(n alert)"
unset CA_FAKE_BUS; export CA_FAKE_GW=failed; run
[ "$c1" = 1 ] && [ "$(n alert)" = 1 ] && grep -q '"states": \["gateway-down", "bus-down"\]' "$calls" \
  && grep -q '"outage_since": 1000000' "$calls" && ok "i flapping gateway/bus/gateway -> one alert after run 2, both states" \
  || { bad "i flapping"; cat "$calls"; }

reset; export CA_FAKE_GW=failed; run; run; unset CA_FAKE_GW; export CA_FAKE_BUS=down; run
early="$(n alert)"
reset; export CA_FAKE_GW=failed; run; run 600; unset CA_FAKE_GW; export CA_FAKE_BUS=down; run
late="$(n alert)"
[ "$early" = 1 ] && [ "$late" = 2 ] && grep -q '"state": "bus-down"' "$calls" \
  && ok "j state change in alerted outage: <10 min none, >=10 min re-alert ($early/$late)" || { bad "j re-alert on change $early/$late"; cat "$calls"; }

reset; run; export CA_FAKE_UM=failed; run; unset CA_FAKE_UM; run; run
[ "$(wc -l < "$calls")" = 0 ] && [ "$(st)" = ok ] && ok "k ok, non-ok once, ok -> no alert, no recovery" || { bad "k blip"; cat "$calls"; }

# G1: executor reading + executor-stale (only while expect-executor exists; host/user/gateway/bus/dash states first)
reset; touch "$XDG_CONFIG_HOME/carbon-alive/expect-executor"; export CA_FAKE_EXEC=99999; run; run
[ "$(n alert)" = 1 ] && [ "$(st)" = executor-stale ] && grep -q '"state": "executor-stale"' "$calls" && grep -q '"executor": "stale"' "$calls" \
  && ok "l expect-executor + heartbeat 99999 s old x2 -> one alert, state executor-stale" || { bad "l executor-stale"; cat "$calls"; }

reset; export CA_FAKE_EXEC=99999; run; run
[ "$(wc -l < "$calls")" = 0 ] && [ "$(st)" = ok ] && [ "$(ex)" = stale ] && grep -q '"executor": "stale"' "$sdir/probes.jsonl" \
  && ok "m no expect-executor, heartbeat stale -> state ok, state.json executor=stale, no alert" || { bad "m executor reading only"; cat "$calls"; }

reset; touch "$XDG_CONFIG_HOME/carbon-alive/expect-executor"; export CA_FAKE_EXEC=99999 CA_FAKE_GW=failed; run; run
[ "$(st)" = gateway-down ] && [ "$(ex)" = stale ] && grep -q '"executor": "stale"' "$calls" \
  && ok "l2 gateway-down takes precedence over executor-stale; alert carries executor=stale" || { bad "l2 precedence"; cat "$calls"; }

reset; export CA_FAKE_EXEC=60; run; e1="$(ex)"; export CA_FAKE_EXEC=x; run; e2="$(ex)"; unset CA_FAKE_EXEC; run; e3="$(ex)"
export CA_FAKE_RC=255; CA_FAKE_EXEC=60 run; e4="$(ex)"
reset; export CA_FAKE_EXEC=1801 CARBON_ALIVE_EXEC_MAX_S=3600; run; e5="$(ex)"; unset CARBON_ALIVE_EXEC_MAX_S
[ "$e1/$e2/$e3/$e4/$e5" = fresh/unknown/unknown/unknown/fresh ] && ok "l3 executor fresh / non-numeric / absent / unreachable / custom max ($e1/$e2/$e3/$e4/$e5)" \
  || bad "l3 executor readings $e1/$e2/$e3/$e4/$e5"

reset; export CA_FAKE_UM=failed; run; run
python3 -I -c 'import json,sys;a=json.loads(open(sys.argv[1]).read().split(" ",1)[1]);assert a["text"].startswith("1970-01-12T13:48:40Z "),a["text"];assert "executor=unknown" in a["text"]' "$calls" \
  && ok "l4 alert text starts with its at time (UTC ISO) and names the executor" || { bad "l4 alert text"; cat "$calls"; }

# G2: outbox cap 200, oldest overflow -> outbox.dead.jsonl with one log line each
reset; setdel "$badd"; queue 205; run 2> "$T/err"
[ "$(wc -l < "$sdir/outbox.jsonl")" = 200 ] && [ "$(wc -l < "$sdir/outbox.dead.jsonl")" = 5 ] \
  && [ "$(grep -c 'moved oldest' "$T/err")" = 5 ] && grep -q '"id": "e5"' "$sdir/outbox.dead.jsonl" && ! grep -q '"id": "e6"' "$sdir/outbox.dead.jsonl" \
  && head -n1 "$sdir/outbox.jsonl" | grep -q '"id": "e6"' && ok "o 205 queued -> outbox holds 200, oldest 5 dead-lettered + logged" \
  || { bad "o outbox cap"; cat "$T/err"; }

reset; mkdir -p "$sdir"; echo 'not json' > "$sdir/outbox.jsonl"; queue 1; run 2> "$T/err"
[ "$(n alert)" = 1 ] && grep -qx 'not json' "$sdir/outbox.dead.jsonl" && [ ! -s "$sdir/outbox.jsonl" ] && grep -q unparseable "$T/err" \
  && ok "o2 unparseable outbox entry -> dead-lettered, the next entry still delivered" || { bad "o2 unparseable"; cat "$T/err"; }

p3="$T/deliver-3.sh"; printf '#!/bin/sh\ni=$(cat); case "$i" in *\\"e1\\"*) exit 3;; esac; echo "$1 $i" >> %s\n' "$calls" > "$p3"; chmod +x "$p3"
reset; setdel "$p3"; queue 2; run 2> "$T/err"
[ "$(n alert)" = 1 ] && grep -q '"id": "e2"' "$calls" && grep -q '"id": "e1"' "$sdir/outbox.dead.jsonl" && [ ! -s "$sdir/outbox.jsonl" ] \
  && grep -q 'rejected kind=alert state=bus-down at=1 permanently' "$T/err" \
  && ok "o3 deliver command exit 3 -> entry dead-lettered + logged, next delivered" || { bad "o3 exit 3"; cat "$T/err" "$calls"; }

# G3: replayed entries carry replay_at, entries queued this run do not
reset; queue 1; export CA_FAKE_UM=failed; run; run
python3 -I -c 'import json,sys
L=[json.loads(l.split(" ",1)[1]) for l in open(sys.argv[1])]
assert L[0]["id"]=="e1" and L[0]["replay_at"]==1000000, L[0]
assert L[1]["state"]=="user-manager-down" and "replay_at" not in L[1], L[1]' "$calls" \
  && ok "p2 queued entry replayed with replay_at; this run's alert sent without it" || { bad "p2 replay_at"; cat "$calls"; }

# G4: a run killed mid-loop (systemd TimeoutStartSec kills the cgroup) re-sends only the undelivered entries
pq="$T/deliver-block.sh"
printf '#!/bin/sh\necho "$1 $(cat)" >> %s\nif [ "$(wc -l < %s)" = 2 ] && [ -e %s ]; then ps -o pgid= -p $$ > %s.t; mv %s.t %s; exec sleep 20; fi\n' \
  "$calls" "$calls" "$T/block" "$T/blocked" "$T/blocked" "$T/blocked" > "$pq"; chmod +x "$pq"
reset; setdel "$pq"; queue 3; touch "$T/block"; rm -f "$T/blocked"
CARBON_ALIVE_NOW="$clock" "$here/.local/bin/carbon-alive.sh" 2>/dev/null & qp=$!
for _ in $(seq 100); do [ -e "$T/blocked" ] && break; sleep 0.1; done
# SIGKILL the run itself mid-send, as a TimeoutStartSec cgroup kill would, plus the blocked deliverer's group (timeout
# makes its own; read from the deliverer), never this test's own group
qg="$(tr -d ' ' < "$T/blocked" 2>/dev/null)"; mine="$(ps -o pgid= -p $$ | tr -d ' ')"
kill -KILL "$qp" 2>/dev/null; wait "$qp" 2>/dev/null; qrc=$?
[ -n "$qg" ] && [ "$qg" != "$mine" ] && kill -KILL -- "-$qg" 2>/dev/null
left="$(wc -l < "$sdir/outbox.jsonl")"; rm -f "$T/block"; clock=$((clock+120)); run
c1="$(grep -c '"id": "e1"' "$calls")"; c2="$(grep -c '"id": "e2"' "$calls")"; c3="$(grep -c '"id": "e3"' "$calls")"
[ -e "$T/blocked" ] && [ "$qrc" = 137 ] && [ "$left" = 2 ] && [ "$c1/$c2/$c3" = 1/2/1 ] && [ ! -s "$sdir/outbox.jsonl" ] \
  && ok "q killed after first success -> outbox kept e2,e3 only; next run sends e1 0x, e2 again, e3 ($c1/$c2/$c3)" \
  || { bad "q interrupted loop rc=$qrc left=$left counts $c1/$c2/$c3"; cat "$calls"; }

reset; queue 2; export CARBON_ALIVE_SEND_BUDGET_S=0; run 2> "$T/err"; c0="$(wc -l < "$calls")"; unset CARBON_ALIVE_SEND_BUDGET_S; run
[ "$c0" = 0 ] && grep -q 'send budget 0s spent, 2 outbox entries left' "$T/err" && [ "$(n alert)" = 2 ] && [ ! -s "$sdir/outbox.jsonl" ] \
  && ok "r send budget spent -> no new send starts, entries wait for the next run" || { bad "r budget c0=$c0"; cat "$T/err"; }

echo "carbon-alive.test: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
