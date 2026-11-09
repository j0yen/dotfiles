#!/usr/bin/env bash
# followup-deliver.sh: the default FOLLOWUP_DELIVER_CMD (ledger asks A1307, A1346). Reads one outbox entry (JSON) on stdin. Exit 0 only when everything was sent / the bell rang, so the outbox keeps the entry otherwise.
# - no .dest: rings the owning seat's bell with seat-event.sh (appends to the seat's events log; no model turn started by this script).
# - .dest (e.g. discord:#ops): sends .summary and .attachment through `hermes send`, once per (dest, task, rev, result, kind) and per part.
#   A durable {"sending_part":true,...} marker is appended BEFORE each remote send and cleared ({"send_cleared":true}) when hermes returns an error, or turned into the
#   sent_part record when it returns success. A marker still open on replay means a crash left the outcome UNKNOWN (hermes send has no readback): that part is NEVER
#   resent; a {"needs_reconcile":true,...} record naming the part is appended, the seat bell rings once, later parts are held and the exit is 1 (delivered stays false).
#   A human settles it by appending {"reconciled":true,"key":K,"part":P,"action":"sent"|"resend"} to the outbox.
#   Each returned message id is recorded as a {"sent_part":true,...} line in the SAME outbox before the next part; a repeat or a second line with the
#   same identity sends nothing. A 429 on the attachment is retried with backoff (a numeric Retry-After clamped to FOLLOWUP_RETRY_AFTER_MAX, else 2^n s), then the file
#   goes out as chunked text; a part that never sent leaves exit 1, so the entry stays undelivered and the parts already sent are not repeated. An empty attachment
#   file (0 bytes) sends a one-line empty-attachment note as the attachment part and the item is delivered.
# Env: SEAT_EVENT_BIN (default seat-event.sh on PATH / ~/.local/bin); FOLLOWUP_OUTBOX / FOLLOWUP_STATE_DIR (as followup-eval.py); FOLLOWUP_DELIVER_RETRIES (default 3);
#      FOLLOWUP_CHUNK_BYTES (default 1800); FOLLOWUP_RETRY_AFTER_MAX (default 300 s); FOLLOWUP_LOCK_HELD (set by followup-eval.py replay, which already holds the state lock).
set -u
command -v jq >/dev/null 2>&1 || exit 1
in="$(cat)"; [ -n "$in" ] || exit 1
seat="$(jq -r '.seat // "ctl"' <<<"$in" 2>/dev/null)"; id="$(jq -r '.id // empty' <<<"$in" 2>/dev/null)"
[ -n "$id" ] || exit 1
dest="$(jq -r '.dest // empty' <<<"$in" 2>/dev/null)"
if [ -z "$dest" ]; then
  line="FOLLOW-UP $(jq -r '.kind // "obligation"' <<<"$in") $id: $(jq -r '.detail // ""' <<<"$in")"
  bin="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"
  [ -x "$bin" ] || bin="$(command -v seat-event.sh)" || exit 1
  SEAT_EVENT_NOWAKE=1 EVENT_SOURCE=followup-loop "$bin" "$seat" "$line" >/dev/null 2>&1
  exit $?
fi

sd="${FOLLOWUP_STATE_DIR:-$HOME/.local/state/followup-loop}"; ob="${FOLLOWUP_OUTBOX:-$sd/outbox.jsonl}"
retries="${FOLLOWUP_DELIVER_RETRIES:-3}"; chunk="${FOLLOWUP_CHUNK_BYTES:-1800}"
key="$(jq -r '[.dest, (.task // .id), (.rev // 0), (.result // .id), (.kind // "result")] | map(tostring) | join("|")' <<<"$in")"
summary="$(jq -r '.summary // empty' <<<"$in")"; att="$(jq -r '.attachment // empty' <<<"$in")"
if [ -z "${FOLLOWUP_LOCK_HELD:-}" ]; then   # one sender per state dir at a time: check, send and record are atomic against concurrent senders
  mkdir -p "$sd" && exec 9>"$sd/lock" && flock 9 || exit 1
fi
mkdir -p "$(dirname "$ob")"; [ -e "$ob" ] || : >"$ob"

sent() { jq -e -s --arg k "$key" --arg p "$1" 'any(.[]; (.sent_part==true or (.reconciled==true and .action=="sent")) and .key==$k and .part==$p)' "$ob" >/dev/null 2>&1; }
record() { jq -nc --arg k "$key" --arg p "$1" --arg m "$2" --arg d "$dest" --arg ts "$(date -Is)" \
  '{sent_part:true,delivered:true,key:$k,part:$p,message_id:$m,dest:$d,ts:$ts}' >>"$ob"; }
mark() { # kind part [marker_ts]: kind = sending_part | send_cleared | needs_reconcile
  jq -nc --arg kind "$1" --arg k "$key" --arg p "$2" --arg d "$dest" --arg i "$id" --arg ts "$(date -Is)" --arg mts "${3:-}" \
    '{($kind):true,key:$k,part:$p,dest:$d,id:$i,ts:$ts} + (if $mts == "" then {} else {marker_ts:$mts} end)' >>"$ob"; }
pstate() { # part -> "sending <ts>" when the last marker for it is an open sending_part, else "ok"
  jq -r -s --arg k "$key" --arg p "$1" '[.[] | select(.key==$k and .part==$p and (.sent_part==true or .sending_part==true or .send_cleared==true or .reconciled==true))] | last
    | if . != null and .sending_part == true then "sending " + .ts else "ok" end' "$ob" 2>/dev/null; }
reconcile() { # part marker_ts: surface the unknown part once per marker (record + bell), never resend
  jq -e -s --arg k "$key" --arg p "$1" --arg t "$2" 'any(.[]; .needs_reconcile==true and .key==$k and .part==$p and .marker_ts==$t)' "$ob" >/dev/null 2>&1 && return 0
  mark needs_reconcile "$1" "$2"
  local bin="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"; [ -x "$bin" ] || bin="$(command -v seat-event.sh)" || return 0
  SEAT_EVENT_NOWAKE=1 EVENT_SOURCE=followup-loop "$bin" "$seat" "FOLLOW-UP needs-reconcile $id: part $1 of $key may already be sent (crash between send and record); not resent, settle with a reconciled record" >/dev/null 2>&1
  return 0; }
rmax="${FOLLOWUP_RETRY_AFTER_MAX:-300}"; [[ "$rmax" =~ ^[0-9]{1,6}$ ]] || rmax=300
send_retry() { # body -> sets mid; 0 when hermes accepted it. A rate-limit reply sleeps a validated Retry-After (else 2^n s) and tries again, up to $retries attempts.
  local body="$1" n=1 out rc wait ra backoff
  while :; do
    out="$(hermes send --to "$dest" --json "$body" 2>/dev/null)"; rc=$?
    if [ "$rc" = 0 ]; then mid="$(jq -r '.message_id // empty' <<<"$out" 2>/dev/null)"; return 0; fi
    [ "$n" -ge "$retries" ] && return 1
    backoff=$((2 ** n)); [ "$backoff" -gt "$rmax" ] && backoff=$rmax; wait=$backoff
    ra="$(jq -r '.retry_after // empty | if type=="string" or type=="number" then tostring else empty end' <<<"$out" 2>/dev/null)"
    if [[ "$ra" =~ ^[0-9]+(\.[0-9]*)?$ ]]; then   # plain non-negative decimal only; anything else (text, sign, exponent) falls back to the backoff
      ra="${ra%%.*}"; if [ "${#ra}" -gt 6 ]; then ra=$rmax; else ra=$((10#${ra:-0})); fi
      [ "$ra" -gt "$rmax" ] && ra=$rmax
      [ "$ra" -gt "$wait" ] && wait=$ra
    fi
    sleep "$wait"; n=$((n + 1))
  done
}
deliver_part() { # part body -> 0 sent, 1 failed (retryable), 2 outcome unknown (held for reconcile)
  local part="$1" body="$2" st
  st="$(pstate "$part")"
  if [ "${st%% *}" = sending ]; then reconcile "$part" "${st#* }"; return 2; fi
  mark sending_part "$part"
  if send_retry "$body"; then record "$part" "$mid"; return 0; fi
  mark send_cleared "$part"; return 1
}
mid=""; fail=0; held=0
if [ -n "$summary" ] && ! sent summary; then
  deliver_part summary "$summary"; case $? in 0) ;; 1) fail=1;; *) fail=1; held=1;; esac
fi
if [ -n "$att" ] && [ "$held" = 0 ] && ! sent attachment; then
  if [ ! -r "$att" ]; then fail=1
  elif [ ! -s "$att" ]; then   # 0 bytes: nothing to chunk, so say so and finish instead of failing forever
    deliver_part attachment "[attachment empty: $(basename "$att")]" || fail=1
  else
    started=0; jq -e -s --arg k "$key" 'any(.[]; (.sent_part==true or .sending_part==true) and .key==$k and (.part|startswith("attachment-chunk-")))' "$ob" >/dev/null 2>&1 && started=1
    ok=0
    if [ "$started" = 0 ]; then
      # the file itself, one try per backoff round; a 429 here falls through to chunked text
      deliver_part attachment "MEDIA:$att"; rc=$?
      if [ "$rc" = 0 ]; then ok=1; elif [ "$rc" = 2 ]; then ok=1; fail=1; fi
    fi
    if [ "$ok" = 0 ]; then
      i=0; allok=1
      while IFS= read -r -d '' part || [ -n "$part" ]; do
        i=$((i + 1))
        sent "attachment-chunk-$i" && continue
        deliver_part "attachment-chunk-$i" "$part" || { allok=0; break; }
      done < <(python3 -I -c 'import sys
n=int(sys.argv[2]); t=open(sys.argv[1],errors="replace").read()
for i in range(0,len(t),n): sys.stdout.write(t[i:i+n]+"\0")' "$att" "$chunk")
      if [ "$allok" = 1 ] && [ "$i" -gt 0 ]; then record attachment "$mid"; else fail=1; fi
    fi
  fi
fi
exit "$fail"
