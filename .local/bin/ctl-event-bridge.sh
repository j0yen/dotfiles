#!/usr/bin/env bash
# ctl-event-bridge.sh: durable event -> ctl tmux pane bridge with ack + retry (Hermes recovery 11-06).
# The one-shot ctl-event-wait.sh exits after one event; this loop re-arms it forever, queues each actionable event
# on disk, and re-delivers every unacked event to the ctl pane every RETRY_SEC until `ack`.
#   run                 loop (BR_CYCLES=0 forever; SIGTERM ends it)
#   pending             print each unacked queue/*.json, one per line
#   ack <id>|--all      move to done/ (unknown id -> exit 1; an already-acked id with no queued file -> exit 0, no second ack; a re-queued id is a new delivery: own evidence, own done/<id>.rN.json + receipt). --all acks only ids with consumer
#                       evidence (deterministic/haiku: result + routed cache), prints the skipped ids and exits 1; pane-delivered ids need `ack <id>`
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

# A1255: the row marker is looked up in the canonical ledger (asks-view); no TSV file is read or passed on.
cached_route() { local c="$RTD/routed/$1.json"; [ -f "$c" ] && jget "$c" route; }
held() { [ -e "$RTD/held/$1" ]; } # the router held this id (exit 75, an unreadable file): queued, but nothing acts on it until it routes
deliverable() { # unrouted (router absent/failed: fail-safe, never dropped) or route=fable; error/other routes and held ids never reach the pane
  [ "${BR_ROUTE:-1}" = 0 ] && return 0
  held "$1" && return 1
  local rt; rt="$(cached_route "$1")"; [ -z "$rt" ] || [ "$rt" = fable ]
}
evidence_ok() { # typed fail-closed check for a deterministic/haiku id: results/<id>.json and routed/<id>.json must match the schema exactly; success = exit 0 and no typed failure
  # a requeued id (done/<id>.json exists) is a new delivery: its evidence must be at least as new as the queued payload's `created`. Sets EV_WHY to the refusal class.
  local id="$1" row out
  EV_WHY=""
  out="$(python3 -I -c 'import json,os,re,sys
rd,cd,eid,qf,df=sys.argv[1:6]
def no(w): print("NO\t"+w); sys.exit(0)
def load(p):
    try: d=json.load(open(p))
    except Exception: return None
    return d if isinstance(d,dict) else None
def unk(v):   # UNKNOWN in any casing, anywhere in the document (keys, nested values), is never success
    if isinstance(v,dict): return any(str(k).strip().lower() in ("status","unknown") or unk(k) or unk(x) for k,x in v.items())
    if isinstance(v,list): return any(unk(x) for x in v)
    return isinstance(v,str) and v.strip().lower()=="unknown"
rf=rd+"/results/"+eid+".json"; cf=cd+"/routed/"+eid+".json"
r=load(rf); c=load(cf)
if r is None or c is None: no("missing")
if unk(r) or unk(c): no("UNKNOWN")
if c.get("id")!=eid or c.get("route") not in ("deterministic","haiku"): no("invalid-cache")
if r.get("id")!=eid or r.get("route",c["route"])!=c["route"]: no("invalid-result-id")
if not isinstance(r.get("result"),str) or not re.fullmatch(r"[a-z][a-z0-9-]*",r["result"]): no("invalid-result")
e=r.get("exit")
if not isinstance(e,int) or isinstance(e,bool): no("invalid-exit")
if e!=0 or re.search(r"blocked|error|fail|refused",r["result"]): no("typed-failure")   # router typed failures: blocked-row exit 2, error-row exit 4, any nonzero exit
rw=c.get("row","")
if not isinstance(rw,str): no("invalid-cache")
if os.path.isfile(df):   # requeued: evidence older than this delivery belongs to the earlier delivery
    q=load(qf); cr=q.get("created") if q else None
    if not isinstance(cr,int) or isinstance(cr,bool): no("stale-requeue")
    if min(os.path.getmtime(rf),os.path.getmtime(cf))<cr: no("stale-requeue")
print("OK\t"+rw)' "$RTD" "$RTD" "$id" "$BR/queue/$id.json" "$BR/done/$id.json")" || { EV_WHY=invalid; return 1; }
  if [ "${out%%$'\t'*}" != OK ]; then EV_WHY="${out#*$'\t'}"; return 1; fi
  row="${out#*$'\t'}"
  [ -z "$row" ] || "${ASKS_VIEW_BIN:-asks-view}" 2>/dev/null | grep -qF "event:$id" || { EV_WHY=row-marker; return 1; }
}
ack_ok() { # explicit `ack <id>`: a held id is refused (held-unreadable without a cache, inconsistent with one); deterministic/haiku ids need evidence_ok; fable-routed and unrouted (pane-delivered) ids are acked by the consumer's word; any other cache is refused
  local id="$1" c="$RTD/routed/$1.json" rt
  if held "$id"; then
    if [ -e "$c" ]; then echo "refused $id: held marker beside a routed cache (inconsistent state; nothing acts until the router re-routes it)" >&2
    else echo "refused $id: held-unreadable (the router held it, exit 75; not success, it stays queued until the router routes it)" >&2; fi
    return 1
  fi
  [ -e "$c" ] || return 0   # no cache and not held: pane-delivered/legacy id, the consumer's explicit ack is the evidence
  rt="$(jget "$c" route)"
  case "$rt" in
    deterministic|haiku) evidence_ok "$id" || { echo "refused $id: route=$rt needs the typed success result (exit 0, id bound, never UNKNOWN or a typed failure, newer than a requeued payload) and the routed cache; reason class: $EV_WHY" >&2; return 1; } ;;
    fable) ;;
    *) echo "refused $id: routed cache is missing/malformed or names route '${rt:-none}'" >&2; return 1 ;;
  esac
}
handled_by_router() { local rt; rt="$(cached_route "$1")"; { [ "$rt" = deterministic ] || [ "$rt" = haiku ]; } && evidence_ok "$1"; }
held_err() { # one route.err line per held id per HELD_LOG_SEC (default 900) naming the router exit code; stamp $RTD/held-log/<id>.rc
  local s="$RTD/held-log/$1.rc" w="${HELD_LOG_SEC:-900}" m
  m="$(stat -c %Y "$s" 2>/dev/null || echo 0)"
  [ $(( $(epoch) - m )) -lt "$w" ] && return 0
  mkdir -p "$RTD/held-log" && : > "$s"
  echo "$(iso) held id $1: router exit $2 (still held and queued, not delivered)" >> "$BR/route.err"
}
clear_held() { rm -f "$RTD/held/$1" "$RTD/held-log/$1" "$RTD/held-log/$1.rc"; }
sweep_held() { # marker files whose queue file is gone (acked, deleted by hand) are removed
  local m b
  for m in "$RTD"/held/* "$RTD"/held-log/*; do
    [ -e "$m" ] || continue
    b="$(basename "$m")"; b="${b%.rc}"
    [ -f "$BR/queue/$b.json" ] || rm -f "$m"
  done
}
route_pending() { # route each queued id once; ack deterministic/haiku ids only after consumer evidence exists
  [ "${BR_ROUTE:-1}" = 0 ] && return 0
  sweep_held
  [ -x "$RTB" ] || return 0
  local f id c rt rc
  for f in "$BR"/queue/*.json; do
    [ -f "$f" ] || continue
    id="$(jget "$f" id)"; [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    c="$RTD/routed/$id.json"
    if [ ! -f "$c" ]; then
      RT_DIR="$RTD" "$RTB" route "$f" >/dev/null 2>>"$BR/route.err"
      rc=$?
      if [ $rc -eq 75 ]; then
        if ! held "$id"; then echo "$(iso) held id $id: router exit 75 (first hold; queued, not delivered, not acked)" >> "$BR/route.err"; fi   # first-time hold: its own line, outside the HELD_LOG_SEC stamp
        mkdir -p "$RTD/held" && : > "$RTD/held/$id"; echo "ack-refused $id: held-unreadable (router exit 75; queued, not acked)" >&2
      elif [ $rc -ne 0 ] && held "$id"; then held_err "$id" "$rc"; fi   # a previously held id stays held and queued (no fail-open to the pane), but a router failure is logged
    fi
    [ -f "$c" ] || continue
    rm -f "$RTD/held/$id"
    rt="$(jget "$c" route)"
    if [ "$rt" = fable ] && [ "${BR_FABLE:-1}" != 0 ] && [ -x "$FEB" ]; then   # real escalation (A1148 defect 11-07): separate Fable process, once per id
      ( setsid "$FEB" "$f" >> "$BR/fable-esc.log" 2>&1 & ) 
    fi
    if [ "$rt" = deterministic ] || [ "$rt" = haiku ]; then
      if evidence_ok "$id"; then ackone "$f"; else echo "$(iso) ack-refused $id no-consumer-evidence reason=$EV_WHY" >> "$BR/deliveries.log"; echo "ack-refused $id: $EV_WHY (route=$rt; queued, not acked)" >&2; fi
    fi
  done
}
FEB="${BR_FABLE_BIN:-$HOME/.local/bin/ctl-fable-escalate.sh}"
fable_note() { local r="${FE_DIR:-$HOME/.cache/aide/fable-esc}/$1.json"; if [ -s "$r" ]; then printf ' fable-verdict=%s' "$r"; elif [ -e "${FE_DIR:-$HOME/.cache/aide/fable-esc}/$1.fail" ]; then printf ' fable=FAILED-owned'; else printf ' fable=pending'; fi; }
reason_of() { local c="$RTD/routed/$1.json"; [ -f "$c" ] && jget "$c" reason | tr -d '\n|' | cut -c1-120; }

deliver() { # one line for every pending id
  local f ids="" summary="" n=0 p rc id kind
  for f in "$BR"/queue/*.json; do
    [ -f "$f" ] || continue
    id="$(jget "$f" id)"; kind="$(jget "$f" event.event)"
    deliverable "$id" || continue
    n=$((n+1)); ids="$ids $id"; summary="${summary:+$summary | }$id $kind reason=$(reason_of "$id")$( [ "$(cached_route "$id")" = fable ] && fable_note "$id")"
  done
  [ "$n" -gt 0 ] || return 0
  p="$(pane)"
  if ! pane_ok; then echo "$(iso) no-pane$ids" >> "$BR/deliveries.log"; PANE_OK=false; return 0; fi
  PANE_OK=true
  "$TMUXB" send-keys -t "$p" -l "ctl-event $n pending: $summary ; read: ctl-event-bridge.sh pending ; ack: ctl-event-bridge.sh ack <id>"; rc=$?
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
  if [ "$want" = "--all" ]; then   # acks only ids with consumer evidence (deterministic/haiku: result + routed cache); pane-delivered, unseen and held ids stay queued
    local skipped=""
    sweep_held
    for f in "$BR"/queue/*.json; do
      [ -f "$f" ] || continue
      id="$(basename "$f" .json)"
      if ! held "$id" && handled_by_router "$id" && ackone "$f"; then n=$((n+1)); else skipped="$skipped $id"; fi
    done
    echo "acked $n"
    [ -z "$skipped" ] || { echo "skipped (no consumer evidence):$skipped" >&2; return 1; }
    return 0
  fi
  [[ "$want" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "unknown id: $want" >&2; return 1; }
  ( flock 9
    if [ ! -f "$BR/queue/$want.json" ]; then   # no queued delivery: done/ is the record of an already-acked one
      if [ -f "$BR/done/$want.json" ]; then echo "already acked: $want"; exit 0; fi
      echo "unknown id: $want" >&2; exit 1
    fi
    ack_ok "$want" || exit 1   # a queued file beside a done/ entry is a new delivery of the id: it needs its own evidence
    ackone_locked "$BR/queue/$want.json" && echo "acked 1"
  ) 9>"$BR/.ack.lock"
}
ackone_locked() { # caller holds the queue lock (fd 9); the first delivery of an id is done/<id>.json + receipt <id>, a later delivery of the same id gets done/<id>.rN.json + receipt <id>.rN (never overwrites, never deleted unrecorded)
  local f="$1" id key n=0 extra=""; id="$(basename "$f" .json)"; key="$id"
  [ -f "$f" ] || return 0
  while [ -e "$BR/done/$key.json" ]; do n=$((n+1)); key="$id.r$n"; extra=" delivery=r$n"; done
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); d["acked"]=int(sys.argv[2]); json.dump(d,open(sys.argv[3]+".tmp","w"))' "$f" "$(epoch)" "$BR/done/$key.json" && mv "$BR/done/$key.json.tmp" "$BR/done/$key.json" && rm -f "$f" \
    && clear_held "$id" && handled_receipt "$key" && echo "$(iso) ack $id$extra" >> "$BR/deliveries.log"
}
ackone() { # serialized per queue root (flock): a concurrent ack of the same delivery finds the queue file gone and is a no-op
  ( flock 9; ackone_locked "$1" ) 9>"$BR/.ack.lock"
}
# The ledger done-check for an event row is `test -e $RTD/handled/<id>`; the ack is the handler's completion, so it writes the receipt (atomic: tmp + mv).
handled_receipt() {
  local id="$1" h="$RTD/handled"
  mkdir -p "$h" && : > "$h/.$id.tmp.$$" && mv -f "$h/.$id.tmp.$$" "$h/$id"
}

selftest() {
  local T; T="$(mktemp -d)"; local f=0
  printf '#!/bin/sh\necho "$@" >> %s/tmux.log\n[ "$1" = list-panes ] && echo claude\nexit 0\n' "$T" > "$T/tmux"
  printf '#!/bin/sh\nl=$(head -n1 %s/ev); if [ -n "$l" ]; then sed -i 1d %s/ev; echo "$l"; else echo {\\"event\\":\\"timeout\\"}; fi\n' "$T" "$T" > "$T/ew"
  chmod +x "$T/tmux" "$T/ew"; echo '{"event":"inbox","detail":{}}' > "$T/ev"
  env -i HOME="$T" PATH="$PATH" BR_DIR="$T/br" EW_BIN="$T/ew" TMUX_BIN="$T/tmux" CTL_PANE=t:0.0 BR_CYCLES=2 bash "$SELF" run
  [ "$(count "$T/br/queue")" = 1 ] && grep -q 'send-keys' "$T/tmux.log"; [ $? = 0 ] || f=1
  env -i HOME="$T" PATH="$PATH" BR_DIR="$T/br" bash "$SELF" ack --all >/dev/null 2>&1; [ "$(count "$T/br/queue")" = 1 ] || f=1   # pane-delivered: --all leaves it queued
  env -i HOME="$T" PATH="$PATH" BR_DIR="$T/br" bash "$SELF" ack "$(basename "$(ls "$T"/br/queue/*.json | head -1)" .json)" >/dev/null
  [ "$(count "$T/br/queue")" = 0 ] && [ "$(count "$T/br/done")" = 1 ] || f=1
  rm -rf "$T"; echo "ctl-event-bridge selftest: $([ $f = 0 ] && echo ALL PASS || echo FAILURES)"; return $f
}

case "${1:-}" in
  run) run ;;
  pending) for f in "$BR"/queue/*.json; do [ -f "$f" ] && ! held "$(basename "$f" .json)" && { cat "$f"; echo; }; done; exit 0 ;;
  ack) shift; ack "${1:-}" ;;
  status) cat "$BR/status.json" 2>/dev/null || echo '{"status":"no status yet"}' ;;
  --selftest) selftest ;;
  *) echo "usage: ctl-event-bridge.sh run|pending|ack <id>|--all|status|--selftest" >&2; exit 2 ;;
esac
