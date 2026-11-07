#!/usr/bin/env bash
# ctl-event-bridge.sh: durable event -> ctl tmux pane bridge with ack + retry (Hermes recovery 11-06).
# The one-shot ctl-event-wait.sh exits after one event; this loop re-arms it forever, queues each actionable event
# on disk, and re-delivers every unacked event to the ctl pane every RETRY_SEC until `ack`.
#   run                 loop (BR_CYCLES=0 forever; SIGTERM ends it)
#   pending             print each unacked queue/*.json, one per line
#   ack <id>|--all      move to done/ (unknown id -> exit 1)
#   status              print status.json
#   --selftest          small fixture check in a temp HOME (stub tmux + stub waiter)
# Pre-Fable routing (A1148): before delivery every queued id goes through ctl-event-route.sh (deterministic | haiku | fable).
# Only route=fable ids reach the pane; deterministic/haiku-handled ids are acked by the bridge AFTER the router wrote the
# mechanical result and the routed cache ($RT_DIR/routed/<id>.json). An id with a cache but no ack is acked from the cache
# (no second model call). A missing router or a router failure leaves the id queued and delivered (never dropped).
# BR_ROUTE=0 disables routing (the legacy deliver-everything path).
# Env: BR_DIR EW_BIN TMUX_BIN CTL_PANE RETRY_SEC WAIT_MAX_SEC BR_CYCLES BR_ROUTE RT_BIN RT_DIR
set -u
export LC_ALL=C
BR="${BR_DIR:-$HOME/.cache/aide/event-bridge}"
EWB="${EW_BIN:-$HOME/.local/bin/ctl-event-wait.sh}"
TMUXB="${TMUX_BIN:-tmux}"
RETRY="${RETRY_SEC:-600}"; WMAX="${WAIT_MAX_SEC:-300}"; CYC="${BR_CYCLES:-0}"
SELF="$(readlink -f "$0")"
RTB="${RT_BIN:-$HOME/.local/bin/ctl-event-route.sh}"
RTD="${RT_DIR:-$HOME/.cache/aide/event-route}"
iso() { date -Iseconds; }
epoch() { date +%s; }
pane() {
  local p="${CTL_PANE:-}"
  if [ -z "$p" ]; then p="$(head -c 100 "$HOME/.cache/aide/pane" 2>/dev/null | tr -d '\n')"; fi
  [[ "$p" =~ ^[A-Za-z0-9_.:@%-]+$ ]] || p="aide:0.0"
  printf '%s' "$p"
}
pane_ok() { "$TMUXB" list-panes -t "$(pane)" -F '#{pane_current_command}' >/dev/null 2>&1; }
jget() { python3 -I -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
v=d
for k in sys.argv[2].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else v)' "$1" "$2"; }
count() { ls "$1"/*.json 2>/dev/null | wc -l; }

queue_event() { # waiter-json -> prints id
  local kind id
  kind="$(printf '%s' "$1" | python3 -I -c 'import json,sys,re; print(re.sub(r"[^a-z0-9]","",str(json.load(sys.stdin).get("event","x")).lower()) or "x")' 2>/dev/null)" || return 1
  [ -n "$kind" ] || return 1
  id="$(epoch)-$kind-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s' "$1" | python3 -I -c 'import json,sys
ev=json.load(sys.stdin)
json.dump({"id":sys.argv[1],"event":ev,"created":int(sys.argv[2]),"attempts":0,"last_delivery":0},open(sys.argv[3]+".tmp","w"))' "$id" "$(epoch)" "$BR/queue/$id.json" || return 1
  mv "$BR/queue/$id.json.tmp" "$BR/queue/$id.json"; printf '%s' "$id"
}

OAF="${RT_OPEN_ASKS:-$HOME/.cache/aide/open-asks.tsv}"
cached_route() { local c="$RTD/routed/$1.json"; [ -f "$c" ] && jget "$c" route; }
deliverable() { # unrouted (router absent/failed: fail-safe, never dropped) or route=fable; error/other routes never reach the pane
  [ "${BR_ROUTE:-1}" = 0 ] && return 0
  local rt; rt="$(cached_route "$1")"; [ -z "$rt" ] || [ "$rt" = fable ]
}
evidence_ok() { # consumer success: results/<id>.json has an exit field and, when the route made a row, the row marker is in open-asks
  local id="$1" r="$RTD/results/$1.json" c="$RTD/routed/$1.json" row
  [ -f "$r" ] && [ -n "$(jget "$r" exit)" ] || return 1
  row="$(jget "$c" row)"
  [ -z "$row" ] || grep -qF "event:$id" "$OAF" 2>/dev/null
}
route_pending() { # route each queued id once; ack deterministic/haiku ids only after consumer evidence exists
  [ "${BR_ROUTE:-1}" = 0 ] && return 0
  [ -x "$RTB" ] || return 0
  local f id c rt
  for f in "$BR"/queue/*.json; do
    [ -f "$f" ] || continue
    id="$(jget "$f" id)"; [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    c="$RTD/routed/$id.json"
    [ -f "$c" ] || RT_DIR="$RTD" RT_OPEN_ASKS="$OAF" "$RTB" route "$f" >/dev/null 2>>"$BR/route.err" || true
    [ -f "$c" ] || continue
    rt="$(jget "$c" route)"
    if [ "$rt" = deterministic ] || [ "$rt" = haiku ]; then
      if evidence_ok "$id"; then ackone "$f"; else echo "$(iso) ack-refused $id no-consumer-evidence" >> "$BR/deliveries.log"; fi
    fi
  done
}
reason_of() { local c="$RTD/routed/$1.json"; [ -f "$c" ] && jget "$c" reason | tr -d '\n|' | cut -c1-120; }

deliver() { # one line for every pending id
  local f ids="" summary="" n=0 p rc id kind
  for f in "$BR"/queue/*.json; do
    [ -f "$f" ] || continue
    id="$(jget "$f" id)"; kind="$(jget "$f" event.event)"
    deliverable "$id" || continue
    n=$((n+1)); ids="$ids $id"; summary="${summary:+$summary | }$id $kind reason=$(reason_of "$id")"
  done
  [ "$n" -gt 0 ] || return 0
  p="$(pane)"
  if ! pane_ok; then echo "$(iso) no-pane$ids" >> "$BR/deliveries.log"; PANE_OK=false; return 0; fi
  PANE_OK=true
  "$TMUXB" send-keys -t "$p" -l "ctl-event $n pending: $summary ; read: ctl-event-bridge.sh pending ; ack: ctl-event-bridge.sh ack --all"; rc=$?
  "$TMUXB" send-keys -t "$p" Enter || rc=$?
  for f in "$BR"/queue/*.json; do
    [ -f "$f" ] || continue
    python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); d["attempts"]=int(d.get("attempts",0))+1; d["last_delivery"]=int(sys.argv[2])
json.dump(d,open(sys.argv[1]+".tmp","w"))' "$f" "$(epoch)" && mv "$f.tmp" "$f"
  done
  LAST_DELIVERY="$(iso)"
  echo "$(iso) deliver$ids pane=$p rc=$rc" >> "$BR/deliveries.log"
}

due_redelivery() { # true when any queued file is undelivered or older than RETRY
  local f ld t; t="$(epoch)"
  for f in "$BR"/queue/*.json; do
    [ -f "$f" ] || continue
    deliverable "$(jget "$f" id)" || continue
    ld="$(jget "$f" last_delivery)"; ld="${ld:-0}"
    [[ "$ld" =~ ^[0-9]+$ ]] || ld=0
    if [ "$ld" -eq 0 ] || [ $((t - ld)) -ge "$RETRY" ]; then return 0; fi
  done
  return 1
}

write_status() {
  local po=false; pane_ok && po=true; PANE_OK="$po"
  python3 -I -c 'import json,sys,os
a=sys.argv
d={"ts":a[1],"cycle":int(a[2]),"queue_pending":int(a[3]),"done_total":int(a[4]),"last_event":a[5],"last_delivery":a[6],"pane":a[7],"pane_ok":a[8]=="true","waiter_exit":int(a[9])}
json.dump(d,open(a[10]+".tmp","w")); os.replace(a[10]+".tmp",a[10])' \
    "$(iso)" "$cycle" "$(count "$BR/queue")" "$(count "$BR/done")" "$LAST_EVENT" "$LAST_DELIVERY" "$(pane)" "$po" "$WEXIT" "$BR/status.json"
}

run() {
  mkdir -p "$BR/queue" "$BR/done"; touch "$BR/deliveries.log"
  cycle=0; LAST_EVENT=""; LAST_DELIVERY=""; WEXIT=0; PANE_OK=true; wp=""
  trap '[ -n "$wp" ] && kill "$wp" 2>/dev/null; exit 0' TERM INT
  while :; do
    cycle=$((cycle+1))
    route_pending
    if due_redelivery; then deliver; fi
    local tmp="$BR/.wait.out"
    "$EWB" wait --max-sec "$WMAX" > "$tmp" 2>>"$BR/waiter.err" & wp=$!
    wait "$wp"; WEXIT=$?; wp=""
    local out ev id; out="$(tail -n 1 "$tmp" 2>/dev/null)"
    ev="$(printf '%s' "$out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("event",""))' 2>/dev/null || true)"
    if [ -n "$ev" ] && [ "$ev" != timeout ]; then
      if id="$(queue_event "$out")"; then LAST_EVENT="$id"; route_pending; deliver; fi
    fi
    write_status
    if [ "$CYC" -gt 0 ] && [ "$cycle" -ge "$CYC" ]; then break; fi
    # a waiter that fails instantly must not spin
    if [ "$WEXIT" -ne 0 ]; then sleep 5; fi
  done
}

ack() {
  local f id n=0 want="${1:-}"
  [ -n "$want" ] || { echo "usage: ack <id>|--all" >&2; return 2; }
  mkdir -p "$BR/queue" "$BR/done"
  if [ "$want" = "--all" ]; then
    for f in "$BR"/queue/*.json; do [ -f "$f" ] && ackone "$f" && n=$((n+1)); done
    echo "acked $n"; return 0
  fi
  [[ "$want" =~ ^[A-Za-z0-9._-]+$ ]] && [ -f "$BR/queue/$want.json" ] || { echo "unknown id: $want" >&2; return 1; }
  ackone "$BR/queue/$want.json" && echo "acked 1"
}
ackone() {
  local f="$1" id; id="$(basename "$f" .json)"
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); d["acked"]=int(sys.argv[2]); json.dump(d,open(sys.argv[3],"w"))' "$f" "$(epoch)" "$BR/done/$id.json" && rm -f "$f" \
    && echo "$(iso) ack $id" >> "$BR/deliveries.log"
}

selftest() {
  local T; T="$(mktemp -d)"; local f=0
  printf '#!/bin/sh\necho "$@" >> %s/tmux.log\n[ "$1" = list-panes ] && echo claude\nexit 0\n' "$T" > "$T/tmux"
  printf '#!/bin/sh\nl=$(head -n1 %s/ev); if [ -n "$l" ]; then sed -i 1d %s/ev; echo "$l"; else echo {\\"event\\":\\"timeout\\"}; fi\n' "$T" "$T" > "$T/ew"
  chmod +x "$T/tmux" "$T/ew"; echo '{"event":"inbox","detail":{}}' > "$T/ev"
  env -i HOME="$T" PATH="$PATH" BR_DIR="$T/br" EW_BIN="$T/ew" TMUX_BIN="$T/tmux" CTL_PANE=t:0.0 BR_CYCLES=2 bash "$SELF" run
  [ "$(count "$T/br/queue")" = 1 ] && grep -q 'send-keys' "$T/tmux.log"; [ $? = 0 ] || f=1
  env -i HOME="$T" PATH="$PATH" BR_DIR="$T/br" bash "$SELF" ack --all >/dev/null
  [ "$(count "$T/br/queue")" = 0 ] && [ "$(count "$T/br/done")" = 1 ] || f=1
  rm -rf "$T"; echo "ctl-event-bridge selftest: $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; return $f
}

case "${1:-}" in
  run) run ;;
  pending) for f in "$BR"/queue/*.json; do [ -f "$f" ] && { cat "$f"; echo; }; done; exit 0 ;;
  ack) shift; ack "${1:-}" ;;
  status) cat "$BR/status.json" 2>/dev/null || echo '{"status":"no status yet"}' ;;
  --selftest) selftest ;;
  *) echo "usage: ctl-event-bridge.sh run|pending|ack <id>|--all|status|--selftest" >&2; exit 2 ;;
esac
