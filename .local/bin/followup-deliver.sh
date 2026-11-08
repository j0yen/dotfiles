#!/usr/bin/env bash
# followup-deliver.sh: the default FOLLOWUP_DELIVER_CMD (ledger asks A1307, A1346). Reads one outbox entry (JSON) on stdin. Exit 0 only when everything was sent / the bell rang, so the outbox keeps the entry otherwise.
# - no .dest: rings the owning seat's bell with seat-event.sh (appends to the seat's events log; no model turn started by this script).
# - .dest (e.g. discord:#ops): sends .summary and .attachment through `hermes send`, once per (dest, task, rev, result, kind) and per part.
#   Each returned message id is recorded as a {"sent_part":true,...} line in the SAME outbox before the next part; a repeat or a second line with the
#   same identity sends nothing. A 429 on the attachment is retried with backoff (Retry-After, else 2^n s), then the file goes out as chunked text; a part that
#   never sent leaves exit 1, so the entry stays undelivered and the parts already sent are not repeated. A send whose outcome is unknown (crash between the
#   remote send and the local record) is NOT detectable here: hermes send has no readback, so that window can still repeat one part.
# Env: SEAT_EVENT_BIN (default seat-event.sh on PATH / ~/.local/bin); FOLLOWUP_OUTBOX / FOLLOWUP_STATE_DIR (as followup-eval.py); FOLLOWUP_DELIVER_RETRIES (default 3);
#      FOLLOWUP_CHUNK_BYTES (default 1800); FOLLOWUP_LOCK_HELD (set by followup-eval.py replay, which already holds the state lock).
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

sent() { jq -e -s --arg k "$key" --arg p "$1" 'any(.[]; .sent_part==true and .key==$k and .part==$p)' "$ob" >/dev/null 2>&1; }
record() { jq -nc --arg k "$key" --arg p "$1" --arg m "$2" --arg d "$dest" --arg ts "$(date -Is)" \
  '{sent_part:true,delivered:true,key:$k,part:$p,message_id:$m,dest:$d,ts:$ts}' >>"$ob"; }
send_retry() { # body -> sets mid; 0 when hermes accepted it. A rate-limit reply sleeps Retry-After (else 2^n s) and tries again, up to $retries attempts.
  local body="$1" n=1 out rc wait
  while :; do
    out="$(hermes send --to "$dest" --json "$body" 2>/dev/null)"; rc=$?
    if [ "$rc" = 0 ]; then mid="$(jq -r '.message_id // empty' <<<"$out" 2>/dev/null)"; return 0; fi
    [ "$n" -ge "$retries" ] && return 1
    wait="$(jq -r '.retry_after // empty' <<<"$out" 2>/dev/null)"; [ -n "$wait" ] || wait=$((2 ** n))
    [ "$wait" -lt "$((2 ** n))" ] 2>/dev/null && wait=$((2 ** n))
    sleep "$wait"; n=$((n + 1))
  done
}
mid=""; fail=0
if [ -n "$summary" ] && ! sent summary; then
  if send_retry "$summary"; then record summary "$mid"; else fail=1; fi
fi
if [ -n "$att" ] && ! sent attachment; then
  if [ ! -r "$att" ]; then fail=1
  else
    started=0; jq -e -s --arg k "$key" 'any(.[]; .sent_part==true and .key==$k and (.part|startswith("attachment-chunk-")))' "$ob" >/dev/null 2>&1 && started=1
    ok=0
    if [ "$started" = 0 ]; then
      # the file itself, one try per backoff round; a 429 here falls through to chunked text
      if FOLLOWUP_DELIVER_RETRIES="$retries" send_retry "MEDIA:$att"; then record attachment "$mid"; ok=1; fi
    fi
    if [ "$ok" = 0 ]; then
      i=0; allok=1
      while IFS= read -r -d '' part || [ -n "$part" ]; do
        i=$((i + 1))
        sent "attachment-chunk-$i" && continue
        if send_retry "$part"; then record "attachment-chunk-$i" "$mid"; else allok=0; break; fi
      done < <(python3 -I -c 'import sys
n=int(sys.argv[2]); t=open(sys.argv[1],errors="replace").read()
for i in range(0,len(t),n): sys.stdout.write(t[i:i+n]+"\0")' "$att" "$chunk")
      if [ "$allok" = 1 ] && [ "$i" -gt 0 ]; then record attachment "$mid"; else fail=1; fi
    fi
  fi
fi
exit "$fail"
