#!/usr/bin/env bash
# ctl-event-bridge.sh: durable event -> ctl tmux pane bridge with ack + retry (Hermes recovery 11-06).
# The one-shot ctl-event-wait.sh exits after one event; this loop re-arms it forever, queues each actionable event
# on disk, and re-delivers every unacked event to the ctl pane every RETRY_SEC until `ack`.
#   run                 loop (BR_CYCLES=0 forever; SIGTERM ends it)
#   pending             print each unacked queue/*.json, one per line
#   ack <id>|--all      move to done/ (unknown id -> exit 1; an already-acked id with no queued file -> exit 0, no second ack; a re-queued id is a new delivery: own evidence, own done/<id>.rN.json + receipt). --all acks only ids with consumer
#                       evidence (deterministic/haiku: result + routed cache), prints the skipped ids and exits 1; pane-delivered ids need `ack <id>`
#   resolve <id> --disposition <class> --reason <text> [--by <who>]   operator exit for a failure-held id (typed failure, UNKNOWN, held-unreadable): writes dispositions/<id>.json (success=false) and moves the
#                       queue file to resolved/ (kept); no done/ entry, no handled receipt, never replayed; refuses an id ack would accept
#   requeue <id>        the sanctioned way to deliver an acked/resolved event again: writes a NEW queue file (new attempt_id, attempts 0) from the latest done/ (else resolved/) record; refuses an id that is already queued or unknown.
#                       Copying a done/ record or an old queue payload back into queue/ by hand is NOT a requeue: it is recognised as the already-acked delivery, NOT redelivered, kept under recovered/ and announced (stderr + deliveries.log).
#   status              print status.json
#   --selftest          small fixture check in a temp HOME (stub tmux + stub waiter)
# Pre-Fable routing (A1148): before delivery every queued id goes through ctl-event-route.sh (deterministic | haiku | fable).
# Only route=fable ids reach the pane; deterministic/haiku-handled ids are acked by the bridge AFTER the router wrote the
# mechanical result and the routed cache ($RT_DIR/routed/<id>.json). An id with a cache but no ack is acked from the cache
# (no second model call). A missing router or a router failure leaves the id queued and delivered (never dropped).
# No-cache evidence (R4-1): a result file without the routed cache (the router crashed between its two writes, or is absent) is judged by the SAME rules as the cache-present path (typed success only; UNKNOWN, any nonzero exit
# and any typed failure refused; attempt-bound); `resolve` accepts such an id with a non-success disposition. A success result with no cache is still acked by explicit `ack <id>` (Amendment 2: the result is the mechanical evidence,
# the cache is the router's index); `ack --all` and the run loop still need the cache. No result and no cache = pane-delivered/legacy id: the consumer's explicit ack.
# Version handshake (R4-6, protocol attempt-v1): the router file carries `# ctl-event-proto: attempt-v1`; a bridge whose router (a real ctl-event-route.sh) lacks it pauses routing, delivery and acks with a typed `router-version-mismatch` line in route.err;
# the router refuses to route for a calling bridge that does not announce BR_PROTO=attempt-v1 (`bridge-version-mismatch`, exit 3). Ship both or neither.
# BR_ROUTE=0 disables routing (the legacy deliver-everything path).
# Attempt identity (A1296 R3-1): every queue file instance (a delivery) carries `attempt_id`; the router copies it into its cache/result/stage files and archives an earlier attempt's artifacts, the bridge
# accepts evidence only when both files carry the delivery's attempt_id (file mtimes are not consulted). Ack/resolve recovery after a crash is keyed on the same id (done/<id>*.json, dispositions/<id>*.json).
# Crash order in an ack: done record, receipt, queue removal (so no crash leaves a done/ entry without its receipt and without a queue file: settle work is O(queue), not O(done/)).
# Test seams (default unset): BR_CRASH_AT=<pre|tmp|done|receipt|rm|clear|disp>, BR_PAUSE_AFTER_SETTLE=<sec>. Ship the bridge and the router together (an attempt-unaware router leaves every cache non-current).
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
PROTO=attempt-v1; ROUTER_MISMATCH=0
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
  # attempt_id = the identity of this delivery (queue file instance): the router copies it into its result, cache and stage files, the bridge accepts evidence only when it matches
  printf '%s' "$1" | python3 -I -c 'import json,sys
ev=json.load(sys.stdin)
json.dump({"id":sys.argv[1],"event":ev,"created":int(sys.argv[2]),"attempts":0,"last_delivery":0,"attempt_id":sys.argv[4]},open(sys.argv[3]+".tmp","w"))' "$id" "$(epoch)" "$BR/queue/$id.json" "$(epoch)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" || return 1
  mv "$BR/queue/$id.json.tmp" "$BR/queue/$id.json"; printf '%s' "$id"
}

# A1255: the row marker is looked up in the canonical ledger (asks-view); no TSV file is read or passed on.
cache_current() { # the routed cache exists and belongs to THIS delivery (same attempt_id as the queue file; both absent = legacy). Compares PRINTED values only: the single TYPED guard (str vs int, "" vs absent) is evidence_ok's attempt check (Z9b, R4-2)
  local c="$RTD/routed/$1.json"
  [ -f "$c" ] && [ "$(jget "$BR/queue/$1.json" attempt_id)" = "$(jget "$c" attempt_id)" ]
}
cached_route() { cache_current "$1" && jget "$RTD/routed/$1.json" route; }
held() { [ -e "$RTD/held/$1" ]; } # the router held this id (exit 75, an unreadable file): queued, but nothing acts on it until it routes
deliverable() { # unrouted (router absent/failed: fail-safe, never dropped) or route=fable; error/other routes and held ids never reach the pane
  [ "${BR_ROUTE:-1}" = 0 ] && return 0
  held "$1" && return 1
  local rt; rt="$(cached_route "$1")"; [ -z "$rt" ] || [ "$rt" = fable ]
}
evidence_ok() { # evidence_ok <id> [nocache]. typed fail-closed check for a deterministic/haiku id: results/<id>.json and routed/<id>.json must match the schema exactly; success = exit 0 and no typed failure
  # evidence belongs to ONE delivery: both files must carry the queue file's attempt_id (a requeue is a new delivery with a new attempt_id; file mtimes are not consulted).
  # Sets EV_WHY to the refusal class.
  local id="$1" row out
  EV_WHY=""
  out="$(python3 -I -c 'import json,os,re,sys
rd,cd,eid,qf,df,mode=sys.argv[1:7]
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
nc=mode=="nocache"   # R4-1: no routed cache, a result file exists: the result alone is judged (its route/row/attempt_id stand in for the cache)
r=load(rf); c=load(cf) if not nc else (dict(id=eid,route=r.get("route"),row=r.get("row",""),attempt_id=r.get("attempt_id")) if r is not None else None)
if r is None or c is None: no("missing")
if unk(r) or unk(c): no("UNKNOWN")
fab=nc and r.get("route")=="fable"   # a fable-route result is the consumer'"'"'s word (same as the cache-present path); only UNKNOWN and the attempt binding apply
if not fab:
    if c.get("id")!=eid or c.get("route") not in ("deterministic","haiku"): no("invalid-cache")
    if r.get("id")!=eid or r.get("route",c["route"])!=c["route"]: no("invalid-result-id")
    if not isinstance(r.get("result"),str) or not re.fullmatch(r"[a-z][a-z0-9-]*",r["result"]): no("invalid-result")
    e=r.get("exit")
    if not isinstance(e,int) or isinstance(e,bool): no("invalid-exit")
    if e!=0 or re.search(r"blocked|error|fail|refused",r["result"]): no("typed-failure")   # router typed failures: blocked-row exit 2, error-row exit 4, any nonzero exit
rw=c.get("row","")
if not isinstance(rw,str): no("invalid-cache")
q=load(qf); qa=q.get("attempt_id") if q else None
if qa is not None and not (isinstance(qa,str) and re.fullmatch(r"[A-Za-z0-9._-]{1,64}",qa)): no("invalid-attempt")
rq=os.path.isfile(df)   # a done/<id>.json beside this queue file: this is a requeue, a new delivery of an acked id
if rq:
    cr=q.get("created") if q else None
    if not isinstance(cr,int) or isinstance(cr,bool): no("invalid-created")
    if qa is None: no("stale-requeue")   # a requeued delivery with no attempt identity cannot be bound to any evidence
if r.get("attempt_id")!=qa or c.get("attempt_id")!=qa: no("stale-requeue" if rq else "attempt-mismatch")
print("OK\t"+rw)' "$RTD" "$RTD" "$id" "$BR/queue/$id.json" "$BR/done/$id.json" "${2:-cache}")" || { EV_WHY=invalid; return 1; }
  if [ "${out%%$'\t'*}" != OK ]; then EV_WHY="${out#*$'\t'}"; return 1; fi
  row="${out#*$'\t'}"
  [ -z "$row" ] || "${ASKS_VIEW_BIN:-asks-view}" 2>/dev/null | grep -qF "event:$id" || { EV_WHY=row-marker; return 1; }
}
ack_ok() { # explicit `ack <id>`: a held id is refused (held-unreadable without a cache, inconsistent with one); deterministic/haiku ids need evidence_ok; fable-routed and unrouted (pane-delivered) ids are acked by the consumer's word; any other cache is refused
  local id="$1" c="$RTD/routed/$1.json" rt
  EV_WHY=""
  if held "$id"; then
    EV_WHY=held-unreadable
    if [ -e "$c" ]; then echo "refused $id: held marker beside a routed cache (inconsistent state; nothing acts until the router re-routes it)" >&2
    else echo "refused $id: held-unreadable (the router held it, exit 75; not success, it stays queued until the router routes it)" >&2; fi
    return 1
  fi
  if [ ! -e "$c" ]; then
    [ -e "$RTD/results/$id.json" ] || return 0   # no cache, no result, not held: pane-delivered/legacy id, the consumer's explicit ack is the evidence
    evidence_ok "$id" nocache || { echo "refused $id: a result file exists but the routed cache does not (router crashed between its writes, or is absent): same rules as with a cache, typed success only (exit 0, id bound, never UNKNOWN or a typed failure, the same attempt_id as this delivery); reason class: $EV_WHY; resolve it, or let the router re-route it" >&2; return 1; }
    return 0
  fi
  if ! cache_current "$id"; then EV_WHY=attempt-mismatch; [ ! -f "$BR/done/$id.json" ] || EV_WHY=stale-requeue; echo "refused $id: the routed cache belongs to another delivery of this id (attempt_id differs); the router has to route this delivery first (reason class: $EV_WHY)" >&2; return 1; fi
  rt="$(jget "$c" route)"
  case "$rt" in
    deterministic|haiku) evidence_ok "$id" || { echo "refused $id: route=$rt needs the typed success result (exit 0, id bound, never UNKNOWN or a typed failure, the same attempt_id as this delivery) and the routed cache; reason class: $EV_WHY" >&2; return 1; } ;;
    fable) ;;
    *) EV_WHY=invalid-cache; echo "refused $id: routed cache is missing/malformed or names route '${rt:-none}'" >&2; return 1 ;;
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
router_proto_ok() { # a real router (its header names ctl-event-route.sh) must carry the protocol line; a stub or custom RT_BIN without that header is outside the handshake
  local r; r="$(readlink -f "$RTB" 2>/dev/null)" || return 0
  head -n 5 "$r" 2>/dev/null | grep -q 'ctl-event-route\.sh' || return 0
  head -n 40 "$r" 2>/dev/null | grep -qx "# ctl-event-proto: $PROTO"
}
proto_pause_msg() { # the one mismatch wording (route.err / ack refusal): routing, delivery AND acks are paused
  echo "router-version-mismatch: $RTB does not carry 'ctl-event-proto: $PROTO' (bridge/router pair differs); routing, delivery and acks are paused, nothing is acked, sent or dropped; install the matching ctl-event-bridge.sh + ctl-event-route.sh pair"
}
acks_paused() { # F1: while routing is on and the router fails the handshake, ack <id> and ack --all refuse (nothing written); resolve stays the operator exit
  [ "${BR_ROUTE:-1}" = 0 ] && return 1
  [ -x "$RTB" ] || return 1
  router_proto_ok && return 1
  echo "ack-refused: $(proto_pause_msg)" >&2
  return 0
}
route_pending() { # route each queued id once; ack deterministic/haiku ids only after consumer evidence exists
  [ "${BR_ROUTE:-1}" = 0 ] && return 0
  sweep_held
  [ -x "$RTB" ] || return 0
  if ! router_proto_ok; then
    ROUTER_MISMATCH=1
    echo "$(iso) $(proto_pause_msg)" | tee -a "$BR/route.err" >&2
    return 0
  fi
  ROUTER_MISMATCH=0
  local f id c rt rc att
  ( flock 9; settle_leftovers ) 9>"$BR/.ack.lock"   # crash recovery first: a queue file whose delivery is already acked/resolved is finished, never re-routed
  for f in "$BR"/queue/*.json; do
    [ -f "$f" ] || continue
    id="$(jget "$f" id)"; [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    stamp_requeue "$f" "$id"
    c="$RTD/routed/$id.json"
    if ! cache_current "$id"; then   # no cache, or the cache belongs to an earlier delivery of this id (the router archives it and routes this attempt fresh)
      RT_DIR="$RTD" BR_PROTO="$PROTO" "$RTB" route "$f" >/dev/null 2>>"$BR/route.err"
      rc=$?
      if [ $rc -eq 75 ]; then
        if ! held "$id"; then echo "$(iso) held id $id: router exit 75 (first hold; queued, not delivered, not acked)" >> "$BR/route.err"; fi   # first-time hold: its own line, outside the HELD_LOG_SEC stamp
        mkdir -p "$RTD/held" && : > "$RTD/held/$id"; echo "ack-refused $id: held-unreadable (router exit 75; queued, not acked)" >&2
      elif [ $rc -ne 0 ] && held "$id"; then held_err "$id" "$rc"; fi   # a previously held id stays held and queued (no fail-open to the pane), but a router failure is logged
    fi
    cache_current "$id" || continue
    rm -f "$RTD/held/$id"
    rt="$(jget "$c" route)"
    if [ "$rt" = fable ] && [ "${BR_FABLE:-1}" != 0 ] && [ -x "$FEB" ]; then   # real escalation (A1148 defect 11-07): separate Fable process, once per id
      ( setsid "$FEB" "$f" >> "$BR/fable-esc.log" 2>&1 & ) 
    fi
    if [ "$rt" = deterministic ] || [ "$rt" = haiku ]; then
      att="$(jget "$f" attempt_id)"   # F2: the delivery the evidence is judged for; ackone re-verifies it under the lock
      if evidence_ok "$id"; then ackone "$f" "$att"; else echo "$(iso) ack-refused $id no-consumer-evidence reason=$EV_WHY" >> "$BR/deliveries.log"; echo "ack-refused $id: $EV_WHY (route=$rt; queued, not acked)" >&2; fi
    fi
  done
}
FEB="${BR_FABLE_BIN:-$HOME/.local/bin/ctl-fable-escalate.sh}"
fable_note() { local r="${FE_DIR:-$HOME/.cache/aide/fable-esc}/$1.json"; if [ -s "$r" ]; then printf ' fable-verdict=%s' "$r"; elif [ -e "${FE_DIR:-$HOME/.cache/aide/fable-esc}/$1.fail" ]; then printf ' fable=FAILED-owned'; else printf ' fable=pending'; fi; }
reason_of() { local c="$RTD/routed/$1.json"; [ -f "$c" ] && jget "$c" reason | tr -d '\n|' | cut -c1-120; }

deliver() { # one line for every pending id
  local f ids="" summary="" n=0 p rc id kind
  [ "${ROUTER_MISMATCH:-0}" = 1 ] && return 0   # R4-6: a mismatched router pauses delivery too (no pane spam on every retry)
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

crash_at() { # test seam (default unset = no effect): BR_CRASH_AT=<step> SIGKILLs this process at that step boundary of ackone_locked/resolve, leaving the on-disk state a crash would
  [ "${BR_CRASH_AT:-}" = "$1" ] || return 0
  kill -9 "$$" 2>/dev/null; kill -9 "$BASHPID"
}
rec_key() { # <dir> <id> <attempt_id>: print the key (<id> or <id>.rN) of a record in <dir> that is this delivery's (same attempt_id)
  python3 -I -c 'import json,os,re,sys
d,i,a=sys.argv[1:4]
for n in (sorted(os.listdir(d)) if os.path.isdir(d) else []):
    if re.fullmatch(re.escape(i)+r"(\.r[0-9]+)?\.json",n):
        try: j=json.load(open(d+"/"+n))
        except Exception: continue
        if isinstance(j,dict) and j.get("attempt_id")==a: print(n[:-5]); break' "$1" "$2" "$3"
}
stamp_requeue() { # a legacy queue file (no attempt_id) beside a done/ entry is a requeued delivery: give it its own attempt identity (atomic rewrite under the lock)
  local f="$1" id="$2"
  [ -f "$BR/done/$id.json" ] && [ -z "$(jget "$f" attempt_id)" ] || return 0
  ( flock 9
    [ -f "$f" ] && [ -z "$(jget "$f" attempt_id)" ] || exit 0
    python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); d["attempt_id"]=sys.argv[2]; json.dump(d,open(sys.argv[1]+".tmp","w"))' "$f" "$(epoch)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" && mv "$f.tmp" "$f"
  ) 9>"$BR/.ack.lock"
}
same_legacy() { # the queue file and done/<id>.json both carry no attempt_id and the same id/event/created: the old bridge's crash leftover (or a hand copy-back)
  python3 -I -c 'import json,sys
def l(p):
    try: d=json.load(open(p))
    except Exception: return None
    return d if isinstance(d,dict) else None
q=l(sys.argv[1]); d=l(sys.argv[2])
ok=q is not None and d is not None and "attempt_id" not in q and "attempt_id" not in d and all(k in q and q.get(k)==d.get(k) for k in ("id","event","created"))
sys.exit(0 if ok else 1)' "$1" "$2"
}
settle_one() { # caller holds the lock. A queue file whose attempt_id already has a done/ record (crash after the done write) or a disposition record (crash after the record) is the SAME delivery: finish what the crash cut off, never a second record.
  # A legacy pair (done/<id>.json and queue/<id>.json, neither with attempt_id, same id/event/created: R4-7) is recovered the same way. A recovered queue file is announced and its copy kept under recovered/ (a hand copy-back is not a requeue: use `requeue <id>`).
  local f="$1" id att k
  [ -f "$f" ] || return 1
  id="$(basename "$f" .json)"; att="$(jget "$f" attempt_id)"
  if [ -z "$att" ]; then
    [ -f "$BR/done/$id.json" ] && same_legacy "$f" "$BR/done/$id.json" || return 1
    recovered_note "$f" "$id" "$id" "legacy done/$id.json (no attempt_id)"; clear_held "$id"; [ -e "$RTD/handled/$id" ] || handled_receipt "$id"
    echo "$(iso) ack-recovered $id key=$id legacy (queue file removed, original receipt kept; to deliver again use: ctl-event-bridge.sh requeue $id)" >> "$BR/deliveries.log"; return 0
  fi
  if k="$(rec_key "$BR/done" "$id" "$att")" && [ -n "$k" ]; then
    recovered_note "$f" "$id" "$k" "done/$k.json (attempt $att)"; clear_held "$id"; [ -e "$RTD/handled/$k" ] || handled_receipt "$k"
    echo "$(iso) ack-recovered $id key=$k (queue file removed, original receipt kept; to deliver again use: ctl-event-bridge.sh requeue $id)" >> "$BR/deliveries.log"; return 0
  fi
  if k="$(rec_key "$BR/dispositions" "$id" "$att")" && [ -n "$k" ]; then
    mkdir -p "$BR/resolved"; mv -f "$f" "$BR/resolved/$k.json"; clear_held "$id"
    echo "$(iso) resolve-recovered $id key=$k" >> "$BR/deliveries.log"; return 0
  fi
  return 1
}
recovered_note() { # <queue file> <id> <key> <what>: keep a copy of the queue file being removed as an already-handled delivery, say so, remove it
  mkdir -p "$BR/recovered"; cp "$1" "$BR/recovered/$3.$(epoch).json" 2>/dev/null
  echo "recovered $2: the queue file matches the already-acked delivery $4, so it is treated as that delivery's crash leftover and NOT redelivered (copy kept under $BR/recovered/); to deliver this event again use: ctl-event-bridge.sh requeue $2" >&2
  rm -f "$1"
}
settle_leftovers() { # caller holds the lock: finish every cut-off ack/resolve. Work is O(queue): the ack writes its receipt BEFORE removing the queue file, so no crash leaves a done/ entry without a receipt and without a queue file (R4-3)
  local f
  for f in "$BR"/queue/*.json; do settle_one "$f" || true; done
}

ack() {
  local f id n=0 want="${1:-}"
  [ -n "$want" ] || { echo "usage: ack <id>|--all" >&2; return 2; }
  acks_paused && return 1   # F1: the version-mismatch pause covers acks (header lines 22-23)
  mkdir -p "$BR/queue" "$BR/done"
  if [ "$want" = "--all" ]; then   # acks only ids with consumer evidence (deterministic/haiku: result + routed cache); pane-delivered, unseen and held ids stay queued
    local skipped=""
    ( flock 9; settle_leftovers ) 9>"$BR/.ack.lock"
    [ -z "${BR_PAUSE_AFTER_SETTLE:-}" ] || sleep "$BR_PAUSE_AFTER_SETTLE"   # test seam (default unset): widens the window between the settle pass and the per-id ack so a test can leave a crash leftover inside it
    sweep_held
    for f in "$BR"/queue/*.json; do
      [ -f "$f" ] || continue
      id="$(basename "$f" .json)"; att="$(jget "$f" attempt_id)"   # F2: judged-for attempt, re-verified under the lock by ackone
      if ! held "$id" && handled_by_router "$id" && ackone "$f" "$att"; then n=$((n+1)); else skipped="$skipped $id"; fi
    done
    echo "acked $n"
    [ -z "$skipped" ] || { echo "skipped (no consumer evidence):$skipped" >&2; return 1; }
    return 0
  fi
  [[ "$want" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "unknown id: $want" >&2; return 1; }
  ( flock 9
    settle_leftovers
    if [ ! -f "$BR/queue/$want.json" ]; then   # no queued delivery: done/ is the record of an already-acked one
      if [ -f "$BR/done/$want.json" ]; then echo "already acked: $want"; exit 0; fi
      if [ -f "$BR/dispositions/$want.json" ]; then echo "resolved by an operator disposition, not acked: $want (no handled receipt)" >&2; exit 1; fi
      echo "unknown id: $want" >&2; exit 1
    fi
    ack_ok "$want" || exit 1   # a queued file beside a done/ entry is a new delivery of the id: it needs its own evidence
    ackone_locked "$BR/queue/$want.json" && echo "acked 1"
  ) 9>"$BR/.ack.lock"
}
ackone_locked() { # caller holds the queue lock (fd 9); the first delivery of an id is done/<id>.json + receipt <id>, a later delivery of the same id gets done/<id>.rN.json + receipt <id>.rN (never overwrites, never deleted unrecorded).
  # Crash-idempotent: the done record carries the queue file's attempt_id, so a restart that finds the queue file beside a done record of the same attempt finishes the original ack (settle_one), never a second one.
  local f="$1" id key n=0 extra="" cur; id="$(basename "$f" .json)"; key="$id"
  [ -f "$f" ] || return 0
  if [ $# -ge 2 ]; then   # F2 (A1296 R3-1): evidence was judged for attempt "$2"; a queue file of another attempt is a NEW delivery (a requeue in the window) and needs its own evidence: skipped, left queued
    cur="$(jget "$f" attempt_id)"
    if [ "$cur" != "$2" ]; then echo "ack-skipped $id: the queue file is a new delivery (attempt ${cur:-none}); the evidence was judged for attempt ${2:-none}; it stays queued and needs its own evidence" >&2; echo "$(iso) ack-skipped $id attempt-changed judged=${2:-none} now=${cur:-none}" >> "$BR/deliveries.log"; return 1; fi
  fi
  settle_one "$f" && return 0
  while [ -e "$BR/done/$key.json" ]; do n=$((n+1)); key="$id.r$n"; extra=" delivery=r$n"; done
  crash_at pre
  python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); d["acked"]=int(sys.argv[2]); json.dump(d,open(sys.argv[3]+".tmp","w"))' "$f" "$(epoch)" "$BR/done/$key.json" || return 1
  crash_at tmp
  mv "$BR/done/$key.json.tmp" "$BR/done/$key.json" || return 1
  crash_at done
  handled_receipt "$key" || return 1   # receipt before the queue removal: a restart that finds done + queue completes the ack (settle_one); no crash leaves a done/ entry without its receipt and without a queue file
  crash_at receipt
  rm -f "$f" || return 1
  crash_at rm
  clear_held "$id"
  crash_at clear
  echo "$(iso) ack $id$extra" >> "$BR/deliveries.log"
}
ackone() { # ackone <queue file> [judged-attempt]: serialized per queue root (flock): a concurrent ack of the same delivery finds the queue file gone and is a no-op; with the attempt the evidence was judged for, the ack is skipped (exit 1) if the file is another attempt
  ( flock 9; ackone_locked "$@" ) 9>"$BR/.ack.lock"
}
# The ledger done-check for an event row is `test -e $RTD/handled/<id>`; the ack is the handler's completion, so it writes the receipt (atomic: tmp + mv).
handled_receipt() {
  local id="$1" h="$RTD/handled"
  mkdir -p "$h" && : > "$h/.$id.tmp.$$" && mv -f "$h/.$id.tmp.$$" "$h/$id"
}

# resolve <id> --disposition <class> --reason <text> [--by <who>]: the operator's exit for a failure-held id (typed failure, UNKNOWN, held-unreadable, any id `ack` refuses).
# Writes a typed disposition record dispositions/<id>[.rN].json (success=false, replayed=false) and moves the queue file to resolved/ (kept, never deleted). No done/ entry, no handled receipt,
# no router call, no pane send: it is a disposition, not a success. An id `ack` would accept is refused (ack it); UNKNOWN is only resolved when an operator names it.
DISPOSITIONS="operator-handled abandoned superseded duplicate not-actionable"
resolve() {
  local id="${1:-}" cls="" reason="" by="operator" bad=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --disposition|--reason|--by) [ $# -ge 2 ] || { bad="$1 needs a value"; break; }
        case "$1" in --disposition) cls="$2";; --reason) reason="$2";; --by) by="$2";; esac; shift 2 ;;
      *) bad="unknown argument $1"; break ;;
    esac
  done
  [ -z "$bad" ] || { echo "resolve: $bad" >&2; return 2; }
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "usage: resolve <id> --disposition <$(echo $DISPOSITIONS | tr ' ' '|')> --reason <text> [--by <who>]" >&2; return 2; }
  case " $DISPOSITIONS " in *" $cls "*) ;; *) echo "resolve: --disposition must be one of: $DISPOSITIONS" >&2; return 2 ;; esac
  python3 -I -c 'import re,sys
r=sys.argv[1]
sys.exit(0 if r.strip() and len(r)<=300 and not re.search(r"[\x00-\x1f\x7f]",r) and sys.argv[2].strip() and len(sys.argv[2])<=60 and not re.search(r"[\x00-\x1f\x7f]",sys.argv[2]) else 1)' "$reason" "$by" || { echo "resolve: --reason is required (1-300 printable characters), --by 1-60" >&2; return 2; }
  mkdir -p "$BR/queue" "$BR/done" "$BR/dispositions" "$BR/resolved"
  ( flock 9
    settle_leftovers
    local f="$BR/queue/$id.json" key="$id" n=0 att why
    if [ ! -f "$f" ]; then
      if [ -f "$BR/dispositions/$id.json" ]; then echo "already resolved: $id"; exit 0; fi
      if [ -f "$BR/done/$id.json" ]; then echo "already acked: $id (nothing to resolve)" >&2; exit 1; fi
      echo "unknown id: $id" >&2; exit 1
    fi
    if ack_ok "$id" 2>/dev/null; then echo "refused resolve $id: not failure-held, ack would accept it; use ack" >&2; exit 1; fi
    why="${EV_WHY:-refused}"
    att="$(jget "$f" attempt_id)"
    while [ -e "$BR/dispositions/$key.json" ]; do n=$((n+1)); key="$id.r$n"; done
    python3 -I -c 'import json,sys
q=json.load(open(sys.argv[1]))
json.dump({"kind":"disposition","id":sys.argv[2],"attempt_id":sys.argv[3] or None,"disposition":sys.argv[4],"reason":sys.argv[5],"evidence_class":sys.argv[6],"by":sys.argv[7],"resolved":int(sys.argv[8]),"success":False,"replayed":False,"queue":q},open(sys.argv[9]+".tmp","w"))' "$f" "$id" "$att" "$cls" "$reason" "$why" "$by" "$(epoch)" "$BR/dispositions/$key.json" || exit 1
    mv "$BR/dispositions/$key.json.tmp" "$BR/dispositions/$key.json" || exit 1
    crash_at disp
    mv -f "$f" "$BR/resolved/$key.json" || exit 1
    clear_held "$id"
    echo "$(iso) resolve $id disposition=$cls class=$why key=$key" >> "$BR/deliveries.log"
    echo "resolved $id disposition=$cls (not acked: no done/ entry, no handled receipt; never replayed; queue file kept at resolved/$key.json)"
  ) 9>"$BR/.ack.lock"
}

# requeue <id>: the sanctioned way to deliver an acked or resolved event again (R4-4). A NEW queue file with a new attempt_id (its own evidence, its own done/<id>.rN.json + receipt); the old records are kept.
requeue() {
  local id="${1:-}"
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "usage: requeue <id>" >&2; return 2; }
  mkdir -p "$BR/queue" "$BR/done"
  ( flock 9
    settle_leftovers
    local f="$BR/queue/$id.json" src
    if [ -e "$f" ]; then echo "refused requeue $id: it is already queued (ack or resolve it first)" >&2; exit 1; fi
    src="$(python3 -I -c 'import os,re,sys
i=sys.argv[2]
def best(d):
    c=[]
    for n in (os.listdir(d) if os.path.isdir(d) else []):
        m=re.fullmatch(re.escape(i)+r"(?:\.r([0-9]+))?\.json",n)
        if m: c.append((int(m.group(1) or 0),d+"/"+n))
    return max(c)[1] if c else ""
print(best(sys.argv[1]+"/done") or best(sys.argv[1]+"/resolved"))' "$BR" "$id")"
    if [ -z "$src" ]; then echo "unknown id: $id (no done/ or resolved/ record to requeue)" >&2; exit 1; fi
    python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
o={"id":d["id"],"event":d["event"],"created":int(sys.argv[3]),"attempts":0,"last_delivery":0,"attempt_id":sys.argv[4]}
json.dump(o,open(sys.argv[2]+".tmp","w"))' "$src" "$f" "$(epoch)" "$(epoch)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')" || { rm -f "$f.tmp"; echo "refused requeue $id: unreadable record $src" >&2; exit 1; }
    mv "$f.tmp" "$f" || exit 1
    echo "$(iso) requeue $id from $(basename "$src") attempt=$(jget "$f" attempt_id)" >> "$BR/deliveries.log"
    echo "requeued $id as a new delivery (attempt $(jget "$f" attempt_id)); it needs its own evidence"
  ) 9>"$BR/.ack.lock"
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
  resolve) shift; resolve "$@" ;;
  requeue) shift; requeue "${1:-}" ;;
  status) cat "$BR/status.json" 2>/dev/null || echo '{"status":"no status yet"}' ;;
  --selftest) selftest ;;
  *) echo "usage: ctl-event-bridge.sh run|pending|ack <id>|--all|resolve <id> --disposition <class> --reason <text>|requeue <id>|status|--selftest" >&2; exit 2 ;;
esac
