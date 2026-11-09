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
reset() { rm -rf "$XDG_STATE_HOME" "$calls"; : > "$calls"; unset CA_FAKE_RC CA_FAKE_UM CA_FAKE_GW CA_FAKE_BUS CA_FAKE_DASH; setdel "$good"; clock=1000000; }
run() { CARBON_ALIVE_NOW="$clock" "$here/.local/bin/carbon-alive.sh"; local r=$?; clock=$((clock+${1:-120})); return $r; }
n() { grep -c "^$1 " "$calls"; }
st() { python3 -I -c "import json;print(json.load(open('$XDG_STATE_HOME/carbon-alive/state.json'))['state'])"; }

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

echo "carbon-alive.test: $pass PASS $fail FAIL"; [ "$fail" = 0 ]
