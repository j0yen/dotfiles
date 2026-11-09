#!/usr/bin/env bash
# followup-deliver.sh: the default FOLLOWUP_DELIVER_CMD (ledger asks A1307, A1346). Reads one outbox entry (JSON) on stdin. Exit 0 only when everything was sent / the bell rang, so the outbox keeps the entry otherwise.
# - no .dest: rings the owning seat's bell with seat-event.sh (appends to the seat's events log; no model turn started by this script).
# - .dest (e.g. discord:#ops): sends .summary and .attachment through `hermes send`, once per (dest, task, rev, result, kind) and per part.
#   Before ANY send a durable {"sending_part":true,...} marker is committed to the outbox (append, fsync, read back); if the marker cannot be committed nothing is sent,
#   the seat bell rings and the exit is 2. Only a POSITIVELY identified provider rejection (nonzero exit AND an HTTP 429 / rate-limit reply from hermes) may be retried
#   or fall back to chunks, and only that clears the marker ({"send_cleared":true}). Success with a message id turns the marker into a sent_part record. Anything else
#   (any other nonzero exit, a timeout, a transport error, success without a message id, a crash) leaves the outcome UNKNOWN (hermes send has no readback): the marker
#   stays, that part is NEVER resent, ONE {"needs_reconcile":true,...} record + ONE seat bell are raised, later parts are held and the exit is 1 (delivered stays false).
#   A human settles an unknown part with this script (same flock): followup-deliver.sh --reconcile <part> sent|resend [--key K] < event.json
#   (sent = it did arrive, resend = it did not, release it). Nothing appends to a live outbox by hand.
#   Each returned message id is recorded as a {"sent_part":true,...} line in the SAME outbox before the next part; a repeat or a second line with the
#   same identity sends nothing. A 429 on the attachment is retried with backoff (a numeric Retry-After clamped to FOLLOWUP_RETRY_AFTER_MAX, else 2^n s), then the file
#   goes out as chunked text; a part that never sent leaves exit 1, so the entry stays undelivered and the parts already sent are not repeated. An empty attachment
#   file (0 bytes) sends a one-line empty-attachment note as the attachment part and the item is delivered.
# Env: SEAT_EVENT_BIN (default seat-event.sh on PATH / ~/.local/bin); FOLLOWUP_OUTBOX / FOLLOWUP_STATE_DIR (as followup-eval.py); FOLLOWUP_DELIVER_RETRIES (default 3);
#      FOLLOWUP_CHUNK_BYTES (default 1800); FOLLOWUP_RETRY_AFTER_MAX (default 300 s); FOLLOWUP_LOCK_HELD (set by followup-eval.py replay, which already holds the state lock).
set -u
command -v jq >/dev/null 2>&1 || exit 1
mode=""; rpart=""; ract=""; rkey=""
if [ "${1:-}" = --reconcile ]; then
  mode=rec; rpart="${2:-}"; ract="${3:-}"; [ "${4:-}" = --key ] && rkey="${5:-}"
  [ -n "$rpart" ] && { [ "$ract" = sent ] || [ "$ract" = resend ]; } || { echo "usage: followup-deliver.sh --reconcile <part> sent|resend [--key K] < event.json" >&2; exit 64; }
fi
if [ -n "$rkey" ]; then in='{"id":"reconcile","dest":"-"}'; else in="$(cat)"; fi; [ -n "$in" ] || exit 1
seat="$(jq -r '.seat // "ctl"' <<<"$in" 2>/dev/null)"; id="$(jq -r '.id // empty' <<<"$in" 2>/dev/null)"
[ -n "$id" ] || exit 1
dest="$(jq -r '.dest // empty' <<<"$in" 2>/dev/null)"
if [ -z "$dest" ] && [ -z "$mode" ]; then
  line="FOLLOW-UP $(jq -r '.kind // "obligation"' <<<"$in") $id: $(jq -r '.detail // ""' <<<"$in")"
  bin="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"
  [ -x "$bin" ] || bin="$(command -v seat-event.sh)" || exit 1
  SEAT_EVENT_NOWAKE=1 EVENT_SOURCE=followup-loop "$bin" "$seat" "$line" >/dev/null 2>&1
  exit $?
fi

sd="${FOLLOWUP_STATE_DIR:-$HOME/.local/state/followup-loop}"; ob="${FOLLOWUP_OUTBOX:-$sd/outbox.jsonl}"
retries="${FOLLOWUP_DELIVER_RETRIES:-3}"; chunk="${FOLLOWUP_CHUNK_BYTES:-1800}"
key="$(jq -r '[.dest, (.task // .id), (.rev // 0), (.result // .id), (.kind // "result")] | map(tostring) | join("|")' <<<"$in")"
[ -n "$rkey" ] && key="$rkey"
[ -n "$dest" ] || exit 1
summary="$(jq -r '.summary // empty' <<<"$in")"; att="$(jq -r '.attachment // empty' <<<"$in")"
if [ -z "${FOLLOWUP_LOCK_HELD:-}" ]; then   # one sender per state dir at a time: check, send and record are atomic against concurrent senders
  mkdir -p "$sd" && exec 9>"$sd/lock" && flock 9 || exit 1
fi
bell() { local bin="${SEAT_EVENT_BIN:-$HOME/.local/bin/seat-event.sh}"; [ -x "$bin" ] || bin="$(command -v seat-event.sh)" || return 0
  SEAT_EVENT_NOWAKE=1 EVENT_SOURCE=followup-loop "$bin" "$seat" "$1" >/dev/null 2>&1; return 0; }
nocommit() { # the outbox cannot take a durable line: nothing may be sent
  echo "followup-deliver: cannot commit to $ob ($1); nothing sent" >&2
  bell "FOLLOW-UP deliver-blocked $id: could not commit $1 to $ob; nothing was sent, fix the outbox (disk, permissions) and replay"; exit 2; }
commit_line() { # one JSON line: append, fsync, read back; 0 only when the line is durably the last line of the outbox
  printf '%s\n' "$1" >>"$ob" || return 1
  sync -- "$ob" 2>/dev/null || return 1
  [ "$(tail -n1 "$ob")" = "$1" ]; }
if [ ! -e "$ob" ]; then mkdir -p "$(dirname "$ob")" && : >"$ob" && sync -- "$(dirname "$ob")" 2>/dev/null || nocommit "outbox creation"; fi

sent() { jq -e -s --arg k "$key" --arg p "$1" 'any(.[]; (.sent_part==true or (.reconciled==true and .action=="sent")) and .key==$k and .part==$p)' "$ob" >/dev/null 2>&1; }
record() { commit_line "$(jq -nc --arg k "$key" --arg p "$1" --arg m "$2" --arg d "$dest" --arg ts "$(date -Ins)" \
  '{sent_part:true,delivered:true,key:$k,part:$p,message_id:$m,dest:$d,ts:$ts}')"; }
mark() { # kind part [marker_ts]: kind = sending_part | send_cleared | needs_reconcile; 0 only when durably committed
  commit_line "$(jq -nc --arg kind "$1" --arg k "$key" --arg p "$2" --arg d "$dest" --arg i "$id" --arg ts "$(date -Ins)" --arg mts "${3:-}" \
    '{($kind):true,key:$k,part:$p,dest:$d,id:$i,ts:$ts} + (if $mts == "" then {} else {marker_ts:$mts} end)')"; }
pstate() { # part -> "sending <ts>" when the last marker for it is an open sending_part, else "ok"
  jq -r -s --arg k "$key" --arg p "$1" '[.[] | select(.key==$k and .part==$p and (.sent_part==true or .sending_part==true or .send_cleared==true or .reconciled==true))] | last
    | if . != null and .sending_part == true then "sending " + .ts else "ok" end' "$ob" 2>/dev/null; }
reconcile() { # part marker_ts: surface the unknown part once per marker (record + bell), never resend
  jq -e -s --arg k "$key" --arg p "$1" --arg t "$2" 'any(.[]; .needs_reconcile==true and .key==$k and .part==$p and .marker_ts==$t)' "$ob" >/dev/null 2>&1 && return 0
  mark needs_reconcile "$1" "$2"
  bell "FOLLOW-UP needs-reconcile $id: part $1 of $key may already be sent (outcome unknown); not resent, settle with: followup-deliver.sh --reconcile $1 sent|resend --key '$key'"
  return 0; }
unknown() { local st; st="$(pstate "$1")"; [ "${st%% *}" = sending ] && reconcile "$1" "${st#* }"; return 0; }
if [ -n "$mode" ]; then   # flock-guarded human settlement of an unknown part (the lock above is held)
  st="$(pstate "$rpart")"
  [ "${st%% *}" = sending ] || { echo "followup-deliver: no open unknown marker for part $rpart of $key" >&2; exit 1; }
  commit_line "$(jq -nc --arg k "$key" --arg p "$rpart" --arg a "$ract" --arg ts "$(date -Ins)" '{reconciled:true,key:$k,part:$p,action:$a,by:"reconcile-mode",ts:$ts}')" || nocommit "reconcile record"
  exit 0
fi
rmax="${FOLLOWUP_RETRY_AFTER_MAX:-300}"; [[ "$rmax" =~ ^[0-9]{1,6}$ ]] || rmax=300
is_rl() { # hermes reply that positively identifies a provider rate-limit rejection (HTTP 429)
  jq -e '(try ((.http_status // .status // .status_code // .code // empty) | tostring) catch "") == "429" or ((.error // .message // "" | tostring) | test("429|rate[ _-]?limit|too many requests";"i"))' <<<"$1" >/dev/null 2>&1 \
    || grep -Eiq '(http|status)[ :=]*429|too many requests|rate[ _-]?limit' <<<"$1"; }
send_retry() { # body -> sets mid; 0 accepted with a message id, 1 positively rate-limited (nothing sent, retries used up), 2 outcome unknown
  local body="$1" n=1 out rc wait ra backoff
  while :; do
    out="$(hermes send --to "$dest" --json "$body" 2>/dev/null)"; rc=$?
    if [ "$rc" = 0 ]; then mid="$(jq -r '.message_id // empty' <<<"$out" 2>/dev/null)"; [ -n "$mid" ] && return 0; return 2; fi
    is_rl "$out" || return 2
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
deliver_part() { # part body -> 0 sent, 1 rejected by the provider (retryable), 2 outcome unknown (held for reconcile); a marker that cannot be committed exits 2 before any send
  local part="$1" body="$2" st rc
  st="$(pstate "$part")"
  if [ "${st%% *}" = sending ]; then reconcile "$part" "${st#* }"; return 2; fi
  command -v hermes >/dev/null 2>&1 || return 1
  mark sending_part "$part" || nocommit "send marker for part $part"
  send_retry "$body"; rc=$?
  case $rc in
    0) record "$part" "$mid" && return 0; unknown "$part"; return 2;;   # sent but the record failed: the open marker keeps it UNKNOWN
    1) mark send_cleared "$part" && return 1; unknown "$part"; return 2;;
    *) unknown "$part"; return 2;;
  esac
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
